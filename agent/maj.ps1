<#
  Services de mise à jour du mode événement, envoyé devant pilote.ps1 pour
  l'op `evenement` seulement (la commande reste sous la longueur permise).
  Utilise Get-Valeur, Write-Utf8 et $base de pilote.ps1, définis avant l'appel.
  Compatible Windows PowerShell 5.1.
#>

# La pause ne retient ni le Microsoft Store ni les définitions de Defender, et
# Windows Famille ignore les stratégies de Windows Update : pendant le mode, les
# services de mise à jour sont désactivés et arrêtés. Windows (WaaSMedicSvc)
# peut les relancer : la tâche PointeNoire-Evenement les recoupe toutes les
# 15 minutes tant que mode-evenement.json existe, puis s'efface.
$servicesMaj = @('wuauserv', 'UsoSvc', 'InstallService')
$tacheGarde = 'PointeNoire-Evenement'
$scriptGarde = @'
$fichier = Join-Path $env:ProgramData 'PointeNoire\mode-evenement.json'
if (-not (Test-Path $fichier)) {
    Unregister-ScheduledTask -TaskName 'PointeNoire-Evenement' -Confirm:$false -ErrorAction SilentlyContinue
    return
}
foreach ($n in @('wuauserv', 'UsoSvc', 'InstallService')) {
    & sc.exe config $n start= disabled | Out-Null
    Stop-Service -Name $n -Force -ErrorAction SilentlyContinue
}
'@

# Le démarrage d'un service, lu dans le registre : Start (2 auto, 3 manuel,
# 4 désactivé) et DelayedAutostart, que Get-Service ne rend pas en 5.1.
function Get-Demarrage([string]$Nom) {
    $cle = "HKLM:\SYSTEM\CurrentControlSet\Services\$Nom"
    if (-not (Test-Path $cle)) { return $null }
    $svc = Get-Service -Name $Nom -ErrorAction SilentlyContinue
    [ordered]@{
        start   = Get-Valeur $cle 'Start'
        differe = Get-Valeur $cle 'DelayedAutostart'
        marche  = [bool]($svc -and $svc.Status -eq 'Running')
    }
}

function Set-Demarrage([string]$Nom, $Avant) {
    $mot = switch ([int]$Avant.start) { 2 { if ($Avant.differe -eq 1) { 'delayed-auto' } else { 'auto' } } 3 { 'demand' } 4 { 'disabled' } default { $null } }
    if ($mot) { & sc.exe config $Nom start= $mot | Out-Null }
    if ($Avant.marche) { Start-Service -Name $Nom -ErrorAction SilentlyContinue }
}

function Stop-ServicesMaj($Avant) {
    $Avant.services = [ordered]@{}
    $ko = @()
    foreach ($n in $servicesMaj) {
        $d = Get-Demarrage $n
        if (-not $d) { continue }
        $Avant.services[$n] = $d
        & sc.exe config $n start= disabled | Out-Null
        if ($LASTEXITCODE -ne 0) { $ko += "$n (sc.exe $LASTEXITCODE)" }
        try { Stop-Service -Name $n -Force -ErrorAction Stop } catch { $ko += "$n (arrêt refusé)" }
    }
    $f = Join-Path $base 'evenement-garde.ps1'
    Write-Utf8 $f $scriptGarde
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$f`""
    $quand = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 15)
    $reglages = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    $demarrage = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $tacheGarde -Action $action -Trigger @($quand, $demarrage) -Settings $reglages -Principal $principal -Force | Out-Null
    if ($ko.Count) { return "services de mise à jour arrêtés, sauf : $($ko -join ', ')" }
    'services de mise à jour et du Store arrêtés'
}

function Start-ServicesMaj($Avant) {
    Unregister-ScheduledTask -TaskName $tacheGarde -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $base 'evenement-garde.ps1') -Force -ErrorAction SilentlyContinue
    if (-not $Avant.services) { return $null }
    foreach ($p in @($Avant.services.PSObject.Properties)) { Set-Demarrage $p.Name $p.Value }
    'services de mise à jour rendus'
}

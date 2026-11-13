<#
  Pose ou retire la veille réseau (agent/reseau.ps1) dans
  C:\ProgramData\PointeNoire\reseau. Lancé par l'agent MeshCentral (compte
  SYSTEM) juste après la pose de la sonde, à part de pilote.ps1 pour rester
  sous la longueur de commande. Compatible Windows PowerShell 5.1.

  PNPL_PARAMS : { op: reseau_veille, actif, cible, nom_cible }. reseau.ps1
  arrive dans $VeilleSource, placé par le worker en tête de ce script. La
  veille lit l'adresse et le jeton de la sonde : sans sonde, pas de veille.
  Le journal du poste est gardé d'une pose à l'autre. Sortie :
  PNPL1:<jeton>:<JSON en base64>, comme pilote.ps1.
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$dossier = Join-Path $env:ProgramData 'PointeNoire\reseau'
$tache = 'PointeNoire-Reseau'
$result = [ordered]@{ op = 'reseau_veille'; ok = $false; detail = '' }

try {
    $p = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:PNPL_PARAMS)) | ConvertFrom-Json
    # La veille en cours s'arrête d'abord : le script qu'elle lit va changer.
    Stop-ScheduledTask -TaskName $tache -ErrorAction SilentlyContinue
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { [string]$_.CommandLine -like "*PointeNoire\reseau\reseau.ps1*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    if ($p.actif) {
        if (-not (Test-Path (Join-Path $env:ProgramData 'PointeNoire\supervision\config.json'))) { throw 'la sonde n''est pas installée sur ce poste' }
        $cible = $null
        if ($p.cible) {
            if ([string]$p.cible -notmatch '^[A-Za-z0-9.:-]{1,253}$') { throw 'cible du site illisible' }
            $cible = [string]$p.cible
        }
        if (-not (Test-Path $dossier)) { New-Item -ItemType Directory -Path $dossier -Force | Out-Null }
        & icacls.exe $dossier /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
        $fichier = Join-Path $dossier 'reseau.ps1'
        # Le BOM UTF-8 : sans lui, Windows PowerShell 5.1 lit le fichier en ANSI.
        [IO.File]::WriteAllText($fichier, $VeilleSource, (New-Object System.Text.UTF8Encoding $true))
        [IO.File]::WriteAllText((Join-Path $dossier 'reseau.json'), ([ordered]@{ cible = $cible; nom_cible = [string]$p.nom_cible } | ConvertTo-Json), (New-Object System.Text.UTF8Encoding $false))
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$fichier`""
        # Au démarrage, puis toutes les 5 minutes : une veille arrêtée repart,
        # une veille en cours n'est pas doublée (IgnoreNew et le mutex).
        $demarrage = New-ScheduledTaskTrigger -AtStartup
        $relance = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(5) -RepetitionInterval (New-TimeSpan -Minutes 5)
        $reglages = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -Priority 7
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskName $tache -Action $action -Trigger @($demarrage, $relance) -Settings $reglages -Principal $principal -Force | Out-Null
        Start-ScheduledTask -TaskName $tache
        $result.ok = $true
        $result.detail = 'veille réseau posée' + $(if ($cible) { " (cible du site : $(if ($p.nom_cible) { "$($p.nom_cible), " })$cible)" } else { ' (pas de cible du site)' })
    } else {
        Unregister-ScheduledTask -TaskName $tache -Confirm:$false -ErrorAction SilentlyContinue
        if (Test-Path $dossier) { Remove-Item -Path $dossier -Recurse -Force }
        $result.ok = $true
        $result.detail = 'veille réseau retirée'
    }
} catch {
    $result.ok = $false
    $result.detail = "$($_.Exception.Message) (reseau-pose.ps1, ligne $($_.InvocationInfo.ScriptLineNumber))"
}
$json = $result | ConvertTo-Json -Compress -Depth 4
'PNPL1:' + $env:PNPL_NONCE + ':' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))

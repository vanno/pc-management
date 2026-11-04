<#
  Met le poste au mur d'écrans d'AVDiagram (agent/vignette.ps1) ou l'en
  retire. Lancé par l'agent MeshCentral (compte SYSTEM), à part de pilote.ps1
  pour rester sous la longueur de commande de l'agent. Compatible Windows
  PowerShell 5.1.

  PNPL_PARAMS : { op: vignette, actif, url, jeton, script } (script :
  vignette.ps1, gzip puis base64). Sortie : PNPL1:<jeton>:<JSON en base64>,
  comme pilote.ps1.

  Pose : C:\ProgramData\PointeNoire\vignette (lecture seule pour les comptes :
  la capture tourne dans leur session et lit le jeton pnv_, qui ne permet que
  de poser l'image de ce poste), la tâche PointeNoire-Vignette (groupe
  Utilisateurs : ouverture de session, puis chaque minute), lancée par wscript
  sans fenêtre.
  Retrait : la tâche et le dossier partent.
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$dossier = Join-Path $env:ProgramData 'PointeNoire\vignette'
$tache = 'PointeNoire-Vignette'
$result = [ordered]@{ op = 'vignette'; ok = $false; detail = '' }

function Write-Texte([string]$Chemin, [string]$Texte, [bool]$Bom) {
    [IO.File]::WriteAllText($Chemin, $Texte, (New-Object System.Text.UTF8Encoding $Bom))
}

try {
    $p = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:PNPL_PARAMS)) | ConvertFrom-Json
    if ($p.actif) {
        if ([string]$p.url -notmatch '^https://[^\s"]+$') { throw 'adresse AVDiagram illisible' }
        if ([string]$p.jeton -notmatch '^pnv_[A-Za-z0-9_-]{20,100}$') { throw 'jeton de vignette illisible' }
        $m = New-Object IO.MemoryStream(, [Convert]::FromBase64String($p.script))
        $g = New-Object IO.Compression.GZipStream($m, [IO.Compression.CompressionMode]::Decompress)
        $script = (New-Object IO.StreamReader($g, [Text.Encoding]::UTF8)).ReadToEnd()
        if (-not (Test-Path $dossier)) { New-Item -ItemType Directory -Path $dossier -Force | Out-Null }
        # Les comptes lisent et lancent, seuls SYSTEM et les administrateurs écrivent.
        & icacls.exe $dossier /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
        $vignette = Join-Path $dossier 'vignette.ps1'
        $lanceur = Join-Path $dossier 'lanceur.vbs'
        # Avec BOM : PowerShell 5.1 lit sinon les accents en ANSI.
        Write-Texte $vignette $script $true
        Write-Texte (Join-Path $dossier 'config.json') (@{ url = [string]$p.url; jeton = [string]$p.jeton } | ConvertTo-Json -Compress) $false
        $commande = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$vignette"""
        $vbs = $commande.Replace('"', '""')
        Write-Texte $lanceur ("CreateObject(""WScript.Shell"").Run ""$vbs"", 0, False`r`n") $false
        $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "//B //Nologo ""$lanceur"""
        $session = New-ScheduledTaskTrigger -AtLogOn
        $minute = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)
        $reglages = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
        $principal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited
        Register-ScheduledTask -TaskName $tache -Action $action -Trigger @($session, $minute) -Settings $reglages -Principal $principal -Force | Out-Null
        Start-ScheduledTask -TaskName $tache
        $result.ok = $true
        $result.detail = 'poste mis au mur d''écrans : image envoyée seulement quand la page du mur le montre'
    } else {
        $avait = [bool](Get-ScheduledTask -TaskName $tache -ErrorAction SilentlyContinue)
        Unregister-ScheduledTask -TaskName $tache -Confirm:$false -ErrorAction SilentlyContinue
        if (Test-Path $dossier) { Remove-Item -Path $dossier -Recurse -Force }
        $result.ok = $true
        $result.detail = if ($avait) { 'poste retiré du mur d''écrans' } else { 'ce poste n''était pas au mur d''écrans' }
    }
} catch {
    $result.ok = $false
    $result.detail = $_.Exception.Message
}
$json = $result | ConvertTo-Json -Compress -Depth 4
'PNPL1:' + $env:PNPL_NONCE + ':' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))

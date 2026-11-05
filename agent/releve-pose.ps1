<#
  Pose agent/releve.ps1, le relevé de l'écran du mode événement, à côté de
  fond.ps1 (C:\ProgramData\PointeNoire\fond). Lancé par l'agent MeshCentral
  (compte SYSTEM) juste avant fond-pose.ps1 : à deux dans une commande, ils
  dépasseraient la longueur que l'agent accepte. releve.ps1 arrive dans
  $FondSource, que le worker place en tête de ce script.
  PNPL_PARAMS : { op: releve }. Sortie : PNPL1:<jeton>:<JSON en base64>, comme
  pilote.ps1. Compatible Windows PowerShell 5.1.
#>

$ErrorActionPreference = 'Stop'
$result = [ordered]@{ op = 'releve'; ok = $false; detail = '' }
try {
    if (-not $FondSource) { throw 'releve.ps1 absent de la commande' }
    $dossier = Join-Path $env:ProgramData 'PointeNoire\fond'
    if (-not (Test-Path $dossier)) { New-Item -ItemType Directory -Path $dossier -Force | Out-Null }
    # Les comptes lisent et lancent, seuls SYSTEM et les administrateurs écrivent.
    & icacls.exe $dossier /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
    # Avec BOM : PowerShell 5.1 lit sinon les accents en ANSI.
    [IO.File]::WriteAllText((Join-Path $dossier 'releve.ps1'), $FondSource, (New-Object System.Text.UTF8Encoding $true))
    $result.ok = $true
    $result.detail = 'relevé de l''écran posé'
} catch {
    $result.detail = "$($_.Exception.Message) (releve-pose.ps1, ligne $($_.InvocationInfo.ScriptLineNumber))"
}
$json = $result | ConvertTo-Json -Compress
'PNPL1:' + $env:PNPL_NONCE + ':' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))

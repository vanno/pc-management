<#
  Pose ou retire l'envoi à la console régie locale (agent/console.ps1) dans
  le dossier de la sonde. Lancé par l'agent MeshCentral (compte SYSTEM) juste
  après la pose de la sonde, à part de pilote.ps1 pour rester sous la longueur
  de commande. Compatible Windows PowerShell 5.1.

  PNPL_PARAMS : { op: console, actif, reference, consoles : [{ id, nom,
  empreinte, jeton, port, adresse }] }. console.ps1 arrive dans $RegieSource,
  placé par le worker en tête de ce script. Sortie : PNPL1:<jeton>:<JSON en
  base64>, comme pilote.ps1. Le dossier de la sonde ne se lit que par SYSTEM
  et les administrateurs : les jetons des consoles y restent.
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$dossier = Join-Path $env:ProgramData 'PointeNoire\supervision'
$result = [ordered]@{ op = 'console'; ok = $false; detail = '' }

function Write-Utf8([string]$Chemin, [string]$Texte) {
    [IO.File]::WriteAllText($Chemin, $Texte, (New-Object System.Text.UTF8Encoding $false))
}

try {
    $p = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:PNPL_PARAMS)) | ConvertFrom-Json
    $consoles = @($p.consoles | Where-Object { $_ })
    if ($p.actif -and $consoles.Count) {
        if (-not (Test-Path (Join-Path $dossier 'config.json'))) { throw 'la sonde n''est pas installée sur ce poste' }
        foreach ($c in $consoles) {
            if ([string]$c.empreinte -notmatch '^[0-9a-f]{64}$' -or [string]$c.jeton -notmatch '^pnr_[A-Za-z0-9_-]{40,60}$') { throw "console $($c.id) illisible" }
        }
        Write-Utf8 (Join-Path $dossier 'console.ps1') $RegieSource
        Write-Utf8 (Join-Path $dossier 'console.json') ([ordered]@{ reference = [string]$p.reference; consoles = $consoles } | ConvertTo-Json -Depth 4)
        Remove-Item -Path (Join-Path $dossier 'console-vue.json') -ErrorAction SilentlyContinue
        $noms = ($consoles | ForEach-Object { [string]$_.nom }) -join ', '
        $result.ok = $true
        $result.detail = "console régie posée : $noms"
    } else {
        foreach ($f in 'console.ps1', 'console.json', 'console-vue.json') { Remove-Item -Path (Join-Path $dossier $f) -ErrorAction SilentlyContinue }
        Get-ChildItem -Path $dossier -Filter 'regie-*.dll' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        $result.ok = $true
        $result.detail = 'aucune console régie'
    }
} catch {
    $result.ok = $false
    $result.detail = "$($_.Exception.Message) (console-pose.ps1, ligne $($_.InvocationInfo.ScriptLineNumber))"
}
$json = $result | ConvertTo-Json -Compress -Depth 4
'PNPL1:' + $env:PNPL_NONCE + ':' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))

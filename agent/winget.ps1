<#
  Installe ou met à jour UN logiciel par winget, lancé par l'agent MeshCentral
  (compte SYSTEM). Compatible Windows PowerShell 5.1.

  Entrées (variables posées par le worker) :
      PNWG_NONCE  le jeton de la commande
      PNWG_ID     l'identifiant winget, ex. VideoLAN.VLC

  Sortie : une seule ligne
      PNWG1:<jeton>:<JSON encodé en base64 UTF-8>
  avec { id, step (install | upgrade | none), code, scope, output }.
  Le worker lit le code de sortie de winget et en déduit l'état.

  En compte SYSTEM, winget n'est pas dans le PATH : il est cherché dans le
  dossier de l'App Installer. L'installation tente d'abord la portée machine
  (pour tous les utilisateurs du poste), puis la portée par défaut si le
  logiciel n'a pas d'installeur machine.
#>

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

$id = $env:PNWG_ID
$result = [ordered]@{ id = $id; step = 'none'; code = $null; scope = $null; output = '' }

function Send-Result {
    $json = $result | ConvertTo-Json -Compress -Depth 4
    'PNWG1:' + $env:PNWG_NONCE + ':' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
}

if (-not $id -or $id -notmatch '^[A-Za-z0-9][A-Za-z0-9.+_-]{0,127}$') {
    $result.output = 'identifiant winget absent ou illisible'
    Send-Result
    return
}

$winget = Get-ChildItem -Path "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe" |
    Sort-Object -Property { $_.Directory.Name } | Select-Object -Last 1
if (-not $winget) {
    $result.code = -1
    $result.output = 'winget introuvable (App Installer absent du poste)'
    Send-Result
    return
}
$wg = $winget.FullName
$common = @('--id', $id, '--exact', '--accept-source-agreements', '--disable-interactivity')

function Invoke-Winget([string[]]$Arguments) {
    $out = & $wg @Arguments 2>&1 | Out-String
    # Les barres de progression de winget n'apportent rien au résultat.
    $lines = $out -split "`r?`n" | Where-Object { $_ -match '\S' -and $_ -notmatch '^[\s\-\\|/█▒]*$' -and $_ -notmatch '\d+(\.\d+)?\s*[KMG]B\s*/' }
    $script:result.output = (($lines | Select-Object -Last 6) -join ' | ')
    return $LASTEXITCODE
}

& $wg list @common *> $null
$installed = ($LASTEXITCODE -eq 0)

if ($installed) {
    $result.step = 'upgrade'
    $result.code = Invoke-Winget (@('upgrade') + $common + @('--silent', '--accept-package-agreements', '--include-unknown'))
} else {
    $result.step = 'install'
    $result.scope = 'machine'
    $code = Invoke-Winget (@('install') + $common + @('--silent', '--accept-package-agreements', '--scope', 'machine'))
    # 0x8A150010 : pas d'installeur pour cette portée. On réessaie sans.
    if ($code -eq -1978335216) {
        $result.scope = 'default'
        $code = Invoke-Winget (@('install') + $common + @('--silent', '--accept-package-agreements'))
    }
    $result.code = $code
}

Send-Result

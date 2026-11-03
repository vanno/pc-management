<#
  Installe UN logiciel hors winget (vMix, ATEM, DaVinci...) à partir d'un
  installeur envoyé par le NAS. Lancé par l'agent MeshCentral (compte SYSTEM).
  Compatible Windows PowerShell 5.1.

  Entrées (variables posées par le worker) :
      PNIN_NONCE   le jeton de la commande
      PNIN_PARAMS  JSON en base64 UTF-8 : { mode, match, file, args }
          mode  check    cherche le logiciel, prépare le dossier de dépôt
                download télécharge l'installeur depuis url (adresse signée)
                install  lance l'installeur déposé, puis l'efface
          match motif du nom affiché dans Programmes et fonctionnalités, ex. vMix*
          file  nom du fichier déposé, ex. vmix29.exe
          url   adresse de téléchargement (mode download)
          args  arguments de l'installation silencieuse
          configuration  facultatif : texte écrit dans configuration.xml à côté
                de l'installeur, {configuration} dans args devient son chemin

  Sortie : une seule ligne
      PNIN1:<jeton>:<JSON encodé en base64 UTF-8>
  check    -> { found, name, version, free }   (free : octets libres du disque)
  download -> { code, size, output }
  install -> { code, output }
#>

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

$dir = Join-Path $env:ProgramData 'PointeNoire\installeurs'
$result = [ordered]@{}

function Send-Result {
    $json = $result | ConvertTo-Json -Compress -Depth 4
    'PNIN1:' + $env:PNIN_NONCE + ':' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
}

try {
    $p = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:PNIN_PARAMS)) | ConvertFrom-Json
} catch {
    $result.code = -1
    $result.output = 'paramètres illisibles'
    Send-Result
    return
}

if ($p.mode -eq 'check') {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $hit = Get-ItemProperty -Path $keys | Where-Object { $_.DisplayName -like $p.match } |
        Sort-Object -Property DisplayVersion | Select-Object -Last 1
    $result.found = [bool]$hit
    $result.name = if ($hit) { [string]$hit.DisplayName } else { $null }
    $result.version = if ($hit) { [string]$hit.DisplayVersion } else { $null }
    $drive = Get-PSDrive -Name ($env:ProgramData.Substring(0, 1))
    $result.free = if ($drive) { [int64]$drive.Free } else { $null }
    Send-Result
    return
}

if ($p.mode -eq 'download') {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $file = Join-Path $dir ([IO.Path]::GetFileName($p.file))
    Remove-Item -LiteralPath $file -Force
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (Test-Path -LiteralPath $curl) {
        # curl.exe est livré avec Windows 10 1803 et suivants.
        $out = & $curl -L --fail --silent --show-error --retry 3 -o $file $p.url 2>&1 | Out-String
        $result.code = $LASTEXITCODE
        $result.output = $out.Trim()
    } else {
        try {
            Invoke-WebRequest -Uri $p.url -OutFile $file -UseBasicParsing
            $result.code = 0
            $result.output = ''
        } catch {
            $result.code = -1
            $result.output = [string]$_.Exception.Message
        }
    }
    $item = Get-Item -LiteralPath $file
    $result.size = if ($item) { [int64]$item.Length } else { 0 }
    if ($result.code -ne 0) { Remove-Item -LiteralPath $file -Force }
    Send-Result
    return
}

if ($p.mode -eq 'install') {
    $file = Join-Path $dir ([IO.Path]::GetFileName($p.file))
    if (-not (Test-Path -LiteralPath $file)) {
        $result.code = -1
        $result.output = 'installeur absent du poste après envoi'
        Send-Result
        return
    }
    $config = $null
    $installArgs = [string]$p.args
    if ($p.configuration) {
        $config = Join-Path $dir 'configuration.xml'
        [IO.File]::WriteAllText($config, [string]$p.configuration, (New-Object Text.UTF8Encoding($false)))
        $installArgs = $installArgs.Replace('{configuration}', "`"$config`"")
    }
    try {
        if ($file -like '*.msi') {
            $argList = "/i `"$file`" /qn /norestart " + $installArgs
            $proc = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" -ArgumentList $argList -Wait -PassThru -WindowStyle Hidden
        } elseif ($installArgs) {
            $proc = Start-Process -FilePath $file -ArgumentList $installArgs -Wait -PassThru -WindowStyle Hidden
        } else {
            $proc = Start-Process -FilePath $file -Wait -PassThru -WindowStyle Hidden
        }
        $result.code = $proc.ExitCode
        $result.output = ''
    } catch {
        $result.code = -1
        $result.output = [string]$_.Exception.Message
    }
    Remove-Item -LiteralPath $file -Force
    if ($config) { Remove-Item -LiteralPath $config -Force }
    Send-Result
    return
}

$result.code = -1
$result.output = 'mode inconnu'
Send-Result

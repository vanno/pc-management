<#
  Désinstaller UN logiciel d'un poste, lancé par pc-management à travers
  MeshCentral, comme pilote.ps1 (même enveloppe PNPL1, mêmes paramètres
  PNPL_PARAMS en base64). Compte SYSTEM, Windows PowerShell 5.1.

  op desinstaller  { nom, version? } : le logiciel tel que l'inventaire le
                   lit (DisplayName des clés Uninstall de la machine, 64 et
                   32 bits). Sans version, toutes les lignes de ce nom.

  La désinstallation est silencieuse ou n'a pas lieu : un désinstalleur qui
  ouvre une fenêtre attendrait un clic que personne ne peut donner (le compte
  SYSTEM n'a pas d'écran). Dans l'ordre :
    1. MSI (clé au nom d'un GUID, WindowsInstaller = 1) :
       msiexec /x {GUID} /qn /norestart ;
    2. QuietUninstallString, la commande silencieuse que l'éditeur a écrite ;
    3. Inno Setup (propriété « Inno Setup: App Path ») : UninstallString
       avec /VERYSILENT /SUPPRESSMSGBOXES /NORESTART ;
    4. winget uninstall --name <nom> --exact --silent, qui connaît les
       options silencieuses de nombreux désinstalleurs ;
    5. sinon, refus expliqué : rien n'est lancé.

  Chaque désinstalleur a 10 minutes, puis il est arrêté. Le registre est
  ensuite relu jusqu'à une minute (certains désinstalleurs se relancent
  depuis le dossier temporaire et rendent la main tout de suite) : le point
  de contrôle dit si le logiciel est encore listé. L'agent MeshCentral
  lui-même n'est jamais désinstallé : le poste serait perdu pour le relais.
  Le redémarrage éventuel n'est jamais lancé, seulement signalé.
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$result = [ordered]@{ op = $null; ok = $false; detail = ''; methode = $null; code = $null; redemarrage = $false; points = @() }

function Send-Result {
    $json = $result | ConvertTo-Json -Compress -Depth 6
    'PNPL1:' + $env:PNPL_NONCE + ':' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
}

$Cles = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
$DelaiDesinstalleur = 600
$DelaiRelecture = 60
$Proteges = @('Mesh Agent', 'MeshCentral Agent', 'MeshAgent')

# Les lignes de ce nom (et de cette version) dans les clés Uninstall, avec le
# même filtre que l'inventaire : ce qu'on y voit est ce qu'on désinstalle.
function Get-Lignes([string]$Nom, [string]$Version) {
    @(foreach ($cle in $Cles) {
        Get-ItemProperty $cle -ErrorAction SilentlyContinue | Where-Object {
            $_.DisplayName -and ("$($_.DisplayName)").Trim() -eq $Nom -and -not $_.SystemComponent -and -not $_.ParentKeyName -and -not $_.ReleaseType -and
            (-not $Version -or "$($_.DisplayVersion)" -eq $Version)
        }
    })
}

function Stop-Arbre([int]$ProcessId) {
    & taskkill.exe /T /F /PID $ProcessId *> $null
}

# Lance une commande et attend sa fin ; rend son code de sortie, ou $null si
# elle a été arrêtée au bout du délai.
function Invoke-Desinstalleur([string]$Fichier, [string]$Arguments) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Fichier
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = [Diagnostics.Process]::Start($psi)
    if (-not $proc.WaitForExit($DelaiDesinstalleur * 1000)) {
        Stop-Arbre $proc.Id
        return $null
    }
    $proc.ExitCode
}

function Find-Winget {
    $w = Get-ChildItem -Path "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe" -ErrorAction SilentlyContinue |
        Sort-Object -Property { $_.Directory.Name } | Select-Object -Last 1
    if ($w) { $w.FullName } else { $null }
}

function Remove-Logiciel($Ligne) {
    $guid = $Ligne.PSChildName
    if ($guid -match '^\{[0-9A-Fa-f-]{36}\}$' -and ($Ligne.WindowsInstaller -eq 1 -or "$($Ligne.UninstallString)" -match 'msiexec')) {
        $script:result.methode = 'msi'
        return Invoke-Desinstalleur "$env:SystemRoot\System32\msiexec.exe" "/x $guid /qn /norestart REBOOT=ReallySuppress"
    }
    if ($Ligne.QuietUninstallString) {
        $script:result.methode = 'silencieux'
        return Invoke-Desinstalleur "$env:SystemRoot\System32\cmd.exe" ('/d /s /c "' + $Ligne.QuietUninstallString + '"')
    }
    if ($Ligne.UninstallString -and $Ligne.PSObject.Properties['Inno Setup: App Path']) {
        $script:result.methode = 'inno'
        return Invoke-Desinstalleur "$env:SystemRoot\System32\cmd.exe" ('/d /s /c "' + $Ligne.UninstallString + ' /VERYSILENT /SUPPRESSMSGBOXES /NORESTART"')
    }
    $wg = Find-Winget
    if ($wg) {
        $script:result.methode = 'winget'
        $nom = ("$($Ligne.DisplayName)").Trim() -replace '"', ''
        $code = Invoke-Desinstalleur $wg ('uninstall --name "' + $nom + '" --exact --silent --accept-source-agreements --disable-interactivity')
        # 0x8A150014 : winget ne reconnaît pas ce logiciel. Rien n'a été lancé.
        if ($code -eq -1978335212) {
            $script:result.methode = $null
            throw 'pas de désinstallation silencieuse connue pour ce logiciel (ni MSI, ni commande silencieuse de l''éditeur, ni winget) : désinstallez-le en prenant la main'
        }
        return $code
    }
    throw 'pas de désinstallation silencieuse connue pour ce logiciel et winget absent du poste : désinstallez-le en prenant la main'
}

function Invoke-Desinstaller($p) {
    $nom = ("$($p.nom)").Trim()
    $version = if ($p.version) { ("$($p.version)").Trim() } else { '' }
    if (-not $nom -or $nom.Length -gt 200) { throw 'nom de logiciel absent ou trop long' }
    foreach ($x in $Proteges) {
        if ($nom -like "*$x*") { throw 'l''agent MeshCentral ne se désinstalle pas d''ici : le poste serait perdu pour le relais' }
    }
    $lignes = Get-Lignes $nom $version
    $libelle = if ($version) { "$nom $version" } else { $nom }
    if (-not $lignes.Count) {
        $result.ok = $true
        $result.detail = "$libelle n'est pas sur ce poste (déjà désinstallé ?)"
        $result.points = @([ordered]@{ nom = $libelle; ok = $true; constat = 'absent de la liste des logiciels de Windows' })
        return
    }
    $codes = @()
    foreach ($l in $lignes) {
        $code = Remove-Logiciel $l
        if ($null -eq $code) { throw "le désinstalleur de $libelle tournait encore au bout de $([int]($DelaiDesinstalleur / 60)) minutes : arrêté" }
        $codes += $code
        if ($code -eq 3010 -or $code -eq 1641) { $result.redemarrage = $true }
    }
    $result.code = $codes[-1]
    $fin = (Get-Date).AddSeconds($DelaiRelecture)
    do {
        $reste = Get-Lignes $nom $version
        if (-not $reste.Count) { break }
        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $fin)
    $methodes = @{ msi = 'Windows Installer'; silencieux = 'commande silencieuse de l''éditeur'; inno = 'désinstalleur Inno Setup'; winget = 'winget' }
    $par = $methodes[$result.methode]
    if ($reste.Count) {
        $result.ok = $false
        $result.detail = "$libelle est encore listé après sa désinstallation ($par, code $($result.code))"
        $result.points = @([ordered]@{ nom = $libelle; ok = $false; constat = "encore dans la liste des logiciels de Windows (code $($result.code))" })
        return
    }
    $result.ok = $true
    $result.detail = "$libelle désinstallé ($par)" + $(if ($result.redemarrage) { ', redémarrage demandé par le désinstalleur, non lancé' } else { '' })
    $result.points = @([ordered]@{ nom = $libelle; ok = $true; constat = 'retiré de la liste des logiciels de Windows' })
}

try {
    $p = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:PNPL_PARAMS)) | ConvertFrom-Json
    $result.op = $p.op
    switch ($p.op) {
        'desinstaller' { Invoke-Desinstaller $p }
        default { $result.detail = "opération inconnue : $($p.op)" }
    }
} catch {
    $result.ok = $false
    $result.detail = "$($_.Exception.Message)"
}

Send-Result

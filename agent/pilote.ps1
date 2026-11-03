<#
  Pilotage d'un poste, lancé par l'agent MeshCentral (compte SYSTEM) depuis la
  page Postes d'AVDiagram. Compatible Windows PowerShell 5.1.

  Entrées (variables posées par le worker) :
      PNPL_NONCE   le jeton de la commande
      PNPL_PARAMS  JSON encodé en base64 UTF-8, avec `op` :
        etat             { evenement, depuis, cartes }
        alimentation     { mode: redemarrer | eteindre, force }
        reseau           { interface, dhcp, ip, prefixe, passerelle, dns, retour, hote, port, delai }
        reseau_resultat  lit le résultat du dernier changement de réseau
        evenement        { actif, jours }

  Sortie : une seule ligne
      PNPL1:<jeton>:<JSON encodé en base64 UTF-8>
  avec { op, ok, detail, ... }.

  Le changement de réseau coupe la connexion de l'agent : il ne se fait pas
  dans cette commande. Elle garde la configuration d'avant, écrit un script et
  le lance par une tâche planifiée (SYSTEM), puis rend la main. Ce script
  applique la demande, vérifie que MeshCentral est joignable (TCP vers hote:port)
  pendant `delai` secondes, et sinon remet la configuration d'avant. Le worker
  lit ensuite le résultat (`reseau_resultat`), une fois l'agent revenu.
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$base = Join-Path $env:ProgramData 'PointeNoire'
$fichierEvenement = Join-Path $base 'mode-evenement.json'
$dossierReseau = Join-Path $base 'reseau'
$tacheReseau = 'PointeNoire-Reseau'
$result = [ordered]@{ op = $null; ok = $false; detail = '' }

function Send-Result {
    $json = $result | ConvertTo-Json -Compress -Depth 6
    'PNPL1:' + $env:PNPL_NONCE + ':' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
}

function Write-Utf8([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding $false))
}

function Get-Carte([string]$Alias) {
    $ip = @(Get-NetIPAddress -InterfaceAlias $Alias -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike '169.254.*' })
    $route = @(Get-NetRoute -InterfaceAlias $Alias -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric)
    $dns = @((Get-DnsClientServerAddress -InterfaceAlias $Alias -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses)
    $itf = Get-NetIPInterface -InterfaceAlias $Alias -AddressFamily IPv4 -ErrorAction SilentlyContinue
    [ordered]@{
        interface  = $Alias
        dhcp       = ($itf -and $itf.Dhcp -eq 'Enabled')
        adresses   = @($ip | ForEach-Object { [ordered]@{ ip = $_.IPAddress; prefixe = [int]$_.PrefixLength } })
        passerelle = $(if ($route.Count) { $route[0].NextHop } else { $null })
        dns        = $dns
    }
}

function Get-Cartes {
    @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object {
        $c = Get-Carte $_.Name
        $c['etat'] = [string]$_.Status
        $c['mac'] = $_.MacAddress
        $c
    })
}

# --- Mode événement --------------------------------------------------------------

$cleWU = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
$valeursWU = @('PauseUpdatesStartTime', 'PauseUpdatesExpiryTime', 'PauseFeatureUpdatesStartTime', 'PauseFeatureUpdatesEndTime', 'PauseQualityUpdatesStartTime', 'PauseQualityUpdatesEndTime')
$cleAU = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
$reglagesVeille = @(@('SUB_SLEEP', 'STANDBYIDLE'), @('SUB_SLEEP', 'HIBERNATEIDLE'), @('SUB_VIDEO', 'VIDEOIDLE'))

function Get-Valeur([string]$Cle, [string]$Nom) {
    $v = Get-ItemProperty -Path $Cle -Name $Nom -ErrorAction SilentlyContinue
    if ($v) { return $v.$Nom }
    return $null
}

function Set-Valeur([string]$Cle, [string]$Nom, $Valeur, [string]$Type) {
    if ($null -eq $Valeur) {
        Remove-ItemProperty -Path $Cle -Name $Nom -ErrorAction SilentlyContinue
        return
    }
    if (-not (Test-Path $Cle)) { New-Item -Path $Cle -Force | Out-Null }
    New-ItemProperty -Path $Cle -Name $Nom -Value $Valeur -PropertyType $Type -Force | Out-Null
}

# Les deux dernières valeurs hexadécimales de powercfg /q : secteur puis batterie.
# La lecture ne dépend pas de la langue de Windows.
function Get-Veille([string]$Sous, [string]$Reglage) {
    $texte = (& powercfg.exe /q SCHEME_CURRENT $Sous $Reglage) -join "`n"
    $hex = @([regex]::Matches($texte, '0x[0-9a-fA-F]{8}') | ForEach-Object { $_.Value })
    if ($hex.Count -lt 2) { return $null }
    [ordered]@{ ac = [Convert]::ToInt64($hex[-2], 16); dc = [Convert]::ToInt64($hex[-1], 16) }
}

function Set-Veille([string]$Sous, [string]$Reglage, [long]$Ac, [long]$Dc) {
    & powercfg.exe /setacvalueindex SCHEME_CURRENT $Sous $Reglage $Ac | Out-Null
    & powercfg.exe /setdcvalueindex SCHEME_CURRENT $Sous $Reglage $Dc | Out-Null
}

# Les comptes ouverts sur le poste : leur ruche est chargée sous HKEY_USERS.
function Get-Comptes {
    @(Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^S-1-5-21-[\d-]+$' } | ForEach-Object { $_.PSChildName })
}

function Enable-Evenement([int]$Jours) {
    if (Test-Path $fichierEvenement) {
        $result.ok = $true
        $result.detail = 'mode événement déjà actif'
        return
    }
    $avant = [ordered]@{ depuis = (Get-Date).ToString('o'); wu = [ordered]@{}; au = (Get-Valeur $cleAU 'NoAutoRebootWithLoggedOnUsers'); veille = @(); toasts = [ordered]@{} }
    foreach ($n in $valeursWU) { $avant.wu[$n] = Get-Valeur $cleWU $n }
    foreach ($r in $reglagesVeille) {
        $v = Get-Veille $r[0] $r[1]
        if ($v) { $avant.veille += , [ordered]@{ sous = $r[0]; reglage = $r[1]; ac = $v.ac; dc = $v.dc } }
    }
    $comptes = Get-Comptes
    foreach ($sid in $comptes) {
        $avant.toasts[$sid] = Get-Valeur "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\PushNotifications" 'ToastEnabled'
    }
    if (-not (Test-Path $base)) { New-Item -ItemType Directory -Path $base -Force | Out-Null }
    # La sauvegarde d'abord : sans elle, pas de retour possible.
    Write-Utf8 $fichierEvenement ($avant | ConvertTo-Json -Depth 6)

    $debut = (Get-Date).ToUniversalTime()
    $fin = $debut.AddDays($Jours)
    $f = 'yyyy-MM-ddTHH:mm:ssZ'
    foreach ($n in @('PauseUpdatesStartTime', 'PauseFeatureUpdatesStartTime', 'PauseQualityUpdatesStartTime')) { Set-Valeur $cleWU $n $debut.ToString($f) 'String' }
    foreach ($n in @('PauseUpdatesExpiryTime', 'PauseFeatureUpdatesEndTime', 'PauseQualityUpdatesEndTime')) { Set-Valeur $cleWU $n $fin.ToString($f) 'String' }
    Set-Valeur $cleAU 'NoAutoRebootWithLoggedOnUsers' 1 'DWord'
    foreach ($r in $reglagesVeille) { Set-Veille $r[0] $r[1] 0 0 }
    & powercfg.exe /setactive SCHEME_CURRENT | Out-Null
    foreach ($sid in $comptes) { Set-Valeur "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\PushNotifications" 'ToastEnabled' 0 'DWord' }
    $result.ok = $true
    $result.detail = "mode événement actif : Windows Update en pause jusqu'au $($fin.ToLocalTime().ToString('dd/MM HH:mm')), veille coupée, notifications coupées pour $($comptes.Count) compte(s)"
}

function Disable-Evenement {
    if (-not (Test-Path $fichierEvenement)) {
        $result.ok = $true
        $result.detail = 'mode événement déjà inactif'
        return
    }
    $avant = Get-Content -Raw -Path $fichierEvenement | ConvertFrom-Json
    foreach ($n in $valeursWU) { Set-Valeur $cleWU $n $avant.wu.$n 'String' }
    Set-Valeur $cleAU 'NoAutoRebootWithLoggedOnUsers' $avant.au 'DWord'
    foreach ($v in @($avant.veille)) { Set-Veille $v.sous $v.reglage ([long]$v.ac) ([long]$v.dc) }
    & powercfg.exe /setactive SCHEME_CURRENT | Out-Null
    $n = 0
    foreach ($p in $avant.toasts.PSObject.Properties) {
        $cle = "Registry::HKEY_USERS\$($p.Name)\Software\Microsoft\Windows\CurrentVersion\PushNotifications"
        if (Test-Path "Registry::HKEY_USERS\$($p.Name)") { Set-Valeur $cle 'ToastEnabled' $p.Value 'DWord'; $n++ }
    }
    Remove-Item -Path $fichierEvenement -Force
    $result.ok = $true
    $result.detail = "poste rendu à la normale (actif depuis le $(([datetime]$avant.depuis).ToString('dd/MM HH:mm'))), notifications rendues pour $n compte(s)"
}

# --- Réseau --------------------------------------------------------------------

# Le script de la tâche planifiée. Il ne dépend que de ses fichiers.
$scriptReseau = @'
$ErrorActionPreference = 'Stop'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$d = Get-Content -Raw -Path (Join-Path $dir 'demande.json') | ConvertFrom-Json
$avant = Get-Content -Raw -Path (Join-Path $dir 'avant.json') | ConvertFrom-Json

function Write-Etat([string]$Etat, [string]$Detail) {
    $j = [ordered]@{ etat = $Etat; detail = $Detail; le = (Get-Date).ToString('o') } | ConvertTo-Json -Compress
    [IO.File]::WriteAllText((Join-Path $dir 'resultat.json'), $j, (New-Object System.Text.UTF8Encoding $false))
}

function Set-Config([string]$Alias, [bool]$Dhcp, $Adresses, $Passerelle, $Dns) {
    Get-NetRoute -InterfaceAlias $Alias -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
    if ($Dhcp) {
        Get-NetIPAddress -InterfaceAlias $Alias -AddressFamily IPv4 -PrefixOrigin Manual -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
        Set-NetIPInterface -InterfaceAlias $Alias -AddressFamily IPv4 -Dhcp Enabled
        Set-DnsClientServerAddress -InterfaceAlias $Alias -ResetServerAddresses
        & ipconfig.exe /renew "$Alias" | Out-Null
        return
    }
    Set-NetIPInterface -InterfaceAlias $Alias -AddressFamily IPv4 -Dhcp Disabled
    Get-NetIPAddress -InterfaceAlias $Alias -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    $premiere = $true
    foreach ($a in @($Adresses)) {
        $p = @{ InterfaceAlias = $Alias; AddressFamily = 'IPv4'; IPAddress = $a.ip; PrefixLength = [int]$a.prefixe }
        if ($premiere -and $Passerelle) { $p.DefaultGateway = $Passerelle }
        New-NetIPAddress @p | Out-Null
        $premiere = $false
    }
    if (@($Dns).Count) { Set-DnsClientServerAddress -InterfaceAlias $Alias -ServerAddresses @($Dns) }
    else { Set-DnsClientServerAddress -InterfaceAlias $Alias -ResetServerAddresses }
}

function Restore {
    Set-Config $avant.interface ([bool]$avant.dhcp) $avant.adresses $avant.passerelle $avant.dns
}

function Test-Mesh {
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $t = $c.ConnectAsync($d.hote, [int]$d.port)
        return ($t.Wait(3000) -and $c.Connected)
    } catch { return $false } finally { $c.Dispose() }
}

Write-Etat 'en_cours' 'changement en cours'
try {
    $adresses = @()
    if (-not $d.dhcp) { $adresses = @([pscustomobject]@{ ip = $d.ip; prefixe = $d.prefixe }) }
    Set-Config $d.interface ([bool]$d.dhcp) $adresses $d.passerelle $d.dns
} catch {
    $msg = $_.Exception.Message
    try { Restore } catch { }
    Write-Etat 'echec' ("changement refusé par Windows, configuration d'avant remise : " + $msg)
    return
}
if (-not $d.retour) {
    Start-Sleep -Seconds 10
    Write-Etat 'applique' 'appliqué sans retour automatique'
    return
}
$depart = Get-Date
$fin = $depart.AddSeconds([int]$d.delai)
Start-Sleep -Seconds 5
while ((Get-Date) -lt $fin) {
    if (Test-Mesh) {
        Write-Etat 'applique' ("MeshCentral joint après " + [int]((Get-Date) - $depart).TotalSeconds + " s")
        return
    }
    Start-Sleep -Seconds 5
}
try {
    Restore
    Write-Etat 'retour' ("MeshCentral injoignable après " + [int]$d.delai + " s : configuration d'avant remise")
} catch {
    Write-Etat 'echec' ("MeshCentral injoignable, et le retour à la configuration d'avant a échoué : " + $_.Exception.Message)
}
'@

function Start-Reseau($p) {
    if (-not (Get-NetAdapter -Name $p.interface -ErrorAction SilentlyContinue)) {
        $noms = (@(Get-NetAdapter -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) -join ', ')
        throw "aucune carte réseau nommée « $($p.interface) » sur ce poste (cartes : $noms)"
    }
    $etat = Get-ScheduledTask -TaskName $tacheReseau -ErrorAction SilentlyContinue
    if ($etat -and $etat.State -eq 'Running') { throw 'un changement de réseau est déjà en cours sur ce poste' }
    if (-not (Test-Path $dossierReseau)) { New-Item -ItemType Directory -Path $dossierReseau -Force | Out-Null }
    $avant = Get-Carte $p.interface
    Write-Utf8 (Join-Path $dossierReseau 'avant.json') ($avant | ConvertTo-Json -Depth 5)
    Write-Utf8 (Join-Path $dossierReseau 'demande.json') ($p | ConvertTo-Json -Depth 5)
    Write-Utf8 (Join-Path $dossierReseau 'appliquer.ps1') $scriptReseau
    Write-Utf8 (Join-Path $dossierReseau 'resultat.json') '{"etat":"prevu","detail":"en attente de la tâche planifiée"}'
    $script = Join-Path $dossierReseau 'appliquer.ps1'
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$script`""
    $reglages = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 15) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $tacheReseau -Action $action -Settings $reglages -Principal $principal -Force | Out-Null
    Start-ScheduledTask -TaskName $tacheReseau
    $result.ok = $true
    $result.avant = $avant
    $result.detail = 'changement lancé'
}

function Read-Reseau {
    $f = Join-Path $dossierReseau 'resultat.json'
    if (-not (Test-Path $f)) { throw 'aucun changement de réseau sur ce poste' }
    $r = Get-Content -Raw -Path $f | ConvertFrom-Json
    $result.etat = $r.etat
    $result.detail = $r.detail
    $result.ok = $true
    if ($r.etat -in @('applique', 'retour', 'echec')) {
        Unregister-ScheduledTask -TaskName $tacheReseau -Confirm:$false -ErrorAction SilentlyContinue
        $result.carte = Get-Carte (Get-Content -Raw -Path (Join-Path $dossierReseau 'demande.json') | ConvertFrom-Json).interface
    }
}

# --- Entrée --------------------------------------------------------------------

try {
    $p = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:PNPL_PARAMS)) | ConvertFrom-Json
    $result.op = $p.op
    switch ($p.op) {
        'etat' {
            $result.evenement = (Test-Path $fichierEvenement)
            if ($result.evenement) { $result.depuis = (Get-Content -Raw -Path $fichierEvenement | ConvertFrom-Json).depuis }
            $result.cartes = Get-Cartes
            $result.ok = $true
        }
        'alimentation' {
            if ((Test-Path $fichierEvenement) -and -not $p.force) {
                $result.detail = 'refusé : le poste est en mode événement'
                break
            }
            $drapeau = '/r'
            $mot = 'Redémarrage'
            if ($p.mode -eq 'eteindre') { $drapeau = '/s'; $mot = 'Extinction' }
            & shutdown.exe $drapeau /f /t 30 /c "$mot demandé depuis AVDiagram (Pointe Noire) dans 30 secondes." | Out-Null
            $code = $LASTEXITCODE
            $result.code = $code
            if ($code -eq 0) { $result.ok = $true; $result.detail = "$($mot.ToLower()) dans 30 secondes" }
            elseif ($code -eq 1190) { $result.ok = $true; $result.detail = 'un arrêt était déjà programmé' }
            else { $result.detail = "shutdown.exe a rendu le code $code" }
        }
        'reseau' { Start-Reseau $p }
        'reseau_resultat' { Read-Reseau }
        'evenement' {
            if ($p.actif) {
                $jours = 7
                if ($p.jours) { $jours = [Math]::Min(35, [Math]::Max(1, [int]$p.jours)) }
                Enable-Evenement $jours
            } else { Disable-Evenement }
        }
        default { $result.detail = "opération inconnue : $($p.op)" }
    }
} catch {
    $result.ok = $false
    $result.detail = $_.Exception.Message
}
Send-Result

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
        evenement        { actif, jours, parties } (windows_update, veille,
                         notifications, conseils, fond ; toutes sans parties)
        supervision      { actif, url, jeton, script } : pose ou retire la sonde
                         (script : agent/supervision.ps1, gzip puis base64)
        script           { empreinte, script, delai } : lance un script approuvé
                         dans AVDiagram (gzip puis base64), refusé si son
                         empreinte SHA-256 n'est pas celle annoncée
        fichier          { url, nom, destination, taille } : télécharge un
                         fichier de la bibliothèque dans un dossier du poste
        nettoyage        { actif, applications } : applique ou annule le profil
                         de nettoyage (alimentation, services, tâches,
                         réglages ; applications Windows inutiles si
                         `applications`). L'état d'avant est gardé dans
                         ProgramData\PointeNoire\nettoyage.json.

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

$toutesParties = @('windows_update', 'veille', 'notifications', 'conseils', 'fond')
$cleToast = 'Software\Microsoft\Windows\CurrentVersion\PushNotifications'
$cleNotif = 'Software\Microsoft\Windows\CurrentVersion\Notifications\Settings'
$cleCdm = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
$cleScoobe = 'Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement'
# Conseils, suggestions et « Tirez le meilleur parti de Windows ».
$valeursConseils = @('SubscribedContent-338389Enabled', 'SubscribedContent-310093Enabled', 'SubscribedContent-338388Enabled', 'SoftLandingEnabled', 'SystemPaneSuggestionsEnabled')

function Read-Fond {
    $f = Join-Path $base 'fond\etat.json'
    if (-not (Test-Path $f)) { return $null }
    try { Get-Content -Raw -Encoding UTF8 $f | ConvertFrom-Json } catch { $null }
}

function Get-Parties($Demande) {
    $r = @(@($Demande) | Where-Object { $toutesParties -contains $_ })
    if (-not $r.Count) { $r = $toutesParties }
    $r
}

# Lit l'état d'avant d'une partie (pour la rendre), puis l'applique.
function Set-Partie([string]$Partie, $Avant, [int]$Jours) {
    switch ($Partie) {
        'windows_update' {
            $Avant.wu = [ordered]@{}
            foreach ($n in $valeursWU) { $Avant.wu[$n] = Get-Valeur $cleWU $n }
            $Avant.au = Get-Valeur $cleAU 'NoAutoRebootWithLoggedOnUsers'
            $debut = (Get-Date).ToUniversalTime(); $fin = $debut.AddDays($Jours); $f = 'yyyy-MM-ddTHH:mm:ssZ'
            foreach ($n in @('PauseUpdatesStartTime', 'PauseFeatureUpdatesStartTime', 'PauseQualityUpdatesStartTime')) { Set-Valeur $cleWU $n $debut.ToString($f) 'String' }
            foreach ($n in @('PauseUpdatesExpiryTime', 'PauseFeatureUpdatesEndTime', 'PauseQualityUpdatesEndTime')) { Set-Valeur $cleWU $n $fin.ToString($f) 'String' }
            Set-Valeur $cleAU 'NoAutoRebootWithLoggedOnUsers' 1 'DWord'
            "Windows Update en pause jusqu'au $($fin.ToLocalTime().ToString('dd/MM HH:mm'))"
        }
        'veille' {
            $Avant.veille = @()
            foreach ($r in $reglagesVeille) {
                $v = Get-Veille $r[0] $r[1]
                if ($v) { $Avant.veille += , [ordered]@{ sous = $r[0]; reglage = $r[1]; ac = $v.ac; dc = $v.dc } }
            }
            foreach ($r in $reglagesVeille) { Set-Veille $r[0] $r[1] 0 0 }
            & powercfg.exe /setactive SCHEME_CURRENT | Out-Null
            'veille coupée'
        }
        'notifications' {
            $Avant.toasts = [ordered]@{}; $Avant.global = [ordered]@{}
            $comptes = @(Get-Comptes)
            foreach ($sid in $comptes) {
                $h = "Registry::HKEY_USERS\$sid"
                $Avant.toasts[$sid] = Get-Valeur "$h\$cleToast" 'ToastEnabled'
                $Avant.global[$sid] = Get-Valeur "$h\$cleNotif" 'NOC_GLOBAL_SETTING_TOASTS_ENABLED'
                Set-Valeur "$h\$cleToast" 'ToastEnabled' 0 'DWord'
                Set-Valeur "$h\$cleNotif" 'NOC_GLOBAL_SETTING_TOASTS_ENABLED' 0 'DWord'
            }
            "notifications coupées pour $($comptes.Count) compte(s)"
        }
        'conseils' {
            $Avant.conseils = [ordered]@{}
            $comptes = @(Get-Comptes)
            foreach ($sid in $comptes) {
                $h = "Registry::HKEY_USERS\$sid"
                $c = [ordered]@{ scoobe = (Get-Valeur "$h\$cleScoobe" 'ScoobeSystemSettingEnabled') }
                foreach ($n in $valeursConseils) { $c[$n] = Get-Valeur "$h\$cleCdm" $n; Set-Valeur "$h\$cleCdm" $n 0 'DWord' }
                Set-Valeur "$h\$cleScoobe" 'ScoobeSystemSettingEnabled' 0 'DWord'
                $Avant.conseils[$sid] = $c
            }
            "conseils Windows coupés pour $($comptes.Count) compte(s)"
        }
        # Le fond d'état (fond.ps1) lit les parties actives : écran noir et
        # « MODE ÉVÉNEMENT ». Sans fond d'état, le relais le pose (fond_a_poser)
        # et Reset-Partie le retire à la fin.
        'fond' {
            $e = Read-Fond
            $Avant.fond = [bool]($e -and -not $e.retire)
            if (-not $Avant.fond) { $result.fond_a_poser = $true }
            'écran « Mode événement »'
        }
    }
}

function Reset-Partie([string]$Partie, $Avant) {
    switch ($Partie) {
        'windows_update' {
            foreach ($n in $valeursWU) { Set-Valeur $cleWU $n $Avant.wu.$n 'String' }
            Set-Valeur $cleAU 'NoAutoRebootWithLoggedOnUsers' $Avant.au 'DWord'
            'Windows Update repris'
        }
        'veille' {
            foreach ($v in @($Avant.veille)) { Set-Veille $v.sous $v.reglage ([long]$v.ac) ([long]$v.dc) }
            & powercfg.exe /setactive SCHEME_CURRENT | Out-Null
            'veille rendue'
        }
        'notifications' {
            $n = 0
            foreach ($p in @($Avant.toasts.PSObject.Properties)) {
                $h = "Registry::HKEY_USERS\$($p.Name)"
                if (-not (Test-Path $h)) { continue }
                Set-Valeur "$h\$cleToast" 'ToastEnabled' $p.Value 'DWord'
                if ($Avant.global) { Set-Valeur "$h\$cleNotif" 'NOC_GLOBAL_SETTING_TOASTS_ENABLED' $Avant.global.($p.Name) 'DWord' }
                $n++
            }
            "notifications rendues pour $n compte(s)"
        }
        'conseils' {
            $n = 0
            foreach ($p in @($Avant.conseils.PSObject.Properties)) {
                $h = "Registry::HKEY_USERS\$($p.Name)"
                if (-not (Test-Path $h)) { continue }
                foreach ($v in $valeursConseils) { Set-Valeur "$h\$cleCdm" $v $p.Value.$v 'DWord' }
                Set-Valeur "$h\$cleScoobe" 'ScoobeSystemSettingEnabled' $p.Value.scoobe 'DWord'
                $n++
            }
            "conseils Windows rendus pour $n compte(s)"
        }
        'fond' {
            if ($Avant.fond -ne $false) { 'écran rendu' }
            else {
                # Posé pour l'événement seulement : retiré, chaque compte retrouve son fond.
                $f = Join-Path $base 'fond\etat.json'
                $e = Read-Fond
                if ($e -and -not $e.retire) {
                    $e | Add-Member -NotePropertyName retire -NotePropertyValue $true -Force
                    $e | Add-Member -NotePropertyName retireLe -NotePropertyValue (Get-Date).ToString('o') -Force
                    Write-Utf8 $f ($e | ConvertTo-Json -Depth 4)
                    Remove-Item (Join-Path $env:PUBLIC 'Desktop\État du poste.lnk') -Force -ErrorAction SilentlyContinue
                }
                'état de l''écran retiré (posé pour l''événement)'
            }
        }
    }
}

function Read-Evenement {
    if (-not (Test-Path $fichierEvenement)) { return $null }
    $e = Get-Content -Raw -Path $fichierEvenement | ConvertFrom-Json
    # Avant les parties (lot 2) : les trois d'origine.
    if (-not $e.parties) { $e | Add-Member -NotePropertyName parties -NotePropertyValue @('windows_update', 'veille', 'notifications') }
    $e
}

function Enable-Evenement([int]$Jours, $Demande) {
    $etat = Read-Evenement
    if (-not $etat) { $etat = [pscustomobject]@{ depuis = (Get-Date).ToString('o'); parties = @() } }
    $nouvelles = @(Get-Parties $Demande | Where-Object { @($etat.parties) -notcontains $_ })
    if (-not $nouvelles.Count) { $result.ok = $true; $result.detail = 'mode événement déjà actif'; return }
    if (-not (Test-Path $base)) { New-Item -ItemType Directory -Path $base -Force | Out-Null }
    $faits = @()
    foreach ($partie in $nouvelles) {
        $avant = [ordered]@{ wu = $null; au = $null; veille = $null; toasts = $null; global = $null; conseils = $null; fond = $null }
        $texte = Set-Partie $partie $avant $Jours
        foreach ($k in @($avant.Keys)) { if ($null -ne $avant[$k]) { $etat | Add-Member -NotePropertyName $k -NotePropertyValue $avant[$k] -Force } }
        $etat.parties = @(@($etat.parties) + $partie)
        # La sauvegarde après chaque partie : sans elle, pas de retour possible.
        Write-Utf8 $fichierEvenement ($etat | ConvertTo-Json -Depth 6)
        $faits += $texte
    }
    $result.ok = $true
    $result.detail = "mode événement actif : $($faits -join ', ')"
}

function Disable-Evenement($Demande) {
    $etat = Read-Evenement
    if (-not $etat) { $result.ok = $true; $result.detail = 'mode événement déjà inactif'; return }
    $demandees = @(Get-Parties $Demande)
    $faits = @()
    foreach ($partie in @($etat.parties)) {
        if ($demandees -contains $partie) { $faits += Reset-Partie $partie $etat }
    }
    $reste = @(@($etat.parties) | Where-Object { $demandees -notcontains $_ })
    if ($reste.Count) {
        $etat.parties = $reste
        Write-Utf8 $fichierEvenement ($etat | ConvertTo-Json -Depth 6)
        $result.ok = $true
        $result.detail = "$($faits -join ', '). Reste actif : $($reste -join ', ')"
        return
    }
    # La copie rendue : agent/controle.ps1 y relit l'état d'avant.
    Write-Utf8 (Join-Path $base 'mode-evenement-rendu.json') ($etat | ConvertTo-Json -Depth 6)
    Remove-Item -Path $fichierEvenement -Force
    $result.ok = $true
    $result.detail = "poste rendu à la normale (actif depuis le $(([datetime]$etat.depuis).ToString('dd/MM HH:mm'))) : $($faits -join ', ')"
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

# --- Supervision ------------------------------------------------------------------

$dossierSonde = Join-Path $base 'supervision'
$tacheSonde = 'PointeNoire-Supervision'

function Install-Sonde($p) {
    if ($p.url -notmatch '^https://' -or $p.jeton -notmatch '^pns_[A-Za-z0-9_-]{20,100}$') { throw 'adresse ou jeton de sonde illisible' }
    $m = New-Object IO.MemoryStream(, [Convert]::FromBase64String($p.script))
    $g = New-Object IO.Compression.GZipStream($m, [IO.Compression.CompressionMode]::Decompress)
    $script = (New-Object IO.StreamReader($g, [Text.Encoding]::UTF8)).ReadToEnd()
    if (-not (Test-Path $dossierSonde)) { New-Item -ItemType Directory -Path $dossierSonde -Force | Out-Null }
    # Le jeton ne se lit que par SYSTEM et les administrateurs (SID : sans dépendre de la langue).
    & icacls.exe $dossierSonde /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    Write-Utf8 (Join-Path $dossierSonde 'supervision.ps1') $script
    Write-Utf8 (Join-Path $dossierSonde 'config.json') ([ordered]@{ url = $p.url; jeton = $p.jeton } | ConvertTo-Json)
    Remove-Item -Path (Join-Path $dossierSonde 'en-attente.json') -ErrorAction SilentlyContinue
    $fichier = Join-Path $dossierSonde 'supervision.ps1'
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$fichier`""
    $chaqueMinute = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(10) -RepetitionInterval (New-TimeSpan -Minutes 1)
    $demarrage = New-ScheduledTaskTrigger -AtStartup
    $reglages = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $tacheSonde -Action $action -Trigger @($chaqueMinute, $demarrage) -Settings $reglages -Principal $principal -Force | Out-Null
    $result.ok = $true
    $result.detail = 'sonde installée : premières mesures dans la minute'
}

function Remove-Sonde {
    Unregister-ScheduledTask -TaskName $tacheSonde -Confirm:$false -ErrorAction SilentlyContinue
    if (Test-Path $dossierSonde) { Remove-Item -Path $dossierSonde -Recurse -Force }
    $result.ok = $true
    $result.detail = 'sonde retirée'
}

# --- Envois : scripts approuvés et fichiers ------------------------------------------

$dossierScripts = Join-Path $base 'scripts'

function Get-Fin([string]$Texte, [int]$Max) {
    if (-not $Texte) { return '' }
    $t = $Texte.Trim()
    if ($t.Length -le $Max) { return $t }
    '…' + $t.Substring($t.Length - $Max)
}

function Invoke-Script($p) {
    if ($p.empreinte -notmatch '^[0-9a-f]{64}$') { throw 'empreinte du script illisible' }
    $m = New-Object IO.MemoryStream(, [Convert]::FromBase64String($p.script))
    $g = New-Object IO.Compression.GZipStream($m, [IO.Compression.CompressionMode]::Decompress)
    $octets = New-Object IO.MemoryStream
    $g.CopyTo($octets)
    $brut = $octets.ToArray()
    $sha = [Security.Cryptography.SHA256]::Create()
    $vue = -join ($sha.ComputeHash($brut) | ForEach-Object { $_.ToString('x2') })
    if ($vue -ne $p.empreinte) { throw 'le script reçu ne correspond pas à son empreinte : rien n''est lancé' }
    if (-not (Test-Path $dossierScripts)) { New-Item -ItemType Directory -Path $dossierScripts -Force | Out-Null }
    & icacls.exe $dossierScripts /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    $fichier = Join-Path $dossierScripts ($vue + '.ps1')
    $sortie = Join-Path $dossierScripts ($vue + '.out.txt')
    $erreurs = Join-Path $dossierScripts ($vue + '.err.txt')
    # Le BOM UTF-8 : sans lui, Windows PowerShell 5.1 lit le fichier en ANSI.
    [IO.File]::WriteAllText($fichier, [Text.Encoding]::UTF8.GetString($brut), (New-Object System.Text.UTF8Encoding $true))
    $delai = 300
    if ($p.delai) { $delai = [Math]::Min(1800, [Math]::Max(10, [int]$p.delai)) }
    try {
        $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "`"$fichier`"") `
            -RedirectStandardOutput $sortie -RedirectStandardError $erreurs -WindowStyle Hidden -PassThru
        $fini = $proc.WaitForExit($delai * 1000)
        if (-not $fini) {
            & taskkill.exe /PID $proc.Id /T /F | Out-Null
            $result.code = $null
        } else {
            $proc.WaitForExit()
            $result.code = $proc.ExitCode
        }
        $out = ''
        $err = ''
        if (Test-Path $sortie) { $out = [IO.File]::ReadAllText($sortie) }
        if (Test-Path $erreurs) { $err = [IO.File]::ReadAllText($erreurs) }
        $result.sortie = Get-Fin $out 2500
        $result.erreurs = Get-Fin $err 1000
        if (-not $fini) {
            $result.detail = "arrêté après $delai secondes"
        } elseif ($result.code -eq 0 -and -not $err.Trim()) {
            $result.ok = $true
            $result.detail = 'script terminé (code 0)'
        } elseif ($result.code -eq 0) {
            $result.ok = $true
            $result.detail = 'script terminé (code 0), avec des erreurs écrites'
        } else {
            $result.detail = "le script a rendu le code $($result.code)"
        }
    } finally {
        Remove-Item -Path $fichier, $sortie, $erreurs -Force -ErrorAction SilentlyContinue
    }
}

function Save-Fichier($p) {
    if ($p.url -notmatch '^https://') { throw 'adresse de téléchargement illisible' }
    if ($p.nom -notmatch '^[A-Za-z0-9][A-Za-z0-9 ._()+-]{0,150}\.[A-Za-z0-9]{1,10}$') { throw 'nom de fichier refusé' }
    $dest = [string]$p.destination
    if ($dest -notmatch '^[A-Za-z]:\\' -or $dest -match '\.\.' -or $dest -match '[<>"|?*]' -or $dest.Length -gt 240) { throw 'dossier de destination refusé' }
    if (-not (Test-Path -LiteralPath $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
    $cible = Join-Path $dest $p.nom
    $partiel = $cible + '.part'
    Remove-Item -LiteralPath $partiel -Force -ErrorAction SilentlyContinue
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (Test-Path -LiteralPath $curl) {
        # Sous Windows PowerShell 5.1, la sortie d'erreur d'un programme
        # redirigée lève une exception avec 'Stop' : le code de curl suffit.
        $ErrorActionPreference = 'Continue'
        $out = & $curl -L --fail --silent --show-error --retry 3 -o $partiel $p.url 2>&1 | Out-String
        $code = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        if ($code -ne 0) {
            Remove-Item -LiteralPath $partiel -Force -ErrorAction SilentlyContinue
            throw "téléchargement impossible (curl $code) : $(Get-Fin $out 200)"
        }
    } else {
        Invoke-WebRequest -Uri $p.url -OutFile $partiel -UseBasicParsing
    }
    $taille = (Get-Item -LiteralPath $partiel).Length
    if ($p.taille -and [int64]$p.taille -ne $taille) {
        Remove-Item -LiteralPath $partiel -Force -ErrorAction SilentlyContinue
        throw "téléchargement incomplet ($taille octets sur $($p.taille))"
    }
    Move-Item -LiteralPath $partiel -Destination $cible -Force
    $result.ok = $true
    $result.taille = $taille
    $result.detail = "posé dans $cible"
}

# --- Nettoyage (lot 6) -----------------------------------------------------------

$fichierNettoyage = Join-Path $base 'nettoyage.json'
# Performances optimales (copiée à l'application), sinon Performances élevées.
$planOptimal = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
$planEleve = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
# Ce qui ne sert à rien sur un poste de production : télémétrie, Xbox, cartes,
# démonstration en magasin, fax, géolocalisation. Rien de ce dont vMix, NDI,
# Office ou MeshCentral ont besoin (Defender, pare-feu, Windows Update, la
# recherche, les manettes restent tels quels).
$servicesNettoyage = @('DiagTrack', 'dmwappushservice', 'MapsBroker', 'RetailDemo', 'XblAuthManager', 'XblGameSave', 'XboxNetApiSvc', 'Fax', 'lfsvc')
$tachesNettoyage = @(
    '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser',
    '\Microsoft\Windows\Application Experience\ProgramDataUpdater',
    '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator',
    '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip',
    '\Microsoft\Windows\Feedback\Siuf\DmClient',
    '\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload',
    '\Microsoft\Windows\Maps\MapsUpdateTask',
    '\Microsoft\Windows\Maps\MapsToastTask',
    '\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector'
)
# cle, nom, valeur (DWord)
$reglagesNettoyage = @(
    @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection', 'AllowTelemetry', 1),
    @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR', 'AllowGameDVR', 0),
    @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent', 'DisableWindowsConsumerFeatures', 1),
    @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo', 'DisabledByGroupPolicy', 1),
    @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search', 'AllowCortana', 0),
    @('HKLM:\SOFTWARE\Policies\Microsoft\Dsh', 'AllowNewsAndInterests', 0),
    # Démarrage rapide coupé : un vrai redémarrage, et le Wake-on-LAN plus fiable.
    @('HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power', 'HiberbootEnabled', 0)
)
$applicationsNettoyage = @(
    'Microsoft.BingNews', 'Microsoft.BingWeather', 'Microsoft.BingSearch', 'Microsoft.GamingApp', 'Microsoft.XboxApp',
    'Microsoft.XboxGamingOverlay', 'Microsoft.XboxGameOverlay', 'Microsoft.XboxSpeechToTextOverlay',
    'Microsoft.MicrosoftSolitaireCollection', 'Microsoft.People', 'Microsoft.WindowsFeedbackHub', 'Microsoft.GetHelp',
    'Microsoft.Getstarted', 'Microsoft.MicrosoftOfficeHub', 'Microsoft.WindowsMaps', 'Microsoft.Todos',
    'Microsoft.PowerAutomateDesktop', 'Microsoft.549981C3F5F10', 'Microsoft.MixedReality.Portal', 'Microsoft.SkypeApp',
    'Clipchamp.Clipchamp', 'MicrosoftCorporationII.MicrosoftFamily', 'king.com.*', 'Disney.*', 'SpotifyAB.SpotifyMusic'
)
$cleServices = 'HKLM:\SYSTEM\CurrentControlSet\Services'

function Get-PlanActif {
    $texte = (& powercfg.exe /getactivescheme) -join ' '
    $m = [regex]::Match($texte, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
    if ($m.Success) { return $m.Value.ToLower() }
    return $null
}

$nomPlan = 'Pointe Noire production'

# Avant le 2026-11-05, chaque allègement créait ce plan sans le garder.
function Get-PlansProduction {
    foreach ($l in @(& powercfg.exe /list)) {
        $m = [regex]::Match([string]$l, '([0-9a-fA-F-]{36})\s+\((.+)\)')
        if ($m.Success -and $m.Groups[2].Value.Trim() -eq $nomPlan) { $m.Groups[1].Value.ToLower() }
    }
}

function Set-PlanProduction($etat) {
    if (-not $etat.plan) { $etat.plan = [ordered]@{ avant = (Get-PlanActif); cree = $null } }
    $guid = $etat.plan.cree
    $faits = @(Get-PlansProduction)
    if ($faits -notcontains $guid) {
        # Un plan laissé par un allègement d'avant : l'actif s'il en est un.
        $a = Get-PlanActif
        $guid = $(if ($faits -contains $a) { $a } else { $faits | Select-Object -First 1 })
        $etat.plan.cree = $guid
    }
    if (-not $guid) {
        $texte = (& powercfg.exe /duplicatescheme $planOptimal) -join ' '
        $m = [regex]::Match($texte, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
        if ($LASTEXITCODE -eq 0 -and $m.Success) {
            $guid = $m.Value.ToLower()
            $etat.plan.cree = $guid
            & powercfg.exe /changename $guid $nomPlan | Out-Null
        } else {
            $guid = $planEleve
        }
    }
    # Pas de mise en veille sélective USB ni d'économie PCI Express : les cartes
    # de capture, les interfaces audio et les manettes restent alimentées.
    & powercfg.exe /setacvalueindex $guid 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0 | Out-Null
    & powercfg.exe /setacvalueindex $guid SUB_PCIEXPRESS ASPM 0 | Out-Null
    & powercfg.exe /setactive $guid | Out-Null
    if ($LASTEXITCODE -ne 0) { return 'plan d''alimentation inchangé' }
    $faits | Where-Object { $_ -ne $guid } | ForEach-Object { & powercfg.exe /delete $_ | Out-Null }
    if ($guid -eq $planEleve) { return 'plan Performances élevées' }
    return 'plan Performances optimales'
}

function Enable-Nettoyage([bool]$Applications) {
    if (-not (Test-Path $base)) { New-Item -ItemType Directory -Path $base -Force | Out-Null }
    $etat = [ordered]@{ depuis = (Get-Date).ToString('o'); plan = $null; services = [ordered]@{}; taches = [ordered]@{}; reglages = [ordered]@{}; applications = @() }
    if (Test-Path $fichierNettoyage) {
        # Appliqué une seconde fois : l'état d'origine reste celui de la première.
        $lu = Get-Content -Raw -Path $fichierNettoyage | ConvertFrom-Json
        $etat.depuis = $lu.depuis
        if ($lu.plan) { $etat.plan = [ordered]@{ avant = $lu.plan.avant; cree = $lu.plan.cree } }
        foreach ($x in @('services', 'taches', 'reglages')) {
            if ($lu.$x) { foreach ($q in $lu.$x.PSObject.Properties) { $etat[$x][$q.Name] = $q.Value } }
        }
        $etat.applications = @($lu.applications | Where-Object { $_ })
    }
    foreach ($n in $servicesNettoyage) {
        $cle = Join-Path $cleServices $n
        if (-not (Test-Path $cle)) { continue }
        if (-not $etat.services.Contains($n)) {
            $etat.services[$n] = [ordered]@{ start = (Get-Valeur $cle 'Start'); delai = (Get-Valeur $cle 'DelayedAutostart') }
        }
    }
    foreach ($t in $tachesNettoyage) {
        $i = $t.LastIndexOf('\')
        $tache = Get-ScheduledTask -TaskPath $t.Substring(0, $i + 1) -TaskName $t.Substring($i + 1) -ErrorAction SilentlyContinue
        if (-not $tache) { continue }
        if (-not $etat.taches.Contains($t)) { $etat.taches[$t] = ($tache.State -ne 'Disabled') }
    }
    foreach ($r in $reglagesNettoyage) {
        $k = $r[0] + '|' + $r[1]
        if (-not $etat.reglages.Contains($k)) { $etat.reglages[$k] = Get-Valeur $r[0] $r[1] }
    }
    # La sauvegarde d'abord, plan compris : sans elle, pas de retour possible.
    if (-not $etat.plan) { $etat.plan = [ordered]@{ avant = (Get-PlanActif); cree = $null } }
    Write-Utf8 $fichierNettoyage ($etat | ConvertTo-Json -Depth 6)

    $plan = Set-PlanProduction $etat
    # Chaque refus de Windows est nommé, et le reste s'applique quand même.
    $refus = @()
    $services = 0
    foreach ($n in @($etat.services.Keys)) {
        try { Set-Valeur (Join-Path $cleServices $n) 'Start' 4 'DWord'; $services++ } catch { $refus += "service $n ($($_.Exception.Message))" }
        Stop-Service -Name $n -Force -ErrorAction SilentlyContinue
    }
    $taches = 0
    foreach ($t in @($etat.taches.Keys)) {
        $i = $t.LastIndexOf('\')
        try { Disable-ScheduledTask -TaskPath $t.Substring(0, $i + 1) -TaskName $t.Substring($i + 1) -ErrorAction Stop | Out-Null; $taches++ } catch { $refus += "tâche $($t.Substring($i + 1))" }
    }
    $reglages = 0
    $etat.proteges = @()
    foreach ($r in $reglagesNettoyage) {
        try { Set-Valeur $r[0] $r[1] $r[2] 'DWord'; $reglages++ }
        catch {
            # Windows 11 protège certaines clés par son pilote UCPD, même contre
            # SYSTEM qui a tous les droits dessus (AllowNewsAndInterests sur PN09,
            # le 2026-11-05) : le réglage reste à Windows, et le contrôle le sait.
            if ($_.Exception -is [UnauthorizedAccessException] -and (Get-Service UCPD -ErrorAction SilentlyContinue).Status -eq 'Running') { $etat.proteges += $r[1] }
            else { $refus += "réglage $($r[1]) ($($_.Exception.Message))" }
        }
    }
    # Le plan choisi et les réglages protégés sont gardés : le contrôle les
    # relit, le retour supprime le plan.
    Write-Utf8 $fichierNettoyage ($etat | ConvertTo-Json -Depth 6)
    $retirees = @()
    $sansListe = $null
    if ($Applications) {
        # La liste des applications installées, une seule fois : Windows peut la refuser.
        try {
            $installees = @(Get-AppxPackage -AllUsers -ErrorAction Stop)
            $prevues = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop)
        } catch { $sansListe = $_.Exception.Message; $installees = @(); $prevues = @() }
        foreach ($a in $applicationsNettoyage) {
            foreach ($pkg in @($installees | Where-Object { $_.Name -like $a })) {
                try { Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop; $retirees += $pkg.Name } catch { $refus += "application $($pkg.Name)" }
            }
            foreach ($prov in @($prevues | Where-Object { $_.DisplayName -like $a })) {
                try { Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop | Out-Null; $retirees += $prov.DisplayName } catch { }
            }
        }
        $etat.applications = @(@($etat.applications) + $retirees | Where-Object { $_ } | Sort-Object -Unique)
        Write-Utf8 $fichierNettoyage ($etat | ConvertTo-Json -Depth 6)
    }
    $result.ok = -not $sansListe
    # Allégé, applications pas retirées : le contrôle relit quand même l'allègement.
    if ($sansListe) { $result.partiel = $true }
    $result.applications = @($retirees | Sort-Object -Unique)
    $txt = "profil appliqué : $plan, $services service(s) et $taches tâche(s) coupés, $reglages réglages posés"
    if ($Applications) { $txt += ", $(@($result.applications).Count) application(s) retirée(s)" }
    if ($sansListe) { $txt += ". Applications pas retirées : Windows refuse d'en donner la liste ($sansListe)" }
    if ($etat.proteges.Count) { $txt += ". Laissé à Windows, qui le protège (pilote UCPD actif) : $($etat.proteges -join ', ')" }
    if ($refus.Count) { $txt += ". Refusé par Windows : $($refus -join ', ')" }
    $result.detail = $txt + '. Le démarrage rapide est coupé : effet complet au prochain redémarrage'
}

function Disable-Nettoyage {
    if (-not (Test-Path $fichierNettoyage)) {
        $result.ok = $true
        $result.detail = 'aucun profil de nettoyage sur ce poste'
        return
    }
    $etat = Get-Content -Raw -Path $fichierNettoyage | ConvertFrom-Json
    $echecs = @()
    if ($etat.plan -and $etat.plan.avant) {
        & powercfg.exe /setactive $etat.plan.avant | Out-Null
        if ($LASTEXITCODE -ne 0) { $echecs += 'plan d''alimentation' }
        else { @(Get-PlansProduction) + $etat.plan.cree | Where-Object { $_ -and $_ -ne $etat.plan.avant } | Sort-Object -Unique | ForEach-Object { & powercfg.exe /delete $_ | Out-Null } }
    }
    $services = 0
    foreach ($q in @($etat.services.PSObject.Properties)) {
        $cle = Join-Path $cleServices $q.Name
        if (-not (Test-Path $cle)) { continue }
        try {
            Set-Valeur $cle 'Start' $q.Value.start 'DWord'
            Set-Valeur $cle 'DelayedAutostart' $q.Value.delai 'DWord'
            if ($q.Value.start -eq 2) { Start-Service -Name $q.Name -ErrorAction SilentlyContinue }
            $services++
        } catch { $echecs += "service $($q.Name)" }
    }
    $taches = 0
    foreach ($q in @($etat.taches.PSObject.Properties)) {
        if (-not $q.Value) { continue }
        $i = $q.Name.LastIndexOf('\')
        try {
            Enable-ScheduledTask -TaskPath $q.Name.Substring(0, $i + 1) -TaskName $q.Name.Substring($i + 1) -ErrorAction Stop | Out-Null
            $taches++
        } catch { $echecs += "tâche $($q.Name.Substring($i + 1))" }
    }
    foreach ($q in @($etat.reglages.PSObject.Properties)) {
        $cle, $nom = $q.Name -split '\|', 2
        try { Set-Valeur $cle $nom $q.Value 'DWord' } catch { $echecs += "réglage $nom" }
    }
    $apps = @($etat.applications | Where-Object { $_ })
    if ($echecs.Count) {
        # L'état reste : une seconde annulation reprend ce qui a échoué.
        $result.detail = "annulation partielle, à reprendre : $($echecs -join ', ')"
        return
    }
    Write-Utf8 (Join-Path $base 'nettoyage-rendu.json') ($etat | ConvertTo-Json -Depth 6)
    Remove-Item -Path $fichierNettoyage -Force
    $result.ok = $true
    $result.applications = $apps
    $txt = "profil annulé (appliqué le $(([datetime]$etat.depuis).ToString('dd/MM HH:mm'))) : plan d'alimentation, $services service(s), $taches tâche(s) et réglages rendus"
    if ($apps.Count) { $txt += ". Applications retirées, à réinstaller depuis le Microsoft Store si besoin : $($apps -join ', ')" }
    $result.detail = $txt
}

# --- Fond d'état (agent/fond-pose.ps1) ------------------------------------------

# Après chaque commande : la dernière commande et la sonde pour le fond, relu
# tout de suite dans les sessions ouvertes. Sept jours après un retrait, la
# tâche part.
function Update-Fond {
    $d = Join-Path $base 'fond'
    $f = Join-Path $d 'etat.json'
    if ($result.op -eq 'etat' -or -not (Test-Path $f)) { return }
    try {
        $e = Get-Content -Raw -Encoding UTF8 $f | ConvertFrom-Json
        if ($e.retire -and $e.retireLe -and ((Get-Date) - [datetime]$e.retireLe).TotalDays -gt 7) {
            Unregister-ScheduledTask -TaskName 'PointeNoire-Fond' -Confirm:$false -ErrorAction SilentlyContinue
            Remove-Item $d -Recurse -Force
            return
        }
        $t = "$($result.op) : $($result.detail)"
        if ($t.Length -gt 90) { $t = $t.Substring(0, 89) + '…' }
        $le = (Get-Date).ToString('o')
        $e | Add-Member -NotePropertyName derniere -NotePropertyValue ([ordered]@{ texte = $t; le = $le }) -Force
        # Les cinq dernières actions, réussies ou non, pour l'écran du poste.
        # La première phrase ; pour un échec, celle qui dit pourquoi quand il y en a une.
        $phrases = @([string]$result.detail -split '\. ' | Where-Object { $_ })
        $d = [string]$phrases[0]
        if (-not $result.ok) { $pourquoi = @($phrases | Where-Object { $_ -match 'pas retirées|[Rr]efusé|échec|erreur' }); if ($pourquoi.Count) { $d = [string]$pourquoi[0] } }
        $d = $d -replace '^mode événement ', ''
        $nom = @{ evenement = 'Mode événement'; nettoyage = 'Allègement'; supervision = 'Suivi'; alimentation = 'Alimentation'; reseau = 'Réseau'; script = 'Script'; fichier = 'Fichier' }[[string]$result.op]
        if (-not $nom) { $nom = [string]$result.op }
        $h = "${nom} : $d"
        if ($h.Length -gt 70) { $h = $h.Substring(0, 69) + '…' }
        $e | Add-Member -NotePropertyName historique -NotePropertyValue (@(@([ordered]@{ op = [string]$result.op; texte = $h; ok = [bool]$result.ok; le = $le }) + @($e.historique | Where-Object { $_ }) | Select-Object -First 5)) -Force
        $e | Add-Member -NotePropertyName sonde -NotePropertyValue (Test-Path (Join-Path $dossierSonde 'config.json')) -Force
        Write-Utf8 $f ($e | ConvertTo-Json -Depth 4)
        Start-ScheduledTask -TaskName 'PointeNoire-Fond' -ErrorAction SilentlyContinue
    } catch { }
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
                Enable-Evenement $jours $p.parties
            } else { Disable-Evenement $p.parties }
        }
        'supervision' { if ($p.actif) { Install-Sonde $p } else { Remove-Sonde } }
        'script' { Invoke-Script $p }
        'fichier' { Save-Fichier $p }
        'nettoyage' {
            # Le mode événement garde les réglages de veille du plan actif : on
            # ne change pas de plan sous lui, ni dans un sens ni dans l'autre.
            if (Test-Path $fichierEvenement) { $result.detail = 'refusé : le poste est en mode événement'; break }
            if ($p.actif) { Enable-Nettoyage ([bool]$p.applications) } else { Disable-Nettoyage }
        }
        default { $result.detail = "opération inconnue : $($p.op)" }
    }
} catch {
    $result.ok = $false
    $i = $_.InvocationInfo
    $result.detail = "$($_.Exception.Message) (pilote.ps1, ligne $($i.ScriptLineNumber)$(if ($i.MyCommand) { ", $($i.MyCommand.Name)" }))"
}
Update-Fond
Send-Result

<#
  La veille réseau d'un poste (monitoring réseau, lot 1). Posée par
  reseau-pose.ps1 dans C:\ProgramData\PointeNoire\reseau, lancée au démarrage
  par la tâche PointeNoire-Reseau (compte SYSTEM), relancée toutes les 5
  minutes si elle s'est arrêtée. Une seule à la fois (mutex). Compatible
  Windows PowerShell 5.1. Rien n'est changé sur le poste.

  Chaque seconde : un ping vers la passerelle, vers la cible du site (le PC
  régie par défaut, reseau.json) et vers 1.1.1.1.
  Toutes les 2 s : l'état des cartes physiques (lien, vitesse, adresse,
  passerelle, DNS, serveur DHCP) et leurs compteurs (octets, erreurs, paquets
  jetés, multicast et broadcast reçus), lus par .NET, sans WMI.
  Toutes les 10 s : le Wi-Fi (netsh), l'adresse MAC de la passerelle, les
  retransmissions TCP.
  Toutes les 30 s : le temps de résolution DNS du serveur AVDiagram, demandé
  au serveur DNS de la carte (pas au cache), la connexion TCP 443, le profil
  du pare-feu, les conflits d'adresse (Tcpip 4199) et les déconnexions Wi-Fi
  (WLAN-AutoConfig 8003) du journal.

  Sur le poste (dossier journal) : une ligne par seconde dans un fichier par
  heure, gardés 24 h ; les événements et les résumés par minute, 7 jours.
  Vers AVDiagram, chaque minute : le résumé de la minute (min, médiane, 95e
  centile, max, gigue, perte, plus longue coupure par cible ; débit, erreurs
  par carte ; Wi-Fi ; DNS ; TCP) et les événements (lien, vitesse, adresse,
  passerelle, DNS, DHCP, borne Wi-Fi, coupure, MAC de la passerelle, conflit).
  POST <url de la sonde, /mesures remplacé par /reseau>, avec le jeton de la
  sonde (C:\ProgramData\PointeNoire\supervision\config.json), relu à chaque
  envoi. Sans réseau, 60 minutes et 300 événements attendent dans
  en-attente.json. Sonde retirée : la veille s'arrête.
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$fichierSonde = Join-Path $env:ProgramData 'PointeNoire\supervision\config.json'
$fichierReglages = Join-Path $dir 'reseau.json'
$dossierJournal = Join-Path $dir 'journal'
$fichierAttente = Join-Path $dir 'en-attente.json'
$fichierEvenements = Join-Path $dossierJournal 'evenements.jsonl'
$fichierMinutes = Join-Path $dossierJournal 'minutes.jsonl'
$utf8 = New-Object System.Text.UTF8Encoding $false
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$mutex = New-Object Threading.Mutex($false, 'Global\PointeNoire-Reseau')
try { if (-not $mutex.WaitOne(0)) { exit 0 } } catch [Threading.AbandonedMutexException] { }
if (-not (Test-Path $fichierSonde)) { exit 0 }
if (-not (Test-Path $dossierJournal)) { New-Item -ItemType Directory -Path $dossierJournal -Force | Out-Null }

function Get-Utc { [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') }

function Add-Ligne([string]$Chemin, [string]$Texte) {
    try { [IO.File]::AppendAllText($Chemin, $Texte + "`n", $utf8) } catch { }
}

# --- Réglages -----------------------------------------------------------------------

$reglages = [ordered]@{ cible = $null; nom_cible = $null }
if (Test-Path $fichierReglages) {
    try {
        $lu = Get-Content -Raw -Path $fichierReglages | ConvertFrom-Json
        if ($lu.cible -and [string]$lu.cible -match '^[A-Za-z0-9.:-]{1,253}$') { $reglages.cible = [string]$lu.cible; $reglages.nom_cible = [string]$lu.nom_cible }
    } catch { }
}

function Get-Sonde {
    try {
        $c = Get-Content -Raw -Path $fichierSonde | ConvertFrom-Json
        if ([string]$c.url -notmatch '^https://' -or [string]$c.jeton -notmatch '^pns_') { return $null }
        $url = ([string]$c.url) -replace '/mesures/?$', '/reseau'
        return @{ url = $url; jeton = [string]$c.jeton; hote = ([Uri]$c.url).Host }
    } catch { return $null }
}

# --- Événements -----------------------------------------------------------------------

$evenements = New-Object System.Collections.ArrayList

function Add-Evenement([string]$Type, [string]$Texte, $Carte = $null, $Avant = $null, $Apres = $null) {
    $e = [ordered]@{ at = (Get-Utc); type = $Type; text = $Texte }
    if ($Carte) { $e.nic = [string]$Carte }
    if ($null -ne $Avant) { $e.before = [string]$Avant }
    if ($null -ne $Apres) { $e.after = [string]$Apres }
    [void]$evenements.Add($e)
    Add-Ligne $fichierEvenements (ConvertTo-Json -InputObject $e -Compress)
}

# --- Pings ------------------------------------------------------------------------------

$cles = @('passerelle', 'site', 'internet')
$pings = @{}
$series = @{}
$suites = @{}
$coupuresDebut = @{}
foreach ($k in $cles) { $pings[$k] = New-Object Net.NetworkInformation.Ping; $series[$k] = New-Object System.Collections.Generic.List[int]; $suites[$k] = 0 }
$adresses = @{ passerelle = $null; site = $reglages.cible; internet = '1.1.1.1' }
$noms = @{ passerelle = 'la passerelle'; site = $(if ($reglages.nom_cible) { $reglages.nom_cible } else { 'la cible du site' }); internet = 'internet (1.1.1.1)' }

function Measure-Pings {
    $taches = @{}
    foreach ($k in $cles) {
        if ($adresses[$k]) {
            try { $taches[$k] = $pings[$k].SendPingAsync([string]$adresses[$k], 900) } catch { $taches[$k] = $null }
        }
    }
    $liste = @($taches.Values | Where-Object { $_ })
    if ($liste.Count) { try { [void][Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]$liste, 1000) } catch { } }
    $r = @{}
    foreach ($k in $cles) {
        if (-not $adresses[$k]) { $r[$k] = $null; continue }
        $t = $taches[$k]
        $ms = -1
        if ($t -and $t.Status -eq 'RanToCompletion' -and $t.Result.Status -eq 'Success') { $ms = [int]$t.Result.RoundtripTime }
        $r[$k] = $ms
        $series[$k].Add($ms)
        # Une coupure : 3 pings perdus de suite au moins. Elle devient un
        # événement à son retour, avec sa durée.
        if ($ms -lt 0) {
            if ($suites[$k] -eq 0) { $coupuresDebut[$k] = [DateTime]::UtcNow }
            $suites[$k]++
        } else {
            if ($suites[$k] -ge 3) {
                $duree = [int]([DateTime]::UtcNow - $coupuresDebut[$k]).TotalSeconds
                Add-Evenement 'coupure' "$($noms[$k]) injoignable pendant $duree s" $null $adresses[$k] $duree
            }
            $suites[$k] = 0
        }
    }
    $r
}

function Get-Stats($Valeurs) {
    $n = $Valeurs.Count
    if (-not $n) { return $null }
    $ok = @($Valeurs | Where-Object { $_ -ge 0 } | Sort-Object)
    $s = [ordered]@{ n = $n; loss = [Math]::Round(100 * ($n - $ok.Count) / $n, 1) }
    if ($ok.Count) {
        $s.min = $ok[0]
        $s.med = $ok[[int][Math]::Floor(($ok.Count - 1) / 2)]
        $s.p95 = $ok[[Math]::Max(0, [int][Math]::Ceiling(0.95 * $ok.Count) - 1)]
        $s.max = $ok[$ok.Count - 1]
    }
    # La gigue : l'écart moyen entre deux réponses qui se suivent.
    $somme = 0; $paires = 0; $suite = 0; $pire = 0; $avant = -1
    foreach ($v in $Valeurs) {
        if ($v -ge 0) {
            if ($avant -ge 0) { $somme += [Math]::Abs($v - $avant); $paires++ }
            $suite = 0
        } else {
            $suite++
            if ($suite -gt $pire) { $pire = $suite }
        }
        $avant = $v
    }
    $s.jitter = $(if ($paires) { [Math]::Round($somme / $paires, 1) } else { $null })
    $s.gap = $pire
    $s
}

# --- Cartes -----------------------------------------------------------------------------

$physiques = @{}
$physiquesLues = [DateTime]::MinValue
$cartesAvant = @{}
$cumul = @{}

function Update-Physiques {
    $script:physiques = @{}
    foreach ($a in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)) {
        $script:physiques[([string]$a.InterfaceGuid).Trim('{}').ToLower()] = $a.Name
    }
    $script:physiquesLues = [DateTime]::UtcNow
}

function Get-Cartes {
    $vues = @{}
    foreach ($ni in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        $id = ([string]$ni.Id).Trim('{}').ToLower()
        if (-not $physiques.ContainsKey($id)) { continue }
        $ipp = $ni.GetIPProperties()
        $v4 = @($ipp.UnicastAddresses | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' -and -not $_.Address.ToString().StartsWith('169.254.') }) | Select-Object -First 1
        $dhcp = $null
        try { $dhcp = $ipp.GetIPv4Properties().IsDhcpEnabled } catch { }
        $st = $ni.GetIPv4Statistics()
        $vues[$physiques[$id]] = [ordered]@{
            up      = ($ni.OperationalStatus -eq 'Up')
            wired   = ($ni.NetworkInterfaceType -ne 'Wireless80211')
            speed   = [long]$ni.Speed
            ip      = $(if ($v4) { "$($v4.Address)/$($v4.PrefixLength)" } else { '' })
            gw      = (@($ipp.GatewayAddresses | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.Address.ToString() }) -join ' ')
            dns     = (@($ipp.DnsAddresses | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.ToString() }) -join ' ')
            dhcpsrv = (@($ipp.DhcpServerAddresses | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.ToString() }) -join ' ')
            dhcp    = $dhcp
            rx      = [long]$st.BytesReceived
            tx      = [long]$st.BytesSent
            err     = [long]$st.IncomingPacketsWithErrors + [long]$st.OutgoingPacketsWithErrors
            drop    = [long]$st.IncomingPacketsDiscarded + [long]$st.OutgoingPacketsDiscarded
            nonuni  = [long]$st.NonUnicastPacketsReceived
        }
    }
    $vues
}

function Format-Vitesse([long]$Bps) {
    if ($Bps -ge 1e9) { return "$([Math]::Round($Bps / 1e9, 1)) Gb/s" }
    "$([Math]::Round($Bps / 1e6)) Mb/s"
}

$instant = @{ rx = 0L; tx = 0L }

function Compare-Cartes($Vues, [double]$Secondes) {
    $instant.rx = 0L; $instant.tx = 0L
    foreach ($nom in $Vues.Keys) {
        $c = $Vues[$nom]
        $a = $cartesAvant[$nom]
        if ($a) {
            if ($a.up -ne $c.up) {
                $t = $(if ($c.up) { 'lien rétabli' } else { 'lien coupé' })
                Add-Evenement 'lien' "$nom : $t" $nom $(if ($a.up) { 'up' } else { 'down' }) $(if ($c.up) { 'up' } else { 'down' })
            } elseif ($c.up -and $c.wired -and $a.speed -ne $c.speed -and $a.speed -gt 0 -and $c.speed -gt 0) {
                # En Wi-Fi, la vitesse suit le signal à chaque instant : pas un événement.
                Add-Evenement 'vitesse' "$nom : $(Format-Vitesse $a.speed) devenu $(Format-Vitesse $c.speed)" $nom $a.speed $c.speed
            }
            if ($c.up -and $a.up) {
                if ($a.ip -ne $c.ip) { Add-Evenement 'adresse' "$nom : adresse $(if ($a.ip) { $a.ip } else { 'aucune' }) devenue $(if ($c.ip) { $c.ip } else { 'aucune' })" $nom $a.ip $c.ip }
                if ($a.gw -ne $c.gw) { Add-Evenement 'passerelle' "$nom : passerelle $(if ($a.gw) { $a.gw } else { 'aucune' }) devenue $(if ($c.gw) { $c.gw } else { 'aucune' })" $nom $a.gw $c.gw }
                if ($a.dns -ne $c.dns) { Add-Evenement 'dns' "$nom : DNS $(if ($a.dns) { $a.dns } else { 'aucun' }) devenu $(if ($c.dns) { $c.dns } else { 'aucun' })" $nom $a.dns $c.dns }
                if ($a.dhcpsrv -and $c.dhcpsrv -and $a.dhcpsrv -ne $c.dhcpsrv) { Add-Evenement 'dhcp' "$nom : serveur DHCP $($a.dhcpsrv) remplacé par $($c.dhcpsrv)" $nom $a.dhcpsrv $c.dhcpsrv }
            }
            if ($Secondes -gt 0 -and $c.up) {
                $k = $cumul[$nom]
                if (-not $k) { $k = [ordered]@{ wired = $c.wired; speed = $c.speed; rx = 0.0; tx = 0.0; rxmax = 0.0; txmax = 0.0; sec = 0.0; err = 0; drop = 0; nonuni = 0.0 }; $cumul[$nom] = $k }
                $drx = [Math]::Max(0, $c.rx - $a.rx); $dtx = [Math]::Max(0, $c.tx - $a.tx)
                $k.rx += $drx; $k.tx += $dtx; $k.sec += $Secondes
                $instant.rx += [long]($drx * 8 / $Secondes); $instant.tx += [long]($dtx * 8 / $Secondes)
                $k.rxmax = [Math]::Max($k.rxmax, $drx * 8 / $Secondes)
                $k.txmax = [Math]::Max($k.txmax, $dtx * 8 / $Secondes)
                $k.err += [Math]::Max(0, $c.err - $a.err)
                $k.drop += [Math]::Max(0, $c.drop - $a.drop)
                $k.nonuni = [Math]::Max($k.nonuni, [Math]::Max(0, $c.nonuni - $a.nonuni) / $Secondes)
                $k.speed = $c.speed; $k.wired = $c.wired
            }
        } elseif ($cartesAvant.Count) {
            Add-Evenement 'carte' "$nom : carte apparue" $nom
        }
    }
    foreach ($nom in @($cartesAvant.Keys)) {
        if (-not $Vues.ContainsKey($nom)) { Add-Evenement 'carte' "$nom : carte disparue" $nom }
    }
    $script:cartesAvant = $Vues
}

# --- Wi-Fi, passerelle, TCP -----------------------------------------------------------

$wifiAvant = $null
$wifiSignaux = New-Object System.Collections.Generic.List[int]
$wifiDernier = $null

function Get-Wifi {
    $ErrorActionPreference = 'Continue'
    $sortie = & netsh.exe wlan show interfaces 2>$null
    $ErrorActionPreference = 'Stop'
    $w = [ordered]@{}
    foreach ($brut in @($sortie)) {
        # netsh français met une espace insécable avant « % » ; lue dans la
        # mauvaise page de code, elle devient « ┬á ».
        $ligne = ([string]$brut) -replace '\u252C\u00E1|\u00A0', ' '
        if ($ligne -match '^\s*SSID\s*:\s*(.+)$') { $w.ssid = $Matches[1].Trim() }
        elseif ($ligne -match '^\s*(AP\s+)?BSSID(\s+AP)?\s*:\s*([0-9a-fA-F:]{17})') { $w.bssid = $Matches[3].ToLower() }
        elseif ($ligne -match '^\s*Signal\s*:\s*(\d+)\s*%') { $w.signal = [int]$Matches[1] }
        elseif ($ligne -match '^\s*(Canal|Channel)\s*:\s*(\d+)') { $w.channel = [int]$Matches[2] }
        elseif ($ligne -match '^\s*(Bande|Band)\s*:\s*(.+)$') { $w.band = $Matches[2].Trim() }
        elseif ($ligne -match '^\s*(Vitesse de r.ception|Receive rate)[^:]*:\s*([\d.,]+)') { $w.rate = [double]($Matches[2] -replace ',', '.') }
    }
    if ($w.Contains('ssid')) { return $w }
    $null
}

function Watch-Wifi {
    if (-not @($cartesAvant.Values | Where-Object { $_.up -and -not $_.wired }).Count) { $script:wifiAvant = $null; return }
    $w = Get-Wifi
    if (-not $w) { return }
    if ($null -ne $w.signal) { $wifiSignaux.Add([int]$w.signal) }
    if ($wifiAvant) {
        if ($wifiAvant.ssid -ne $w.ssid) { Add-Evenement 'wifi' "Wi-Fi : réseau $($wifiAvant.ssid) remplacé par $($w.ssid)" $null $wifiAvant.ssid $w.ssid }
        elseif ($wifiAvant.bssid -and $w.bssid -and $wifiAvant.bssid -ne $w.bssid) { Add-Evenement 'borne' "Wi-Fi : changement de borne ($($wifiAvant.bssid) vers $($w.bssid)), signal $($w.signal) %" $null $wifiAvant.bssid $w.bssid }
    }
    $script:wifiAvant = $w
    $script:wifiDernier = $w
}

$macPasserelle = @{}
function Watch-Passerelle {
    $gw = $null
    try {
        $r = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object { $_.RouteMetric + $_.InterfaceMetric }) | Select-Object -First 1
        if ($r -and $r.NextHop -ne '0.0.0.0') { $gw = [string]$r.NextHop }
    } catch { }
    $adresses['passerelle'] = $gw
    if (-not $gw) { return }
    try {
        $n = Get-NetNeighbor -IPAddress $gw -ErrorAction SilentlyContinue | Where-Object { $_.LinkLayerAddress -and $_.LinkLayerAddress -ne '00-00-00-00-00-00' } | Select-Object -First 1
        if ($n) {
            $mac = ([string]$n.LinkLayerAddress).ToLower()
            if ($macPasserelle[$gw] -and $macPasserelle[$gw] -ne $mac) { Add-Evenement 'mac_passerelle' "La passerelle $gw répond avec une autre adresse MAC ($($macPasserelle[$gw]) puis $mac) : autre routeur ou deux appareils sur la même adresse" $null $macPasserelle[$gw] $mac }
            $macPasserelle[$gw] = $mac
        }
    } catch { }
}

$tcpDebut = $null
function Get-Tcp {
    try {
        $s = [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetTcpIPv4Statistics()
        return @{ sent = [long]$s.SegmentsSent; resent = [long]$s.SegmentsResent }
    } catch { return $null }
}

# --- DNS, TCP vers le serveur, journal Windows ----------------------------------------

$dnsMesure = $null
$tcpMesure = $null
$profilAvant = @{}
$journalDepuis = [DateTime]::Now

function Watch-Services($Sonde) {
    if (-not $Sonde) { return }
    $serveur = $null
    $principale = @($cartesAvant.Keys | Where-Object { $cartesAvant[$_].up -and $cartesAvant[$_].gw -and $cartesAvant[$_].dns }) | Select-Object -First 1
    if ($principale) { $serveur = @($cartesAvant[$principale].dns -split ' ')[0] }
    $t = [Diagnostics.Stopwatch]::StartNew()
    try {
        # Demandé au serveur DNS de la carte : le cache de Windows répondrait en 0 ms.
        if ($serveur) { $r = @(Resolve-DnsName -Name $Sonde.hote -Type A -DnsOnly -NoHostsFile -QuickTimeout -Server $serveur -ErrorAction Stop | Where-Object { $_.IPAddress }) }
        else { $r = @(Resolve-DnsName -Name $Sonde.hote -Type A -DnsOnly -NoHostsFile -QuickTimeout -ErrorAction Stop | Where-Object { $_.IPAddress }) }
        $script:dnsMesure = [ordered]@{ name = $Sonde.hote; server = $serveur; ok = [bool]$r.Count; ms = [int]$t.ElapsedMilliseconds }
    } catch {
        $script:dnsMesure = [ordered]@{ name = $Sonde.hote; server = $serveur; ok = $false; ms = $null }
        Add-Evenement 'dns_echec' "Résolution de $($Sonde.hote) en échec$(if ($serveur) { " (serveur $serveur)" })" $null $serveur
    }
    $c = New-Object Net.Sockets.TcpClient
    $t = [Diagnostics.Stopwatch]::StartNew()
    try {
        $a = $c.BeginConnect($Sonde.hote, 443, $null, $null)
        if ($a.AsyncWaitHandle.WaitOne(3000)) { $c.EndConnect($a); $script:tcpMesure = [ordered]@{ host = $Sonde.hote; port = 443; ok = $true; ms = [int]$t.ElapsedMilliseconds } }
        else { $script:tcpMesure = [ordered]@{ host = $Sonde.hote; port = 443; ok = $false; ms = $null } }
    } catch { $script:tcpMesure = [ordered]@{ host = $Sonde.hote; port = 443; ok = $false; ms = $null } } finally { $c.Close() }

    try {
        foreach ($p in @(Get-NetConnectionProfile -ErrorAction SilentlyContinue)) {
            $nom = [string]$p.InterfaceAlias
            $cat = [string]$p.NetworkCategory
            if ($profilAvant[$nom] -and $profilAvant[$nom] -ne $cat) { Add-Evenement 'profil' "$nom : profil du pare-feu $($profilAvant[$nom]) devenu $cat" $nom $profilAvant[$nom] $cat }
            $profilAvant[$nom] = $cat
        }
    } catch { }

    $depuis = $script:journalDepuis
    $script:journalDepuis = [DateTime]::Now
    $filtres = @(
        @{ f = @{ LogName = 'System'; ProviderName = 'Tcpip'; Id = 4199; StartTime = $depuis }; type = 'conflit' },
        @{ f = @{ LogName = 'Microsoft-Windows-WLAN-AutoConfig/Operational'; Id = 8003; StartTime = $depuis }; type = 'wifi_deconnexion' }
    )
    foreach ($q in $filtres) {
        try {
            foreach ($ev in @(Get-WinEvent -FilterHashtable $q.f -MaxEvents 10 -ErrorAction Stop)) {
                $texte = ([string]$ev.Message -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 3) -join ' '
                if ($texte.Length -gt 240) { $texte = $texte.Substring(0, 240) }
                Add-Evenement $q.type $texte
            }
        } catch { }
    }
}

# --- Journal local ----------------------------------------------------------------------

function Write-Seconde($Pings, [long]$Rx, [long]$Tx) {
    $h = [DateTime]::UtcNow
    $f = Join-Path $dossierJournal ('secondes-' + $h.ToString('yyyyMMdd-HH') + '.csv')
    $neuf = -not (Test-Path $f)
    if ($neuf) { Add-Ligne $f 'at,passerelle_ms,site_ms,internet_ms,rx_bps,tx_bps' }
    $v = foreach ($k in $cles) { if ($null -eq $Pings[$k]) { '' } else { $Pings[$k] } }
    Add-Ligne $f ("$($h.ToString('yyyy-MM-ddTHH:mm:ssZ')),$($v -join ','),$Rx,$Tx")
    if ($neuf) { Clear-Journal }
}

function Clear-Journal {
    # Les secondes 24 h ; les événements et les minutes 7 jours.
    $limite = [DateTime]::UtcNow.AddHours(-25)
    Get-ChildItem -Path $dossierJournal -Filter 'secondes-*.csv' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTimeUtc -lt $limite } | Remove-Item -Force -ErrorAction SilentlyContinue
    $borne = [DateTime]::UtcNow.AddDays(-7).ToString('yyyy-MM-ddTHH:mm:ssZ')
    foreach ($f in $fichierEvenements, $fichierMinutes) {
        if (-not (Test-Path $f)) { continue }
        try {
            $garde = @([IO.File]::ReadAllLines($f, $utf8) | Where-Object { $_.Length -gt 9 -and $_.Substring(7, [Math]::Min(20, $_.Length - 7)) -ge $borne })
            [IO.File]::WriteAllLines($f, [string[]]$garde, $utf8)
        } catch { }
    }
}

# --- La minute et l'envoi ---------------------------------------------------------------

$refuse = $null

function Send-Minute($Sonde) {
    $tcp = Get-Tcp
    $retrans = $null
    if ($tcp -and $script:tcpDebut) {
        $envoyes = $tcp.sent - $script:tcpDebut.sent
        if ($envoyes -gt 0) { $retrans = [Math]::Round(100 * ($tcp.resent - $script:tcpDebut.resent) / $envoyes, 2) }
    }
    $script:tcpDebut = $tcp
    $cibles = [ordered]@{}
    foreach ($k in $cles) {
        $s = Get-Stats $series[$k]
        if ($s) { $s.ip = $adresses[$k]; $cibles[$k] = $s }
        $series[$k].Clear()
    }
    $cartes = @(foreach ($nom in $cumul.Keys) {
        $k = $cumul[$nom]
        $sec = [Math]::Max(1.0, $k.sec)
        [ordered]@{ name = $nom; wired = $k.wired; speed = $k.speed; rx = [Math]::Round($k.rx * 8 / $sec); tx = [Math]::Round($k.tx * 8 / $sec); rx_max = [Math]::Round($k.rxmax); tx_max = [Math]::Round($k.txmax); errors = $k.err; discards = $k.drop; nonunicast_pps = [Math]::Round($k.nonuni) }
    })
    $cumul.Clear()
    $minute = [ordered]@{ at = (Get-Utc); targets = $cibles; nics = $cartes; retrans = $retrans; dns = $dnsMesure; tcp = $tcpMesure }
    if ($wifiDernier) {
        $w = [ordered]@{ ssid = $wifiDernier.ssid; bssid = $wifiDernier.bssid; channel = $wifiDernier.channel; band = $wifiDernier.band; rate = $wifiDernier.rate }
        if ($wifiSignaux.Count) { $w.signal_min = ($wifiSignaux | Measure-Object -Minimum).Minimum; $w.signal = [Math]::Round(($wifiSignaux | Measure-Object -Average).Average) }
        $minute.wifi = $w
    }
    $wifiSignaux.Clear()
    $script:wifiDernier = $null
    Add-Ligne $fichierMinutes (ConvertTo-Json -InputObject $minute -Compress -Depth 5)

    $attente = [ordered]@{ minutes = @(); events = @() }
    if (Test-Path $fichierAttente) {
        try {
            $lu = Get-Content -Raw -Path $fichierAttente | ConvertFrom-Json
            $attente.minutes = @($lu.minutes | Where-Object { $_ })
            $attente.events = @($lu.events | Where-Object { $_ })
        } catch { }
    }
    $attente.minutes = @(@($attente.minutes) + @($minute) | Select-Object -Last 60)
    $attente.events = @(@($attente.events) + @($evenements) | Select-Object -Last 300)
    $evenements.Clear()
    if (-not $Sonde -or ($refuse -and $refuse -eq $Sonde.jeton)) {
        [IO.File]::WriteAllText($fichierAttente, (ConvertTo-Json -InputObject $attente -Compress -Depth 6), $utf8)
        return
    }
    try {
        $corps = ConvertTo-Json -InputObject $attente -Compress -Depth 6
        Invoke-RestMethod -Method Post -Uri $Sonde.url -Headers @{ Authorization = "Bearer $($Sonde.jeton)" } -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($corps)) -TimeoutSec 15 -UseBasicParsing | Out-Null
        Remove-Item -Path $fichierAttente -ErrorAction SilentlyContinue
        $script:refuse = $null
    } catch {
        $code = $null
        try { $code = [int]$_.Exception.Response.StatusCode } catch { }
        if ($code -eq 401) {
            # Sonde retirée ou remplacée : rien ne part plus avec ce jeton.
            $script:refuse = $Sonde.jeton
            Remove-Item -Path $fichierAttente -ErrorAction SilentlyContinue
        } elseif ($code -ge 400 -and $code -lt 500) {
            # Des mesures refusées ne repartent pas en boucle.
            Remove-Item -Path $fichierAttente -ErrorAction SilentlyContinue
        } else {
            [IO.File]::WriteAllText($fichierAttente, (ConvertTo-Json -InputObject $attente -Compress -Depth 6), $utf8)
        }
    }
}

# --- Boucle ---------------------------------------------------------------------------------

Update-Physiques
Watch-Passerelle
$cartesAvant = Get-Cartes
$lu = [DateTime]::UtcNow
$tcpDebut = Get-Tcp
Add-Evenement 'veille' 'veille réseau démarrée'
$debut = [DateTime]::UtcNow
$minuteSuivante = $debut.AddSeconds(60 - $debut.Second)
$tic = 0
while ($true) {
    $tic++
    $reponses = Measure-Pings
    if ($tic % 2 -eq 0) {
        if (([DateTime]::UtcNow - $physiquesLues).TotalSeconds -ge 60) { Update-Physiques }
        $maintenant = [DateTime]::UtcNow
        $vues = Get-Cartes
        Compare-Cartes $vues ($maintenant - $lu).TotalSeconds
        $lu = $maintenant
    }
    if ($tic % 10 -eq 0) { Watch-Wifi; Watch-Passerelle }
    if ($tic % 30 -eq 5) { Watch-Services (Get-Sonde) }
    Write-Seconde $reponses $instant.rx $instant.tx
    if ([DateTime]::UtcNow -ge $minuteSuivante) {
        if (-not (Test-Path $fichierSonde)) { break }
        Send-Minute (Get-Sonde)
        $minuteSuivante = $minuteSuivante.AddSeconds(60)
        if ([DateTime]::UtcNow -ge $minuteSuivante) { $minuteSuivante = [DateTime]::UtcNow.AddSeconds(60 - [DateTime]::UtcNow.Second) }
    }
    $reste = 1000 - ([DateTime]::UtcNow - $debut).TotalMilliseconds % 1000
    Start-Sleep -Milliseconds ([int][Math]::Max(50, $reste))
}

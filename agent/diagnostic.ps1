<#
  Le diagnostic réseau d'un poste (0080), lancé par pc-management à travers
  MeshCentral, comme pilote.ps1 (même enveloppe PNPL1, mêmes paramètres
  PNPL_PARAMS en base64). Compatible Windows PowerShell 5.1. Script à part :
  pilote.ps1 doit rester sous la longueur de commande de l'agent.

  Rien n'est changé sur le poste. Paramètres : debit (mesure du débit
  internet, environ 30 s), scan (ping du réseau local, préfixe /22 au plus
  large), cibles ([{ hote, port }], ports TCP à tester en plus).
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$result = [ordered]@{ op = 'diagnostic'; ok = $false; detail = '' }

function Send-Result {
    $json = $result | ConvertTo-Json -Compress -Depth 6
    'PNPL1:' + $env:PNPL_NONCE + ':' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
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

# --- Diagnostic réseau ----------------------------------------------------------
# Avant, pendant et après un live : les cartes, le Wi-Fi, le DNS, les ports
# joignables, le débit internet, les ports à l'écoute et les voisins du réseau
# local. Rien n'est changé sur le poste. Le résultat reste compact (moins de
# 32 Kio) : il repasse par MeshCentral.

function Test-Port([string]$Hote, [int]$Port, [int]$Delai = 2000) {
    $c = New-Object System.Net.Sockets.TcpClient
    $t = [Diagnostics.Stopwatch]::StartNew()
    try {
        $a = $c.BeginConnect($Hote, $Port, $null, $null)
        if (-not $a.AsyncWaitHandle.WaitOne($Delai)) { return [ordered]@{ hote = $Hote; port = $Port; ok = $false; ms = $null; detail = 'délai dépassé' } }
        $c.EndConnect($a)
        return [ordered]@{ hote = $Hote; port = $Port; ok = $true; ms = [int]$t.ElapsedMilliseconds; detail = $null }
    } catch {
        $m = $_.Exception.InnerException
        if (-not $m) { $m = $_.Exception }
        return [ordered]@{ hote = $Hote; port = $Port; ok = $false; ms = $null; detail = ([string]$m.Message).Substring(0, [Math]::Min(120, ([string]$m.Message).Length)) }
    } finally { $c.Close() }
}

function Get-Wifi {
    $ErrorActionPreference = 'Continue'
    $sortie = & netsh.exe wlan show interfaces
    $ErrorActionPreference = 'Stop'
    $w = [ordered]@{}
    foreach ($brut in @($sortie)) {
        # netsh français met une espace insécable avant « % » et « GHz » ; lue
        # dans la mauvaise page de code, elle devient « ┬á » et casse le motif.
        $ligne = ([string]$brut) -replace '\u252C\u00E1|\u00A0', ' '
        if ($ligne -match '^\s*SSID\s*:\s*(.+)$') { $w.ssid = $Matches[1].Trim() }
        elseif ($ligne -match '^\s*Signal\s*:\s*(\d+)\s*%') { $w.signal = [int]$Matches[1] }
        elseif ($ligne -match '^\s*(Bande|Band)\s*:\s*(.+)$') { $w.bande = $Matches[2].Trim() }
        elseif ($ligne -match '^\s*(Canal|Channel)\s*:\s*(\d+)') { $w.canal = [int]$Matches[2] }
    }
    if ($w.Contains('ssid')) { return $w }
    return $null
}

function Measure-Debit {
    $d = [ordered]@{ descendant_mbps = $null; montant_mbps = $null; detail = $null }
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (-not (Test-Path $curl)) { $d.detail = 'curl.exe absent'; return $d }
    $ErrorActionPreference = 'Continue'
    try {
        $v = & $curl -s -o NUL -w '%{speed_download}' --max-time 15 'https://speed.cloudflare.com/__down?bytes=50000000'
        if ($LASTEXITCODE -in 0, 28 -and [double]$v -gt 0) { $d.descendant_mbps = [Math]::Round([double]$v * 8 / 1e6, 1) }
        $f = Join-Path $env:TEMP ('pn-debit-' + [guid]::NewGuid().ToString('N'))
        $o = New-Object byte[] 10000000
        (New-Object Random).NextBytes($o)
        [IO.File]::WriteAllBytes($f, $o)
        $v = & $curl -s -o NUL -w '%{speed_upload}' --max-time 15 --data-binary "@$f" 'https://speed.cloudflare.com/__up'
        if ($LASTEXITCODE -in 0, 28 -and [double]$v -gt 0) { $d.montant_mbps = [Math]::Round([double]$v * 8 / 1e6, 1) }
        Remove-Item -Path $f -Force -ErrorAction SilentlyContinue
    } catch { $d.detail = $_.Exception.Message }
    $ErrorActionPreference = 'Stop'
    $d
}

function Get-Voisins($Carte) {
    $a = @($Carte.adresses) | Select-Object -First 1
    if (-not $a -or $a.prefixe -lt 22) { return @() }
    $octets = ([Net.IPAddress]::Parse($a.ip)).GetAddressBytes()
    [Array]::Reverse($octets)
    $ip = [BitConverter]::ToUInt32($octets, 0)
    $masque = [uint32]([Math]::Pow(2, 32) - [Math]::Pow(2, 32 - $a.prefixe))
    $reseau = $ip -band $masque
    $nombre = [Math]::Min(1022, [Math]::Pow(2, 32 - $a.prefixe) - 2)
    $cibles = @(for ($i = 1; $i -le $nombre; $i++) {
        $b = [BitConverter]::GetBytes([uint32]($reseau + $i))
        [Array]::Reverse($b)
        ([Net.IPAddress]$b).ToString()
    })
    $vus = @()
    for ($i = 0; $i -lt $cibles.Count; $i += 256) {
        $lot = $cibles[$i..([Math]::Min($i + 255, $cibles.Count - 1))]
        $taches = @($lot | ForEach-Object { (New-Object System.Net.NetworkInformation.Ping).SendPingAsync($_, 700) })
        try { [Threading.Tasks.Task]::WaitAll($taches) } catch { }
        for ($j = 0; $j -lt $lot.Count; $j++) {
            if ($taches[$j].Status -eq 'RanToCompletion' -and $taches[$j].Result.Status -eq 'Success') { $vus += $lot[$j] }
        }
    }
    $macs = @{}
    foreach ($n in @(Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
        if ($n.LinkLayerAddress -and $n.LinkLayerAddress -ne '00-00-00-00-00-00') { $macs[$n.IPAddress] = $n.LinkLayerAddress }
    }
    @($vus | Select-Object -First 254 | ForEach-Object { [ordered]@{ ip = $_; mac = $macs[$_] } })
}

function Invoke-Diagnostic($p) {
    $d = [ordered]@{ le = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); poste = $env:COMPUTERNAME }
    $d.cartes = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object {
        $c = Get-Carte $_.Name
        $c['etat'] = [string]$_.Status
        $c['mac'] = $_.MacAddress
        $c['vitesse'] = [string]$_.LinkSpeed
        $profil = Get-NetConnectionProfile -InterfaceAlias $_.Name -ErrorAction SilentlyContinue | Select-Object -First 1
        $c['profil'] = $(if ($profil) { [string]$profil.NetworkCategory } else { $null })
        $c
    })
    $d.wifi = Get-Wifi
    $d.pare_feu = @(Get-NetFirewallProfile -ErrorAction SilentlyContinue | ForEach-Object { [ordered]@{ profil = [string]$_.Name; actif = [bool]$_.Enabled } })
    $d.dns = @(foreach ($n in @('meshcentral.pointe-noire.com', 'www.google.com')) {
        $t = [Diagnostics.Stopwatch]::StartNew()
        try {
            $r = @(Resolve-DnsName -Name $n -Type A -DnsOnly -QuickTimeout -ErrorAction Stop | Where-Object { $_.IPAddress })
            [ordered]@{ nom = $n; ok = $true; ms = [int]$t.ElapsedMilliseconds; ip = $(if ($r.Count) { $r[0].IPAddress } else { $null }) }
        } catch { [ordered]@{ nom = $n; ok = $false; ms = $null; ip = $null } }
    })
    $cibles = @(@{ h = 'meshcentral.pointe-noire.com'; p = 443 }, @{ h = '1.1.1.1'; p = 443 }, @{ h = 'a.rtmp.youtube.com'; p = 1935 }, @{ h = 'live-api-s.facebook.com'; p = 443 })
    foreach ($c in @($p.cibles)) {
        if ($c -and $c.hote -and $c.port) { $cibles += @{ h = [string]$c.hote; p = [int]$c.port } }
    }
    $d.ports = @($cibles | Select-Object -First 20 | ForEach-Object { Test-Port $_.h $_.p })
    $noms = @{}
    foreach ($pr in @(Get-Process -ErrorAction SilentlyContinue)) { $noms[[int]$pr.Id] = $pr.ProcessName }
    $d.ecoute = @(@(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.LocalAddress -notlike '127.*' -and $_.LocalAddress -ne '::1' } | ForEach-Object { [ordered]@{ proto = 'tcp'; port = [int]$_.LocalPort; processus = $noms[[int]$_.OwningProcess] } }) +
                  @(Get-NetUDPEndpoint -ErrorAction SilentlyContinue | Where-Object { $_.LocalAddress -notlike '127.*' -and $_.LocalAddress -ne '::1' } | ForEach-Object { [ordered]@{ proto = 'udp'; port = [int]$_.LocalPort; processus = $noms[[int]$_.OwningProcess] } }) |
                  Sort-Object proto, port -Unique | Select-Object -First 120)
    if ($p.debit) { $d.debit = Measure-Debit }
    if ($p.scan) {
        $principale = @($d.cartes | Where-Object { $_.passerelle -and @($_.adresses).Count }) | Select-Object -First 1
        if (-not $principale) { $principale = @($d.cartes | Where-Object { @($_.adresses).Count }) | Select-Object -First 1 }
        if ($principale) { $d.voisins = @(Get-Voisins $principale) }
    }
    $result.diagnostic = $d
    $result.ok = $true
    $actives = @($d.cartes | Where-Object { @($_.adresses).Count })
    $txt = @($actives | ForEach-Object { "$($_.interface) $(@($_.adresses)[0].ip)/$(@($_.adresses)[0].prefixe)" }) -join ', '
    if (-not $txt) { $txt = 'aucune adresse IPv4' }
    $ko = @($d.ports | Where-Object { -not $_.ok }).Count
    $txt += " ; ports : $(@($d.ports).Count - $ko)/$(@($d.ports).Count) joignables"
    if ($d.Contains('debit') -and $d.debit.descendant_mbps) { $txt += " ; débit $($d.debit.descendant_mbps) Mb/s ↓ $($d.debit.montant_mbps) Mb/s ↑" }
    if ($d.Contains('voisins')) { $txt += " ; $(@($d.voisins).Count) appareils sur le réseau local" }
    $result.detail = $txt
}

# --- Entrée --------------------------------------------------------------------

try {
    $p = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:PNPL_PARAMS)) | ConvertFrom-Json
    Invoke-Diagnostic $p
} catch {
    $result.ok = $false
    $result.detail = $_.Exception.Message
}
Send-Result

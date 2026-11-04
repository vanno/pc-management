<#
  La sonde de supervision d'un poste (lot 3). Installée par `pilote.ps1` dans
  C:\ProgramData\PointeNoire\supervision, lancée chaque minute par la tâche
  planifiée PointeNoire-Supervision (compte SYSTEM). Compatible Windows
  PowerShell 5.1.

  Une exécution prend deux mesures à 30 secondes d'écart et les envoie à
  AVDiagram (POST <url>, Authorization: Bearer <jeton de sonde>) :
      cpu, ram (% occupée), disk_free (% libre du disque système),
      gateway_ms / gateway_loss, internet_ms / internet_loss (4 pings, 1 s),
      nics : débit reçu et envoyé de chaque carte physique active, en bits
             par seconde, calculé sur les compteurs d'octets de la carte ;
             et son réseau (adresse IPv4, préfixe, passerelle, DHCP, profil
             du pare-feu Public ou Privé), pour savoir quels postes partagent
             un réseau.

  Sans réseau, les mesures attendent dans en-attente.json (10 au plus) et
  partent à l'exécution suivante. Un 401 veut dire sonde retirée ou
  remplacée : la tâche se désactive.
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$conf = Get-Content -Raw -Path (Join-Path $dir 'config.json') | ConvertFrom-Json
$attente = Join-Path $dir 'en-attente.json'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Get-Compteurs {
    $r = @{}
    foreach ($a in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })) {
        $s = Get-NetAdapterStatistics -Name $a.Name -ErrorAction SilentlyContinue
        if ($s) { $r[$a.Name] = @{ rx = [double]$s.ReceivedBytes; tx = [double]$s.SentBytes; speed = [double]$a.Speed } }
    }
    $r
}

function Get-Reseau([string]$Alias) {
    $r = [ordered]@{ ipv4 = $null; prefix = $null; gateway = $null; dhcp = $null; profile = $null }
    try {
        $ip = @(Get-NetIPAddress -InterfaceAlias $Alias -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike '169.254.*' }) | Select-Object -First 1
        if ($ip) { $r.ipv4 = $ip.IPAddress; $r.prefix = [int]$ip.PrefixLength }
        $route = @(Get-NetRoute -InterfaceAlias $Alias -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric) | Select-Object -First 1
        if ($route) { $r.gateway = $route.NextHop }
        $itf = Get-NetIPInterface -InterfaceAlias $Alias -AddressFamily IPv4 -ErrorAction SilentlyContinue
        if ($itf) { $r.dhcp = ($itf.Dhcp -eq 'Enabled') }
        $profil = Get-NetConnectionProfile -InterfaceAlias $Alias -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($profil) { $r.profile = [string]$profil.NetworkCategory }
    } catch { }
    $r
}

function Measure-Ping([string]$Cible) {
    if (-not $Cible) { return @{ ms = $null; loss = $null } }
    $p = New-Object System.Net.NetworkInformation.Ping
    $ok = @()
    for ($i = 0; $i -lt 4; $i++) {
        try {
            $r = $p.Send($Cible, 1000)
            if ($r.Status -eq 'Success') { $ok += [double]$r.RoundtripTime }
        } catch { }
    }
    $ms = $null
    if ($ok.Count) { $ms = [Math]::Round(($ok | Measure-Object -Average).Average, 1) }
    @{ ms = $ms; loss = [double](100 * (4 - $ok.Count) / 4) }
}

function Get-Mesure($Avant, $Apres, [double]$Secondes) {
    $cpu = $null; $ram = $null; $disque = $null
    try { $cpu = [double](Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'").PercentProcessorTime } catch { }
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $ram = [Math]::Round(100 * (1 - $os.FreePhysicalMemory / $os.TotalVisibleMemorySize), 1)
    } catch { }
    try {
        $d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'"
        if ($d.Size) { $disque = [Math]::Round(100 * $d.FreeSpace / $d.Size, 1) }
    } catch { }
    $gw = $null
    try { $gw = (@(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric) | Select-Object -First 1).NextHop } catch { }
    $pg = Measure-Ping $gw
    $pi = Measure-Ping '1.1.1.1'
    $cartes = @()
    foreach ($nom in $Apres.Keys) {
        if (-not $Avant.ContainsKey($nom) -or $Secondes -le 0) { continue }
        $rx = [Math]::Max(0, ($Apres[$nom].rx - $Avant[$nom].rx) * 8 / $Secondes)
        $tx = [Math]::Max(0, ($Apres[$nom].tx - $Avant[$nom].tx) * 8 / $Secondes)
        $n = Get-Reseau $nom
        $cartes += [ordered]@{ name = $nom; rx = [Math]::Round($rx); tx = [Math]::Round($tx); speed = $Apres[$nom].speed; ipv4 = $n.ipv4; prefix = $n.prefix; gateway = $n.gateway; dhcp = $n.dhcp; profile = $n.profile }
    }
    [ordered]@{
        at            = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        cpu           = $cpu
        ram           = $ram
        disk_free     = $disque
        gateway_ms    = $pg.ms
        gateway_loss  = $pg.loss
        internet_ms   = $pi.ms
        internet_loss = $pi.loss
        nics          = $cartes
    }
}

$mesures = @()
$debut = Get-Date
$avant = Get-Compteurs
$t = $debut
foreach ($k in 1, 2) {
    $reste = ($debut.AddSeconds(28 * $k) - (Get-Date)).TotalSeconds
    if ($reste -gt 0) { Start-Sleep -Milliseconds ([int]($reste * 1000)) }
    $apres = Get-Compteurs
    $maintenant = Get-Date
    $mesures += , (Get-Mesure $avant $apres ($maintenant - $t).TotalSeconds)
    $avant = $apres
    $t = $maintenant
}

$envoi = @()
if (Test-Path $attente) {
    # PowerShell 5.1 rend un tableau JSON comme UN objet : foreach le déroule.
    try { foreach ($m in (Get-Content -Raw -Path $attente | ConvertFrom-Json)) { $envoi += , $m } } catch { $envoi = @() }
}
$envoi = @($envoi + $mesures | Select-Object -Last 10)
$corps = @{ samples = $envoi } | ConvertTo-Json -Depth 6 -Compress
try {
    Invoke-RestMethod -Method Post -Uri $conf.url -Headers @{ Authorization = "Bearer $($conf.jeton)" } -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($corps)) -TimeoutSec 15 -UseBasicParsing | Out-Null
    Remove-Item -Path $attente -ErrorAction SilentlyContinue
} catch {
    $code = $null
    try { $code = [int]$_.Exception.Response.StatusCode } catch { }
    if ($code -eq 401) {
        Disable-ScheduledTask -TaskName 'PointeNoire-Supervision' -ErrorAction SilentlyContinue | Out-Null
        Remove-Item -Path $attente -ErrorAction SilentlyContinue
    } elseif ($code -eq 400) {
        # Des mesures refusées ne repartent pas en boucle.
        Remove-Item -Path $attente -ErrorAction SilentlyContinue
    } else {
        [IO.File]::WriteAllText($attente, (ConvertTo-Json -InputObject @($envoi) -Depth 6 -Compress), (New-Object System.Text.UTF8Encoding $false))
    }
}

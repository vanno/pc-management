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
             un réseau ; wired (Ethernet ou non), errors (paquets en erreur
             reçus et envoyés sur l'intervalle).
      Une carte filaire tombée depuis moins de 10 minutes part aussi, avec
      down = true (état dans liens.json) : c'est le seul regard sur le câble
      quand le switch n'est pas manageable.

  Sans réseau, les mesures attendent dans en-attente.json (10 au plus) et
  partent à l'exécution suivante. Un 401 veut dire sonde retirée ou
  remplacée : la tâche se désactive, sauf si config.json porte déjà un jeton
  neuf (sonde reposée pendant la mesure).
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$conf = Get-Content -Raw -Path (Join-Path $dir 'config.json') | ConvertFrom-Json
$attente = Join-Path $dir 'en-attente.json'
$fichierLiens = Join-Path $dir 'liens.json'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# MeshCentral ne lance qu'une commande à la fois par poste, sans limite de
# durée : une commande restée ouverte (un PowerShell qui attend la fin d'un
# bloc écrit sur plusieurs lignes) bloque toutes les suivantes, celles du
# relais comprises (PN09, le 2026-11-05). Passé 90 minutes, plus que la plus
# longue tâche du relais, elle est fermée et notée dans debloque.log. Le
# terminal de MeshCentral se lance autrement et n'est jamais touché.
try {
    $agents = @(Get-CimInstance Win32_Service -Filter "Name='Mesh Agent' OR PathName LIKE '%MeshAgent%'" | ForEach-Object { [int]$_.ProcessId } | Where-Object { $_ })
    foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'")) {
        if ($agents -contains [int]$p.ParentProcessId -and [string]$p.CommandLine -match '-noprofile -nologo -command -\s*$' -and $p.CreationDate -lt (Get-Date).AddMinutes(-90)) {
            Stop-Process -Id $p.ProcessId -Force
            Add-Content -Path (Join-Path $dir 'debloque.log') -Encoding UTF8 -Value "$(Get-Date -Format s) commande MeshCentral fermée après $([int]((Get-Date) - $p.CreationDate).TotalMinutes) minutes (PID $($p.ProcessId))"
        }
    }
} catch { }

function Get-Compteurs {
    $r = @{}
    foreach ($a in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })) {
        $s = Get-NetAdapterStatistics -Name $a.Name -ErrorAction SilentlyContinue
        if ($s) {
            $err = [double]$s.ReceivedPacketErrors + [double]$s.OutboundPacketErrors
            $r[$a.Name] = @{ rx = [double]$s.ReceivedBytes; tx = [double]$s.SentBytes; speed = [double]$a.Speed; err = $err; wired = ([string]$a.PhysicalMediaType -eq '802.3') }
        }
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

function Get-LiensCoupes($Actives) {
    # Une carte filaire vue active puis tombée : gardée 10 minutes, puis
    # oubliée (un portable retiré de son dock ne reste pas « coupé »).
    $etat = @{}
    if (Test-Path $fichierLiens) {
        try {
            $lu = Get-Content -Raw -Path $fichierLiens | ConvertFrom-Json
            foreach ($p in $lu.PSObject.Properties) { $etat[$p.Name] = $p.Value }
        } catch { $etat = @{} }
    }
    $maintenant = (Get-Date).ToUniversalTime()
    $nouveau = @{}
    $coupes = @()
    foreach ($nom in $Actives.Keys) {
        if ($Actives[$nom].wired) { $nouveau[$nom] = @{ coupe = $null } }
    }
    foreach ($nom in $etat.Keys) {
        if ($nouveau.ContainsKey($nom)) { continue }
        $a = Get-NetAdapter -Name $nom -Physical -ErrorAction SilentlyContinue
        if (-not $a -or $a.Status -eq 'Up') { continue }
        $coupe = $maintenant
        if ($etat[$nom].coupe) { try { $coupe = [DateTime]::Parse([string]$etat[$nom].coupe).ToUniversalTime() } catch { } }
        if (($maintenant - $coupe).TotalMinutes -ge 10) { continue }
        $nouveau[$nom] = @{ coupe = $coupe.ToString('yyyy-MM-ddTHH:mm:ssZ') }
        $coupes += [ordered]@{ name = $nom; rx = 0; tx = 0; speed = $null; wired = $true; down = $true }
    }
    try { [IO.File]::WriteAllText($fichierLiens, (ConvertTo-Json -InputObject $nouveau -Compress), (New-Object System.Text.UTF8Encoding $false)) } catch { }
    , $coupes
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
        $rx = [Math]::Max(0.0, ($Apres[$nom].rx - $Avant[$nom].rx) * 8 / $Secondes)
        $tx = [Math]::Max(0.0, ($Apres[$nom].tx - $Avant[$nom].tx) * 8 / $Secondes)
        $n = Get-Reseau $nom
        $err = [Math]::Max(0, $Apres[$nom].err - $Avant[$nom].err)
        $cartes += [ordered]@{ name = $nom; rx = [Math]::Round($rx); tx = [Math]::Round($tx); speed = $Apres[$nom].speed; ipv4 = $n.ipv4; prefix = $n.prefix; gateway = $n.gateway; dhcp = $n.dhcp; profile = $n.profile; wired = $Apres[$nom].wired; errors = [long]$err }
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
$coupes = Get-LiensCoupes $avant
if ($coupes.Count -and $mesures.Count) {
    $derniere = $mesures[$mesures.Count - 1]
    $derniere.nics = @(@($derniere.nics) + $coupes | Select-Object -First 8)
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
    # Une sonde reposée entre-temps a un jeton neuf : seul l'ancien est refusé.
    $jeton = $null
    try { $jeton = (Get-Content -Raw -Path (Join-Path $dir 'config.json') | ConvertFrom-Json).jeton } catch { }
    if ($code -eq 401 -and $jeton -eq $conf.jeton) { Disable-ScheduledTask -TaskName 'PointeNoire-Supervision' -ErrorAction SilentlyContinue | Out-Null }
    if ($code -eq 401 -or $code -eq 400) {
        # Des mesures refusées ne repartent pas en boucle.
        Remove-Item -Path $attente -ErrorAction SilentlyContinue
    } else {
        [IO.File]::WriteAllText($attente, (ConvertTo-Json -InputObject @($envoi) -Depth 6 -Compress), (New-Object System.Text.UTF8Encoding $false))
    }
}

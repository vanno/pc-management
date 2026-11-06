<#
  Essai sous Windows PowerShell 5.1 (GitHub Actions, ou à la main sur un PC)
  de la lecture de vMix (agent/vmix.ps1) et du test de sortie
  (agent/diagnostic.ps1), sans vMix ni plateforme : un faux vMix répond sur
  127.0.0.1:8088 puis sur le port TCP 8099, un faux serveur RTMP et un faux
  serveur SRT répondent sur la boucle locale.

    powershell -ExecutionPolicy Bypass -File agent\essai-direct.ps1

  Le protocole lui-même a été vérifié contre libsrt 1.5.3
  (srt-live-transmit en listener) et un serveur RTMP ffmpeg : cet essai
  vérifie que le code tourne sous PowerShell 5.1.
#>
$ErrorActionPreference = 'Stop'
$racine = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('essai-direct-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp | Out-Null
$echecs = 0
function Test-Point([string]$Nom, [bool]$Ok, [string]$Detail) {
    if ($Ok) { Write-Host "OK     $Nom" } else { Write-Host "ECHEC  $Nom : $Detail"; $script:echecs++ }
}
# Un processus de tâche met plusieurs secondes à démarrer sous Windows : on attend que l'écoute soit ouverte.
function Wait-Pret([string]$Fichier, $Tache) {
    for ($k = 0; $k -lt 60 -and -not (Test-Path $Fichier); $k++) {
        if ($Tache.State -in 'Failed', 'Completed', 'Stopped') { break }
        Start-Sleep -Milliseconds 500
    }
    if (-not (Test-Path $Fichier)) { Write-Host "Écoute pas ouverte ($($Tache.State)) : $(Receive-Job $Tache 2>&1 | Out-String)" }
}
Write-Host "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"

foreach ($f in 'vmix.ps1', 'diagnostic.ps1', 'supervision.ps1', 'console-pose.ps1') {
    # Lus en UTF-8 comme le relais les envoie (ParseFile lirait un fichier sans BOM en ANSI).
    $err = $null
    [void][Management.Automation.Language.Parser]::ParseInput([IO.File]::ReadAllText((Join-Path $racine "agent\$f"), [Text.Encoding]::UTF8), [ref]$null, [ref]$err)
    Test-Point "$f se lit sous PowerShell 5.1" (-not $err) ($err | Out-String)
}

$xml = '<vmix><version>27.0.0.49</version><edition>4K</edition><inputs><input key="a" number="1" type="Capture" title="Cam 1" state="Running">Cam 1</input></inputs><recording duration="125">True</recording><external>False</external><streaming channel1="True" channel2="False">True</streaming><multiCorder>False</multiCorder></vmix>'
$sonde = Join-Path $tmp 'sonde'
New-Item -ItemType Directory -Path $sonde | Out-Null
$vmix = Join-Path $sonde 'vmix.ps1'
# Comme console-pose.ps1 : avec BOM.
[IO.File]::WriteAllText($vmix, [IO.File]::ReadAllText((Join-Path $racine 'agent\vmix.ps1'), [Text.Encoding]::UTF8), (New-Object System.Text.UTF8Encoding $true))

# 1. Sans vMix lancé : rien
Test-Point 'sans vMix : rien' ($null -eq (& $vmix)) 'une lecture sans vMix'

# Un faux vMix : un processus de ce nom.
$faux = Join-Path $tmp 'vMix64.exe'
Copy-Item (Join-Path $PSHOME 'powershell.exe') $faux
$proc = Start-Process -FilePath $faux -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 300' -PassThru -WindowStyle Hidden
$http = $null; $tcp = $null
try {
    Start-Sleep -Seconds 1
    # 2. vMix lancé, API muette
    $v = & $vmix
    Test-Point 'vMix muet' ($v -and $v.ok -eq $false -and $v.running -eq $true) ($v | ConvertTo-Json -Compress)

    # 3. API HTTP 8088
    $pret = Join-Path $tmp 'pret-http'
    $http = Start-Job -ArgumentList $xml, $pret -ScriptBlock {
        param($Xml, $Pret)
        $l = New-Object Net.HttpListener
        $l.Prefixes.Add('http://127.0.0.1:8088/')
        $l.Start()
        Set-Content -Path $Pret -Value 1
        # Deux lectures attendues (la sonde d'essai, puis vmix.ps1) : la tâche finit d'elle-même.
        for ($i = 0; $i -lt 2; $i++) {
            $c = $l.GetContext()
            $b = [Text.Encoding]::UTF8.GetBytes($Xml)
            $c.Response.ContentType = 'text/xml'
            $c.Response.OutputStream.Write($b, 0, $b.Length)
            $c.Response.Close()
        }
        $l.Stop()
    }
    Wait-Pret $pret $http
    # Une première lecture sans limite serrée : dit si l'écoute répond, et en combien de temps.
    $t0 = [Diagnostics.Stopwatch]::StartNew()
    try {
        $q = [Net.HttpWebRequest][Net.WebRequest]::Create('http://127.0.0.1:8088/api')
        $q.Proxy = $null; $q.Timeout = 15000
        $rep = $q.GetResponse(); $rep.Close()
        Write-Host "       faux vMix HTTP : réponse en $($t0.ElapsedMilliseconds) ms"
    } catch { Write-Host "       faux vMix HTTP : $($_.Exception.InnerException.Message) $($_.Exception.Message) après $($t0.ElapsedMilliseconds) ms" }
    $v = & $vmix
    Test-Point 'lecture par le port 8088' ($v.ok -and $v.source -eq 'http' -and $v.streaming -and $v.recording -and $v.recording_s -eq 125 -and $v.inputs -eq 1 -and $v.version -eq '27.0.0.49') ($v | ConvertTo-Json -Compress)
    Test-Point 'destinations du stream' (@($v.channels).Count -eq 2 -and $v.channels[0] -eq $true -and $v.channels[1] -eq $false) ($v.channels | ConvertTo-Json -Compress)
    Wait-Job $http -Timeout 5 | Out-Null; Remove-Job $http -Force -ErrorAction SilentlyContinue; $http = $null

    # 4. Port TCP 8099, stream arrêté depuis la mesure d'avant
    $xml2 = $xml.Replace('channel1="True"', 'channel1="False"').Replace('>True</streaming>', '>False</streaming>')
    $pret = Join-Path $tmp 'pret-tcp'
    $tcp = Start-Job -ArgumentList $xml2, $pret -ScriptBlock {
        param($Xml, $Pret)
        $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 8099)
        $l.Start()
        Set-Content -Path $Pret -Value 1
        for ($i = 0; $i -lt 1; $i++) {
            $c = $l.AcceptTcpClient()
            $s = $c.GetStream()
            $h = [Text.Encoding]::ASCII.GetBytes("VERSION OK 27.0.0.49`r`n")
            $s.Write($h, 0, $h.Length)
            $q = New-Object byte[] 64
            [void]$s.Read($q, 0, 64)
            $b = [Text.Encoding]::UTF8.GetBytes($Xml)
            $t = [Text.Encoding]::ASCII.GetBytes("XML $($b.Length)`r`n")
            $s.Write($t, 0, $t.Length)
            $s.Write($b, 0, $b.Length)
            $c.Close()
        }
        $l.Stop()
    }
    Wait-Pret $pret $tcp
    $v = & $vmix
    Test-Point 'lecture par le port 8099' ($v.ok -and $v.source -eq 'tcp' -and $v.streaming -eq $false) ($v | ConvertTo-Json -Compress)
    Test-Point 'arrêt du stream noté' ([bool]$v.stopped_at) ($v | ConvertTo-Json -Compress)
} finally {
    foreach ($j in @($http, $tcp)) { if ($j) { Wait-Job $j -Timeout 5 | Out-Null; Remove-Job $j -Force -ErrorAction SilentlyContinue } }
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 1
$v = & $vmix
Test-Point 'vMix fermé après un stream' ($v -and $v.running -eq $false -and $v.detail -eq 'vMix fermé') ($v | ConvertTo-Json -Compress)

# 5. Test de sortie : les fonctions du diagnostic, contre de faux serveurs
$src = [IO.File]::ReadAllText((Join-Path $racine 'agent\diagnostic.ps1'), [Text.Encoding]::UTF8)
$ast = [Management.Automation.Language.Parser]::ParseInput($src, [ref]$null, [ref]$null)
foreach ($f in $ast.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    if ($f.Name -in 'Get-Stats', 'Read-Octets', 'Test-Rtmp', 'Test-Srt', 'Measure-Sortie') { . ([ScriptBlock]::Create($f.Extent.Text)) }
}
$rtmp = Start-Job -ScriptBlock {
    $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 19350)
    $l.Start()
    for ($i = 0; $i -lt 10; $i++) {
        $c = $l.AcceptTcpClient()
        $s = $c.GetStream()
        $o = New-Object byte[] 1537
        $lu = 0; while ($lu -lt 1537) { $lu += $s.Read($o, $lu, 1537 - $lu) }
        $r = New-Object byte[] 3073
        $r[0] = 3
        $s.Write($r, 0, $r.Length)
        $c2 = New-Object byte[] 1536
        $lu = 0; while ($lu -lt 1536) { $k = $s.Read($c2, $lu, 1536 - $lu); if ($k -le 0) { break }; $lu += $k }
        $c.Close()
    }
    $l.Stop()
}
$srt = Start-Job -ScriptBlock {
    $u = New-Object Net.Sockets.UdpClient(19000)
    $u.Client.ReceiveTimeout = 15000
    for ($i = 0; $i -lt 20; $i++) {
        $de = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)
        try { $q = $u.Receive([ref]$de) } catch { break }
        if ($q.Length -lt 64 -or $q[0] -ne 0x80 -or $q[39] -ne 1) { continue }
        # Réponse d'induction : version 5, adressée à l'identifiant du demandeur.
        $r = New-Object byte[] 64
        $r[0] = 0x80
        [Array]::Copy($q, 40, $r, 12, 4)
        $r[19] = 5; $r[39] = 1
        [void]$u.Send($r, 64, $de)
    }
    $u.Close()
}
try {
    Start-Sleep -Seconds 2
    $s = Measure-Sortie @{ protocole = 'rtmp'; hote = '127.0.0.1'; port = 19350; prevu_mbps = 8 }
    Test-Point 'RTMP : 10 poignées de main' ($s.reussis -eq 10 -and $s.perte -eq 0 -and $null -ne $s.ms_moy -and $s.prevu_mbps -eq 8) ($s | ConvertTo-Json -Compress)
    $s = Measure-Sortie @{ protocole = 'srt'; hote = '127.0.0.1'; port = 19000 }
    Test-Point 'SRT : 20 inductions' ($s.reussis -eq 20 -and $s.perte -eq 0) ($s | ConvertTo-Json -Compress)
    $s = Measure-Sortie @{ protocole = 'srt'; hote = '127.0.0.1'; port = 19001 }
    Test-Point 'SRT fermé : perte 100 %' ($s.reussis -eq 0 -and $s.perte -eq 100 -and $s.detail) ($s | ConvertTo-Json -Compress)
} finally {
    foreach ($j in @($rtmp, $srt)) { Wait-Job $j -Timeout 20 | Out-Null; Remove-Job $j -Force -ErrorAction SilentlyContinue }
}
if ($echecs) { Write-Host "$echecs échec(s)"; exit 1 }
Write-Host 'Tout est bon.'

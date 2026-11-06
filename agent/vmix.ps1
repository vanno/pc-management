<#
  La lecture de vMix sur le poste, appelée par supervision.ps1 à chaque
  mesure (compte SYSTEM). Posée à côté de la sonde par console-pose.ps1.
  Compatible Windows PowerShell 5.1. Rend $null si vMix n'est pas lancé
  (sauf dans les 10 minutes après un stream : « vMix fermé »). L'arrêt du
  stream (stopped_at) et les images perdues depuis la mesure d'avant
  (dropped_new) se suivent dans vmix-etat.json.

  Source : l'API de vMix sur le poste même, http://127.0.0.1:8088/api, puis
  le port TCP 8099 (commande « XML ») si le premier ne répond pas. Ce que
  l'API donne (doc vMix, module vMix de Companion) :
      <version>, <edition>, <streaming channel1="True"…>True</streaming>,
      <recording duration="123">True</recording>, <external>, <multiCorder>,
      <inputs><input type="…" state="Running|Paused|Completed" …>.
  Elle ne donne ni images perdues, ni débit sortant, ni entrées en erreur :
  le débit sortant se lit sur la carte réseau (la sonde le mesure déjà), et
  les images perdues sont cherchées dans le dernier journal de stream de
  vMix (C:\ProgramData\vMix\streaming, emplacement rapporté par un
  utilisateur, pas par vMix ; la ligne lue part telle quelle pour vérifier).
#>
param([int]$Delai = 1500)

$ErrorActionPreference = 'Stop'
$script:erreurHttp = $null
# D'une mesure à l'autre : le stream était-il actif, quand s'est-il arrêté,
# combien d'images perdues au dernier relevé.
$fichierEtat = Join-Path $PSScriptRoot 'vmix-etat.json'
$maintenant = (Get-Date).ToUniversalTime()
$avant = $null
try { if (Test-Path $fichierEtat) { $avant = Get-Content -Raw -Path $fichierEtat | ConvertFrom-Json } } catch { $avant = $null }

function Get-Arret([bool]$Coupe) {
    # Le moment où le stream s'est arrêté, gardé 10 minutes.
    $a = $null
    if ($Coupe) { $a = $maintenant }
    elseif ($avant -and $avant.stopped_at) { try { $a = [DateTime]::Parse([string]$avant.stopped_at).ToUniversalTime() } catch { } }
    if ($a -and ($maintenant - $a).TotalMinutes -lt 10) { return $a.ToString('yyyy-MM-ddTHH:mm:ssZ') }
    $null
}

function Save-Etat($V) {
    $e = [ordered]@{ streaming = ($V.streaming -eq $true); stopped_at = $V.stopped_at; dropped = $V.dropped }
    try { [IO.File]::WriteAllText($fichierEtat, (ConvertTo-Json -InputObject $e -Compress), (New-Object System.Text.UTF8Encoding $false)) } catch { }
}

$etaitLive = [bool]($avant -and $avant.streaming -eq $true)
if (-not @(Get-Process -Name 'vMix64', 'vMix' -ErrorAction SilentlyContinue).Count) {
    # vMix fermé : rien à dire, sauf s'il streamait il y a peu.
    $arret = Get-Arret $etaitLive
    if (-not $arret) { Remove-Item -Path $fichierEtat -ErrorAction SilentlyContinue; return $null }
    $v = [ordered]@{ ok = $false; running = $false; streaming = $false; stopped_at = $arret; dropped = $null; detail = 'vMix fermé' }
    Save-Etat $v
    return $v
}

function Read-Http {
    try {
        $q = [Net.HttpWebRequest][Net.WebRequest]::Create('http://127.0.0.1:8088/api')
        $q.Proxy = $null
        $q.Timeout = $Delai
        $q.ReadWriteTimeout = $Delai
        $rep = $q.GetResponse()
        try { return (New-Object IO.StreamReader($rep.GetResponseStream(), [Text.Encoding]::UTF8)).ReadToEnd() } finally { $rep.Close() }
    } catch {
        # La raison remonte dans « detail » si le port TCP ne répond pas non plus.
        $m = $_.Exception
        while ($m.InnerException) { $m = $m.InnerException }
        $script:erreurHttp = $m.Message
        return $null
    }
}

function Read-Tcp {
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $a = $c.BeginConnect('127.0.0.1', 8099, $null, $null)
        if (-not $a.AsyncWaitHandle.WaitOne($Delai)) { return $null }
        $c.EndConnect($a)
        $s = $c.GetStream()
        $s.ReadTimeout = $Delai
        $q = [Text.Encoding]::ASCII.GetBytes("XML`r`n")
        $s.Write($q, 0, $q.Length)
        # vMix salue d'abord (« VERSION OK … »), puis « XML <octets>\r\n » et le XML en UTF-8.
        $tete = ''
        for ($k = 0; $k -lt 4 -and $tete -notmatch '^XML \d+$'; $k++) {
            $l = New-Object Text.StringBuilder
            while ($true) {
                $b = $s.ReadByte()
                if ($b -lt 0) { return $null }
                if ($b -eq 10) { break }
                if ($b -ne 13) { [void]$l.Append([char]$b) }
                if ($l.Length -gt 200) { return $null }
            }
            $tete = $l.ToString()
        }
        if ($tete -notmatch '^XML (\d+)$') { return $null }
        $n = [int]$Matches[1]
        if ($n -le 0 -or $n -gt 8MB) { return $null }
        $o = New-Object byte[] $n
        $lu = 0
        while ($lu -lt $n) {
            $k = $s.Read($o, $lu, $n - $lu)
            if ($k -le 0) { return $null }
            $lu += $k
        }
        return [Text.Encoding]::UTF8.GetString($o)
    } catch { return $null } finally { $c.Close() }
}

function Test-Vrai($Noeud) {
    if ($null -eq $Noeud) { return $false }
    return ([string]$Noeud.InnerText).Trim() -eq 'True'
}

function Read-Journal {
    # Le journal de stream le plus récent, s'il a bougé depuis 10 minutes.
    $r = [ordered]@{ dropped = $null; log = $null }
    try {
        $d = Join-Path $env:ProgramData 'vMix\streaming'
        if (-not (Test-Path $d)) { return $r }
        $f = Get-ChildItem -Path $d -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
        if (-not $f -or $f.LastWriteTimeUtc -lt (Get-Date).ToUniversalTime().AddMinutes(-10)) { return $r }
        $fs = [IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite')
        try {
            $n = [int][Math]::Min(8192, $fs.Length)
            [void]$fs.Seek(-$n, 'End')
            $o = New-Object byte[] $n
            [void]$fs.Read($o, 0, $n)
        } finally { $fs.Close() }
        $lignes = @(([Text.Encoding]::UTF8.GetString($o) -split "`r?`n") | Where-Object { $_.Trim() })
        foreach ($l in $lignes) { if ($l -match '(?i)dropped\D{0,3}(\d+)') { $r.dropped = [long]$Matches[1] } }
        if ($lignes.Count) {
            $l = ($lignes[$lignes.Count - 1] -replace '[\x00-\x1F]', ' ').Trim()
            $r.log = $l.Substring(0, [Math]::Min(160, $l.Length))
        }
    } catch { }
    $r
}

$brut = Read-Http
$source = 'http'
if (-not $brut) { $brut = Read-Tcp; $source = 'tcp' }
$v = [ordered]@{ ok = $false; running = $true; source = $null }
$r = $null
if ($brut) { try { $r = ([xml]$brut).SelectSingleNode('/vmix') } catch { $r = $null } }
if (-not $r) {
    $v.detail = $(if ($brut) { 'réponse de vMix illisible' } else { 'vMix lancé mais son API ne répond pas (Web Controller coupé ou accès refusé)' + $(if ($script:erreurHttp) { ' : ' + $script:erreurHttp.Substring(0, [Math]::Min(120, $script:erreurHttp.Length)) } else { '' }) })
    # Sans lecture, l'état du stream d'avant est gardé tel quel.
    $v.stopped_at = Get-Arret $false
    return $v
}
function Get-Texte([string]$Nom) { $n = $r.SelectSingleNode($Nom); if ($n) { $n.InnerText.Trim() } else { $null } }
$v.ok = $true
$v.source = $source
$v.version = Get-Texte 'version'
$v.edition = Get-Texte 'edition'
$st = $r.SelectSingleNode('streaming')
$v.streaming = [bool](Test-Vrai $st)
$canaux = @()
if ($st) { foreach ($i in 1..5) { $a = $st.GetAttribute("channel$i"); if ($a) { $canaux += , ($a -eq 'True') } } }
$v.channels = $canaux
$rec = $r.SelectSingleNode('recording')
$v.recording = [bool](Test-Vrai $rec)
$v.recording_s = $null
if ($rec -and $rec.GetAttribute('duration') -match '^\d+$') { $v.recording_s = [long]$rec.GetAttribute('duration') }
$v.external = [bool](Test-Vrai $r.SelectSingleNode('external'))
$v.multicorder = [bool](Test-Vrai $r.SelectSingleNode('multiCorder'))
$v.inputs = @($r.SelectNodes('inputs/input')).Count
$v.stopped_at = $(if ($v.streaming) { $null } else { Get-Arret $etaitLive })
$j = Read-Journal
$v.dropped = $j.dropped
$v.dropped_new = $null
if ($null -ne $j.dropped -and $avant -and $null -ne $avant.dropped -and $j.dropped -ge [long]$avant.dropped) { $v.dropped_new = $j.dropped - [long]$avant.dropped }
$v.log = $j.log
Save-Etat $v
$v

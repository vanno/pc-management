<#
  La vignette du poste pour le mur d'écrans d'AVDiagram (0084). Tourne dans la
  session ouverte (tâche PointeNoire-Vignette, groupe Utilisateurs, chaque
  minute), lancée par wscript sans fenêtre. Compatible Windows PowerShell 5.1.

  Chaque lancement dure 55 secondes au plus : il demande à AVDiagram si
  quelqu'un regarde ce poste (deux fois par minute), et seulement alors il
  envoie une image réduite de l'écran (tous les écrans, 1920 x 540 au plus,
  JPEG) toutes les 10 secondes, 30 en mode événement. Rien n'est gardé sur le
  poste. Écran verrouillé : il le dit, sans image.

  Seule la session de la console capture : une session RDP ouverte en même
  temps ne double pas les envois. Jeton refusé (retiré du mur) : la tâche
  s'arrête d'elle-même.
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$base = Join-Path $env:ProgramData 'PointeNoire'
$dossier = Join-Path $base 'vignette'
$fichierEvenement = Join-Path $base 'mode-evenement.json'
$conf = Get-Content -Raw -Encoding UTF8 (Join-Path $dossier 'config.json') | ConvertFrom-Json
if (-not $conf.url -or -not $conf.jeton) { exit 0 }

Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace PointeNoire {
    public static class Session {
        [DllImport("kernel32.dll")] public static extern uint WTSGetActiveConsoleSessionId();
        [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
        [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
    }
}
'@
# Sans ça, Windows rend un écran à 150 % en pixels réduits, et la capture est coupée.
[void][PointeNoire.Session]::SetProcessDPIAware()

$moi = [Diagnostics.Process]::GetCurrentProcess().SessionId
if ($moi -ne [PointeNoire.Session]::WTSGetActiveConsoleSessionId()) { exit 0 }

function Test-Verrouille {
    [bool](Get-Process -Name LogonUI -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $moi })
}

function Get-Pas([int]$Demande) {
    $pas = [Math]::Max(5, $Demande)
    if (Test-Path $fichierEvenement) {
        try { if (@((Get-Content -Raw $fichierEvenement | ConvertFrom-Json).parties).Count) { $pas = [Math]::Max($pas, 30) } } catch { }
    }
    $pas
}

$jpeg = [Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' } | Select-Object -First 1

function Get-Image {
    # L'écran virtuel : tous les écrans, l'origine pouvant être négative.
    $x = [PointeNoire.Session]::GetSystemMetrics(76); $y = [PointeNoire.Session]::GetSystemMetrics(77)
    $l = [PointeNoire.Session]::GetSystemMetrics(78); $h = [PointeNoire.Session]::GetSystemMetrics(79)
    if ($l -le 0 -or $h -le 0) { throw 'écran introuvable' }
    $k = [Math]::Min([Math]::Min(1920 / $l, 540 / $h), 1)
    $lr = [Math]::Max(1, [int]($l * $k)); $hr = [Math]::Max(1, [int]($h * $k))
    $plein = New-Object Drawing.Bitmap $l, $h
    $reduit = New-Object Drawing.Bitmap $lr, $hr
    try {
        $g = [Drawing.Graphics]::FromImage($plein)
        try { $g.CopyFromScreen($x, $y, 0, 0, $plein.Size) } finally { $g.Dispose() }
        $g = [Drawing.Graphics]::FromImage($reduit)
        try {
            $g.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBilinear
            $g.DrawImage($plein, 0, 0, $lr, $hr)
        } finally { $g.Dispose() }
        foreach ($qualite in 60, 35) {
            $p = New-Object Drawing.Imaging.EncoderParameters 1
            $p.Param[0] = New-Object Drawing.Imaging.EncoderParameter([Drawing.Imaging.Encoder]::Quality, [long]$qualite)
            $m = New-Object IO.MemoryStream
            try { $reduit.Save($m, $jpeg, $p); $b = [Convert]::ToBase64String($m.ToArray()) } finally { $m.Dispose() }
            if ($b.Length -le 390000) { return @{ image = $b; width = $lr; height = $hr } }
        }
        throw 'image trop lourde'
    } finally {
        $plein.Dispose(); $reduit.Dispose()
    }
}

function Send-Vignette($Corps) {
    $json = $Corps | ConvertTo-Json -Compress
    Invoke-RestMethod -Method Post -Uri $conf.url -Headers @{ Authorization = "Bearer $($conf.jeton)" } -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec 20 -UseBasicParsing
}

$fin = (Get-Date).AddSeconds(55)
$regarde = $false
$pas = 10
while ((Get-Date) -lt $fin) {
    $corps = @{}
    if (Test-Verrouille) { $corps = @{ state = 'locked' } }
    elseif ($regarde) {
        try { $corps = Get-Image } catch { $corps = @{ state = 'locked' } }
    }
    try {
        $r = Send-Vignette $corps
        $regarde = [bool]$r.watched
        if ($r.interval) { $pas = [int]$r.interval }
    } catch {
        $code = $null
        try { $code = [int]$_.Exception.Response.StatusCode } catch { }
        # Retiré du mur : le retrait enlève aussi la tâche, celle-ci s'arrête là.
        if ($code -eq 401) { exit 0 }
        $regarde = $false
    }
    # Regardé, et ce tour n'était qu'une question : la première image part tout de suite.
    if ($regarde -and $corps.Count -eq 0) { continue }
    $attente = if ($regarde) { Get-Pas $pas } else { 25 }
    $reste = ($fin - (Get-Date)).TotalSeconds
    if ($reste -le $attente) { break }
    Start-Sleep -Seconds $attente
}

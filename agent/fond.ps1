<#
  Le fond d'état d'un poste. Installé par `pilote.ps1` dans
  C:\ProgramData\PointeNoire\fond, lancé dans la session de chaque compte
  ouvert par la tâche PointeNoire-Fond (groupe Utilisateurs, à l'ouverture de
  session, toutes les 15 minutes, et après chaque commande du pilote), par
  lanceur.vbs : aucune fenêtre ne s'ouvre, même un instant. Compatible
  Windows PowerShell 5.1, sans droit d'administrateur.

  Écran principal : la référence, les cartes réseau (IP, profil), le mode
  événement partie par partie, le nettoyage, la sonde, la dernière commande.
  Couleur : gris normal, orange mode événement partiel, rouge complet.
  Autres écrans : noir uni, rien ne part vers un projecteur ou un mur LED.
  Partie « fond » du mode événement : tout noir, la référence en petit.

  Le fond d'origine de chaque écran est gardé dans
  %LOCALAPPDATA%\PointeNoire\fond-avant.json et rendu quand le pilote retire
  le fond (`retire` dans etat.json), avec Windows à la une, coupé entre-temps.
  Bilan de chaque passage : fond-resultat.json, relu par fond-pose.ps1.

  -Detail : la page « État du poste » (icône du Bureau public), en local.
#>
param([switch]$Detail)

$ErrorActionPreference = 'Stop'
# Avant tout : Get-Ton en a besoin, même pour -Detail.
Add-Type -AssemblyName System.Drawing
$base = Join-Path $env:ProgramData 'PointeNoire'
$etatFond = Join-Path $base 'fond\etat.json'
$perso = Join-Path $env:LOCALAPPDATA 'PointeNoire'
$avantFichier = Join-Path $perso 'fond-avant.json'
$resultatFichier = Join-Path $perso 'fond-resultat.json'
$cleFonds = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers'
$cleUne = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\DesktopSpotlight\Settings'
$parties = [ordered]@{ windows_update = 'Windows Update en pause'; veille = 'Veille coupée'; notifications = 'Notifications coupées'; conseils = 'Conseils Windows coupés'; fond = 'Fond noir' }

function Read-Json([string]$Chemin) {
    if (-not (Test-Path $Chemin)) { return $null }
    try { Get-Content -Raw -Encoding UTF8 -Path $Chemin | ConvertFrom-Json } catch { $null }
}

function Get-Etat {
    $f = Read-Json $etatFond
    $e = Read-Json (Join-Path $base 'mode-evenement.json')
    $actives = @()
    if ($e) { $actives = @($e.parties); if (-not $actives.Count) { $actives = @('windows_update', 'veille', 'notifications') } }
    $wu = $null
    try { $wu = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' -Name PauseUpdatesExpiryTime -ErrorAction Stop).PauseUpdatesExpiryTime } catch { }
    $n = Read-Json (Join-Path $base 'nettoyage.json')
    $cartes = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up' | Sort-Object Name | ForEach-Object {
        $ip = @(Get-NetIPAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike '169.254.*' } | ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength)" })
        $profil = @{ Public = 'Public'; Private = 'Privé'; DomainAuthenticated = 'Domaine' }[[string](Get-NetConnectionProfile -InterfaceIndex $_.ifIndex -ErrorAction SilentlyContinue).NetworkCategory]
        $gw = @(Get-NetRoute -InterfaceIndex $_.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1).NextHop
        [pscustomobject]@{ nom = $_.Name; vitesse = $_.LinkSpeed; ip = ($ip -join ', '); profil = [string]$profil; passerelle = $gw; filaire = ($_.PhysicalMediaType -eq '802.3') }
    })
    $mesh = Get-Service -Name 'Mesh Agent' -ErrorAction SilentlyContinue
    $ref = $env:COMPUTERNAME
    if ($f -and $f.reference) { $ref = [string]$f.reference }
    [pscustomobject]@{
        reference = $ref; machine = $env:COMPUTERNAME; actives = $actives; depuis = $(if ($e) { $e.depuis } else { $null }); wu = $wu
        nettoyage = $(if ($n) { $n.depuis } else { $null }); sonde = ($f -and $f.sonde); derniere = $(if ($f) { $f.derniere } else { $null })
        cartes = $cartes; mesh = $(if ($mesh) { [string]$mesh.Status } else { 'absent' }); retire = ($f -and $f.retire)
    }
}

function Get-Valeur([string]$Cle, [string]$Nom) {
    try { (Get-ItemProperty -Path $Cle -Name $Nom -ErrorAction Stop).$Nom } catch { $null }
}

function Write-Resultat([bool]$Ok, [string]$Texte) {
    if (-not (Test-Path $perso)) { New-Item -ItemType Directory -Path $perso -Force | Out-Null }
    $r = [ordered]@{ le = (Get-Date).ToString('o'); ok = $Ok; detail = $Texte }
    [IO.File]::WriteAllText($resultatFichier, ($r | ConvertTo-Json), (New-Object System.Text.UTF8Encoding $false))
}

function Get-Date2($Texte) {
    try { ([datetime]$Texte).ToString('dd/MM HH:mm') } catch { [string]$Texte }
}

function Get-Lignes($s) {
    $l = New-Object System.Collections.Generic.List[string]
    foreach ($c in $s.cartes) {
        $txt = "$($c.nom) : $(if ($c.ip) { $c.ip } else { 'pas d''adresse' })"
        if ($c.profil) { $txt += " · $($c.profil)" }
        if ($c.vitesse) { $txt += " · $($c.vitesse)" }
        $l.Add($txt)
    }
    if (-not $s.cartes.Count) { $l.Add('Aucune carte réseau connectée') }
    if ($s.actives.Count) {
        foreach ($k in $parties.Keys) {
            $t = $parties[$k]
            if ($k -eq 'windows_update' -and $s.wu) { $t += " jusqu'au $(Get-Date2 $s.wu)" }
            $l.Add($(if ($s.actives -contains $k) { "■ $t" } else { "□ $($t -replace ' (en pause|coupée?s?|noir)$', '') : normal" }))
        }
    } else { $l.Add('Mode événement : inactif') }
    if ($s.nettoyage) { $l.Add("Nettoyé le $(Get-Date2 $s.nettoyage)") }
    $l.Add($(if ($s.sonde) { 'Supervision : active' } else { 'Supervision : non' }))
    $l.Add("Agent MeshCentral : $(@{ Running = 'actif'; Stopped = 'arrêté'; absent = 'absent' }[$s.mesh])")
    if ($s.derniere) { $l.Add("Dernière commande : $($s.derniere.texte) ($(Get-Date2 $s.derniere.le))") }
    $l.Add("Mis à jour le $((Get-Date).ToString('dd/MM HH:mm'))")
    $l
}

function Get-Ton($s) {
    if (-not $s.actives.Count) { return @('Normal', [Drawing.Color]::FromArgb(58, 62, 68)) }
    $completes = @('windows_update', 'veille', 'notifications', 'conseils' | Where-Object { $s.actives -contains $_ })
    if ($completes.Count -eq 4) { return @('Mode événement', [Drawing.Color]::FromArgb(150, 30, 30)) }
    @('Mode événement partiel', [Drawing.Color]::FromArgb(176, 96, 0))
}

# --- La page « État du poste » -------------------------------------------------

if ($Detail) {
    $s = Get-Etat
    $ton = Get-Ton $s
    $h = { param($t) [Net.WebUtility]::HtmlEncode([string]$t) }
    $c = $ton[1]
    $lignes = (Get-Lignes $s | ForEach-Object { "<li>$(& $h $_)</li>" }) -join ''
    $cartes = ($s.cartes | ForEach-Object { "<tr><td>$(& $h $_.nom)</td><td>$(& $h $_.ip)</td><td>$(& $h $_.passerelle)</td><td>$(& $h $_.profil)</td><td>$(& $h $_.vitesse)</td><td>$(if ($_.filaire) { 'filaire' } else { 'sans fil' })</td></tr>" }) -join ''
    $html = @"
<!doctype html><html lang="fr"><meta charset="utf-8"><title>État du poste $(& $h $s.reference)</title>
<style>body{font:15px Segoe UI,sans-serif;margin:24px;background:#111;color:#eee}h1{margin:0 0 4px}.b{display:inline-block;padding:4px 10px;border-radius:4px;background:rgb($($c.R),$($c.G),$($c.B))}td,th{padding:4px 10px;text-align:left;border-bottom:1px solid #333}li{margin:3px 0}</style>
<h1>$(& $h $s.reference)</h1><p>$(& $h $s.machine) · <span class="b">$(& $h $ton[0])</span></p>
<ul>$lignes</ul><h2>Cartes réseau</h2><table><tr><th>Carte</th><th>IPv4</th><th>Passerelle</th><th>Profil</th><th>Débit</th><th>Type</th></tr>$cartes</table>
<p style="color:#888">Les commandes se donnent depuis AVDiagram, Parc, Postes. Ce poste ne change rien de lui-même.</p></html>
"@
    if (-not (Test-Path $perso)) { New-Item -ItemType Directory -Path $perso -Force | Out-Null }
    $page = Join-Path $perso 'etat-poste.html'
    [IO.File]::WriteAllText($page, $html, (New-Object System.Text.UTF8Encoding $true))
    Start-Process $page
    return
}

# --- Le fond, écran par écran --------------------------------------------------

try {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace PointeNoire {
  [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
  [ComImport, Guid("B92B56A9-8B55-4E14-9A89-0199BBB6F93B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface IDesktopWallpaper {
    void SetWallpaper([MarshalAs(UnmanagedType.LPWStr)] string monitorID, [MarshalAs(UnmanagedType.LPWStr)] string wallpaper);
    [return: MarshalAs(UnmanagedType.LPWStr)] string GetWallpaper([MarshalAs(UnmanagedType.LPWStr)] string monitorID);
    [return: MarshalAs(UnmanagedType.LPWStr)] string GetMonitorDevicePathAt(uint monitorIndex);
    uint GetMonitorDevicePathCount();
    Rect GetMonitorRECT([MarshalAs(UnmanagedType.LPWStr)] string monitorID);
    void SetBackgroundColor(uint color);
    uint GetBackgroundColor();
    void SetPosition(int position);
    int GetPosition();
  }
  [ComImport, Guid("C2CF3110-460E-4fc1-B9D0-8A1C0C9CC4BD")] public class DesktopWallpaperClass { }
  public class Ecran { public string Id; public int Gauche, Haut, Largeur, Hauteur; }
  // PowerShell n'appelle pas une interface COM sans IDispatch : tout passe par ici.
  public static class Ecrans {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    static IDesktopWallpaper F() { return (IDesktopWallpaper)new DesktopWallpaperClass(); }
    public static Ecran[] Liste() {
      IDesktopWallpaper w = F();
      var l = new System.Collections.Generic.List<Ecran>();
      uint n = w.GetMonitorDevicePathCount();
      for (uint i = 0; i < n; i++) {
        string id = w.GetMonitorDevicePathAt(i);
        // Un écran déclaré mais éteint n'a pas de rectangle.
        try { Rect r = w.GetMonitorRECT(id); l.Add(new Ecran { Id = id, Gauche = r.Left, Haut = r.Top, Largeur = r.Right - r.Left, Hauteur = r.Bottom - r.Top }); } catch (Exception) { }
      }
      return l.ToArray();
    }
    public static string Lire(string id) { try { return F().GetWallpaper(id) ?? ""; } catch (Exception) { return ""; } }
    public static void Poser(string id, string chemin) { F().SetWallpaper(id, chemin); }
    public static int Position() { return F().GetPosition(); }
    public static void Placer(int position) { F().SetPosition(position); }
  }
}
'@
[void][PointeNoire.Ecrans]::SetProcessDPIAware()
$ecrans = @([PointeNoire.Ecrans]::Liste() | ForEach-Object { [pscustomobject]@{ id = $_.Id; l = $_.Largeur; h = $_.Hauteur; principal = ($_.Gauche -eq 0 -and $_.Haut -eq 0) } })
if (-not (Test-Path $perso)) { New-Item -ItemType Directory -Path $perso -Force | Out-Null }
$s = Get-Etat
$bilan = $null

if (-not $ecrans.Count) {
    $bilan = 'aucun écran actif dans cette session, rien à changer'
} elseif ($s.retire) {
    $avant = Read-Json $avantFichier
    if ($avant) {
        foreach ($e in $ecrans) {
            $f = ($avant.ecrans | Where-Object id -eq $e.id | Select-Object -First 1).fond
            if (-not $f) { $f = $avant.defaut }
            if ($f -and (Test-Path $f)) { [PointeNoire.Ecrans]::Poser($e.id, $f) }
        }
        [PointeNoire.Ecrans]::Placer([int]$avant.position)
        # Windows à la une, s'il était là avant le fond d'état.
        if ($null -ne $avant.une -and (Test-Path $cleUne)) { Set-ItemProperty -Path $cleUne -Name EnabledState -Value ([int]$avant.une) -Type DWord }
        if ($null -ne $avant.type) { Set-ItemProperty -Path $cleFonds -Name BackgroundType -Value ([int]$avant.type) -Type DWord }
        Remove-Item $avantFichier -Force
        $bilan = 'fond d''origine rendu'
    } else { $bilan = 'pas de fond d''état dans cette session' }
    Get-ChildItem $perso -Filter 'fond-*.png' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
} else {

# Le fond d'origine, une seule fois : c'est lui que le retrait rend.
$type0 = Get-Valeur $cleFonds 'BackgroundType'
$une0 = Get-Valeur $cleUne 'EnabledState'
$ecrase = 0
if (-not (Test-Path $avantFichier)) {
    $garde = @($ecrans | ForEach-Object { [ordered]@{ id = $_.id; fond = [PointeNoire.Ecrans]::Lire($_.id) } })
    $defaut = (Get-ItemProperty 'HKCU:\Control Panel\Desktop' -Name WallPaper -ErrorAction SilentlyContinue).WallPaper
    $avant = [ordered]@{ ecrans = $garde; defaut = $defaut; position = [PointeNoire.Ecrans]::Position(); type = $type0; une = $une0 }
    [IO.File]::WriteAllText($avantFichier, ($avant | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding $false))
} else {
    # Gardé par une version sans le type de fond : complété.
    $avant = Read-Json $avantFichier
    if ($avant -and $avant.PSObject.Properties.Name -notcontains 'type') {
        $avant | Add-Member -NotePropertyName type -NotePropertyValue $type0
        $avant | Add-Member -NotePropertyName une -NotePropertyValue $une0
        [IO.File]::WriteAllText($avantFichier, ($avant | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding $false))
    }
    # Déjà affiché une fois : un écran qui n'a plus notre image, Windows l'a remplacée.
    if (Get-ChildItem $perso -Filter 'fond-*.png' -ErrorAction SilentlyContinue) {
        $ecrase = @($ecrans | Where-Object { [IO.Path]::GetFileName([PointeNoire.Ecrans]::Lire($_.id)) -notlike 'fond-*.png' }).Count
    }
}

# Windows à la une remet sinon sa photo par-dessus : coupé le temps du fond d'état.
$aLaUne = ($type0 -eq 3) -or ($une0 -eq 1)
if ($aLaUne) {
    if ($une0 -eq 1) { Set-ItemProperty -Path $cleUne -Name EnabledState -Value 0 -Type DWord }
    if (-not (Test-Path $cleFonds)) { New-Item -Path $cleFonds -Force | Out-Null }
    Set-ItemProperty -Path $cleFonds -Name BackgroundType -Value 0 -Type DWord
}

$noir = $s.actives -contains 'fond'
$ton = Get-Ton $s
$horodate = (Get-Date).ToString('yyyyMMddHHmmss')
$images = @()
$rang = 0
foreach ($e in $ecrans) {
    $l = [Math]::Max(640, $e.l); $h = [Math]::Max(480, $e.h)
    $bmp = New-Object Drawing.Bitmap $l, $h
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.TextRenderingHint = [Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $g.Clear([Drawing.Color]::Black)
    if ($e.principal) {
        $k = $h / 1080
        if ($noir) {
            # En direct : la référence seule, à peine lisible de près.
            $p = New-Object Drawing.Font 'Segoe UI', ([float](11 * $k))
            $g.DrawString($s.reference, $p, (New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(70, 70, 70))), [float]($l - 140 * $k), [float]($h - 70 * $k))
        } else {
            $titre = New-Object Drawing.Font 'Segoe UI Semibold', ([float](34 * $k))
            $etiquette = New-Object Drawing.Font 'Segoe UI Semibold', ([float](15 * $k))
            $texte = New-Object Drawing.Font 'Segoe UI', ([float](13 * $k))
            $lignes = @(Get-Lignes $s)
            $pl = [float](560 * $k); $ph = [float]((110 + 24 * $lignes.Count) * $k)
            $x = [float]($l - $pl - 40 * $k); $y = [float]($h - $ph - 80 * $k)
            $g.FillRectangle((New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(235, 22, 24, 28))), $x, $y, $pl, $ph)
            $g.FillRectangle((New-Object Drawing.SolidBrush $ton[1]), $x, $y, [float](8 * $k), $ph)
            $blanc = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(235, 235, 235))
            $gris = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(170, 170, 170))
            $g.DrawString($s.reference, $titre, $blanc, [float]($x + 24 * $k), [float]($y + 14 * $k))
            $g.FillRectangle((New-Object Drawing.SolidBrush $ton[1]), [float]($x + 24 * $k), [float]($y + 72 * $k), [float](230 * $k), [float](26 * $k))
            $g.DrawString($ton[0], $etiquette, $blanc, [float]($x + 30 * $k), [float]($y + 73 * $k))
            $yy = $y + 108 * $k
            foreach ($ligne in $lignes) { $g.DrawString($ligne, $texte, $(if ($ligne.StartsWith('■')) { $blanc } else { $gris }), [float]($x + 24 * $k), [float]$yy); $yy += 24 * $k }
        }
    }
    $g.Dispose()
    $chemin = Join-Path $perso "fond-$rang-$horodate.png"
    $rang++
    $bmp.Save($chemin, [Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    $images += $chemin
    [PointeNoire.Ecrans]::Poser($e.id, $chemin)
}
# 4 : remplir l'écran (DWPOS_FILL).
[PointeNoire.Ecrans]::Placer(4)
Get-ChildItem $perso -Filter 'fond-*.png' | Where-Object { $images -notcontains $_.FullName } | Remove-Item -Force -ErrorAction SilentlyContinue
# La preuve : ce que Windows affiche vraiment, relu écran par écran.
$noms = @($images | ForEach-Object { [IO.Path]::GetFileName($_) })
$refuses = @($ecrans | Where-Object { $noms -notcontains [IO.Path]::GetFileName([PointeNoire.Ecrans]::Lire($_.id)) }).Count
if ($refuses) { throw "Windows n'a pas pris le fond sur $refuses écran(s) sur $($ecrans.Count)" }
$bilan = "affiché sur $($ecrans.Count) écran(s)"
# Un fond image ne vaut que pour le bureau virtuel actif.
$bureaux = Get-Valeur 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VirtualDesktops' 'VirtualDesktopIDs'
if ($bureaux -and $bureaux.Length -ge 32) { $bilan += ", sur le bureau virtuel actif seulement ($([int]($bureaux.Length / 16)) bureaux)" }
if ($aLaUne) { $bilan += ', Windows à la une coupé jusqu''au retrait' }
if ($ecrase) { $bilan += ", remis sur $ecrase écran(s) où Windows l'avait remplacé" }
}
Write-Resultat $true $bilan
} catch {
    Write-Resultat $false "$($_.Exception.Message) (fond.ps1, ligne $($_.InvocationInfo.ScriptLineNumber))"
}

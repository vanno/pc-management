<#
  Le relevé du mode événement : ce qu'un technicien du direct vérifie avant de
  lancer, lu sur le poste sans droit d'administrateur, en quelques secondes.
  Posé par fond-pose.ps1 à côté de fond.ps1 (C:\ProgramData\PointeNoire\fond),
  qui le charge : Get-Releve pour l'écran du mode événement et la page « État
  du poste », Show-Evenement pour dessiner l'écran principal. Compatible
  Windows PowerShell 5.1.

  Réseau (câble, adresse, profil pour NDI, passerelle, internet, port RTMP),
  machine (secteur, mode d'alimentation, disques, mémoire, redémarrage
  attendu), écrans et son (définition et fréquence réelles, appareils par
  défaut), logiciels du direct lancés ou non, services, protections du mode
  relues dans la session, dernières actions. Chaque ligne a son niveau (ok,
  neutre, attention, alerte) ; ce qui demande d'agir remonte dans « À vérifier ».
#>

# Ce que le relevé cherche sur le poste : nom affiché, nom dans « Applications
# installées », processus quand on sait les reconnaître (sinon le dossier
# d'installation suffit à dire « lancé »).
$logiciels = @(
    @('vMix', '^vMix', 'vMix64|vMix'),
    @('OBS Studio', '^OBS Studio', 'obs64|obs32'),
    @('Companion', '^(Bitfocus )?Companion', 'Companion'),
    @('ATEM Software Control', 'ATEM (Switchers|Software)', 'ATEM Software Control'),
    @('NDI Tools', '^NDI \d* ?Tools', ''),
    @('Dante Virtual Soundcard', '^Dante Virtual Soundcard', ''),
    @('Pilote Blackmagic', 'Blackmagic Desktop Video|^Desktop Video', '')
)
$pasCoupe = [ordered]@{ windows_update = 'Windows Update pas en pause'; veille = 'Veille pas coupée'; notifications = 'Notifications pas coupées'; conseils = 'Conseils Windows pas coupés' }

# Les écrans (mode réel : définition et fréquence) et le son par défaut.
$codeReleve = @"
using System;
using System.Runtime.InteropServices;
namespace PointeNoire {
  public static class Releve {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    internal struct Peripherique { public int cb; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string Nom; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Texte; public int Etat; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Id; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Cle; }
    // DEVMODEW, 220 octets : seuls la taille, la définition et la fréquence servent.
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    internal struct Mode { [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string a; public short b, c, Taille, d; public int e, f, g, h, i; public short j, k, l, m, n; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string o; public short p; public int q, Largeur, Hauteur, r, Frequence, s1, s2, s3, s4, s5, s6, s7, s8; }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplayDevices(string device, uint i, ref Peripherique p, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplaySettings(string device, int mode, ref Mode m);
    // « largeur|hauteur|fréquence|principal » pour chaque écran du Bureau.
    public static string[] Ecrans() {
      var l = new System.Collections.Generic.List<string>();
      for (uint i = 0; i < 16; i++) {
        var p = new Peripherique(); p.cb = Marshal.SizeOf(typeof(Peripherique));
        if (!EnumDisplayDevices(null, i, ref p, 0)) break;
        if ((p.Etat & 1) == 0) continue;
        var m = new Mode(); m.Taille = (short)Marshal.SizeOf(typeof(Mode));
        if (!EnumDisplaySettings(p.Nom, -1, ref m)) continue;
        l.Add(m.Largeur + "|" + m.Hauteur + "|" + m.Frequence + "|" + ((p.Etat & 4) != 0 ? "1" : "0"));
      }
      return l.ToArray();
    }
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] internal class Enumerateur { }
    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IEnumerateur { [PreserveSig] int EnumAudioEndpoints(int flux, int etats, out IntPtr liste); [PreserveSig] int GetDefaultAudioEndpoint(int flux, int role, out IAppareil appareil); }
    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAppareil { [PreserveSig] int Activate(ref Guid iid, int ctx, IntPtr p, out IntPtr o); [PreserveSig] int OpenPropertyStore(int acces, out IProprietes p); }
    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IProprietes { [PreserveSig] int GetCount(out int n); [PreserveSig] int GetAt(int i, out Cle k); [PreserveSig] int GetValue(ref Cle k, out Valeur v); }
    [StructLayout(LayoutKind.Sequential)] internal struct Cle { public Guid fmtid; public int pid; }
    // PROPVARIANT : 24 octets en 64 bits, 16 en 32 bits ; le plus grand des deux.
    [StructLayout(LayoutKind.Explicit, Size = 24)] internal struct Valeur { [FieldOffset(0)] public short vt; [FieldOffset(8)] public IntPtr p; }
    [DllImport("ole32.dll")] static extern int PropVariantClear(ref Valeur v);
    // Le nom de l'appareil son par défaut : 0 sortie, 1 entrée. Vide sans appareil.
    public static string Son(int flux) {
      try {
        var en = (IEnumerateur)new Enumerateur();
        IAppareil a; IProprietes pr; Valeur v;
        if (en.GetDefaultAudioEndpoint(flux, 0, out a) != 0 || a == null) return "";
        if (a.OpenPropertyStore(0, out pr) != 0 || pr == null) return "";
        var k = new Cle { fmtid = new Guid("A45C254E-DF1C-4EFD-8020-67D146A850E0"), pid = 14 };
        if (pr.GetValue(ref k, out v) != 0) return "";
        string nom = v.vt == 31 ? Marshal.PtrToStringUni(v.p) : "";
        PropVariantClear(ref v);
        return nom ?? "";
      } catch (Exception) { return ""; }
    }
  }
}
"@

function New-Ligne([string]$Texte, [string]$Niveau = 'neutre') { [pscustomobject]@{ t = $Texte; n = $Niveau } }

function Get-Adresse([string]$Hote) {
    try { $r = [Net.Dns]::BeginGetHostAddresses($Hote, $null, $null); if ($r.AsyncWaitHandle.WaitOne(2000)) { return @([Net.Dns]::EndGetHostAddresses($r) | Where-Object { $_.AddressFamily -eq 'InterNetwork' })[0] } } catch { }
    $null
}

# Les millisecondes d'une connexion TCP, $null si elle n'aboutit pas en 1,5 seconde.
function Test-Tcp($Adresse, [int]$Port) {
    if (-not $Adresse) { return $null }
    $c = New-Object Net.Sockets.TcpClient
    try {
        $w = [Diagnostics.Stopwatch]::StartNew()
        $a = $c.BeginConnect([Net.IPAddress]$Adresse, $Port, $null, $null)
        if ($a.AsyncWaitHandle.WaitOne(1500) -and $c.Connected) { return [int]$w.ElapsedMilliseconds }
    } catch { } finally { $c.Close() }
    $null
}

function Get-Ping([string]$Hote) {
    try { $p = New-Object Net.NetworkInformation.Ping; foreach ($i in 1..2) { $r = $p.Send($Hote, 1000); if ($r.Status -eq 'Success') { return [int]$r.RoundtripTime } } } catch { }
    $null
}

function Get-Go([double]$Octets) { '{0:N0} Go' -f ($Octets / 1GB) }

# Section par section, chaque ligne avec son niveau (ok, neutre, attention,
# alerte) ; ce qui demande d'agir remonte aussi dans « À vérifier ». Tout se
# lit sans droit d'administrateur, en quelques secondes.
function Get-Releve($s) {
    $r = [pscustomobject]@{ alertes = New-Object System.Collections.Generic.List[object]; sections = [ordered]@{} }
    function Add-Ligne([string]$Section, [string]$Texte, [string]$Niveau = 'neutre', [string]$Alerte) {
        if (-not $r.sections.Contains($Section)) { $r.sections[$Section] = New-Object System.Collections.Generic.List[object] }
        $r.sections[$Section].Add((New-Ligne $Texte $Niveau))
        if ($Alerte) { $r.alertes.Add((New-Ligne $Alerte $Niveau)) }
    }

    # Réseau : le câble, l'adresse, le profil (NDI), la passerelle, internet, RTMP.
    $cartes = @($s.cartes)
    if (-not $cartes.Count) { Add-Ligne 'Réseau' 'Aucune carte réseau connectée' 'alerte' 'Aucune carte réseau connectée' }
    foreach ($c in $cartes) {
        Add-Ligne 'Réseau' "$($c.nom) · $(if ($c.filaire) { 'câble' } else { 'Wi-Fi' }) · $($c.vitesse)"
        if (-not $c.ip) { Add-Ligne 'Réseau' 'Pas d''adresse IP' 'alerte' "$($c.nom) : pas d'adresse IP" }
        else { Add-Ligne 'Réseau' "$($c.ip)$(if ($c.passerelle) { " · passerelle $($c.passerelle)" })" }
        if ($c.profil -eq 'Public') { Add-Ligne 'Réseau' 'Profil Public : NDI souvent bloqué' 'attention' "$($c.nom) en profil Public : NDI risque de ne pas voir les autres postes" }
        elseif ($c.profil) { Add-Ligne 'Réseau' "Profil $($c.profil)" 'ok' }
        if ($c.filaire -and [string]$c.vitesse -match '^(\d+) Mbps$' -and [int]$Matches[1] -lt 1000) { $r.alertes.Add((New-Ligne "$($c.nom) à $($c.vitesse) : câble ou port à vérifier" 'attention')) }
    }
    if ($cartes.Count -and -not @($cartes | Where-Object { $_.filaire }).Count) { $r.alertes.Add((New-Ligne 'Wi-Fi seulement : un câble est plus sûr pour le direct' 'attention')) }
    $gw = @($cartes | Where-Object { $_.passerelle } | Select-Object -First 1)
    if ($gw.Count) {
        $ms = Get-Ping $gw[0].passerelle
        if ($null -ne $ms) { Add-Ligne 'Réseau' "Passerelle : répond en $ms ms" 'ok' } else { Add-Ligne 'Réseau' 'Passerelle : ne répond pas au ping' 'attention' 'La passerelle ne répond pas au ping' }
    }
    if ($cartes.Count) {
        $ip = Get-Adresse 'www.google.com'
        $ms = Test-Tcp $ip 443
        if ($null -ne $ms) {
            Add-Ligne 'Réseau' "Internet : joignable en $ms ms" 'ok'
            if ($null -ne (Test-Tcp (Get-Adresse 'a.rtmp.youtube.com') 1935)) { Add-Ligne 'Réseau' 'RTMP (port 1935) : ouvert' 'ok' }
            else { Add-Ligne 'Réseau' 'RTMP (port 1935) : bloqué' 'attention' 'Port RTMP 1935 bloqué : diffuser en RTMPS (443)' }
        } elseif (-not $ip -and $null -ne (Test-Tcp '1.1.1.1' 443)) { Add-Ligne 'Réseau' 'Internet : joignable, DNS en panne' 'alerte' 'Le DNS ne répond pas : les adresses par nom échouent' }
        else { Add-Ligne 'Réseau' 'Internet : injoignable' 'alerte' 'Internet injoignable' }
    }

    # Machine : secteur, mode d'alimentation, disques, mémoire, redémarrage attendu.
    $bat = @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
    if (-not $bat.Count) { Add-Ligne 'Machine' 'Alimentation : secteur' 'ok' }
    elseif ($bat[0].BatteryStatus -eq 1) { Add-Ligne 'Machine' "Sur batterie : $($bat[0].EstimatedChargeRemaining) %" 'alerte' "Sur batterie ($($bat[0].EstimatedChargeRemaining) %) : brancher le secteur" }
    else { Add-Ligne 'Machine' "Secteur · batterie $($bat[0].EstimatedChargeRemaining) %" 'ok' }
    # Le nom du mode par WMI : la sortie de powercfg n'a pas le même encodage partout.
    $plan = [string](@(Get-CimInstance -Namespace root\cimv2\power -ClassName Win32_PowerPlan -Filter 'IsActive=True' -ErrorAction SilentlyContinue)[0].ElementName)
    if ($plan) { if ($plan -match 'conomi|saver') { Add-Ligne 'Machine' "Alimentation : $plan" 'attention' "Mode d'alimentation « $plan » : le poste se bride" } else { Add-Ligne 'Machine' "Alimentation : $plan" } }
    foreach ($d in @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3 OR DriveType=2' -ErrorAction SilentlyContinue | Where-Object { $_.Size -gt 0 })) {
        $pc = [int](100 * $d.FreeSpace / $d.Size)
        $n = $(if ($pc -lt 10) { 'alerte' } elseif ($pc -lt 20) { 'attention' } else { 'ok' })
        Add-Ligne 'Machine' "Disque $($d.DeviceID)$(if ($d.DriveType -eq 2) { ' (amovible)' }) $(Get-Go $d.FreeSpace) libres sur $(Get-Go $d.Size)" $n $(if ($n -ne 'ok') { "Disque $($d.DeviceID) presque plein : $pc % libres" })
    }
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    if ($os) {
        Add-Ligne 'Machine' ('Mémoire : {0:N1} Go libres sur {1:N0}' -f ($os.FreePhysicalMemory / 1MB), ($os.TotalVisibleMemorySize / 1MB))
        $u = (Get-Date) - $os.LastBootUpTime
        Add-Ligne 'Machine' "Allumé depuis $(if ($u.Days) { "$($u.Days) j " })$($u.Hours) h $('{0:00}' -f $u.Minutes)"
    }
    if ((Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')) {
        Add-Ligne 'Machine' 'Windows attend un redémarrage' 'attention' 'Windows attend un redémarrage : à faire après le direct'
    }
    foreach ($v in @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Select-Object -First 2)) { Add-Ligne 'Machine' "GPU : $($v.Name)" }

    # Écrans et son : définition et fréquence réelles, appareils son par défaut.
    try {
        if (-not ('PointeNoire.Releve' -as [type])) { Add-Type -TypeDefinition $codeReleve }
        $i = 0
        foreach ($e in [PointeNoire.Releve]::Ecrans()) {
            $i++; $v = $e -split '\|'
            $hz = [int]$v[2]
            $t = "Écran $i$(if ($v[3] -eq '1') { ' (principal)' }) : $($v[0]) × $($v[1]) à $hz Hz"
            if ($hz -gt 1 -and $hz -lt 50) { Add-Ligne 'Écrans et son' $t 'attention' "Écran $i à $hz Hz : l'image saccade, passer en 50 ou 60 Hz" } else { Add-Ligne 'Écrans et son' $t }
        }
        foreach ($f in @(@(0, 'Sortie son'), @(1, 'Entrée son'))) {
            $nom = [PointeNoire.Releve]::Son($f[0])
            if ($nom) { Add-Ligne 'Écrans et son' "$($f[1]) : $nom" } else { Add-Ligne 'Écrans et son' "$($f[1]) : aucune" 'attention' "Aucune $($f[1].ToLower()) par défaut" }
        }
    } catch { Add-Ligne 'Écrans et son' 'Relevé des écrans impossible' 'attention' }

    # Logiciels du direct : installés, et lancés ou non.
    $installes = @(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName })
    $procs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Select-Object Name, ExecutablePath)
    foreach ($a in $logiciels) {
        $x = @($installes | Where-Object { $_.DisplayName -match $a[1] } | Select-Object -First 1)
        if (-not $x.Count) { continue }
        $nom = "$($a[0]) $(([string]$x[0].DisplayVersion -split ' ')[0])".Trim()
        if (-not $a[2]) { Add-Ligne 'Logiciels du direct' "$nom : installé"; continue }
        $dir = ([string]$x[0].InstallLocation).TrimEnd('\')
        $lance = @($procs | Where-Object { $_.Name -match "^($($a[2]))\.exe$" -or ($dir.Length -gt 3 -and $_.ExecutablePath -and $_.ExecutablePath.StartsWith("$dir\", 'OrdinalIgnoreCase')) }).Count
        Add-Ligne 'Logiciels du direct' "$nom : $(if ($lance) { 'lancé' } else { 'pas lancé' })" $(if ($lance) { 'ok' } else { 'neutre' })
    }
    if (-not $r.sections.Contains('Logiciels du direct')) { Add-Ligne 'Logiciels du direct' 'Aucun logiciel du direct reconnu' }

    # Services : prise en main, son, et ceux du matériel de production.
    $sv = @(Get-Service -ErrorAction SilentlyContinue)
    foreach ($x in @(@('Mesh Agent', 'Prise en main à distance', 'alerte'), @('Audiosrv', 'Son Windows', 'alerte'), @('WSearch', 'Recherche Windows', ''))) {
        $o = @($sv | Where-Object { $_.Name -eq $x[0] })
        if (-not $o.Count) { continue }
        if ($o[0].Status -eq 'Running') { Add-Ligne 'Services' "$($x[1]) : en marche" $(if ($x[2]) { 'ok' } else { 'neutre' }) }
        elseif ($x[2]) { Add-Ligne 'Services' "$($x[1]) : arrêté" $x[2] "$($x[1]) : service arrêté" }
        else { Add-Ligne 'Services' "$($x[1]) : arrêté" }
    }
    foreach ($o in @($sv | Where-Object { $_.DisplayName -match '^(Dante|NDI|Blackmagic|AJA|Magewell|Elgato|vMix|Bitfocus)|Bonjour' } | Sort-Object DisplayName | Select-Object -First 6)) {
        if ($o.Status -eq 'Running') { Add-Ligne 'Services' "$($o.DisplayName) : en marche" 'ok' }
        elseif ([string]$o.StartType -eq 'Automatic') { Add-Ligne 'Services' "$($o.DisplayName) : arrêté" 'attention' "$($o.DisplayName) arrêté alors qu'il démarre avec Windows" }
        else { Add-Ligne 'Services' "$($o.DisplayName) : arrêté (à la demande)" }
    }
    Add-Ligne 'Services' "Suivi en direct : $(if ($s.sonde) { 'actif' } else { 'inactif' })" $(if ($s.sonde) { 'ok' } else { 'neutre' })

    # Protections du mode événement, relues ici quand la session le permet.
    foreach ($k in $pasCoupe.Keys) {
        if ($s.actives -notcontains $k) { Add-Ligne 'Protections' $pasCoupe[$k] 'attention' "Mode événement partiel : $($pasCoupe[$k].ToLower())"; continue }
        $t = $parties[$k]
        if ($k -eq 'windows_update' -and $s.wu) { $t += " jusqu'au $(Get-Date2 $s.wu)" }
        if ($k -eq 'notifications' -and (Get-Valeur 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications' 'ToastEnabled') -ne 0) {
            Add-Ligne 'Protections' 'Notifications encore actives ici' 'alerte' 'Notifications encore actives dans cette session'; continue
        }
        if ($k -eq 'veille') {
            $hex = @([regex]::Matches(((& powercfg.exe /q SCHEME_CURRENT SUB_SLEEP STANDBYIDLE) -join ' '), '0x[0-9a-fA-F]{8}') | ForEach-Object { $_.Value })
            if ($hex.Count -ge 2 -and [Convert]::ToInt64($hex[-2], 16) -gt 0) { Add-Ligne 'Protections' "Veille encore à $([int]([Convert]::ToInt64($hex[-2], 16) / 60)) min" 'alerte' 'La veille est encore programmée sur secteur'; continue }
        }
        Add-Ligne 'Protections' $t 'ok'
    }
    foreach ($a in @($s.historique | Select-Object -First 3)) { Add-Ligne 'Dernières actions' (Get-Action $a) $(if ($a.ok) { 'ok' } else { 'alerte' }) }
    $r
}

# L'écran principal en mode événement : le bandeau jaune, ce qui est à vérifier,
# puis trois colonnes, toujours à la même place.
function Show-Evenement($g, [int]$l, [int]$h, $s, $r, [string]$Libelle) {
    $k = [Math]::Min($h / 1080, $l / 1920)
    $police = { param([float]$t, [bool]$gras) New-Object Drawing.Font $(if ($gras) { 'Segoe UI Semibold' } else { 'Segoe UI' }), ([float]($t * $k)) }
    $pinceau = { param($c) New-Object Drawing.SolidBrush $c }
    $couleur = @{ ok = [Drawing.Color]::FromArgb(120, 205, 145); neutre = [Drawing.Color]::FromArgb(140, 140, 140); attention = [Drawing.Color]::FromArgb(245, 190, 80); alerte = [Drawing.Color]::FromArgb(245, 110, 95) }
    $clair = & $pinceau ([Drawing.Color]::FromArgb(232, 232, 232))
    $fond = & $pinceau ([Drawing.Color]::FromArgb(235, 22, 24, 28))
    $pw = [float]([Math]::Min(1320 * $k, $l - 520 * $k)); $x0 = [float]($l - $pw - 48 * $k); $y = [float](48 * $k); $bas = [float]($h - 96 * $k)
    # Le bandeau : jaune comme dans AVDiagram.
    $g.FillRectangle((& $pinceau ([Drawing.Color]::FromArgb(245, 197, 24))), $x0, $y, $pw, [float](132 * $k))
    $encre = & $pinceau ([Drawing.Color]::FromArgb(20, 20, 20))
    $g.DrawString($Libelle, (& $police 52 $true), $encre, [float]($x0 + 28 * $k), [float]($y + 10 * $k))
    $ref = & $police 40 $true
    $g.DrawString($s.reference, $ref, $encre, [float]($x0 + $pw - 28 * $k - $g.MeasureString($s.reference, $ref).Width), [float]($y + 18 * $k))
    $sous = "$(if ($s.depuis) { "Depuis le $(Get-Date2 $s.depuis) · " })relevé à $((Get-Date).ToString('HH:mm')), toutes les 15 minutes"
    $g.DrawString($sous, (& $police 19 $false), $encre, [float]($x0 + 30 * $k), [float]($y + 88 * $k))
    $y += 132 * $k + 14 * $k
    # À vérifier : ce qui demande d'agir, sinon une ligne verte.
    $lignes = @($r.alertes | Select-Object -First 6)
    if (-not $lignes.Count) { $lignes = @(New-Ligne 'Aucun point à vérifier dans ce relevé' 'ok') }
    $texte = & $police 20 $false
    $haut = [float]((22 + 32 * $lignes.Count + 10) * $k)
    $g.FillRectangle($fond, $x0, $y, $pw, $haut)
    $pire = $(if (@($lignes | Where-Object { $_.n -eq 'alerte' }).Count) { 'alerte' } elseif (@($lignes | Where-Object { $_.n -eq 'attention' }).Count) { 'attention' } else { 'ok' })
    $g.FillRectangle((& $pinceau $couleur[$pire]), $x0, $y, [float](8 * $k), $haut)
    $g.DrawString($(if ($pire -eq 'ok') { 'TOUT EST EN PLACE' } else { 'À VÉRIFIER' }), (& $police 14 $true), (& $pinceau $couleur[$pire]), [float]($x0 + 28 * $k), [float]($y + 10 * $k))
    $yy = $y + 34 * $k
    foreach ($ligne in $lignes) {
        $g.FillEllipse((& $pinceau $couleur[$ligne.n]), [float]($x0 + 30 * $k), [float]($yy + 9 * $k), [float](11 * $k), [float](11 * $k))
        $g.DrawString((Get-Ajuste $g $ligne.t $texte ($pw - 80 * $k)), $texte, $(if ($ligne.n -eq 'ok') { $clair } else { & $pinceau $couleur[$ligne.n] }), [float]($x0 + 50 * $k), [float]$yy)
        $yy += 32 * $k
    }
    $y += $haut + 14 * $k
    # Les colonnes.
    $titre = & $police 14 $true; $ecrit = & $police 18 $false
    $gris = & $pinceau ([Drawing.Color]::FromArgb(160, 160, 160))
    $cw = [float](($pw - 2 * 14 * $k) / 3)
    $colonnes = @(@('Réseau', 'Écrans et son'), @('Machine', 'Services'), @('Logiciels du direct', 'Protections', 'Dernières actions'))
    $g.FillRectangle($fond, $x0, $y, $pw, [float]($bas - $y))
    for ($c = 0; $c -lt 3; $c++) {
        $cx = [float]($x0 + $c * ($cw + 14 * $k) + 22 * $k); $cy = $y + 16 * $k
        foreach ($nom in $colonnes[$c]) {
            if (-not $r.sections.Contains($nom) -or $cy -gt $bas - 60 * $k) { continue }
            $g.DrawString($nom.ToUpper(), $titre, $gris, $cx, [float]$cy)
            $cy += 28 * $k
            foreach ($ligne in $r.sections[$nom]) {
                if ($cy -gt $bas - 34 * $k) { break }
                $g.FillEllipse((& $pinceau $couleur[$ligne.n]), $cx, [float]($cy + 8 * $k), [float](9 * $k), [float](9 * $k))
                $g.DrawString((Get-Ajuste $g $ligne.t $ecrit ($cw - 48 * $k)), $ecrit, $(if ($ligne.n -in 'attention', 'alerte') { & $pinceau $couleur[$ligne.n] } else { $clair }), [float]($cx + 18 * $k), [float]$cy)
                $cy += 27 * $k
            }
            $cy += 18 * $k
        }
    }
}

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
# installées », et le nom exact du processus quand on sait dire « lancé ».
# « vMix » seul : vMix Social et vMix Video Codec sont d'autres produits.
$logiciels = @(
    @('vMix', '^vMix( \d[\d.]*)?$', 'vMix64|vMix'),
    @('OBS Studio', '^OBS Studio', 'obs64|obs32'),
    @('Companion', '^(Bitfocus )?Companion', 'Companion'),
    @('ATEM Software Control', 'ATEM (Switchers|Software)', 'ATEM Software Control'),
    @('NDI Tools', '^NDI \d* ?Tools', ''),
    @('Dante Virtual Soundcard', '^Dante Virtual Soundcard', ''),
    @('Pilote Blackmagic', 'Blackmagic Desktop Video|^Desktop Video', '')
)
$pasCoupe = [ordered]@{ windows_update = 'Windows Update pas en pause'; veille = 'Veille pas coupée'; notifications = 'Notifications pas coupées'; conseils = 'Conseils Windows pas coupés' }
$nomsParties = @{ windows_update = 'Windows Update'; veille = 'veille'; notifications = 'notifications'; conseils = 'conseils Windows' }
# Les mêmes valeurs que pilote.ps1 met à 0 pour couper les conseils.
$valeursConseils = @('SubscribedContent-338389Enabled', 'SubscribedContent-310093Enabled', 'SubscribedContent-338388Enabled', 'SoftLandingEnabled', 'SystemPaneSuggestionsEnabled')
# Les modes d'alimentation de Windows, par leur GUID : le nom affiché par
# powercfg dépend de la langue et de l'encodage de la console.
$plansAlim = @{ 'a1841308-3541-4fab-bc81-f71556f20b4a' = 'Économie d''énergie'; '381b4222-f694-41f0-9685-ff5bb260df2e' = 'Utilisation normale'; '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' = 'Performances élevées'; 'e9a42b02-d5df-448d-aa00-03f14749eb61' = 'Performances optimales' }
# Windows 11, Paramètres > Alimentation > Mode d'alimentation, par-dessus le
# mode choisi : GUID_POWER_MODE_BEST_EFFICIENCY et BEST_PERFORMANCE de
# powrprof.h (zéro ou vide : équilibré).
$modesAlim = @{ '961cc777-2547-4f9d-8174-7d86181b8a7a' = 'meilleure efficacité énergétique'; 'ded574b5-45a0-4f42-8737-46345c09c238' = 'meilleures performances' }

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

# L'adresse publique du poste, vue par Cloudflare (1.1.1.1, sans DNS), $null en 2,5 secondes.
function Get-IpPublique {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $q = [Net.HttpWebRequest]::Create('https://1.1.1.1/cdn-cgi/trace')
        $q.Timeout = 2500; $q.ReadWriteTimeout = 2500
        $rep = $q.GetResponse()
        try { $texte = (New-Object IO.StreamReader $rep.GetResponseStream()).ReadToEnd() } finally { $rep.Close() }
        if ($texte -match '(?m)^ip=([0-9a-fA-F.:]+)') { return $Matches[1] }
    } catch { }
    $null
}

# Une ligne trop longue pour sa colonne passe sur plusieurs, coupée entre deux
# mots, sans laisser un mot seul à la fin ; au-delà de $Lignes, « … ».
function Split-Texte($G, [string]$T, $F, [float]$Max, [int]$Lignes = 3) {
    $mots = @($T -split ' ')
    $i = 0
    while ($i -lt $mots.Count) {
        $Lignes--
        if ($Lignes -le 0) { Get-Ajuste $G ($mots[$i..($mots.Count - 1)] -join ' ') $F $Max; return }
        $n = $i + 1
        while ($n -lt $mots.Count -and $G.MeasureString(($mots[$i..$n] -join ' '), $F).Width -le $Max) { $n++ }
        if ($n -eq $mots.Count - 1 -and $n - $i -gt 2) { $n-- }
        # Ni « · » ni « « » seuls en bout de ligne : ils descendent avec la suite.
        while ($n - $i -gt 1 -and $n -lt $mots.Count -and $mots[$n - 1] -match '^[·«]$') { $n-- }
        Get-Ajuste $G ($mots[$i..($n - 1)] -join ' ') $F $Max
        $i = $n
    }
}

# Relit dans Windows ce qu'une partie du mode événement a coupé, sans se fier
# à ce que le pilote a noté : la pause de Windows Update, la veille et
# l'extinction de l'écran (sur batterie aussi quand il y en a une), les
# notifications et les conseils de cette session. Rend la ligne courte de la
# colonne (t), son niveau (n) et la phrase complète pour « À vérifier » (a).
function Get-Protection([string]$Partie, $s, [bool]$Batterie, [bool]$SurBatterie) {
    $ligne = { param($t, $n, $a) [pscustomobject]@{ t = $t; n = $n; a = $a } }
    switch ($Partie) {
        'windows_update' {
            $fin = $null
            try { if ($s.wu) { $fin = [datetime]$s.wu } } catch { }
            if ($fin -and $fin -gt (Get-Date)) { return & $ligne "Windows Update en pause jusqu'au $($fin.ToString('dd/MM HH:mm'))" 'ok' }
            return & $ligne 'Windows Update pas en pause' 'alerte' 'Windows Update n''est plus en pause'
        }
        'veille' {
            $reste = New-Object System.Collections.Generic.List[string]
            $niveau = 'ok'
            foreach ($x in @(@('SUB_SLEEP', 'STANDBYIDLE', 'veille'), @('SUB_SLEEP', 'HIBERNATEIDLE', 'veille prolongée'), @('SUB_VIDEO', 'VIDEOIDLE', 'écran éteint'))) {
                $hex = @([regex]::Matches(((& powercfg.exe /q SCHEME_CURRENT $x[0] $x[1]) -join ' '), '0x[0-9a-fA-F]{8}') | ForEach-Object { $_.Value })
                if ($hex.Count -lt 2) { continue }
                $ac = [Convert]::ToInt64($hex[-2], 16); $dc = [Convert]::ToInt64($hex[-1], 16)
                if ($ac -gt 0) { $reste.Add("$($x[2]) $([Math]::Ceiling($ac / 60)) min"); $niveau = 'alerte' }
                elseif ($Batterie -and $dc -gt 0) {
                    $reste.Add("$($x[2]) $([Math]::Ceiling($dc / 60)) min sur batterie")
                    if ($SurBatterie) { $niveau = 'alerte' } elseif ($niveau -eq 'ok') { $niveau = 'attention' }
                }
            }
            if (-not $reste.Count) { return & $ligne 'Veille et extinction de l''écran coupées' 'ok' }
            return & $ligne 'Veille encore programmée' $niveau "Encore programmé : $($reste -join ', ')"
        }
        'notifications' {
            $a = Get-Valeur 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications' 'ToastEnabled'
            $b = Get-Valeur 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings' 'NOC_GLOBAL_SETTING_TOASTS_ENABLED'
            if ($a -eq 0 -and $b -eq 0) { return & $ligne 'Notifications coupées' 'ok' }
            return & $ligne 'Notifications actives' 'alerte' 'Notifications encore actives dans cette session'
        }
        'conseils' {
            $cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
            $actifs = @($valeursConseils | Where-Object { (Get-Valeur $cdm $_) -ne 0 })
            if ((Get-Valeur 'HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement' 'ScoobeSystemSettingEnabled') -ne 0) { $actifs += 'ScoobeSystemSettingEnabled' }
            if (-not $actifs.Count) { return & $ligne 'Conseils Windows coupés' 'ok' }
            return & $ligne 'Conseils Windows actifs' 'alerte' 'Conseils et écrans « Tirez le meilleur parti de Windows » encore actifs dans cette session'
        }
    }
}

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
    # La passerelle de la première carte qui en a une : relevée à part, avec son ping.
    $gw = @($cartes | Where-Object { $_.passerelle } | Select-Object -First 1)
    if (-not $cartes.Count) { Add-Ligne 'Réseau' 'Aucune carte réseau connectée' 'alerte' 'Aucune carte réseau connectée' }
    foreach ($c in $cartes) {
        $type = $(if ($c.filaire) { 'câble' } else { 'Wi-Fi' })
        Add-Ligne 'Réseau' "$(if ($c.nom -ne $type) { "$($c.nom) · " })$type · $($c.vitesse)"
        if (-not $c.ip) { Add-Ligne 'Réseau' 'Pas d''adresse IP' 'alerte' "$($c.nom) : pas d'adresse IP" }
        else { Add-Ligne 'Réseau' "IP $($c.ip)$(if ($c.passerelle -and -not ($gw.Count -and $c.passerelle -eq $gw[0].passerelle)) { " · passerelle $($c.passerelle)" })" }
        if ($c.profil -eq 'Public') { Add-Ligne 'Réseau' 'Profil Public : NDI souvent bloqué' 'attention' "$($c.nom) en profil Public : NDI risque de ne pas voir les autres postes" }
        elseif ($c.profil) { Add-Ligne 'Réseau' "Profil $($c.profil)" 'ok' }
        if ($c.filaire -and [string]$c.vitesse -match '^(\d+) Mbps$' -and [int]$Matches[1] -lt 1000) { $r.alertes.Add((New-Ligne "$($c.nom) à $($c.vitesse) : câble ou port à vérifier" 'attention')) }
    }
    if ($cartes.Count -and -not @($cartes | Where-Object { $_.filaire }).Count) { $r.alertes.Add((New-Ligne 'Wi-Fi seulement : un câble est plus sûr pour le direct' 'attention')) }
    if ($gw.Count) {
        $ms = Get-Ping $gw[0].passerelle
        if ($null -ne $ms) { Add-Ligne 'Réseau' "Passerelle $($gw[0].passerelle) : $ms ms" 'ok' } else { Add-Ligne 'Réseau' "Passerelle $($gw[0].passerelle) : pas de réponse" 'attention' "La passerelle $($gw[0].passerelle) ne répond pas au ping" }
    }
    if ($cartes.Count) {
        $ip = Get-Adresse 'www.google.com'
        $ms = Test-Tcp $ip 443
        if ($null -ne $ms) {
            Add-Ligne 'Réseau' "Internet : joignable en $ms ms" 'ok'
            $publique = Get-IpPublique
            if ($publique) { Add-Ligne 'Réseau' "IP publique $publique" }
            if ($null -ne (Test-Tcp (Get-Adresse 'a.rtmp.youtube.com') 1935)) { Add-Ligne 'Réseau' 'RTMP (port 1935) : ouvert' 'ok' }
            else { Add-Ligne 'Réseau' 'RTMP (port 1935) : bloqué' 'attention' 'Port RTMP 1935 bloqué : diffuser en RTMPS (443)' }
        } elseif (-not $ip -and $null -ne (Test-Tcp '1.1.1.1' 443)) { Add-Ligne 'Réseau' 'Internet : joignable, DNS en panne' 'alerte' 'Le DNS ne répond pas : les adresses par nom échouent' }
        else { Add-Ligne 'Réseau' 'Internet : injoignable' 'alerte' 'Internet injoignable' }
    }

    # Machine : secteur, mode d'alimentation, disques, mémoire, redémarrage attendu.
    $bat = @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
    $surBatterie = $bat.Count -and $bat[0].BatteryStatus -eq 1
    if (-not $bat.Count) { Add-Ligne 'Machine' 'Alimentation : secteur' 'ok' }
    elseif ($surBatterie) { Add-Ligne 'Machine' "Sur batterie : $($bat[0].EstimatedChargeRemaining) %" 'alerte' "Sur batterie ($($bat[0].EstimatedChargeRemaining) %) : brancher le secteur" }
    else { Add-Ligne 'Machine' "Secteur · batterie $($bat[0].EstimatedChargeRemaining) %" 'ok' }
    # Win32_PowerPlan ne répond pas sans droit d'administrateur : powercfg, lu par GUID.
    if (((& powercfg.exe /getactivescheme) -join ' ') -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\s*\((.+)\)') {
        $guid = $Matches[1].ToLower()
        $plan = $(if ($plansAlim[$guid]) { $plansAlim[$guid] } else { $Matches[2].Trim() })
        $overlay = [string](Get-Valeur 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes' $(if ($surBatterie) { 'ActiveOverlayDcPowerScheme' } else { 'ActiveOverlayAcPowerScheme' }))
        $mode = $modesAlim[$overlay.ToLower()]
        $t = "Alimentation : $plan$(if ($mode) { " · $mode" })"
        if ($guid -eq 'a1841308-3541-4fab-bc81-f71556f20b4a') { Add-Ligne 'Machine' $t 'attention' "Mode d'alimentation « $plan » : le poste se bride" }
        elseif ($mode -eq 'meilleure efficacité énergétique') { Add-Ligne 'Machine' $t 'attention' "Mode d'alimentation « Meilleure efficacité énergétique » : le poste se bride" }
        else { Add-Ligne 'Machine' $t }
    }
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
    foreach ($v in @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.Name } | Where-Object { $_ } | Select-Object -Unique -First 4)) { Add-Ligne 'Machine' "GPU : $v" }

    # Écrans et son : définition et fréquence réelles, appareils son par défaut.
    try {
        if (-not ('PointeNoire.Releve' -as [type])) { Add-Type -TypeDefinition $codeReleve }
        $i = 0
        foreach ($e in [PointeNoire.Releve]::Ecrans()) {
            $i++; $v = $e -split '\|'
            $hz = [int]$v[2]
            $t = "Écran $i$(if ($v[3] -eq '1') { ' principal' }) : $($v[0]) × $($v[1]) · $hz Hz"
            if ($hz -gt 1 -and $hz -lt 50) { Add-Ligne 'Écrans et son' $t 'attention' "Écran $i à $hz Hz : l'image saccade, passer en 50 ou 60 Hz" } else { Add-Ligne 'Écrans et son' $t }
        }
        foreach ($f in @(@(0, 'Sortie son'), @(1, 'Entrée son'))) {
            $nom = [PointeNoire.Releve]::Son($f[0])
            if ($nom) { Add-Ligne 'Écrans et son' "$($f[1]) : $nom" } else { Add-Ligne 'Écrans et son' "$($f[1]) : aucune" 'attention' "Aucune $($f[1].ToLower()) par défaut" }
        }
    } catch { Add-Ligne 'Écrans et son' 'Relevé des écrans impossible' 'attention' }

    # Logiciels du direct : installés, et lancés ou non.
    $installes = @(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName })
    # Par le nom exact du processus : un service du même dossier (vMixService)
    # ne fait pas « lancé ».
    $procs = @(Get-Process -ErrorAction SilentlyContinue | ForEach-Object { $_.ProcessName })
    foreach ($a in $logiciels) {
        $x = @($installes | Where-Object { $_.DisplayName -match $a[1] } | Select-Object -First 1)
        if (-not $x.Count) { continue }
        $version = ([string]$x[0].DisplayVersion -split ' ')[0]
        if (-not $version -and $a[2]) {
            $exe = ([string]$x[0].DisplayIcon -replace '"', '' -replace ',-?\d+$', '').Trim()
            if ($exe -notmatch '\.exe$' -and $x[0].InstallLocation) { $exe = Join-Path ([string]$x[0].InstallLocation) "$(($a[2] -split '\|')[0]).exe" }
            try { if ($exe -and (Test-Path -LiteralPath $exe)) { $version = [string](Get-Item -LiteralPath $exe).VersionInfo.ProductVersion } } catch { }
        }
        $nom = "$($a[0]) $version".Trim()
        if (-not $a[2]) { Add-Ligne 'Logiciels du direct' "$nom : installé"; continue }
        $lance = @($procs | Where-Object { $_ -match "^($($a[2]))$" }).Count
        Add-Ligne 'Logiciels du direct' "$nom : $(if ($lance) { 'lancé' } else { 'pas lancé' })" $(if ($lance) { 'ok' } else { 'neutre' })
    }
    if (-not $r.sections.Contains('Logiciels du direct')) { Add-Ligne 'Logiciels du direct' 'Aucun logiciel du direct reconnu' }

    # Services : prise en main, son, et ceux du matériel de production.
    $sv = @(Get-Service -ErrorAction SilentlyContinue)
    foreach ($x in @(@('Mesh Agent', 'Prise en main à distance', 'alerte'), @('Audiosrv', 'Son Windows', 'alerte'))) {
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

    # Protections du mode événement : en mode normal rien n'est coupé, et ce
    # n'est pas un défaut. Sinon chaque partie est relue dans Windows.
    $actives = @($s.actives)
    if (-not $actives.Count) { Add-Ligne 'Protections' 'Mode événement inactif : rien de coupé' }
    else {
        $manque = @($pasCoupe.Keys | Where-Object { $actives -notcontains $_ })
        if ($manque.Count) { $r.alertes.Add((New-Ligne "Mode événement partiel, pas coupé : $(($manque | ForEach-Object { $nomsParties[$_] }) -join ', ')" 'attention')) }
        foreach ($k in $pasCoupe.Keys) {
            if ($actives -notcontains $k) { Add-Ligne 'Protections' $pasCoupe[$k] 'attention'; continue }
            $p = Get-Protection $k $s ([bool]$bat.Count) ([bool]$surBatterie)
            Add-Ligne 'Protections' $p.t $p.n $p.a
        }
    }
    foreach ($a in @($s.historique | Select-Object -First 3)) { Add-Ligne 'Dernières actions' (Get-Action $a) $(if ($a.ok) { 'ok' } else { 'alerte' }) }
    # Le plus grave d'abord : une alerte rouge ne se cache pas derrière les orange.
    $tri = @($r.alertes | Where-Object { $_.n -eq 'alerte' }) + @($r.alertes | Where-Object { $_.n -ne 'alerte' })
    $r.alertes.Clear()
    foreach ($x in $tri) { $r.alertes.Add($x) }
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
    # À droite, en laissant à gauche trois colonnes d'icônes du Bureau.
    $pw = [float]([Math]::Min(1560 * $k, $l - 360 * $k)); $x0 = [float]($l - $pw - 48 * $k); $y = [float](36 * $k); $bas = [float]($h - 96 * $k)
    # Le logo Pointe Noire au-dessus du bandeau, lettres claires et ses couleurs
    # ($codeLogo vient de fond.ps1). Sans lui, l'écran se dessine quand même.
    try {
        if (-not ('PointeNoire.Logo' -as [type])) { Add-Type -TypeDefinition $codeLogo -ReferencedAssemblies System.Drawing }
        [PointeNoire.Logo]::Dessine($g, $x0, [float]$y, [float](30 * $k), [Drawing.Color]::FromArgb(232, 232, 232))
        $y = [float]($y + 46 * $k)
    } catch { }
    # Le bandeau : jaune comme dans AVDiagram.
    $g.FillRectangle((& $pinceau ([Drawing.Color]::FromArgb(245, 197, 24))), $x0, $y, $pw, [float](132 * $k))
    $encre = & $pinceau ([Drawing.Color]::FromArgb(20, 20, 20))
    $grand = & $police 52 $true
    $g.DrawString($Libelle, $grand, $encre, [float]($x0 + 28 * $k), [float]($y + 10 * $k))
    # La référence à droite, coupée si elle risque de toucher le titre.
    $ref = & $police 40 $true
    $texteRef = Get-Ajuste $g ([string]$s.reference) $ref ($pw - 96 * $k - $g.MeasureString($Libelle, $grand).Width)
    $g.DrawString($texteRef, $ref, $encre, [float]($x0 + $pw - 28 * $k - $g.MeasureString($texteRef, $ref).Width), [float]($y + 18 * $k))
    $sous = "$(if ($s.depuis) { "Depuis le $(Get-Date2 $s.depuis) · " })relevé à $((Get-Date).ToString('HH:mm')), toutes les 15 minutes"
    $g.DrawString($sous, (& $police 19 $false), $encre, [float]($x0 + 30 * $k), [float]($y + 88 * $k))
    $y += 132 * $k + 14 * $k
    # À vérifier : ce qui demande d'agir, sinon une ligne verte.
    # Par le pipeline : @() sur la List lève « Les types des arguments ne
    # correspondent pas » sous PowerShell 5.1.
    $lignes = @($r.alertes | Where-Object { $_ })
    if ($lignes.Count -gt 6) { $lignes = @($lignes[0..4]) + @(New-Ligne "+ $($lignes.Count - 5) autres points sur la page « État du poste »" 'neutre') }
    if (-not $lignes.Count) { $lignes = @(New-Ligne 'Aucun point à vérifier dans ce relevé' 'ok') }
    $texte = & $police 20 $false
    $haut = [float]((34 + 32 * $lignes.Count + 14) * $k)
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
    # Les colonnes : les sections gardent leur ordre et se répartissent pour que
    # la plus haute des trois colonnes soit la plus basse possible. Ce qui ne
    # tient pas est compté en bas de la colonne, jamais perdu sans le dire.
    $titre = & $police 14 $true; $ecrit = & $police 18 $false
    $gris = & $pinceau ([Drawing.Color]::FromArgb(160, 160, 160))
    $cw = [float](($pw - 2 * 14 * $k) / 3)
    $g.FillRectangle($fond, $x0, $y, $pw, [float]($bas - $y))
    $blocs = @(foreach ($nom in 'Réseau', 'Écrans et son', 'Machine', 'Services', 'Logiciels du direct', 'Protections', 'Dernières actions') {
        if (-not $r.sections.Contains($nom)) { continue }
        $lignesBloc = @(foreach ($ligne in $r.sections[$nom]) {
            [pscustomobject]@{ t = $ligne.t; n = $ligne.n; m = @(Split-Texte $g $ligne.t $ecrit ($cw - 48 * $k)) }
        })
        $rangs = 0; foreach ($x in $lignesBloc) { $rangs += $x.m.Count }
        [pscustomobject]@{ nom = $nom; lignes = $lignesBloc; h = 46 + 27 * $rangs }
    })
    $nb = $blocs.Count; $coupes = @(0, 0); $pire = [double]::MaxValue
    for ($a = 0; $a -le $nb; $a++) {
        for ($b = $a; $b -le $nb; $b++) {
            $hc = @(0, 0, 0)
            for ($i = 0; $i -lt $nb; $i++) { $hc[$(if ($i -lt $a) { 0 } elseif ($i -lt $b) { 1 } else { 2 })] += $blocs[$i].h }
            $max = ($hc | Measure-Object -Maximum).Maximum
            if ($max -lt $pire) { $pire = $max; $coupes = @($a, $b) }
        }
    }
    $fin = $bas - 7 * $k
    for ($c = 0; $c -lt 3; $c++) {
        $cx = [float]($x0 + $c * ($cw + 14 * $k) + 22 * $k); $cy = $y + 16 * $k
        $de = @(0, $coupes[0], $coupes[1])[$c]; $jusque = @($coupes[0], $coupes[1], $nb)[$c]
        $restantes = 0; for ($i = $de; $i -lt $jusque; $i++) { $restantes += $blocs[$i].lignes.Count }
        $plein = $false
        for ($i = $de; $i -lt $jusque -and -not $plein; $i++) {
            # Un titre ne descend que si une ligne tient dessous, avec la place du compte s'il en reste.
            if ($fin - $cy -lt (28 + 27 * $(if ($restantes -gt 1) { 2 } else { 1 })) * $k) { $plein = $true; break }
            $g.DrawString($blocs[$i].nom.ToUpper(), $titre, $gris, $cx, [float]$cy)
            $cy += 28 * $k
            foreach ($ligne in $blocs[$i].lignes) {
                $place = [int][Math]::Floor(($fin - $cy) / (27 * $k)) - $(if ($restantes -gt 1) { 1 } else { 0 })
                if ($place -lt 1) { $plein = $true; break }
                $morceaux = $ligne.m
                if ($morceaux.Count -gt $place) { $morceaux = @(Split-Texte $g $ligne.t $ecrit ($cw - 48 * $k) $place) }
                $g.FillEllipse((& $pinceau $couleur[$ligne.n]), $cx, [float]($cy + 8 * $k), [float](9 * $k), [float](9 * $k))
                $encreLigne = $(if ($ligne.n -in 'attention', 'alerte') { & $pinceau $couleur[$ligne.n] } else { $clair })
                foreach ($m in $morceaux) { $g.DrawString($m, $ecrit, $encreLigne, [float]($cx + 18 * $k), [float]$cy); $cy += 27 * $k }
                $restantes--
            }
            $cy += 18 * $k
        }
        if ($restantes -gt 0) {
            $compte = "+ $restantes $(if ($restantes -gt 1) { 'lignes' } else { 'ligne' }) sur la page « État du poste »"
            $g.DrawString((Get-Ajuste $g $compte $ecrit ($cw - 30 * $k)), $ecrit, $gris, $cx, [float][Math]::Min($cy, $fin - 27 * $k))
        }
    }
}

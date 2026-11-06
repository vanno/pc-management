<#
  Envoi des mesures de la sonde à la console régie locale (lot 1 de la
  console). Posé par console-pose.ps1 dans le dossier de la sonde, appelé par
  supervision.ps1 après chaque mesure, dans le même PowerShell (compte SYSTEM).
  Compatible Windows PowerShell 5.1.

  console.json : { reference, consoles : [{ id, nom, empreinte, jeton, port,
  adresse }] }. Pour chaque console : l'adresse qui a marché la dernière fois,
  sinon la découverte (diffusion UDP « PNC1? <id> » sur le port 8472, à chaque
  réseau du poste), sinon l'adresse fixée à l'avance. L'envoi se fait en HTTPS
  vers https://<adresse>:<port>/api/sonde avec le jeton du poste, et seul le
  certificat dont l'empreinte SHA-256 est celle de console.json est accepté :
  un appareil du LAN qui se ferait passer pour la console ne reçoit rien.
  Le résultat de chaque console est noté dans console-vue.json.

  Le code C# est compilé une fois par version dans regie-<empreinte>.dll.
#>
param($Mesure)

$ErrorActionPreference = 'Stop'
$ici = Split-Path -Parent $MyInvocation.MyCommand.Path
$conf = [IO.File]::ReadAllText((Join-Path $ici 'console.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
$fichierVu = Join-Path $ici 'console-vue.json'

$codeRegie = @"
using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;

namespace PointeNoire {
    public static class Regie {
        public static string Erreur = "";

        public static string Empreinte(X509Certificate c) {
            using (SHA256 s = SHA256.Create()) {
                return BitConverter.ToString(s.ComputeHash(c.GetRawCertData())).Replace("-", "").ToLowerInvariant();
            }
        }

        // Rend le code HTTP, ou 0 sans réponse (Erreur dit pourquoi).
        public static int Envoyer(string url, string empreinte, string jeton, string corps, int ms) {
            Erreur = "";
            string vue = null;
            HttpWebRequest req = (HttpWebRequest)WebRequest.Create(url);
            req.Method = "POST";
            req.ContentType = "application/json; charset=utf-8";
            req.Timeout = ms;
            req.ReadWriteTimeout = ms;
            req.KeepAlive = false;
            req.Proxy = null;
            req.Headers["Authorization"] = "Bearer " + jeton;
            req.ServerCertificateValidationCallback = delegate(object o, X509Certificate c, X509Chain ch, SslPolicyErrors e) {
                if (c == null) { return false; }
                vue = Empreinte(c);
                return string.Equals(vue, empreinte, StringComparison.OrdinalIgnoreCase);
            };
            byte[] b = Encoding.UTF8.GetBytes(corps);
            req.ContentLength = b.Length;
            try {
                using (Stream s = req.GetRequestStream()) { s.Write(b, 0, b.Length); }
                using (HttpWebResponse r = (HttpWebResponse)req.GetResponse()) { return (int)r.StatusCode; }
            } catch (WebException ex) {
                HttpWebResponse r = ex.Response as HttpWebResponse;
                if (r != null) { int code = (int)r.StatusCode; r.Close(); Erreur = "HTTP " + code; return code; }
                if (vue != null && !string.Equals(vue, empreinte, StringComparison.OrdinalIgnoreCase)) { Erreur = "empreinte inattendue " + vue; }
                else { Erreur = ex.Status.ToString(); }
                return 0;
            }
        }

        // Les adresses de diffusion de chaque réseau IPv4 du poste, et 255.255.255.255.
        public static string[] Diffusions() {
            List<string> l = new List<string>();
            foreach (NetworkInterface n in NetworkInterface.GetAllNetworkInterfaces()) {
                if (n.OperationalStatus != OperationalStatus.Up || n.NetworkInterfaceType == NetworkInterfaceType.Loopback) { continue; }
                foreach (UnicastIPAddressInformation u in n.GetIPProperties().UnicastAddresses) {
                    if (u.Address.AddressFamily != AddressFamily.InterNetwork || u.IPv4Mask == null) { continue; }
                    byte[] a = u.Address.GetAddressBytes();
                    if (a[0] == 169 && a[1] == 254) { continue; }
                    byte[] m = u.IPv4Mask.GetAddressBytes();
                    byte[] d = new byte[4];
                    for (int i = 0; i < 4; i++) { d[i] = (byte)(a[i] | ~m[i]); }
                    string s = new IPAddress(d).ToString();
                    if (!l.Contains(s)) { l.Add(s); }
                }
            }
            l.Add("255.255.255.255");
            return l.ToArray();
        }

        // Les consoles qui répondent « PNC1 <id> <port> », en adresse:port.
        public static string[] Chercher(string id, int port, int ms) {
            List<string> vues = new List<string>();
            using (UdpClient u = new UdpClient(0)) {
                u.EnableBroadcast = true;
                byte[] q = Encoding.ASCII.GetBytes("PNC1? " + id);
                foreach (string d in Diffusions()) {
                    try { u.Send(q, q.Length, new IPEndPoint(IPAddress.Parse(d), port)); } catch (SocketException) { }
                }
                DateTime fin = DateTime.UtcNow.AddMilliseconds(ms);
                while (true) {
                    int reste = (int)(fin - DateTime.UtcNow).TotalMilliseconds;
                    if (reste <= 0) { break; }
                    u.Client.ReceiveTimeout = reste;
                    try {
                        IPEndPoint de = new IPEndPoint(IPAddress.Any, 0);
                        string[] p = Encoding.ASCII.GetString(u.Receive(ref de)).Split(' ');
                        int pt;
                        if (p.Length >= 3 && p[0] == "PNC1" && p[1] == id && int.TryParse(p[2], out pt)) {
                            string a = de.Address.ToString() + ":" + pt;
                            if (!vues.Contains(a)) { vues.Add(a); }
                        }
                    } catch (SocketException) { break; }
                }
            }
            return vues.ToArray();
        }
    }
}
"@

if (-not ('PointeNoire.Regie' -as [type])) {
    $sha = New-Object Security.Cryptography.SHA256Managed
    $h = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($codeRegie))).Replace('-', '').Substring(0, 12).ToLowerInvariant()
    $dll = Join-Path $ici "regie-$h.dll"
    if (Test-Path $dll) {
        Add-Type -Path $dll
    } else {
        Get-ChildItem -Path $ici -Filter 'regie-*.dll' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        try { Add-Type -TypeDefinition $codeRegie -OutputAssembly $dll -OutputType Library } catch { }
        if (-not ('PointeNoire.Regie' -as [type])) {
            if (Test-Path $dll) { Add-Type -Path $dll } else { Add-Type -TypeDefinition $codeRegie }
        }
    }
}

$vu = @{}
if (Test-Path $fichierVu) {
    try {
        $lu = [IO.File]::ReadAllText($fichierVu, [Text.Encoding]::UTF8) | ConvertFrom-Json
        foreach ($p in $lu.PSObject.Properties) { $vu[$p.Name] = $p.Value }
    } catch { $vu = @{} }
}

$corps = [ordered]@{ reference = [string]$conf.reference; poste = $env:COMPUTERNAME; samples = @($Mesure) } | ConvertTo-Json -Depth 6 -Compress
$maintenant = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

foreach ($c in @($conf.consoles)) {
    $id = [string]$c.id
    $port = [int]$c.port
    $ancien = $vu[$id]
    $essais = New-Object System.Collections.ArrayList
    if ($ancien -and $ancien.adresse) { [void]$essais.Add([string]$ancien.adresse) }
    $code = 0
    $erreur = ''
    $par = ''
    $retenue = $null
    foreach ($etape in 'connue', 'decouverte', 'fixe') {
        if ($etape -eq 'decouverte') {
            $essais.Clear()
            foreach ($a in [PointeNoire.Regie]::Chercher($id, 8472, 1500)) { [void]$essais.Add($a) }
        } elseif ($etape -eq 'fixe') {
            $essais.Clear()
            if ($c.adresse) { [void]$essais.Add("$($c.adresse):$port") }
        }
        foreach ($a in $essais) {
            $code = [PointeNoire.Regie]::Envoyer("https://$a/api/sonde", [string]$c.empreinte, [string]$c.jeton, $corps, 3000)
            $erreur = [PointeNoire.Regie]::Erreur
            if ($code -eq 200) { $retenue = $a; $par = $etape; break }
            # Une console qui répond mais refuse le jeton : inutile d'en chercher une autre.
            if ($code -eq 401) { $retenue = $a; $par = $etape; break }
        }
        if ($retenue) { break }
    }
    $etat = 'injoignable'
    if ($code -eq 200) { $etat = 'ok' } elseif ($code -eq 401) { $etat = 'jeton refusé' } elseif ($code) { $etat = "HTTP $code" }
    $vu[$id] = [ordered]@{ nom = [string]$c.nom; adresse = $(if ($code -eq 200) { $retenue } else { $null }); etat = $etat; par = $par; erreur = $erreur; le = $maintenant }
}

try { [IO.File]::WriteAllText($fichierVu, (ConvertTo-Json -InputObject $vu -Depth 4 -Compress), (New-Object System.Text.UTF8Encoding $false)) } catch { }

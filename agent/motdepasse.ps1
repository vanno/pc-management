<#
  Mot de passe d'un compte local et ouverture de session automatique (0088),
  lancé par pc-management à travers MeshCentral, comme pilote.ps1 (même
  enveloppe PNPL1, mêmes paramètres PNPL_PARAMS en base64). Compte SYSTEM,
  Windows PowerShell 5.1. Script à part : pilote.ps1 doit rester sous la
  longueur de commande de l'agent.

  op cle           { n, e } : la clé publique RSA du poste, créée au besoin
                   dans le magasin de clés de la machine.
  op mot_de_passe  { compte, chiffre, auto } : change le mot de passe d'un
                   compte local (chiffre : RSA-OAEP SHA-1 avec la clé du
                   poste), active (auto vrai) ou coupe (auto faux)
                   l'ouverture de session automatique. Le mot de passe de
                   l'ouverture automatique est rangé comme le fait Windows
                   (secret LSA DefaultPassword), jamais en clair dans le
                   registre. Il n'apparaît ni dans la commande ni dans la
                   réponse, qui rend des points de contrôle relus.
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$result = [ordered]@{ op = $null; ok = $false; detail = '' }

function Send-Result {
    $json = $result | ConvertTo-Json -Compress -Depth 6
    'PNPL1:' + $env:PNPL_NONCE + ':' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
}

# La clé du poste : une paire RSA rangée dans le magasin de clés de la machine.
# Le relais chiffre le mot de passe avec la partie publique, juste avant de
# l'envoyer : MeshCentral et ses journaux ne voient passer que du chiffré.
$conteneurCle = 'PointeNoire-Relais'

function Get-CleRelais {
    $cp = New-Object Security.Cryptography.CspParameters
    $cp.KeyContainerName = $conteneurCle
    $cp.Flags = [Security.Cryptography.CspProviderFlags]::UseMachineKeyStore
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider(2048, $cp)
    $rsa.PersistKeyInCsp = $true
    $rsa
}

function Read-Secret([string]$Chiffre) {
    $rsa = Get-CleRelais
    try { [Text.Encoding]::UTF8.GetString($rsa.Decrypt([Convert]::FromBase64String($Chiffre), $true)) }
    catch { throw 'mot de passe illisible : la clé du poste a changé, relancez l''action' }
    finally { $rsa.Dispose() }
}

$LsaSource = @'
using System;
using System.Runtime.InteropServices;
public static class PnLsa {
  [StructLayout(LayoutKind.Sequential)] struct UNI { public ushort Length; public ushort MaximumLength; public IntPtr Buffer; }
  [StructLayout(LayoutKind.Sequential)] struct OBJ { public int Length; public IntPtr RootDirectory; public IntPtr ObjectName; public uint Attributes; public IntPtr SecurityDescriptor; public IntPtr SecurityQualityOfService; }
  [DllImport("advapi32.dll")] static extern uint LsaOpenPolicy(IntPtr system, ref OBJ attrs, uint access, out IntPtr handle);
  [DllImport("advapi32.dll")] static extern uint LsaStorePrivateData(IntPtr handle, ref UNI key, IntPtr data);
  [DllImport("advapi32.dll")] static extern uint LsaRetrievePrivateData(IntPtr handle, ref UNI key, out IntPtr data);
  [DllImport("advapi32.dll")] static extern uint LsaClose(IntPtr handle);
  [DllImport("advapi32.dll")] static extern uint LsaFreeMemory(IntPtr buffer);
  [DllImport("advapi32.dll")] static extern int LsaNtStatusToWinError(uint status);
  static UNI Uni(string s) { UNI u = new UNI(); u.Buffer = Marshal.StringToHGlobalUni(s); u.Length = (ushort)(s.Length * 2); u.MaximumLength = (ushort)(s.Length * 2 + 2); return u; }
  static IntPtr Open() {
    OBJ o = new OBJ(); o.Length = Marshal.SizeOf(typeof(OBJ)); IntPtr h;
    uint s = LsaOpenPolicy(IntPtr.Zero, ref o, 0x20 | 0x04, out h);
    if (s != 0) throw new System.ComponentModel.Win32Exception(LsaNtStatusToWinError(s));
    return h;
  }
  public static void Store(string key, string value) {
    IntPtr h = Open(); UNI k = Uni(key); IntPtr pv = IntPtr.Zero;
    try {
      if (value != null) { UNI v = Uni(value); pv = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(UNI))); Marshal.StructureToPtr(v, pv, false); }
      uint s = LsaStorePrivateData(h, ref k, pv);
      if (s != 0 && !(value == null && s == 0xC0000034)) throw new System.ComponentModel.Win32Exception(LsaNtStatusToWinError(s));
    } finally {
      if (pv != IntPtr.Zero) { UNI v = (UNI)Marshal.PtrToStructure(pv, typeof(UNI)); Marshal.ZeroFreeGlobalAllocUnicode(v.Buffer); Marshal.FreeHGlobal(pv); }
      Marshal.FreeHGlobal(k.Buffer); LsaClose(h);
    }
  }
  public static bool Exists(string key) {
    IntPtr h = Open(); UNI k = Uni(key); IntPtr d;
    try {
      uint s = LsaRetrievePrivateData(h, ref k, out d);
      if (s != 0) return false;
      bool ok = false;
      if (d != IntPtr.Zero) { UNI v = (UNI)Marshal.PtrToStructure(d, typeof(UNI)); ok = v.Length > 0; LsaFreeMemory(d); }
      return ok;
    } finally { Marshal.FreeHGlobal(k.Buffer); LsaClose(h); }
  }
}
'@

$cleWinlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'

# Le compte visé : celui demandé, sinon le compte principal du poste (celui de
# l'ouverture automatique, puis celui de la session ouverte, puis le seul
# compte local actif qui n'est pas un compte intégré). Jamais deviné au hasard.
function Resolve-Compte([string]$Demande) {
    $locaux = @(Get-LocalUser | Where-Object { $_.Enabled -and $_.SID.Value -notmatch '-50[0-3]$|-504$' })
    if ($Demande) {
        $c = $locaux | Where-Object { $_.Name -eq $Demande } | Select-Object -First 1
        if (-not $c) { throw "aucun compte actif nommé « $Demande » sur ce poste" }
        return $c
    }
    $candidats = @()
    $auto = [string](Get-ItemProperty -Path $cleWinlogon -ErrorAction SilentlyContinue).DefaultUserName
    if ($auto) { $candidats += $auto }
    $session = [string](Get-CimInstance Win32_ComputerSystem).UserName
    if ($session) { $candidats += ($session -split '\\')[-1] }
    foreach ($n in $candidats) {
        $c = $locaux | Where-Object { $_.Name -eq $n } | Select-Object -First 1
        if ($c) { return $c }
    }
    if ($locaux.Count -eq 1) { return $locaux[0] }
    throw "plusieurs comptes sur ce poste ($(($locaux | ForEach-Object { $_.Name }) -join ', ')) : précisez lequel"
}

function Test-MotDePasse([string]$Compte, [string]$Secret) {
    Add-Type -AssemblyName System.DirectoryServices.AccountManagement
    $ctx = New-Object DirectoryServices.AccountManagement.PrincipalContext([DirectoryServices.AccountManagement.ContextType]::Machine)
    try { $ctx.ValidateCredentials($Compte, $Secret) } finally { $ctx.Dispose() }
}

function Set-MotDePasse($p) {
    if (-not ('PnLsa' -as [type])) { Add-Type -TypeDefinition $LsaSource }
    $compte = Resolve-Compte ([string]$p.compte)
    $nom = $compte.Name
    $result.compte = $nom
    if ([string]$compte.PrincipalSource -ne 'Local') { throw "« $nom » est un compte $($compte.PrincipalSource) : son mot de passe se change en ligne, pas sur le poste" }
    $points = @()
    $secret = $null
    if ($p.chiffre) {
        $secret = Read-Secret ([string]$p.chiffre)
        if ($secret.Length -lt 4) { throw 'mot de passe trop court' }
        $u = [ADSI]"WinNT://$env:COMPUTERNAME/$nom,user"
        $u.SetPassword($secret)
        # Un mot de passe posé : le compte n'est plus marqué « mot de passe facultatif ».
        $drapeaux = [int]$u.UserFlags.Value
        if ($drapeaux -band 0x20) { $u.UserFlags.Value = $drapeaux -bxor 0x20; $u.SetInfo() }
        $bon = Test-MotDePasse $nom $secret
        $points += [ordered]@{ nom = 'Mot de passe'; ok = [bool]$bon; constat = $(if ($bon) { "$nom : accepté par Windows" } else { "$nom : refusé par Windows à la relecture" }) }
    }
    if ($p.auto -eq $true) {
        if (-not $secret) { throw 'l''ouverture automatique demande le mot de passe du compte' }
        [PnLsa]::Store('DefaultPassword', $secret)
        Set-ItemProperty -Path $cleWinlogon -Name AutoAdminLogon -Value '1' -Type String
        Set-ItemProperty -Path $cleWinlogon -Name DefaultUserName -Value $nom -Type String
        Set-ItemProperty -Path $cleWinlogon -Name DefaultDomainName -Value $env:COMPUTERNAME -Type String
        Remove-ItemProperty -Path $cleWinlogon -Name DefaultPassword, AutoLogonCount -ErrorAction SilentlyContinue
    } elseif ($p.auto -eq $false) {
        Set-ItemProperty -Path $cleWinlogon -Name AutoAdminLogon -Value '0' -Type String
        Remove-ItemProperty -Path $cleWinlogon -Name DefaultPassword, AutoLogonCount -ErrorAction SilentlyContinue
        [PnLsa]::Store('DefaultPassword', $null)
    } elseif ($secret -and ([string](Get-ItemProperty -Path $cleWinlogon).AutoAdminLogon -eq '1') -and ([string](Get-ItemProperty -Path $cleWinlogon).DefaultUserName -eq $nom)) {
        # Déjà en ouverture automatique sur ce compte : le nouveau mot de passe la suit.
        [PnLsa]::Store('DefaultPassword', $secret)
        Remove-ItemProperty -Path $cleWinlogon -Name DefaultPassword -ErrorAction SilentlyContinue
    }
    $secret = $null
    $w = Get-ItemProperty -Path $cleWinlogon
    $actif = ([string]$w.AutoAdminLogon -eq '1')
    $stocke = [PnLsa]::Exists('DefaultPassword')
    if ($p.auto -eq $true) {
        $ok = $actif -and ([string]$w.DefaultUserName -eq $nom) -and $stocke -and -not $w.DefaultPassword
        $points += [ordered]@{ nom = 'Ouverture automatique'; ok = $ok; constat = $(if ($ok) { "active sur $nom, mot de passe rangé par Windows" } else { 'pas relue telle que voulue' }) }
    } elseif ($p.auto -eq $false) {
        $ok = -not $actif -and -not $stocke -and -not $w.DefaultPassword
        $points += [ordered]@{ nom = 'Ouverture automatique'; ok = $ok; constat = $(if ($ok) { 'coupée, mot de passe retiré' } else { 'encore en place' }) }
    }
    $result.auto = $actif
    $result.points = $points
    $result.ok = -not ($points | Where-Object { $_.ok -ne $true })
    $parts = @()
    if ($p.chiffre) { $parts += "mot de passe de $nom changé" }
    if ($p.auto -eq $true) { $parts += 'ouverture automatique activée' }
    elseif ($p.auto -eq $false) { $parts += 'ouverture automatique coupée' }
    elseif ($actif) { $parts += "ouverture automatique sur $($w.DefaultUserName)" }
    $result.detail = ($parts -join ', ')
    if (-not $result.ok) { $result.detail += ' (relecture en échec)' }
}

# --- Entrée --------------------------------------------------------------------

try {
    $p = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:PNPL_PARAMS)) | ConvertFrom-Json
    $result.op = $p.op
    switch ($p.op) {
        'cle' {
            $rsa = Get-CleRelais
            try { $k = $rsa.ExportParameters($false); $result.n = [Convert]::ToBase64String($k.Modulus); $result.e = [Convert]::ToBase64String($k.Exponent) } finally { $rsa.Dispose() }
            $result.ok = $true
        }
        'mot_de_passe' { Set-MotDePasse $p }
        default { $result.detail = "opération inconnue : $($p.op)" }
    }
} catch {
    $result.ok = $false
    $i = $_.InvocationInfo
    $result.detail = "$($_.Exception.Message) (motdepasse.ps1, ligne $($i.ScriptLineNumber))"
}
Send-Result

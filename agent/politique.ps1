<#
  Stratégie de groupe locale, pour l'allègement (op nettoyage de pilote.ps1).
  Le worker l'envoie devant pilote.ps1, seulement pour cette opération : la
  commande des autres opérations reste sous la limite de l'agent. Une erreur
  de l'allègement compte donc ses lignes à partir du début de ce fichier.
  Compatible Windows PowerShell 5.1.
#>

# --- Stratégie de groupe locale (Registry.pol) ------------------------------------
# Le pilote UCPD de Windows 11 refuse certaines clés à PowerShell, même sous
# SYSTEM (AllowNewsAndInterests sur PN09, le 2026-11-05). La stratégie de
# groupe locale est appliquée par le service Stratégie de groupe, que UCPD
# laisse écrire : c'est ce que fait gpedit. Registry.pol est écrit ici, sans
# gpedit, qui manque sur Windows Famille.
$paquetWidgets = 'MicrosoftWindows.Client.WebExperience'
$cseRegistre = '[{35378EAC-683F-11D2-A89A-00C04FBBCFA2}{D02B1F72-3407-48AE-BA88-E8213C6761F1}]'

function Get-DossierSysteme {
    # Un PowerShell 32 bits verrait SysWOW64 à la place de System32.
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { return Join-Path $env:windir 'Sysnative' }
    Join-Path $env:windir 'System32'
}

function Read-Chaine([byte[]]$B, [ref]$P) {
    $i = $P.Value
    while ($i + 1 -lt $B.Length -and ($B[$i] -ne 0 -or $B[$i + 1] -ne 0)) { $i += 2 }
    $s = [Text.Encoding]::Unicode.GetString($B, $P.Value, $i - $P.Value)
    $P.Value = $i + 2
    $s
}

# Les entrées [clé;valeur;type;taille;données] d'un Registry.pol (format PReg 1).
function Read-Pol([string]$Chemin) {
    $entrees = New-Object System.Collections.ArrayList
    if (-not (Test-Path $Chemin)) { return ,$entrees }
    $b = [IO.File]::ReadAllBytes($Chemin)
    if ($b.Length -lt 8 -or [Text.Encoding]::ASCII.GetString($b, 0, 4) -ne 'PReg' -or [BitConverter]::ToUInt32($b, 4) -ne 1) { throw 'Registry.pol illisible, laissé tel quel' }
    $p = 8
    while ($p + 1 -lt $b.Length) {
        if ($b[$p] -ne 0x5B -or $b[$p + 1] -ne 0) { throw 'Registry.pol illisible, laissé tel quel' }
        $p += 2
        $cle = Read-Chaine $b ([ref]$p); $p += 2
        $nom = Read-Chaine $b ([ref]$p); $p += 2
        $type = [BitConverter]::ToUInt32($b, $p); $p += 6
        $taille = [int][BitConverter]::ToUInt32($b, $p); $p += 6
        if ($p + $taille + 2 -gt $b.Length) { throw 'Registry.pol illisible, laissé tel quel' }
        $donnees = New-Object byte[] $taille
        [Array]::Copy($b, $p, $donnees, 0, $taille)
        $p += $taille + 2
        [void]$entrees.Add([pscustomobject]@{ cle = $cle; nom = $nom; type = $type; donnees = $donnees })
    }
    return ,$entrees
}

function Add-Octets($Flux, [byte[]]$Octets) { $Flux.Write($Octets, 0, $Octets.Length) }

function Write-Pol([string]$Chemin, $Entrees) {
    $m = New-Object IO.MemoryStream
    $u = [Text.Encoding]::Unicode
    Add-Octets $m ([Text.Encoding]::ASCII.GetBytes('PReg'))
    Add-Octets $m ([BitConverter]::GetBytes([uint32]1))
    foreach ($e in $Entrees) {
        Add-Octets $m ($u.GetBytes('[' + $e.cle + [char]0 + ';' + $e.nom + [char]0 + ';'))
        Add-Octets $m ([BitConverter]::GetBytes([uint32]$e.type))
        Add-Octets $m ($u.GetBytes(';'))
        Add-Octets $m ([BitConverter]::GetBytes([uint32]$e.donnees.Length))
        Add-Octets $m ($u.GetBytes(';'))
        Add-Octets $m ([byte[]]$e.donnees)
        Add-Octets $m ($u.GetBytes(']'))
    }
    $d = Split-Path $Chemin
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    [IO.File]::WriteAllBytes($Chemin, $m.ToArray())
}

# Le numéro de version de gpt.ini dit au service qu'il y a du nouveau ; ses
# 16 bits du bas comptent la partie ordinateur.
function Update-GptIni([string]$Dossier) {
    $ini = Join-Path $Dossier 'gpt.ini'
    $version = [long]0
    $groupes = @()
    $autres = @()
    if (Test-Path $ini) {
        foreach ($l in @(Get-Content -Path $ini)) {
            if ($l -match '^\s*Version\s*=\s*(\d+)') { $version = [long]$Matches[1] }
            elseif ($l -match '^\s*gPCMachineExtensionNames\s*=\s*(.*)$') { $groupes = @([regex]::Matches($Matches[1], '\[[^\]]*\]') | ForEach-Object { $_.Value }) }
            elseif ($l.Trim() -and $l -notmatch '^\s*\[General\]\s*$') { $autres += $l }
        }
    }
    if (-not @($groupes | Where-Object { $_ -like '*35378EAC-683F-11D2-A89A-00C04FBBCFA2*' }).Count) { $groupes += $cseRegistre }
    $machine = ($version % 65536) + 1
    if ($machine -gt 65535) { $machine = 1 }
    $version = $version - ($version % 65536) + $machine
    $texte = @('[General]', ('gPCMachineExtensionNames=' + (@($groupes | Sort-Object) -join '')), "Version=$version") + $autres
    [IO.File]::WriteAllText($ini, ($texte -join "`r`n") + "`r`n", [Text.Encoding]::ASCII)
}

# Pose (valeur) ou retire ($null) des DWord de la stratégie locale, puis la
# fait appliquer. Rend $null, ou ce qui a échoué.
function Set-PolitiqueLocale($Reglages) {
    $sys = Get-DossierSysteme
    $dossier = Join-Path $sys 'GroupPolicy'
    $pol = Join-Path $dossier 'Machine\Registry.pol'
    $entrees = Read-Pol $pol
    foreach ($r in $Reglages) {
        $cle = $r[0] -replace '^HKLM:\\', ''
        foreach ($x in @($entrees | Where-Object { $_.cle -eq $cle -and $_.nom -eq $r[1] })) { $entrees.Remove($x) }
        if ($null -ne $r[2]) { [void]$entrees.Add([pscustomobject]@{ cle = $cle; nom = $r[1]; type = 4; donnees = [BitConverter]::GetBytes([uint32]$r[2]) }) }
    }
    Write-Pol $pol $entrees
    Update-GptIni $dossier
    # gpupdate peut poser une question : la réponse est déjà là, rien n'attend.
    # Sa sortie d'erreur ne doit pas arrêter le script (PowerShell 5.1).
    $ErrorActionPreference = 'Continue'
    $sortie = ('N' | & (Join-Path $sys 'gpupdate.exe') /target:computer /force /wait:120 2>&1) -join ' '
    if ($LASTEXITCODE -ne 0) { return "gpupdate a rendu $LASTEXITCODE : $($sortie.Trim())" }
    return $null
}

# Les widgets coupés pour de bon quand UCPD protège leur réglage : par la
# stratégie locale, puis en retirant leur paquet si Windows l'ignore.
function Disable-Widgets($Etat, [ref]$Refus) {
    # Une boucle : @() sur un seul tableau sorti du pipeline le déplierait.
    $r = $null
    foreach ($x in $reglagesNettoyage) { if ($x[1] -eq 'AllowNewsAndInterests') { $r = $x } }
    try {
        $erreur = Set-PolitiqueLocale @(,$r)
        if ($erreur) { $Refus.Value += "stratégie locale ($erreur)" }
        elseif ([string](Get-Valeur $r[0] $r[1]) -eq [string]$r[2]) {
            $Etat.politique = @(@($Etat.politique) + $r[1] | Where-Object { $_ } | Sort-Object -Unique)
            return 'par la stratégie de groupe locale'
        }
    } catch { $Refus.Value += "stratégie locale ($($_.Exception.Message))" }
    try {
        foreach ($pkg in @(Get-AppxPackage -AllUsers -Name $paquetWidgets -ErrorAction Stop)) { Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop }
        foreach ($prov in @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $paquetWidgets })) { Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction SilentlyContinue | Out-Null }
        $Etat.applications = @(@($Etat.applications) + $paquetWidgets | Where-Object { $_ } | Sort-Object -Unique)
        return 'en retirant leur paquet (stratégie ignorée par Windows)'
    } catch { $Refus.Value += "paquet des widgets ($($_.Exception.Message))" }
    return $null
}

<#
  Contrôle d'une action, lancé par l'agent MeshCentral (compte SYSTEM) juste
  après elle, à part de pilote.ps1 : relit dans Windows l'effet de ce que
  l'action devait changer. Ne change aucun réglage. Sa seule écriture, hors
  de la lecture dans les sessions : une action que Windows n'applique pas
  passe en échec dans l'historique de l'écran du poste (fond\etat.json).
  Compatible Windows PowerShell 5.1.

  PNPL_PARAMS : { op: controle, quoi, actif, parties }
    quoi : evenement (parties : windows_update, veille, notifications,
           conseils, fond ; toutes sans parties), nettoyage, supervision.
  Sortie : PNPL1:<jeton>:<JSON en base64> avec { op, ok, detail, points },
  un point par partie relue : { nom, ok, constat }. ok vaut null quand la
  partie n'a pas pu être relue, false quand Windows ne l'applique pas.

  Notifications : relues dans chaque session ouverte par Windows lui-même
  (ToastNotificationManager), le registre ne prouvant que l'écriture. Une
  tâche temporaire du groupe Utilisateurs y lance la lecture, puis part.
  Écran « Mode événement » : la tâche PointeNoire-Fond est relancée, son bilan relu.
  Retour à la normale : comparé à l'état d'avant, gardé par pilote.ps1 dans
  mode-evenement-rendu.json et nettoyage-rendu.json (10 minutes au plus).
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$base = Join-Path $env:ProgramData 'PointeNoire'
$result = [ordered]@{ op = 'controle'; ok = $false; detail = ''; points = @() }
$points = New-Object System.Collections.ArrayList

function Add-Point([string]$Nom, $Ok, [string]$Constat) {
    [void]$points.Add([ordered]@{ nom = $Nom; ok = $Ok; constat = $Constat })
}

function Get-Valeur([string]$Cle, [string]$Nom) {
    $v = Get-ItemProperty -Path $Cle -Name $Nom -ErrorAction SilentlyContinue
    if ($v) { return $v.$Nom }
    return $null
}

# Deux valeurs du registre ou du JSON : absentes toutes les deux, ou égales.
function Test-Egal($A, $B) {
    if ($null -eq $A -or $null -eq $B) { return ($null -eq $A -and $null -eq $B) }
    return ([string]$A -eq [string]$B)
}

function Read-Json([string]$Chemin, [int]$Minutes = 0) {
    $f = Get-Item -LiteralPath $Chemin -ErrorAction SilentlyContinue
    if (-not $f) { return $null }
    if ($Minutes -and ((Get-Date) - $f.LastWriteTime).TotalMinutes -gt $Minutes) { return $null }
    try { Get-Content -Raw -Encoding UTF8 -LiteralPath $Chemin | ConvertFrom-Json } catch { $null }
}

# Un point pour plusieurs comptes : faux s'il y a un échec, nul si l'un n'a pas été relu.
function Add-Comptes([string]$Nom, $Etats, [string]$SansCompte, [bool]$SansEchoue) {
    $e = @($Etats | Where-Object { $_ })
    if (-not $e.Count) { Add-Point $Nom $(if ($SansEchoue) { $false } else { $null }) $SansCompte; return }
    $ok = $true
    if (@($e | Where-Object { $_.ok -eq $false }).Count) { $ok = $false }
    elseif (@($e | Where-Object { $null -eq $_.ok }).Count) { $ok = $null }
    Add-Point $Nom $ok (($e | ForEach-Object { $_.texte }) -join ', ')
}

function Get-Nom([string]$Sid) {
    try { ((New-Object Security.Principal.SecurityIdentifier $Sid).Translate([Security.Principal.NTAccount]).Value -split '\\')[-1] } catch { $Sid }
}

# Les comptes à relire : à l'activation, ceux dont la ruche est chargée (ceux
# que pilote.ps1 a réglés) ; au retour, ceux de l'état d'avant.
function Get-Ruches([bool]$Actif, $Avant) {
    if (-not $Actif) { return @($Avant.PSObject.Properties | Where-Object { $_ } | ForEach-Object { $_.Name }) }
    @(Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^S-1-5-21-[\d-]+$' } | ForEach-Object { $_.PSChildName })
}

# pilote.ps1 ne rend pas le réglage d'un compte dont la session s'est fermée.
function Get-Ferme([string]$Sid) {
    if (Test-Path "Registry::HKEY_USERS\$Sid") { return $null }
    [pscustomobject]@{ ok = $false; texte = "$(Get-Nom $Sid) : session fermée pendant l'événement, réglage pas rendu" }
}

# Les sessions ouvertes (propriétaires d'explorer.exe), et le fichier de bilan dans leur profil.
function Get-Sessions([string]$Fichier) {
    $vus = @{}
    foreach ($x in @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue)) {
        $sid = (Invoke-CimMethod -InputObject $x -MethodName GetOwnerSid -ErrorAction SilentlyContinue).Sid
        if (-not $sid -or $vus.ContainsKey($sid)) { continue }
        $profil = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" -ErrorAction SilentlyContinue).ProfileImagePath
        if (-not $profil) { continue }
        $vus[$sid] = [pscustomobject]@{ sid = $sid; nom = (Get-Nom $sid); fichier = Join-Path $profil "AppData\Local\PointeNoire\$Fichier" }
    }
    @($vus.Values | Sort-Object nom)
}

function Wait-Bilans($Comptes, [datetime]$Debut, [int]$Secondes) {
    $bilans = @{}
    for ($i = 0; $i -lt $Secondes -and $bilans.Count -lt @($Comptes).Count; $i++) {
        Start-Sleep -Seconds 1
        foreach ($c in $Comptes) {
            if ($bilans.ContainsKey($c.sid)) { continue }
            $f = Get-Item -LiteralPath $c.fichier -ErrorAction SilentlyContinue
            if ($f -and $f.LastWriteTime -ge $Debut) { $b = Read-Json $c.fichier; if ($b) { $bilans[$c.sid] = $b } }
        }
    }
    $bilans
}

# --- Lecture dans les sessions ouvertes ---------------------------------------------

$dossierSonde = Join-Path $base 'controle'
$tacheSonde = 'PointeNoire-Controle'
$scriptSession = @'
$r = [ordered]@{ le = (Get-Date).ToString('o'); notifications = '' }
try {
    $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    # L'identifiant de PowerShell, connu de Windows. Un réglage vide n'est pas « activé ».
    $v = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe').Setting
    $r.notifications = $(if ($null -eq $v) { 'illisible : Windows rend un réglage vide' } else { [string]$v })
} catch { $r.notifications = "illisible : $($_.Exception.Message)" }
$d = Join-Path $env:LOCALAPPDATA 'PointeNoire'
if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
[IO.File]::WriteAllText((Join-Path $d 'controle-session.json'), ($r | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding $false))
'@

# Rend { sessions: SID des sessions ouvertes, bilans: SID -> bilan }.
function Invoke-Sonde {
    $comptes = @(Get-Sessions 'controle-session.json')
    if (-not $comptes.Count) { return @{ sessions = @(); bilans = @{} } }
    if (-not (Test-Path $dossierSonde)) { New-Item -ItemType Directory -Path $dossierSonde -Force | Out-Null }
    & icacls.exe $dossierSonde /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
    $s = Join-Path $dossierSonde 'session.ps1'
    $l = Join-Path $dossierSonde 'lanceur.vbs'
    # Avec BOM : PowerShell 5.1 lit sinon les accents en ANSI.
    [IO.File]::WriteAllText($s, $scriptSession, (New-Object System.Text.UTF8Encoding $true))
    $vbs = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$s""".Replace('"', '""')
    [IO.File]::WriteAllText($l, "CreateObject(""WScript.Shell"").Run ""$vbs"", 0, False`r`n", (New-Object System.Text.UTF8Encoding $false))
    $debut = (Get-Date).AddSeconds(-1)
    $bilans = @{}
    try {
        $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "//B //Nologo ""$l"""
        $principal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited
        $reglages = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName $tacheSonde -Action $action -Principal $principal -Settings $reglages -Force | Out-Null
        Start-ScheduledTask -TaskName $tacheSonde
        $bilans = Wait-Bilans $comptes $debut 20
    } catch {
        # Sans lecture dans la session, le contrôle s'en tient au registre.
    } finally {
        Unregister-ScheduledTask -TaskName $tacheSonde -Confirm:$false -ErrorAction SilentlyContinue
        Remove-Item $dossierSonde -Recurse -Force -ErrorAction SilentlyContinue
    }
    @{ sessions = @($comptes | ForEach-Object { $_.sid }); bilans = $bilans }
}

# --- Mode événement ----------------------------------------------------------------

$fichierEvenement = Join-Path $base 'mode-evenement.json'
$cleWU = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
$valeursWU = @('PauseUpdatesStartTime', 'PauseUpdatesExpiryTime', 'PauseFeatureUpdatesStartTime', 'PauseFeatureUpdatesEndTime', 'PauseQualityUpdatesStartTime', 'PauseQualityUpdatesEndTime')
$cleAU = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
# sous-groupe, réglage, GUID (pour une stratégie de groupe qui l'imposerait), nom
$reglagesVeille = @(
    @('SUB_SLEEP', 'STANDBYIDLE', '29f6c1db-86da-48c5-9fdb-f2b67b1f44da', 'mise en veille'),
    @('SUB_SLEEP', 'HIBERNATEIDLE', '9d7815a6-7ee4-497e-8888-515a05f02364', 'veille prolongée'),
    @('SUB_VIDEO', 'VIDEOIDLE', '3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e', 'extinction de l''écran')
)
$cleToast = 'Software\Microsoft\Windows\CurrentVersion\PushNotifications'
$cleNotif = 'Software\Microsoft\Windows\CurrentVersion\Notifications\Settings'
$cleCdm = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
$cleScoobe = 'Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement'
$valeursConseils = @('SubscribedContent-338389Enabled', 'SubscribedContent-310093Enabled', 'SubscribedContent-338388Enabled', 'SoftLandingEnabled', 'SystemPaneSuggestionsEnabled')
$toutesParties = @('windows_update', 'veille', 'notifications', 'conseils', 'fond')
$noms = @{ windows_update = 'Windows Update'; veille = 'Veille'; notifications = 'Notifications'; conseils = 'Conseils Windows'; fond = 'Écran « Mode événement »' }
# La clé de l'état d'avant que pilote.ps1 garde pour chaque partie activée.
$clesAvant = @{ windows_update = 'wu'; veille = 'veille'; notifications = 'toasts'; conseils = 'conseils' }

# Les deux dernières valeurs hexadécimales de powercfg /q : secteur puis batterie.
function Get-Veille([string]$Sous, [string]$Reglage) {
    $texte = (& powercfg.exe /q SCHEME_CURRENT $Sous $Reglage) -join "`n"
    $hex = @([regex]::Matches($texte, '0x[0-9a-fA-F]{8}') | ForEach-Object { $_.Value })
    if ($hex.Count -lt 2) { return $null }
    @([Convert]::ToInt64($hex[-2], 16), [Convert]::ToInt64($hex[-1], 16))
}

function Get-Duree([long]$Secondes) {
    if ($Secondes -eq 0) { return 'jamais' }
    "$([Math]::Round($Secondes / 60)) min"
}

function Get-DateUtc($Texte) {
    try { [datetime]::Parse([string]$Texte, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]'AdjustToUniversal, AssumeUniversal') } catch { $null }
}

function Test-WindowsUpdate([bool]$Actif, $Avant) {
    $au = Get-Valeur $cleAU 'NoAutoRebootWithLoggedOnUsers'
    if ($Actif) {
        $fin = Get-DateUtc (Get-Valeur $cleWU 'PauseUpdatesExpiryTime')
        if (-not $fin -or $fin -le [datetime]::UtcNow) { Add-Point 'Windows Update' $false 'pas en pause' }
        elseif ($au -ne 1) { Add-Point 'Windows Update' $false 'en pause, mais le redémarrage automatique reste permis' }
        else { Add-Point 'Windows Update' $true "en pause jusqu'au $($fin.ToLocalTime().ToString('dd/MM HH:mm')), sans redémarrage automatique" }
        return
    }
    $ko = @($valeursWU | Where-Object { -not (Test-Egal (Get-Valeur $cleWU $_) $Avant.wu.$_) })
    if (-not (Test-Egal $au $Avant.au)) { $ko += 'NoAutoRebootWithLoggedOnUsers' }
    if ($ko.Count) { Add-Point 'Windows Update' $false "pas rendu comme avant : $($ko -join ', ')" }
    else { Add-Point 'Windows Update' $true 'rendu comme avant l''événement' }
}

function Test-Veille([bool]$Actif, $Avant) {
    $ko = @()
    foreach ($r in $reglagesVeille) {
        if ($Actif) { $attendu = @(0, 0) }
        else {
            $a = @($Avant.veille | Where-Object { $_.reglage -eq $r[1] })
            if (-not $a.Count) { continue }
            $attendu = @([long]$a[0].ac, [long]$a[0].dc)
        }
        $v = Get-Veille $r[0] $r[1]
        $pol = Get-Valeur "HKLM:\SOFTWARE\Policies\Microsoft\Power\PowerSettings\$($r[2])" 'ACSettingIndex'
        if (-not $v) { $ko += "$($r[3]) illisible" }
        elseif ($v[0] -ne $attendu[0]) { $ko += "$($r[3]) : $(Get-Duree $v[0]) au lieu de $(Get-Duree $attendu[0])" }
        elseif ($v[1] -ne $attendu[1]) { $ko += "$($r[3]) sur batterie : $(Get-Duree $v[1]) au lieu de $(Get-Duree $attendu[1])" }
        elseif ($Actif -and $null -ne $pol -and $pol -ne 0) { $ko += "$($r[3]) imposée par une stratégie de groupe ($(Get-Duree $pol))" }
    }
    if ($ko.Count) { Add-Point 'Veille' $false ($ko -join ', ') }
    elseif ($Actif) { Add-Point 'Veille' $true 'jamais (veille, veille prolongée, écran), plan actif relu' }
    else { Add-Point 'Veille' $true 'rendue comme avant l''événement' }
}

function Test-Notifications([bool]$Actif, $Avant) {
    $sonde = Invoke-Sonde
    $etats = foreach ($sid in (Get-Ruches $Actif $Avant.toasts)) {
        $h = "Registry::HKEY_USERS\$sid"
        $t = Get-Valeur "$h\$cleToast" 'ToastEnabled'
        $g = Get-Valeur "$h\$cleNotif" 'NOC_GLOBAL_SETTING_TOASTS_ENABLED'
        if ($Actif) { $ecrit = ($t -eq 0 -and $g -eq 0); $coupees = $true }
        else {
            $f = Get-Ferme $sid
            if ($f) { $f; continue }
            $ecrit = (Test-Egal $t $Avant.toasts.$sid) -and (Test-Egal $g $Avant.global.$sid)
            $coupees = ($Avant.toasts.$sid -eq 0)
        }
        $nom = Get-Nom $sid
        $s = [string]$sonde.bilans[$sid].notifications
        if (-not $ecrit) { [pscustomobject]@{ ok = $false; texte = "$nom : réglage pas écrit" } }
        elseif ($sonde.sessions -notcontains $sid) { [pscustomobject]@{ ok = $true; texte = "$nom : réglé, appliqué à sa prochaine session" } }
        # Windows 11 ne rend plus l'effet dans la session (ToastNotifier.Setting
        # vide, 0x80070490, vu sur PN09 et PC-VANNH-BUREAU le 2026-11-05) : la
        # valeur relue dans la ruche de la session ouverte fait foi.
        elseif (-not $s -or $s -like 'illisible*') { [pscustomobject]@{ ok = $true; texte = "$nom : $(if ($Actif) { 'coupées' } else { 'rendues comme avant' }), relu dans le registre de sa session" } }
        elseif ($coupees -and $s -notlike 'Disabled*') { [pscustomobject]@{ ok = $false; texte = "$nom : réglé, mais Windows affiche encore les notifications" } }
        elseif (-not $coupees -and $s -eq 'DisabledForUser') { [pscustomobject]@{ ok = $false; texte = "$nom : réglé, mais Windows garde les notifications coupées" } }
        elseif ($coupees) { [pscustomobject]@{ ok = $true; texte = "$nom : coupées, relu par Windows" } }
        else { [pscustomobject]@{ ok = $true; texte = "$nom : rendues, relu par Windows" } }
    }
    Add-Comptes 'Notifications' $etats 'aucun compte ouvert, rien n''a été réglé' $Actif
}

function Test-Conseils([bool]$Actif, $Avant) {
    $etats = foreach ($sid in (Get-Ruches $Actif $Avant.conseils)) {
        $h = "Registry::HKEY_USERS\$sid"
        if (-not $Actif) { $f = Get-Ferme $sid; if ($f) { $f; continue } }
        $ko = @()
        foreach ($n in $valeursConseils) {
            $v = Get-Valeur "$h\$cleCdm" $n
            if (($Actif -and $v -ne 0) -or (-not $Actif -and -not (Test-Egal $v $Avant.conseils.$sid.$n))) { $ko += $n }
        }
        $v = Get-Valeur "$h\$cleScoobe" 'ScoobeSystemSettingEnabled'
        if (($Actif -and $v -ne 0) -or (-not $Actif -and -not (Test-Egal $v $Avant.conseils.$sid.scoobe))) { $ko += 'ScoobeSystemSettingEnabled' }
        $nom = Get-Nom $sid
        if ($ko.Count) { [pscustomobject]@{ ok = $false; texte = "$nom : pas écrit ($($ko -join ', '))" } }
        else { [pscustomobject]@{ ok = $true; texte = "$nom : relu dans le registre" } }
    }
    Add-Comptes 'Conseils Windows' $etats 'aucun compte ouvert, rien n''a été réglé' $Actif
}

# Le fond d'état est redessiné dans chaque session : « MODE ÉVÉNEMENT » sur fond noir pendant l'événement.
function Test-Fond([bool]$Noir) {
    $e = Read-Json (Join-Path $base 'fond\etat.json')
    $nom = $noms['fond']
    if (-not $e -or $e.retire) {
        if ($Noir) { Add-Point $nom $false 'l''état de l''écran n''a pas pu être posé : rien n''indique le mode à l''écran' }
        return
    }
    $comptes = @(Get-Sessions 'fond-resultat.json')
    if (-not $comptes.Count) { Add-Point $nom $null 'aucune session ouverte, appliqué à la prochaine'; return }
    $debut = (Get-Date).AddSeconds(-1)
    Start-ScheduledTask -TaskName 'PointeNoire-Fond' -ErrorAction SilentlyContinue
    $bilans = Wait-Bilans $comptes $debut 30
    $voulu = $(if ($Noir) { 'en mode événement' } else { 'rendu' })
    $etats = foreach ($c in $comptes) {
        $b = $bilans[$c.sid]
        if (-not $b) { [pscustomobject]@{ ok = $null; texte = "$($c.nom) : pas de réponse en 30 secondes" } }
        elseif (-not $b.ok) { [pscustomobject]@{ ok = $false; texte = "$($c.nom) : $($b.detail)" } }
        elseif ($b.detail -like 'aucun écran*') { [pscustomobject]@{ ok = $null; texte = "$($c.nom) : aucun écran actif" } }
        elseif ($null -eq $b.noir) { [pscustomobject]@{ ok = $null; texte = "$($c.nom) : fond d'état d'une ancienne version, à afficher de nouveau" } }
        elseif ([bool]$b.noir -ne $Noir) { [pscustomobject]@{ ok = $false; texte = "$($c.nom) : écran pas $voulu" } }
        else { [pscustomobject]@{ ok = $true; texte = "$($c.nom) : écran $voulu, relu par Windows" } }
    }
    Add-Comptes $nom $etats '' $false
}

function Test-Evenement([bool]$Actif, $Demande) {
    $parties = @(@($Demande) | Where-Object { $toutesParties -contains $_ })
    if (-not $parties.Count) { $parties = $toutesParties }
    $e = Read-Json $fichierEvenement
    if ($e -and -not $e.parties) { $e | Add-Member -NotePropertyName parties -NotePropertyValue @('windows_update', 'veille', 'notifications') }
    if ($Actif -and -not $e) { Add-Point 'Mode événement' $false 'pas enregistré sur le poste'; return }
    # Retour partiel : l'état d'avant reste dans le fichier ; complet : dans la copie rendue.
    $avant = $e
    if (-not $Actif -and -not $e) {
        $avant = Read-Json (Join-Path $base 'mode-evenement-rendu.json') 10
        if (-not $avant) { Add-Point 'Mode événement' $null 'déjà inactif, rien à comparer'; return }
    }
    foreach ($partie in $parties) {
        $active = $e -and (@($e.parties) -contains $partie)
        if ($Actif -and -not $active) { Add-Point $noms[$partie] $false 'pas enregistrée dans le mode événement'; continue }
        if (-not $Actif -and $active) { Add-Point $noms[$partie] $false 'encore active'; continue }
        # Une partie jamais activée pendant cet événement n'a rien à rendre.
        if (-not $Actif -and $clesAvant[$partie] -and $null -eq $avant.($clesAvant[$partie])) { continue }
        switch ($partie) {
            'windows_update' { Test-WindowsUpdate $Actif $avant }
            'veille' { Test-Veille $Actif $avant }
            'notifications' { Test-Notifications $Actif $avant }
            'conseils' { Test-Conseils $Actif $avant }
            'fond' { Test-Fond $Actif }
        }
    }
}

# --- Nettoyage ---------------------------------------------------------------------

$planEleve = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
# Les réglages posés par pilote.ps1 (cle, nom, valeur) : les mêmes, vérifié par les tests.
$reglagesNettoyage = @(
    @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection', 'AllowTelemetry', 1),
    @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR', 'AllowGameDVR', 0),
    @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent', 'DisableWindowsConsumerFeatures', 1),
    @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo', 'DisabledByGroupPolicy', 1),
    @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search', 'AllowCortana', 0),
    @('HKLM:\SOFTWARE\Policies\Microsoft\Dsh', 'AllowNewsAndInterests', 0),
    @('HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power', 'HiberbootEnabled', 0)
)

function Get-Plan {
    $texte = (& powercfg.exe /getactivescheme) -join ' '
    $m = [regex]::Match($texte, '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\s*(\((.+)\))?')
    if (-not $m.Success) { return $null }
    [pscustomobject]@{ guid = $m.Groups[1].Value.ToLower(); nom = $(if ($m.Groups[3].Success) { $m.Groups[3].Value.Trim() } else { $m.Groups[1].Value }) }
}

function Test-Nettoyage([bool]$Actif) {
    if ($Actif) { $e = Read-Json (Join-Path $base 'nettoyage.json') }
    else { $e = Read-Json (Join-Path $base 'nettoyage-rendu.json') 10 }
    if (-not $e) {
        if ($Actif) { Add-Point 'Profil' $false 'pas enregistré sur le poste' }
        else { Add-Point 'Profil' $null 'rien à comparer, le profil n''était pas appliqué' }
        return
    }
    $plan = Get-Plan
    $attendu = $(if ($Actif) { $(if ($e.plan.cree) { $e.plan.cree } else { $planEleve }) } else { $e.plan.avant })
    if ($attendu) {
        if (-not $plan) { Add-Point 'Plan d''alimentation' $null 'plan actif illisible' }
        elseif ($plan.guid -eq ([string]$attendu).ToLower()) { Add-Point 'Plan d''alimentation' $true "« $($plan.nom) » actif" }
        else { Add-Point 'Plan d''alimentation' $false "« $($plan.nom) » actif au lieu du plan attendu" }
    }
    $ko = @(); $n = 0
    foreach ($q in @($e.services.PSObject.Properties)) {
        $cle = "HKLM:\SYSTEM\CurrentControlSet\Services\$($q.Name)"
        if (-not (Test-Path $cle)) { continue }
        $n++
        $start = Get-Valeur $cle 'Start'
        if ($Actif) {
            $svc = Get-Service -Name $q.Name -ErrorAction SilentlyContinue
            if ($start -ne 4) { $ko += "$($q.Name) pas désactivé" }
            elseif ($svc -and $svc.Status -eq 'Running') { $ko += "$($q.Name) encore lancé" }
        } elseif (-not (Test-Egal $start $q.Value.start)) { $ko += "$($q.Name) pas rendu" }
    }
    if ($n) { Add-Point 'Services' (-not $ko.Count) $(if ($ko.Count) { $ko -join ', ' } elseif ($Actif) { "$n coupés" } else { "$n rendus" }) }
    $ko = @(); $n = 0
    foreach ($q in @($e.taches.PSObject.Properties)) {
        $i = $q.Name.LastIndexOf('\')
        $t = Get-ScheduledTask -TaskPath $q.Name.Substring(0, $i + 1) -TaskName $q.Name.Substring($i + 1) -ErrorAction SilentlyContinue
        if (-not $t) { continue }
        $n++
        $coupee = ($t.State -eq 'Disabled')
        if ($Actif -and -not $coupee) { $ko += "$($q.Name.Substring($i + 1)) encore active" }
        elseif (-not $Actif -and $q.Value -and $coupee) { $ko += "$($q.Name.Substring($i + 1)) encore coupée" }
    }
    if ($n) { Add-Point 'Tâches planifiées' (-not $ko.Count) $(if ($ko.Count) { $ko -join ', ' } elseif ($Actif) { "$n coupées" } else { "$n rendues" }) }
    $ko = @()
    if ($Actif) {
        $proteges = @($e.proteges | Where-Object { $_ })
        foreach ($r in $reglagesNettoyage) { if ($proteges -notcontains $r[1] -and -not (Test-Egal (Get-Valeur $r[0] $r[1]) $r[2])) { $ko += $r[1] } }
        $n = $reglagesNettoyage.Count - $proteges.Count
        if ($proteges.Count) { Add-Point 'Réglages protégés' $true "laissés à Windows, qui les protège (UCPD) : $($proteges -join ', ')" }
    } else {
        $n = 0
        foreach ($q in @($e.reglages.PSObject.Properties)) {
            $cle, $nom = $q.Name -split '\|', 2
            $n++
            if (-not (Test-Egal (Get-Valeur $cle $nom) $q.Value)) { $ko += $nom }
        }
    }
    if ($n) { Add-Point 'Réglages' (-not $ko.Count) $(if ($ko.Count) { "pas en place : $($ko -join ', ')" } elseif ($Actif) { "$n en place" } else { "$n rendus" }) }
    $apps = @($e.applications | Where-Object { $_ })
    if ($Actif -and $apps.Count) {
        # Un paquet seulement préparé (Staged) n'est installé pour personne.
        $installees = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object { @($_.PackageUserInformation | Where-Object { [string]$_.InstallState -eq 'Installed' }).Count } | ForEach-Object { $_.Name })
        $restees = @($apps | Where-Object { $installees -contains $_ })
        Add-Point 'Applications' (-not $restees.Count) $(if ($restees.Count) { "encore là : $($restees -join ', ')" } else { "$($apps.Count) retirées" })
    }
}

# --- Supervision -------------------------------------------------------------------

function Test-Supervision([bool]$Actif) {
    $d = Join-Path $base 'supervision'
    $tache = 'PointeNoire-Supervision'
    $t = Get-ScheduledTask -TaskName $tache -ErrorAction SilentlyContinue
    if (-not $Actif) {
        $reste = @()
        if ($t) { $reste += 'la tâche' }
        if (Test-Path $d) { $reste += 'le dossier' }
        if ($reste.Count) { Add-Point 'Sonde' $false "encore là : $($reste -join ', ')" } else { Add-Point 'Sonde' $true 'retirée' }
        return
    }
    $conf = Get-Item -LiteralPath (Join-Path $d 'config.json') -ErrorAction SilentlyContinue
    if (-not $t -or -not $conf) { Add-Point 'Sonde' $false 'pas installée'; return }
    # Premier passage 10 secondes après la pose : il envoie la première mesure.
    for ($i = 0; $i -lt 45; $i++) {
        $t = Get-ScheduledTask -TaskName $tache
        $info = $t | Get-ScheduledTaskInfo
        if ($t.State -eq 'Disabled' -or ($info.LastRunTime -ge $conf.LastWriteTime -and $t.State -ne 'Running')) { break }
        Start-Sleep -Seconds 1
    }
    if ($t.State -eq 'Disabled') { Add-Point 'Sonde' $false 'coupée : AVDiagram a refusé son jeton' }
    elseif ($info.LastRunTime -lt $conf.LastWriteTime) { Add-Point 'Sonde' $null 'pas encore passée après 45 secondes' }
    elseif ($info.LastTaskResult -ne 0) { Add-Point 'Sonde' $false "arrêtée en erreur (code $($info.LastTaskResult))" }
    elseif (Test-Path (Join-Path $d 'en-attente.json')) { Add-Point 'Sonde' $false 'mesures en attente, AVDiagram ne les a pas reçues' }
    else { Add-Point 'Sonde' $true "première mesure envoyée à $($info.LastRunTime.ToString('HH:mm:ss'))" }
}

# L'écran du poste montre ses dernières actions : celle-ci y passe en échec
# quand Windows ne l'a pas appliquée.
function Update-Historique([string]$Op) {
    $f = Join-Path $base 'fond\etat.json'
    $e = Read-Json $f
    if (-not $e -or -not $e.historique -or -not @($points | Where-Object { $_.ok -eq $false }).Count) { return }
    $h = @($e.historique)[0]
    if ([string]$h.op -ne $Op -or -not $h.ok) { return }
    $h.ok = $false
    $h.texte = "$($h.texte), pas appliqué"
    [IO.File]::WriteAllText($f, ($e | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding $false))
    Start-ScheduledTask -TaskName 'PointeNoire-Fond' -ErrorAction SilentlyContinue
}

# --- Entrée --------------------------------------------------------------------

try {
    $p = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:PNPL_PARAMS)) | ConvertFrom-Json
    switch ($p.quoi) {
        'evenement' { Test-Evenement ([bool]$p.actif) $p.parties }
        'nettoyage' { Test-Nettoyage ([bool]$p.actif) }
        'supervision' { Test-Supervision ([bool]$p.actif) }
        default { throw "contrôle inconnu : $($p.quoi)" }
    }
    try { Update-Historique ([string]$p.quoi) } catch { }
    $result.ok = $true
} catch {
    $result.detail = "$($_.Exception.Message) (controle.ps1, ligne $($_.InvocationInfo.ScriptLineNumber))"
}
$result.points = @($points.ToArray())
$json = $result | ConvertTo-Json -Compress -Depth 5
'PNPL1:' + $env:PNPL_NONCE + ':' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))

<#
  Mises à jour par étapes (Windows, pilotes, logiciels winget), lancé par
  l'agent MeshCentral (compte SYSTEM). Compatible Windows PowerShell 5.1.

  PNPL_PARAMS : JSON en base64 UTF-8, avec `op` :
    releve     { logiciels: [id winget] } : ce que Windows Update propose
               (correctifs, pilotes dont la carte graphique), et pour chaque
               logiciel du catalogue la version posée et la version disponible.
               Ne change rien.
    appliquer  { windows: [{ id, rev }], logiciels: [{ id, version }],
               redemarrer, campagne } : installe exactement ces mises à jour,
               dans une tâche planifiée SYSTEM (PointeNoire-MiseAJour) qui
               survit à la fin de la commande et au redémarrage. Refusé en
               mode événement.
    resultat   l'état de la dernière installation (maj\etat.json), et l'heure
               du dernier démarrage de Windows.
    report     { jours } : garde le poste derrière le pilote. Windows Pro :
               stratégie locale de report des correctifs (jours) et pilotes
               exclus de Windows Update automatique. Windows Famille, où ces
               stratégies ne s'appliquent pas : Windows Update en pause pour
               jours + 1, renouvelée chaque semaine par le relais. 0 retire le
               report (le pilote). Sans `jours`, le dernier choix du poste
               (maj\report.json) est reposé. Rend les points relus.

  Sortie : PNPL1:<jeton>:<JSON en base64> avec { op, ok, detail, ... }.

  Pourquoi une tâche planifiée : l'agent MeshCentral ne lance qu'une commande
  à la fois par poste, et une installation de Windows Update dure souvent
  plus d'une demi-heure. L'API Windows Update refuse aussi de télécharger et
  d'installer depuis une session distante ; une tâche planifiée SYSTEM le
  peut. Le poste reste libre pour les autres actions pendant l'installation.

  La même tâche lance ce script avec l'argument `executer` : il se recopie
  pour cela dans ProgramData\PointeNoire\maj\majwin.ps1.

  Les mises à jour de fonctionnalité (24H2 vers 25H2) ne sont jamais
  relevées ni installées ici.
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$base = Join-Path $env:ProgramData 'PointeNoire'
$dossierMaj = Join-Path $base 'maj'
$fichierEtat = Join-Path $dossierMaj 'etat.json'
$fichierDemande = Join-Path $dossierMaj 'demande.json'
$fichierScript = Join-Path $dossierMaj 'majwin.ps1'
$fichierEvenement = Join-Path $base 'mode-evenement.json'
$tacheMaj = 'PointeNoire-MiseAJour'
$fichierReport = Join-Path $dossierMaj 'report.json'
$clePol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$valeursPol = @('DeferQualityUpdates', 'DeferQualityUpdatesPeriodInDays', 'ExcludeWUDriversInQualityUpdate')
$cleWU = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
$valeursPause = @('PauseUpdatesStartTime', 'PauseUpdatesExpiryTime', 'PauseQualityUpdatesStartTime', 'PauseQualityUpdatesEndTime', 'PauseFeatureUpdatesStartTime', 'PauseFeatureUpdatesEndTime')
$result = [ordered]@{ op = $null; ok = $false; detail = '' }
# Le texte de ce script, recopié pour la tâche planifiée : la commande du
# relais le garde dans $s avant de le lancer.
$moiMeme = $null
try { $moiMeme = [string]$s } catch { }
if (-not $moiMeme) { $moiMeme = [string]$MyInvocation.MyCommand.Definition }

# Catégories de Windows Update (identifiants publiés par Microsoft).
$catFonction = '3689bdc8-b205-4af4-8d4b-a63924c5e9d5'
$catDefinition = 'e0789628-ce08-4437-be74-2495b842f43b'
$catSecurite = '0fa1201d-4330-4fa8-8ae9-b877473b6441'
$catCritique = 'e6cf1350-c01b-414d-a61f-263d14d133b4'

function Send-Result {
    $json = $result | ConvertTo-Json -Compress -Depth 6
    'PNPL1:' + $env:PNPL_NONCE + ':' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
}

function Write-Utf8([string]$Path, [string]$Text, [bool]$Bom = $false) {
    [IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding $Bom))
}

function Read-Json([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    try { Get-Content -Raw -Encoding UTF8 $Path | ConvertFrom-Json } catch { $null }
}

function Test-Evenement {
    $e = Read-Json $fichierEvenement
    return [bool]($e -and $e.actif)
}

function Get-Demarrage {
    try { ([Management.ManagementDateTimeConverter]::ToDateTime((Get-WmiObject Win32_OperatingSystem).LastBootUpTime)).ToUniversalTime().ToString('o') } catch { $null }
}

function Test-RedemarrageAttendu {
    (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
    (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
}

function Get-Valeur([string]$Cle, [string]$Nom) {
    $v = Get-ItemProperty -Path $Cle -Name $Nom -ErrorAction SilentlyContinue
    if ($v) { return $v.$Nom }
    return $null
}

function Set-Valeur([string]$Cle, [string]$Nom, $Valeur, [string]$Type) {
    if ($null -eq $Valeur) {
        Remove-ItemProperty -Path $Cle -Name $Nom -ErrorAction SilentlyContinue
        return
    }
    if (-not (Test-Path $Cle)) { New-Item -Path $Cle -Force | Out-Null }
    New-ItemProperty -Path $Cle -Name $Nom -Value $Valeur -PropertyType $Type -Force | Out-Null
}

# Windows Famille (EditionID Core, CoreSingleLanguage...) ignore les
# stratégies de Windows Update pour les entreprises.
function Test-Famille {
    [string](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').EditionID -like 'Core*'
}

# Pose le report, sans toucher à la pause du mode événement (pilote.ps1 la
# garde et la rend à la fin du mode).
function Set-Report([int]$Jours) {
    $famille = Test-Famille
    if ($famille) {
        if (-not (Test-Evenement)) {
            if ($Jours -gt 0) {
                $debut = (Get-Date).ToUniversalTime(); $fin = $debut.AddDays($Jours + 1); $f = 'yyyy-MM-ddTHH:mm:ssZ'
                foreach ($n in @('PauseUpdatesStartTime', 'PauseQualityUpdatesStartTime', 'PauseFeatureUpdatesStartTime')) { Set-Valeur $cleWU $n $debut.ToString($f) 'String' }
                foreach ($n in @('PauseUpdatesExpiryTime', 'PauseQualityUpdatesEndTime', 'PauseFeatureUpdatesEndTime')) { Set-Valeur $cleWU $n $fin.ToString($f) 'String' }
            } else {
                $avant = Read-Json $fichierReport
                if ($avant -and $avant.mode -eq 'pause') { foreach ($n in $valeursPause) { Set-Valeur $cleWU $n $null '' } }
            }
        }
    } else {
        if ($Jours -gt 0) {
            Set-Valeur $clePol 'DeferQualityUpdates' 1 'DWord'
            Set-Valeur $clePol 'DeferQualityUpdatesPeriodInDays' $Jours 'DWord'
            Set-Valeur $clePol 'ExcludeWUDriversInQualityUpdate' 1 'DWord'
        } else {
            foreach ($n in $valeursPol) { Set-Valeur $clePol $n $null '' }
        }
    }
    if (-not (Test-Path $dossierMaj)) { New-Item -ItemType Directory -Path $dossierMaj -Force | Out-Null }
    Write-Utf8 $fichierReport (([ordered]@{ jours = $Jours; mode = $(if ($famille) { 'pause' } else { 'strategie' }); le = (Get-Date).ToUniversalTime().ToString('o') }) | ConvertTo-Json)
}

function Get-PointsReport([int]$Jours) {
    $pts = New-Object System.Collections.ArrayList
    if (Test-Famille) {
        $fin = Get-Valeur $cleWU 'PauseUpdatesExpiryTime'
        if (Test-Evenement) {
            [void]$pts.Add([ordered]@{ nom = 'Pause de Windows Update'; ok = $null; constat = "mode événement : pause du mode jusqu'au $fin" })
        } elseif ($Jours -gt 0) {
            $ok = $false
            try { $ok = ([datetime]::Parse($fin).ToUniversalTime() -gt (Get-Date).ToUniversalTime().AddDays($Jours - 1)) } catch { }
            [void]$pts.Add([ordered]@{ nom = 'Pause de Windows Update'; ok = $ok; constat = $(if ($fin) { "jusqu'au $fin" } else { 'pas de pause' }) })
        } else {
            [void]$pts.Add([ordered]@{ nom = 'Pause de Windows Update'; ok = $true; constat = $(if ($fin) { "pause d'avant gardée jusqu'au $fin" } else { 'pas de pause' }) })
        }
    } else {
        $d = Get-Valeur $clePol 'DeferQualityUpdatesPeriodInDays'
        $x = Get-Valeur $clePol 'ExcludeWUDriversInQualityUpdate'
        if ($Jours -gt 0) {
            [void]$pts.Add([ordered]@{ nom = 'Report des correctifs'; ok = ([int]$d -eq $Jours -and [int](Get-Valeur $clePol 'DeferQualityUpdates') -eq 1); constat = "$d jour(s)" })
            [void]$pts.Add([ordered]@{ nom = 'Pilotes hors Windows Update'; ok = ([int]$x -eq 1); constat = $(if ([int]$x -eq 1) { 'exclus' } else { 'pas exclus' }) })
        } else {
            [void]$pts.Add([ordered]@{ nom = 'Report des correctifs'; ok = ($null -eq $d); constat = $(if ($null -eq $d) { 'aucun' } else { "$d jour(s)" }) })
        }
    }
    return , @($pts)
}

function Invoke-Report($Demande) {
    $jours = $null
    if ($null -ne $Demande.jours) { $jours = [int]$Demande.jours }
    if ($null -eq $jours) {
        $avant = Read-Json $fichierReport
        if (-not $avant) { $result.ok = $true; $result.detail = 'aucun report demandé sur ce poste'; $result.points = @(); return }
        $jours = [int]$avant.jours
    }
    if ($jours -lt 0 -or $jours -gt 30) { $result.detail = "report refusé : $jours jours"; return }
    Set-Report $jours
    $result.points = Get-PointsReport $jours
    $result.ok = $true
    $quoi = $(if (Test-Famille) { 'pause de Windows Update' } else { 'stratégie de report' })
    $result.detail = $(if ($jours -gt 0) { "$quoi : $jours jours derrière le pilote" } else { 'aucun report : le poste reçoit Windows Update comme le pilote' })
}

# Pendant l'installation demandée : le report et la pause levés, sinon
# Windows Update cache au poste ce que le pilote a validé. Remis ensuite.
function Suspend-Report {
    $r = Read-Json $fichierReport
    if (-not $r -or [int]$r.jours -le 0) { return $null }
    if (Test-Famille) { foreach ($n in $valeursPause) { Set-Valeur $cleWU $n $null '' } }
    else { foreach ($n in $valeursPol) { Set-Valeur $clePol $n $null '' } }
    try { & "$env:SystemRoot\System32\UsoClient.exe" RefreshSettings 2>$null | Out-Null } catch { }
    return [int]$r.jours
}

function Get-Winget {
    $w = Get-ChildItem -Path "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe" -ErrorAction SilentlyContinue |
        Sort-Object -Property { $_.Directory.Name } | Select-Object -Last 1
    if ($w) { return $w.FullName }
    return $null
}

# La ligne de `winget list --id X --exact` qui porte l'identifiant : la suite
# donne la version posée, la version disponible s'il y en a une, puis la
# source. Lu par position des mots, pas par les en-têtes (qui suivent la
# langue de Windows).
function Get-Version([string]$Wg, [string]$Id) {
    $lignes = @(& $Wg list --id $Id --exact --accept-source-agreements --disable-interactivity 2>$null)
    foreach ($l in $lignes) {
        $mots = @(([string]$l).Trim() -split '\s+')
        $i = -1
        for ($k = 0; $k -lt $mots.Count; $k++) {
            $m = $mots[$k]
            if ($m -ieq $Id -or ($m.EndsWith([string][char]0x2026) -and $Id.StartsWith($m.TrimEnd([char]0x2026), 'OrdinalIgnoreCase'))) { $i = $k; break }
        }
        if ($i -lt 0) { continue }
        $reste = @($mots | Select-Object -Skip ($i + 1))
        if ($reste.Count -and @('winget', 'msstore') -contains $reste[-1]) { $reste = @($reste | Select-Object -First ($reste.Count - 1)) }
        if (-not $reste.Count) { continue }
        $dispo = $null
        if ($reste.Count -ge 2) { $dispo = $reste[1] }
        return [ordered]@{ id = $Id; installe = $reste[0]; disponible = $dispo }
    }
    return [ordered]@{ id = $Id; installe = $null; disponible = $null }
}

function Get-Genre($U) {
    if ([int]$U.Type -eq 2) { return 'pilote' }
    $ids = @($U.Categories | ForEach-Object { [string]$_.CategoryID })
    if ($ids -contains $catFonction) { return 'fonction' }
    if ($ids -contains $catDefinition) { return 'definition' }
    if ($U.MsrcSeverity -or $ids -contains $catSecurite -or $ids -contains $catCritique) { return 'securite' }
    return 'qualite'
}

function Find-Mises {
    $session = New-Object -ComObject Microsoft.Update.Session
    $session.ClientApplicationID = 'Pointe Noire'
    $chercheur = $session.CreateUpdateSearcher()
    $trouve = $chercheur.Search("IsInstalled=0 and IsHidden=0 and Type='Software' or IsInstalled=0 and IsHidden=0 and Type='Driver'")
    return , @($session, $trouve.Updates)
}

function Get-Releve($Demande) {
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $result.windows_version = [ordered]@{ edition = [string]$cv.EditionID; version = [string]$cv.DisplayVersion; build = "$($cv.CurrentBuild).$($cv.UBR)" }
    $result.evenement = Test-Evenement
    $result.redemarrage_attendu = [bool](Test-RedemarrageAttendu)
    $result.demarre_le = Get-Demarrage
    try { $result.pause_jusqu_au = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' -Name PauseUpdatesExpiryTime -ErrorAction Stop).PauseUpdatesExpiryTime } catch { $result.pause_jusqu_au = $null }
    $windows = New-Object System.Collections.ArrayList
    try {
        $r = Find-Mises
        foreach ($u in $r[1]) {
            $genre = Get-Genre $u
            if ($genre -eq 'fonction') { continue }
            $classe = $null
            if ([int]$u.Type -eq 2) { try { $classe = [string]$u.DriverClass } catch { } }
            $kb = @($u.KBArticleIDs | ForEach-Object { 'KB' + $_ })
            [void]$windows.Add([ordered]@{
                id = [string]$u.Identity.UpdateID
                rev = [int]$u.Identity.RevisionNumber
                titre = [string]$u.Title
                kb = ($kb -join ' ')
                genre = $genre
                gpu = ($classe -eq 'Display')
                classe = $classe
                taille_mo = [math]::Round([double]$u.MaxDownloadSize / 1MB, 1)
                gravite = [string]$u.MsrcSeverity
            })
        }
        $result.windows_ok = $true
    } catch {
        $result.windows_ok = $false
        $result.windows_erreur = $_.Exception.Message
    }
    $result.windows = @($windows)
    $logiciels = New-Object System.Collections.ArrayList
    $ids = @($Demande.logiciels | Where-Object { $_ -match '^[A-Za-z0-9][A-Za-z0-9.+_-]{0,127}$' })
    if ($ids.Count) {
        $wg = Get-Winget
        if ($wg) {
            foreach ($id in $ids) { [void]$logiciels.Add((Get-Version $wg $id)) }
        } else {
            $result.winget_erreur = 'winget introuvable (App Installer absent du poste)'
        }
    }
    $result.logiciels = @($logiciels)
    $nb = $windows.Count
    $nbl = @($logiciels | Where-Object { $_.disponible }).Count
    $txt = "$nb mise(s) à jour Windows, $nbl logiciel(s) à mettre à jour"
    if (-not $result.windows_ok) { $txt = "Windows Update illisible ($($result.windows_erreur)), $nbl logiciel(s) à mettre à jour" }
    $result.ok = [bool]$result.windows_ok
    $result.detail = $txt
}

function Save-Etat($Etat) {
    $Etat.maj_le = (Get-Date).ToUniversalTime().ToString('o')
    Write-Utf8 $fichierEtat ($Etat | ConvertTo-Json -Depth 6)
}

function Start-Application($Demande) {
    if (Test-Evenement) { $result.detail = 'refusé : le poste est en mode événement'; return }
    $enCours = Read-Json $fichierEtat
    $tache = Get-ScheduledTask -TaskName $tacheMaj -ErrorAction SilentlyContinue
    if ($enCours -and $enCours.etape -eq 'en_cours' -and $tache -and $tache.State -eq 'Running') {
        $result.detail = 'refusé : une installation est déjà en cours sur ce poste'
        return
    }
    $src = $moiMeme
    if (-not $src -or $src.Length -lt 1000) { $result.detail = 'texte du script introuvable, installation non lancée'; return }
    if (-not (Test-Path $dossierMaj)) { New-Item -ItemType Directory -Path $dossierMaj -Force | Out-Null }
    # Le fichier lu par powershell.exe -File : avec BOM, sinon lu en ANSI.
    Write-Utf8 $fichierScript $src $true
    Write-Utf8 $fichierDemande ($Demande | ConvertTo-Json -Depth 6)
    Save-Etat ([ordered]@{ etape = 'demande'; campagne = $Demande.campagne; debut = $null; fin = $null; elements = @(); redemarrage = $false; redemarre = $false; detail = 'en attente de la tâche planifiée' })
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$fichierScript`" executer"
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $reglages = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 3) -StartWhenAvailable
    Register-ScheduledTask -TaskName $tacheMaj -Action $action -Principal $principal -Settings $reglages -Force | Out-Null
    Start-ScheduledTask -TaskName $tacheMaj
    $result.ok = $true
    $result.detail = 'installation lancée par la tâche planifiée'
}

function Get-Resultat {
    $e = Read-Json $fichierEtat
    $result.ok = $true
    $result.etat = $e
    $result.demarre_le = Get-Demarrage
    $result.redemarrage_attendu = [bool](Test-RedemarrageAttendu)
    $result.evenement = Test-Evenement
    $t = Get-ScheduledTask -TaskName $tacheMaj -ErrorAction SilentlyContinue
    $result.tache = $(if ($t) { [string]$t.State } else { $null })
    $result.detail = $(if ($e) { [string]$e.etape } else { 'aucune installation' })
}

# Le point de restauration avant de toucher Windows : seulement si la
# protection du système est déjà active (elle n'est pas activée ici).
function New-PointRestauration {
    try {
        $cle = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
        New-ItemProperty -Path $cle -Name SystemRestorePointCreationFrequency -Value 0 -PropertyType DWord -Force | Out-Null
        Checkpoint-Computer -Description 'Pointe Noire avant mises à jour' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        return 'point de restauration créé'
    } catch {
        return "pas de point de restauration ($($_.Exception.Message))"
    }
}

function Invoke-Execution {
    $d = Read-Json $fichierDemande
    $etat = [ordered]@{ etape = 'en_cours'; campagne = $d.campagne; debut = (Get-Date).ToUniversalTime().ToString('o'); fin = $null; elements = @(); redemarrage = $false; redemarre = $false; detail = '' }
    $elements = New-Object System.Collections.ArrayList
    if (Test-Evenement) {
        $etat.etape = 'refuse'; $etat.detail = 'mode événement activé avant le départ'; $etat.fin = (Get-Date).ToUniversalTime().ToString('o')
        Save-Etat $etat
        return
    }
    Save-Etat $etat
    $notes = @()
    $demandes = @($d.windows | Where-Object { $_.id })
    $report = $null
    if ($demandes.Count) {
        $notes += New-PointRestauration
        $report = Suspend-Report
        try {
            $r = Find-Mises
            $session = $r[0]
            $voulus = @{}
            foreach ($w in $demandes) { $voulus[[string]$w.id] = $w }
            $lot = New-Object -ComObject Microsoft.Update.UpdateColl
            $ids = New-Object System.Collections.ArrayList
            $trouves = @{}
            foreach ($u in $r[1]) {
                $id = [string]$u.Identity.UpdateID
                # Le même correctif (même KB) peut porter un autre identifiant
                # sur un autre poste : il compte pour la mise à jour approuvée.
                $kbs = @($u.KBArticleIDs | ForEach-Object { 'KB' + $_ })
                if (-not $voulus.ContainsKey($id)) {
                    foreach ($w in $demandes) {
                        $kbVoulus = @(([string]$w.kb) -split ' ' | Where-Object { $_ })
                        if (@($kbVoulus | Where-Object { $kbs -contains $_ }).Count) { $id = [string]$w.id; break }
                    }
                }
                if (-not $voulus.ContainsKey($id) -or (Get-Genre $u) -eq 'fonction' -or $trouves.ContainsKey($id)) { continue }
                if (-not $u.EulaAccepted) { $u.AcceptEula() }
                [void]$lot.Add($u)
                [void]$ids.Add($id)
                $trouves[$id] = [string]$u.Title
            }
            foreach ($w in $demandes) {
                if (-not $trouves.ContainsKey([string]$w.id)) {
                    [void]$elements.Add([ordered]@{ genre = 'windows'; id = [string]$w.id; titre = [string]$w.titre; etat = 'absente'; code = $null; constat = 'pas proposée à ce poste (déjà posée, matériel ou version de Windows différents)' })
                }
            }
            if ($lot.Count) {
                $etat.detail = "téléchargement de $($lot.Count) mise(s) à jour Windows"; Save-Etat $etat
                $dl = $session.CreateUpdateDownloader(); $dl.Updates = $lot; [void]$dl.Download()
                $etat.detail = "installation de $($lot.Count) mise(s) à jour Windows"; Save-Etat $etat
                $inst = $session.CreateUpdateInstaller(); $inst.Updates = $lot
                $res = $inst.Install()
                for ($i = 0; $i -lt $lot.Count; $i++) {
                    $ur = $res.GetUpdateResult($i)
                    $code = [int]$ur.ResultCode
                    $ok = ($code -eq 2 -or $code -eq 3)
                    [void]$elements.Add([ordered]@{ genre = 'windows'; id = [string]$ids[$i]; titre = [string]$lot.Item($i).Title; etat = $(if ($ok) { 'installee' } else { 'echec' }); code = ('0x{0:X8}' -f $ur.HResult); constat = $(if ($ur.RebootRequired) { 'redémarrage demandé' } else { '' }) })
                }
                if ($res.RebootRequired) { $etat.redemarrage = $true }
            }
        } catch {
            [void]$elements.Add([ordered]@{ genre = 'windows'; id = $null; titre = 'Windows Update'; etat = 'echec'; code = $null; constat = $_.Exception.Message })
        }
        if ($null -ne $report) {
            Set-Report $report
            $notes += "report de $report jours remis"
        }
    }
    $logiciels = @($d.logiciels | Where-Object { $_.id -match '^[A-Za-z0-9][A-Za-z0-9.+_-]{0,127}$' })
    if ($logiciels.Count) {
        $wg = Get-Winget
        foreach ($l in $logiciels) {
            if (Test-Evenement) {
                [void]$elements.Add([ordered]@{ genre = 'logiciel'; id = [string]$l.id; titre = [string]$l.id; etat = 'refuse'; code = $null; constat = 'mode événement activé pendant les mises à jour' })
                continue
            }
            if (-not $wg) {
                [void]$elements.Add([ordered]@{ genre = 'logiciel'; id = [string]$l.id; titre = [string]$l.id; etat = 'echec'; code = $null; constat = 'winget introuvable' })
                continue
            }
            $etat.detail = "mise à jour de $($l.id)"; Save-Etat $etat
            $args2 = @('upgrade', '--id', [string]$l.id, '--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity', '--include-unknown')
            if ($l.version -and [string]$l.version -match '^[\w.+-]{1,64}$') { $args2 += @('--version', [string]$l.version) }
            & $wg @args2 *> $null
            $code = $LASTEXITCODE
            $v = Get-Version $wg ([string]$l.id)
            # 0x8A15002B : pas de mise à jour applicable (déjà à cette version).
            $ok = ($code -eq 0 -or $code -eq -1978335189 -or ($l.version -and $v.installe -eq [string]$l.version))
            if ($code -eq -1978334967 -or $code -eq -1978334966) { $etat.redemarrage = $true; $ok = $true }
            [void]$elements.Add([ordered]@{ genre = 'logiciel'; id = [string]$l.id; titre = [string]$l.id; etat = $(if ($ok) { 'installee' } else { 'echec' }); code = ('0x{0:X8}' -f $code); constat = "version posée : $($v.installe)" })
        }
    }
    $etat.elements = @($elements)
    if (Test-RedemarrageAttendu) { $etat.redemarrage = $true }
    $nbOk = @($elements | Where-Object { $_.etat -eq 'installee' }).Count
    $nbKo = @($elements | Where-Object { $_.etat -eq 'echec' }).Count
    $etat.detail = (@("$nbOk posée(s), $nbKo en échec") + $notes) -join ', '
    if ($etat.redemarrage -and $d.redemarrer -and -not (Test-Evenement)) {
        $etat.redemarre = $true
        $etat.detail += ', redémarrage dans 2 minutes'
    }
    $etat.etape = 'termine'
    $etat.fin = (Get-Date).ToUniversalTime().ToString('o')
    Save-Etat $etat
    if ($etat.redemarre) {
        & shutdown.exe /r /t 120 /c 'Mises à jour Pointe Noire : redémarrage dans 2 minutes.' /d p:2:17 | Out-Null
    }
}

if ($args.Count -and $args[0] -eq 'executer') {
    try { Invoke-Execution } catch {
        Save-Etat ([ordered]@{ etape = 'termine'; debut = $null; fin = (Get-Date).ToUniversalTime().ToString('o'); elements = @(); redemarrage = $false; redemarre = $false; detail = "erreur : $($_.Exception.Message)" })
    }
    return
}

try {
    $demande = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:PNPL_PARAMS)) | ConvertFrom-Json
    $result.op = [string]$demande.op
    switch ($result.op) {
        'releve' { Get-Releve $demande }
        'appliquer' { Start-Application $demande }
        'resultat' { Get-Resultat }
        'report' { Invoke-Report $demande }
        default { $result.detail = "opération inconnue : $($result.op)" }
    }
} catch {
    $result.ok = $false
    $result.detail = "erreur : $($_.Exception.Message)"
}
Send-Result

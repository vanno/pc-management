<#
  Pose ou retire le fond d'état d'un poste (agent/fond.ps1). Lancé par l'agent
  MeshCentral (compte SYSTEM), à part de pilote.ps1 pour rester sous la
  longueur de commande de l'agent. Compatible Windows PowerShell 5.1.

  PNPL_PARAMS : { op: fond, actif, reference, script } (script : fond.ps1,
  gzip puis base64). Sortie : PNPL1:<jeton>:<JSON en base64>, comme pilote.ps1.

  Pose : C:\ProgramData\PointeNoire\fond (lecture seule pour les comptes),
  la tâche PointeNoire-Fond (groupe Utilisateurs : ouverture de session,
  toutes les 15 minutes), lancée par wscript sans fenêtre, et l'icône
  « État du poste » du Bureau public.
  Retrait : chaque compte ouvert retrouve son fond d'origine ; un compte fermé
  le retrouve à sa prochaine ouverture de session, la tâche restant 7 jours
  en mode retrait avant de partir.

  Le résultat dit ce qui s'est passé dans chaque session ouverte : fond.ps1 y
  écrit son bilan (%LOCALAPPDATA%\PointeNoire\fond-resultat.json), relu ici
  pendant 30 secondes au plus. Un échec dans une session rend la tâche en échec.
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$dossier = Join-Path $env:ProgramData 'PointeNoire\fond'
$tache = 'PointeNoire-Fond'
$icone = Join-Path $env:PUBLIC 'Desktop\État du poste.lnk'
$result = [ordered]@{ op = 'fond'; ok = $false; detail = '' }

function Write-Texte([string]$Chemin, [string]$Texte, [bool]$Bom) {
    [IO.File]::WriteAllText($Chemin, $Texte, (New-Object System.Text.UTF8Encoding $Bom))
}

# Les comptes ouverts : le propriétaire de chaque explorer.exe, et le bilan que
# fond.ps1 laisse dans son profil.
function Get-Comptes {
    $vus = @{}
    foreach ($x in @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue)) {
        $sid = (Invoke-CimMethod -InputObject $x -MethodName GetOwnerSid -ErrorAction SilentlyContinue).Sid
        if (-not $sid -or $vus.ContainsKey($sid)) { continue }
        $profil = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" -ErrorAction SilentlyContinue).ProfileImagePath
        if (-not $profil) { continue }
        $nom = [string](Invoke-CimMethod -InputObject $x -MethodName GetOwner -ErrorAction SilentlyContinue).User
        $vus[$sid] = [pscustomobject]@{ nom = $(if ($nom) { $nom } else { Split-Path $profil -Leaf }); fichier = Join-Path $profil 'AppData\Local\PointeNoire\fond-resultat.json' }
    }
    @($vus.Values | Sort-Object nom)
}

# Lance la tâche dans les sessions ouvertes et attend leur bilan.
function Invoke-Sessions([string]$SansCompte) {
    $debut = (Get-Date).AddSeconds(-1)
    Start-ScheduledTask -TaskName $tache -ErrorAction SilentlyContinue
    $comptes = @(Get-Comptes)
    if (-not $comptes.Count) { return @{ echec = $false; texte = $SansCompte; points = @() } }
    $bilans = @{}
    for ($i = 0; $i -lt 30 -and $bilans.Count -lt $comptes.Count; $i++) {
        Start-Sleep -Seconds 1
        foreach ($c in $comptes) {
            if ($bilans.ContainsKey($c.nom)) { continue }
            $f = Get-Item -LiteralPath $c.fichier -ErrorAction SilentlyContinue
            if ($f -and $f.LastWriteTime -ge $debut) {
                try { $bilans[$c.nom] = Get-Content -Raw -Encoding UTF8 -LiteralPath $c.fichier | ConvertFrom-Json } catch { }
            }
        }
    }
    # Un point de contrôle par session, comme agent/controle.ps1 (ok nul : pas relu).
    $points = foreach ($c in $comptes) {
        $b = $bilans[$c.nom]
        if (-not $b) { [ordered]@{ nom = "Session de $($c.nom)"; ok = $null; constat = 'pas de réponse en 30 secondes, nouvel essai dans 15 minutes' } }
        elseif ($b.ok) { [ordered]@{ nom = "Session de $($c.nom)"; ok = $true; constat = [string]$b.detail } }
        else { [ordered]@{ nom = "Session de $($c.nom)"; ok = $false; constat = "échec, $(([string]$b.detail).Substring(0, [Math]::Min(200, ([string]$b.detail).Length)))" } }
    }
    $points = @($points)
    @{ echec = [bool]@($points | Where-Object { $_.ok -eq $false }).Count; texte = (($points | ForEach-Object { "$($_.nom) : $($_.constat)" }) -join '. '); points = $points }
}

function Write-Etat($Valeurs) {
    $f = Join-Path $dossier 'etat.json'
    $e = [ordered]@{}
    if (Test-Path $f) { (Get-Content -Raw -Encoding UTF8 $f | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $e[$_.Name] = $_.Value } }
    foreach ($k in $Valeurs.Keys) { $e[$k] = $Valeurs[$k] }
    Write-Texte $f ($e | ConvertTo-Json -Depth 4) $false
}

try {
    $p = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:PNPL_PARAMS)) | ConvertFrom-Json
    $lanceur = Join-Path $dossier 'lanceur.vbs'
    $fond = Join-Path $dossier 'fond.ps1'
    if ($p.actif) {
        if ([string]$p.reference -notmatch '^[\w .-]{1,60}$') { throw 'référence du poste illisible' }
        $m = New-Object IO.MemoryStream(, [Convert]::FromBase64String($p.script))
        $g = New-Object IO.Compression.GZipStream($m, [IO.Compression.CompressionMode]::Decompress)
        $script = (New-Object IO.StreamReader($g, [Text.Encoding]::UTF8)).ReadToEnd()
        if (-not (Test-Path $dossier)) { New-Item -ItemType Directory -Path $dossier -Force | Out-Null }
        # Les comptes lisent et lancent, seuls SYSTEM et les administrateurs écrivent.
        & icacls.exe $dossier /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
        # Avec BOM : PowerShell 5.1 lit sinon les accents en ANSI.
        Write-Texte $fond $script $true
        $commande = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$fond"""
        $vbs = $commande.Replace('"', '""')
        Write-Texte $lanceur ("Dim a : a = """"`r`nIf WScript.Arguments.Count > 0 Then a = "" -Detail""`r`nCreateObject(""WScript.Shell"").Run ""$vbs"" & a, 0, False`r`n") $false
        Write-Etat ([ordered]@{ reference = [string]$p.reference; sonde = (Test-Path (Join-Path $env:ProgramData 'PointeNoire\supervision\config.json')); retire = $false })
        $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "//B //Nologo ""$lanceur"""
        $session = New-ScheduledTaskTrigger -AtLogOn
        $quartDHeure = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 15)
        $reglages = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
        $principal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited
        Register-ScheduledTask -TaskName $tache -Action $action -Trigger @($session, $quartDHeure) -Settings $reglages -Principal $principal -Force | Out-Null
        $w = New-Object -ComObject WScript.Shell
        $l = $w.CreateShortcut($icone)
        $l.TargetPath = 'wscript.exe'
        $l.Arguments = "//B //Nologo ""$lanceur"" detail"
        $l.IconLocation = "$env:SystemRoot\System32\imageres.dll,-1023"
        $l.Description = 'Ce que AVDiagram a appliqué sur ce poste'
        $l.Save()
        $sessions = Invoke-Sessions 'Aucun compte ouvert : il s''affichera à la prochaine ouverture de session'
        $result.ok = -not $sessions.echec
        $result.points = $sessions.points
        $result.detail = "fond d'état posé, icône « État du poste » sur le Bureau. $($sessions.texte)"
        if ($sessions.echec) { $result.detail = "fond d'état pas affiché. $($sessions.texte)" }
    } else {
        $ev = $null
        try { $ev = Get-Content -Raw -Encoding UTF8 (Join-Path $env:ProgramData 'PointeNoire\mode-evenement.json') | ConvertFrom-Json } catch { }
        if (-not (Test-Path $fond)) { $result.ok = $true; $result.detail = 'pas de fond d''état sur ce poste' }
        elseif ($ev -and @($ev.parties) -contains 'fond') { $result.detail = 'refusé : le poste est en mode événement, son écran l''indique jusqu''à la fin du mode' }
        else {
        Write-Etat ([ordered]@{ retire = $true; retireLe = (Get-Date).ToString('o') })
        Remove-Item $icone -Force -ErrorAction SilentlyContinue
        # La tâche reste, en retrait : elle rend son fond à chaque compte qui
        # s'ouvre. pilote.ps1 la retire après 7 jours.
        $sessions = Invoke-Sessions 'Aucun compte ouvert.'
        $result.ok = -not $sessions.echec
        $result.points = $sessions.points
        $result.detail = "fond d'état retiré, les comptes fermés retrouvent le leur à leur prochaine session. $($sessions.texte)"
        }
    }
} catch {
    $result.ok = $false
    $result.detail = "$($_.Exception.Message) (fond-pose.ps1, ligne $($_.InvocationInfo.ScriptLineNumber))"
}
$json = $result | ConvertTo-Json -Compress -Depth 4
'PNPL1:' + $env:PNPL_NONCE + ':' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))

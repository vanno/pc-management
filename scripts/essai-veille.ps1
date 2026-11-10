<#
  Essai réel de la veille réseau sous Windows PowerShell 5.1, sur une machine
  JETABLE (la machine Windows de GitHub Actions, ou une machine virtuelle) :
  il écrit dans C:\ProgramData\PointeNoire, crée la tâche PointeNoire-Reseau
  et ajoute un certificat d'essai, puis retire tout. Jamais sur un poste du
  parc : il refuse dès qu'une sonde est déjà installée.

      powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\essai-veille.ps1 -Jetable

  1. Un faux AVDiagram en HTTPS sur ce poste (scripts\essai-recepteur.py).
  2. La commande du relais (scripts\essai-commande.py, donc pcm.pilot) pose la
     veille, comme l'agent MeshCentral la lancerait.
  3. La veille tourne -Secondes secondes sous le compte SYSTEM.
  4. Relus : la tâche, le journal du poste (secondes, minutes, événements),
     l'envoi reçu (chemin, jeton, forme du corps), le processeur consommé.
  5. La commande du relais retire la veille : plus de tâche, plus de dossier.

  Sortie : une ligne OK ou ÉCHEC par point, le premier envoi reçu entre deux
  repères (à comparer au schéma d'AVDiagram), le code de sortie 0 si tout passe.
#>
param([switch]$Jetable, [int]$Secondes = 150, [int]$Port = 443)

$ErrorActionPreference = 'Stop'
$racine = Split-Path -Parent $PSScriptRoot
$echecs = 0
function Dis([bool]$Ok, [string]$Texte) {
    if ($Ok) { Write-Output "OK     $Texte" } else { Write-Output "ÉCHEC  $Texte"; $script:echecs++ }
}

$pn = Join-Path $env:ProgramData 'PointeNoire'
$fichierSonde = Join-Path $pn 'supervision\config.json'
$dossier = Join-Path $pn 'reseau'
$tache = 'PointeNoire-Reseau'
if (-not $Jetable) { Write-Output 'Essai refusé : à lancer avec -Jetable, sur une machine jetable seulement.'; exit 2 }
if (Test-Path $fichierSonde) { Write-Output 'Essai refusé : une sonde est installée sur ce poste, ce n''est pas une machine jetable.'; exit 2 }
$admin = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { Write-Output 'Essai refusé : à lancer en administrateur.'; exit 2 }

$tmp = Join-Path $env:TEMP ('essai-veille-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$recus = Join-Path $tmp 'recus.jsonl'
$jeton = 'pns_' + ('a' * 43)
$hote = 'localhost'
$url = 'https://' + $hote + $(if ($Port -ne 443) { ":$Port" }) + '/api/v1/postes/mesures'
$recepteur = $null
$certificat = $null

function Invoke-Relais([string]$Sens, [string]$Cible, [string]$NomCible) {
    # La commande du relais, lancée comme l'agent MeshCentral la lance : un
    # PowerShell neuf, la commande entière en une fois.
    $nonce = [Guid]::NewGuid().ToString('N')
    $f = Join-Path $tmp "commande-$Sens.txt"
    $arguments = @((Join-Path $PSScriptRoot 'essai-commande.py'), $f, $nonce, $Sens)
    if ($Sens -eq 'pose') { $arguments += @($Cible, $NomCible) }
    $longueur = & python @arguments
    if ($LASTEXITCODE -ne 0) { throw "essai-commande.py : $longueur" }
    $sortie = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "& ([ScriptBlock]::Create([IO.File]::ReadAllText('$f', [Text.Encoding]::UTF8)))" 2>&1
    $ligne = @($sortie | ForEach-Object { [string]$_ } | Where-Object { $_.StartsWith("PNPL1:${nonce}:") }) | Select-Object -Last 1
    if (-not $ligne) { throw "pas de réponse PNPL1 ($Sens) : $(@($sortie) -join ' / ')" }
    $reponse = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ligne.Substring(7 + $nonce.Length))) | ConvertFrom-Json
    [pscustomobject]@{ longueur = [int]$longueur; reponse = $reponse }
}

function Get-Veille {
    @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { [string]$_.CommandLine -like '*PointeNoire\reseau\reseau.ps1*' })
}

try {
    # --- 1. Le faux AVDiagram ---------------------------------------------------------
    $openssl = (Get-Command openssl.exe -ErrorAction SilentlyContinue).Source
    if (-not $openssl) { $openssl = @('C:\Program Files\Git\usr\bin\openssl.exe', 'C:\Program Files\Git\mingw64\bin\openssl.exe') | Where-Object { Test-Path $_ } | Select-Object -First 1 }
    if (-not $openssl) { throw 'openssl.exe introuvable (il vient avec Git pour Windows)' }
    $cert = Join-Path $tmp 'cert.pem'
    $cle = Join-Path $tmp 'cle.pem'
    $ErrorActionPreference = 'Continue'
    & $openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=$hote" -addext "subjectAltName=DNS:$hote" -keyout $cle -out $cert 2>&1 | Out-Null
    $ErrorActionPreference = 'Stop'
    if (-not (Test-Path $cert)) { throw 'certificat d''essai non créé' }
    $certificat = Import-Certificate -FilePath $cert -CertStoreLocation Cert:\LocalMachine\Root
    $recepteur = Start-Process -FilePath python -ArgumentList @("`"$(Join-Path $PSScriptRoot 'essai-recepteur.py')`"", "`"$cert`"", "`"$cle`"", "`"$recus`"", $Port) -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 3
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $essai = Invoke-RestMethod -Method Post -Uri ($url -replace '/mesures$', '/essai') -ContentType 'application/json' -Body '{"minutes":[]}' -TimeoutSec 15 -UseBasicParsing
    Dis ($essai.written -eq 0 -and -not $recepteur.HasExited) "faux AVDiagram en HTTPS sur $hote, port $Port"

    # --- 2. La pose par la commande du relais ---------------------------------------
    New-Item -ItemType Directory -Path (Split-Path -Parent $fichierSonde) -Force | Out-Null
    [IO.File]::WriteAllText($fichierSonde, (@{ url = $url; jeton = $jeton } | ConvertTo-Json), (New-Object System.Text.UTF8Encoding $false))
    $debut = Get-Date
    $pose = Invoke-Relais 'pose' '127.0.0.1' 'Essai'
    Dis ([bool]$pose.reponse.ok) "pose par la commande du relais ($($pose.longueur) caractères) : $($pose.reponse.detail)"
    $t = Get-ScheduledTask -TaskName $tache -ErrorAction SilentlyContinue
    Dis ([bool]$t -and $t.Principal.UserId -eq 'SYSTEM') "tâche $tache créée, compte $($t.Principal.UserId)"
    $reglages = Get-Content -Raw -Path (Join-Path $dossier 'reseau.json') | ConvertFrom-Json
    Dis ($reglages.cible -eq '127.0.0.1' -and $reglages.nom_cible -eq 'Essai') "reseau.json : cible $($reglages.cible) ($($reglages.nom_cible))"

    # --- 3. La veille tourne ----------------------------------------------------------
    Write-Output "       ... la veille tourne $Secondes s"
    Start-Sleep -Seconds $Secondes

    # --- 4. Ce qu'elle a fait ---------------------------------------------------------
    $veille = Get-Veille
    Dis ($veille.Count -eq 1) "$($veille.Count) veille en cours (une seule attendue), tâche $((Get-ScheduledTask -TaskName $tache).State)"
    if ($veille.Count -ge 1) {
        $v = $veille[0]
        $duree = ((Get-Date) - $v.CreationDate).TotalSeconds
        $cpu = ([double]$v.KernelModeTime + [double]$v.UserModeTime) / 1e7
        $coeurs = [Environment]::ProcessorCount
        $part = [Math]::Round(100 * $cpu / $duree / $coeurs, 2)
        Write-Output "INFO   processeur : $([Math]::Round($cpu, 1)) s en $([Math]::Round($duree)) s, soit $part % de la machine ($coeurs coeurs), mémoire $([Math]::Round($v.WorkingSetSize / 1MB)) Mo"
        Dis ($part -lt 3) "processeur sous 3 % de la machine ($part %)"
    }
    $journal = Join-Path $dossier 'journal'
    $secondes = @(Get-ChildItem -Path $journal -Filter 'secondes-*.csv' -ErrorAction SilentlyContinue | ForEach-Object { [IO.File]::ReadAllLines($_.FullName) } | Where-Object { $_ -match '^\d{4}-' })
    Dis ($secondes.Count -ge [int]($Secondes * 0.8)) "journal du poste : $($secondes.Count) lignes à la seconde pour $Secondes s"
    $avecCible = @($secondes | Where-Object { $c = ($_ -split ',')[2]; $c -ne '' -and [int]$c -ge 0 }).Count
    Dis ($avecCible -ge [int]($secondes.Count * 0.8)) "cible du site (127.0.0.1) : $avecCible réponses sur $($secondes.Count) secondes"
    $minutes = @()
    if (Test-Path (Join-Path $journal 'minutes.jsonl')) { $minutes = @([IO.File]::ReadAllLines((Join-Path $journal 'minutes.jsonl')) | Where-Object { $_ }) }
    Dis ($minutes.Count -ge 1) "journal du poste : $($minutes.Count) résumé(s) par minute"
    $evenements = @()
    if (Test-Path (Join-Path $journal 'evenements.jsonl')) { $evenements = @([IO.File]::ReadAllLines((Join-Path $journal 'evenements.jsonl'), [Text.Encoding]::UTF8) | Where-Object { $_ }) }
    Dis (@($evenements | Where-Object { $_ -like '*"veille"*' }).Count -ge 1) "journal du poste : $($evenements.Count) événement(s), dont le démarrage de la veille"

    $envois = @()
    if (Test-Path $recus) { $envois = @([IO.File]::ReadAllLines($recus, [Text.Encoding]::UTF8) | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.path -ne '/api/v1/postes/essai' }) }
    Dis ($envois.Count -ge 1) "$($envois.Count) envoi(s) reçu(s) par le faux AVDiagram"
    if ($envois.Count -ge 1) {
        $e = $envois[0]
        Dis ($e.path -eq '/api/v1/postes/reseau') "chemin de l'envoi : $($e.path)"
        Dis ($e.authorization -eq "Bearer $jeton") 'jeton de la sonde en Authorization: Bearer'
        Dis ([string]$e.type -like 'application/json*') "type du corps : $($e.type)"
        $corps = $e.body | ConvertFrom-Json
        $m = @($corps.minutes)[0]
        Dis ([bool]$m -and [string]$m.at -match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$') "minute datée en UTC : $($m.at)"
        $site = $m.targets.site
        Dis ([bool]$site -and $site.n -ge 1 -and $site.loss -eq 0 -and $null -ne $site.med) "cible du site : $($site.n) pings, perte $($site.loss) %, médiane $($site.med) ms"
        Dis ([bool]$m.targets.internet -and $m.targets.internet.ip -eq '1.1.1.1') "cible internet : $($m.targets.internet.n) pings vers $($m.targets.internet.ip), perte $($m.targets.internet.loss) %"
        Dis (@($m.nics).Count -ge 1 -and [bool]@($m.nics)[0].name) "$(@($m.nics).Count) carte(s) réseau, la première : $(@($m.nics)[0].name)"
        Dis (@($corps.events | Where-Object { $_.type -eq 'veille' }).Count -ge 1) "$(@($corps.events).Count) événement(s) dans l'envoi, dont le démarrage"
        Dis (-not (Test-Path (Join-Path $dossier 'en-attente.json'))) 'rien en attente après un envoi accepté'
        Write-Output '--- premier envoi reçu ---'
        Write-Output $e.body
        Write-Output '--- fin du premier envoi ---'
        if ($envois.Count -ge 2) {
            Write-Output '--- dernier envoi reçu ---'
            Write-Output $envois[-1].body
            Write-Output '--- fin du dernier envoi ---'
        }
    }
    if ($secondes.Count -eq 0) {
        # Rien d'écrit : la veille s'est arrêtée. La relancer ici montre pourquoi.
        Write-Output "INFO   dernier résultat de la tâche : $((Get-ScheduledTaskInfo -TaskName $tache).LastTaskResult)"
        Stop-ScheduledTask -TaskName $tache -ErrorAction SilentlyContinue
        $ErrorActionPreference = 'Continue'
        $essaiDirect = Start-Job { & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $using:dossier\reseau.ps1 2>&1 }
        Wait-Job $essaiDirect -Timeout 20 | Out-Null
        Write-Output (Receive-Job $essaiDirect | Out-String)
        Stop-Job $essaiDirect -ErrorAction SilentlyContinue
        $ErrorActionPreference = 'Stop'
    }

    # --- 5. Le retrait par la commande du relais ------------------------------------
    $retrait = Invoke-Relais 'retrait' '' ''
    Dis ([bool]$retrait.reponse.ok) "retrait par la commande du relais : $($retrait.reponse.detail)"
    Start-Sleep -Seconds 2
    Dis (-not (Get-ScheduledTask -TaskName $tache -ErrorAction SilentlyContinue)) "tâche $tache retirée"
    Dis (-not (Test-Path $dossier)) 'dossier de la veille retiré'
    Dis ((Get-Veille).Count -eq 0) 'plus aucune veille en cours'
} catch {
    Dis $false "essai interrompu : $($_.Exception.Message) (ligne $($_.InvocationInfo.ScriptLineNumber))"
} finally {
    # La machine est jetable, mais l'essai range quand même derrière lui.
    $ErrorActionPreference = 'SilentlyContinue'
    Unregister-ScheduledTask -TaskName $tache -Confirm:$false
    Get-Veille | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
    if ($recepteur -and -not $recepteur.HasExited) { Stop-Process -Id $recepteur.Id -Force }
    Remove-Item -Path $fichierSonde -Force
    if (Test-Path $dossier) { Remove-Item -Path $dossier -Recurse -Force }
    if ($certificat) { Remove-Item -Path ("Cert:\LocalMachine\Root\" + $certificat.Thumbprint) -Force }
    Remove-Item -Path $tmp -Recurse -Force
}

Write-Output "$echecs échec(s)"
exit $echecs

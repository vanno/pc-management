<#
  Essai de bout en bout sous Windows PowerShell 5.1 (GitHub Actions, ou à la
  main sur un PC) : la console régie construite (console-regie.exe), et la
  partie poste (agent/console.ps1, agent/supervision.ps1) telle qu'elle
  tourne sur les postes.

    powershell -ExecutionPolicy Bypass -File console\essai-windows.ps1 -Exe dist\console-regie.exe

  Vérifie : envoi à l'adresse fixée avec l'empreinte épinglée, refus d'une
  autre empreinte, découverte par diffusion UDP, deux envois par passage de
  la sonde complète.
#>
param([Parameter(Mandatory = $true)][string]$Exe)

$ErrorActionPreference = 'Stop'
$Exe = (Resolve-Path $Exe).Path
$racine = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("essai-regie-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp | Out-Null
$donnees = Join-Path $tmp 'console'
$sonde = Join-Path $tmp 'sonde'
New-Item -ItemType Directory -Path $sonde | Out-Null
$echecs = 0
function Test-Point([string]$Nom, [bool]$Ok, [string]$Detail) {
    if ($Ok) { Write-Host "OK     $Nom" } else { Write-Host "ECHEC  $Nom : $Detail"; $script:echecs++ }
}

Write-Host "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
$proc = Start-Process -FilePath $Exe -ArgumentList @('--dossier', "`"$donnees`"", '--sans-navigateur', '--port-local', '18470', '--port-https', '18471') -PassThru -NoNewWindow -RedirectStandardOutput (Join-Path $tmp 'console.log') -RedirectStandardError (Join-Path $tmp 'console.err')
try {
    $pret = $false
    for ($i = 0; $i -lt 60 -and -not $pret; $i++) {
        Start-Sleep -Seconds 1
        try { Invoke-RestMethod -Uri 'http://127.0.0.1:18470/api/etat' -UseBasicParsing -TimeoutSec 2 | Out-Null; $pret = $true } catch { }
    }
    if (-not $pret) { Get-Content (Join-Path $tmp 'console.log'), (Join-Path $tmp 'console.err') -ErrorAction SilentlyContinue; throw 'la console ne répond pas' }
    Test-Point 'console lancée' $true ''

    $code = (& $Exe --dossier $donnees --appairage | Out-String).Trim()
    $brut = $code.Substring(5).Replace('-', '+').Replace('_', '/')
    while ($brut.Length % 4) { $brut += '=' }
    $app = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($brut)) | ConvertFrom-Json
    function Get-Jeton([string]$Ref) {
        $h = New-Object Security.Cryptography.HMACSHA256 (, [Text.Encoding]::ASCII.GetBytes($app.secret))
        $b = $h.ComputeHash([Text.Encoding]::UTF8.GetBytes('sonde:' + $Ref.ToUpper()))
        'pnr_' + [Convert]::ToBase64String($b).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    }
    function Set-Console([string]$Ref, [string]$Empreinte, $Adresse) {
        $c = [ordered]@{ reference = $Ref; consoles = @([ordered]@{ id = $app.id; nom = $app.nom; empreinte = $Empreinte; jeton = (Get-Jeton $Ref); port = 18471; adresse = $Adresse }) }
        [IO.File]::WriteAllText((Join-Path $sonde 'console.json'), ($c | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding $false))
        Remove-Item (Join-Path $sonde 'console-vue.json') -ErrorAction SilentlyContinue
    }
    function Read-Vu { (Get-Content -Raw (Join-Path $sonde 'console-vue.json') | ConvertFrom-Json).($app.id) }
    Copy-Item (Join-Path $racine 'agent\console.ps1') $sonde
    $m = [ordered]@{ at = (Get-Date).ToUniversalTime().ToString('s') + 'Z'; cpu = 12.5; ram = 40; disk_free = 50; gateway_ms = 1; gateway_loss = 0; internet_ms = $null; internet_loss = 100
        nics = @([ordered]@{ name = 'Ethernet'; rx = 1000; tx = 2000; speed = 1e9; ipv4 = '192.168.1.21'; prefix = 24; gateway = '192.168.1.1'; dhcp = $false; profile = 'Private'; wired = $true; errors = 0 }) }

    # 1. Adresse fixée, bonne empreinte
    Set-Console 'PNESSAI' $app.empreinte '127.0.0.1'
    & (Join-Path $sonde 'console.ps1') -Mesure $m
    $v = Read-Vu
    Test-Point 'envoi à l''adresse fixée' ($v.etat -eq 'ok') "$($v.etat) $($v.erreur)"
    Test-Point 'C# compilé une fois' ([bool](Get-ChildItem $sonde -Filter 'regie-*.dll')) 'pas de dll'
    $etat = Invoke-RestMethod -Uri 'http://127.0.0.1:18470/api/etat' -UseBasicParsing
    $p = @($etat.postes | Where-Object { $_.reference -eq 'PNESSAI' })
    Test-Point 'poste visible sur la console' ($p.Count -eq 1 -and $p[0].cpu -eq 12.5) ($etat | ConvertTo-Json -Depth 3 -Compress)

    # 2. Adresse déjà connue : réutilisée
    & (Join-Path $sonde 'console.ps1') -Mesure $m
    $v = Read-Vu
    Test-Point 'adresse connue réutilisée' ($v.etat -eq 'ok' -and $v.par -eq 'connue') "$($v.etat) par $($v.par)"

    # 3. Autre empreinte : rien ne part
    Set-Console 'PNESSAI' ('0' * 64) '127.0.0.1'
    & (Join-Path $sonde 'console.ps1') -Mesure $m
    $v = Read-Vu
    Test-Point 'empreinte différente refusée' ($v.etat -eq 'injoignable' -and $v.erreur -like 'empreinte inattendue*') "$($v.etat) $($v.erreur)"

    # 4. Jeton d'un autre poste
    Set-Console 'PNESSAI' $app.empreinte '127.0.0.1'
    $c = Get-Content -Raw (Join-Path $sonde 'console.json') | ConvertFrom-Json
    $c.reference = 'PNAUTRE'
    [IO.File]::WriteAllText((Join-Path $sonde 'console.json'), ($c | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding $false))
    & (Join-Path $sonde 'console.ps1') -Mesure $m
    $v = Read-Vu
    Test-Point 'jeton d''un autre poste refusé' ($v.etat -eq 'jeton_refuse') "$($v.etat) $($v.erreur)"

    # 5. Découverte, sans adresse fixée (le réseau d'un exécuteur GitHub n'est pas un LAN de site : avertissement seulement)
    Set-Console 'PNESSAI' $app.empreinte $null
    & (Join-Path $sonde 'console.ps1') -Mesure $m
    $v = Read-Vu
    if ($v.etat -eq 'ok' -and $v.par -eq 'decouverte') { Write-Host "OK     découverte UDP ($($v.adresse))" }
    else { Write-Host "::warning::découverte UDP sans réponse ici : $($v.etat) $($v.erreur)" }

    # 6. La sonde complète : deux envois par passage, AVDiagram injoignable n'y change rien
    Set-Console 'PNSONDE' $app.empreinte '127.0.0.1'
    Copy-Item (Join-Path $racine 'agent\supervision.ps1') $sonde
    [IO.File]::WriteAllText((Join-Path $sonde 'config.json'), '{"url":"https://127.0.0.1:9/api/v1/postes/mesures","jeton":"pns_essaiessaiessaiessaiessai"}', (New-Object Text.UTF8Encoding $false))
    $debut = Get-Date
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $sonde 'supervision.ps1')
    $duree = [int]((Get-Date) - $debut).TotalSeconds
    $hist = Invoke-RestMethod -Uri 'http://127.0.0.1:18470/api/historique?reference=PNSONDE' -UseBasicParsing
    Test-Point "sonde complète en $duree s : 2 mesures reçues" (@($hist.points).Count -eq 2) "$(@($hist.points).Count) mesure(s)"
    Test-Point 'mesures gardées pour AVDiagram' (Test-Path (Join-Path $sonde 'en-attente.json')) 'en-attente.json absent'
    Test-Point 'passage sous 100 s (contrôle de la sonde)' ($duree -lt 100) "$duree s"
} finally {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    Get-Process -Name 'console-regie' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}
if ($echecs) { Write-Host "$echecs échec(s)"; exit 1 }
Write-Host 'Tout est bon.'

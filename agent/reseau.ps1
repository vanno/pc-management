<#
  Le changement de réseau d'un poste, lancé par la tâche planifiée
  PointeNoire-Reseau (SYSTEM) que pilote.ps1 (op reseau) pose. Il ne dépend que
  des fichiers de son dossier (ProgramData\PointeNoire\reseau) : demande.json,
  avant.json, base.json. Il voyage dans la demande (`appliquer`), pas dans
  pilote.ps1 : la commande de pose de la sonde est près de la limite de l'agent.

  Sans paramètre : applique demande.json, vérifie que MeshCentral est joignable
  pendant `delai` secondes (sauf `retour` faux), sinon remet avant.json. Une
  fois gardé, pose le retour au réseau normal (sauf `normal`) : la tâche
  PointeNoire-Reseau-Retour, à l'heure `fin` si elle est donnée, et le
  raccourci « Revenir au réseau normal » du bureau commun.

  Avec -Retour (cette tâche) : remet base.json, la configuration d'avant le
  premier changement, puis efface tâche, raccourci et base.json.

  Résultat dans resultat.json : etat prevu, en_cours, applique, retour, revenu
  ou echec, et detail. Compatible Windows PowerShell 5.1.
#>
param([switch]$Retour)
$ErrorActionPreference = 'Stop'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$tacheRetour = 'PointeNoire-Reseau-Retour'
$bureau = [Environment]::GetFolderPath('CommonDesktopDirectory')
if (-not $bureau) { $bureau = Join-Path $env:PUBLIC 'Desktop' }
$raccourci = Join-Path $bureau 'Revenir au réseau normal.lnk'

function Write-Etat([string]$Etat, [string]$Detail) {
    $j = [ordered]@{ etat = $Etat; detail = $Detail; le = (Get-Date).ToString('o') } | ConvertTo-Json -Compress
    [IO.File]::WriteAllText((Join-Path $dir 'resultat.json'), $j, (New-Object System.Text.UTF8Encoding $false))
}

function Set-Config([string]$Alias, [bool]$Dhcp, $Adresses, $Passerelle, $Dns) {
    Get-NetRoute -InterfaceAlias $Alias -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
    if ($Dhcp) {
        Get-NetIPAddress -InterfaceAlias $Alias -AddressFamily IPv4 -PrefixOrigin Manual -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
        Set-NetIPInterface -InterfaceAlias $Alias -AddressFamily IPv4 -Dhcp Enabled
        Set-DnsClientServerAddress -InterfaceAlias $Alias -ResetServerAddresses
        & ipconfig.exe /renew "$Alias" | Out-Null
        return
    }
    Set-NetIPInterface -InterfaceAlias $Alias -AddressFamily IPv4 -Dhcp Disabled
    Get-NetIPAddress -InterfaceAlias $Alias -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    $premiere = $true
    foreach ($a in @($Adresses)) {
        $p = @{ InterfaceAlias = $Alias; AddressFamily = 'IPv4'; IPAddress = $a.ip; PrefixLength = [int]$a.prefixe }
        if ($premiere -and $Passerelle) { $p.DefaultGateway = $Passerelle }
        New-NetIPAddress @p | Out-Null
        $premiere = $false
    }
    if (@($Dns).Count) { Set-DnsClientServerAddress -InterfaceAlias $Alias -ServerAddresses @($Dns) }
    else { Set-DnsClientServerAddress -InterfaceAlias $Alias -ResetServerAddresses }
}

function Set-Copie($c) { Set-Config $c.interface ([bool]$c.dhcp) $c.adresses $c.passerelle $c.dns }

function Clear-Retour {
    Unregister-ScheduledTask -TaskName $tacheRetour -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $raccourci -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $dir 'base.json') -Force -ErrorAction SilentlyContinue
}

# Le retour au réseau normal : une tâche SYSTEM qu'un compte sans droits
# d'administrateur peut lancer (lecture et exécution pour les utilisateurs
# authentifiés), et un raccourci sur le bureau commun qui la lance.
function Install-Retour($Fin) {
    $script = Join-Path $dir 'appliquer.ps1'
    $t = @{
        TaskName  = $tacheRetour
        Action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`" -Retour"
        Principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        Settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
        Force     = $true
    }
    if ($Fin) { $t.Trigger = New-ScheduledTaskTrigger -Once -At $Fin }
    Register-ScheduledTask @t | Out-Null
    $texte = @()
    try {
        $s = New-Object -ComObject Schedule.Service
        $s.Connect()
        $tache = $s.GetFolder('\').GetTask($tacheRetour)
        $sd = $tache.GetSecurityDescriptor(4)
        if ($sd -notmatch ';;;AU\)') { $tache.SetSecurityDescriptor($sd + '(A;;GRGX;;;AU)', 0) }
    } catch { $texte += "droits du raccourci non posés ($($_.Exception.Message))" }
    try {
        $l = (New-Object -ComObject WScript.Shell).CreateShortcut($raccourci)
        $l.TargetPath = Join-Path $env:SystemRoot 'System32\schtasks.exe'
        $l.Arguments = "/run /tn $tacheRetour"
        $l.WindowStyle = 7
        $l.IconLocation = (Join-Path $env:SystemRoot 'System32\shell32.dll') + ',18'
        $l.Description = 'Remet la configuration réseau d''avant le changement fait depuis AVDiagram'
        $l.Save()
        $texte = @('raccourci « Revenir au réseau normal » sur le bureau') + $texte
    } catch { $texte += "raccourci non posé ($($_.Exception.Message))" }
    if ($Fin) { $texte = @("retour au réseau normal prévu le $($Fin.ToString('dd/MM à HH:mm'))") + $texte }
    return ($texte -join ', ')
}

if ($Retour) {
    $f = Join-Path $dir 'base.json'
    if (-not (Test-Path $f)) { Clear-Retour; return }
    Write-Etat 'en_cours' 'retour au réseau normal'
    try {
        $b = Get-Content -Raw -Path $f | ConvertFrom-Json
        Set-Copie $b
        Clear-Retour
        Write-Etat 'revenu' "réseau normal remis sur $($b.interface)"
    } catch {
        Write-Etat 'echec' ("retour au réseau normal refusé par Windows : " + $_.Exception.Message)
    }
    return
}

$d = Get-Content -Raw -Path (Join-Path $dir 'demande.json') | ConvertFrom-Json
$avant = Get-Content -Raw -Path (Join-Path $dir 'avant.json') | ConvertFrom-Json

function Test-Mesh {
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $t = $c.ConnectAsync($d.hote, [int]$d.port)
        return ($t.Wait(3000) -and $c.Connected)
    } catch { return $false } finally { $c.Dispose() }
}

# Après un changement gardé : le profil « normal » efface le retour, les autres le posent.
function Complete([string]$Detail) {
    $suite = ''
    try {
        if ($d.normal) { Clear-Retour; $suite = 'réseau normal du poste' }
        else {
            $fin = $null
            if ($d.fin) { $fin = [datetime]$d.fin }
            $suite = Install-Retour $fin
        }
    } catch { $suite = "retour au réseau normal non posé : $($_.Exception.Message)" }
    if ($suite) { $Detail = "$Detail ; $suite" }
    Write-Etat 'applique' $Detail
}

Write-Etat 'en_cours' 'changement en cours'
try {
    $adresses = @()
    if (-not $d.dhcp) { $adresses = @([pscustomobject]@{ ip = $d.ip; prefixe = $d.prefixe }) }
    Set-Config $d.interface ([bool]$d.dhcp) $adresses $d.passerelle $d.dns
} catch {
    $msg = $_.Exception.Message
    try { Set-Copie $avant } catch { }
    Write-Etat 'echec' ("changement refusé par Windows, configuration d'avant remise : " + $msg)
    return
}
if (-not $d.retour) {
    Start-Sleep -Seconds 10
    Complete 'appliqué sans retour automatique'
    return
}
$depart = Get-Date
$fin = $depart.AddSeconds([int]$d.delai)
Start-Sleep -Seconds 5
while ((Get-Date) -lt $fin) {
    if (Test-Mesh) {
        Complete ("MeshCentral joint après " + [int]((Get-Date) - $depart).TotalSeconds + " s")
        return
    }
    Start-Sleep -Seconds 5
}
try {
    Set-Copie $avant
    Write-Etat 'retour' ("MeshCentral injoignable après " + [int]$d.delai + " s : configuration d'avant remise")
} catch {
    Write-Etat 'echec' ("MeshCentral injoignable, et le retour à la configuration d'avant a échoué : " + $_.Exception.Message)
}

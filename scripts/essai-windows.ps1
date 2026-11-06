<#
  Essai des scripts du poste sous Windows PowerShell 5.1, sans rien changer à
  Windows : à lancer depuis la racine d'un clone, sur un PC de la régie.

      powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\essai-windows.ps1

  1. Chaque agent\*.ps1, lu en UTF-8 comme le relais l'envoie, se lit sans
     erreur de syntaxe.
  2. Le relais vide les lignes de commentaire avant l'envoi (pilot.slim). La
     même découpe est refaite ici : le script envoyé doit garder exactement les
     mêmes jetons que le fichier, chaînes @' '@ comprises (fond.ps1 dans
     $FondSource). L'empreinte de chaque envoi se compare à celle que donne
     `python -m pcm.pilot` (dossier worker) sur le relais.
  3. Get-PlansProduction (pilote.ps1) relit la vraie sortie de powercfg /list.

  Sortie : une ligne OK ou ÉCHEC par point, et le code de sortie 0 si tout passe.
#>

$ErrorActionPreference = 'Stop'
$racine = Split-Path -Parent $PSScriptRoot
$agent = Join-Path $racine 'agent'
$echecs = 0
function Dis([bool]$Ok, [string]$Texte) {
    if ($Ok) { Write-Output "OK     $Texte" } else { Write-Output "ÉCHEC  $Texte"; $script:echecs++ }
}

function Lis([string]$Nom) {
    # Comme le relais : UTF-8, fins de ligne LF (un clone Windows peut avoir CRLF).
    $t = [IO.File]::ReadAllText((Join-Path $agent $Nom), [Text.Encoding]::UTF8)
    $t.Replace("`r`n", "`n").TrimStart([char]0xFEFF)
}

function Get-Slim([string]$Texte) {
    $out = New-Object System.Collections.Generic.List[string]
    $fin = $null
    $bloc = $false
    foreach ($l in $Texte.Split("`n")) {
        $t = $l.Trim()
        if ($fin) {
            if ($l.StartsWith($fin)) { $fin = $null }
            $out.Add($l)
        } elseif ($bloc) {
            $bloc = -not $l.Contains('#>')
            $out.Add('')
        } elseif ($t.StartsWith('<#')) {
            $bloc = -not $t.Substring(2).Contains('#>')
            $out.Add('')
        } elseif ($t.StartsWith('#')) {
            $out.Add('')
        } else {
            $m = [regex]::Match($l, "@(['""])\s*$")
            $fin = $(if ($m.Success) { $m.Groups[1].Value + '@' } else { $null })
            $out.Add($l)
        }
    }
    $out -join "`n"
}

function Get-Jetons([string]$Texte) {
    $jetons = $null
    $erreurs = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($Texte, [ref]$jetons, [ref]$erreurs)
    $garde = @($jetons | Where-Object { @('Comment', 'NewLine', 'LineContinuation', 'EndOfInput') -notcontains [string]$_.Kind } | ForEach-Object { "$($_.Kind)|$($_.Text)" })
    [pscustomobject]@{ erreurs = @($erreurs); jetons = $garde }
}

function Get-Empreinte([string]$Texte) {
    $sha = [Security.Cryptography.SHA256]::Create()
    (-join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Texte)) | ForEach-Object { $_.ToString('x2') })).Substring(0, 12)
}

# Ce que le relais envoie : chaque script seul, et l'écran avec son script dans $FondSource.
$envois = [ordered]@{}
foreach ($f in Get-ChildItem $agent -Filter '*.ps1' | Sort-Object Name) { $envois[$f.Name] = Lis $f.Name }
$envois['releve-pose.ps1+releve.ps1'] = "`$FondSource = @'`n" + (Lis 'releve.ps1') + "`n'@`n" + (Lis 'releve-pose.ps1')
$envois['fond-pose.ps1+fond.ps1'] = "`$FondSource = @'`n" + (Lis 'fond.ps1') + "`n'@`n" + (Lis 'fond-pose.ps1')
$envois['politique.ps1+pilote.ps1'] = (Lis 'politique.ps1') + "`n" + (Lis 'pilote.ps1')

foreach ($nom in $envois.Keys) {
    $texte = $envois[$nom]
    $avant = Get-Jetons $texte
    $slim = Get-Slim $texte
    $apres = Get-Jetons $slim
    Dis ($avant.erreurs.Count -eq 0) "$nom : $($avant.erreurs.Count) erreur(s) de syntaxe $(@($avant.erreurs | ForEach-Object { "ligne $($_.Extent.StartLineNumber) : $($_.Message)" }) -join ' / ')"
    $memes = ($avant.jetons.Count -eq $apres.jetons.Count) -and (-not (Compare-Object $avant.jetons $apres.jetons -SyncWindow 0 -CaseSensitive))
    Dis $memes "$nom : envoi sans commentaires, mêmes $($avant.jetons.Count) jetons, $($texte.Split("`n").Count) lignes gardées : $($slim.Split("`n").Count -eq $texte.Split("`n").Count), empreinte $(Get-Empreinte $slim)"
}

# Get-PlansProduction sur la vraie liste des plans, avec le nom du plan actif.
$pilote = [System.Management.Automation.Language.Parser]::ParseInput((Lis 'pilote.ps1'), [ref]$null, [ref]$null)
$def = $pilote.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-PlansProduction' }, $true)
$actif = (& powercfg.exe /getactivescheme) -join ' '
$m = [regex]::Match($actif, '([0-9a-fA-F-]{36})\s+\((.+)\)')
if ($def -and $m.Success) {
    $nomPlan = $m.Groups[2].Value.Trim()
    . ([ScriptBlock]::Create($def.Extent.Text))
    $vus = @(Get-PlansProduction)
    Dis ($vus.Count -ge 1 -and $vus -contains $m.Groups[1].Value.ToLower()) "Get-PlansProduction : $($vus.Count) plan(s) « $nomPlan », dont l'actif $($m.Groups[1].Value.ToLower())"
} else {
    Dis $false 'Get-PlansProduction : fonction ou plan actif introuvable'
}

Write-Output "$echecs échec(s)"
exit $echecs

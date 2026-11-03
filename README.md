# PC Management

Gestion du parc PC Pointe Noire (portables de régie, encodeurs, postes vMix et
Companion) au-dessus de MeshCentral. Étude d'architecture :
https://claude.ai/artifact/HH2q2UQaam1b11itbPQ9qo

Phase 1 : inventaire matériel et logiciel de chaque poste, historisé, et
synchronisé sur sa fiche du parc AVDiagram.

## Comment ça marche

1. `pcm` liste les postes Windows connectés à MeshCentral (`meshctrl listdevices`).
2. Il envoie `agent/inventory.ps1` à chaque poste en ligne
   (`meshctrl runcommand --powershell --reply`), quatre à la fois.
   Le script tourne en compte SYSTEM, ne modifie rien, et rend une ligne
   `PNINV1:<JSON en base64>`.
3. Chaque inventaire est gardé dans `data/pcm.sqlite`. Le rapport donne ce qui a
   changé depuis le précédent : logiciels ajoutés, retirés, mis à jour, matériel.
4. Avec `--push`, la fiche AVDiagram du poste est complétée par l'outil MCP
   `update_unit` : numéro de série (seulement s'il est vide), version de Windows
   dans le champ firmware, IP avec `--push-ip`.

La clé de rapprochement est la référence de parc AVDiagram (PN01, PC-VANNH...).
Le nom de l'appareil dans MeshCentral doit être cette référence. En attendant
les renommages, `config/mapping.json` fait la correspondance (voir
`config/mapping.example.json`).

Garde-fou : un numéro de série déjà saisi dans AVDiagram et différent de celui du
poste n'est jamais écrasé. Le rapport le signale, c'est le signe qu'un poste
porte le nom d'un autre.

## Installation sur le NAS

```bash
cp .env.example .env        # renseigner le compte MeshCentral et le jeton AVDiagram
mkdir -p data config
sudo chown 1000:1000 data   # le conteneur tourne en utilisateur node (uid 1000)
docker compose build
docker compose run --rm pcm devices
```

Le compte MeshCentral doit être dédié au worker, membre des groupes du parc, avec
le droit d'exécuter des commandes. Le jeton AVDiagram se crée dans Profil,
Jetons d'API, par un membre qui a le droit `parc:ecrire`.

## Test sur 2 postes

```bash
# 1. Inventaire seul, rien n'est écrit dans AVDiagram
docker compose run --rm pcm inventory --only PN01,PN02

# 2. Comparaison avec AVDiagram, toujours sans écrire
docker compose run --rm pcm inventory --only PN01,PN02 --check-avd

# 3. Écriture des fiches
docker compose run --rm pcm inventory --only PN01,PN02 --push
```

À vérifier pendant ce test : le script passe bien par l'agent MeshCentral
(longueur de commande, environ 9 300 caractères), la sortie revient complète, et
les noms de logiciels accentués sont lisibles.

## Limites connues

- Les logiciels installés « pour l'utilisateur » (clé HKCU) ne sont pas vus
  depuis le compte SYSTEM. Le rapport l'indique par `software_scope: machine`.
- La santé de batterie vient de `root\wmi` et peut manquer sur certains modèles.
- Les postes hors ligne sont listés à part et inventoriés au passage suivant.

## Développement

```bash
cd worker
python3 -m unittest discover -s tests -v
```

Python 3.11 ou plus, bibliothèque standard uniquement.

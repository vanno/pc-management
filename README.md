# PC Management

Gestion du parc PC Pointe Noire (portables de régie, encodeurs, postes vMix et
Companion) au-dessus de MeshCentral. Étude d'architecture :
https://claude.ai/artifact/HH2q2UQaam1b11itbPQ9qo

Phase 1 : inventaire matériel et logiciel de chaque poste, historisé, et
synchronisé sur sa fiche du parc AVDiagram.

## Comment ça marche

1. `pcm` liste les postes Windows connectés à MeshCentral (`meshctrl listdevices`).
2. Il envoie `agent/inventory.ps1` à chaque poste en ligne
   (`meshctrl runcommand --powershell --reply`), un poste à la fois.
   Le script tourne en compte SYSTEM, ne modifie rien, et rend une ligne
   `PNINV1:<jeton>:<JSON en base64>`. Le jeton, différent à chaque appel, garantit que la réponse vient bien du poste interrogé.
3. Chaque inventaire est gardé dans `data/pcm.sqlite`. Le rapport donne ce qui a
   changé depuis le précédent : logiciels ajoutés, retirés, mis à jour, matériel.
4. Avec `--push`, la fiche AVDiagram du poste est complétée par l'outil MCP
   `update_unit` : numéro de série (seulement s'il est vide), version de Windows
   dans le champ firmware, IP avec `--push-ip`.
5. Toujours avec `--push`, l'inventaire détaillé (machine, processeur, mémoire,
   cartes graphiques, disques, espace libre, réseau, batterie, logiciels, et
   ce qui a changé depuis le passage précédent) est posé sur la fiche par
   l'outil MCP `set_unit_inventory`. Il s'affiche dans la section « Inventaire
   du poste » de la fiche de l'appareil. Il faut un AVDiagram avec la migration
   0069 : avant, le rapport le signale en alerte et le reste du passage se fait.
   `--no-details` désactive cet envoi.

6. `pcm serve` tourne en service (`pcm-service` dans `docker-compose.yml`).
   Toutes les 30 secondes, il envoie à AVDiagram la liste des postes vus par
   MeshCentral (`POST /api/v1/postes/battement`) et repart avec au plus une
   tâche demandée depuis la page Parc, Postes. Il l'exécute (aujourd'hui :
   « Inventorier », soit le passage du point 5 sur ce seul poste), rend le
   résultat (`POST /api/v1/postes/taches/{id}`), puis prend la suivante sans
   attendre. C'est le NAS qui appelle : aucun port ouvert. Il faut un
   AVDiagram avec la migration 0070.

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

Le chemin du partage docker dépend du NAS (sur le DS920+ de l'agence : /volume2/docker). Le compte MeshCentral doit être dédié au worker, membre des groupes du parc, avec
le droit d'exécuter des commandes. Le jeton AVDiagram se crée dans Profil,
Jetons d'API, par un membre qui a le droit `parc:ecrire`.

## Service de la page Postes

```bash
docker compose build
docker compose up -d pcm-service
docker compose logs -f pcm-service     # une ligne par tâche, et les pannes
```

Le service ne s'arrête pas sur une panne (MeshCentral, réseau, AVDiagram) :
il l'écrit au journal et réessaie au battement suivant. Sans battement depuis
3 minutes, la page Postes affiche un bandeau. Après une mise à jour du code :
`docker compose build && docker compose up -d pcm-service`.

Une tâche passe en échec avec sa raison quand le poste est hors ligne, quand
MeshCentral ne connaît aucun agent à ce nom, ou quand l'action est inconnue de
cette version de l'outil. Une tâche prise et restée sans réponse 30 minutes
passe en échec côté AVDiagram.

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
- Les caractères de contrôle (un caractère nul laissé par le registre au bout
  d'un nom de logiciel) sont retirés avant l'envoi : PostgreSQL les refuse.

## Développement

```bash
cd worker
python3 -m unittest discover -s tests -v
```

Python 3.11 ou plus, bibliothèque standard uniquement.

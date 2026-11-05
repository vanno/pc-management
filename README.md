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

## Mise à jour automatique du NAS

Chaque fusion dans `main` construit l'image du worker sur GitHub (tests
compris) et la publie sur `ghcr.io/vanno/pc-management` (`latest` et le
numéro de commit). Le NAS la récupère seul la nuit : plus de ZIP à copier.

Mise en place, une seule fois :

1. Si le dépôt est privé, l'image l'est aussi. Créer sur GitHub un jeton
   classique avec le seul droit `read:packages`, puis sur le NAS, en root :

   ```bash
   docker login ghcr.io -u vanno
   ```

   (coller le jeton comme mot de passe ; il est gardé dans
   `/root/.docker/config.json`).
2. Copier une dernière fois `docker-compose.yml` et `scripts/` de main dans
   `/volume2/docker/pc-management-main`, puis lancer
   `sh scripts/maj-nas.sh` une fois à la main pour vérifier.
3. DSM, Panneau de configuration, Planificateur de tâches : Créer, Tâche
   planifiée, Script défini par l'utilisateur, utilisateur `root`, tous les
   jours à 04:30, commande :

   ```bash
   sh /volume2/docker/pc-management-main/scripts/maj-nas.sh
   ```

4. Pour le bouton « Mettre à jour l'outil » de la page Postes : une seconde
   tâche, même utilisateur `root`, tous les jours, répétée toutes les
   5 minutes de 00:00 à 23:55, commande :

   ```bash
   sh /volume2/docker/pc-management-main/scripts/maj-nas.sh --si-demande
   ```

   Elle ne fait rien tant qu'aucune mise à jour n'est demandée. Le bouton
   passe par le battement : `pcm-service` dépose `data/maj-demandee`, la
   tâche l'applique dans les 5 minutes. Le conteneur n'a jamais accès à
   Docker. La page Postes affiche la version en service (le commit de
   l'image) et la dernière ligne de `data/maj-nas.log`.

Pour forcer une mise à jour sans AVDiagram : Planificateur de tâches,
sélectionner la tâche, Exécuter, ou en SSH `sudo sh scripts/maj-nas.sh`.

Le script relance `pcm-service` seulement si l'image a changé, et note chaque
passage dans `data/maj-nas.log`. Un redémarrage du worker ne touche aucun
poste : une tâche en cours est reprise par AVDiagram après son délai. Pour
revenir à une version précise : `PCM_IMAGE=ghcr.io/vanno/pc-management:<commit>`
dans `.env`, puis `docker compose up -d pcm-service`. `docker compose build`
reste possible pour un essai local.

## Diagnostic réseau et réseaux du parc

« Diagnostic réseau » (page Postes) lance `agent/diagnostic.ps1` sur le poste,
sans rien changer : cartes et adresses, Wi-Fi, profil et état du pare-feu,
DNS, ports TCP joignables (MeshCentral, RTMP YouTube, Facebook Live, plus les
cibles demandées), ports à l'écoute avec leur processus. La version complète
ajoute le débit internet (speed.cloudflare.com, environ 60 Mo) et le ping de
tout le réseau local (/22 au plus large). Le détail part dans AVDiagram
(`POST /api/v1/postes/diagnostics`, migration 0080).

La sonde de supervision remonte aussi l'adresse, le préfixe, la passerelle, le
DHCP et le profil du pare-feu de chaque carte : la page Postes regroupe les
postes par réseau. Une sonde déjà posée garde l'ancien script : « Superviser »
à nouveau la remplace.

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

## Profil de logiciels

Un seul profil pour tous les postes, dans `config/logiciels.json` (copié de
`config/logiciels.example.json`, non suivi par git). Le bouton « Installer les
logiciels » de la page Postes installe par winget ce qui manque, met à jour le
reste, puis refait l'inventaire du poste.

```bash
cp config/logiciels.example.json config/logiciels.json
docker compose run --rm pcm software --only PN09   # test sur un poste
```

Chaque logiciel passe par un appel MeshCentral séparé, avec 30 minutes au plus.
Une tâche « logiciels » reste « En cours » jusqu'à 3 heures avant de passer en
échec côté AVDiagram (Office et Creative Cloud sont longs).

Points connus :

- Une mise à jour ferme le logiciel ouvert : à ne pas lancer sur un poste en
  cours d'événement.
- Adobe Creative Cloud installe le lanceur seul. Premiere Pro, After Effects,
  Photoshop se posent ensuite depuis le lanceur, avec une session Adobe.
- Microsoft 365 ne passe pas par winget : le paquet Microsoft.Office pointe
  vers un setup.exe que Microsoft remplace sans changer l'adresse, d'où
  l'erreur 0x8A150011 (empreinte différente). Il passe par les installeurs du
  NAS, voir plus bas.
- Microsoft 365 s'installe sans licence : la connexion se fait au premier
  lancement.
- QuickTime est exclu : Apple ne le met plus à jour depuis 2016 et ses failles
  ne sont pas corrigées.
- vMix, Blackmagic ATEM Switchers et DaVinci Resolve ne sont pas dans winget :
  voir « Installeurs du NAS » ci-dessous.

## Catalogue d'AVDiagram (Parc, Postes, Logiciels)

Depuis AVDiagram avec la migration 0072, le profil se tient dans l'onglet
Parc, Postes, Logiciels : identifiants winget, et installeurs .exe ou .msi
déposés depuis la page. Dès que ce catalogue a une ligne, il remplace
`config/logiciels.json` et `config/installeurs.json`. Chaque installeur arrive
avec une adresse de téléchargement signée (6 heures) : le poste le télécharge
lui-même (curl.exe, Windows 10 1803 et suivants), sans passer par le NAS. La
taille téléchargée est comparée à celle du catalogue avant l'installation.
`pcm software --only PN09` lit aussi ce catalogue quand `AVD_URL` et
`AVD_TOKEN` sont posés.

## Installeurs du NAS (vMix, ATEM, DaVinci)

Le même bouton installe aussi, après winget, les logiciels hors winget à partir
d'installeurs déposés sur le NAS. Le poste ne télécharge rien : le fichier lui
est envoyé par MeshCentral (`meshctrl upload`), lancé en silencieux sous le
compte SYSTEM, puis effacé.

1. Télécharger l'installeur Windows sur le site de l'éditeur. Pour ATEM et
   DaVinci, Blackmagic livre un ZIP : l'extraire et ne garder que le .exe ou le
   .msi qu'il contient.
2. Le déposer dans `installeurs/` à côté de `docker-compose.yml`.
3. Le décrire dans `config/installeurs.json` (modèle :
   `config/installeurs.example.json`) :

| Champ | Rôle |
|---|---|
| `nom` | nom affiché sur la page Postes |
| `fichier` | nom du .exe ou .msi dans `installeurs/` |
| `detection` | motif du nom dans Programmes et fonctionnalités, ex. `vMix*` |
| `version` | facultatif. Vide : un logiciel déjà présent est laissé tel quel. Rempli (ex. `29`) : toute autre version est remplacée |
| `arguments` | arguments de l'installation silencieuse. Un .msi reçoit déjà `/qn /norestart` |
| `configuration` | facultatif : texte écrit dans configuration.xml sur le poste, `{configuration}` dans `arguments` devient son chemin |

Tester un poste sans refaire winget :

```bash
docker compose run --rm pcm software --only PN09 --installers-only
```

Arguments silencieux du modèle, à valider sur PN09 avant tout le parc : ils
viennent de sources tierces, pas de l'éditeur.

- vMix : `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART` (installeur Inno Setup,
  cité sur le forum vMix).
- ATEM : le .msi du ZIP, sans argument de plus. Le pilote Blackmagic peut
  demander une confirmation de sécurité Windows qui bloquerait l'installation
  silencieuse : à vérifier au premier essai.
- DaVinci Resolve : `/i /q /noreboot` (SilentInstallHQ, version 18).
- Microsoft 365 : l'outil de déploiement d'Office (setup.exe) avec
  `/configure {configuration}`. Le champ `configuration` du modèle installe
  O365BusinessRetail, l'identifiant de Microsoft 365 Business Standard et
  Business Premium selon Microsoft (« Product IDs supported by the Office
  Deployment Tool »), en 64 bits, langue de Windows, canal Current, mises à
  jour automatiques. Office se télécharge depuis Microsoft. Pour récupérer
  setup.exe :

```bash
curl -L -o installeurs/setup.exe https://officecdn.microsoft.com/pr/wsus/setup.exe
```

L'envoi passe par le relais MeshCentral du NAS : compter le temps de
l'installeur de DaVinci (plusieurs Go) au débit montant de l'agence quand le
poste est dehors. Une tâche de plus de 3 heures passe en échec sur la page.
Le disque du poste doit avoir trois fois la taille de l'installeur de libre.

## Pilotage depuis la page Postes

Les boutons Redémarrer, Éteindre, Réveiller, Mode événement et le formulaire
Réseau de la page Postes passent par `agent/pilote.ps1`, envoyé au poste
compressé (gzip puis base64) comme les autres scripts.

- Redémarrer, Éteindre : `shutdown.exe /r` ou `/s`, `/f /t 30`, avec un
  message à l'écran. Refusé en mode événement.
- Réveiller : `meshctrl devicepower --wake`. Le serveur et chaque agent
  connecté envoient le paquet magique aux adresses MAC connues du poste.
  Il faut le Wake-on-LAN actif dans le BIOS et la carte réseau du poste.
- Mode événement : Windows Update en pause 7 jours (clés `Pause*` de
  `HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings`), pas de redémarrage
  automatique, veille et extinction d'écran à 0 sur secteur et batterie,
  notifications coupées (`ToastEnabled` et `NOC_GLOBAL_SETTING_TOASTS_ENABLED`
  des comptes ouverts), conseils et suggestions de Windows coupés
  (`ContentDeliveryManager`, écran « Tirez le meilleur parti de Windows »).
  Chaque partie (`windows_update`, `veille`, `notifications`, `conseils`)
  s'applique ou se rend seule avec le paramètre `parties` ; sans lui, les
  quatre. Les réglages d'avant sont gardés partie par partie dans
  `C:\ProgramData\PointeNoire\mode-evenement.json` et remis par « Fin du
  mode événement ». Le fichier disparaît quand plus aucune partie n'est
  active. Installer les logiciels est refusé tant qu'il existe. Seuls les
  comptes ouverts au moment de la commande sont touchés.
- Fond d'état (`agent/fond.ps1`, posé par `agent/fond-pose.ps1`) : sur
  l'écran principal, la référence, les cartes (IP, profil, débit), le mode
  événement partie par partie, le nettoyage, la sonde et la dernière commande ;
  gris en temps normal, orange en mode événement partiel, rouge complet. Les
  autres écrans sont noirs : rien ne part vers un projecteur ou un mur LED. La
  partie `fond` du mode événement met tout au noir, la référence en petit.
  Une tâche PointeNoire-Fond (groupe Utilisateurs, par `wscript` pour
  qu'aucune fenêtre ne s'ouvre) le redessine à l'ouverture de session, toutes
  les 15 minutes et après chaque commande du pilote. L'icône « État du poste »
  du Bureau public ouvre le détail en local. Le fond d'origine de chaque compte
  est gardé dans `%LOCALAPPDATA%\PointeNoire\fond-avant.json` et rendu au
  retrait ; un compte fermé le retrouve à sa prochaine session, la tâche part
  7 jours après. Windows à la une remettrait sa photo par-dessus : il est
  coupé pendant le fond d'état (`BackgroundType` et `DesktopSpotlight`) et
  rendu au retrait. Chaque passage relit le fond que Windows affiche et écrit
  son bilan dans `%LOCALAPPDATA%\PointeNoire\fond-resultat.json` ;
  `fond-pose.ps1` attend ce bilan 30 secondes dans chaque session ouverte, et
  la tâche AVDiagram passe en échec si une session n'a pas pris le fond. Avec
  plusieurs bureaux virtuels, Windows ne pose le fond que sur le bureau actif :
  le bilan le dit.
- Mur d'écrans (`agent/vignette.ps1`, posé par `agent/vignette-pose.ps1`) :
  AVDiagram tire un jeton `pnv_` par poste, qui ne permet que de poser l'image
  de son écran. Une tâche PointeNoire-Vignette (groupe Utilisateurs, chaque
  minute, par `wscript`) demande deux fois par minute si la page du mur montre
  ce poste ; seulement alors elle envoie une image réduite de tous les écrans
  (JPEG, 1920 x 540 au plus) toutes les 10 secondes, 30 en mode événement.
  Seule la session de la console capture ; écran verrouillé, elle le dit sans
  image. Le jeton est lisible par les comptes du poste (la capture tourne dans
  leur session). Le retrait enlève la tâche et le dossier.
- Message à l'écran : `meshctrl devicetoast` (notification) ou
  `devicemessage` (fenêtre à valider, 10 minutes au plus). Refusé sur un poste
  en mode événement, sauf avec `forcer`. MeshCentral ne confirme pas
  l'affichage d'une fenêtre : sans réponse en 20 secondes, elle est tenue
  pour relayée.
- Réseau : la commande garde la configuration de la carte dans
  `C:\ProgramData\PointeNoire\reseau\avant.json`, puis lance une tâche
  planifiée `PointeNoire-Reseau` (SYSTEM) qui applique la demande et teste
  pendant 90 s une connexion TCP vers l'hôte de `MESHCTRL_URL`. Sans réponse,
  elle remet la configuration d'avant. Le worker relit le résultat une fois
  l'agent revenu (jusqu'à 5 minutes). Sans retour automatique (réseau fermé
  d'une régie), le poste ne répond plus jusqu'à son retour sur un réseau qui
  joint MeshCentral.

### Contrôle : l'effet réel, relu dans Windows

Après le mode événement, le nettoyage et la sonde, le worker lance
`agent/controle.ps1` (à part de `pilote.ps1`, compte SYSTEM). Il ne change
aucun réglage : il relit ce que l'action devait changer et rend un point par
partie (`nom`, `ok`, `constat`), que la tâche AVDiagram garde dans `controle` :

| Partie | Ce qui est relu |
|---|---|
| Windows Update | la fin de pause dans `UX\Settings` (dans le futur) et `NoAutoRebootWithLoggedOnUsers` |
| Veille | `powercfg /q` du plan actif, et une stratégie de groupe qui imposerait une durée (`Policies\Microsoft\Power\PowerSettings`) |
| Notifications | le registre de chaque compte, puis Windows lui-même dans chaque session ouverte (`ToastNotificationManager`, réglage `DisabledForUser`) |
| Conseils Windows | le registre de chaque compte |
| Fond noir | la tâche PointeNoire-Fond relancée, le bilan de chaque session (`noir`) |
| Nettoyage | plan actif, services (désactivés et arrêtés), tâches, réglages, applications encore installées |
| Sonde | son premier passage (10 s après la pose), son code de sortie, aucune mesure en attente |

La lecture dans les sessions passe par une tâche temporaire du groupe
Utilisateurs (PointeNoire-Controle, par `wscript`), retirée aussitôt. Le
retour à la normale est comparé à l'état d'avant : `pilote.ps1` en garde une
copie (`mode-evenement-rendu.json`, `nettoyage-rendu.json`), relue dans les
10 minutes. Le fond d'état rend son propre contrôle : le bilan de chaque
session ouverte.

État du contrôle : `verifie` (chaque point relu tel que voulu),
`pas_applique` (Windows n'en applique pas un : la tâche passe en échec, avec
ce qui manque) ou `non_verifie` (contrôle impossible, aucune session ouverte,
ou un point illisible). Un compte dont la session s'est fermée pendant
l'événement ne retrouve pas ses notifications ni ses conseils au retour : le
contrôle le signale.

Le battement envoie aussi, pour chaque poste, le lien vers sa page MeshCentral
(`https://<hôte>/?gotonode=<id>&viewmode=11`) : la page Postes l’affiche en
« Prendre la main » : il ouvre directement l’onglet Bureau.

## Supervision (sonde par poste)

« Superviser » sur la page Postes : le worker demande à AVDiagram un jeton de
sonde pour ce poste (`POST /api/v1/postes/sondes`, jeton `pns_…` montré une
fois, AVDiagram n'en garde que l'empreinte), puis `pilote.ps1` installe
`agent/supervision.ps1` dans `C:\ProgramData\PointeNoire\supervision`
(dossier lisible par SYSTEM et les administrateurs seuls) et la tâche
planifiée `PointeNoire-Supervision` (SYSTEM, chaque minute et au démarrage).

Chaque minute, la sonde prend deux mesures à 30 s d'écart : CPU, mémoire,
disque système, débit reçu et envoyé de chaque carte physique active
(compteurs d'octets de la carte), latence et perte sur 4 pings vers la
passerelle et vers 1.1.1.1. Elle les envoie directement à AVDiagram
(`POST /api/v1/postes/mesures`), sans passer par le NAS ni par MeshCentral.
Sans réseau, les mesures attendent (10 au plus). Un 401 (sonde retirée ou
remplacée) désactive la tâche. Le jeton de sonde n'ouvre que cette route.

Le lien de chaque carte part aussi : filaire ou non, paquets en erreur sur
l'intervalle, et une carte filaire tombée depuis moins de 10 minutes
(`down`, état dans `liens.json`). AVDiagram en tire « lien coupé », « lien à
100 Mb/s » et « erreurs réseau », et une alerte en mode événement. Avec des
switchs non manageables (GS105), c'est le seul regard sur le câble. Un poste
déjà supervisé reçoit cette sonde au prochain « Superviser ».

## Envois : scripts approuvés et fichiers

L'onglet « Envois » de la page Postes d'AVDiagram (migration 0075) tient une
bibliothèque :

- des scripts PowerShell, qu'un administrateur approuve avant tout envoi. Un
  script approuvé ne se modifie plus : pour le changer, on en crée un autre.
  L'outil relit le script dans AVDiagram (`GET /api/v1/postes/envois/<id>`),
  vérifie qu'il est toujours approuvé et que son empreinte SHA-256 est celle de
  la demande, puis `agent/pilote.ps1` la vérifie encore sur le poste avant de
  le lancer (compte SYSTEM, 5 minutes au plus, sortie rendue dans le résultat
  de la tâche). Environ 12 000 caractères au plus : au-delà, la commande ne
  passe plus par MeshCentral et la tâche le dit ;
- des fichiers (fond d'écran, preset vMix, licence...), que le poste télécharge
  lui-même par une adresse signée dans le dossier choisi
  (`C:\Users\Public\Desktop` par défaut), taille vérifiée.

## Vitesse et régularité (lot 5)

- **Session permanente.** `pcm serve` garde une session ouverte avec
  MeshCentral (`worker/meshpipe.js`, lancé par l'outil) et marque chaque
  commande d'un identifiant de réponse à elle. meshctrl 1.2.5 marque toutes ses
  commandes `meshctrl` et le serveur renvoie chaque réponse à toutes les
  sessions du compte : deux meshctrl simultanés se volaient leurs réponses.
  Avec la session permanente, 4 postes travaillent en même temps
  (`PCM_CONCURRENCY`), les tâches d'un même poste l'une après l'autre (un
  agent ne fait qu'une commande à la fois). `PCM_MESHPIPE=0` revient à
  meshctrl, un poste à la fois. Le certificat du serveur est vérifié.
  L'envoi de fichiers du NAS, le réveil et la liste des postes passent
  toujours par meshctrl.
- **Planification.** `PCM_INVENTORY_AT` (« 03:00 » par défaut) : chaque nuit,
  un inventaire des postes en ligne. `PCM_UPDATE_AT` (« dim 04:00 » par
  défaut) : chaque semaine, « Installer les logiciels » sur les postes en
  ligne ; un poste en mode événement est laissé tel quel, sa tâche finit
  « Ignoré ». `off` coupe l'une ou l'autre. Fuseau : `PCM_TZ`
  (Europe/Paris). Les tâches passent par la file d'AVDiagram
  (`POST /api/v1/postes/taches`) et se lisent sur la page Postes. Un créneau
  manqué n'est rattrapé que dans les 6 heures.
- **Version de MeshCentral.** Une fois par jour, `meshctrl serverversion`
  donne la version du serveur et la dernière publiée ; la page Postes
  affiche un bandeau quand elles diffèrent. La mise à jour du serveur reste
  une décision manuelle : pensez à aligner `MESHCENTRAL_VERSION` du
  Dockerfile.

## Nettoyage réversible (lot 6)

L'action « Nettoyer » de la page Postes applique un profil de production, et
« Annuler le nettoyage » remet le poste comme avant. L'état d'origine est
écrit sur le poste avant tout changement, dans
`C:\ProgramData\PointeNoire\nettoyage.json` ; une seconde application garde
l'état de la première.

| Partie | Effet | Annulation |
|---|---|---|
| Alimentation | copie du plan Performances optimales (sinon Performances élevées), mise en veille sélective USB et économie PCI Express coupées | plan d'avant réactivé, copie supprimée |
| Services | DiagTrack, dmwappushservice, MapsBroker, RetailDemo, XblAuthManager, XblGameSave, XboxNetApiSvc, Fax, lfsvc désactivés | type de démarrage d'avant |
| Tâches | collecte de compatibilité, programme d'amélioration, retours, cartes, diagnostic disque | réactivées si elles l'étaient |
| Réglages | télémétrie au minimum, enregistrement de jeu, applications suggérées, publicité, Cortana, widgets, démarrage rapide coupés | valeurs d'avant, ou supprimées |
| Applications (option) | Actualités, Météo, Xbox, Solitaire, Contacts, Hub de commentaires, Clipchamp, Candy Crush… retirées pour tous les comptes | **non réinstallées** : la liste est rendue, à réinstaller depuis le Microsoft Store |

Rien ne touche à Defender, au pare-feu, à Windows Update, à la recherche, aux
manettes ni au Lecteur multimédia. Refusé en mode événement, dans les deux
sens : le mode événement garde les réglages de veille du plan actif. Le
démarrage rapide coupé prend effet au prochain redémarrage. Certaines
stratégies dépendent de l'édition : d'après Microsoft, celle des applications
suggérées n'agit que sous Entreprise et Éducation. Elles sont posées quand
même, sans effet ailleurs. Non vérifié sur un vrai poste à l'écriture.

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

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

   Depuis le schéma 2 de `agent/inventory.ps1`, l'inventaire porte aussi la
   santé de chaque disque (`Get-PhysicalDisk`, page SMART NVMe lue directement
   par `IOCTL_STORAGE_QUERY_PROPERTY`, sinon `Get-StorageReliabilityCounter`,
   refusé sur certains postes :
   état Windows, usure en %, température, heures sous tension, erreurs non
   corrigées, alerte SMART `MSStorageDriver_FailurePredictStatus`), les cycles
   et capacités de la batterie (`BatteryCycleCount`, `BatteryStaticData`,
   `BatteryFullChargedCapacity`, et à défaut le rapport `powercfg /batteryreport`,
   car `BatteryStaticData` échoue sur certains Lenovo), la licence Windows (`SoftwareLicensingProduct` :
   activée ou non, canal OEM, Retail ou Volume, les 5 derniers caractères de
   la clé, jamais la clé) et l'édition de vMix, lue par son API locale
   (`http://127.0.0.1:8088/api`) quand vMix est ouvert. vMix fermé, l'édition
   vue la dernière fois est gardée avec sa date. Les heures sous tension du
   disque système servent de compteur d'utilisation du poste. AVDiagram en
   garde un point par jour (migration 0089) pour prévoir l'usure.

   Inventaire à l'allumage : un poste qui apparaît en ligne dans MeshCentral
   reçoit une tâche « Inventaire à l'allumage », au plus une fois toutes les
   deux heures par poste. Elle est ignorée, sans échec, si le poste est en
   mode événement, comme l'inventaire de la nuit. Un clic sur « Faire
   l'inventaire » passe toujours.

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

## Mots de passe et ouverture de session automatique

« Changer le mot de passe » (page Postes, administrateurs) change le mot de
passe d'un compte local et active ou coupe l'ouverture de session automatique
(`agent/motdepasse.ps1`, migration 0088 d'AVDiagram). Sans compte précisé, le
poste prend son compte principal : celui de l'ouverture automatique, sinon de
la session ouverte, sinon le seul compte local actif ; s'il y en a plusieurs,
il refuse. Un compte Microsoft est refusé : son mot de passe se change en
ligne.

Le chemin du mot de passe : AVDiagram le garde chiffré (AES-256-GCM, clé
`AVD_CLE_SECRETS` sur Vercel). Le relais le lit au dernier moment
(`GET /api/v1/postes/taches/{id}/secret`, seulement tant que la tâche est en
cours), demande au poste sa clé publique (paire RSA 2048 dans le magasin de
clés de la machine, conteneur `PointeNoire-Relais`) et l'envoie chiffré en
RSA-OAEP. La commande MeshCentral, le journal du relais et la réponse du poste
ne le portent jamais en clair. L'ouverture automatique le range comme Windows
(secret LSA `DefaultPassword`) et retire toute valeur `DefaultPassword` en
clair du registre. La tâche relit le mot de passe auprès de Windows et
l'ouverture automatique avant de se dire faite.

## Désinstaller un logiciel

« Désinstaller » (AVDiagram, Postes, Préparer, Logiciels installés) retire UN
logiciel de la liste relevée par l'inventaire, sur un ou plusieurs postes
cochés : une tâche `desinstallation` par poste, `{ nom, version? }`
(`agent/desinstalle.ps1`, migration 0092 d'AVDiagram). Refusée en mode
événement. Après une désinstallation réussie, le relais relève l'inventaire :
la liste d'AVDiagram ne montre plus le logiciel.

Seulement en silencieux, dans cet ordre : MSI (`msiexec /x {GUID} /qn
/norestart`), la commande silencieuse écrite par l'éditeur
(`QuietUninstallString`), Inno Setup (`/VERYSILENT /SUPPRESSMSGBOXES
/NORESTART`), puis `winget uninstall --name <nom> --exact --silent`. Sans
aucune des quatre, rien n'est lancé et la tâche le dit : un désinstalleur à
fenêtre attendrait un clic en compte SYSTEM. 10 minutes par désinstalleur,
puis arrêt ; le registre est relu une minute pour le contrôle (« encore
listé » = échec). Jamais de redémarrage, seulement signalé. L'agent
MeshCentral est refusé, par le relais et par le poste.

Limite : les logiciels installés « pour un utilisateur » (HKCU) ne sont pas
dans l'inventaire, donc pas proposés.

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
  événement partie par partie, le nettoyage, la sonde et les cinq dernières
  actions, chacune « Réussi » (vert) ou « Échec » (rouge) ; gris en temps
  normal, orange en mode événement partiel, rouge complet. Les autres écrans
  sont noirs : rien ne part vers un projecteur ou un mur LED. La partie
  `fond` du mode événement remplace ce panneau par l'écran d'un technicien du
  direct (`agent/releve.ps1`) : le logo Pointe Noire (en vecteurs, repris des
  étiquettes d'AVDiagram), un bandeau « MODE ÉVÉNEMENT » avec la
  référence et l'heure du relevé, un cadre « À vérifier » qui remonte les
  points bloquants, puis trois colonnes. Réseau : carte, câble ou Wi-Fi,
  vitesse du lien, IP locale et publique, profil Public (NDI bloqué),
  passerelle, internet, DNS
  et sortie RTMP (port 1935). Écrans et son : définition et fréquence de
  chaque écran, sortie et entrée son par défaut. Machine : secteur ou
  batterie, mode d'alimentation, disques, mémoire, redémarrage en attente,
  cartes graphiques. Services : prise en main à distance, son Windows et
  services de production (Dante, NDI, Blackmagic, AJA, Magewell, Elgato,
  vMix, Companion, Bonjour). Logiciels du direct installés, lancés ou non
  (vMix, OBS, Companion, ATEM, NDI Tools, Dante, Desktop Video). Protections :
  chaque partie du mode, avec les notifications et la veille relues dans
  Windows, et les dernières actions. Le même relevé s'ajoute à la page « État
  du poste ». Le relais envoie `releve.ps1` avant le fond, dans une commande
  à part posée par `agent/releve-pose.ps1`, pour rester sous la longueur de
  commande de MeshCentral. Sans fond d'état sur le poste, le relais le pose en même temps
  (`fond_a_poser`), et le poste le retire à la fin du mode ; le retrait à la
  main est refusé pendant le mode.
  L'historique vient de `pilote.ps1` (`historique` dans `fond\etat.json`) ;
  `controle.ps1` y fait passer en échec l'action que Windows n'a pas appliquée.
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
| Écran « Mode événement » | la tâche PointeNoire-Fond relancée, le bilan de chaque session (`noir`) |
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

Windows PowerShell 5.1 rend seul l'objet d'une liste qui n'en compte qu'un, et
un `[pscustomobject]` seul n'y a pas de `.Count` : `$x = Get-Sessions` puis
`$x.Count` y vaut rien, et un seul compte ouvert passait pour « aucune
session ». Ces listes s'écrivent `$x = @(Get-Sessions …)`, ce que
`AgentScriptTests` vérifie dans tous les scripts.

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

## Veille réseau (monitoring réseau, lot 1)

Posée juste après la sonde, par sa propre commande (`agent/reseau-pose.ps1`,
`agent/reseau.ps1` dans `$VeilleSource`), dans
`C:\ProgramData\PointeNoire\reseau`, tâche `PointeNoire-Reseau` (SYSTEM, au
démarrage puis relancée toutes les 5 minutes si elle s'est arrêtée, une seule
à la fois). Retirée avec la sonde. Rien n'est changé sur le poste.

Chaque seconde, un ping vers la passerelle, la cible du site et 1.1.1.1. La
cible du site vient de la tâche (`cible`, `nom_cible`, réglées dans AVDiagram),
sinon de la première console régie qui a une adresse dans
`config/consoles.json`. Toutes les 2 s, l'état des cartes physiques par .NET
(lien, vitesse, adresse, passerelle, DNS, serveur DHCP, octets, erreurs,
paquets jetés, multicast et broadcast reçus). Toutes les 10 s, le Wi-Fi
(netsh), la MAC de la passerelle et les retransmissions TCP. Toutes les 30 s,
la résolution DNS du serveur AVDiagram demandée au serveur DNS de la carte, la
connexion TCP 443, le profil du pare-feu, les conflits d'adresse (Tcpip 4199)
et les déconnexions Wi-Fi (WLAN-AutoConfig 8003).

Sur le poste, dans `journal` : une ligne par seconde (un fichier par heure,
24 h), les événements et les résumés par minute (7 jours). Chaque minute, le
résumé (min, médiane, 95e centile, max, gigue, perte, plus longue coupure par
cible ; débit moyen et maximal, erreurs par carte ; Wi-Fi ; DNS ; TCP) et les
événements partent vers `POST /api/v1/postes/reseau`, avec le jeton de la
sonde. Sans réseau, 60 minutes et 300 événements attendent dans
`en-attente.json`.

### Essais avant fusion et déploiement

Chaque PR lance `.github/workflows/essais.yml` : les tests du relais, puis sur
la machine Windows jetable de GitHub (Windows PowerShell 5.1)
`scripts/essai-windows.ps1` (syntaxe et envoi de chaque script) et
`scripts/essai-veille.ps1 -Jetable`. Ce dernier pose la veille par la vraie
commande du relais (`scripts/essai-commande.py`, donc `pcm.pilot`), la laisse
tourner 150 s sous SYSTEM, relit le journal du poste, reçoit ses envois sur un
faux AVDiagram en HTTPS (`scripts/essai-recepteur.py`), mesure le processeur
consommé, puis la retire. Il refuse de tourner sur un poste qui a une sonde.
Les envois reçus sont rejoués côté AVDiagram
(`src/lib/postes/fixtures/veille-windows.json`).

Déploiement : fusionner cette PR d'abord (l'image part sur GHCR, le NAS la
prend à 04:30 ou au bouton « Mettre à jour l'outil »), puis celle d'AVDiagram
(migration 0093 passée au déploiement Vercel). Sur un poste, la veille arrive
au prochain « Activer le suivi ». Tant qu'AVDiagram n'a pas la route, la
veille reçoit 404 et jette ses minutes : rien ne s'accumule.

## Console régie locale (site sans internet, lot 1)

Sur un site sans internet, les postes ne joignent plus AVDiagram ni
MeshCentral. La console régie reprend la supervision sur le réseau du site :
c'est un exécutable Windows (`console-regie.exe`) lancé sur le PC régie. Plan :
https://claude.ai/artifact/2MBxWMg3x1U5vKYB8vn5Uh. Le lot 1 est en lecture
seule : santé, réseaux, Companion. Aucune action sur les postes.

Ce qui se passe :

1. Les sondes déjà posées envoient chaque mesure (toutes les 30 s) à la
   console, en plus d'AVDiagram. Elles la trouvent par une diffusion UDP sur
   le port 8472, ou à l'adresse fixée à l'avance si la diffusion ne passe
   pas. Aucune règle de pare-feu sur les postes : seul le PC régie écoute.
2. L'envoi se fait en HTTPS (port 8471) vers un certificat auto-signé dont
   l'empreinte est épinglée dans la sonde : un appareil du LAN qui se ferait
   passer pour la console ne reçoit rien. Chaque poste présente son propre
   jeton, calculé par le relais du NAS avec le secret de la console : un
   appareil inconnu ne peut pas écrire de fausses mesures.
3. La page `http://127.0.0.1:8470/` (ouverte au lancement) montre l'état de
   chaque poste, ses alertes (processeur, mémoire, disque, passerelle, câble
   débranché, erreurs réseau), ses courbes des 2 dernières heures, et les
   réseaux du parc avec les adresses en double et les passerelles qui ne
   concordent pas. Les mesures des 12 dernières heures restent sur la
   console (`%LOCALAPPDATA%\PointeNoire\ConsoleRegie`).
4. Companion (Stream Deck) : la console pousse des variables personnalisées
   par l'API HTTP de Companion (`POST /api/custom-variable/<nom>/value`).

Mise en place, une fois :

1. Télécharger `console-regie.exe` :
   https://github.com/vanno/pc-management/releases/latest/download/console-regie.exe
   (construit et essayé sous Windows PowerShell 5.1 par GitHub à chaque
   fusion). Il n'est pas signé : SmartScreen demande « Informations
   complémentaires », « Exécuter quand même ».
2. Le lancer. Au premier lancement, Windows demande d'autoriser l'accès au
   réseau : cocher réseaux privés ET publics (un réseau d'événement est
   souvent classé Public). Sans cette autorisation, aucune sonde n'arrive.
   En administrateur, l'équivalent :

   ```powershell
   New-NetFirewallRule -DisplayName "Console régie Pointe Noire (TCP)" -Direction Inbound -Protocol TCP -LocalPort 8471 -Action Allow -Profile Any
   New-NetFirewallRule -DisplayName "Console régie Pointe Noire (UDP)" -Direction Inbound -Protocol UDP -LocalPort 8472 -Action Allow -Profile Any
   ```

3. Sur la page de la console, section « Appairage et accès » : copier le
   bloc proposé dans `config/consoles.json` sur le NAS (modèle :
   `config/consoles.example.json`). `adresse` est l'adresse de secours du PC
   régie, à mettre en IP fixe sur le réseau du site si possible.
4. C'est tout : le relais voit le changement de `consoles.json` et fait
   reposer la sonde sur chaque poste supervisé (comme après une mise à jour),
   avec l'empreinte et le jeton du poste. Un poste qui n'était pas supervisé
   doit l'être (« Superviser »), et il faut internet pour cette pose.

La console garde son identité (certificat, secret, code de la page) dans son
dossier : la relancer ne change rien. Changer de PC régie, c'est une autre
console : remettre son code dans `consoles.json`. Le code d'appairage contient
le secret, il ne se partage pas.

Voir la page depuis un autre appareil : `https://<adresse du PC régie>:8471/`,
puis le code à 6 chiffres affiché dans la fenêtre de la console. Le navigateur
prévient d'un certificat inconnu : comparer l'empreinte avec celle de la
fenêtre.

Companion :

1. Sur la page de la console, régler l'adresse de Companion
   (`http://127.0.0.1:8000` s'il tourne sur le même PC).
2. Dans Companion, Variables personnalisées : créer les variables listées
   sur la page (`pn_resume`, `pn_etat`, `pn_alertes`, `pn_hors_ligne`, et par
   poste `pn_pn09_etat`, `pn_pn09_texte`, `pn_pn09_cpu`). Je ne peux pas
   confirmer qu'une variable absente est créée par l'API : la page affiche le
   refus de Companion si c'est le cas.
3. Sur un bouton : texte `$(custom:pn_pn09_texte)`, retour interne
   « Variable : vérifier la valeur » sur `pn_pn09_etat` égal à `ALERTE` ou
   `HORS LIGNE` pour la couleur.

Pour un Companion sur un autre appareil qui lit plutôt que de recevoir :
`GET https://<PC régie>:8471/api/companion` (toutes les variables en JSON) ou
`/api/companion/pn_resume` (une valeur en texte), avec `?jeton=` ou
`Authorization: Bearer` et le jeton Companion de la page.

Côté poste, `agent/console.ps1` est posé par `agent/console-pose.ps1` dans
le dossier de la sonde, juste après elle. Son état est dans
`C:\ProgramData\PointeNoire\supervision\console-vue.json` (dernière
adresse, ok, injoignable, jeton_refuse). Une panne de la console ne change
rien à l'envoi vers AVDiagram.

Le PC régie et les postes doivent être sur le même réseau, pas seulement
dans la même plage d'adresses. Essai du 06/11 : PC de Vannh à la maison en
192.168.1.44 (passerelle 192.168.1.254), PN09 et PN-UK au bureau en
192.168.1.34 et .42 (passerelle 192.168.1.1). Même plage, deux réseaux :
aucune mesure n'arrive. Pour vérifier depuis le PC régie :
`ping <adresse d'un poste>` doit répondre, et sa passerelle (`ipconfig`)
doit être celle que la page Postes d'AVDiagram montre pour les postes.
L'adresse de secours de `consoles.json` est l'adresse du PC régie sur ce
réseau, jamais celle de Tailscale (100.x) : les postes ne la joignent pas.
La page de la console propose l'adresse du réseau local en premier.

Limites du lot 1 : lecture seule (les actions signées sont le lot 2), pas de
renvoi du journal à AVDiagram (lot 3). La découverte UDP ne traverse pas un
routeur : sur un autre réseau, seule l'adresse fixée marche.

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
l'état de la première. Chaque écriture refusée par Windows est nommée dans le
résultat (« Refusé par Windows : service …, réglage … ») et le reste
s'applique. Si Windows refuse la liste des applications, la désinstallation
passe en échec en le disant, le profil restant appliqué : le relais le
signale (`partiel`), le contrôle relit quand même l'allègement, et AVDiagram
montre le poste allégé avec la désinstallation en échec.

| Partie | Effet | Annulation |
|---|---|---|
| Alimentation | copie du plan Performances optimales (sinon Performances élevées), mise en veille sélective USB et économie PCI Express coupées | plan d'avant réactivé, copie supprimée |
| Services | DiagTrack, dmwappushservice, MapsBroker, RetailDemo, XblAuthManager, XblGameSave, XboxNetApiSvc, Fax, lfsvc désactivés | type de démarrage d'avant |
| Tâches | collecte de compatibilité, programme d'amélioration, retours, cartes, diagnostic disque | réactivées si elles l'étaient |
| Réglages | télémétrie au minimum, enregistrement de jeu, applications suggérées, publicité, Cortana, widgets, démarrage rapide coupés | valeurs d'avant, ou supprimées |
| Widgets | réglage `AllowNewsAndInterests` à 0 ; si le pilote UCPD de Windows 11 le refuse, il passe par la stratégie de groupe locale (Registry.pol écrit par le relais, `gpupdate /target:computer`), aussi sur Windows Famille sans gpedit ; si Windows ignore la stratégie, le paquet des widgets (`MicrosoftWindows.Client.WebExperience`) est retiré | entrée retirée de la stratégie locale ; paquet non réinstallé |
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

La console régie (`console/`) a besoin de `cryptography` (certificat) :

```bash
cd console
pip install -r requirements.txt
python3 -m unittest discover -s tests -v
python3 -m regie --dossier /tmp/console --sans-navigateur
```

L'essai de bout en bout sous Windows PowerShell 5.1 est
`console/essai-windows.ps1`, lancé par `.github/workflows/console.yml`.

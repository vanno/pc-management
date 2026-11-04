#!/bin/sh
# Mise à jour automatique du worker sur le NAS. À lancer par une tâche
# planifiée DSM (Panneau de configuration, Planificateur de tâches, script
# défini par l'utilisateur, compte root), chaque nuit :
#
#   sh /volume2/docker/pc-management-main/scripts/maj-nas.sh
#
# Récupère la dernière image publiée par GitHub ; si elle a changé, relance
# pcm-service. .env, config/, data/ et installeurs/ ne sont jamais touchés.
# Pour revenir à une version : PCM_IMAGE=ghcr.io/vanno/pc-management:<commit>
# dans .env, puis docker compose up -d pcm-service.
set -eu
PATH=/usr/local/bin:/usr/bin:/bin:$PATH

DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$DIR"
JOURNAL="$DIR/data/maj-nas.log"
note() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$JOURNAL"; }

avant=$(docker compose images -q pcm-service 2>/dev/null || true)
if ! docker compose pull -q pcm-service >> "$JOURNAL" 2>&1; then
  note "échec du téléchargement de l'image (connexion à ghcr.io ?), version actuelle gardée"
  exit 1
fi
docker compose up -d pcm-service >> "$JOURNAL" 2>&1
apres=$(docker compose images -q pcm-service 2>/dev/null || true)
if [ "$avant" = "$apres" ]; then
  note "déjà à jour"
else
  note "mis à jour : ${avant:-aucune} -> $apres"
  docker image prune -f >> "$JOURNAL" 2>&1 || true
fi
# Le journal garde ses 500 dernières lignes.
tail -n 500 "$JOURNAL" > "$JOURNAL.tmp" && mv "$JOURNAL.tmp" "$JOURNAL"

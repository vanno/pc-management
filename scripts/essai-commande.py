"""La commande que le relais envoie pour poser ou retirer la veille réseau,
construite par le relais lui-même (pcm.pilot), écrite dans un fichier pour
scripts/essai-veille.ps1.

    python essai-commande.py <fichier> <jeton hexadécimal> <pose|retrait> [cible] [nom de la cible]
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "worker"))

from pcm import pilot  # noqa: E402

out, nonce, sens = sys.argv[1], sys.argv[2], sys.argv[3]
params: dict = {"op": "reseau_veille", "actif": sens == "pose"}
if sens == "pose":
    params.update({"cible": sys.argv[4] if len(sys.argv) > 4 else None, "nom_cible": sys.argv[5] if len(sys.argv) > 5 else None})
script = pilot.with_source(pilot.WATCH_INSTALLER.read_text(encoding="utf-8"), pilot.WATCH_SCRIPT, "VeilleSource")
command = pilot.build_command(params, nonce, script)
if len(command) > pilot.MAX_COMMAND:
    sys.exit(f"commande trop longue : {len(command)} caractères (limite {pilot.MAX_COMMAND})")
Path(out).write_text(command, encoding="utf-8")
print(len(command))

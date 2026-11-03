"""Appels à MeshCentral par l'outil officiel meshctrl (node meshctrl.js).

Les identifiants viennent de l'environnement (MESHCTRL_URL,
MESHCTRL_LOGINUSER, MESHCTRL_LOGINPASS, MESHCTRL_TOKEN pour un second
facteur) et sont passés en arguments --url, --loginuser, --loginpass, --token.
meshctrl ne lit ces variables lui-même qu'à partir des versions postérieures à
la 1.2.5 : sans arguments, il se connecte à wss://localhost.
"""

from __future__ import annotations

import json
import os
import shlex
import subprocess
from dataclasses import dataclass

# Bit 1 de `conn` : l'agent est connecté au serveur.
AGENT_CONNECTED = 1


class MeshError(RuntimeError):
    pass


@dataclass(frozen=True)
class Device:
    id: str
    name: str
    group: str | None
    online: bool
    os: str | None

    @property
    def is_windows(self) -> bool:
        return "windows" in (self.os or "").lower()


class MeshCtrl:
    def __init__(self, command: str | None = None, timeout: int = 180):
        # Ex. « node /opt/meshcentral/node_modules/meshcentral/meshctrl.js »
        self.command = shlex.split(command or os.environ.get("MESHCTRL_CMD", "node meshctrl.js"))
        self.timeout = timeout

    def _login_args(self) -> list[str]:
        url = os.environ.get("MESHCTRL_URL")
        if not url:
            raise MeshError("Variable MESHCTRL_URL manquante (ex. wss://meshcentral.pointe-noire.com)")
        args = ["--url", url]
        for flag, var in (("--loginuser", "MESHCTRL_LOGINUSER"), ("--loginpass", "MESHCTRL_LOGINPASS"), ("--token", "MESHCTRL_TOKEN")):
            if os.environ.get(var):
                args += [flag, os.environ[var]]
        return args

    def _run(self, *args: str, timeout: int | None = None) -> str:
        try:
            done = subprocess.run(
                [*self.command, *args, *self._login_args()],
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=timeout or self.timeout,
                check=False,
            )
        except subprocess.TimeoutExpired as exc:
            raise MeshError(f"meshctrl {args[0]} : délai dépassé ({exc.timeout} s)") from exc
        if done.returncode != 0:
            raise MeshError(f"meshctrl {args[0]} : code {done.returncode} : {(done.stderr or done.stdout).strip()[:300]}")
        # meshctrl rend 0 même quand la connexion échoue : on le lit dans la sortie.
        first = done.stdout.strip().splitlines()[:1]
        if first and first[0].startswith(("Unable to connect", "Invalid login", "Invalid url", "Authentication token required")):
            raise MeshError(f"meshctrl {args[0]} : {first[0]}")
        return done.stdout

    def list_devices(self, group: str | None = None) -> list[Device]:
        args = ["listdevices", "--json"]
        if group:
            args += ["--group", group]
        out = self._run(*args, timeout=60)
        try:
            nodes = json.loads(out)
        except json.JSONDecodeError as exc:
            raise MeshError(f"meshctrl listdevices : réponse non JSON : {out.strip()[:300]}") from exc
        return [parse_device(n) for n in nodes]

    def run_powershell(self, device_id: str, command: str, timeout: int | None = None) -> str:
        """Exécute une commande PowerShell sur le poste et rend sa sortie."""
        return self._run("runcommand", "--id", device_id, "--powershell", "--reply", "--run", command, timeout=timeout)

    def upload(self, device_id: str, local_path: str, remote_dir: str, timeout: int | None = None) -> None:
        """Envoie un fichier dans un dossier du poste, sous le même nom.

        meshctrl rend 0 même quand l'envoi échoue : on lit sa sortie, qui finit
        par « Upload done, N bytes sent. » quand tout est passé.
        """
        out = self._run("upload", "--id", device_id, "--file", local_path, "--target", remote_dir, timeout=timeout)
        if "Upload done" not in out:
            last = (out.strip().splitlines() or ["(sortie vide)"])[-1]
            raise MeshError(f"meshctrl upload : envoi non terminé : {last[:200]}")


def parse_device(node: dict) -> Device:
    return Device(
        id=node["_id"],
        name=node.get("name") or node.get("rname") or node["_id"],
        group=node.get("groupname"),
        online=bool((node.get("conn") or 0) & AGENT_CONNECTED),
        os=node.get("osdesc"),
    )

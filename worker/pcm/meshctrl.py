"""Appels à MeshCentral par l'outil officiel meshctrl (node meshctrl.js).

meshctrl lit ses identifiants dans l'environnement : MESHCTRL_URL,
MESHCTRL_LOGINUSER, MESHCTRL_LOGINPASS (et MESHCTRL_TOKEN pour un second
facteur). Ils ne passent donc jamais sur la ligne de commande, où `ps` les
montrerait.
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

    def _run(self, *args: str, timeout: int | None = None) -> str:
        try:
            done = subprocess.run(
                [*self.command, *args],
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

    def run_powershell(self, device_id: str, command: str) -> str:
        """Exécute une commande PowerShell sur le poste et rend sa sortie."""
        return self._run("runcommand", "--id", device_id, "--powershell", "--reply", "--run", command)


def parse_device(node: dict) -> Device:
    return Device(
        id=node["_id"],
        name=node.get("name") or node.get("rname") or node["_id"],
        group=node.get("groupname"),
        online=bool((node.get("conn") or 0) & AGENT_CONNECTED),
        os=node.get("osdesc"),
    )

"""Profil de logiciels de la page Postes : installer ce qui manque, mettre à jour le reste.

Un logiciel à la fois, par `agent/winget.ps1` envoyé au poste comme
l'inventaire (`meshctrl runcommand --powershell --reply`, compte SYSTEM). Le
profil est le même pour tous les postes : `config/logiciels.json` (voir
`config/logiciels.example.json`), relu à chaque tâche.
"""

from __future__ import annotations

import base64
import binascii
import json
import re
from dataclasses import dataclass
from pathlib import Path

MARKER = "PNWG1:"
AGENT_SCRIPT = Path(__file__).resolve().parents[2] / "agent" / "winget.ps1"
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.+_-]{0,127}$")
# Microsoft 365 ou Creative Cloud : un téléchargement de plusieurs Go.
PACKAGE_TIMEOUT = 1800

# Codes de sortie de winget (AppInstallerErrors.h, dépôt microsoft/winget-cli).
UPDATE_NOT_APPLICABLE = 0x8A15002B - 2**32
PACKAGE_ALREADY_INSTALLED = 0x8A150061 - 2**32
NO_APPLICATIONS_FOUND = 0x8A150014 - 2**32
PACKAGE_IN_USE = 0x8A150101 - 2**32
INSTALL_IN_PROGRESS = 0x8A150102 - 2**32
REBOOT_TO_FINISH = 0x8A150109 - 2**32
REBOOT_FOR_INSTALL = 0x8A15010A - 2**32
PACKAGE_IN_USE_BY_APPLICATION = 0x8A150111 - 2**32


class SoftwareError(ValueError):
    pass


@dataclass(frozen=True)
class Package:
    id: str
    name: str


@dataclass(frozen=True)
class Outcome:
    package: Package
    state: str  # installed | updated | uptodate | reboot | failed
    detail: str = ""

    @property
    def ok(self) -> bool:
        return self.state != "failed"


def load_profile(path: str | Path) -> list[Package]:
    p = Path(path)
    if not p.exists():
        raise SoftwareError(f"Profil de logiciels absent : créez {p} (modèle : config/logiciels.example.json).")
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise SoftwareError(f"Profil de logiciels illisible ({p}) : {exc}") from exc
    items = data.get("logiciels") if isinstance(data, dict) else data
    if not isinstance(items, list) or not items:
        raise SoftwareError(f"Profil de logiciels vide ({p}).")
    packages, seen = [], set()
    for item in items:
        pid = (item.get("id") if isinstance(item, dict) else item) or ""
        pid = str(pid).strip()
        if not ID_RE.match(pid):
            raise SoftwareError(f"Identifiant winget illisible dans le profil : {pid!r}")
        if pid.lower() in seen:
            continue
        seen.add(pid.lower())
        name = str(item.get("nom") or pid) if isinstance(item, dict) else pid
        packages.append(Package(pid, name))
    return packages


def build_command(package_id: str, nonce: str, script: str | None = None) -> str:
    if not ID_RE.match(package_id):
        raise SoftwareError(f"Identifiant winget illisible : {package_id!r}")
    if not re.fullmatch(r"[0-9a-f]+", nonce):
        raise SoftwareError("Jeton invalide.")
    if script is None:
        script = AGENT_SCRIPT.read_text(encoding="utf-8")
    encoded = base64.b64encode(script.encode("utf-8")).decode("ascii")
    return (
        f"$env:PNWG_NONCE='{nonce}';$env:PNWG_ID='{package_id}';"
        "$s=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('"
        + encoded
        + "'));& ([ScriptBlock]::Create($s))"
    )


def parse_output(output: str, nonce: str) -> dict:
    for line in reversed(output.splitlines()):
        line = line.strip()
        if not line.startswith(MARKER):
            continue
        received, _, payload = line[len(MARKER):].partition(":")
        if received != nonce:
            raise SoftwareError(f"Réponse d'une autre commande (jeton {received!r} au lieu de {nonce!r})")
        try:
            return json.loads(base64.b64decode(payload, validate=True).decode("utf-8"))
        except (binascii.Error, UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise SoftwareError(f"Réponse illisible : {exc}") from exc
    raise SoftwareError(f"Aucune réponse de winget : {output.strip()[:200] or '(sortie vide)'}")


def classify(package: Package, reply: dict) -> Outcome:
    code = reply.get("code")
    step = reply.get("step")
    tail = str(reply.get("output") or "")[:300]
    if code == 0:
        return Outcome(package, "installed" if step == "install" else "updated")
    if code in (UPDATE_NOT_APPLICABLE, PACKAGE_ALREADY_INSTALLED):
        return Outcome(package, "uptodate")
    if code in (REBOOT_TO_FINISH, REBOOT_FOR_INSTALL):
        return Outcome(package, "reboot", "redémarrage demandé")
    if code in (PACKAGE_IN_USE, PACKAGE_IN_USE_BY_APPLICATION):
        return Outcome(package, "failed", "logiciel ouvert sur le poste, fermez-le et relancez")
    if code == INSTALL_IN_PROGRESS:
        return Outcome(package, "failed", "une autre installation est en cours sur le poste")
    if code == NO_APPLICATIONS_FOUND:
        return Outcome(package, "failed", "identifiant introuvable dans winget")
    if code == -1:
        return Outcome(package, "failed", tail or "winget introuvable sur le poste")
    shown = f"0x{code & 0xFFFFFFFF:08X}" if isinstance(code, int) else str(code)
    return Outcome(package, "failed", f"code {shown}" + (f" : {tail}" if tail else ""))


def install(mesh, device_id: str, package: Package, nonce: str, script: str | None = None) -> Outcome:
    """Installe ou met à jour un logiciel sur le poste. Une panne devient un échec du logiciel."""
    from .meshctrl import MeshError

    try:
        output = mesh.run_powershell(device_id, build_command(package.id, nonce, script), timeout=PACKAGE_TIMEOUT)
        return classify(package, parse_output(output, nonce))
    except (MeshError, SoftwareError) as exc:
        return Outcome(package, "failed", str(exc)[:300])


LABELS = {"installed": "installé", "updated": "mis à jour", "uptodate": "à jour", "reboot": "redémarrage demandé", "failed": "en échec"}


def summary(outcomes: list[Outcome]) -> str:
    """Une phrase pour la page Postes : les nombres, puis le détail de ce qui demande un geste."""
    counts: dict[str, int] = {}
    for o in outcomes:
        counts[o.state] = counts.get(o.state, 0) + 1
    order = ["installed", "updated", "uptodate", "reboot", "failed"]
    plural = {"installed": "installés"}
    parts = [f"{counts[s]} {plural.get(s, LABELS[s]) if counts[s] > 1 else LABELS[s]}" for s in order if counts.get(s)]
    text = f"{len(outcomes)} logiciels : " + ", ".join(parts)
    reboot = [o.package.name for o in outcomes if o.state == "reboot"]
    failed = [f"{o.package.name} ({o.detail})" for o in outcomes if o.state == "failed"]
    if reboot:
        text += ". Redémarrage demandé : " + ", ".join(reboot)
    if failed:
        text += ". En échec : " + " ; ".join(failed)
    return text

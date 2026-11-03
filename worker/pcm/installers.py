"""Logiciels hors winget (vMix, ATEM, DaVinci...) : installeurs déposés sur le NAS.

Pour chaque installeur de `config/installeurs.json` (modèle :
`config/installeurs.example.json`), dont le fichier est dans le dossier
`installeurs/` du NAS :

1. `agent/installeur.ps1` en mode check : le logiciel est-il là, en quelle
   version, et reste-t-il assez de place sur le disque ;
2. s'il manque ou n'a pas la version voulue, `meshctrl upload` envoie le
   fichier au poste par MeshCentral (dans C:\\ProgramData\\PointeNoire\\installeurs) ;
3. le même script en mode install le lance en silencieux, rend son code de
   sortie et efface le fichier.

Le poste ne télécharge rien lui-même : seul le NAS a les installeurs, ce qui
évite les formulaires d'inscription des sites Blackmagic.
"""

from __future__ import annotations

import base64
import binascii
import json
import re
from dataclasses import dataclass
from pathlib import Path

from .software import Outcome, Package

MARKER = "PNIN1:"
AGENT_SCRIPT = Path(__file__).resolve().parents[2] / "agent" / "installeur.ps1"
REMOTE_DIR = "C:\\ProgramData\\PointeNoire\\installeurs"
FILE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 ._()+-]{0,150}\.(exe|msi)$", re.IGNORECASE)
MATCH_RE = re.compile(r"^[^\x00-\x1f]{1,120}$")
# L'installation elle-même : DaVinci Resolve pose plusieurs Go.
INSTALL_TIMEOUT = 2700
CHECK_TIMEOUT = 120
# Envoi par le relais MeshCentral du NAS : on compte au pire 500 ko/s.
UPLOAD_RATE = 500_000
# Place à garder libre : le fichier, puis ce qu'il décompresse.
SPACE_FACTOR = 3

REBOOT_CODES = (3010, 1641)
MSI_CODES = {
    1602: "installation annulée",
    1603: "erreur fatale de l'installeur",
    1618: "une autre installation est en cours sur le poste",
    1638: "une autre version est déjà installée, à désinstaller d'abord",
}


class InstallerError(ValueError):
    pass


@dataclass(frozen=True)
class Installer:
    name: str
    file: str
    match: str
    version: str | None
    args: str
    path: Path

    @property
    def package(self) -> Package:
        return Package(self.file, self.name)


def load_installers(path: str | Path, folder: str | Path) -> list[Installer]:
    """Rend la liste, vide si le fichier n'existe pas (les installeurs sont facultatifs)."""
    p, d = Path(path), Path(folder)
    if not p.exists():
        return []
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise InstallerError(f"Liste des installeurs illisible ({p}) : {exc}") from exc
    items = data.get("installeurs") if isinstance(data, dict) else data
    if not isinstance(items, list):
        raise InstallerError(f"Liste des installeurs illisible ({p}) : « installeurs » doit être une liste.")
    out = []
    for item in items:
        if not isinstance(item, dict):
            raise InstallerError(f"Installeur illisible : {item!r}")
        file = str(item.get("fichier") or "").strip()
        name = str(item.get("nom") or file).strip()
        match = str(item.get("detection") or "").strip()
        if not FILE_RE.match(file):
            raise InstallerError(f"{name} : nom de fichier refusé {file!r} (un .exe ou .msi, sans dossier)")
        if not MATCH_RE.match(match):
            raise InstallerError(f"{name} : « detection » manquant (motif du nom dans Programmes et fonctionnalités, ex. vMix*)")
        out.append(Installer(
            name=name,
            file=file,
            match=match,
            version=str(item.get("version") or "").strip() or None,
            args=str(item.get("arguments") or "").strip(),
            path=d / file,
        ))
    return out


def build_command(params: dict, nonce: str, script: str | None = None) -> str:
    if not re.fullmatch(r"[0-9a-f]+", nonce):
        raise InstallerError("Jeton invalide.")
    if script is None:
        script = AGENT_SCRIPT.read_text(encoding="utf-8")
    encoded = base64.b64encode(script.encode("utf-8")).decode("ascii")
    p = base64.b64encode(json.dumps(params, ensure_ascii=False).encode("utf-8")).decode("ascii")
    return (
        f"$env:PNIN_NONCE='{nonce}';$env:PNIN_PARAMS='{p}';"
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
            raise InstallerError(f"Réponse d'une autre commande (jeton {received!r} au lieu de {nonce!r})")
        try:
            return json.loads(base64.b64decode(payload, validate=True).decode("utf-8"))
        except (binascii.Error, UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise InstallerError(f"Réponse illisible : {exc}") from exc
    raise InstallerError(f"Aucune réponse du poste : {output.strip()[:200] or '(sortie vide)'}")


def same_version(installed: str | None, wanted: str) -> bool:
    if not installed:
        return False
    return installed == wanted or installed.startswith(wanted + ".")


def upload_timeout(size: int) -> int:
    return 600 + size // UPLOAD_RATE


def classify_install(found: bool, reply: dict) -> tuple[str, str]:
    code = reply.get("code")
    if code == 0:
        return ("updated" if found else "installed"), ""
    if code in REBOOT_CODES:
        return "reboot", "redémarrage demandé"
    if code in MSI_CODES:
        return "failed", MSI_CODES[code]
    tail = str(reply.get("output") or "")[:200]
    return "failed", f"code {code}" + (f" : {tail}" if tail else "")


def install(mesh, device_id: str, inst: Installer, new_nonce, script: str | None = None) -> Outcome:
    """Vérifie, envoie, installe. Une panne devient un échec de ce logiciel."""
    from .meshctrl import MeshError

    pkg = inst.package
    try:
        if not inst.path.is_file():
            return Outcome(pkg, "failed", f"fichier {inst.file} absent du dossier installeurs du NAS")
        size = inst.path.stat().st_size

        nonce = new_nonce()
        check = parse_output(mesh.run_powershell(
            device_id, build_command({"mode": "check", "match": inst.match}, nonce, script), timeout=CHECK_TIMEOUT), nonce)
        found = bool(check.get("found"))
        version = check.get("version")
        if found and (inst.version is None or same_version(version, inst.version)):
            return Outcome(pkg, "uptodate", f"version {version}" if version else "")
        free = check.get("free")
        if isinstance(free, int) and free < size * SPACE_FACTOR:
            return Outcome(pkg, "failed", f"place insuffisante sur le disque ({free // 10**9} Go libres)")

        mesh.upload(device_id, str(inst.path), REMOTE_DIR, timeout=upload_timeout(size))

        nonce = new_nonce()
        reply = parse_output(mesh.run_powershell(
            device_id,
            build_command({"mode": "install", "file": inst.file, "args": inst.args}, nonce, script),
            timeout=INSTALL_TIMEOUT,
        ), nonce)
        state, detail = classify_install(found, reply)
        return Outcome(pkg, state, detail)
    except (MeshError, InstallerError) as exc:
        return Outcome(pkg, "failed", str(exc)[:300])

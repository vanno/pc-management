"""Les consoles régie locales connues du relais (config/consoles.json).

Chaque console tire, à son premier lancement, un code d'appairage
`PNC1-<base64url JSON>` : { v, id, nom, empreinte, secret, port }. Il est
posé ici une fois :

    { "consoles": [ { "code": "PNC1-...", "adresse": "192.168.1.20" } ] }

`adresse` (facultative) sert de secours quand la découverte UDP ne passe pas.
À la pose de la sonde, chaque poste reçoit l'empreinte du certificat de la
console (épinglée) et SON jeton, calculé ici avec le secret : le secret ne
quitte jamais le NAS, et la console vérifie le jeton sans liste à tenir.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import ipaddress
import json
import os
import re
from pathlib import Path

PREFIX = "PNC1-"
ID_RE = re.compile(r"^[0-9a-f]{8}$")
FINGERPRINT_RE = re.compile(r"^[0-9a-f]{64}$")
NAME_MAX = 60
LIMIT = 4


class ConsoleError(ValueError):
    pass


def config_path() -> Path:
    return Path(os.environ.get("PCM_CONSOLES") or Path(__file__).resolve().parents[2] / "config" / "consoles.json")


def probe_token(secret: str, reference: str) -> str:
    """Même calcul que la console (console/regie/identite.py, jeton_poste)."""
    mac = hmac.new(secret.encode("ascii"), ("sonde:" + reference.strip().upper()).encode("utf-8"), hashlib.sha256).digest()
    return "pnr_" + base64.urlsafe_b64encode(mac).decode("ascii").rstrip("=")


def decode(code: str) -> dict:
    code = (code or "").strip()
    if not code.startswith(PREFIX):
        raise ConsoleError("code d'appairage attendu (PNC1-...)")
    raw = code[len(PREFIX):]
    try:
        data = json.loads(base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4)).decode("utf-8"))
    except (ValueError, UnicodeDecodeError) as exc:
        raise ConsoleError(f"code d'appairage illisible : {exc}") from exc
    if not isinstance(data, dict) or data.get("v") != 1:
        raise ConsoleError("version de code d'appairage inconnue")
    if not ID_RE.fullmatch(str(data.get("id") or "")):
        raise ConsoleError("identifiant de console illisible")
    if not FINGERPRINT_RE.fullmatch(str(data.get("empreinte") or "")):
        raise ConsoleError("empreinte de console illisible")
    secret = data.get("secret")
    if not isinstance(secret, str) or not re.fullmatch(r"[A-Za-z0-9_-]{32,100}", secret):
        raise ConsoleError("secret de console illisible")
    port = data.get("port")
    if not isinstance(port, int) or not 1 <= port <= 65535:
        raise ConsoleError("port de console illisible")
    name = str(data.get("nom") or "Console régie").strip()[:NAME_MAX]
    return {"id": data["id"], "nom": name, "empreinte": data["empreinte"], "secret": secret, "port": port}


def load(path: Path | None = None) -> list[dict]:
    """Les consoles connues, vides sans fichier. Un fichier illisible lève
    ConsoleError : la pose de la sonde le dit plutôt que de retirer la console."""
    path = path or config_path()
    if not path.exists():
        return []
    try:
        data = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError) as exc:
        raise ConsoleError(f"{path.name} illisible : {exc}") from exc
    entries = data.get("consoles") if isinstance(data, dict) else None
    if not isinstance(entries, list):
        raise ConsoleError(f"{path.name} : liste « consoles » attendue")
    out, seen = [], set()
    for entry in entries[:LIMIT]:
        if isinstance(entry, str):
            entry = {"code": entry}
        if not isinstance(entry, dict):
            raise ConsoleError(f"{path.name} : chaque console est un objet {{ code, adresse }}")
        console = decode(entry.get("code") or "")
        address = str(entry.get("adresse") or "").strip()
        if address:
            try:
                address = str(ipaddress.IPv4Address(address))
            except ValueError as exc:
                raise ConsoleError(f"adresse de la console {console['nom']} illisible : {address}") from exc
        console["adresse"] = address or None
        if console["id"] not in seen:
            seen.add(console["id"])
            out.append(console)
    return out


def for_probe(consoles: list[dict], reference: str) -> list[dict]:
    """Ce que reçoit un poste : sans le secret, avec son jeton."""
    return [
        {"id": c["id"], "nom": c["nom"], "empreinte": c["empreinte"], "port": c["port"], "adresse": c["adresse"], "jeton": probe_token(c["secret"], reference)}
        for c in consoles
    ]


def fingerprint_of_config(path: Path | None = None) -> bytes:
    path = path or config_path()
    try:
        return path.read_bytes()
    except OSError:
        return b""

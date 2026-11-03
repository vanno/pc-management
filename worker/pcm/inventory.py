"""Lecture, résumé et comparaison des inventaires remontés par agent/inventory.ps1."""

from __future__ import annotations

import base64
import binascii
import json
import re
import secrets
from dataclasses import dataclass, field
from pathlib import Path

MARKER = "PNINV1:"
SCHEMA = 1
AGENT_SCRIPT = Path(__file__).resolve().parents[2] / "agent" / "inventory.ps1"

# Windows refuse une ligne de commande de plus de 32 767 caractères. On garde
# une marge, l'agent ajoutant son propre enrobage autour de la commande.
MAX_COMMAND_LENGTH = 24_000


class InventoryError(ValueError):
    """La sortie d'un poste ne contient pas d'inventaire lisible."""


def new_nonce() -> str:
    return secrets.token_hex(8)


def build_command(script: str | None = None, nonce: str = "") -> str:
    """La commande PowerShell à passer à `meshctrl runcommand --powershell`.

    Le script voyage encodé en base64 pour échapper aux guillemets et aux
    retours à la ligne, puis il est décodé et exécuté sur le poste. Le jeton
    `nonce` revient dans la sortie : il prouve que la réponse vient bien de
    cette commande et pas d'une autre lancée au même moment.
    """
    if not re.fullmatch(r"[0-9a-f]*", nonce):
        raise InventoryError("Jeton invalide.")
    if script is None:
        script = AGENT_SCRIPT.read_text(encoding="utf-8")
    encoded = base64.b64encode(script.encode("utf-8")).decode("ascii")
    command = (
        f"$env:PNINV_NONCE='{nonce}';"
        "$s=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('"
        + encoded
        + "'));& ([ScriptBlock]::Create($s))"
    )
    if len(command) > MAX_COMMAND_LENGTH:
        raise InventoryError(
            f"Commande d'inventaire trop longue ({len(command)} caractères, maximum {MAX_COMMAND_LENGTH})."
        )
    return command


def parse_output(output: str, nonce: str = "") -> dict:
    """Extrait l'inventaire de la sortie brute renvoyée par l'agent.

    Une sortie qui porte un autre jeton que celui envoyé est refusée : c'est la
    réponse d'un autre poste.
    """
    for line in reversed(output.splitlines()):
        line = line.strip()
        if not line.startswith(MARKER):
            continue
        received, _, payload = line[len(MARKER):].partition(":")
        if received != nonce:
            raise InventoryError(f"Réponse d'une autre commande (jeton {received!r} au lieu de {nonce!r})")
        try:
            data = json.loads(base64.b64decode(payload, validate=True).decode("utf-8"))
        except (binascii.Error, UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise InventoryError(f"Charge utile illisible : {exc}") from exc
        if data.get("schema") != SCHEMA:
            raise InventoryError(f"Version de schéma inattendue : {data.get('schema')!r}")
        return _normalise(data)
    excerpt = output.strip()[:300] or "(sortie vide)"
    raise InventoryError(f"Aucun inventaire dans la sortie : {excerpt}")


def _as_list(value) -> list:
    """ConvertTo-Json rend un objet seul au lieu d'une liste d'un élément."""
    if value is None:
        return []
    return value if isinstance(value, list) else [value]


def _normalise(data: dict) -> dict:
    for key in ("cpus", "memory", "gpus", "disks", "volumes", "network", "software"):
        data[key] = _as_list(data.get(key))
    for nic in data["network"]:
        nic["ipv4"] = _as_list(nic.get("ipv4"))
        nic["gateway"] = _as_list(nic.get("gateway"))
    return data


def asset_tag_for(device_name: str, mapping: dict[str, str] | None = None) -> str:
    """La référence de parc AVDiagram d'un poste.

    Le nom MeshCentral (ou Windows) doit être la référence de parc. Une table
    de correspondance couvre les exceptions le temps de renommer les postes.
    """
    mapping = {k.upper(): v for k, v in (mapping or {}).items()}
    name = device_name.strip()
    return mapping.get(name.upper(), name.upper())


def primary_ipv4(data: dict) -> str | None:
    """L'adresse IPv4 de la carte connectée qui porte la route par défaut."""
    candidates = [n for n in data["network"] if n.get("connected") and n["ipv4"]]
    candidates.sort(key=lambda n: (not n["gateway"], n.get("speed_bps") is None))
    for nic in candidates:
        for ip in nic["ipv4"]:
            if not ip.startswith("169.254."):
                return ip
    return None


def windows_label(data: dict) -> str | None:
    """Ex. « Windows 11 Pro 23H2 (22631.4460) », rangé dans le champ firmware."""
    w = data.get("windows") or {}
    caption = re.sub(r"^Microsoft\s+", "", w.get("caption") or "").strip()
    if not caption:
        return None
    parts = [caption]
    if w.get("display_version"):
        parts.append(str(w["display_version"]))
    build = str(w.get("build") or "")
    if build:
        parts.append(f"({build}.{w['ubr']})" if w.get("ubr") is not None else f"({build})")
    return " ".join(parts)


def is_home_edition(data: dict) -> bool:
    edition = ((data.get("windows") or {}).get("edition_id") or "").lower()
    return edition.startswith("core")


def summary(data: dict) -> dict:
    """Les champs poussés sur la fiche AVDiagram, et ceux affichés au rapport."""
    s = data.get("system") or {}
    ram = s.get("ram_bytes") or 0
    return {
        "hostname": s.get("hostname"),
        "serial_number": (s.get("serial") or "").strip() or None,
        "ip_address": primary_ipv4(data),
        "firmware": windows_label(data),
        "model": " ".join(p for p in (s.get("manufacturer"), s.get("model")) if p) or None,
        "ram_gb": round(ram / 1024**3) if ram else None,
        "cpu": data["cpus"][0]["name"] if data["cpus"] else None,
        "gpus": [g.get("name") for g in data["gpus"] if g.get("name")],
        "home_edition": is_home_edition(data),
        "software_count": len(data["software"]),
    }


@dataclass
class Diff:
    added: list[str] = field(default_factory=list)
    removed: list[str] = field(default_factory=list)
    updated: list[str] = field(default_factory=list)
    hardware: list[str] = field(default_factory=list)

    @property
    def empty(self) -> bool:
        return not (self.added or self.removed or self.updated or self.hardware)


def diff(previous: dict | None, current: dict) -> Diff:
    """Ce qui a changé depuis le dernier inventaire du même poste."""
    result = Diff()
    if previous is None:
        return result

    def by_name(d: dict) -> dict[str, str]:
        return {sw["name"]: str(sw.get("version") or "") for sw in d["software"]}

    old, new = by_name(previous), by_name(current)
    result.added = sorted(f"{n} {new[n]}".strip() for n in new.keys() - old.keys())
    result.removed = sorted(f"{n} {old[n]}".strip() for n in old.keys() - new.keys())
    result.updated = sorted(
        f"{n} {old[n]} -> {new[n]}" for n in old.keys() & new.keys() if old[n] != new[n]
    )

    before, after = summary(previous), summary(current)
    for key in ("serial_number", "model", "ram_gb", "cpu", "gpus", "firmware"):
        if before[key] != after[key]:
            result.hardware.append(f"{key}: {before[key]} -> {after[key]}")
    return result

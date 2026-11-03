"""Écriture des fiches du parc AVDiagram.

Lecture par l'API REST (`GET /api/v1/parc`), écriture par l'outil MCP
`update_unit` (`POST /api/mcp`), qui passe par les actions de l'application :
mêmes contrôles, mêmes droits, même journal qu'une modification à l'écran.
Le jeton (`avd_…`) se crée dans AVDiagram, Profil, Jetons d'API. Il porte le
rôle de son propriétaire, qui doit avoir le droit parc:ecrire.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.request
from dataclasses import dataclass


class AvdError(RuntimeError):
    pass


@dataclass(frozen=True)
class Unit:
    asset_tag: str
    serial_number: str | None
    ip_address: str | None
    firmware: str | None


class AvdClient:
    def __init__(self, base_url: str, token: str, timeout: int = 30):
        if not token.startswith("avd_"):
            raise AvdError("Le jeton AVDiagram doit commencer par avd_.")
        self.base_url = base_url.rstrip("/")
        self.token = token
        self.timeout = timeout

    def _request(self, method: str, path: str, body: dict | None = None) -> dict:
        headers = {"Authorization": f"Bearer {self.token}", "Accept": "application/json, text/event-stream"}
        data = None
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(self.base_url + path, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", "replace")[:300]
            raise AvdError(f"AVDiagram {method} {path} : HTTP {exc.code} : {detail}") from exc
        except urllib.error.URLError as exc:
            raise AvdError(f"AVDiagram injoignable : {exc.reason}") from exc

    def computers(self) -> dict[str, Unit]:
        """Les exemplaires de la catégorie computer, par référence de parc."""
        data = self._request("GET", "/api/v1/parc?categorie=computer")
        return {
            u["assetTag"].upper(): Unit(u["assetTag"], u.get("serialNumber"), u.get("ipAddress"), u.get("firmware"))
            for u in data.get("exemplaires", [])
        }

    def _tool(self, name: str, asset_tag: str, arguments: dict) -> str:
        reply = self._request(
            "POST",
            "/api/mcp",
            {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": name, "arguments": arguments}},
        )
        if "error" in reply:
            raise AvdError(f"{name} {asset_tag} : {reply['error'].get('message')}")
        result = reply.get("result") or {}
        text = " ".join(c.get("text", "") for c in result.get("content", []) if c.get("type") == "text").strip()
        if result.get("isError"):
            raise AvdError(f"{name} {asset_tag} : {text}")
        return text

    def update_unit(self, asset_tag: str, **fields: str | None) -> str:
        """Appelle l'outil MCP update_unit. Seuls les champs donnés changent."""
        return self._tool("update_unit", asset_tag, {"unit": asset_tag, **{k: v for k, v in fields.items() if v is not None}})

    def set_inventory(self, asset_tag: str, payload: dict) -> str:
        """Appelle l'outil MCP set_unit_inventory : remplace l'inventaire détaillé de la fiche."""
        return self._tool("set_unit_inventory", asset_tag, {"unit": asset_tag, **payload})


def plan_update(unit: Unit, summary: dict, push_ip: bool = False) -> tuple[dict, list[str]]:
    """Les champs à écrire sur la fiche, et les alertes à remonter.

    Un numéro de série déjà saisi et différent n'est jamais écrasé : c'est le
    signe qu'un poste porte le nom d'un autre, à corriger à la main.
    """
    changes: dict[str, str] = {}
    warnings: list[str] = []

    serial = summary.get("serial_number")
    if serial:
        if not unit.serial_number:
            changes["serial_number"] = serial
        elif unit.serial_number.strip().upper() != serial.upper():
            warnings.append(
                f"{unit.asset_tag} : n° de série AVDiagram {unit.serial_number} différent du poste ({serial}), non modifié"
            )

    firmware = summary.get("firmware")
    if firmware and firmware != unit.firmware:
        changes["firmware"] = firmware

    ip = summary.get("ip_address")
    if push_ip and ip and ip != unit.ip_address:
        changes["ip_address"] = ip

    return changes, warnings

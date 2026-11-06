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
    def __init__(self, message: str, status: int | None = None):
        super().__init__(message)
        self.status = status


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
            raise AvdError(f"AVDiagram {method} {path} : HTTP {exc.code} : {detail}", exc.code) from exc
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


    def heartbeat(self, source: str, devices: list[dict] | None, limit: int, tool: dict | None = None) -> list[dict]:
        """Battement de la page Postes : dit ce que MeshCentral voit, rend les
        tâches en attente (passées « en cours » côté AVDiagram). `tool` (lot 5) :
        la version du serveur MeshCentral et les heures de planification."""
        body: dict = {"source": source, "limit": limit}
        if devices is not None:
            body["devices"] = devices
        if tool:
            body["tool"] = tool
        reply = self._request("POST", "/api/v1/postes/battement", body)
        # La dernière demande de mise à jour de l'outil faite depuis la page
        # Postes (0078), à relayer au NAS. Absente d'un AVDiagram plus ancien.
        self.update_requested_at = reply.get("update_requested_at") or None
        return reply.get("tasks") or []

    def software(self) -> list[dict] | None:
        """Le catalogue de l'onglet Postes, Logiciels (0072). None si cet
        AVDiagram ne l'a pas encore (route absente ou migration manquante)."""
        try:
            return self._request("GET", "/api/v1/postes/logiciels").get("software") or []
        except AvdError as exc:
            if exc.status in (404, 503):
                return None
            raise

    def create_probe(self, unit_id: str) -> dict:
        """Pose la sonde de supervision d'un poste (0074) : { token, url }. Le
        jeton n'est rendu qu'une fois ; il part directement au poste."""
        return self._request("POST", "/api/v1/postes/sondes", {"unit_id": unit_id})

    def remove_probe(self, unit_id: str) -> bool:
        return bool(self._request("DELETE", "/api/v1/postes/sondes", {"unit_id": unit_id}).get("removed"))

    def create_thumbnail(self, unit_id: str) -> dict:
        """Met un poste au mur d'écrans (0084) : { token, url }. Le jeton n'est
        rendu qu'une fois ; il part directement au poste."""
        return self._request("POST", "/api/v1/postes/vignettes/jetons", {"unit_id": unit_id})

    def remove_thumbnail(self, unit_id: str) -> bool:
        return bool(self._request("DELETE", "/api/v1/postes/vignettes/jetons", {"unit_id": unit_id}).get("removed"))

    def post_diagnostic(self, task_id: str, unit_id: str, data: dict) -> None:
        """Le diagnostic réseau complet d'un poste (0080), gardé avec la tâche."""
        self._request("POST", "/api/v1/postes/diagnostics", {"task_id": task_id, "unit_id": unit_id, "data": data})

    def request_tasks(self, action: str, asset_tags: list[str], params: dict | None = None) -> dict:
        """Demande une tâche par poste, comme la page Postes (lot 5, tâches
        planifiées) : { requested, busy, unknown }."""
        return self._request("POST", "/api/v1/postes/taches", {"action": action, "asset_tags": asset_tags, "params": params or {}})

    def request_reposes(self, action: str, asset_tags: list[str]) -> dict:
        """Après une mise à jour du relais : l'écran (`fond`), le mur
        (`vignette`) ou la sonde (`supervision`) reposé là où il est posé, et
        seulement là. Un poste éteint le reçoit à son allumage.
        { requested, busy, unknown }."""
        body = {"action": action, "asset_tags": asset_tags, "params": {"actif": True}, "seulement_actifs": True, "attendre": True}
        return self._request("POST", "/api/v1/postes/taches", body)

    def get_envoi(self, envoi_id: str) -> dict:
        """Un script approuvé ou un fichier de la bibliothèque d'envois (0075).
        Le fichier porte une adresse de téléchargement signée."""
        return self._request("GET", f"/api/v1/postes/envois/{envoi_id}")

    def finish_task(self, task_id: str, ok: bool, result: str, controle: dict | None = None) -> bool:
        """Rend le résultat d'une tâche, et ce que le contrôle a relu dans
        Windows (pilot.verdict). False si AVDiagram ne l'attend plus (annulée,
        ou expirée après 30 minutes)."""
        body: dict = {"status": "done" if ok else "failed", "result": result[:4000]}
        if controle is not None:
            body["controle"] = controle
        try:
            self._request("POST", f"/api/v1/postes/taches/{task_id}", body)
            return True
        except AvdError as exc:
            if exc.status == 409:
                return False
            raise


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

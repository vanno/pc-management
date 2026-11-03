"""Pilotage des postes depuis la page Postes d'AVDiagram (lot 2).

    alimentation    redémarrer ou éteindre (shutdown.exe, 30 s de préavis à
                    l'écran), réveiller (Wake-on-LAN par MeshCentral)
    reseau          adresse fixe ou DHCP sur une carte, avec retour
                    automatique si le poste ne joint plus MeshCentral
    mode_evenement  Windows Update en pause, veille et notifications coupées ;
                    redémarrer, éteindre et installer refusés

Tout passe par `agent/pilote.ps1`, envoyé au poste comme l'inventaire
(`meshctrl runcommand --powershell --reply`, compte SYSTEM), sauf le réveil :
un poste éteint n'a plus d'agent, c'est le serveur MeshCentral qui fait
envoyer le paquet magique par un autre agent du même réseau.

Les paramètres viennent d'AVDiagram, qui les a validés ; ils sont revalidés
ici avant tout envoi.
"""

from __future__ import annotations

import base64
import binascii
import gzip
import ipaddress
import json
import re
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable
from urllib.parse import urlparse

from .meshctrl import MeshCtrl, MeshError

MARKER = "PNPL1:"
AGENT_SCRIPT = Path(__file__).resolve().parents[2] / "agent" / "pilote.ps1"
INTERFACE_RE = re.compile(r"^[^\W_][\w ._()&+'-]{0,79}$")
POWER_MODES = ("redemarrer", "eteindre", "reveiller")
# Le délai pendant lequel le poste doit joindre MeshCentral avant de revenir en arrière.
NETWORK_DELAY = 90
# Après le changement : le temps de revenir à l'ancienne configuration, puis
# celui que l'agent se reconnecte au serveur.
NETWORK_FIRST_READ = NETWORK_DELAY + 20
NETWORK_READS = 10
NETWORK_READ_GAP = 20
CALL_TIMEOUT = 120
READ_TIMEOUT = 45
EVENT_DAYS = 7


class PilotError(ValueError):
    pass


@dataclass(frozen=True)
class Network:
    interface: str
    dhcp: bool
    ip: str | None = None
    prefix: int | None = None
    gateway: str | None = None
    dns: tuple[str, ...] = ()
    rollback: bool = True

    def label(self) -> str:
        if self.dhcp:
            return f"DHCP sur {self.interface}"
        return f"{self.ip}/{self.prefix} sur {self.interface}"


def parse_network(params: dict) -> Network:
    """Les paramètres de l'action `reseau`, revalidés."""
    name = str(params.get("interface") or "").strip()
    if not INTERFACE_RE.match(name):
        raise PilotError(f"Nom de carte réseau illisible : {name!r}")
    rollback = params.get("retour") is not False
    if params.get("dhcp") is True:
        return Network(name, True, rollback=rollback)
    try:
        ip = ipaddress.IPv4Address(str(params.get("ip") or ""))
        prefix = int(params.get("prefixe"))
        if not 8 <= prefix <= 30:
            raise ValueError("préfixe entre 8 et 30")
        net = ipaddress.IPv4Network(f"{ip}/{prefix}", strict=False)
        if ip in (net.network_address, net.broadcast_address):
            raise ValueError("adresse du réseau ou de diffusion")
        gateway = params.get("passerelle")
        gw = ipaddress.IPv4Address(str(gateway)) if gateway else None
        if gw is not None and (gw not in net or gw == ip):
            raise ValueError("passerelle hors du réseau de l'adresse")
        dns = tuple(str(ipaddress.IPv4Address(str(d))) for d in (params.get("dns") or [])[:2])
    except (ValueError, TypeError) as exc:
        raise PilotError(f"Adresse refusée : {exc}") from exc
    return Network(name, False, str(ip), prefix, str(gw) if gw else None, dns, rollback)


def mesh_target(url: str | None) -> tuple[str, int]:
    """L'hôte et le port que le poste doit joindre après un changement de réseau."""
    u = urlparse(url or "")
    if not u.hostname:
        raise PilotError("MESHCTRL_URL manquante : impossible de vérifier le réseau après le changement.")
    return u.hostname, u.port or (80 if u.scheme in ("ws", "http") else 443)


def device_link(url: str | None, device_id: str) -> str | None:
    """La page du poste dans MeshCentral : `https://hôte/?gotonode=<id>&viewmode=10`."""
    u = urlparse(url or "")
    parts = device_id.split("/")
    if not u.hostname or len(parts) != 3 or parts[0] != "node" or not re.fullmatch(r"[A-Za-z0-9@$_-]+", parts[2]):
        return None
    domain = f"/{parts[1]}" if parts[1] else ""
    port = f":{u.port}" if u.port and u.port != 443 else ""
    return f"https://{u.hostname}{port}{domain}/?gotonode={parts[2]}&viewmode=10"


def build_command(params: dict, nonce: str, script: str | None = None) -> str:
    """Le script voyage compressé (gzip puis base64) : il dépasse sinon la
    longueur de ligne de commande que l'agent accepte."""
    if not re.fullmatch(r"[0-9a-f]+", nonce):
        raise PilotError("Jeton invalide.")
    if script is None:
        script = AGENT_SCRIPT.read_text(encoding="utf-8")
    packed = base64.b64encode(gzip.compress(script.encode("utf-8"), mtime=0)).decode("ascii")
    p = base64.b64encode(json.dumps(params, ensure_ascii=False).encode("utf-8")).decode("ascii")
    return (
        f"$env:PNPL_NONCE='{nonce}';$env:PNPL_PARAMS='{p}';"
        f"$m=New-Object IO.MemoryStream(,[Convert]::FromBase64String('{packed}'));"
        "$g=New-Object IO.Compression.GZipStream($m,[IO.Compression.CompressionMode]::Decompress);"
        "$s=(New-Object IO.StreamReader($g,[Text.Encoding]::UTF8)).ReadToEnd();"
        "& ([ScriptBlock]::Create($s))"
    )


def parse_output(output: str, nonce: str) -> dict:
    for line in reversed(output.splitlines()):
        line = line.strip()
        if not line.startswith(MARKER):
            continue
        received, _, payload = line[len(MARKER):].partition(":")
        if received != nonce:
            raise PilotError(f"Réponse d'une autre commande (jeton {received!r} au lieu de {nonce!r})")
        try:
            return json.loads(base64.b64decode(payload, validate=True).decode("utf-8"))
        except (binascii.Error, UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise PilotError(f"Réponse illisible : {exc}") from exc
    raise PilotError(f"Aucune réponse du poste : {output.strip()[:200] or '(sortie vide)'}")


def call(mesh: MeshCtrl, device_id: str, params: dict, new_nonce: Callable[[], str], timeout: int = CALL_TIMEOUT, script: str | None = None) -> dict:
    nonce = new_nonce()
    return parse_output(mesh.run_powershell(device_id, build_command(params, nonce, script), timeout=timeout), nonce)


def state(mesh: MeshCtrl, device_id: str, new_nonce: Callable[[], str], script: str | None = None) -> dict:
    """{ evenement, depuis, cartes } : lu sur le poste."""
    return call(mesh, device_id, {"op": "etat"}, new_nonce, script=script)


def power(mesh: MeshCtrl, device_id: str, params: dict, new_nonce: Callable[[], str], script: str | None = None) -> tuple[bool, str]:
    mode = params.get("mode")
    if mode not in POWER_MODES:
        return False, f"Mode d'alimentation inconnu : {mode!r}"
    if mode == "reveiller":
        try:
            reply = mesh.wake(device_id)
        except MeshError as exc:
            return False, str(exc)
        return True, f"Wake-on-LAN envoyé ({reply}). Le poste apparaît en ligne dans une à deux minutes s'il l'accepte."
    try:
        reply = call(mesh, device_id, {"op": "alimentation", "mode": mode, "force": params.get("force") is True}, new_nonce, script=script)
    except (MeshError, PilotError) as exc:
        return False, str(exc)
    detail = reply.get("detail") or ""
    return bool(reply.get("ok")), detail[:1].upper() + detail[1:]


def event_mode(mesh: MeshCtrl, device_id: str, params: dict, new_nonce: Callable[[], str], script: str | None = None) -> tuple[bool, str]:
    if not isinstance(params.get("actif"), bool):
        return False, "Paramètre `actif` manquant."
    try:
        reply = call(mesh, device_id, {"op": "evenement", "actif": params["actif"], "jours": EVENT_DAYS}, new_nonce, script=script)
    except (MeshError, PilotError) as exc:
        return False, str(exc)
    detail = reply.get("detail") or ""
    return bool(reply.get("ok")), detail[:1].upper() + detail[1:]


def network(
    mesh: MeshCtrl,
    device_id: str,
    params: dict,
    mesh_url: str | None,
    new_nonce: Callable[[], str],
    sleep: Callable[[float], None] = time.sleep,
    script: str | None = None,
) -> tuple[bool, str]:
    """Lance le changement sur le poste, attend, puis lit son résultat une fois
    l'agent revenu (sur la nouvelle adresse, ou l'ancienne après un retour)."""
    try:
        net = parse_network(params)
        host, port = mesh_target(mesh_url)
    except PilotError as exc:
        return False, str(exc)
    request = {
        "op": "reseau",
        "interface": net.interface,
        "dhcp": net.dhcp,
        "ip": net.ip,
        "prefixe": net.prefix,
        "passerelle": net.gateway,
        "dns": list(net.dns),
        "retour": net.rollback,
        "hote": host,
        "port": port,
        "delai": NETWORK_DELAY,
    }
    try:
        reply = call(mesh, device_id, request, new_nonce, script=script)
    except (MeshError, PilotError) as exc:
        return False, f"Changement non lancé : {exc}"
    if not reply.get("ok"):
        return False, f"Changement refusé : {reply.get('detail')}"
    before = _describe(reply.get("avant"))
    sleep(NETWORK_FIRST_READ if net.rollback else 30)
    last = ""
    for _ in range(NETWORK_READS):
        try:
            r = call(mesh, device_id, {"op": "reseau_resultat"}, new_nonce, timeout=READ_TIMEOUT, script=script)
        except (MeshError, PilotError) as exc:
            last = str(exc)
            sleep(NETWORK_READ_GAP)
            continue
        etat = r.get("etat")
        now = _describe(r.get("carte"))
        if etat == "applique":
            return True, f"Réseau {net.label()} appliqué : {r.get('detail')}. Avant : {before}. Maintenant : {now}"
        if etat == "retour":
            return False, f"Réseau {net.label()} non gardé : {r.get('detail')}. Le poste est revenu à : {now}"
        if etat == "echec":
            return False, f"Réseau {net.label()} : {r.get('detail')}"
        last = f"changement toujours {etat}"
        sleep(NETWORK_READ_GAP)
    if not net.rollback:
        return False, (
            f"Réseau {net.label()} demandé sans retour automatique : le poste ne répond plus à MeshCentral "
            f"({last}). C'est attendu sur un réseau fermé. Avant : {before}"
        )
    return False, f"Le poste ne répond plus depuis le changement {net.label()} ({last}). Avant : {before}"


def _describe(card: dict | None) -> str:
    if not isinstance(card, dict):
        return "?"
    if card.get("dhcp"):
        addr = ", ".join(a.get("ip", "?") for a in card.get("adresses") or [])
        return f"DHCP ({addr or 'sans adresse'})"
    addr = ", ".join(f"{a.get('ip')}/{a.get('prefixe')}" for a in card.get("adresses") or []) or "sans adresse"
    gw = card.get("passerelle")
    return addr + (f", passerelle {gw}" if gw else ", sans passerelle")

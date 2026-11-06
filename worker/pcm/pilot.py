"""Pilotage des postes depuis la page Postes d'AVDiagram (lot 2).

    alimentation    redémarrer ou éteindre (shutdown.exe, 30 s de préavis à
                    l'écran), réveiller (Wake-on-LAN par MeshCentral)
    reseau          adresse fixe ou DHCP sur une carte, avec retour
                    automatique si le poste ne joint plus MeshCentral
    mode_evenement  Windows Update en pause, veille et notifications coupées ;
                    redémarrer, éteindre et installer refusés
    supervision     pose ou retire la sonde (lot 3)
    envoi           lance un script approuvé dans AVDiagram ou pose un
                    fichier de la bibliothèque sur le poste (lot 4)
    fond            pose ou retire le fond d'état et l'icône « État du poste »
                    (agent/fond.ps1, posé par agent/fond-pose.ps1)
    nettoyage       applique ou annule le profil de nettoyage réversible :
                    plan d'alimentation, services et tâches inutiles,
                    réglages de télémétrie et de jeu ; applications Windows
                    inutiles en option (lot 6)

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
import hashlib
import ipaddress
import json
import re
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable
from urllib.parse import urlparse

from . import regie
from .meshctrl import MeshCtrl, MeshError

MARKER = "PNPL1:"
AGENT_SCRIPT = Path(__file__).resolve().parents[2] / "agent" / "pilote.ps1"
PROBE_SCRIPT = Path(__file__).resolve().parents[2] / "agent" / "supervision.ps1"
DIAGNOSTIC_SCRIPT = Path(__file__).resolve().parents[2] / "agent" / "diagnostic.ps1"
# La stratégie de groupe locale de l'allègement, envoyée devant pilote.ps1.
POLICY_SCRIPT = Path(__file__).resolve().parents[2] / "agent" / "politique.ps1"
WALLPAPER_SCRIPT = Path(__file__).resolve().parents[2] / "agent" / "fond.ps1"
WALLPAPER_INSTALLER = Path(__file__).resolve().parents[2] / "agent" / "fond-pose.ps1"
SURVEY_SCRIPT = Path(__file__).resolve().parents[2] / "agent" / "releve.ps1"
SURVEY_INSTALLER = Path(__file__).resolve().parents[2] / "agent" / "releve-pose.ps1"
THUMBNAIL_SCRIPT = Path(__file__).resolve().parents[2] / "agent" / "vignette.ps1"
THUMBNAIL_INSTALLER = Path(__file__).resolve().parents[2] / "agent" / "vignette-pose.ps1"
CHECK_SCRIPT = Path(__file__).resolve().parents[2] / "agent" / "controle.ps1"
# L'envoi à la console régie locale, posé dans le dossier de la sonde.
CONSOLE_SCRIPT = Path(__file__).resolve().parents[2] / "agent" / "console.ps1"
CONSOLE_INSTALLER = Path(__file__).resolve().parents[2] / "agent" / "console-pose.ps1"
VMIX_SCRIPT = Path(__file__).resolve().parents[2] / "agent" / "vmix.ps1"
# Ce qui reste sur un poste après la commande qui l'a posé : l'écran (fond et
# relevé du mode événement) et le mur. Après une mise à jour du relais, ces
# scripts gardent leur ancienne version jusqu'à leur prochaine pose.
# Les scripts posés sur les postes, par action : une mise à jour du relais
# qui en change un les fait reposer là où ils sont posés (service._repose).
POSED = {
    "fond": (WALLPAPER_SCRIPT, WALLPAPER_INSTALLER, SURVEY_SCRIPT, SURVEY_INSTALLER),
    "vignette": (THUMBNAIL_SCRIPT, THUMBNAIL_INSTALLER),
    "supervision": (PROBE_SCRIPT, CONSOLE_SCRIPT, CONSOLE_INSTALLER, VMIX_SCRIPT),
}
MESSAGE_KINDS = ("toast", "boite")
MESSAGE_MAX = 500
TITLE_MAX = 60
CONTROL_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")
REFERENCE_RE = re.compile(r"^[\w .-]{1,60}$")
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
# La ligne de commande que l'agent MeshCentral accepte, avec de la marge.
MAX_COMMAND = 23_000
SCRIPT_DELAY = 300
UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.I)
# Un téléchargement de 5 Go en 1 Mo/s laisse 10 minutes de base.
DOWNLOAD_RATE = 1_000_000


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
    """Le bureau à distance du poste dans MeshCentral (onglet Bureau) : `https://hôte/?gotonode=<id>&viewmode=11`."""
    u = urlparse(url or "")
    parts = device_id.split("/")
    if not u.hostname or len(parts) != 3 or parts[0] != "node" or not re.fullmatch(r"[A-Za-z0-9@$_-]+", parts[2]):
        return None
    domain = f"/{parts[1]}" if parts[1] else ""
    port = f":{u.port}" if u.port and u.port != 443 else ""
    return f"https://{u.hostname}{port}{domain}/?gotonode={parts[2]}&viewmode=11"


def build_command(params: dict, nonce: str, script: str | None = None) -> str:
    """Le script voyage compressé (gzip puis base64) : il dépasse sinon la
    longueur de ligne de commande que l'agent accepte."""
    if not re.fullmatch(r"[0-9a-f]+", nonce):
        raise PilotError("Jeton invalide.")
    if script is None:
        script = AGENT_SCRIPT.read_text(encoding="utf-8")
    packed = base64.b64encode(gzip.compress(slim(script).encode("utf-8"), mtime=0)).decode("ascii")
    p = base64.b64encode(json.dumps(params, ensure_ascii=False).encode("utf-8")).decode("ascii")
    return (
        f"$env:PNPL_NONCE='{nonce}';$env:PNPL_PARAMS='{p}';"
        f"$m=New-Object IO.MemoryStream(,[Convert]::FromBase64String('{packed}'));"
        "$g=New-Object IO.Compression.GZipStream($m,[IO.Compression.CompressionMode]::Decompress);"
        "$s=(New-Object IO.StreamReader($g,[Text.Encoding]::UTF8)).ReadToEnd();"
        "& ([ScriptBlock]::Create($s))"
    )


_HERE_OPEN = re.compile(r"@(['\"])\s*$")


def slim(script: str) -> str:
    """Le script tel qu'il voyage : ses lignes de commentaire vidées, pas
    retirées, pour que les numéros de ligne des erreurs restent ceux du
    fichier. Une chaîne @' '@ ou @" "@ (fond.ps1 dans $FondSource, le script
    réseau) voyage telle quelle, jusqu'à sa fermeture du même guillemet."""
    out, close, block = [], None, False
    for line in script.split("\n"):
        stripped = line.strip()
        if close:
            if line.startswith(close):
                close = None
            out.append(line)
        elif block:
            block = "#>" not in line
            out.append("")
        elif stripped.startswith("<#"):
            block = "#>" not in stripped[2:]
            out.append("")
        elif stripped.startswith("#"):
            out.append("")
        else:
            m = _HERE_OPEN.search(line)
            close = (m.group(1) + "@") if m else None
            out.append(line)
    return "\n".join(out)


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


# Les parties du mode événement, dans l'ordre où le poste les applique.
EVENT_PARTS = ("windows_update", "veille", "notifications", "conseils", "fond")


def event_mode(
    mesh: MeshCtrl,
    device_id: str,
    params: dict,
    new_nonce: Callable[[], str],
    script: str | None = None,
    reference: str = "",
    wallpaper_script: str | None = None,
) -> tuple[bool, str]:
    """Le mode événement. Sa partie « fond » affiche « MODE ÉVÉNEMENT » sur
    l'écran principal : sans fond d'état sur le poste (`fond_a_poser`), le
    relais le pose aussitôt, et le poste le retire à la fin du mode."""
    if not isinstance(params.get("actif"), bool):
        return False, "Paramètre `actif` manquant."
    body = {"op": "evenement", "actif": params["actif"], "jours": EVENT_DAYS}
    parties = params.get("parties")
    if parties is not None:
        if not isinstance(parties, list) or not parties or any(p not in EVENT_PARTS for p in parties):
            return False, "Paramètre `parties` invalide."
        body["parties"] = list(dict.fromkeys(parties))
    try:
        reply = call(mesh, device_id, body, new_nonce, script=script)
    except (MeshError, PilotError) as exc:
        return False, str(exc)
    detail = reply.get("detail") or ""
    ok, text = bool(reply.get("ok")), detail[:1].upper() + detail[1:]
    if ok and reply.get("fond_a_poser"):
        posed = wallpaper(mesh, device_id, reference, {"actif": True}, new_nonce, script=wallpaper_script)
        text = f"{text.rstrip('.')}. État de l'écran posé pour l'événement : {posed[1][:1].lower() + posed[1][1:]}" if posed[0] else f"{text.rstrip('.')}. État de l'écran pas posé : {posed[1]}"
    return ok, text


CLEANUP_TIMEOUT = 600


def with_policy(script: str | None = None) -> str:
    """pilote.ps1 précédé de politique.ps1 : les widgets coupés par la
    stratégie de groupe locale quand UCPD refuse leur réglage."""
    if script is None:
        script = AGENT_SCRIPT.read_text(encoding="utf-8")
    return POLICY_SCRIPT.read_text(encoding="utf-8") + "\n" + script


def cleanup(mesh: MeshCtrl, device_id: str, params: dict, new_nonce: Callable[[], str], script: str | None = None) -> tuple[bool, str] | tuple[bool, str, bool]:
    """Le profil de nettoyage. L'état d'avant reste sur le poste, qui sait l'annuler.
    Un troisième élément vrai : en échec, mais l'allègement est posé (Windows
    refuse seulement la liste des applications), donc à relire quand même."""
    if not isinstance(params.get("actif"), bool):
        return False, "Paramètre `actif` manquant."
    body = {"op": "nettoyage", "actif": params["actif"], "applications": params.get("applications") is True}
    try:
        # Retirer des applications pour tous les comptes prend plusieurs minutes.
        reply = call(mesh, device_id, body, new_nonce, timeout=CLEANUP_TIMEOUT, script=with_policy(script))
    except (MeshError, PilotError) as exc:
        return False, str(exc)
    detail = reply.get("detail") or ""
    if reply.get("partiel") is True and not reply.get("ok"):
        return False, detail[:1].upper() + detail[1:], True
    return bool(reply.get("ok")), detail[:1].upper() + detail[1:]


DIAGNOSTIC_TIMEOUT = 180


def diagnostic(mesh: MeshCtrl, device_id: str, params: dict, new_nonce: Callable[[], str], script: str | None = None) -> tuple[bool, str, dict | None]:
    """Le diagnostic réseau du poste : cartes, Wi-Fi, pare-feu, DNS, ports
    joignables, ports à l'écoute ; le débit internet et le scan du réseau local
    s'ils sont demandés. Rien n'est changé sur le poste."""
    targets = []
    for t in params.get("cibles") or []:
        if isinstance(t, dict) and isinstance(t.get("hote"), str) and isinstance(t.get("port"), int) and 0 < t["port"] < 65536:
            if re.fullmatch(r"[A-Za-z0-9.-]{1,253}", t["hote"]):
                targets.append({"hote": t["hote"], "port": t["port"]})
    body = {"op": "diagnostic", "debit": params.get("debit") is True, "scan": params.get("scan") is True, "cibles": targets[:16]}
    # Le test de sortie : le point d'entrée de la plateforme, jamais sa clé de stream.
    out = params.get("sortie")
    if isinstance(out, dict) and out.get("protocole") in ("rtmp", "rtmps", "srt") and isinstance(out.get("hote"), str) and isinstance(out.get("port"), int) and 0 < out["port"] < 65536:
        if re.fullmatch(r"[A-Za-z0-9.-]{1,253}", out["hote"]):
            body["sortie"] = {"protocole": out["protocole"], "hote": out["hote"], "port": out["port"]}
            prevu = params.get("prevu_mbps")
            if isinstance(prevu, (int, float)) and not isinstance(prevu, bool) and 0 < prevu < 1000:
                body["sortie"]["prevu_mbps"] = prevu
    try:
        # Un script à part : pilote.ps1 reste sous la longueur de commande de l'agent.
        reply = call(mesh, device_id, body, new_nonce, timeout=DIAGNOSTIC_TIMEOUT, script=script or DIAGNOSTIC_SCRIPT.read_text(encoding="utf-8"))
    except (MeshError, PilotError) as exc:
        return False, str(exc), None
    detail = reply.get("detail") or ""
    data = reply.get("diagnostic") if isinstance(reply.get("diagnostic"), dict) else None
    return bool(reply.get("ok")), detail[:1].upper() + detail[1:], data


def supervision(mesh: MeshCtrl, device_id: str, unit_id: str, params: dict, avd, new_nonce: Callable[[], str], script: str | None = None, reference: str = "") -> tuple[bool, str]:
    """Pose la sonde (jeton tiré par AVDiagram, envoyé tel quel au poste) ou la retire.
    Le jeton ne passe pas par le journal du worker. Après la pose, l'envoi à la
    console régie locale (config/consoles.json) est posé ou retiré à son tour."""
    if not isinstance(params.get("actif"), bool):
        return False, "Paramètre `actif` manquant."
    if not unit_id:
        return False, "La tâche ne dit pas quel exemplaire superviser."
    consoles: list[dict] = []
    if params["actif"]:
        try:
            consoles = regie.load()
        except regie.ConsoleError as exc:
            return False, f"Console régie : {exc}"
        if consoles and not REFERENCE_RE.fullmatch(reference or ""):
            return False, "Référence du poste illisible pour la console régie."
    try:
        if params["actif"]:
            probe = avd.create_probe(unit_id)
            # Sans ses commentaires : la commande de pose est près de la longueur
            # que l'agent accepte (pilote.ps1 et la sonde, tous deux emballés).
            packed = pack(slim(PROBE_SCRIPT.read_text(encoding="utf-8-sig")).encode("utf-8"))
            request = {"op": "supervision", "actif": True, "url": probe["url"], "jeton": probe["token"], "script": packed}
        else:
            avd.remove_probe(unit_id)
            request = {"op": "supervision", "actif": False}
        reply = call(mesh, device_id, request, new_nonce, script=script)
    except (MeshError, PilotError) as exc:
        return False, str(exc)
    except Exception as exc:  # AvdError et réponse inattendue
        return False, f"AVDiagram : {exc}"
    detail = reply.get("detail") or ""
    text = detail[:1].upper() + detail[1:]
    if not reply.get("ok") or not params["actif"]:
        return bool(reply.get("ok")), text
    # La pose de la sonde retire une console posée avant (pilote.ps1), son
    # retrait emporte tout le dossier : seule une console connue est reposée.
    # La lecture de vMix suit le même chemin, même sans console.
    body = {"op": "console", "actif": True, "reference": reference.upper(), "consoles": regie.for_probe(consoles, reference) if consoles else []}
    try:
        second = call(mesh, device_id, body, new_nonce, script=probe_extras())
    except (MeshError, PilotError) as exc:
        return True, f"{text}. Console régie et lecture de vMix pas posées : {exc}"
    extra = second.get("detail") or "pas de réponse"
    if not second.get("ok"):
        return True, f"{text}. Console régie et lecture de vMix pas posées : {extra}"
    return True, f"{text}. {extra[:1].upper() + extra[1:]}"


def probe_extras() -> str:
    """console-pose.ps1 avec console.ps1 et vmix.ps1 en tête."""
    return with_source(with_source(CONSOLE_INSTALLER.read_text(encoding="utf-8"), CONSOLE_SCRIPT, "RegieSource"), VMIX_SCRIPT, "VmixSource")


def wallpaper(mesh: MeshCtrl, device_id: str, reference: str, params: dict, new_nonce: Callable[[], str], script: str | None = None) -> tuple[bool, str] | tuple[bool, str, dict]:
    """Pose ou retire le fond d'état (agent/fond.ps1) par agent/fond-pose.ps1,
    à part de pilote.ps1 pour rester sous la longueur de commande. Le bilan
    relu dans chaque session ouverte devient le contrôle de la tâche."""
    if not isinstance(params.get("actif"), bool):
        return False, "Paramètre `actif` manquant."
    body: dict = {"op": "fond", "actif": params["actif"]}
    installer = script or WALLPAPER_INSTALLER.read_text(encoding="utf-8")
    if params["actif"]:
        if not REFERENCE_RE.fullmatch(reference or ""):
            return False, "Référence du poste illisible pour le fond d'état."
        body["reference"] = reference
        # Le relevé de l'écran du mode événement d'abord, par son propre
        # installeur : avec fond.ps1, la commande dépasserait la longueur que
        # l'agent accepte.
        try:
            survey = with_wallpaper(SURVEY_INSTALLER.read_text(encoding="utf-8"), SURVEY_SCRIPT)
            first = call(mesh, device_id, {"op": "releve"}, new_nonce, script=survey)
        except (MeshError, PilotError) as exc:
            return False, str(exc)
        if not first.get("ok"):
            detail = first.get("detail") or "pas de réponse"
            return False, f"Relevé de l'écran pas posé : {detail}"
        installer = with_wallpaper(installer)
    try:
        reply = call(mesh, device_id, body, new_nonce, script=installer)
    except (MeshError, PilotError) as exc:
        return False, str(exc)
    detail = reply.get("detail") or ""
    text = detail[:1].upper() + detail[1:]
    if not isinstance(reply.get("points"), list):
        return bool(reply.get("ok")), text
    return bool(reply.get("ok")), text, verdict(reply["points"], "Aucune session ouverte sur le poste : rien à relire.")


# --- Contrôle : l'effet réel d'une action, relu dans Windows -----------------------

# Ce que le contrôle attend au plus : la sonde (45 s), le fond (30 s), les notifications (20 s).
CHECK_TIMEOUT = 150
CHECK_POINTS = 30
# Les actions relues par agent/controle.ps1, et ce qu'il y relit.
CHECKED = {"mode_evenement": "evenement", "nettoyage": "nettoyage", "supervision": "supervision"}


def verdict(points, raison: str | None = None) -> dict:
    """Le contrôle tel qu'AVDiagram le garde : `verifie` quand chaque point a été
    relu tel que voulu, `pas_applique` quand Windows n'en applique pas un,
    `non_verifie` sinon (rien de relu, ou un point illisible)."""
    clean = []
    for p in points if isinstance(points, list) else []:
        if not isinstance(p, dict) or not isinstance(p.get("nom"), str) or not p["nom"].strip():
            continue
        ok = p["ok"] if isinstance(p.get("ok"), bool) else None
        clean.append({"nom": p["nom"].strip()[:60], "ok": ok, "constat": str(p.get("constat") or "").strip()[:300]})
    clean = clean[:CHECK_POINTS]
    if any(p["ok"] is False for p in clean):
        state = "pas_applique"
    elif clean and all(p["ok"] is True for p in clean):
        state = "verifie"
    else:
        state = "non_verifie"
    out: dict = {"etat": state, "points": clean}
    if state == "non_verifie" and raison:
        out["raison"] = raison.strip()[:300]
    return out


def check(mesh: MeshCtrl, device_id: str, quoi: str, params: dict, new_nonce: Callable[[], str], script: str | None = None) -> dict:
    """Relit dans Windows l'effet d'une action faite (agent/controle.ps1, qui ne
    change aucun réglage)."""
    body: dict = {"op": "controle", "quoi": quoi, "actif": params.get("actif") is True}
    if isinstance(params.get("parties"), list):
        body["parties"] = [p for p in dict.fromkeys(params["parties"]) if p in EVENT_PARTS]
    try:
        reply = call(mesh, device_id, body, new_nonce, timeout=CHECK_TIMEOUT, script=script or CHECK_SCRIPT.read_text(encoding="utf-8"))
    except (MeshError, PilotError) as exc:
        return verdict([], f"Contrôle impossible : {exc}")
    raison = None if reply.get("ok") else f"Contrôle interrompu : {reply.get('detail') or 'sans explication'}"
    return verdict(reply.get("points"), raison)


def with_check(ok: bool, text: str, controle: dict) -> tuple[bool, str, dict]:
    """Une action que Windows n'applique pas passe en échec, avec ce qui manque."""
    if controle["etat"] != "pas_applique":
        return ok, text, controle
    manque = ". ".join(f"{p['nom']} : {p['constat']}" for p in controle["points"] if p["ok"] is False)
    return False, f"{text.rstrip('.')}. Pas appliqué dans Windows. {manque}", controle


def thumbnail(mesh: MeshCtrl, device_id: str, unit_id: str, params: dict, avd, new_nonce: Callable[[], str], script: str | None = None) -> tuple[bool, str]:
    """Met le poste au mur d'écrans (agent/vignette.ps1, jeton pnv_ tiré par
    AVDiagram et envoyé tel quel au poste) ou l'en retire, par
    agent/vignette-pose.ps1. Le jeton ne passe pas par le journal du worker."""
    if not isinstance(params.get("actif"), bool):
        return False, "Paramètre `actif` manquant."
    if not unit_id:
        return False, "La tâche ne dit pas quel exemplaire mettre au mur."
    try:
        if params["actif"]:
            got = avd.create_thumbnail(unit_id)
            body = {"op": "vignette", "actif": True, "url": got["url"], "jeton": got["token"], "script": pack(THUMBNAIL_SCRIPT.read_bytes())}
        else:
            avd.remove_thumbnail(unit_id)
            body = {"op": "vignette", "actif": False}
        reply = call(mesh, device_id, body, new_nonce, script=script or THUMBNAIL_INSTALLER.read_text(encoding="utf-8"))
    except (MeshError, PilotError) as exc:
        return False, str(exc)
    except Exception as exc:  # AvdError et réponse inattendue
        return False, f"AVDiagram : {exc}"
    detail = reply.get("detail") or ""
    return bool(reply.get("ok")), detail[:1].upper() + detail[1:]


def message(mesh: MeshCtrl, device_id: str, name: str, params: dict, new_nonce: Callable[[], str], script: str | None = None) -> tuple[bool, str]:
    """Un message à l'écran du poste, par MeshCentral : notification (`toast`)
    ou fenêtre à valider (`boite`). Refusé en mode événement sans `forcer` :
    une fenêtre par-dessus le logiciel de direct peut passer à l'antenne. Un
    poste qui ne sait pas dire son état (ancienne version) n'est pas bloqué."""
    text = params.get("texte")
    title = params.get("titre") or "Régie Pointe Noire"
    kind = params.get("genre") or "toast"
    if not isinstance(text, str) or not text.strip() or len(text) > MESSAGE_MAX or CONTROL_RE.search(text):
        return False, "Message vide, trop long ou illisible."
    if not isinstance(title, str) or len(title) > TITLE_MAX or CONTROL_RE.search(title) or "\n" in title:
        return False, "Titre trop long ou illisible."
    if kind not in MESSAGE_KINDS:
        return False, f"Genre de message inconnu : {kind!r}"
    if params.get("forcer") is not True:
        try:
            st = state(mesh, device_id, new_nonce, script=script)
        except (MeshError, PilotError):
            st = {}
        if st.get("evenement"):
            return False, f"Refusé : {name} est en mode événement. Cochez « Même en mode événement » pour l'afficher quand même."
    try:
        if kind == "toast":
            mesh.toast(device_id, text.strip(), title.strip())
            return True, f"Notification envoyée à {name} : elle s'affiche si une session est ouverte."
        mesh.message_box(device_id, text.strip(), title.strip())
        return True, f"Fenêtre envoyée à {name} : elle reste jusqu'à OK, 10 minutes au plus."
    except MeshError as exc:
        return False, str(exc)


def posed_versions() -> dict[str, str]:
    """La version de chaque script posé, tirée de son contenu : elle change
    seulement quand une mise à jour du relais le change."""
    out = {}
    for action, paths in POSED.items():
        h = hashlib.sha256()
        for path in paths:
            h.update(path.read_bytes())
        if action == "supervision":
            # Une console régie ajoutée ou retirée sur le NAS fait reposer la sonde.
            h.update(regie.fingerprint_of_config())
        out[action] = h.hexdigest()[:12]
    return out


def pack(data: bytes) -> str:
    return base64.b64encode(gzip.compress(data, mtime=0)).decode("ascii")


def with_wallpaper(installer: str, path: Path = WALLPAPER_SCRIPT) -> str:
    """Un script du fond en tête de fond-pose.ps1, dans `$FondSource` : une
    seule compression pour les deux, au lieu d'un base64 dans le base64 des
    paramètres."""
    return with_source(installer, path, "FondSource")


def with_source(installer: str, path: Path, variable: str) -> str:
    source = path.read_text(encoding="utf-8-sig")
    if re.search(r"^'@", source, re.M):
        raise PilotError(f"{path.name} a une ligne qui commence par '@ : il ne peut pas voyager dans une chaîne @' '@.")
    return f"${variable} = @'\n{source}\n'@\n{installer}"


def send(mesh: MeshCtrl, device_id: str, item: dict, params: dict, new_nonce: Callable[[], str], script: str | None = None) -> tuple[bool, str]:
    """Un élément de la bibliothèque d'envois (GET /api/v1/postes/envois/<id>)."""
    kind = item.get("kind")
    name = str(item.get("name") or "?")
    if kind == "script":
        content = item.get("content")
        if not isinstance(content, str) or not content.strip():
            return False, f"Script {name} vide."
        if item.get("approved") is not True:
            return False, f"Le script {name} n'est pas approuvé : rien n'est lancé."
        raw = content.encode("utf-8")
        digest = hashlib.sha256(raw).hexdigest()
        if digest != item.get("sha256") or (params.get("empreinte") and digest != params.get("empreinte")):
            return False, f"Le script {name} a changé depuis la demande : rien n'est lancé."
        request = {"op": "script", "empreinte": digest, "script": pack(raw), "delai": SCRIPT_DELAY}
        nonce = new_nonce()
        command = build_command(request, nonce, script)
        if len(command) > MAX_COMMAND:
            return False, f"Le script {name} est trop long pour passer par MeshCentral ({len(command)} caractères une fois emballé)."
        try:
            reply = parse_output(mesh.run_powershell(device_id, command, timeout=SCRIPT_DELAY + 60), nonce)
        except (MeshError, PilotError) as exc:
            return False, str(exc)
        detail = str(reply.get("detail") or "")
        parts = [f"{name} : {detail}"]
        if reply.get("sortie"):
            parts.append(f"Sortie : {reply['sortie']}")
        if reply.get("erreurs"):
            parts.append(f"Erreurs : {reply['erreurs']}")
        return bool(reply.get("ok")), "\n".join(parts)
    if kind == "file":
        url = item.get("url")
        if not isinstance(url, str) or not url.startswith("https://"):
            return False, f"Le fichier {name} n'a pas d'adresse de téléchargement (stockage absent ?)."
        size = item.get("size") if isinstance(item.get("size"), int) else 0
        request = {"op": "fichier", "url": url, "nom": item.get("file"), "destination": item.get("destination"), "taille": size or None}
        try:
            reply = call(mesh, device_id, request, new_nonce, timeout=600 + size // DOWNLOAD_RATE, script=script)
        except (MeshError, PilotError) as exc:
            return False, str(exc)
        detail = str(reply.get("detail") or "")
        return bool(reply.get("ok")), f"{name} : {detail}"
    return False, f"Élément d'envoi inconnu : {kind!r}"


def envoi(mesh: MeshCtrl, device_id: str, params: dict, avd, new_nonce: Callable[[], str], script: str | None = None) -> tuple[bool, str]:
    envoi_id = params.get("envoi_id")
    if not isinstance(envoi_id, str) or not UUID_RE.match(envoi_id):
        return False, "Paramètre `envoi_id` manquant."
    try:
        item = avd.get_envoi(envoi_id)
    except Exception as exc:  # AvdError
        return False, f"AVDiagram : {exc}"
    return send(mesh, device_id, item, params, new_nonce, script=script)


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


def slim_fingerprints() -> dict[str, str]:
    """L'empreinte de chaque script tel qu'il voyage, à comparer avec celle de
    scripts/essai-windows.ps1, qui refait la découpe sous Windows."""
    agent = AGENT_SCRIPT.parent
    sent = {p.name: p.read_text(encoding="utf-8-sig") for p in sorted(agent.glob("*.ps1"))}
    sent["releve-pose.ps1+releve.ps1"] = with_wallpaper(SURVEY_INSTALLER.read_text(encoding="utf-8"), SURVEY_SCRIPT)
    sent["fond-pose.ps1+fond.ps1"] = with_wallpaper(WALLPAPER_INSTALLER.read_text(encoding="utf-8"), WALLPAPER_SCRIPT)
    sent["politique.ps1+pilote.ps1"] = with_policy()
    return {name: hashlib.sha256(slim(text).encode("utf-8")).hexdigest()[:12] for name, text in sent.items()}


if __name__ == "__main__":
    for name, fingerprint in slim_fingerprints().items():
        print(f"{fingerprint}  {name}")

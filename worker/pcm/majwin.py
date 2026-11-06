"""Mises à jour par étapes : Windows Update, pilotes (carte graphique comprise)
et logiciels winget, d'abord sur le poste pilote, puis sur le parc.

AVDiagram tient la campagne (page Postes, Mises à jour) : le relevé du pilote,
la liste figée de ce qui est approuvé, l'étape pilote, le feu vert, puis le
parc. L'outil des postes n'exécute que deux choses, avec l'action
`mises_a_jour` :

    releve     ce que Windows Update propose au poste et les versions des
               logiciels du catalogue. Ne change rien. Le relevé détaillé part
               avec la tâche (`donnees`).
    appliquer  exactement la liste approuvée (identifiants Windows Update,
               versions winget figées) : un poste du parc reçoit ce que le
               pilote a reçu, pas ce qui est sorti depuis. Lancée dans une
               tâche planifiée du poste (agent/majwin.ps1), suivie jusqu'au
               bout, redémarrage compris, puis relue : un nouveau relevé dit
               si chaque mise à jour est vraiment posée.

Jamais en mode événement : le relais le vérifie avant de lancer, le poste le
revérifie au départ de l'installation, avant chaque logiciel et avant de
redémarrer.
"""

from __future__ import annotations

import re
import time
from pathlib import Path
from typing import Callable

from . import pilot
from .meshctrl import MeshError

SCRIPT = Path(__file__).resolve().parents[2] / "agent" / "majwin.ps1"
OPS = ("releve", "appliquer", "report")
KB_RE = re.compile(r"^(KB\d{4,8})( KB\d{4,8})*$")
# Le report des postes du parc derrière le pilote (choix du 2026-11-06).
MAX_DEFER = 30
GUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.I)
WINGET_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.+_-]{0,127}$")
VERSION_RE = re.compile(r"^[\w.+-]{1,64}$")
MAX_ITEMS = 60
# Une recherche Windows Update dure de quelques secondes à plusieurs minutes,
# puis winget relit chaque logiciel du catalogue.
SURVEY_TIMEOUT = 900
READ_TIMEOUT = 60
POLL_GAP = 60
# Le délai d'AVDiagram pour cette action est de 3 heures : le relais rend la
# main avant.
POLL_LIMIT = 165 * 60


class UpdateError(ValueError):
    pass


def parse(params: dict) -> dict:
    """Les paramètres d'AVDiagram, revalidés avant tout envoi."""
    op = params.get("op")
    if op not in OPS:
        raise UpdateError(f"Opération de mise à jour inconnue : {op!r}")
    if op == "releve":
        return {"op": "releve"}
    if op == "report":
        jours = params.get("jours")
        if jours is None:
            return {"op": "report"}
        if not isinstance(jours, int) or isinstance(jours, bool) or not 0 <= jours <= MAX_DEFER:
            raise UpdateError(f"Report illisible : {jours!r}")
        return {"op": "report", "jours": jours}
    windows, logiciels = [], []
    for w in params.get("windows") or []:
        if not isinstance(w, dict) or not GUID_RE.match(str(w.get("id") or "")):
            raise UpdateError(f"Mise à jour Windows illisible : {w!r}")
        kb = str(w.get("kb") or "").strip()
        windows.append({"id": str(w["id"]).lower(), "rev": int(w.get("rev") or 0), "titre": str(w.get("titre") or "")[:200], "kb": kb if KB_RE.match(kb) else ""})
    for l in params.get("logiciels") or []:
        if not isinstance(l, dict) or not WINGET_RE.match(str(l.get("id") or "")):
            raise UpdateError(f"Logiciel illisible : {l!r}")
        version = l.get("version")
        if version is not None and not VERSION_RE.match(str(version)):
            raise UpdateError(f"Version illisible pour {l['id']} : {version!r}")
        logiciels.append({"id": str(l["id"]), "version": str(version) if version is not None else None})
    if not windows and not logiciels:
        raise UpdateError("Rien à installer : la liste approuvée est vide.")
    if len(windows) + len(logiciels) > MAX_ITEMS:
        raise UpdateError(f"Plus de {MAX_ITEMS} mises à jour dans une même étape.")
    campagne = params.get("campagne")
    if campagne is not None and not GUID_RE.match(str(campagne)):
        raise UpdateError("Identifiant de campagne illisible.")
    return {"op": "appliquer", "windows": windows, "logiciels": logiciels, "redemarrer": params.get("redemarrer") is not False, "campagne": campagne}


def _call(mesh, device_id: str, body: dict, new_nonce: Callable[[], str], timeout: int, script: str | None) -> dict:
    return pilot.call(mesh, device_id, body, new_nonce, timeout=timeout, script=script or SCRIPT.read_text(encoding="utf-8"))


def survey_summary(data: dict) -> str:
    windows = [w for w in data.get("windows") or [] if isinstance(w, dict)]
    logiciels = [l for l in data.get("logiciels") or [] if isinstance(l, dict) and l.get("disponible")]
    parts = []
    if data.get("windows_ok") is False:
        parts.append(f"Windows Update illisible : {str(data.get('windows_erreur') or '?')[:200]}")
    else:
        securite = sum(1 for w in windows if w.get("genre") == "securite")
        pilotes = [w for w in windows if w.get("genre") == "pilote"]
        gpu = sum(1 for w in pilotes if w.get("gpu"))
        txt = f"{len(windows)} mise{'s' if len(windows) > 1 else ''} à jour Windows"
        details = []
        if securite:
            details.append(f"{securite} de sécurité")
        if pilotes:
            details.append(f"{len(pilotes)} pilote{'s' if len(pilotes) > 1 else ''}" + (f" dont {gpu} carte graphique" if gpu else ""))
        parts.append(txt + (f" ({', '.join(details)})" if details else ""))
    parts.append(f"{len(logiciels)} logiciel{'s' if len(logiciels) > 1 else ''} à mettre à jour")
    if data.get("winget_erreur"):
        parts.append(str(data["winget_erreur"])[:200])
    if data.get("redemarrage_attendu"):
        parts.append("redémarrage déjà attendu par Windows")
    return ", ".join(parts)


def survey(mesh, device_id: str, software_ids: list[str], new_nonce: Callable[[], str], script: str | None = None) -> tuple[bool, str, dict | None]:
    ids = [i for i in dict.fromkeys(software_ids) if WINGET_RE.match(i)][:MAX_ITEMS]
    try:
        reply = _call(mesh, device_id, {"op": "releve", "logiciels": ids}, new_nonce, SURVEY_TIMEOUT, script)
    except (MeshError, pilot.PilotError) as exc:
        return False, f"Relevé impossible : {exc}", None
    data = {k: reply.get(k) for k in ("windows_version", "evenement", "redemarrage_attendu", "demarre_le", "pause_jusqu_au", "windows_ok", "windows_erreur", "windows", "logiciels", "winget_erreur")}
    return bool(reply.get("ok")), survey_summary(data), data


def check(request: dict, after: dict | None, elements: list[dict]) -> dict:
    """Ce qu'un nouveau relevé dit de chaque mise à jour demandée : Windows ne
    la propose plus, et winget donne la version voulue."""
    points = []
    if after is None:
        return pilot.verdict([], "Relevé après installation impossible.")
    offered = [w for w in after.get("windows") or [] if isinstance(w, dict)]
    pending = {str(w.get("id") or "").lower() for w in offered}
    pending_kb = {kb for w in offered for kb in str(w.get("kb") or "").split()}
    by_id = {str(e.get("id") or "").lower(): e for e in elements if isinstance(e, dict)}
    for w in request["windows"]:
        e = by_id.get(w["id"], {})
        nom = (w.get("titre") or w["id"])[:60]
        if after.get("windows_ok") is False:
            points.append({"nom": nom, "ok": None, "constat": "Windows Update illisible au contrôle"})
        elif w["id"] in pending or any(kb in pending_kb for kb in w.get("kb", "").split()):
            points.append({"nom": nom, "ok": False, "constat": f"toujours proposée par Windows Update ({e.get('etat') or 'pas lancée'} {e.get('code') or ''})".strip()})
        elif e.get("etat") == "absente":
            points.append({"nom": nom, "ok": True, "constat": "déjà posée, plus proposée"})
        else:
            points.append({"nom": nom, "ok": True, "constat": "posée, plus proposée par Windows Update"})
    versions = {str(l.get("id") or "").lower(): l for l in after.get("logiciels") or [] if isinstance(l, dict)}
    for l in request["logiciels"]:
        v = versions.get(l["id"].lower())
        if v is None:
            points.append({"nom": l["id"], "ok": None, "constat": "pas relu par winget"})
        elif l["version"] and v.get("installe") == l["version"]:
            points.append({"nom": l["id"], "ok": True, "constat": f"version {l['version']}"})
        elif l["version"]:
            points.append({"nom": l["id"], "ok": False, "constat": f"version {v.get('installe') or 'absente'} au lieu de {l['version']}"})
        else:
            points.append({"nom": l["id"], "ok": not v.get("disponible"), "constat": f"version {v.get('installe') or 'absente'}"})
    if after.get("redemarrage_attendu"):
        points.append({"nom": "Redémarrage", "ok": None, "constat": "Windows attend encore un redémarrage pour finir"})
    return pilot.verdict(points)


def apply(
    mesh,
    device_id: str,
    params: dict,
    software_ids: list[str],
    new_nonce: Callable[[], str],
    sleep: Callable[[float], None] = time.sleep,
    clock: Callable[[], float] = time.monotonic,
    script: str | None = None,
) -> tuple[bool, str, dict | None, dict | None]:
    """(ok, texte, contrôle, données). Lance l'installation sur le poste, suit
    son état (le poste peut disparaître pendant le redémarrage), puis relit."""
    try:
        request = parse(params)
    except (UpdateError, ValueError, TypeError) as exc:
        return False, str(exc), None, None
    try:
        reply = _call(mesh, device_id, request, new_nonce, pilot.CALL_TIMEOUT, script)
    except (MeshError, pilot.PilotError) as exc:
        return False, f"Installation non lancée : {exc}", None, None
    if not reply.get("ok"):
        return False, f"Installation {reply.get('detail') or 'refusée par le poste'}", None, None
    start = clock()
    last, etat = "", None
    while clock() - start < POLL_LIMIT:
        sleep(POLL_GAP)
        try:
            r = _call(mesh, device_id, {"op": "resultat"}, new_nonce, READ_TIMEOUT, script)
        except (MeshError, pilot.PilotError) as exc:
            last = f"poste injoignable ({exc})"  # redémarrage en cours, le plus souvent
            continue
        etat = r.get("etat") if isinstance(r.get("etat"), dict) else None
        if not etat:
            last = "état de l'installation absent du poste"
            continue
        if etat.get("etape") == "refuse":
            return False, f"Installation refusée par le poste : {etat.get('detail')}", None, {"etat": etat}
        if etat.get("etape") != "termine":
            last = str(etat.get("detail") or etat.get("etape") or "")
            continue
        # Les deux heures en UTC au format ISO : comparables comme du texte.
        if etat.get("redemarre") and not str(r.get("demarre_le") or "") > str(etat.get("fin") or ""):
            last = "redémarrage annoncé, pas encore fait"
            continue
        break
    else:
        return False, f"Installation sans fin après {POLL_LIMIT // 60} minutes : {last or 'aucune nouvelle'}", None, {"etat": etat}
    elements = [e for e in etat.get("elements") or [] if isinstance(e, dict)]
    ok_survey, _, after = survey(mesh, device_id, software_ids or [l["id"] for l in request["logiciels"]], new_nonce, script=script)
    controle = check(request, after if ok_survey or after else None, elements)
    failed = [e for e in elements if e.get("etat") in ("echec", "refuse")]
    text = f"Mises à jour : {etat.get('detail') or 'terminé'}"
    if failed:
        text += ". En échec : " + " ; ".join(f"{str(e.get('titre') or e.get('id'))[:80]} ({e.get('code') or e.get('constat') or '?'})" for e in failed[:8])
    ok = not failed
    ok, text, controle = pilot.with_check(ok, text, controle)
    return ok, text, controle, {"etat": etat, "apres": after}


def defer(mesh, device_id: str, params: dict, new_nonce: Callable[[], str], script: str | None = None) -> tuple[bool, str, dict | None]:
    """Garde le poste derrière le pilote (ou retire le report, 0 jour) et
    relit ce que Windows en garde. Sans `jours` : le dernier choix du poste,
    reposé (le renouvellement de la semaine)."""
    try:
        request = parse({**params, "op": "report"})
    except UpdateError as exc:
        return False, str(exc), None
    try:
        reply = _call(mesh, device_id, request, new_nonce, pilot.CALL_TIMEOUT, script)
    except (MeshError, pilot.PilotError) as exc:
        return False, f"Report non posé : {exc}", None
    detail = str(reply.get("detail") or "")
    text = detail[:1].upper() + detail[1:]
    if not reply.get("ok"):
        return False, text or "Report refusé par le poste", None
    points = reply.get("points") or []
    if not points:
        return True, text, None
    return pilot.with_check(True, text, pilot.verdict(points))

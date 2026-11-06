"""L'état de chaque poste, les réseaux du parc et les variables de Companion,
calculés à partir des dernières mesures. Fonctions pures, sans réseau."""

from __future__ import annotations

import ipaddress
from datetime import datetime
import re

# La sonde envoie une mesure toutes les 30 secondes : trois manquées, le poste
# est hors ligne.
EN_LIGNE_S = 90
SEUIL_CPU = 90
SEUIL_RAM = 90
SEUIL_DISQUE = 10
SEUIL_PASSERELLE_MS = 50

ETIQUETTES = {"ok": "OK", "alerte": "ALERTE", "hors_ligne": "HORS LIGNE"}


def _n(v):
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def cartes(mesure: dict) -> list[dict]:
    return [c for c in mesure.get("nics") or [] if isinstance(c, dict)]


# Un stream qui envoie moins que ça n'envoie rien d'utile.
SEUIL_STREAM_BPS = 300_000


def vmix(mesure: dict) -> dict | None:
    v = mesure.get("vmix")
    return v if isinstance(v, dict) else None


def etiquette_vmix(v: dict | None) -> str:
    """LIVE, REC, LIVE REC, PRÊT, MUET (vMix lancé, API muette), FERMÉ, ou vide sans vMix."""
    if not v:
        return ""
    if v.get("running") is False:
        return "FERMÉ"
    if not v.get("ok"):
        return "MUET"
    morceaux = [m for m, actif in (("LIVE", v.get("streaming")), ("REC", v.get("recording"))) if actif is True]
    return " ".join(morceaux) or "PRÊT"


def heure_locale(iso: str) -> str:
    try:
        return datetime.fromisoformat(iso.replace("Z", "+00:00")).astimezone().strftime("%H:%M")
    except ValueError:
        return iso[11:16]


def alertes_vmix(mesure: dict) -> list[str]:
    v = vmix(mesure)
    if not v:
        return []
    out = []
    if v.get("running") is False:
        out.append("vMix fermé")
    elif not v.get("ok"):
        out.append("vMix ne répond pas (Web Controller ?)")
    if v.get("streaming") is True:
        tx = sum(_n(c.get("tx")) or 0 for c in cartes(mesure) if not c.get("down"))
        if tx < SEUIL_STREAM_BPS:
            out.append("Stream vMix actif mais rien ne sort")
        coupes = [i + 1 for i, c in enumerate(v.get("channels") or []) if c is False]
        if coupes and len(v.get("channels") or []) > 1:
            out.append("Destination " + ", ".join(map(str, coupes)) + " coupée")
    elif isinstance(v.get("stopped_at"), str):
        out.append(f"Stream vMix arrêté à {heure_locale(v['stopped_at'])}")
    perdues = _n(v.get("dropped_new"))
    if perdues:
        out.append(f"vMix : {perdues:.0f} images perdues")
    return out


def alertes(mesure: dict) -> list[str]:
    out = []
    cpu, ram, disque = _n(mesure.get("cpu")), _n(mesure.get("ram")), _n(mesure.get("disk_free"))
    if cpu is not None and cpu >= SEUIL_CPU:
        out.append(f"Processeur à {cpu:.0f} %")
    if ram is not None and ram >= SEUIL_RAM:
        out.append(f"Mémoire à {ram:.0f} %")
    if disque is not None and disque <= SEUIL_DISQUE:
        out.append(f"Disque système à {disque:.0f} % libre")
    perte, ms = _n(mesure.get("gateway_loss")), _n(mesure.get("gateway_ms"))
    if perte is not None and perte >= 100:
        out.append("Passerelle injoignable")
    elif perte:
        out.append(f"Perte de {perte:.0f} % vers la passerelle")
    if ms is not None and ms >= SEUIL_PASSERELLE_MS:
        out.append(f"Passerelle à {ms:.0f} ms")
    for c in cartes(mesure):
        nom = str(c.get("name") or "carte")
        if c.get("down"):
            out.append(f"Câble débranché sur {nom}")
        elif (_n(c.get("errors")) or 0) > 0:
            out.append(f"Erreurs réseau sur {nom}")
    out.extend(alertes_vmix(mesure))
    return out


def etat_poste(p: dict, maintenant: float) -> dict:
    m = p.get("mesure") or {}
    age = maintenant - float(p.get("recu") or 0)
    liste = alertes(m) if age <= EN_LIGNE_S else []
    etat = "hors_ligne" if age > EN_LIGNE_S else ("alerte" if liste else "ok")
    actives = [c for c in cartes(m) if not c.get("down")]
    internet = _n(m.get("internet_loss"))
    return {
        "reference": p["reference"],
        "poste": p.get("poste"),
        "etat": etat,
        "etiquette": ETIQUETTES[etat],
        "age": round(age),
        "alertes": liste,
        "cpu": _n(m.get("cpu")),
        "ram": _n(m.get("ram")),
        "disque": _n(m.get("disk_free")),
        "passerelle_ms": _n(m.get("gateway_ms")),
        "passerelle_perte": _n(m.get("gateway_loss")),
        "internet": None if internet is None else internet < 100,
        "internet_ms": _n(m.get("internet_ms")),
        "rx": sum(_n(c.get("rx")) or 0 for c in actives),
        "tx": sum(_n(c.get("tx")) or 0 for c in actives),
        "adresses": [c.get("ipv4") for c in actives if c.get("ipv4")],
        "cartes": cartes(m),
        "adresse": p.get("adresse"),
        "console_ip": p.get("console_ip"),
        "vmix": etiquette_vmix(vmix(m)) if age <= EN_LIGNE_S else "",
        "vmix_detail": vmix(m) if age <= EN_LIGNE_S else None,
    }


def reseaux(etats: list[dict]) -> dict:
    """Les postes en ligne regroupés par réseau IPv4, les adresses en double,
    et dans un même réseau les passerelles qui ne concordent pas."""
    groupes: dict[str, dict] = {}
    par_ip: dict[str, set] = {}
    for e in etats:
        if e["etat"] == "hors_ligne":
            continue
        for c in e["cartes"]:
            ip, prefixe = c.get("ipv4"), c.get("prefix")
            if c.get("down") or not ip or not isinstance(prefixe, int):
                continue
            try:
                reseau = ipaddress.ip_network(f"{ip}/{prefixe}", strict=False)
            except ValueError:
                continue
            g = groupes.setdefault(str(reseau), {"reseau": str(reseau), "membres": [], "passerelles": set()})
            g["membres"].append({
                "reference": e["reference"], "carte": c.get("name"), "ip": ip, "dhcp": c.get("dhcp"),
                "passerelle": c.get("gateway"), "filaire": c.get("wired"), "profil": c.get("profile"),
            })
            if c.get("gateway"):
                g["passerelles"].add(c["gateway"])
            par_ip.setdefault(ip, set()).add(e["reference"])
    doublons = {ip: sorted(refs) for ip, refs in par_ip.items() if len(refs) > 1}
    out = []
    for g in groupes.values():
        remarques = []
        if len(g["passerelles"]) > 1:
            remarques.append("Passerelles différentes : " + ", ".join(sorted(g["passerelles"])))
        for ip in sorted({m["ip"] for m in g["membres"] if m["ip"] in doublons}):
            remarques.append(f"Adresse {ip} en double : " + ", ".join(doublons[ip]))
        publics = sorted({m["reference"] for m in g["membres"] if m["profil"] == "Public"})
        if publics:
            remarques.append("Profil Public (pare-feu strict) : " + ", ".join(publics))
        g["membres"].sort(key=lambda m: ipaddress.ip_address(m["ip"]))
        out.append({"reseau": g["reseau"], "membres": g["membres"], "passerelles": sorted(g["passerelles"]), "remarques": remarques, "conflit": any(m["ip"] in doublons for m in g["membres"])})
    out.sort(key=lambda g: (-len(g["membres"]), g["reseau"]))
    return {"reseaux": out, "doublons": doublons}


def nom_variable(reference: str) -> str:
    return "pn_" + (re.sub(r"[^a-z0-9]+", "_", reference.lower()).strip("_") or "poste")


def texte_court(e: dict) -> str:
    if e["etat"] == "hors_ligne":
        return "Hors ligne"
    if e["alertes"]:
        return e["alertes"][0]
    morceaux = [e["vmix"]] if e.get("vmix") in ("LIVE", "REC", "LIVE REC") else []
    if e["cpu"] is not None:
        morceaux.append(f"CPU {e['cpu']:.0f}%")
    if e["passerelle_ms"] is not None:
        morceaux.append(f"GW {e['passerelle_ms']:.0f}ms")
    return " ".join(morceaux) or "OK"


def variables_companion(etats: list[dict]) -> dict[str, str]:
    """Les variables personnalisées poussées dans Companion : un résumé, et
    pour chaque poste son état (OK, ALERTE, HORS LIGNE), une ligne courte et
    l'état de vMix (LIVE, REC, LIVE REC, PRÊT, MUET, FERMÉ, vide sans vMix)."""
    compte = {k: 0 for k in ETIQUETTES}
    v: dict[str, str] = {}
    for e in etats:
        compte[e["etat"]] += 1
        base = nom_variable(e["reference"])
        v[f"{base}_etat"] = e["etiquette"]
        v[f"{base}_texte"] = texte_court(e)
        v[f"{base}_cpu"] = "" if e["cpu"] is None else str(round(e["cpu"]))
        v[f"{base}_vmix"] = e.get("vmix") or ""
    total = len(etats)
    v["pn_resume"] = f"{compte['ok']}/{total} OK" if total else "Aucun poste"
    v["pn_alertes"] = str(compte["alerte"])
    v["pn_hors_ligne"] = str(compte["hors_ligne"])
    v["pn_live"] = str(sum(1 for e in etats if "LIVE" in (e.get("vmix") or "")))
    v["pn_etat"] = "HORS LIGNE" if not total or compte["hors_ligne"] == total else ("ALERTE" if compte["alerte"] or compte["hors_ligne"] else "OK")
    return v


def vue(postes: list[dict], maintenant: float) -> dict:
    etats = [etat_poste(p, maintenant) for p in postes]
    compte = {k: sum(1 for e in etats if e["etat"] == k) for k in ETIQUETTES}
    return {"postes": etats, "compte": compte, **reseaux(etats)}

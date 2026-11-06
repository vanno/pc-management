"""L'état de chaque poste, les réseaux du parc et les variables de Companion,
calculés à partir des dernières mesures. Fonctions pures, sans réseau."""

from __future__ import annotations

import ipaddress
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
    morceaux = []
    if e["cpu"] is not None:
        morceaux.append(f"CPU {e['cpu']:.0f}%")
    if e["passerelle_ms"] is not None:
        morceaux.append(f"GW {e['passerelle_ms']:.0f}ms")
    return " ".join(morceaux) or "OK"


def variables_companion(etats: list[dict]) -> dict[str, str]:
    """Les variables personnalisées poussées dans Companion : un résumé, et
    pour chaque poste son état (OK, ALERTE, HORS LIGNE) et une ligne courte."""
    compte = {k: 0 for k in ETIQUETTES}
    v: dict[str, str] = {}
    for e in etats:
        compte[e["etat"]] += 1
        base = nom_variable(e["reference"])
        v[f"{base}_etat"] = e["etiquette"]
        v[f"{base}_texte"] = texte_court(e)
        v[f"{base}_cpu"] = "" if e["cpu"] is None else str(round(e["cpu"]))
    total = len(etats)
    v["pn_resume"] = f"{compte['ok']}/{total} OK" if total else "Aucun poste"
    v["pn_alertes"] = str(compte["alerte"])
    v["pn_hors_ligne"] = str(compte["hors_ligne"])
    v["pn_etat"] = "HORS LIGNE" if not total or compte["hors_ligne"] == total else ("ALERTE" if compte["alerte"] or compte["hors_ligne"] else "OK")
    return v


def vue(postes: list[dict], maintenant: float) -> dict:
    etats = [etat_poste(p, maintenant) for p in postes]
    compte = {k: sum(1 for e in etats if e["etat"] == k) for k in ETIQUETTES}
    return {"postes": etats, "compte": compte, **reseaux(etats)}

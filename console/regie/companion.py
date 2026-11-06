"""Pousse l'état du parc dans Companion (Stream Deck) par son API HTTP :
POST /api/custom-variable/<nom>/value?value=<valeur>. Les boutons affichent
$(custom:pn_pn09_etat) et se colorent par le retour interne « Variable ».
Seules les valeurs changées partent, et tout est renvoyé toutes les 5 minutes
(Companion relancé entre-temps)."""

from __future__ import annotations

import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Callable

INTERVALLE = 3
TOUT_RENVOYER = 300


def adresse_valide(url: str) -> bool:
    p = urllib.parse.urlparse(url or "")
    return p.scheme in ("http", "https") and bool(p.hostname) and p.path in ("", "/") and not p.query


class Companion:
    def __init__(self, lire_url: Callable[[], str], lire_variables: Callable[[], dict], horloge=time.time, ouvrir=urllib.request.urlopen):
        self.lire_url = lire_url
        self.lire_variables = lire_variables
        self.horloge = horloge
        self.ouvrir = ouvrir
        self.envoye: dict[str, str] = {}
        self.dernier_tout = 0.0
        self.etat = {"actif": False, "ok": None, "erreur": "", "le": None, "envoyees": 0}
        self._url_vue = ""
        self._arret = threading.Event()

    def un_passage(self) -> None:
        url = (self.lire_url() or "").rstrip("/")
        if not url or not adresse_valide(url):
            self.etat.update(actif=False, ok=None, erreur="" if not url else "adresse illisible")
            self.envoye.clear()
            return
        if url != self._url_vue:
            self._url_vue = url
            self.envoye.clear()
        maintenant = self.horloge()
        if maintenant - self.dernier_tout >= TOUT_RENVOYER:
            self.envoye.clear()
        valeurs = self.lire_variables()
        a_envoyer = {k: v for k, v in valeurs.items() if self.envoye.get(k) != v}
        if not self.envoye:
            self.dernier_tout = maintenant
        self.etat["actif"] = True
        refus = ""
        for nom, valeur in a_envoyer.items():
            cible = f"{url}/api/custom-variable/{urllib.parse.quote(nom)}/value?value={urllib.parse.quote(valeur)}"
            req = urllib.request.Request(cible, data=b"", method="POST")
            try:
                with self.ouvrir(req, timeout=2) as r:
                    r.read()
                self.envoye[nom] = valeur
                self.etat["envoyees"] += 1
            except urllib.error.HTTPError as exc:
                # 404 : la variable n'existe pas dans Companion. Les autres partent
                # quand même, et celle-ci ne repart qu'au prochain renvoi complet.
                refus = f"{nom} refusée par Companion (HTTP {exc.code}) : créez-la dans Variables personnalisées"
                self.envoye[nom] = valeur
            except (urllib.error.URLError, OSError) as exc:
                raison = getattr(exc, "reason", exc)
                self.etat.update(ok=False, erreur=f"Companion injoignable à {url} ({raison})", le=maintenant)
                return
        if refus:
            self.etat.update(ok=False, erreur=refus, le=maintenant)
        elif a_envoyer:
            self.etat.update(ok=True, erreur="", le=maintenant)

    def tourner(self) -> None:
        while not self._arret.wait(INTERVALLE):
            try:
                self.un_passage()
            except Exception as exc:  # un passage raté n'arrête pas la console
                self.etat.update(ok=False, erreur=str(exc))

    def demarrer(self) -> threading.Thread:
        t = threading.Thread(target=self.tourner, name="companion", daemon=True)
        t.start()
        return t

    def arreter(self) -> None:
        self._arret.set()

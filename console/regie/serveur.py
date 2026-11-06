"""Les deux écoutes de la console.

  http://127.0.0.1:8470   la page et l'API pour ce PC seulement (navigateur,
                          Companion installé sur la régie). Sans code : seul
                          ce PC y accède, et l'en-tête Host est vérifié contre
                          le détournement DNS.
  https://<LAN>:8471      les sondes des postes (POST /api/sonde, jeton du
                          poste), la page vue d'un autre appareil (code de la
                          page) et Companion installé ailleurs (jeton Companion).
                          Certificat auto-signé, son empreinte est épinglée
                          dans chaque sonde.
"""

from __future__ import annotations

import hmac
import ipaddress
import json
import socket
import ssl
import threading
import time
import urllib.parse
from http import cookies
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from . import VERSION, etat
from .companion import Companion, adresse_valide
from .identite import REFERENCE_RE, Identite
from .page import PAGE, PAGE_CODE
from .store import Store

CORPS_MAX = 256 * 1024
MESURES_MAX = 20
NOM_MAX = 60


def ordre_adresse(a: str) -> tuple:
    """Les adresses du LAN du site d'abord (192.168, 10, 172.16-31), un VPN
    comme Tailscale (100.64.0.0/10) en dernier : les postes ne le joignent pas."""
    try:
        ip = ipaddress.IPv4Address(a)
    except ValueError:
        return (3, a)
    if ip in ipaddress.IPv4Network("100.64.0.0/10"):
        return (2, a)
    return (0 if ip.is_private else 1, tuple(int(x) for x in a.split(".")))


def adresses_locales() -> list[str]:
    vues = set()
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            vues.add(info[4][0])
    except OSError:
        pass
    # L'adresse de sortie par défaut, sans rien envoyer.
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("10.255.255.255", 1))
        vues.add(s.getsockname()[0])
        s.close()
    except OSError:
        pass
    return sorted((a for a in vues if not a.startswith("127.") and not a.startswith("169.254.")), key=ordre_adresse)


class Console:
    def __init__(self, ident: Identite, store: Store, port_local: int, port_https: int, port_udp: int, horloge=time.time):
        self.ident = ident
        self.store = store
        self.horloge = horloge
        self.port_local = port_local
        self.port_https = port_https
        self.port_udp = port_udp
        self.demarre = horloge()
        self.recues = 0
        self.refusees = 0
        self.derniers_refus: list[dict] = []
        self.companion = Companion(lambda: self.ident.reglages.get("companion_url", ""), self.variables)
        self._lock = threading.Lock()

    # --- Données -------------------------------------------------------------------

    def vue(self) -> dict:
        return etat.vue(self.store.postes(), self.horloge())

    def variables(self) -> dict:
        return etat.variables_companion(self.vue()["postes"])

    def info(self, local: bool) -> dict:
        ips = adresses_locales()
        vues = sorted({p["console_ip"] for p in self.store.postes() if p.get("console_ip") and not p["console_ip"].startswith("127.")})
        out = {
            "nom": self.ident.nom, "id": self.ident.id, "version": VERSION, "empreinte": self.ident.empreinte,
            "adresses": sorted(set(ips) | set(vues), key=ordre_adresse), "port_https": self.port_https, "port_local": self.port_local, "port_udp": self.port_udp,
            "depuis": self.demarre, "recues": self.recues, "refusees": self.refusees, "local": local,
            "companion": dict(self.companion.etat), "companion_url": self.ident.reglages.get("companion_url", ""),
        }
        if local:
            out.update(appairage=self.ident.code_appairage(self.port_https), code_page=self.ident.code_page,
                       jeton_companion=self.ident.jeton_companion, derniers_refus=list(self.derniers_refus))
        return out

    def recevoir(self, corps: dict, jeton: str, client: str, ip_console: str) -> tuple[int, dict]:
        reference = str(corps.get("reference") or "").strip().upper()
        if not REFERENCE_RE.fullmatch(reference):
            return 400, {"erreur": "référence illisible"}
        if not self.ident.verifier_poste(reference, jeton):
            with self._lock:
                self.refusees += 1
                self.derniers_refus = ([{"reference": reference[:60], "adresse": client, "le": self.horloge()}] + self.derniers_refus)[:10]
            return 401, {"erreur": "jeton refusé : la sonde n'est pas appairée à cette console"}
        mesures = [m for m in corps.get("samples") or [] if isinstance(m, dict)][-MESURES_MAX:]
        if not mesures:
            return 400, {"erreur": "aucune mesure"}
        poste = str(corps.get("poste") or "")[:NOM_MAX]
        self.store.ajouter(reference, poste, client, ip_console, mesures)
        with self._lock:
            self.recues += 1
        return 200, {"ok": True, "console": self.ident.id, "taches": []}

    def regler(self, corps: dict) -> tuple[int, dict]:
        if "nom" in corps:
            nom = str(corps["nom"] or "").strip()
            if not 1 <= len(nom) <= NOM_MAX:
                return 400, {"erreur": "nom de 1 à 60 caractères"}
            self.ident.nom = nom
        if "companion_url" in corps:
            url = str(corps["companion_url"] or "").strip().rstrip("/")
            if url and not adresse_valide(url):
                return 400, {"erreur": "adresse de Companion attendue sous la forme http://127.0.0.1:8000"}
            self.ident.reglages["companion_url"] = url
        self.ident.enregistrer()
        return 200, {"ok": True}


# --- HTTP ------------------------------------------------------------------------------


class Gestionnaire(BaseHTTPRequestHandler):
    console: Console
    local: bool
    server_version = "ConsoleRegie/" + VERSION
    sys_version = ""
    timeout = 15

    def log_message(self, format, *args):  # le journal reste lisible dans la fenêtre
        pass

    # --- Réponses ------------------------------------------------------------------

    def _envoyer(self, code: int, corps: bytes, type_: str, entetes: dict | None = None) -> None:
        self.send_response(code)
        self.send_header("Content-Type", type_)
        self.send_header("Content-Length", str(len(corps)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        for k, v in (entetes or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(corps)

    def _json(self, code: int, data) -> None:
        self._envoyer(code, json.dumps(data, ensure_ascii=False).encode("utf-8"), "application/json; charset=utf-8")

    def _texte(self, code: int, texte: str) -> None:
        self._envoyer(code, texte.encode("utf-8"), "text/plain; charset=utf-8")

    # --- Contrôles -----------------------------------------------------------------

    def _hote_local(self) -> bool:
        hote = (self.headers.get("Host") or "").lower()
        return hote in (f"127.0.0.1:{self.console.port_local}", f"localhost:{self.console.port_local}")

    def _code_ok(self) -> bool:
        if self.local:
            return True
        c = cookies.SimpleCookie()
        try:
            c.load(self.headers.get("Cookie") or "")
        except cookies.CookieError:
            return False
        v = c.get("pn_code")
        return bool(v) and hmac.compare_digest(v.value, self.console.ident.code_page)

    def _jeton(self) -> str:
        a = self.headers.get("Authorization") or ""
        return a[7:].strip() if a.lower().startswith("bearer ") else ""

    def _companion_ok(self, requete: dict) -> bool:
        if self.local or self._code_ok():
            return True
        jeton = self._jeton() or (requete.get("jeton") or [""])[0]
        return bool(jeton) and hmac.compare_digest(jeton, self.console.ident.jeton_companion)

    def _corps(self) -> dict | None:
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            return None
        if n <= 0 or n > CORPS_MAX:
            return None
        try:
            data = json.loads(self.rfile.read(n).decode("utf-8-sig"))
        except (ValueError, UnicodeDecodeError):
            return None
        return data if isinstance(data, dict) else None

    # --- Routes --------------------------------------------------------------------

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        if self.local and not self._hote_local():
            return self._texte(421, "Adresse refusée : ouvrir http://127.0.0.1:%d" % self.console.port_local)
        url = urllib.parse.urlsplit(self.path)
        requete = urllib.parse.parse_qs(url.query)
        chemin = url.path
        if chemin == "/entrer" and not self.local:
            code = (requete.get("code") or [""])[0].strip()
            if code and hmac.compare_digest(code, self.console.ident.code_page):
                return self._envoyer(303, b"", "text/plain", {"Location": "/", "Set-Cookie": f"pn_code={code}; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=86400"})
            return self._envoyer(200, PAGE_CODE.replace("{{ERREUR}}", "Code faux." if code else "").encode("utf-8"), "text/html; charset=utf-8")
        if chemin.startswith("/api/companion"):
            if not self._companion_ok(requete):
                return self._texte(401, "jeton Companion attendu")
            v = self.console.variables()
            nom = chemin[len("/api/companion"):].strip("/")
            if not nom:
                return self._json(200, v)
            return self._texte(200, v[nom]) if nom in v else self._texte(404, "variable inconnue")
        if chemin in ("/", "/index.html"):
            if not self._code_ok():
                return self._envoyer(303, b"", "text/plain", {"Location": "/entrer"})
            return self._envoyer(200, PAGE.encode("utf-8"), "text/html; charset=utf-8", {"Content-Security-Policy": "default-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src 'self' data:"})
        if not self._code_ok():
            return self._json(401, {"erreur": "code de la page attendu"})
        if chemin == "/api/etat":
            return self._json(200, {**self.console.vue(), "console": self.console.info(self.local), "maintenant": self.console.horloge()})
        if chemin == "/api/historique":
            ref = (requete.get("reference") or [""])[0].strip().upper()
            if not REFERENCE_RE.fullmatch(ref):
                return self._json(400, {"erreur": "référence illisible"})
            return self._json(200, {"reference": ref, "points": self.console.store.historique(ref)})
        return self._json(404, {"erreur": "introuvable"})

    def do_POST(self):
        chemin = urllib.parse.urlsplit(self.path).path
        if chemin == "/api/sonde" and not self.local:
            corps = self._corps()
            if corps is None:
                return self._json(400, {"erreur": "corps JSON attendu"})
            code, data = self.console.recevoir(corps, self._jeton(), self.client_address[0], self.connection.getsockname()[0])
            return self._json(code, data)
        if not self.local:
            return self._json(404, {"erreur": "introuvable"})
        # Réglages : depuis ce PC seulement, et pas depuis une page d'un autre
        # site (l'en-tête maison force une vérification préalable qu'on ne donne pas).
        if not self._hote_local() or self.headers.get("X-PN-Local") != "1":
            return self._json(403, {"erreur": "refusé"})
        corps = self._corps()
        if corps is None:
            return self._json(400, {"erreur": "corps JSON attendu"})
        if chemin == "/api/reglages":
            return self._json(*self.console.regler(corps))
        if chemin == "/api/oublier":
            ref = str(corps.get("reference") or "").strip().upper()
            if not REFERENCE_RE.fullmatch(ref):
                return self._json(400, {"erreur": "référence illisible"})
            self.console.store.oublier(ref)
            return self._json(200, {"ok": True})
        return self._json(404, {"erreur": "introuvable"})


class ServeurTLS(ThreadingHTTPServer):
    """La poignée de main TLS se fait dans le fil de la requête : un client lent
    ne bloque pas les autres."""

    daemon_threads = True

    def __init__(self, adresse, gestionnaire, contexte: ssl.SSLContext):
        self.contexte = contexte
        super().__init__(adresse, gestionnaire)

    def finish_request(self, request, client_address):
        request.settimeout(15)
        try:
            tls = self.contexte.wrap_socket(request, server_side=True)
        except (ssl.SSLError, OSError):
            return
        try:
            self.RequestHandlerClass(tls, client_address, self)
        finally:
            try:
                tls.close()
            except OSError:
                pass


class ServeurLocal(ThreadingHTTPServer):
    daemon_threads = True


def gestionnaire(console: Console, local: bool):
    return type("GestionnaireLocal" if local else "GestionnaireLan", (Gestionnaire,), {"console": console, "local": local})


def contexte_tls(ident: Identite) -> ssl.SSLContext:
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(str(ident.certificat), str(ident.cle))
    return ctx


def demarrer(console: Console, hote_lan: str = "0.0.0.0") -> tuple[ServeurLocal, ServeurTLS]:
    local = ServeurLocal(("127.0.0.1", console.port_local), gestionnaire(console, True))
    lan = ServeurTLS((hote_lan, console.port_https), gestionnaire(console, False), contexte_tls(console.ident))
    console.port_local = local.server_address[1]
    console.port_https = lan.server_address[1]
    for s, nom in ((local, "local"), (lan, "lan")):
        threading.Thread(target=s.serve_forever, name=nom, daemon=True).start()
    return local, lan

import hashlib
import http.client
import json
import socket
import ssl
import sys
import tempfile
import threading
import time
import unittest
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

ICI = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ICI))
sys.path.insert(0, str(ICI.parent / "worker"))

from regie import etat, identite  # noqa: E402
from regie.companion import Companion  # noqa: E402
from regie.decouverte import Annonce, reponse  # noqa: E402
from regie.serveur import Console, demarrer  # noqa: E402
from regie.store import Store  # noqa: E402


def mesure(**over):
    m = {"at": "2026-11-06T10:00:00Z", "cpu": 12.0, "ram": 40.0, "disk_free": 55.0, "gateway_ms": 1.2, "gateway_loss": 0.0,
         "internet_ms": None, "internet_loss": 100.0,
         "nics": [{"name": "Ethernet", "rx": 2_000_000, "tx": 500_000, "speed": 1e9, "ipv4": "192.168.1.21", "prefix": 24,
                   "gateway": "192.168.1.1", "dhcp": False, "profile": "Private", "wired": True, "errors": 0}]}
    m.update(over)
    return m


class IdentiteTests(unittest.TestCase):
    def test_created_once_and_kept(self):
        d = Path(tempfile.mkdtemp())
        a = identite.charger(d, "Régie test")
        b = identite.charger(d)
        self.assertEqual((a.id, a.secret, a.empreinte, a.code_page), (b.id, b.secret, b.empreinte, b.code_page))
        self.assertEqual(b.nom, "Régie test")
        self.assertRegex(a.empreinte, r"^[0-9a-f]{64}$")
        self.assertRegex(a.code_page, r"^\d{6}$")

    def test_pairing_code_is_what_the_relay_reads(self):
        from pcm import regie

        a = identite.charger(Path(tempfile.mkdtemp()))
        lu = regie.decode(a.code_appairage())
        self.assertEqual((lu["id"], lu["empreinte"], lu["secret"], lu["port"]), (a.id, a.empreinte, a.secret, 8471))
        # Le relais et la console calculent le même jeton de poste.
        self.assertEqual(regie.probe_token(a.secret, "pn09"), identite.jeton_poste(a.secret, "PN09"))
        self.assertTrue(a.verifier_poste("PN09", regie.probe_token(a.secret, "PN09")))
        self.assertFalse(a.verifier_poste("PN02", regie.probe_token(a.secret, "PN09")))


class EtatTests(unittest.TestCase):
    def test_states_and_alerts(self):
        now = 1000.0
        ok = etat.etat_poste({"reference": "PN01", "recu": now - 10, "mesure": mesure()}, now)
        self.assertEqual((ok["etat"], ok["alertes"], ok["internet"]), ("ok", [], False))
        chaud = etat.etat_poste({"reference": "PN02", "recu": now - 10, "mesure": mesure(cpu=97, gateway_loss=50,
                                 nics=[{"name": "Ethernet 2", "down": True, "wired": True}])}, now)
        self.assertEqual(chaud["etat"], "alerte")
        self.assertEqual(chaud["alertes"], ["Processeur à 97 %", "Perte de 50 % vers la passerelle", "Câble débranché sur Ethernet 2"])
        parti = etat.etat_poste({"reference": "PN03", "recu": now - 200, "mesure": mesure(cpu=99)}, now)
        self.assertEqual((parti["etat"], parti["alertes"]), ("hors_ligne", []))

    def test_networks_find_duplicates_and_gateways(self):
        now = 1000.0
        postes = [
            {"reference": "PN01", "recu": now, "mesure": mesure()},
            {"reference": "PN02", "recu": now, "mesure": mesure(nics=[{**mesure()["nics"][0], "ipv4": "192.168.1.21", "gateway": "192.168.1.254"}])},
            {"reference": "PN03", "recu": now, "mesure": mesure(nics=[{**mesure()["nics"][0], "ipv4": "10.0.0.5", "prefix": 8, "profile": "Public"}])},
        ]
        v = etat.vue(postes, now)
        self.assertEqual(v["doublons"], {"192.168.1.21": ["PN01", "PN02"]})
        g = v["reseaux"][0]
        self.assertEqual(g["reseau"], "192.168.1.0/24")
        self.assertTrue(g["conflit"])
        self.assertIn("Passerelles différentes : 192.168.1.1, 192.168.1.254", g["remarques"])
        self.assertIn("Profil Public (pare-feu strict) : PN03", v["reseaux"][1]["remarques"])

    def test_companion_variables(self):
        now = 1000.0
        v = etat.variables_companion([etat.etat_poste(p, now) for p in [
            {"reference": "PN-UK", "recu": now, "mesure": mesure()},
            {"reference": "PN09", "recu": now - 500, "mesure": mesure()},
        ]])
        self.assertEqual(v["pn_pn_uk_etat"], "OK")
        self.assertEqual(v["pn_pn_uk_texte"], "CPU 12% GW 1ms")
        self.assertEqual(v["pn_pn09_etat"], "HORS LIGNE")
        self.assertEqual((v["pn_resume"], v["pn_hors_ligne"], v["pn_etat"]), ("1/2 OK", "1", "ALERTE"))


class VmixTests(unittest.TestCase):
    def vm(self, **k):
        base = {"ok": True, "running": True, "streaming": True, "channels": [True], "recording": False, "stopped_at": None, "dropped": None, "dropped_new": None}
        return {**base, **k}

    def test_live_poste(self):
        now = 1000.0
        m = mesure(nics=[{**mesure()["nics"][0], "tx": 6_000_000}])
        m["vmix"] = self.vm(recording=True, recording_s=300)
        e = etat.etat_poste({"reference": "PN09", "recu": now, "mesure": m}, now)
        self.assertEqual((e["etat"], e["vmix"]), ("ok", "LIVE REC"))
        v = etat.variables_companion([e])
        self.assertEqual((v["pn_pn09_vmix"], v["pn_live"]), ("LIVE REC", "1"))
        self.assertTrue(v["pn_pn09_texte"].startswith("LIVE REC CPU"))

    def test_vmix_alerts(self):
        m = mesure(nics=[{**mesure()["nics"][0], "tx": 1000}])
        m["vmix"] = self.vm(channels=[True, False], dropped_new=12)
        self.assertEqual(etat.alertes_vmix(m), ["Stream vMix actif mais rien ne sort", "Destination 2 coupée", "vMix : 12 images perdues"])
        m["vmix"] = self.vm(streaming=False, channels=[False], stopped_at="2026-11-06T16:32:11Z")
        self.assertEqual(len(etat.alertes_vmix(m)), 1)
        self.assertTrue(etat.alertes_vmix(m)[0].startswith("Stream vMix arrêté à "))
        m["vmix"] = {"ok": False, "running": True}
        self.assertEqual(etat.alertes_vmix(m), ["vMix ne répond pas (Web Controller ?)"])
        self.assertEqual(etat.etiquette_vmix(m["vmix"]), "MUET")
        self.assertEqual(etat.etiquette_vmix({"ok": False, "running": False}), "FERMÉ")
        self.assertEqual(etat.etiquette_vmix(None), "")
        self.assertEqual(etat.alertes_vmix(mesure()), [])


class AdressesTests(unittest.TestCase):
    def test_lan_first_vpn_last(self):
        from regie.serveur import ordre_adresse

        vues = ["100.114.184.1", "192.168.192.1", "192.168.1.44", "10.0.0.2"]
        self.assertEqual(sorted(vues, key=ordre_adresse), ["10.0.0.2", "192.168.1.44", "192.168.192.1", "100.114.184.1"])


class StoreTests(unittest.TestCase):
    def test_keeps_last_and_history(self):
        t = [1000.0]
        s = Store(":memory:", horloge=lambda: t[0])
        s.ajouter("PN01", "DESKTOP-1", "192.168.1.21", "192.168.1.10", [mesure(cpu=10), mesure(cpu=20)])
        t[0] += 30
        s.ajouter("PN01", "DESKTOP-1", "192.168.1.21", "192.168.1.10", [mesure(cpu=30)])
        self.assertEqual(s.postes()[0]["mesure"]["cpu"], 30)
        self.assertEqual([p[1] for p in s.historique("PN01")], [10, 20, 30])
        self.assertEqual(s.historique("PN01")[0][5], 2_000_000)


def client_epingle(port, empreinte):
    """Un client qui fait comme la sonde : seule l'empreinte compte."""
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    c = http.client.HTTPSConnection("127.0.0.1", port, context=ctx, timeout=5)
    c.connect()
    vu = hashlib.sha256(c.sock.getpeercert(binary_form=True)).hexdigest()
    if vu != empreinte:
        raise AssertionError("empreinte inattendue")
    return c


class ServeurTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ident = identite.charger(Path(tempfile.mkdtemp()), "Régie test")
        cls.store = Store(":memory:")
        cls.console = Console(cls.ident, cls.store, 0, 0, 0)
        cls.local, cls.lan = demarrer(cls.console, "127.0.0.1")

    @classmethod
    def tearDownClass(cls):
        for s in (cls.local, cls.lan):
            s.shutdown()

    def envoyer(self, corps, jeton):
        c = client_epingle(self.console.port_https, self.ident.empreinte)
        c.request("POST", "/api/sonde", body=json.dumps(corps), headers={"Authorization": "Bearer " + jeton, "Content-Type": "application/json"})
        r = c.getresponse()
        return r.status, json.loads(r.read())

    def local_get(self, chemin, hote=None):
        c = http.client.HTTPConnection("127.0.0.1", self.console.port_local, timeout=5)
        c.request("GET", chemin, headers={"Host": hote or f"127.0.0.1:{self.console.port_local}"})
        r = c.getresponse()
        return r.status, r.read()

    def test_probe_with_its_token_is_recorded(self):
        code, data = self.envoyer({"reference": "pn09", "poste": "PC-PN09", "samples": [mesure()]}, identite.jeton_poste(self.ident.secret, "PN09"))
        self.assertEqual((code, data["ok"]), (200, True))
        status, body = self.local_get("/api/etat")
        d = json.loads(body)
        self.assertEqual(status, 200)
        p = [x for x in d["postes"] if x["reference"] == "PN09"][0]
        self.assertEqual((p["etat"], p["poste"]), ("ok", "PC-PN09"))
        self.assertTrue(d["console"]["appairage"].startswith("PNC1-"))
        status, body = self.local_get("/api/companion/pn_pn09_etat")
        self.assertEqual((status, body), (200, b"OK"))

    def test_wrong_token_is_refused(self):
        code, _ = self.envoyer({"reference": "PN02", "samples": [mesure()]}, identite.jeton_poste(self.ident.secret, "PN09"))
        self.assertEqual(code, 401)
        code, _ = self.envoyer({"reference": "PN02", "samples": [mesure()]}, identite.jeton_poste("autre-secret-" * 3, "PN02"))
        self.assertEqual(code, 401)

    def test_lan_needs_the_page_code(self):
        c = client_epingle(self.console.port_https, self.ident.empreinte)
        c.request("GET", "/api/etat")
        self.assertEqual(c.getresponse().status, 401)
        c = client_epingle(self.console.port_https, self.ident.empreinte)
        c.request("GET", "/api/etat", headers={"Cookie": "pn_code=" + self.ident.code_page})
        r = c.getresponse()
        d = json.loads(r.read())
        self.assertEqual(r.status, 200)
        # Le secret ne sort jamais vers un autre appareil.
        self.assertNotIn("appairage", d["console"])
        self.assertNotIn(self.ident.secret, json.dumps(d))
        c = client_epingle(self.console.port_https, self.ident.empreinte)
        c.request("GET", "/api/companion/pn_resume?jeton=" + self.ident.jeton_companion)
        self.assertEqual(c.getresponse().status, 200)
        c = client_epingle(self.console.port_https, self.ident.empreinte)
        c.request("GET", "/entrer?code=" + self.ident.code_page)
        r = c.getresponse()
        self.assertEqual(r.status, 303)
        self.assertIn("HttpOnly", r.getheader("Set-Cookie"))

    def test_local_refuses_foreign_host_and_cross_site_post(self):
        self.assertEqual(self.local_get("/api/etat", hote="pirate.example:80")[0], 421)
        c = http.client.HTTPConnection("127.0.0.1", self.console.port_local, timeout=5)
        c.request("POST", "/api/reglages", body=json.dumps({"nom": "X"}), headers={"Host": f"127.0.0.1:{self.console.port_local}", "Content-Type": "application/json"})
        self.assertEqual(c.getresponse().status, 403)
        c = http.client.HTTPConnection("127.0.0.1", self.console.port_local, timeout=5)
        c.request("POST", "/api/reglages", body=json.dumps({"companion_url": "ftp://x"}), headers={"Host": f"127.0.0.1:{self.console.port_local}", "X-PN-Local": "1"})
        self.assertEqual(c.getresponse().status, 400)

    def test_page_served(self):
        status, body = self.local_get("/")
        self.assertEqual(status, 200)
        self.assertIn(b"Console r\xc3\xa9gie", body)


class FauxCompanion(BaseHTTPRequestHandler):
    recu = []
    refus = set()

    def do_POST(self):
        FauxCompanion.recu.append(self.path)
        code = 404 if any(n in self.path for n in FauxCompanion.refus) else 200
        self.send_response(code)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *a):
        pass


class CompanionTests(unittest.TestCase):
    def test_pushes_only_changes(self):
        srv = HTTPServer(("127.0.0.1", 0), FauxCompanion)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        self.addCleanup(srv.shutdown)
        valeurs = {"pn_resume": "1/1 OK", "pn_pn09_etat": "OK"}
        t = [1000.0]
        c = Companion(lambda: f"http://127.0.0.1:{srv.server_address[1]}", lambda: dict(valeurs), horloge=lambda: t[0])
        FauxCompanion.recu = []
        c.un_passage()
        self.assertEqual(sorted(FauxCompanion.recu), ["/api/custom-variable/pn_pn09_etat/value?value=OK", "/api/custom-variable/pn_resume/value?value=1/1%20OK"])
        self.assertTrue(c.etat["ok"])
        FauxCompanion.recu = []
        valeurs["pn_pn09_etat"] = "HORS LIGNE"
        c.un_passage()
        self.assertEqual(FauxCompanion.recu, ["/api/custom-variable/pn_pn09_etat/value?value=HORS%20LIGNE"])
        FauxCompanion.refus = {"pn_resume"}
        t[0] += 400
        c.un_passage()
        self.assertFalse(c.etat["ok"])
        self.assertIn("pn_resume refusée", c.etat["erreur"])
        FauxCompanion.refus = set()

    def test_unreachable_companion_is_reported(self):
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
        s.close()
        c = Companion(lambda: f"http://127.0.0.1:{port}", lambda: {"pn_resume": "x"})
        c.un_passage()
        self.assertFalse(c.etat["ok"])
        self.assertIn("injoignable", c.etat["erreur"])


class DecouverteTests(unittest.TestCase):
    def test_answers_its_own_id_only(self):
        self.assertEqual(reponse(b"PNC1? 1a2b3c4d", "1a2b3c4d", 8471), b"PNC1 1a2b3c4d 8471")
        self.assertIsNone(reponse(b"PNC1? 99999999", "1a2b3c4d", 8471))
        self.assertIsNone(reponse(b"bonjour", "1a2b3c4d", 8471))

    def test_udp_round_trip(self):
        a = Annonce("1a2b3c4d", 8471, 0, hote="127.0.0.1")
        a.demarrer()
        self.addCleanup(a.arreter)
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(3)
        s.sendto(b"PNC1? 1a2b3c4d", ("127.0.0.1", a.port))
        data, _ = s.recvfrom(100)
        self.assertEqual(data, b"PNC1 1a2b3c4d 8471")
        s.close()


if __name__ == "__main__":
    unittest.main()

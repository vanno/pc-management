import base64
import gzip
import json
import re
import unittest

from pcm import pilot
from pcm.meshctrl import MeshError


def pilot_params(command):
    nonce = command.split("$env:PNPL_NONCE='", 1)[1].split("'", 1)[0]
    raw = command.split("$env:PNPL_PARAMS='", 1)[1].split("'", 1)[0]
    return nonce, json.loads(base64.b64decode(raw))


def pnpl_reply(nonce, **data):
    return "bruit\r\n" + pilot.MARKER + nonce + ":" + base64.b64encode(json.dumps(data).encode()).decode() + "\r\n"


def nonces():
    n = iter(range(1, 1000))
    return lambda: f"{next(n):04x}"


class FakeMesh:
    """Rejoue une suite de réponses par opération ; une exception est levée telle quelle."""

    def __init__(self, replies):
        self.replies = {k: list(v) for k, v in replies.items()}
        self.calls = []
        self.woken = []

    def run_powershell(self, device_id, command, timeout=None):
        nonce, params = pilot_params(command)
        self.calls.append((params, timeout))
        r = self.replies[params["op"]].pop(0)
        if isinstance(r, Exception):
            raise r
        return pnpl_reply(nonce, **r)

    def wake(self, device_id):
        self.woken.append(device_id)
        return "Used 2 device(s) to send wake packets"


class CommandTests(unittest.TestCase):
    def test_script_travels_compressed(self):
        cmd = pilot.build_command({"op": "etat"}, "ab12")
        self.assertLess(len(cmd), 16_000)
        packed = re.search(r"FromBase64String\('([^']+)'\)\);\$g", cmd).group(1)
        self.assertEqual(gzip.decompress(base64.b64decode(packed)).decode("utf-8"), pilot.AGENT_SCRIPT.read_text(encoding="utf-8"))
        self.assertEqual(pilot_params(cmd), ("ab12", {"op": "etat"}))
        with self.assertRaises(pilot.PilotError):
            pilot.build_command({}, "zz';")

    def test_parse_checks_nonce(self):
        with self.assertRaisesRegex(pilot.PilotError, "autre commande"):
            pilot.parse_output(pnpl_reply("cd34", ok=True), "ab12")

    def test_links(self):
        self.assertEqual(
            pilot.device_link("wss://meshcentral.pointe-noire.com", "node//Ab$c@d"),
            "https://meshcentral.pointe-noire.com/?gotonode=Ab$c@d&viewmode=10",
        )
        self.assertEqual(pilot.device_link("wss://mesh.local:4430", "node/dom/x1"), "https://mesh.local:4430/dom/?gotonode=x1&viewmode=10")
        self.assertIsNone(pilot.device_link(None, "node//x"))
        self.assertIsNone(pilot.device_link("wss://m", "node//x\"><script>"))
        self.assertEqual(pilot.mesh_target("wss://meshcentral.pointe-noire.com"), ("meshcentral.pointe-noire.com", 443))


class NetworkParamsTests(unittest.TestCase):
    def test_static_and_dhcp(self):
        n = pilot.parse_network({"interface": "Ethernet 2", "dhcp": False, "ip": "192.168.10.21", "prefixe": 24, "passerelle": "192.168.10.1", "dns": ["1.1.1.1"]})
        self.assertEqual(n, pilot.Network("Ethernet 2", False, "192.168.10.21", 24, "192.168.10.1", ("1.1.1.1",), True))
        self.assertEqual(pilot.parse_network({"interface": "Wi-Fi", "dhcp": True, "retour": False}), pilot.Network("Wi-Fi", True, rollback=False))
        self.assertIsNone(pilot.parse_network({"interface": "Ethernet", "dhcp": False, "ip": "10.0.0.5", "prefixe": 8}).gateway)

    def test_refusals(self):
        for bad in (
            {"interface": "Eth'; Remove-Item C:\\", "dhcp": True},
            {"interface": "Ethernet", "dhcp": False, "ip": "192.168.10.255", "prefixe": 24},
            {"interface": "Ethernet", "dhcp": False, "ip": "192.168.10.21", "prefixe": 24, "passerelle": "192.168.11.1"},
            {"interface": "Ethernet", "dhcp": False, "ip": "192.168.10.21", "prefixe": 31},
            {"interface": "Ethernet", "dhcp": False, "ip": "x", "prefixe": 24},
        ):
            with self.assertRaises(pilot.PilotError, msg=bad):
                pilot.parse_network(bad)


class NetworkFlowTests(unittest.TestCase):
    URL = "wss://meshcentral.pointe-noire.com"
    STATIC = {"interface": "Ethernet", "dhcp": False, "ip": "192.168.10.21", "prefixe": 24, "passerelle": "192.168.10.1"}
    BEFORE = {"interface": "Ethernet", "dhcp": True, "adresses": [{"ip": "192.168.1.40", "prefixe": 24}], "passerelle": "192.168.1.1"}

    def run_flow(self, replies, params=None):
        mesh = FakeMesh(replies)
        waits = []
        out = pilot.network(mesh, "node//pn01", params or self.STATIC, self.URL, nonces(), sleep=waits.append)
        return out, mesh, waits

    def test_applied_after_agent_comes_back(self):
        (ok, text), mesh, waits = self.run_flow({
            "reseau": [{"ok": True, "avant": self.BEFORE}],
            "reseau_resultat": [MeshError("délai dépassé"), {"ok": True, "etat": "applique", "detail": "MeshCentral joint après 12 s",
                                 "carte": {"dhcp": False, "adresses": [{"ip": "192.168.10.21", "prefixe": 24}], "passerelle": "192.168.10.1"}}],
        })
        self.assertTrue(ok)
        self.assertIn("192.168.10.21/24 sur Ethernet appliqué", text)
        self.assertIn("Avant : DHCP (192.168.1.40)", text)
        request = mesh.calls[0][0]
        self.assertEqual((request["hote"], request["port"], request["delai"], request["retour"]), ("meshcentral.pointe-noire.com", 443, 90, True))
        self.assertEqual(waits[0], pilot.NETWORK_FIRST_READ)

    def test_rollback_is_a_failure(self):
        (ok, text), _, _ = self.run_flow({
            "reseau": [{"ok": True, "avant": self.BEFORE}],
            "reseau_resultat": [{"ok": True, "etat": "retour", "detail": "MeshCentral injoignable après 90 s : configuration d'avant remise", "carte": self.BEFORE}],
        })
        self.assertFalse(ok)
        self.assertIn("non gardé", text)

    def test_refused_on_device(self):
        (ok, text), _, _ = self.run_flow({"reseau": [{"ok": False, "detail": "aucune carte réseau nommée « Ethernet »"}]})
        self.assertFalse(ok)
        self.assertIn("Changement refusé", text)

    def test_silent_device(self):
        (ok, text), mesh, waits = self.run_flow({"reseau": [{"ok": True}], "reseau_resultat": [MeshError("hors ligne")] * pilot.NETWORK_READS})
        self.assertFalse(ok)
        self.assertIn("ne répond plus", text)
        self.assertEqual(len(mesh.calls), 1 + pilot.NETWORK_READS)

    def test_invalid_params_never_reach_device(self):
        (ok, _), mesh, _ = self.run_flow({}, params={"interface": "Ethernet", "dhcp": False, "ip": "1.2.3.4", "prefixe": 40})
        self.assertFalse(ok)
        self.assertEqual(mesh.calls, [])


class FakeAvd:
    def __init__(self):
        self.calls = []

    def create_probe(self, unit_id):
        self.calls.append(("create", unit_id))
        return {"token": "pns_" + "a" * 43, "url": "https://avd.example/api/v1/postes/mesures"}

    def remove_probe(self, unit_id):
        self.calls.append(("remove", unit_id))
        return True


class SupervisionTests(unittest.TestCase):
    def test_install_sends_token_and_compressed_probe(self):
        mesh = FakeMesh({"supervision": [{"ok": True, "detail": "sonde installée : premières mesures dans la minute"}]})
        avd = FakeAvd()
        ok, text = pilot.supervision(mesh, "node//pn01", "u1", {"actif": True}, avd, nonces())
        self.assertTrue(ok)
        self.assertEqual(text, "Sonde installée : premières mesures dans la minute")
        request = mesh.calls[0][0]
        self.assertEqual((request["url"], request["jeton"]), ("https://avd.example/api/v1/postes/mesures", "pns_" + "a" * 43))
        self.assertEqual(gzip.decompress(base64.b64decode(request["script"])), pilot.PROBE_SCRIPT.read_bytes())
        self.assertEqual(avd.calls, [("create", "u1")])
        cmd = pilot.build_command(request, "ab12")
        self.assertLess(len(cmd), 24_000)

    def test_remove(self):
        mesh = FakeMesh({"supervision": [{"ok": True, "detail": "sonde retirée"}]})
        avd = FakeAvd()
        self.assertEqual(pilot.supervision(mesh, "n", "u1", {"actif": False}, avd, nonces()), (True, "Sonde retirée"))
        self.assertEqual(avd.calls, [("remove", "u1")])
        self.assertFalse(pilot.supervision(mesh, "n", "", {"actif": True}, avd, nonces())[0])


ENVOI_ID = "0f1e2d3c-4b5a-4968-8776-655443322110"
SCRIPT = "Write-Output 'Bonjour é'\nRestart-Service -Name Spooler\n"


class EnvoiAvd:
    def __init__(self, item):
        self.item = item
        self.asked = []

    def get_envoi(self, envoi_id):
        self.asked.append(envoi_id)
        if isinstance(self.item, Exception):
            raise self.item
        return self.item


def script_item(**over):
    import hashlib

    item = {"kind": "script", "name": "Relance spouleur", "content": SCRIPT, "sha256": hashlib.sha256(SCRIPT.encode("utf-8")).hexdigest(), "approved": True}
    item.update(over)
    return item


class EnvoiTests(unittest.TestCase):
    def test_approved_script_runs_with_its_digest(self):
        item = script_item()
        mesh = FakeMesh({"script": [{"ok": True, "detail": "script terminé (code 0)", "code": 0, "sortie": "Bonjour é"}]})
        ok, text = pilot.envoi(mesh, "n", {"envoi_id": ENVOI_ID, "empreinte": item["sha256"]}, EnvoiAvd(item), nonces())
        self.assertTrue(ok)
        self.assertEqual(text, "Relance spouleur : script terminé (code 0)\nSortie : Bonjour é")
        request, timeout = mesh.calls[0]
        self.assertEqual(request["empreinte"], item["sha256"])
        self.assertEqual(gzip.decompress(base64.b64decode(request["script"])).decode("utf-8"), SCRIPT)
        self.assertEqual(timeout, pilot.SCRIPT_DELAY + 60)

    def test_unapproved_or_changed_script_never_reaches_device(self):
        mesh = FakeMesh({})
        self.assertFalse(pilot.envoi(mesh, "n", {"envoi_id": ENVOI_ID}, EnvoiAvd(script_item(approved=False)), nonces())[0])
        self.assertFalse(pilot.envoi(mesh, "n", {"envoi_id": ENVOI_ID}, EnvoiAvd(script_item(sha256="0" * 64)), nonces())[0])
        ok, text = pilot.envoi(mesh, "n", {"envoi_id": ENVOI_ID, "empreinte": "1" * 64}, EnvoiAvd(script_item()), nonces())
        self.assertFalse(ok)
        self.assertIn("a changé depuis la demande", text)
        self.assertFalse(pilot.envoi(mesh, "n", {"envoi_id": "../x"}, EnvoiAvd(script_item()), nonces())[0])
        self.assertEqual(mesh.calls, [])

    def test_too_long_script_is_refused(self):
        import random

        rng = random.Random(4)
        content = "".join(rng.choice("abcdefghijklmnopqrstuvwxyz0123456789") for _ in range(30_000))
        mesh = FakeMesh({})
        import hashlib

        item = script_item(content=content, sha256=hashlib.sha256(content.encode()).hexdigest())
        ok, text = pilot.envoi(mesh, "n", {"envoi_id": ENVOI_ID}, EnvoiAvd(item), nonces())
        self.assertFalse(ok)
        self.assertIn("trop long", text)
        self.assertEqual(mesh.calls, [])

    def test_file_is_downloaded_by_the_device(self):
        item = {"kind": "file", "name": "Fond vMix", "file": "fond.png", "size": 2_000_000, "destination": "C:\\Users\\Public\\Desktop", "url": "https://stockage.example/s/fond.png?token=x"}
        mesh = FakeMesh({"fichier": [{"ok": True, "detail": "posé dans C:\\Users\\Public\\Desktop\\fond.png", "taille": 2_000_000}]})
        ok, text = pilot.envoi(mesh, "n", {"envoi_id": ENVOI_ID}, EnvoiAvd(item), nonces())
        self.assertTrue(ok)
        self.assertIn("Fond vMix : posé dans", text)
        request, timeout = mesh.calls[0]
        self.assertEqual((request["nom"], request["taille"], request["url"]), ("fond.png", 2_000_000, item["url"]))
        self.assertEqual(timeout, 602)
        self.assertFalse(pilot.envoi(FakeMesh({}), "n", {"envoi_id": ENVOI_ID}, EnvoiAvd({**item, "url": None}), nonces())[0])

    def test_avd_error_is_reported(self):
        ok, text = pilot.envoi(FakeMesh({}), "n", {"envoi_id": ENVOI_ID}, EnvoiAvd(RuntimeError("HTTP 404")), nonces())
        self.assertFalse(ok)
        self.assertIn("AVDiagram : HTTP 404", text)


class PowerTests(unittest.TestCase):
    def test_restart_and_event_refusal(self):
        mesh = FakeMesh({"alimentation": [{"ok": True, "detail": "redémarrage dans 30 secondes"}, {"ok": False, "detail": "refusé : le poste est en mode événement"}]})
        self.assertEqual(pilot.power(mesh, "n", {"mode": "redemarrer"}, nonces()), (True, "Redémarrage dans 30 secondes"))
        self.assertEqual(pilot.power(mesh, "n", {"mode": "eteindre"}, nonces()), (False, "Refusé : le poste est en mode événement"))
        self.assertEqual(mesh.calls[1][0], {"op": "alimentation", "mode": "eteindre", "force": False})

    def test_wake_and_unknown(self):
        mesh = FakeMesh({})
        ok, text = pilot.power(mesh, "node//pn02", {"mode": "reveiller"}, nonces())
        self.assertTrue(ok)
        self.assertIn("Used 2 device(s)", text)
        self.assertFalse(pilot.power(mesh, "n", {"mode": "formater"}, nonces())[0])


if __name__ == "__main__":
    unittest.main()

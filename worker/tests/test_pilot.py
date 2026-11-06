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


def pilot_script(command):
    packed = re.search(r"FromBase64String\('([^']+)'\)\);\$g", command).group(1)
    return gzip.decompress(base64.b64decode(packed)).decode("utf-8")


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
        # Comme le fond : la sonde passe à 22 100 caractères en production.
        self.assertLess(len(cmd), 18_000)
        packed = re.search(r"FromBase64String\('([^']+)'\)\);\$g", cmd).group(1)
        sent = gzip.decompress(base64.b64decode(packed)).decode("utf-8")
        self.assertEqual(sent, pilot.slim(pilot.AGENT_SCRIPT.read_text(encoding="utf-8")))
        # Commentaires vidés, lignes gardées : une erreur dit la ligne du fichier.
        self.assertEqual(sent.count("\n"), pilot.AGENT_SCRIPT.read_text(encoding="utf-8").count("\n"))
        self.assertNotIn("# --- Nettoyage", sent)
        self.assertEqual(pilot_params(cmd), ("ab12", {"op": "etat"}))
        with self.assertRaises(pilot.PilotError):
            pilot.build_command({}, "zz';")

    def test_diagnostic_script_travels_alone_under_the_same_limit(self):
        cmd = pilot.build_command({"op": "diagnostic"}, "ab12", script=pilot.DIAGNOSTIC_SCRIPT.read_text(encoding="utf-8"))
        self.assertLess(len(cmd), 16_000)

    def test_wallpaper_installer_and_script_stay_under_the_agent_limit(self):
        for installer, path, op in ((pilot.SURVEY_INSTALLER, pilot.SURVEY_SCRIPT, "releve"), (pilot.WALLPAPER_INSTALLER, pilot.WALLPAPER_SCRIPT, "fond")):
            cmd = pilot.build_command({"op": op, "actif": True, "reference": "PN-UK"}, "ab12", script=pilot.with_wallpaper(installer.read_text(encoding="utf-8"), path))
            # La sonde passe à 22 100 caractères en production : 18 000 garde de la marge.
            self.assertLess(len(cmd), 18_000, path.name)
            # Le script arrive entier dans $FondSource, devant l'installeur.
            sent = pilot_script(cmd)
            self.assertTrue(sent.startswith("$FondSource = @'\n" + path.read_text(encoding="utf-8") + "\n'@\n"), path.name)
            self.assertTrue(sent.endswith(pilot.slim(installer.read_text(encoding="utf-8"))), installer.name)

    def test_check_script_travels_alone_under_the_same_limit(self):
        body = {"op": "controle", "quoi": "evenement", "actif": True, "parties": list(pilot.EVENT_PARTS)}
        cmd = pilot.build_command(body, "ab12", script=pilot.CHECK_SCRIPT.read_text(encoding="utf-8"))
        self.assertLess(len(cmd), 16_000)

    def test_thumbnail_installer_and_script_stay_under_the_agent_limit(self):
        body = {"op": "vignette", "actif": True, "url": "https://avd.exemple/api/v1/postes/vignettes", "jeton": "pnv_" + "a" * 43, "script": pilot.pack(pilot.THUMBNAIL_SCRIPT.read_bytes())}
        cmd = pilot.build_command(body, "ab12", script=pilot.THUMBNAIL_INSTALLER.read_text(encoding="utf-8"))
        self.assertLess(len(cmd), 16_000)

    def test_slim_keeps_code_and_here_strings(self):
        text = "\n".join([
            "<#", "  en-tête", "#>", "# un commentaire", "    # indenté", "$a = 1 # reste",
            "$s = @'", "# dans la chaîne", "\"@ pas la fin", "'@", "$t = @\"", "  # aussi", "\"@", "# après",
        ])
        self.assertEqual(pilot.slim(text).split("\n"), [
            "", "", "", "", "", "$a = 1 # reste",
            "$s = @'", "# dans la chaîne", "\"@ pas la fin", "'@", "$t = @\"", "  # aussi", "\"@", "",
        ])
        for path in (pilot.AGENT_SCRIPT, pilot.CHECK_SCRIPT, pilot.WALLPAPER_INSTALLER, pilot.SURVEY_INSTALLER, pilot.THUMBNAIL_INSTALLER, pilot.DIAGNOSTIC_SCRIPT):
            text = path.read_text(encoding="utf-8")
            kept = [l for l in pilot.slim(text).split("\n") if l.strip()]
            code = [l for l in text.split("\n") if l.strip() and not l.strip().startswith("#")]
            # Seules des lignes de commentaire partent (l'en-tête <# #> compris).
            self.assertTrue(set(kept) <= set(code) | {l for l in text.split("\n") if l.strip().startswith("#")}, path.name)

    def test_parse_checks_nonce(self):
        with self.assertRaisesRegex(pilot.PilotError, "autre commande"):
            pilot.parse_output(pnpl_reply("cd34", ok=True), "ab12")

    def test_links(self):
        self.assertEqual(
            pilot.device_link("wss://meshcentral.pointe-noire.com", "node//Ab$c@d"),
            "https://meshcentral.pointe-noire.com/?gotonode=Ab$c@d&viewmode=11",
        )
        self.assertEqual(pilot.device_link("wss://mesh.local:4430", "node/dom/x1"), "https://mesh.local:4430/dom/?gotonode=x1&viewmode=11")
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
        sent = gzip.decompress(base64.b64decode(request["script"])).decode("utf-8")
        self.assertEqual(sent, pilot.slim(pilot.PROBE_SCRIPT.read_text(encoding="utf-8-sig")))
        self.assertIn("Send-Regie", sent)
        self.assertNotIn("Une panne de la console", sent)
        self.assertEqual(avd.calls, [("create", "u1")])
        cmd = pilot.build_command(request, "ab12")
        self.assertLess(len(cmd), 24_000)

    def test_probe_frees_a_stuck_meshcentral_command(self):
        # MeshCentral ne lance qu'une commande à la fois par poste : la sonde
        # ferme celle de l'agent restée ouverte plus de 90 minutes, jamais le terminal.
        probe = pilot.PROBE_SCRIPT.read_text(encoding="utf-8-sig")
        guard = probe[probe.index("Win32_Service"): probe.rindex("debloque.log")]
        self.assertIn("ParentProcessId", guard)
        self.assertIn("-noprofile -nologo -command -", guard)
        self.assertIn("AddMinutes(-90)", guard)
        self.assertLess(probe.rindex("debloque.log"), probe.index("$avant = Get-Compteurs"))

    def test_repose_does_not_switch_the_new_probe_off(self):
        # Reposer la sonde change son jeton : la mesure en cours s'arrête avant,
        # et un 401 ne coupe la tâche que si config.json garde l'ancien jeton.
        pilote = pilot.AGENT_SCRIPT.read_text(encoding="utf-8-sig")
        install = pilote[pilote.index("function Install-Sonde"): pilote.index("function Remove-Sonde")]
        self.assertLess(install.index("Stop-ScheduledTask -TaskName $tacheSonde"), install.index("Write-Utf8"))
        probe = pilot.PROBE_SCRIPT.read_text(encoding="utf-8-sig")
        self.assertIn("if ($code -eq 401 -and $jeton -eq $conf.jeton) { Disable-ScheduledTask", probe)

    def test_check_waits_for_the_first_probe_run(self):
        # PN09 et PN-UK, 06/11 : le contrôle s'arrêtait à 45 secondes, la sonde
        # tournait encore (267009, SCHED_S_TASK_RUNNING), échec à tort.
        pilote = pilot.AGENT_SCRIPT.read_text(encoding="utf-8-sig")
        probe = pilot.PROBE_SCRIPT.read_text(encoding="utf-8-sig")
        controle = pilot.CHECK_SCRIPT.read_text(encoding="utf-8")
        install = pilote[pilote.index("function Install-Sonde"): pilote.index("function Remove-Sonde")]
        premier = int(re.search(r"-Once -At \(Get-Date\)\.AddSeconds\((\d+)\)", install).group(1))
        mesure = int(re.search(r"\$debut\.AddSeconds\((\d+) \* \$k\)", probe).group(1))
        mesures = len(re.search(r"foreach \(\$k in ([\d, ]+)\)", probe).group(1).split(","))
        envoi = int(re.search(r"-TimeoutSec (\d+)", probe).group(1))
        test = controle[controle.index("function Test-Supervision"): controle.index("function Update-Historique")]
        attente = int(re.search(r"\$attente = (\d+)", test).group(1))
        self.assertGreater(attente, premier + mesure * mesures + envoi)
        self.assertLess(attente + 30, pilot.CHECK_TIMEOUT)
        self.assertLess(test.index("267009"), test.index("$info.LastTaskResult -ne 0"))

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


class CleanupTests(unittest.TestCase):
    def test_apply_and_undo(self):
        mesh = FakeMesh({"nettoyage": [
            {"ok": True, "detail": "profil appliqué : plan Performances optimales", "applications": ["Microsoft.BingNews"]},
            {"ok": False, "detail": "refusé : le poste est en mode événement"},
        ]})
        self.assertEqual(pilot.cleanup(mesh, "n", {"actif": True, "applications": True}, nonces()), (True, "Profil appliqué : plan Performances optimales"))
        self.assertEqual(mesh.calls[0], ({"op": "nettoyage", "actif": True, "applications": True}, pilot.CLEANUP_TIMEOUT))
        self.assertEqual(pilot.cleanup(mesh, "n", {"actif": False, "applications": "oui"}, nonces()), (False, "Refusé : le poste est en mode événement"))
        self.assertEqual(mesh.calls[1][0], {"op": "nettoyage", "actif": False, "applications": False})

    def test_missing_flag(self):
        self.assertFalse(pilot.cleanup(FakeMesh({}), "n", {}, nonces())[0])

    def test_agent_has_the_operation(self):
        text = pilot.AGENT_SCRIPT.read_text(encoding="utf-8")
        self.assertIn("'nettoyage'", text)
        self.assertNotIn("Set-MpPreference", text)


if __name__ == "__main__":
    unittest.main()


class CheckTests(unittest.TestCase):
    """Le contrôle : l'effet réel d'une action, relu dans Windows par agent/controle.ps1."""

    def test_verdict(self):
        ok = {"nom": "Veille", "ok": True, "constat": "jamais"}
        self.assertEqual(pilot.verdict([ok])["etat"], "verifie")
        self.assertEqual(pilot.verdict([ok, {"nom": "Notifications", "ok": False, "constat": "encore actives"}])["etat"], "pas_applique")
        flou = pilot.verdict([ok, {"nom": "Fond noir", "ok": None, "constat": "pas de réponse"}], "raison")
        self.assertEqual((flou["etat"], flou["raison"]), ("non_verifie", "raison"))
        vide = pilot.verdict([], "Aucune session ouverte.")
        self.assertEqual(vide, {"etat": "non_verifie", "points": [], "raison": "Aucune session ouverte."})
        # Une raison ne s'ajoute qu'à un contrôle non vérifié.
        self.assertNotIn("raison", pilot.verdict([ok], "raison"))

    def test_verdict_cleans_what_the_agent_sends(self):
        points = [{"nom": "  Veille  ", "ok": "oui", "constat": None}, {"nom": ""}, "texte", {"ok": True}, {"nom": "x" * 80, "ok": True, "constat": "c" * 400}]
        v = pilot.verdict(points)
        self.assertEqual(v["points"][0], {"nom": "Veille", "ok": None, "constat": ""})
        self.assertEqual((len(v["points"]), len(v["points"][1]["nom"]), len(v["points"][1]["constat"])), (2, 60, 300))
        self.assertEqual(len(pilot.verdict([{"nom": f"p{i}", "ok": True} for i in range(50)])["points"]), pilot.CHECK_POINTS)
        self.assertEqual(pilot.verdict(None)["etat"], "non_verifie")

    def test_check_sends_the_parts_to_the_check_script(self):
        mesh = FakeMesh({"controle": [{"ok": True, "points": [{"nom": "Notifications", "ok": True, "constat": "vannh : coupées, relu par Windows"}]}]})
        v = pilot.check(mesh, "n", "evenement", {"actif": True, "parties": ["notifications", "registre", "notifications"]}, nonces(), script="'x'")
        self.assertEqual(v["etat"], "verifie")
        self.assertEqual(mesh.calls[0], ({"op": "controle", "quoi": "evenement", "actif": True, "parties": ["notifications"]}, pilot.CHECK_TIMEOUT))

    def test_check_that_cannot_run_is_not_verified(self):
        mesh = FakeMesh({"controle": [MeshError("Sans réponse"), {"ok": False, "detail": "contrôle inconnu : x", "points": []}]})
        v = pilot.check(mesh, "n", "supervision", {"actif": False}, nonces(), script="'x'")
        self.assertEqual((v["etat"], v["raison"]), ("non_verifie", "Contrôle impossible : Sans réponse"))
        self.assertEqual(mesh.calls[0][0], {"op": "controle", "quoi": "supervision", "actif": False})
        v = pilot.check(mesh, "n", "supervision", {"actif": True}, nonces(), script="'x'")
        self.assertEqual(v["raison"], "Contrôle interrompu : contrôle inconnu : x")

    def test_action_not_applied_fails_with_what_is_missing(self):
        controle = pilot.verdict([{"nom": "Veille", "ok": True, "constat": "jamais"}, {"nom": "Notifications", "ok": False, "constat": "vannh : réglé, mais Windows affiche encore les notifications"}])
        ok, text, c = pilot.with_check(True, "Mode événement actif : veille coupée.", controle)
        self.assertFalse(ok)
        self.assertEqual(text, "Mode événement actif : veille coupée. Pas appliqué dans Windows. Notifications : vannh : réglé, mais Windows affiche encore les notifications")
        self.assertIs(c, controle)
        self.assertEqual(pilot.with_check(True, "Sonde retirée", pilot.verdict([]))[:2], (True, "Sonde retirée"))

    def test_wallpaper_sessions_become_the_check(self):
        mesh = FakeMesh({"releve": [{"ok": True, "detail": "relevé de l'écran posé"}], "fond": [
            {"ok": True, "detail": "fond d'état posé. Session de vannh : affiché sur 2 écran(s)", "points": [{"nom": "Session de vannh", "ok": True, "constat": "affiché sur 2 écran(s)"}]},
            {"ok": True, "detail": "fond d'état retiré. Aucun compte ouvert.", "points": []},
            {"ok": True, "detail": "pas de fond d'état sur ce poste"},
        ]})
        ok, text, controle = pilot.wallpaper(mesh, "n", "PN09", {"actif": True}, nonces(), script="'x'")
        self.assertEqual((ok, controle["etat"]), (True, "verifie"))
        # Le relevé part d'abord, seul ; le retrait n'en a pas besoin.
        self.assertEqual([c[0] for c in mesh.calls[:2]], [{"op": "releve"}, {"op": "fond", "actif": True, "reference": "PN09"}])
        ok, text, controle = pilot.wallpaper(mesh, "n", "PN09", {"actif": False}, nonces(), script="'x'")
        self.assertEqual((controle["etat"], controle["raison"]), ("non_verifie", "Aucune session ouverte sur le poste : rien à relire."))
        self.assertEqual(len(pilot.wallpaper(mesh, "n", "PN09", {"actif": False}, nonces(), script="'x'")), 2)

    def test_event_mode_screen_not_posed_is_said(self):
        mesh = FakeMesh({
            "evenement": [{"ok": True, "detail": "mode événement actif : veille coupée", "fond_a_poser": True}, {"ok": True, "detail": "mode événement déjà actif"}],
            "releve": [{"ok": True, "detail": "relevé de l'écran posé"}],
            "fond": [{"ok": False, "detail": "fond d'état pas affiché. Session de vannh : échec, accès refusé", "points": []}],
        })
        ok, text = pilot.event_mode(mesh, "n", {"actif": True}, nonces(), script="'x'", reference="PN09", wallpaper_script="'y'")
        self.assertTrue(ok)
        self.assertEqual(text, "Mode événement actif : veille coupée. État de l'écran pas posé : Fond d'état pas affiché. Session de vannh : échec, accès refusé")
        self.assertEqual(mesh.calls[2][0]["reference"], "PN09")
        # Sans `fond_a_poser`, rien d'autre ne part.
        self.assertEqual(pilot.event_mode(mesh, "n", {"actif": True}, nonces(), script="'x'"), (True, "Mode événement déjà actif"))
        self.assertEqual(len(mesh.calls), 4)

    def test_wallpaper_stops_when_the_survey_is_not_posed(self):
        mesh = FakeMesh({"releve": [{"ok": False, "detail": "accès refusé"}]})
        self.assertEqual(pilot.wallpaper(mesh, "n", "PN09", {"actif": True}, nonces(), script="'x'"), (False, "Relevé de l'écran pas posé : accès refusé"))
        self.assertEqual(len(mesh.calls), 1)

    def test_check_script_reads_what_the_pilot_writes(self):
        """controle.ps1 relit les mêmes réglages que ceux que pilote.ps1 pose."""
        pilote = pilot.AGENT_SCRIPT.read_text(encoding="utf-8")
        controle = pilot.CHECK_SCRIPT.read_text(encoding="utf-8")
        for name in ("$cleWU", "$valeursWU", "$cleAU", "$cleToast", "$cleNotif", "$cleCdm", "$cleScoobe", "$valeursConseils", "$toutesParties", "$planEleve"):
            line = re.compile(r"^" + re.escape(name) + r" = .*$", re.M)
            self.assertEqual(line.search(controle).group(0), line.search(pilote).group(0), name)
        block = re.compile(r"^\$reglagesNettoyage = @\((.*?)^\)", re.M | re.S)
        rows = lambda text: re.findall(r"@\('[^']+', '[^']+', \d\)", block.search(text).group(1))
        self.assertEqual(rows(controle), rows(pilote))
        self.assertEqual(len(rows(pilote)), 7)
        veille = re.findall(r"@\('(SUB_\w+)', '(\w+)'", controle)
        self.assertEqual(veille, re.findall(r"@\('(SUB_\w+)', '(\w+)'\)", pilote.split("$reglagesVeille = ", 1)[1].split("\n", 1)[0]))
        # Le retour à la normale garde une copie que le contrôle relit.
        self.assertIn("mode-evenement-rendu.json", pilote)
        self.assertIn("nettoyage-rendu.json", pilote)

    def test_check_script_changes_no_setting(self):
        text = pilot.CHECK_SCRIPT.read_text(encoding="utf-8")
        for verb in ("Set-ItemProperty", "New-ItemProperty", "Remove-ItemProperty", "powercfg.exe /set", "Disable-ScheduledTask", "Enable-ScheduledTask", "Stop-Service", "Set-Service", "Remove-AppxPackage"):
            self.assertNotIn(verb, text)
        # Sa seule écriture : la tâche temporaire de lecture dans les sessions, retirée aussitôt.
        self.assertEqual(text.count("Register-ScheduledTask"), 1)
        self.assertIn("Unregister-ScheduledTask -TaskName $tacheSonde", text)


class AgentScriptTests(unittest.TestCase):
    """Ce que les scripts du poste doivent tenir, faute de Windows pour les essayer ici."""

    SCRIPTS = sorted((pilot.AGENT_SCRIPT.parent).glob("*.ps1"))

    def test_lists_of_objects_are_kept_as_arrays(self):
        """Windows PowerShell 5.1 : une fonction qui rend une liste d'un seul
        [pscustomobject] le rend seul, et cet objet n'a pas de .Count (corrigé
        en PowerShell 6.1 seulement). `$x = Get-Liste` puis `$x.Count` vaut
        alors rien : PN09 avec un seul compte ouvert passait pour « aucune
        session ». Toute affectation d'une telle fonction passe par @()."""
        for path in self.SCRIPTS:
            text = path.read_text(encoding="utf-8-sig")
            lists = set()
            for m in re.finditer(r"^function ([\w-]+)[^\n]*\{\n(.*?)^\}", text, re.M | re.S):
                body = [line.strip() for line in m.group(2).splitlines() if line.strip()]
                if body and body[-1].startswith("@(") and "[pscustomobject]" in m.group(2):
                    lists.add(m.group(1))
            for m in re.finditer(r"\$\w+\s*=\s*([\w-]+)\b", text):
                self.assertNotIn(m.group(1), lists, f"{path.name} ligne {text.count(chr(10), 0, m.start()) + 1} : {m.group(0)} sans @()")

    def test_screen_says_event_mode_and_last_actions(self):
        fond = pilot.WALLPAPER_SCRIPT.read_text(encoding="utf-8")
        pilote = pilot.AGENT_SCRIPT.read_text(encoding="utf-8")
        controle = pilot.CHECK_SCRIPT.read_text(encoding="utf-8")
        releve = pilot.SURVEY_SCRIPT.read_text(encoding="utf-8")
        # Plus de fond noir muet : l'étiquette en grand, et les actions réussies ou non.
        self.assertIn("Show-Evenement $g $l $h $s $releve $ton[0].ToUpper()", fond)
        self.assertIn("Dernières actions", releve)
        # Le logo Pointe Noire en vecteurs (fond.ps1), sans lequel l'écran se dessine quand même.
        self.assertIn('$codeLogo = @"', fond)
        self.assertIn("try {\n        if (-not ('PointeNoire.Logo' -as [type]))", releve)
        self.assertIn("IP publique", releve)
        # Ce qui ne tient pas dans une colonne est compté, jamais perdu sans le dire.
        self.assertIn("sur la page « État du poste »", releve)
        self.assertIn("$coupes = @($a, $b)", releve)
        # Une colonne trop longue raccourcit sa plus longue section, pas la dernière.
        self.assertIn("$cible.vues--", releve)
        # Ce que le technicien veut voir part en dernier, et l'écran normal n'est jamais raccourci pour rien.
        self.assertIn("min = $(if ($nom -in 'Protections', 'Dernières actions') { 2 } else { 1 })", releve)
        self.assertIn("$total = -18", releve)
        self.assertNotIn("WSearch", releve)
        self.assertNotIn("à peine lisible", fond)
        self.assertIn("'Réussi' } else { 'Échec' }", fond)
        self.assertIn("historique", pilote)
        # Le contrôle fait passer en échec, à l'écran, ce que Windows n'a pas appliqué.
        self.assertIn("Update-Historique", controle)
        # Posé pour l'événement, retiré à sa fin ; pas de retrait à la main pendant.
        self.assertIn("$result.fond_a_poser = $true", pilote)
        self.assertIn("posé pour l''événement", pilote)
        self.assertIn("son écran l''indique jusqu''à la fin du mode", pilot.WALLPAPER_INSTALLER.read_text(encoding="utf-8"))
        # Essai sous Windows : pas de « Windows Update en pause jusqu'au … : normal » quand la partie est rendue.
        self.assertIn("$s.wu -and $s.actives -contains $k", fond.split("function Get-Lignes", 1)[1].split("\nfunction ", 1)[0])
        # Un échec garde à l'écran la phrase qui dit pourquoi, pas seulement la première.
        self.assertIn("pas retirées|[Rr]efusé|échec|erreur", pilote.split("function Update-Fond", 1)[1])

    def test_survey_reads_protections_in_windows(self):
        """Essai sous Windows du 2026-11-05 : la page d'un poste en mode normal
        affichait quatre « Mode événement partiel », et deux protections
        passaient au vert sans rien relire."""
        releve = pilot.SURVEY_SCRIPT.read_text(encoding="utf-8")
        pilote = pilot.AGENT_SCRIPT.read_text(encoding="utf-8")
        # Mode normal : rien de coupé n'est pas un défaut.
        self.assertIn("if (-not $actives.Count) { Add-Ligne 'Protections' 'Mode événement inactif", releve)
        # Les conseils relus sont ceux que le pilote coupe.
        pattern = r"\$valeursConseils = (@\([^)]*\))"
        self.assertEqual(re.search(pattern, releve).group(1), re.search(pattern, pilote).group(1))
        # La veille relue sur les trois réglages que le pilote met à 0.
        for reglage in ("STANDBYIDLE", "HIBERNATEIDLE", "VIDEOIDLE"):
            self.assertIn(reglage, pilote)
            self.assertIn(reglage, releve.split("function Get-Protection", 1)[1])
        # Win32_PowerPlan ne répond pas sans droit d'administrateur.
        self.assertNotIn("Win32_PowerPlan -", releve)
        self.assertIn("powercfg.exe /getactivescheme", releve)
        # Second essai : @() directement sur une List de [pscustomobject] lève
        # « Les types des arguments ne correspondent pas » sous PowerShell 5.1,
        # et l'écran n'était plus dessiné. Ces listes passent par le pipeline.
        for path in self.SCRIPTS:
            text = path.read_text(encoding="utf-8-sig")
            self.assertNotRegex(text, r"@\(\$\w+\.alertes\)", path.name)

    def test_cleanup_keeps_its_power_plan(self):
        """PN09, 2026-11-05 : « Pointe Noire production » actif au lieu du plan
        attendu. Le plan créé n'était pas gardé : le contrôle attendait
        Performances élevées, et chaque allègement en créait un de plus."""
        pilote = pilot.AGENT_SCRIPT.read_text(encoding="utf-8")
        corps = pilote.split("function Enable-Nettoyage", 1)[1].split("\nfunction ", 1)[0]
        apres = corps.split("$plan = Set-PlanProduction $etat", 1)[1]
        self.assertLess(apres.index("Write-Utf8 $fichierNettoyage"), apres.index("$result.ok"), "plan gardé avant la réponse")
        plan = pilote.split("function Set-PlanProduction", 1)[1].split("\nfunction ", 1)[0]
        # Un plan déjà là sert avant d'en créer un, et les doublons partent.
        self.assertLess(plan.index("Get-PlansProduction"), plan.index("/duplicatescheme"))
        self.assertIn("$etat.plan.cree = $guid", plan.split("/duplicatescheme", 1)[0])
        self.assertIn("ForEach-Object { & powercfg.exe /delete $_", plan.split("/setactive $guid", 1)[1])
        retour = pilote.split("function Disable-Nettoyage", 1)[1].split("\nfunction ", 1)[0]
        self.assertIn("@(Get-PlansProduction) + $etat.plan.cree", retour)
        self.assertIn("$_ -ne $etat.plan.avant", retour)
        self.assertEqual(pilote.count("'Pointe Noire production'"), 1)

    def test_cleanup_leaves_ucpd_protected_settings_to_windows(self):
        """PN09, 2026-11-05 : AllowNewsAndInterests refusé à SYSTEM, qui a
        pourtant tous les droits sur la clé parente, pilote UCPD actif."""
        pilote = pilot.AGENT_SCRIPT.read_text(encoding="utf-8")
        corps = pilote.split("function Enable-Nettoyage", 1)[1].split("\nfunction ", 1)[0]
        self.assertIn("$_.Exception -is [UnauthorizedAccessException] -and (Get-Service UCPD", corps)
        self.assertLess(corps.index("$etat.proteges += $r[1]"), corps.rindex("Write-Utf8 $fichierNettoyage"))
        controle = pilot.CHECK_SCRIPT.read_text(encoding="utf-8")
        nettoyage = controle.split("function Test-Nettoyage", 1)[1].split("\nfunction ", 1)[0]
        self.assertIn("$proteges -notcontains $r[1]", nettoyage)
        self.assertIn("Add-Point 'Réglages protégés' $true", nettoyage)

    def test_cleanup_turns_widgets_off_through_local_group_policy(self):
        """PN09, 2026-11-06 : widgets laissés à Windows par UCPD. La stratégie
        locale (Registry.pol, gpupdate) les coupe, aussi sur Windows Famille
        sans gpedit ; si Windows l'ignore, leur paquet est retiré."""
        pilote = pilot.with_policy()
        corps = pilote.split("function Enable-Nettoyage", 1)[1].split("\nfunction ", 1)[0]
        self.assertLess(corps.index("$etat.proteges += $r[1]"), corps.index("Disable-Widgets $etat ([ref]$refus)"))
        self.assertLess(corps.index("Disable-Widgets $etat"), corps.rindex("Write-Utf8 $fichierNettoyage"))
        self.assertIn("$etat.politique = @($lu.politique", corps)
        widgets = pilote.split("function Disable-Widgets", 1)[1].split("\nfunction ", 1)[0]
        self.assertLess(widgets.index("Set-PolitiqueLocale"), widgets.index("Remove-AppxPackage"), "la stratégie avant le paquet")
        politique = pilote.split("function Set-PolitiqueLocale", 1)[1].split("\nfunction ", 1)[0]
        self.assertLess(politique.index("Write-Pol"), politique.index("Update-GptIni"))
        # gpupdate lit sa réponse dans le tube : l'agent ne ferme jamais stdin.
        self.assertIn("'N' | & (Join-Path $sys 'gpupdate.exe') /target:computer /force", politique)
        self.assertIn("{35378EAC-683F-11D2-A89A-00C04FBBCFA2}{D02B1F72-3407-48AE-BA88-E8213C6761F1}", pilote)
        retour = pilote.split("function Disable-Nettoyage", 1)[1].split("\nfunction ", 1)[0]
        self.assertLess(retour.index("Set-PolitiqueLocale"), retour.index("Set-Valeur $cle $nom $q.Value"))
        self.assertIn("if ($politique -contains $nom) { continue }", retour)
        # La stratégie voyage devant pilote.ps1, pour l'allègement seulement.
        cmd = pilot.build_command({"op": "nettoyage", "actif": True}, "ab12", script=pilot.with_policy())
        self.assertLess(len(cmd), 18_000)
        self.assertIn("function Set-PolitiqueLocale", pilot_script(cmd))
        self.assertNotIn("function Set-PolitiqueLocale", pilot_script(pilot.build_command({"op": "etat"}, "ab12")))

    def test_cleanup_names_what_windows_refuses(self):
        """« Tentative d'exécution d'une opération non autorisée » sans plus :
        chaque écriture du nettoyage est gardée, et son refus nommé."""
        pilote = pilot.AGENT_SCRIPT.read_text(encoding="utf-8")
        corps = pilote.split("function Enable-Nettoyage", 1)[1].split("\nfunction ", 1)[0]
        lines = corps.splitlines()
        for i, line in enumerate(lines):
            if re.search(r"Set-Valeur|Disable-ScheduledTask|Remove-AppxPackage|Get-AppxPackage", line):
                gardee = "try {" in line or any(l.strip() == "try {" for l in lines[max(0, i - 2):i])
                self.assertTrue(gardee, line.strip())
        self.assertIn("Refusé par Windows", corps)
        # Une erreur imprévue dit sa ligne et sa commande.
        self.assertIn("pilote.ps1, ligne $($i.ScriptLineNumber)", pilote)


class PasswordTests(unittest.TestCase):
    def key(self):
        try:
            from cryptography.hazmat.primitives.asymmetric import rsa
        except ImportError:  # pragma: no cover
            self.skipTest("cryptography absent")
        k = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        pn = k.public_key().public_numbers()
        return k, {"ok": True, "n": base64.b64encode(pn.n.to_bytes(256, "big")).decode(), "e": base64.b64encode(pn.e.to_bytes(3, "big")).decode()}

    def decrypt(self, k, chiffre):
        from cryptography.hazmat.primitives import hashes
        from cryptography.hazmat.primitives.asymmetric import padding

        return k.decrypt(base64.b64decode(chiffre), padding.OAEP(mgf=padding.MGF1(hashes.SHA1()), algorithm=hashes.SHA1(), label=None)).decode("utf-8")

    def test_password_travels_encrypted_for_the_poste_key(self):
        k, cle = self.key()
        reply = {"ok": True, "detail": "mot de passe de PN 9 changé, ouverture automatique activée", "points": [{"nom": "Mot de passe", "ok": True, "constat": "PN 9 : accepté par Windows"}]}
        mesh = FakeMesh({"cle": [cle], "mot_de_passe": [reply]})
        captured = []
        real = mesh.run_powershell
        mesh.run_powershell = lambda d, c, timeout=None: (captured.append(c), real(d, c, timeout))[1]
        ok, text, controle = pilot.password(mesh, "n", {"compte": "", "auto": True, "secret_id": "x"}, "Régie-2026!", nonces())
        self.assertTrue(ok)
        self.assertEqual(text, "Mot de passe de PN 9 changé, ouverture automatique activée")
        self.assertEqual(controle["etat"], "verifie")
        body = mesh.calls[1][0]
        self.assertEqual((body["op"], body["compte"], body["auto"]), ("mot_de_passe", "", True))
        self.assertEqual(self.decrypt(k, body["chiffre"]), "Régie-2026!")
        for c in captured:
            self.assertNotIn("Régie-2026!", c)
            self.assertNotIn(base64.b64encode("Régie-2026!".encode()).decode(), c)

    def test_turning_auto_off_needs_no_password_nor_key(self):
        mesh = FakeMesh({"mot_de_passe": [{"ok": True, "detail": "ouverture automatique coupée", "points": [{"nom": "Ouverture automatique", "ok": True, "constat": "coupée"}]}]})
        ok, text, _ = pilot.password(mesh, "n", {"compte": "PN UK", "auto": False}, None, nonces())
        self.assertTrue(ok)
        self.assertEqual([c[0]["op"] for c in mesh.calls], ["mot_de_passe"])
        self.assertNotIn("chiffre", mesh.calls[0][0])

    def test_refusals(self):
        mesh = FakeMesh({})
        self.assertFalse(pilot.password(mesh, "n", {"auto": True}, None, nonces())[0])
        self.assertFalse(pilot.password(mesh, "n", {"compte": "a/b"}, "longmotdepasse", nonces())[0])
        self.assertFalse(pilot.password(mesh, "n", {}, "court", nonces())[0])
        self.assertEqual(mesh.calls, [])

    def test_pilote_never_returns_the_password(self):
        pilote = pilot.PASSWORD_SCRIPT.read_text(encoding="utf-8")
        body = pilote.split("function Set-MotDePasse", 1)[1].split("\n}\n", 1)[0]
        self.assertNotRegex(body, r"\$result\.\w+\s*=\s*\$secret")
        self.assertIn("$secret = $null", body)
        self.assertIn("Remove-ItemProperty -Path $cleWinlogon -Name DefaultPassword", body)

    def test_password_script_fits_the_command_line(self):
        cmd = pilot.build_command({"op": "mot_de_passe", "compte": "PN 9", "auto": True, "chiffre": "A" * 344}, "00ff", pilot.PASSWORD_SCRIPT.read_text(encoding="utf-8"))
        self.assertLess(len(cmd), 18_000)

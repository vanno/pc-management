import base64
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from pcm import pilot, regie

from test_pilot import FakeAvd, FakeMesh, nonces, pilot_script

SECRET = "s" * 43
EMPREINTE = "ab" * 32


def code(**over):
    data = {"v": 1, "id": "1a2b3c4d", "nom": "Régie Vannh", "empreinte": EMPREINTE, "secret": SECRET, "port": 8471, **over}
    raw = json.dumps(data, ensure_ascii=False).encode("utf-8")
    return "PNC1-" + base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


class ConfigTests(unittest.TestCase):
    def write(self, data):
        d = tempfile.mkdtemp()
        p = Path(d) / "consoles.json"
        p.write_text(json.dumps(data) if not isinstance(data, str) else data, encoding="utf-8")
        return p

    def test_missing_file_means_no_console(self):
        self.assertEqual(regie.load(Path(tempfile.mkdtemp()) / "absent.json"), [])

    def test_reads_codes_and_fallback_address(self):
        p = self.write({"consoles": [{"code": code(), "adresse": "192.168.1.20"}, code(id="99999999")]})
        c = regie.load(p)
        self.assertEqual([x["id"] for x in c], ["1a2b3c4d", "99999999"])
        self.assertEqual((c[0]["adresse"], c[1]["adresse"], c[0]["port"], c[0]["nom"]), ("192.168.1.20", None, 8471, "Régie Vannh"))

    def test_refuses_what_it_cannot_read(self):
        for bad in ("{", {"consoles": [{"code": "PNC2-x"}]}, {"consoles": [{"code": code(empreinte="zz")}]},
                    {"consoles": [{"code": code(), "adresse": "regie.local"}]}, {"consoles": [{"code": code(secret="court")}]}, {"autre": []}):
            with self.assertRaises(regie.ConsoleError, msg=bad):
                regie.load(self.write(bad))

    def test_probe_gets_its_own_token_and_never_the_secret(self):
        c = regie.load(self.write({"consoles": [code()]}))
        a = regie.for_probe(c, "pn09")[0]
        b = regie.for_probe(c, "PN02")[0]
        self.assertNotIn("secret", a)
        self.assertNotIn(SECRET, json.dumps(a))
        self.assertEqual(a["jeton"], regie.probe_token(SECRET, "PN09"))
        self.assertNotEqual(a["jeton"], b["jeton"])
        self.assertRegex(a["jeton"], r"^pnr_[A-Za-z0-9_-]{40,60}$")


class SupervisionConsoleTests(unittest.TestCase):
    def setUp(self):
        d = tempfile.mkdtemp()
        self.path = Path(d) / "consoles.json"
        env = mock.patch.dict(os.environ, {"PCM_CONSOLES": str(self.path)})
        env.start()
        self.addCleanup(env.stop)

    def install(self, replies, reference="PN09"):
        mesh = FakeMesh(replies)
        scripts = []
        run = mesh.run_powershell

        def spy(device_id, command, timeout=None):
            scripts.append(pilot_script(command))
            return run(device_id, command, timeout)

        mesh.run_powershell = spy
        out = pilot.supervision(mesh, "node//pn09", "u1", {"actif": True}, FakeAvd(), nonces(), reference=reference)
        return out, mesh, scripts

    def test_without_console_nothing_changes(self):
        (ok, text), mesh, _ = self.install({"supervision": [{"ok": True, "detail": "sonde installée"}]})
        self.assertEqual((ok, text), (True, "Sonde installée"))
        self.assertEqual(len(mesh.calls), 1)

    def test_console_posed_after_the_probe(self):
        self.path.write_text(json.dumps({"consoles": [{"code": code(), "adresse": "192.168.1.20"}]}), encoding="utf-8")
        (ok, text), mesh, scripts = self.install({
            "supervision": [{"ok": True, "detail": "sonde installée"}],
            "console": [{"ok": True, "detail": "console régie posée : Régie Vannh"}],
        })
        self.assertTrue(ok)
        self.assertEqual(text, "Sonde installée. Console régie posée : Régie Vannh")
        body = mesh.calls[1][0]
        self.assertEqual((body["op"], body["actif"], body["reference"]), ("console", True, "PN09"))
        self.assertEqual(body["consoles"][0]["jeton"], regie.probe_token(SECRET, "PN09"))
        self.assertEqual(body["consoles"][0]["adresse"], "192.168.1.20")
        # console.ps1 voyage dans $RegieSource, en tête de console-pose.ps1.
        self.assertTrue(scripts[1].startswith("$RegieSource = @'\n"))
        self.assertIn("PointeNoire.Regie", scripts[1])
        self.assertIn("ServerCertificateValidationCallback", scripts[1])

    def test_console_failure_keeps_the_probe(self):
        self.path.write_text(json.dumps({"consoles": [code()]}), encoding="utf-8")
        (ok, text), _, _ = self.install({
            "supervision": [{"ok": True, "detail": "sonde installée"}],
            "console": [{"ok": False, "detail": "la sonde n'est pas installée sur ce poste"}],
        })
        self.assertTrue(ok)
        self.assertIn("Console régie pas posée : la sonde n'est pas installée", text)

    def test_unreadable_config_stops_before_touching_the_device(self):
        self.path.write_text("{", encoding="utf-8")
        (ok, text), mesh, _ = self.install({})
        self.assertFalse(ok)
        self.assertIn("Console régie", text)
        self.assertEqual(mesh.calls, [])

    def test_config_change_reposes_the_probe(self):
        before = pilot.posed_versions()["supervision"]
        self.path.write_text(json.dumps({"consoles": [code()]}), encoding="utf-8")
        self.assertNotEqual(pilot.posed_versions()["supervision"], before)

    def test_command_fits(self):
        consoles = regie.for_probe([{**regie.decode(code()), "adresse": "192.168.1.20"}] * 4, "PN-UK")
        cmd = pilot.build_command({"op": "console", "actif": True, "reference": "PN-UK", "consoles": consoles}, "ab12",
                                  pilot.with_source(pilot.CONSOLE_INSTALLER.read_text(encoding="utf-8"), pilot.CONSOLE_SCRIPT, "RegieSource"))
        self.assertLess(len(cmd), pilot.MAX_COMMAND)


class ProbeScriptTests(unittest.TestCase):
    def test_install_clears_an_old_console_and_probe_calls_it(self):
        pilote = pilot.AGENT_SCRIPT.read_text(encoding="utf-8-sig")
        install = pilote[pilote.index("function Install-Sonde"): pilote.index("function Remove-Sonde")]
        self.assertIn("'console.json'", install)
        probe = pilot.PROBE_SCRIPT.read_text(encoding="utf-8-sig")
        # Après la première mesure, et après la seconde une fois les câbles coupés ajoutés.
        self.assertLess(probe.index("if ($k -eq 1) { Send-Regie $m }"), probe.index("$coupes = Get-LiensCoupes"))
        self.assertLess(probe.index("$coupes = Get-LiensCoupes"), probe.index("Send-Regie $mesures[$mesures.Count - 1]"))
        self.assertLess(probe.index("Send-Regie $mesures[$mesures.Count - 1]"), probe.index("Invoke-RestMethod"))

    def test_console_script_travels_in_a_single_quoted_here_string(self):
        src = pilot.CONSOLE_SCRIPT.read_text(encoding="utf-8")
        cs = src[src.index('$codeRegie = @"'): src.index('\n"@')]
        # Aucune variable PowerShell dans le C# d'une chaîne @" "@.
        self.assertNotIn("$", cs.split("\n", 1)[1])
        self.assertNotIn("`", cs)

    def test_console_script_code_is_ascii(self):
        # Posé sans BOM, il est lu en ANSI par Windows PowerShell 5.1 : un
        # « é » hors commentaire ne vaudrait plus ce qu'il vaut (essai du 06/11).
        for n, line in enumerate(pilot.CONSOLE_SCRIPT.read_text(encoding="utf-8").splitlines(), 1):
            code = line.split("//")[0].split("#")[0] if not line.lstrip().startswith(("#", "//")) else ""
            self.assertTrue(code.isascii(), f"console.ps1 ligne {n} : {line}")


if __name__ == "__main__":
    unittest.main()

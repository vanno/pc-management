import base64
import json
import tempfile
import unittest
from pathlib import Path

from pcm import software as sw

EXAMPLE = Path(__file__).resolve().parents[2] / "config" / "logiciels.example.json"


def winget_output(nonce: str, **reply) -> str:
    payload = base64.b64encode(json.dumps(reply).encode()).decode()
    return f"bruit\r\nPNWG1:{nonce}:{payload}\r\n"


class ProfileTests(unittest.TestCase):
    def test_example_profile_is_valid(self):
        packages = sw.load_profile(EXAMPLE)
        ids = [p.id for p in packages]
        self.assertIn("Bitfocus.Companion", ids)
        self.assertIn("Microsoft.Office", ids)
        self.assertNotIn("Apple.QuickTime", ids)
        self.assertEqual(len(ids), len(set(ids)))

    def test_missing_bad_and_duplicate(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "logiciels.json"
            with self.assertRaisesRegex(sw.SoftwareError, "absent"):
                sw.load_profile(path)
            path.write_text(json.dumps({"logiciels": [{"id": "VideoLAN.VLC"}, {"id": "videolan.vlc"}, "Zoom.Zoom"]}))
            self.assertEqual([p.id for p in sw.load_profile(path)], ["VideoLAN.VLC", "Zoom.Zoom"])
            path.write_text(json.dumps({"logiciels": [{"id": "VLC; Remove-Item C:\\"}]}))
            with self.assertRaisesRegex(sw.SoftwareError, "illisible"):
                sw.load_profile(path)


class CommandTests(unittest.TestCase):
    def test_command_carries_id_and_nonce(self):
        cmd = sw.build_command("VideoLAN.VLC", "ab12")
        self.assertIn("$env:PNWG_ID='VideoLAN.VLC'", cmd)
        self.assertIn("$env:PNWG_NONCE='ab12'", cmd)
        self.assertLess(len(cmd), 24_000)

    def test_command_refuses_injection(self):
        with self.assertRaises(sw.SoftwareError):
            sw.build_command("VLC';Remove-Item", "ab12")
        with self.assertRaises(sw.SoftwareError):
            sw.build_command("VideoLAN.VLC", "zz")

    def test_parse_checks_nonce(self):
        out = winget_output("ab12", id="VideoLAN.VLC", step="install", code=0)
        self.assertEqual(sw.parse_output(out, "ab12")["code"], 0)
        with self.assertRaisesRegex(sw.SoftwareError, "autre commande"):
            sw.parse_output(out, "cd34")
        with self.assertRaisesRegex(sw.SoftwareError, "Aucune réponse"):
            sw.parse_output("Accès refusé", "ab12")


class ClassifyTests(unittest.TestCase):
    P = sw.Package("Zoom.Zoom", "Zoom")

    def state(self, **reply):
        return sw.classify(self.P, reply)

    def test_codes(self):
        self.assertEqual(self.state(step="install", code=0).state, "installed")
        self.assertEqual(self.state(step="upgrade", code=0).state, "updated")
        self.assertEqual(self.state(step="upgrade", code=sw.UPDATE_NOT_APPLICABLE).state, "uptodate")
        self.assertEqual(self.state(step="install", code=sw.REBOOT_TO_FINISH).state, "reboot")
        used = self.state(step="upgrade", code=sw.PACKAGE_IN_USE_BY_APPLICATION)
        self.assertEqual(used.state, "failed")
        self.assertIn("ouvert", used.detail)
        other = self.state(step="install", code=-2147024891, output="Accès refusé")
        self.assertEqual(other.state, "failed")
        self.assertIn("0x80070005", other.detail)

    def test_summary(self):
        outcomes = [
            sw.Outcome(sw.Package("A", "A"), "installed"),
            sw.Outcome(sw.Package("B", "B"), "installed"),
            sw.Outcome(sw.Package("C", "C"), "uptodate"),
            sw.Outcome(sw.Package("Microsoft.Office", "Microsoft 365"), "reboot", "redémarrage demandé"),
            sw.Outcome(sw.Package("Zoom.Zoom", "Zoom"), "failed", "logiciel ouvert"),
        ]
        self.assertEqual(
            sw.summary(outcomes),
            "5 logiciels : 2 installés, 1 à jour, 1 redémarrage demandé, 1 en échec. "
            "Redémarrage demandé : Microsoft 365. En échec : Zoom (logiciel ouvert)",
        )


if __name__ == "__main__":
    unittest.main()

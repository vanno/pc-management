import base64
import json
import unittest
from pathlib import Path

from pcm import inventory as inv
from pcm.avdiagram import Unit, plan_update
from pcm.meshctrl import parse_device

FIXTURE = json.loads((Path(__file__).parent / "fixtures" / "pn01.json").read_text(encoding="utf-8"))


def agent_output(data: dict, noise: str = "", nonce: str = "") -> str:
    payload = base64.b64encode(json.dumps(data, ensure_ascii=False).encode("utf-8")).decode()
    return f"{noise}\r\nPNINV1:{nonce}:{payload}\r\n"


class ParseTests(unittest.TestCase):
    def test_parse_with_noise_and_single_objects(self):
        data = inv.parse_output(agent_output(FIXTURE, noise="AVERTISSEMENT : quelque chose"))
        self.assertEqual(len(data["cpus"]), 1)
        self.assertEqual(len(data["disks"]), 1)
        self.assertEqual(data["network"][0]["ipv4"], ["192.168.1.21"])

    def test_accents_survive(self):
        data = dict(FIXTURE, software=[{"name": "Logiciel édité à Paris", "version": "1"}])
        self.assertEqual(inv.parse_output(agent_output(data))["software"][0]["name"], "Logiciel édité à Paris")

    def test_nonce_checked(self):
        self.assertEqual(inv.parse_output(agent_output(FIXTURE, nonce="ab12"), "ab12")["system"]["hostname"], "PN01")

    def test_other_command_reply_rejected(self):
        with self.assertRaisesRegex(inv.InventoryError, "autre commande"):
            inv.parse_output(agent_output(FIXTURE, nonce="ab12"), "cd34")

    def test_missing_marker(self):
        with self.assertRaises(inv.InventoryError):
            inv.parse_output("Accès refusé")

    def test_wrong_schema(self):
        with self.assertRaises(inv.InventoryError):
            inv.parse_output(agent_output(dict(FIXTURE, schema=99)))


class SummaryTests(unittest.TestCase):
    def setUp(self):
        self.data = inv.parse_output(agent_output(FIXTURE))

    def test_summary(self):
        s = inv.summary(self.data)
        self.assertEqual(s["serial_number"], "PF3ABCDE")
        self.assertEqual(s["ip_address"], "192.168.1.21")
        self.assertEqual(s["firmware"], "Windows 11 Professionnel 23H2 (22631.4460)")
        self.assertEqual(s["ram_gb"], 16)
        self.assertFalse(s["home_edition"])

    def test_home_edition(self):
        data = inv.parse_output(agent_output(dict(FIXTURE, windows=dict(FIXTURE["windows"], edition_id="Core"))))
        self.assertTrue(inv.summary(data)["home_edition"])

    def test_ip_ignores_link_local(self):
        net = [dict(FIXTURE["network"][1])]
        data = inv.parse_output(agent_output(dict(FIXTURE, network=net)))
        self.assertIsNone(inv.primary_ipv4(data))


class DiffTests(unittest.TestCase):
    def test_diff(self):
        before = inv.parse_output(agent_output(FIXTURE))
        sw = [{"name": "vMix", "version": "28.0.0.42"}, {"name": "OBS Studio", "version": "30.1.2"}, {"name": "NDI Tools", "version": "6"}]
        after = inv.parse_output(agent_output(dict(FIXTURE, software=sw)))
        d = inv.diff(before, after)
        self.assertEqual(d.added, ["NDI Tools 6"])
        self.assertEqual(d.removed, ["Bitfocus Companion 3.2.2"])
        self.assertEqual(d.updated, ["vMix 27.0.0.49 -> 28.0.0.42"])
        self.assertEqual(d.hardware, [])

    def test_first_snapshot_has_no_diff(self):
        self.assertTrue(inv.diff(None, inv.parse_output(agent_output(FIXTURE))).empty)


class MappingTests(unittest.TestCase):
    def test_asset_tag(self):
        self.assertEqual(inv.asset_tag_for("pn01"), "PN01")
        self.assertEqual(inv.asset_tag_for("DESKTOP-8F3K2", {"desktop-8f3k2": "PN07"}), "PN07")


class PlanUpdateTests(unittest.TestCase):
    summ = {"serial_number": "PF3ABCDE", "firmware": "Windows 11 Pro 23H2 (22631.4460)", "ip_address": "192.168.1.21"}

    def test_fills_empty_serial(self):
        changes, warnings = plan_update(Unit("PN01", None, None, None), self.summ)
        self.assertEqual(changes, {"serial_number": "PF3ABCDE", "firmware": "Windows 11 Pro 23H2 (22631.4460)"})
        self.assertEqual(warnings, [])

    def test_never_overwrites_other_serial(self):
        changes, warnings = plan_update(Unit("PN01", "XYZ999", None, None), self.summ)
        self.assertNotIn("serial_number", changes)
        self.assertEqual(len(warnings), 1)

    def test_ip_only_on_request(self):
        changes, _ = plan_update(Unit("PN01", "PF3ABCDE", None, "Windows 11 Pro 23H2 (22631.4460)"), self.summ, push_ip=True)
        self.assertEqual(changes, {"ip_address": "192.168.1.21"})


class CommandTests(unittest.TestCase):
    def test_real_script_fits_command_line(self):
        command = inv.build_command(nonce="0123456789abcdef")
        self.assertLess(len(command), inv.MAX_COMMAND_LENGTH)
        self.assertTrue(command.startswith("$env:PNINV_NONCE='0123456789abcdef';"))
        encoded = command.split("'")[3]
        self.assertIn("$env:PNINV_NONCE", base64.b64decode(encoded).decode("utf-8"))

    def test_nonce_must_be_hex(self):
        with self.assertRaises(inv.InventoryError):
            inv.build_command(nonce="x';Remove-Item")


class DeviceTests(unittest.TestCase):
    def test_parse_device(self):
        d = parse_device({"_id": "node//abc", "name": "PN01", "conn": 1, "osdesc": "Microsoft Windows 11 Pro", "groupname": "Parc"})
        self.assertTrue(d.online and d.is_windows)
        self.assertFalse(parse_device({"_id": "node//x", "name": "NAS", "conn": 0}).online)


if __name__ == "__main__":
    unittest.main()


class AvdPayloadTests(unittest.TestCase):
    def test_payload_shape(self):
        data = inv.parse_output(agent_output(FIXTURE))
        p = inv.avd_payload(data)
        self.assertEqual(p["source"], "pc-management")
        self.assertEqual(p["collected_at"], FIXTURE["collected_at"])
        h = p["hardware"]
        self.assertEqual(h["hostname"], "PN01")
        self.assertEqual(h["os_edition"], "Professional")
        self.assertEqual(h["ram_gb"], 15.9)
        self.assertEqual(h["disks"][0], {"model": "SAMSUNG MZVLB1T0", "size_gb": 953.9, "bus": "SCSI"})
        self.assertEqual(h["network"][0]["ipv4"], ["192.168.1.21"])
        self.assertEqual(h["battery_health_pct"], 80.0)
        self.assertEqual(p["software"][0], {"name": "vMix", "version": "27.0.0.49", "publisher": "StudioCoast Pty Ltd"})
        self.assertNotIn("changes", p)

    def test_changes_only_when_something_changed(self):
        data = inv.parse_output(agent_output(FIXTURE))
        self.assertNotIn("changes", inv.avd_payload(data, inv.Diff()))
        p = inv.avd_payload(data, inv.Diff(added=["OBS 31"]))
        self.assertEqual(p["changes"], {"added": ["OBS 31"], "removed": [], "updated": [], "hardware": []})

    def test_payload_drops_control_characters(self):
        data = inv.parse_output(agent_output(dict(FIXTURE, software=[{"name": "Pilote audio\u0000", "version": "1.0\u0000", "publisher": "Realtek\x1f"}])))
        sw = inv.avd_payload(data)["software"][0]
        self.assertEqual(sw, {"name": "Pilote audio", "version": "1.0", "publisher": "Realtek"})
        self.assertNotIn("\\u0000", json.dumps(inv.avd_payload(data)))

    def test_payload_is_json(self):
        data = inv.parse_output(agent_output(FIXTURE))
        json.dumps(inv.avd_payload(data))

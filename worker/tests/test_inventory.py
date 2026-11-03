import base64
import json
import unittest
from pathlib import Path

from pcm import inventory as inv
from pcm.avdiagram import Unit, plan_update
from pcm.meshctrl import parse_device

FIXTURE = json.loads((Path(__file__).parent / "fixtures" / "pn01.json").read_text(encoding="utf-8"))


def agent_output(data: dict, noise: str = "") -> str:
    payload = base64.b64encode(json.dumps(data, ensure_ascii=False).encode("utf-8")).decode()
    return f"{noise}\r\nPNINV1:{payload}\r\n"


class ParseTests(unittest.TestCase):
    def test_parse_with_noise_and_single_objects(self):
        data = inv.parse_output(agent_output(FIXTURE, noise="AVERTISSEMENT : quelque chose"))
        self.assertEqual(len(data["cpus"]), 1)
        self.assertEqual(len(data["disks"]), 1)
        self.assertEqual(data["network"][0]["ipv4"], ["192.168.1.21"])

    def test_accents_survive(self):
        data = dict(FIXTURE, software=[{"name": "Logiciel édité à Paris", "version": "1"}])
        self.assertEqual(inv.parse_output(agent_output(data))["software"][0]["name"], "Logiciel édité à Paris")

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
        command = inv.build_command()
        self.assertLess(len(command), inv.MAX_COMMAND_LENGTH)
        encoded = command.split("'")[1]
        self.assertIn("PNINV1:", base64.b64decode(encoded).decode("utf-8"))


class DeviceTests(unittest.TestCase):
    def test_parse_device(self):
        d = parse_device({"_id": "node//abc", "name": "PN01", "conn": 1, "osdesc": "Microsoft Windows 11 Pro", "groupname": "Parc"})
        self.assertTrue(d.online and d.is_windows)
        self.assertFalse(parse_device({"_id": "node//x", "name": "NAS", "conn": 0}).online)


if __name__ == "__main__":
    unittest.main()

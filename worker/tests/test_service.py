import json
import signal
import tempfile
import threading
import unittest
from pathlib import Path

from pcm.avdiagram import AvdError, Unit
from pcm.meshctrl import Device, MeshError
from pcm.service import Service, serve
from pcm.store import Store

from pcm import software as sw
from test_inventory import FIXTURE, agent_output
from test_software import winget_output
from test_installers import params_of, reply as pnin_reply


class FakeMesh:
    def __init__(self, devices, fail=None):
        self.devices = devices
        self.fail = fail
        self.commands = []
        self.packages = []
        self.winget_codes = {}

    def list_devices(self, group=None):
        if self.fail:
            raise MeshError(self.fail)
        return self.devices

    def upload(self, device_id, local_path, remote_dir, timeout=None):
        self.packages.append(("upload", Path(local_path).name))

    def run_powershell(self, device_id, command, timeout=None):
        self.commands.append(device_id)
        if "$env:PNIN_NONCE='" in command:
            nonce = command.split("$env:PNIN_NONCE='", 1)[1].split("'", 1)[0]
            mode = params_of(command)["mode"]
            self.packages.append((mode, None))
            return pnin_reply(nonce, found=False, free=10**12) if mode == "check" else pnin_reply(nonce, code=3010)
        if "$env:PNWG_NONCE='" in command:
            nonce = command.split("$env:PNWG_NONCE='", 1)[1].split("'", 1)[0]
            pkg = command.split("$env:PNWG_ID='", 1)[1].split("'", 1)[0]
            self.packages.append((pkg, timeout))
            code = self.winget_codes.get(pkg, 0)
            return winget_output(nonce, id=pkg, step="install", code=code)
        nonce = command.split("$env:PNINV_NONCE='", 1)[1].split("'", 1)[0]
        return agent_output(FIXTURE, nonce=nonce)


class FakeAvd:
    def __init__(self, tasks=(), units=None, inventory_error=None, expired=False):
        self.queue = list(tasks)
        self.units = units if units is not None else {"PN01": Unit("PN01", None, None, None)}
        self.inventory_error = inventory_error
        self.expired = expired
        self.heartbeats = []
        self.finished = []
        self.inventories = []
        self.updates = []

    def heartbeat(self, source, devices, limit):
        self.heartbeats.append({"source": source, "devices": devices, "limit": limit})
        taken, self.queue = self.queue[:limit], self.queue[limit:]
        return taken

    def finish_task(self, task_id, ok, result):
        self.finished.append((task_id, ok, result))
        return not self.expired

    def computers(self):
        return self.units

    def update_unit(self, asset_tag, **fields):
        self.updates.append((asset_tag, fields))

    def set_inventory(self, asset_tag, payload):
        if self.inventory_error:
            raise AvdError(self.inventory_error)
        json.dumps(payload)
        self.inventories.append(asset_tag)


PN01 = Device("node//pn01", "PN01", "Régie", True, "Windows 11 Pro")
PN02 = Device("node//pn02", "pn2", "Régie", False, "Windows 10 Famille")
MAC = Device("node//mac", "MAC01", "Régie", True, "macOS 14")


def task(tag="PN01", action="inventaire", id="t1"):
    return {"id": id, "unit_id": "u1", "asset_tag": tag, "action": action, "params": {}}


class ServiceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = Store(Path(self.tmp.name) / "pcm.sqlite")
        self.logs = []

    def tearDown(self):
        self.store.db.close()
        self.tmp.cleanup()

    def service(self, mesh, avd, mapping=None, **kw):
        return Service(mesh, avd, self.store, mapping or {}, logger=self.logs.append, **kw)

    def profile(self, ids):
        path = Path(self.tmp.name) / "logiciels.json"
        path.write_text(json.dumps({"logiciels": [{"id": i, "nom": i.split(".")[-1]} for i in ids]}))
        return str(path)

    def test_software_task_installs_profile_then_inventories(self):
        avd = FakeAvd([task(action="logiciels")])
        mesh = FakeMesh([PN01])
        mesh.winget_codes = {"Zoom.Zoom": sw.PACKAGE_IN_USE_BY_APPLICATION}
        svc = self.service(mesh, avd, profile_path=self.profile(["VideoLAN.VLC", "Zoom.Zoom"]))
        self.assertEqual(svc.tick(), 1)
        self.assertEqual(mesh.packages, [("VideoLAN.VLC", sw.PACKAGE_TIMEOUT), ("Zoom.Zoom", sw.PACKAGE_TIMEOUT)])
        self.assertEqual(avd.inventories, ["PN01"])
        (_, ok, result), = avd.finished
        self.assertFalse(ok)
        self.assertIn("2 logiciels : 1 installé, 1 en échec", result)
        self.assertIn("Zoom (logiciel ouvert", result)
        self.assertIn("Fiche à jour", result)

    def test_software_task_runs_nas_installers_after_winget(self):
        folder = Path(self.tmp.name) / "installeurs"
        folder.mkdir()
        (folder / "vmix29.exe").write_bytes(b"x")
        cfg = Path(self.tmp.name) / "installeurs.json"
        cfg.write_text(json.dumps({"installeurs": [{"nom": "vMix", "fichier": "vmix29.exe", "detection": "vMix*"}]}))
        avd = FakeAvd([task(action="logiciels")])
        mesh = FakeMesh([PN01])
        svc = self.service(mesh, avd, profile_path=self.profile(["VideoLAN.VLC"]), installers_path=str(cfg), installers_dir=str(folder))
        svc.tick()
        self.assertEqual([p[0] for p in mesh.packages], ["VideoLAN.VLC", "check", "upload", "install"])
        (_, ok, result), = avd.finished
        self.assertTrue(ok)
        self.assertIn("2 logiciels : 1 installé, 1 redémarrage demandé. Redémarrage demandé : vMix", result)

    def test_installers_alone_work_without_winget_profile(self):
        folder = Path(self.tmp.name) / "installeurs"
        folder.mkdir()
        (folder / "a.msi").write_bytes(b"x")
        cfg = Path(self.tmp.name) / "installeurs.json"
        cfg.write_text(json.dumps([{"nom": "ATEM", "fichier": "a.msi", "detection": "Blackmagic ATEM*"}]))
        avd = FakeAvd([task(action="logiciels")])
        mesh = FakeMesh([PN01])
        self.service(mesh, avd, profile_path=str(Path(self.tmp.name) / "absent.json"), installers_path=str(cfg), installers_dir=str(folder)).tick()
        (_, ok, result), = avd.finished
        self.assertTrue(ok)
        self.assertIn("1 logiciel : 1 redémarrage demandé", result)

    def test_software_task_without_profile_fails_clearly(self):
        avd = FakeAvd([task(action="logiciels")])
        mesh = FakeMesh([PN01])
        self.service(mesh, avd, profile_path=str(Path(self.tmp.name) / "absent.json")).tick()
        (_, ok, result), = avd.finished
        self.assertFalse(ok)
        self.assertIn("Profil de logiciels absent", result)
        self.assertEqual(mesh.commands, [])

    def test_heartbeat_continues_during_a_long_task(self):
        avd = FakeAvd([task(action="logiciels")])
        mesh = FakeMesh([PN01])
        svc = self.service(mesh, avd, profile_path=self.profile(["VideoLAN.VLC"]), pulse_interval=0.01)
        original = mesh.run_powershell

        def slow(*a, **kw):
            threading.Event().wait(0.1)
            return original(*a, **kw)

        mesh.run_powershell = slow
        svc.tick()
        pulses = [b for b in avd.heartbeats if b["limit"] == 0]
        self.assertGreater(len(pulses), 2)
        self.assertEqual(pulses[0]["devices"][0]["asset_tag"], "PN01")

    def test_heartbeat_reports_windows_devices_with_asset_tags(self):
        avd = FakeAvd()
        handled = self.service(FakeMesh([PN01, PN02, MAC]), avd, {"PN2": "PN02"}).tick()
        self.assertEqual(handled, 0)
        beat = avd.heartbeats[0]
        self.assertEqual(beat["limit"], 1)
        self.assertEqual(
            beat["devices"],
            [
                {"name": "PN01", "asset_tag": "PN01", "online": True, "os": "Windows 11 Pro"},
                {"name": "pn2", "asset_tag": "PN02", "online": False, "os": "Windows 10 Famille"},
            ],
        )

    def test_inventory_task_pushes_and_reports(self):
        avd = FakeAvd([task()])
        mesh = FakeMesh([PN01])
        self.assertEqual(self.service(mesh, avd).tick(), 1)
        self.assertEqual(mesh.commands, ["node//pn01"])
        self.assertEqual(avd.inventories, ["PN01"])
        (task_id, ok, result), = avd.finished
        self.assertEqual(task_id, "t1")
        self.assertTrue(ok, result)
        self.assertIn("logiciels", result)
        self.assertIn("fiche à jour", result)
        self.assertIsNotNone(self.store.latest("PN01"))

    def test_offline_unknown_and_unsupported_tasks_fail_with_a_reason(self):
        cases = [
            (task("PN02"), "hors ligne"),
            (task("PN99"), "aucun agent nommé PN99"),
            (task(action="debloat"), "Action inconnue"),
            (task("PN02", action="logiciels"), "hors ligne"),
            (task(tag=None), "n'existe plus"),
        ]
        for t, expected in cases:
            avd = FakeAvd([t])
            mesh = FakeMesh([PN01, PN02])
            self.service(mesh, avd, {"PN2": "PN02"}).tick()
            (_, ok, result), = avd.finished
            self.assertFalse(ok)
            self.assertIn(expected, result)
            self.assertEqual(mesh.commands, [])

    def test_inventory_not_posted_is_a_failure(self):
        avd = FakeAvd([task()], inventory_error="HTTP 503 : migration 0069")
        self.service(FakeMesh([PN01]), avd).tick()
        (_, ok, result), = avd.finished
        self.assertFalse(ok)
        self.assertIn("inventaire détaillé non envoyé", result)

    def test_unit_without_record_is_a_failure(self):
        avd = FakeAvd([task()], units={})
        self.service(FakeMesh([PN01]), avd).tick()
        (_, ok, result), = avd.finished
        self.assertFalse(ok)
        self.assertIn("aucune fiche AVDiagram", result)

    def test_expired_task_is_logged(self):
        avd = FakeAvd([task()], expired=True)
        self.service(FakeMesh([PN01]), avd).tick()
        self.assertIn("ne l'attendait plus", self.logs[-1])

    def test_serve_survives_failures_and_stops(self):
        stop = threading.Event()
        svc = self.service(FakeMesh([], fail="Unable to connect"), FakeAvd())
        calls = []
        original = svc.tick

        def tick():
            calls.append(1)
            if len(calls) == 3:
                stop.set()
            return original()

        svc.tick = tick
        thread = threading.Thread(target=serve, args=(svc, 0.01, stop))
        thread.start()
        thread.join(5)
        self.assertFalse(thread.is_alive())
        self.assertEqual(len(calls), 3)
        # Une même panne n'est écrite qu'une fois.
        self.assertEqual(sum("battement en échec" in line for line in self.logs), 1)
        self.assertEqual(self.logs[-1], "service arrêté")

    def test_serve_chains_tasks_without_waiting(self):
        stop = threading.Event()
        avd = FakeAvd([task(id="t1"), task(id="t2")])
        svc = self.service(FakeMesh([PN01]), avd)
        original = svc.tick

        def tick():
            handled = original()
            if not handled:
                stop.set()
            return handled

        svc.tick = tick
        # Dans le fil principal : la base SQLite n'est lisible que depuis le
        # fil qui l'a ouverte, comme dans le conteneur.
        saved = {sig: signal.getsignal(sig) for sig in (signal.SIGTERM, signal.SIGINT)}
        try:
            serve(svc, 60, stop)
        finally:
            for sig, handler in saved.items():
                signal.signal(sig, handler)
        self.assertEqual([f[0] for f in avd.finished], ["t1", "t2"])
        self.assertNotIn("erreur inattendue", " ".join(self.logs))


if __name__ == "__main__":
    unittest.main()

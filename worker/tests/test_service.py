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

from test_inventory import FIXTURE, agent_output


class FakeMesh:
    def __init__(self, devices, fail=None):
        self.devices = devices
        self.fail = fail
        self.commands = []

    def list_devices(self, group=None):
        if self.fail:
            raise MeshError(self.fail)
        return self.devices

    def run_powershell(self, device_id, command):
        self.commands.append(device_id)
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

    def service(self, mesh, avd, mapping=None):
        return Service(mesh, avd, self.store, mapping or {}, logger=self.logs.append)

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

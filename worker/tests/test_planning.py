import tempfile
import threading
import time
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

from pcm import planning as plan
from pcm.avdiagram import AvdError, Unit
from pcm.meshctrl import Device
from pcm.service import Service
from pcm.store import Store

from test_service import PN01, PN02, FakeAvd, FakeMesh, task

PARIS = plan.zone("Europe/Paris")


class SlotTests(unittest.TestCase):
    def test_parse(self):
        self.assertEqual(plan.parse_slot("03:00"), plan.Slot(3, 0))
        self.assertEqual(plan.parse_slot("dim 04:30"), plan.Slot(4, 30, 6))
        self.assertEqual(plan.parse_slot("Sun 04:30"), plan.Slot(4, 30, 6))
        self.assertIsNone(plan.parse_slot("off"))
        self.assertIsNone(plan.parse_slot(""))
        for bad in ("25:00", "3h", "xyz 03:00", "03:60"):
            with self.assertRaises(plan.PlanningError, msg=bad):
                plan.parse_slot(bad)

    def test_daily_due_once_and_catch_up_window(self):
        s = plan.parse_slot("03:00")
        at = datetime(2026, 11, 4, 3, 0, tzinfo=PARIS)
        self.assertEqual(s.due(at + timedelta(minutes=1), None), at)
        self.assertIsNone(s.due(at + timedelta(minutes=2), at + timedelta(minutes=1)))
        self.assertIsNone(s.due(at - timedelta(minutes=1), at - timedelta(days=1, minutes=-1)))
        # NAS redémarré à 15 h : le créneau de 3 h n'est pas rattrapé.
        self.assertIsNone(s.due(at + timedelta(hours=12), None))

    def test_weekly(self):
        s = plan.parse_slot("dim 04:00")
        sunday = datetime(2026, 11, 8, 4, 0, tzinfo=PARIS)
        self.assertEqual(s.last_before(sunday + timedelta(days=3)), sunday)
        self.assertEqual(s.due(sunday + timedelta(minutes=30), sunday - timedelta(days=7)), sunday)
        self.assertIsNone(s.due(sunday + timedelta(days=1), None))


class PlanAvd(FakeAvd):
    def __init__(self, *a, fail=False, **kw):
        super().__init__(*a, **kw)
        self.requests = []
        self.fail = fail

    def request_tasks(self, action, asset_tags, params=None):
        self.requests.append((action, asset_tags, params))
        if self.fail:
            raise AvdError("HTTP 503 : migration absente", 503)
        return {"requested": len(asset_tags), "busy": 0, "unknown": []}


class VersionMesh(FakeMesh):
    def server_version(self):
        return {"current": "1.2.5", "latest": "1.3.1"}


class ScheduleTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = Store(Path(self.tmp.name) / "pcm.sqlite")
        self.logs = []
        self.now = datetime(2026, 11, 4, 2, 1, tzinfo=timezone.utc)  # 3 h 01 à Paris

    def tearDown(self):
        self.store.db.close()
        self.tmp.cleanup()

    def service(self, mesh, avd, **kw):
        return Service(mesh, avd, self.store, {"PN2": "PN02"}, logger=self.logs.append, tz=PARIS, clock=lambda: self.now, **kw)

    def test_nightly_inventory_asks_online_devices_once(self):
        avd = PlanAvd()
        svc = self.service(VersionMesh([PN01, PN02]), avd, schedules={"inventaire": plan.parse_slot("03:00"), "logiciels": plan.parse_slot("dim 04:00")})
        svc.tick()
        svc.tick()
        self.assertEqual(avd.requests, [("inventaire", ["PN01"], {"planifie": True})])
        self.assertIsNotNone(self.store.last_run("inventaire"))
        beat = avd.heartbeats[0]
        self.assertEqual(beat["tool"]["meshcentral"], {"current": "1.2.5", "latest": "1.3.1"})
        self.assertEqual(beat["tool"]["schedule"], {"inventory": "03:00", "software": "dim 04:00", "tz": "Europe/Paris"})
        self.assertTrue(any("1.3.1 publiée" in line for line in self.logs))

    def test_failed_request_is_tried_once_per_slot(self):
        avd = PlanAvd(fail=True)
        svc = self.service(FakeMesh([PN01]), avd, schedules={"inventaire": plan.parse_slot("03:00")})
        svc.tick()
        svc.tick()
        self.assertEqual(len(avd.requests), 1)
        self.assertIsNone(self.store.last_run("inventaire"))

    def test_scheduled_update_skips_event_mode_without_failure(self):
        mesh = FakeMesh([PN01])
        mesh.event = True
        t = task(action="logiciels")
        t["params"] = {"planifie": True}
        avd = PlanAvd([t])
        avd.catalogue = [{"kind": "winget", "id": "VideoLAN.VLC", "name": "VLC"}]
        self.service(mesh, avd).tick()
        self.assertEqual(avd.finished, [("t1", True, "Ignoré : mode événement.")])

    def test_scheduled_task_on_device_switched_off_is_ignored(self):
        off = Device("node//pn01", "PN01", "Régie", False, "Windows 11 Pro")
        t = task()
        t["params"] = {"planifie": True}
        avd = PlanAvd([t])
        self.service(FakeMesh([off]), avd).tick()
        self.assertTrue(avd.finished[0][1])
        self.assertIn("Ignoré", avd.finished[0][2])


class ParallelMesh(FakeMesh):
    parallel = True

    def __init__(self, devices):
        super().__init__(devices)
        self.lock = threading.Lock()
        self.active = 0
        self.peak = 0

    def run_powershell(self, device_id, command, timeout=None):
        with self.lock:
            self.active += 1
            self.peak = max(self.peak, self.active)
        time.sleep(0.05)
        try:
            return super().run_powershell(device_id, command, timeout)
        finally:
            with self.lock:
                self.active -= 1


class ParallelTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = Store(Path(self.tmp.name) / "pcm.sqlite")

    def tearDown(self):
        self.store.db.close()
        self.tmp.cleanup()

    def test_devices_run_together_and_one_device_waits_its_turn(self):
        devices = [Device(f"node//pn0{i}", f"PN0{i}", "Régie", True, "Windows 11 Pro") for i in range(1, 4)]
        units = {d.name: Unit(d.name, None, None, None) for d in devices}
        tasks = [task(d.name, id=f"t{i}") for i, d in enumerate(devices)] + [task("PN01", action="mode_evenement", id="t9")]
        tasks[-1]["params"] = {"actif": True}
        mesh = ParallelMesh(devices)
        avd = FakeAvd(tasks, units=units)
        svc = Service(mesh, avd, self.store, {}, logger=lambda m: None, concurrency=4)
        self.assertEqual(svc.tick(), 4)
        self.assertEqual(sorted(f[0] for f in avd.finished), ["t0", "t1", "t2", "t9"])
        self.assertTrue(all(f[1] for f in avd.finished), avd.finished)
        self.assertGreater(mesh.peak, 1)
        self.assertEqual(avd.heartbeats[0]["limit"], 4)
        # PN01 : l'inventaire avant le mode événement, dans l'ordre de la file.
        order = [f[0] for f in avd.finished]
        self.assertLess(order.index("t0"), order.index("t9"))

    def test_without_pipe_one_task_at_a_time(self):
        svc = Service(FakeMesh([PN01]), FakeAvd(), self.store, {}, logger=lambda m: None, concurrency=8)
        self.assertEqual(svc.concurrency, 1)


if __name__ == "__main__":
    unittest.main()

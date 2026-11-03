"""`pcm serve` : l'outil des postes en service, piloté par la page Postes d'AVDiagram.

Toutes les 30 secondes, le worker envoie à AVDiagram ce que MeshCentral voit
(`POST /api/v1/postes/battement`) et repart avec au plus une tâche, passée
« en cours ». Il l'exécute, rend son résultat
(`POST /api/v1/postes/taches/{id}`), puis enchaîne aussitôt sur la suivante.
Une tâche à la fois : meshctrl 1.2.5 ne supporte pas deux commandes
simultanées du même compte, et un battement court garde la page à jour.

C'est le NAS qui appelle AVDiagram : aucun port n'est ouvert vers lui.
"""

from __future__ import annotations

import os
import signal
import threading
from contextlib import contextmanager
from datetime import datetime, timezone
from typing import Callable

from . import inventory as inv
from . import software as sw
from .avdiagram import AvdClient, AvdError
from .meshctrl import Device, MeshCtrl, MeshError
from .store import Store
from .sync import process

SOURCE = "pc-management"
RESULT_MAX = 4000


def log(message: str) -> None:
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    print(f"{stamp} {message}", flush=True)


class Service:
    def __init__(
        self,
        mesh: MeshCtrl,
        avd: AvdClient,
        store: Store,
        mapping: dict[str, str],
        script: str | None = None,
        group: str | None = None,
        push_ip: bool = False,
        logger: Callable[[str], None] = log,
        profile_path: str | None = None,
        pulse_interval: float = 30,
    ):
        self.mesh = mesh
        self.avd = avd
        self.store = store
        self.mapping = mapping
        self.script = script
        self.group = group
        self.push_ip = push_ip
        self.log = logger
        self.profile_path = profile_path or os.environ.get("PCM_SOFTWARE", "config/logiciels.json")
        self.pulse_interval = pulse_interval
        self.seen: list[dict] = []

    def tick(self) -> int:
        """Un battement. Rend le nombre de tâches traitées (0 ou 1)."""
        devices = [d for d in self.mesh.list_devices(self.group) if d.is_windows]
        by_tag = {inv.asset_tag_for(d.name, self.mapping).upper(): d for d in devices}
        seen = [
            {"name": d.name, "asset_tag": tag, "online": d.online, "os": d.os}
            for tag, d in sorted(by_tag.items())
        ]
        self.seen = seen
        tasks = self.avd.heartbeat(SOURCE, seen, limit=1)
        for task in tasks:
            with self._pulse():
                ok, result = self.run_task(task, by_tag)
            kept = self.avd.finish_task(task["id"], ok, result)
            state = "fait" if ok else "échec"
            suffix = "" if kept else " (AVDiagram ne l'attendait plus)"
            self.log(f"tâche {task['id']} {task.get('action')} {task.get('asset_tag')} : {state} : {result}{suffix}")
        return len(tasks)

    @contextmanager
    def _pulse(self):
        """Pendant une tâche longue (une installation peut durer une demi-heure),
        un battement sans prise de tâche garde la page Postes informée que
        l'outil est vivant."""
        stop = threading.Event()

        def beat():
            while not stop.wait(self.pulse_interval):
                try:
                    self.avd.heartbeat(SOURCE, self.seen, limit=0)
                except Exception as exc:  # un battement manqué n'arrête pas la tâche
                    self.log(f"battement pendant la tâche en échec : {exc}")

        thread = threading.Thread(target=beat, daemon=True)
        thread.start()
        try:
            yield
        finally:
            stop.set()
            thread.join(5)

    def run_task(self, task: dict, by_tag: dict[str, Device]) -> tuple[bool, str]:
        action = task.get("action")
        tag = (task.get("asset_tag") or "").strip().upper()
        if action not in ("inventaire", "logiciels"):
            return False, f"Action inconnue de cette version de pc-management : {action}. Mettez l'outil à jour sur le NAS."
        if not tag:
            return False, "La fiche de ce poste n'existe plus."
        device = by_tag.get(tag)
        if device is None:
            return False, f"MeshCentral ne connaît aucun agent nommé {tag} (ni dans config/mapping.json)."
        if not device.online:
            return False, f"{device.name} est hors ligne dans MeshCentral."
        if action == "logiciels":
            return self.install_profile(device, tag)
        return self.inventory(device, tag)

    def install_profile(self, device: Device, tag: str) -> tuple[bool, str]:
        """Le profil de logiciels, un logiciel à la fois, puis un inventaire pour la fiche."""
        try:
            packages = sw.load_profile(self.profile_path)
        except sw.SoftwareError as exc:
            return False, _short(str(exc))
        outcomes = []
        for package in packages:
            outcome = sw.install(self.mesh, device.id, package, inv.new_nonce())
            self.log(f"{tag} {package.id} : {sw.LABELS[outcome.state]}{' : ' + outcome.detail if outcome.detail else ''}")
            outcomes.append(outcome)
        text = sw.summary(outcomes)
        inv_ok, inv_text = self.inventory(device, tag)
        text += ". Fiche à jour" if inv_ok else f". Inventaire après installation impossible : {inv_text}"
        return all(o.ok for o in outcomes), _short(text)

    def inventory(self, device: Device, tag: str) -> tuple[bool, str]:
        nonce = inv.new_nonce()
        try:
            output = self.mesh.run_powershell(device.id, inv.build_command(self.script, nonce))
            data = inv.parse_output(output, nonce)
        except (MeshError, inv.InventoryError) as exc:
            return False, _short(f"Inventaire impossible : {exc}")
        unit = self.avd.computers().get(tag)
        out = process(
            device,
            data,
            tag=tag,
            store=self.store,
            mapping=self.mapping,
            avd=self.avd,
            unit=unit,
            push=True,
            push_ip=self.push_ip,
        )
        notes = [a.split(" : ", 1)[-1] for a in out.alerts]
        if out.errors or not out.details_sent:
            return False, _short(" ; ".join(out.errors + notes) or "Inventaire non posé sur la fiche.")
        e = out.entry
        parts = [f"{e['software_count']} logiciels", e.get("firmware") or "Windows ?"]
        if e.get("changements"):
            c = e["changements"]
            parts.append(f"{len(c['added'])} ajoutés, {len(c['removed'])} retirés, {len(c['updated'])} mis à jour")
        parts.append("fiche à jour")
        return True, _short(", ".join(parts) + (". " + " ; ".join(notes) if notes else ""))


def _short(text: str) -> str:
    text = " ".join(text.split())
    return text if len(text) <= RESULT_MAX else text[: RESULT_MAX - 1] + "…"


def serve(service: Service, interval: float = 30, stop: threading.Event | None = None) -> int:
    """La boucle du service. Une panne (réseau, MeshCentral, AVDiagram) est
    écrite au journal et retentée au battement suivant : le service ne
    s'arrête que sur SIGTERM ou SIGINT (docker compose stop)."""
    stop = stop or threading.Event()
    if threading.current_thread() is threading.main_thread():
        for sig in (signal.SIGTERM, signal.SIGINT):
            signal.signal(sig, lambda *_: stop.set())
    service.log(f"service démarré, battement toutes les {interval:g} s")
    failures = 0
    while not stop.is_set():
        handled = 0
        try:
            handled = service.tick()
            if failures:
                service.log("battement rétabli")
            failures = 0
        except (MeshError, AvdError) as exc:
            failures += 1
            # Une même panne n'est pas répétée à chaque battement.
            if failures == 1 or failures % 20 == 0:
                service.log(f"battement en échec ({failures}) : {exc}")
        except Exception as exc:  # le service ne doit pas mourir d'un cas imprévu
            failures += 1
            service.log(f"erreur inattendue : {type(exc).__name__} : {exc}")
        if handled:
            continue  # une tâche faite : on prend la suivante sans attendre
        stop.wait(interval)
    service.log("service arrêté")
    return 0

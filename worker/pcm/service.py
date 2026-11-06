"""`pcm serve` : l'outil des postes en service, piloté par la page Postes d'AVDiagram.

Toutes les 30 secondes, le worker envoie à AVDiagram ce que MeshCentral voit
(`POST /api/v1/postes/battement`) et repart avec des tâches, passées « en
cours ». Il les exécute, rend leur résultat (`POST /api/v1/postes/taches/{id}`),
puis enchaîne aussitôt sur les suivantes.

Avec la session permanente de `meshpipe.js` (lot 5), plusieurs postes
travaillent en même temps (PCM_CONCURRENCY, 4 par défaut), les tâches d'un
même poste l'une après l'autre. Sans elle, une tâche à la fois : deux meshctrl
1.2.5 simultanés se volent leurs réponses.

Il lance aussi, à heure fixe, l'inventaire de la nuit et les mises à jour de
la semaine (`planning.py`), et relève chaque jour la version du serveur
MeshCentral, qu'AVDiagram compare à la dernière publiée.

Le bouton « Mettre à jour l'outil » de la page Postes (0078) revient au
battement : le service le relaie au NAS en déposant `data/maj-demandee`, que
la tâche planifiée DSM `scripts/maj-nas.sh --si-demande` (toutes les 5
minutes) applique. Le conteneur n'a pas accès à Docker : il ne fait que
déposer la demande. Il remonte sa version, la demande en attente et la
dernière ligne du journal de mise à jour.

C'est le NAS qui appelle AVDiagram : aucun port n'est ouvert vers lui.
"""

from __future__ import annotations

import os
import signal
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone, tzinfo
from typing import Callable

from . import inventory as inv
from . import installers as ins
from . import pilot
from . import planning as plan
from . import software as sw
from .avdiagram import AvdClient, AvdError
from .meshctrl import Device, MeshCtrl, MeshError
from .store import Store
from .sync import process

SOURCE = "pc-management"
RESULT_MAX = 4000
ACTIONS = ("inventaire", "logiciels", "alimentation", "reseau", "mode_evenement", "supervision", "envoi", "nettoyage", "diagnostic", "fond", "vignette", "message")


def load_software(profile_path, installers_path, installers_dir, avd=None):
    """Ce que le bouton « Installer les logiciels » pose : le catalogue
    d'AVDiagram (Postes, Logiciels) s'il a au moins une ligne, sinon le profil
    winget et les installeurs du NAS. Côté NAS, l'un des deux peut manquer, pas
    les deux."""
    if avd is not None:
        catalogue = avd.software()
        if catalogue:
            packages = [
                sw.Package(str(e.get("id")), str(e.get("name") or e.get("id")))
                for e in catalogue
                if e.get("kind") == "winget"
            ]
            for p in packages:
                if not sw.ID_RE.match(p.id):
                    raise sw.SoftwareError(f"Identifiant winget illisible dans le catalogue : {p.id!r}")
            installers = ins.from_catalogue([e for e in catalogue if e.get("kind") == "installer"])
            return packages, installers
    installers = ins.load_installers(installers_path, installers_dir)
    try:
        packages = sw.load_profile(profile_path)
    except sw.SoftwareError:
        if installers and not os.path.exists(profile_path):
            return [], installers
        raise
    return packages, installers


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
        installers_path: str | None = None,
        installers_dir: str | None = None,
        pulse_interval: float = 30,
        sleep: Callable[[float], None] = time.sleep,
        pilot_script: str | None = None,
        concurrency: int | None = None,
        schedules: dict[str, plan.Slot | None] | None = None,
        tz: tzinfo = timezone.utc,
        clock: Callable[[], datetime] = lambda: datetime.now(timezone.utc),
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
        self.installers_path = installers_path or os.environ.get("PCM_INSTALLERS", "config/installeurs.json")
        self.installers_dir = installers_dir or os.environ.get("PCM_INSTALLERS_DIR", "installeurs")
        self.pulse_interval = pulse_interval
        self.sleep = sleep
        self.pilot_script = pilot_script
        # agent/controle.ps1, relu à chaque contrôle sauf s'il est donné ici.
        self.check_script: str | None = None
        # agent/fond-pose.ps1, de même (le mode événement le pose s'il manque).
        self.wallpaper_script: str | None = None
        self.seen: list[dict] = []
        parallel = bool(getattr(mesh, "parallel", False))
        self.concurrency = max(1, concurrency or 4) if parallel else 1
        self.schedules = schedules or {}
        self.tz = tz
        self.clock = clock
        # Les actions que cette version sait faire : AVDiagram grise les autres
        # au lieu de laisser partir une tâche vouée à l'échec.
        self.tool: dict = {"actions": list(ACTIONS)}
        self._version_at: datetime | None = None
        self._plan_failed: dict[str, datetime] = {}
        self._repose_failed: dict[str, datetime] = {}
        self.data_dir = os.path.dirname(os.path.abspath(os.environ.get("PCM_DB", "data/pcm.sqlite")))
        if self.schedules:
            self.tool["schedule"] = {
                "inventory": (self.schedules.get("inventaire") or None) and self.schedules["inventaire"].label(),
                "software": (self.schedules.get("logiciels") or None) and self.schedules["logiciels"].label(),
                "tz": str(tz),
            }

    def tick(self) -> int:
        """Un battement. Rend le nombre de tâches traitées."""
        try:
            devices = [d for d in self.mesh.list_devices(self.group) if d.is_windows]
        except MeshError as exc:
            # MeshCentral injoignable : AVDiagram le sait (alerte du parc,
            # 0079), l'état des postes y reste celui d'avant.
            self.tool["mesh_error"] = _short(str(exc))[:300] or "MeshCentral ne répond pas"
            self.tool["nas"] = self._nas_state()
            try:
                self.avd.heartbeat(SOURCE, None, limit=0, tool=self.tool)
            except Exception as inner:  # le battement en échec est déjà dit par serve()
                self.log(f"battement sans MeshCentral en échec : {inner}")
            raise
        self.tool.pop("mesh_error", None)
        by_tag = {inv.asset_tag_for(d.name, self.mapping).upper(): d for d in devices}
        mesh_url = os.environ.get("MESHCTRL_URL")
        seen = [
            {"name": d.name, "asset_tag": tag, "online": d.online, "os": d.os, "link": pilot.device_link(mesh_url, d.id)}
            for tag, d in sorted(by_tag.items())
        ]
        self.seen = seen
        self._maintenance(by_tag)
        self._repose(by_tag)
        self.tool["nas"] = self._nas_state()
        extra = {"tool": self.tool} if self.tool else {}
        tasks = self.avd.heartbeat(SOURCE, seen, limit=self.concurrency, **extra)
        self._relay_update(getattr(self.avd, "update_requested_at", None))
        if not tasks:
            return 0
        with self._pulse():
            if self.concurrency == 1 or len(tasks) == 1:
                for task in tasks:
                    self._do(task, by_tag)
            else:
                # Les tâches d'un même poste l'une après l'autre, les postes en même temps.
                groups: dict[str, list[dict]] = {}
                for task in tasks:
                    groups.setdefault((task.get("asset_tag") or "").upper() or task["id"], []).append(task)
                with ThreadPoolExecutor(max_workers=min(self.concurrency, len(groups))) as pool:
                    for f in [pool.submit(self._do_all, g, by_tag) for g in groups.values()]:
                        f.result()
        return len(tasks)

    # -- Mise à jour de l'outil demandée depuis la page Postes (0078) ----------

    def _nas_path(self, name: str) -> str:
        return os.path.join(self.data_dir, name)

    def _read(self, name: str) -> str | None:
        try:
            with open(self._nas_path(name), encoding="utf-8", errors="replace") as f:
                return f.read()
        except OSError:
            return None

    def _nas_state(self) -> dict:
        """Ce que la page Postes montre de l'outil : sa version (le commit de
        l'image), la dernière demande relayée, si le NAS ne l'a pas encore
        appliquée, et la dernière ligne du journal de scripts/maj-nas.sh."""
        journal = (self._read("maj-nas.log") or "").strip().splitlines()
        derniere = next((l for l in reversed(journal) if l[:2].isdigit()), None)
        return {
            "version": (os.environ.get("PCM_VERSION") or "dev")[:40],
            "relayed": ((self._read("maj-relayee") or "").strip() or None),
            "pending": os.path.exists(self._nas_path("maj-demandee")),
            "last": derniere[:300] if derniere else None,
        }

    def _relay_update(self, requested_at: str | None) -> None:
        """Une demande nouvelle : dépose `maj-demandee` pour la tâche DSM.
        Une demande déjà relayée ne l'est pas deux fois, même après un
        redémarrage du service (c'est justement ce que fait la mise à jour)."""
        if not requested_at or not isinstance(requested_at, str) or len(requested_at) > 40:
            return
        if (self._read("maj-relayee") or "").strip() == requested_at:
            return
        try:
            with open(self._nas_path("maj-demandee"), "w", encoding="utf-8") as f:
                f.write(requested_at + "\n")
            with open(self._nas_path("maj-relayee"), "w", encoding="utf-8") as f:
                f.write(requested_at + "\n")
        except OSError as exc:
            self.log(f"demande de mise à jour non déposée : {exc}")
            return
        self.log(f"mise à jour de l'outil demandée ({requested_at}), relayée au NAS")
        self.tool["nas"] = self._nas_state()

    def _do_all(self, tasks: list[dict], by_tag: dict[str, Device]) -> None:
        for task in tasks:
            self._do(task, by_tag)

    def _do(self, task: dict, by_tag: dict[str, Device]) -> None:
        controle = None
        try:
            ok, result, *rest = self.run_task(task, by_tag)
            controle = rest[0] if rest else None
        except (MeshError, AvdError) as exc:
            ok, result = False, _short(str(exc))
        except Exception as exc:  # une tâche ne fait pas tomber les autres
            ok, result = False, _short(f"Erreur inattendue de l'outil : {type(exc).__name__} : {exc}")
        kept = self.avd.finish_task(task["id"], ok, result, controle) if controle else self.avd.finish_task(task["id"], ok, result)
        state = "fait" if ok else "échec"
        if controle:
            state += f", contrôle {controle['etat']}"
        suffix = "" if kept else " (AVDiagram ne l'attendait plus)"
        self.log(f"tâche {task['id']} {task.get('action')} {task.get('asset_tag')} : {state} : {result}{suffix}")

    def _checked(self, device: Device, action: str, params: dict, done: tuple) -> tuple:
        """Après une action faite, son effet relu dans Windows (pilot.check).
        Une action en échec qui a quand même posé quelque chose (`done[2]` vrai,
        le nettoyage sans la liste des applications) est relue aussi : elle
        reste en échec, et AVDiagram sait que le poste a changé."""
        ok, text = done[0], done[1]
        partial = len(done) > 2 and done[2] is True
        if not ok and not partial:
            return done
        if partial:
            controle = pilot.check(self.mesh, device.id, pilot.CHECKED[action], params, inv.new_nonce, script=self.check_script)
            return False, text, controle
        controle = pilot.check(self.mesh, device.id, pilot.CHECKED[action], params, inv.new_nonce, script=self.check_script)
        return pilot.with_check(ok, text, controle)

    def _maintenance(self, by_tag: dict[str, Device]) -> None:
        """La version du serveur MeshCentral (une fois par jour) et les tâches planifiées."""
        now = self.clock()
        if hasattr(self.mesh, "server_version") and (self._version_at is None or now - self._version_at >= timedelta(hours=24)):
            self._version_at = now
            try:
                tags = self.mesh.server_version()
                self.tool["meshcentral"] = tags
                if tags.get("latest") and tags.get("current") and tags["latest"] != tags["current"]:
                    self.log(f"MeshCentral {tags['current']} sur le serveur, {tags['latest']} publiée")
            except MeshError as exc:
                self.log(f"version de MeshCentral illisible : {exc}")
        for name, slot in self.schedules.items():
            if slot is None:
                continue
            last = self.store.last_run(name)
            at = slot.due(now.astimezone(self.tz), last.astimezone(self.tz) if last else None)
            if at is None or self._plan_failed.get(name) == at:
                continue
            tags = sorted(tag for tag, d in by_tag.items() if d.online)
            try:
                res = self.avd.request_tasks(name, tags, {"planifie": True}) if tags else {"requested": 0, "busy": 0}
            except AvdError as exc:
                # Une seule tentative par créneau : pas de rafale au journal ni sur l'API.
                self._plan_failed[name] = at
                self.log(f"planification {name} ({slot.label()}) impossible : {exc}")
                continue
            self.store.set_last_run(name, now)
            self.log(f"planification {name} ({slot.label()}) : {res.get('requested', 0)} poste(s) en ligne, {res.get('busy', 0)} déjà occupé(s)")

    def _repose(self, by_tag: dict[str, Device]) -> None:
        """Après une mise à jour du relais qui change l'écran, le mur ou la sonde,
        AVDiagram les fait reposer là où ils sont posés : un poste n'a plus
        besoin qu'on retire puis remette son état à l'écran. Une seule demande par
        version, retentée au plus une fois par heure si AVDiagram la refuse."""
        if not by_tag or not hasattr(self.avd, "request_reposes"):
            return
        now = self.clock()
        for action, version in pilot.posed_versions().items():
            name = f"repose:{action}:{version}"
            if self.store.last_run(name) is not None:
                continue
            failed = self._repose_failed.get(name)
            if failed and now - failed < timedelta(hours=1):
                continue
            try:
                res = self.avd.request_reposes(action, sorted(by_tag))
            except AvdError as exc:
                self._repose_failed[name] = now
                self.log(f"repose {action} ({version}) impossible : {exc}")
                continue
            self.store.set_last_run(name, now)
            self.log(f"repose {action} ({version}) : {res.get('requested', 0)} poste(s), {res.get('busy', 0)} déjà occupé(s)")

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

    def run_task(self, task: dict, by_tag: dict[str, Device]) -> tuple:
        """(ok, texte), ou (ok, texte, contrôle) pour une action relue dans Windows."""
        action = task.get("action")
        tag = (task.get("asset_tag") or "").strip().upper()
        if action not in ACTIONS:
            return False, f"Action inconnue de cette version de pc-management : {action}. Mettez l'outil à jour sur le NAS."
        if not tag:
            return False, "La fiche de ce poste n'existe plus."
        device = by_tag.get(tag)
        if device is None:
            return False, f"MeshCentral ne connaît aucun agent nommé {tag} (ni dans config/mapping.json)."
        params = task.get("params") or {}
        if action == "alimentation" and params.get("mode") == "reveiller":
            if device.online:
                return True, f"{device.name} est déjà allumé et en ligne."
            return pilot.power(self.mesh, device.id, params, inv.new_nonce, script=self.pilot_script)
        scheduled = params.get("planifie") is True
        if not device.online:
            if scheduled:
                return True, f"Ignoré : {device.name} s'est éteint avant son tour."
            return False, f"{device.name} est hors ligne dans MeshCentral."
        if action == "alimentation":
            return pilot.power(self.mesh, device.id, params, inv.new_nonce, script=self.pilot_script)
        if action == "supervision":
            done = pilot.supervision(self.mesh, device.id, task.get("unit_id") or "", params, self.avd, inv.new_nonce, script=self.pilot_script, reference=tag)
            return self._checked(device, action, params, done)
        if action == "envoi":
            ok, text = pilot.envoi(self.mesh, device.id, params, self.avd, inv.new_nonce, script=self.pilot_script)
            # La sortie d'un script garde ses lignes.
            return ok, text if len(text) <= RESULT_MAX else text[: RESULT_MAX - 1] + "…"
        if action == "mode_evenement":
            done = pilot.event_mode(self.mesh, device.id, params, inv.new_nonce, script=self.pilot_script, reference=tag, wallpaper_script=self.wallpaper_script)
            return self._checked(device, action, params, done)
        if action == "fond":
            return pilot.wallpaper(self.mesh, device.id, tag, params, inv.new_nonce, script=self.wallpaper_script)
        if action == "vignette":
            return pilot.thumbnail(self.mesh, device.id, task.get("unit_id") or "", params, self.avd, inv.new_nonce)
        if action == "message":
            return pilot.message(self.mesh, device.id, device.name, params, inv.new_nonce, script=self.pilot_script)
        if action == "nettoyage":
            done = pilot.cleanup(self.mesh, device.id, params, inv.new_nonce, script=self.pilot_script)
            return self._checked(device, action, params, done)
        if action == "diagnostic":
            ok, text, data = pilot.diagnostic(self.mesh, device.id, params, inv.new_nonce)
            if data is not None:
                try:
                    self.avd.post_diagnostic(task.get("id") or "", task.get("unit_id") or "", data)
                except AvdError as exc:
                    text += f" (détail non enregistré dans AVDiagram : {exc})"
            return ok, _short(text)
        if action == "reseau":
            ok, text = pilot.network(self.mesh, device.id, params, os.environ.get("MESHCTRL_URL"), inv.new_nonce, sleep=self.sleep, script=self.pilot_script)
            return ok, _short(text)
        if action == "logiciels":
            return self.install_profile(device, tag, scheduled=scheduled)
        return self.inventory(device, tag)

    def _event_refusal(self, device: Device) -> str | None:
        """Un poste en mode événement ne reçoit pas d'installation. Un poste qui
        ne sait pas répondre (ancienne version, panne passagère) n'est pas bloqué."""
        try:
            st = pilot.state(self.mesh, device.id, inv.new_nonce, script=self.pilot_script)
        except (MeshError, pilot.PilotError) as exc:
            self.log(f"{device.name} : état du mode événement illisible ({exc}), installation lancée")
            return None
        if st.get("evenement"):
            return f"Refusé : {device.name} est en mode événement depuis le {str(st.get('depuis') or '?')[:16].replace('T', ' ')}. Terminez le mode événement d'abord."
        return None

    def install_profile(self, device: Device, tag: str, scheduled: bool = False) -> tuple[bool, str]:
        """Le profil winget puis les installeurs du NAS, un logiciel à la fois, puis un inventaire."""
        try:
            packages, installers = load_software(self.profile_path, self.installers_path, self.installers_dir, self.avd)
        except (sw.SoftwareError, ins.InstallerError, AvdError) as exc:
            return False, _short(str(exc))
        refused = self._event_refusal(device)
        if refused:
            # La mise à jour de la semaine laisse un poste d'événement tranquille, sans échec.
            return (True, "Ignoré : mode événement.") if scheduled else (False, refused)
        outcomes = []
        for package in packages:
            outcomes.append(self._logged(tag, package.id, sw.install(self.mesh, device.id, package, inv.new_nonce())))
        for inst in installers:
            outcomes.append(self._logged(tag, inst.name, ins.install(self.mesh, device.id, inst, inv.new_nonce)))
        text = sw.summary(outcomes)
        inv_ok, inv_text = self.inventory(device, tag)
        text += ". Fiche à jour" if inv_ok else f". Inventaire après installation impossible : {inv_text}"
        return all(o.ok for o in outcomes), _short(text)

    def _logged(self, tag: str, label: str, outcome: sw.Outcome) -> sw.Outcome:
        self.log(f"{tag} {label} : {sw.LABELS[outcome.state]}{' : ' + outcome.detail if outcome.detail else ''}")
        return outcome

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

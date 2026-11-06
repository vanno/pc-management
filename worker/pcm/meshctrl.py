"""Appels à MeshCentral par l'outil officiel meshctrl (node meshctrl.js).

Les identifiants viennent de l'environnement (MESHCTRL_URL,
MESHCTRL_LOGINUSER, MESHCTRL_LOGINPASS, MESHCTRL_TOKEN pour un second
facteur) et sont passés en arguments --url, --loginuser, --loginpass, --token.
meshctrl ne lit ces variables lui-même qu'à partir des versions postérieures à
la 1.2.5 : sans arguments, il se connecte à wss://localhost.
"""

from __future__ import annotations

import itertools
import json
import os
import shlex
import subprocess
import threading
from dataclasses import dataclass
from pathlib import Path

# Bit 1 de `conn` : l'agent est connecté au serveur.
AGENT_CONNECTED = 1


class MeshError(RuntimeError):
    pass


@dataclass(frozen=True)
class Device:
    id: str
    name: str
    group: str | None
    online: bool
    os: str | None

    @property
    def is_windows(self) -> bool:
        return "windows" in (self.os or "").lower()


PIPE_SCRIPT = Path(__file__).resolve().parents[1] / "meshpipe.js"


class MeshPipe:
    """La session permanente de `worker/meshpipe.js` (lot 5) : les commandes
    PowerShell de plusieurs postes en même temps, chacune reconnue par son
    propre identifiant de réponse. Le processus Node est relancé s'il s'arrête.
    Les identifiants passent par l'environnement, jamais par la ligne de
    commande (visible dans `ps`)."""

    def __init__(self, command: str | None = None, ready_timeout: float = 20, popen=subprocess.Popen):
        self.command = shlex.split(command or os.environ.get("MESHPIPE_CMD", f"node {PIPE_SCRIPT}"))
        self.ready_timeout = ready_timeout
        self.popen = popen
        self.proc = None
        self.lock = threading.Lock()
        self.ready = threading.Event()
        self.pending: dict[str, dict] = {}
        self.ids = itertools.count(1)
        self.reason = "session pas encore ouverte"

    def _env(self) -> dict:
        url = os.environ.get("MESHCTRL_URL")
        if not url:
            raise MeshError("Variable MESHCTRL_URL manquante (ex. wss://meshcentral.pointe-noire.com)")
        env = {**os.environ, "MESHPIPE_URL": url}
        for target, var in (("MESHPIPE_USER", "MESHCTRL_LOGINUSER"), ("MESHPIPE_PASS", "MESHCTRL_LOGINPASS"), ("MESHPIPE_TOKEN", "MESHCTRL_TOKEN")):
            if os.environ.get(var):
                env[target] = os.environ[var]
        return env

    def _ensure(self) -> None:
        with self.lock:
            if self.proc is not None and self.proc.poll() is None:
                return
            self.ready.clear()
            self.proc = self.popen(
                self.command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, encoding="utf-8", errors="replace", bufsize=1, env=self._env()
            )
            threading.Thread(target=self._read, args=(self.proc,), daemon=True).start()

    def _read(self, proc) -> None:
        for line in proc.stdout:
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue
            if msg.get("event") == "ready":
                self.reason = ""
                self.ready.set()
            elif msg.get("event") == "down":
                self.reason = str(msg.get("reason") or "session perdue")
                self.ready.clear()
            elif isinstance(msg.get("id"), str):
                slot = self.pending.pop(msg["id"], None)
                if slot is not None:
                    slot["reply"] = msg
                    slot["done"].set()
        self.ready.clear()
        self.reason = "processus meshpipe arrêté"
        for slot in list(self.pending.values()):
            slot["reply"] = {"error": "processus meshpipe arrêté pendant la commande"}
            slot["done"].set()
        self.pending.clear()

    def _send(self, obj: dict) -> None:
        with self.lock:
            self.proc.stdin.write(json.dumps(obj) + "\n")
            self.proc.stdin.flush()

    def run(self, device_id: str, command: str, timeout: float) -> str:
        self._ensure()
        if not self.ready.wait(self.ready_timeout):
            raise MeshError(f"MeshCentral injoignable : {self.reason}")
        rid = str(next(self.ids))
        slot = {"done": threading.Event(), "reply": None}
        self.pending[rid] = slot
        try:
            self._send({"id": rid, "node": device_id, "cmds": command, "type": 2})
        except (OSError, ValueError) as exc:
            self.pending.pop(rid, None)
            raise MeshError(f"meshpipe : envoi impossible : {exc}") from exc
        if not slot["done"].wait(timeout):
            self.pending.pop(rid, None)
            try:
                self._send({"cancel": rid})
            except (OSError, ValueError):
                pass
            # MeshCentral ne lance qu'une commande à la fois par poste, sans
            # limite de durée : une commande restée ouverte bloque les suivantes.
            raise MeshError(
                f"runcommand : délai dépassé ({timeout:g} s). Poste en veille, ou une commande précédente encore ouverte"
                " (MeshCentral n'en lance qu'une à la fois) : la sonde de supervision la ferme après 90 minutes, un redémarrage aussi"
            )
        reply = slot["reply"] or {}
        if "error" in reply:
            raise MeshError(f"runcommand : {reply['error']}")
        return str(reply.get("output") or "")

    def close(self) -> None:
        with self.lock:
            if self.proc is not None and self.proc.poll() is None:
                self.proc.stdin.close()
                try:
                    self.proc.wait(5)
                except subprocess.TimeoutExpired:
                    self.proc.kill()


class MeshCtrl:
    def __init__(self, command: str | None = None, timeout: int = 180, pipe: MeshPipe | None = None):
        # Ex. « node /opt/meshcentral/node_modules/meshcentral/meshctrl.js »
        self.command = shlex.split(command or os.environ.get("MESHCTRL_CMD", "node meshctrl.js"))
        self.timeout = timeout
        self.pipe = pipe
        # Sans la session permanente, deux runcommand de meshctrl se volent
        # leurs réponses : un seul à la fois.
        self._serial = threading.Lock()

    @property
    def parallel(self) -> bool:
        return self.pipe is not None

    def _login_args(self) -> list[str]:
        url = os.environ.get("MESHCTRL_URL")
        if not url:
            raise MeshError("Variable MESHCTRL_URL manquante (ex. wss://meshcentral.pointe-noire.com)")
        args = ["--url", url]
        for flag, var in (("--loginuser", "MESHCTRL_LOGINUSER"), ("--loginpass", "MESHCTRL_LOGINPASS"), ("--token", "MESHCTRL_TOKEN")):
            if os.environ.get(var):
                args += [flag, os.environ[var]]
        return args

    def _run(self, *args: str, timeout: int | None = None) -> str:
        try:
            done = subprocess.run(
                [*self.command, *args, *self._login_args()],
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=timeout or self.timeout,
                check=False,
            )
        except subprocess.TimeoutExpired as exc:
            raise MeshError(f"meshctrl {args[0]} : délai dépassé ({exc.timeout} s)") from exc
        if done.returncode != 0:
            raise MeshError(f"meshctrl {args[0]} : code {done.returncode} : {(done.stderr or done.stdout).strip()[:300]}")
        # meshctrl rend 0 même quand la connexion échoue : on le lit dans la sortie.
        first = done.stdout.strip().splitlines()[:1]
        if first and first[0].startswith(("Unable to connect", "Invalid login", "Invalid url", "Authentication token required")):
            raise MeshError(f"meshctrl {args[0]} : {first[0]}")
        return done.stdout

    def list_devices(self, group: str | None = None) -> list[Device]:
        args = ["listdevices", "--json"]
        if group:
            args += ["--group", group]
        out = self._run(*args, timeout=60)
        try:
            nodes = json.loads(out)
        except json.JSONDecodeError as exc:
            raise MeshError(f"meshctrl listdevices : réponse non JSON : {out.strip()[:300]}") from exc
        return [parse_device(n) for n in nodes]

    def run_powershell(self, device_id: str, command: str, timeout: int | None = None) -> str:
        """Exécute une commande PowerShell sur le poste et rend sa sortie."""
        if self.pipe is not None:
            return self.pipe.run(device_id, command, timeout or self.timeout)
        with self._serial:
            return self._run("runcommand", "--id", device_id, "--powershell", "--reply", "--run", command, timeout=timeout)

    def server_version(self) -> dict:
        """{ current, latest, stable } : la version du serveur MeshCentral et
        celles que le serveur sait publiées (il interroge npm lui-même)."""
        out = self._run("serverversion", "--json", timeout=60)
        try:
            tags = json.loads(out)
        except json.JSONDecodeError as exc:
            raise MeshError(f"meshctrl serverversion : réponse non JSON : {out.strip()[:200]}") from exc
        if not isinstance(tags, dict):
            raise MeshError("meshctrl serverversion : réponse illisible")
        return {k: str(tags[k]) for k in ("current", "latest", "stable") if isinstance(tags.get(k), str)}

    def upload(self, device_id: str, local_path: str, remote_dir: str, timeout: int | None = None) -> None:
        """Envoie un fichier dans un dossier du poste, sous le même nom.

        meshctrl rend 0 même quand l'envoi échoue : on lit sa sortie, qui finit
        par « Upload done, N bytes sent. » quand tout est passé.
        """
        out = self._run("upload", "--id", device_id, "--file", local_path, "--target", remote_dir, timeout=timeout)
        if "Upload done" not in out:
            last = (out.strip().splitlines() or ["(sortie vide)"])[-1]
            raise MeshError(f"meshctrl upload : envoi non terminé : {last[:200]}")


    def toast(self, device_id: str, message: str, title: str) -> None:
        """Une notification Windows dans la session ouverte du poste. Le serveur
        répond « ok » dès qu'il a relayé : sans session ouverte, rien ne
        s'affiche. `--msg=` garde tel quel un message qui commence par un tiret."""
        out = self._run("devicetoast", "--id", device_id, f"--msg={message}", f"--title={title}", timeout=60).strip()
        last = (out.splitlines() or [""])[-1].strip()
        if last.lower() != "ok":
            raise MeshError(f"meshctrl devicetoast : {last or '(sortie vide)'}")

    def message_box(self, device_id: str, message: str, title: str, timeout_ms: int = 600_000) -> str:
        """Une fenêtre au milieu de l'écran du poste, jusqu'à OK ou `timeout_ms`.

        Le serveur ne répond que si le message ne passe pas (« Unable to
        route ») : une attente de 20 secondes sans réponse veut dire relayé."""
        try:
            out = self._run("devicemessage", "--id", device_id, f"--msg={message}", f"--title={title}", "--timeout", str(timeout_ms), timeout=20).strip()
        except MeshError as exc:
            if "délai dépassé" in str(exc):
                return "relayée"
            raise
        last = (out.splitlines() or [""])[-1].strip()
        if last and last.lower() not in ("ok", "relayée"):
            raise MeshError(f"meshctrl devicemessage : {last}")
        return "relayée"

    def wake(self, device_id: str) -> str:
        """Wake-on-LAN : le serveur et chaque agent connecté envoient le paquet
        magique aux adresses MAC connues du poste. Rend la réponse du serveur,
        « Used N device(s) to send wake packets »."""
        out = self._run("devicepower", "--wake", "--id", device_id, timeout=60).strip()
        last = (out.splitlines() or [""])[-1].strip()
        if not last or last.lower().startswith(("invalid", "no known mac", "no power operation")):
            raise MeshError(f"meshctrl devicepower : {last or '(sortie vide)'}")
        return last


def parse_device(node: dict) -> Device:
    return Device(
        id=node["_id"],
        name=node.get("name") or node.get("rname") or node["_id"],
        group=node.get("groupname"),
        online=bool((node.get("conn") or 0) & AGENT_CONNECTED),
        os=node.get("osdesc"),
    )

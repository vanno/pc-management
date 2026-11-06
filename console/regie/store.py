"""Ce que la console garde : la dernière mesure de chaque poste et les
courbes des dernières heures (SQLite, dans le dossier de la console)."""

from __future__ import annotations

import json
import sqlite3
import threading
import time
from pathlib import Path

GARDE_HEURES = 12
# Un poste pas vu depuis une journée sort de la page.
OUBLI_HEURES = 24


def _num(v):
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None


class Store:
    def __init__(self, chemin: Path | str, horloge=time.time):
        self.horloge = horloge
        self._lock = threading.Lock()
        self.db = sqlite3.connect(str(chemin), check_same_thread=False)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.executescript(
            """
            CREATE TABLE IF NOT EXISTS postes (
                reference TEXT PRIMARY KEY,
                poste TEXT,
                recu REAL NOT NULL,
                adresse TEXT,
                console_ip TEXT,
                mesure TEXT
            );
            CREATE TABLE IF NOT EXISTS mesures (
                reference TEXT NOT NULL,
                recu REAL NOT NULL,
                cpu REAL, ram REAL, disque REAL,
                passerelle_ms REAL, passerelle_perte REAL,
                internet_ms REAL, internet_perte REAL,
                rx REAL, tx REAL
            );
            CREATE INDEX IF NOT EXISTS mesures_ref ON mesures (reference, recu);
            """
        )
        self._purge = 0.0

    def ajouter(self, reference: str, poste: str, adresse: str, console_ip: str, mesures: list[dict]) -> None:
        maintenant = self.horloge()
        with self._lock, self.db:
            for m in mesures:
                nics = [n for n in m.get("nics") or [] if isinstance(n, dict)]
                rx = sum(_num(n.get("rx")) or 0 for n in nics if not n.get("down"))
                tx = sum(_num(n.get("tx")) or 0 for n in nics if not n.get("down"))
                self.db.execute(
                    "INSERT INTO mesures VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                    (reference, maintenant, _num(m.get("cpu")), _num(m.get("ram")), _num(m.get("disk_free")), _num(m.get("gateway_ms")),
                     _num(m.get("gateway_loss")), _num(m.get("internet_ms")), _num(m.get("internet_loss")), rx, tx),
                )
            if mesures:
                self.db.execute(
                    "INSERT INTO postes VALUES (?,?,?,?,?,?) ON CONFLICT(reference) DO UPDATE SET poste=excluded.poste, recu=excluded.recu, adresse=excluded.adresse, console_ip=excluded.console_ip, mesure=excluded.mesure",
                    (reference, poste, maintenant, adresse, console_ip, json.dumps(mesures[-1], ensure_ascii=False)),
                )
            if maintenant - self._purge > 600:
                self._purge = maintenant
                self.db.execute("DELETE FROM mesures WHERE recu < ?", (maintenant - GARDE_HEURES * 3600,))
                self.db.execute("DELETE FROM postes WHERE recu < ?", (maintenant - OUBLI_HEURES * 3600,))

    def postes(self) -> list[dict]:
        limite = self.horloge() - OUBLI_HEURES * 3600
        with self._lock:
            rows = self.db.execute("SELECT reference, poste, recu, adresse, console_ip, mesure FROM postes WHERE recu >= ? ORDER BY reference", (limite,)).fetchall()
        out = []
        for ref, poste, recu, adresse, console_ip, mesure in rows:
            try:
                m = json.loads(mesure) if mesure else {}
            except ValueError:
                m = {}
            out.append({"reference": ref, "poste": poste, "recu": recu, "adresse": adresse, "console_ip": console_ip, "mesure": m})
        return out

    def historique(self, reference: str, heures: float = GARDE_HEURES) -> list[list]:
        limite = self.horloge() - heures * 3600
        with self._lock:
            rows = self.db.execute(
                "SELECT recu, cpu, ram, passerelle_ms, passerelle_perte, rx, tx FROM mesures WHERE reference = ? AND recu >= ? ORDER BY recu",
                (reference, limite),
            ).fetchall()
        return [list(r) for r in rows]

    def oublier(self, reference: str) -> None:
        with self._lock, self.db:
            self.db.execute("DELETE FROM postes WHERE reference = ?", (reference,))
            self.db.execute("DELETE FROM mesures WHERE reference = ?", (reference,))

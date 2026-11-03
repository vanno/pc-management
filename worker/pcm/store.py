"""Historique des inventaires dans une base SQLite (un fichier sur le NAS)."""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path

SCHEMA = """
create table if not exists snapshots (
    id           integer primary key,
    asset_tag    text not null,
    device_id    text not null,
    collected_at text not null,
    data         text not null
);
create index if not exists snapshots_asset_idx on snapshots (asset_tag, collected_at);

create table if not exists runs (
    id          integer primary key,
    started_at  text not null default (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    report      text not null
);
"""


class Store:
    def __init__(self, path: str | Path):
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(path)
        self.db.executescript(SCHEMA)

    def latest(self, asset_tag: str) -> dict | None:
        row = self.db.execute(
            "select data from snapshots where asset_tag = ? order by collected_at desc limit 1", (asset_tag,)
        ).fetchone()
        return json.loads(row[0]) if row else None

    def save(self, asset_tag: str, device_id: str, data: dict) -> None:
        with self.db:
            self.db.execute(
                "insert into snapshots (asset_tag, device_id, collected_at, data) values (?, ?, ?, ?)",
                (asset_tag, device_id, data["collected_at"], json.dumps(data, ensure_ascii=False)),
            )

    def save_run(self, report: dict) -> None:
        with self.db:
            self.db.execute("insert into runs (report) values (?)", (json.dumps(report, ensure_ascii=False),))

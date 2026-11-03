"""Ce que l'outil des postes fait seul, à heure fixe (lot 5).

    PCM_INVENTORY_AT  « 03:00 » : chaque nuit, un inventaire des postes en ligne
    PCM_UPDATE_AT     « dim 04:00 » : chaque semaine, « Installer les logiciels »
                      (ce qui manque du catalogue, et les mises à jour) sur les
                      postes en ligne. Un poste en mode événement est laissé tel
                      quel : sa tâche se termine « ignorée », pas en échec.
    PCM_TZ            le fuseau de ces heures, Europe/Paris par défaut

« off » ou vide coupe une planification. Les tâches passent par la file
d'AVDiagram, comme un clic sur la page Postes : on les voit, avec leur
résultat, dans « Dernière tâche ».

Un créneau manqué (NAS arrêté à l'heure dite) n'est rattrapé que dans les
6 heures qui suivent : un inventaire n'a pas à partir au milieu d'une
journée d'événement.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone, tzinfo

DAYS = {
    "lun": 0, "mar": 1, "mer": 2, "jeu": 3, "ven": 4, "sam": 5, "dim": 6,
    "mon": 0, "tue": 1, "wed": 2, "thu": 3, "fri": 4, "sat": 5, "sun": 6,
}
CATCH_UP = timedelta(hours=6)
SPEC_RE = re.compile(r"^(?:(?P<day>[a-z]{3})\s+)?(?P<h>[01]?\d|2[0-3]):(?P<m>[0-5]\d)$")


class PlanningError(ValueError):
    pass


@dataclass(frozen=True)
class Slot:
    hour: int
    minute: int
    weekday: int | None = None  # None : chaque jour

    def label(self) -> str:
        day = "" if self.weekday is None else next(k for k, v in DAYS.items() if v == self.weekday) + " "
        return f"{day}{self.hour:02d}:{self.minute:02d}"

    def last_before(self, now: datetime) -> datetime:
        """Le dernier créneau à `now` ou avant (même fuseau que `now`)."""
        at = now.replace(hour=self.hour, minute=self.minute, second=0, microsecond=0)
        if self.weekday is None:
            return at if at <= now else at - timedelta(days=1)
        at -= timedelta(days=(at.weekday() - self.weekday) % 7)
        return at if at <= now else at - timedelta(days=7)

    def due(self, now: datetime, last_run: datetime | None) -> datetime | None:
        """Le créneau à faire maintenant, ou None."""
        at = self.last_before(now)
        if now - at > CATCH_UP:
            return None
        if last_run is not None and last_run >= at:
            return None
        return at


def parse_slot(spec: str | None) -> Slot | None:
    text = (spec or "").strip().lower()
    if text in ("", "off", "non", "0"):
        return None
    m = SPEC_RE.match(text)
    if not m:
        raise PlanningError(f"Heure de planification illisible : {spec!r} (ex. « 03:00 » ou « dim 04:00 »)")
    day = m.group("day")
    if day is not None and day not in DAYS:
        raise PlanningError(f"Jour illisible dans {spec!r} : lun, mar, mer, jeu, ven, sam ou dim")
    return Slot(int(m.group("h")), int(m.group("m")), DAYS[day] if day else None)


def zone(name: str | None) -> tzinfo:
    try:
        from zoneinfo import ZoneInfo

        return ZoneInfo(name or "Europe/Paris")
    except Exception:  # base des fuseaux absente de l'image : UTC, dit au journal
        return timezone.utc

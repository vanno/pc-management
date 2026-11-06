"""Un poste inventorié, de la sortie de l'agent jusqu'à sa fiche AVDiagram.

Partagé par `pcm inventory` (tout le parc, rapport JSON) et `pcm serve` (une
tâche demandée depuis la page Postes).
"""

from __future__ import annotations

from dataclasses import dataclass, field

from . import inventory as inv
from .avdiagram import AvdClient, AvdError, Unit, plan_update
from .meshctrl import Device
from .store import Store


@dataclass
class Outcome:
    entry: dict
    alerts: list[str] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)
    # La fiche a reçu l'inventaire détaillé (set_unit_inventory).
    details_sent: bool = False


def process(
    device: Device,
    data: dict,
    *,
    tag: str,
    store: Store,
    mapping: dict[str, str],
    avd: AvdClient | None = None,
    unit: Unit | None = None,
    push: bool = False,
    push_ip: bool = False,
    details: bool = True,
) -> Outcome:
    """Historise l'inventaire, le compare au précédent et, avec `push`, écrit la fiche.

    `avd` sans `unit` : le poste n'a pas de fiche, c'est une alerte.
    """
    hostname = (data.get("system") or {}).get("hostname") or ""
    previous = store.latest(tag)
    store.save(tag, device.id, inv.carry_over(data, previous))
    summ = inv.summary(data)
    changes = inv.diff(previous, data)
    out = Outcome(entry={"poste": tag, "meshcentral": device.name, **summ})
    if hostname.upper() != device.name.upper() and inv.asset_tag_for(hostname, mapping) != tag:
        out.alerts.append(f"{tag} : nom Windows {hostname} différent du nom MeshCentral {device.name}")
    if not changes.empty:
        out.entry["changements"] = changes.__dict__
    if summ["home_edition"]:
        out.alerts.append(f"{tag} : Windows édition Famille")

    if avd is None:
        return out
    if unit is None:
        out.alerts.append(f"{tag} : aucune fiche AVDiagram avec cette référence")
        return out

    to_write, warnings = plan_update(unit, summ, push_ip=push_ip)
    out.alerts.extend(warnings)
    out.entry["avdiagram"] = to_write or "à jour"
    if push and to_write:
        try:
            avd.update_unit(unit.asset_tag, **to_write)
            out.entry["avdiagram_ecrit"] = True
        except AvdError as exc:
            out.errors.append(str(exc))
    if push and details:
        # Un AVDiagram sans l'outil (avant la migration 0069) ne doit pas faire
        # échouer le passage : c'est un plus.
        try:
            avd.set_inventory(unit.asset_tag, inv.avd_payload(data, changes, previous=previous))
            out.entry["avdiagram_inventaire"] = True
            out.details_sent = True
        except AvdError as exc:
            out.alerts.append(f"{tag} : inventaire détaillé non envoyé ({exc})")
    return out

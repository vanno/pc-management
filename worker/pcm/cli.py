"""pcm : inventaire du parc PC par MeshCentral, synchronisé vers AVDiagram.

    pcm devices                       les postes vus par MeshCentral
    pcm inventory [--only PN01,PN02]  inventaire, rapport, historique local
    pcm inventory --push              idem, puis écriture des fiches AVDiagram

Sans --push, rien n'est écrit dans AVDiagram : le rapport dit ce qui le serait.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

from . import inventory as inv
from .avdiagram import AvdClient, AvdError, plan_update
from .meshctrl import Device, MeshCtrl, MeshError
from .store import Store


def load_mapping(path: str | None) -> dict[str, str]:
    if not path or not Path(path).exists():
        return {}
    return json.loads(Path(path).read_text(encoding="utf-8"))


def collect(mesh: MeshCtrl, device: Device, command: str) -> tuple[Device, dict | None, str | None]:
    try:
        return device, inv.parse_output(mesh.run_powershell(device.id, command)), None
    except (MeshError, inv.InventoryError) as exc:
        return device, None, str(exc)


def cmd_devices(args, mesh: MeshCtrl) -> int:
    for d in sorted(mesh.list_devices(args.group), key=lambda d: d.name):
        state = "en ligne" if d.online else "hors ligne"
        print(f"{d.name:<16} {state:<10} {d.group or '':<20} {d.os or ''}")
    return 0


def cmd_inventory(args, mesh: MeshCtrl) -> int:
    mapping = load_mapping(args.mapping)
    script_path = os.environ.get("PCM_AGENT_SCRIPT")
    command = inv.build_command(Path(script_path).read_text(encoding="utf-8") if script_path else None)

    devices = [d for d in mesh.list_devices(args.group) if d.is_windows]
    if args.only:
        wanted = {t.strip().upper() for t in args.only.split(",") if t.strip()}
        devices = [d for d in devices if inv.asset_tag_for(d.name, mapping) in wanted]

    report: dict = {"push": args.push, "postes": [], "hors_ligne": [], "erreurs": [], "alertes": []}
    online = [d for d in devices if d.online]
    report["hors_ligne"] = sorted(d.name for d in devices if not d.online)

    avd = None
    units = {}
    if args.push or args.check_avd:
        missing = [k for k in ("AVD_URL", "AVD_TOKEN") if not os.environ.get(k)]
        if missing:
            raise AvdError(f"Variables manquantes : {', '.join(missing)}")
        avd = AvdClient(os.environ["AVD_URL"], os.environ["AVD_TOKEN"])
        units = avd.computers()

    store = Store(args.db)
    with ThreadPoolExecutor(max_workers=args.concurrency) as pool:
        futures = [pool.submit(collect, mesh, d, command) for d in online]
        for future in as_completed(futures):
            device, data, error = future.result()
            if error:
                report["erreurs"].append(f"{device.name} : {error}")
                continue

            tag = inv.asset_tag_for(device.name, mapping)
            previous = store.latest(tag)
            store.save(tag, device.id, data)
            summ = inv.summary(data)
            changes = inv.diff(previous, data)
            entry = {"poste": tag, "meshcentral": device.name, **summ}
            if not changes.empty:
                entry["changements"] = changes.__dict__
            if summ["home_edition"]:
                report["alertes"].append(f"{tag} : Windows édition Famille")

            if avd is not None:
                unit = units.get(tag.upper())
                if unit is None:
                    report["alertes"].append(f"{tag} : aucune fiche AVDiagram avec cette référence")
                else:
                    to_write, warnings = plan_update(unit, summ, push_ip=args.push_ip)
                    report["alertes"].extend(warnings)
                    entry["avdiagram"] = to_write or "à jour"
                    if args.push and to_write:
                        try:
                            avd.update_unit(unit.asset_tag, **to_write)
                            entry["avdiagram_ecrit"] = True
                        except AvdError as exc:
                            report["erreurs"].append(str(exc))
            report["postes"].append(entry)

    report["postes"].sort(key=lambda e: e["poste"])
    store.save_run(report)
    json.dump(report, sys.stdout, ensure_ascii=False, indent=2)
    print()
    return 1 if report["erreurs"] else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="pcm", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--group", help="Groupe MeshCentral à cibler (tous par défaut)")
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("devices", help="Lister les postes")
    p = sub.add_parser("inventory", help="Inventorier les postes en ligne")
    p.add_argument("--only", help="Références de parc séparées par des virgules, ex. PN01,PN02")
    p.add_argument("--push", action="store_true", help="Écrire les fiches AVDiagram")
    p.add_argument("--check-avd", action="store_true", help="Comparer aux fiches AVDiagram sans rien écrire")
    p.add_argument("--push-ip", action="store_true", help="Écrire aussi l'adresse IP (changeante en DHCP)")
    p.add_argument("--concurrency", type=int, default=4)
    p.add_argument("--db", default=os.environ.get("PCM_DB", "data/pcm.sqlite"))
    p.add_argument("--mapping", default=os.environ.get("PCM_MAPPING", "config/mapping.json"))
    args = parser.parse_args(argv)

    mesh = MeshCtrl()
    try:
        return {"devices": cmd_devices, "inventory": cmd_inventory}[args.cmd](args, mesh)
    except (MeshError, AvdError) as exc:
        print(f"Erreur : {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())

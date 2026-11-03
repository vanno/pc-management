"""pcm : inventaire du parc PC par MeshCentral, synchronisé vers AVDiagram.

    pcm devices                       les postes vus par MeshCentral
    pcm inventory [--only PN01,PN02]  inventaire, rapport, historique local
    pcm inventory --push              idem, puis écriture des fiches AVDiagram
                                      (série, version Windows, inventaire détaillé)
    pcm serve                         service : exécute les tâches demandées
                                      depuis la page Postes d'AVDiagram

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
from .avdiagram import AvdClient, AvdError
from .meshctrl import Device, MeshCtrl, MeshError
from .store import Store
from .sync import process


def load_mapping(path: str | None) -> dict[str, str]:
    if not path or not Path(path).exists():
        return {}
    return json.loads(Path(path).read_text(encoding="utf-8"))


def collect(mesh: MeshCtrl, device: Device, script: str | None) -> tuple[Device, dict | None, str | None]:
    nonce = inv.new_nonce()
    try:
        output = mesh.run_powershell(device.id, inv.build_command(script, nonce))
        return device, inv.parse_output(output, nonce), None
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
    script = Path(script_path).read_text(encoding="utf-8") if script_path else None
    inv.build_command(script)  # refuse tout de suite un script trop long

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
        avd = avd_client()
        units = avd.computers()

    store = Store(args.db)
    with ThreadPoolExecutor(max_workers=args.concurrency) as pool:
        futures = [pool.submit(collect, mesh, d, script) for d in online]
        for future in as_completed(futures):
            device, data, error = future.result()
            if error:
                report["erreurs"].append(f"{device.name} : {error}")
                continue

            tag = inv.asset_tag_for(device.name, mapping)
            out = process(
                device,
                data,
                tag=tag,
                store=store,
                mapping=mapping,
                avd=avd,
                unit=units.get(tag.upper()),
                push=args.push,
                push_ip=args.push_ip,
                details=not args.no_details,
            )
            report["alertes"].extend(out.alerts)
            report["erreurs"].extend(out.errors)
            entry = out.entry
            report["postes"].append(entry)

    report["postes"].sort(key=lambda e: e["poste"])
    store.save_run(report)
    json.dump(report, sys.stdout, ensure_ascii=False, indent=2)
    print()
    return 1 if report["erreurs"] else 0


def avd_client() -> AvdClient:
    missing = [k for k in ("AVD_URL", "AVD_TOKEN") if not os.environ.get(k)]
    if missing:
        raise AvdError(f"Variables manquantes : {', '.join(missing)}")
    return AvdClient(os.environ["AVD_URL"], os.environ["AVD_TOKEN"])


def cmd_serve(args, mesh: MeshCtrl) -> int:
    from .service import Service, serve

    script_path = os.environ.get("PCM_AGENT_SCRIPT")
    script = Path(script_path).read_text(encoding="utf-8") if script_path else None
    inv.build_command(script)
    service = Service(
        mesh,
        avd_client(),
        Store(args.db),
        load_mapping(args.mapping),
        script=script,
        group=args.group,
        push_ip=args.push_ip,
    )
    return serve(service, interval=args.interval)


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
    p.add_argument("--no-details", action="store_true", help="Avec --push, ne pas envoyer l'inventaire détaillé (matériel, logiciels)")
    # meshctrl 1.2.5 répond à toutes ses commandes sous le même identifiant :
    # deux runcommand simultanés du même compte peuvent recevoir la réponse
    # l'un de l'autre. Le jeton détecte l'échange, mais un poste à la fois
    # l'évite. Ne monter qu'avec une version de meshctrl qui corrige ce point.
    p.add_argument("--concurrency", type=int, default=1)
    p.add_argument("--db", default=os.environ.get("PCM_DB", "data/pcm.sqlite"))
    p.add_argument("--mapping", default=os.environ.get("PCM_MAPPING", "config/mapping.json"))
    s = sub.add_parser("serve", help="Service : battement vers AVDiagram et tâches de la page Postes")
    s.add_argument("--interval", type=float, default=float(os.environ.get("PCM_INTERVAL", "30")), help="Secondes entre deux battements (30 par défaut)")
    s.add_argument("--push-ip", action="store_true", help="Écrire aussi l'adresse IP sur la fiche")
    s.add_argument("--db", default=os.environ.get("PCM_DB", "data/pcm.sqlite"))
    s.add_argument("--mapping", default=os.environ.get("PCM_MAPPING", "config/mapping.json"))
    args = parser.parse_args(argv)

    mesh = MeshCtrl()
    try:
        return {"devices": cmd_devices, "inventory": cmd_inventory, "serve": cmd_serve}[args.cmd](args, mesh)
    except (MeshError, AvdError) as exc:
        print(f"Erreur : {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())

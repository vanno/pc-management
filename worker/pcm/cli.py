"""pcm : inventaire du parc PC par MeshCentral, synchronisé vers AVDiagram.

    pcm devices                       les postes vus par MeshCentral
    pcm inventory [--only PN01,PN02]  inventaire, rapport, historique local
    pcm inventory --push              idem, puis écriture des fiches AVDiagram
                                      (série, version Windows, inventaire détaillé)
    pcm software --only PN09          installe le profil de logiciels sur ces postes
    pcm software --only PN09 --installers-only   seulement vMix, ATEM, DaVinci depuis le NAS
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


def cmd_software(args, mesh: MeshCtrl) -> int:
    from . import installers as ins
    from . import software as sw
    from .service import load_software

    mapping = load_mapping(args.mapping)
    avd = avd_client() if os.environ.get("AVD_URL") and os.environ.get("AVD_TOKEN") else None
    packages, installers = load_software(args.profile, args.installers, args.installers_dir, avd)
    if args.installers_only:
        packages = []
    wanted = {t.strip().upper() for t in args.only.split(",") if t.strip()}
    devices = [d for d in mesh.list_devices(args.group) if d.is_windows and inv.asset_tag_for(d.name, mapping).upper() in wanted]
    failed = False
    for d in devices:
        if not d.online:
            print(f"{d.name} : hors ligne")
            failed = True
            continue
        outcomes = []
        steps = [(p.id, lambda p=p: sw.install(mesh, d.id, p, inv.new_nonce())) for p in packages]
        steps += [(i.name, lambda i=i: ins.install(mesh, d.id, i, inv.new_nonce)) for i in installers]
        for label, run in steps:
            o = run()
            print(f"{d.name} {label} : {sw.LABELS[o.state]}{' : ' + o.detail if o.detail else ''}", flush=True)
            outcomes.append(o)
        print(f"{d.name} : {sw.summary(outcomes)}")
        failed = failed or not all(o.ok for o in outcomes)
    missing = wanted - {inv.asset_tag_for(d.name, mapping).upper() for d in devices}
    for tag in sorted(missing):
        print(f"{tag} : aucun agent MeshCentral à ce nom")
        failed = True
    return 1 if failed else 0


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
    from . import planning as plan
    from .meshctrl import MeshPipe

    # La session permanente (lot 5) : plusieurs postes en même temps.
    # PCM_MESHPIPE=0 revient à meshctrl, un poste à la fois.
    if os.environ.get("PCM_MESHPIPE", "1") != "0":
        mesh.pipe = MeshPipe()
    schedules = {
        "inventaire": plan.parse_slot(os.environ.get("PCM_INVENTORY_AT", "03:00")),
        "logiciels": plan.parse_slot(os.environ.get("PCM_UPDATE_AT", "dim 04:00")),
        "report": plan.parse_slot(os.environ.get("PCM_DEFER_AT", "lun 05:00")),
    }
    service = Service(
        mesh,
        avd_client(),
        Store(args.db),
        load_mapping(args.mapping),
        script=script,
        group=args.group,
        push_ip=args.push_ip,
        concurrency=int(os.environ.get("PCM_CONCURRENCY", "4")),
        schedules=schedules,
        tz=plan.zone(os.environ.get("PCM_TZ")),
    )
    try:
        return serve(service, interval=args.interval)
    finally:
        if mesh.pipe is not None:
            mesh.pipe.close()


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
    w = sub.add_parser("software", help="Installer le profil de logiciels sur des postes (winget, puis installeurs du NAS)")
    w.add_argument("--only", required=True, help="Références de parc séparées par des virgules, ex. PN09")
    w.add_argument("--profile", default=os.environ.get("PCM_SOFTWARE", "config/logiciels.json"))
    w.add_argument("--mapping", default=os.environ.get("PCM_MAPPING", "config/mapping.json"))
    w.add_argument("--installers", default=os.environ.get("PCM_INSTALLERS", "config/installeurs.json"))
    w.add_argument("--installers-dir", default=os.environ.get("PCM_INSTALLERS_DIR", "installeurs"))
    w.add_argument("--installers-only", action="store_true", help="Seulement les installeurs du NAS (vMix, ATEM, DaVinci), sans winget")
    s = sub.add_parser("serve", help="Service : battement vers AVDiagram et tâches de la page Postes")
    s.add_argument("--interval", type=float, default=float(os.environ.get("PCM_INTERVAL", "30")), help="Secondes entre deux battements (30 par défaut)")
    s.add_argument("--push-ip", action="store_true", help="Écrire aussi l'adresse IP sur la fiche")
    s.add_argument("--db", default=os.environ.get("PCM_DB", "data/pcm.sqlite"))
    s.add_argument("--mapping", default=os.environ.get("PCM_MAPPING", "config/mapping.json"))
    args = parser.parse_args(argv)

    mesh = MeshCtrl()
    try:
        return {"devices": cmd_devices, "inventory": cmd_inventory, "serve": cmd_serve, "software": cmd_software}[args.cmd](args, mesh)
    except (MeshError, AvdError, ValueError) as exc:
        print(f"Erreur : {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())

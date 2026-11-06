"""Lancement : `console-regie.exe` (ou `python -m regie`). La fenêtre reste
ouverte tant que la console tourne : la fermer arrête la console."""

from __future__ import annotations

import argparse
import sys
import threading
import time
import webbrowser
from pathlib import Path

from . import VERSION
from .decouverte import Annonce
from .identite import PORT_HTTPS, PORT_LOCAL, PORT_UDP, charger, dossier_par_defaut
from .serveur import Console, adresses_locales, demarrer
from .store import Store


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="console-regie", description="Console régie locale Pointe Noire")
    ap.add_argument("--dossier", type=Path, default=None, help=f"données de la console (défaut : {dossier_par_defaut()})")
    ap.add_argument("--port-local", type=int, default=PORT_LOCAL)
    ap.add_argument("--port-https", type=int, default=PORT_HTTPS)
    ap.add_argument("--port-udp", type=int, default=PORT_UDP)
    ap.add_argument("--sans-navigateur", action="store_true", help="ne pas ouvrir la page au lancement")
    ap.add_argument("--appairage", action="store_true", help="afficher le code d'appairage et quitter")
    a = ap.parse_args(argv)
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, OSError):
        pass

    ident = charger(a.dossier)
    if a.appairage:
        print(ident.code_appairage(a.port_https))
        return 0
    store = Store(ident.dossier / "console.sqlite")
    console = Console(ident, store, a.port_local, a.port_https, a.port_udp)
    try:
        demarrer(console)
        annonce = Annonce(ident.id, console.port_https, a.port_udp)
    except OSError as exc:
        print(f"Impossible d'écouter sur le réseau ({exc}). Une autre console tourne peut-être déjà sur ce PC.")
        input("Entrée pour fermer.")
        return 1
    annonce.demarrer()
    console.companion.demarrer()
    page = f"http://127.0.0.1:{console.port_local}/"
    print(f"Console régie {VERSION} : {ident.nom}")
    print(f"  Page de ce PC        {page}")
    for ip in adresses_locales():
        print(f"  Depuis un autre PC   https://{ip}:{console.port_https}/  (code {ident.code_page})")
    print(f"  Empreinte            {ident.empreinte}")
    print(f"  Données              {ident.dossier}")
    print("Fermer cette fenêtre arrête la console.")
    if not a.sans_navigateur:
        threading.Timer(1.0, lambda: webbrowser.open(page)).start()
    vu = 0
    try:
        while True:
            time.sleep(5)
            if console.recues != vu:
                vu = console.recues
                n = len(store.postes())
                print(f"\r{time.strftime('%H:%M:%S')}  {n} poste(s) suivis, {vu} envois reçus, {console.refusees} refusés   ", end="", flush=True)
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    sys.exit(main())

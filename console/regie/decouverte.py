"""La console se fait trouver sur le LAN : une sonde diffuse « PNC1? <id> »
sur le port UDP 8472, la console répond « PNC1 <id> <port https> » à
l'adresse qui a demandé. La réponse ne prouve rien : la sonde vérifie ensuite
l'empreinte du certificat de la console. Le pare-feu de Windows laisse passer
une réponse en unicast à une diffusion pendant 3 secondes, sans règle sur
les postes."""

from __future__ import annotations

import os
import socket
import threading

QUESTION = b"PNC1? "


def reponse(message: bytes, ident: str, port_https: int) -> bytes | None:
    if not message.startswith(QUESTION):
        return None
    demande = message[len(QUESTION):].strip().decode("ascii", "replace")
    if demande not in (ident, "*"):
        return None
    return f"PNC1 {ident} {port_https}".encode("ascii")


class Annonce:
    def __init__(self, ident: str, port_https: int, port_udp: int, hote: str = "0.0.0.0"):
        self.ident = ident
        self.port_https = port_https
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        if os.name != "nt":
            # Sous Windows, SO_REUSEADDR laisserait un autre programme prendre le port.
            self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind((hote, port_udp))
        self.sock.settimeout(1.0)
        self.port = self.sock.getsockname()[1]
        self._arret = threading.Event()
        self.questions = 0

    def tourner(self) -> None:
        while not self._arret.is_set():
            try:
                message, source = self.sock.recvfrom(512)
            except socket.timeout:
                continue
            except OSError:
                if self._arret.is_set():
                    return
                continue
            r = reponse(message, self.ident, self.port_https)
            if r:
                self.questions += 1
                try:
                    self.sock.sendto(r, source)
                except OSError:
                    pass

    def demarrer(self) -> threading.Thread:
        t = threading.Thread(target=self.tourner, name="annonce", daemon=True)
        t.start()
        return t

    def arreter(self) -> None:
        self._arret.set()
        self.sock.close()

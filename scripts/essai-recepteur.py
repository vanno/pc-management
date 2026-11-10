"""Le récepteur de scripts/essai-veille.ps1 : un faux AVDiagram en HTTPS sur
127.0.0.1, qui note chaque POST (chemin, jeton, corps) dans un fichier, une
ligne JSON par envoi, et répond comme /api/v1/postes/reseau.

    python essai-recepteur.py <cert.pem> <cle.pem> <recus.jsonl> <port>
"""

import json
import ssl
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

CERT, KEY, OUT, PORT = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])


class Recepteur(BaseHTTPRequestHandler):
    def do_POST(self):  # noqa: N802 (nom imposé par http.server)
        body = self.rfile.read(int(self.headers.get("content-length") or 0)).decode("utf-8", "replace")
        with open(OUT, "a", encoding="utf-8") as f:
            f.write(json.dumps({"path": self.path, "authorization": self.headers.get("authorization"), "type": self.headers.get("content-type"), "body": body}) + "\n")
        try:
            written = len(json.loads(body).get("minutes") or [])
        except (ValueError, AttributeError):
            written = 0
        reply = json.dumps({"written": written}).encode("utf-8")
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(reply)))
        self.end_headers()
        self.wfile.write(reply)

    def log_message(self, *args):
        pass


context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(CERT, KEY)
server = HTTPServer(("127.0.0.1", PORT), Recepteur)
server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()

"""L'identité de la console : un certificat auto-signé dont l'empreinte est
épinglée par les sondes, un secret qui sert à vérifier le jeton de chaque
poste, le code de la page vue d'un autre appareil et le jeton de Companion.
Tout est tiré une fois, au premier lancement, et gardé dans le dossier de
la console."""

from __future__ import annotations

import base64
import datetime as dt
import hashlib
import hmac
import json
import os
import re
import secrets
from dataclasses import dataclass, field
from pathlib import Path

PREFIXE_APPAIRAGE = "PNC1-"
REFERENCE_RE = re.compile(r"^[\w .-]{1,60}$")
PORT_HTTPS = 8471
PORT_LOCAL = 8470
PORT_UDP = 8472


def dossier_par_defaut() -> Path:
    if os.environ.get("PN_CONSOLE_DIR"):
        return Path(os.environ["PN_CONSOLE_DIR"])
    base = os.environ.get("LOCALAPPDATA")
    if base:
        return Path(base) / "PointeNoire" / "ConsoleRegie"
    return Path.home() / ".pointenoire-console"


def jeton_poste(secret: str, reference: str) -> str:
    """Le jeton qu'un poste présente à la console. Le relais le calcule à la
    pose de la sonde avec le même secret : la console n'a aucune liste à tenir,
    et un poste ne connaît que le sien."""
    mac = hmac.new(secret.encode("ascii"), ("sonde:" + reference.strip().upper()).encode("utf-8"), hashlib.sha256).digest()
    return "pnr_" + base64.urlsafe_b64encode(mac).decode("ascii").rstrip("=")


def empreinte_der(der: bytes) -> str:
    return hashlib.sha256(der).hexdigest()


@dataclass
class Identite:
    dossier: Path
    id: str
    nom: str
    secret: str
    code_page: str
    jeton_companion: str
    empreinte: str
    reglages: dict = field(default_factory=dict)

    @property
    def certificat(self) -> Path:
        return self.dossier / "certificat.pem"

    @property
    def cle(self) -> Path:
        return self.dossier / "cle.pem"

    def code_appairage(self, port: int = PORT_HTTPS) -> str:
        """Ce que le relais du NAS doit connaître pour poser la console sur les
        sondes (config/consoles.json). Il contient le secret : à garder pour soi."""
        data = {"v": 1, "id": self.id, "nom": self.nom, "empreinte": self.empreinte, "secret": self.secret, "port": port}
        brut = json.dumps(data, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        return PREFIXE_APPAIRAGE + base64.urlsafe_b64encode(brut).decode("ascii").rstrip("=")

    def verifier_poste(self, reference: str, jeton: str) -> bool:
        return bool(jeton) and hmac.compare_digest(jeton_poste(self.secret, reference), jeton)

    def enregistrer(self) -> None:
        data = {"id": self.id, "nom": self.nom, "secret": self.secret, "code_page": self.code_page, "jeton_companion": self.jeton_companion, **self.reglages}
        ecrire_prive(self.dossier / "identite.json", json.dumps(data, indent=2, ensure_ascii=False))


def ecrire_prive(chemin: Path, texte: str) -> None:
    tmp = chemin.with_suffix(chemin.suffix + ".tmp")
    tmp.write_text(texte, encoding="utf-8")
    try:
        os.chmod(tmp, 0o600)
    except OSError:
        pass
    os.replace(tmp, chemin)


def _creer_certificat(dossier: Path, ident: str) -> None:
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.x509.oid import NameOID

    # RSA 2048 : ce que le TLS de Windows PowerShell 5.1 accepte partout.
    cle = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    nom = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, f"Console regie Pointe Noire {ident}")])
    maintenant = dt.datetime.now(dt.timezone.utc)
    cert = (
        x509.CertificateBuilder()
        .subject_name(nom)
        .issuer_name(nom)
        .public_key(cle.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(maintenant - dt.timedelta(days=1))
        .not_valid_after(maintenant + dt.timedelta(days=3650))
        .add_extension(x509.SubjectAlternativeName([x509.DNSName("console-regie")]), critical=False)
        .sign(cle, hashes.SHA256())
    )
    ecrire_prive(dossier / "cle.pem", cle.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()).decode("ascii"))
    (dossier / "certificat.pem").write_bytes(cert.public_bytes(serialization.Encoding.PEM))


def _empreinte_fichier(chemin: Path) -> str:
    import ssl

    return empreinte_der(ssl.PEM_cert_to_DER_cert(chemin.read_text(encoding="ascii")))


def charger(dossier: Path | None = None, nom_par_defaut: str | None = None) -> Identite:
    dossier = Path(dossier or dossier_par_defaut())
    dossier.mkdir(parents=True, exist_ok=True)
    fichier = dossier / "identite.json"
    data = json.loads(fichier.read_text(encoding="utf-8")) if fichier.exists() else {}
    avant = dict(data)
    data.setdefault("id", secrets.token_hex(4))
    data.setdefault("nom", nom_par_defaut or f"Régie {os.environ.get('COMPUTERNAME') or 'locale'}")
    data.setdefault("secret", secrets.token_urlsafe(32))
    data.setdefault("code_page", f"{secrets.randbelow(1_000_000):06d}")
    data.setdefault("jeton_companion", "pnc_" + secrets.token_urlsafe(24))
    if not (dossier / "certificat.pem").exists() or not (dossier / "cle.pem").exists():
        _creer_certificat(dossier, data["id"])
    reglages = {k: v for k, v in data.items() if k not in ("id", "nom", "secret", "code_page", "jeton_companion")}
    ident = Identite(dossier, data["id"], data["nom"], data["secret"], data["code_page"], data["jeton_companion"], _empreinte_fichier(dossier / "certificat.pem"), reglages)
    if data != avant:
        ident.enregistrer()
    return ident


def lire_appairage(code: str) -> dict:
    """Le code d'appairage relu (même format que celui du relais)."""
    code = (code or "").strip()
    if not code.startswith(PREFIXE_APPAIRAGE):
        raise ValueError("code d'appairage illisible")
    brut = code[len(PREFIXE_APPAIRAGE):]
    return json.loads(base64.urlsafe_b64decode(brut + "=" * (-len(brut) % 4)))

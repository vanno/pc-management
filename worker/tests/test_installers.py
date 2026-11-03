import base64
import json
import tempfile
import unittest
from pathlib import Path

from pcm import installers as ins
from pcm.meshctrl import MeshError


def reply(nonce, **data):
    return "bruit\n" + ins.MARKER + nonce + ":" + base64.b64encode(json.dumps(data).encode()).decode() + "\n"


def params_of(command):
    raw = command.split("$env:PNIN_PARAMS='", 1)[1].split("'", 1)[0]
    return json.loads(base64.b64decode(raw))


class FakeMesh:
    """Répond aux modes check et install, note les envois."""

    def __init__(self, found=False, version=None, free=10**12, code=0, upload_error=None):
        self.found, self.version, self.free, self.code = found, version, free, code
        self.upload_error = upload_error
        self.calls = []

    def run_powershell(self, device_id, command, timeout=None):
        nonce = command.split("$env:PNIN_NONCE='", 1)[1].split("'", 1)[0]
        p = params_of(command)
        self.calls.append((p["mode"], p, timeout))
        if p["mode"] == "check":
            return reply(nonce, found=self.found, name="vMix 29", version=self.version, free=self.free)
        return reply(nonce, code=self.code, output="")

    def upload(self, device_id, local_path, remote_dir, timeout=None):
        if self.upload_error:
            raise MeshError(self.upload_error)
        self.calls.append(("upload", (local_path, remote_dir), timeout))


def nonces():
    it = iter(f"{i:08x}" for i in range(1, 100))
    return lambda: next(it)


class InstallersTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name) / "installeurs"
        self.dir.mkdir()
        (self.dir / "vmix29.exe").write_bytes(b"x" * 1000)
        self.cfg = Path(self.tmp.name) / "installeurs.json"

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, items):
        self.cfg.write_text(json.dumps({"installeurs": items}))
        return ins.load_installers(self.cfg, self.dir)

    def vmix(self, **kw):
        item = {"nom": "vMix", "fichier": "vmix29.exe", "detection": "vMix*", "arguments": "/VERYSILENT"}
        item.update(kw)
        return self.write([item])[0]

    def test_example_list_is_valid(self):
        example = Path(__file__).resolve().parents[2] / "config" / "installeurs.example.json"
        names = [i.name for i in ins.load_installers(example, self.dir)]
        self.assertEqual(names, ["vMix", "Blackmagic ATEM Switchers", "DaVinci Resolve", "Microsoft 365"])

    def test_missing_list_means_no_installers(self):
        self.assertEqual(ins.load_installers(self.cfg, self.dir), [])

    def test_refuses_paths_and_missing_detection(self):
        for bad in ("..\\evil.exe", "a/b.exe", "setup.bat", ""):
            with self.assertRaises(ins.InstallerError):
                self.write([{"nom": "x", "fichier": bad, "detection": "x*"}])
        with self.assertRaises(ins.InstallerError):
            self.write([{"nom": "x", "fichier": "x.msi"}])

    def test_parameters_cannot_break_out_of_the_command(self):
        cmd = ins.build_command({"mode": "install", "file": "a.exe", "args": "'; Remove-Item C:\\ -Recurse; '"}, "abc", script="x")
        self.assertEqual(cmd.count("'"), 6)
        self.assertEqual(params_of(cmd)["args"], "'; Remove-Item C:\\ -Recurse; '")

    def test_installs_when_missing(self):
        mesh = FakeMesh(found=False)
        o = ins.install(mesh, "node1", self.vmix(), nonces(), script="x")
        self.assertEqual((o.state, o.package.name), ("installed", "vMix"))
        self.assertEqual([c[0] for c in mesh.calls], ["check", "upload", "install"])
        upload = mesh.calls[1]
        self.assertEqual(upload[1][1], ins.REMOTE_DIR)
        self.assertEqual(upload[2], ins.upload_timeout(1000))
        self.assertEqual(mesh.calls[2][1]["args"], "/VERYSILENT")

    def test_present_without_version_is_up_to_date(self):
        mesh = FakeMesh(found=True, version="29.0.0.36")
        o = ins.install(mesh, "node1", self.vmix(), nonces(), script="x")
        self.assertEqual(o.state, "uptodate")
        self.assertEqual([c[0] for c in mesh.calls], ["check"])

    def test_other_version_is_updated(self):
        mesh = FakeMesh(found=True, version="28.0.0.40")
        o = ins.install(mesh, "node1", self.vmix(version="29"), nonces(), script="x")
        self.assertEqual(o.state, "updated")
        mesh = FakeMesh(found=True, version="29.0.0.36")
        self.assertEqual(ins.install(mesh, "n", self.vmix(version="29"), nonces(), script="x").state, "uptodate")
        self.assertFalse(ins.same_version("290.1", "29"))

    def test_reboot_and_msi_errors(self):
        self.assertEqual(ins.install(FakeMesh(code=3010), "n", self.vmix(), nonces(), script="x").state, "reboot")
        o = ins.install(FakeMesh(code=1618), "n", self.vmix(), nonces(), script="x")
        self.assertEqual((o.state, o.detail), ("failed", "une autre installation est en cours sur le poste"))

    def test_not_enough_space_and_missing_file_and_upload_failure(self):
        o = ins.install(FakeMesh(free=2000), "n", self.vmix(), nonces(), script="x")
        self.assertIn("place insuffisante", o.detail)
        (self.dir / "vmix29.exe").unlink()
        o = ins.install(FakeMesh(), "n", self.vmix(), nonces(), script="x")
        self.assertIn("absent du dossier installeurs", o.detail)
        (self.dir / "vmix29.exe").write_bytes(b"x")
        mesh = FakeMesh(upload_error="meshctrl upload : envoi non terminé : Upload error.")
        o = ins.install(mesh, "n", self.vmix(), nonces(), script="x")
        self.assertEqual(o.state, "failed")
        self.assertIn("Upload error", o.detail)
        self.assertEqual([c[0] for c in mesh.calls], ["check"])

    def test_reply_from_another_command_is_refused(self):
        with self.assertRaises(ins.InstallerError):
            ins.parse_output(reply("aaaa", code=0), "bbbb")


class UploadTests(unittest.TestCase):
    def test_upload_reads_meshctrl_output(self):
        from pcm.meshctrl import MeshCtrl

        class M(MeshCtrl):
            def __init__(self, out):
                self.out = out

            def _run(self, *args, timeout=None):
                self.args = args
                return self.out

        m = M("Connected.\nUploading...\nUpload done, 1000 bytes sent.\n")
        m.upload("node1", "/installeurs/a.exe", "C:\\x", timeout=5)
        self.assertEqual(m.args[:7], ("upload", "--id", "node1", "--file", "/installeurs/a.exe", "--target", "C:\\x"))
        with self.assertRaises(MeshError):
            M("Connected.\nUploading...\nUpload error.\n").upload("n", "a", "b")


if __name__ == "__main__":
    unittest.main()

import os
import sys
import unittest
from unittest import mock

from pcm.meshctrl import MeshCtrl, MeshError



def mesh_printing(text: str) -> MeshCtrl:
    m = MeshCtrl()
    m.command = [sys.executable, "-c", f"print({text!r})"]
    return m


ENV = {"MESHCTRL_URL": "wss://mesh.example", "MESHCTRL_LOGINUSER": "worker", "MESHCTRL_LOGINPASS": "secret"}


class LoginArgsTests(unittest.TestCase):
    def test_credentials_passed_as_arguments(self):
        with mock.patch.dict(os.environ, ENV, clear=True):
            self.assertEqual(
                MeshCtrl()._login_args(),
                ["--url", "wss://mesh.example", "--loginuser", "worker", "--loginpass", "secret"],
            )

    def test_missing_url(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            with self.assertRaises(MeshError):
                MeshCtrl()._login_args()


class ErrorDetectionTests(unittest.TestCase):
    def test_connection_failure_with_exit_code_zero(self):
        with mock.patch.dict(os.environ, ENV, clear=True):
            with self.assertRaisesRegex(MeshError, "Unable to connect"):
                mesh_printing("Unable to connect to wss://mesh.example/control.ashx").list_devices()

    def test_invalid_login(self):
        with mock.patch.dict(os.environ, ENV, clear=True):
            with self.assertRaisesRegex(MeshError, "Invalid login"):
                mesh_printing("Invalid login.").list_devices()

    def test_json_ok(self):
        with mock.patch.dict(os.environ, ENV, clear=True):
            devices = mesh_printing('[{"_id": "node//a", "name": "PN01", "conn": 1}]').list_devices()
            self.assertEqual(devices[0].name, "PN01")


class MessageTests(unittest.TestCase):
    def test_toast_passes_message_after_equals_sign(self):
        m = MeshCtrl()
        m.command = [sys.executable, "-c", "import sys; print('ok' if '--msg=-- urgent' in sys.argv and '--title=Régie' in sys.argv else 'bad')"]
        with mock.patch.dict(os.environ, ENV, clear=True):
            m.toast("node//a", "-- urgent", "Régie")

    def test_toast_refused(self):
        with mock.patch.dict(os.environ, ENV, clear=True):
            with self.assertRaisesRegex(MeshError, "Access Denied"):
                mesh_printing("Access Denied").toast("node//a", "x", "y")

    def test_message_box_without_answer_counts_as_relayed(self):
        m = MeshCtrl()
        m.command = [sys.executable, "-c", "import time; time.sleep(30)"]
        with mock.patch.dict(os.environ, ENV, clear=True), mock.patch("subprocess.run", side_effect=__import__("subprocess").TimeoutExpired("meshctrl", 20)):
            self.assertEqual(m.message_box("node//a", "x", "y"), "relayée")

    def test_message_box_unroutable(self):
        with mock.patch.dict(os.environ, ENV, clear=True):
            with self.assertRaisesRegex(MeshError, "Unable to route"):
                mesh_printing("Unable to route").message_box("node//a", "x", "y")


if __name__ == "__main__":
    unittest.main()

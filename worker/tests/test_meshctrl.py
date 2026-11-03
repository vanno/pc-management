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


if __name__ == "__main__":
    unittest.main()

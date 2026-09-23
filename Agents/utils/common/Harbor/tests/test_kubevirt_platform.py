"""Offline unit tests for the platform-HTTP lifecycle and request builder."""

from __future__ import annotations

import contextlib
import os
import tempfile
import unittest
from pathlib import Path

from kubevirt_windows.control import Settings

VALID_ENV = {
    "HARBOR_KUBEVIRT_BASE_URL": "http://10.9.202.91:31600",
    "HARBOR_KUBEVIRT_TOKEN": "tok",
    "HARBOR_KUBEVIRT_IMAGE": "ubuntu20.04-template-image",
    "HARBOR_KUBEVIRT_NAMESPACE": "default",
    "HARBOR_KUBEVIRT_SSH_USER": "runner",
    "HARBOR_KUBEVIRT_SSH_PORT": "22",
    "HARBOR_KUBEVIRT_START_TIMEOUT": "600",
    "HARBOR_KUBEVIRT_COMMAND_TIMEOUT": "3600",
    "HARBOR_KUBEVIRT_TRANSFER_TIMEOUT": "300",
}


@contextlib.contextmanager
def _pristine_harbor_env():
    saved = {}
    for key in list(os.environ):
        if key.startswith("HARBOR_KUBEVIRT_"):
            saved[key] = os.environ.pop(key)
    try:
        yield
    finally:
        os.environ.update(saved)


def make_settings(overrides: dict, ssh_key: Path) -> Settings:
    with _pristine_harbor_env():
        env = {**VALID_ENV, "HARBOR_KUBEVIRT_SSH_KEY": str(ssh_key), **overrides}
        os.environ.update(env)
        return Settings.from_env()


class SettingsTests(unittest.TestCase):
    def test_requires_platform_url_token_and_image(self):
        with tempfile.TemporaryDirectory() as tmp:
            key = Path(tmp) / "id_rsa"
            key.touch()
            with self.assertRaises(ValueError):
                make_settings({"HARBOR_KUBEVIRT_BASE_URL": ""}, key)
            with self.assertRaises(ValueError):
                make_settings({"HARBOR_KUBEVIRT_TOKEN": ""}, key)
            with self.assertRaises(ValueError):
                make_settings({"HARBOR_KUBEVIRT_IMAGE": ""}, key)

    def test_rejects_bad_url_scheme(self):
        with tempfile.TemporaryDirectory() as tmp:
            key = Path(tmp) / "id_rsa"
            key.touch()
            with self.assertRaises(ValueError):
                make_settings({"HARBOR_KUBEVIRT_BASE_URL": "ftp://bad"}, key)

    def test_rejects_bad_namespace(self):
        with tempfile.TemporaryDirectory() as tmp:
            key = Path(tmp) / "id_rsa"
            key.touch()
            with self.assertRaises(ValueError):
                make_settings({"HARBOR_KUBEVIRT_NAMESPACE": "Bad_NS"}, key)

    def test_rejects_missing_ssh_key(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(FileNotFoundError):
                make_settings({}, Path(tmp) / "missing-key")
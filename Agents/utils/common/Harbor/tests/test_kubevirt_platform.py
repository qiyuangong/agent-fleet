"""Offline unit tests for the platform-HTTP lifecycle and request builder."""

from __future__ import annotations

import contextlib
import json
import os
import tempfile
import unittest
from pathlib import Path

import httpx

from kubevirt_windows.control import (
    DEFAULT_CPU_CORES,
    DEFAULT_CPU_SOCKETS,
    DEFAULT_DISK_SIZE,
    DEFAULT_MEMORY_GUEST,
    Platform,
    PlatformAPIError,
    PlatformControl,
    Settings,
    build_create_request,
)

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


@contextlib.contextmanager
def _tmp_key():
    with tempfile.TemporaryDirectory() as tmp:
        key = Path(tmp) / "id_rsa"
        key.touch()
        yield key


def build_settings():
    with _tmp_key() as key:
        return Settings(
            platform=Platform(base_url="http://10.9.202.91:31600", token="tok"),
            image="ubuntu20.04-template-image",
            namespace="default",
            ssh_user="runner",
            ssh_key=key,
            subnet="ovn-default",
            storage_class="ceph-rbd-sc",
        )


class CreateRequestTests(unittest.TestCase):
    def test_build_create_request_shape(self):
        settings = build_settings()
        request = build_create_request(settings, "trial-a1b2", "10.16.0.4")
        self.assertEqual(
            request,
            {
                "name": "trial-a1b2",
                "namespace": "default",
                "createType": "template",
                "compute": {
                    "cpuCores": DEFAULT_CPU_CORES,
                    "cpuSockets": DEFAULT_CPU_SOCKETS,
                    "memoryGuest": DEFAULT_MEMORY_GUEST,
                },
                "network": {"subnetName": "ovn-default", "ipAddress": "10.16.0.4"},
                "storage": {
                    "rootDisk": {
                        "imageName": "ubuntu20.04-template-image",
                        "size": DEFAULT_DISK_SIZE,
                        "storageClassName": "ceph-rbd-sc",
                    }
                },
            },
        )
        self.assertNotIn("labels", request)

    def test_build_create_request_includes_labels_when_provided(self):
        settings = build_settings()
        labels = [{"key": "agent-fleet/trial", "value": "abc"}]
        request = build_create_request(settings, "trial-a1b2", "10.16.0.4", labels)
        self.assertEqual(request["labels"], labels)

    def test_build_create_request_rejects_bad_name(self):
        settings = build_settings()
        for bad in ("UPPER_CASE", "with space", "A", ""):
            with self.assertRaises(ValueError):
                build_create_request(settings, bad, "10.16.0.4")


class PlatformControlTests(unittest.IsolatedAsyncioTestCase):
    def _control(self, handler) -> PlatformControl:
        transport = httpx.MockTransport(handler)
        settings = build_settings()
        return PlatformControl(settings, transport=transport)

    async def test_create_and_get_and_stop_and_delete_routes(self):
        calls = []

        def handler(request: httpx.Request) -> httpx.Response:
            calls.append(
                (request.method, request.url.path, request.content.decode())
            )
            path = request.url.path
            if request.method == "POST" and path.endswith("/virtualmachines"):
                return httpx.Response(200, json={"code": 200, "message": "ok", "data": {"name": "trial-a1b2"}})
            if request.method == "GET":
                return httpx.Response(
                    200,
                    json={
                        "code": 200,
                        "message": "ok",
                        "data": {
                            "name": "trial-a1b2",
                            "namespace": "default",
                            "ipAddress": "10.16.0.4",
                            "ready": True,
                            "labels": {"agent-fleet/trial": "abc"},
                            "printableStatus": "Running",
                            "uid": "uid-1",
                        },
                    },
                )
            if request.method == "PUT" and path.endswith("/virtualmachines/stop"):
                return httpx.Response(200, json={"code": 200, "message": "ok", "data": {}})
            if request.method == "DELETE":
                return httpx.Response(200, json={"code": 200, "message": "ok", "data": {}})
            return httpx.Response(404, json={"code": 404, "message": "not found"})

        control = self._control(handler)
        async with control:
            created = await control.create("trial-a1b2", "10.16.0.4")
            self.assertEqual(created, {"name": "trial-a1b2"})
            vm = await control.get("trial-a1b2")
            self.assertEqual(vm["ip"], "10.16.0.4")
            self.assertTrue(vm["ready"])
            self.assertEqual(vm["status"], "Running")
            self.assertEqual(vm["uid"], "uid-1")
            await control.stop("trial-a1b2")
            await control.delete("trial-a1b2")

        methods = [c[0] for c in calls]
        self.assertEqual(
            methods, ["POST", "GET", "PUT", "DELETE"]
        )
        self.assertEqual(
            [c[1] for c in calls],
            [
                "/api/v1/virtualmachines",
                "/api/v1/virtualmachines/default/trial-a1b2",
                "/api/v1/virtualmachines/stop",
                "/api/v1/virtualmachines/default/trial-a1b2",
            ],
        )
        create_body = json.loads(calls[0][2])
        self.assertEqual(create_body["name"], "trial-a1b2")
        self.assertEqual(create_body["network"]["ipAddress"], "10.16.0.4")
        stop_body = json.loads(calls[2][2])
        self.assertEqual(stop_body, {"namespace": "default", "name": "trial-a1b2"})

    async def test_raise_for_envelope_error(self):
        def handler(request: httpx.Request) -> httpx.Response:
            return httpx.Response(
                200,
                json={"code": 400, "message": "创建类型必须为 iso 或 template", "data": None},
            )

        control = self._control(handler)
        async with control:
            with self.assertRaises(PlatformAPIError) as ctx:
                await control.create("trial-a1b2", "10.16.0.4")
            self.assertIn("创建类型必须为 iso 或 template", str(ctx.exception))

    async def test_raise_for_http_status_error(self):
        def handler(request: httpx.Request) -> httpx.Response:
            return httpx.Response(500, json={"code": 500, "message": "boom"})

        control = self._control(handler)
        async with control:
            with self.assertRaises(httpx.HTTPStatusError):
                await control.get("trial-a1b2")

    async def test_ping_ok(self):
        captured = []

        def handler(request: httpx.Request) -> httpx.Response:
            captured.append(request.url.path)
            return httpx.Response(
                200, json={"code": 200, "message": "ok", "data": {"name": "me"}}
            )

        control = self._control(handler)
        async with control:
            self.assertTrue(await control.ping())
            self.assertEqual(captured, ["/api/v1/users/me"])

    async def test_ping_rejects_bad_token(self):
        def handler(request: httpx.Request) -> httpx.Response:
            return httpx.Response(401, json={"code": 401, "message": "unauthorized"})

        control = self._control(handler)
        async with control:
            self.assertFalse(await control.ping())
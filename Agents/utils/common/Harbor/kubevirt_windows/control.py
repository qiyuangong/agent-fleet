"""KubeVirt lifecycle via kubectl; no credentials are copied into the guest."""

from __future__ import annotations

import asyncio
import copy
import json
import os
import re
import signal
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import httpx
import yaml

OWNER_LABEL = "agent-fleet/trial"

DEFAULT_CPU_CORES = 2
DEFAULT_CPU_SOCKETS = 1
DEFAULT_MEMORY_GUEST = "4Gi"
DEFAULT_DISK_SIZE = 32

# Lowercase RFC 1123 DNS subdomain (max 63): what the platform requires for VM
# names because it auto-creates a guest-credential Secret named after the VM.
RFC1123_NAME_RE = re.compile(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?")


class PlatformAPIError(RuntimeError):
    """Raised when the platform returns a non-2xx HTTP status or envelope code."""


async def run_process(
    argv, *, data=None, timeout=60, max_output_bytes=16 * 1024 * 1024
):
    """Bound subprocess output/lifetime, including ProxyCommand descendants."""
    process = await asyncio.create_subprocess_exec(
        *map(str, argv),
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        start_new_session=True,
    )

    async def read_bounded(stream):
        output = bytearray()
        while chunk := await stream.read(65536):
            if len(output) + len(chunk) > max_output_bytes:
                raise RuntimeError(f"{Path(argv[0]).name} exceeded its output limit")
            output.extend(chunk)
        return bytes(output)

    async def write_input():
        try:
            if data:
                process.stdin.write(data)
                await process.stdin.drain()
            process.stdin.close()
            await process.stdin.wait_closed()
        except (BrokenPipeError, ConnectionResetError):
            pass  # Report the subprocess exit status after collecting stderr.

    tasks = [
        asyncio.create_task(coro)
        for coro in (
            read_bounded(process.stdout),
            read_bounded(process.stderr),
            write_input(),
            process.wait(),
        )
    ]
    try:
        stdout, stderr, _, _ = await asyncio.wait_for(asyncio.gather(*tasks), timeout)
    except BaseException:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        await process.wait()
        raise
    if process.returncode:
        # Do not print argv or stdin: requests can contain guest credentials.
        raise RuntimeError(
            f"{Path(argv[0]).name} failed ({process.returncode}): "
            f"{stderr.decode(errors='replace')[-4000:]}"
        )
    return stdout


URL_RE = re.compile(r"^https?://", re.IGNORECASE)
NS_RE = re.compile(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?")


@dataclass(frozen=True)
class Platform:
    base_url: str
    token: str


@dataclass(frozen=True)
class Settings:
    platform: Platform
    image: str
    namespace: str
    ssh_user: str
    ssh_key: Path
    subnet: str
    storage_class: str
    ssh_port: int = 22
    start_timeout: int = 600
    command_timeout: int = 3600
    transfer_timeout: int = 300

    @classmethod
    def from_env(cls):
        def required(key):
            value = os.environ.get("HARBOR_KUBEVIRT_" + key, "")
            if not value:
                raise ValueError(f"HARBOR_KUBEVIRT_{key} is required")
            return value

        base_url = required("BASE_URL")
        if not URL_RE.match(base_url):
            raise ValueError("HARBOR_KUBEVIRT_BASE_URL must use http:// or https://")
        namespace = required("NAMESPACE")
        if not NS_RE.fullmatch(namespace):
            raise ValueError("Invalid Kubernetes namespace")
        ssh_user = required("SSH_USER")
        if not ssh_user or any(c in ssh_user for c in "\r\n\x00@"):
            raise ValueError("Invalid SSH user")
        ssh_key = Path(required("SSH_KEY")).expanduser()
        if not ssh_key.is_file():
            raise FileNotFoundError(ssh_key)
        image = required("IMAGE")
        subnet = os.environ.get("HARBOR_KUBEVIRT_SUBNET", "ovn-default")
        storage_class = os.environ.get("HARBOR_KUBEVIRT_STORAGE_CLASS", "ceph-rbd-sc")

        def as_int(key, default):
            value = os.environ.get("HARBOR_KUBEVIRT_" + key)
            try:
                return int(value) if value is not None and value != "" else default
            except ValueError:
                raise ValueError(
                    f"HARBOR_KUBEVIRT_{key} must be an integer, got {value!r}"
                ) from None

        ssh_port = as_int("SSH_PORT", 22)
        start_timeout = as_int("START_TIMEOUT", 600)
        command_timeout = as_int("COMMAND_TIMEOUT", 3600)
        transfer_timeout = as_int("TRANSFER_TIMEOUT", 300)
        if min(start_timeout, command_timeout, transfer_timeout) <= 0:
            raise ValueError("Timeouts must be positive")
        if not 1 <= ssh_port <= 65535:
            raise ValueError("SSH port must be between 1 and 65535")
        return cls(
            platform=Platform(base_url=base_url, token=required("TOKEN")),
            image=image,
            namespace=namespace,
            ssh_user=ssh_user,
            ssh_key=ssh_key,
            subnet=subnet,
            storage_class=storage_class,
            ssh_port=ssh_port,
            start_timeout=start_timeout,
            command_timeout=command_timeout,
            transfer_timeout=transfer_timeout,
        )


def build_manifest(template, name, namespace, token, *, cpus=None, memory_mb=None):
    """Allocate new names for all disks; never attach an existing writable PVC."""
    vm = copy.deepcopy(template)
    if (
        not isinstance(vm, dict)
        or vm.get("apiVersion") != "kubevirt.io/v1"
        or vm.get("kind") != "VirtualMachine"
    ):
        raise ValueError("Template must be one kubevirt.io/v1 VirtualMachine")
    vm.pop("status", None)
    original_metadata = vm.get("metadata", {})
    vm["metadata"] = {
        "name": name,
        "namespace": namespace,
        "labels": {**original_metadata.get("labels", {}), OWNER_LABEL: token},
    }
    annotations = original_metadata.get("annotations", {}).copy()
    annotations.pop("kubectl.kubernetes.io/last-applied-configuration", None)
    vm["metadata"]["annotations"] = annotations
    spec = vm["spec"]
    spec.pop("running", None)
    spec["runStrategy"] = "Always"
    # Shared firmware state can defeat trial isolation.
    guest = spec["template"]["spec"]
    if (
        guest.get("domain", {})
        .get("firmware", {})
        .get("bootloader", {})
        .get("efi", {})
        .get("persistent")
    ):
        raise ValueError("Persistent EFI state is unsupported")
    if guest.get("domain", {}).get("devices", {}).get("tpm", {}).get("persistent"):
        raise ValueError("Persistent TPM state is unsupported")
    template_metadata = spec["template"].get("metadata", {})
    spec["template"]["metadata"] = {
        "labels": {**template_metadata.get("labels", {}), OWNER_LABEL: token},
        "annotations": template_metadata.get("annotations", {}),
    }
    names = {}
    for index, disk in enumerate(spec.get("dataVolumeTemplates", [])):
        old = disk["metadata"]["name"]
        if old in names:
            raise ValueError("Duplicate DataVolume template name")
        names[old] = f"{name}-disk-{index}"
        disk["metadata"] = {
            "name": names[old],
            "labels": {**disk["metadata"].get("labels", {}), OWNER_LABEL: token},
            "annotations": disk["metadata"].get("annotations", {}),
        }
        disk.pop("status", None)
        if not (
            disk.get("spec", {}).get("source") or disk.get("spec", {}).get("sourceRef")
        ):
            raise ValueError("Each DataVolume needs a source or sourceRef")
    boot_disk = False
    for volume in guest.get("volumes", []):
        if "dataVolume" in volume:
            old = volume["dataVolume"]["name"]
            if old not in names:
                raise ValueError(
                    "Every DataVolume must have a per-trial dataVolumeTemplate"
                )
            volume["dataVolume"]["name"] = names[old]
            boot_disk = True
        elif "containerDisk" in volume:
            boot_disk = True
        elif not any(
            key in volume
            for key in (
                "cloudInitNoCloud",
                "cloudInitConfigDrive",
                "sysprep",
                "secret",
                "configMap",
                "emptyDisk",
            )
        ):
            raise ValueError(
                "Unsupported volume: use dataVolumeTemplates for isolated disks"
            )
    if not boot_disk:
        raise ValueError("Template requires a DataVolume or containerDisk")
    domain = guest.setdefault("domain", {})
    # Let KubeVirt allocate instance identities rather than copying exported
    # golden-VM UUIDs or MAC addresses into every concurrently running clone.
    domain.get("firmware", {}).pop("uuid", None)
    for interface in domain.get("devices", {}).get("interfaces", []):
        interface.pop("macAddress", None)
    if cpus is not None:
        domain.setdefault("cpu", {}).update(cores=cpus, sockets=1, threads=1)
        domain["cpu"].pop("maxSockets", None)
        resources = domain.setdefault("resources", {})
        for key in ("requests", "limits"):
            resources.setdefault(key, {})["cpu"] = str(cpus)
    if memory_mb is not None:
        domain.setdefault("memory", {})["guest"] = f"{memory_mb}Mi"
        domain["memory"].pop("maxGuest", None)
        # Preserve KubeVirt's automatic virtualization overhead calculation.
        resources = domain.setdefault("resources", {})
        for key in ("requests", "limits"):
            resources.get(key, {}).pop("memory", None)
    return vm


class VMControl:
    def __init__(self, settings, name, token):
        self.settings, self.name, self.token = settings, name, token
        self.attempted = False

    async def kubectl(self, *args, data=None, timeout=60):
        return await run_process(
            ["kubectl", *self.settings.kube_args(), "--request-timeout=30s", *args],
            data=data,
            timeout=timeout,
        )

    async def create(self, manifest):
        self.attempted = True  # Also clean up an ambiguous create response.
        await self.kubectl("create", "-f", "-", data=json.dumps(manifest).encode())

    async def owned_vm(self):
        raw = await self.kubectl(
            "get", "virtualmachine", self.name, "--ignore-not-found", "-o", "json"
        )
        if not raw.strip():
            return None
        vm = json.loads(raw)
        if vm["metadata"].get("labels", {}).get(OWNER_LABEL) != self.token:
            raise RuntimeError("Refusing to mutate a VM owned by another trial")
        return vm

    async def stop(self, delete):
        if not self.attempted or await self.owned_vm() is None:
            return
        if delete:
            await self.kubectl(
                "delete",
                "virtualmachine",
                self.name,
                "--cascade=foreground",
                "--wait=true",
                "--timeout=120s",
                timeout=150,
            )
            self.attempted = False
        else:
            await self.kubectl(
                "patch",
                "virtualmachine",
                self.name,
                "--type=merge",
                "-p",
                '{"spec":{"runStrategy":"Halted"}}',
            )
            # Halted is a requested state; wait for the VMI to disappear.
            await self.kubectl(
                "wait",
                "--for=delete",
                f"virtualmachineinstance/{self.name}",
                "--timeout=120s",
                timeout=150,
            )


def load_template(path):
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def _api_base(base_url: str) -> str:
    """Normalize a human-supplied base URL into the API v1 endpoint."""
    return base_url.rstrip("/") + "/api/v1"


def raise_for_platform(response: httpx.Response) -> None:
    """Raise if the HTTP status or the envelope's `code` is not 2xx."""
    try:
        response.raise_for_status()
    except httpx.HTTPStatusError as exc:
        raise exc from None
    try:
        payload = response.json()
    except (ValueError, TypeError):
        return  # No JSON envelope to inspect; the HTTP status already passed.
    if not isinstance(payload, dict):
        return
    code = payload.get("code")
    if isinstance(code, int) and not 200 <= code < 300:
        raise PlatformAPIError(
            f"Platform API error (code={code}): {payload.get('message', '')}"
        )


def build_create_request(
    settings: Settings, name: str, ip: str, labels: list[dict] | None = None
) -> dict:
    """Build the CreateVMRequest envelope accepted by POST /virtualmachines."""
    if not name or not RFC1123_NAME_RE.fullmatch(name):
        raise ValueError(
            "VM name must be a lowercase RFC1123 DNS subdomain (max 63 chars)"
        )
    if not ip:
        raise ValueError("A subnet IP address is required")
    request: dict[str, Any] = {
        "name": name,
        "namespace": settings.namespace,
        "createType": "template",
        "compute": {
            "cpuCores": DEFAULT_CPU_CORES,
            "cpuSockets": DEFAULT_CPU_SOCKETS,
            "memoryGuest": DEFAULT_MEMORY_GUEST,
        },
        "network": {"subnetName": settings.subnet, "ipAddress": ip},
        "storage": {
            "rootDisk": {
                "imageName": settings.image,
                "size": DEFAULT_DISK_SIZE,
                "storageClassName": settings.storage_class,
            }
        },
    }
    if labels:
        request["labels"] = labels
    return request


def _as_bool(value) -> bool:
    """Coerce a ready flag that may arrive as bool, int, or string."""
    if isinstance(value, str):
        return value.strip().lower() in ("true", "1", "yes")
    return bool(value)


def parse_vm(data: dict) -> dict:
    """Normalize a GET VM `data` payload into a stable, tolerant dict."""
    metadata = data.get("metadata") or {}
    labels = data.get("labels") or metadata.get("labels") or {}
    return {
        "name": data.get("name") or metadata.get("name") or "",
        "namespace": data.get("namespace") or metadata.get("namespace") or "",
        "ip": data.get("ipAddress") or "",
        "ready": _as_bool(data.get("ready")),
        "labels": labels,
        "status": data.get("printableStatus")
        or data.get("status")
        or (metadata.get("status") or ""),
        "uid": data.get("uid") or metadata.get("uid") or "",
    }


class PlatformControl:
    """Async client for the platform HTTP VM lifecycle API.

    Replaces the kubectl-based VMControl. Uses direct bearer-token auth; the
    client is created per instance and never performs I/O at import time.
    """

    def __init__(
        self,
        settings: Settings,
        transport: httpx.AsyncBaseTransport | None = None,
    ):
        self.settings = settings
        self._client = httpx.AsyncClient(
            base_url=_api_base(settings.platform.base_url),
            headers={"Authorization": f"Bearer {settings.platform.token}"},
            timeout=httpx.Timeout(30.0),
            transport=transport,
        )

    async def __aenter__(self):
        return self

    async def __aexit__(self, exc_type, exc, tb):
        await self.close()

    async def close(self) -> None:
        await self._client.aclose()

    async def create(
        self, name: str, ip: str, labels: list[dict] | None = None
    ) -> dict:
        response = await self._client.post(
            "/virtualmachines", json=build_create_request(self.settings, name, ip, labels)
        )
        raise_for_platform(response)
        body = response.json()
        return body.get("data", {}) if isinstance(body, dict) else {}

    async def get(self, name: str) -> dict:
        response = await self._client.get(
            f"/virtualmachines/{self.settings.namespace}/{name}"
        )
        raise_for_platform(response)
        body = response.json()
        return parse_vm(body.get("data", {}) if isinstance(body, dict) else {})

    async def stop(self, name: str) -> dict:
        response = await self._client.put(
            "/virtualmachines/stop",
            json={"namespace": self.settings.namespace, "name": name},
        )
        raise_for_platform(response)
        body = response.json()
        return body.get("data", {}) if isinstance(body, dict) else {}

    async def delete(self, name: str) -> dict:
        response = await self._client.delete(
            f"/virtualmachines/{self.settings.namespace}/{name}"
        )
        raise_for_platform(response)
        body = response.json()
        return body.get("data", {}) if isinstance(body, dict) else {}

    async def ping(self) -> bool:
        try:
            response = await self._client.get("/users/me")
            raise_for_platform(response)
            return True
        except (httpx.HTTPError, PlatformAPIError):
            return False

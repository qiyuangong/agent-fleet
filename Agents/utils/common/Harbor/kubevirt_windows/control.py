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

import yaml

OWNER_LABEL = "agent-fleet/trial"


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


@dataclass(frozen=True)
class Settings:
    template: Path
    namespace: str
    ssh_user: str
    ssh_key: Path
    context: str = ""
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

        settings = cls(
            template=Path(required("TEMPLATE")).expanduser(),
            namespace=required("NAMESPACE"),
            ssh_user=required("SSH_USER"),
            ssh_key=Path(required("SSH_KEY")).expanduser(),
            context=os.environ.get("HARBOR_KUBEVIRT_CONTEXT", ""),
            ssh_port=int(os.environ.get("HARBOR_KUBEVIRT_SSH_PORT", "22")),
            start_timeout=int(os.environ.get("HARBOR_KUBEVIRT_START_TIMEOUT", "600")),
            command_timeout=int(
                os.environ.get("HARBOR_KUBEVIRT_COMMAND_TIMEOUT", "3600")
            ),
            transfer_timeout=int(
                os.environ.get("HARBOR_KUBEVIRT_TRANSFER_TIMEOUT", "300")
            ),
        )
        if not re.fullmatch(
            r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", settings.namespace
        ):
            raise ValueError("Invalid Kubernetes namespace")
        if not settings.ssh_user or any(c in settings.ssh_user for c in "\r\n\x00@"):
            raise ValueError("Invalid SSH user")
        for path in (settings.template, settings.ssh_key):
            if not path.is_file():
                raise FileNotFoundError(path)
        if not 1 <= settings.ssh_port <= 65535:
            raise ValueError("SSH port must be between 1 and 65535")
        if (
            min(
                settings.start_timeout,
                settings.command_timeout,
                settings.transfer_timeout,
            )
            <= 0
        ):
            raise ValueError("Timeouts must be positive")
        return settings

    def kube_args(self):
        # KUBECONFIG is inherited (and may contain several paths).
        return (["--context", self.context] if self.context else []) + [
            "--namespace",
            self.namespace,
        ]


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

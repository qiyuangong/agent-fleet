"""Harbor environment for native ALE Linux and Windows CPU sandboxes."""

import asyncio
import json
import os
import signal
from dataclasses import replace
from pathlib import Path, PurePosixPath

from harbor.environments.base import BaseEnvironment, ExecResult
from harbor.environments.capabilities import (
    EnvironmentCapabilities,
    EnvironmentResourceCapabilities,
)
from harbor.models.task.config import TaskOS
from harbor.utils.path_filter import filter_paths_by_patterns
from kubevirt_windows.control import validate_image
from kubevirt_windows.environment import KubeVirtWindowsEnvironment

from .source import REVISION, select_image, source_digest, validate_source


class ALEEnvironment(BaseEnvironment):
    def __init__(self, *args, source, native_python, image_map,
                 task_data_source="baked_in_sandbox", **kwargs):
        self.source = str(validate_source(source))
        self.native_python = str(Path(native_python).absolute())  # Preserve the virtualenv symlink.
        if not Path(self.native_python).is_file():
            raise ValueError("Run ALE setup before benchmark launch")
        if task_data_source != "baked_in_sandbox" and not task_data_source.startswith(("gs://", "s3://", "oss://")):
            raise ValueError("ALE supports baked data and native gs/s3/oss staging")
        self.worker, self.worker_log, self.backend = None, None, None
        self._started = False
        self._retained = False
        self._phase_lock = asyncio.Lock()
        super().__init__(*args, **kwargs)
        self.native = json.loads((self.environment_dir / "ale.json").read_text())
        if self.native["revision"] != REVISION or self.native["source_sha256"] != source_digest(self.source):
            raise ValueError("ALE source changed since task conversion")
        if self.native["os"] != self.os.value:
            raise ValueError("Native ALE task OS differs from its Harbor environment")
        relative = Path(self.native["task"])
        if relative.is_absolute() or ".." in relative.parts or not relative.parts or relative.parts[0] != "tasks":
            raise ValueError("Invalid native ALE task path")
        profile = select_image(self.native, json.loads(Path(image_map).read_text()))
        self.spec = {**self.native, "source": self.source, "profile": profile, "task_data_source": task_data_source}
        if self.os == TaskOS.WINDOWS:
            validate_image(profile["pvc"])
            self.backend = KubeVirtWindowsEnvironment(*args, **kwargs)
            self.backend.settings = replace(self.backend.settings, image=profile["pvc"])
            self.backend.control.settings = self.backend.settings
            if self.backend.settings.guest_protocol != "ale":
                raise ValueError("ALE Windows requires the ALE CUA command protocol")
        else:
            memory_mb = self.task_env_config.memory_mb or self.native["memory_mb"]
            if memory_mb % 1024:
                raise ValueError("ALE QEMU memory must be a whole number of GiB")
            self.spec.update(cpus=self.task_env_config.cpus or self.native["cpus"], memory_mb=memory_mb)

    @staticmethod
    def type():
        return "ale-cpu"

    @property
    def capabilities(self):
        return EnvironmentCapabilities(windows=True)

    @classmethod
    def resource_capabilities(cls):
        return EnvironmentResourceCapabilities(cpu_limit=True, memory_limit=True)

    def _validate_definition(self):
        super()._validate_definition()
        if self.task_env_config.gpus:
            raise ValueError("GPU ALE tasks are excluded")
        if self.task_env_config.network_mode.value != "public":
            raise ValueError("ALE does not enforce restricted network policies")
        if self.task_env_config.docker_image or self.task_env_config.storage_mb is not None:
            raise ValueError("ALE uses prepared full-OS images; Docker images and disk resizing are unsupported")
        logs = {"/logs/agent", "/logs/verifier", "/logs/artifacts"} if self.os == TaskOS.LINUX else {
            "c:/logs/agent", "c:/logs/verifier", "c:/logs/artifacts"}
        if any(mount["target"].lower() not in logs or mount.get("read_only") for mount in self._mounts):
            raise ValueError("ALE does not support arbitrary host mounts")

    async def start(self, force_build=False):
        if self._started:
            return
        if self._retained:
            raise RuntimeError("A retained ALE guest cannot be reused; create a new environment instance")
        self.trial_paths.trial_dir.mkdir(parents=True, exist_ok=True)
        try:
            if self.backend:
                await self.backend.start(force_build=force_build)
                self.spec.update(vm=self.backend.vm_name, endpoint=str(self.backend._guest().client.base_url).rstrip("/"))
            else:
                spec = self.trial_paths.trial_dir / "ale-worker.json"
                spec.write_text(json.dumps(self.spec, indent=2) + "\n")
                self.worker_log = (self.trial_paths.trial_dir / "ale-linux.log").open("wb")
                self.worker = await asyncio.create_subprocess_exec(
                    self.native_python, "-m", "ale_adapter.linux_worker", str(spec),
                    env=self._worker_env(), stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
                    stderr=self.worker_log, limit=16 * 1024 * 1024, start_new_session=True)
            await self.native_phase("setup")
            self._started = True
        except BaseException:
            await asyncio.shield(self.stop(delete=True))
            raise

    def _worker_env(self, extra=None):
        return {**os.environ, **(extra or {}), "PYTHONDONTWRITEBYTECODE": "1",
                "PYTHONPATH": str(Path(__file__).resolve().parents[1]) + ":" + self.source}

    async def native_phase(self, phase, verifier_env=None):
        async with self._phase_lock:
            if not self.backend:
                return await self._request(phase, verifier_env=verifier_env or {})
            spec = self.trial_paths.trial_dir / "ale-worker.json"
            spec.write_text(json.dumps(self.spec, indent=2) + "\n")
            result = self.trial_paths.trial_dir / f"ale-{phase}.json"
            result.unlink(missing_ok=True)
            with (self.trial_paths.trial_dir / f"ale-{phase}.log").open("wb") as log:
                try:
                    self.worker = await asyncio.create_subprocess_exec(
                        self.native_python, "-m", "ale_adapter.native", phase, str(spec), str(result),
                        env=self._worker_env(verifier_env), stdout=log, stderr=log, start_new_session=True)
                    if await self.worker.wait():
                        raise RuntimeError(f"ALE {phase} failed; see ale-{phase}.log")
                    return json.loads(result.read_text())
                finally:
                    await asyncio.shield(self._stop_worker())

    async def _request(self, method, **params):
        if self.worker is None or self.worker.returncode is not None:
            raise RuntimeError("Native ALE Linux worker is not running")
        try:
            self.worker.stdin.write((json.dumps({"method": method, **params}) + "\n").encode())
            await self.worker.stdin.drain()
            line = await self.worker.stdout.readline()
            if not line:
                raise RuntimeError("Native ALE Linux worker exited; see ale-linux.log")
            response = json.loads(line)
            if not response["ok"]:
                raise RuntimeError(f"ALE {method} failed ({response['error_type']}); see ale-linux.log")
            return response["result"]
        except BaseException:
            await asyncio.shield(self._stop_worker())
            raise

    async def _stop_worker(self):
        worker, self.worker = self.worker, None
        try:
            if worker is not None:
                if worker.returncode is None:
                    if worker.stdin:
                        worker.stdin.close()
                    # Let asyncio cancellation unwind native QEMU acquire/release.
                    try:
                        os.killpg(worker.pid, signal.SIGINT)
                        await asyncio.wait_for(worker.wait(), timeout=30)
                    except (ProcessLookupError, TimeoutError):
                        if worker.returncode is None:
                            os.killpg(worker.pid, signal.SIGKILL)
                await worker.wait()
        finally:
            if self.worker_log:
                self.worker_log.close()
                self.worker_log = None

    async def stop(self, delete=True):
        try:
            if not self.backend and self.worker and self.worker.returncode is None:
                self._retained = not delete
                async with self._phase_lock:
                    await self._request("release", mode="delete" if delete else "stop")
                    await asyncio.wait_for(self.worker.wait(), timeout=30)
        finally:
            try:
                await self._stop_worker()
            finally:
                if self.backend:
                    await self.backend.stop(delete=delete)
                self._started = False

    async def exec(self, command, cwd=None, env=None, timeout_sec=None, user=None):
        if self.backend:
            result = await self.backend.exec(command, cwd=cwd, env=self._merge_env(env),
                                             timeout_sec=timeout_sec, user=self._resolve_user(user))
        else:
            async with self._phase_lock:
                result = ExecResult(**await self._request("exec", command=command,
                    cwd=cwd or self.task_env_config.workdir or "/workspace", env=self._merge_env(env) or {},
                    timeout=timeout_sec if timeout_sec is not None else 3600,
                    user=user if user is not None else self.default_user))
        callback = self._output_callback()
        if callback:
            for stream in ("stdout", "stderr"):
                if getattr(result, stream):
                    await callback(getattr(result, stream), stream)
        return result

    async def upload_file(self, source_path, target_path):
        if self.backend:
            return await self.backend.upload_file(source_path, target_path)
        async with self._phase_lock:
            await self._request("upload", source=str(Path(source_path).absolute()), target=str(target_path))

    async def upload_dir(self, source_dir, target_dir):
        if self.backend:
            return await self.backend.upload_dir(source_dir, target_dir)
        async with self._phase_lock:
            await self._request("mkdir", path=str(target_dir))
        for path in Path(source_dir).rglob("*"):
            if path.is_symlink():
                raise ValueError("ALE uploads do not follow host symlinks")
            remote = str(PurePosixPath(target_dir) / path.relative_to(source_dir))
            if path.is_file():
                await self.upload_file(path, remote)
            elif path.is_dir():
                async with self._phase_lock:
                    await self._request("mkdir", path=remote)

    async def download_file(self, source_path, target_path):
        if self.backend:
            return await self.backend.download_file(source_path, target_path)
        async with self._phase_lock:
            await self._request("download", source=str(source_path), target=str(Path(target_path).absolute()))

    async def download_dir(self, source_dir, target_dir):
        await self.download_dir_filtered(source_dir=source_dir, target_dir=target_dir)

    async def download_dir_with_exclusions(self, *, source_dir, target_dir, exclude):
        await self.download_dir_filtered(source_dir=source_dir, target_dir=target_dir, exclude=exclude)

    async def download_dir_filtered(self, *, source_dir, target_dir, include=None, exclude=None, protect=None):
        if self.backend:
            return await self.backend.download_dir_filtered(source_dir=source_dir, target_dir=target_dir,
                                                            include=include, exclude=exclude, protect=protect)
        async with self._phase_lock:
            entries = await self._request("list", path=str(source_dir))
        paths = [entry["relpath"] for entry in entries if not entry["is_dir"]]
        selected = filter_paths_by_patterns(paths, include=include, exclude=exclude)
        selected = dict.fromkeys(selected + [path for path in paths if path in (protect or [])])
        target = Path(target_dir).resolve()
        target.mkdir(parents=True, exist_ok=True)
        for path in selected:
            local = target / path
            if not local.resolve().is_relative_to(target):
                raise ValueError("Download would escape the output directory")
            await self.download_file(str(PurePosixPath(source_dir) / path), local)

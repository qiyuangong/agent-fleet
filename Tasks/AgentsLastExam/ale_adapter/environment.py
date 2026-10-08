"""Attach ALE setup and evaluation to the isolated Harbor Windows environment."""

import asyncio
import json
import os
import signal
from dataclasses import replace
from pathlib import Path

from harbor.environments.capabilities import EnvironmentCapabilities
from kubevirt_windows.control import validate_image
from kubevirt_windows.environment import KubeVirtWindowsEnvironment

from .source import REVISION, select_image, source_digest, validate_source


class ALEEnvironment(KubeVirtWindowsEnvironment):
    def __init__(self, *args, source, native_python, image_map,
                 task_data_source="baked_in_sandbox", **kwargs):
        self.source = str(Path(source).resolve())
        # A virtualenv's Python is often a symlink. Resolving it discards the
        # virtualenv and therefore the native ALE dependencies.
        self.native_python = str(Path(native_python).absolute())
        if not Path(self.native_python).is_file():
            raise ValueError("Run ALE setup before benchmark launch")
        if task_data_source != "baked_in_sandbox" and not task_data_source.startswith(("gs://", "s3://", "oss://")):
            raise ValueError("ALE Windows supports baked data and native gs/s3/oss staging")
        self.task_data_source = task_data_source
        self.worker = None
        self._phase_lock = asyncio.Lock()
        super().__init__(*args, **kwargs)
        self.native = json.loads((self.environment_dir / "ale.json").read_text())
        validate_source(self.source)
        if self.native["revision"] != REVISION or self.native["source_sha256"] != source_digest(self.source):
            raise ValueError("ALE source changed since task conversion")
        relative = Path(self.native["task"])
        if relative.is_absolute() or ".." in relative.parts or relative.parts[0] != "tasks":
            raise ValueError("Invalid native ALE task path")
        profile = select_image(self.native, json.loads(Path(image_map).read_text()))
        validate_image(profile["pvc"])
        if (self.task_env_config.gpus or 0) != int(self.native["requires_gpu"]):
            raise ValueError("ALE GPU count must match the native snapshot (zero or one)")
        # This control object has not opened a client yet; each environment gets
        # its own immutable settings, allowing mixed snapshots in one Harbor job.
        self.settings = replace(self.settings, image=profile["pvc"],
                                gpu_device=profile.get("gpu_device", ""))
        self.control.settings = self.settings
        if self.settings.guest_protocol != "ale":
            raise ValueError("ALE tasks require the ALE CUA command protocol")

    @staticmethod
    def type():
        return "ale-kubevirt-windows"

    @property
    def capabilities(self):
        return EnvironmentCapabilities(windows=True, gpus=True)

    async def start(self, force_build=False):
        if self._started:
            return
        try:
            await super().start(force_build=force_build)
            guest = self._guest()
            self.spec = {**self.native, "source": self.source, "vm": self.vm_name,
                         "endpoint": str(guest.client.base_url).rstrip("/"),
                         "task_data_source": self.task_data_source}
            await self.native_phase("setup")
        except BaseException:
            await asyncio.shield(self.stop(delete=True))
            raise

    async def native_phase(self, phase, verifier_env=None):
        async with self._phase_lock:
            self._guest()
            spec = self.trial_paths.trial_dir / "ale-worker.json"
            spec.write_text(json.dumps(self.spec, indent=2) + "\n")
            result = self.trial_paths.trial_dir / f"ale-{phase}.json"
            result.unlink(missing_ok=True)
            # Verifier overrides remain host-side and are supplied only to eval.
            env = {**os.environ, **(verifier_env or {})}
            adapter_root = str(Path(__file__).resolve().parents[1])
            env["PYTHONPATH"] = adapter_root + ":" + self.source
            env["PYTHONDONTWRITEBYTECODE"] = "1"
            with (self.trial_paths.trial_dir / f"ale-{phase}.log").open("wb") as log:
                try:
                    self.worker = await asyncio.create_subprocess_exec(
                        self.native_python, "-m", "ale_adapter.native", phase, str(spec), str(result),
                        env=env, stdout=log, stderr=log, start_new_session=True,
                    )
                    if await self.worker.wait():
                        raise RuntimeError(f"ALE {phase} failed; see ale-{phase}.log")
                    return json.loads(result.read_text())
                finally:
                    await asyncio.shield(self._stop_worker())

    async def _stop_worker(self):
        worker, self.worker = self.worker, None
        if worker is not None:
            try:
                os.killpg(worker.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            await worker.wait()

    async def stop(self, delete=True):
        try:
            await self._stop_worker()
        finally:
            await super().stop(delete=delete)

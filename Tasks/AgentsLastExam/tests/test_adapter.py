"""Portable checks of conversion, Harbor lifecycle, CPU scope and scores."""

import argparse
import asyncio
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock, patch

from ale_adapter.adapter import discover, materialize
from ale_adapter.environment import ALEEnvironment
from ale_adapter.launch import command
from ale_adapter.source import REVISION, select_image, source_digest, validate_source
from ale_adapter.verifier import ALEVerifier, score
from harbor.models.task.config import EnvironmentConfig
from harbor.models.task.task import Task
from harbor.models.trial.paths import TrialPaths
from kubevirt_windows.control import Cluster, Settings
from kubevirt_windows.environment import KubeVirtWindowsEnvironment


def record(gpu=False, os_type="windows"):
    return {"task": "tasks/visual_media/example", "variant": 3, "os": os_type,
            "description": "Solve the task using E:\\agenthle.\nKeep Unicode: 中文",
            "snapshot": "gpu-free" if gpu else "cpu-free", "image_family": "ale-win10",
            "resolution": [1024, 768], "requires_gpu": gpu,
            "cpus": 8, "memory_mb": 16384, "timeout": 7200,
            "revision": REVISION, "source_sha256": "fixture-source"}


class AdapterTests(unittest.TestCase):
    def test_conversion_uses_windows_schema_and_preserves_variant_and_prompt(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with patch("ale_adapter.adapter.validate_source", return_value=root), \
                    patch("ale_adapter.adapter.discover", return_value=[record()]), \
                    patch("ale_adapter.adapter.source_digest", return_value="fixture-source"):
                before = list(sys.path)
                try:
                    self.assertEqual(materialize(root, root / "output"), 1)
                finally:
                    sys.path[:] = before
            task = Task(root / "output/visual_media--example--v3")
            self.assertEqual(task.instruction, record()["description"] + "\n")
            self.assertEqual(task.config.environment.os.value, "windows")
            self.assertEqual(task.config.environment.gpus, 0)
            self.assertEqual(task.config.environment.cpus, 8)
            self.assertEqual(task.config.environment.memory_mb, 16384)
            self.assertEqual(task.config.agent.timeout_sec, 7200)
            self.assertIn(b"exit /b 1", (task.paths.tests_dir / "test.bat").read_bytes())
            native = json.loads((task.paths.environment_dir / "ale.json").read_text())
            self.assertEqual(native["variant"], 3)
            self.assertEqual(native["revision"], REVISION)

    def test_discovery_includes_both_cpu_oses_and_skips_gpu_before_import(self):
        loaded = []
        class Loader:
            def __init__(self, path):
                self.os = "linux" if path.endswith("linux") else "windows"
                loaded.append(Path(path).name)
                if path.endswith("gpu"):
                    raise AssertionError("GPU implementation must never be imported")
            def _load_module(self):
                return SimpleNamespace(load=lambda: [None, None])
            def get_evaluate_fn(self):
                return lambda: None
            def load(self, variant_index):
                return {"os_type": self.os, "description": f"Variant {variant_index}"}
        modules = {
            "ale_run.environments.images": SimpleNamespace(get=lambda name: SimpleNamespace(os=name)),
            "ale_run.environments.providers.gcloud": SimpleNamespace(_parse_gce_machine_type=lambda value: None),
            "ale_run.tasks.loader": SimpleNamespace(TaskLoader=Loader),
        }
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "configs/environments").mkdir(parents=True)
            (root / "configs/environments/environment_gcloud.yaml").write_text(
                "snapshots:\n  cpu-linux: {image: linux}\n  cpu-win: {image: windows}\n"
                "  gpu-win: {image: windows, gcloud: {gpu: {count: 1}}}\n")
            for name, snapshot in [("linux", "cpu-linux"), ("windows", "cpu-win"), ("gpu", "gpu-win")]:
                card = root / "tasks/fixture" / name / "task_card.json"
                card.parent.mkdir(parents=True)
                card.write_text(json.dumps({"vm": {"snapshot": snapshot}}))
            with patch.dict(sys.modules, modules):
                records = discover(root)
        self.assertEqual(set(loaded), {"linux", "windows"})
        self.assertEqual([item["os"] for item in records], ["linux", "linux", "windows", "windows"])
        self.assertTrue(all(not item["requires_gpu"] for item in records))

    def test_conversion_does_not_publish_partial_dataset(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            broken = record()
            broken.pop("description")
            before = list(sys.path)
            try:
                with patch("ale_adapter.adapter.validate_source", return_value=root), \
                        patch("ale_adapter.adapter.discover", return_value=[record(), broken]), \
                        patch("ale_adapter.adapter.source_digest", return_value="fixture-source"), \
                        self.assertRaises((KeyError, FileExistsError)):
                    materialize(root, root / "output")
            finally:
                sys.path[:] = before
            self.assertFalse((root / "output").exists())
            self.assertEqual(list(root.iterdir()), [])

    def test_linux_conversion_preserves_os_and_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            native = {**record(os_type="linux"), "snapshot": "cpu-free-ubuntu", "image_family": "ale-ubuntu22"}
            with patch("ale_adapter.adapter.validate_source", return_value=root), \
                    patch("ale_adapter.adapter.discover", return_value=[native]), \
                    patch("ale_adapter.adapter.source_digest", return_value="fixture-source"):
                before = list(sys.path)
                try:
                    materialize(root, root / "output")
                finally:
                    sys.path[:] = before
            task = Task(root / "output/visual_media--example--v3")
            self.assertEqual(task.config.environment.os.value, "linux")
            self.assertEqual(task.config.environment.gpus, 0)
            self.assertIn("exit 1", (task.paths.tests_dir / "test.sh").read_text())
            self.assertEqual(json.loads((root / "output/dataset.json").read_text())["scope"], "cpu")

    def test_linux_mapping_requires_prepared_local_disk(self):
        native = {**record(os_type="linux"), "image_family": "ale-ubuntu22"}
        profile = {"image_family": "ale-ubuntu22", "qemu": {"disk_source": "hf://example/disk"}}
        with self.assertRaisesRegex(ValueError, "local"):
            select_image(native, {"cpu-free": profile})
        with tempfile.TemporaryDirectory() as tmp:
            disk = Path(tmp) / "base.qcow2"
            disk.write_bytes(b"fixture")
            profile["qemu"]["disk_source"] = str(disk)
            self.assertEqual(select_image(native, {"cpu-free": profile}), profile)

    def test_source_rejects_wrong_revision_and_fingerprints_helpers(self):
        with patch("ale_adapter.source.subprocess.check_output", return_value="different\n"), \
                self.assertRaisesRegex(ValueError, "pinned"):
            validate_source(".")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "tasks").mkdir()
            original = source_digest(root)
            (root / "tasks/helper.py").write_text("changed")
            self.assertNotEqual(source_digest(root), original)

    def test_image_map_requires_correct_family_and_gpu(self):
        profile = {"pvc": "golden", "image_family": "ale-win10"}
        self.assertEqual(select_image(record(), {"cpu-free": profile}), profile)
        with self.assertRaisesRegex(ValueError, "GPU"):
            select_image(record(True), {"gpu-free": profile})
        with self.assertRaisesRegex(ValueError, "family"):
            select_image(record(), {"cpu-free": {**profile, "image_family": "ale-ubuntu22"}})

    def test_native_cli_and_opik_selection_preserve_forwarded_args(self):
        args = argparse.Namespace(dataset=Path("tasks"), source=Path("source"),
                                  native_python=Path("python"), image_map=Path("images.json"),
                                  agent="kubevirt_windows.agent:WindowsCommandAgent",
                                  task_data_source="baked_in_sandbox",
                                  harbor_args=["--", "--include-task-name", "test--v3", "--max-retries", "2"])
        with patch.dict(os.environ, {"OPIK_URL": "", "HARBOR_CLI_BIN": "/prepared/harbor"}):
            cmd = command(args)
        self.assertEqual(cmd[0], "/prepared/harbor")
        self.assertEqual(cmd[-4:], args.harbor_args[-4:])
        self.assertIn("ale_adapter.verifier:ALEVerifier", cmd)
        self.assertIn("ale_adapter.environment:ALEEnvironment", cmd)
        with patch.dict(os.environ, {"OPIK_URL": "https://opik.example/api", "HARBOR_OPIK_BIN": "/prepared/opik"}):
            self.assertEqual(command(args)[:3], ["/prepared/opik", "harbor", "run"])

    def test_launcher_keeps_virtualenv_interpreter_symlink(self):
        with tempfile.TemporaryDirectory() as tmp:
            python = Path(tmp) / "python"
            python.symlink_to(sys.executable)
            args = argparse.Namespace(dataset=Path("tasks"), source=Path("source"),
                                      native_python=python, image_map=Path("images.json"),
                                      agent="custom_agent:WindowsAgent", task_data_source="baked_in_sandbox", harbor_args=[])
            self.assertIn(f"native_python={python}", command(args))
            self.assertEqual(command(args)[command(args).index("--agent") + 1], args.agent)

    def test_score_preserves_zero_fractional_negative_and_final_score(self):
        for result, expected in [({"score": 0}, 0), ({"score": .4}, .4),
                                 ({"score": -1}, -1), ({"final_score": .7}, .7)]:
            self.assertEqual(score(result), expected)
        for invalid in [{"error": "judge offline", "score": 1}, {},
                        {"score": None}, {"score": float("nan")}, {"score": float("inf")}]:
            with self.assertRaises((ValueError, RuntimeError)):
                score(invalid)


class LifecycleTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.settings = Settings(cluster=Cluster("https://cluster.example", "ca", "cert", "key"),
                                 image="default-pvc", namespace="default", node="", guest_protocol="ale")
        for target, value in [("kubevirt_windows.control.Settings.from_env", self.settings),
                              ("ale_adapter.environment.validate_source", self.root),
                              ("ale_adapter.environment.source_digest", "fixture-source")]:
            patcher = patch(target, return_value=value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def environment(self, gpu=False, **kwargs):
        native = record(gpu)
        directory = self.root / ("gpu" if gpu else "cpu")
        directory.mkdir(exist_ok=True)
        (directory / "ale.json").write_text(json.dumps(native))
        image_map = self.root / "images.json"
        image_map.write_text(json.dumps({
            "cpu-free": {"pvc": "cpu-pvc", "image_family": "ale-win10"},
            "gpu-free": {"pvc": "gpu-pvc", "image_family": "ale-win10", "gpu_device": "nvidia.com/test-gpu"},
        }))
        return ALEEnvironment(
            environment_dir=directory, environment_name="ale-test", session_id="trial",
            trial_paths=TrialPaths(self.root / ("gpu-trial" if gpu else "cpu-trial")),
            task_env_config=EnvironmentConfig(os="windows", gpus=int(gpu)),
            source=self.root, native_python=sys.executable, image_map=image_map, **kwargs,
        )

    def test_per_trial_image_selection_and_gpu_exclusion(self):
        cpu = self.environment()
        self.assertEqual(cpu.backend.settings.image, "cpu-pvc")
        self.assertEqual(self.settings.image, "default-pvc")
        with self.assertRaises(ValueError):
            self.environment(True)

    def test_rejects_unimplemented_data_backend(self):
        with self.assertRaisesRegex(ValueError, "staging"):
            self.environment(task_data_source="local:/data")

    async def test_native_setup_precedes_agent_and_failure_cleans_vm(self):
        environment = self.environment()
        async def started(*args, **kwargs):
            environment.backend._started = True
            environment.backend.transport = Mock(client=Mock(base_url="http://127.0.0.1:5000/"))
        with patch.object(KubeVirtWindowsEnvironment, "start", side_effect=started), \
                patch.object(KubeVirtWindowsEnvironment, "stop", new_callable=AsyncMock) as stop:
            environment.native_phase = AsyncMock(side_effect=RuntimeError("setup failed"))
            with self.assertRaisesRegex(RuntimeError, "setup failed"):
                await environment.start()
            environment.native_phase.assert_awaited_once_with("setup")
            stop.assert_awaited_once_with(delete=True)

    async def test_verifier_returns_harbor_reward_and_keeps_native_details(self):
        environment = self.environment()
        result = {"score": 0, "raw_scores": [0, .2]}
        environment.native_phase = AsyncMock(return_value=result)
        verifier = ALEVerifier(task=Mock(), trial_paths=environment.trial_paths,
                               environment=environment, verifier_env={"JUDGE_KEY": "fake"})
        verified = await verifier.verify()
        self.assertEqual(verified.rewards, {"reward": 0})
        self.assertEqual(json.loads((environment.trial_paths.verifier_dir / "native-result.json").read_text()), result)
        environment.native_phase.assert_awaited_once_with("evaluate", verifier_env={"JUDGE_KEY": "fake"})
        self.assertEqual(environment.trial_paths.reward_text_path.read_text(), "0.0\n")

    async def test_windows_delegation_preserves_harbor_user_and_scoped_env(self):
        environment = self.environment()
        environment.default_user = "other-user"
        environment.backend.exec = AsyncMock(return_value=Mock(stdout="", stderr="", return_code=0))
        with environment.scoped_exec_env({"HARBOR_MODEL": "fake-model"}):
            await environment.exec("echo hello")
        self.assertEqual(environment.backend.exec.call_args.kwargs["user"], "other-user")
        self.assertEqual(environment.backend.exec.call_args.kwargs["env"]["HARBOR_MODEL"], "fake-model")

    async def test_cancelled_phase_terminates_worker_before_vm_cleanup(self):
        environment = self.environment()
        environment._started, environment.transport = True, Mock()
        environment.trial_paths.trial_dir.mkdir()
        environment.spec = {}
        worker = Mock(pid=12345, returncode=None)
        worker.wait = AsyncMock(side_effect=[asyncio.CancelledError(), 0, 0])
        with patch("ale_adapter.environment.asyncio.create_subprocess_exec", new_callable=AsyncMock, return_value=worker), \
                patch("ale_adapter.environment.os.killpg") as kill:
            with self.assertRaises(asyncio.CancelledError):
                await environment.native_phase("setup")
            kill.assert_called_once()
        self.assertIsNone(environment.worker)

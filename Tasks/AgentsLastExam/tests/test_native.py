"""Exercise a real Harbor trial and the pinned ALE driver via loopback CUA."""

import asyncio
import base64
import json
import os
import shutil
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import AsyncMock, Mock, patch

from ale_adapter.source import REVISION, source_digest
from harbor.models.trial.config import TrialConfig
from harbor.trial.trial import Trial
from kubevirt_windows.control import Cluster, Settings
from kubevirt_windows.environment import KubeVirtWindowsEnvironment

SOURCE = os.environ.get("ALE_TEST_SOURCE")
PYTHON = os.environ.get("ALE_TEST_PYTHON")


@unittest.skipUnless(SOURCE and PYTHON, "Prepare the pinned native ALE source and Python environment")
class NativeTrialTests(unittest.IsolatedAsyncioTestCase):
    async def test_native_setup_reference_timing_grading_and_harbor_reporting(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "source"
            await asyncio.to_thread(subprocess.run,
                                    ["git", "-c", "advice.detachedHead=false", "clone", "--quiet", "--shared", SOURCE, str(source)],
                                    check=True)
            await asyncio.to_thread(subprocess.run,
                                    ["git", "-C", str(source), "checkout", "--quiet", "--detach", REVISION], check=True)
            fixture = source / "tasks/fixture/roundtrip"
            fixture.mkdir(parents=True)
            (fixture / "main.py").write_text('''
import cua_bench as cb
from tasks.common_config import GeneralTaskConfig
config = GeneralTaskConfig(DOMAIN_NAME="fixture", TASK_NAME="roundtrip", VARIANT_NAME="base")
def load():
    return [cb.Task(description="Write a fractional answer", metadata=config.to_metadata(),
                    computer={"setup_config": {"os_type": "windows"}})]
async def start(task, session):
    await session.write_bytes("C:/fixture/setup.txt", b"ready")
async def evaluate(task, session):
    assert await session.read_bytes("C:/fixture/setup.txt") == b"ready"
    assert await session.read_bytes("E:/agenthle/fixture/roundtrip/base/reference/expected.txt") == b"reference"
    return [float(await session.read_bytes("C:/fixture/answer.txt")), 0.9]
''')
            (fixture / "task_card.json").write_text(json.dumps({"vm": {"snapshot": "cpu-free", "timeout": 7200}}))
            task = root / "task"
            (task / "environment").mkdir(parents=True)
            (task / "tests").mkdir()
            (task / "instruction.md").write_text("Write a fractional answer")
            (task / "task.toml").write_text(
                '[environment]\nos="windows"\ncpus=4\nmemory_mb=16384\n'
                '[agent]\ntimeout_sec=60\n[verifier]\ntimeout_sec=60\n'
            )
            (task / "tests/test.bat").write_bytes(b"@echo off\r\nexit /b 1\r\n")
            native = {"task": "tasks/fixture/roundtrip", "variant": 0,
                      "snapshot": "cpu-free", "image_family": "ale-win10", "requires_gpu": False,
                      "resolution": [1024, 768], "revision": REVISION, "source_sha256": source_digest(source)}
            (task / "environment/ale.json").write_text(json.dumps(native))
            mapping = root / "images.json"
            mapping.write_text(json.dumps({"cpu-free": {"pvc": "ale-cpu-free", "image_family": "ale-win10"}}))
            files, phases = {}, []

            class Handler(BaseHTTPRequestHandler):
                def log_message(self, *_):
                    pass

                def do_POST(self):
                    request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                    method, params = request["command"], request["params"]
                    result = {"success": True}
                    if method == "run_command":
                        command = params["command"]
                        result.update(return_code=0, stdout="", stderr="")
                        if "base64.b64decode" in command:
                            phases.append("resolution")
                            result["stdout"] = "set_ok"
                        elif "7z x" in command:
                            phases.append("reference")
                            files["E:/agenthle/fixture/roundtrip/base/reference/expected.txt"] = b"reference"
                        elif "pyvenv.cfg" in command:
                            result["return_code"] = 1
                    elif method == "write_bytes":
                        files[params["path"]] = base64.b64decode(params["content_b64"])
                        phases.append("setup")
                    elif method == "get_file_size":
                        result["size"] = len(files[params["path"]])
                    elif method == "read_bytes":
                        result["content_b64"] = base64.b64encode(files[params["path"]]).decode()
                        phases.append("grade")
                    else:
                        result = {"success": False, "error": "Unsupported fixture command"}
                    body = ("data: " + json.dumps(result) + "\n\n").encode()
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(body)))
                    self.send_header("Content-Type", "text/event-stream")
                    self.end_headers()
                    self.wfile.write(body)

            server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            self.addCleanup(server.server_close)
            self.addCleanup(server.shutdown)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            endpoint = f"http://127.0.0.1:{server.server_port}"
            transport = Mock(client=Mock(base_url=endpoint))
            transport.upload_file = AsyncMock()
            transport.list_files = AsyncMock(return_value=[])

            async def execute(*args, **kwargs):
                self.assertEqual(files["C:/fixture/setup.txt"], b"ready")
                self.assertNotIn("reference", phases)
                phases.append("agent")
                files["C:/fixture/answer.txt"] = b"0.4"
                return {"return_code": 0, "stdout": "", "stderr": ""}
            transport.execute = AsyncMock(side_effect=execute)

            async def start(environment, force_build=False):
                environment.trial_paths.trial_dir.mkdir(parents=True, exist_ok=True)
                environment._started, environment.transport = True, transport

            async def stop(environment, delete=True):
                environment._started = False
                phases.append("cleanup")

            settings = Settings(cluster=Cluster("https://cluster.example", "ca", "cert", "key"),
                                image="ale-cpu-free", namespace="default", node="", guest_protocol="ale")
            config = TrialConfig.model_validate({
                "trial_name": "ale-native-fixture", "trials_dir": str(root / "trials"),
                "task": {"path": str(task)},
                "environment": {"import_path": "ale_adapter.environment:ALEEnvironment", "kwargs": {
                    "source": str(source), "native_python": PYTHON, "image_map": str(mapping)}},
                "agent": {"import_path": "kubevirt_windows.agent:WindowsCommandAgent", "model_name": "fake-model",
                          "kwargs": {"command": "C:\\Agent\\run.cmd"}},
                "verifier": {"import_path": "ale_adapter.verifier:ALEVerifier"},
            })
            with patch("kubevirt_windows.environment.Settings.from_env", return_value=settings), \
                    patch.object(KubeVirtWindowsEnvironment, "start", start), \
                    patch.object(KubeVirtWindowsEnvironment, "stop", stop), \
                    patch.dict(os.environ, {"ALE_REFERENCE_ARCHIVE_PASSWORD": "fake-reference-password"}):
                result = await (await Trial.create(config)).run()
            trial = root / "trials/ale-native-fixture"
            if result.exception_info:
                logs = "\n".join(p.read_text() for p in trial.glob("ale-*.log"))
                self.fail(f"{result.exception_info}\n{logs}")
            self.assertEqual(result.verifier_result.rewards, {"reward": .4})
            self.assertEqual(json.loads((trial / "verifier/native-result.json").read_text())["raw_scores"], [.4, .9])
            self.assertTrue((trial / "result.json").is_file())
            self.assertEqual(phases[:3], ["resolution", "setup", "agent"])
            self.assertLess(phases.index("agent"), phases.index("reference"))
            self.assertLess(phases.index("reference"), phases.index("grade"))
            self.assertEqual(phases[-1], "cleanup")
            shutil.rmtree(source)

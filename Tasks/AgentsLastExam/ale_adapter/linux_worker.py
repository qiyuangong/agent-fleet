"""Native ALE QEMU lifecycle and Linux guest I/O for a Harbor trial."""

import argparse
import asyncio
import contextlib
import json
import math
import os
import shlex
import sys
import traceback
from dataclasses import asdict
from pathlib import Path, PurePosixPath
from urllib.parse import urlparse

from .native import run
from .source import validate_source


async def serve(spec, spec_path, output):
    source = validate_source(spec["source"])
    sys.path.insert(0, str(source))
    from ale_run.base_interface import SandboxSpec
    from ale_run.environments.providers.qemu import QemuProvider

    profile = {**spec["profile"]["qemu"], "image": spec["image_family"], "vcpus": 0, "memory_gb": 0}
    profile.setdefault("runner_pull_policy", "never")
    provider = QemuProvider({"snapshots": {spec["snapshot"]: profile}})
    # Native QEMU and CUA use local ports; do not send guest traffic to a host proxy.
    for key in ("NO_PROXY", "no_proxy"):
        os.environ[key] = ",".join(filter(None, [os.environ.get(key), "127.0.0.1", "localhost"]))
    sandbox, mode = None, "delete"
    try:
        sandbox = await provider.acquire(SandboxSpec(snapshot=spec["snapshot"], os="linux",
            vcpus=spec["cpus"], memory_gb=spec["memory_mb"] // 1024, task_id=spec["task"]))
        (spec_path.parent / "ale-sandbox.json").write_text(json.dumps(asdict(sandbox), indent=2) + "\n")
        spec.update(vm=sandbox.id, endpoint=sandbox.endpoint)
        for key in ("NO_PROXY", "no_proxy"):
            os.environ[key] += "," + urlparse(sandbox.endpoint).hostname
        bootstrap = await sandbox.run_command(
            'sudo -n mkdir -p /logs/agent /logs/verifier /logs/artifacts /workspace && '
            'sudo -n chown -R "$(id -u):$(id -g)" /logs /workspace', timeout=60)
        if bootstrap.returncode:
            raise RuntimeError("Failed to prepare Harbor's guest log directories")
        while line := await asyncio.to_thread(sys.stdin.readline):
            try:
                request = json.loads(line)
                method = request["method"]
                if method == "release":
                    mode = request["mode"]
                    await provider.release(sandbox, mode=mode)
                    sandbox = None
                    result = {"released": True}
                elif method in ("setup", "evaluate"):
                    with patched_env(request.get("verifier_env", {})):
                        result = await run(spec, method, sandbox=sandbox)
                elif method == "exec":
                    timeout = float(request["timeout"])
                    if not math.isfinite(timeout) or timeout <= 0:
                        raise ValueError("Command timeout must be positive and finite")
                    env = request["env"]
                    if any(not key or "=" in key or "\x00" in key + value for key, value in env.items()):
                        raise ValueError("Invalid guest environment variable")
                    args = ["env", "--", *[f"{key}={value}" for key, value in env.items()],
                            "timeout", "--signal=TERM", "--kill-after=5s", str(timeout), "bash", "-lc",
                            "cd " + shlex.quote(request["cwd"]) + " && " + request["command"]]
                    if request["user"] is not None:
                        args = ["sudo", "-n", "-u", str(request["user"]), "--", *args]
                    completed = await sandbox.run_command(shlex.join(args), timeout=timeout + 30)
                    if completed.returncode in (124, 137):
                        raise TimeoutError("Guest command timed out")
                    result = {"stdout": completed.stdout, "stderr": completed.stderr, "return_code": completed.returncode}
                elif method == "mkdir":
                    await sandbox.mkdir(request["path"])
                    result = {}
                elif method == "upload":
                    source_file = Path(request["source"])
                    if source_file.is_symlink() or not source_file.is_file():
                        raise ValueError("Upload requires a regular file")
                    await sandbox.mkdir(str(PurePosixPath(request["target"]).parent))
                    await sandbox.upload_local_file(str(source_file), request["target"])
                    result = {}
                elif method == "download":
                    target = Path(request["target"])
                    target.parent.mkdir(parents=True, exist_ok=True)
                    if not await sandbox.download_to_local(request["source"], str(target)):
                        raise RuntimeError("Guest file download failed")
                    result = {}
                elif method == "list":
                    result = await sandbox.list_dir(request["path"])
                else:
                    raise ValueError("Unsupported ALE Linux operation")
                response = {"ok": True, "result": result}
            except Exception as error:  # noqa: BLE001 — report native failures across the RPC boundary.
                traceback.print_exc(file=sys.stderr)
                response = {"ok": False, "error_type": type(error).__name__}
            output.write(json.dumps(response, allow_nan=False) + "\n")
            output.flush()
            if sandbox is None:
                break
    finally:
        if sandbox is not None:
            await provider.release(sandbox, mode=mode)


@contextlib.contextmanager
def patched_env(values):
    previous = {key: os.environ.get(key) for key in values}
    os.environ.update(values)
    try:
        yield
    finally:
        for key, value in previous.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("spec", type=Path)
    args = parser.parse_args()
    output = sys.stdout
    with contextlib.redirect_stdout(sys.stderr):
        asyncio.run(serve(json.loads(args.spec.read_text()), args.spec, output))


if __name__ == "__main__":
    main()

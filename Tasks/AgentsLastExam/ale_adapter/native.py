"""Run one ALE phase in its own dependency environment against Harbor's VM."""

import argparse
import asyncio
import contextlib
import json
import os
import sys
from pathlib import Path
from urllib.parse import urlparse

from .source import REVISION, source_digest, validate_source


async def run(spec, phase):
    source = validate_source(spec["source"])
    if spec["revision"] != REVISION or source_digest(source) != spec["source_sha256"]:
        raise ValueError("ALE source changed since task conversion")
    sys.path.insert(0, str(source))
    # Native imports/judges inherit operator credentials; guest requests bypass
    # HTTP proxies while external judge calls retain their normal configuration.
    host = urlparse(spec["endpoint"]).hostname
    for key in ("NO_PROXY", "no_proxy"):
        os.environ[key] = ",".join(filter(None, [os.environ.get(key), host]))
    from ale_run.base_interface import SandboxHandle
    from ale_run.environments.images import get as get_image
    from ale_run.environments.providers.static import StaticProvider
    from ale_run.environments.task_data import select
    from ale_run.tasks.driver import TaskDriver

    image = get_image(spec["image_family"])
    sandbox = SandboxHandle(id=spec["vm"], endpoint=spec["endpoint"], os="windows", **image.sandbox_paths())
    session = StaticProvider({"endpoint": spec["endpoint"], "image": image.name}).open_session(sandbox)
    driver = TaskDriver(str(source / spec["task"]), session, variant=spec["variant"], os_type="windows")
    if driver.task_info["os_type"] != "windows":
        raise ValueError("ALE adapter only supports Windows tasks")
    data = driver.task_info["task_data"]
    backend = select(spec["task_data_source"])
    try:
        if phase == "setup":
            if spec.get("resolution"):
                # Reuse ALE's Windows API implementation and reject unsupported modes.
                import base64

                from ale_run.environments.providers.gcloud import _SET_RES_PY
                width, height = spec["resolution"]
                encoded = base64.b64encode(_SET_RES_PY.encode()).decode()
                result = await sandbox.run_command(
                    f'"{sandbox.python}" -c "import base64,sys;sys.argv=[\'display\',\'{width}\',\'{height}\'];'
                    f'exec(base64.b64decode(\'{encoded}\'))"', timeout=60,
                )
                if result.returncode or "set_ok" not in result.stdout:
                    raise RuntimeError("ALE desktop resolution setup failed")
            if data.reference_dir:
                # Golden images must have encrypted references only. Remove any
                # stale plaintext reference for this variant before agent setup.
                await sandbox.rm([data.reference_dir])
            if data.requires_task_data:
                await backend.stage_input(sandbox, data, source=spec["task_data_source"])
            await driver.setup()
            return {"setup": "complete"}
        if not callable(driver._task_loader.get_evaluate_fn()):
            raise TypeError("Missing native ALE evaluator")
        if data.requires_task_data:
            await backend.stage_reference(sandbox, data, source=spec["task_data_source"])
        return await driver.evaluate()
    finally:
        await driver.close()
        with contextlib.suppress(Exception):
            session.computer.interface.force_close()
        with contextlib.suppress(Exception):
            await asyncio.wait_for(session.close(), timeout=10)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=("setup", "evaluate"))
    parser.add_argument("spec", type=Path)
    parser.add_argument("result", type=Path)
    args = parser.parse_args()
    result = asyncio.run(run(json.loads(args.spec.read_text()), args.phase))
    args.result.write_text(json.dumps(result, indent=2, allow_nan=False) + "\n")


if __name__ == "__main__":
    main()

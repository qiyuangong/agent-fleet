#!/usr/bin/env python3
"""Prepare the persistent Opik Harbor CLI used by harbor-tui workers."""

from __future__ import annotations

import os
import subprocess
from pathlib import Path


def append_run(log_handle, cmd: list[str]) -> bool:
    return subprocess.run(cmd, stdout=log_handle, stderr=log_handle).returncode == 0


def main() -> int:
    runtime_dir = Path(os.environ["RUNTIME_DIR"])
    status_file = Path(os.environ["HARBOR_RUNNER_PREPARE_STATUS_FILE"])
    log_file = Path(os.environ["HARBOR_RUNNER_PREPARE_LOG_FILE"])
    harbor_opik_bin = Path(os.environ["HARBOR_OPIK_BIN"])
    workers_failed_file = Path(os.environ["WORKERS_FAILED_FILE"])

    runtime_dir.mkdir(parents=True, exist_ok=True)

    if os.environ.get("HARBOR_RUNNER_PREPARE") != "1":
        status_file.write_text("skipped\n", encoding="utf-8")
        return 0

    status_file.write_text("preparing\n", encoding="utf-8")
    log_file.write_text("", encoding="utf-8")
    print("preparing Harbor Opik runner CLI...")

    with log_file.open("a", encoding="utf-8") as log_handle:
        if harbor_opik_bin.is_file() and os.access(harbor_opik_bin, os.X_OK):
            if append_run(log_handle, [str(harbor_opik_bin), "harbor", "run", "--help"]):
                status_file.write_text("done\n", encoding="utf-8")
                return 0

        harbor_opik_bin.parent.mkdir(parents=True, exist_ok=True)
        if append_run(log_handle, ["uv", "tool", "install", "--with", "harbor", "opik"]):
            if append_run(log_handle, [str(harbor_opik_bin), "harbor", "run", "--help"]):
                status_file.write_text("done\n", encoding="utf-8")
                return 0

    status_file.write_text("failed\n", encoding="utf-8")
    workers_failed_file.touch()
    return 1


if __name__ == "__main__":
    raise SystemExit(main())

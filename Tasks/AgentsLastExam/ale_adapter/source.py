"""Validate the official ALE checkout without changing native task code."""

import hashlib
import subprocess
from pathlib import Path

REPOSITORY = "https://github.com/rdi-berkeley/agents-last-exam.git"
REVISION = "d9abc0734b56ea34116c5bfcbdd0b808269ab9e2"


def select_image(native, mapping):
    if native["requires_gpu"]:
        raise ValueError("GPU ALE tasks are excluded")
    profile = mapping[native["snapshot"]]
    if native["os"] == "windows" and (not isinstance(profile.get("pvc"), str) or not profile["pvc"]):
        raise ValueError("Mapped ALE image requires a golden PVC name")
    if profile["image_family"] != native["image_family"]:
        raise ValueError("Mapped ALE image family differs from the native task")
    if native["os"] == "linux":
        disk = profile.get("qemu", {}).get("disk_source", "")
        if not disk or "://" in disk or not Path(disk).expanduser().is_absolute():
            raise ValueError("Linux ALE tasks require a prepared local QEMU disk with an absolute path")
        path = Path(disk).expanduser()
        if not path.is_file() or not path.stat().st_size:
            raise ValueError("Prepared Linux QEMU disk is missing or empty")
        profile = {**profile, "qemu": {**profile["qemu"], "disk_source": str(path)}}
    return profile


def validate_source(source):
    source = Path(source).resolve()
    revision = subprocess.check_output(
        ["git", "-C", str(source), "rev-parse", "HEAD"], text=True,
    ).strip()
    if revision != REVISION:
        raise ValueError(f"ALE source must be pinned to {REVISION}")
    subprocess.run(
        ["git", "-C", str(source), "diff", "--quiet", "HEAD", "--", "ale_run", "tasks", "configs"],
        check=True,
    )
    return source


def source_digest(source):
    """Also detect untracked helpers that could affect Python task imports."""
    digest = hashlib.sha256()
    for directory in ("ale_run", "tasks", "configs"):
        for path in sorted((Path(source) / directory).rglob("*")):
            if path.is_file() and "__pycache__" not in path.parts and path.suffix != ".pyc":
                digest.update(str(path.relative_to(source)).encode())
                digest.update(path.read_bytes())
    return digest.hexdigest()

"""Validate the official ALE checkout without changing native task code."""

import hashlib
import subprocess
from pathlib import Path

REPOSITORY = "https://github.com/rdi-berkeley/agents-last-exam.git"
REVISION = "d9abc0734b56ea34116c5bfcbdd0b808269ab9e2"


def select_image(native, mapping):
    profile = mapping[native["snapshot"]]
    if not isinstance(profile.get("pvc"), str) or not profile["pvc"]:
        raise ValueError("Mapped ALE image requires a golden PVC name")
    if profile["image_family"] != native["image_family"]:
        raise ValueError("Mapped ALE image family differs from the native task")
    if native["requires_gpu"] and not profile.get("gpu_device"):
        raise ValueError("GPU ALE tasks require a KubeVirt GPU device resource")
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

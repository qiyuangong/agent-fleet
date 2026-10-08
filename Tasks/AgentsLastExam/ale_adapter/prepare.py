"""Explicitly prepare the pinned ALE checkout and its native host dependencies."""

import argparse
import subprocess
from pathlib import Path

from .source import REPOSITORY, REVISION, validate_source


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--env-dir", type=Path, required=True)
    args = parser.parse_args()
    if not args.source.exists():
        args.source.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["git", "init", str(args.source)], check=True)
        subprocess.run(["git", "-C", str(args.source), "fetch", "--depth", "1", REPOSITORY, REVISION], check=True)
        subprocess.run(["git", "-C", str(args.source), "checkout", "--detach", "FETCH_HEAD"], check=True)
    source = validate_source(args.source)
    if not args.env_dir.exists():
        subprocess.run(["uv", "venv", "--python", "3.12", str(args.env_dir)], check=True)
    # Keep native ALE dependencies separate from the pinned Harbor runner.
    # Both requirement sets come from the upstream revision; task eval deps can
    # include large packages such as torch. Startup never installs packages.
    subprocess.run(["uv", "pip", "install", "--torch-backend", "cpu", "--python", str(args.env_dir / "bin/python"),
                    str(source), str(source / "tasks")], check=True)


if __name__ == "__main__":
    main()

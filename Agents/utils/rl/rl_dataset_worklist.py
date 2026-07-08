#!/usr/bin/env python3
"""Generate a deterministic task work list from a Harbor-style dataset root."""

from __future__ import annotations

import argparse
from pathlib import Path


def task_sort_key(path: Path) -> tuple[int, int | str]:
    return (0, int(path.name)) if path.name.isdigit() else (1, path.name)


def discover_tasks(dataset_root: Path) -> list[str]:
    if not dataset_root.is_dir():
        raise FileNotFoundError(f"dataset root does not exist: {dataset_root}")
    tasks: list[str] = []
    for task_dir in sorted((p for p in dataset_root.iterdir() if p.is_dir()), key=task_sort_key):
        if (task_dir / "task.yaml").is_file() or (task_dir / "instruction.md").is_file():
            tasks.append(task_dir.name)
    return tasks


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("dataset_root")
    parser.add_argument("--output", required=True)
    parser.add_argument("--include-disabled", action="store_true")
    parser.add_argument("--disabled-task-ids", default="")
    args = parser.parse_args()

    disabled = {
        item.strip()
        for item in args.disabled_task_ids.replace(";", ",").split(",")
        if item.strip()
    }
    tasks = discover_tasks(Path(args.dataset_root))
    if not args.include_disabled:
        tasks = [task for task in tasks if task not in disabled]

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n".join(tasks) + ("\n" if tasks else ""), encoding="utf-8")
    print(f"wrote {len(tasks)} tasks to {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Write a final summary for a native Harbor registry run."""

from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path


def main() -> None:
    job_dir_raw, summary_raw, exit_code, dataset = sys.argv[1:]
    job_dir = Path(job_dir_raw) if job_dir_raw else None
    summary = Path(summary_raw)

    result_path = None
    result = {}
    if job_dir and job_dir.is_dir():
        candidates = sorted(
            job_dir.rglob("result.json"),
            key=lambda path: path.stat().st_mtime,
            reverse=True,
        )
        for candidate in candidates:
            try:
                payload = json.loads(candidate.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                continue
            if (
                isinstance(payload, dict)
                and "n_total_trials" in payload
                and isinstance(payload.get("stats"), dict)
            ):
                result_path = candidate
                result = payload
                break

    lines = [
        f"finished_at: {result.get('finished_at') or datetime.now(timezone.utc).isoformat()}",
        f"RUN_ID:      {os.environ.get('RUN_ID', '')}",
        f"AGENT:       {os.environ.get('AGENT', '')}",
        f"DATASET_NAME: {dataset}",
        f"OUTPUT_PATH: {summary.parent}",
        f"OPIK_PROJECT_NAME: {os.environ.get('OPIK_PROJECT_NAME', '')}",
        f"harbor_exit_code: {exit_code}",
        "",
    ]

    if result_path is None:
        lines.append("Harbor result summary: unavailable")
    else:
        stats = result.get("stats") or {}
        lines.extend(
            [
                f"total:      {result.get('n_total_trials', 0)}",
                f"completed:  {stats.get('n_completed_trials', 0)}",
                f"errored:    {stats.get('n_errored_trials', 0)}",
                f"cancelled:  {stats.get('n_cancelled_trials', 0)}",
                f"retries:    {stats.get('n_retries', 0)}",
                "",
                "Harbor stats:",
                json.dumps(stats, indent=2, sort_keys=True),
            ]
        )

    lines.extend(
        [
            "",
            "result paths:",
            f"  output:          {summary.parent}",
            f"  job:             {job_dir_raw or '<unknown>'}",
            f"  result:          {result_path or '<missing>'}",
        ]
    )

    summary.parent.mkdir(parents=True, exist_ok=True)
    tmp = summary.with_name(f"{summary.name}.tmp.{os.getpid()}")
    tmp.write_text("\n".join(lines) + "\n", encoding="utf-8")
    os.replace(tmp, summary)


if __name__ == "__main__":
    main()

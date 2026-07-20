"""Validate the Monitor PR #52 analyzer handover v2 contract."""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any

from . import SCHEMA_VERSION
from .identity import task_key

EXPECTED_AUDIENCE = "analyzer_subagent"
EXPECTED_KIND = "task_analysis_handover"
EXPECTED_ANALYZE_STATUSES = {"complete_failed", "complete_unknown", "not_complete"}
EXPECTED_SKIP_STATUSES = {"complete_success"}
HANDOVER_ID_RE = re.compile(r"^sha256-[0-9a-f]{64}$")


def _resolved(value: str) -> Path:
    return Path(value).expanduser().resolve()


def validate_handover(
    handover: dict[str, Any],
    *,
    run_dir: Path,
    queue_dir: Path | None,
) -> list[dict[str, Any]]:
    """Return validated task copies or raise ValueError on a contract mismatch."""

    errors: list[str] = []
    if handover.get("schema_version") != SCHEMA_VERSION:
        errors.append("schema_version_must_be_2")
    if handover.get("audience") != EXPECTED_AUDIENCE:
        errors.append("audience_must_be_analyzer_subagent")
    if handover.get("kind") != EXPECTED_KIND:
        errors.append("kind_must_be_task_analysis_handover")

    handover_id = handover.get("handover_id")
    if not isinstance(handover_id, str) or not HANDOVER_ID_RE.fullmatch(handover_id):
        errors.append("handover_id_must_be_sha256")

    tasks = handover.get("tasks")
    if not isinstance(tasks, list):
        errors.append("tasks_must_be_array")
        tasks = []
    should_run = handover.get("should_run_analyzer")
    if not isinstance(should_run, bool):
        errors.append("should_run_analyzer_must_be_boolean")
    elif should_run != bool(tasks):
        errors.append("should_run_analyzer_tasks_mismatch")

    analyze_statuses = handover.get("analyze_statuses")
    if not isinstance(analyze_statuses, list) or not all(
        isinstance(value, str) and value for value in analyze_statuses
    ):
        errors.append("analyze_statuses_must_be_nonempty_string_array")
        analyze_statuses = []
    skip_statuses = handover.get("skip_statuses")
    if not isinstance(skip_statuses, list) or not all(
        isinstance(value, str) and value for value in skip_statuses
    ):
        errors.append("skip_statuses_must_be_string_array")
        skip_statuses = []
    if set(analyze_statuses) & set(skip_statuses):
        errors.append("analyze_and_skip_statuses_overlap")
    if set(analyze_statuses) != EXPECTED_ANALYZE_STATUSES:
        errors.append("analyze_statuses_status_policy_mismatch")
    if set(skip_statuses) != EXPECTED_SKIP_STATUSES:
        errors.append("skip_statuses_status_policy_mismatch")

    signal_definitions = handover.get("signal_definitions")
    if not isinstance(signal_definitions, dict) or not all(
        isinstance(key, str)
        and key
        and isinstance(value, str)
        and value.strip()
        for key, value in (signal_definitions.items() if isinstance(signal_definitions, dict) else [])
    ):
        errors.append("signal_definitions_must_be_string_map")
        signal_definitions = {}

    paths = handover.get("paths")
    if not isinstance(paths, dict):
        errors.append("paths_must_be_object")
        paths = {}
    contract_run_dir = paths.get("run_dir")
    if not isinstance(contract_run_dir, str) or not contract_run_dir:
        errors.append("paths_run_dir_required")
    else:
        try:
            if _resolved(contract_run_dir) != run_dir.resolve():
                errors.append("paths_run_dir_mismatch")
        except OSError:
            errors.append("paths_run_dir_invalid")

    contract_queue_dir = paths.get("queue_dir")
    if queue_dir is None:
        if contract_queue_dir not in (None, ""):
            errors.append("paths_queue_dir_cli_missing")
    elif not isinstance(contract_queue_dir, str) or not contract_queue_dir:
        errors.append("paths_queue_dir_required")
    else:
        try:
            if _resolved(contract_queue_dir) != queue_dir.resolve():
                errors.append("paths_queue_dir_mismatch")
        except OSError:
            errors.append("paths_queue_dir_invalid")

    validated: list[dict[str, Any]] = []
    identities: set[tuple[str, str, str]] = set()
    for index, raw_task in enumerate(tasks):
        if not isinstance(raw_task, dict):
            errors.append(f"task_{index}_must_be_object")
            continue
        task = dict(raw_task)
        task_index = str(task.get("task_index") or "").strip()
        task_name = str(task.get("task_name") or "").strip()
        if not task_index:
            errors.append(f"task_{index}_task_index_required")
        if not task_name:
            errors.append(f"task_{index}_task_name_required")
        status = task.get("task_complete_status")
        if status not in analyze_statuses:
            errors.append(f"task_{index}_status_not_analyzable")
        if status in skip_statuses:
            errors.append(f"task_{index}_status_is_skipped")
        signals = task.get("task_result_signals")
        if not isinstance(signals, list) or not all(isinstance(value, str) for value in signals):
            errors.append(f"task_{index}_signals_must_be_string_array")
            signals = []
        missing_definitions = sorted(set(signals) - set(signal_definitions))
        if missing_definitions:
            errors.append(
                f"task_{index}_signal_definitions_missing={','.join(missing_definitions)}"
            )
        identity = task_key(
            {
                "task_index": task_index,
                "task_name": task_name,
                "attempt_id": task.get("attempt_id"),
            }
        )
        if identity in identities:
            errors.append(f"task_{index}_duplicate_identity")
        identities.add(identity)
        validated.append(task)

    if errors:
        raise ValueError("invalid analyzer handover v2: " + "; ".join(errors))
    return validated

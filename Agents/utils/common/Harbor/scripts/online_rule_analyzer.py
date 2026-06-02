#!/usr/bin/env python3
"""Tail Harbor task consoles and report deterministic task-status signals."""

from __future__ import annotations

import argparse
import json
import re
import time
from collections import Counter
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

STRUCTURED_PREFIX = "[ONLINE_ENV] "
CONSOLE_RE = re.compile(r"^(?P<task_id>\d+)-(?P<task_name>.+)\.console\.log$")
ANSI_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
TASK_BLOCKING_ALLOWLIST = {
    ("preflight", "host_prerequisite", "command_unavailable"),
    ("preflight", "docker", "daemon_unavailable"),
    ("preflight", "docker_registry", "connectivity_unavailable"),
    ("agent_setup", "agent_configuration", "invalid_llm_kwargs"),
    ("agent_setup", "agent_configuration", "auth_token_missing"),
}
RAW_RULES = (
    (re.compile(r"Docker Hub preflight failed|cannot reach https://(?:auth|registry-1)\.docker\.io", re.I), "harbor_console_compat", "docker-registry-preflight-degraded", "docker_registry", "warning"),
    (re.compile(r"NonZeroAgentExitCodeError"), "agent_runtime", "agent-process-exit-abnormal", "agent", "warning"),
    (re.compile(r"AgentTimeoutError"), "agent_runtime", "agent-timeout", "agent", "warning"),
)
IGNORED_RAW = (re.compile(r"No module named ['\"]botocore['\"]", re.I),)


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


@dataclass
class Event:
    timestamp: str
    task_id: int
    task_name: str
    source_file: str
    layer: str
    phase: str
    component: str
    event: str
    severity: str
    fatal: bool
    task_blocking: bool
    evidence: str
    structured: bool


class Analyzer:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.run_dir = args.run_dir.resolve()
        self.output_dir = (args.output_dir or self.run_dir / "online-analysis").resolve()
        self.events_path = self.output_dir / "environment-events.jsonl"
        self.summary_path = self.output_dir / "environment-summary.json"
        self.offsets: dict[Path, int] = {}
        self.partials: dict[Path, str] = {}
        self.partial_updated_at: dict[Path, float] = {}
        self.partial_idle_seconds = max(2.0, args.poll_interval * 2)
        self.events: list[Event] = []
        self.seen_raw: set[tuple[int, str]] = set()

    def consoles(self) -> list[tuple[Path, int, str]]:
        found = []
        for path in sorted(self.run_dir.glob("*.console.log")):
            match = CONSOLE_RE.match(path.name)
            if match:
                found.append((path, int(match.group("task_id")), match.group("task_name")))
        return found

    def emit(self, event: Event) -> None:
        self.events.append(event)
        with self.events_path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(asdict(event), ensure_ascii=True, sort_keys=True) + "\n")
        self.write_summary()

    def parse_structured(self, line: str, path: Path, task_id: int, task_name: str) -> Event | None:
        if not line.startswith(STRUCTURED_PREFIX):
            return None
        try:
            data: dict[str, Any] = json.loads(line[len(STRUCTURED_PREFIX):])
        except json.JSONDecodeError as exc:
            return Event(utc_now(), task_id, task_name, str(path), "harbor", "unknown", "structured_event", "invalid_json", "warning", False, False, str(exc), True)
        if data.get("schema") != 1 or data.get("task_id") not in (None, task_id) or data.get("scope") != "task":
            return Event(utc_now(), task_id, task_name, str(path), "harbor", "unknown", "structured_event", "invalid_payload", "warning", False, False, line[:500], True)
        phase = str(data.get("phase", "unknown"))
        component = str(data.get("component", "unknown"))
        event = str(data.get("event", "unknown"))
        fatal = data.get("fatal") is True
        task_blocking = fatal and (phase, component, event) in TASK_BLOCKING_ALLOWLIST
        return Event(utc_now(), task_id, task_name, str(path), "harbor", phase, component, event, str(data.get("severity", "warning")), fatal, task_blocking, str(data.get("message", ""))[:1000], True)

    def parse_line(self, raw_line: str, path: Path, task_id: int, task_name: str) -> None:
        line = ANSI_RE.sub("", raw_line).rstrip("\r\n")
        event = self.parse_structured(line, path, task_id, task_name)
        if event:
            self.emit(event)
            return
        if any(pattern.search(line) for pattern in IGNORED_RAW):
            return
        for pattern, layer, event_name, component, severity in RAW_RULES:
            if pattern.search(line) and (task_id, event_name) not in self.seen_raw:
                self.seen_raw.add((task_id, event_name))
                self.emit(Event(utc_now(), task_id, task_name, str(path), layer, "unknown", component, event_name, severity, False, False, line[:1000], False))

    def scan_once(self) -> None:
        for path, task_id, task_name in self.consoles():
            offset = self.offsets.get(path, 0)
            try:
                if path.stat().st_size < offset:
                    offset = 0
                    self.partials[path] = ""
                    self.partial_updated_at.pop(path, None)
                with path.open("r", encoding="utf-8", errors="replace") as handle:
                    handle.seek(offset)
                    chunk = handle.read()
                    self.offsets[path] = handle.tell()
            except FileNotFoundError:
                continue
            previous_partial = self.partials.get(path, "")
            lines = (previous_partial + chunk).splitlines(keepends=True)
            self.partials[path] = ""
            if lines and not lines[-1].endswith(("\n", "\r")):
                partial = lines.pop()
                self.partials[path] = partial
                if partial != previous_partial:
                    self.partial_updated_at[path] = time.monotonic()
            else:
                self.partial_updated_at.pop(path, None)
            for line in lines:
                self.parse_line(line, path, task_id, task_name)
        self.write_summary()

    def flush_partials(self, force: bool = False) -> None:
        now = time.monotonic()
        for path, task_id, task_name in self.consoles():
            line = self.partials.get(path, "")
            if not line or (not force and now - self.partial_updated_at[path] < self.partial_idle_seconds):
                continue
            if not force and line.startswith(STRUCTURED_PREFIX):
                try:
                    json.loads(line[len(STRUCTURED_PREFIX):])
                except json.JSONDecodeError:
                    continue
            self.partials.pop(path, None)
            self.partial_updated_at.pop(path, None)
            self.parse_line(line, path, task_id, task_name)

    def write_summary(self) -> None:
        monitor_environment_events = Counter(
            f"{event.component}.{event.event}"
            for event in self.events
            if event.structured
        )
        summary = {
            "schema": 1,
            "generated_at": utc_now(),
            "run_dir": str(self.run_dir),
            "input_policy": "top-level *.console.log only",
            "mode": "follow" if self.args.follow else "replay",
            "console_files_scanned": len(self.consoles()),
            "event_count": len(self.events),
            "task_blocking_event_count": sum(event.task_blocking for event in self.events),
            "events_by_type": dict(sorted(Counter(event.event for event in self.events).items())),
            "monitor_environment_events_by_type": dict(sorted(monitor_environment_events.items())),
        }
        self.summary_path.write_text(json.dumps(summary, indent=2, ensure_ascii=True, sort_keys=True) + "\n", encoding="utf-8")

    def run(self) -> None:
        self.output_dir.mkdir(parents=True, exist_ok=True)
        self.events_path.write_text("", encoding="utf-8")
        self.scan_once()
        if not self.args.follow:
            self.flush_partials(force=True)
        while self.args.follow:
            time.sleep(self.args.poll_interval)
            self.scan_once()
            self.flush_partials()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_dir", type=Path)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--follow", action="store_true")
    parser.add_argument("--poll-interval", type=float, default=1.0)
    args = parser.parse_args()
    if args.poll_interval <= 0:
        parser.error("--poll-interval must be positive")
    return args


if __name__ == "__main__":
    Analyzer(parse_args()).run()

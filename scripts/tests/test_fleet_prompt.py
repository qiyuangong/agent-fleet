import json
import os
import pty
import signal
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "run_fleet.sh"


class FleetGoalTest(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.repo = self.root / "repo"
        self.bin_dir = self.root / "bin"
        self.repo.mkdir()
        self.bin_dir.mkdir()

        (self.repo / "config.env").write_text(
            "BASE_URL=https://public.example.invalid\n"
            "API_KEY=fake-public-token\n"
            "MODEL=public-model\n",
            encoding="utf-8",
        )
        (self.repo / "config.local.env").write_text(
            "BASE_URL=https://local.example.invalid/v1\n"
            "API_KEY=fake-local-token\n"
            "MODEL=local-model\n",
            encoding="utf-8",
        )

        claude = self.bin_dir / "claude"
        claude.write_text(
            """#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${CLAUDE_STUB_CAPTURE:-}" ]]; then
  {
    printf 'base=%s\\n' "${ANTHROPIC_BASE_URL:-}"
    printf 'token=%s\\n' "${ANTHROPIC_AUTH_TOKEN:-}"
    printf 'model=%s\\n' "${ANTHROPIC_MODEL:-}"
    printf 'haiku=%s\\n' "${ANTHROPIC_DEFAULT_HAIKU_MODEL:-}"
    printf 'fast=%s\\n' "${ANTHROPIC_SMALL_FAST_MODEL:-}"
    printf 'arg=<%s>\\n' "$@"
  } >"$CLAUDE_STUB_CAPTURE"
fi
printf '%s\\n' "$CLAUDE_STUB_RESPONSE"
exit "${CLAUDE_STUB_EXIT:-0}"
""",
            encoding="utf-8",
        )
        claude.chmod(0o755)

        harbor = self.repo / "Agents/utils/common/Harbor/start.sh"
        harbor.parent.mkdir(parents=True)
        harbor.write_text(
            """#!/usr/bin/env bash
printf 'runner=harbor\\n'
printf 'DATASET_NAME=%s\\n' "${DATASET_NAME-}"
printf 'AGENT=%s\\n' "${AGENT-}"
printf 'TOTAL_WORKERS=%s\\n' "${TOTAL_WORKERS-}"
printf 'args=%s\\n' "$*"
printf 'stdin_tty=%s\\n' "$([ -t 0 ] && echo yes || echo no)"
if [[ -n "${STUB_PIDFILE-}" ]]; then
  printf '%s\\n' "$$" >"$STUB_PIDFILE"
  # Detach the sleep from the harness pipes so an orphaned child cannot
  # hold them open after this process is signalled.
  sleep 30 </dev/null >/dev/null 2>&1
fi
exit "${STUB_EXIT:-0}"
""",
            encoding="utf-8",
        )

        pinchbench = self.repo / "Tasks/Pinchbench/scripts/run-parallel-workers.py"
        pinchbench.parent.mkdir(parents=True)
        pinchbench.write_text(
            """import os
import sys
print("runner=pinchbench")
print("args=" + " ".join(sys.argv[1:]))
raise SystemExit(int(os.environ.get("STUB_EXIT", "0")))
""",
            encoding="utf-8",
        )

        clawbio = self.repo / "Tasks/clawBio/scripts/run-openclaw-clawbio.sh"
        clawbio.parent.mkdir(parents=True)
        clawbio.write_text(
            """#!/usr/bin/env bash
printf 'runner=clawbio\\n'
printf 'COUNT=%s\\n' "${COUNT-}"
exit "${STUB_EXIT:-0}"
""",
            encoding="utf-8",
        )

    def tearDown(self):
        self.temp_dir.cleanup()

    @staticmethod
    def response(*, ready=True, message="", spec=None, specs=None):
        if specs is None and ready:
            specs = [spec or {
                "schema_version": 1,
                "taskset": "terminal-bench/terminal-bench-2",
                "agent": "claude-code",
                "workers": 2,
            }]
        elif specs is None:
            specs = []
        return json.dumps(
            {
                "type": "result",
                "structured_output": {
                    "ready": ready,
                    "message": message,
                    "specs": specs,
                },
            }
        )

    def goal_env(self, response=None, extra_env=None):
        env = os.environ.copy()
        for name in (
            "ANTHROPIC_API_KEY",
            "ANTHROPIC_AUTH_TOKEN",
            "ANTHROPIC_BASE_URL",
            "ANTHROPIC_MODEL",
            "ANTHROPIC_DEFAULT_OPUS_MODEL",
            "ANTHROPIC_DEFAULT_SONNET_MODEL",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL",
            "ANTHROPIC_SMALL_FAST_MODEL",
            "CLAUDE_CODE_SUBAGENT_MODEL",
            "API_KEY",
            "BASE_URL",
            "MODEL",
        ):
            env.pop(name, None)
        env.update(
            {
                "PATH": f"{self.bin_dir}{os.pathsep}{env['PATH']}",
                "REPO_DIR": str(self.repo),
                "CLAUDE_STUB_RESPONSE": response or self.response(),
            }
        )
        env.update(extra_env or {})
        return env

    def run_goal(self, *args, response=None, extra_env=None, stdin=None):
        return subprocess.run(
            [str(SCRIPT), *args],
            cwd=self.root,
            env=self.goal_env(response=response, extra_env=extra_env),
            text=True,
            capture_output=True,
            check=False,
            stdin=stdin,
        )

    def test_prompt_writes_fleetspec_and_runs_it(self):
        output = self.root / "fleet-spec.json"
        result = self.run_goal(
            "--prompt",
            "Run terminal-bench/terminal-bench-2 with claude-code and 2 workers",
            "--output",
            str(output),
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("FleetSpec written", result.stderr)
        self.assertIn("runner=harbor", result.stdout)
        self.assertIn("DATASET_NAME=terminal-bench/terminal-bench-2", result.stdout)
        self.assertIn("AGENT=claude-code", result.stdout)
        self.assertIn("TOTAL_WORKERS=2", result.stdout)
        self.assertEqual(
            json.loads(output.read_text(encoding="utf-8")),
            {
                "schema_version": 1,
                "taskset": "terminal-bench/terminal-bench-2",
                "agent": "claude-code",
                "workers": 2,
            },
        )

    def test_prompt_runs_openclaw_without_printing_the_spec(self):
        result = self.run_goal("--prompt", "Run pinchbench", response=self.response(
            spec={"schema_version": 1, "taskset": "pinchbench"}
        ))

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("runner=pinchbench", result.stdout)
        self.assertNotIn("schema_version", result.stdout)
        # The interpreted spec must still be visible on stderr: without it, a
        # mistranslated prompt starts a runner with no trace of what was asked.
        self.assertIn(
            '[INFO] FleetSpec: {"schema_version":1,"taskset":"pinchbench"}',
            result.stderr,
        )

    def test_caller_config_wins_and_goal_is_one_literal_argument(self):
        capture = self.root / "claude-capture.txt"
        goal = '{"request":"run terminal-bench/terminal-bench-2"}'
        result = self.run_goal(
            "--prompt",
            goal,
            extra_env={
                "BASE_URL": "https://caller.example.invalid/v1/",
                "API_KEY": "fake-caller-token",
                "MODEL": "caller-model",
                "ANTHROPIC_BASE_URL": "https://stale.example.invalid",
                "ANTHROPIC_AUTH_TOKEN": "fake-stale-token",
                "ANTHROPIC_MODEL": "stale-model",
                "CLAUDE_STUB_CAPTURE": str(capture),
            },
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        captured = capture.read_text(encoding="utf-8")
        self.assertIn("base=https://caller.example.invalid", captured)
        self.assertIn("token=fake-caller-token", captured)
        self.assertIn("model=caller-model", captured)
        self.assertIn("haiku=caller-model", captured)
        self.assertIn("fast=caller-model", captured)
        self.assertNotIn("stale", captured)
        self.assertIn(f"arg=<{goal}>", captured)
        self.assertIn("Terminus-2", captured)
        self.assertIn("return ready=false", captured)
        self.assertIn('"specs"', captured)
        self.assertIn('"maxItems": 16', captured)

    def test_prompt_multiple_specs_run_through_spec_dispatch_and_write_array(self):
        output = self.root / "fleet-specs.json"
        result = self.run_goal(
            "--prompt",
            "Run terminalbench21 once with claude-code and once with opencode, both with 2 workers",
            "--output",
            str(output),
            "--detach",
            response=self.response(
                specs=[
                    {
                        "schema_version": 1,
                        "taskset": "terminalbench21",
                        "agent": "claude-code",
                        "workers": 2,
                    },
                    {
                        "schema_version": 1,
                        "taskset": "terminalbench21",
                        "agent": "opencode",
                        "workers": 2,
                    },
                ]
            ),
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            json.loads(output.read_text(encoding="utf-8")),
            [
                {
                    "schema_version": 1,
                    "taskset": "terminalbench21",
                    "agent": "claude-code",
                    "workers": 2,
                },
                {
                    "schema_version": 1,
                    "taskset": "terminalbench21",
                    "agent": "opencode",
                    "workers": 2,
                },
            ],
        )
        self.assertIn('[INFO] FleetSpec [1/2]:', result.stderr)
        self.assertIn('[INFO] FleetSpec [2/2]:', result.stderr)
        self.assertIn("--detach is implicit", result.stderr)
        artifact_dirs = list((self.root / "fleet-batch-logs").iterdir())
        self.assertEqual(len(artifact_dirs), 1)
        first_log = (artifact_dirs[0] / "1.log").read_text(encoding="utf-8")
        second_log = (artifact_dirs[0] / "2.log").read_text(encoding="utf-8")
        self.assertIn("AGENT=claude-code", first_log)
        self.assertIn("AGENT=opencode", second_log)
        self.assertIn("TOTAL_WORKERS=2", first_log)
        self.assertIn("args=--detach", first_log)
        self.assertIn("args=--detach", second_log)

    def test_prompt_has_no_separate_batch_entrypoint(self):
        prompt_script = (SCRIPT.parent / "fleet_prompt.sh").read_text(encoding="utf-8")

        self.assertIn("run_args=(--spec /dev/fd/3)", prompt_script)
        self.assertNotIn("--batch", prompt_script)
        self.assertNotIn("fleet_batch.sh", prompt_script)

    def test_prompt_multiple_specs_dry_run_starts_no_runner(self):
        result = self.run_goal(
            "--prompt",
            "Run owner/first and owner/second",
            "--dry-run",
            response=self.response(
                specs=[
                    {"schema_version": 1, "taskset": "owner/first"},
                    {"schema_version": 1, "taskset": "owner/second"},
                ]
            ),
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count("Command: env"), 2)
        self.assertNotIn("runner=harbor", result.stdout)
        artifact_dirs = list((self.root / "fleet-batch-logs").iterdir())
        self.assertEqual(len(artifact_dirs), 1)
        self.assertEqual(list(artifact_dirs[0].glob("*.log")), [])

    def test_prompt_multiple_specs_return_aggregate_failure(self):
        result = self.run_goal(
            "--prompt",
            "Run owner/first and owner/second",
            response=self.response(
                specs=[
                    {"schema_version": 1, "taskset": "owner/first"},
                    {"schema_version": 1, "taskset": "owner/second"},
                ]
            ),
            extra_env={"STUB_EXIT": "17"},
        )

        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr.count("FAILED(17)"), 2)

    def test_prompt_multiple_openclaw_specs_are_rejected_before_output(self):
        output = self.root / "fleet-specs.json"
        result = self.run_goal(
            "--prompt",
            "Run pinchbench and clawbio",
            "--output",
            str(output),
            response=self.response(
                specs=[
                    {"schema_version": 1, "taskset": "pinchbench"},
                    {"schema_version": 1, "taskset": "clawbio"},
                ]
            ),
        )

        self.assertEqual(result.returncode, 3)
        self.assertIn("at most one OpenClaw run", result.stderr)
        self.assertNotIn("[INFO] FleetSpec", result.stderr)
        self.assertFalse(output.exists())
        self.assertFalse((self.root / "fleet-batch-logs").exists())
        self.assertNotIn("runner=", result.stdout)

    def test_prompt_rejects_multi_run_when_one_spec_is_invalid(self):
        output = self.root / "fleet-specs.json"
        result = self.run_goal(
            "--prompt",
            "Run owner/valid and another invalid run",
            "--output",
            str(output),
            response=self.response(
                specs=[
                    {"schema_version": 1, "taskset": "owner/valid"},
                    {"schema_version": 1, "taskset": ""},
                ]
            ),
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn("invalid FleetSpec", result.stderr)
        self.assertFalse(output.exists())
        self.assertFalse((self.root / "fleet-batch-logs").exists())

    def test_goal_needing_input_does_not_write_a_spec(self):
        output = self.root / "fleet-spec.json"
        result = self.run_goal(
            "--prompt",
            "Run a benchmark",
            "--output",
            str(output),
            response=self.response(
                ready=False,
                message="Which taskset should be run?",
            ),
        )

        self.assertEqual(result.returncode, 3)
        self.assertIn("Which taskset should be run?", result.stderr)
        self.assertFalse(output.exists())
        self.assertNotIn("runner=", result.stdout)

    def test_ready_translation_with_invalid_spec_is_rejected(self):
        result = self.run_goal(
            "--prompt",
            "Run something",
            response=self.response(spec={"schema_version": 1, "taskset": ""}),
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn("invalid FleetSpec v1 candidate", result.stderr)
        self.assertNotIn("runner=", result.stdout)

    def test_ready_translation_with_nonempty_message_is_rejected(self):
        # The envelope contract says ready=true and a question cannot coexist;
        # a translation that violates it must not silently produce a spec.
        result = self.run_goal(
            "--prompt",
            "Run pinchbench",
            response=self.response(ready=True, message="Are you sure?"),
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn("no valid structured Prompt translation", result.stderr)
        self.assertNotIn("runner=", result.stdout)

    def test_integral_float_workers_are_normalized(self):
        # JSON has no int/float distinction; a model-produced 3.0 passes the
        # integral check but must reach the runner as 3, never 3.0.
        result = self.run_goal(
            "--prompt",
            "Run pinchbench with 3 workers",
            response=self.response(
                spec={"schema_version": 1, "taskset": "pinchbench", "workers": 3.0}
            ),
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("runner=pinchbench", result.stdout)
        self.assertIn("args=--instances 3", result.stdout)
        self.assertNotIn("3.0", result.stdout)

    def test_workers_above_4096_are_rejected(self):
        result = self.run_goal(
            "--prompt",
            "Run pinchbench with 5000 workers",
            response=self.response(
                spec={"schema_version": 1, "taskset": "pinchbench", "workers": 5000}
            ),
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn("invalid FleetSpec v1 candidate", result.stderr)
        self.assertNotIn("runner=", result.stdout)

    def test_missing_config_fails_before_calling_the_model(self):
        (self.repo / "config.env").unlink()
        (self.repo / "config.local.env").unlink()
        capture = self.root / "claude-capture.txt"
        result = self.run_goal(
            "--prompt",
            "Run pinchbench",
            extra_env={"CLAUDE_STUB_CAPTURE": str(capture)},
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn("incomplete model configuration", result.stderr)
        self.assertFalse(capture.exists())
        self.assertNotIn("runner=", result.stdout)

    def test_socket_failure_with_proxy_prints_no_proxy_hint(self):
        result = self.run_goal(
            "--prompt",
            "Run pinchbench",
            response=json.dumps({"result": "API Error: UND_ERR_SOCKET"}),
            extra_env={
                "CLAUDE_STUB_EXIT": "1",
                "HTTPS_PROXY": "http://proxy.example.invalid:8080",
            },
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn("UND_ERR_SOCKET", result.stderr)
        self.assertIn("add its hostname to NO_PROXY", result.stderr)
        self.assertNotIn("runner=", result.stdout)

    def test_goal_requires_nonempty_text(self):
        result = self.run_goal("--prompt", "   ")

        self.assertEqual(result.returncode, 2)
        self.assertIn("must not be empty", result.stderr)

    def test_prompt_dry_run_resolves_command_without_starting_runner(self):
        result = self.run_goal(
            "--prompt",
            "Run terminal-bench/terminal-bench-2 with two workers",
            "--dry-run",
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Command: env", result.stdout)
        self.assertIn("DATASET_NAME=terminal-bench/terminal-bench-2", result.stdout)
        self.assertIn("TOTAL_WORKERS=2", result.stdout)
        self.assertNotIn("runner=harbor", result.stdout)

    def test_prompt_detach_is_forwarded_through_spec_execution(self):
        result = self.run_goal(
            "--prompt",
            "Run terminal-bench/terminal-bench-2",
            "--detach",
            "--dry-run",
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Harbor/start.sh --detach", result.stdout)

    def test_prompt_returns_downstream_runner_exit_code(self):
        result = self.run_goal(
            "--prompt",
            "Run terminal-bench/terminal-bench-2",
            extra_env={"STUB_EXIT": "17"},
        )

        self.assertEqual(result.returncode, 17)
        self.assertIn("runner=harbor", result.stdout)

    def test_prompt_output_requires_a_file_path_before_model_call(self):
        capture = self.root / "claude-capture.txt"
        result = self.run_goal(
            "--prompt",
            "Run pinchbench",
            "--output",
            "-",
            extra_env={"CLAUDE_STUB_CAPTURE": str(capture)},
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn("file path, not -", result.stderr)
        self.assertFalse(capture.exists())
        self.assertNotIn("runner=", result.stdout)

    def test_prompt_output_rejects_empty_path_before_model_call(self):
        capture = self.root / "claude-capture.txt"
        result = self.run_goal(
            "--prompt",
            "Run pinchbench",
            "--output",
            "",
            extra_env={"CLAUDE_STUB_CAPTURE": str(capture)},
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn("non-empty file path", result.stderr)
        self.assertFalse(capture.exists())
        self.assertNotIn("runner=", result.stdout)

    def test_prompt_output_rejects_mistyped_option_token_before_model_call(self):
        capture = self.root / "claude-capture.txt"
        result = self.run_goal(
            "--prompt",
            "Run pinchbench",
            "--output",
            "--dryrn",
            extra_env={"CLAUDE_STUB_CAPTURE": str(capture)},
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn("requires a file path", result.stderr)
        self.assertFalse(capture.exists())
        self.assertFalse((self.root / "--dryrn").exists())

    def test_prompt_output_rejects_option_token_before_model_call(self):
        # `--output --dry-run` is a mangled preview command; consuming the
        # token as a filename silently turned it into a live benchmark run.
        capture = self.root / "claude-capture.txt"
        result = self.run_goal(
            "--prompt",
            "Run pinchbench",
            "--output",
            "--dry-run",
            extra_env={"CLAUDE_STUB_CAPTURE": str(capture)},
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn("requires a file path", result.stderr)
        self.assertFalse(capture.exists())
        self.assertNotIn("runner=", result.stdout)
        self.assertFalse((self.root / "--dry-run").exists())

    def test_prompt_foreground_runner_keeps_terminal_stdin(self):
        # The runner must inherit the caller's terminal on fd 0: foreground
        # Harbor attaches an interactive Zellij session that reads it.
        master, slave = pty.openpty()
        try:
            result = self.run_goal(
                "--prompt",
                "Run terminal-bench/terminal-bench-2 with claude-code and 2 workers",
                stdin=slave,
            )
        finally:
            os.close(master)
            os.close(slave)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("stdin_tty=yes", result.stdout)
        self.assertIn("DATASET_NAME=terminal-bench/terminal-bench-2", result.stdout)

    def test_prompt_cancellation_by_pid_reaches_the_runner(self):
        # The exec chain must keep the runner on the PID a supervisor knows,
        # so cancelling that PID stops the benchmark instead of orphaning it.
        pidfile = self.root / "runner.pid"
        proc = subprocess.Popen(
            [str(SCRIPT), "--prompt", "Run terminal-bench/terminal-bench-2"],
            cwd=self.root,
            env=self.goal_env(extra_env={"STUB_PIDFILE": str(pidfile)}),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            for _ in range(200):
                if pidfile.exists() and pidfile.read_text().strip():
                    break
                time.sleep(0.05)
            else:
                proc.kill()
                self.fail("runner never started")

            self.assertEqual(int(pidfile.read_text()), proc.pid)
            proc.send_signal(signal.SIGTERM)
            self.assertEqual(proc.wait(timeout=5), -signal.SIGTERM)
        finally:
            if proc.poll() is None:
                proc.kill()
            proc.stdout.close()
            proc.stderr.close()
            proc.wait()

    def test_short_flags_match_long_forms(self):
        output = self.root / "spec.json"
        result = self.run_goal(
            "-p",
            "Run terminal-bench/terminal-bench-2 with claude-code and 2 workers",
            "-o",
            str(output),
            "-d",
            "--dry-run",
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Harbor/start.sh --detach", result.stdout)
        self.assertTrue(output.exists())

    def test_short_option_token_rejected_as_output_value(self):
        result = self.run_goal("-p", "Run pinchbench", "-o", "-d")

        self.assertEqual(result.returncode, 2)
        self.assertIn("requires a file path", result.stderr)
        self.assertNotIn("runner=", result.stdout)

    def test_spec_option_token_rejected_as_prompt_output_value(self):
        result = self.run_goal("-p", "Run pinchbench", "-o", "--spec")

        self.assertEqual(result.returncode, 2)
        self.assertIn("requires a file path", result.stderr)
        self.assertNotIn("runner=", result.stdout)

    def test_unsupported_terminus_prompt_does_not_write_a_spec(self):
        output = self.root / "fleet-spec.json"
        result = self.run_goal(
            "--prompt",
            "Run terminalbench21 with Terminus-2",
            "--output",
            str(output),
            response=self.response(
                ready=False,
                message="Terminus-2 is not a supported Harbor agent.",
            ),
        )

        self.assertEqual(result.returncode, 3)
        self.assertIn("not a supported Harbor agent", result.stderr)
        self.assertFalse(output.exists())
        self.assertNotIn("runner=", result.stdout)

    def test_model_cannot_emit_unsupported_terminus_spec(self):
        result = self.run_goal(
            "--prompt",
            "Run terminalbench21 with Terminus-2",
            response=self.response(
                spec={
                    "schema_version": 1,
                    "taskset": "terminalbench21",
                    "agent": "Terminus-2",
                }
            ),
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn("invalid FleetSpec v1 candidate", result.stderr)
        self.assertNotIn("runner=", result.stdout)


if __name__ == "__main__":
    unittest.main()

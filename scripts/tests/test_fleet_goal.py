import json
import os
import subprocess
import tempfile
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

    def tearDown(self):
        self.temp_dir.cleanup()

    @staticmethod
    def response(*, ready=True, message="", spec=None):
        if spec is None:
            spec = {
                "schema_version": 1,
                "taskset": "terminal-bench/terminal-bench-2",
                "agent": "claude-code",
                "workers": 2,
            }
        return json.dumps(
            {
                "type": "result",
                "structured_output": {
                    "ready": ready,
                    "message": message,
                    "spec": spec,
                },
            }
        )

    def run_goal(self, *args, response=None, extra_env=None):
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
        return subprocess.run(
            [str(SCRIPT), *args],
            cwd=self.root,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_goal_writes_fleetspec_without_running_a_benchmark(self):
        output = self.root / "fleet-spec.json"
        result = self.run_goal(
            "--prompt",
            "Run terminal-bench/terminal-bench-2 with claude-code and 2 workers",
            "--output",
            str(output),
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("FleetSpec written", result.stdout)
        self.assertEqual(
            json.loads(output.read_text(encoding="utf-8")),
            {
                "schema_version": 1,
                "taskset": "terminal-bench/terminal-bench-2",
                "agent": "claude-code",
                "workers": 2,
            },
        )

    def test_goal_prints_fleetspec_to_stdout_by_default(self):
        result = self.run_goal("--prompt", "Run pinchbench", response=self.response(
            spec={"schema_version": 1, "taskset": "pinchbench"}
        ))

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            json.loads(result.stdout),
            {"schema_version": 1, "taskset": "pinchbench"},
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
                spec={"schema_version": 1, "taskset": ""},
            ),
        )

        self.assertEqual(result.returncode, 3)
        self.assertIn("Which taskset should be run?", result.stderr)
        self.assertFalse(output.exists())

    def test_ready_translation_with_invalid_spec_is_rejected(self):
        result = self.run_goal(
            "--prompt",
            "Run something",
            response=self.response(spec={"schema_version": 1, "taskset": ""}),
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn("invalid FleetSpec v1 candidate", result.stderr)

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

    def test_integral_float_workers_are_normalized(self):
        # JSON has no int/float distinction; a model-produced 3.0 passes the
        # integral check but must reach the spec file as 3, never 3.0.
        result = self.run_goal(
            "--prompt",
            "Run pinchbench with 3 workers",
            response=self.response(
                spec={"schema_version": 1, "taskset": "pinchbench", "workers": 3.0}
            ),
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        workers = json.loads(result.stdout)["workers"]
        self.assertEqual(workers, 3)
        self.assertIsInstance(workers, int)

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

    def test_goal_requires_nonempty_text(self):
        result = self.run_goal("--prompt", "   ")

        self.assertEqual(result.returncode, 2)
        self.assertIn("must not be empty", result.stderr)

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
                spec={"schema_version": 1, "taskset": ""},
            ),
        )

        self.assertEqual(result.returncode, 3)
        self.assertIn("not a supported Harbor agent", result.stderr)
        self.assertFalse(output.exists())

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


if __name__ == "__main__":
    unittest.main()

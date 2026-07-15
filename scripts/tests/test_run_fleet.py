import os
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "run_fleet.sh"


class FleetRouterTest(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.repo = self.root / "repo"

        harbor = self.repo / "Agents/utils/common/Harbor/start.sh"
        harbor.parent.mkdir(parents=True)
        harbor.write_text(
            """#!/usr/bin/env bash
printf 'runner=harbor\\n'
printf 'DATASET_NAME=%s\\n' "${DATASET_NAME-}"
printf 'DATASET_PATH=%s\\n' "${DATASET_PATH-}"
printf 'TB_PATH=%s\\n' "${TB_PATH-}"
printf 'AGENT=%s\\n' "${AGENT-}"
printf 'TB_AGENT=%s\\n' "${TB_AGENT-}"
printf 'TOTAL_WORKERS=%s\\n' "${TOTAL_WORKERS-}"
printf 'TB_N_CONCURRENT=%s\\n' "${TB_N_CONCURRENT-}"
printf 'RUN_ID=%s\\n' "${RUN_ID-}"
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
print("RUN_ID=" + os.environ.get("RUN_ID", ""))
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
printf 'RUN_ID=%s\\n' "${RUN_ID-}"
exit "${STUB_EXIT:-0}"
""",
            encoding="utf-8",
        )

    def tearDown(self):
        self.temp_dir.cleanup()

    def run_fleet(self, *args, extra_env=None):
        env = os.environ.copy()
        for name in (
            "AGENT",
            "TB_AGENT",
            "TOTAL_WORKERS",
            "TB_N_CONCURRENT",
            "DATASET_NAME",
            "DATASET_PATH",
            "TB_PATH",
            "RUN_ID",
        ):
            env.pop(name, None)
        env["REPO_DIR"] = str(self.repo)
        env.update(extra_env or {})
        return subprocess.run(
            [str(SCRIPT), *args],
            cwd=self.root,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_harbor_registry_handoff(self):
        result = self.run_fleet(
            "--taskset",
            "terminal-bench/terminal-bench-2-1",
            "--agent",
            "claude-code",
            "--workers",
            "3",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("runner=harbor", result.stdout)
        self.assertIn("DATASET_NAME=terminal-bench/terminal-bench-2-1", result.stdout)
        self.assertIn("AGENT=claude-code", result.stdout)
        self.assertIn("TB_AGENT=claude-code", result.stdout)
        self.assertIn("TOTAL_WORKERS=3", result.stdout)
        self.assertIn("TB_N_CONCURRENT=3", result.stdout)
        self.assertIn("RUN_ID=\n", result.stdout)

    def test_explicit_local_taskset_maps_only_path_inputs(self):
        result = self.run_fleet("--taskset", "./tasks", "--agent", "opencode")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("runner=harbor", result.stdout)
        self.assertIn("DATASET_NAME=auto", result.stdout)
        self.assertIn(f"DATASET_PATH={self.root}/./tasks", result.stdout)
        self.assertIn(f"TB_PATH={self.root}/./tasks", result.stdout)

    def test_pinchbench_routes_to_openclaw_runner(self):
        result = self.run_fleet(
            "--taskset", "pinchbench", "--agent", "openclaw", "--workers", "4"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("runner=pinchbench", result.stdout)
        self.assertIn("args=--instances 4", result.stdout)
        self.assertIn("RUN_ID=\n", result.stdout)

    def test_clawbio_routes_to_openclaw_launcher(self):
        result = self.run_fleet(
            "--taskset", "clawbio", "--agent", "openclaw", "--workers", "5"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("runner=clawbio", result.stdout)
        self.assertIn("COUNT=5", result.stdout)
        self.assertIn("RUN_ID=\n", result.stdout)

    def test_openclaw_tasksets_route_without_agent(self):
        pinchbench = self.run_fleet("--taskset", "pinchbench")
        self.assertEqual(pinchbench.returncode, 0, pinchbench.stderr)
        self.assertIn("runner=pinchbench", pinchbench.stdout)

        clawbio = self.run_fleet("--taskset", "clawbio")
        self.assertEqual(clawbio.returncode, 0, clawbio.stderr)
        self.assertIn("runner=clawbio", clawbio.stdout)

    def test_openclaw_agent_mismatch_reports_requested_and_actual_agents(self):
        result = self.run_fleet(
            "--taskset", "clawbio", "--agent", "opencode", "--workers", "1"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("runner=clawbio", result.stdout)
        self.assertIn("requested agent: opencode", result.stderr)
        self.assertIn("taskset: clawbio", result.stderr)
        self.assertIn("actual agent: openclaw", result.stderr)

    def test_caller_agent_environment_is_preserved(self):
        result = self.run_fleet(
            "--taskset", "terminalbench21", extra_env={"AGENT": "opencode"}
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("runner=harbor", result.stdout)
        self.assertIn("AGENT=opencode", result.stdout)
        self.assertIn("TB_AGENT=\n", result.stdout)

    def test_downstream_exit_code_is_returned_unchanged(self):
        result = self.run_fleet(
            "--taskset", "terminalbench21", extra_env={"STUB_EXIT": "17"}
        )
        self.assertEqual(result.returncode, 17)

    def test_harbor_dry_run_prints_command_without_starting_runner(self):
        result = self.run_fleet(
            "--taskset",
            "terminal-bench/terminal-bench-2-1",
            "--agent",
            "claude-code",
            "--workers",
            "3",
            "--dry-run",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Command: env", result.stdout)
        self.assertIn("DATASET_NAME=terminal-bench/terminal-bench-2-1", result.stdout)
        self.assertIn("AGENT=claude-code", result.stdout)
        self.assertIn("TOTAL_WORKERS=3", result.stdout)
        self.assertIn("Harbor/start.sh", result.stdout)
        self.assertNotIn("runner=harbor", result.stdout)

    def test_harbor_detach_is_forwarded_to_start(self):
        result = self.run_fleet(
            "--taskset", "terminalbench21", "--detach", "--dry-run"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Harbor/start.sh --detach", result.stdout)

    def test_openclaw_detach_is_reported_and_ignored(self):
        for taskset in ("pinchbench", "clawbio"):
            with self.subTest(taskset=taskset):
                result = self.run_fleet(
                    "--taskset", taskset, "--detach", "--dry-run"
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f"--detach ignored for taskset: {taskset}", result.stderr)
                self.assertNotIn("--detach", result.stdout)

    def test_openclaw_dry_run_prints_each_runner_without_starting_it(self):
        pinchbench = self.run_fleet(
            "--taskset", "pinchbench", "--agent", "openclaw", "--workers", "4",
            "--dry-run",
        )
        self.assertEqual(pinchbench.returncode, 0, pinchbench.stderr)
        self.assertIn("Command: python3", pinchbench.stdout)
        self.assertIn("run-parallel-workers.py --instances 4", pinchbench.stdout)
        self.assertNotIn("runner=pinchbench", pinchbench.stdout)

        clawbio = self.run_fleet(
            "--taskset", "clawbio", "--agent", "openclaw", "--workers", "5",
            "--dry-run",
        )
        self.assertEqual(clawbio.returncode, 0, clawbio.stderr)
        self.assertIn("Command: env COUNT=5 bash", clawbio.stdout)
        self.assertIn("run-openclaw-clawbio.sh", clawbio.stdout)
        self.assertNotIn("runner=clawbio", clawbio.stdout)

    def test_help_exposes_only_router_options(self):
        result = self.run_fleet("--help")
        self.assertEqual(result.returncode, 0)
        self.assertIn("--taskset", result.stdout)
        self.assertIn("--agent", result.stdout)
        self.assertIn("--workers", result.stdout)
        self.assertIn("--detach", result.stdout)
        self.assertIn("--dry-run", result.stdout)
        self.assertNotRegex(result.stdout, r"--tasks(?:\s|$)")

    def test_portal_is_shell_only(self):
        self.assertFalse((SCRIPT.parent / "run_fleet.py").exists())
        self.assertFalse((SCRIPT.parent / "run_fleet_legacy.sh").exists())


if __name__ == "__main__":
    unittest.main()

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
WORKFLOW = ROOT / ".github" / "workflows" / "pr-ci.yml"
SANDBOX_DOCKERFILE = ROOT / ".github" / "ci" / "Dockerfile"


class PrCiWorkflowContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = WORKFLOW.read_text(encoding="utf-8")
        cls.sandbox_dockerfile = SANDBOX_DOCKERFILE.read_text(encoding="utf-8")

    def test_runs_for_draft_and_fork_pull_requests(self):
        self.assertIn('"on":\n  pull_request_target:', self.workflow)
        self.assertIn("converted_to_draft", self.workflow)
        self.assertNotIn("pull_request.draft", self.workflow)
        self.assertNotIn(
            "head.repo.full_name == github.repository",
            self.workflow,
        )

    def test_targets_the_self_hosted_linux_runner(self):
        self.assertIn(
            "runs-on: [self-hosted, Linux, X64]",
            self.workflow,
        )

    def test_uses_least_privilege_and_pinned_checkout(self):
        self.assertIn("permissions:\n  contents: read", self.workflow)
        self.assertNotIn("secrets.", self.workflow)
        self.assertEqual(self.workflow.count("persist-credentials: false"), 2)
        self.assertEqual(
            len(re.findall(r"uses: actions/checkout@[0-9a-f]{40}", self.workflow)),
            2,
        )

    def test_builds_the_sandbox_from_the_trusted_base(self):
        self.assertIn(
            "ref: ${{ github.event.pull_request.base.sha }}",
            self.workflow,
        )
        self.assertIn(
            'trusted-${{ github.run_id }}/.github/ci/Dockerfile',
            self.workflow,
        )
        self.assertRegex(
            self.sandbox_dockerfile,
            re.compile(r"\AFROM python:3\.11-slim@sha256:[0-9a-f]{64}\n"),
        )

    def test_checks_out_the_candidate_without_executing_it_on_the_host(self):
        self.assertIn(
            "repository: ${{ github.event.pull_request.head.repo.full_name }}",
            self.workflow,
        )
        self.assertIn(
            "ref: ${{ github.event.pull_request.head.sha }}",
            self.workflow,
        )
        self.assertIn(
            'candidate-${{ github.run_id }}:/src:ro',
            self.workflow,
        )

    def test_locks_down_untrusted_code_in_a_container(self):
        for option in (
            "--network none",
            "--read-only",
            "--cap-drop ALL",
            "--security-opt no-new-privileges",
            "--user 65534:65534",
        ):
            with self.subTest(option=option):
                self.assertIn(option, self.workflow)
        self.assertNotIn("/var/run/docker.sock", self.workflow)

    def test_runs_the_fast_test_suites_in_the_sandbox(self):
        for suite in ("tests", "scripts/tests", ".github/scripts/tests"):
            with self.subTest(suite=suite):
                self.assertIn(
                    f"python3 -m unittest discover -s {suite} -v",
                    self.workflow,
                )
        self.assertIn("bash scripts/tests/test_dind_run.sh", self.workflow)


if __name__ == "__main__":
    unittest.main()

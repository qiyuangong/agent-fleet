"""Pass a prepared ALE CPU dataset to Harbor's native job CLI."""

import argparse
import json
import os
from pathlib import Path

from .source import REVISION, select_image, source_digest, validate_source


def command(args):
    runner = Path(os.environ.get("HARBOR_RUNNER_DIR", "/opt/harbor-runner"))
    if not runner.exists() and "HARBOR_RUNNER_DIR" not in os.environ:
        runner = Path.home() / ".local/share/agent-fleet/harbor-runner"
    if os.environ.get("OPIK_URL"):
        cmd = [os.environ.get("HARBOR_OPIK_BIN", str(runner / "bin/opik")), "harbor"]
    else:
        cmd = [os.environ.get("HARBOR_CLI_BIN", str(runner / "bin/harbor"))]
    cmd += ["run", "--path", str(args.dataset.resolve()),
            "--agent", args.agent,
            "--env", "ale_adapter.environment:ALEEnvironment",
            "--verifier", "ale_adapter.verifier:ALEVerifier",
            "--ek", f"source={args.source.resolve()}",
            "--ek", f"native_python={args.native_python.absolute()}",
            "--ek", f"image_map={args.image_map.resolve()}",
            "--ek", f"task_data_source={args.task_data_source}"]
    return cmd + (args.harbor_args[1:] if args.harbor_args[:1] == ["--"] else args.harbor_args)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset", type=Path, required=True)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--native-python", type=Path, required=True)
    parser.add_argument("--image-map", type=Path, required=True)
    parser.add_argument("--agent", default="Agents.AgentsLastExam.agent:ALECommandAgent")
    parser.add_argument("--task-data-source", default="baked_in_sandbox")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("harbor_args", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    source = validate_source(args.source)
    provenance = json.loads((args.dataset / "dataset.json").read_text())
    if provenance.get("scope") != "cpu" or provenance["revision"] != REVISION or provenance["source_sha256"] != source_digest(source):
        parser.error("ALE dataset differs from the prepared native source")
    if not args.native_python.is_file():
        parser.error("Run ALE setup before launch")
    mapping = json.loads(args.image_map.read_text())
    definitions = sorted(args.dataset.glob("*/environment/ale.json"))
    if len(definitions) != provenance["tasks"]:
        parser.error("ALE dataset is incomplete")
    for definition in definitions:
        native = json.loads(definition.read_text())
        if native["revision"] != REVISION or native["source_sha256"] != provenance["source_sha256"]:
            parser.error("ALE task provenance changed")
        select_image(native, mapping)
    cmd = command(args)
    if args.dry_run:
        # Native CLI arguments can contain credentials. Do not print them.
        counts = {os_type: sum(json.loads(path.read_text())["os"] == os_type for path in definitions)
                  for os_type in ("linux", "windows")}
        print(json.dumps({"benchmark": "ale-cpu", "tasks": len(definitions), "os": counts, "revision": REVISION}))
        return
    os.execvpe(cmd[0], cmd, os.environ)


if __name__ == "__main__":
    main()

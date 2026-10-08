# Agents' Last Exam → Harbor

This adapter runs the Linux and Windows CPU tasks from the [official ALE repository](https://github.com/rdi-berkeley/agents-last-exam/tree/d9abc0734b56ea34116c5bfcbdd0b808269ab9e2)
at `d9abc0734b56ea34116c5bfcbdd0b808269ab9e2`: **205 variants from 151 task
implementations (134 Linux, 71 Windows variants)**. Both licensed and unlicensed
CPU snapshots are included. GPU snapshots are excluded before importing task
modules. Native task prompts, setup and graders remain unchanged. Generated
tasks stay outside this repository.

Harbor owns concurrency, trials, timeouts, retries, resume and result reporting.
`ALEEnvironment` provisions a fresh sandbox per trial: the existing SBX (qz) sandbox
provider by default, with Docker fallback for Ubuntu and a KubeVirt PVC clone for Windows. ALE's `TaskDriver`
sets up and grades the same guest that the Harbor agent uses. `ALEVerifier`
stages references only after agent execution, preserves zero, fractional and
negative scores, and saves the native result. Missing scores and grader failures
are errors. Generated shell/batch verifiers fail if the custom verifier is omitted.

## Prepare

Run repository setup for the pinned Harbor runner. ALE dependencies live in a
separate Python environment so they cannot change Harbor's pins:

```bash
./scripts/setup.sh
./Tasks/AgentsLastExam/setup.sh \
  --source "$HOME/.cache/agent-fleet/ale/source" \
  --env-dir "$HOME/.cache/agent-fleet/ale/native-env"
PYTHONPATH=Tasks/AgentsLastExam PYTHONDONTWRITEBYTECODE=1 \
  "$HOME/.cache/agent-fleet/ale/native-env/bin/python" -m ale_adapter.adapter \
  --source "$HOME/.cache/agent-fleet/ale/source" \
  --output-dir "$HOME/.cache/agent-fleet/ale/tasks"
```

Setup installs upstream framework and evaluation dependencies, including large
packages such as PyTorch with CPU host wheels. The source revision and native
CUA dependency are pinned; other dependencies follow upstream ranges. Conversion
and launch reject different revisions or changed native code. Regenerate into a
new output directory; old Windows-only datasets must be converted again.
Startup never installs host dependencies.

## Guest images and task data

For Linux, use a prepared ALE Ubuntu container image with native task software,
input data and encrypted references. The upstream image is
`agentslastexam/ale-ubuntu22-docker:latest`, exported from the native Ubuntu
image with the same `/media/user/data/agenthle` and `/opt/ale-run/.venv` paths.
Supply an immutable prepared tag/digest for repeatable runs.

The default `--linux-backend auto` prefers the repository's existing
[SBX/qz provider](../../Agents/utils/common/Harbor/QZ_SANDBOX_README.md).
Configure `SBX_API_KEY` (or `QZ_SANDBOX_API_KEY`) and a prepared ALE template,
using `sbx_template` in the image map or `QZ_SANDBOX_TEMPLATE` /
`QZ_SANDBOX_TEMPLATE_MAP`. Templates must contain the native task software/data
and a running CUA server on port 5000. A profile may supply `startup_command`
to start prepared guest services. Template CPU/RAM must satisfy task requirements;
SBX uses its registered compute spec and cannot enforce per-task resource limits.

If SBX is unconfigured or sandbox provisioning fails, auto mode cleans up the
SBX attempt and uses Harbor's existing Docker environment. `--linux-backend sbx`
requires SBX and never falls back; `--linux-backend docker` forces Docker. Once
native setup starts, setup/agent/grader failures remain trial errors and never
trigger backend switching. Provisioning cancellation also never triggers fallback.

Docker requires the usual Docker/Compose host setup. It boots the prepared
container with ALE's `/dockerstartup/entrypoint.sh`, preserving its desktop and
CUA services. There is no QEMU, qcow2 disk, or `/dev/kvm` requirement. CPU/memory
limits follow the Harbor task configuration. Native setup/grading reach CUA
through a per-trial loopback HTTP proxy using the backend's existing command/file
APIs; no guest port needs to be exposed externally.

All Linux tasks remain included, including nested Docker and Apptainer/Singularity
tasks. Prepare an image/template with those runtimes and the required permissions.
For a Docker host that supports them, set `docker.privileged: true` and
`docker.enable_dind: true` to start ALE's baked inner Docker daemon. An image
containing the required nested workloads/GUI bundles is still necessary. The
adapter never skips tasks because their runtime is missing; native failures are
reported as trial errors.

For Windows, import the official ALE CPU images as golden PVCs following the
[Windows backend guide](../../Agents/utils/common/Harbor/KUBEVIRT_WINDOWS_README.md).
Preserve `E:\agenthle`, task applications/licenses, Python and CUA startup.

Create an operator-owned image map, for example `/data/ale-images.json`:

```json
{
  "cpu-free-ubuntu": {
    "image_family": "ale-ubuntu22",
    "sbx_template": "ale_ubuntu22_prepared",
    "docker_image": "your-registry/ale-ubuntu22:prepared",
    "docker": {"privileged": true, "enable_dind": true}
  },
  "cpu-free": {"pvc": "ale-cpu-free", "image_family": "ale-win10"},
  "cpu-license": {"pvc": "ale-cpu-license", "image_family": "ale-win10"}
}
```

Each snapshot must match the native task's software and licensing requirements.
CPU, memory, task timeout and Windows desktop resolution follow native task
metadata. GPU tasks and GPU resource overrides are rejected.

Golden images must contain encrypted `reference.7z` archives only, with no
plaintext references for **any** variant. Keep judge credentials on the host.
Default `baked_in_sandbox` staging uses native encrypted-reference handling;
set `ALE_REFERENCE_ARCHIVE_PASSWORD` on the host for grading. Native `gs://`,
`s3://` and `oss://` task staging are supported via `--task-data-source`, with
their native guest tools/credentials prepared beforehand. Inputs/software are
staged before setup; references are staged only during verification. Host
`local:` and the unimplemented `hf://` task-data backend are rejected.
`AGENTHLE_CREDENTIALS_DIR` and `AGENTHLE_EVAL_CREDENTIALS_DIR` follow native ALE
contracts. Keep secrets outside the image map and generated dataset.

## Run

The default `Agents.AgentsLastExam.agent:ALECommandAgent` uses an image-provided
entrypoint on each OS. Both entrypoints read UTF-8 `HARBOR_INSTRUCTION_FILE` and
select `HARBOR_MODEL`. Provide CLI/GUI tools suitable for the tasks. The Windows
side reuses [WindowsCommandAgent and its optional preparation manifest](../../Agents/utils/common/Harbor/KUBEVIRT_WINDOWS_README.md#harbor-and-agent-contracts).
Linux entrypoints run in bash and write logs under `/logs/agent`; Windows logs
use `C:/logs/agent`.

```bash
export SBX_API_KEY='sbx_your-private-key'
export HARBOR_ALE_LINUX_AGENT_COMMAND='/opt/agent/run-agent.sh'
export HARBOR_KUBEVIRT_IMAGE=ale-cpu-free
export HARBOR_WINDOWS_AGENT_COMMAND='C:\Agent\run-agent.cmd'
export ALE_REFERENCE_ARCHIVE_PASSWORD='your-private-reference-password'
./Tasks/AgentsLastExam/run.sh \
  --dataset "$HOME/.cache/agent-fleet/ale/tasks" \
  --source "$HOME/.cache/agent-fleet/ale/source" \
  --native-python "$HOME/.cache/agent-fleet/ale/native-env/bin/python" \
  --image-map /data/ale-images.json --dry-run
# Remove --dry-run to execute; forward ordinary Harbor options after --:
./Tasks/AgentsLastExam/run.sh \
  --dataset "$HOME/.cache/agent-fleet/ale/tasks" \
  --source "$HOME/.cache/agent-fleet/ale/source" \
  --native-python "$HOME/.cache/agent-fleet/ale/native-env/bin/python" \
  --image-map /data/ale-images.json -- \
  --model your-model --n-concurrent 2 --jobs-dir ./runs --job-name ale-cpu
```

Use `--agent module:Class` before `--` for a custom Harbor agent. Mixed runs need
an agent supporting both OSes; Linux-only agents can run with Windows tasks
filtered out. Configure kubeconfig, namespace, guest ports, nodes and clone
storage through shared `HARBOR_KUBEVIRT_*` settings. Each Windows trial replaces
the initial preflight image with its mapped PVC. Linux trials do not require
cluster settings. Runtime overrides, including empty values, follow the shared
configuration loader. `OPIK_URL` selects the prepared `opik harbor` runner;
empty selects ordinary Harbor.

Harbor's `--include-task-name` / `--exclude-task-name` select subsets. Names are
`<domain>--<task>--v<variant-index>`; full CPU runs omit filters. Dry-run validates
all image mappings and provenance, prints counts by OS, and starts no guests.
Forwarded CLI options can contain credentials and are never printed.

Results use normal Harbor job/trial artifacts plus `verifier/native-result.json`.
Both OSes write `ale-setup.log` and `ale-evaluate.log`; `ale-linux.json` records
the selected Linux backend. Resume with native `harbor jobs resume
--job-path ./runs/ale-cpu` and the same configuration and
`PYTHONPATH=.:Tasks/AgentsLastExam:Agents/utils/common/Harbor`.
Cancellation stops native phases before guest cleanup. Hard termination may
leave resources: inspect `kubevirt.json` for Windows and `ale-linux.json` for
Linux. Inspect Docker's Harbor project or the SBX sandbox using its backend logs.

## Checks

```bash
PYTHONPATH=.:Tasks/AgentsLastExam:Agents/utils/common/Harbor \
  python3 -m unittest discover -s Tasks/AgentsLastExam/tests -v
# Also exercise native ALE setup/grading through real Harbor trials on both OSes:
ALE_TEST_SOURCE=/path/to/pinned/ale ALE_TEST_PYTHON=/path/to/native-env/bin/python \
  PYTHONPATH=.:Tasks/AgentsLastExam:Agents/utils/common/Harbor \
  python3 -m unittest discover -s Tasks/AgentsLastExam/tests -v
```

Portable and loopback tests do not establish live benchmark parity. A complete
run needs a prepared ALE SBX template or Docker image, Windows CPU/licensed images, native task
data, judge credentials and agent entrypoints. These are operator-provided assets.

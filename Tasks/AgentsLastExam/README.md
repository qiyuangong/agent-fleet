# Agents' Last Exam Windows → Harbor

This adapter runs the Windows tasks from the [official ALE repository](https://github.com/rdi-berkeley/agents-last-exam/tree/d9abc0734b56ea34116c5bfcbdd0b808269ab9e2)
at `d9abc0734b56ea34116c5bfcbdd0b808269ab9e2`. It converts all 231 variants
from 56 Windows task implementations. The 109 Linux task implementations are
excluded using ALE's native snapshot/image registry. No task prompts or graders
are rewritten. Generated tasks stay outside this repository.

Harbor owns concurrency, trials, timeouts, retries, resume, and result reporting.
`ALEEnvironment` clones a KubeVirt golden PVC per trial, runs ALE's native
`TaskDriver.setup()`, and exposes the same VM to a Windows Harbor agent.
`ALEVerifier` stages references and calls `TaskDriver.evaluate()` on that VM.
It preserves zero, fractional and negative scores, keeps native score details,
and treats grader failures/missing scores as errors. The fallback `test.bat`
fails when the required custom verifier is omitted.

## Prepare

Run the normal repository setup for the pinned Harbor runner. ALE's Python
dependencies are installed separately so they cannot change Harbor's pins:

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

Setup fetches the pinned revision and installs its framework and task evaluation
requirements. These include large packages such as PyTorch; host evaluation
uses the CPU wheel. The source revision and native CUA dependency are pinned,
while ALE's upstream requirement ranges determine other host dependencies.
Conversion and launch reject a different revision or modified native code.
Use a new output directory to regenerate tasks. Startup never installs packages.

## Windows images and data

Import the official ALE Windows images as golden PVCs following the
[Windows backend guide](../../Agents/utils/common/Harbor/KUBEVIRT_WINDOWS_README.md).
Each must retain the native `E:\agenthle` paths, installed task software and
licenses, Python, and the CUA server. Only encrypted `reference.7z` archives
may be present in a golden image; plaintext answers must be absent for **all**
variants. Store evaluator credentials on the host.

Create an operator-owned image map, for example `/data/ale-images.json`:

```json
{
  "cpu-free": {"pvc": "ale-cpu-free", "image_family": "ale-win10"},
  "cpu-license": {"pvc": "ale-cpu-license", "image_family": "ale-win10"},
  "gpu-free": {
    "pvc": "ale-gpu-free", "image_family": "ale-win10",
    "gpu_device": "nvidia.com/your-permitted-gpu"
  },
  "gpu-license": {
    "pvc": "ale-gpu-license", "image_family": "ale-win10",
    "gpu_device": "nvidia.com/your-permitted-gpu"
  }
}
```

All four categories must match the native task's software and licensing needs.
GPU resources must be permitted by the cluster and backed by a compatible GPU
and guest driver; see [KubeVirt device assignment](https://kubevirt.io/user-guide/compute/host-devices/).
The adapter adds the mapped resource to the VM's `devices.gpus`. CPU and memory
come from ALE task cards; GPU counts and desktop resolutions follow its native
profiles. An absent GPU mapping fails before launch.

The default `baked_in_sandbox` staging uses ALE's native encrypted-reference
backend. Set `ALE_REFERENCE_ARCHIVE_PASSWORD` on the host for grading.
Native `gs://`, `s3://`, and `oss://` staging are also supported through
`--task-data-source`; prepare their guest tools and credentials as required by
ALE. Input/software are staged before setup; reference data becomes available
only during verification. Host `local:` and ALE's unimplemented `hf://` backend
are rejected. Agent credentials use `AGENTHLE_CREDENTIALS_DIR`; evaluator
credentials use `AGENTHLE_EVAL_CREDENTIALS_DIR`, following ALE's native contracts.
Do not put these secrets in the image map or generated dataset.

## Run

Provision a Windows agent entrypoint using the existing
[WindowsCommandAgent contract](../../Agents/utils/common/Harbor/KUBEVIRT_WINDOWS_README.md#harbor-and-agent-contracts).
It reads `HARBOR_INSTRUCTION_FILE` and selects `HARBOR_MODEL`. A CLI or GUI
agent must supply its own tools suitable for the selected ALE tasks.
Alternatively pass a Windows-compatible Harbor agent using `--agent module:Class`
before `--`. This integration reuses the existing command agent and preparation
manifest; it does not install Linux agents in Windows.

```bash
export HARBOR_KUBEVIRT_IMAGE=ale-cpu-free
export HARBOR_WINDOWS_AGENT_COMMAND='C:\Agent\run-agent.cmd'
export ALE_REFERENCE_ARCHIVE_PASSWORD='your-private-reference-password'
./Tasks/AgentsLastExam/run.sh \
  --dataset "$HOME/.cache/agent-fleet/ale/tasks" \
  --source "$HOME/.cache/agent-fleet/ale/source" \
  --native-python "$HOME/.cache/agent-fleet/ale/native-env/bin/python" \
  --image-map /data/ale-images.json --dry-run
# Remove --dry-run to execute. Forward ordinary Harbor options after --:
./Tasks/AgentsLastExam/run.sh \
  --dataset "$HOME/.cache/agent-fleet/ale/tasks" \
  --source "$HOME/.cache/agent-fleet/ale/source" \
  --native-python "$HOME/.cache/agent-fleet/ale/native-env/bin/python" \
  --image-map /data/ale-images.json -- \
  --model your-model --n-concurrent 2 --jobs-dir ./runs --job-name ale-windows
```

Kubeconfig, namespace, guest ports, node selection and clone storage settings
are shared `HARBOR_KUBEVIRT_*` settings. `HARBOR_KUBEVIRT_IMAGE` supplies the
backend's initial preflight image; each trial replaces it with its mapped PVC
without changing another trial's settings. Runtime environment overrides,
including empty values, follow the normal configuration loader. `OPIK_URL`
selects the prepared `opik harbor` runner; empty selects ordinary Harbor.

Use Harbor's `--include-task-name` / `--exclude-task-name` for subsets. Names
are `<domain>--<task>--v<variant-index>`; full runs omit these filters.
Native Harbor options can contain credentials, so dry-run prints only task
count and provenance and does not access the cluster or start an agent.

Results remain native Harbor job/trial artifacts, with additional host-side
`ale-setup.log`, `ale-evaluate.log` and `verifier/native-result.json`. Run native
`harbor jobs resume --job-path ./runs/ale-windows` with the same configuration and
`PYTHONPATH=Tasks/AgentsLastExam:Agents/utils/common/Harbor` to resume.
Cancelled native phases are stopped before VM cleanup. Hard termination may
leave resources requiring inspection using the recorded `kubevirt.json`.

## Checks

```bash
PYTHONPATH=Tasks/AgentsLastExam:Agents/utils/common/Harbor \
  python3 -m unittest discover -s Tasks/AgentsLastExam/tests -v
# Also exercises the pinned native driver against a loopback CUA server:
ALE_TEST_SOURCE=/path/to/pinned/ale ALE_TEST_PYTHON=/path/to/native-env/bin/python \
  PYTHONPATH=Tasks/AgentsLastExam:Agents/utils/common/Harbor \
  python3 -m unittest discover -s Tasks/AgentsLastExam/tests -v
```

Portable and loopback tests do not establish live Windows benchmark parity.
A complete run additionally needs prepared CPU/GPU/licensed images, native task
data, judge credentials and Windows agents; these are operator-provided assets.

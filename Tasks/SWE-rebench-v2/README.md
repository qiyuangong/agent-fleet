# SWE-Rebench-V2

Harbor support for SWE-Rebench-V2 uses the published Harbor Hub dataset.

Default source:

- Harbor Hub: https://hub.harborframework.com/datasets/openthoughts/tasktrove-swe-rebench-v2-patched-oracle

The default is the oracle subset. The underlying Harbor CLI invocation uses
`--dataset openthoughts/tasktrove-swe-rebench-v2-patched-oracle`.

## Unified Entry

Run through the normal Harbor entrypoint in non-interactive mode:

```bash
# Change to other dataset if necessary
DATASET_NAME=openthoughts/tasktrove-swe-rebench-v2-patched-oracle \
bash Agents/utils/common/Harbor/start.sh bash Agents/utils/common/Harbor/harboropik.sh
```

For a non-interactive dry-run of the same entrypoint:

```bash
# Change to other dataset if necessary
DATASET_NAME=openthoughts/tasktrove-swe-rebench-v2-patched-oracle \
OUTPUT_ROOT=/tmp/swerebenchv2-runs \
TB_DRY_RUN=1 \
HARBOR_RUNNER_PREPARE=0 \
bash Agents/utils/common/Harbor/start.sh bash Agents/utils/common/Harbor/harboropik.sh
```

The bare zellij entrypoint (`bash Agents/utils/common/Harbor/start.sh`) is not
supported for registry-backed datasets yet because it requires a materialized
`TASK_FILE`.

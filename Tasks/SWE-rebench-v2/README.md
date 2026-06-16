# SWE-Rebench-V2

Harbor support for SWE-Rebench-V2 uses the published Harbor Hub dataset.

Default source:

- Harbor Hub: https://hub.harborframework.com/datasets/openthoughts/tasktrove-swe-rebench-v2-patched-oracle

The default is the oracle subset. The underlying Harbor CLI invocation uses
`--dataset openthoughts/tasktrove-swe-rebench-v2-patched-oracle`.

## Unified Entry

Run through the normal Harbor zellij entrypoint:

```bash
DATASET_NAME=openthoughts/tasktrove-swe-rebench-v2-patched-oracle \
bash Agents/utils/common/Harbor/start.sh --detach
```

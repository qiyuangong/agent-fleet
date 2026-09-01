# DeepSearchQA

Agent Fleet runs the published [Harbor Hub dataset](https://hub.harborframework.com/datasets/kgmon/deepsearchqa) without vendoring its 900 tasks. `DATASET_NAME=deepsearchqa` resolves to `kgmon/deepsearchqa`; a versioned registry ID such as `kgmon/deepsearchqa@<version>` also works directly.

DeepSearchQA tasks require internet access. For Claude Code runs, the alias leaves `WebSearch` and `WebFetch` available while continuing to disable interactive and remote-trigger tools. An explicit `HARBOR_DISALLOWED_TOOLS` value always takes precedence.

## Verifier credential

The dataset verifier uses Gemini 2.5 Flash by default. Put one judge credential in the git-ignored `config.local.env`:

```bash
GEMINI_API_KEY=replace-with-your-key
# Alternatively: GOOGLE_API_KEY=replace-with-your-key
```

The key is consumed by the verifier contract, not passed to the evaluated agent. Live runs fail before setup if neither variable is available. To use a different judge, set `DEEPSEARCHQA_GRADER_MODEL`; results from a different judge may not be directly comparable with the published benchmark.

## Run

Start with one task because both web research and judge calls can incur cost:

```bash
DATASET_NAME=deepsearchqa \
HARBOR_LIMIT=1 \
HARBOR_N_CONCURRENT=1 \
bash Agents/utils/common/Harbor/start.sh --detach
```

For a full run, remove `HARBOR_LIMIT` and set the desired concurrency:

```bash
DATASET_NAME=deepsearchqa \
HARBOR_N_CONCURRENT=10 \
bash Agents/utils/common/Harbor/start.sh --detach
```

The native registry summary reports `mean_reward` from DeepSearchQA's primary `reward` metric and preserves the complete Harbor statistics in `OUTPUT_PATH/summary.txt`.

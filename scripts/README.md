# scripts/ — Setup & Benchmark Entry Points

| 脚本 | 用途 |
| --- | --- |
| `setup.sh` | 一次性环境初始化:装 Node + Claude Code,写配置,装 skills |
| `run_fleet.sh` | 跑 benchmark:加载配置 → 创建 tmux → 调用 claude agent |

## Quick Start

```bash
# 1. 一次性环境初始化(交互式输入 BASE_URL / AUTH_TOKEN / MODEL)
./scripts/setup.sh
source ~/.bashrc

# 2. 跑 benchmark
./scripts/run_fleet.sh harbor    # Harbor: 3 SETA + 3 Terminal-Bench-2
./scripts/run_fleet.sh openclaw  # OpenClaw: 10 fleet + 3 PinchBench + 3 ClawBio
```

---

## setup.sh

**用途**: 一次性、幂等的环境初始化。完成以下工作:

1. 收集 model endpoint 配置(交互 prompt 或环境变量)
2. 检查基础依赖(git / curl / docker / python3)
3. 通过 nvm 安装 Node.js(如未装或 < 18)
4. 安装 Claude Code(固定 2.1.90)
5. 写环境变量到 `~/.bashrc`
6. Clone 仓库 + 安装 skills 插件
7. 写 `config.local.env`
8. 检查 Docker 权限

**前提**: 手动装好 `git` / `curl` / `docker` / `python3`。Node 和 Claude Code 不需要预装。

**用法**:

```bash
./scripts/setup.sh
# 交互式输入 BASE_URL / AUTH_TOKEN / MODEL
```

或通过环境变量预填(适合自动化):

```bash
BASE_URL=https://your-gateway.example.com \
AUTH_TOKEN=your-token \
MODEL=glm-5.1-fp8 \
./scripts/setup.sh
```

<details>
<summary>可覆盖的变量</summary>

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `NODE_VERSION` | `24` | Node.js 大版本 |
| `CLAUDE_CODE_VERSION` | `2.1.90` | Claude Code 版本 |
| `REPO_URL` | `https://github.com/sii-system/sii-agent-fleet.git` | clone 用的 URL |
| `REPO_DIR` | `$HOME/sii-agent-fleet` | clone 目标路径 |
| `CLAUDE_TGZ_SOURCE` | (空) | 本地 Claude Code tgz,容器内离线安装用 |
| `CLAUDE_WHEEL_DIR_SOURCE` | (空) | 本地 Python wheel 目录,需含 `npm-cache/` |

`API_KEY` 是 `AUTH_TOKEN` 的别名,两者设一个即可。

</details>

<details>
<summary>幂等性说明</summary>

- `~/.bashrc`: 用标记块 `# >>> sii-agent-fleet env >>>` 包裹,每次替换整个块
- `~/.claude/settings.json`: 合并 managed keys,保留用户自定义
- `config.local.env`: 只更新 managed keys,保留注释和其他 key
- 每次修改前会备份(`*.bak.sii-agent-fleet`)

安全可重跑。

</details>

**运行后**: `source ~/.bashrc` 让新环境变量生效,然后就可以跑 `run_fleet.sh` 了。

---

## run_fleet.sh

**用途**: 加载配置 → 固定 Claude 版本 → 创建 tmux → 调用 claude agent 跑 e2e benchmark。

**前提**: 已运行 `setup.sh`(或手动完成等价配置)。

**用法**:

```bash
./scripts/run_fleet.sh harbor    # Harbor smoke test
./scripts/run_fleet.sh openclaw  # OpenClaw fleet smoke test
```

**一次性环境覆盖**(临时换模型/endpoint,不改 config 文件):

```bash
MODEL=gpt-4o ./scripts/run_fleet.sh harbor
BASE_URL=https://other-gateway.example.com ./scripts/run_fleet.sh openclaw
```

<details>
<summary>运行流程</summary>

1. 解析参数,选择 prompt 文件(`skills/e2e-{harbor,openclaw}-benchmark.txt`)
2. 加载 `config.env` → `config.local.env` → 还原 caller env(命令行覆盖优先)
3. 从 `BASE_URL` / `API_KEY` 派生 `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN`
4. 固定 Claude Code 版本(禁用自动更新)
5. 配置本地 Claude 安装包(如已设置)
6. 创建 tmux session(`harbor-bench` 或 `openclaw-bench`)
7. 在 tmux 内执行 `claude --plugin-dir <skills> --permission-mode bypassPermissions -p "<prompt>"`
8. 输出通过 `tee` 写入 `scripts/logs/<bench>_<timestamp>.log`

</details>

<details>
<summary>tmux 操作</summary>

| 操作 | 命令 |
| --- | --- |
| 重新连接 | `tmux attach -t harbor-bench` / `tmux attach -t openclaw-bench` |
| 分离 | `Ctrl+B` 然后按 `D` |
| 滚动 | 鼠标滚轮 |
| 杀掉 session | `tmux kill-session -t harbor-bench` |

session 已存在时脚本会拒绝重复创建,提示 attach 或 kill。

</details>

<details>
<summary>日志</summary>

```
scripts/logs/<bench>_<YYYYMMDD>_<HHMMSS>.log
```

> **已知问题**: `claude | tee` 管道缓冲可能导致 log 文件 0 字节。
> 如遇此情况,查看 tmux 终端输出或 benchmark 结果目录
> (`~/harbor-runs/` 或 `.smoke-openclaw-*/`)。

</details>

---

## 建议 & 提醒

- **先 setup.sh 再 run_fleet.sh**: setup 装环境,run_fleet 跑 benchmark。跳过 setup 大概率失败。
- **先 harbor 后 openclaw**: harbor 更轻量(单容器),openclaw 要 10 个容器。
- **换模型先验证 endpoint**: 改 `MODEL` 后先 `curl` 验证 gateway 能响应,再跑 benchmark。
- **内网环境配本地 Claude 包**: 不配 `CLAUDE_TGZ_SOURCE` 的话容器内会访问 `downloads.claude.ai`,内网大概率超时。setup 时传入:
  ```bash
  CLAUDE_TGZ_SOURCE=/path/to/claude-code.tgz \
  CLAUDE_WHEEL_DIR_SOURCE=/path/to/wheels/ \
  ./scripts/setup.sh
  ```
- **ClawBio 已知 bug**: `Tasks/clawBio/scripts/run-benchmark.py` 没传 `OPENCLAW_GATEWAY_TOKEN`,ClawBio 可能失败。PinchBench 不受影响。
- **清理旧 run**: openclaw 会留 `.smoke-openclaw-*` 目录和容器,定期清理:
  ```bash
  docker rm -f $(docker ps -aq --filter "name=ocsmoke-" --filter "name=ocpb-")
  rm -rf .smoke-openclaw-*
  ```
- **不要 commit `config.local.env`**: 里面有密钥。
- **`bypassPermissions` 模式**: agent 自动执行所有工具调用,只在受控环境使用。
- **SSH 断开**: run_fleet.sh 必须用 tmux 模式(默认),否则断开即终止。

# Symphony

[English](README.md) | [中文](README.zh-CN.md)

让 coding agent 从真实 tracker issue 出发，交付经过验证的 pull request。

Symphony 把 issue 驱动的工程工作变成一个可重复运行的本地运行时：它从 GitHub、Linear 或 GitLab
领取任务，为每个任务创建隔离 workspace，在其中启动 Codex app-server，执行仓库自己的 workflow，
并在验证通过后交回分支、PR 或 tracker 状态更新。

| 接入任务 | 隔离执行 | 验证交付 |
| --- | --- | --- |
| 轮询 GitHub issue、Linear issue 或 GitLab work item。 | 每个任务一个 workspace，在里面运行 Codex。 | 按仓库定义的检查命令验证后再 PR、评论或改状态。 |

<p align="center">
  <a href="#github-issues-到-pr"><strong>GitHub Issues -&gt; PR</strong></a>
  ·
  <a href="#linear-issues-到-pr"><strong>Linear Issues -&gt; PR</strong></a>
  ·
  <a href="#repo-first-concierge">用 skill 安装</a>
  ·
  <a href="#常用命令">本地运行</a>
</p>

这个仓库最初 fork 自
[`openai/symphony`](https://github.com/openai/symphony)，但现在已经加入了较大改造，重点放在
repo-first 接入、release 分发，以及 GitHub 场景下的一句话 onboarding。它不是 OpenAI 官方项
目，也不代表 OpenAI 的官方立场或背书。

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](.github/media/symphony-demo.mp4)

> [!WARNING]
> Symphony 目前仍然属于工程预览版本，更适合在可信仓库和清晰边界下试用。

## 选择接入路径

[English](README.md#choose-a-setup-path) | [中文](#选择接入路径)

真实项目最快路径是 repo-first 的 `symphony-concierge` skill。在目标仓库根目录里运行后，它会生成
安装 manifest、写入 `WORKFLOW.md`、启动 Symphony，并验证本地 dashboard/API 是否可访问。

| 任务来源 | tracker | 常见结果 |
| --- | --- | --- |
| GitHub Issues | `github` | Symphony 改 label、评论 issue、push 分支、创建 PR。 |
| Linear | `linear` | Symphony 改 Linear state、写 Linear comment、push GitHub 分支、创建 PR。 |
| GitLab | `gitlab` | runtime 支持；concierge 路径目前不如 GitHub/Linear 完整。 |

### GitHub Issues 到 PR

在目标仓库里对 Codex 说：

```text
使用 symphony-concierge 接入当前仓库，tracker 用 GitHub，验证命令用 npm run check。
```

默认 GitHub 状态是 labels：

| Label | 含义 |
| --- | --- |
| `Todo` | 等待 Symphony 领取 |
| `In Progress` | 已领取并处理中 |
| `Done` | 已验证并完成 handoff |

新 GitHub issue 必须有 `Todo` 之类 active-state label。只有 open、但没有 active label 的 issue，
默认不会被 Symphony 拉取。

### Linear Issues 到 PR

在目标仓库里对 Codex 说：

```text
使用 symphony-concierge 接入当前仓库，tracker 用 Linear，使用我的 Linear project slug，验证命令用 npm run check。
```

默认 Linear 状态是 issue workflow states：

| State | 含义 |
| --- | --- |
| `Todo` | 等待 Symphony 领取 |
| `In Progress` | 已领取并处理中 |
| `Done` | 已验证并完成 handoff |
| `Canceled` / `Duplicate` | 终态，Symphony 应忽略 |

Linear 管任务来源和任务状态。如果代码 forge 是 GitHub，代码 review 和 merge 仍然由 GitHub 控制，
所以 Linear-backed run 通常会在 Linear comment 里附上 GitHub PR。

## 运行方式

```text
Tracker issue -> isolated workspace -> Codex app-server -> validation -> PR / tracker update
```

1. Symphony 轮询 tracker，找出 active work。
2. 为任务创建或复用隔离 workspace。
3. 在 workspace 里启动 `codex app-server`。
4. 根据 `WORKFLOW.md` 和 issue 内容生成 prompt。
5. 持续监控事件、console、验证结果和 tracker 状态，直到完成或阻塞。

## Repo-First Concierge

### 前置条件

接入真实项目前，先确认：

- 目标项目是 Git 仓库
- `origin` 指向普通 GitHub 仓库
- 已安装并登录 `gh`
- 当你希望 Symphony agent 能评论 issue、push 分支、创建 PR 时，环境里有 `GITHUB_TOKEN`
- 当 tracker 使用 Linear 时，环境里有 `LINEAR_API_KEY`
- Codex 可以通过 `codex app-server` 启动
- 项目有明确的验证命令，例如 `npm run check`、`npm test` 或 `make test`

GitHub token 至少要能读写 issue、push branch、创建 pull request。重要仓库建议保留 branch
protection 和 required CI checks，不要让自动化直接绕过主分支保护。

Linear API key 至少要能读取目标 project 里的 issue，并能写 comment 或修改 issue 状态。Symphony
通常仍然把 GitHub 当作代码 forge 来 push 分支和创建 PR，所以 Linear tracker 项目一般同时需要
`LINEAR_API_KEY` 和 GitHub push/PR 凭据。

### 安装 skill

在目标仓库根目录里，对 Codex 说：

```text
从 https://github.com/tianheil3/symphony.git 安装 .codex/skills/symphony-concierge，然后用它帮当前仓库接入 Symphony。
```

concierge 流程会：

1. 对当前仓库做一次扫描
2. 一次性询问关键配置问题
3. 写入 `.symphony/install/request.json`
4. 执行 `symphony install --manifest .symphony/install/request.json`
5. 当 tracker 是 GitHub 时创建或校验 workflow-state labels
6. 在一个空闲本地端口启动 Symphony
7. 验证进程存活和 API health 都通过后再报告成功

如果本机还没有 `symphony`，skill 自带的 helper 会尝试从本仓库的 GitHub Releases 下载对应平台的
安装包。

### Skill 会问什么

skill 会一次性询问这些值：

- tracker provider：`github`、`linear` 或 `gitlab`
- tracker project slug：GitHub 场景下填写 `owner/repo`；Linear 场景下填写 Linear project slug
- workspace root：Symphony 为每个 issue 创建独立 workspace 的目录
- workspace bootstrap command：通常是 `git clone --depth 1 <origin-url> .`
- Codex command：通常是 `codex app-server`
- handoff 前验证命令：agent 声称完成前必须跑的命令

刚开始接入真实项目时，建议保守配置：

```yaml
agent:
  max_concurrent_agents: 1
  max_turns: 10
codex:
  command: codex app-server
```

先审过几个完整 PR、理解当前仓库的失败模式后，再考虑提高并发。

<details>
<summary>GitHub WORKFLOW.md 示例</summary>

GitHub Issues 作为 tracker 时，可以使用这种形状：

```yaml
---
tracker:
  kind: github
  api_key: $GITHUB_TOKEN
  project_slug: owner/repo
  active_states:
    - Todo
    - In Progress
  terminal_states:
    - Done
    - Closed
    - Canceled
workspace:
  root: ~/code/my-project-workspaces
hooks:
  after_create: |
    git clone --depth 1 https://github.com/owner/repo.git .
    npm install
agent:
  max_concurrent_agents: 1
  max_turns: 10
codex:
  command: codex app-server
---
只在 Symphony 创建的 issue workspace 里工作。
handoff 前运行 `npm run check`。
```

</details>

<details>
<summary>Linear WORKFLOW.md 示例</summary>

Linear 作为 tracker、GitHub 作为代码 forge 时，可以使用这种形状：

```yaml
---
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  project_slug: MYPROJECT
  active_states:
    - Todo
    - In Progress
  terminal_states:
    - Done
    - Canceled
workspace:
  root: ~/code/my-project-workspaces
hooks:
  after_create: |
    git clone --depth 1 https://github.com/owner/repo.git .
    npm install
agent:
  max_concurrent_agents: 1
  max_turns: 10
codex:
  command: codex app-server
---
你正在处理一个 Linear issue。
使用 `linear_graphql` 工具处理 Linear comment 和状态流转。
handoff 前运行 `npm run check`。
代码改动准备好后，创建 GitHub pull request 供 review。
```

</details>

## Workflow 规则

`WORKFLOW.md` 是保证运行可预测的核心契约。

| Tracker | Agent 应该使用 | Agent 应该避免 |
| --- | --- | --- |
| GitHub | `gh issue comment`、`gh api`、`gh issue edit`、branch/PR 命令 | `linear_graphql` 和 Linear-only closeout 工具 |
| Linear | 用 `linear_graphql` 读 issue、写 comment、更新 workpad、修改状态 | 用 GitHub issue label 命令管理 tracker 状态 |

无论 tracker 是什么，agent 都应该只在 Symphony 创建的 issue workspace 里工作，并且在 handoff 前运行
配置好的验证命令。

## 日常运行模型

真实项目里最安全的默认模式是“只自动开 PR”：Symphony 可以 push branch、创建 PR，但是否进入受保护
主分支，仍然由 CI、branch protection 和人类 review 决定。

| 步骤 | GitHub tracker | Linear tracker |
| --- | --- | --- |
| 1 | 创建或选择一个 GitHub issue。 | 创建或选择一个 Linear issue。 |
| 2 | 添加 `Todo` label。 | 移到 `Todo` 或其他 active state。 |
| 3 | 启动或保持 Symphony 运行。 | 启动或保持 Symphony 运行。 |
| 4 | Symphony 把 issue 移到 `In Progress`。 | Symphony 把 issue 移到 `In Progress`。 |
| 5 | 审查生成的分支和 PR。 | 审查生成的 GitHub 分支和 PR。 |
| 6 | 验证和 handoff 完成后移到 `Done`。 | 验证和 handoff 完成后移到 `Done`。 |

## 应该提交什么

目标仓库通常应该提交：

- `WORKFLOW.md`，因为它是这个仓库自己的执行契约
- 团队内部关于如何投喂 Symphony issue 的项目文档

目标仓库通常不应该提交本地运行状态：

- `.symphony/install/state.json`
- `.symphony/install/events.jsonl`
- `.symphony/install/launch.log`
- 每次运行创建的 workspace 目录

如果需要，给目标项目加对应 ignore 规则，避免本地 Symphony 状态进入普通代码 review。

## Operator Surfaces

Tracker-dispatched 本地运行会暴露：

- dashboard：查看 active agents、tokens、状态和事件摘要
- API：`/api/v1/state`
- 每个活跃 issue 一个稳定的本地 `tmux` session
- Web console：`/console/<issue_identifier>`
- 受控 operator 命令：`help`、`status`、`explain`、`continue`、`prompt <text>`、`cancel`

## 常用命令

接入完成后，在目标仓库里启动：

```sh
symphony --i-understand-that-this-will-be-running-without-the-usual-guardrails --port 49190 ./WORKFLOW.md
```

检查 API health：

```sh
curl -fsS http://127.0.0.1:49190/api/v1/state
```

打开 dashboard：

```text
http://127.0.0.1:49190/
```

列出待处理 GitHub issues：

```sh
gh issue list --repo owner/repo --label Todo --state open
```

Linear 的候选任务可以在 Linear project view 里按配置好的 active states 过滤，例如 `Todo` 和
`In Progress`。在 agent 运行过程中，Linear 的读取和写入应通过 Symphony Codex app-server session
暴露的 `linear_graphql` 工具完成。

## 安全检查清单

在高价值项目上使用前：

- 先从一个低风险 issue 开始
- 保持 `max_concurrent_agents: 1`
- PR 必须要求 CI
- 合并前必须有人 review
- 不要把 secrets 写进 issue body 或 workflow prompt
- 只在可信仓库和可信本地 workspace 中运行
- 前几个 PR 要仔细审查，再扩大使用范围

## 当前范围

当前这版主要覆盖：

- Elixir 参考实现
- Linear / GitLab / GitHub tracker 支持
- 面向普通 GitHub 仓库的 repo-first concierge v1
- `linux/x86_64` 与 `darwin/arm64` 的安装器 release 资产

当前仍然存在的边界：

- concierge v1 是故意收窄的，当前对 GitHub 以及 Linear-backed GitHub 仓库最完整
- 这还是原型系统，不是已经打磨完成的生产级控制平面

## Release 分发

安装器和 concierge bundle 的 release 由 `.github/workflows/release-escript.yml` 发布。

当前的发行物包括：

- `symphony-<version>-linux-x86_64.tar.gz`
- `symphony-<version>-darwin-arm64.tar.gz`
- `symphony-concierge-<version>.tar.gz`

最新 release：

- <https://github.com/tianheil3/symphony/releases/latest>

这些 release 资产是“一句话接入”成立的关键，因为它让 `symphony-concierge` 不必要求用户先手工在本
机编译 Symphony。

## 与上游 fork 的关系

这个仓库虽然起点是 `openai/symphony`，但现在已经不是简单镜像。

这个 fork 目前最明显的差异是：

- repo-first installer 和 manifest 流程
- `symphony-concierge` onboarding skill
- 针对 installer 和 concierge bundle 的 GitHub release 打包
- GitHub-backed tracker 接入路径
- 面向“把它接进我的仓库”的文档组织方式

如果你想先看上游规范本身，可以从这里开始：

- <https://github.com/openai/symphony/blob/main/SPEC.md>

## 文档入口

按用途看文档：

- [README.md](README.md)：英文项目入口
- [elixir/README.md](elixir/README.md)：运行时安装、配置与 workflow 说明
- [elixir/docs/installer.md](elixir/docs/installer.md)：installer manifest、session state 与
  concierge 交接契约

## 许可证

本项目使用 [Apache License 2.0](LICENSE)。

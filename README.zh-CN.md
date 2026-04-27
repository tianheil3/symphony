# Symphony

[English](README.md) | [中文](README.zh-CN.md)

Symphony 是一个面向 coding agent 的工作编排系统。它的目标不是让人类盯着每一次 agent
执行，而是把“任务从哪里来、如何执行、如何验证、如何落地”这些流程变成一个可重复运行的系统。

这个仓库最初 fork 自
[`openai/symphony`](https://github.com/openai/symphony)，但现在已经加入了较大改造，重点放在
repo-first 接入、release 分发，以及 GitHub 场景下的一句话 onboarding。它不是 OpenAI 官方项
目，也不代表 OpenAI 的官方立场或背书。

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](.github/media/symphony-demo.mp4)

> [!WARNING]
> Symphony 目前仍然属于工程预览版本，更适合在可信仓库和清晰边界下试用。

## 这是什么

Symphony 适合那些想把“管理工作”而不是“手动驾驶 agent”作为默认方式的团队或个人。

它提供的核心能力包括：

- 从 tracker 拉取任务
- 为每个任务创建隔离 workspace
- 在 workspace 中启动 Codex app-server
- 通过 `WORKFLOW.md` 约束执行流程
- 为每次运行提供验证和可观测性
- 提供一个 repo-first 的 concierge 接入路径，把现有仓库接进 Symphony

## 为什么要做它

今天很多 coding agent 工作流仍然要人类不断重复这些动作：

- 打开 issue
- 切到正确仓库
- 手动准备环境
- 把项目规则再说一遍
- 盯着 agent 执行
- 验证结果
- 安全落地改动

Symphony 的目标是把这些重复协调动作沉淀成运行时和工作流契约，让系统去重复，而不是人。

## 愿景

这个项目的目标不是“让 agent 跑一个 issue”这么窄。

更大的目标是把项目工作变成一种可操作的系统：

- 任务从真实 tracker 进入
- 执行发生在隔离环境里
- 每次运行都遵守仓库自己的 workflow
- 验证是系统的一部分，而不是事后补救
- 新仓库接入不再靠手工拼 prompt，而是变成稳定流程

## 系统架构

运行时主循环是比较直接的：

1. Symphony 轮询 tracker，找出可执行任务
2. 为每个任务创建或复用一个隔离 workspace
3. 在 workspace 中启动 Codex app-server
4. 根据 `WORKFLOW.md` 和 issue 内容生成执行 prompt
5. 持续监控执行状态、验证信号和 tracker 状态，直到完成或阻塞

系统的主要组成部分是：

- `tracker`：任务来源。目前 Elixir runtime 支持 `linear`、`gitlab`、`github`
- `workspace`：每个任务的独立 checkout 和 bootstrap 环境
- `codex runtime`：实际执行 agent 的引擎，通常是 `codex app-server`
- `workflow contract`：`WORKFLOW.md` 里的 YAML 配置和 Markdown prompt
- `observability`：本地 dashboard、API，以及共享 console 面，用来查看状态与健康情况

## Shared Console

本地 worker 的 tracker 任务现在会暴露一个共享 console：

- 每个活跃 issue 都会有一个稳定的本地 `tmux` session
- dashboard 里会出现 `Open Console`
- Web console 路径是 `/console/<issue_identifier>`
- operator 只能发送受控命令，不能原样把 stdin 透传给 agent：`help`、`status`、`explain`、`continue`、`prompt <text>`、`cancel`

## 在真实项目中使用 Symphony

[English](README.md#use-symphony-with-a-real-project) | [中文](#在真实项目中使用-symphony)

真实项目推荐走 repo-first 的 `symphony-concierge` skill。这个 skill 应该在目标仓库根目录里运行，
它会生成安装 manifest、写入 `WORKFLOW.md`、启动 Symphony，并在交还给你之前验证本地 dashboard/API
是否可访问。

### 前置条件

接入真实项目前，先确认：

- 目标项目是 Git 仓库
- `origin` 指向普通 GitHub 仓库
- 已安装并登录 `gh`
- 当你希望 Symphony agent 能评论 issue、push 分支、创建 PR 时，环境里有 `GITHUB_TOKEN`
- Codex 可以通过 `codex app-server` 启动
- 项目有明确的验证命令，例如 `npm run check`、`npm test` 或 `make test`

GitHub token 至少要能读写 issue、push branch、创建 pull request。重要仓库建议保留 branch
protection 和 required CI checks，不要让自动化直接绕过主分支保护。

### 安装并调用 skill

在目标仓库根目录里，对 Codex 说：

```text
从 https://github.com/tianheil3/symphony.git 安装 .codex/skills/symphony-concierge，然后用它帮当前仓库接入 Symphony。
```

如果 skill 已经安装好，可以直接说：

```text
使用 symphony-concierge 接入当前仓库，tracker 用 GitHub，验证命令用 npm run check。
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

### 配置时会问什么

skill 会一次性询问这些值：

- tracker provider：`github`、`linear` 或 `gitlab`；大多数真实 GitHub 项目使用 `github`
- tracker project slug：GitHub 场景下填写 `owner/repo`
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

### GitHub issue 工作流

GitHub tracker 场景下，Symphony 使用 workflow-state labels 作为任务状态来源：

- `Todo`：等待 Symphony 领取
- `In Progress`：Symphony 已领取并正在处理
- `Done`：实现和 handoff 已完成

GitHub 场景下，Symphony 默认不是只看 issue 是否 `open`，而是看 issue 是否带有这些 workflow-state
labels。也就是说，一个新建但没有 `Todo` 之类 active-state label 的 GitHub issue，默认不会被
Symphony 当成候选任务拉取。

生成出来的 `WORKFLOW.md` 应该显式要求 agent：

- 用 `gh issue comment` 维护持久 workpad comment
- 用 `gh api` 或 `gh issue edit` 修改 workflow-state labels
- 当 `tracker.kind=github` 时，不要调用 `linear_graphql` 或任何 Linear-only closeout 工具
- 只在 Symphony 创建的 issue workspace 里工作
- 创建 handoff 或 PR 前必须运行配置好的验证命令

### 日常运行模型

接入完成后，正常循环是：

1. 创建或选择一个 GitHub issue
2. 给它加 `Todo` label
3. 启动或保持 Symphony 运行
4. 打开 concierge 报告的 dashboard URL 观察状态
5. Symphony 会把 issue 移到 `In Progress`
6. 审查生成的分支和 PR
7. 依赖 CI 和人工 review 决定是否合并
8. 只有验证和 handoff 完成后，issue 才移动到 `Done`

真实项目里最安全的默认模式是“只自动开 PR”：Symphony 可以 push branch、创建 PR，但是否进入受保护
主分支，仍然由 CI、branch protection 和人类 review 决定。

### 应该提交到目标仓库的内容

目标仓库通常应该提交：

- `WORKFLOW.md`，因为它是这个仓库自己的执行契约
- 团队内部关于如何投喂 Symphony issue 的项目文档

目标仓库通常不应该提交本地运行状态：

- `.symphony/install/state.json`
- `.symphony/install/events.jsonl`
- `.symphony/install/launch.log`
- 每次运行创建的 workspace 目录

如果需要，给目标项目加对应 ignore 规则，避免本地 Symphony 状态进入普通代码 review。

### 常用命令

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

### 安全检查清单

在高价值项目上使用前：

- 先从一个低风险 issue 开始
- 保持 `max_concurrent_agents: 1`
- PR 必须要求 CI
- 合并前必须有人 review
- 不要把 secrets 写进 issue body 或 workflow prompt
- 只在可信仓库和可信本地 workspace 中运行
- 前几个 PR 要仔细审查，再扩大使用范围

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

## 当前范围

当前这版主要覆盖：

- Elixir 参考实现
- Linear / GitLab / GitHub tracker 支持
- 面向普通 GitHub 仓库的 repo-first concierge v1
- `linux/x86_64` 与 `darwin/arm64` 的安装器 release 资产

当前仍然存在的边界：

- concierge v1 是故意收窄的，主要服务 GitHub 托管仓库
- 这还是原型系统，不是已经打磨完成的生产级控制平面

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

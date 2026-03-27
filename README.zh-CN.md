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
- `observability`：本地 dashboard 和 API，用来查看状态与健康情况

## 最快使用方式

最快的路径是使用 repo-first 的 `symphony-concierge` skill。

在你的目标仓库里，直接对 Codex 说：

```text
从 https://github.com/tianheil3/symphony.git 安装 .codex/skills/symphony-concierge，然后用它帮当前仓库接入 Symphony。
```

这条 concierge 流程会自动：

1. 对当前仓库做一次扫描
2. 一次性询问关键配置问题
3. 写入 `.symphony/install/request.json`
4. 执行 `symphony install --manifest .symphony/install/request.json`
5. 在一个空闲本地端口启动 Symphony
6. 验证进程存活和 API health 都通过后再报告成功

如果你用的是 GitHub tracker，concierge 还必须校验或创建默认的 workflow-state labels：

- `Todo`
- `In Progress`
- `Done`

GitHub 场景下，Symphony 默认不是只看 issue 是否 `open`，而是看 issue 是否带有这些 workflow-state
labels。也就是说，一个新建但没有 `Todo` 之类 active-state label 的 GitHub issue，默认不会被
Symphony 当成候选任务拉取。

如果本机还没有 `symphony`，skill 自带的 helper 会尝试从本仓库的 GitHub Releases 下载对应平台的
安装包。

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

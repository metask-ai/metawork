# Changelog

本文记录 MetaWork 各版本显著的开发、架构、依赖与验证变更，不作为面向用户的发布说明。

格式遵循 [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)，版本号遵循 [Semantic Versioning](https://semver.org/spec/v2.0.0.html)，真源是 `app.zon`。当前能力边界与验证状态以 [docs/validation.md](docs/validation.md) 为准。

## [Unreleased]

## [0.1.5] - 2026-08-29

### Added

- 新增 Windows ARM64 签名打包流程；x64 与 ARM64 分别生成版本化安装器，并遵循相同的 Authenticode 验证规则。
- 新增原生单实例协调与受控启动转交，并补充进程级生命周期验证。
- 新增异步文件预览抽屉；Host 在读取前重新校验 Task、Run 与文件引用，并限制读取范围和响应大小。
- 新增 Agent 对话过程呈现，区分过程说明与最终回复，并展示统一的 Run 执行状态。

### Changed

- AgentCore 升级至 ABI v1 revision 14，并锁定 macOS arm64/x64、Windows x64/ARM64 四个目标的独立 bundle。
- Completion 脱离 AgentCore Runtime，改由 Agent 提供独立、一次性的非流式调用能力。
- 将原 Workbench composition owner 收口为 Product Control，并将 Workspace 与 Schedule 状态分别归入各自 Runtime。
- 收紧 Account execution authority，避免 Product Control 持有或推导不属于自身的执行配置事实。

### Fixed

- 修复 Task 终态事件尚未排空时提前发布结果，以及活跃 Run 阶段被错误视为终态的问题。
- 修复 Task 模型选择未精确绑定 Metask execution authority 的问题。
- 修复 Scheduled Task 将 execution credential 遗留在持久状态中的问题。
- 修复单实例 endpoint 安全、启动转交重试和失败结果不确定的问题。

## [0.1.4] - 2026-08-26

### Added

- 新增 macOS x64 发布目标；macOS 打包默认同时生成 arm64 与 x64 DMG，并保留已有架构产物。
- MCP server 启用状态进入产品投影，启动不再等待 server activation，并简化配置与恢复流程。

### Changed

- 将 Product Task、MCP 与 Skill 收口为各自的 live aggregate，关闭跨 owner 的内部状态与生命周期入口，并隔离 executor job 和 catalog refresh worker。
- AgentCore bundle 改为按目标平台选择 canonical bundle，开发与发布流程使用同一 target-specific 规则。

### Fixed

- 修复 Conversation 恢复错误绑定历史 execution generation 的问题；兼容当前 provider/model authority 时持久化推进 Task binding，并在首次发送前透明恢复。
- 修复 Task Session 所有权竞态与 recovery authority 失效处理。
- 修复 Skill 无效重调度，以及 MCP applying 状态和 mutation locking。
- 修复 Windows 主程序图标嵌入，以及 macOS flat icon 打包与 staged icon cache 刷新。

## [0.1.3] - 2026-08-24

### Added

- 新增 Agent Completion capability；Workbench 在首个 Run admission 时显示 provisional title，并在 Run 收口后通过独立 Completion 生成不超过 32 个 Unicode 字符的 Task 标题。

### Changed

- 统一 Agent provider identity，并将 Account provider probe 迁移到 Completion capability。
- 定义 Account transaction architecture，收口 transaction kernel 状态模型，并 hard cut model preference transaction 路径。

### Fixed

- 修复 MCP catalog freshness 生命周期，覆盖 refresh operation 串行化、deadline 保留、Workbench pending request 和 Conversation restore。
- 修复 Account identity 切换或退出被 live Task 阻止的问题；既有 Task 继续使用已取得的 ExecutionConfig 收口，不被中止或改写。
- 修复账号菜单退出必须先打开设置页，以及 signed-out identity 与菜单状态不清晰的问题。
- 修复 Account terminal transaction 在 preference recovery 与 catalog terminal handoff 后遗留 shadow、candidate 或 secret session 的问题。

## [0.1.2] - 2026-08-22

### Added

- 启用并重设计 MCP 管理页，覆盖 server 配置、授权、测试、启停、工具 allowlist 与恢复交互。
- 新增 Workbench-owned 持久化分层 Skill 启用策略，支持用户默认值、项目 override，并端到端接入 Workspace 与 Run admission。
- 新增 SDK-independent SQL foundation contract、直连 SQLite backend 及对应 migration、transaction 和 conformance tests。
- 建立统一的应用与托盘图标资产管线。
- 新增签名的 Windows x64 安装包，以及带 Applications 拖拽布局、签名和公证的 macOS DMG 发布流程。

### Changed

- AgentCore hard cut 到 ABI v1 revision 9 skill policy contract；Skill authority 改为不可变、事务化的 Run 输入，并停止注册 `AskUserQuestion`。
- MCP 配置现在可在不重启应用的情况下应用；管理页统一布局，并 hard cut 到当前 AgentCore HTTP response contract。
- Renderer conversation surfaces 迁移到统一 AI UI primitives，收口重复的消息、活动状态和交互实现。
- Account hard move 到 `src/product/account/`；Application 通过 Account-owned ports 绑定 HTTP、OAuth loopback、credential persistence 和其他平台 effect。
- 收紧 Agent 与 Application 的 MCP transport boundary，减少跨 owner 的具体 transport 依赖。
- 更新 Windows/macOS AgentCore staged artifacts，纳入 Conversation restore、Skill policy 与 MCP 修复。
- 重新明确验证 owner、失败模式与最小充分测试层，并将 lifecycle roots 和真实架构边界接入默认测试守卫。
- 隔离 automation runner identity，并更新 vertical fixtures 以匹配当前产品合同。

### Fixed

- 修复 Skill 管理与 Run admission 共享可变 policy context，以及 enablement 持久化失败后的状态一致性问题。
- 修复 MCP stdio executable `PATH`、stderr EOF teardown 和 SSE 空事件处理问题。
- 修复 MCP 恢复交互与管理页重构后的残留状态、组件和样式路径。
- 修复关闭 Task 后的删除协调流程，以及不适用的降级历史提示仍被显示的问题。
- 明确定义并修复 Storage receiver callback 的 reentrancy 行为。
- 修复 macOS package 缺少托盘图标资源及 Settings sidebar 样式不一致的问题。

## [0.1.1] - 2026-08-18

### Added

- 新增 Account-owned 用户模型连接运行时、持久化 registry、Bridge command/projection，以及 Metask managed 与 user-managed execution source 的显式切换事务。
- 接入 OpenAI Chat Completions 与 Gemini Native typed provider contract、AgentCore provider probe 和合同测试；Anthropic Messages 在原生 `x-api-key` 合同可用前保持 capability gate 关闭。
- 新增 Windows/macOS `native_sdk_compat/secure_input` 窄 capability seam，并将 MCP secret capture 接入 Host-owned 安全输入路径。
- 新增 `TaskContent`、`TaskOverview` Run activity 投影与可拖拽工作台侧栏；补齐对应 Renderer contract、decode、i18n 和交互测试。

### Changed

- 将 Agent Session 拆分为 `control`、`binding`、`runtime`、`wire` 叶模块，并把 MCP 实现收口到 `src/agent/mcp/`；同步强化 owner-boundary 与 inline coverage guard。
- Renderer hard cut 从 `AgentWorkSurface`/本地 conversation projection 切换到 Host 投影驱动的 `TaskContent`，删除失去职责的旧 AI 组件和样式路径。
- Workbench Run projection 区分 thinking、responding 与 tool activity，并统一 Task 消息排版和活动状态呈现。
- Workspace Edit permission 默认决策调整为 accept。
- Native SDK 升级到 `0.9.2`，并更新 Windows/macOS AgentCore staged bundle、lock 与 ABI 验证基线。

### Fixed

- 修复 Agent Runtime MCP selection update 未向外暴露的问题。
- 修复 UI request 在用户响应前提前离开 pending 状态，以及 Renderer 未在对应阅读位置渲染 pending request 的问题。
- 修复活跃 Run 进度未同步到 Task 内容区和详情投影的问题。
- 修复 Account 菜单设置入口未打开设置根页面的问题。

## [0.1.0] - 2026-08-16

### Added

- 桌面 Agent Workbench 首个发布版本：Windows x86_64（development baseline）与 macOS arm64（本地签名打包）。
- Metask Account：OAuth 登录、API Key 与模型目录、默认 API/模型切换与持久化；默认配置变更不影响已有 Task。
- Task 工作台：Task 创建、重命名、归档、关闭与删除；自动标题回退；任务状态通知；每个 Task 独立绑定模型。
- Agent 执行：基于 Metask AgentCore（ABI v1 revision 8）的 typed Text/Skill Run；内置 Read/Bash/Edit 工具；question/permission 用户决策；Run 取消；结构化 run 状态投影。
- 会话管理：手动 `/compact` 压缩；checkpoint 持久化，应用重启后从最近 finalized checkpoint 显式恢复 Conversation。
- Workspace：Manual Workspace 授权与复用；Automatic Workspace 按 Task 独立分配目录。
- 技能管理：本地 Skill 导入（包/目录）、导出、重新导入与卸载，支持个人与项目两种作用域。
- 定时任务：本地进程内 cron 调度；窗口关闭后继续运行；下次启动执行单次 missed-run reconciliation。
- 界面：中英双语；统一的 Metask 设计语言字号阶梯与组件体系。

[unreleased]: https://github.com/metask-ai/metawork/compare/v0.1.5...HEAD
[0.1.5]: https://github.com/metask-ai/metawork/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/metask-ai/metawork/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/metask-ai/metawork/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/metask-ai/metawork/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/metask-ai/metawork/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/metask-ai/metawork/releases/tag/v0.1.0

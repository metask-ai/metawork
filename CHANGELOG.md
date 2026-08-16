# Changelog

本文记录 MetaWork 所有面向用户的显著变更。

格式遵循 [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)，版本号遵循 [Semantic Versioning](https://semver.org/spec/v2.0.0.html)，真源是 `app.zon`。当前能力边界与验证状态以 [docs/validation.md](docs/validation.md) 为准。

## [Unreleased]

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

[unreleased]: https://github.com/metask-ai/metawork/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/metask-ai/metawork/releases/tag/v0.1.0

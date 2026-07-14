# MetaWork

MetaWork 是一款桌面端 Agent Workbench，面向工作区、会话、Agent 运行、工具调用、审批和工作结果管理。产品形态接近 Codex Desktop、Claude Work，但不以 IDE 或终端模拟器为中心。

## 当前状态

技术选型与三层职责边界已经确认；Run 并发、StopReason、反向控制、事件泵失败和恢复语义已形成实现约束，仍需由 Phase 0 垂直原型验证具体容量、进程模型与依赖契约。

| 层级 | 选择 |
| --- | --- |
| Renderer | React + Tailwind |
| Desktop Framework | Native SDK |
| Host / Workbench | Zig |
| AgentCore | cc-zig / `metacodes-core` |
| Agent UI contract | cc-zig `CoreEvent`、`UiEvent`、`UiRequest` / `UiResponse` |

Native SDK 直接构成 Zig Host，不设置额外 Adapter。模型 Provider SSE 由 cc-zig 内部处理，MetaWork 接收并渲染定义好的结构化数据。

`UiEvent` 当前是 cc-zig 已定义但尚未由 `agent_loop` 生产路径消费的协议类型。Phase 0 的 stop/cancel 直接使用 per-Run `AbortSignal`，不把 `UiBackend.poll()` 当作已完成能力。

## 文档

- [产品需求](docs/requirements.md)
- [高层架构](docs/architecture.md)
- [AgentCore 集成契约](docs/agentcore-integration.md)
- [Phase 0 验证计划](docs/phase-0-validation.md)
- [Agent 工作约束](AGENTS.md)

## 当前非目标

- 不采用 Tauri + Rust 作为正式宿主栈；
- 不使用 `.native` 取代当前 React Renderer；
- 不建立通用 UI 或 Desktop Framework 抽象层；
- 不以 PTY、xterm 或终端字节流作为默认 Agent 协议。

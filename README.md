# MetaWork

MetaWork 是一款桌面端 Agent Workbench，面向工作区、会话、Agent 运行、工具调用、审批和工作结果管理。产品形态接近 Codex Desktop、Claude Work，但不以 IDE 或终端模拟器为中心。

## 当前状态

技术选型与三层职责边界已经确认，macOS-first Phase 0 已完成 Gate 0 Native SDK React smoke，下一步进入 artifact-only AgentCore raw contract probe。Gate 0 的命令、trace、边界与已知限制见 [验证报告](docs/phase-0-gate-0-report.md)。

第一条实现链路基于 cc-zig experimental AgentCore ABI revision 1，只验证同步 Run、结构化事件、built-in tools、同步 UI request、取消和 Host 生命周期。它不包含 async pending、suspend/resume、进程重建恢复、strict Workspace security 或正式 Host tools。

完成同进程同步原型后，还必须通过 fault-domain spike 才能结束 Phase 0A。Windows 作为 Phase 0B 后续验证，不阻塞 macOS baseline。

| 层级 | 选择 |
| --- | --- |
| Renderer | React + Tailwind |
| Desktop Framework | Native SDK |
| Host / Workbench | Zig |
| AgentCore | cc-zig / 版本化 AgentCore library bundle |
| Agent UI contract | cc-zig `CoreEvent`、`UiRequest` / `UiResponse` |

Native SDK 直接构成 Zig Host，不设置额外 Adapter。模型 Provider SSE 由 cc-zig 内部处理，MetaWork 接收并渲染定义好的结构化数据。

MetaWork 不直接编译 cc-zig source tree。当前从显式 bundle root 锁定并校验精确 artifact；同步 baseline 通过后再建设本地 cache 和远程发布流程。正式 Host 只使用 cc-zig bundle SDK，不复制 ABI code、事件 tag 或 UI JSON schema。

`UiEvent` 当前是 cc-zig 已定义但尚未由 `agent_loop` 生产路径消费的协议类型。当前 stop/cancel 使用 per-Run abort，不把 `UiBackend.poll()` 当作已完成能力。

## 文档

- [产品需求](docs/requirements.md)
- [高层架构](docs/architecture.md)
- [AgentCore 集成契约](docs/agentcore-integration.md)
- [AgentCore ABI v1 消费基线](docs/agentcore-abi-v1.md)
- [Phase 0 验证计划](docs/phase-0-validation.md)
- [Phase 0 Gate 0 验证报告](docs/phase-0-gate-0-report.md)
- [Agent 工作约束](AGENTS.md)

## macOS 开发命令

要求 Node.js 22.15+ 与 Zig 0.16.0：

```bash
npm ci
npm run dev
npm run check
npm test
npm run build:debug
npm run build:release
npm run package:macos
```

项目使用本地锁定的 `@native-sdk/cli`，不依赖全局 `native`。`npm run build:*` 先构建 React production assets，再生成 macOS binary；打包产物位于 `zig-out/package/metawork.app`。

## 当前非目标

- 不采用 Tauri + Rust 作为正式宿主栈；
- 不使用 `.native` 取代当前 React Renderer；
- 不建立通用 UI 或 Desktop Framework 抽象层；
- 不以 PTY、xterm 或终端字节流作为默认 Agent 协议；
- 不把同步 ABI v1 baseline 描述为生产可用或可恢复产品。

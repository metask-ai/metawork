# MetaWork

MetaWork 是一款桌面端 Agent Workbench，面向工作区、会话、Agent 运行、工具调用、审批和工作结果管理。产品形态接近 Codex Desktop、Claude Work，但不以 IDE 或终端模拟器为中心。

## 当前状态

技术选型与三层职责边界已经确认，macOS-first Phase 0A Gate 0 至 Gate 7 已通过。当前有一条真实的同进程同步垂直原型，完成 Native SDK Bridge、React Workbench、锁定 AgentCore bundle、built-in Read/Bash/Edit、同步权限、取消、reload 视图恢复、bounded event/lifecycle 和 fault-domain 对照。

第一条实现链路当前精确锁定 metacodes（原 cc-zig）bundle `0.0.0-dev+5fe198cfac4a` 的 experimental AgentCore ABI revision 1，只验证同步 Run、结构化事件、built-in tools、同步 UI request、取消和 Host 生命周期。它不包含 async pending、suspend/resume、进程重建恢复、strict Workspace security 或正式 Host tools。

Gate 7 已证明当前同进程路径是零进程级隔离，并选择单 AgentCore Worker 作为后续正式方向。Worker 尚未实现，当前应用不得宣称具备 crash recovery。Windows 作为 Phase 0B 后续验证，不阻塞 macOS baseline。

| 层级 | 选择 |
| --- | --- |
| Renderer | React + Tailwind |
| Desktop Framework | Native SDK |
| Host / Workbench | Zig |
| AgentCore | metacodes / 版本化 AgentCore library bundle |
| Agent UI contract | metacodes `CoreEvent`、`UiRequest` / `UiResponse` |

Native SDK 直接构成 Zig Host，不设置额外 Adapter。模型 Provider SSE 由 metacodes 内部处理，MetaWork 接收并渲染 Host 产品投影。

MetaWork 不直接编译 metacodes source tree。隔离 probe 从显式 bundle root 校验精确 artifact；正式 build 使用与 lock 完全一致并 staged 的 bundle。后续再建设 content-addressed cache 和远程发布流程。正式 Host 只使用 bundle typed SDK，不复制 ABI code、事件 tag 或 UI JSON schema。

`UiEvent` 当前是 metacodes 已定义但尚未由 `agent_loop` 生产路径消费的协议类型。当前 stop/cancel 使用 per-Run abort，不把 `UiBackend.poll()` 当作已完成能力。

## 文档

- [产品需求](docs/requirements.md)
- [高层架构](docs/architecture.md)
- [AgentCore 集成契约](docs/agentcore-integration.md)
- [AgentCore ABI v1 消费基线](docs/agentcore-abi-v1.md)
- [Phase 0 验证计划](docs/phase-0-validation.md)
- [Phase 0 Gate 0 验证报告](docs/phase-0-gate-0-report.md)
- [Phase 0 Gate 1 验证报告](docs/phase-0-gate-1-report.md)
- [Phase 0 Gate 6 验证报告](docs/phase-0-gate-6-report.md)
- [Phase 0 Gate 7 验证报告](docs/phase-0-gate-7-report.md)
- [Agent 工作约束](AGENTS.md)

## macOS 开发命令

要求 Node.js 22.15+ 与 Zig 0.16.0：

```bash
npm ci
npm run agentcore:stage -- /absolute/path/to/metacodes-agentcore-bundle
npm run dev
npm run check
npm test
npm run build:debug
npm run build:release
npm run package:macos
```

项目使用本地锁定的 `@native-sdk/cli`，不依赖全局 `native`。`npm run build:*` 先构建 React production assets，再生成 macOS binary；打包产物位于 `zig-out/package/metawork.app`。

Gate 1 的隔离 probe 需要显式绝对 bundle root：

```bash
AGENTCORE_BUNDLE_ROOT=/absolute/path/to/bundle npm run probe:agentcore
```

该命令校验 bundle 后使用 `spikes/agentcore-contract` 的独立 build graph。正式应用 build/test/package 不读取该环境变量，只读取 `.agentcore/bundle` 中由 `agentcore:stage` 校验并原子更新的精确 bundle。

## 当前非目标

- 不采用 Tauri + Rust 作为正式宿主栈；
- 不使用 `.native` 取代当前 React Renderer；
- 不建立通用 UI 或 Desktop Framework 抽象层；
- 不以 PTY、xterm 或终端字节流作为默认 Agent 协议；
- 不把同步 ABI v1 baseline 描述为生产可用或可恢复产品。

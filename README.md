# MetaWork

MetaWork 是一款桌面端 Agent Workbench，面向工作区、会话、Agent 运行、工具调用、审批和工作结果管理。产品形态接近 Codex Desktop、Claude Work，但不以 IDE 或终端模拟器为中心。

## 当前状态

技术选型与三层职责边界已经确认，macOS-first 初始技术验证已经完成。当前有一条真实的同进程同步垂直原型，完成 Native SDK Bridge、React Workbench、锁定 AgentCore bundle、built-in Read/Bash/Edit、同步权限、取消、reload 视图恢复、bounded event/lifecycle 和 fault-domain 对照。

当前已验证基线 hard cut 到 Metask AgentCore ABI v1 revision 3，正式 build graph 只消费 `.agentcore/bundle/bindings/zig` 官方 package，不保留旧 namespace、路径、symbol、module alias 或 fallback。candidate/staged 信任链、完整测试、Debug/Release、桌面自动化和 macOS package 均已通过；精确 development artifact identity 与证据分别见 [AgentCore ABI v1 revision 3 消费合同](docs/agentcore-abi-v1.md)和 [revision 3 迁移验证报告](docs/agentcore-revision-3-migration-report.md)。同步链路不包含 async pending、suspend/resume、进程重建恢复、strict Workspace security 或正式 Host tools。

fault-domain 对照已经证明当前同进程路径是零进程级隔离，并选择单 AgentCore Worker 作为后续正式方向。Worker 尚未实现，当前应用不得宣称具备 crash recovery。Windows development baseline 已通过 artifact/probe、Native Debug/Release 和桌面自动化；这不等于 MSI、签名、更新或完整跨平台交付已经完成。当前证据边界见 [验证规范](docs/validation.md)。Linux 是后续计划，目前只有 target-policy 架构预留。

| 层级              | 选择                                              |
| ----------------- | ------------------------------------------------- |
| Renderer          | React + Tailwind                                  |
| Desktop Framework | Native SDK                                        |
| Host / Workbench  | Zig                                               |
| AgentCore         | 版本化 Metask AgentCore library bundle             |
| Agent UI contract | AgentCore `CoreEvent`、`UiRequest` / `UiResponse`  |

Native SDK 直接构成 Zig Host，不设置额外 Adapter。模型 Provider SSE 由 Metask AgentCore 内部处理，MetaWork 接收并渲染 Host 产品投影。

MetaWork 不直接编译 AgentCore 实现源码。candidate probe 从显式 bundle root 校验精确 artifact，并通过官方 Zig package 完成 source-free discover/link/run；正式 build 使用与 lock 字节完全一致并 staged 的 bundle。公司内部初步开发直接使用本机精确路径 `metacodes/zig-out`，当前不建设 resolver、content-addressed cache、artifact repository 或跨机器分发。正式 Host 只使用 bundle typed SDK，不复制 ABI code、事件 tag 或 UI JSON schema。

`UiEvent` 当前是 Metask AgentCore 已定义但尚未由 `agent_loop` 生产路径消费的协议类型。当前 stop/cancel 使用 per-Run abort，不把 `UiBackend.poll()` 当作已完成能力。

## 文档

- [产品需求](docs/requirements.md)
- [高层架构](docs/architecture.md)
- [AgentCore 集成契约](docs/agentcore-integration.md)
- [AgentCore ABI v1 revision 3 消费合同](docs/agentcore-abi-v1.md)
- [当前验证规范](docs/validation.md)
- [Account 集成历史实施记录](docs/account-integration-plan.md)
- [Metask Account API 合同状态](docs/metask-account-contract.md)
- [AgentCore ABI v1 revision 3 迁移验证报告](docs/agentcore-revision-3-migration-report.md)
- [Agent 工作约束](AGENTS.md)

## macOS 开发命令

要求 Node.js 22.15+ 与 Zig 0.16.0：

```bash
npm ci
npm run agentcore:stage -- /absolute/path/to/metacodes/zig-out/agentcore/aarch64-macos
npm run dev
npm run check
npm test
npm run build:debug
npm run build:release
npm run package:macos
```

项目使用本地锁定的 `@native-sdk/cli`，不依赖全局 `native`。`npm run build:*` 先构建 React production assets，再生成 macOS binary；打包产物位于 `zig-out/package/metawork.app`。

## Windows baseline 命令

要求 Node.js 22.15+、Zig 0.16.0 和精确锁定的 x86_64 Windows GNU revision 3 bundle：

```powershell
npm ci
npm run agentcore:stage -- C:\absolute\path\to\x86_64-windows.win10...win11_dt-gnu
npm run test:windows:bringup
```

Debug/Release 可执行文件及 Renderer 资源位于 `zig-out/bin`，可直接运行 `zig-out/bin/metawork.exe`。当前不生成 MSI，也不要求签名；分发、签名和更新是后续交付。

candidate 隔离 probe 需要显式绝对 bundle root：

```bash
AGENTCORE_BUNDLE_ROOT=/absolute/path/to/bundle npm run probe:agentcore
```

该命令先执行 exact lock/checksum/target/symbol 校验，再在 bundle 外部临时目录中编译并运行官方 Zig package consumer。正式应用 build/test/package 不读取该环境变量，只读取 `.agentcore/bundle` 中由 `agentcore:stage` 校验和可恢复替换的精确 bundle；stager 不承诺并发 stage/build 或跨进程 crash transaction。

## 当前非目标

- 不采用 Tauri + Rust 作为正式宿主栈；
- 不使用 `.native` 取代当前 React Renderer；
- 不建立通用 UI 或 Desktop Framework 抽象层；
- 不以 PTY、xterm 或终端字节流作为默认 Agent 协议；
- 不把同步 ABI v1 baseline 描述为生产可用或可恢复产品。

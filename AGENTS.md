# AGENTS.md

本文件适用于整个 MetaWork 仓库。

## 开始工作前

按任务范围阅读对应 source of truth：

1. 产品行为与范围：[docs/requirements.md](docs/requirements.md)
2. 技术选型与系统边界：[docs/architecture.md](docs/architecture.md)
3. cc-zig、事件泵、所有权和生命周期：[docs/agentcore-integration.md](docs/agentcore-integration.md)
4. 当前 AgentCore 预编译库能力：[docs/agentcore-abi-v1.md](docs/agentcore-abi-v1.md)
5. 原型范围与验收：[docs/phase-0-validation.md](docs/phase-0-validation.md)

`README.md` 只作为项目入口；不要把它当作完整需求或架构规范。

## 当前阶段

- macOS 是当前唯一优先实现和真实验收平台；Windows 属于后续 Phase 0B。
- 当前 cc-zig bundle 是精确锁定的 experimental AgentCore ABI revision 1，用于同步 macOS baseline，不代表 stable compatibility policy 已冻结。
- 同步 baseline、完整 Phase 0A 和后续 AgentCore capability 是三个不同门槛。Renderer reload 可以恢复仍存活 Host 的视图，不等于 AgentCore 进程恢复。
- async pending、suspend/resume、Session 持久化恢复、strict Workspace security 和可路由产品 Host tools 不属于当前 ABI v1 baseline。

## 不可违反的边界

- React + Tailwind 是当前正式 Renderer。
- Native SDK 直接构成 Zig Host；不要增加 `NativeSdkAdapter`、通用 Desktop Interface 或框架替换层。
- cc-zig 是 Agent 结构化协议的唯一来源；不要再定义平行的 `AgentEvent` / `WorkbenchEvent` 体系。
- MetaWork 正式应用只链接 AgentCore library bundle。当前隔离的 artifact-only contract probe 和后续正式 Host 都可以从显式 bundle root 消费精确产物，但不得把 cc-zig source tree 纳入 build graph。禁止 path/Git source dependency、源码复制、`latest`、可变 tag 和静默 source fallback。
- 初期不先实现 artifact resolver 或内容寻址 cache。同步 baseline 通过后，再让本地 cache 与远程 artifact repository 复用同一 bundle layout、identity 和 checksum 规则。
- AgentCore binary ABI facade 由 cc-zig 单一维护；MetaWork 只使用 bundle SDK。ABI 禁止 native Zig slice、Zig enum、allocator、error union 和 tagged union，wire 层使用固定宽度整数 code、pointer+length、opaque handle、固定布局 struct 和 callback context。
- 隔离的 raw contract probe 可以使用 bundle 当前 raw SDK 表面记录依赖缺口，但不得进入正式 Host。正式 Host 必须等待 bundle SDK 提供 typed `Status` / `StopReason`、校验后的 `CoreEvent` / `UiRequest` decoder 和 `UiResponse` encoder；MetaWork 不自行复制 code、tag 或 JSON schema。
- 当前产品路径不得注册 ABI v1 Host tools。现有 Host tool callback 的内部 `session_id` 尚未形成 MetaWork Session/Run 的正式映射合同；Read/Bash/Edit 使用 cc-zig built-in tools。
- Provider credential 只由 Host 读取并传给 AgentCore；不得进入 Renderer、Bridge、日志、事件、snapshot 或持久化视图。
- 当前 v1 只允许临时或用户明确 trusted 的 Workspace 做验证，不得宣称已经具备 strict Workspace security。
- MetaWork 通过 cc-zig `UiBackend` / `UiRequester` / `agent_loop` library contract 接入 AgentCore，不解析 Provider SSE。
- `CoreEvent` 中需要异步保留的 borrowed slice 必须在 callback 返回前深拷贝。
- AgentCore/tool 线程不得直接调用 WebView；所有事件必须经过有界、线程安全的 Host 事件泵。
- `text_chunk` 可以合并，但在没有完整消息快照前不得丢失字节；控制事件不得静默丢弃。
- callback 内 event copy 或入队失败时返回 callback fatal。callback 返回后的不可恢复 Bridge pipeline failure 必须设置 per-Run `HostCause` 并中止 in-flight Run；不得只改 Host 状态后让 Core 继续运行。
- ABI function status 必须先于 `RunResult` 处理；status 非 OK 时禁止读取 `RunResult`，并精确释放 diagnostic buffer。
- `StopReason` 必须先由 cc-zig bundle SDK 校验 raw wire code，再对 SDK 类型做无 `else` 的穷尽 switch，并在 Host envelope 中保留原始 code/reason。当前缺少恢复载荷时，`suspended` / `backgrounded` 视为 dependency contract failure，不伪造可恢复状态。
- 不假设 `UiBackend.poll()` 已接通。当前 stop/cancel 直接使用 per-Run abort；生成期消息进入 Host 有界 Session 队列，直到 cc-zig 生产调用链被验证。
- 当前 UI request 是同步 callback。等待用户期间占用 Run executor slot，但不得阻塞 WebView 主线程；deadline、cancel、Session close 和 Host shutdown 都必须唤醒等待。
- 每个 Session 至多一个 in-flight Run；同步 `run()` 通过有上限的 executor 调度，不为任意数量 Session 无上限创建线程。
- Session close 必须遵循：拒绝新任务、取消 queued Run、唤醒 UI wait、设置 first-writer-wins `HostCause`、abort、join、等待 callback quiescence、destroy。Runtime 只能在全部 Session 销毁后销毁。
- `Conversation` 和跨 Run 状态属于 Session 生命周期；不得让它们引用已释放的 run-scoped arena。
- Renderer 不是安全边界。Host 必须执行命令白名单、来源、payload、会话归属、工作区和权限校验。
- 不以 PTY、xterm 或终端字符流作为默认 Agent 通信协议。普通 Bash 工具使用非交互 shell 子进程和 stdout/stderr capture。
- 不因统一使用 Zig 而默认单进程；Gate 7 必须用故障注入比较同进程和最小 Worker fault domain。在该 Gate 前只能称同进程 prototype，不能称完整 Phase 0A。
- 不建立 React 到 `.native` 的迁移层或第二套 Renderer。
- 固定 cc-zig bundle identity、commit、target、toolchain 和 checksum；其 Markdown 与 bundle SDK/manifest 冲突时，以锁定 artifact 的机器可读合同为准并记录依赖缺陷。

## 变更规则

- 产品需求变化只更新 `docs/requirements.md`，并检查其对架构和验证计划的影响。
- 技术决策变化更新 `docs/architecture.md`，不要在 README 或 AGENTS 中复制完整论证。
- cc-zig 契约、线程、所有权、生命周期、恢复和 Shell 行为变化更新 `docs/agentcore-integration.md`。
- AgentCore ABI required capabilities、函数职责、wire 所有权或兼容门槛变化更新 `docs/agentcore-abi-v1.md`。
- 验收矩阵、spike 和退出判据变化更新 `docs/phase-0-validation.md`。
- 如果同一事实出现在多份文档，保留一个规范性定义，其他位置使用链接或简短摘要。

## 验证

当前 macOS 工程命令：

```bash
npm ci
npm run format:check
npm run check
npm test
npm run build:debug
npm run build:release
npm run package:macos
```

`npm run dev` 启动 React development server 和 Native SDK shell。Native SDK 由根 `package.json` 与 `package-lock.json` 精确锁定；不要改用全局 `native` 或提交 `.native/` 生成目录。Windows 命令进入 Phase 0B 后再补充。禁止让验证流程只存在于个人环境或聊天记录中。

Gate 1 artifact-only probe 使用独立 build graph，必须显式指定绝对 bundle root：

```bash
AGENTCORE_BUNDLE_ROOT=/absolute/path/to/bundle npm run probe:agentcore
```

该变量不得进入正式应用 build/test/package，probe 也不得导入 cc-zig 实现源码。

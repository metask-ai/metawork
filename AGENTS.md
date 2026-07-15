# AGENTS.md

本文件适用于整个 MetaWork 仓库。

## 开始工作前

按任务范围阅读对应 source of truth：

1. 产品行为与范围：[docs/requirements.md](docs/requirements.md)
2. 技术选型与系统边界：[docs/architecture.md](docs/architecture.md)
3. cc-zig、事件泵、所有权和恢复：[docs/agentcore-integration.md](docs/agentcore-integration.md)
4. AgentCore 预编译库首版能力：[docs/agentcore-abi-v1.md](docs/agentcore-abi-v1.md)
5. 原型范围与验收：[docs/phase-0-validation.md](docs/phase-0-validation.md)

`README.md` 只作为项目入口；不要把它当作完整需求或架构规范。

## 不可违反的边界

- React + Tailwind 是当前正式 Renderer。
- Native SDK 直接构成 Zig Host；不要增加 `NativeSdkAdapter`、通用 Desktop Interface 或框架替换层。
- cc-zig 是 Agent 结构化协议的唯一来源；不要再定义平行的 `AgentEvent` / `WorkbenchEvent` 体系。
- MetaWork 正式应用只链接 AgentCore library bundle。Phase 0 允许隔离 packaging spike 读取本地 cc-zig source tree，以验证静态库/API/manifest 可行性；该 spike 不得进入应用 build graph。验证后由 cc-zig 正式构建发布，MetaWork 从本地 artifact cache 或远程消费，并精确锁定 version/build identity 与 checksum。除该 spike 外，禁止 source tree、path/Git source dependency、源码复制、`latest`、可变 tag 和静默 source fallback。
- AgentCore binary ABI facade 由 cc-zig 单一维护；MetaWork 只使用 bundle SDK。ABI 禁止 native Zig slice、Zig enum、allocator、error union 和 tagged union，wire 层使用校验后的固定宽度整数 code、pointer+length、opaque handle、固定布局 struct 和 callback context；bundle SDK 再将合法 code 包装为类型化 enum。
- MetaWork 通过 cc-zig `UiBackend` / `UiRequester` / `agent_loop` library contract 接入 AgentCore，不解析 Provider SSE。
- `CoreEvent` 中需要异步保留的 borrowed slice 必须在 `emit()` 返回前深拷贝。
- AgentCore/tool 线程不得直接调用 WebView；所有事件必须经过有界、线程安全的 Host 事件泵。
- `text_chunk` 可以合并，但在没有完整消息快照前不得丢失字节；控制事件不得静默丢弃。
- event copy、控制队列或 Bridge pipeline 发生不可恢复错误时，必须设置 Run fatal reason 并触发其 `AbortSignal`；不得只改 Host 状态后让 Core 继续运行。
- `StopReason` 必须先由 cc-zig bundle SDK 校验 raw wire code，再对 SDK 的类型化 enum 做无 `else` 的穷尽 switch，并在 Host envelope 中保留原始 code/reason；cc-zig facade 对内部 enum 也必须穷尽映射。
- 不假设 `UiBackend.poll()` 已接通。当前 stop/cancel 直接使用 per-Run `AbortSignal`；生成期消息进入 Host 有界 Session 队列，直到 cc-zig 生产调用链被验证。
- 每个 Session 至多一个 in-flight Run；同步 `run()` 通过有上限的 executor 调度，不为任意数量 Session 无上限创建线程。
- `Conversation` 和跨 Run 状态属于 Session 生命周期；不得让它们引用已释放的 run-scoped arena。
- 当前每个 turn 只有一个可恢复挂起点，且 `UiRequester` 只供顶层 Run；subagent 不得进入未定义的挂起恢复路径。
- Renderer 不是安全边界。Host 必须执行命令白名单、来源、payload、会话归属、工作区和权限校验。
- 不以 PTY、xterm 或终端字符流作为默认 Agent 通信协议。普通 Bash 工具使用非交互 shell 子进程和 stdout/stderr capture。
- 不因统一使用 Zig 而默认单进程；进程模型由 Phase 0 的故障与资源数据决定。
- 不建立 React 到 `.native` 的迁移层或第二套 Renderer。
- 固定 cc-zig commit；其 Markdown API 文档与编译器类型冲突时，以固定 commit 的导入类型为准并记录依赖缺陷。

## 变更规则

- 产品需求变化只更新 `docs/requirements.md`，并检查其对架构和验证计划的影响。
- 技术决策变化更新 `docs/architecture.md`，不要在 README 或 AGENTS 中复制完整论证。
- cc-zig 契约、线程、所有权、恢复和 Shell 行为变化更新 `docs/agentcore-integration.md`。
- AgentCore ABI required capabilities、函数职责、wire 所有权或冻结门槛变化更新 `docs/agentcore-abi-v1.md`。
- 验收矩阵、spike 和退出判据变化更新 `docs/phase-0-validation.md`。
- 如果同一事实出现在多份文档，保留一个规范性定义，其他位置使用链接或简短摘要。

## 验证

项目尚未完成代码脚手架，因此当前没有正式 build/test 命令。引入可运行工程时，先补充 macOS 开发构建、测试、格式检查和打包命令；进入 Phase 0B 时再补充对应 Windows 命令。禁止让验证流程只存在于个人环境或聊天记录中。

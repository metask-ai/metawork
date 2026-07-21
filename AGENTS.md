# AGENTS.md

本文件适用于整个 MetaWork 仓库。

## 开始工作前

按任务范围阅读对应 source of truth：

1. 产品行为与范围：[docs/requirements.md](docs/requirements.md)
2. 技术选型与系统边界：[docs/architecture.md](docs/architecture.md)
3. AgentCore、事件泵、所有权和生命周期：[docs/agentcore-integration.md](docs/agentcore-integration.md)
4. 当前 AgentCore 预编译库能力：[docs/agentcore-abi-v1.md](docs/agentcore-abi-v1.md)
5. 当前验证矩阵与退出条件：[docs/validation.md](docs/validation.md)
6. Metask Account production API 确认状态：[docs/metask-account-contract.md](docs/metask-account-contract.md)

`README.md` 只作为项目入口；不要把它当作完整需求或架构规范。

## 当前阶段

- macOS 仍是优先真实验收平台；Windows development baseline（artifact、官方 SDK candidate probe、Native Debug/Release 和桌面自动化）已通过。Windows 分发、签名、更新和完整安全矩阵仍属后续交付；Linux 只做架构预留，尚未接入。
- 当前已验证基线 hard cut 到精确锁定的 development AgentCore ABI v1 revision 3 target-specific artifacts。macOS artifact 为 dirty provenance，Windows x86_64 GNU artifact 为同 commit 的 clean build；二者分别以完整 manifest bytes 和 payload checksum 锁定，不推导为同一可重建源码状态。证据见 `docs/agentcore-revision-3-migration-report.md`、当前 repository locks 与 `docs/validation.md`。
- 当前同步 baseline 与后续 AgentCore capability 是不同门槛。Renderer reload 可以恢复仍存活 Host 的视图，不等于 AgentCore 进程恢复。
- async pending、suspend/resume、Session 持久化恢复、strict Workspace security 和可路由产品 Host tools 不属于当前 ABI v1 baseline。

## 不可违反的边界

- React + Tailwind 是当前正式 Renderer。
- Native SDK 直接构成 Zig Host；不要增加 `NativeSdkAdapter`、通用 Desktop Interface 或框架替换层。
- Metask AgentCore bundle SDK 是 Agent 结构化协议的唯一来源；不要再定义平行的 `AgentEvent` / `WorkbenchEvent` 体系。
- MetaWork 正式应用只消费 canonical `.agentcore/bundle` 和其中的官方 `bindings/zig` package；显式外部 bundle root 只属于 candidate probe/stage。不得把 AgentCore 实现源码纳入 build graph。禁止 path/Git implementation source dependency、源码复制、`latest`、可变 tag 和静默 source fallback。
- 公司内部初步开发直接从本机精确路径 `metacodes/zig-out/agentcore/<target>` 获取 target-specific candidate；当前不实现 artifact resolver、内容寻址 cache、artifact repository 或跨机器自动分发。
- AgentCore binary ABI facade 由 Metask AgentCore 单一维护；MetaWork 只使用 bundle SDK。ABI 禁止 native Zig slice、Zig enum、allocator、error union 和 tagged union，wire 层使用固定宽度整数 code、pointer+length、opaque handle、固定布局 struct 和 callback context。
- candidate probe 只验证锁定 artifact 和官方 Zig package 能够 source-free discover/link/run，不进入正式 Host。正式 Host 只使用 bundle SDK 提供的 typed `Status` / `StopReason`、校验后的 `CoreEvent` / `UiRequest` decoder 和 `UiResponse` encoder；MetaWork 不自行复制 code、tag 或 JSON schema，也不维护上游 facade 或 SDK 的平行测试套件。
- 当前产品路径不得注册 ABI v1 Host tools。revision 3 Host tool callback 的 `RunContext` wire identity 已可验证，但 MetaWork 尚未定义产品级 tool catalog、权限、Workspace 与多 Session 路由政策；Read/Bash/Edit 使用 AgentCore built-in tools。
- Provider credential 只由 Host Account 读取并经 Workbench owned runtime config 传给 AgentCore；不得进入 Renderer、Bridge、日志、事件、snapshot 或持久化视图。
- production provider/model/base URL/API Key 只来自 Account 已锁定并验证的 Metask contract；禁止环境默认值、Renderer 字段或 Bridge payload 注入。Metask contract blocked 时可以实现纯状态机和 test-only fake，不得猜测或发布 production OAuth/API client。
- 当前 v1 只允许临时或用户明确 trusted 的 Workspace 做验证，不得宣称已经具备 strict Workspace security。
- MetaWork 通过 AgentCore `UiBackend` / `UiRequester` / `agent_loop` library contract 接入，不解析 Provider SSE。
- `CoreEvent` 中需要异步保留的 borrowed slice 必须在 callback 返回前深拷贝。
- AgentCore/tool 线程不得直接调用 WebView；所有事件必须经过有界、线程安全的 Host 事件泵。
- `text_chunk` 可以合并，但在没有完整消息快照前不得丢失字节；控制事件不得静默丢弃。
- callback 内 event validation/copy/入队失败，或 canonical consumer 无法被通知时，返回 callback fatal；已经 owned 的 event 不得因 notification failure 被泄漏或静默丢弃。Renderer/Bridge response、revision、snapshot、reload 或 connection failure 必须以 typed transport fact 交给 Workbench policy，Bridge 不得直接设置 Run cause 或 abort Agent Run。
- 跨越同步 Bridge handler 返回的 payload 必须是 Bridge-owned copy 或显式 ownership transfer；shutdown 先 stop ingress 和 quiesce callbacks，再断开 Workbench，owned delivery buffers 最后独立释放。
- ABI function status 必须先于 `RunResult` 处理；status 非 OK 时禁止读取 `RunResult`，并精确释放 diagnostic buffer。
- `StopReason` 必须先由 Metask AgentCore bundle SDK 校验 raw wire code，再对 SDK 类型做无 `else` 的穷尽 switch，并在 Host envelope 中保留原始 code/reason。unknown code fail closed，不伪造恢复或预算状态。
- 当前 ABI v1 revision 3 的 observation decoder 必须显式处理 `known` / `unknown`；当前 Host 在 SDK 完成结构、ownership 和 byte-bound 校验后立即忽略 valid unknown observation，不让其占用产品事件泵，也不得传给 Renderer 或猜测为产品状态。`resource_limit` 和 admission 后 Session poisoning 必须按 SDK contract 处理。
- 当前 ABI v1 revision 3 只提供 question 与 permission UI control。未提供的 plan approval、custom UI、Output、FileChange 和 plan-progress 必须隐藏并延期，不得复制旧 experimental 协议。
- 不假设 `UiBackend.poll()` 已接通。当前 stop/cancel 直接使用 per-Run abort；生成期消息进入 Host 有界 Session 队列，直到 AgentCore 生产调用链被验证。
- 当前 UI request 是同步 callback。等待用户期间占用 Run executor slot，但不得阻塞 WebView 主线程；deadline、cancel、Session close 和 Host shutdown 都必须唤醒等待。
- UI callback admission 成功后仍可能与后续 Core identity failure 并发；发布 request 和最终提取 response 时都必须在 Session lock 下确认现有 identity/dependency-contract 状态健康。identity failure 必须返回 UI fatal，并释放已经编码但尚未转移给 Core 的 response。
- 每个 Session 至多一个 in-flight Run；同步 `run()` 通过有上限的 executor 调度，不为任意数量 Session 无上限创建线程。
- Session close 必须遵循：拒绝新任务、取消 queued Run、唤醒 UI wait、设置 first-writer-wins `HostCause`、abort、join、等待 callback quiescence、destroy。Runtime 只能在全部 Session 销毁后销毁。
- Workbench 独占 Executor、queue 与 workers 的创建、admission、shutdown 和释放；Agent Runtime 不接收 Scheduler capability，也不得反向 enqueue 或销毁 Workbench 执行资源。
- `Conversation` 和跨 Run 状态属于 Session 生命周期；不得让它们引用已释放的 run-scoped arena。
- Renderer 不是安全边界。Host 必须执行命令白名单、来源、payload、会话归属、工作区和权限校验。
- 不以 PTY、xterm 或终端字符流作为默认 Agent 通信协议。普通 Bash 工具使用非交互 shell 子进程和 stdout/stderr capture。
- 不因统一使用 Zig 而默认单进程；fault-domain 故障注入已经比较同进程和最小 Worker，并选择单 AgentCore Worker 作为后续正式方向。Worker 实现前只能称当前路径为同进程 prototype。
- 不建立 React 到 `.native` 的迁移层或第二套 Renderer。
- 固定 AgentCore bundle identity、commit、target、toolchain 和 checksum；其 Markdown 与 bundle SDK/manifest 冲突时，以锁定 artifact 的机器可读合同为准并记录依赖缺陷。

## 变更规则

- 产品需求变化只更新 `docs/requirements.md`，并检查其对架构和验证计划的影响。
- 技术决策变化更新 `docs/architecture.md`，不要在 README 或 AGENTS 中复制完整论证。
- AgentCore 契约、线程、所有权、生命周期、恢复和 Shell 行为变化更新 `docs/agentcore-integration.md`。
- AgentCore ABI required capabilities、函数职责、wire 所有权或兼容门槛变化更新 `docs/agentcore-abi-v1.md`。
- 当前验证矩阵、持续回归和退出判据变化更新 `docs/validation.md`。
- Metask OAuth、API Key catalog、ExecutionTarget 或错误 schema 的外部确认状态更新 `docs/metask-account-contract.md`。
- 如果同一事实出现在多份文档，保留一个规范性定义，其他位置使用链接或简短摘要。

## 验证

macOS 工程命令：

```bash
npm ci
npm run format:check
npm run check
npm test
npm run build:debug
npm run build:release
npm run package:macos
```

Windows baseline 命令：

```powershell
npm run agentcore:stage -- C:\absolute\path\to\x86_64-windows.win10...win11_dt-gnu
npm run test:windows:bringup
```

`npm run dev` 启动 React development server 和 Native SDK shell。Native SDK 由根 `package.json` 与 `package-lock.json` 精确锁定；不要改用全局 `native` 或提交 `.native/` 生成目录。禁止让验证流程只存在于个人环境或聊天记录中。

candidate probe 使用临时的独立 SDK consumer，必须显式指定绝对 bundle root：

```bash
AGENTCORE_BUNDLE_ROOT=/absolute/path/to/bundle npm run probe:agentcore
```

该变量不得进入正式应用 build/test/package，probe 也不得导入 AgentCore 实现源码。

# MetaWork 工程结构与所有权

> 状态：描述 active tree 的当前结构与可执行边界；不维护目标目录草案或迁移计划

## 1. 文档职责

本文只回答三个问题：代码现在放在哪里、每个目录拥有什么、依赖可以朝哪个方向流动。

- 产品行为以 [产品需求](requirements.md) 为准；
- 系统职责与安全边界以 [高层架构](architecture.md) 为准；
- Application 内部 owner、事务与恢复以 [Application 内部架构](application-architecture.md) 为准；
- Renderer Bridge wire 与运输语义以 [Renderer Bridge 合同](renderer-bridge-contract.md) 为准；
- AgentCore 生命周期以 [AgentCore 集成契约](agentcore-integration.md) 为准；
- UI 行为以 [Workbench UI 设计](workbench-ui-design.md) 为准；
- 验证状态与入口以 [验证规范](validation.md) 为准。

本文不预测尚不存在的文件，不为未来 capability 预建空目录，也不记录已经完成的迁移步骤。结构变化只有在真实职责或不变量形成后才进入本文。

## 2. 当前仓库地图

```text
metawork/
├── docs/                  # 当前规范、验证账本与保留的 artifact migration 证据
├── frontend/
│   └── src/
│       ├── app/           # React composition 与窗口级状态
│       ├── bridge/        # Renderer Bridge client、runtime decoder 与 snapshot transport
│       ├── workbench/     # canonical snapshot store、selector 与纯派生状态
│       ├── features/      # 用户可见 feature
│       ├── components/ui/ # 无业务语义的 UI primitive 与 declarative window controls
│       ├── i18n/          # message catalog、formatter 与 locale runtime
│       └── platform/      # Renderer-only 本地偏好；不得包含原生窗口能力
├── src/
│   ├── main.zig           # 进程入口
│   ├── app.zig            # Desktop Host composition root；共置 Application coordinator
│   ├── app/                # Desktop Host-owned 窄平台 capability composition
│   ├── product_identity.zig # 从 app.zon 派生 development identity 与 macOS namespace
│   ├── native_sdk_compat/ # 按已登记 capability 隔离的 Desktop Host 兼容实现
│   │   ├── system_webview_drag_region.zig # 有界 System WebView drag-region contract/state
│   │   ├── system_webview_drag_region/
│   │       ├── windows.zig # 创建期 HWND 捕获与 root/WebView hit-test subclass
│   │       └── macos.zig   # live-pointer drag 的公开 SDK 原语
│   │   ├── system_webview_window_controls.zig # SDK 缺失按钮能力的窄 contract/state
│   │   └── system_webview_window_controls/
│   │       └── windows.zig # 最大化/还原、用户关闭与最大化状态
│   ├── account.zig        # Account module entrypoint
│   ├── account/           # Account Runtime、OAuth、catalog、credential 与状态机
│   ├── bridge.zig         # Renderer Bridge module entrypoint
│   ├── bridge/            # command policy、Dispatcher 与 ProductDelivery
│   ├── workbench.zig      # Workbench module entrypoint
│   ├── workbench/         # 产品 projection 与 bounded executor
│   ├── agent.zig          # Agent execution module entrypoint
│   ├── agent/             # catalog、Session、event pump 与 callback ownership
│   ├── automation.zig     # compile-time automation selection
│   └── automation/        # enabled/disabled authority capability
├── tests/
│   ├── agent/             # Agent lifecycle invariants
│   ├── workbench/         # Workbench executor/lifecycle invariants
│   ├── integration/       # 跨 owner 竞态
│   └── support/           # deterministic fake 与共享 fixture
├── scripts/               # Node 回归、真实应用编排与 artifact 工具
├── build_support/         # 正式 AgentCore bundle verifier 与 target locks
├── build.zig              # Zig/Native SDK module graph
├── app.zon                # Native window、origin 与 command allowlist
└── package.json           # 工程命令入口
```

`build_support/` 是正式 build graph 的一部分，不是归档目录。一次性 candidate consumer 在临时目录生成；实验 harness、阶段报告和仅为旧验证服务的 fixture 不进入 active tree。

## 3. 顶层所有权

| Boundary / role          | 唯一职责                                                                                                           | 不拥有                                                                          |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------- |
| Desktop Host composition | Native SDK composition、平台 capability 注入、平台资源与顶层 Bridge/Application/Native 生命周期顺序                | 产品 policy、Application 内部事务、第二套 Bridge transport                      |
| App coordinator          | Application 主线程跨 owner 提交、事件屏障与内部生命周期顺序                                                        | Account/Workbench 领域状态、Agent 调度策略、平台资源                            |
| Account                  | Runtime、OAuth/catalog 状态、credential、attempt/effect/mailbox、恢复、脱敏 Account view、ExecutionConfig transfer | Workbench Task、Renderer 状态、AgentCore Runtime                                |
| Workbench                | Workspace/Task/Run 产品状态、Executor、admission、terminal product record、snapshot projection                     | AgentCore raw protocol、Native WebView、Account secret                          |
| Agent                    | AgentCore Runtime/Session/Conversation、callback、event pump、Run terminal facts                                   | 产品队列、Task 历史、Bridge transport                                           |
| Bridge                   | command authority、payload decode、Workspace grant、ProductDelivery connection/revision/snapshot transport         | 产品策略真相、AgentCore handle、Account runtime                                 |
| Renderer                 | snapshot 消费、产品 WebUI 交互、纯 UI 状态与本地草稿                                                               | 原生窗口 owner、平台真实状态、安全决策、secret、AgentCore raw event、产品状态机 |

`account/contract.zig` 是 Account owner 发布的纯合同，不是第六个产品 owner。`automation/` 只提供受控账号、origin 和临时 Workspace authority，不注册额外协议，也不拥有产品 transport state。

## 4. Renderer 结构

### `app/`

`App.tsx` 是唯一 React composition entry。它组装 feature、选择当前 Task 与 New task 路径上下文，并协调 bootstrap、view-sync 和窗口级错误状态。只有形成可独立测试的不变量时才提取 controller 或 hook；不得只为缩短文件制造 callback 转发层。

### `bridge/`

- `commands.ts` 定义 Renderer 使用的完整命令目录与 Bridge identity/revision；
- `client.ts` 是唯一 `window.zero` command/event 适配入口；
- `decode-contracts.ts` 对所有 Host payload 做 runtime decode；
- `connection.ts` 协调 contract bootstrap、generation、重连与 snapshot refresh；
- `snapshot/` 负责 bounded descriptor、分块读取和 retry，不拥有产品状态；
- `__fixtures__/workbench-snapshot.fixture` 是 Zig serializer 与 TypeScript decoder 共用的 canonical bytes。

Renderer Bridge 的 identity、revision、command、event、snapshot 与兼容策略只由 [Renderer Bridge 合同](renderer-bridge-contract.md)定义。React component 不得直接访问 `window.zero`、拼 wire payload 或解析 AgentCore raw JSON。

### `workbench/` 与 `features/`

`workbench/` 只保存 canonical Host snapshot、selector 和无副作用派生状态。Workspace/Task 生命周期仍由 Host 决定；Renderer 只持有选择、折叠、输入草稿等纯 UI 状态。

`features/` 按用户可见能力分区。feature 通过 `workbench/` selector 消费产品状态，不读取其他 feature 的内部文件。带业务语义的 Timeline、Approval、Composer、Task list、Workspace path selection、Search 和 Task activity 保留在各自 feature；真正无业务语义的 primitive 才进入 `components/ui/`。

`features/settings/WorkspaceSettings.tsx` 是 Manual Workspace 的低频 lifecycle 视图，消费已解码 projection 并通过 App action controller 调用现有 choose/remove command；它不拥有 registry、authority、Task 导航或 Host removal 状态机。已有 Task 的 Workspace 只从 Task projection 推导，New task 只持有 `draftWorkspaceId`，Renderer 不保存 `activeWorkspaceId` 镜像。

`workbench/task-visibility.ts` 定义一个跨 Store、左栏与搜索复用的纯 projection 不变量：只有 owning Workspace 同时存在于 canonical snapshot 的 Task 才参与活动导航。它不拥有 Task 历史或 Workspace lifecycle；被移除 Workspace 的 Task 仍由 Host 保存。

## 5. Zig 结构

### `app.zig`、`app/` 与 module entrypoint

`main.zig` 只调用 `metawork_app`。`app.zig` 物理上共置两个角色：Desktop Host composition root 组装 Bridge 与 Application、消费并注入 Native SDK 的窄平台 capability、驱动平台生命周期；Application coordinator 在主线程按规范协调 Account prepare/commit、MCP preparation/activation、Workbench no-fail install、Agent event drain 与 owner 生命周期。后者属于 Application 的事务协调但不持有领域状态或复制 owner policy；这种源码共置不产生新的模块、业务 owner 或统一 Host facade。

`app/mcp_platform.zig` 只适配 MCP 系统 credential、stdio 与 Streamable HTTP mechanics，不解析 MCP JSON-RPC 或复制协商，也不形成新的产品 owner。

`native_sdk_compat/system_webview_drag_region.zig` 是 Desktop Host-owned 的有界 System WebView drag-region capability seam。它只拥有有界 region 校验、root 平台 binding 与 drag 调用编排；document generation 和 source-window authority 归 Bridge `Dispatcher`，不进入该 seam。只有 `app.zig` 可以组装它；不拥有按钮 action、按钮 capability、窗口最大化状态或 resize。Windows 启动期精确捕获并绑定 root HWND，document `connect/disconnect` 只标记 Renderer 会话是否附着；`sync` 只事务式替换 region，不能安装、重装或销毁平台资源，也不得递归依赖 Chromium 跨进程 child HWND。`system_webview_drag_region/macos.zig` 只在 live pointer event 内调用 SDK 已有 `startWindowDrag` 原语并保留系统交通灯；Windows 在 Native SDK 提供正式 System WebView drag-region 能力前不发布 live-pointer drag。System WebView 隐藏标题栏的 resize hit surface 仍归 Native SDK，不由该 seam 模拟。平台文件独占对应 root hook、subclass 与 teardown，不创建覆盖 WebView 的辅助窗口。

`native_sdk_compat/system_webview_window_controls.zig` 是 Desktop Host-owned 的窄共置边界：maximize/restore、maximized state 与 user-close 是三项独立登记、独立删除的 Native SDK 0.8.0 缺口，只因共享同一 startup HWND 生命周期而留在一个文件中，并分别暴露 `toggleMaximize`、`state` 与 `userClose`，不提供内部 action enum/facade。Windows 平台子文件独占 `IsZoomed`、`ShowWindow`、`PostMessageW(WM_CLOSE)` 及其创建期 HWND 绑定；非 Windows 不发布 Renderer controls。`minimize` 已有正式 Runtime API，必须由 `app.zig` 直接调用 `Runtime.minimizeWindow`，不得进入兼容层。Bridge 的 document generation 校验仍由既有 Host window-chrome command 边界完成，按钮兼容能力不持有 Bridge DTO 或 generation。

Windows startup identity 不是独立 capability。Desktop Host 在进入 Native SDK runner 前为当前 UI 线程武装 CBT 创建 hook，并在 `app.start` 入口立即收口；该区间必须恰好产生一个无 parent 的 top-level HWND，随后还要通过 root、owner、thread 与 process 校验，零个或多个候选一律 fail closed。该机制不读取标题、焦点、前台窗口、`GWLP_USERDATA` 或 `PlatformServices.context`，也不解释 Native SDK 私有类型。显式退出不属于兼容层：确认对话框与主窗口关闭使用 Native SDK Runtime API，由 Runtime 维护窗口/View 状态并驱动正常 shutdown。

整个 Host command 边界只接受绑定当前 document generation 的 `minimize | toggle_maximize | close` 固定 enum，不接受任意 action、window id、platform、活动窗口猜测或独立 state query；按钮 seam 只发布按钮呈现所需的 `rendererControls` 与 `maximized` 真值，不形成通用 Desktop Interface、Native SDK adapter、第二窗口 owner 或任意 action facade。Native SDK Runtime 对应能力经目标平台验收可用后，必须逐项原位替换：先移除对应按钮兼容 action/state，再删除不再需要的 HWND 绑定、低层调用、allowlist 与专用验证。

Renderer 的 `components/ui/WindowTitlebar.tsx` 绘制产品 header，并通过 portal 在 document root 只声明一个 `data-metawork-window-drag` marker；`components/ui/WindowControls.tsx` 绘制带固定 `data-metawork-window-control` 语义的按钮，不注册 native handler 或调用 transport。`frontend/src/bridge/window-chrome.ts` 是 browser-side Bridge boundary：它有界镜像 candidate/交互排除区、转换 control intent、runtime decode Host geometry/capability/state，并写入 CSS variables/document dataset；document attach 只 `connect` 一次，Native SDK `window.zero.on("resize")` 与 DOM observer 通过 latest-only scheduler 同步当前 generation，失败不清除仍有效的 controls/session。产品 React 代码不得直接调用 `window.zero`，不得维护平台名或窗口真实状态。已删除的 `app/useWindowChrome.ts` 与 `platform/window-chrome.ts` 不得恢复。

`account.zig`、`bridge.zig`、`workbench.zig` 和 `agent.zig` 是小型公开入口，只显式暴露实际消费者需要的类型、函数或窄 namespace。内部文件不通过 `usingnamespace` 或无边界 barrel 重新泄漏。

### `account/`

- `runtime.zig` 是 Account 长生命周期 owner，拥有状态机实例、private/public candidate catalog、credential、attempt、mailbox/effect queue、平台恢复状态、自动选择与 continuation；它不导入 Workbench，跨 owner 提交仍由 App coordinator 协调；
- `state.zig` 拥有 Account 状态机、attempt/generation 与 prepare/admit/commit；
- `oauth.zig`、`loopback.zig`、`login_attempt.zig` 和 `network_attempt.zig` 拥有登录网络链路；
- `metask_client.zig` 与 `catalog.zig` 消费锁定的 Metask production contract；
- `app.zon` 单一拥有 development 产品 Bundle ID；`product_identity.zig` 派生该值及 macOS 数据目录与 Keychain service，不定义或统一 Windows storage；
- `credential_store.zig` 独立拥有 macOS 双 family slot、固定 `manifest.json` schema 与原子提交语义；
- `scripts/cleanup-legacy-macos-account.mjs` 是 Account-owned、只由开发者显式执行的一次性 legacy maintenance 入口；签名 setup 不拥有或删除 Account credential；
- `windows_store.zig` 拥有 Windows 单 refresh token 与无版本、无 secret `account.json` 状态；不读取 macOS manifest，也不持久化 access token 或 Provider API Key；
- `platform.zig` 是当前 Account 平台实现中唯一导入 Native SDK 的过渡边界，分别适配 macOS 与 Windows 的 credential、URL、timer 与持久化能力；它仍让 Application owner 持有原始 `PlatformServices`，属于 [验证规范](validation.md#native-sdk-能力路径)登记的架构缺口，不是获准兼容 seam，也不得增加新的底层能力或消费者；
- `credentials.zig` 管理 execution credential ownership/rotation。

Account 与 Workbench 是同级 owner，只通过纯 `account/contract.zig` 和 App coordinator 主线程提交链协作。Bridge 只消费脱敏 view/command contract，不导入 Account Runtime。App coordinator 可以持有两个 owner 的实例引用以协调提交，但不得持有 Account catalog、credential、attempt、mailbox 或 continuation 状态。

### `bridge/`

- `dispatcher.zig` 统一拥有 handler registry、callback ingress、authority、payload decode、Workspace grant 与 `*Workbench` command 边界；
- `commands.zig` 定义完整 Bridge identity/revision 和 command catalog；
- `policy.zig` 定义 release/development origin、command 与 builtin policy；
- `handlers.zig` 只定义 bounded wire DTO 和解析；
- `product_delivery.zig` 是 connection generation、revision retry/timer、snapshot identity 和 owned transport storage 的唯一 owner；
- `revision_delivery.zig` 与 `snapshot_delivery.zig` 是 `ProductDelivery` 内部状态，不形成第二个公开 transport；
- `callback_gate.zig` 管理同步 Native callback ingress stop/quiescence；
- `workspace_grant.zig` 管理绑定 window/source 的一次性 Renderer capability，不是持久 Workspace registry。

Bridge handler 不能绕过 Workbench 操作 AgentCore handle。automation 只能驱动和观察真实 `ProductDelivery`，不得注册测试专用 handler 或平行 event/ACK/object 协议。

### `frontend/src/features/composer/`

`slash.ts` 是 Renderer-owned Command identifier、Slash Resolver、Text/Skill draft 和 typed Run input 转换的唯一纯语义模块；它只消费 Bridge catalog projection，不读取 Skill source。`SlashMenu.tsx` 拥有 context-aware listbox 展示，`ComposerFooter.tsx` 拥有输入焦点、键盘、IME、Skill identity 与 positional argument 交互；真正的产品动作仍由 `app/App.tsx` action controller 转换到现有本地导航或具体 typed Bridge command。`drafts.ts` 与 `useTaskDrafts.ts` 只持有 Renderer session-scoped tagged draft，不形成产品 history。禁止在这些模块中新增 Skill loader、raw slash Bridge payload、通用 `slash.execute` 或绕过领域 owner 的 command 数据面。

### `frontend/src/features/skills/`

`SkillsPage.tsx` 是 MetaWork 用户 Skill catalog 的只读一级视图，拥有搜索、catalog 状态、bounded issue 与空状态展示。它只消费 Bridge 已解码的 Workbench 顶层 canonical projection，并由 `app/App.tsx` 发起 `skills.refreshCatalog`；不得读取目录或 Skill body、依赖 selected Workspace、推断 source、持有 policy，或增加安装、编辑、启用/禁用路径。

### `frontend/src/features/mcp/`

`McpPage.tsx` 是具有稳定左栏入口的 MCP 服务状态与工具目录一级视图，拥有搜索、行动优先分组、空/不可用状态和详情 drawer。它只消费 Bridge 已严格解码并清洗的顶层 `mcp` projection；不得读取 MCP 配置、AgentCore handle、schema、credential 或 raw diagnostic，不得直接调用 AgentCore，也不得在没有 typed Workbench command 时增加服务、认证、刷新、启停、删除、工具选择或 marketplace 动作。Host 可以发布 ready/degraded 只读目录，但这不代表 Renderer 管理 capability 已开放。

### `frontend/src/features/scheduled-tasks/`

`ScheduledTasksPage.tsx` 是与 Skill 中心同级的持久自动化管理视图，拥有搜索、Text 建议模板、状态分区、连续列表、真实 Task/occurrence 链接与 detail/editor drawer；任务内容只编辑 Text instruction，不读取任何 Skill catalog 或持有 Skill 配置。recurrence 的本地输入与确认摘要留在该 feature，但 Host snapshot 和 typed mutation result 始终是产品真相。该目录不得使用 Renderer timer 触发 Run、用浏览器存储持久化 Scheduled Task、直接调用 AgentCore，或复制 Task timeline。

### `workbench/` 与 `agent/`

`workbench/projection.zig` 当前拥有 Workspace current catalog、Task pinned catalog、typed Text/Skill admission 与 history、Workspace/Scheduled Task/Task/Run 产品状态、Task 唯一 active operation、stable Run/compact record、executor worker reference、write-once terminal publication 和 bounded snapshot writer。Manual compact 是 append-only Task maintenance history，不复用 Run identity。`workbench/task_persistence.zig` 拥有 schema 1 的无 secret Workspace/Task history codec、严格恢复校验、16 MiB 上限、进程级单写锁与同目录原子替换；当前文件为 `workbench-history.json`，旧 `workbench-state.json` 按 pre-release hard cut 忽略且不迁移。`workbench/mcp_configuration.zig` 拥有 `<MetaWork data dir>/mcp/registry.json` schema 1 的 bounded strict codec、稳定 server/namespace identity、desired mutation、fresh credential locator 引用差分、single-writer atomic commit 和基于 durable generation 的 journal recovery；它不保存 credential 原文、不解析 AgentCore catalog，也不形成新的 product owner。Workbench 的 current MCP projection 仍来自 effective startup preparation/activation，desired registry 只通过内部 management port 管理并统一要求重启应用。Desktop Host composition role 只打开 data root 并注入 load/commit/platform capability，Session/Conversation 不进入这些文件。`workbench/automatic_workspace_allocator.zig` 拥有 Desktop Host-opened automatic root capability、相对随机子目录分配、canonical containment 与发布前空目录回滚；它不扫描旧目录、不恢复 Task，也不递归删除目录。`workbench/scheduled_tasks.zig` 拥有 bounded definition/occurrence storage、结构化 recurrence、跨恢复 planned-time identity 和纯状态转换；`workbench/scheduled_task_persistence.zig` 拥有无 secret codec、candidate commit、恢复校验和 schema revision。`workbench/skill_package.zig` 拥有本地 Skill 目录与 ZIP 包的路径/资源上限预检、regular-bytes-only staging、内容摘要和 canonical `.skill` 导出，不执行包内容或访问网络；`workbench/skill_management.zig` 拥有独立 install identity、personal/project inventory、管理状态、未完成文件事务恢复事实和 schema 1 无 secret 原子持久化。它们都属于 Workbench owner，不是第二个执行器或 AgentCore scheduler。`workbench/executor.zig` 独占 catalog/Run/compact 与显式 MCP refresh 共用的单一队列、workers、admission 和 shutdown。

`app/mcp_platform.zig` 是系统 credential service、stdio process capability 与 Streamable HTTP mechanics 的 App composition seam；它只把惰性、opaque transport owner 注入 Agent，不解析 MCP JSON-RPC 或复制协商。`agent/catalog.zig` 拥有 AgentCore Skill catalog descriptor 的即时解码、MetaWork-owned 安全投影、opaque handle lease 与 root/home/epoch 绑定；raw handle、scope、物理来源和 policy 不离开 Agent。`agent/mcp_connector.zig` 是 Host transport capability 到官方 `McpConnectorV1` 的唯一映射点，只拥有 callback/status、取消借用、response ownership、bounded secret guard、transport owner 与连接引用，不解析 MCP JSON 或协商协议；`agent/mcp_stdio.zig` 以显式 argv/cwd/environment capability 提供 bounded 子进程与 pipe 生命周期，stderr 只做固定缓冲 drain 和清零，不形成诊断数据面；`agent/mcp_http.zig` 只持有 opaque preauthorized endpoint capability、bounded session token 与连接状态，credential/header/HTTP mechanics 留在 capability owner；`agent/mcp_runtime.zig` 以一次性 `McpRuntimeInput` 线性接管 transport owner、adapter、official server descriptor、稳定 binding identity 与 allowlist；`agent/mcp_catalog.zig` 只经官方 decoder 复制 bounded catalog authority，并原子构造 Runtime-bound selection 与 typed activation health。`agent/session.zig` 串行化 MCP refresh、立即 generation invalidation、activation、Session create/idle replacement 与 shutdown，并继续拥有 AgentCore Runtime/Session、Conversation、typed Run/compact、callback quiescence 和 immutable terminal result。`event_sink.zig` 与 `event_pump.zig` 管理 borrowed event 深拷贝、容量和通知。Agent 不接收 Scheduler capability，也不反向 enqueue Workbench。

`app/mcp_platform.zig` 对 transport-facing credential bytes 做最终 fail-closed 校验，并按 Content-Type 有界读取 JSON 或增量剥离 SSE framing；它不解析 JSON-RPC identity/semantics。`agent/mcp_connector.zig` 的公开 runtime limits 经 App 注入 Workbench preparation，确保 `eligible` server 可直接构造正式 connector。

正式允许的依赖方向固定为：

```text
main -> app
app  -> account, workbench, agent, bridge, automation, Native SDK
app  -> native_sdk_compat
bridge -> workbench, account contract, Native SDK
workbench -> agent, account contract
agent -> Metask AgentCore bundle SDK
account -> account contract
```

`bridge -> Native SDK` 只允许消费正式 Bridge transport contract，以及 transport authority 和窄 Host capability 调用所需的 data-only DTO/opaque identifier；它不允许 Bridge 持有 `PlatformServices`、具体平台实现、OS handle 或直接系统调用权。当前 `account/platform.zig -> Native SDK` 是验证规范登记的非合规例外，不属于允许依赖图，也不能作为新增依赖的先例。禁止 `agent -> workbench/bridge/app`、`workbench -> bridge`、`bridge -> Account runtime` 和任何产品模块反向依赖 Renderer。

## 6. 测试与构建资产

- 正式 Zig test graph 由 `build.zig` 注册，产品 module 与其测试使用相同依赖边界；
- `tests/agent/` 验证 Session/callback/quiescence，`tests/workbench/` 验证 Executor/admission/shutdown，`tests/integration/` 只保留跨边界竞态；
- `tests/support/` 的 fake 和 fixture 不得升级为产品 owner；
- `scripts/` 可以编排真实应用、Renderer runtime 和 artifact 校验，但不能建立测试专用产品协议；
- `build_support/agentcore_bundle.zig` 与 target lock 是正式信任边界；candidate probe 只使用临时 source-free SDK consumer；
- `app.zon`、Zig commands 和 TypeScript commands 的完整目录必须由集合等式测试保持一致；
- release artifact 必须继续证明 automation credential、origin 和证据 token 被裁掉。

## 7. 结构变更规则

- 先证明新的 owner 或不变量，再拆文件；不为目标树、行数或命名整齐创建空模块；
- 类型跟随拥有其不变量的模块，不建立 `models`、`common`、`helpers`、`services` 或 `managers` 垃圾桶；
- 同一事实只在一个 source of truth 定义，目录文档不复制完整产品或生命周期论证；
- 删除 owner 时同步删除 build graph、allowlist、测试入口和文档引用，不把废弃实现移动到归档目录；
- 目录调整必须保持 Bridge contract、lifecycle、event pump、snapshot、release isolation 和真实 vertical path 的对应验证；
- 不增加 Native SDK adapter、AgentCore facade、平行 Renderer、平行协议或 source dependency fallback。

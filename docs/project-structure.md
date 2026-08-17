# MetaWork 工程结构与所有权

> 状态：描述 active tree 的当前结构与可执行边界；不维护目标目录草案或迁移计划

## 1. 文档职责

本文只回答三个问题：代码现在放在哪里、每个目录拥有什么、依赖可以朝哪个方向流动。

- 产品行为以 [产品需求](requirements.md) 为准；
- 系统职责与安全边界以 [高层架构](architecture.md) 为准；
- Product 内部 owner、事务与恢复以 [Product 内部架构](product-architecture.md) 为准；
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
│       ├── components/ui/ # Foundation UI primitive 与 declarative window controls
│       ├── components/ai/ # AI UI presentation primitive；不拥有 MetaWork 产品语义
│       ├── i18n/          # message catalog、formatter 与 locale runtime
│       └── platform/      # Renderer-only 本地偏好；不得包含原生窗口能力
├── src/
│   ├── main.zig           # 进程入口
│   ├── app.zig            # Application composition root；App vtable、装配、run 与顶层生命周期
│   ├── app/               # Application 的具名适配、resolver、store 与用例编排实现
│   │   ├── account_coordinator.zig   # Account/Workbench 跨 owner 提交编排
│   │   ├── agent_event_coordinator.zig # Agent event-ready wake 合并与主线程 drain 触发
│   │   ├── automation.zig            # automation authority 与启动覆盖适配
│   │   ├── frontend.zig              # frontend source 与 asset root resolver
│   │   ├── mcp_platform.zig          # MCP credential/transport 平台 capability
│   │   ├── mcp_bridge_adapter.zig    # Renderer Bridge MCP typed port 到 Application coordinator 的窄适配
│   │   ├── mcp_management_coordinator.zig # MCP 测试连接、legacy 审批、首次 OAuth 与安全采集编排
│   │   ├── mcp_startup.zig           # MCP 启动恢复与 preparation 编排
│   │   ├── paths.zig                 # data directory 与 canonical home resolver
│   │   ├── platform.zig              # DispatcherPlatform vtable 与 Native SDK 引用
│   │   ├── stores.zig                # Application-created stores 与 restored bytes 生命周期
│   │   └── window.zig                # window/tray/dialog/notification 与 compat capability
│   ├── product_identity.zig # 从 app.zon 派生 development identity 与 macOS namespace
│   ├── native_sdk_compat/ # 按已登记 capability 隔离的 Application 兼容实现
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
│   ├── agent/             # catalog、Session、event pump、callback 与 MCP ownership
│   │   └── mcp/           # connector、stdio/http transport、runtime 与 catalog
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

| Boundary / role | 唯一职责                                                                                                                      | 不拥有                                                                          |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| Application     | Native SDK composition、窄 capability 注入、平台资源、bootstrap resolver、store 生命周期、跨 owner 用例编排与顶层生命周期顺序 | owner 领域状态与 policy、Bridge transport、AgentCore 协议、Renderer 实现        |
| Account         | Runtime、OAuth/catalog 状态、credential、attempt/effect/mailbox、恢复、脱敏 Account view、ExecutionConfig transfer            | Workbench Task、Renderer 状态、AgentCore Runtime                                |
| Workbench       | Workspace/Task/Run 产品状态、Executor、admission、terminal product record、snapshot projection                                | AgentCore raw protocol、Native WebView、Account secret                          |
| Agent           | AgentCore integration、MetaWork Runtime/Session/Conversation、callback、event pump、Run terminal facts                     | 产品队列、Task 历史、Bridge transport、AgentCore 内部实现                        |
| Bridge          | command authority、payload decode、Workspace grant、ProductDelivery connection/revision/snapshot transport                    | 产品策略真相、AgentCore handle、Account runtime                                 |
| Renderer        | snapshot 消费、产品 WebUI 交互、纯 UI 状态与本地草稿、`frontend/src/bridge/` 合同实现层（transport 适配与 runtime decode）    | 原生窗口 owner、平台真实状态、安全决策、secret、AgentCore raw event、产品状态机 |

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

`frontend/src/bridge/` 归 Renderer 模块，是其唯一的合同实现层（browser-side Bridge）：它写入 CSS variables/document dataset 属于 Renderer 呈现职责；runtime decode 的 fail-closed 规则仍由合同约束，不因归属放松。Renderer Bridge 的 identity、revision、command、event、snapshot 与兼容策略只由 [Renderer Bridge 合同](renderer-bridge-contract.md)定义。React component 不得直接访问 `window.zero`、拼 wire payload 或解析 AgentCore raw JSON。

### `workbench/` 与 `features/`

`workbench/` 只保存 canonical Host snapshot、selector 和无副作用派生状态。Workspace/Task 生命周期仍由 Host 决定；Renderer 只持有选择、折叠、输入草稿等纯 UI 状态。

`features/` 按用户可见能力分区。feature 通过 `workbench/` selector 消费产品状态，不读取其他 feature 的内部文件。Agent 工作面的 projection、布局和交互编排归 `features/agent-surface/`；Approval、Composer、Task list、Workspace path selection、Search 等独立语义仍保留在各自 feature。真正无业务语义的 Foundation primitive 进入 `components/ui/`，面向 AI 对话的可复用 presentation primitive 进入 `components/ai/`。`components/ai/` 可以借鉴或 vendoring AI Elements 的源代码，但不得拥有 Task/Run/Workspace、Bridge command、capability gate 或 AgentCore 语义；这些由 `features/` 中的 Coding Agent product component 负责。

`components/ai/` 只能向下依赖 `components/ui/`、共享 renderer 工具和已锁定的通用前端依赖；AI 组件必须复用 Foundation UI 的交互原语与 Design Tokens，不得在自身目录重建 Button、Input、Popover 等基础控件，也不得反向导入 `features/`、`bridge/`、`workbench/` 或 `app/`。

### `frontend/src/features/agent-surface/`

`conversation-projection.ts` 将 Workbench 的 Task/Run/Tool/UI/Compact projection 整理为保留输入类型、redaction、活动数量和稳定顺序的可渲染模型；它不创建新的 Bridge 合同或事实来源。`AgentWorkSurface.tsx` 负责工作面布局、流式回复、滚动跟随、Tool/Attention/Compact 组合和现有 Composer 的布局，不拥有输入草稿、Run admission、retry policy 或 AgentCore 语义。旧 Timeline 路径不得与该 feature 并存为第二条 active rendering path。

`features/settings/SettingsPage.tsx` 是覆盖 Workbench 内容区的长期 Settings surface，消费 Account projection 并通过 App action controller 提交账号与模型设置；它不拥有 Workspace registry、authority、Task 导航或 Host lifecycle。已有 Task 的 Workspace 只从 Task projection 推导，New task 只持有 `draftWorkspaceId`，Renderer 不保存 `activeWorkspaceId` 镜像。

`workbench/task-visibility.ts` 定义一个跨 Store、左栏与搜索复用的纯 projection 不变量：只有 owning Workspace 同时存在于 canonical snapshot 的 Task 才参与活动导航。它不拥有 Task 历史或 Workspace lifecycle；被移除 Workspace 的 Task 仍由 Host 保存。

## 5. Zig 结构

### `app.zig`、`app/` 与 module entrypoint

`main.zig` 只调用 `metawork_app`。架构边界统一称为 Application，代码组合类型保持 `App`。`app.zig` 是 composition root，只保留 Native SDK `App` vtable、装配顺序、`run()` 与唯一的顶层启动/关闭顺序；Application 拥有的具体实现进入 `app/`，不得把实现重新堆回 root。

`app/` 只接纳四类实现：平台适配、一次性 bootstrap resolver、Application 创建资源的生命周期，以及跨 owner 用例编排。适配按稳定资源类别分文件，编排按用例分文件；编排只安排 owner 调用顺序，不读取领域状态自行形成 policy。`agent/`、`workbench/`、`account/` 与 `bridge/` 不得反向导入 `app/`。

`app/platform.zig` 是唯一 `DispatcherPlatform` vtable 实现并持有 Native SDK runtime/services 引用；窗口系统行为委托给 `app/window.zig`。`app/window.zig` 拥有窗口、tray、notification、dialog 与两个已登记 compat capability，但不拥有 Bridge authority 或 Product policy。`app/paths.zig` 的 `Paths` 原位持有所有路径 buffer，只能按指针传递并由 `run()` 保持稳定地址。`app/stores.zig` 拥有 Application 创建的 store、单写锁与 restored bytes 生命周期。

`app/mcp_startup.zig` 负责启动期 registry load、credential transaction recovery 与 Workbench preparation 的线性编排；`app/mcp_platform.zig` 只适配 MCP 系统 credential、stdio 与 Streamable HTTP mechanics，不解析 MCP JSON-RPC 或复制协商，也不形成新的产品 owner。`app/mcp_management_coordinator.zig` 把 Workbench transaction seam 与 legacy 原生确认、系统浏览器、loopback、有界 OAuth worker，以及单一候选 Runtime 测试 worker 串成用例；测试 worker 只消费 canonical prepared target 并回写安全结果，不拥有正式 Runtime authority。coordinator 不拥有 registry、持久 operation、credential 或 OAuth policy。当前 Native SDK 缺少安全文本输入 Runtime capability，因此正式 platform binding 的 secret capture 必须保持 unavailable，不能扩展 Renderer credential bridge。

`native_sdk_compat/system_webview_drag_region.zig` 是 Application-owned 的有界 System WebView drag-region capability seam。它只拥有有界 region 校验、root 平台 binding 与 drag 调用编排；document generation 和 source-window authority 归 Bridge `Dispatcher`，不进入该 seam。只有 `app/window.zig` 可以组装它；不拥有按钮 action、按钮 capability、窗口最大化状态或 resize。Windows 消费共享 startup root binding；document `connect/disconnect` 只标记 Renderer 会话是否附着，`sync` 只事务式替换 region，不能安装、重装或销毁平台资源。`beginDrag` 不信任 Renderer 坐标授予执行权，而是重新观察逻辑主鼠标键、实际 OS 光标、光标下 HWND 的 root identity、root native hit 与当前 DPI，并只在实际点命中最新 candidate-minus-exclusions 时通过 `ReleaseCapture`/`PostMessageW(WM_NCLBUTTONDOWN, HTCAPTION)` 进入系统 move loop。它不递归依赖 Chromium 跨进程 child HWND，也不保留旧 root `WM_NCHITTEST` subclass 路径。`system_webview_drag_region/macos.zig` 只在 live pointer event 内调用 SDK 已有 `startWindowDrag` 原语并保留系统交通灯。System WebView 隐藏标题栏的 resize hit surface 仍归 Native SDK，不由该 seam 模拟；平台文件不创建覆盖 WebView 的辅助窗口。

`native_sdk_compat/system_webview_window_controls.zig` 是 Application-owned 的窄共置边界：maximize/restore、maximized state 与 user-close 是三项独立登记、独立删除的 Native SDK 0.8.0 缺口，只因共享同一 startup HWND 生命周期而留在一个文件中，并分别暴露 `toggleMaximize`、`state` 与 `userClose`，不提供内部 action enum/facade。Windows 平台子文件消费共享 startup root binding，并独占 `IsZoomed`、`ShowWindow` 与 `PostMessageW(WM_CLOSE)`；它不安装第二条创建 hook。非 Windows 不发布 Renderer controls。`minimize` 已有正式 Runtime API，必须由 `app/window.zig` 直接调用 `Runtime.minimizeWindow`，不得进入兼容层。Bridge 的 document generation 校验仍由既有 window-chrome command 边界完成，按钮兼容能力不持有 Bridge DTO 或 generation。

Windows startup identity 不是独立 capability。`system_webview_startup_window` 是私有共享 lifecycle plumbing：Application 在进入 Native SDK runner 前只为当前 UI 线程武装一条 CBT 创建 hook，并在 `App.start` 入口立即收口；该区间必须恰好产生一个无 parent 的 top-level HWND，随后还要通过 root、owner、thread 与 process 校验，零个或多个候选一律 fail closed。结果是一个由 `app/window.zig` 注入 drag 与 controls seam 的 opaque binding；两条 seam 不得各自捕获或发现窗口。该机制不读取标题、焦点、前台窗口、`GWLP_USERDATA` 或 `PlatformServices.context`，也不解释 Native SDK 私有类型。显式退出不属于兼容层：确认对话框与主窗口关闭使用 Native SDK Runtime API，由 Runtime 维护窗口/View 状态并驱动正常 shutdown。

整个 Host command 边界只接受绑定当前 document generation 的 `minimize | toggle_maximize | close` 固定 enum，不接受任意 action、window id、platform、活动窗口猜测或独立 state query；按钮 seam 只发布按钮呈现所需的 `rendererControls` 与 `maximized` 真值，不形成通用 Desktop Interface、Native SDK adapter、第二窗口 owner 或任意 action facade。Native SDK Runtime 对应能力经目标平台验收可用后，必须逐项原位替换：先移除对应按钮兼容 action/state，再删除不再需要的 HWND 绑定、低层调用、allowlist 与专用验证。

Renderer 的 `components/ui/WindowTitlebar.tsx` 绘制产品 header，并通过 portal 在 document root 只声明一个 `data-metawork-window-drag` marker；`components/ui/WindowControls.tsx` 绘制带固定 `data-metawork-window-control` 语义的按钮，不注册 native handler 或调用 transport。`frontend/src/bridge/window-chrome.ts` 是 browser-side Bridge boundary：它有界镜像 candidate/交互排除区、转换 control intent、runtime decode Host geometry/capability/state，并写入 CSS variables/document dataset；document attach 只 `connect` 一次，Native SDK `window.zero.on("resize")` 与 DOM observer 通过 latest-only scheduler 同步当前 generation，失败不清除仍有效的 controls/session。产品 React 代码不得直接调用 `window.zero`，不得维护平台名或窗口真实状态。已删除的 `app/useWindowChrome.ts` 与 `platform/window-chrome.ts` 不得恢复。

`account.zig`、`bridge.zig`、`workbench.zig` 和 `agent.zig` 是小型公开入口，只显式暴露实际消费者需要的类型、函数或窄 namespace。内部文件不通过 `usingnamespace` 或无边界 barrel 重新泄漏。

### `account/`

- `runtime.zig` 是 Account 长生命周期 owner，拥有状态机实例、private/public candidate catalog、credential、attempt、mailbox/effect queue、平台恢复状态、自动选择与 continuation；它不导入 Workbench，跨 owner 提交仍由 Application coordinator 协调；
- `state.zig` 拥有 Account 状态机、attempt/generation 与 prepare/admit/commit；
- `oauth.zig`、`loopback.zig`、`login_attempt.zig` 和 `network_attempt.zig` 拥有登录网络链路；
- `metask_client.zig` 与 `catalog.zig` 消费锁定的 Metask production contract；
- `app.zon` 单一拥有 development 产品 Bundle ID；`product_identity.zig` 派生该值及 macOS 数据目录；
- `credential_store.zig` 独立拥有跨平台 Account persistence 合同：secure store 中唯一的 refresh token，以及原子、无 secret 的 `preferences.json`；production 与 automation service 在编译期隔离；
- `platform.zig` 是当前 Account 平台实现中唯一导入 Native SDK 的过渡边界，以同一 backend 适配各平台 credential、URL、timer 与 preference 持久化能力；它仍让 Product owner 持有原始 `PlatformServices`，属于 [验证规范](validation.md#native-sdk-能力路径)登记的架构缺口，不是获准兼容 seam，也不得增加新的底层能力或消费者；
- `credentials.zig` 管理 execution credential ownership/rotation。

Account 与 Workbench 是同级 owner，只通过纯 `account/contract.zig` 和 Application coordinator 主线程提交链协作。Bridge 只消费脱敏 view/command contract，不导入 Account Runtime。Application coordinator 可以持有两个 owner 的实例引用以协调提交，但不得持有 Account catalog、credential、attempt、mailbox 或 continuation 状态。

### `bridge/`

- `dispatcher.zig` 统一拥有 handler registry、callback ingress、authority、payload decode、Workspace grant 与 `*Workbench` command 边界；
- `commands.zig` 定义完整 Bridge identity/revision 和 command catalog；
- `policy.zig` 定义 release/development origin、command 与 builtin policy；
- `handlers.zig` 只定义 bounded wire DTO 和解析；
- `product_delivery.zig` 是 connection generation、revision retry/timer、snapshot identity 和 owned transport storage 的唯一 owner；
- `revision_delivery.zig` 与 `snapshot_delivery.zig` 是 `ProductDelivery` 内部状态，不形成第二个公开 transport；
- `callback_gate.zig` 管理同步 Native callback ingress stop/quiescence；
- `workspace_grant.zig` 管理绑定 window/source 的一次性 Renderer capability，不是持久 Workspace registry；
- `skill_grant.zig` 管理绑定 window/source 的一次性 Skill capability，与 workspace_grant 同构，不是持久 Skill registry。

Bridge handler 不能绕过 Workbench 操作 AgentCore handle。automation 只能驱动和观察真实 `ProductDelivery`，不得注册测试专用 handler 或平行 event/ACK/object 协议。

### `frontend/src/features/composer/`

`slash.ts` 是 Renderer-owned Command identifier、Slash Resolver、Text/Skill draft 和 typed Run input 转换的唯一纯语义模块；它只消费 Bridge catalog projection，不读取 Skill source。`SlashMenu.tsx` 拥有 context-aware listbox 展示，`ComposerFooter.tsx` 拥有输入焦点、键盘、IME、Skill identity 与 positional argument 交互；真正的产品动作仍由 `app/App.tsx` action controller 转换到现有本地导航或具体 typed Bridge command。`drafts.ts` 与 `useTaskDrafts.ts` 只持有 Renderer session-scoped tagged draft，不形成产品 history。禁止在这些模块中新增 Skill loader、raw slash Bridge payload、通用 `slash.execute` 或绕过领域 owner 的 command 数据面。

### `frontend/src/features/skills/`

`SkillsPage.tsx` 是 MetaWork 用户 Skill catalog 的只读一级视图，拥有搜索、catalog 状态、bounded issue 与空状态展示。它只消费 Bridge 已解码的 Workbench 顶层 canonical projection，并由 `app/App.tsx` 发起 `skills.refreshCatalog`；不得读取目录或 Skill body、依赖 selected Workspace、推断 source、持有 policy，或增加安装、编辑、启用/禁用路径。

### `frontend/src/features/mcp/`

`McpPage.tsx` 是具有稳定左栏入口的 MCP 全局管理视图，拥有搜索、行动优先分组、空/不可用/恢复状态、transport-discriminated Add/Edit、detail drawer、即时测试、正式 Runtime refresh、启停/删除和逐工具 allowlist。Add/Edit 的显式提交就是连接授权，正常流程不再追加一次自我审核；legacy unapproved 配置才显示连接动作。页面只消费 Bridge 已严格解码并清洗的顶层 `mcp` projection，并通过 `frontend/src/bridge` 的 field-level typed command 提交 intent；它可以查看和预填 Host 发布的完整非敏感 typed connection，但不得维护 registry 镜像、直接调用 AgentCore 或读取 environment/header value、credential、schema、Runtime fingerprint 与 raw diagnostic。marketplace/trust 与 Task-level override 不进入该目录。

### `frontend/src/features/scheduled-tasks/`

`ScheduledTasksPage.tsx` 是与 Skill 中心同级的持久自动化管理视图，拥有搜索、Text 建议模板、状态分区、连续列表、真实 Task/occurrence 链接与 detail/editor drawer；任务内容只编辑 Text instruction，不读取任何 Skill catalog 或持有 Skill 配置。recurrence 的本地输入与确认摘要留在该 feature，但 Host snapshot 和 typed mutation result 始终是产品真相。该目录不得使用 Renderer timer 触发 Run、用浏览器存储持久化 Scheduled Task、直接调用 AgentCore，或复制 Task timeline。

### `workbench/` 与 `agent/`

`workbench/task_persistence.zig` 的当前 hard-cut store 是 `workbench-history.store`：固定 frame header、header/payload checksum、record type、bounded JSON payload 与 Task failure record 组成唯一 canonical history；不读取、不迁移、不双写任何旧 envelope，也不引入迁移版本层。Workspace/Task frame 可独立恢复，无法信任 Task identity 时只进入 `degraded`，可确认的坏 Task 以同一 store 的 failure record 留痕，不关闭新 Task admission；Automatic Workspace 仅在唯一 Task 恢复后占用容量。

`workbench/mcp_configuration.zig` 的 static locator 只在 Replace 前后 command + ordered argv + cwd 或 endpoint 与 auth mode 相同时按同名 slot 沿用；其余 locator 仍由既有全 registry 引用差分和 credential journal 退休。Desired enabled 可独立于 credential readiness 保存，Runtime preparation 与 Admission 继续负责 fail-closed eligibility。

`workbench/projection.zig` 当前拥有 Workspace current catalog、Task pinned catalog、typed Text/Skill admission 与 history、Workspace/Scheduled Task/Task/Run 产品状态、Task 唯一 active operation、stable Run/compact/recovery record、executor worker reference、Agent event 消费与固定双 drain 终态屏障、write-once terminal publication 和 bounded snapshot writer。它直接接收自己的 `std.Io`，不得借 `agent.Runtime` 获取 Executor、文件、目录或随机数能力。Manual compact 是 append-only Task maintenance history，不复用 Run identity；Conversation restore 只重建 runtime attachment，不创建历史事件。`workbench/task_persistence.zig` 拥有 hard-cut (无迁移版本层) 的无 secret Workspace/Task history record codec、header/payload checksum、Task failure record、严格恢复校验、16 MiB 上限、进程级单写锁与同目录原子替换；当前文件为 `workbench-history.store`，旧 JSON envelope 不读取、不迁移、不双写。Workspace/Task frame 逐条隔离，无法信任 Task identity 时只记录 degraded health；可确认的坏 Task 以同一 canonical store 中的 failure record 持久化，Automatic Workspace 仅在唯一 Task 恢复后占用容量。`workbench/mcp_configuration.zig` 拥有 `<MetaWork data dir>/mcp/registry.json` schema 2 的 bounded strict codec、schema 1 disabled+unapproved migration、稳定 server/namespace identity、connection approval、OAuth 非 secret 状态与顶层单一 `oauth_operation`、Desired Registry mutation、全 registry credential locator 引用差分、single-writer atomic commit 和基于 durable generation 的 credential journal recovery；OAuth registration 精确保存 exact issuer、client identity、token endpoint auth method 与 client-credential revision，DCR operation marker 保存完整 consent draft，返回的 issued identity 再生成最终 consent fingerprint。STDIO 与 Streamable HTTP 分别使用 transport-specific create/update input，static environment/header 以 `{ name, nullable credential_ref }` secret slot 持久化，缺失 locator 是可修复的 `needs_authentication` 状态而不是明文占位。Host-only secure capture 消费并清零临时 secret、生成 fresh locator，并仍通过同一 credential journal 提交；该输入不从 `workbench.zig` 导出，也没有 Renderer/Bridge command。operation marker 的同文件状态提交不推进 desired generation，遗留 marker 则通过同一 journal 生成 `reauth_required` target 并退休旧 token locator。Refresh begin 在 marker commit 前预构建 reduced Admission 与 detached network binding；refresh completion 从当前 canonical generation 重建 fresh token target，先准备 Runtime snapshot replacement 与恢复 Admission，再按 credential journal 提交并 no-fail 安装。Admission 的唯一构造路径同时解释 active marker 与 OAuth `ready/reauth_required`，所以无关 server mutation 不会重新授予正在操作的 server。`app/mcp_oauth.zig` 复用 Account 的无产品语义 PKCE/loopback primitive，拥有无 credential discovery、metadata 校验、系统 HTTP deadline/cancel、authorization URL、RFC 9207 callback 校验、metadata-advertised DCR、code exchange 与 single-shot refresh effect；窄 `StatePort` 先从 Workbench 取得 approved endpoint/consent binding，DCR 与 code exchange 只有在 durable begin 返回后才发送 POST，返回结果只能 complete、clear 或进入 uncertain recovery。POST 的 transport/响应不确定性只返回 outcome unknown，不自行重放或改写产品状态。`workbench/testdata/mcp-http-endpoints.json` 是由该 owner 定义、Host 与 Renderer 测试共同消费的 endpoint acceptance corpus，不进入产品构建数据面。MCP configuration 不保存 credential 原文、不解析 AgentCore catalog，也不形成新的 product owner。Workbench 的 MCP control plane 额外持有与当前 Agent Runtime 同寿命的 immutable Runtime Manifest、Agent Activation lease 与 `ready(optional selection) | blocked(reason)` Admission Authority；Manifest 只记录 loaded descriptor fingerprint 或安全 absence proof，desired generation 只做持久化并发版本。field-level mutation、refresh、OAuth operation 与 Task admission 共用 Workbench 串行化边界，新 Task 不再直接读取 Activation current selection。Application 只打开 data root 并注入 load/commit/platform capability，Session/Conversation 不进入这些文件。`workbench/automatic_workspace_allocator.zig` 拥有 Application-opened automatic root capability、相对随机子目录分配、canonical containment 与发布前空目录回滚；它不扫描旧目录、不恢复 Task，也不递归删除目录。`workbench/scheduled_tasks.zig` 拥有 bounded definition/occurrence storage、结构化 recurrence、跨恢复 planned-time identity 和纯状态转换；`workbench/scheduled_task_persistence.zig` 拥有无 secret codec、candidate commit、恢复校验和 schema revision。`workbench/skill_package.zig` 拥有本地 Skill 目录与 ZIP 包的路径/资源上限预检、regular-bytes-only staging、内容摘要和 canonical `.skill` 导出，不执行包内容或访问网络；`workbench/skill_management.zig` 拥有独立 install identity、personal/project inventory、管理状态、未完成文件事务恢复事实和 schema 1 无 secret 原子持久化。它们都属于 Workbench owner，不是第二个执行器或 AgentCore scheduler。`workbench/executor.zig` 独占 catalog/Run/compact/restore 与显式 MCP refresh 共用的单一队列、workers、admission 和 shutdown。

`agent/checkpoint.zig` 是 checkpoint export、Session description、官方 limit ceiling 和 operation-specific status disposition 的唯一 AgentCore SDK 边界；`agent/checkpoint_restore.zig` 独占 verified source adapter、restore expectation/report 对账和 restore-specific status disposition。`agent/session.zig` 只在锁内预留 Session slot 与维护 restore in-flight fence，流式 ABI 调用在锁外执行。两者不解析或复制 AgentCore 私有 blob 格式。

`workbench/checkpoint_record.zig` 定义 durable `Record = blob + session + anchor`，严格分离 blob identity、最小 Session binding 与 Workbench terminal/binding 锚点；`workbench/checkpoint_store.zig` 拥有不可变 per-Task blob 布局、进程级单写锁、bounded no-follow scan、hash/size 校验、原子提交和可信启动孤儿清理；`task_persistence.zig` 只逐字段白名单编码嵌套 record。`workbench/task_runtime.zig` 独占 `attached | detached` runtime resource union；`workbench/task_recovery.zig` 是 continuation/eligibility 的纯策略；`workbench/task_recovery_job.zig` 拥有 immutable prepared attempt、bounded executor job、verified source、Skill/MCP authority acquisition 与 typed completion。`workbench/projection.zig` 只做主线程 prepare/commit、optimistic revalidation、candidate attachment 安装和 snapshot projection，不在 snapshot 路径读取 checkpoint 文件。Application 只按既有 store 生命周期打开 `<MetaWork data dir>/workbench/checkpoints` 并注入 capability；Bridge、Renderer 与 Account 不依赖 checkpoint 模块。

`app/mcp_platform.zig` 是系统 credential service、stdio process capability 与 Streamable HTTP mechanics 的 Application composition seam；它只把惰性、opaque transport owner 注入 Agent，不解析 MCP JSON-RPC 或复制协商。OAuth HTTP owner 与 Application lookup registry 共同引用同一 auth slot；每次请求租借 immutable token snapshot，同 consent epoch 的 revision CAS 替换 slot，旧 snapshot 到最后一个 in-flight lease 释放后才清零。`app/mcp_oauth_coordinator.zig` 只拥有一个 earliest-expiry one-shot timer、一个可取消 refresh network job 和主线程 completion sequencing；它先调用 Workbench durable begin，再读取系统 credential 并启动 discovery/POST，结果回主线程后协调 snapshot/registry/Admission commit，shutdown 时先停 timer、cancel/join job 并收口 marker。它不保存 Desired Registry、不形成通用 scheduler。`agent/catalog.zig` 拥有 AgentCore Skill catalog descriptor 的即时解码、MetaWork-owned 安全投影、opaque handle lease 与 root/home/epoch 绑定；raw handle、scope、物理来源和 policy 不离开 Agent。`agent/mcp/connector.zig` 是 Application transport capability 到官方 `McpConnectorV1` 的唯一映射点，只拥有 callback/status、取消借用、response ownership、bounded secret guard、transport owner 与连接引用，不解析 MCP JSON 或协商协议；`agent/mcp/stdio.zig` 以显式 argv/cwd/environment capability 提供 bounded 子进程与 pipe 生命周期，stderr 只做固定缓冲 drain 和清零，不形成诊断数据面；`agent/mcp/http.zig` 只持有 opaque preauthorized endpoint capability、bounded session token 与连接状态，credential/header/HTTP mechanics 留在 capability owner；`agent/mcp/runtime.zig` 以一次性 `McpRuntimeInput` 线性接管 transport owner、adapter、official server descriptor、稳定 binding identity 与 allowlist；`agent/mcp/catalog.zig` 只经官方 decoder 复制 bounded catalog authority，并为 Workbench 构造 Runtime-bound owned selection 与 typed Activation health。`agent/session.zig` 串行化 MCP refresh、立即 catalog generation invalidation、selection validation、Session create/idle replacement 与 shutdown，并继续拥有 AgentCore Runtime/Session、Conversation、typed Run/compact、callback quiescence 和 immutable terminal result。Workbench Admission Authority 只借用 selection 完成同步 Session create，AgentCore 复制后不保留该指针；refresh/shutdown 前 Workbench 必须先释放 authority 与 Activation。`event_sink.zig` 与 `event_pump.zig` 管理 borrowed event 深拷贝、容量和通知。Agent 不接收 Scheduler capability，也不反向 enqueue Workbench。

`app/mcp_platform.zig` 对 transport-facing credential bytes 做最终 fail-closed 校验，并按 Content-Type 有界读取 JSON 或增量剥离 SSE framing；它不解析 JSON-RPC identity/semantics。`agent/mcp/connector.zig` 的公开 runtime limits 经 Application 注入 Workbench preparation，确保 `eligible` server 可直接构造正式 connector。

正式允许的依赖方向固定为：

```text
main -> app
app  -> account, workbench, agent, bridge, automation, Native SDK
app  -> native_sdk_compat
bridge -> workbench, account contract, Native SDK
workbench -> agent, account contract
agent -> Metask AgentCore bundle SDK
account -> account contract
automation -> bridge, account contract, Native SDK
```

`bridge -> Native SDK` 只允许消费正式 Bridge transport contract，以及 transport authority 和窄 Application capability 调用所需的 data-only DTO/opaque identifier；它不允许 Bridge 持有 `PlatformServices`、具体平台实现、OS handle 或直接系统调用权。`automation -> bridge` 只消费 policy 类型；`automation -> Native SDK` 只消费同级 Bridge policy contract 类型，同样不得持有 `PlatformServices`、平台实现或系统调用权。当前 `account/platform.zig -> Native SDK` 是验证规范登记的非合规例外，不属于允许依赖图，也不能作为新增依赖的先例。禁止 `agent -> workbench/bridge/app`、`workbench -> bridge`、`bridge -> Account runtime` 和任何产品模块反向依赖 Renderer。

## 6. 测试与构建资产

- 正式 Zig test graph 由 `build.zig` 注册，产品 module 与其测试使用相同依赖边界；
- `tests/agent/` 验证 Session/callback/quiescence，`tests/workbench/` 验证 Executor/admission/shutdown，`tests/integration/` 只保留跨边界竞态；
- `tests/support/` 的 fake 和 fixture 不得升级为产品 owner；
- `scripts/` 可以编排真实应用、Renderer runtime 和 artifact 校验，但不能建立测试专用产品协议；
- 根 `package.json` 只保留 `dev`、`check`、`test`、`format`、`format:check`、`build:debug`、`build:release` 与 `package:macos` 八个工程入口，不登记内部步骤、单项测试、probe 或平台验收 harness；macOS `dev` 只使用显式选择的 Apple Development identity，`package:macos` 只使用唯一有效的 Developer ID Application identity 和钥匙串 `metawork-notary` profile，并要求 notarization `Accepted`、staple、Gatekeeper 与最终 ZIP 完整性全部通过；
- `scripts/*.test.mjs` 是默认 `npm test` 自动发现的长期回归；新增文件必须绑定当前可观察不变量，不得用该后缀保存一次性诊断；
- 平台验收 harness 只有在绑定当前能力缺口、真实失败模式和明确删除条件时才进入 active tree，并由验证规范直接引用；一次性 audit、仅为单次证据服务的截图生成器和问题定位 probe 在完成验收后删除，Git 历史负责保存一次性事实；
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

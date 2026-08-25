# MetaWork 工程结构与所有权

> 状态：描述 active tree 的当前结构与可执行边界；不维护目标目录草案或迁移计划

## 1. 文档职责

本文只回答三个问题：代码现在放在哪里、每个目录拥有什么、依赖可以朝哪个方向流动。

- 产品行为以 [产品需求](requirements.md) 为准；
- 系统职责与安全边界以 [高层架构](architecture.md) 为准；
- Product 内部 owner、事务与恢复以 [Product 内部架构](product-architecture.md) 为准；
- Account 内部状态、事务、提交与恢复以 [Account 内部架构](account-architecture.md) 为准；
- Renderer Bridge wire 与运输语义以 [Renderer Bridge 合同](renderer-bridge-contract.md) 为准；
- AgentCore 生命周期以 [AgentCore 集成契约](agentcore-integration.md) 为准；
- UI 行为以 [Workbench UI 设计](workbench-ui-design.md) 为准；
- 测试归属、验证状态与入口以 [验证规范](validation.md) 为准。

本文不预测尚不存在的文件，不为未来 capability 预建空目录，也不记录已经完成的迁移步骤。结构变化只有在真实职责或不变量形成后才进入本文。

## 2. 当前仓库地图

```text
metawork/
├── assets/
│   ├── brand/             # MetaWork 标志几何真源
│   └── icons/             # 用途资产、macOS Icon Composer 源与 Windows 平台交付产物
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
├── scripts/
│   └── native-sdk-compat/ # 不进入 executable 的窄发布 artifact 兼容 seam
├── src/
│   ├── main.zig           # 进程入口
│   ├── app.zig            # Application composition root；App vtable、装配、run 与顶层生命周期
│   ├── app/               # Application 的具名适配、resolver、store 与用例编排实现
│   │   ├── account_coordinator.zig   # Account/Workbench 跨 owner 提交编排
│   │   ├── account_platform_binding.zig # Account ports 的 Native SDK/文件系统绑定
│   │   ├── agent_event_coordinator.zig # Agent event-ready wake 合并与主线程 drain 触发
│   │   ├── automation.zig            # automation authority 与启动覆盖适配
│   │   ├── frontend.zig              # frontend source 与 asset root resolver
│   │   ├── mcp_platform.zig          # MCP credential/transport 平台 capability
│   │   ├── mcp_bridge_adapter.zig    # Renderer Bridge MCP typed port 到 Application coordinator 的窄适配
│   │   ├── mcp_management_coordinator.zig # MCP 测试连接、legacy 审批、首次 OAuth 与安全采集编排
│   │   ├── mcp_startup.zig           # MCP 启动恢复与 preparation 编排
│   │   ├── metask_http_transport.zig # Account Metask transport 的 concrete HTTP effect
│   │   ├── oauth_loopback_transport.zig # OAuth loopback listener/socket/HTTP pump
│   │   ├── paths.zig                 # data directory 与 canonical home resolver
│   │   ├── platform.zig              # DispatcherPlatform vtable 与 Native SDK 引用
│   │   ├── stores.zig                # Application-created stores 与 restored bytes 生命周期
│   │   └── window.zig                # window/tray/dialog/notification 与 compat capability
│   ├── product_identity.zig # 从 app.zon 派生 development identity 与 macOS namespace
│   ├── native_sdk_compat/ # 按已登记 capability 隔离的 Application 兼容实现
│   │   ├── secure_input.zig # 有界安全文本输入 contract、线程与清零纪律
│   │   ├── secure_input/
│   │       ├── windows.zig # startup HWND-owned 密码对话框与严格 UTF-16 转换
│   │       └── macos.zig   # NSSecureTextField modal prompt
│   │   ├── system_webview_drag_region.zig # 有界 System WebView drag-region contract/state
│   │   ├── system_webview_drag_region/
│   │       ├── windows.zig # 创建期 HWND 捕获与 root/WebView hit-test subclass
│   │       └── macos.zig   # live-pointer drag 的公开 SDK 原语
│   │   ├── system_webview_window_controls.zig # SDK 缺失按钮能力的窄 contract/state
│   │   └── system_webview_window_controls/
│   │       └── windows.zig # 最大化/还原、用户关闭与最大化状态
│   ├── product/           # Product owner 与其持有的具名产品子模块；不形成统一 facade
│   │   ├── account.zig    # Account module entrypoint；公开模块名仍为 metawork_account
│   │   ├── account/       # Account Runtime、OAuth、catalog、credential 与状态机
│   │   ├── mcp.zig        # Workbench-held Product MCP module entrypoint
│   │   ├── mcp/           # MCP configuration、runtime state/freshness 与 owner-defined testdata
│   │   ├── skill.zig      # Live Product Skill 的窄公开入口
│   │   ├── skill/         # runtime/ports 与内部 state/policy/view/management-runtime 等 kernels
│   │   ├── task.zig       # Product Task state 与 kernel entrypoint
│   │   └── task/          # aggregate state/policy、persistence、checkpoint、binding、runtime 与 recovery kernels
│   ├── bridge.zig         # Renderer Bridge module entrypoint
│   ├── bridge/            # command policy、Dispatcher 与 ProductDelivery
│   ├── workbench.zig      # Workbench module entrypoint
│   ├── workbench/         # 产品 projection 与 bounded executor
│   ├── agent.zig          # Agent execution module entrypoint
│   ├── agent/             # catalog、Completion、Session/Runtime、event pump、callback 与 MCP ownership
│   │   ├── provider.zig   # Agent 共享 ProviderKind 与 AgentCore wire 映射
│   │   ├── completion.zig # 独立 Completion owner、typed request/result 与 streaming lifecycle
│   │   ├── mcp/           # connector、stdio/http transport、runtime 与 catalog
│   │   └── session/       # Session composition、Runtime lifecycle、binding、wire 与纯控制值
│   ├── storage.zig        # backend-independent Storage module entrypoint
│   ├── storage/           # SQL contract、direct SQLite backend 与共享 conformance tests
│   ├── automation.zig     # compile-time automation selection
│   └── automation/        # enabled/disabled authority capability
├── tests/
│   ├── agent/             # Agent lifecycle invariants
│   ├── workbench/         # Workbench executor/lifecycle invariants
│   ├── integration/       # 跨 owner 竞态
│   └── support/           # deterministic fake 与共享 fixture
├── scripts/               # Node 回归、真实应用编排与 artifact 工具
├── packaging/
│   └── windows/           # 单 EXE 安装器定义；只消费 Native SDK runtime stage
├── build_support/         # 正式 AgentCore bundle verifier 与 target locks
├── build.zig              # Zig/Native SDK module graph
├── app.zon                # Native window、origin 与 command allowlist
└── package.json           # 工程命令入口
```

`build_support/` 是正式 build graph 的一部分，不是归档目录。一次性 candidate consumer 在临时目录生成；实验 harness、阶段报告和仅为旧验证服务的 fixture 不进入 active tree。

## 3. 顶层所有权

| Boundary / role | 唯一职责                                                                                                                      | 不拥有                                                                             |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| Application     | Native SDK composition、窄 capability 注入、平台资源、bootstrap resolver、store 生命周期、跨 owner 用例编排与顶层生命周期顺序 | owner 领域状态与 policy、Bridge transport、AgentCore 协议、Renderer 实现           |
| Account         | Runtime、OAuth/catalog 状态、credential、attempt/effect/mailbox、恢复、脱敏 Account view、ExecutionConfig transfer            | Workbench Task、Renderer 状态、AgentCore Runtime                                   |
| Workbench       | Workspace/Task/Run 产品状态、Executor、admission、terminal product record、snapshot projection                                | AgentCore raw protocol、Native WebView、Account secret                             |
| Agent           | AgentCore integration、MetaWork Runtime/Session/Conversation、callback、event pump、Run terminal facts                        | 产品队列、Task 历史、Bridge transport、AgentCore 内部实现                          |
| Storage         | 无业务 SQL contract、limits、migration mechanism、direct SQLite backend、engine profile 与 conformance                        | Product schema/health/recovery、产品路径、Application lifecycle、Native SDK policy |
| Bridge          | command authority、payload decode、Workspace grant、ProductDelivery connection/revision/snapshot transport                    | 产品策略真相、AgentCore handle、Account runtime                                    |
| Renderer        | snapshot 消费、产品 WebUI 交互、纯 UI 状态与本地草稿、`frontend/src/bridge/` 合同实现层（transport 适配与 runtime decode）    | 原生窗口 owner、平台真实状态、安全决策、secret、AgentCore raw event、产品状态机    |

`product/account/contract.zig` 是 Account owner 发布的纯合同，不是新的产品 owner。`product/mcp.zig` 与 `product/mcp/` 是 Workbench 持有的产品 MCP 子模块；`product/skill.zig` 与 `product/skill/` 收拢 live aggregate state、Workspace/Task 共用的 immutable catalog compiler、enablement policy/store、本地 Skill management transaction，以及 package 的有界检查、staging 和导入导出 kernel；`product/task.zig` 与 `product/task/` 拥有 Task aggregate state 及已形成独立不变量的 policy、persistence、view、checkpoint、binding、runtime 与 recovery kernels。三者都不增加新的 Product owner。`product/` 是产品 owner 及具名产品子模块的目录归属，不增加统一 Product facade。`automation/` 只提供受控账号、origin 和临时 Workspace authority，不注册额外协议，也不拥有产品 transport state。

Product Skill 的公开 module 只发布 runtime、ports、catalog、enablement 与 management。package、policy、state、view、management-runtime 只在 Runtime 的内部 module graph 中装配；Workbench projection 不得直接 import 这些 kernel、拼装其状态、读取 `.skill.state`，也不得取得 `CatalogSlot`/`CatalogControl` 可变指针。Task/Session 组合只消费 Runtime 发布的 immutable catalog authority；catalog redaction、invalidation、generation 与 reschedule 不离开 Runtime。已安装 definition read/export 的 `.agents/skills` root 由 Runtime 根据 canonical binding 打开，Workbench 不拼接路径或传递 `CanonicalRoot`。

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

`features/` 按用户可见能力分区。feature 通过 `workbench/` selector 消费产品状态，不读取其他 feature 的内部文件。Task list、Task 内容、Approval、Composer、Workspace path selection、Search 与 Task overview 各自保留明确语义；不存在统一的 Agent surface、Timeline 或 Conversation projection owner。真正无业务语义的 Foundation primitive 进入 `components/ui/`；`components/ai/` 以 `Conversation`、`Message`、`Activity`、`Intervention`、`Composer`、`Markdown` 与 `CodeBlock` 七个最小组件统一中间 AI 对话的 Renderer 视觉语法，但不得拥有 Task/Run/Workspace、Bridge command、capability gate、AgentCore 或产品 visibility 语义。

`components/ai/` 只能向下依赖 `components/ui/`、共享 renderer 工具和已锁定的通用前端依赖；AI 组件必须复用 Foundation UI 的交互原语与 Design Tokens，不得在自身目录重建 Button、Input、Popover 等基础控件，也不得反向导入 `features/`、`bridge/`、`workbench/` 或 `app/`。

### `frontend/src/features/tasks/`

Task 内容 presentation 只按 canonical Run 顺序把用户输入、Assistant 回复、active 状态、必要 terminal 状态和 permission 适配到共享 AI UI 组件；`Conversation` 只是统一阅读面的 Renderer component，不成为新的 projection owner 或产品 facade。Tool、usage、Compact 和 UI history 不因存在于 Workbench snapshot 就进入主阅读流。长内容滚动可以保存每个 Task 的会话内阅读位置，但不得拥有输入草稿、Run admission、retry policy 或 AgentCore 语义。

`features/settings/SettingsPage.tsx` 是覆盖 Workbench 内容区的长期 Settings surface，消费 Account projection，并通过 App action controller 分别提交 Metask 账号默认配置与用户管理的模型连接操作；它不拥有 Workspace registry、authority、Task 导航或 Host lifecycle。已有 Task 的 Workspace 只从 Task projection 推导，New task 只持有 `draftWorkspaceId`，Renderer 不保存 `activeWorkspaceId` 镜像。

`workbench/task-visibility.ts` 定义一个跨 Store、左栏与搜索复用的纯 projection 不变量：只有 owning Workspace 同时存在于 canonical snapshot 的 Task 才参与活动导航。它不拥有 Task 历史或 Workspace lifecycle；被移除 Workspace 的 Task 仍由 Host 保存。

## 5. Zig 结构

### `app.zig`、`app/` 与 module entrypoint

`main.zig` 只调用 `metawork_app`。架构边界统一称为 Application，代码组合类型保持 `App`。`app.zig` 是 composition root，只保留 Native SDK `App` vtable、装配顺序、`run()` 与唯一的顶层启动/关闭顺序；Application 拥有的具体实现进入 `app/`，不得把实现重新堆回 root。

`app/` 只接纳四类实现：平台适配、一次性 bootstrap resolver、Application 创建资源的生命周期，以及跨 owner 用例编排。适配按稳定资源类别分文件，编排按用例分文件；编排只安排 owner 调用顺序，不读取领域状态自行形成 policy。`agent/`、`workbench/`、`product/account/` 与 `bridge/` 不得反向导入 `app/`。

`app/platform.zig` 是唯一 `DispatcherPlatform` vtable 实现并持有 Native SDK runtime/services 引用；窗口系统行为委托给 `app/window.zig`。`app/window.zig` 拥有窗口、tray、notification、dialog 与两个已登记 compat capability，但不拥有 Bridge authority 或 Product policy。`app/account_platform_binding.zig` 把 Account 定义的 credential/preference、authorization URL、timer 与 Model Connection credential vault ports 绑定到 Native SDK 和有界文件 I/O；它只拥有系统资源与机械 effect，不拥有 Account transaction、codec、恢复或 Model Connection registry policy。`app/metask_http_transport.zig` 实现 Account 定义的窄 Metask HTTP transport port，拥有 `std.http.Client`、请求 deadline/cancellation race 与 bounded response 写入；Metask request kind、响应状态分类、JSON codec 和 credential 生命周期仍归 Account。`app/oauth_loopback_transport.zig` 独占 OAuth loopback listener、connection、accept/receive deadline、跨线程 cancel 与 HTTP response byte pump；它只向 Account-owned callback sink 传递 callback-scoped request metadata，不解释 state、code、error 或 issuer。`app/paths.zig` 的 `Paths` 原位持有所有路径 buffer，只能按指针传递并由 `run()` 保持稳定地址。`app/stores.zig` 拥有 Application 创建的 store、单写锁与 restored bytes 生命周期。

`app/mcp_startup.zig` 负责启动期 registry load、credential transaction recovery、Workbench Desired preparation 与 canonical empty Runtime Manifest proof；它在 Desired preparation 进入 Workbench 前释放 credential staging，不构造正式 transport input或执行外部 MCP effect。`app/mcp_platform.zig` 只适配 MCP 系统 credential、stdio process/pipe 与 Streamable HTTP connection/raw-byte effect，不解析 MCP JSON-RPC、STDIO/HTTP framing 或复制协商，也不形成新的产品 owner。`app/mcp_management_coordinator.zig` 把 Workbench transaction seam、正式 Runtime complete replacement/activation、原生确认、Application-owned secure-input capability、系统浏览器、loopback、有界 OAuth worker，以及单一候选 Runtime 测试 worker串成用例；Application 启动与后续 Desired mutation复用同一个 configuration-apply job，没有第二个 startup worker。测试 worker 只消费 canonical prepared target并回写安全结果，不拥有正式 Runtime authority。coordinator 不拥有 registry、持久 operation、credential 或 OAuth policy。MCP secret capture 只在对应平台通过真实 modal 事件 gate 后开放；未验收平台保持 unavailable，不能扩展 Renderer credential bridge。

`native_sdk_compat/system_webview_drag_region.zig` 是 Application-owned 的有界 System WebView drag-region capability seam。它只拥有有界 region 校验、root 平台 binding 与 drag 调用编排；document generation 和 source-window authority 归 Bridge `Dispatcher`，不进入该 seam。只有 `app/window.zig` 可以组装它；不拥有按钮 action、按钮 capability、窗口最大化状态或 resize。Windows 消费共享 startup root binding；document `connect/disconnect` 只标记 Renderer 会话是否附着，`sync` 只事务式替换 region，不能安装、重装或销毁平台资源。`beginDrag` 不信任 Renderer 坐标授予执行权，而是重新观察逻辑主鼠标键、实际 OS 光标、光标下 HWND 的 root identity、root native hit 与当前 DPI，并只在实际点命中最新 candidate-minus-exclusions 时通过 `ReleaseCapture`/`PostMessageW(WM_NCLBUTTONDOWN, HTCAPTION)` 进入系统 move loop。它不递归依赖 Chromium 跨进程 child HWND，也不保留旧 root `WM_NCHITTEST` subclass 路径。`system_webview_drag_region/macos.zig` 只在 live pointer event 内调用 SDK 已有 `startWindowDrag` 原语并保留系统交通灯。System WebView 隐藏标题栏的 resize hit surface 仍归 Native SDK，不由该 seam 模拟；平台文件不创建覆盖 WebView 的辅助窗口。

`native_sdk_compat/system_webview_window_controls.zig` 是 Application-owned 的窄共置边界：maximize/restore、maximized state 与 user-close 是三项独立登记、独立删除的 Native SDK 0.8.0 缺口，只因共享同一 startup HWND 生命周期而留在一个文件中，并分别暴露 `toggleMaximize`、`state` 与 `userClose`，不提供内部 action enum/facade。Windows 平台子文件消费共享 startup root binding，并独占 `IsZoomed`、`ShowWindow` 与 `PostMessageW(WM_CLOSE)`；它不安装第二条创建 hook。非 Windows 不发布 Renderer controls。`minimize` 已有正式 Runtime API，必须由 `app/window.zig` 直接调用 `Runtime.minimizeWindow`，不得进入兼容层。Bridge 的 document generation 校验仍由既有 window-chrome command 边界完成，按钮兼容能力不持有 Bridge DTO 或 generation。

`native_sdk_compat/secure_input.zig` 是 Application-owned、与具体产品用途无关的安全文本输入 capability seam。它只拥有有界 UTF-8 options、调用线程、单一 active prompt、caller-owned 输出缓冲区和清零纪律；不导入 Product 或 Bridge，不解释输入用途，也不持有 credential store。Windows 子文件独占 startup HWND-owned modal 窗口、`ES_PASSWORD`、字符上限和带 `WC_ERR_INVALID_CHARS` 的 UTF-16→UTF-8 转换；非法 Unicode 或 UTF-8 字节超限保留对话框重试。macOS 子文件独占 `NSAlert`/`NSSecureTextField`。同步 modal loop 会继续派发当前 UI 线程事件，正式调用方必须另行证明其调用栈允许该事件纪律；该平台 gate 未通过时不能宣称 capability 可用。只有 `app/window.zig` 可以组装该 seam；Native SDK 正式 API 经对应平台验收后删除相应平台文件、allowlist 和验证。

Windows startup identity 不是独立 capability。`system_webview_startup_window` 是私有共享 lifecycle plumbing：Application 在进入 Native SDK runner 前只为当前 UI 线程武装一条 CBT 创建 hook，并在 `App.start` 入口立即收口；该区间必须恰好产生一个无 parent 的 top-level HWND，随后还要通过 root、owner、thread 与 process 校验，零个或多个候选一律 fail closed。结果是一个由 `app/window.zig` 注入 drag、controls 与 secure-input seam 的 opaque binding；各 seam 不得自行捕获或发现窗口。该机制不读取标题、焦点、前台窗口、`GWLP_USERDATA` 或 `PlatformServices.context`，也不解释 Native SDK 私有类型。显式退出不属于兼容层：确认对话框与主窗口关闭使用 Native SDK Runtime API，由 Runtime 维护窗口/View 状态并驱动正常 shutdown。

整个 Host command 边界只接受绑定当前 document generation 的 `minimize | toggle_maximize | close` 固定 enum，不接受任意 action、window id、platform、活动窗口猜测或独立 state query；按钮 seam 只发布按钮呈现所需的 `rendererControls` 与 `maximized` 真值，不形成通用 Desktop Interface、Native SDK adapter、第二窗口 owner 或任意 action facade。Native SDK Runtime 对应能力经目标平台验收可用后，必须逐项原位替换：先移除对应按钮兼容 action/state，再删除不再需要的 HWND 绑定、低层调用、allowlist 与专用验证。

Renderer 的 `components/ui/WindowTitlebar.tsx` 绘制产品 header，并通过 portal 在 document root 只声明一个 `data-metawork-window-drag` marker；`components/ui/WindowControls.tsx` 绘制带固定 `data-metawork-window-control` 语义的按钮，不注册 native handler 或调用 transport。`frontend/src/bridge/window-chrome.ts` 是 browser-side Bridge boundary：它有界镜像 candidate/交互排除区、转换 control intent、runtime decode Host geometry/capability/state，并写入 CSS variables/document dataset；document attach 只 `connect` 一次，Native SDK `window.zero.on("resize")` 与 DOM observer 通过 latest-only scheduler 同步当前 generation，失败不清除仍有效的 controls/session。产品 React 代码不得直接调用 `window.zero`，不得维护平台名或窗口真实状态。已删除的 `app/useWindowChrome.ts` 与 `platform/window-chrome.ts` 不得恢复。

`account.zig`、`bridge.zig`、`workbench.zig`、`agent.zig` 和 `storage.zig` 是小型公开入口，只显式暴露实际消费者需要的类型、函数或窄 namespace。内部文件不通过 `usingnamespace` 或无边界 barrel 重新泄漏。

### `storage/`

`storage/sql.zig` 是稳定、backend-independent 的基础合同，只定义 SQL values、statement batches、row receiver、limits、migration 和 typed outcomes；它不导入 Product、Application、Native SDK 或 SQLite C 类型。`storage/sqlite.zig` 是当前唯一 concrete backend，独占 SQLite C API、连接资源、`WAL + synchronous=NORMAL` profile、migration transaction 和错误映射；`storage/conformance.zig` 以同一合同验证 fake 与真实 SQLite 后端。官方 SQLite amalgamation 以固定版本和 hash 进入 `build.zig.zon`，C source/include 只接到 Storage module。

Storage 当前只接入正式 Native test graph 和定向 `zig build test-storage`，没有注入 Application、Workbench、Account、Agent 或 Bridge，也不会解析产品路径或创建 production `app.db`。未来 Product owner 只能依赖 `storage/sql.zig` 发布的能力并继续拥有自己的 schema 与恢复语义；只有 Application composition 可以创建 concrete backend，业务模块不得导入 `storage/sqlite.zig` 或直接调用 SQLite。

### `product/account/`

- `runtime.zig` 是 Account 长生命周期 aggregate，拥有状态机实例、private catalog session、committed/candidate public catalog slot 及 candidate attempt identity、credential、mailbox/effect queue、preference shadow/恢复、自动选择与 continuation；effect driver 不拥有 committed 产品目录。它不导入 Workbench，跨 owner 提交仍由 Application coordinator 协调；
- `state.zig` 拥有封闭 `Transaction` sum type、attempt/generation、bounded pending facts 与 prepare/commit decision；每个 prepared change 显式给出 catalog/execution/replacement intent，不保存可独立漂移的 operation/attempt 组合状态；
- `oauth.zig` 与 `loopback.zig` 拥有 OAuth material、callback/state/code/error/issuer 校验、无效请求预算和 response policy；`login_attempt.zig`、`network_attempt.zig` 拥有 Account worker、token/identity 链路与取消编排，只经注入的 endpoint/sink 使用 Application loopback transport；
- `metask_client.zig` 与 `catalog.zig` 消费锁定的 Metask production contract；`metask_client.zig` 只发布协议、状态分类与 transport port，不持有 concrete HTTP client；
- `app.zon` 单一拥有 development 产品 Bundle ID；`product_identity.zig` 派生该值、macOS 数据目录和仅供 `-Dautomation=true` artifact 使用的 `.automation` Native SDK runner identity。正式 artifact 始终把 manifest identity 传给 runner；automation identity 只隔离 Native SDK 的 data/window/log namespace，不改写产品 identity、签名或 credential 合同；
- `credential_store.zig` 独立拥有跨平台 Account persistence 合同、preference codec 与事务：secure store 中唯一的 refresh token，以及原子、无 secret 的 `preferences.json`；production 与 automation service 在编译期隔离；
- `ports.zig` 定义 Account 对内需要的五族 effect surface：refresh-token credential、preference load/commit/delete、authorization URL、timer 与 Model Connection credential vault；它复用 `credential_store.Backend` 表达前两族，不为每个函数制造独立抽象，也不导入 Native SDK 或 Application；
- `credentials.zig` 管理 execution credential ownership/rotation。

Account 与 Workbench 是同级 owner，只通过纯 `product/account/contract.zig` 和 Application coordinator 主线程提交链协作。源码位置不改变公开 Zig module identity：构建仍导出 `metawork_account` 与 `metawork_account_contract`。Bridge 只消费脱敏 view/command contract，不导入 Account Runtime。Application coordinator 可以持有两个 owner 的实例引用以协调提交，但不得持有 Account catalog、credential、attempt、mailbox 或 continuation 状态。

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

`SkillsPage.tsx` 是 MetaWork 用户 Skill catalog 的一级管理视图，拥有搜索、catalog 状态、bounded issue、空状态、Personal 用户默认开关和 Manual Workspace 三态覆盖控件。它只消费 Bridge 已解码的 Workbench 顶层 canonical projection，并由 `app/App.tsx` 发起 `skills.refreshCatalog` 与 `skills.setEnabled`；不得读取目录或 Skill body、依赖 selected Workspace、推断 source，或持有 enablement policy。项目 switch 写入 enabled/disabled override，独立“跟随用户”动作清除 override；安装和编辑不属于该页面。

### `frontend/src/features/mcp/`

`McpPage.tsx` 是具有稳定左栏入口的 MCP 全局管理视图，拥有搜索、行动优先分组、空/不可用/恢复状态、transport-discriminated Add/Edit、稳定 master-detail、可选连接测试、正式 Runtime apply/refresh、启停/删除和逐工具 allowlist。Add/Edit 的显式提交就是连接授权并自动进入正式 apply，正常流程不再追加一次自我审核；legacy unapproved 配置才显示连接动作。页面只消费 Bridge 已严格解码并清洗的顶层 `mcp` projection，并通过 `frontend/src/bridge` 的 field-level typed command 提交 intent；它可以查看和预填 Host 发布的完整非敏感 typed connection，但不得维护 registry 镜像、直接调用 AgentCore 或读取 environment/header value、credential、schema、Runtime fingerprint 与 raw diagnostic。marketplace/trust 与 Task-level override 不进入该目录。

### `frontend/src/features/scheduled-tasks/`

`ScheduledTasksPage.tsx` 是与 Skill 中心同级的持久自动化管理视图，拥有搜索、Text 建议模板、状态分区、连续列表、真实 Task/occurrence 链接与 detail/editor drawer；任务内容只编辑 Text instruction，不读取任何 Skill catalog 或持有 Skill 配置。recurrence 的本地输入与确认摘要留在该 feature，但 Host snapshot 和 typed mutation result 始终是产品真相。该目录不得使用 Renderer timer 触发 Run、用浏览器存储持久化 Scheduled Task、直接调用 AgentCore，或复制 Task timeline。

### `workbench/` 与 `agent/`

Task 标题生成不新增模块或 owner：`workbench/projection.zig` 在首个 Run admission 先提交旧规则生成的临时标题，再由同一 Run worker 消费现有独立 Completion，并在主线程完成候选校验、用户标题优先、替换、脱敏和持久化；它不扩展 Agent surface，也不建立标题专用 executor 或 Session 路径。

`product/task/persistence.zig` 的当前 hard-cut store 是 `workbench-history.store`：固定 frame header、header/payload checksum、record type、bounded JSON payload 与 Task failure record 组成唯一 canonical history；不读取、不迁移、不双写任何旧 envelope，也不引入迁移版本层。Workspace/Task frame 可独立恢复，无法信任 Task identity 时只进入 `degraded`，可确认的坏 Task 以同一 store 的 failure record 留痕，不关闭新 Task admission；Automatic Workspace 仅在唯一 Task 恢复后占用容量。

`product/mcp/configuration.zig` 的 static locator 只在 Replace 前后 command + ordered argv + cwd 或 endpoint 与 auth mode 相同时按同名 slot 沿用；其余 locator 仍由既有全 registry 引用差分和 credential journal 退休。Desired enabled 可独立于 credential readiness 保存，Runtime preparation 与 Admission 继续负责 fail-closed eligibility。

`product/mcp/state.zig` 持有 Workbench-owned MCP Runtime Manifest、Activation/Selection authority、Admission、OAuth/reauthorization、connection test、configuration apply 与 freshness 状态；freshness 精确包含 request generation、pending、是否必须封锁 admission、绝对 monotonic deadline，以及 earliest safe TTL 的转换规则。它可以依赖 `metawork_agent` 的公共 Activation/Selection 类型，但不得依赖 AgentCore SDK、Application、Bridge、Account 或 Native SDK。`McpRefreshJob`、executor enqueue/cancel/commit 与 worker 引用继续留在 `workbench/projection.zig`，避免把 Workbench 的执行资源伪装成独立 MCP owner。

`product/mcp/policy.zig` 是无 Workbench 资源的策略与状态转换 kernel：它读取 configuration/state，处理 authorization phase、pending reauthorization 合并与清理、Desired Admission tools、refresh allowlist/binding、expected generation、OAuth expiry/operation busy、new-Task/recovery query，以及 runtime-auth-failure 优先的 Admission swap。它可以构造并返回 Agent 公共 `McpServerAllowlist` 或借用 `McpSelection`，但不得持有 Agent Runtime、调用 selection 创建、提交 durable mutation、推进 revision，或引用 refresh job、executor、timer、线程和 Application effect。

`product/mcp/view.zig` 是无状态 MCP snapshot 派生模块：它只读取 configuration/state，并通过 callback-scoped `TextProjection` 借用 Workbench 已有的敏感文本判断与 JSON 遮蔽规则；refresh worker 是否在途以单个 bool fact 输入。它不得持有 Workbench、credential、refresh job、线程或 effect，也不得直接依赖 Agent、AgentCore、Application、Bridge、Account 或 Native SDK。Workbench 继续拥有 revision 1 完整 snapshot 的字段编排、容量、buffer 与交付，并只在 MCP 子树位置调用该 View。

`product/task/view.zig` 是无状态 Task snapshot 派生模块：它读取 Task state/policy/recovery 与 pinned Product Skill catalog，并保持 Task/Run/Compact/pending-UI/UI-history 子树的 revision 1 字节合同。Workbench 以 callback-scoped `TextProjection`、`CatalogProjection` 与 `PendingUiProjection` 提供 credential-safe JSON、共享 catalog writer 和即时 Session observation；View 不保留这些借用，也不持有 Workbench、Session、credential、allocator、worker、revision 或 effect。下文 `workbench/projection.zig` 的 bounded snapshot writer 精确指完整 snapshot 的根编排、容量 buffer 与交付，不包含已经归入该 View 的 Task 子树派生。

`workbench/projection.zig` 当前拥有 Workspace identity、Task pinned catalog、typed Text/Skill admission 与 history、Workspace/Scheduled Task 状态、Task 唯一 active operation、executor job context/worker reference、Agent event pump 的固定双 drain 编排、durable commit、revision publication 和 bounded snapshot writer；Task/Run/Compact aggregate、事件状态转换、write-once terminal publication 与 final event-drain gate 归 `product/task/state.zig`；terminal/interruption/lifecycle/recovery 的无外部 effect 分类、查询与 transition 归 `product/task/policy.zig`。组合层只以 callback-scoped `EventProjection` 借出全局有界投影内存和 credential 清洗机制，state 不保留 capability、allocator 或 credential；MCP 策略与状态转换委托给 `product/mcp/policy.zig`，MCP 子树的纯派生委托给 `product/mcp/view.zig`，但 Agent selection 创建、durable mutation commit、refresh job/timer、revision publication、完整 snapshot 编排、容量与交付不转移。current authority 使用 tagged `CatalogSlot`：生产 committed 分支同时拥有 AgentCore opaque lease 与 immutable compiled snapshot；catalog job 独立表达 refresh，不能覆盖或拆散 last-good authority。它直接接收自己的 `std.Io`，不得借 `agent.Runtime` 获取 Executor、文件、目录或随机数能力。Manual compact 是 append-only Task maintenance history，不复用 Run identity；Conversation restore 只重建 runtime attachment，不创建历史事件。`product/task/persistence.zig` 拥有 hard-cut (无迁移版本层) 的无 secret Workspace/Task history record codec、header/payload checksum、Task failure record、严格恢复校验、16 MiB 上限、进程级单写锁与同目录原子替换；当前文件为 `workbench-history.store`，旧 JSON envelope 不读取、不迁移、不双写。Workspace/Task frame 逐条隔离，无法信任 Task identity 时只记录 degraded health；可确认的坏 Task 以同一 canonical store 中的 failure record 持久化，Automatic Workspace 仅在唯一 Task 恢复后占用容量。Workbench 持有的 `product/mcp/configuration.zig` 拥有 `<MetaWork data dir>/mcp/registry.json` schema 2 的 bounded strict codec、schema 1 disabled+unapproved migration、稳定 server/namespace identity、connection approval、OAuth 非 secret 状态与顶层单一 `oauth_operation`、Desired Registry mutation、全 registry credential locator 引用差分、single-writer atomic commit 和基于 durable generation 的 credential journal recovery；OAuth registration 精确保存 exact issuer、client identity、token endpoint auth method 与 client-credential revision，DCR operation marker 保存完整 consent draft，返回的 issued identity 再生成最终 consent fingerprint。STDIO 与 Streamable HTTP 分别使用 transport-specific create/update input，static environment/header 以 `{ name, nullable credential_ref }` secret slot 持久化，缺失 locator 是可修复的 `needs_authentication` 状态而不是明文占位。Host-only secure capture 消费并清零临时 secret、生成 fresh locator，并仍通过同一 credential journal 提交；该输入不从 `workbench.zig` 导出，也没有 Renderer/Bridge command。operation marker 的同文件状态提交不推进 desired generation，遗留 marker 则通过同一 journal 生成 `reauth_required` target 并退休旧 token locator。Refresh begin 在 marker commit 前预构建 reduced Admission 与 detached network binding；refresh completion 从当前 canonical generation 重建 fresh token target，先准备 Runtime snapshot replacement 与恢复 Admission，再按 credential journal 提交并 no-fail 安装。Admission 的唯一构造路径同时解释 active marker 与 OAuth `ready/reauth_required`，所以无关 server mutation 不会重新授予正在操作的 server。`app/mcp_oauth.zig` 复用 Account 的无系统资源 PKCE/callback policy，并复用 Application-owned `oauth_loopback_transport` 执行 listener/socket/HTTP pump；它拥有无 credential discovery、metadata 校验、系统 HTTP deadline/cancel、authorization URL、RFC 9207 callback policy、metadata-advertised DCR、code exchange 与 single-shot refresh effect。窄 `StatePort` 先从 Workbench 取得 approved endpoint/consent binding，DCR 与 code exchange 只有在 durable begin 返回后才发送 POST，返回结果只能 complete、clear 或进入 uncertain recovery。POST 的 transport/响应不确定性只返回 outcome unknown，不自行重放或改写产品状态。`product/mcp/testdata/mcp-http-endpoints.json` 是由该 owner 定义、Host 与 Renderer 测试共同消费的 endpoint acceptance corpus，不进入产品构建数据面。MCP configuration 不保存 credential 原文、不解析 AgentCore catalog，也不形成新的 product owner。Workbench 的 MCP control plane 额外持有与当前 Agent Runtime 同寿命的 Runtime Manifest、configuration apply state、Agent Activation lease 与 `ready(optional selection) | blocked(reason)` Admission Authority；Manifest 只记录正式 Runtime 已接管的 descriptor fingerprint 或安全 absence proof，desired generation 只做持久化并发版本。field-level mutation、refresh、OAuth operation 与 Task admission 共用 Workbench 串行化边界，新 Task 不再直接读取 Activation current selection。Application 只打开 data root 并注入 load/commit/platform capability，Session/Conversation 不进入这些文件。`workbench/automatic_workspace_allocator.zig` 拥有 Application-opened automatic root capability、相对随机子目录分配、canonical containment 与发布前空目录回滚；它不扫描旧目录、不恢复 Task，也不递归删除目录。`workbench/scheduled_tasks.zig` 拥有 bounded definition/occurrence storage、结构化 recurrence、跨恢复 planned-time identity 和纯状态转换；`workbench/scheduled_task_persistence.zig` 拥有无 secret codec、candidate commit、恢复校验和 schema revision。`product/skill/package.zig` 拥有本地 Skill 目录与 ZIP 包的路径/资源上限预检、regular-bytes-only staging、内容摘要和 canonical `.skill` 导出，不执行包内容或访问网络；`product/skill/management.zig` 拥有独立 install identity、personal/project inventory、管理状态、未完成文件事务恢复事实和 schema 1 无 secret 原子持久化。它们都属于 Workbench owner，不是第二个执行器或 AgentCore scheduler。`workbench/executor.zig` 独占 catalog/Run/compact/restore 与显式 MCP refresh 共用的单一队列、workers、admission 和 shutdown。

`product/skill/runtime.zig` 是 live Product Skill aggregate：它持有 `state.State`、Personal/Workspace `CatalogControl`、Workspace canonical root binding、catalog job、reschedule 与 shutdown 状态，按 `(workspace id, epoch, request generation)` 提交或丢弃 Agent acquisition。`ports.zig` 只发布 shared Executor enqueue/cancel、Agent catalog query/release 和 notifier 窄 capability；Runtime 不持有 Workbench、具体 Executor、Agent Runtime/Session 或线程。`state.zig` 收口 inventory/transactions、management/enablement health、staging root、reconciliation latch 与 tagged authority；committed slot 同时拥有 opaque Agent lease 与 immutable snapshot。`policy.zig` 无外部 effect 地解释 persistence failure、scope enablement/selection revision 与 inventory invocation 查询，并调用 catalog compiler 生成完整 candidate；`view.zig` 无状态地编码 catalog 与 management snapshot 子树。`enablement.zig` 拥有 `skill-enablement.json` schema 1、全局 revision、用户 defaults 与 Manual Workspace overrides；`catalog.zig` 是共享 immutable authority compiler；`management.zig` 与 `package.zig` 分别拥有本地事务/store 与有界 package 处理。`projection.zig` 只绑定窄 ports、同步 Runtime outcome、提供投影预算、Workspace authority/Task quiescence facts 与时间值，并继续拥有 Task create/refresh/restore、Run admission、完整 snapshot 根编排、容量、revision 与交付；enablement CAS/encode/FileStore commit/authority swap 已归 Runtime；它不得重新持有 catalog job 或 Workspace catalog control。Application 直接创建并持有两类 `FileStore` 后注入组合层。当前 catalog query 只使用 AgentCore 默认的 user/workspace `.agents/skills` discovery，不拥有其他路径配置。

`agent/completion.zig` 独占不借用 Runtime/Session 的 Completion owner、typed request/result/event 校验、operation-specific status disposition、owned buffer 和 Stream → Completion 销毁顺序；`agent/provider_probe.zig` 只组合该能力完成有界 Model Connection 测试。`agent/checkpoint.zig` 是 checkpoint export、Session description、官方 limit ceiling 和 operation-specific status disposition 的唯一 AgentCore SDK 边界；`agent/checkpoint_restore.zig` 独占 verified source adapter、restore expectation/report 对账和 restore-specific status disposition。`agent/session/runtime.zig` 在锁内预留 Session slot、维护 restore in-flight fence，并拥有流式 ABI 调用的 Runtime 生命周期；`agent/session.zig` 保留 Session 对象与锁内状态转换；`agent/session/wire.zig` 独占 AgentCore payload 解码、UTF-8 校验、builtin profile 与 wire code 映射，`agent/session/control.zig` 只保存不持有 Session/Runtime 指针的状态、终态结果和 notifier 值。两者不解析或复制 AgentCore 私有 blob 格式。

`product/task/agent_session.zig` 是 Product Task 对 Agent Session 的唯一 gateway，独占裸 `*agent.Session`、`SessionRoute` 与 `SessionRestoreRoute` 的 Product 侧出现位置。`Binding` 保存 Runtime slot 归还责任和纯 route identity；`Access` 通过 Session `retainReference/releaseReference` 形成无额外分配、exactly-once 的调用 lease。`runtime.zig` 的 attachment 只保存 Binding，不保存裸 Session 或重复 route id；`recovery_job.zig` 的 candidate 只公开 Binding 与值类型 restore report。Run/Compact job context 在实际 Agent 操作期间持 Access；Run 在自动标题等非 Session follow-up 前释放它，pending-UI/checkpoint/model/catalog/permission 使用 scoped Access。普通 close 必须等待全部 Access quiescence，成功后归还 Runtime slot；Runtime shutdown 成功后的残留 Binding 只允许进入不可逆 `relinquished` 终态。

`product/task/state.zig` 拥有 Task/Run/Compact aggregate、Agent event 产品状态转换、terminal publication 与 final event-drain gate；`product/task/policy.zig` 拥有 Agent terminal/interrupt 到产品 outcome/cause、Task lifecycle/active operation、checkpoint history/recovery 与 Session disposition 的无外部 effect policy；`product/task/view.zig` 只借用 state/policy/recovery 与 Product Skill catalog，并通过 callback-scoped projector 复用组合层的敏感文本、catalog JSON 和 pending-UI observation，保持 Task snapshot 子树的 revision 1 字节合同；它不持有 Workbench、Session、credential、worker、allocator、revision 或外部 effect；`product/task/checkpoint_record.zig` 定义 durable `Record = blob + session + anchor`，严格分离 blob identity、最小 Session binding 与 Workbench terminal/binding 锚点；`product/task/checkpoint_store.zig` 拥有不可变 per-Task blob 布局、进程级单写锁、bounded no-follow scan、hash/size 校验、原子提交和可信启动孤儿清理；`product/task/persistence.zig` 拥有 history capability/health、逐字段白名单 codec、Task/Run/Tool/Compact/UI/checkpoint wire projection、恢复重建与跨记录校验，并通过 callback-scoped `RestoreProjection` 借用组合层的全局有界内存记账。根级 Workspace frame 组装与 durable commit effect 不进入该模块。`product/task/runtime.zig` 独占 `attached | detached | closing` runtime resource union；`product/task/deletion.zig` 独占 runtime-only 删除用例状态，并以纯决策函数按 checkpoint → terminal event → Session → worker reference → durable commit 的 owner 顺序选择唯一下一 effect；`product/task/recovery.zig` 是 continuation/eligibility 的纯策略；`product/task/recovery_job.zig` 拥有 immutable prepared attempt、bounded executor job、verified source、Skill/MCP authority acquisition 与 typed completion。`workbench/projection.zig` 只读取各 owner fact、组装 Workspace history frame、执行 durable commit 与删除决策产生的 effect、完成主线程 prepare/commit、optimistic revalidation、candidate attachment 安装和完整 snapshot 根编排，不在 snapshot 路径读取 checkpoint 文件。Application 只按既有 store 生命周期打开 `<MetaWork data dir>/workbench/checkpoints` 并注入 capability；Bridge、Renderer 与 Account 不依赖 checkpoint 模块。

`app/mcp_platform.zig` 是系统 credential service、stdio process/pipe effect 与 Streamable HTTP connection/byte-pump effect 的 Application composition seam；它只把惰性、opaque transport owner 注入 Agent，不解析 MCP JSON-RPC、STDIO framing、HTTP media type 或 SSE。OAuth HTTP owner 与 Application lookup registry 共同引用同一 auth slot；每次请求租借 immutable token snapshot，同 consent epoch 的 revision CAS 替换 slot，旧 snapshot 到最后一个 in-flight lease 释放后才清零。`app/mcp_oauth_coordinator.zig` 只拥有一个 earliest-expiry one-shot timer、一个可取消 refresh network job 和主线程 completion sequencing；它先调用 Workbench durable begin，再读取系统 credential 并启动 discovery/POST，结果回主线程后协调 snapshot/registry/Admission commit，shutdown 时先停 timer、cancel/join job 并收口 marker。它不保存 Desired Registry、不形成通用 scheduler。`agent/capabilities.zig` 是 MetaWork Agent 产品能力的私有真源，定义 typed built-in 身份、精确 AgentCore wire 映射与允许的 UI request 种类；Application、Workbench 和 Renderer 不导入该定义。`agent/catalog.zig` 拥有 AgentCore Skill catalog descriptor 的即时解码、MetaWork-owned 安全投影、opaque handle lease 与 root/home/epoch 绑定；raw handle、scope、物理来源和 policy 不离开 Agent。`agent/mcp/connector.zig` 是 Application transport capability 到官方 `McpConnectorV1` 的唯一映射点，只拥有 callback/status、取消借用、response ownership、bounded secret guard、transport owner 与连接引用，不解析 MCP JSON 或协商协议；`agent/mcp/stdio.zig` 只拥有 newline framing、消息 bound、序列化与失败策略，并通过窄 process endpoint 使用 Application-owned child/pipe/stderr/timeout effect；`agent/mcp/http_protocol.zig` 是零运行时依赖的 Agent-owned MCP request header 真源，Workbench 配置验证只依赖这个窄叶子而不依赖 transport backend；`agent/mcp/http.zig` 拥有 MCP request/response headers、status/media-type/session 规则、JSON bound、SSE decoder 与连接失败策略，并通过窄 authorized endpoint 使用 Application-owned auth/connection/raw-byte effect。两类 endpoint 都以同步 sink callback 泵 borrowed bytes，不转移 process、pipe、reader 或 connection 句柄。`agent/mcp/runtime.zig` 以线性 `McpRuntimeInput` 接管完整 server set，并为 declarative Runtime apply 生成 revisioned configuration；`agent/session/runtime.zig` 在 APPLIED 时交换 current Servers owner，按 connector retain/active connection quiescence 回收旧 owner，并在 Runtime 销毁时释放剩余 owner；`agent/mcp/catalog.zig` 只经官方 decoder 复制 bounded catalog authority，并为 Workbench 构造 Runtime-bound owned selection 与 typed Activation health。`agent/session/runtime.zig` 独占 Runtime 创建、MCP/catalog 调用、Session slot/reservation、fresh/restore Session 的统一 capability 应用与 Runtime shutdown；`agent/session/binding.zig` 独占持有 Session 的控制 block、RunControl 与 lease，封装 Session-bound termination/quiescence，不暴露 Session 内部给 Workbench；`agent/session.zig` 保留 Session/Conversation、typed Run/compact、callback、event pump、Session 生命周期和 immutable terminal result，并作为 Runtime/Binding 的组合根；它在 Agent capability gate 不允许的结构化 Question 建立 pending 状态前 callback fatal。`agent/session/wire.zig` 与 `agent/session/control.zig` 是无 Session/Runtime 生命周期引用的叶子模块，分别负责完整 ABI 协议解码和纯值控制。Workbench 不持有 AgentCore built-in profile、wire name 或 Question response；其 Admission Authority 只借用 MCP/Skill selection 完成同步 Session create，AgentCore 复制后不保留该指针；refresh/shutdown 前 Workbench 必须先释放 authority 与 Activation。`event_sink.zig` 与 `event_pump.zig` 管理 borrowed event 深拷贝、容量和通知。Agent 不接收 Scheduler capability，也不反向 enqueue Workbench。

`app/mcp_platform.zig` 对 transport-facing credential bytes 做最终 fail-closed 校验，在 401/403 时记录合法 Bearer challenge，并机械泵送有界 process/network bytes；完整 request response 仍把 status/body 交给 Agent sink，notification 因没有 response descriptor 才在该边界返回 auth failure。它不分类 Content-Type、不剥离 SSE framing，也不解析 JSON-RPC identity/semantics。`agent/mcp/connector.zig` 将 stdio 的 status 0 或 Streamable HTTP 的完整 status/body 映射到官方 `McpResponseV1`，其公开 runtime limits 经 Application 注入 Workbench preparation，确保 `eligible` server 可直接构造正式 connector。

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
storage -> SQLite amalgamation
```

`storage -> SQLite amalgamation` 只存在于 direct backend；Storage contract 不依赖 SQLite 或 Native SDK，当前没有任何 `app/product -> storage` 正式运行时边。`bridge -> Native SDK` 只允许消费正式 Bridge transport contract，以及 transport authority 和窄 Application capability 调用所需的 data-only DTO/opaque identifier；它不允许 Bridge 持有 `PlatformServices`、具体平台实现、OS handle 或直接系统调用权。`automation -> bridge` 只消费 policy 类型；`automation -> Native SDK` 只消费同级 Bridge policy contract 类型，同样不得持有 `PlatformServices`、平台实现或系统调用权。Account 只依赖自身 `ports.zig`；`app/account_platform_binding.zig` 在 Application 生命周期内持有并绑定对应系统 effect，shutdown 必须先让 Account 清空 port 引用，再释放 binding。禁止 `agent -> workbench/bridge/app`、`workbench -> bridge`、`bridge -> Account runtime` 和任何产品模块反向依赖 Renderer。

`product/skill/management_runtime.zig` 是总 Runtime 内部的 live local-asset use-case owner：它调用唯一 package/management kernels，闭合 preview/read/export、install/reimport/uninstall/retry、staging、恢复和 catalog reconciliation。`product/skill/runtime.zig` 只保留 aggregate 入口、catalog refresh 协调与内部 owner 委托；`projection.zig` 只证明 Workspace authority/Task quiescence、传入时间事实并发布 revision，不直接调用 package 或 Transactions。

## 6. 测试与构建资产

本节只定义测试与构建资产的目录归属；测试层、失败模式、默认入口、probe 生命周期和证据纪律由[验证规范](validation.md#持续回归)定义，变更时实际执行哪些检查由[仓库执行规则](../AGENTS.md#验证规则)定义。

- 产品 module 的 inline test 与实现共置并使用相同依赖边界；正式 external Zig test root 置于 `tests/`，由 `build.zig` 注册；
- `tests/agent/`、`tests/workbench/` 分别归对应 owner，`tests/integration/` 只容纳无法归属于单一 owner 的跨边界失败，`tests/support/` 只提供 test-only fake 和 fixture，不形成产品 owner；
- Storage contract、conformance 与 direct backend test 与 `src/storage/` 共置；`zig build test-storage` 是其定向入口，正式 Native test graph 仍是提交前的完整入口；
- `scripts/*.test.mjs` 是默认 Node/Renderer 回归资产，由 `npm test` 自动发现；其他 `scripts/` 可以编排真实应用、平台验收和 artifact 工具，但不能建立测试专用产品协议；
- `assets/brand/logo-mark.svg` 是标志几何真源；`assets/icons/` 保存从该真源导出的应用与托盘用途母版、`MetaWork.icon` macOS 平台组合真源及 Windows 平台交付资产；仓库不维护通用图标格式转换工具链，唯一例外是已登记的 `scripts/native-sdk-compat/macos-icon-composer.mjs`，只在 `package:macos` 中调用受版本门约束的 Xcode `actool` 生成不提交的 `Assets.car` 与 fallback ICNS；
- 根 `package.json` 只保留 `dev`、`check`、`test`、`format`、`format:check`、`build:debug`、`build:release`、`package:macos` 与 `package:windows` 九个工程入口，不登记内部步骤、单项测试、probe 或平台验收 harness；`scripts/dev.mjs` 是跨平台开发入口并独占 Apple Development 本地签名策略，`setup-macos-local-signing.mjs` 只复用该 owner 完成一次性选择，二者不得依赖发布脚本；`package-macos.mjs` 独占 Developer ID、Icon Composer 资源 staging、DMG、公证与发布验证，`scripts/native-sdk-compat/macos-icon-composer.mjs` 只作为其内部 artifact compiler/stager，不得依赖开发或 setup owner。macOS `dev` 只使用显式选择的 Apple Development identity；`package:macos` 默认按固定 target store 顺序输出版本化 arm64 与 x64 DMG，显式 `arm64` 或 `x64` 只构建一个，并在当前图形用户会话中使用 Finder 写入左到右拖拽布局，只使用唯一有效的 Developer ID Application identity 和钥匙串 `metawork-notary` profile，要求每份应用与 DMG 签名、notarization `Accepted`、DMG staple、Gatekeeper、磁盘映像及挂载内容完整性全部通过；Windows `package:windows` 只消费 Release build 与 Native SDK Windows runtime stage，要求 x64 GUI subsystem 和完整 runtime 结构，再由 Inno Setup 输出版本化单 EXE；其显式 signed mode 使用 Windows SDK SignTool、精确证书 thumbprint、SHA-256、RFC 3161 与 Authenticode verification，普通 unsigned mode 不读取签名身份；
- `build_support/agentcore_bundle.zig` 与 target lock 是正式信任边界；candidate probe 只使用临时 source-free SDK consumer；

## 7. 结构变更规则

- 先证明新的 owner 或不变量，再拆文件；不为目标树、行数或命名整齐创建空模块；
- 类型跟随拥有其不变量的模块，不建立 `models`、`common`、`helpers`、`services` 或 `managers` 垃圾桶；
- 同一事实只在一个 source of truth 定义，目录文档不复制完整产品或生命周期论证；
- 删除 owner 时同步删除 build graph、allowlist、测试入口和文档引用，不把废弃实现移动到归档目录；
- 目录调整不得以搬迁为由改变 source of truth、不变量或 test graph 接线；确需改变时按对应 owner 合同和验证规则一并收口；
- 不增加 Native SDK adapter、AgentCore facade、平行 Renderer、平行协议或 source dependency fallback。

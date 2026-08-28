# AGENTS.md

本文件适用于整个 MetaWork 仓库。它只定义执行规则和不可绕过的护栏，不替代产品、架构或合同文档。

## 开始工作前

按任务实际触及的边界阅读 source of truth：

| 变更范围                                                      | Source of truth                                                      |
| ------------------------------------------------------------- | -------------------------------------------------------------------- |
| 产品对象、行为与范围                                          | [docs/requirements.md](docs/requirements.md)                         |
| UI 信息架构、交互与 capability gate                           | [docs/workbench-ui-design.md](docs/workbench-ui-design.md)           |
| 技术选型、系统 owner 与安全边界                               | [docs/architecture.md](docs/architecture.md)                         |
| Product owner、事务、并发、恢复及其与 Agent 的协作            | [docs/product-architecture.md](docs/product-architecture.md)         |
| Account owner、Metask 合同、状态、事务、持久化、并发与恢复     | [docs/account-architecture.md](docs/account-architecture.md)         |
| Renderer Bridge command、event、Snapshot 与运输合同           | [docs/renderer-bridge-contract.md](docs/renderer-bridge-contract.md) |
| active tree、目录 owner 与依赖方向                            | [docs/project-structure.md](docs/project-structure.md)               |
| AgentCore Session、工具、Skill、Permission、事件与生命周期    | [docs/agentcore-integration.md](docs/agentcore-integration.md)       |
| AgentCore bundle、ABI 与 required capability                  | [docs/agentcore-abi-v1.md](docs/agentcore-abi-v1.md)                 |
| 测试归属、验证状态、证据和持续回归入口                        | [docs/validation.md](docs/validation.md)                             |

`README.md` 只负责项目入口与快速开始，不是规范。

## 工作方式

- 开始修改前检查工作树，保留用户已有改动，不清理或覆盖无关文件。
- 同一个根因涉及的代码、测试、allowlist 和文档一次收完整；不要拆成只改名字、只搬文件或留半套兼容层的连续小变更。
- 删除已经失去职责的实现、fixture 和阶段文档；Git 历史负责恢复，不建立 active archive、第二份规范或“以防万一”的平行路径。
- 已批准或挂起决策引用的文档路径是稳定身份，即使文件尚未提交也不得被其他议题同名覆盖；新议题必须使用独立文件名。只有显式 supersede 决策才能替换原路径语义，并须同步修正所有引用。
- 只有形成独立 owner 或可测试不变量时才拆模块；不为行数、目标目录树或未来 capability 创建空层。
- 机器 identifier、外部路径、symbol 和 wire name 保持精确；产品与说明文字使用 MetaWork、Metask 和 Metask AgentCore。
- `app.zon` 是 MetaWork release version 真源；根 npm、Renderer 和 Zig package 版本必须精确镜像。Bridge、persistence、AgentCore ABI 与 bundle schema 不随产品版本联动。任何合同类版本标识的变更都必须先得到用户显式同意。
- 变更规范时同步检查实现和验证影响；变更实现时检查对应 source of truth 是否仍准确。

## 架构护栏

### Renderer 与 Bridge

- React + Tailwind 是唯一正式 Renderer；不建立 `.native` 替代层、第二套 Renderer 或通用 Desktop Interface。
- `src/app.zig` 与 `src/app/` 共同构成 Application；代码中的组合类型保持名为 `App`。`app.zig` 只保留 Native SDK `App` vtable、装配顺序、`run()` 与顶层生命周期顺序；平台适配、bootstrap resolver、store 生命周期和跨 owner 用例编排必须进入 `src/app/` 的具名实现。Application 不成为业务 owner，也不增加统一 facade。
- Native SDK 与 Metask AgentCore 都是外部依赖。原生窗口机制由 Application 通过 Native SDK 执行；React 只负责 WebUI，涉及产品语义的决策归对应 owner。Renderer 可以呈现一体化标题/命令栏并提交白名单化意图，但不得持有原生窗口身份、模拟平台行为或把本地推测作为平台真相。
- `src/native_sdk_compat/system_webview_drag_region.zig` 只是在 Native SDK 尚未提供官方 System WebView drag-region 时补齐单一启动窗口标题栏能力的窄 capability seam；其平台子文件独占对应低层调用、窗口身份与资源 teardown。该 seam 不得扩展成通用 Desktop Interface、第二套窗口 owner 或 Renderer 可调用的任意原生 API。官方 Runtime API 经目标平台验收可用后必须原位替换该 seam，并同步删除平台子文件及收口不再需要的专用 command、allowlist 和测试。
- Renderer Bridge 产品合同是 `metawork.renderer-bridge` 固定 revision 1。快速开发阶段直接原地 hard cut command、event、payload 与 wire 语义；不得为临时合同形态递增 revision、保留兼容层或在 snapshot 内建立局部 schema version。`connect` 精确匹配 identity/revision 后才开放产品路径；任何 revision 变更必须先得到用户显式同意。
- `app.zon`、Zig 和 TypeScript command catalog 必须完全一致。Renderer 对 Host payload 做 runtime decode；Host 执行 origin、command、payload、Workspace、Task 和权限校验。
- Bridge 只拥有 command ingress 与 `ProductDelivery` transport；产品状态和 Run policy 归 Workbench。automation 只能驱动真实产品路径，不注册测试专用协议或第二数据面。

### Native SDK 能力路径

- 对窗口、WebView、生命周期和其他系统 effect，Native SDK Runtime API 已提供且可用时必须使用 Runtime API。Bridge 可以消费正式 Native SDK Bridge transport contract，以及完成 transport authority 和窄 Host capability 调用所必需的 data-only DTO/opaque identifier；这些值不得授予直接系统执行权或传播到 Product owner。
- 低层 SDK 原语或 Win32/AppKit/GTK API 只能存在于 [高层架构](docs/architecture.md#35-native-sdk)和[验证规范](docs/validation.md#native-sdk-能力路径)逐项登记的 Application compatibility seam。每条 seam 只补一个 SDK 缺口，并独立 allowlist、验证和删除；禁止文件级或目录级宽泛放行，现存违规不得作为新增依赖的先例。
- Product 和 Renderer 不得依赖 Native SDK 系统能力类型；Bridge 不得持有原始 `PlatformServices`、具体平台实现类型、系统 handle 或底层调用权。任何 MetaWork 代码都不得访问、解释或强转 `PlatformServices.context`。Application 只能向 Bridge 或对应 owner 注入其职责所需的 MetaWork-owned 窄 capability。

### AgentCore 依赖

- 正式应用只消费 canonical `.agentcore/bundles/<target-id>` 及其中的官方 `bindings/zig` package。外部 bundle root 只用于 candidate probe/stage；禁止源码依赖、源码复制、Git/path implementation dependency、`latest`、可变 tag 和静默 fallback。
- Metask AgentCore 是 binary ABI facade 和 Agent 结构化协议的唯一 owner。MetaWork 不复制 ABI code、event tag、UI JSON schema，不维护上游 facade/SDK 的平行测试套件，也不建立 `AgentEvent` / `WorkbenchEvent` 镜像协议。
- 正式 Host 只使用 bundle SDK 校验后的 typed `Status`、`StopReason`、`CoreEvent`、`UiRequest` 和 `UiResponse`。unknown、malformed、ownership 或 notification failure 必须 fail closed；详细处理以 AgentCore 两份 source of truth 为准。
- 当前产品不注册 ABI v1 Host tools；实际工具集合只使用 AgentCore built-in，精确名单由 AgentCore 集成契约定义，`AskUserQuestion` 不进入产品集合。MetaWork 不以 PTY/xterm、终端字节流或 Provider SSE 作为 Agent 协议；`src/agent/completion*` 只为独立无 Tool Completion 能力解析 Anthropic、OpenAI、Gemini 的有界非流式 JSON 响应，该路径不进入 AgentCore Run/Event 协议。

### Owner、并发与生命周期

- Application 只做 composition、平台 capability 注入、平台生命周期驱动和跨 owner 用例编排；编排实现不得持有领域状态或复制 owner policy。Account 拥有 credential 与 ExecutionConfig；Workbench 拥有 Workspace/Task/Run、Executor 和产品历史；Agent 拥有 Runtime/Session/Conversation；Bridge 拥有 Renderer transport。`src/agent/`、`src/workbench/`、`src/product/account/` 与 `src/bridge/` 不得反向导入 `src/app/` 实现。
- Workbench 独占 executor、queue、workers、admission 和 shutdown。Agent Runtime 不接收 Scheduler capability，不反向 enqueue 或销毁 Workbench 资源。
- 每个 Session 至多一个 in-flight Run；队列和 worker 数量必须有界。Conversation 与跨 Run 状态属于 Session，不能引用 run-scoped arena。
- AgentCore/tool 线程不得调用 WebView。跨 callback 保留的 borrowed bytes 必须在返回前深拷贝；control event 不得静默丢弃。
- shutdown 必须先停止 ingress、唤醒 wait、abort/join 并等待 callback quiescence，再断开 owner，最后释放 transport 和 Runtime。不得用 transport failure 直接伪造 Run cause。

### Account、安全与能力声明

- production provider、model、base URL 和 API Key 只来自已锁定的 Metask Account contract；禁止环境默认值、Renderer 字段或 Bridge payload 注入。
- credential 只由 Host Account 和 Workbench-owned runtime config 持有，不得进入 Renderer、Bridge、日志、event、snapshot 或产品历史。
- 当前只允许临时或用户明确 trusted 的 Workspace。strict Workspace security、持久 permission、正式 Host tools、plan approval、custom UI、Output 和 FileChange 未通过能力验收前必须隐藏，不得由 Renderer 猜测或模拟。
- 当前应用仍是同进程 prototype。单 AgentCore Worker 是后续方向；Worker 落地前不得宣称具备进程隔离、crash recovery 或跨进程 Conversation 恢复。

## 文档变更路由

- 产品需求变化更新 `docs/requirements.md`。
- UI 交互规则变化更新 `docs/workbench-ui-design.md`。
- 顶层技术决策、模块职责、进程或安全边界变化更新 `docs/architecture.md`。
- Product 跨 owner 事务、并发、恢复或其与 Agent 的产品协作变化更新 `docs/product-architecture.md`；Account owner、Metask OAuth/catalog/ExecutionTarget 消费合同、状态、事务、持久化、提交、并发或恢复变化更新 `docs/account-architecture.md`；实际目录和依赖变化更新 `docs/project-structure.md`。
- Renderer Bridge command、event、Snapshot 或 transport 语义变化更新 `docs/renderer-bridge-contract.md`。
- AgentCore Session、工具集合、Skill catalog binding、Permission、线程、所有权、生命周期和 Shell 行为变化更新 `docs/agentcore-integration.md`。
- AgentCore ABI、bundle、required capability 或兼容门槛变化更新 `docs/agentcore-abi-v1.md`。
- 测试层与归属、验收矩阵、长期证据、持续回归入口和能力缺口变化更新 `docs/validation.md`。
- 同一事实只在一份规范中定义；其他文档链接或做不产生新语义的摘要。

## 验证规则

新增或修改测试时，先按[验证规范的测试归属规则](docs/validation.md#测试归属)确定 source of truth、不变量 owner、唯一失败模式和最小充分测试层；测试文件位置不能反向决定 owner。执行验证时按实际失败模式选择最小充分范围，不按“碰过某类文件”机械扩大平台矩阵：

- 纯文档删除或改写：检查链接、锚点、残留引用和 `git diff --check`；不运行 runtime 测试。
- Renderer/TypeScript：运行 typecheck 与受影响的 Renderer suite；合同变化同时运行跨语言 fixture 和 Bridge tests。
- 平台无关 Zig：运行对应 Zig test root；共享 owner 或 module graph 变化运行正式 Native test graph。
- 架构、allowlist 或 bundle verifier：运行 architecture/bundle guard，以及能命中该失败模式的当前平台 build/probe。
- lifecycle、真实 ProductDelivery 或 AgentCore 调用链：运行对应 lifecycle/vertical；只有存在独立平台失败模式时才追加 macOS 或 Windows 验证。
- 不能仅因修改了 `build.zig`、脚本名或 lock 路径就要求全平台回归。若错误会在下一次 build/test 中 fail closed 且平台无差异，当前平台验证即可。

标准命令和平台矩阵以 [docs/validation.md](docs/validation.md) 为准。缺少 canonical staged bundle 时必须明确失败，不能跳过 AgentCore 用例后报告成功。普通可重现测试结果不写入长期证据账本；报告中只声明实际执行过的命令与结果。

# MetaWork Renderer Bridge 合同

> 状态：`metawork.renderer-bridge` 固定 revision 1
> 日期：2026-08-07

顶层模块职责见 [MetaWork 高层架构](architecture.md)，用户可见的信息架构、交互与视觉见 [UI 设计规范](ui-design.md)。本文件是 Renderer 与 Product 之间 command、event、Snapshot、连接与运输语义的唯一架构真源；具体源码目录见 [工程结构与所有权](project-structure.md)，持续验收入口见 [验证规范](validation.md)。

## 1. Bridge 定位

Bridge 是 Renderer 与 Host 之间唯一的产品命令和 Product projection 边界，承运两类 surface。产品命令面：验证调用来源与启动窗口 identity、严格解码 payload、把合法输入转换为产品命令、dispatch 给 Product 中对应 owner、编码 typed result，并通过 Snapshot/Event 运输发布产品投影；Bridge 不决定 Task 是否可以运行、Workspace 是否有效、Agent 是否应取消、credential 是否可以替换或历史如何持久化，这些判断必须由 Product 内对应 owner 完成。受限平台 capability 面只承运已登记的 window-chrome bootstrap 与 external-link handoff capability，dispatch 给 Application 执行，原生行为与真实状态由 Native SDK/OS 拥有。两面共用同一 transport、origin policy 与 source/window authority，不共用数据面；新增平台面 command 必须与 capability seam 同级登记（identity、SDK 缺口、删除条件），不因该面已存在而豁免。

Renderer 的可信定位与 Native SDK WebView UI/input 边界以[高层架构](architecture.md#31-renderer)为准。Bridge 的严格 command catalog、runtime decode、source/window 校验、CAS 与 Product admission 用于维护 owner、处理陈旧 UI 状态、隔离实现错误并拒绝畸形输入。本地路径等输入只有在具体领域合同明确登记时才能通过容量有界的 typed command 转交，Host 仍独立校验文件类型、范围、当前 authority 与生命周期；这不形成 generic file、process 或 OS action command。

Task binding projection 只运输 `epoch + availability + protocol + model + executionGeneration + unavailableReason`。Scheduled Task 的 `binding` 精确为 `{ status: "bound", modelRef, sourceGeneration, selectionRevision, protocol }`，没有其他判别分支。两处 protocol 均精确取 `openai_responses | openai_chat_completions | anthropic_messages | gemini_native`，不发布厂商类别。revision 1 对这些 shape 原地 hard cut，旧 Scheduled Task `execution`、旧 `provider` 与 migration shape 既不接受也不归一化。`unavailableReason` 当前只有 `runtime_detached`，表示恢复历史没有进程内 Session/ExecutionConfig；Task projection 不包含 account identity、API Key selection/metadata、Custom Provider identity/generation、credential locator 或完整 ExecutionConfig，也不得用当前 Account/Models projection 为历史 Task 补写这些字段。

Bridge 的唯一产品数据面由具体 `Dispatcher` 内部的 `ProductDelivery` 统一拥有：connection generation、revision retry/timer、snapshot identity 和 snapshot transport storage 都不再存放在 `app.zig`。Dispatcher 通过明确的 `*product_control.Runtime` 同步生成 snapshot；Application 只注入 Native emit/timer/dialog/window-chrome/main-thread capability，并组织 Bridge、Product、Agent 与 Native SDK 的顶层 shutdown；Agent event 的产品投影和固定终态 drain 屏障由 Product Control 执行，Application 只安排 main-loop 调用。

`hidden_inset_tall` 的 System WebView window chrome 是独立于 ProductDelivery connection 的受限 Host bootstrap capability。browser-side Bridge 使用既有 `window.zero.invoke` transport 调用 `metawork.host.windowChrome.connect/refresh/gesture/control/disconnect`。`connect` 接受空 payload，返回 document generation、top band/safe insets、caption-button bounds、`rendererControls`、`maximized` 与 `gestureMode: browser_mouse | native_press | disabled`；`refresh` 只接受 `{ generation }` 并返回同一环境格式，不接受 viewport 或 DOM 区域。`gesture` 严格接受 `{ generation, action: "start_drag" | "toggle_maximize", x, y }`，坐标必须有限且在 `[0, 65536]` 内；旧 pointer command、phase 和额外字段不接受。`control` 只接受同 generation 的 `minimize | toggle_maximize | close`。gesture/control 成功返回严格的 `{ generation, handled: true }`，只表示受理，不保证原生交互完成。`disconnect` 精确撤销当前 generation，返回 `{ generation, detached: true }`。所有响应均须 runtime decode；只有 connect/refresh 可更新 CSS variables/document dataset。React 只登记标题栏真实 DOM 节点及清理，不消费 DTO、调用 transport、持有原生 identity 或维护窗口状态。

Bridge policy 约束 origin，Dispatcher 校验单一启动窗口 identity、generation、严格 payload 与主线程；generation 只归 Dispatcher。connect 建立文档会话，其他命令必须绑定该会话，不因 resize、layout 或动作失败隐式 reconnect。SDK 正式 resize event、可能改变状态的 gesture/control 处理后及重新获得焦点时调度 refresh；最多一个在途读取，期间的需求合并为后续读取，新动作/原生变化/卸载使之前的读取失效。刷新失败保留最后确认的 controls/session，不重放动作；手势不等待 refresh。卸载须移除监听并撤销连接，迟到 connect 只能清理自身 generation，不能重新安装或覆盖新 UI。

browser-side Bridge 仅在实际标题栏绑定原生监听，沿 composedPath 完整祖先链排除交互/inert/no-drag 内容；不观察全页按下、不镜像区域，业务事件自身零窗口命令。Windows `browser_mouse` 模式下可信主键 mousedown 的 detail 精确为 1 请求 start_drag、精确为 2 请求 toggle_maximize，其他计数忽略；只有有效动作才取消默认行为并停止该次传播。Host 不保存首击历史、不自行计时配对，不接收业务/blur/边缘 reset；浏览器可能在插入事件或失焦后继续给出 2，应用不保证强制中断。两种动作都用实际 OS 光标、逻辑主键、已绑定 root、native hit 与 DPI 重新授权，检查 `0 ≤ clientLogicalY < chrome_top`；Renderer 坐标只作有界格式输入，不授予执行权。start_drag 进入系统 caption move loop，toggle 经既有 window-controls owner 执行。macOS `native_press` 只在可信 primary pointerdown 请求 start_drag，不额外取消默认行为；Host 拒绝该模式下的 gesture toggle，检查 SDK top band 后调用 `startWindowDrag`，由 AppKit 与系统偏好处理双击。disabled 或无可用 top band 不执行手势。有效范围是 DOM 候选与原生 top-band 的交集，不保证缩放后的整个视觉 header 都获得授权。

minimize 使用 Native SDK Runtime API；尚未正式覆盖的 maximize/restore、user-close 和 maximized fact 由独立登记的 window-controls seam 补齐，user-close 必须进入 `close_policy = hide`。该 capability 不接受 HWND、任意 window id、platform、任意 action 或脱离会话的查询，不形成通用窗口 facade、第二窗口 owner 或第二产品数据面。原生机制、真实状态与生命周期仍由 SDK/OS 拥有；官方等价能力经平台验收后在 revision 1 原位替换，并删除失去职责的 seam、命令、allowlist、DTO 和测试。automation 只驱动真实产品路径，不注册测试专用协议。

Windows 窗口动作执行前读取 SDK 当前窗口事实：connect/refresh 要求主窗口仍打开，允许已隐藏；minimize、toggle、user-close 与两种 gesture 还要求未隐藏。最大化按钮与标题栏手势共用执行原语，但 gesture 必须先通过实时原生输入授权，不转发到按钮入口绕过校验。Runtime、窗口或 binding 不可用时返回错误，不投影虚假的 maximized=false。旧 generation、错误 identity 仍在 Bridge 拒绝；失败不重试、不重放、不维护点击历史。disconnect 不新增 Runtime/可见性要求；托盘 Open/Quit 保留 SDK 流程。Windows connect 只读检查先于 attachment，refresh 失败保留会话。close ACK 只表示投递；已隐藏后受理的标题栏动作必须拒绝，不承诺撤销此前受理的 OS 请求。这些 Windows 前提不扩展到 macOS 原有路径。

外部链接只通过 `metawork.host.links.openExternal` 打开。payload 精确为 `{ url }`，URL 的 UTF-8 长度上限为 4096 bytes；Host 在已连接的启动窗口与主线程上重新校验，只接受不含空白、控制字符、反斜杠或 userinfo 的绝对 `http`/`https` URL，以及非空且不含 CR/LF 注入的 `mailto` URL。结果精确为 `{ outcome: "opened" | "rejected" | "unavailable" }`：`opened` 只表示系统 handler 已接收请求，`rejected` 表示目标不满足闭合策略，`unavailable` 表示平台能力或系统 handler 失败。结构错误、额外字段、不可信 origin、未连接或错误 window 仍是 Bridge error。该命令不允许 `file`、自定义 scheme、相对地址、任意导航、URL 日志、重试或 fallback；Renderer 必须在点击时同步阻止 WebView 默认导航，严格解码结果，并把非 `opened` 与 transport failure 就地呈现。

## 2. ProductDelivery 与 Snapshot transport

Host view snapshot 使用 Bridge `Dispatcher` 内部 `ProductDelivery` 独占的 64 MiB 有界存储，不受 Bridge 单次 1 MiB result 上限反向约束。该容量覆盖 512 KiB Task projection、最大 Models provider/API Key/model catalog、bounded Custom Provider projection、Workspace/Task Skill catalog 结构、JSON 最坏转义和全部结构上界。Dispatcher 同时拥有 callback gate、workspace grants、handler registry 和 `*product_control.Runtime`，产品 command 的 decode、authority、domain call 与 response encode 不再经过 `app.zig`。Product Control writer 只能在同步调用期间借用这块 output buffer；返回后 Bridge 独占 encoded bytes，禁止保存 Product Control borrowed view。Renderer 通过带 snapshot identity 的 256 KiB 分块读取完成 resync；begin 写入前先使旧 descriptor 失效，序列化失败后旧 identity 必须保持 stale，不能继续读取已被部分覆盖的 store。Host 独占 revision 通知投递的 pending/retry 状态；Renderer 独占快照拉取的需求合并、在途读取与有限重试。Host revision retry 同时受 attempt 和 deadline 预算约束，耗尽或 retry timer 不可用时当前 event connection fail closed，但不终止后台 Agent Run。

Renderer 在读取开始时冻结该次 revision 目标，读取期间的新通知只产生后续需求；合格读取无需追上未来通知，也不因正常滞后消耗失败预算。空闲后的通知按固定窗口合并，持续通知不能推迟首次读取。显式刷新只有在调用之后开始的合格读取被当前连接消费后才能完成，不等待整条追赶链；在途失败与退避期间到达的等待者共享同一份有限重试预算。预算耗尽、合同故障、停止、断开及等待期间 generation 被替换均须明确拒绝，不得零读取返回成功或把旧等待者转移到新连接。

连接层独占 readiness：新 generation 必须完成有效握手、真实首读与 ping，不能把等待旧 Promise 误判为同步成功；后续正常 pending 不撤销已确认的 readiness，最终命令 admission 仍属于 Host。新 event generation 建立时使旧 snapshot descriptor 失效；读取与 ACK、ping、定时及清理回调均须校验所属连接，旧异步结果不能影响新连接、复活 stopped 连接或清除合同故障。

显式恢复先在现有 generation 内进行一轮有界同步；普通读取失败升级为一次连接重建与新首读、ping，不依赖错误字符串判断 Host 是否仍保有连接，不嵌套重建循环。断开或明确要求连接替换时直接重建；合同故障不按普通读取故障自动重试。普通刷新不隐式重建。保留 generation 的恢复不取消在途附件或重置审批观测，真正重建沿用 connection-bound authority 的撤销语义。恢复升级之间不发布中间终态故障；全部恢复失败才发布最终故障，合同故障仍及时呈现。

Bridge 异步保留的 payload 必须自有；Application 在 shutdown 时先 stop Bridge ingress，在 Native platform loop 上确认同步 handler quiescence，再关闭 delivery connection、取消 timer，并 detach Product Control；随后依次收口 Account/Models coordinator、Product Control 与 Agent，完成 terminal drain/lifecycle sync，最后才独立释放 delivery buffers。

## 3. Renderer Bridge wire contract

根 snapshot 必须独立发布 `automaticWorkspaceRoot = { generation, mode, canonicalRoot, health, redacted, canChoose, canReset, canRetry }`。`generation` 是非零 canonical decimal wire integer；`mode = system_default | custom | null`，只有 Host 拥有可信配置时非空；`canonicalRoot` 是当前可信 effective canonical path 或 null；`health = ready | path_unavailable | persistence_unavailable | read_failed | corrupt | write_failed | outcome_unknown`。`redacted` 只表示 Host credential redaction 是否改写了可发布路径；不得用占位路径伪造可信 root。三个 action boolean 由 Workspace owner 根据当前 health 一次性计算，Renderer 不从 mode/health 反推。既有 `capabilities.automaticWorkspaces` 仍只表达当前能否分配新 Automatic Workspace，不承担配置诊断。

Host-only command 精确为 `metawork.workspaces.chooseAutomaticRoot`、`metawork.workspaces.resetAutomaticRoot` 和 `metawork.workspaces.retryAutomaticRoot`，payload 都只接受 `{ expectedGeneration }`。Choose 在 Application 内打开原生目录选择器，Renderer 不得提交 path、bookmark、token 或 mode；取消不产生 mutation。Reset 恢复 Native SDK `.data` 解析的 system default，Retry 只重新校验并打开已提交 root，不改写配置。三者都必须在 Product/Workspace transaction 内重新校验 generation、health、path 和 registry 冲突，结果与 Snapshot revision 遵守既有 command/resync 语义；Renderer 不做乐观路径替换。

Run 的 `elapsedMs` 是 nullable canonical decimal `u64` string，表示从本轮接纳起经过的单调时间，包含排队、批准等待和重试。active Run 发布 Host 在本次 Snapshot 的采样值，时钟推进不发布 revision；Renderer 只从本次 Snapshot 的本地接收时刻低频外推，reload 必须重新采样，不能从组件挂载时起算或将显示时间写回 Host。Product 在完整 terminal event-drain barrier 首次形成正式终态时用同一单调时钟冻结最终值，随 Run 历史持久化且写入后不可修改；terminal Run 的 Renderer 不再外推。时钟不可用以及字段引入前的历史记录保持 null，不用 wall-clock 时间、Snapshot 接收时间或 Tool elapsed 迁移、反推或补写。该字段不是事件活跃度、完成比例或剩余时间。

Run 的 `submittedAtUnixMs` 是 nullable canonical decimal `u64` string，表示 Product 接纳该 Run 输入时观察到的 Unix epoch 毫秒。该字段适用于 active 与 terminal Run，并随 Run 历史持久化；时钟不可用以及字段引入前的历史记录保持 null，不做迁移，不允许 Renderer 以完成时间、Snapshot 接收时间、Run 顺序、Run ID 或 `elapsedMs` 反推。非空值必须大于零且不超过 ECMAScript Date 上界 `8640000000000000`，写入后不可修改；Renderer 只进行本地化相对时间呈现，不把它解释为 Agent 开始执行、事件时间线或执行耗时。

Run 的 `finishedAtUnixMs` 是 nullable canonical decimal `u64` string，表示 Product 在完整 terminal event-drain barrier 后首次把该 Run 收口为正式终态时观察到的 Unix epoch 毫秒。非 terminal Run 必须为 null；时钟不可用以及该字段引入前的历史记录继续为 null，不允许 Renderer 以 Snapshot 接收、reload、Run 顺序或 `elapsedMs` 反推。非空值必须大于零且不超过 ECMAScript Date 上界 `8640000000000000`，随 Run 历史持久化且写入后不可修改；Renderer 只进行本地化相对时间呈现，绝不把它解释为事件时间线或执行耗时。

`metawork.tasks.create` 的 execution admission 字段精确为 `expectedExecutionGeneration + expectedSelectionRevision + modelSelection`，三者必须同时存在，其中前两者来自同一份根 `newTaskAdmission` snapshot 且均为非零 canonical wire id。`modelSelection` 精确为 `null | { targetModelRef: { sourceId, modelId }, expectedSourceGeneration, expectedCatalogGeneration }`：null 表示采用 active default；非 null 表示只为本次新 Task 选择同一 active source 中的另一个当前 ready 模型。Host 在创建事务中同时 compare-and-swap当前 active generation 与 selection revision，并对 override 重新校验 active source、protocol、source generation 与 catalog generation/membership；缺字段、revision/generation 已变化、跨 source 或模型已失效均 fail closed，绝不回退默认模型。这样同一 execution authority 内默认模型变化可以保持 generation 稳定，同时不会让旧 Renderer snapshot 静默采用新的默认模型，也不会把单 Task 选择写回 global default。

每个 Task 根对象必须发布 Host-owned `modelSelectionAvailability`，精确取 `available | catalog_loading | catalog_unavailable | execution_replacing | runtime_detached | unsupported_source | authority_changed`。Product Control 根据 Task binding、当前 installed execution、replacement 与 Models catalog 的跨 owner 事实一次性计算；Renderer 只消费该枚举决定菜单可编辑、暂时禁用或只读及其原因，不得再比较根 `models`、`newTaskAdmission` 与 Task 字段重建 authority。缺失或未知值属于 snapshot contract failure。

Host 与 Renderer 随同一应用包原子发布，不承担旧 Renderer/新 Host 或新 Renderer/旧 Host 的兼容。bootstrap 必须拒绝合同 identity 或经用户批准后出现的 revision 错配；固定 revision 策略下，`connect` 无法通过 revision 数字识别同 revision 的陈旧开发产物。严格 command catalog 和 payload decoder 只能在实际命令或结构差异被触及时失败，不能检测纯 wire 语义错配。此类错配属于 unsupported development state，必须通过 clean rebuild、清理缓存或重新安装恢复；原子打包用于降低发生概率，不构成 runtime compatibility guarantee。Renderer Bridge contract 覆盖全部 product command、event 和 snapshot wire surface；它与产品版本、AgentCore ABI、bundle manifest schema 相互独立。

Renderer Bridge 使用独立合同身份 `metawork.renderer-bridge`，快速开发阶段固定 revision 为 `1`。Host 与 Renderer 随同一应用包原子发布，任何 command、event、payload 字段或 wire 语义变化都直接原地 hard cut，不为临时合同形态递增 revision、不维护兼容层，也不在 snapshot 内维护第二个局部版本。`contractRevision` 仍精确匹配，用于拒绝非当前固定标识，但不承诺识别同 revision 的开发产物错配。任何合同类版本标识的变更都必须先得到用户显式同意；对本文件即包括 Renderer Bridge revision。

Run snapshot 已在 revision 1 内原地 hard cut 删除自由文本 `assistant`、`assistantRedacted`、`status`，以及 Run 顶层 `outcome/cause` 与 Task 顶层 `lastRunOutcome/cause`。每个 Run 精确发布 `execution + elapsedMs + submittedAtUnixMs + finishedAtUnixMs + output + activity + terminal`：`execution = { generation, protocol, model }`，generation 是非零 canonical decimal wire integer，protocol 为合同既有封闭枚举，model 是该 Run 实际持有的无 secret model identity；它们是不可由 Task 当前 binding 或 Models 当前默认值补写的逐 Run 历史 provenance。Task 最近结果由最后一个非空 Run terminal 派生，不发布第二份摘要。

`output = { commentary, response, responseKind, provisional, redacted, provisionalRedacted }`，其中 `commentary` 是最多 256 项的有序 string array，每一项对应一个非空、已闭合的 Product commentary group；数组顺序只表达 Run 内的稳定叙事顺序，不运输时间戳、CoreEvent identity、Tool 关联或 raw event timeline。credential 清洗跨整个 canonical output 一次完成，可以使个别投影项为空，但不得改变项数或泄漏跨边界 credential。`responseKind = final | partial | null`；null 时 response 必须为空，分类后的 response 不得同时保留 provisional，terminal Run 的 provisional 必须为空。全部 commentary 项、response 与 provisional 来自同一个 Host output byte budget；provisional 只包含 open/continued buffer 中 credential-safe committed bytes，discard 后必须消失。

`activity` 是 nullable discriminated union：简单 kind 为 `queued | starting | waiting_model | thinking | writing_response | waiting_user | compacting_context | finalizing | stopping`；`executing_tools.inFlight` 为 nullable canonical decimal wire integer string，非空时必须为正数；`retrying_provider.attempt/max/delayMs` 要么全部为空、要么都是 canonical decimal wire integer string，attempt/max 为正数、delayMs 可为零且 attempt 不超过 max。`terminal` 精确为 `null | { outcome, cause, diagnosticDisposition }`；非 terminal Run 必须具有 activity 且 terminal 为 null，terminal Run 必须没有 activity且 terminal 非空，phase 与 outcome 必须一致。`cause` 保留 Product 已知的稳定分类。`diagnosticDisposition = absent | withheld`：absent 表示 Agent/Provider 终态没有附加诊断，withheld 表示 Host 接收过非空、被截断或被 credential 清洗的附加诊断，但这些内容按安全边界只留在 Host，不进入 snapshot。该字段不证明诊断的具体类别，也不得被 Renderer 扩写成鉴权、限流、网络或配置结论。AgentCore `api_error`、`tool_error` 与 `image_input_unsupported` 分别映射为 Product `provider_failure`、`tool_failure` 与 `image_input_unsupported`，不得折叠成 `agent_failure` 或把 provider raw diagnostic 发布给 Renderer。queued、waiting_ui、stopping phase 分别只接受 queued、waiting_user、stopping activity。旧字段、缺失 execution/terminal 或额外兼容 shape 一律由严格 decoder 拒绝，不归一化、不 fallback。

每个 Run 另精确发布 `fileChanges = null | { observation, changes }`。null 表示没有建立 typed observation，不能解释为“确认没有修改”；observation 只取 `collecting | complete | incomplete`。`changes[]` entry 精确为 `{ id, order, kind, status, displayPath, fromDisplayPath, beforeBytes, afterBytes, diffAvailable, diffComplete, redacted }`：id 是 Run 内 opaque identity，order、beforeBytes、afterBytes 是 canonical decimal `u64` string；kind 只取 `created | modified | deleted | moved`，status 只取 `applied | partial`，fromDisplayPath 只在 moved 时非空，其余安全标志均为 boolean。同一 Run 的 id 和 order 必须唯一并按 order 严格递增；同路径多次记录不得合并。该投影不运输 raw locator、absolute path、AgentCore handle、agent depth、unified diff、credential 或文件当前内容。根 capability `typedFileChanges` 为 true 时 Renderer 才可消费此字段。

每个 Task 精确发布 `context = { pressure, lastAutoCompact }`。pressure 为 null，或 `{ sourceRunId, currentTokens, warningThreshold, autoCompactThreshold, blockingLimit, severity }`；lastAutoCompact 为 null，或 `{ sourceRunId, dropped, kept, beforeTokens, afterTokens }`。所有计量使用 canonical decimal wire integer，sourceRunId 必须引用同一 Task 的 Run history；threshold 顺序、severity 与 token 数必须一致。context 属于当前 attached Conversation，可跨同一 Session 的 Run 保留，但 Task detach/replacement/restart 后两项均为空，且 detached Task 不得发布 observation。该 surface 不运输 raw CoreEvent tag、transition sequence、private reasoning、provider diagnostic 或 `file_changes`。

Tool 的 `bash` 必填且 nullable，只由 Host 为精确 `Bash` identifier 投影：`{ command: string | null, description: string | null, result: null | { exitCode: i32, stdout: string, stderr: string, stdoutIncomplete: boolean, stderrIncomplete: boolean } }`。description 依附已解析的 command；运行中的 Tool 或截断的原始 content 不得提供 result，截断的 input 不得提供 command。未知、超出解析预算或不完整的 envelope 保留原始安全证据而不猜测可读字段；解码后的文本仍受 credential 清洗。DTO 不改变 Tool state、Run activity、terminal、fileRefs 或持久化格式。

Tool 另必填 `presentation` 与 `errorDetail`。`presentation` 为 null，或仅由 Host 按精确 built-in identifier 投影的 discriminated union：`read { target, offset, limit }`、`write|edit { target }`、`glob { pattern, scope }`、`grep { pattern, scope, include }`、`bash_output { jobId, result }`、`kill_shell { jobId }`、`web_search { query }`、`web_fetch { url, prompt, result }`；nullable 数字以 canonical decimal `u64` string 发布。`bash_output.result` 精确包含闭合 status `running | exited | killed`、stdout/stderr 与各自 incomplete 标志；`web_fetch.result` 精确包含 url、nullable bytes 与正文。截断 input 不得携带 presentation，运行中或截断 content 不得携带 result。解析失败保持 presentation null，由安全原始字段兜底，不在 Renderer 猜测。`errorDetail` 为 nullable string，只允许 failed Tool，由 Host 从已知错误 envelope 提取并再次 credential 清洗；无法解释时保持 null。上述字段不进入持久化格式，也不建立第二套 Tool identity 或 executor。

`output`、`activity`、`tools` 与 `context` 只定义 Renderer 可消费的产品事实和 fail-closed 边界，不规定最终组件、布局、展开策略或更新节奏。当前 Agent 对话的 owner 链、Run exchange 槽位、active→terminal 呈现收口和 full Snapshot 渲染机制由 [UI 设计规范](ui-design.md#72-agent-对话渲染机制)定义；wire 字段存在、scripted Provider vertical 或静态 DOM 通过都不能替代真实 Provider cadence 与长任务阅读体验的独立验收。后续纯呈现调整仍可在不改变 revision 1 wire 语义的前提下进行。

## Skill source settings

revision 1 的 Skill 来源设置提供两个 typed 写入口：`metawork.skills.setSourceEnabled` 的 payload 精确为 `{ sourceId, enabled, expectedRevision }`，sourceId 仅为品牌 `claude | codex`，Host 在一次 CAS/持久提交中将该品牌的个人和项目来源同时设为 enabled；拒绝逐根 ID、目录路径或 Workspace target，不提供旧逐目录写入兼容路径。`metawork.skills.recoverSourceSettings` 精确为 `{ action, expectedRecoveryToken }`，action 仅为 `reread | reset`。revision/token 是非零 canonical decimal u64。结果精确为 `{ applied, revision, reason }`；成功（含两个值均未变化的 no-op）给出可信 revision 与 null reason，失败给出 null revision 与闭合原因。no-op 不写盘、不调度、不通知；失败若改变 health、token 或 authority 仍发布 Product revision。保存成功不表示查询成功。超时只 resync，不自动重放。

原因仅为 `stale_revision | busy | source_settings_unavailable | write_failed | persistence_outcome_unknown | stale_recovery_token | recovery_not_allowed | read_failed | revision_exhausted | shutting_down`。Renderer 不能将失败的 null revision 覆盖 committed 选择，不能用恢复按钮绕过 Host 对新鲜恢复 token 和实际文件状态的校验。

`skillManagement.sourceSettings` 精确发布 `{ revision, health, entries, recovery }`。entries 恰好包含四个唯一固定 ID，每项为 `{ sourceId, enabled, canSetEnabled }`；可信值的 revision 非空且 enabled 为 boolean，未知值均为 null 且不可操作。health 为 `unavailable | ready | read_failed | corrupt | missing | unsupported_schema | too_large | write_failed | outcome_unknown`；仅 ready 或明确 write_failed 可以持有可信旧值。recovery 为 `{ canReread, canReset, token }`，token 仅可重读时非空；reset 仅可在未知且 corrupt/missing 的可重读状态开放，不以读取失败、超限或不支持格式冒充损坏。

`skillManagement.personalSourceDiscovery` 与 `workspaces[].skillSourceDiscovery` 是 nullable 根检查数组。非 null 时分别含完整的三个/六个逻辑根：个人/项目默认 `agents.user.default`、`agents.workspace.default` 与适用兼容 ID；每项 `{ sourceId, state, reason }`，state 为 `disabled | checking | missing | checked | error`，reason 仅 error 时为 `unreadable | unsupported_entry | changed`。关闭的兼容根为 disabled，默认根不能 disabled。未知配置、无可用 base、非已授权 Manual Workspace 不得伪造检测结果。checked 只表示根检查通过；Skill winner、冲突和查询健康仍消费既有 catalog。共享 `SkillCatalogView` 与 Task pinned catalog shape 不扩展。

`skillManagement.assets[].origin` 为 null 或 `{ ecosystem: agents | claude | codex, scope: personal | project }`；由 Product 通过精确来源关联提供，不代替 asset 的 policy context 或 sourceKind 导入方式。未知 origin 不允许猜测，外部来源不能因 origin 获得文件管理 authority。

`skillManagement.assets[].scope` 精确为 `{ kind: personal | project | external, workspaceId }`，project 时 `workspaceId` 非空，其余为 null；asset 不携带 Workspace epoch。Renderer 只按 `workspaceId` 把 project asset 归入 `workspaces[]` 中的 Workspace；所有携带 `expectedWorkspaceEpoch` 的 command 必须取同一 snapshot 中该 Workspace 的当前 `epoch`。

## File preview command

`metawork.files.preview` 是 revision 1 command catalog 中的异步 command，原地 hard cut 使用 Native SDK async registry；它不出现在同步 handler registry。request 精确为：

```json
{
  "taskId": "17",
  "runId": "23",
  "fileReferenceId": "task:17:run:23:file:1"
}
```

三个字段均不可省略或增加替代字段；Task/Run 必须是 canonical decimal `u64`，reference id 必须是 1–128 bytes 的 opaque identity。Renderer 永不提交文件系统路径、URI、shell command、range、Tool name 或 AgentCore handle。Host 只在精确 Task + Run 内解析 reference，不做全局 reference id 扫描。

response result 精确为：

```json
{
  "state": "ready | missing | restricted | unsupported | changing | error",
  "content": "...",
  "truncated": false,
  "redacted": false
}
```

`loading` 只属于 Renderer 临时状态，不进入 wire。仅 `ready` 可以携带正文与 true 的 `truncated/redacted`；其他状态必须精确返回空 `content` 和两个 false。`changing` 表示同一次有界读取的 before/after metadata 连续两次不稳定，不是 FileChange observation。Host 结果编码必须容纳 256 KiB 正文在 JSON escaping 后仍落在 Native SDK 1 MiB async response 上限内；任一解析、authority、容量或 shutdown failure 都以一次 terminal `error` result 收口，不悬挂 responder，也不改用同步 handler。

Product Control 使用独立 2-worker、最多 8 个 in-flight 的 File Preview lane 执行 no-follow、root-contained、regular-file-only 的有界读取；worker 不持有 Product Control/Bridge/Renderer，不向 Bridge 发布 raw bytes。主线程 completion 在序列化前重新校验 Task、Run、reference、Workspace id/epoch/root/authorization，并扫描当前及历史 Task execution credential（含截断边界前缀）；安全内容只在 callback 期间借给 Bridge，随后 secure-zero。正文不进入 Snapshot、Task persistence、日志或缓存。

Snapshot `tools[].fileRefs[]` entry 精确只含 `{ id, title, displayPath }`。AgentCore 可能提供的 kind/range 只可作为 Host 内部历史事实，不进入当前 Renderer wire，Renderer 也不得将其解释为 Files Changed。

## File changes diff command

`metawork.files.diff` 是 revision 1 command catalog 中的异步 command，不出现在同步 handler registry。request 精确为 `{ "taskId": "17", "runId": "23", "fileChangeId": "task:17:run:23:change:1" }`；三个字段均不可省略，Task/Run 必须是 canonical decimal `u64`，change id 必须是 1–128 bytes opaque identity。Renderer 不提交路径、artifact locator、digest、range 或读取上限；Host 只在精确 Task + Run 内解析 change id。

response 是以下 closed union：

```json
{ "status": "ready", "content": "...", "complete": true, "redacted": false }
```

```json
{
  "status": "unavailable",
  "reason": "not_recorded | capacity | missing | corrupt",
  "content": ""
}
```

只有 `ready` 携带 credential-safe unified diff。`complete` 只说明 AgentCore 对该条 diff 没有声明截断，不等价于 Run observation complete；`redacted` 表示 Host 已替换至少一个 credential。`not_recorded` 覆盖没有 artifact reference、请求 identity 已 stale 或 owner 已消失；`capacity` 表示有界读取 lane 没有接纳请求；`missing/corrupt` 分别表示已记录 artifact 不存在或 identity/size/digest/UTF-8 校验失败。unavailable 不得携带部分正文。

Product Control 使用 File Changes 专用 bounded artifact lane 按 reference 读取，不扫描 Workspace 或 Git。异步 completion 在跨 Bridge 前重新校验 Task、Run、change 与 artifact identity 仍一致；Task/Run 切换、删除、shutdown 或 reference replacement 后的旧结果只能返回 `not_recorded`。任一已接纳请求必须恰好一次 terminal response；正文和 retained payload 必须落在 Native SDK async response 与 shutdown 上界内，不进入 Snapshot、Task persistence、日志或 Renderer 缓存。

## 文件 attachment commands

根 `capabilities.attachments` 精确为 `{ enabled, imageFormats, maxFiles, maxFileBytes, maxStagedBytes }`。`enabled` 为 boolean，`imageFormats` 在开放时精确为有序 `png | jpeg | webp` 数组，表示当前可发送的图片分类；其他 limit 是 canonical decimal `u64` string。Renderer 只用该对象解释入口和本地 admission，Host 对 command 重新执行全部限制；所有已支持图片与其他文件共用 `maxFileBytes`；原件字节计入暂存配额，模型输入的预览/引用预算不投影成第二个文件大小上限。store 或图片能力不可用时 `enabled=false`。

成功的 `metawork.events.connect` 响应增加 `attachmentInput = { mode, maxChunkBytes }`，拒绝响应不带该字段。Application 选择 `mode = native_paths | file_bytes`；Windows 使用 `file_bytes`，其他平台使用 `native_paths`。`maxChunkBytes` 是非零 canonical decimal raw-byte 上限，不能超过单次 Bridge frame 预算；它只约束字节入口，不是 Product capability。Renderer 每个平台只消费一个拖放入口，不监听另一入口作重试或超时 fallback。

新的添加操作使用 revision 1 上的四个 async command。整批 key 精确为非零 canonical decimal u64 string 的 `{ generation, batchId }`，绑定当前 window/connection。`beginAdd` 精确接收 key 与 `source`：`{ kind: "picker" }`、`{ kind: "native_paths", paths }` 或 `{ kind: "file_bytes", files: [{ name, sizeBytes }] }`；路径仅能来自当前 Native drop，DOM 字节仅能来自本次 File，模式必须匹配 handshake。picker 与路径在最终整批准备结束后返回 ready/cancelled/rejected；字节来源只有完整预留并初始化 writer 后才返回 accepted。

`appendAdd` 精确接收 key、JSON u32 `fileIndex`、canonical u64 string `offset` 与 `dataBase64`，只允许连续文件、连续 offset 和单块上限；worker 实际写入完成后返回 accepted/cancelled/rejected。`finishAdd` 只接收 key，在 worker 完成原件长度校验和同步及 Native loop 图片准备后，整批原子发布 ready/cancelled/rejected；ready 沿用既有 descriptor。新拒绝原因在既有文件原因上增加 `invalid_transfer | stale_transfer | input_busy | cleanup_failed`，不新增 Snapshot 状态或轮询接口。

`cancelAdd` 只接收 key。取消先撤销 writer admission，等待在途 job 关闭句柄，再撤销未消费 grants 并清理候选；只在确认静止且物理清理完成后返回 `{ status: "cleaned", released: boolean }`，删除失败返回 `{ status: "cleanup_failed" }`。未知/已清理 key 的 released=false 不得掩盖该批次的活 writer 或 cleanup debt；借用和已消费原件受 Run 所有权保护。取消先于 begin 通过有界高水位拒绝迟到请求。每个 async responder 恰好结算一次，pending 输入收到 cancelled，已完成 responder 不重复结算。begin 与 finish 无固定短超时，单块和 cancel 使用既有有界 transport budget；取消结果未知立即替换连接，Renderer 清除旧连接未发送附件并保留文字，Host ledger 不因此重置。不自动重试、重放或建立 Host TTL。

既有 revision 1 命令及其 sync/async 语义保留为同一 Product 资源核心的薄适配；旧字节协议与新协议不能交叉驱动同一 writer。旧拒绝原因不增加新名字：input_busy 映射 staging_capacity，cleanup failure 作为 command failure。原件、配额及债务的 owner 与物理清理不变量见[Product 附件合同](product-architecture.md#26-文件-attachment-staging)。

`metawork.attachments.choose` 是 revision 1 async command，只接受空对象。Application 在当前 source/window authority 下打开不限制扩展名的原生多选 picker。`metawork.attachments.addDropped` 是同一 revision 的 async command，payload 精确为 `{ paths }`；`paths` 是 Native SDK `drop:files` 事件给 Renderer 的非空绝对路径数组，Renderer 只能在当前事件处理中提交，不得缓存或投影。Bridge 对路径数量、编码和总字节有界校验。路径入口随后由同一个 Product Control attachment lane 完成整批 staging，结果严格为以下三种之一：

```json
{ "status": "cancelled" }
```

```json
{
  "status": "ready",
  "attachments": [
    {
      "token": "opaque",
      "kind": "image",
      "format": "png",
      "displayName": "diagram.png",
      "sizeBytes": "42"
    }
  ]
}
```

非图片文件 entry 不含 `format`：

```json
{
  "token": "opaque",
  "kind": "file",
  "displayName": "notes.txt",
  "sizeBytes": "42"
}
```

```json
{
  "status": "rejected",
  "reason": "unsupported_type | file_too_large | text_file_too_large | too_many_files | staging_capacity | read_failed | file_changed | shutting_down"
}
```

`attachments` 在 ready 时非空且保持入口顺序；entry 是严格 tagged union：`kind=image` 必须带已发布 `format`，`kind=file` 禁止 `format`。token 是 Bridge-owned、不可猜、connection/window/document-generation-bound 的一次性 grant，不是 Product identity 或路径。整批任一候选失败只能返回单一 rejected 并释放全部 candidate，不返回 ready 与 rejected 混合集合。

`file_bytes` 模式使用同一 revision 的四个同步 typed commands。它们只在当前连接和实际 source window 下接受调用，Host 在主线程线性化生命周期；不接收 Renderer 提供的 window identity：

| Command                              | 精确 payload                                             | 结果                                 |
| ------------------------------------ | -------------------------------------------------------- | ------------------------------------ |
| `metawork.attachments.beginReceive`  | `{ generation, batchId, files: [{ name, sizeBytes }] }`  | `{ status: "accepted" }` 或 rejected |
| `metawork.attachments.appendReceive` | `{ generation, batchId, fileIndex, offset, dataBase64 }` | `{ status: "accepted" }` 或 rejected |
| `metawork.attachments.finishReceive` | `{ generation, batchId }`                                | 上述 ready 或 rejected               |
| `metawork.attachments.cancelReceive` | `{ generation, batchId }`                                | `{ released }`                       |

`generation`、`batchId` 是非零 canonical decimal u64；`sizeBytes`、`offset` 是 canonical decimal u64，offset 可为零。`fileIndex` 为零起始 JSON u32，必须对应当前接收文件。batchId 由 Renderer 在 begin 前按连接单调分配；Host 用有界水位拒绝重复或迟到 begin，包括 cancel 先到的批次。每次只传一个原始块，等 accepted 后才读下一块；文件顺序、offset、声明长度和 Base64 必须严格一致，不接受空块、重复、跳跃或超限数据。Host 根据接收字节分类，不信任 MIME/扩展名；不把 DOM File 冒充具备本地路径身份验证的文件。begin 在读取前预留整个批次的 Product 配额，finish 才发布 grant。资源拒绝复用上述 reason；传输顺序或内容错误为 `invalid_transfer`，未知/过期批次为 `stale_transfer`。畸形 wire、错误 source/window/generation 属于 Bridge command failure。

cancel 释放本批 Product 接收资源或本批已发布但未消费的 grant；未知批次返回 released=false，并阻止同 ID 的迟到 begin。它不能撤销已接纳 Run，也不能释放其他 generation 的批次。begin/append/finish 不自动重试；客户端超时、读取错误或用户取消都定向 cancel，无法确认清理则替换现有 connection，清除旧附件并提示重新选择。断连、document replacement、关闭和 shutdown 必须释放全部接收资源。Host 不新增 TTL 或定时重试；冻结 Renderer 最多保留一个配额内批次直到显式或生命周期清理。完成响应迟到不得在已取消 UI 操作中插入 chip；移交草稿后则由既有 attachment release/consume 负责。

`metawork.attachments.release` 是同步 revision 1 command，payload 精确为 `{ token }`，返回 `{ released }`。它只撤销当前 connection 拥有且尚未 borrowed/consumed 的 grant；未知、stale 或已经释放的 token 返回 released=false，不泄露其他 connection 的存在性。disconnect、document generation replacement 与 shutdown 必须等价释放该 connection 全部 grant。

`metawork.tasks.run` 在既有 `text | skill` 上原地 hard cut 增加 `{ kind: "multimodal", text, attachmentTokens }`。`text` 是 string，允许为空；`attachmentTokens` 必须为非空、有界、无重复的 string array。非空 text 成为第一个 Agent part，后续 part 按 token 数组顺序；Skill 字段和 multimodal 字段不能混合。Bridge 只校验 wire 与 grant authority，Product 决定 Task/Session admission和 token 的 borrow/consume transaction。任一 token 指向 `kind=file` 时，去除首尾空白后的 `text` 必须非空，否则 Run 返回 `reason=missing_instruction` 且保留全部 ready grant；接纳后 Product 将原件保存在 Task 本地存储，非图片文件作为独立有界原件引用 text part 发送，图片为有界 PNG 加原件引用；历史 metadata 仍描述用户原文件。Run 接纳后即使 history save、enqueue、transport 或 Agent terminal 失败也不得恢复或自动重放。

Run snapshot 的 `input` 对 multimodal 精确发布 `{ kind, text, attachments, redacted }`。`text` 为 nullable string；`attachments[]` 是严格 tagged union：图片精确为 `{ kind: "image", format, displayName, sizeBytes, redacted }`，非图片文件精确为 `{ kind: "file", displayName, sizeBytes, redacted }`。顺序与已接纳 input 一致。附件输入的 Snapshot 与 persistence 不含 token、路径、文件原件正文、raw bytes、Base64、digest 或 provider wire；按需读取产生的 Tool 记录遵守既有有界投影与脱敏合同。旧 history record 没有 attachment 字段时只解释为 text/skill 旧 Run，不从正文或文件引用猜测附件。

当前 `metawork.tasks.run` 使用 `input.kind = text | skill | multimodal` 的唯一 tagged payload，旧 `prompt` 不兼容；Skill input 精确为 `{ kind, skillId, catalogRevision, selectionRevision, argumentValues }`，multimodal 精确遵守上节 token 合同。`tasks.create` 必须携带 `workspace = { kind: "automatic" } | { kind: "manual", workspaceId, expectedWorkspaceEpoch }`、必填 nullable `modelSelection`、nullable `expectedSkillCatalogRevision`、nullable `expectedSkillSelectionRevision` 和 `approvalMode = manual | auto_review | full_access`；Text 与 multimodal 的两个 Skill revision 均为 `null`，Skill 两者均非空，混合状态 fail closed。成功 create result 与每个 Task snapshot 都必须包含 `mcpAuthority = { kind: "ready", selection: "selected" | "none" } | { kind: "unavailable", selection: null }`；失败 create result 的该字段为 null。它只描述创建时复制的 immutable MCP authority，不包含 server/tool/credential，不授权 Renderer 热附加或推断当前 MCP 状态。Bridge 与 Product Control 直接使用同一组 `manual | automatic` admission 语义；混合、缺字段或未知 kind/mode 的 payload 一律 fail closed。不存在 `workspaces.select` 命令或 Snapshot 级 selected Workspace；Manual 选择和模型 override 只属于 Renderer New task draft，真正的 Workspace epoch/authorization/recent order 与模型 authority 在 `tasks.create` 事务中校验和提交。`automaticWorkspaces` 只声明新 Automatic Workspace 的分配能力；capability 不可用时，已恢复的 Automatic Workspace 与 owning Task 历史仍可出现在 snapshot 中。Skill 没有 `runSkill` 第二入口。Workspace/Task catalog、typed Run history 和 Skill terminal cause 只从 Product Control snapshot 发布；显式 catalog refresh 也只通过 Bridge 调用 Product Control transaction，Bridge 不持有 catalog lease、不解析 slash、不读取 Skill body。

Automatic 交互 Task 的初始 Skill 准备复用 `tasks[].skillCatalog.availability = loading | ready | degraded | unavailable`，不新增平行 Task 状态对象。`tasks.run` 在 loading 时返回未接纳的 `catalog_loading`，不消费附件 token 或建立 Run。Renderer 在一次用户发送的内部前置步骤中等待同一 connection generation、taskId 与 binding epoch 的 canonical snapshot 准备收口，再仅提交一次 Run；超时、失去 Task、binding 变化或断连保留草稿并禁止自动重放。初始准备 unavailable 不阻止普通 Text/文件引用 Run；它不等同于启用某个 Skill，也不改变 Conversation restore eligibility。

运行中排队发送在 revision 1 内增加两条同步业务命令，不增加 Run 阶段：

| Command | 精确 payload | 精确 result |
| --- | --- | --- |
| `metawork.tasks.queueInput` | `{ operationId, taskId, expectedBindingEpoch, runId, input }` | `{ operationId, taskId, accepted, revision, reason }` |
| `metawork.tasks.withdrawQueuedInput` | `{ operationId, taskId, runId, revision }` | `{ operationId, taskId, withdrawn, revision, reason, input }` |

`operationId` 为 Renderer 在调用前生成的 1–64 字节可打印 ASCII 非空 identity，用于单次操作对账，不是重试 key；不得携带凭据。其他 identity/revision 为非零 canonical decimal u64。两条命令要求当前主窗口和已连接 generation；malformed wire、错误 source/window 或无 connection 属于 command failure，不修改排队状态。queue input 沿用 `tasks.run` tagged payload；文本和 Skill 按完整当前输入、目录 revision、selection revision 与投影容量规则接纳，附件为 `unsupported_input`，不借用或消费 grant。成功结果 revision 非空、reason 为 null；失败 revision 为 null、reason 非空；撤回仅在成功时带回安全输入。runId 与槽位 revision 必须同时匹配，否则为 `queued_input_changed`，不得撤回别的输入。

queue 拒绝原因包括 `task_idle | run_changed | run_stopping | queue_occupied | unsupported_input | binding_changed | binding_unavailable | task_unavailable | task_busy | shutting_down | workspace_unavailable | workspace_changed | workspace_removing | catalog_loading | catalog_unavailable | stale_catalog | skill_not_found | skill_unavailable | invalid_skill_arguments | missing_instruction | capacity_reached | admission_failed`。未知 Task 仍返回 typed `task_unavailable`；不存在的 Task 无可供快照保留的回执。

每个 Task 快照必填 `queuedInput` 与 `queuedInputResult`，无内容时均为 null。前者精确为 `{ revision, runId, input, state, heldReason, queuedAtUnixMs }`；state 为 `waiting | held`，waiting 的 heldReason 必为 null，held 必须有原因。queuedAtUnixMs 为可显示的非零 Unix 毫秒 wire integer 或 null。input 的 text shape 为 `{ kind, text, redacted }`，Skill shape 为 `{ kind, skillId, catalogRevision, selectionRevision, invocationName, displayName, argumentValues, redacted }`，均使用安全投影；selectionRevision 供用户编辑后按当前准入重新校验；不包含原始执行 bytes 或附件。heldReason 复用 queue 原因，并增加 `stopped_by_user | approval_mode_changed | run_not_completed | schedule_completion_unconfirmed`。槽位语义、发送与丢弃边界由 [Product 架构](product-architecture.md) 定义。

最近结果精确为 `{ operationId, kind, outcome, revision, reason, input }`；kind 为 `queue | withdraw`，outcome 为 `queued | withdrawn | rejected`。queued 只能对应 queue，无 input；withdrawn 只能对应 withdraw，带安全 input；两者都有 revision 且 reason=null。rejected 只有 reason，revision/input 均为 null。Host 在同一主线程 mutation 内发布业务效果与结果；响应编码或传输失败不撤销它，自动消费槽位不清掉结果，下一条显式排队操作可以替换结果。不新增 ACK、结果历史、TTL 或跨重启保证。

Renderer 同一 Task 不并发排队操作。调用前在现有草稿会话存储记录 operationId、原草稿版本与编辑/丢弃意图；超时解除本地 busy 并实际刷新 Snapshot，不自动重发。只有匹配 operationId/kind 的结果能确认去向；成功入队仅清除原提交草稿版本，成功编辑撤回仅在没有较新草稿时恢复输入，丢弃撤回不恢复。每个回执只应用一次，旧 connection 的迟到响应无权修改新草稿。空槽位不能证明失败；没有匹配证据时保留“结果未确认”，允许刷新，明确再次使用原输入前提示可能重复。Host 重启、Task 删除或结果被替换后不承诺自动恢复操作结果。

`tasks.run` 精确返回 `{ accepted, taskId, runId, reason }`，accepted 时 runId 非空且 reason=null，rejected 时相反；已知拒绝为 `binding_changed | binding_unavailable | task_unavailable | task_busy | workspace_unavailable | workspace_changed | workspace_removing | catalog_loading | catalog_unavailable | stale_catalog | skill_not_found | skill_unavailable | invalid_skill_arguments | missing_instruction | unsupported_attachment | capacity_reached | shutting_down | queued_input_present`。非空槽位拒绝普通 run；waiting 槽位也使 compact/restore 返回 `queued_input_present`，held 不因此阻止用户显式压缩或恢复。其余既有普通发送的错误和提交行为不改变。

`metawork.tasks.cancel` payload 精确为 `{ taskId, runId }`，成功 acknowledgement 为 `{ taskId, runId, cancelRequested: true }`，只表示停止请求已处理，最终结果仍取 canonical Snapshot。有效普通停止先将匹配 waiting 槽位设为 `held(stopped_by_user)`，即使绑定 Run 恰好已完成也不得自动发送；旧 Run 的停止不能影响已经接纳的后续 Run。超时只刷新，不重发或组合另一条发送命令。

`metawork.tasks.compact` payload 精确为 `{ taskId, expectedBindingEpoch }`，结果精确为 `{ accepted, taskId, operationId, reason }`。`accepted=true` 表示 Product 已建立该 Compact operation identity，不承诺 executor enqueue 或 Agent compact 成功；即使紧随其后的 queue submit 失败，command 仍返回该 accepted `operationId`，随后 canonical Task snapshot 以同一 operation 发布 `phase=failed, cause=resource_limit` 并清除 active operation。Renderer 必须等待 snapshot terminal，不得把 accepted acknowledgement 改判为 command rejection、恢复旧状态或自动重放。

权限策略沿用同一 revision 1 合同原地 hard cut。根 `capabilities.permissionProfiles` 与根 `permissions = { availableProfiles, availableModes, defaultMode }` 定义新 Task 的可用选择与默认值；`metawork.tasks.create` 必须提交 `approvalMode = manual | auto_review | full_access`，成功创建后 Host 才记住新 Task 默认选择。每个 Task 发布当前 `permissionProfile + approvalMode + permissionReviewState`；每个 Run 的 `permissionProfile + permissionInteraction` 是该 Run 创建时的历史事实，不随 Task 模式切换改写。仍活跃的 Run 必须与 Task 当前执行 profile 一致；历史 reviewer audit 只按 owning Run 的 interactive approval profile 校验。Scheduled Task 的 noninteractive 映射保持产品需求定义的边界。

已有 Task 审批切换使用 `metawork.tasks.setApprovalMode`，payload 精确为 `{ taskId, targetMode, expectedBindingEpoch, expectedApprovalRevision }`；三个 identity/revision 是非零 canonical decimal u64，`targetMode = manual | auto_review | full_access`。Host 在同一 Task authority 上执行 epoch 与 approval revision CAS，保留 Workspace、Session 与 Conversation 身份；跨执行 profile 的 Run 取消、quiescence、checkpoint、持久化及失败恢复由 Product Control 推进。Bridge 不组合 cancel/restore/run，也不接受 AgentCore mode、grant 或自由 Session identity。

结果精确为 `{ accepted, taskId, approvalRevision, reason }`。accepted 时 revision 是本次 intent 的 revision；相同模式 no-op 返回当前 revision。它只证明受理，不证明模式已提交；rejected 时 revision 为 null，reason 取 `task_not_found | stale_binding | stale_revision | busy | task_closed | unsupported_interaction | unavailable | revision_exhausted | review_exhausted | shutting_down`。A→B→A 仍推进 revision，旧意图不得因为模式名称相同重新获得 authority。未完成事务拒绝重复意图。

Task Snapshot 必须发布 `approvalRevision`、`availableApprovalModes`、nullable `approvalChange` 与 nullable `approvalResult`。revision 是当前 durable 模式 revision；available modes 是 Host 对各目标的同一准入判断结果，Renderer 不自行推导，事务进行时为空。`approvalChange = { revision, targetMode, state: pending | recovering | outcome_unknown }` 的 revision 指向当前或下一 revision；进行时不发布旧 result。`approvalResult = { revision, outcome: completed | failed, reason }` 只发布最近事务结果：completed 的 revision 等于当前 durable revision 且 reason 为 null；failed 的 reason 取 `cancelled | busy | budget_required | mode_update_failed | checkpoint_failed | persistence_failed | outcome_unknown | recovery_failed | dependency_contract`。change/result 是运行中反馈，不是第二份历史或持久化模式真源。断连重启后以 durable mode/revision 重新确认状态。

Renderer 在发送及等待 Snapshot 时锁定同 Task 的重复选择；模式文字只读取 canonical Snapshot。超时或丢失 response 只请求刷新，不自动重发意图、重放输入或继续 Run；显式刷新后仍没有终态证据时说明“未确认”，由用户检查当前 mode/revision 再重新选择。旧 Snapshot、旧失败结果、旧连接 generation 和迟到 acknowledgement 不得覆盖已经确认的模式或解锁另一个请求。

Scheduled Task create/update mutation 的模型字段精确为 `binding: { modelRef: { sourceId, modelId }, sourceGeneration, selectionRevision, protocol }`，不得携带 `expectedExecutionGeneration`。Renderer 只能从同一 snapshot 的 Models global default 与 `newTaskAdmission` active authority 构造它；source/model、source generation、selection revision、protocol 或 active authority 任一不一致时禁用保存。Host 在 mutation 和每次 occurrence 前重新做相同精确校验并当次 resolve。Host 不发布或接受缺少完整 source-qualified identity 的旧 binding，也不提供 Renderer 重绑迁移状态。occurrence `taskOutcome` 精确接受 `completed | stopped | cancelled | interrupted | failed | dependency_contract_failure | unavailable | null`；`unavailable` 表示该 occurrence 引用的真实 Task 已不再存在，不得伪装成 Task terminal cause。

`metawork.tasks.delete` 只接受 `{ taskId }`，仅对已归档 Task 开放。成功返回 `{ taskId, deleting: true }`，表示 Product Control 已受理唯一删除意图；它不声称 Task 已经物理删除。Task snapshot 以 `deletionStatus = idle | deleting | failed` 发布该 runtime-only 产品用例：`deleting` 时 Renderer 等待后续 snapshot 移除 Task，`failed` 时保留归档 Task 并重新开放显式删除动作。Product Control 自行收口 Attachment、等待 worker/checkpoint quiescence、提交 Task store；Renderer 不重复提交正常推进、不编排 Session teardown，也不解析 checkpoint、close failure 或 worker reference。

每个 Task snapshot 必须发布 `unreadCompletionRunId: canonical decimal u64 | null`。非空时必须精确引用该 Task `runs` 中最新的 terminal Run，且其 `terminal.outcome = completed`；不存在成功完成、最新 terminal 是其他 outcome，或该 Run 已由 Product receipt 确认时必须为 null。Renderer 不从 Run 数组另建未读真源。

`metawork.tasks.markCompletionSeen` 只接受 `{ taskId, runId }`，两者都是非零 canonical decimal u64；返回 `{ taskId, runId, marked }`。只有该 Task 仍存在、未进入删除流程，且 `runId` 仍是最新 terminal `completed` Run 时才能推进 receipt 并返回 `marked=true`；重复、迟到、归档已确认或目标消失统一返回 `marked=false`，不得清除后来 Run 的提醒。成功 mutation 发布新的 snapshot revision，但不改变 Task `recentOrder`，也不单独强制 history commit；receipt 随 Product 的下一既有 durable boundary 或 clean shutdown 合并持久化。Renderer 只能在中央 Task 工作面真实暴露且 document 可见、窗口有焦点时调用；Settings、搜索、窄窗左栏、非停靠 Task Panel、断连和同步失败期间不能确认。该命令没有用户可见错误或自动重放；结果不确定时继续以 canonical snapshot 为准。

`metawork.skills.setEnabled` 是 revision 1 内的原地 hard cut command。payload 精确为 `{ scope, workspaceId, expectedWorkspaceEpoch, skillPolicyKey, state, expectedCatalogRevision, expectedSelectionRevision }`：`scope = personal` 时两个 Workspace 字段必须为 null 且 `state = enabled | disabled`；`scope = project` 时两个 Workspace 字段必须是已授权 Manual Workspace 的 canonical identity，且 `state = inherit | enabled | disabled`。`skillPolicyKey` 必须属于对应 current catalog，不能用易随内容变化的 concrete `skillId` 代替。成功返回 `{ applied: true, selectionRevision, reason: null }`，业务拒绝返回 `{ applied: false, selectionRevision: null, reason }`；非法 shape、越权或非 canonical identity 仍 fail closed。Snapshot 中每个 `skillCatalog` 含 nullable `selectionRevision`，每个 descriptor 含 effective `enabled`；ready/degraded catalog 的两份 revision 均非空，其他状态均为 null。`skillManagement` 含 `enablementAvailability`，asset 含 nullable `skillPolicyKey`、nullable effective `enabled`、nullable `enablementState`、`canSetEnabled` 与 nullable `selectionRevision`；Personal 的 state 只取 enabled/disabled，Project 的 state 可以 inherit。管理 authority 与 enablement authority 分离，能够精确映射当前 catalog member 的 external asset 也可启停，但仍不可因此获得导出、重新导入或卸载 authority。

已有 Task 的模型切换使用独立的 `metawork.tasks.selectModel` command，payload 精确为 `{ taskId, expectedModel, expectedExecutionGeneration, targetModelRef: { sourceId, modelId }, expectedSourceGeneration, expectedCatalogGeneration }`，结果为 `{ accepted, taskId, model, reason }`。`expectedModel + expectedExecutionGeneration` 是 Task 当前 binding 的 compare-and-swap 事实，`targetModelRef + expectedSourceGeneration + expectedCatalogGeneration` 是 Models 当前 Metask authority 的 source-qualified 候选；payload 不携带 credential。Host 只有在 Product Control 当前安装的 active `ModelRef`、Task protocol/generation、Models Metask source/catalog generation 与 payload 精确一致、replacement未开始且目标模型仍在该 catalog时才接受；任一 authority/catalog 漂移统一返回 `stale_catalog`。Task 当前 pinned model 已离开目录不阻止它选择仍有效候选。source-qualified payload 不开放跨 source 能力；Custom Provider Task 仍不复用 Metask catalog，也不开放已有 Task 模型切换。模型切换不 bump Task `binding.epoch`，不改变 pinned `executionGeneration`；已有 Run继续使用自己的历史模型。活跃 Run期间的选择只进入 Host runtime pending，下一次 Run admission前应用，pending不进入 persistence或 Snapshot wire；随后发生的默认 replacement不撤销此前在 exact authority下已接受的 pending选择。

Conversation recovery 使用同一 revision 1 数据面上的 `metawork.tasks.restore`。payload 精确为 `{ taskId, expectedBindingEpoch }`，结果精确为 `{ accepted, taskId, attemptId, reason }`；`attemptId` 仅在 accepted 时为 canonical decimal `u64`，reason 仅在 rejected 时取 `binding_changed | task_unavailable | recovery_unavailable | capacity_reached | shutting_down | queued_input_present`。Bridge 只负责严格 decode、Task authority 与结果 encode，不读取 checkpoint、不决定 eligibility、不调用 Agent。该 command 可由用户 Retry 或发送路径内部调用；Host 可以据 canonical Product facts 选择 checkpoint restore job，或在没有 checkpoint/covered/pending history 时同步 fresh attach 空 Conversation。两者都返回 accepted attempt identity，Renderer 必须等待同一 Task 的 canonical snapshot 确认 attachment 后才能提交 `tasks.run`，不得重放历史输入。AgentCore complete 与 degraded restore 都通过同一既有 attachment/continuation shape 表示成功；degraded 的 Permission accounting 继续只由 `restorePermission` 表示，不新增 command result、Snapshot 字段或 revision。结果不确定或 Renderer timeout 时只能 resync snapshot，不能自动重放。

Pending permission projection 使用 `{ requestId, runId, order, redacted, kind: "permission", toolNamespace, tool, toolBinding, args, availableChoices, policyGeneration, canonicalArgumentsDigest, candidate }`，其中 `candidate` 精确为 `null | { ruleId, scope: "exact_arguments" } | { ruleId, scope: "file_target", target }`。`availableChoices` 由 AgentCore 当前 request 的 `responses[]` 计算；Session choice 只有在 candidate 存在时才可发布。`file_target` 只接受 built-in Write/Edit，target 必须非空且来自 Core canonical target；目标命中敏感过滤时 Host 发布 null candidate 并移除 Session choices。`exact_arguments` 不携带 target，未知 scope、混合字段和非法工具组合必须拒绝。target 只供呈现，不进入 response command 或充当 Renderer authority。Renderer 只能提交 `deny_once | deny_session | allow_once | allow_session` 中实际出现在 `availableChoices` 的 choice；不得提交 `policyGeneration`、digest、candidate `ruleId` 或原始 AgentCore response。Agent 从 pending request 回填 ABI 字段并完成最终校验。Digest 与 candidate 只用于同 Task 的诊断比较，不是 Renderer grant authority。

Permission occurrence 在 `uiHistory` 中额外携带 `agentRequestId` 与 nullable `permission` 摘要。摘要字段固定为 `requestId`、`matchedRuleId`、`toolNamespace`、`toolName`、`toolBinding`、`canonicalArgumentsDigest`、`decision`、`source`、`policyGeneration`、`usedSessionRule`、`callbackOutcome`；它只包含非 secret identifier 和脱敏决策结果，不包含原始参数、credential 或可重放 response。Restore 后 Task snapshot 的 `restorePermission` 仅是本次 restore 的 `{ restoredRules, invalidatedRules }` 运行健康投影，不能被 Renderer 当作本地 grant cache。

根 `permissions` 精确增加 `availableModes` 与 `defaultMode`，保留 `availableProfiles` 与 `defaultProfile` 表达对应 Core profile；模式集合及映射由[产品需求](requirements.md#55-审批与输入)定义。Decoder 拒绝数字、数组、未知或重复模式以及 default mode/profile 不一致。Task snapshot 增加 `approvalMode` 与 `permissionReviewState=idle|reviewing|needs_user`；模式只读并由 Task 自己的事实派生，不用全局 default 补写。人工与完全访问只能处于 `idle`，自动评审的已回答请求也恢复 `idle`。不存在会话中 mode mutation command 或独立委托 command。

每条 `uiHistory` 记录精确增加 `answeredBy=user|reviewer|null` 与 nullable `reviewReason`。取消记录的来源必须为 null，用户决定不带理由；审核器只允许本次 `allowed_once|denied`，对应 Run 必须 interactive 且 profile 为 `approval_required`。非空理由必须是有界、非空白、无控制字符的 Host 脱敏 UTF-8 字符串；wire 接纳历史格式已有的 detail 容量，不以模型当前更小的输出预算拒绝旧合法记录。AgentCore 摘要的 `source=callback` 不区分人工与审核器，Renderer 必须使用 Product 的 `answeredBy`，不能从它或理由自行生成可提交 response。

根 `capabilities.conversationRecovery` 当前为 true。每个 Task 延续唯一 continuation 模型：`continuationAvailable` 表示现在可启动下一 Run，`continuationUnavailableReason` 精确取 `session_poisoned | closing | task_archived | session_recovery_required | session_recovery_in_progress | session_recovery_failed | persistence_unavailable | checkpoint_unavailable | execution_rebind_required | workspace_unavailable | authority_unavailable | runtime_unavailable | history_read_only` 或 null，`continuationRecoveryAvailable` 表示当前 snapshot 下允许 Renderer 在普通发送的内部前置步骤提交 restore；它不产生独立的恢复按钮或卡片。`history_read_only` 表示该 Task 只能以忽略未知字段的方式读取，必须同时 `continuationRecoveryAvailable = false`，Host 拒绝其 Run、restore、模型与审批模式选择、重命名、归档和删除。`execution_rebind_required` 只表示当前 protocol/model authority 不能承载该 Task，不能用于表达历史 generation 与当前 generation 不等；Renderer 也不能把它解释为 Conversation 身份失败。Task lifecycle 精确取 `open | closing`，不存在 `closed`；删除用例另以 `deletionStatus = idle | deleting | failed` 表达，只有 archived Task 可以非 `idle`，`deleting` 必须对应 `closing` lifecycle。active operation 可取 `restore`。Decoder 必须联合校验这些字段：attached 可继续态不能同时声称可恢复；required/failed 只有在精确 checkpoint recovery 或无 checkpoint 且无 included/pending history 的 fresh recovery gate 成立时才可发布 recovery available，Task/Workspace identity、Execution target readiness 与 runtime readiness 在两种模式都必须成立，Skill/MCP/Permission/projection readiness 不属于这些 gate；in-progress 必须对应 restore operation；archived/closing、普通 Run/compact 或 capability=false 时不得发布恢复前置步骤。不得新增并行的 `task.recovery` 状态对象。

每个 Run 与 Compact snapshot 必须包含 `conversationCoverage = included | excluded`。`included` 表示该 operation 属于当前 live Conversation 或最新 checkpoint 的恢复上下文，覆盖内部 pending/covered差异；`excluded` 表示它只保留在 Product history，不会出现在恢复后的 AgentCore上下文。Renderer 不得从 phase、outcome、id 或 checkpoint 状态推断此字段；只要 Task 存在 excluded operation，主阅读流必须保留其历史并显示部分历史未包含在恢复上下文的提示。该提示不能覆盖 continuation truth，也不能把所有 unavailable reason 统一解释为“必须新建 Task”。

Skill management 使用同一 revision 1 数据面发布 bounded preview/detail/projection 与 typed import/export/reimport/uninstall mutation；command catalog、Zig DTO、TypeScript runtime decoder、snapshot fixture 和 automation 必须完全一致，不建立第二 transport 或局部 revision。

Skill asset 的 `managementState` 包含派生的 `recovery_required`，不改变持久化 Asset.state 或事务 phase。该状态必须有 installId，并关闭 canExport/canReimport/canUninstall；canRetry 仅可在 management ready 且 Host 的当前恢复/验证准入成立时为 true。现有 Retry command 不变，其物理恢复与验证分派由 Host 决定；ready/external 或 store 不可信时不得宣称可 Retry。恢复、原操作错误与全局 revision 发布的关系由 [Product 架构](product-architecture.md#24-skill-authority-与本地资产)定义。

MCP 管理使用同一 revision 1 snapshot 与 command 数据面，原地 hard cut 为 transport-discriminated catalog：既有 typed server commands 之外增加空 payload 的 `metawork.mcp.applyConfiguration`；不得暴露 generic upsert 或第二 OAuth callback data plane；手动凭据只允许经 captureSecret 专用 payload 提交。所有 server command 携带 canonical decimal `expectedDesiredGeneration` 和目标 `serverId`（create 除外）；create/update 仍只接收结构化 command + ordered arguments 或严格 HTTP endpoint，不接受 shell string。`applyConfiguration` 返回 `started | busy | rejected | unavailable`，只重试把 Host canonical desired 应用到正式 Runtime，不接受 Renderer 提供配置。完整精确命令集由 `app.zon`、Zig 与 TypeScript catalog 同步定义。

`approveConnection` 只服务 schema 1 迁移留下的 legacy unapproved server；普通 Add/Replace 不经过该 command。`captureSecret` 接收 `{ expectedDesiredGeneration, serverId, slot, secret }`，secret 是用户在 Renderer password input 中显式填写的非空、有界原值；Bridge 同步转交 Host，沿用原有 slot、generation、approval 与事务校验并写入系统 credential store，不记录、缓存、投影或返回 secret。`mcpSecretCapture` 表示此凭据提交能力，不依赖原生输入弹窗。输入在提交、取消、关闭详情、离页、generation 变化或管理不可用时清除，不回填、不持久化、不自动重放。`authorizeOAuth` 只对 approved Streamable HTTP OAuth server 启动全局唯一、server-bound operation，并继续保留独立的 Host consent。`testConnection` 使用 `McpServerIdentity` payload，结果精确为 `started | busy | stale_generation | needs_authentication | rejected | unavailable`；started 表示 Host 已启动一个隔离候选 Runtime 的真实 activation，不表示测试已成功。完成状态只经 snapshot/notification 发布，不返回 raw catalog 或 diagnostic。`refreshCatalog` payload 为空，只刷新当前正式 Runtime catalog，不应用 pending connection configuration 或隐式启动 OAuth。

根 `capabilities` 必须包含 boolean `mcpManagement`、`mcpConnectionApproval`、`mcpSecretCapture` 与 `mcpOAuth`，以及非负安全整数 `mcpSecretMaxBytes`。该上限来自 Host 实际注入 MCP management 的 credential storage 字节限制；management 不可用时为 0，可用时必须大于 0。Renderer 按此值执行 UTF-8 字节校验并插值显示提示，不自行定义上限；Host 仍独立校验。根 `mcp` 必须精确包含 `availability`、`managementHealth`、`operation`、`configurationApply`、`authorizationOperation`、`desiredGeneration`、`runtimeAlignment`、`redacted` 与 `servers`：`configurationApply = idle | applying | failed`，其余 enum 保持既有定义。没有可信 canonical desired或 management outcome unknown 时 configurationApply 必须 idle、generation null、alignment unknown、servers 为空且 authorization operation idle。`mcpManagement = false` 时发布完整 fail-closed baseline。任何不变量不满足都使 Renderer snapshot decode fail closed。

每个 server 使用唯一 opaque `id` 与唯一 `namespace`，并精确包含 `displayName`、`transport = stdio | streamable_http`、`authMode = none | static | oauth`、`negotiation = automatic | modern_only | compat_only`、正整数 `timeoutMs`、nullable typed `connection`、`approvalStatus`、`authorizationStatus`、`desiredEnabled`、`runtimeStatus`、`newTaskAccess`、已清洗的 `safeDiagnostic`、`connectionTest` 与 `tools`。`connectionTest` 精确为 `{ status: untested | testing | connected | failed, toolCount, issueCount }`，只存在于当前进程 projection；配置 mutation 清除旧结果，Host 重启后回到 untested。`connection` 对有效、未被 credential scrub 的 STDIO 精确发布 command、ordered arguments、nullable cwd 与 environment name/status；对 Streamable HTTP 精确发布 endpoint、header name/status、registration kind、用户提供的 client id、token endpoint auth method 与 client-secret status。配置无效或已触发 credential scrub 时 `connection = null`，Renderer 不得猜测或允许盲目替换。

Host 将 Desired Registry 的完整非敏感 typed connection、authorization operation、Runtime Manifest disposition、Agent opaque Activation health 与 Admission Authority 合成为 projection。environment/header value、credential locator、client secret、token/code/PKCE、动态注册所得内部材料、raw OAuth metadata、raw diagnostic、schema body、fingerprint 和 AgentCore handle 不进入 projection；Renderer 不直接解码或镜像 AgentCore MCP schema。`redacted` 只表示 Host 确实移除了可发布文本。Runtime-alignment unknown 或 persistence outcome unknown 时不得发布 last-known desired 伪装 canonical state。

Renderer 的 Slash Resolver 只在 Composer 首 token 处理 `/` 手势。单一 Command registry 当前只由 `App` action controller 复用既有 New task 动作；Command 原文在 Renderer 消费，不产生 Run。Skill 候选只来自当前 Workspace/Task catalog projection，选择后形成带稳定 identity、pinned revision 与 positional arguments 的 tagged draft，再沿唯一 `tasks.run` 路径提交。Command/Skill 同名时裸名称归 Command，Skill 使用 `/skill:name`；Renderer 不读取 Skill body、物理路径或 policy。

Metask Provider-local 模型选择使用 `metawork.models.configureMetaskSelection`，payload 精确为 `{ sourceId, modelId, expectedMetaskSelectionRevision, expectedCatalogGeneration }`，其中 `sourceId` 必须是固定值 `metask`。global default 使用 `metawork.models.selectDefault`，payload 精确为 `{ sourceId, modelId, expectedSelectionRevision, expectedSourceGeneration, expectedCatalogGeneration }`。`sourceId + modelId` 是完整 `ModelRef`；Bridge 只校验字符串边界并把 revision/generation严格解析为 `u64`，归属、membership和 CAS由 Models判断。`metawork.models.refreshCatalog` 为空 payload，只发起使用当前 OAuth authorization lease 的显式 Metask目录刷新；Bridge 不提供 Metask API Key 选择命令。Account command只保留 `beginLogin | cancelOperation | retryRefresh | refreshSummary | openRecharge | logout`，均为空 payload；`retryRefresh` 只用于恢复 Account token refresh 调度，`refreshSummary` 只刷新账户 summary，两者都不接收任何 model/catalog payload且不能互相代替。`metawork.account.openRecharge` 仅请求Account Host通过系统浏览器打开固定充值页，Renderer不得提交URL、token、account ID或query；该命令不改变Account/Product状态。

Models canonical 显式恢复使用 `metawork.models.resetStore`，payload 精确为 `{ expectedRevision }`，返回既有 Execution command result。该命令只在同一 snapshot 的 `models.persistenceHealth = recovery_required` 时可呈现，Bridge 只严格解析 Product revision；Product Control 与 Models owner 在执行时必须再次确认 recovery eligibility。执行时 Host 重新读取并严格解码 canonical：合法当前 schema 被非破坏性重装，中断测试完成确定性收敛；读取失败或资源耗尽拒绝且不写盘；只有文件缺失或严格确认损坏才安装当前空 schema 1。成功表示 canonical 已恢复为可信 Models 状态，不保证配置被清空，也不表示旧 bytes 被迁移、归档或启发式解释。`ready` 与 `unavailable` 必须拒绝；Renderer 不提交路径、文件内容、schema、reset mode、generation 或重放标志。该命令不修改 Account、Workspace、Task、Run 或对话历史，既有 Task-owned execution binding 不被重写。

Custom Provider credential 替换使用 `metawork.models.customProviders.replaceCredential`，payload 精确为 `{ providerId, expectedProviderRevision, apiKey }`。`apiKey` 是用户在本地桌面 Renderer 中显式填写的非空 opaque string，UTF-8 bytes 不得超过 4096；Bridge 只做严格 shape/容量校验并在本次同步调用中转交 Models，不得记录、缓存、投影、返回或异步保留该字段。Models 使用既有两阶段事务，先持久撤销旧 readiness，再写入 credential vault，最后以新的 provider/source generation 恢复为待测试状态。任一中途失败都不得让旧 readiness 配上新 credential；已有 Task/Run 的 owned binding 不受影响。

`models.providers[].models[]` 精确包含 `id`、`displayName` 与 `metadata`。metadata 精确包含 `maxInputTokens`、`maxOutputTokens` 和 `capabilities`。capabilities 精确包含 nullable boolean `textInput`、`imageInput`、`pdfInput`、`audioInput`、`videoInput`、`batch`、`citations`、`codeExecution`、`structuredOutputs`，以及 `output = { text, image, audio, video, embedding }`、`thinking = { supported, adaptive, enabled }`、`effort = { supported, low, medium, high, max }`、`contextManagement = { supported, clearThinking20251015, clearToolUses20250919, compact20260112 }`；各成员均为 nullable boolean。Metask 的缺失/null 能力投影为 false，Custom Provider 的未知声明保留 null。服务声明不直接授予产品能力。

metadata 的两个 token 字段为 null 或正数 canonical decimal u64 string。所有 wire key 均必需，由 Host serializer 与 Renderer strict decoder 同步消费；metadata 不进入 selection command payload。Custom model metadata command 使用相同能力与 token 字段，Host 保存所有已声明的能力。当前 metadata 不包含 `limits`；API token 字段来源与缺失语义以 [Product 架构](product-architecture.md) 为准。

Custom Provider mutation 使用同一 revision 1 数据面上的 `metawork.models.customProviders.create | update | replaceCredential | remove`，内置官方模板创建与地址修改分别使用 `metawork.models.builtinProviders.create | updateBaseUrl`，custom model 集合使用 `metawork.models.customModels.add | replace | remove | test`。custom create 接收 `{ displayName, protocol, normalizedBaseUrl, apiKey }`；builtin create 精确接收 `{ providerId, baseUrl, apiKey }`，其中 `providerId` 只能是 `deepseek | kimi | minimax | glm`，`baseUrl` 是不含 credential、query 或 fragment 的 HTTPS URL，或 HTTP loopback URL。builtin updateBaseUrl 精确接收 `{ providerId, expectedProviderRevision, baseUrl }`，其中 `providerId` 是已创建 Provider 的 source identity。Models 根据 builtin identity 固定 display name 与 protocol，并把 Base URL 映射为该 protocol 的精确 completion endpoint；Renderer 和 Bridge 不提交或推断 protocol。`apiKey` 与 replaceCredential 相同，只能作为调用期 secret 一次性转交 Models credential vault。通用 update/remove 使用 `providerId + expectedProviderRevision`；内置模板 Provider 必须拒绝通用 update，但允许专用 updateBaseUrl、replaceCredential 与 remove。地址变更必须刷新 provider/source generation，并按 Models 既有语义撤销旧 endpoint 上的模型 readiness；已有 Task/Run 的 owned binding 不受影响。test 精确使用 `{ model: ModelRef, expectedProviderRevision, expectedSourceGeneration, expectedCatalogGeneration }`；add 使用 `{ providerId, expectedProviderRevision, expectedCatalogGeneration, model }`，replace/remove 使用完整 `ModelRef` 并携带 expected provider revision 与 catalog generation。Bridge 只接受上述精确结构，不定义旧 payload、别名、归一化或兼容分支。Host 负责 endpoint/protocol、model membership、metadata、credential 状态和全部 revision/generation 校验。

Models snapshot 中的 `builtinProviderPresets[]` 精确发布 `id + displayName + protocol + defaultBaseUrl + apiKeyUrl + documentationUrl`；`protocol` 与 `defaultBaseUrl` 是 Models-owned 模板事实，用于 Renderer 呈现默认值和 endpoint 预览，不代表用户当前保存的地址；不得发布 completion endpoint、credential 或 logo。`customProviders[]` 精确发布 `id + builtinProviderId + displayName + protocol + normalizedBaseUrl + state + credentialStatus + enabled + providerRevision + sourceGeneration + catalogGeneration + models`，其中 `builtinProviderId` 为上述四个 identity 之一或 null；其 `models[]` 成员发布 `id + displayName + metadata + metadataProvenance + testStatus + ready`。Provider 不发布 `selectedModel` 或 Provider 级 `testStatus`；模型选择只存在于 nullable global `defaultSelection`，测试状态只属于具体模型。`state = configuring | ready | disabled` 由当前 source generation 是否存在至少一个 ready model及 credential/enabled 共同决定。成功 probe 建立该精确模型的 ready proof；同一 authority 上的失败重测只改变 latest status，不撤销 proof。设置 custom 或切回 Metask 都使用统一 `metawork.models.selectDefault` 与完整 `ModelRef`；Models 先提交 desired selection，Product Control 再独立 reconcile active binding，失败不回滚 desired。根 `capabilities` 必须精确包含 boolean `customProviderManagement`、`customProviderSecretCapture` 与 `customModelTest`；revision 1 保留 `customProviderSecretCapture` wire name，其 true 表示 secret-bearing create/replace typed command 与系统 credential storage 同时可用。Host 只在 management、credential storage 与模型测试均可用时把三者同时发布为 true，任一缺失全部为 false。该判断只消费当次实际 capability，不以平台名建立静态 allowlist；Renderer 只有三者均为 true 才显示 Provider 设置。

根 `account` 精确包含 `{ state, canCancel, accountId, displayName, emailHint, phoneHint, concurrencyLimit, errorCode, safeDiagnostic, summary }`；authenticated 只要求非空 `accountId`，`displayName/emailHint/phoneHint` 均为可空的best-effort资料提示，`concurrencyLimit` 为nullable非负整数，其中 `null` 表示资料不可用、`0` 表示 Metask 后端的不限并发语义；其他状态的字符串identity字段都为空且`concurrencyLimit`为null；完整邮箱和手机号不得越过Bridge。`errorCode=none` 时 `safeDiagnostic` 必须为空。`summary` 精确为 `{ operation, usageEligibility, wallet, usage, history }`，operation取 `idle | refreshing`，usageEligibility取 `unknown | disabled | enabled`。wallet精确为 `{ availability, balanceU, syncedAt, errorCode, safeDiagnostic }`；usage精确为 `{ availability, today, total, syncedAt, errorCode, safeDiagnostic }`，today精确包含 `{ inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens, totalTokens, actualCostU }`，total精确包含 `{ totalTokens, actualCostU }`；history精确为 `{ availability, startDate, endDate, days, syncedAt, errorCode, safeDiagnostic }`，days的每项精确包含 `{ date, inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens, totalTokens, actualCostU }`。availability取 `unavailable | loading | ready | stale`；日期为nullable `YYYY-MM-DD`，ready/stale范围必须从周一开始并覆盖最近53个周列（365–371个日历日），days最多371项且日期严格递增、唯一并位于闭区间；数值均为nullable canonical decimal string，`syncedAt`为nullable canonical decimal Unix milliseconds string。非authenticated时summary必须是idle + unknown + 三个unavailable空值；ready/stale必须携带完整对应数据和同步时间，unavailable/loading不得携带数据；usageEligibility=disabled时usage/history必须unavailable且无错误。成功的history响应允许Renderer把返回范围内未列出的日期显示为零，失败或stale转换不得由缺失日期伪造零值。Account不得出现provider、catalog、model、selection、source、authorization generation、raw run mode、Task admission、API Key或Custom Provider。根`models`精确包含 `{ availability, persistenceHealth, providers, metaskSelection, metaskSelectionRevision, defaultSelection, selectionRevision, operation, errorCode, builtinProviderPresets, customProviders }`。不得发布`connections`或`ModelConnection`。`persistenceHealth`精确取`ready | recovery_required | unavailable`：前者表示canonical可用，中者表示file capability存在但canonical不可信且允许显式reset，后者表示capability不存在且没有reset action。当前内置provider为 `{ id: "metask", displayName, recommended: true, catalogState, principalRef, models, catalogGeneration, sourceGeneration, errorCode, safeDiagnostic }`；Account授权不可用时其catalogState为`needs_authentication`，models数组为空，但durable无secret selection可以保留。`defaultSelection`与`metaskSelection`均为nullable完整`ModelRef`，Metask selection 的 `sourceId` 固定为 `metask`，不得用裸model id或显示名代替；Provider-local`metaskSelection`有值不能替代nullable global`defaultSelection`，后者为空时Product Control不得据此伪造active binding。 两者是可持久保留的 desired intent，允许引用当前 ready catalog 已排除的模型；Renderer 不因 intent 不在目录而拒绝合法 Snapshot。`catalogState=ready` 表示当前权威目录已接纳，不保证目录非空或 intent 可解析；空目录使用 `errorCode=no_models`。选择及新的执行资格仍由 Host 的 membership、revision/generation 与 `newTaskAdmission` 判断。

根 `newTaskAdmission` 精确包含 `{ available, reason, activeModelRef, activeGeneration, activeSelectionRevision, state }`：`state = unavailable | ready | replacing`，`activeModelRef` 为 nullable 完整 `ModelRef`；无 active binding 时 generation 与 selection revision 必须为 `"0"`，有 active binding 时 generation 必须非零。只有 ready 可以令 `available = true`，replacing 必须拒绝。`reason` 精确区分 `none | custom_provider_persistence_unavailable | credential_unavailable | invalid_candidate | resource_exhausted | schedule_persistence_unavailable | schedule_persistence_failed | schedule_persistence_outcome_unknown`。Models 的 `defaultSelection` 是 desired intent；`newTaskAdmission.activeModelRef/activeGeneration/activeSelectionRevision` 是 Product Control 当前进程已安装事实，两者不得互相伪造。Account authenticated、Models unavailable与 New Task admission unavailable 可以独立组合。Renderer不得从 Account、首个 ready connection或裸 model id反推 admission，不得把连接字段拼成 `tasks.run` payload，也不得把连接测试 candidate当作正式 Task binding。

`capabilities` 在既有 Task/Schedule persistence health 旁精确发布 `taskHistoryRecoveryAvailable` 与 `scheduledTaskRecoveryAvailable`，并在 `taskHistoryRecoveryAvailable` 之后发布 `retainedTaskHistoryCount`：当前版本无法恢复、按原字节保留的 Task record 数量，十进制 wire integer，不随 commit 清零。两者只在对应 Application file capability 存在且 health 为 `read_failed | corrupt | write_failed | outcome_unknown` 时为 true；`ready | degraded | unavailable` 必须为 false。显式命令分别为 `metawork.tasks.recoverHistory` 与 `metawork.scheduledTasks.recoverStore`，payload 精确为 `{ expectedRevision }`，结果精确为 `{ outcome }`，outcome 取 `recovered | stale_revision | not_required | unavailable | failed | outcome_unknown | shutting_down`。命令只请求对应 Product owner 用当前内存真相替换 store；Renderer 不提交路径、文件内容、reset mode 或重放标志。

`connect` 是 product delivery 的 bootstrap 边界。Host 必须在合同身份与 revision 校验成功后才建立 `ProductDelivery` connection；既有 `requireWindow()` 门禁随后统一保护 Account、Task、event 和 snapshot 产品路径。协商前只允许显式列出的无状态 bootstrap/smoke 命令，不得读取或修改产品状态。合同不匹配返回 typed terminal bootstrap error，Renderer 不把它当作瞬时断线重试。

Zig/TypeScript 的 identity、revision 和完整 command catalog 必须精确一致，`app.zon` allowlist 不得缺项或多项；Host serializer → TypeScript decoder 与 TypeScript bootstrap payload → Host decoder 必须有跨语言 fixture/行为测试。Renderer 内同一 wire enum 的 TypeScript type 与 runtime decoder 必须消费同一值目录，不能维护彼此独立的 union 与 allowlist；Host 新增产品 cause 时，serializer、Renderer 值目录、文案和跨语言 fixture 必须在同一变更中收齐。Renderer 始终 runtime decode Host payload；malformed payload 或 decoder/serializer contract mismatch 一律进入 fail-closed view-sync failure，不能猜测字段或静默降级。

采用结构派生的对象以发布 owner 的纯 Zig wire 类型与显式编码声明为唯一结构定义，实际 Host serializer 必须消费同一定义；Renderer 类型、字段集合、基础 decoder 与共享运输限制从中生成，禁止另行手写维护被接管的表达。Product 的投影类型不得反向依赖 Bridge；Bridge 运输描述符由 Bridge 发布。结构生成不接管脱敏、权限、对象关联或业务状态校验，也不得要求先物化完整 Snapshot 对象图或突破既有流式写入、同步借用与容量预算。不支持的编码必须在构建时明确失败。生成结果随源码提交，其新鲜度及跨语言验证由[验证规范](validation.md#标准入口)负责。

结构诊断只报告发生差异的对象路径、缺少的已知字段及额外字段数量，缺字段名称的条数与总长度必须有界；不得输出任意输入 key、字段值或原始 payload。未知 enum 值不回显原文。结构拒绝不自动证明运行组件版本不同，不触发兼容解码或命令重放。

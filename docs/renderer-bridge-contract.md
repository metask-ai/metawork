# MetaWork Renderer Bridge 合同

> 状态：`metawork.renderer-bridge` 固定 revision 1
> 日期：2026-08-07

顶层模块职责见 [MetaWork 高层架构](architecture.md)，用户可见的信息架构、交互与视觉见 [UI 设计规范](ui-design.md)。本文件是 Renderer 与 Product 之间 command、event、Snapshot、连接与运输语义的唯一架构真源；具体源码目录见 [工程结构与所有权](project-structure.md)，持续验收入口见 [验证规范](validation.md)。

## 1. Bridge 定位

Bridge 是 Renderer 与 Host 之间唯一的产品命令和 Product projection 边界，承运两类 surface。产品命令面：验证调用来源与启动窗口 identity、严格解码 payload、把合法输入转换为产品命令、dispatch 给 Product 中对应 owner、编码 typed result，并通过 Snapshot/Event 运输发布产品投影；Bridge 不决定 Task 是否可以运行、Workspace 是否有效、Agent 是否应取消、credential 是否可以替换或历史如何持久化，这些判断必须由 Product 内对应 owner 完成。受限平台 capability 面：只承运 window-chrome bootstrap capability，当前封闭枚举为 `metawork.host.windowChrome.connect / sync / beginDrag / control / disconnect` 五个 command，dispatch 给 Application 执行，原生窗口行为与真实状态由 Native SDK/OS 拥有。两面共用同一 transport、origin policy 与 source/window authority，不共用数据面；新增平台面 command 必须与 capability seam 同级登记（identity、SDK 缺口、删除条件），不因该面已存在而豁免。

Renderer 的可信定位与 Native SDK WebView UI/input 边界以[高层架构](architecture.md#31-renderer)为准。Bridge 的严格 command catalog、runtime decode、source/window 校验、CAS 与 Product admission 用于维护 owner、处理陈旧 UI 状态、隔离实现错误并拒绝畸形输入。本地路径等输入只有在具体领域合同明确登记时才能通过容量有界的 typed command 转交，Host 仍独立校验文件类型、范围、当前 authority 与生命周期；这不形成 generic file、process 或 OS action command。

Task binding projection 只运输 `epoch + availability + protocol + model + executionGeneration + unavailableReason`。Models provider `apiKeys[]` 同样只发布 `protocol`。Scheduled Task 的 `binding` 精确为 `{ status: "bound", modelRef, sourceGeneration, selectionRevision, protocol }`，没有其他判别分支。三处 protocol 均精确取 `openai_responses | openai_chat_completions | anthropic_messages | gemini_native`，不发布厂商类别。revision 1 对这些 shape 原地 hard cut，旧 Scheduled Task `execution`、旧 `provider` 与 migration shape 既不接受也不归一化。`unavailableReason` 当前只有 `runtime_detached`，表示恢复历史没有进程内 Session/ExecutionConfig；Task projection 不包含 account identity、API Key selection/metadata、Custom Provider identity/generation、credential locator 或完整 ExecutionConfig，也不得用当前 Account/Models projection 为历史 Task 补写这些字段。

Bridge 的唯一产品数据面由具体 `Dispatcher` 内部的 `ProductDelivery` 统一拥有：connection generation、revision retry/timer、snapshot identity 和 snapshot transport storage 都不再存放在 `app.zig`。Dispatcher 通过明确的 `*product_control.Runtime` 同步生成 snapshot；Application 只注入 Native emit/timer/dialog/window-chrome/main-thread capability，并组织 Bridge、Product、Agent 与 Native SDK 的顶层 shutdown；Agent event 的产品投影和固定终态 drain 屏障由 Product Control 执行，Application 只安排 main-loop 调用。

`hidden_inset_tall` 的 System WebView window chrome 是独立于 ProductDelivery connection 的受限 Host bootstrap capability。browser-side Bridge boundary 直接使用既有 `window.zero.invoke` transport 执行 `metawork.host.windowChrome.connect/sync/control/disconnect`，并且只有 Host 返回 `livePointerDrag = true` 时才可执行 `beginDrag`。`connect` 返回 document generation、可用 top band/safe insets、caption-button bounds、`rendererControls`、`maximized` 与 live-pointer capability；`sync` 只接受 viewport 和最多一个 top-band candidate 加 32 个 contained exclusions；`beginDrag` 只接受同 generation 的 Web client coordinate；`control` 只接受同 generation 的 `minimize | toggle_maximize | close`；`disconnect` 精确撤销同一 generation。所有响应在 browser-side Bridge runtime decode 后才写入 CSS variables/document dataset，React product component 只绘制 declarative controls，不消费 DTO、不调用 transport、不维护窗口状态。

Bridge policy 先约束 origin，Dispatcher 再校验 Application 注入的单一启动窗口 identity、document generation、payload 上界与主线程；Application capability 不能接收 HWND、活动窗口猜测、任意 action、platform 或独立 state query。document generation 与 source-window authority 只归 Dispatcher：`connect` 在 document attach 时建立一次 generation，`sync`、`beginDrag`、`control` 与 `disconnect` 只能使用该 generation；resize、layout 或 command failure 都不得隐式 reconnect 或轮换 generation。browser-side Bridge 通过 Native SDK 正式 `window.zero.on("resize")` 事件、`ResizeObserver` 与 `MutationObserver` 把最新 viewport/region snapshot 合并到同一个 animation-frame scheduler，并保证最多一个 `sync` in flight；`sync` 以完整候选集事务式替换 live regions，失败输入不得造成半更新，也不得清除仍有效的 control environment 或 session。Windows `beginDrag` 把 Renderer 坐标只当作格式与候选一致性输入；Application capability 必须以当前逻辑主鼠标键、实际 OS 光标、光标下 HWND 的 root identity、native hit、DPI 和最新 region snapshot 重新授权，再把手势交给系统 caption move loop。一次 `beginDrag` 失败只结束当前手势，只有 `sync` 失败才使 Renderer 的 drag geometry gate 失效。`minimize` 使用 Native SDK Runtime API，SDK 0.8.0 尚未提供的 maximize/restore、user-close 和 maximized state 由独立登记的 `system_webview_window_controls` seam 补齐，user-close 必须进入 `close_policy = hide` 的平台用户关闭路径。macOS `beginDrag` 仅补足 SDK 对 live pointer event 的要求并保留系统交通灯。拖动循环、resize、close policy、托盘和真实状态始终由 Native SDK/OS 拥有。该 bootstrap capability 不建立第二产品数据面，也不得扩展为通用窗口 API、Native SDK adapter、第二窗口 owner 或任意 action facade；Native SDK 官方能力经平台验收可用后，必须在 revision 1 内逐项原位替换对应 seam，并同步收口不再需要的 command、allowlist、DTO 和测试。automation 只能驱动真实产品路径，不注册测试专用协议。

## 2. ProductDelivery 与 Snapshot transport

Host view snapshot 使用 Bridge `Dispatcher` 内部 `ProductDelivery` 独占的 64 MiB 有界存储，不受 Bridge 单次 1 MiB result 上限反向约束。该容量覆盖 512 KiB Task projection、最大 Models provider/API Key/model catalog、bounded Custom Provider projection、Workspace/Task Skill catalog 结构、JSON 最坏转义和全部结构上界。Dispatcher 同时拥有 callback gate、workspace grants、handler registry 和 `*product_control.Runtime`，产品 command 的 decode、authority、domain call 与 response encode 不再经过 `app.zig`。Product Control writer 只能在同步调用期间借用这块 output buffer；返回后 Bridge 独占 encoded bytes，禁止保存 Product Control borrowed view。Renderer 通过带 snapshot identity 的 256 KiB 分块读取完成 resync；begin 写入前先使旧 descriptor 失效，序列化失败后旧 identity 必须保持 stale，不能继续读取已被部分覆盖的 store。revision 通知和 snapshot 拉取分别保留 pending/retry 状态，瞬时发送或读取失败不能把旧视图标记为最新。revision retry 同时受 attempt 和 deadline 预算约束，耗尽或 retry timer 不可用时当前 event connection fail closed，但不终止后台 Agent Run。新 event generation 建立时会使旧 snapshot descriptor 失效；Renderer 若仍持有旧 generation Promise，必须在旧 Promise 退出后继续完成新 generation 的实际 resync，不能把等待旧 Promise 误判为同步成功。Bridge 异步保留的 payload 必须自有；Application 在 shutdown 时先 stop Bridge ingress，在 Native platform loop 上确认同步 handler quiescence，再关闭 delivery connection、取消 timer，并 detach Product Control；随后依次收口 Account/Models coordinator、Product Control 与 Agent，完成 terminal drain/lifecycle sync，最后才独立释放 delivery buffers。

## 3. Renderer Bridge wire contract

Run 的 `elapsedMs` 是 nullable canonical decimal `u64` string：表示 Host 在本次 Snapshot 采样时，从本轮接纳起经过的单调时间，包含排队、批准等待和重试。正式 terminal 或没有可靠计时事实时必须为 null，不从历史补写。它不是事件活跃度、完成比例或剩余时间；时钟推进不发布 revision。Renderer 仅用本次 Snapshot 的本地接收时刻外推低频显示，reload 必须重新采样，不能从组件挂载时起算或将显示时间写回 Host。

`metawork.tasks.create` 的 execution admission 字段精确为 `expectedExecutionGeneration + expectedSelectionRevision + modelSelection`，三者必须同时存在，其中前两者来自同一份根 `newTaskAdmission` snapshot 且均为非零 canonical wire id。`modelSelection` 精确为 `null | { targetModelRef: { sourceId, modelId }, expectedSourceGeneration, expectedCatalogGeneration }`：null 表示采用 active default；非 null 表示只为本次新 Task 选择同一 active source 中的另一个当前 ready 模型。Host 在创建事务中同时 compare-and-swap当前 active generation 与 selection revision，并对 override 重新校验 active source、protocol、source generation 与 catalog generation/membership；缺字段、revision/generation 已变化、跨 source 或模型已失效均 fail closed，绝不回退默认模型。这样同一 execution authority 内默认模型变化可以保持 generation 稳定，同时不会让旧 Renderer snapshot 静默采用新的默认模型，也不会把单 Task 选择写回 global default。

每个 Task 根对象必须发布 Host-owned `modelSelectionAvailability`，精确取 `available | catalog_loading | catalog_unavailable | execution_replacing | runtime_detached | unsupported_source | authority_changed`。Product Control 根据 Task binding、当前 installed execution、replacement 与 Models catalog 的跨 owner 事实一次性计算；Renderer 只消费该枚举决定菜单可编辑、暂时禁用或只读及其原因，不得再比较根 `models`、`newTaskAdmission` 与 Task 字段重建 authority。缺失或未知值属于 snapshot contract failure。

Host 与 Renderer 随同一应用包原子发布，不承担旧 Renderer/新 Host 或新 Renderer/旧 Host 的兼容。bootstrap 必须拒绝合同 identity 或经用户批准后出现的 revision 错配；固定 revision 策略下，`connect` 无法通过 revision 数字识别同 revision 的陈旧开发产物。严格 command catalog 和 payload decoder 只能在实际命令或结构差异被触及时失败，不能检测纯 wire 语义错配。此类错配属于 unsupported development state，必须通过 clean rebuild、清理缓存或重新安装恢复；原子打包用于降低发生概率，不构成 runtime compatibility guarantee。Renderer Bridge contract 覆盖全部 product command、event 和 snapshot wire surface；它与产品版本、AgentCore ABI、bundle manifest schema 相互独立。

Renderer Bridge 使用独立合同身份 `metawork.renderer-bridge`，快速开发阶段固定 revision 为 `1`。Host 与 Renderer 随同一应用包原子发布，任何 command、event、payload 字段或 wire 语义变化都直接原地 hard cut，不为临时合同形态递增 revision、不维护兼容层，也不在 snapshot 内维护第二个局部版本。`contractRevision` 仍精确匹配，用于拒绝非当前固定标识，但不承诺识别同 revision 的开发产物错配。任何合同类版本标识的变更都必须先得到用户显式同意；对本文件即包括 Renderer Bridge revision。

Run snapshot 已在 revision 1 内原地 hard cut 删除自由文本 `assistant`、`assistantRedacted`、`status`，以及 Run 顶层 `outcome/cause` 与 Task 顶层 `lastRunOutcome/cause`。每个 Run 精确发布 `execution + output + activity + terminal`：`execution = { generation, protocol, model }`，generation 是非零 canonical decimal wire integer，protocol 为合同既有封闭枚举，model 是该 Run 实际持有的无 secret model identity；它们是不可由 Task 当前 binding 或 Models 当前默认值补写的逐 Run 历史 provenance。Task 最近结果由最后一个非空 Run terminal 派生，不发布第二份摘要。

`output = { commentary, response, responseKind, provisional, redacted, provisionalRedacted }`，其中 `commentary` 是最多 256 项的有序 string array，每一项对应一个非空、已闭合的 Product commentary group；数组顺序只表达 Run 内的稳定叙事顺序，不运输时间戳、CoreEvent identity、Tool 关联或 raw event timeline。credential 清洗跨整个 canonical output 一次完成，可以使个别投影项为空，但不得改变项数或泄漏跨边界 credential。`responseKind = final | partial | null`；null 时 response 必须为空，分类后的 response 不得同时保留 provisional，terminal Run 的 provisional 必须为空。全部 commentary 项、response 与 provisional 来自同一个 Host output byte budget；provisional 只包含 open/continued buffer 中 credential-safe committed bytes，discard 后必须消失。

`activity` 是 nullable discriminated union：简单 kind 为 `queued | starting | waiting_model | thinking | writing_response | waiting_user | compacting_context | finalizing | stopping`；`executing_tools.inFlight` 为 nullable canonical decimal wire integer string，非空时必须为正数；`retrying_provider.attempt/max/delayMs` 要么全部为空、要么都是 canonical decimal wire integer string，attempt/max 为正数、delayMs 可为零且 attempt 不超过 max。`terminal` 精确为 `null | { outcome, cause, diagnosticDisposition }`；非 terminal Run 必须具有 activity 且 terminal 为 null，terminal Run 必须没有 activity且 terminal 非空，phase 与 outcome 必须一致。`cause` 保留 Product 已知的稳定分类。`diagnosticDisposition = absent | withheld`：absent 表示 Agent/Provider 终态没有附加诊断，withheld 表示 Host 接收过非空、被截断或被 credential 清洗的附加诊断，但这些内容按安全边界只留在 Host，不进入 snapshot。该字段不证明诊断的具体类别，也不得被 Renderer 扩写成鉴权、限流、网络或配置结论。AgentCore `api_error`、`tool_error` 与 `image_input_unsupported` 分别映射为 Product `provider_failure`、`tool_failure` 与 `image_input_unsupported`，不得折叠成 `agent_failure` 或把 provider raw diagnostic 发布给 Renderer。queued、waiting_ui、stopping phase 分别只接受 queued、waiting_user、stopping activity。旧字段、缺失 execution/terminal 或额外兼容 shape 一律由严格 decoder 拒绝，不归一化、不 fallback。

每个 Run 另精确发布 `fileChanges = null | { observation, changes }`。null 表示没有建立 typed observation，不能解释为“确认没有修改”；observation 只取 `collecting | complete | incomplete`。`changes[]` entry 精确为 `{ id, order, kind, status, displayPath, fromDisplayPath, beforeBytes, afterBytes, diffAvailable, diffComplete, redacted }`：id 是 Run 内 opaque identity，order、beforeBytes、afterBytes 是 canonical decimal `u64` string；kind 只取 `created | modified | deleted | moved`，status 只取 `applied | partial`，fromDisplayPath 只在 moved 时非空，其余安全标志均为 boolean。同一 Run 的 id 和 order 必须唯一并按 order 严格递增；同路径多次记录不得合并。该投影不运输 raw locator、absolute path、AgentCore handle、agent depth、unified diff、credential 或文件当前内容。根 capability `typedFileChanges` 为 true 时 Renderer 才可消费此字段。

每个 Task 精确发布 `context = { pressure, lastAutoCompact }`。pressure 为 null，或 `{ sourceRunId, currentTokens, warningThreshold, autoCompactThreshold, blockingLimit, severity }`；lastAutoCompact 为 null，或 `{ sourceRunId, dropped, kept, beforeTokens, afterTokens }`。所有计量使用 canonical decimal wire integer，sourceRunId 必须引用同一 Task 的 Run history；threshold 顺序、severity 与 token 数必须一致。context 属于当前 attached Conversation，可跨同一 Session 的 Run 保留，但 Task detach/replacement/restart 后两项均为空，且 detached Task 不得发布 observation。该 surface 不运输 raw CoreEvent tag、transition sequence、private reasoning、provider diagnostic 或 `file_changes`。

Tool 的 `bash` 必填且 nullable，只由 Host 为精确 `Bash` identifier 投影：`{ command: string | null, description: string | null, result: null | { exitCode: i32, stdout: string, stderr: string, stdoutIncomplete: boolean, stderrIncomplete: boolean } }`。description 依附已解析的 command；运行中的 Tool 或截断的原始 content 不得提供 result，截断的 input 不得提供 command。未知、超出解析预算或不完整的 envelope 保留原始安全证据而不猜测可读字段；解码后的文本仍受 credential 清洗。DTO 不改变 Tool state、Run activity、terminal、fileRefs 或持久化格式。

`output`、`activity`、`tools` 与 `context` 只定义 Renderer 可消费的产品事实和 fail-closed 边界，不规定最终组件、布局、展开策略或更新节奏。当前 Agent 对话的 owner 链、Run exchange 槽位、active→terminal process surface 迁移和 full Snapshot 渲染机制由 [UI 设计规范](ui-design.md#72-agent-对话渲染机制)定义；wire 字段存在、scripted Provider vertical 或静态 DOM 通过都不能替代真实 Provider cadence 与长任务阅读体验的独立验收。后续纯呈现调整仍可在不改变 revision 1 wire 语义的前提下进行。

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

根 `capabilities.attachments` 精确为 `{ enabled, imageFormats, maxFiles, maxFileBytes, maxStagedBytes }`。`enabled` 为 boolean，`imageFormats` 在开放时精确为有序 `png | jpeg | webp` 数组，表示当前可发送的图片分类；其他 limit 是 canonical decimal `u64` string。Renderer 只用该对象解释入口和本地 admission，Host 对 command 重新执行全部限制；文本附件的 64 KiB 分类上限由 Host 通过 typed rejection 权威执行，不增加第二个 capability 字段。

成功的 `metawork.events.connect` 响应增加 `attachmentInput = { mode, maxChunkBytes }`，拒绝响应不带该字段。Application 选择 `mode = native_paths | file_bytes`；Windows 使用 `file_bytes`，其他平台使用 `native_paths`。`maxChunkBytes` 是非零 canonical decimal raw-byte 上限，不能超过单次 Bridge frame 预算；它只约束字节入口，不是 Product capability。Renderer 每个平台只消费一个拖放入口，不监听另一入口作重试或超时 fallback。

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

通过 UTF-8 文本分类的文件 entry 不含 `format`：

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

`metawork.tasks.run` 在既有 `text | skill` 上原地 hard cut 增加 `{ kind: "multimodal", text, attachmentTokens }`。`text` 是 string，允许为空；`attachmentTokens` 必须为非空、有界、无重复的 string array。非空 text 成为第一个 Agent part，后续 part 按 token 数组顺序；Skill 字段和 multimodal 字段不能混合。Bridge 只校验 wire 与 grant authority，Product 决定 Task/Session admission和 token 的 borrow/consume transaction。任一 token 指向 `kind=file` 时，去除首尾空白后的 `text` 必须非空，否则 Run 返回 `reason=missing_instruction` 且保留全部 ready grant；接纳后的文本附件作为独立普通 text part 发送。Run 接纳后即使 history save、enqueue、transport 或 Agent terminal 失败也不得恢复或自动重放。

Run snapshot 的 `input` 对 multimodal 精确发布 `{ kind, text, attachments, redacted }`。`text` 为 nullable string；`attachments[]` 是严格 tagged union：图片精确为 `{ kind: "image", format, displayName, sizeBytes, redacted }`，文本附件精确为 `{ kind: "file", displayName, sizeBytes, redacted }`。顺序与已接纳 input 一致。Snapshot 与 persistence 不含 token、路径、文本附件正文、raw bytes、Base64、digest 或 provider wire。旧 history record 没有 attachment 字段时只解释为 text/skill 旧 Run，不从正文或文件引用猜测附件。

当前 `metawork.tasks.run` 使用 `input.kind = text | skill | multimodal` 的唯一 tagged payload，旧 `prompt` 不兼容；Skill input 精确为 `{ kind, skillId, catalogRevision, selectionRevision, argumentValues }`，multimodal 精确遵守上节 token 合同。`tasks.create` 必须携带 `workspace = { kind: "automatic" } | { kind: "manual", workspaceId, expectedWorkspaceEpoch }`、必填 nullable `modelSelection`、nullable `expectedSkillCatalogRevision`、nullable `expectedSkillSelectionRevision` 和 `permissionProfile = approval_required | full_access`；Text 与 multimodal 的两个 Skill revision 均为 `null`，Skill 两者均非空，混合状态 fail closed。成功 create result 与每个 Task snapshot 都必须包含 `mcpAuthority = { kind: "ready", selection: "selected" | "none" } | { kind: "unavailable", selection: null }`；失败 create result 的该字段为 null。它只描述创建时复制的 immutable MCP authority，不包含 server/tool/credential，不授权 Renderer 热附加或推断当前 MCP 状态。Bridge 与 Product Control 直接使用同一组 `manual | automatic` admission 语义；混合、缺字段或未知 kind/profile 的 payload 一律 fail closed。不存在 `workspaces.select` 命令或 Snapshot 级 selected Workspace；Manual 选择和模型 override 只属于 Renderer New task draft，真正的 Workspace epoch/authorization/recent order 与模型 authority 在 `tasks.create` 事务中校验和提交。`automaticWorkspaces` 只声明新 Automatic Workspace 的分配能力；capability 不可用时，已恢复的 Automatic Workspace 与 owning Task 历史仍可出现在 snapshot 中。Skill 没有 `runSkill` 第二入口。Workspace/Task catalog、typed Run history 和 Skill terminal cause 只从 Product Control snapshot 发布；显式 catalog refresh 也只通过 Bridge 调用 Product Control transaction，Bridge 不持有 catalog lease、不解析 slash、不读取 Skill body。

`metawork.tasks.compact` payload 精确为 `{ taskId, expectedBindingEpoch }`，结果精确为 `{ accepted, taskId, operationId, reason }`。`accepted=true` 表示 Product 已建立该 Compact operation identity，不承诺 executor enqueue 或 Agent compact 成功；即使紧随其后的 queue submit 失败，command 仍返回该 accepted `operationId`，随后 canonical Task snapshot 以同一 operation 发布 `phase=failed, cause=resource_limit` 并清除 active operation。Renderer 必须等待 snapshot terminal，不得把 accepted acknowledgement 改判为 command rejection、恢复旧状态或自动重放。

权限策略沿用同一 revision 1 合同原地 hard cut。根 `capabilities.permissionProfiles` 与根 `permissions = { availableProfiles, defaultProfile }` 必须一致：关闭时 available 只能为空，开放时必须精确发布 `approval_required`、`full_access` 完整集合；default 始终是其中之一。`metawork.tasks.create` 成功提交交互式 Task 时必须在同一 Product canonical mutation 中把必填 `permissionProfile` 记为后续默认，并与 Task 历史共用 best-effort persistence；admission 拒绝、回滚与 noninteractive Scheduled occurrence 不得改变。不存在独立修改 default 的 Bridge command。每个 Task 必须发布创建时固定的 `permissionProfile`，每个 Run 必须发布同一 profile 和 `permissionInteraction = interactive | noninteractive`；Renderer 必须拒绝 Run 与 owning Task profile 不一致的 snapshot。已有 Task 不提供改写命令。Scheduled Task projection 同样必须发布当前定义固定的 `permissionProfile`；create/update mutation 必须携带该字段，每次 occurrence 对应的 Task/Run 必须复制 launch 时的定义 profile 并使用 `noninteractive`。后续定义 update 不改写历史 Task，Renderer 不得将历史 Task profile 与当前定义 profile 比较。Schedule failure/occurrence reason 增加 `permission_required`，此时 definition 必须为 `needs_attention`。`permission_required` 是非交互 Run 遇到未覆盖 effect 时的 typed terminal cause，不得转化为 pending UI 或后台弹窗。

Scheduled Task create/update mutation 的模型字段精确为 `binding: { modelRef: { sourceId, modelId }, sourceGeneration, selectionRevision, protocol }`，不得携带 `expectedExecutionGeneration`。Renderer 只能从同一 snapshot 的 Models global default 与 `newTaskAdmission` active authority 构造它；source/model、source generation、selection revision、protocol 或 active authority 任一不一致时禁用保存。Host 在 mutation 和每次 occurrence 前重新做相同精确校验并当次 resolve。Host 不发布或接受缺少完整 source-qualified identity 的旧 binding，也不提供 Renderer 重绑迁移状态。occurrence `taskOutcome` 精确接受 `completed | stopped | cancelled | interrupted | failed | dependency_contract_failure | unavailable | null`；`unavailable` 表示该 occurrence 引用的真实 Task 已不再存在，不得伪装成 Task terminal cause。

`metawork.tasks.delete` 只接受 `{ taskId }`，仅对已归档 Task 开放。成功返回 `{ taskId, deleting: true }`，表示 Product Control 已受理唯一删除意图；它不声称 Task 已经物理删除。Task snapshot 以 `deletionStatus = idle | deleting | failed` 发布该 runtime-only 产品用例：`deleting` 时 Renderer 等待后续 snapshot 移除 Task，`failed` 时保留归档 Task 并重新开放显式删除动作。Product Control 自行收口 Attachment、等待 worker/checkpoint quiescence、提交 Task store；Renderer 不重复提交正常推进、不编排 Session teardown，也不解析 checkpoint、close failure 或 worker reference。

每个 Task snapshot 必须发布 `unreadCompletionRunId: canonical decimal u64 | null`。非空时必须精确引用该 Task `runs` 中最新的 terminal Run，且其 `terminal.outcome = completed`；不存在成功完成、最新 terminal 是其他 outcome，或该 Run 已由 Product receipt 确认时必须为 null。Renderer 不从 Run 数组另建未读真源。

`metawork.tasks.markCompletionSeen` 只接受 `{ taskId, runId }`，两者都是非零 canonical decimal u64；返回 `{ taskId, runId, marked }`。只有该 Task 仍存在、未进入删除流程，且 `runId` 仍是最新 terminal `completed` Run 时才能推进 receipt 并返回 `marked=true`；重复、迟到、归档已确认或目标消失统一返回 `marked=false`，不得清除后来 Run 的提醒。成功 mutation 发布新的 snapshot revision，但不改变 Task `recentOrder`，也不单独强制 history commit；receipt 随 Product 的下一既有 durable boundary 或 clean shutdown 合并持久化。Renderer 只能在中央 Task 工作面真实暴露且 document 可见、窗口有焦点时调用；Settings、搜索、窄窗左栏、非停靠 Task Panel、断连和同步失败期间不能确认。该命令没有用户可见错误或自动重放；结果不确定时继续以 canonical snapshot 为准。

`metawork.skills.setEnabled` 是 revision 1 内的原地 hard cut command。payload 精确为 `{ scope, workspaceId, expectedWorkspaceEpoch, skillPolicyKey, state, expectedCatalogRevision, expectedSelectionRevision }`：`scope = personal` 时两个 Workspace 字段必须为 null 且 `state = enabled | disabled`；`scope = project` 时两个 Workspace 字段必须是已授权 Manual Workspace 的 canonical identity，且 `state = inherit | enabled | disabled`。`skillPolicyKey` 必须属于对应 current catalog，不能用易随内容变化的 concrete `skillId` 代替。成功返回 `{ applied: true, selectionRevision, reason: null }`，业务拒绝返回 `{ applied: false, selectionRevision: null, reason }`；非法 shape、越权或非 canonical identity 仍 fail closed。Snapshot 中每个 `skillCatalog` 含 nullable `selectionRevision`，每个 descriptor 含 effective `enabled`；ready/degraded catalog 的两份 revision 均非空，其他状态均为 null。`skillManagement` 含 `enablementAvailability`，asset 含 nullable `skillPolicyKey`、nullable effective `enabled`、nullable `enablementState`、`canSetEnabled` 与 nullable `selectionRevision`；Personal 的 state 只取 enabled/disabled，Project 的 state 可以 inherit。管理 authority 与 enablement authority 分离，能够精确映射当前 catalog member 的 external asset 也可启停，但仍不可因此获得导出、重新导入或卸载 authority。

已有 Task 的模型切换使用独立的 `metawork.tasks.selectModel` command，payload 精确为 `{ taskId, expectedModel, expectedExecutionGeneration, targetModelRef: { sourceId, modelId }, expectedSourceGeneration, expectedCatalogGeneration }`，结果为 `{ accepted, taskId, model, reason }`。`expectedModel + expectedExecutionGeneration` 是 Task 当前 binding 的 compare-and-swap 事实，`targetModelRef + expectedSourceGeneration + expectedCatalogGeneration` 是 Models 当前 Metask authority 的 source-qualified 候选；payload 不携带 credential。Host 只有在 Product Control 当前安装的 active `ModelRef`、Task protocol/generation、Models Metask source/catalog generation 与 payload 精确一致、replacement未开始且目标模型仍在该 catalog时才接受；任一 authority/catalog 漂移统一返回 `stale_catalog`。Task 当前 pinned model 已离开目录不阻止它选择仍有效候选。source-qualified payload 不开放跨 source 能力；Custom Provider Task 仍不复用 Metask catalog，也不开放已有 Task 模型切换。模型切换不 bump Task `binding.epoch`，不改变 pinned `executionGeneration`；已有 Run继续使用自己的历史模型。活跃 Run期间的选择只进入 Host runtime pending，下一次 Run admission前应用，pending不进入 persistence或 Snapshot wire；随后发生的默认 replacement不撤销此前在 exact authority下已接受的 pending选择。

Conversation recovery 使用同一 revision 1 数据面上的 `metawork.tasks.restore`。payload 精确为 `{ taskId, expectedBindingEpoch }`，结果精确为 `{ accepted, taskId, attemptId, reason }`；`attemptId` 仅在 accepted 时为 canonical decimal `u64`，reason 仅在 rejected 时取 `binding_changed | task_unavailable | recovery_unavailable | capacity_reached | shutting_down`。Bridge 只负责严格 decode、Task authority 与结果 encode，不读取 checkpoint、不决定 eligibility、不调用 Agent。该 command 可由用户 Retry 或发送路径内部调用；accepted 只表示恢复 job 已入队，Renderer 必须等待同一 Task 的 canonical snapshot 确认 attachment 后才能提交 `tasks.run`。AgentCore complete 与 degraded restore 都通过同一既有 attachment/continuation shape 表示成功；degraded 的 Permission accounting 继续只由 `restorePermission` 表示，不新增 command result、Snapshot 字段或 revision。结果不确定或 Renderer timeout 时只能 resync snapshot，不能自动重放。

Pending permission projection 使用 `{ requestId, runId, order, redacted, kind: "permission", tool, args, availableChoices }`。`availableChoices` 由 AgentCore 当前 request 的 `responses[]` 计算；Session choice 只有在 candidate 存在时才可发布，当前锁定 AgentCore 合同的 candidate scope 为 `exact_arguments`。Renderer 只能提交 `deny_once | deny_session | allow_once | allow_session` 中实际出现在 `availableChoices` 的 choice；不得提交 `policy_generation`、candidate `rule_id` 或原始 AgentCore response。Agent 从 pending request 回填这些 ABI 字段并完成最终校验。

Permission occurrence 在 `uiHistory` 中额外携带 `agentRequestId` 与 nullable `permission` 摘要。摘要字段固定为 `requestId`、`matchedRuleId`、`toolNamespace`、`toolName`、`toolBinding`、`decision`、`source`、`policyGeneration`、`usedSessionRule`、`callbackOutcome`；它只包含非 secret identifier 和脱敏决策结果，不包含原始参数、credential 或可重放 response。Restore 后 Task snapshot 的 `restorePermission` 仅是本次 restore 的 `{ restoredRules, invalidatedRules }` 运行健康投影，不能被 Renderer 当作本地 grant cache。

根 `capabilities.conversationRecovery` 当前为 true。每个 Task 延续唯一 continuation 模型：`continuationAvailable` 表示现在可启动下一 Run，`continuationUnavailableReason` 精确取 `session_poisoned | event_projection_failure | closing | task_archived | session_recovery_required | session_recovery_in_progress | session_recovery_failed | persistence_unavailable | checkpoint_unavailable | execution_rebind_required | workspace_unavailable | authority_unavailable | runtime_unavailable` 或 null，`continuationRecoveryAvailable` 表示当前 snapshot 下允许 Renderer 在普通发送的内部前置步骤提交 restore；它不产生独立的恢复按钮、卡片或专用 Composer 文案。`execution_rebind_required` 只表示当前 protocol/model authority 不能承载该 Task，不能用于表达历史 generation 与当前 generation 不等；Renderer 也不能把它解释为 Conversation 身份失败。Task lifecycle 精确取 `open | closing`，不存在 `closed`；删除用例另以 `deletionStatus = idle | deleting | failed` 表达，只有 archived Task 可以非 `idle`，`deleting` 必须对应 `closing` lifecycle。active operation 可取 `restore`。Decoder 必须联合校验这些字段：attached 可继续态不能同时声称可恢复；required/failed 只有在 checkpoint、Task/Workspace source identity、Execution target readiness 与 runtime-readiness 等核心 Host gate 成立时才可发布 recovery available，Skill/MCP/Permission/projection readiness 不属于这些 gate；in-progress 必须对应 restore operation；archived/closing、普通 Run/compact 或 capability=false 时不得发布恢复前置步骤。不得新增并行的 `task.recovery` 状态对象。

Skill management 使用同一 revision 1 数据面发布 bounded preview/detail/projection 与 typed import/export/reimport/uninstall mutation；command catalog、Zig DTO、TypeScript runtime decoder、snapshot fixture 和 automation 必须完全一致，不建立第二 transport 或局部 revision。

Skill asset 的 `managementState` 包含派生的 `recovery_required`，不改变持久化 Asset.state 或事务 phase。该状态必须有 installId，并关闭 canExport/canReimport/canUninstall；canRetry 仅可在 management ready 且 Host 的当前恢复/验证准入成立时为 true。现有 Retry command 不变，其物理恢复与验证分派由 Host 决定；ready/external 或 store 不可信时不得宣称可 Retry。恢复、原操作错误与全局 revision 发布的关系由 [Product 架构](product-architecture.md#24-skill-authority-与本地资产)定义。

MCP 管理使用同一 revision 1 snapshot 与 command 数据面，原地 hard cut 为 transport-discriminated catalog：既有 typed server commands 之外增加空 payload 的 `metawork.mcp.applyConfiguration`；不得暴露 generic upsert、secret-bearing payload 或第二 OAuth callback data plane。所有 server command 携带 canonical decimal `expectedDesiredGeneration` 和目标 `serverId`（create 除外）；create/update 仍只接收结构化 command + ordered arguments 或严格 HTTP endpoint，不接受 shell string。`applyConfiguration` 返回 `started | busy | rejected | unavailable`，只重试把 Host canonical desired 应用到正式 Runtime，不接受 Renderer 提供配置。完整精确命令集由 `app.zon`、Zig 与 TypeScript catalog 同步定义。

`approveConnection` 只服务 schema 1 迁移留下的 legacy unapproved server；普通 Add/Replace 不经过该 command。`captureSecret` 只携带 slot identity，由 Host secure-capture capability 直接写 credential store；该能力不可用时返回 typed `capability_unavailable`，绝不回退为 Renderer secret input。`authorizeOAuth` 只对 approved Streamable HTTP OAuth server 启动全局唯一、server-bound operation，并继续保留独立的 Host consent。`testConnection` 使用 `McpServerIdentity` payload，结果精确为 `started | busy | stale_generation | needs_authentication | rejected | unavailable`；started 表示 Host 已启动一个隔离候选 Runtime 的真实 activation，不表示测试已成功。完成状态只经 snapshot/notification 发布，不返回 raw catalog 或 diagnostic。`refreshCatalog` payload 为空，只刷新当前正式 Runtime catalog，不应用 pending connection configuration 或隐式启动 OAuth。

根 `capabilities` 必须包含 boolean `mcpManagement`、`mcpConnectionApproval`、`mcpSecretCapture` 与 `mcpOAuth`。根 `mcp` 必须精确包含 `availability`、`managementHealth`、`operation`、`configurationApply`、`authorizationOperation`、`desiredGeneration`、`runtimeAlignment`、`redacted` 与 `servers`：`configurationApply = idle | applying | failed`，其余 enum 保持既有定义。没有可信 canonical desired或 management outcome unknown 时 configurationApply 必须 idle、generation null、alignment unknown、servers 为空且 authorization operation idle。`mcpManagement = false` 时发布完整 fail-closed baseline。任何不变量不满足都使 Renderer snapshot decode fail closed。

每个 server 使用唯一 opaque `id` 与唯一 `namespace`，并精确包含 `displayName`、`transport = stdio | streamable_http`、`authMode = none | static | oauth`、`negotiation = automatic | modern_only | compat_only`、正整数 `timeoutMs`、nullable typed `connection`、`approvalStatus`、`authorizationStatus`、`desiredEnabled`、`runtimeStatus`、`newTaskAccess`、已清洗的 `safeDiagnostic`、`connectionTest` 与 `tools`。`connectionTest` 精确为 `{ status: untested | testing | connected | failed, toolCount, issueCount }`，只存在于当前进程 projection；配置 mutation 清除旧结果，Host 重启后回到 untested。`connection` 对有效、未被 credential scrub 的 STDIO 精确发布 command、ordered arguments、nullable cwd 与 environment name/status；对 Streamable HTTP 精确发布 endpoint、header name/status、registration kind、用户提供的 client id、token endpoint auth method 与 client-secret status。配置无效或已触发 credential scrub 时 `connection = null`，Renderer 不得猜测或允许盲目替换。

Host 将 Desired Registry 的完整非敏感 typed connection、authorization operation、Runtime Manifest disposition、Agent opaque Activation health 与 Admission Authority 合成为 projection。environment/header value、credential locator、client secret、token/code/PKCE、动态注册所得内部材料、raw OAuth metadata、raw diagnostic、schema body、fingerprint 和 AgentCore handle 不进入 projection；Renderer 不直接解码或镜像 AgentCore MCP schema。`redacted` 只表示 Host 确实移除了可发布文本。Runtime-alignment unknown 或 persistence outcome unknown 时不得发布 last-known desired 伪装 canonical state。

Renderer 的 Slash Resolver 只在 Composer 首 token 处理 `/` 手势。单一 Command registry 当前只由 `App` action controller 复用既有 New task 动作；Command 原文在 Renderer 消费，不产生 Run。Skill 候选只来自当前 Workspace/Task catalog projection，选择后形成带稳定 identity、pinned revision 与 positional arguments 的 tagged draft，再沿唯一 `tasks.run` 路径提交。Command/Skill 同名时裸名称归 Command，Skill 使用 `/skill:name`；Renderer 不读取 Skill body、物理路径或 policy。

Models 的 Metask API Key 切换使用 `metawork.models.selectMetaskApiKey`，payload 精确为 `{ sourceId, expectedMetaskSelectionRevision, expectedCatalogGeneration }`；`sourceId` 必须是 `metask:<api-key-id>`，成功启动后由 Models 使用新 Key 刷新其模型目录并选择该目录的首个模型。Metask Provider-local 模型选择使用 `metawork.models.configureMetaskSelection`，payload 精确为 `{ sourceId, modelId, expectedMetaskSelectionRevision, expectedCatalogGeneration }`。global default 使用 `metawork.models.selectDefault`，payload 精确为 `{ sourceId, modelId, expectedSelectionRevision, expectedSourceGeneration, expectedCatalogGeneration }`。`sourceId + modelId` 是完整 `ModelRef`；Bridge 只校验字符串边界并把 revision/generation严格解析为 `u64`，归属、membership和 CAS由 Models判断。`metawork.models.refreshCatalog` 为空 payload，只发起显式 Metask目录刷新，不能代替 API Key 切换。Account command只保留 `beginLogin | cancelOperation | retryRefresh | refreshSummary | logout`，均为空 payload；`retryRefresh` 只用于恢复 Account token refresh 调度，`refreshSummary` 只刷新账户 summary，两者都不接收任何 model/catalog payload且不能互相代替。

Models canonical 显式恢复使用 `metawork.models.resetStore`，payload 精确为 `{ expectedRevision }`，返回既有 Execution command result。该命令只在同一 snapshot 的 `models.persistenceHealth = recovery_required` 时可呈现，Bridge 只严格解析 Product revision；Product Control 与 Models owner 在执行时必须再次确认 recovery eligibility。执行时 Host 重新读取并严格解码 canonical：合法当前 schema 被非破坏性重装，中断测试完成确定性收敛；读取失败或资源耗尽拒绝且不写盘；只有文件缺失或严格确认损坏才安装当前空 schema 1。成功表示 canonical 已恢复为可信 Models 状态，不保证配置被清空，也不表示旧 bytes 被迁移、归档或启发式解释。`ready` 与 `unavailable` 必须拒绝；Renderer 不提交路径、文件内容、schema、reset mode、generation 或重放标志。该命令不修改 Account、Workspace、Task、Run 或对话历史，既有 Task-owned execution binding 不被重写。

Custom Provider credential 替换使用 `metawork.models.customProviders.replaceCredential`，payload 精确为 `{ providerId, expectedProviderRevision, apiKey }`。`apiKey` 是用户在本地桌面 Renderer 中显式填写的非空 opaque string，UTF-8 bytes 不得超过 4096；Bridge 只做严格 shape/容量校验并在本次同步调用中转交 Models，不得记录、缓存、投影、返回或异步保留该字段。Models 使用既有两阶段事务，先持久撤销旧 readiness，再写入 credential vault，最后以新的 provider/source generation 恢复为待测试状态。任一中途失败都不得让旧 readiness 配上新 credential；已有 Task/Run 的 owned binding 不受影响。

`models.providers[].models[]` 精确包含 `id`、`displayName` 与 `metadata`。metadata 精确包含 `maxInputTokens`、`maxOutputTokens` 和 `capabilities`：两个上限为 null 或正数 canonical decimal `u64` string；capabilities 精确包含 nullable boolean `imageInput`、`pdfInput`、`batch`、`citations`、`codeExecution`、`structuredOutputs`，以及对象 `thinking = { supported, adaptive, enabled }`、`effort = { supported, low, medium, high, max }`、`contextManagement = { supported, clearThinking20251015, clearToolUses20250919, compact20260112 }`，各子对象叶值同为 nullable boolean。所有 key 均必需，未知值用 null，不省略字段。Host serializer 与 Renderer strict decoder 同步消费此 shape；metadata 只读，不进入 selection command payload。声明来源、未知值和目录生命周期由 Models Metask provider拥有。

Custom Provider mutation 使用同一 revision 1 数据面上的 `metawork.models.customProviders.create | update | replaceCredential | remove`，内置官方模板创建与地址修改分别使用 `metawork.models.builtinProviders.create | updateBaseUrl`，custom model 集合使用 `metawork.models.customModels.add | replace | remove | test`。custom create 接收 `{ displayName, protocol, normalizedBaseUrl, apiKey }`；builtin create 精确接收 `{ providerId, baseUrl, apiKey }`，其中 `providerId` 只能是 `deepseek | kimi | minimax | glm`，`baseUrl` 是不含 credential、query 或 fragment 的 HTTPS URL，或 HTTP loopback URL。builtin updateBaseUrl 精确接收 `{ providerId, expectedProviderRevision, baseUrl }`，其中 `providerId` 是已创建 Provider 的 source identity。Models 根据 builtin identity 固定 display name 与 protocol，并把 Base URL 映射为该 protocol 的精确 completion endpoint；Renderer 和 Bridge 不提交或推断 protocol。`apiKey` 与 replaceCredential 相同，只能作为调用期 secret 一次性转交 Models credential vault。通用 update/remove 使用 `providerId + expectedProviderRevision`；内置模板 Provider 必须拒绝通用 update，但允许专用 updateBaseUrl、replaceCredential 与 remove。地址变更必须刷新 provider/source generation，并按 Models 既有语义撤销旧 endpoint 上的模型 readiness；已有 Task/Run 的 owned binding 不受影响。test 精确使用 `{ model: ModelRef, expectedProviderRevision, expectedSourceGeneration, expectedCatalogGeneration }`；add 使用 `{ providerId, expectedProviderRevision, expectedCatalogGeneration, model }`，replace/remove 使用完整 `ModelRef` 并携带 expected provider revision 与 catalog generation。Bridge 只接受上述精确结构，不定义旧 payload、别名、归一化或兼容分支。Host 负责 endpoint/protocol、model membership、metadata、credential 状态和全部 revision/generation 校验。

Models snapshot 中的 `builtinProviderPresets[]` 精确发布 `id + displayName + protocol + defaultBaseUrl + apiKeyUrl + documentationUrl`；`protocol` 与 `defaultBaseUrl` 是 Models-owned 模板事实，用于 Renderer 呈现默认值和 endpoint 预览，不代表用户当前保存的地址；不得发布 completion endpoint、credential 或 logo。`customProviders[]` 精确发布 `id + builtinProviderId + displayName + protocol + normalizedBaseUrl + state + credentialStatus + enabled + providerRevision + sourceGeneration + catalogGeneration + models`，其中 `builtinProviderId` 为上述四个 identity 之一或 null；其 `models[]` 成员发布 `id + displayName + metadata + metadataProvenance + testStatus + ready`。Provider 不发布 `selectedModel` 或 Provider 级 `testStatus`；模型选择只存在于 nullable global `defaultSelection`，测试状态只属于具体模型。`state = configuring | ready | disabled` 由当前 source generation 是否存在至少一个 ready model及 credential/enabled 共同决定。成功 probe 建立该精确模型的 ready proof；同一 authority 上的失败重测只改变 latest status，不撤销 proof。设置 custom 或切回 Metask 都使用统一 `metawork.models.selectDefault` 与完整 `ModelRef`；Models 先提交 desired selection，Product Control 再独立 reconcile active binding，失败不回滚 desired。根 `capabilities` 必须精确包含 boolean `customProviderManagement`、`customProviderSecretCapture` 与 `customModelTest`；revision 1 保留 `customProviderSecretCapture` wire name，其 true 表示 secret-bearing create/replace typed command 与系统 credential storage 同时可用。Host 只在 management、credential storage 与模型测试均可用时把三者同时发布为 true，任一缺失全部为 false。该判断只消费当次实际 capability，不以平台名建立静态 allowlist；Renderer 只有三者均为 true 才显示 Provider 设置。

根 `account` 精确包含 `{ state, canCancel, accountId, displayName, emailHint, concurrencyLimit, errorCode, safeDiagnostic, summary }`；authenticated 必须同时携带非空 `accountId/displayName`、可空的Host脱敏 `emailHint`与正整数 `concurrencyLimit`，其他状态的字符串identity字段都为空且`concurrencyLimit`为null；完整邮箱不得越过Bridge。`errorCode=none` 时 `safeDiagnostic` 必须为空。`summary` 精确为 `{ operation, usageEligibility, wallet, usage, history }`，operation取 `idle | refreshing`，usageEligibility取 `unknown | disabled | enabled`。wallet精确为 `{ availability, balanceU, syncedAt, errorCode, safeDiagnostic }`；usage精确为 `{ availability, today, total, syncedAt, errorCode, safeDiagnostic }`，today精确包含 `{ inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens, totalTokens, actualCostU }`，total精确包含 `{ totalTokens, actualCostU }`；history精确为 `{ availability, startDate, endDate, days, syncedAt, errorCode, safeDiagnostic }`，days的每项精确包含 `{ date, inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens, totalTokens, actualCostU }`。availability取 `unavailable | loading | ready | stale`；日期为nullable `YYYY-MM-DD`，days最多366项且日期严格递增、唯一并位于闭区间；数值均为nullable canonical decimal string，`syncedAt`为nullable canonical decimal Unix milliseconds string。非authenticated时summary必须是idle + unknown + 三个unavailable空值；ready/stale必须携带完整对应数据和同步时间，unavailable/loading不得携带数据；usageEligibility=disabled时usage/history必须unavailable且无错误。成功的history响应允许Renderer把返回范围内未列出的日期显示为零，失败或stale转换不得由缺失日期伪造零值。Account不得出现provider、catalog、model、selection、source、authorization generation、raw run mode、Task admission、API Key或Custom Provider。根`models`精确包含 `{ availability, persistenceHealth, providers, metaskSelection, metaskSelectionRevision, defaultSelection, selectionRevision, operation, errorCode, builtinProviderPresets, customProviders }`。不得发布`connections`或`ModelConnection`。`persistenceHealth`精确取`ready | recovery_required | unavailable`：前者表示canonical可用，中者表示file capability存在但canonical不可信且允许显式reset，后者表示capability不存在且没有reset action。当前内置provider为 `{ id: "metask", displayName, recommended: true, catalogState, principalRef, apiKeys, models, selectedApiKeyId, catalogGeneration, sourceGeneration, errorCode, safeDiagnostic }`；Account授权不可用时其catalogState为`needs_authentication`，catalog数组为空，但durable无secret selection可以保留。`defaultSelection`与`metaskSelection`均为nullable完整`ModelRef`，不得用裸model id或显示名代替；Provider-local`metaskSelection`有值不能替代nullable global`defaultSelection`，后者为空时Product Control不得据此伪造active binding。

根 `newTaskAdmission` 精确包含 `{ available, reason, activeModelRef, activeGeneration, activeSelectionRevision, state }`：`state = unavailable | ready | replacing`，`activeModelRef` 为 nullable 完整 `ModelRef`；无 active binding 时 generation 与 selection revision 必须为 `"0"`，有 active binding 时 generation 必须非零。只有 ready 可以令 `available = true`，replacing 必须拒绝。`reason` 精确区分 `none | custom_provider_persistence_unavailable | credential_unavailable | invalid_candidate | resource_exhausted | schedule_persistence_unavailable | schedule_persistence_failed | schedule_persistence_outcome_unknown`。Models 的 `defaultSelection` 是 desired intent；`newTaskAdmission.activeModelRef/activeGeneration/activeSelectionRevision` 是 Product Control 当前进程已安装事实，两者不得互相伪造。Account authenticated、Models unavailable与 New Task admission unavailable 可以独立组合。Renderer不得从 Account、首个 ready connection或裸 model id反推 admission，不得把连接字段拼成 `tasks.run` payload，也不得把连接测试 candidate当作正式 Task binding。

`capabilities` 在既有 Task/Schedule persistence health 旁精确发布 `taskHistoryRecoveryAvailable` 与 `scheduledTaskRecoveryAvailable`。两者只在对应 Application file capability 存在且 health 为 `read_failed | corrupt | write_failed | outcome_unknown` 时为 true；`ready | degraded | unavailable` 必须为 false。显式命令分别为 `metawork.tasks.recoverHistory` 与 `metawork.scheduledTasks.recoverStore`，payload 精确为 `{ expectedRevision }`，结果精确为 `{ outcome }`，outcome 取 `recovered | stale_revision | not_required | unavailable | failed | outcome_unknown | shutting_down`。命令只请求对应 Product owner 用当前内存真相替换 store；Renderer 不提交路径、文件内容、reset mode 或重放标志。

`connect` 是 product delivery 的 bootstrap 边界。Host 必须在合同身份与 revision 校验成功后才建立 `ProductDelivery` connection；既有 `requireWindow()` 门禁随后统一保护 Account、Task、event 和 snapshot 产品路径。协商前只允许显式列出的无状态 bootstrap/smoke 命令，不得读取或修改产品状态。合同不匹配返回 typed terminal bootstrap error，Renderer 不把它当作瞬时断线重试。

Zig/TypeScript 的 identity、revision 和完整 command catalog 必须精确一致，`app.zon` allowlist 不得缺项或多项；Host serializer → TypeScript decoder 与 TypeScript bootstrap payload → Host decoder 必须有跨语言 fixture/行为测试。Renderer 内同一 wire enum 的 TypeScript type 与 runtime decoder 必须消费同一值目录，不能维护彼此独立的 union 与 allowlist；Host 新增产品 cause 时，serializer、Renderer 值目录、文案和跨语言 fixture 必须在同一变更中收齐。Renderer 始终 runtime decode Host payload；malformed payload 或 decoder/serializer contract mismatch 一律进入 fail-closed view-sync failure，不能猜测字段或静默降级。

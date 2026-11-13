# MetaWork Renderer Bridge 合同

> 状态：`metawork.renderer-bridge` 固定 revision 1
> 日期：2026-08-07

顶层模块职责见 [MetaWork 高层架构](architecture.md)，用户可见的信息架构、交互与视觉见 [UI 设计规范](ui-design.md)。本文件是 Renderer 与 Product 之间 command、event、Snapshot、连接与运输语义的唯一架构真源；具体源码目录见 [工程结构与所有权](project-structure.md)，持续验收入口见 [验证规范](validation.md)。

## 1. Bridge 定位

Bridge 是 Renderer 与 Host 之间唯一的产品命令和 Product projection 边界，承运两类 surface。产品命令面：验证调用来源与启动窗口 identity、严格解码 payload、把合法输入转换为产品命令、dispatch 给 Product 中对应 owner、编码 typed result，并通过 Snapshot/Event 运输发布产品投影；Bridge 不决定 Task 是否可以运行、Workspace 是否有效、Agent 是否应取消、credential 是否可以替换或历史如何持久化，这些判断必须由 Product 内对应 owner 完成。受限平台 capability 面只承运已登记的 window-chrome bootstrap 与 external-link handoff capability，dispatch 给 Application 执行，原生行为与真实状态由 Native SDK/OS 拥有。两面共用同一 transport、origin policy 与 source/window authority，不共用数据面；新增平台面 command 必须与 capability seam 同级登记（identity、SDK 缺口、删除条件），不因该面已存在而豁免。

Renderer 的可信定位与 Native SDK WebView UI/input 边界以[高层架构](architecture.md#31-renderer)为准。Bridge 的严格 command catalog、runtime decode、source/window 校验、CAS 与 Product admission 用于维护 owner、处理陈旧 UI 状态、隔离实现错误并拒绝畸形输入。本地路径等输入只有在具体领域合同明确登记时才能通过容量有界的 typed command 转交，Host 仍独立校验文件类型、范围、当前 authority 与生命周期；这不形成 generic file、process 或 OS action command。

Task binding projection 只运输 `epoch + availability + protocol + model + executionGeneration + unavailableReason`。Scheduled Task 的 `binding` 精确为 `{ status: "bound", modelRef, sourceGeneration, protocol }`，没有其他判别分支。两处 protocol 均精确取 `openai_responses | openai_chat_completions | anthropic_messages | gemini_native`，不发布厂商类别。revision 1 对这些 shape 原地 hard cut，旧 Scheduled Task `execution`、旧 `provider` 与 migration shape 既不接受也不归一化。`unavailableReason` 当前只有 `runtime_detached`，表示恢复历史没有进程内 Session/ExecutionConfig；Task projection 不包含 account identity、API Key selection/metadata、Custom Provider identity/generation、credential locator 或完整 ExecutionConfig，也不得用当前 Account/Models projection 为历史 Task 补写这些字段。

Bridge 的唯一产品数据面由具体 `Dispatcher` 内部的 `ProductDelivery` 统一拥有：connection generation、revision retry/timer、读取 identity 和 transport storage。Dispatcher 只调用 Product Control 的无业务副作用查询，运输按消费者范围生成的产品视图；查询、版本通知与运输重试不执行 lifecycle、Run admission 或持久化。Application 只注入 Native emit/timer/dialog/window-chrome/main-thread capability，并组织 Bridge、Product、Agent 与 Native SDK 的顶层 shutdown；Agent event 的产品接纳与固定终态 drain 屏障由 Product Control 执行，Application 安排独立于 Renderer 的 main-loop wake。

`hidden_inset_tall` 的 System WebView window chrome 是独立于 ProductDelivery connection 的受限 Host bootstrap capability。browser-side Bridge 使用既有 `window.zero.invoke` transport 调用 `metawork.host.windowChrome.connect/refresh/control/disconnect`。`connect` 接受空 payload，返回 document generation、safe insets、caption-button bounds、`rendererControls` 与 `maximized`；`refresh` 只接受 `{ generation }` 并返回同一环境格式，不接受 viewport、DOM 区域或手势模式。`control` 只接受同 generation 的 `minimize | toggle_maximize | close`，成功返回严格的 `{ generation, handled: true }`，只表示受理，不保证原生交互完成。`disconnect` 精确撤销当前 generation，返回 `{ generation, detached: true }`。所有响应均须 runtime decode；只有 connect/refresh 可更新 CSS variables/document dataset。React 只登记标题栏真实 DOM 节点以绑定窗口按钮及清理，不消费 DTO、调用 transport、持有原生 identity 或维护窗口状态。

Bridge policy 约束 origin，Dispatcher 校验单一启动窗口 identity、generation、严格 payload 与主线程；generation 只归 Dispatcher。connect 建立文档会话，其他命令必须绑定该会话，不因 resize、layout 或动作失败隐式 reconnect。SDK 正式 resize event、control 处理后及重新获得焦点时调度 refresh；最多一个在途读取，期间的需求合并为后续读取，新动作/原生变化/卸载使之前的读取失效。刷新失败保留最后确认的 controls/session，不重放动作。卸载须移除按钮监听并撤销连接，迟到 connect 只能清理自身 generation，不能重新安装或覆盖新 UI。

标题栏拖拽与双击直接使用 Native SDK WebView UI/input surface，精确声明与排除规则见 [UI 设计规范](ui-design.md#43-一体化窗口栏)。它们不依赖 bootstrap 或 ProductDelivery connection，不进入产品 Bridge，不携带 generation、坐标或窗口 identity。revision 1 原位删除旧 `gesture` command、payload、`gestureMode` 环境字段和 Host callback；旧命令与旧响应 shape 不接受，不保留兼容解析。browser-side Bridge 不监听拖拽按下、不按浏览器计数选择动作、不发起或重放手势。

minimize 使用 Native SDK Runtime API；尚未正式覆盖的 maximize/restore、user-close 和 maximized fact 由独立登记的 window-controls seam 补齐，user-close 必须进入 `close_policy = hide`。该 capability 不接受 HWND、任意 window id、platform、任意 action 或脱离会话的查询，不形成通用窗口 facade、第二窗口 owner 或第二产品数据面。原生机制、真实状态与生命周期仍由 SDK/OS 拥有；官方等价能力经平台验收后在 revision 1 原位替换，并删除失去职责的 seam、命令、allowlist、DTO 和测试。automation 只驱动真实产品路径，不注册测试专用协议。

Windows 窗口按钮执行前读取 SDK 当前窗口事实：connect/refresh 要求主窗口仍打开，允许已隐藏；minimize、toggle 与 user-close 还要求未隐藏。Runtime、窗口或 binding 不可用时返回错误，不投影虚假的 maximized=false。旧 generation、错误 identity 仍在 Bridge 拒绝；失败不重试、不重放。disconnect 不新增 Runtime/可见性要求；托盘 Open/Quit 保留 SDK 流程。close ACK 只表示投递，不能撤销此前受理的 OS 请求。这些 Windows 前提不扩展到 macOS 原有按钮路径。SDK 原生标题栏手势的输入与生命周期由 SDK/OS 负责。

外部链接只通过 `metawork.host.links.openExternal` 打开。payload 精确为 `{ url }`，URL 的 UTF-8 长度上限为 4096 bytes；Host 在已连接的启动窗口与主线程上重新校验，只接受不含空白、控制字符、反斜杠或 userinfo 的绝对 `http`/`https` URL，以及非空且不含 CR/LF 注入的 `mailto` URL。结果精确为 `{ outcome: "opened" | "rejected" | "unavailable" }`：`opened` 只表示系统 handler 已接收请求，`rejected` 表示目标不满足闭合策略，`unavailable` 表示平台能力或系统 handler 失败。结构错误、额外字段、不可信 origin、未连接或错误 window 仍是 Bridge error。该命令不允许 `file`、自定义 scheme、相对地址、任意导航、URL 日志、重试或 fallback；Renderer 必须在点击时同步阻止 WebView 默认导航，严格解码结果，并把非 `opened` 与 transport failure 就地呈现。

版本提醒通过产品命令 `metawork.updates.check`、`metawork.updates.openDownload`、`metawork.updates.openWebsite` 承运。check/website payload 精确为 `{}`；download 精确为 `{ expectedVersion }`，为 canonical 正式版本，不能携带 URL、平台或架构。三者都要求已协商的启动窗口与主线程。check/download 结果为 `{ outcome: "accepted" | "rejected" | "unavailable" }`，accepted 只表示接纳或复用在途操作；website 为 `{ outcome: "opened" | "unavailable" }`，opened 只表示系统 handler 受理。结构、来源、窗口或连接错误仍为 Bridge error。断连撤销 pending download，迟到 HEAD 结果无权打开浏览器。

实时 context 必须包含 URL-free `updates`：`checkState = unchecked | checking | succeeded | failed | unavailable`、`checkError = none | network | timeout | invalid_manifest | unavailable`、nullable `latestVersion`、`updateAvailable`、`downloadAvailable`、`downloadState = idle | checking | opened | failed` 及 `downloadError = none | stale_version | missing_download | invalid_link | network | timeout | browser_unavailable | unavailable`。failed 必须且仅能携带非 none 的对应错误；可下载必先有新版，新版必须有 canonical 版本。失败时允许保留已确认版本。该字段参加既有 context 内容版本与原子复用，不增加第二个数据面。领域接受、调度和交接 authority 以[Product 架构](product-architecture.md#28-版本提醒与下载交接)为准。

`metawork.workspaces.remove` 只接受 `{ workspaceId, expectedWorkspaceEpoch }` 两个非零 wire ID。Host 校验连接、窗口、Manual Workspace identity 与 epoch 后调用既有移除事务；不接受路径，不删除目录或任务历史。结果精确为 `{ accepted, workspaceId, reason }`，成功 reason 为 null；预期拒绝为 `workspace_unavailable | workspace_changed | workspace_removing | task_close_failed | capacity_reached`。结构、来源、窗口和连接错误仍为 Bridge error。accepted 仅表示受理，进度和关闭失败以 Workspace Snapshot 为准，命令超时先对账，不自动重发。

`metawork.workspaces.removeProject` 只接受 `{ workspaceId, expectedWorkspaceEpoch }` 两个非零 canonical decimal u64 string。Host 校验当前连接、窗口、Manual Workspace identity 与 epoch，仅更新项目入口状态，不调用上述 Workspace 授权移除事务。结果精确为 `{ accepted, workspaceId, reason }`；成功 reason 为 null，预期拒绝为 `workspace_unavailable | workspace_changed | workspace_removing | capacity_reached`，结构或连接错误仍为 Bridge error。成功表示 Host 已更新入口状态，持久化遵循 Product history 的健康语义。Snapshot 的 `workspaces[].projectRemoved` 是必需 boolean，Automatic Workspace 必须为 false；该字段仅供项目入口呈现，被移除的 Manual Workspace 仍向 Task 和目录授权消费者投影。Renderer 在命令结束或超时后刷新 Snapshot，不自动重放。

`metawork.workspaces.open` 只接受 `{ workspaceId, expectedWorkspaceEpoch }` 两个非零 canonical decimal u64 string，不接受路径、URL 或系统命令。Host 校验当前连接、窗口与主线程，再由 Product Control 校验可见 Manual Workspace、epoch、当前授权与未脱敏状态；Application 重新验证精确 canonical root 仍为目录后，在 Native 主线程经 SDK 的公开系统交接能力打开目录。结果精确为 `{ opened: boolean }`；true 仅表示系统 handler 接收请求，不证明文件管理器已显示；Workspace 不可用、过期、目录缺失或系统交接失败返回 false，结构或连接错误仍为 Bridge error。不改变 Product 状态，不自动重试或重放，不扩大外部链接或 WebView 导航权限。

## 2. ProductDelivery 与 Snapshot transport

ProductDelivery 只有一套产品数据面，按消费者需要读取摘要、实时上下文、当前 Task、有界历史和已挂载管理视图。范围是闭合的 typed 产品请求，不允许任意字段选择、raw CoreEvent、通用 JSON patch 或第二套 transport。产品摘要不携带所有 Task 的 Run、Tool 和正文；读取当前 Task 不处理其他 Task 的历史。历史按稳定 Run identity 有界读取，范围和页大小不得缩小产品实际可访问容量。

实时上下文必须覆盖当前消费者所需的 Account、capabilities、permissions、Models、updates、new-task admission 以及相关 command CAS 事实。Task Composer、TaskInformation、模型选择、Slash 和附件能力在 Task 页面保持实时；Models、Skills、MCP 与 Schedule 的异步管理结果在对应页面挂载期间继续更新，不能仅在进入页面时读取一次。

一次响应冻结同一 Product 提交 revision，明确所返回范围、产品块 identity、内容版本及安全代次。Renderer 只复用 Host 确认仍有效的块，并原子接纳本次页面所需的摘要、上下文和 Task 内容；没有返回某个范围不等于该范围为空。内容版本表达数据变化，不是第二个协议版本。缺失块、错误关联、重复 identity 和未知范围均严格拒绝，不能从其他 Task 或全局默认补造事实。

`snapshot` 请求精确包含消费者范围 `taskId / beforeRunId / runLimit / management / search / searchQuery / searchCursor / receipts` 和 `known = { securityEpoch, versions }`。`versions` 与响应 `blockVersions` 使用同一闭合块目录：`context / workspaces / taskIndex / taskPage / historyPage / management / searchIndex`；请求未知版本为 `"0"`，响应版本为非零 canonical decimal u64。请求中的版本仅是交付提示，不授予 authority，也不参与消费者范围 identity。Host 对相同范围、相同安全代次及相同内容版本确认复用时，响应将块正文置 null 并在唯一、无重复的 `reusedBlocks` 中列出；其他 null 仍按该块原有空值语义解释。Renderer 必须持有本次读取开始时捕获的完全匹配缓存才可补全，严格解码与跨块关联校验成功后才原子安装，禁止根据版本猜测、接受不完整缓存或回退全量通道。实时上下文不重复携带提交 revision；根 revision 绑定本次冻结响应。

已加载历史的复用另受根 `historyEpoch` 与 Run manifest 的 `contentVersion` 确认。historyEpoch 只在整体历史对象被替换时推进，防止持久 identity 与新运行期版本重用；普通产品 revision 不作废其他 Task 的历史。CoreEvent、终态发布、后续输入转移或取消、coverage 排除及异步文件变更结果都推进所修改 Run 的运行期内容版本。Renderer 只保留同一 Task、安全代次、historyEpoch 且 manifest 仍确认相同内容版本的已加载 Run；新返回的当前页和历史页覆盖同 identity 的旧内容。Renderer 只呈现 Host manifest 确认的连续已加载区间，阅读目标按稳定 Run identity 保存，运输游标随连续区间重新计算；范围切换或内容失效造成缺页时有界重取，不得把两端拼成完整历史或丢失访问中间 Run 的入口。这些失效标识不进入历史持久化格式。Product 编码缓存和 Renderer 交付缓存均按总字节预算有界，淘汰只造成后续重建，不改变可访问数据容量；安全失效清空缓存，旧版本不得重新分配给不同内容。

Product 在 begin 时冻结同一提交的 owned 事实、范围、安全代次及 receipt，不保留 Product 对象借用或执行句柄。需要工具展示解析时，`snapshot` 先返回精确 `{ snapshotId, phase: "preparing" }`；消费者在同一 command 上以精确 `{ preparingSnapshotId }` 继续该读取，每次只推进一个有界 Product 准备步，直到返回既有 `{ snapshotId, bytes, chunkBytes }` descriptor。准备与 ready 的 snapshotId 必须相同，准备期间拒绝 chunk，未知字段、错误 identity 或失效连接严格拒绝；消费者限制连续准备次数并通过既有读取失败路径恢复，不能重放产品命令。准备只使用 begin 冻结的 Host-owned 临时输入和 credential 副本，完成、替换、撤销或关闭时清除；原始工具 JSON 可能包含编码后的敏感文本，只能由 Host 的唯一工具 formatter 解析、清洗，不能成为 Bridge payload、缓存或 worker 输入。ready 计划仅持已脱敏的 owned 内容、精确编码长度和块版本。
大字符串的 JSON 转义随 chunk 请求有界推进，每次最多一个 Product 编码步；准备及编码均不推进业务或查询新的 aggregate 事实。Bridge 只保存读取 identity、准备状态与运输 bytes，不解释计划或执行 JSON 投影。Renderer 只等待准备并按 descriptor 的 chunk 大小递增读取；允许重读已生成前缀，拒绝越过前缀跳读。旧读取被替换、断开、安全失效或关闭时撤销计划，并在忘记有效长度之前清除准备 scratch 与运输已写入区域。编码结果只有在源内容仍有效时才能回填当前块缓存；同一次冻结读取不因普通后续业务更新而混入新内容。

Bridge transport storage 是有界 encoded bytes，不持有 Product 内部状态或 credential。Product writer 只在同步调用期间借用 output buffer；运输使用绑定读取 identity、generation、window、范围和安全代次的分块，base64 后仍须满足 Native SDK 单次 result 上限。新的 begin 或安全失效必须先撤销旧 descriptor；失败不得继续读取被部分覆盖或安全代次过期的 buffer。缓存和运输容量必须覆盖合法产品范围，不能通过永久 SnapshotTooLarge、缩小产品状态或回退旧全量路径处理合格数据。

Product Control 改变安全代次后，旧代次缓存和在途读取立即失效；版本通知精确携带 `{ generation, revision, securityEpoch }`，绑定当前已连接文档，响应也明确交付新安全代次。安全代次改变本身需要通知，即使提交 revision 不变；通知前先撤销并清除旧运输存储。Renderer 收到当前 generation 的新安全代次即清除旧 Host 正文、历史、预览和读取候选，不等待下一次快照成功；旧 generation 的迟到通知不能撤销新连接内容。Renderer 清除旧代次正文、块版本和读取候选，按当前范围重新获取；迟到分块不得拼接或重新安装。Host 与 Renderer 都不得把旧安全代次命中当作缓存成功。

`search = false` 时 query 必须为空且 cursor 为 null，`searchIndex` 为 null；启用时 `searchQuery` 是至多 256 UTF-8 bytes 的有效文本，`searchCursor` 为 null 或闭合 `{ revision, securityEpoch, task, run, part, offset }`，各值均为 canonical decimal u64 string，前两个非零。cursor 是进程内搜索位置，Renderer 只原样续传，不能当作 Task/Run identity。Host 查询 Task 标题、用户输入的安全可读表示和已完成且事件收口的消息；Skill 的 `/` 前缀、参数及附件名称间的空格、完成消息段落间的换行参与匹配，不能按字段切开而漏掉跨字段查询，也不能把分开的段落拼成并不存在的连续文本，不运输全量语料或工具原始输出；按 Unicode 默认大小写折叠匹配，恢复非 ASCII 字母的大小写匹配；不做归一化、去重音或分词。续读位置仍使用原文 UTF-8 字节边界。`searchIndex` 精确为 `{ stale, results, nextCursor }`：最多 50 个结果，每项为 `{ taskId, runId, part, kind, detail }`，kind 为 `task | instruction | completion`，Task 标题的 runId 为 null，其他为非零 Run id；part 是可为零的片段身份，detail 至多 512 UTF-8 bytes 且边界完整。每次查询最多检查 128 个片段并执行 65,536 次折叠后字节比较；未完成时返回下一 cursor，空工作页不表示无命中。Renderer 自动续读空工作页，只保留当前有命中页，提供继续及返回第一页，不累积全量结果。搜索内容版本只随 Task 创建/删除/恢复、标题、已接纳输入及完成消息发布推进；执行阶段、流式增量、已读回执、管理状态等无关 Product revision 不使 cursor 过期。搜索内容版本或安全代次不符时只返回 `stale = true`、空 results、null cursor，Renderer 丢弃旧位置从头重新查询；不同 query/cursor 的缓存不得互用。

生产 64 MiB Snapshot 中各块有独立编码字节上限：context 12 MiB，workspaces 和 taskIndex 各 1 MiB，taskPage 与 historyPage 各 12 MiB，management 25 MiB，searchIndex 256 KiB，另预留 768 KiB 给范围、receipt 与运输 metadata；总和为 64 MiB，所有块及整个响应同时 fail closed。正文每页最多 4 个 Run；导航、Run manifest、Compact 和审批继续受现有接纳数量限制并完整发布，不因未返回正文而移除 manifest 身份，也不以截断替代容量错误。正文和普通详情继续受全局 projection 接纳预算约束；可信成果元数据的保留边界以 [Product 架构](product-architecture.md#43-workbench-historystore) 为准。未来扩大历史数量或正文预算必须先重新满足各视图边界，不能只调大存储配额。

Renderer 在读取开始时冻结本次 revision、消费者范围和目标 identity，读取期间的新通知只产生后续需求；合格读取无需追上未来通知，也不因正常滞后消耗失败预算。每个连接最多一个在途读取，后续需求有界合并；空闲后的通知按固定窗口合并，持续通知不能推迟首次读取。显式刷新只有在调用之后开始的合格读取被当前连接消费后才能完成，不等待整条追赶链；在途失败与退避期间到达的等待者共享同一份有限重试预算。预算耗尽、合同故障、停止、断开及等待期间 generation 被替换均须明确拒绝，不得零读取返回成功或把旧等待者转移到新连接。Task、页面或范围切换后，旧请求不得覆盖当前范围；恢复只重新取得当前所需数据，不先物化全部历史。

连接就绪的内部等待追随当前消费者范围，不因启动或恢复期间的正常切页而断开连接；显式页面刷新等待仍在范围被替换时拒绝。两者都必须由所属 generation 的真实合格读取完成，不能由旧范围完成或仅等待旧 Promise 冒充成功。

连接层独占 readiness：新 generation 必须完成有效握手、真实首读与 ping，不能把等待旧 Promise 误判为同步成功；后续正常 pending 不撤销已确认的 readiness，最终命令 admission 仍属于 Host。新 event generation 建立时使旧 snapshot descriptor 失效；读取与 ACK、ping、定时及清理回调均须校验所属连接，旧异步结果不能影响新连接、复活 stopped 连接或清除合同故障。

显式恢复先在现有 generation 内进行一轮有界同步；普通读取失败升级为一次连接重建与新首读、ping，不依赖错误字符串判断 Host 是否仍保有连接，不嵌套重建循环。断开或明确要求连接替换时直接重建；合同故障不按普通读取故障自动重试。普通刷新不隐式重建。保留 generation 的恢复不取消在途附件或重置审批观测，真正重建沿用 connection-bound authority 的撤销语义。恢复升级之间不发布中间终态故障；全部恢复失败才发布最终故障，合同故障仍及时呈现。

Bridge 异步保留的 payload 必须自有；Application 在 shutdown 时先 stop Bridge ingress，在 Native platform loop 上确认同步 handler quiescence，再关闭 delivery connection、取消 timer，并 detach Product Control；随后依次收口 Account/Models coordinator、Product Control 与 Agent，完成 terminal drain/lifecycle sync，最后才独立释放 delivery buffers。

## 3. Renderer Bridge wire contract

根 snapshot 必须独立发布 `automaticWorkspaceRoot = { generation, mode, canonicalRoot, health, redacted, canChoose, canReset, canRetry }`。`generation` 是非零 canonical decimal wire integer；`mode = system_default | custom | null`，只有 Host 拥有可信配置时非空；`canonicalRoot` 是当前可信 effective canonical path 或 null；`health = ready | path_unavailable | persistence_unavailable | read_failed | corrupt | write_failed | outcome_unknown`。`redacted` 只表示 Host credential redaction 是否改写了可发布路径；不得用占位路径伪造可信 root。三个 action boolean 由 Workspace owner 根据当前 health 一次性计算，Renderer 不从 mode/health 反推。既有 `capabilities.automaticWorkspaces` 仍只表达当前能否分配新 Automatic Workspace，不承担配置诊断。

Host-only command 精确为 `metawork.workspaces.chooseAutomaticRoot`、`metawork.workspaces.resetAutomaticRoot` 和 `metawork.workspaces.retryAutomaticRoot`，payload 都只接受 `{ expectedGeneration }`。Choose 在 Application 内打开原生目录选择器，Renderer 不得提交 path、bookmark、token 或 mode；取消不产生 mutation。Reset 恢复 Native SDK `.data` 解析的 system default，Retry 只重新校验并打开已提交 root，不改写配置。三者都必须在 Product/Workspace transaction 内重新校验 generation、health、path 和 registry 冲突，结果与 Snapshot revision 遵守既有 command/resync 语义；Renderer 不做乐观路径替换。

Run 的 `elapsedMs` 是 nullable canonical decimal `u64` string，表示从本轮接纳起经过的单调时间，包含排队、批准等待和重试。active Run 发布 Host 在本次 Snapshot 的采样值，时钟推进不发布 revision；Renderer 只从本次 Snapshot 的本地接收时刻低频外推，reload 必须重新采样，不能从组件挂载时起算或将显示时间写回 Host。Product 在完整 terminal event-drain barrier 首次形成正式终态时用同一单调时钟冻结最终值，随 Run 历史持久化且写入后不可修改；terminal Run 的 Renderer 不再外推。时钟不可用以及字段引入前的历史记录保持 null，不用 wall-clock 时间、Snapshot 接收时间或 Tool elapsed 迁移、反推或补写。该字段不是事件活跃度、完成比例或剩余时间。

Run 的 `submittedAtUnixMs` 是 nullable canonical decimal `u64` string，表示 Product 接纳该 Run 输入时观察到的 Unix epoch 毫秒。该字段适用于 active 与 terminal Run，并随 Run 历史持久化；时钟不可用以及字段引入前的历史记录保持 null，不做迁移，不允许 Renderer 以完成时间、Snapshot 接收时间、Run 顺序、Run ID 或 `elapsedMs` 反推。非空值必须大于零且不超过 ECMAScript Date 上界 `8640000000000000`，写入后不可修改；Renderer 只进行本地化相对时间呈现，不把它解释为 Agent 开始执行、事件时间线或执行耗时。

Run 的 `finishedAtUnixMs` 是 nullable canonical decimal `u64` string，表示 Product 在完整 terminal event-drain barrier 后首次把该 Run 收口为正式终态时观察到的 Unix epoch 毫秒。非 terminal Run 必须为 null；时钟不可用以及该字段引入前的历史记录继续为 null，不允许 Renderer 以 Snapshot 接收、reload、Run 顺序或 `elapsedMs` 反推。非空值必须大于零且不超过 ECMAScript Date 上界 `8640000000000000`，随 Run 历史持久化且写入后不可修改；Renderer 只进行本地化相对时间呈现，绝不把它解释为事件时间线或执行耗时。

`metawork.tasks.create` 必须提交非空 `modelSelection = { targetModelRef: { sourceId, modelId }, expectedSourceGeneration, expectedCatalogGeneration }`；generation 是非零 canonical decimal u64。删除 expectedExecutionGeneration、默认 expectedSelectionRevision 与 null 选择 shape。Host 校验具体来源、目录 membership、协议与 credential，建立 Task-owned 配置，不消费起始偏好作为执行 authority。

每个 Task 根对象必须发布 Host-owned `modelSelectionAvailability`，精确取 `available | catalog_loading | catalog_unavailable | task_unavailable`。Product Control 根据 Task 生命周期与各来源 Models catalog 的跨 owner 事实一次性计算；`task_unavailable` 表示 Task 历史只读、归档、删除、关闭或 Host 退出所造成的不可编辑状态。detached attachment 与 Custom Provider 来源不撤销 Task 的模型选择能力。Renderer 只消费该枚举决定菜单可编辑、暂时禁用或只读及其原因，不得再比较根 `models`、`newTaskAdmission` 与 Task 字段重建 authority。缺失、已退休或未知值属于 snapshot contract failure。

Host 与 Renderer 随同一应用包原子发布，不承担旧 Renderer/新 Host 或新 Renderer/旧 Host 的兼容。bootstrap 必须拒绝合同 identity 或经用户批准后出现的 revision 错配；固定 revision 策略下，`connect` 无法通过 revision 数字识别同 revision 的陈旧开发产物。严格 command catalog 和 payload decoder 只能在实际命令或结构差异被触及时失败，不能检测纯 wire 语义错配。此类错配属于 unsupported development state，必须通过 clean rebuild、清理缓存或重新安装恢复；原子打包用于降低发生概率，不构成 runtime compatibility guarantee。Renderer Bridge contract 覆盖全部 product command、event 和 snapshot wire surface；它与产品版本、AgentCore ABI、bundle manifest schema 相互独立。

Renderer Bridge 使用独立合同身份 `metawork.renderer-bridge`，快速开发阶段固定 revision 为 `1`。Host 与 Renderer 随同一应用包原子发布，任何 command、event、payload 字段或 wire 语义变化都直接原地 hard cut，不为临时合同形态递增 revision、不维护兼容层，也不在 snapshot 内维护第二个局部版本。`contractRevision` 仍精确匹配，用于拒绝非当前固定标识，但不承诺识别同 revision 的开发产物错配。任何合同类版本标识的变更都必须先得到用户显式同意；对本文件即包括 Renderer Bridge revision。

Run snapshot 已在 revision 1 内原地 hard cut 删除自由文本 `assistant`、`assistantRedacted`、`status`，以及 Run 顶层 `outcome/cause` 与 Task 顶层 `lastRunOutcome/cause`。每个 Run 精确发布 `execution + elapsedMs + submittedAtUnixMs + finishedAtUnixMs + output + activity + terminal`：`execution = { generation, protocol, model }`，generation 是非零 canonical decimal wire integer，protocol 为合同既有封闭枚举，model 是该 Run 实际持有的无 secret model identity；它们是不可由 Task 当前 binding 或 Models 当前默认值补写的逐 Run 历史 provenance。Task 最近结果由最后一个非空 Run terminal 派生，不发布第二份摘要。

`output = { commentary, response, responseKind, provisional, redacted, provisionalRedacted }`，其中 `commentary` 是最多 256 项的有序 string array，每一项对应一个非空、已闭合的 Product commentary group；数组顺序只表达 Run 内的稳定叙事顺序，不运输时间戳、CoreEvent identity、Tool 关联或 raw event timeline。credential 清洗跨整个 canonical output 一次完成，可以使个别投影项为空，但不得改变项数或泄漏跨边界 credential。`responseKind = final | partial | null`；null 时 response 必须为空，分类后的 response 不得同时保留 provisional，terminal Run 的 provisional 必须为空。全部 commentary 项、response 与 provisional 来自同一个 Host output byte budget；provisional 只包含 open/continued buffer 中 credential-safe committed bytes，discard 后必须消失。

`activity` 是 nullable discriminated union：简单 kind 为 `queued | starting | waiting_model | thinking | writing_response | waiting_user | compacting_context | finalizing | stopping`；`executing_tools.inFlight` 为 nullable canonical decimal wire integer string，非空时必须为正数；`retrying_provider.attempt/max/delayMs` 要么全部为空、要么都是 canonical decimal wire integer string，attempt/max 为正数、delayMs 可为零且 attempt 不超过 max。`waiting_model` 表示粗粒度模型处理过程，不能解读为仅等待首 token；`thinking | writing_response` 表达 Host 在有效范围内派生的最近已知模型活动，不承诺持续的内部阶段或精确耗时；Renderer 分别本地化呈现，不自行从正文推断。`executing_tools.inFlight` 表示尚未闭合的调用尝试数，不承诺已 dispatch 或实际并发数；Host 的阶段派生规则以 [AgentCore 集成契约](agentcore-integration.md#current-activity-的依据与优先级)为准。`terminal` 精确为 `null | { outcome, cause, diagnosticDisposition, modelError, recordingIncomplete, feedback }`；非 terminal Run 必须具有 activity 且 terminal 为 null，terminal Run 必须没有 activity且 terminal 非空，phase 与 outcome 必须一致。`cause` 保留 Product 已知的稳定分类。`diagnosticDisposition = absent | withheld`：absent 表示 Agent/Provider 终态没有附加诊断，withheld 表示 Host 接收过非空、被截断或被 credential 清洗的附加诊断，但这些内容按安全边界只留在 Host，不进入 snapshot。该字段不证明诊断的具体类别，也不得被 Renderer 扩写成鉴权、限流、网络或配置结论。AgentCore `api_error`、`tool_error` 与 `image_input_unsupported` 分别映射为 Product `provider_failure`、`tool_failure` 与 `image_input_unsupported`，不得折叠成 `agent_failure` 或把 provider raw diagnostic 发布给 Renderer。queued、waiting_ui、stopping phase 分别只接受 queued、waiting_user、stopping activity。`modelError` 是必填可空对象，包含 `agentRunId`、`category`、`message`、可空 `code/type/requestId/httpStatus/retryAfterMs/source`、`retry`、`attempts`、`truncated`、`hostRedacted` 与 `hostTruncated`。文本只发布 Host credential 清洗后的值，空与 null 保持区别；容量由 Agent 接受值和跨语言 fixture 约束。Agent identity、attempts 和 retry-after 按 canonical decimal wire integer 编码，attempts 限正 u32，HTTP status 为可空 u16 JSON integer。`source = metask | custom_provider | null` 冻结错误发生时的来源类别，不授予当前授权；分类和重试语义以 [AgentCore 集成契约](agentcore-integration.md#结构化模型错误)为准，Renderer 不从文本、code 或 HTTP status 再分类；历史重开恢复事实，恢复动作由当前 owner 重新校验。独立 diagnosticDisposition 不描述 modelError 的可见性。`recordingIncomplete` 是必填 boolean，表示 Host 已知部分过程或回复未完整保留，与执行 outcome 独立；true 不能推断 Core 未完成、Workspace 效果失败或最终回复一定缺失。旧字段、缺失 execution/terminal 或额外兼容 shape 一律由严格 decoder 拒绝，不归一化、不 fallback。

`feedback` 是必填对象 `{ guidance, offerInputPreparation }`，在同一 Run 的正文、历史分页和 manifest 中一致。`guidance` 为 `none | account_settings | model_settings | review_context | revise_instruction | wait | prepare_retry | review_changes | review_permissions | review_image_input`。设置建议要求主结果为 `failed/provider_failure` 并有合法 `modelError`，账号设置还要求 Metask 的鉴权或付款分类。补充错误只作诊断，可与主结果派生的建议共存。`offerInputPreparation` 是 boolean，表示该结果适合提供安全的历史输入准备。当前输入资格由现有 Task 和同步事实决定。旧 `modelError.recovery` 作为额外字段拒绝。

`taskIndex` 的摘要与 `taskPage.task` 均必填 `signal`，值为 `attention | running | failed | interrupted | null`。同一次冻结读取中同一 Task 的值必须一致。`latestTerminal` 保留 outcome/cause 摘要，完成未读和归档独立。Workspace 的 `signals` 聚合未归档 Task 的同一信号，`failedOrInterrupted` 合计失败和中断。

`taskIndex` 摘要必填 `archiveBlocker`（归档或恢复归档）及 `deleteBlocker`，`taskPage.task` 详情必填 `compactBlocker`。值为 `null` 时表示当次投影允许发起动作，其余值为 `busy | closing | deleting | history_read_only | no_history | unavailable`。Host 使用 Task 的动作准入和当前外部事实产生这些字段，执行命令时重新校验。Renderer 从这些字段呈现资格和原因，另保留连接及本地在途提交门禁。活动 Run 可以进入停止并删除，手动 compact 资格取 Task 的对话覆盖与操作状态，与已加载的历史页无关。

Run terminal cause `event_payload_too_large` 表示单次执行事件超过 Host 有界接收上限；`queue_capacity_failure` 表示执行或事件队列无法继续准入。两者不代表磁盘空间不足。文件修改 observation 的 incomplete 只表示未能完整确认修改情况，不推断已保存文件损坏。

每个 Run 另精确发布 `fileChanges = null | { observation, changes }`。null 表示没有建立 typed observation，不能解释为“确认没有修改”；observation 只取 `collecting | complete | incomplete`。`changes[]` entry 精确为 `{ id, order, kind, status, displayPath, fromDisplayPath, beforeBytes, afterBytes, diffAvailable, diffComplete, redacted }`：id 是 Run 内 opaque identity，order、beforeBytes、afterBytes 是 canonical decimal `u64` string；kind 只取 `created | modified | deleted | moved`，status 只取 `applied | partial`，fromDisplayPath 只在 moved 时非空，其余安全标志均为 boolean。同一 Run 的 id 和 order 必须唯一并按 order 严格递增；同路径多次记录不得合并。该投影不运输 raw locator、absolute path、AgentCore handle、agent depth、unified diff、credential 或文件当前内容。根 capability `typedFileChanges` 为 true 时 Renderer 才可消费此字段。

每个 Task 精确发布 `context = { pressure, lastAutoCompact }`。pressure 为 null，或 `{ sourceRunId, currentTokens, warningThreshold, autoCompactThreshold, blockingLimit, severity }`；lastAutoCompact 为 null，或 `{ sourceRunId, dropped, kept, beforeTokens, afterTokens }`。所有计量使用 canonical decimal wire integer，sourceRunId 必须引用同一 Task 的 Run history；threshold 顺序、severity 与 token 数必须一致。context 属于当前 attached Conversation，可跨同一 Session 的 Run 保留，但 Task detach/replacement/restart 后两项均为空，且 detached Task 不得发布 observation。该 surface 不运输 raw CoreEvent tag、transition sequence、private reasoning、provider diagnostic 或 `file_changes`。

Tool 的 `bash` 必填且 nullable，只由 Host 为精确 `Bash` identifier 投影：`{ command: string | null, description: string | null, result: null | { exitCode: i32, stdout: string, stderr: string, stdoutIncomplete: boolean, stderrIncomplete: boolean } }`。description 依附已解析的 command；运行中的 Tool 或截断的原始 content 不得提供 result，截断的 input 不得提供 command。未知、超出解析预算或不完整的 envelope 保留原始安全证据而不猜测可读字段；解码后的文本仍受 credential 清洗。DTO 不改变 Tool state、Run activity、terminal、fileRefs 或持久化格式。

Tool 另必填 `presentation` 与 `errorDetail`。`presentation` 为 null，或仅由 Host 按精确 built-in identifier 投影的 discriminated union：`read { target, offset, limit }`、`write|edit { target }`、`glob { pattern, scope }`、`grep { pattern, scope, include }`、`bash_output { jobId, result }`、`kill_shell { jobId }`、`web_search { query }`、`web_fetch { url, prompt, result }`；nullable 数字以 canonical decimal `u64` string 发布。`bash_output.result` 精确包含闭合 status `running | exited | killed`、stdout/stderr 与各自 incomplete 标志；`web_fetch.result` 精确包含 url、nullable bytes 与正文。截断 input 不得携带 presentation，运行中或截断 content 不得携带 result。解析失败保持 presentation null，由安全原始字段兜底，不在 Renderer 猜测。`errorDetail` 为 nullable string，只允许 failed Tool，由 Host 从已知错误 envelope 提取并再次 credential 清洗；无法解释时保持 null。上述字段不进入持久化格式，也不建立第二套 Tool identity 或 executor。

`output`、`activity`、`tools` 与 `context` 只定义 Renderer 可消费的产品事实和 fail-closed 边界，不规定最终组件、布局、展开策略或更新节奏。当前 Agent 对话的 owner 链、Run exchange 槽位与 active→terminal 呈现收口由 [UI 设计规范](ui-design.md#72-agent-对话渲染机制)定义；wire 字段存在、scripted Provider vertical 或静态 DOM 通过都不能替代真实 Provider cadence 与长任务阅读体验的独立验收。后续纯呈现调整仍可在不改变 revision 1 wire 语义的前提下进行。

每个 Run 另精确发布必需的 `outputs` 数组，最多八项；每项精确为 `{ id, displayPath, sizeBytes, redacted }`。id 是非零、32 位小写十六进制的 opaque 成果身份，在 owning Task/Run 内唯一；sizeBytes 是可为零的 canonical decimal `u64` string。displayPath 只包含用于展示及下述普通指令引用的相对文本，必须是容量不超过 512 UTF-8 bytes 的 Workspace 相对路径，不能包含路径逃逸、绝对路径或控制字符；redacted 为 true 时必须为空。Host 还须在投影时防御性检查已知 credential，不能因旧 redacted flag 不一致而泄露路径。协议不运输 locator authority、摘要或组件路径，Renderer 不从 Tool 文本构建成果。`capabilities.typedOutputs` 表示可信交付记录的呈现能力；记录不证明当前文件可用，文件动作须按自己的 Host 授权与内容校验收口。该字段与严格 decoder、scoped/history Run projection 和 fixture 在 revision 1 原位同步替换，不接纳缺失字段的旧 wire。

## Delivered file actions

`metawork.outputs.action` 是异步请求，精确输入 `{ generation, operationId, taskId, runId, outputId, action }`。前四项为非零 canonical decimal u64 string；outputId 为所属 Task/Run 内非零 32 位小写十六进制成果 ID；action 只允许 `check | reveal | save`。Renderer 不提交路径、摘要、文件字节或任意 OS intent。operationId 在当前 connection 内严格递增，不接受重放；Host 独立绑定当前 window/connection、Task/Run/成果和 Workspace authority。

结果精确为 `{ generation, operationId, state }`，身份与请求一致。state 为 `ready | revealed | saved | save_failed | target_changed | cleanup_failed | busy | missing | restricted | changed | too_large | cancelled | timed_out | stale_security | unavailable | failed`。ready 只表示本次 worker 实际读出的字节与交付身份一致，且结果发布时授权有效，不是未来读取的 grant；revealed 只表示同一条校验链通过后，系统接收了定位 Workspace 源文件的请求，不证明文件管理器已显示。check 不返回 revealed，reveal 不返回 ready；save 不返回 ready/revealed，保存专用终态不出现在其他动作。saved 只证明选定目标已原子发布；save_failed、target_changed 与 cleanup_failed 分别说明保存失败、目标身份已变化及临时文件清理未完成，不能伪装成成功。其他失败状态不能发起系统定位；后续每次操作都重新校验。

Bridge 与 Product 分别有界限制在途请求；文件读取在独立 worker，不能占普通 File Preview worker。Product 发布校验结果或执行 Application 定位 effect 前，Bridge 必须再次证明该请求的 connection/window 仍有效且未取消。Renderer 换 Task、成果身份失效、断连或组件卸载时丢弃旧响应并取消在途请求，不持久化检查状态。`metawork.outputs.cancel` 精确输入 `{ generation, operationId }`，同步结果精确为 `{ generation, operationId, cancelled }`；boolean 只表示该连接下仍存在的请求已接受取消，不证明 worker 已物理退出；保存发布决定一旦提交，取消返回 false，不能再把实际保存结果改写为 cancelled。原异步请求只在 worker 静止后完成并释放 owned effect；关闭应用须 join 后逐一结算 responder。文件工作期限覆盖排队、复制和等待发布决定；系统保存对话框的用户选择时间不计算为文件工作。save 的 Renderer transport 不使用普通短 command timeout 催促用户选位置。超时或 transport 失败不自动重放系统动作。

save 由 Application 消费 Native SDK Runtime 保存对话框选择目标，路径只在 Host 有界持有。复制并校验完成后，Product 再检查当前成果/Workspace/安全代次，Bridge 再检查请求；通过后形成一次性发布决定，worker 才原子替换目标。决定前取消、失效或超时使 worker 丢弃暂存；决定后等待实际发布结果，不再撤销已授权的动作。断连仍阻止旧内容用于新连接，但不能把已经提交的保存改写成未发生。保存不创建历史成果副本。

“继续修改”复用 check：通过 owning Task/Run/成果 ID 校验后，Renderer 在同一 Task 的普通可编辑草稿中引用相对显示文本；该文本不是 Host locator authority，不调用文件读取/编辑 command、不伪造 Attachment token，也不自动发送。用户手动发送后仍沿原 Task 输入、权限和 Skill/Shell 路径执行。准备草稿须复核当前 UI audience、Task、成果呈现及输入准入，保留现有文字和附件；Skill 或未完成的斜杠输入发生冲突时保留原草稿，超限不得截断。换 Task、断连或源呈现失效后的旧检查结果不能修改其他草稿。

## Skill directory discovery

`skillManagement.personalSourceDiscovery` 与 `workspaces[].skillSourceDiscovery` 是 nullable 根检查数组。非 null 时分别含一个/两个标准根：个人 `agents.user.default`，Workspace 额外包含 `agents.workspace.default`；每项 `{ sourceId, state, reason }`，state 为 `checking | missing | checked | error`，reason 仅 error 时为 `unreadable | unsupported_entry | changed`。无可用 base 或非已授权 Manual Workspace 不得伪造检测结果。checked 只表示根检查通过；Skill winner、冲突和查询健康仍消费既有 catalog。共享 `SkillCatalogView` 与 Task pinned catalog shape 不扩展。不提供兼容目录设置、来源写入或恢复 command，management 不发布来源设置。

`skillManagement.assets[].sourceKind` 为 `local_package | local_directory | builtin | external`。`builtin` 仅用于管理投影，须由 Host 核验内置目录的精确 Core 来源、查询范围与贡献身份。内置项无 `installId`，`managementState` 为 `externally_managed`，导出、重新导入、卸载与重试权限为 false。启停继续按现有 catalog 与用户策略授权。

`skillManagement.assets[].origin` 为 null 或 `{ ecosystem: agents | claude | codex, scope: personal | project }`；由 Product 通过精确来源关联提供，不代替 asset 的 policy context 或 sourceKind 导入方式。未知 origin 不允许猜测，外部来源不能因 origin 获得文件管理 authority。

`skillManagement.assets[].scope` 精确为 `{ kind: personal | project | external, workspaceId }`，project 时 `workspaceId` 非空，其余为 null；asset 不携带 Workspace epoch。Renderer 只按 `workspaceId` 把 project asset 归入 `workspaces[]` 中的 Workspace；所有携带 `expectedWorkspaceEpoch` 的 command 必须取同一 snapshot 中该 Workspace 的当前 `epoch`。

## File preview command

`metawork.files.preview` 是 revision 1 command catalog 中的异步 command，原地 hard cut 使用 Native SDK async registry；它不出现在同步 handler registry。request 精确为：

```json
{
  "taskId": "17",
  "runId": "23",
  "fileReferenceId": "task:17:run:23:file:1",
  "generation": "1",
  "previewId": "1"
}
```

五个字段均不可省略或增加替代字段；Task/Run、connection generation 和递增 previewId 必须是 canonical decimal `u64`，reference id 必须是 1–128 bytes 的 opaque identity。Renderer 永不提交文件系统路径、URI、shell command、range、Tool name 或 AgentCore handle。Host 只在精确 Task + Run 内解析 reference，不做全局 reference id 扫描。

response result 精确为：

```json
{
  "state": "ready | busy | stale_security | missing | restricted | unsupported | changing | error",
  "content": "...",
  "truncated": false,
  "redacted": false
}
```

`loading` 只属于 Renderer 临时状态，不进入 wire。仅 `ready` 可以携带正文与 true 的 `truncated/redacted`；其他状态必须返回空 `content` 和两个 false。`unsupported` 可以附带 `reason: "image_limit" | "animated_image"`。`changing` 表示同一次有界读取的 before/after metadata 连续两次不稳定，不是 FileChange observation。Host 结果编码必须容纳 256 KiB 正文在 JSON escaping 后仍落在 Native SDK 1 MiB async response 上限内；容量不足独立返回 `busy`，解析、authority 或 shutdown failure 以一次 terminal result 收口，不悬挂 responder。

Product Control 使用独立 2-worker、最多 8 个 in-flight 的 File Preview lane 执行 no-follow、root-contained、regular-file-only 的有界读取；worker 不持有 Product Control/Bridge/Renderer。图片类型及实际大小识别后才在 lane 锁内预留原图额度，文本不占图片槽，锁内不执行文件 IO。主线程交付前重新校验 Task、Run、reference locator、Workspace id/epoch/root/authorization，并有界分步扫描当前及历史 Task execution credential（含分步边界及全部尾部字节）。文本仅在 callback 期间借用；图片由 Product 保留不可变原图，释放时 secure-zero。正文不进入 Snapshot、Task persistence、日志或磁盘缓存。

同一 `metawork.files.preview` 接纳静态 PNG、JPEG 和静态 WebP；不解码、不缩小、不转码。图片成功响应保留 `state: "ready"`、空 `content` 与两个 false flag，额外且精确提供 `image: { token, mediaType, sizeBytes, chunkBytes, width, height, securityEpoch }`。token 是 24 随机字节的小写十六进制串，三个 byte/epoch 字段使用 canonical decimal u64 string，尺寸使用正整数。mediaType 只允许 `image/png | image/jpeg | image/webp`；chunkBytes 固定 `"262143"`。文本响应不含 image；非 ready 响应不得携带图片。容器结构校验允许有效主图或 RIFF 容器之后的尾部数据，但完整原件仍受大小及凭据检查；APNG/动画 WebP 拒绝。

`metawork.files.preview.readImageChunk` 是同步 command，精确接收 `{ generation, previewId, token, offset, securityEpoch }`，只接受所属 window/connection 的 grant 与连续 offset。ready 精确返回 `{ state: "ready", token, offset, bytes, dataBase64 }`，offset/bytes 是 canonical u64 string，每块最多 262143 原始字节，独立 Base64 编码且受 SDK response 上限约束；非 ready 只返回 `{ state: "stale_security" | "restricted" | "expired" | "error" }`。每次读取重新检查 authority、安全代次和期限。`metawork.files.preview.release` 是异步 command，精确接收 `{ generation, previewId }`，返回同 key 加 `released: true`；准备尚未返回 token 时也能取消，ack 表示原图已释放或未创建。先 release 后迟到的同编号 prepare 不得重新创建资源。

Host 原图生命周期合计最多 2 份 / 20 MiB，每次请求总期限 30 秒、交付 grant 闲置期限 15 秒；连接替换、取消、失效、过期及 shutdown 都收口并释放。Renderer 准备请求最多 2 个、接收链路 1 个、显式解码准入 1 个；`busy` 有界重新排队。窗口保留最多 32 张 / 40 MiB 编码字节 / 33554432 像素；额度不足明确反馈，不静默缩图。以上是逻辑准入额度，不是 WebView 物理内存保证。

Renderer 完整接收后释放 Host grant，以受限 MIME 的 data URL 交给实际 `<img>` 解码；实际 `decode()` 完成前保持 loading。安全代次变化清除已交付资源；传输中的 `stale_security` 只在观察到更新的 canonical epoch 并重新授权后最多重试一次。关闭、跨 Task、引用/连接失效、内联预览离开保留区域都会取消并释放；打开的标签允许保留 bytes，刷新和关闭后重开重新读取，不建立跨 Task、跨连接或磁盘缓存。模型图片输入准备不属于此协议，继续保持原有策略。

Snapshot `tools[].fileRefs[]` 普通 entry 精确包含 `{ id, title, displayPath }`；仅经 Agent 验证的 Host 生图凭据派生的 entry 额外包含 `generatedImage: true` 及必填 nullable `presentationAnchor: { afterOutputCount, presentationOrder } | null`。afterOutputCount 为不超过输出槽位容量的非负整数，presentationOrder 为非零 canonical u64 string；null 只表示旧历史位置未知。缺失表示无此来源，不从内容或路径推断。AgentCore 可能提供的 kind/range 只可作为 Host 内部历史事实，不进入当前 Renderer wire，Renderer 也不得将其解释为 Files Changed。

### Generated MP4 preview

`tools[].fileRefs[]` 中的可信 Host 生视频引用精确增加 `generatedVideo: true` 和非空 `presentationAnchor`，沿用生图锚点语义。两种来源标记互斥。Renderer 通过同一个 `metawork.files.preview` 请求精确 Task、Run 和 reference，Host 按该来源及当前 Workspace 授权读取 16 字节至 64 MiB 的 MP4，检查容器标识并对完整字节执行有界凭据检查。文件变化、缺失、受限或格式不支持分别使用既有预览状态。

成功响应沿用空正文的 `ready` shape，额外且精确携带 `video: { token, mediaType, sizeBytes, chunkBytes, securityEpoch }`，其中 mediaType 固定为 `video/mp4`。token、字段编码与分块长度沿用图片 grant；`metawork.files.preview.readVideoChunk` 复用相同的 request、response、连续 offset 和授权校验，并且只接受视频 grant。取消及释放使用既有 `metawork.files.preview.release`。Host 至多保留一份视频资源，复用预览期限与安全代次失效规则。Renderer 至多保留四份且合计不超过 64 MiB 编码字节，完整收到并释放 grant 后才以本地 blob URL 提供给播放器。离开保留区域、Task 或引用失效、断连及安全代次改变时撤销 URL。文件原件与 URL 不持久化。

## Workspace file browsing commands

`metawork.files.listDirectory` 与 `metawork.files.previewWorkspace` 是异步 command，精确接收 `{ generation, previewId, taskId, workspaceId, workspaceEpoch, path }`。前五项是 canonical decimal u64 string。新任务列目录时 `listDirectory` 接受 `taskId: null`，以当前可见且获授权的 Manual Workspace 的 id/epoch 校验。`previewWorkspace` 始终需要 Task identity。`previewId` 与原 File Preview command 共享连接内单调递增空间；`path` 只接受 UTF-8、最多 4096 bytes、最多 64 段的 `/` 分隔工作区相对路径，不接受空段、`.`、`..`、反斜杠、冒号、控制字符或绝对路径。仅列根目录可使用空 `path`。这些 command 不接受 Run/reference identity、物理根路径或 URI；不改变原引用预览 command 的 request。

Host 校验当前工作区 epoch 与授权。带 Task identity 时还校验其所属工作区。校验通过后向同一 File Preview lane 提交 owned 输入。目录与工作区路径逐段拒绝 symlink/reparse 跳转；目录只列一层普通文件与目录，不返回链接或其他特殊文件。worker 在最多观察 4096 个条目、保留 512 项或累计 64 KiB 文件名时停止，达到边界以 `truncated` 说明，不能声称列出全部文件。

目录精确返回 `{ state: "ready" | "busy" | "missing" | "restricted" | "error", entries: [{ name, kind: "file" | "directory" }], truncated, redacted }`。`name` 是单个合法路径段；Renderer 不从展示文字扩大读取权限。仅 ready 可包含 entries 和 true flags。已知凭据命中的名称整体省略并标记 redacted；结果交付前重新验证相同的 Workspace 授权及适用的 Task 归属，失效时整份结果清空。工作区文件预览返回与原引用预览相同的文本/图片结果，复用其分块、release、连接绑定、安全检查、超时及资源额度；每次刷新独立重新授权。

Renderer 的目录缓存与请求绑定 Task、Workspace id/epoch、连接和安全代次；关闭 Task、工作区失效或换代后旧结果不可显示。隐藏视图可保留同一有效 Task 的目录数据，不自动轮询。每个 Task 会话最多缓存 64 个目录，超限明确提示用户刷新；刷新清空缓存及展开状态。目录与打开文件的请求共享准备并发和取消链路，不新增持久读取授权。

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

根 `capabilities.attachments` 精确为 `{ enabled, imageFormats, maxFiles, maxFileBytes, maxStagedBytes }`。`enabled` 为 boolean，`imageFormats` 在开放时精确为有序 `png | jpeg | webp` 数组，表示当前可发送的图片分类；其他 limit 是 canonical decimal `u64` string。`maxFiles` 解释单消息/单批数量，不投影全局记录容量。Renderer 只用该对象解释入口和本地 admission，Host 对 command 重新执行全部限制；所有已支持图片与其他文件共用 `maxFileBytes`；原件字节计入暂存配额，模型输入的预览/引用预算不投影成第二个文件大小上限。store 或图片能力不可用时 `enabled=false`。

成功的 `metawork.events.connect` 响应增加 `attachmentInput = { mode, maxChunkBytes }`，拒绝响应不带该字段。Application 选择拖放入口 `mode = native_paths | file_bytes`；Windows 拖放使用 `file_bytes`，其他平台拖放使用 `native_paths`。mode 只选择拖放入口，不限制统一添加协议接收本次粘贴 File 的字节。`maxChunkBytes` 是非零 canonical decimal raw-byte 上限，不能超过单次 Bridge frame 预算；它只约束字节入口，不是 Product capability。Renderer 每个平台只消费一个拖放入口，不监听另一入口作重试或超时 fallback。

新的添加操作使用 revision 1 上的四个 async command。整批 key 精确为非零 canonical decimal u64 string 的 `{ generation, batchId }`，绑定当前 window/connection。`beginAdd` 精确接收 key、可选 JSON u32 `remainingFiles` 与 `source`：`{ kind: "picker" }`、`{ kind: "native_paths", paths }` 或 `{ kind: "file_bytes", files: [{ name, sizeBytes }] }`；路径仅能来自当前 Native drop，并须匹配 handshake 的 `native_paths` 模式；`file_bytes` 在两种拖放模式下均可使用，DOM 字节仅能来自按当前平台模式开放的拖放 File 或普通 Composer 本次显式粘贴的图片 File，不得由 Renderer 主动读取剪贴板或任意路径建立。`remainingFiles` 只收紧本次单批数量上限，Host 按 `min(maxFiles, remainingFiles)` 接受；缺省沿用单批上限，0 返回 `too_many_files`，null、错误类型或非 u32 整数字面量属于非法 payload。当前 Renderer 传入冻结草稿的剩余名额；Host 在数量已知后、资源检查及复制前执行校验，picker 打开前不因全局资源耗尽拒绝。picker 与路径在最终整批准备结束后返回 ready/cancelled/rejected；字节来源只有完整预留并初始化 writer 后才返回 accepted。

`appendAdd` 精确接收 key、JSON u32 `fileIndex`、canonical u64 string `offset` 与 `dataBase64`，只允许连续文件、连续 offset 和单块上限；worker 实际写入完成后返回 accepted/cancelled/rejected。`finishAdd` 只接收 key，在 worker 完成原件长度校验和同步及 Native loop 图片准备后，整批原子发布 ready/cancelled/rejected；ready 沿用既有 descriptor。新拒绝原因在既有文件原因上增加 `invalid_transfer | stale_transfer | input_busy | cleanup_failed`，不新增 Snapshot 状态或轮询接口。

`cancelAdd` 只接收 key。取消先撤销 writer admission，等待在途 job 关闭句柄，再撤销未消费 grants 并清理候选；只在确认静止且物理清理完成后返回 `{ status: "cleaned", released: boolean }`，删除失败返回 `{ status: "cleanup_failed" }`。未知/已清理 key 的 released=false 不得掩盖该批次的活 writer 或 cleanup debt；借用和已消费原件受 Product 的 Task 消息与 Run 所有权保护。取消先于 begin 通过有界高水位拒绝迟到请求。每个 async responder 恰好结算一次，pending 输入收到 cancelled，已完成 responder 不重复结算。begin 与 finish 无固定短超时，单块和 cancel 使用既有有界 transport budget；取消结果未知立即替换连接，Renderer 清除旧连接未发送附件并保留文字，Host ledger 不因此重置。不自动重试、重放或建立 Host TTL。

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

`beginAdd` 另接受单个工作区引用来源 `{ kind: "workspace_reference", reference: { taskId, workspaceId, workspaceEpoch, path } }`。身份与路径遵守工作区目录命令的规则，`path` 必须非空。`taskId: null` 只用于已选定 Manual Workspace 的新任务。Host 通过既有异步 staging、取消和 grant 流程处理引用。Renderer 不接收文件正文和物理路径，发送时仍通过 `attachmentTokens` 提交，由 Host 重新校验目标 Task 的工作区归属和 epoch。

`metawork.attachments.release` 是同步 revision 1 command，payload 精确为 `{ token }`，返回 `{ released }`。它只撤销当前 connection 拥有且尚未 borrowed/consumed 的 grant；未知、stale 或已经释放的 token 返回 released=false，不泄露其他 connection 的存在性。disconnect、document generation replacement 与 shutdown 必须等价释放该 connection 全部 grant。

`metawork.tasks.run` 在既有 `text | skill` 上原地 hard cut 增加 `{ kind: "multimodal", text, attachmentTokens }`。`text` 是 string，允许为空；`attachmentTokens` 必须为非空、有界、无重复的 string array。非空 text 成为第一个 Agent part，后续 part 按 token 数组顺序；Skill 字段和 multimodal 字段不能混合。Bridge 只校验 wire 与 grant authority，Product 决定 Task/Session admission和 token 的 borrow/consume transaction。任一 token 指向普通 `kind=file` 附件时，去除首尾空白后的 `text` 必须非空，否则 Run 返回 `reason=missing_instruction` 且保留全部 ready grant；接纳后 Product 将原件保存在 Task 本地存储，非图片文件作为独立有界原件引用 text part 发送，图片为有界 PNG 加原件引用；历史 metadata 仍描述用户原文件。Run 接纳后即使 history save、enqueue、transport 或 Agent terminal 失败也不得恢复或自动重放。

Run snapshot 的 `input` 对 multimodal 精确发布 `{ kind, text, attachments, redacted }`。`text` 为 nullable string；`attachments[]` 是严格 tagged union：图片精确为 `{ kind: "image", format, displayName, sizeBytes, redacted }`，非图片文件精确为 `{ kind: "file", displayName, sizeBytes, redacted }`。顺序与已接纳 input 一致。附件输入的 Snapshot 与 persistence 不含 token、路径、文件原件正文、raw bytes、Base64、digest 或 provider wire；按需读取产生的 Tool 记录遵守既有有界投影与脱敏合同。旧 history record 没有 attachment 字段时只解释为 text/skill 旧 Run，不从正文或文件引用猜测附件。

当前 `metawork.tasks.run` 使用 `input.kind = text | skill | multimodal` 的唯一 tagged payload，旧 `prompt` 不兼容；Skill input 精确为 `{ kind, skillId, catalogRevision, selectionRevision, argumentValues }`，multimodal 精确遵守上节 token 合同。`tasks.create` 必须携带 `workspace = { kind: "automatic" } | { kind: "manual", workspaceId, expectedWorkspaceEpoch }`、必填非空 `modelSelection`、nullable `expectedSkillCatalogRevision`、nullable `expectedSkillSelectionRevision` 和 `approvalMode = manual | auto_review | full_access`；Text 与 multimodal 的两个 Skill revision 均为 `null`，Skill 两者均非空，混合状态 fail closed。Manual 创建用 Workspace catalog 校验版本对，Automatic 创建用 personal catalog 校验。Automatic Task 接纳首条消息前可用相同的 personal 版本对通过 `tasks.sendInput` 提交已选 Skill，执行仍须通过该 Task 的 Workspace 准备。成功 create result 与每个 Task snapshot 都必须包含 `mcpAuthority = { kind: "ready", selection: "selected" | "none" } | { kind: "unavailable", selection: null }`；失败 create result 的该字段为 null。它只描述创建时复制的 immutable MCP authority，不包含 server/tool/credential，不授权 Renderer 热附加或推断当前 MCP 状态。Bridge 与 Product Control 直接使用同一组 `manual | automatic` admission 语义；混合、缺字段或未知 kind/mode 的 payload 一律 fail closed。不存在 `workspaces.select` 命令或 Snapshot 级 selected Workspace；Manual 选择和模型 override 只属于 Renderer New task draft，真正的 Workspace epoch/authorization/recent order 与模型 authority 在 `tasks.create` 事务中校验和提交。`automaticWorkspaces` 只声明新 Automatic Workspace 的分配能力；capability 不可用时，已恢复的 Automatic Workspace 与 owning Task 历史仍可出现在 snapshot 中。Skill 没有 `runSkill` 第二入口。Workspace/Task catalog、typed Run history 和 Skill terminal cause 只从 Product Control snapshot 发布；显式 catalog refresh 也只通过 Bridge 调用 Product Control transaction，Bridge 不持有 catalog lease、不解析 slash、不读取 Skill body。

交互 Task 的自动 Skill 准备与 Automatic Task 初始准备复用 `tasks[].skillCatalog.availability = loading | ready | degraded | unavailable`，不新增平行 Task 状态对象。`tasks.run` 在 loading 时返回未接纳的 `catalog_loading`，不消费附件 token 或建立 Run。普通 Composer 通过 `tasks.sendInput` 一次交付输入，Host 在其接收后推进自动准备；公开 `tasks.run` 保持同步 Run 接纳语义，未准备好时返回既有未接纳原因，不消费附件或伪造 Run。Renderer 不编排等待后重放命令。初始准备 unavailable 不阻止普通 Text/文件引用 Run；它不等同于启用某个 Skill，也不改变 Conversation restore eligibility。

Skill catalog 的每个候选必填 `skillPolicyKey`，来自 Core 的逻辑策略身份；它不是执行授权，也不允许 Renderer 按同名来源猜测替代项。Host 接收显式 Skill 输入时校验 concrete identity 与双 revision 后捕获逻辑选择，后续准备重新核验当前 winner、启用状态和参数。发送 payload 与历史格式保持不变。

`metawork.tasks.sendInput` 是普通 Composer 新输入的发送入口，payload 精确为 `{ operationId, taskId, input }`，input 复用 text、skill 与 multimodal tagged union。Renderer 不提供 binding epoch、idle/Run 目标，也不编排 Skill 准备或恢复。Host 校验当前窗口、连接 generation、Task/Workspace authority、内容、附件 grant 和真实容量；Task 在主线程取得唯一 owned payload 与安全展示预留后接收，执行启动、readiness、停止或收尾阶段不能成为普通有效消息的接收拒绝理由。已有公共 `tasks.run` 保留显式新 Run 语义，不能越过更早待处理输入。

`metawork.tasks.retryInput` 精确接收 `{ taskId, originalOperationId, operationId }`。Host 只以该 Task 的未执行失败提交及其进程内保留输入为源，返回普通发送接收结果。原提交已转交时返回已接收的新 `operationId`；响应未知时按操作 ID 查回既有快照回执。`metawork.tasks.discardInputRetry` 精确接收 `{ taskId, originalOperationId }`，返回 `{ discarded }`。这两个命令只接收身份，不接收原文、附件路径或 grant。失败提交可选 `retryAvailable: true` 仅表示 Host 持有可重发输入，重启或淘汰后省略。

Task 的可选 `modelInputBlocker` 由 Host 给出当前 Metask 模型准入阻塞原因，等待中的目录刷新不代表提交已失败。现有 `metawork.models.refreshCatalog` 可由旧任务的目录失败提示调用，完成后等待 canonical view。

Task 可选 `sessionCloseRetryAvailable: true` 表示当前关闭失败允许显式重试。`metawork.tasks.retrySessionClose` 精确接收 `{ taskId, expectedBindingEpoch }`，返回 `{ accepted }`。Host 复核同一 Task、binding 与关闭资格；接收只表示关闭重试已请求，结果由后续 Task 投影确认。

operationId 为 1–64 字节可打印 ASCII identity，只关联单次提交，不是重试 key，不得含凭据。result 精确为 `{ taskId, operationId, outcome, reason }`：`accepted` 表示 Task 已取得消息所有权，reason=null；`rejected` 的 reason 非空，不承诺实际 Run identity。接收后投递失败不反向改判未接收。内部 SDK receipt 的 accepted/adopted/unknown 继续保存在执行记录。接收前失败不能部分消费附件；接收后的断连不取消 Task 意图。

Task Snapshot 必填 `inputReady`、`inputAcceptance:{ available, reason }` 和 `inputSubmissions`。inputReady 只展示当前 Run readiness；inputAcceptance 只表达真实接收资格，available 当且仅当 reason=null。等待记录通常精确为 `{ submission, input, state, reason }`；发送触发内部恢复时，名额失败也使用 `session_releasing | session_capacity | session_close_failed`，仅 `state=failed` 且 `reason=session_close_failed` 的记录额外且必须携带非零 canonical u64 `blockingTaskId`，其余记录禁止该字段。该 identity 与 reason 一样仅存在于运行时，Renderer 指明阻塞 Task 并保留显式重试语义。state=`waiting | failed | cancelled | interrupted`；waiting 和 interrupted 的 reason=null。具体失败原因只在进程内发布，不写历史；重启后安全等待记录显示 interrupted，不恢复原文或执行。数量由 Product Limits 配置且最多 64，使用有界共享原文/文件及安全投影预算，不建立 durable outbox。

`submission` 精确为 `{ operationId, receivedAtUnixMs, anchorRunId, afterOutputCount, presentationOrder }`。时间和 anchor 为 nullable canonical u64 string，anchor 非零；afterOutputCount 为不超过输出槽位上限的非负整数。presentationOrder 为必填 nullable 非零 canonical u64 string，null 只表示旧历史；新消息接收时取 Task 范围展示序号，与可信图片接纳共用顺序，采纳及转入不改写。它记录原接收时间和展示位置；尚无 Run 的后继等待消息在首个根输入正式准入时，将空 anchor 解析为该 Run 的首个输出前位置，保持点击顺序。每个 Run 根输入和 additional input 都有必填 nullable submission，旧历史允许 null。消息转入执行记录时保持同一 submission，并从等待投影移除；同一 operation 不能同时发布为等待记录和执行输入，不重复生成气泡。Task 级单槽 sendInputResult 不再发布。

每个 Run 的 `additionalInputs` 最多 64 项，精确为 `{ id, afterOutputCount, operationId, submission, text, redacted, sequence, adoptedTurn, order, state, transferredToRunId, continuationReason }`。id 为 Run 内递增 u64；afterOutputCount 表示投递时前方 canonical 输出槽位数，不从采纳事件补造。sequence 为 nullable 1–64 integer；state=`pending | adopted | unadopted | unknown | continuing | transferred`，adopted/unadopted/continuing/transferred 必有 sequence。adoptedTurn 与 order 同空或同非空，非空仅允许 adopted，分别为非零 u32 和 u64。transferredToRunId 非空当且仅当 transferred，须指向同 Task 更后的真实 Run；continuing/transferred 只属于正常 completed 来源。continuationReason 仅 unadopted 可非空，且只在内存展示。安全历史不能成为执行来源。

同一来源窗口和 connection generation 内，Bridge 按 Renderer 发起顺序进入 Host 主线程接收事务。Renderer 可在 A 响应前发起 B、C；响应完成顺序不影响 A、B、C 的接收顺序。该保证不扩大到跨窗口或跨连接；真实注册 Dispatcher 接收路径与桌面 transport 共同验证。Renderer 按 operationId 对账所有等待/Run 输入，receipt observed 只证明接收，不证明当前范围有可展示记录；只有安全 canonical 正文与展示位置接管后才能释放唯一消息展示项，范围不足由有界读取补齐。查不到记录不证明未接收；回执未知只刷新，不自动重发、转投或跨重连补发。每次点击立即将本次提交与当前草稿分离，旧响应不能清除较新草稿。首次创建期间有界保留明确点击的提交，共享一个 create 请求，取得身份后按点击顺序交付，不等上一发送回执。创建失败或未知不自动重建，旧 generation 不产生新效果。

`tasks.run` 精确返回 `{ accepted, taskId, runId, reason }`，保留显式新 Run 准入语义；待处理消息或 continuing 预留阻止其抢先。正常未采纳后缀仍由 Task 复用原有一次接续，compact/restore 与实际 Run 继续遵守 Session/worker/checkpoint 门禁。

`metawork.tasks.stop` payload 精确为 `{ taskId }`，返回 `{ taskId, stopRequested:true }`。Task 在同一次主线程处理里取消当时已有等待项/接续，并停止当时实际 operation（含准备），之后接收的消息不受迟到停止终态追溯取消。ack 只表示请求已处理，最终执行状态取 Snapshot。创建期间 Stop 取消之前尚未交付的本地提交；真实 Task 已创建则保留该对象，后来的发送属于新意图。

`metawork.tasks.cancel` 保留 `{ taskId, runId }` 和 `{ taskId, runId, cancelRequested:true }` 的指定 Run 合同：来源 terminal 但仍有接续时可取消该预留，目标已接纳后旧 Run cancel 不影响后续 Run。Composer Stop 使用 Task stop，不拼接多条底层命令。具体 execution failure reason 枚举复用 Task typed `SendInputReason`，接收原因不包含内部阶段的暂态忙碌；malformed/source/connection 错误仍是 command failure。

`metawork.tasks.compact` payload 精确为 `{ taskId, expectedBindingEpoch }`，结果精确为 `{ accepted, taskId, operationId, reason }`。`accepted=true` 表示 Product 已建立该 Compact operation identity，不承诺 executor enqueue 或 Agent compact 成功；即使紧随其后的 queue submit 失败，command 仍返回该 accepted `operationId`，随后 canonical Task snapshot 以同一 operation 发布 `phase=failed, cause=resource_limit` 并清除 active operation。Renderer 必须等待 snapshot terminal，不得把 accepted acknowledgement 改判为 command rejection、恢复旧状态或自动重放。

权限策略沿用同一 revision 1 合同原地 hard cut。根 `capabilities.permissionProfiles` 与根 `permissions = { availableProfiles, availableModes, defaultMode }` 定义新 Task 的可用选择与默认值；`metawork.tasks.create` 必须提交 `approvalMode = manual | auto_review | full_access`，成功创建后 Host 才记住新 Task 默认选择。每个 Task 发布当前 `permissionProfile + approvalMode + permissionReviewState`；每个 Run 的 `permissionProfile + permissionInteraction` 是该 Run 创建时的历史事实，不随 Task 模式切换改写。仍活跃的 Run 必须与 Task 当前执行 profile 一致；历史 reviewer audit 只按 owning Run 的 interactive approval profile 校验。Scheduled Task 的 noninteractive 映射保持产品需求定义的边界。

已有 Task 审批切换使用 `metawork.tasks.setApprovalMode`，payload 精确为 `{ taskId, targetMode, expectedBindingEpoch, expectedApprovalRevision }`；三个 identity/revision 是非零 canonical decimal u64，`targetMode = manual | auto_review | full_access`。Host 在同一 Task authority 上执行 epoch 与 approval revision CAS，保留 Workspace、Session 与 Conversation 身份；跨执行 profile 的 Run 取消、quiescence、checkpoint、持久化及失败恢复由 Product Control 推进。Bridge 不组合 cancel/restore/run，也不接受 AgentCore mode、grant 或自由 Session identity。

结果精确为 `{ accepted, taskId, approvalRevision, reason }`。accepted 时 revision 是本次 intent 的 revision；相同模式 no-op 返回当前 revision。它只证明受理，不证明模式已提交；rejected 时 revision 为 null，reason 取 `task_not_found | stale_binding | stale_revision | busy | task_closed | unsupported_interaction | unavailable | revision_exhausted | review_exhausted | shutting_down`。A→B→A 仍推进 revision，旧意图不得因为模式名称相同重新获得 authority。未完成事务拒绝重复意图。

Task Snapshot 必须发布 `approvalRevision`、`availableApprovalModes`、nullable `approvalChange` 与 nullable `approvalResult`。revision 是当前 durable 模式 revision；available modes 是 Host 对各目标的同一准入判断结果，Renderer 不自行推导，事务进行时为空。`approvalChange = { revision, targetMode, state: pending | recovering | outcome_unknown }` 的 revision 指向当前或下一 revision；进行时不发布旧 result。`approvalResult = { revision, outcome: completed | failed, reason }` 只发布最近事务结果：completed 的 revision 等于当前 durable revision 且 reason 为 null；failed 的 reason 取 `cancelled | busy | budget_required | mode_update_failed | checkpoint_failed | persistence_failed | outcome_unknown | recovery_failed | dependency_contract`。change/result 是运行中反馈，不是第二份历史或持久化模式真源。断连重启后以 durable mode/revision 重新确认状态。

Renderer 在发送及等待 Snapshot 时锁定同 Task 的重复选择；模式文字只读取 canonical Snapshot。超时或丢失 response 只请求刷新，不自动重发意图、重放输入或继续 Run；显式刷新后仍没有终态证据时说明“未确认”，由用户检查当前 mode/revision 再重新选择。旧 Snapshot、旧失败结果、旧连接 generation 和迟到 acknowledgement 不得覆盖已经确认的模式或解锁另一个请求。

Scheduled Task create/update mutation 的模型字段精确为 `modelSelection: { targetModelRef: { sourceId, modelId }, expectedSourceGeneration, expectedCatalogGeneration }`。Host 精确解析并保存 `ModelRef + source_generation + protocol`；Renderer 不提供 protocol，不携带 selectionRevision 或 execution generation。更新的 modelSelection 必填但可为 null，精确表示保留该 item epoch 下的原绑定；创建只接受非空目标。编辑已有定义须由 item epoch 防并发；普通非模型编辑保留既有固定绑定；明确改选或确认恢复 `execution_changed` 时采用当前 ready 目标的新证明。每次 occurrence 按该计划自身来源、模型、source generation、当前目录 membership、授权与 protocol 校验；起始偏好不参与校验或 timer。occurrence taskOutcome 接受 `completed | stopped | cancelled | interrupted | failed | dependency_contract_failure | unavailable | null`。

Scheduled Task recurrence 接受绝对定义 `once: { kind, atUnixSeconds }`、`interval: { kind, startAtUnixSeconds, everySeconds }` 或 `calendar: { kind, startAtUnixSeconds, timezone, frequency, days? }`。绝对时间为正 canonical decimal Unix seconds，calendar 上限为 Gregorian 9999 年末。timezone 为 Host 支持的显式 IANA identity，calendar frequency 为 `hourly | daily | weekly | monthly | yearly`。weekly/monthly 的 `days` 是非空、严格递增且不重复的 JSON 整数数组，分别使用 ISO 周一至周日的 `1..7` 和月内日期 `1..31`。其他频率不得携带 days。缺少 days 的旧周/月规则仍表示起点在所存时区对应的单个星期/日期，Host 在投影与后续持久化写入中明确发布该选择。非时间编辑保留原日历频率、时区及绝对起点。旧 interval 定义继续按原秒数解释。

新建或明确修改日历规则时，Renderer 在 calendar recurrence 中提交 24 小时制 `localTime: "HH:mm"`，替代 `startAtUnixSeconds`，两者不得同时提交。weekly/monthly 必须提供 days。Host 使用自身时钟和与周期执行相同的固定版本 IANA 规则确定首个匹配时间。已有 hourly/yearly 规则修改时分时保留原起点所在的当地日期。Host 仍持久化绝对定义，calendar 投影额外提供 Host 计算的 `localTime`，供 Renderer 显示与回填。

系统通知通过 SDK 普通 notification command 请求定位真实 Task。Bridge 的 `metawork:open-task` event 精确为 `{ generation, taskId }`，均为非零 canonical decimal u64，只是当前连接的导航意图，不授予 Task/Run mutation authority。Renderer 先刷新 canonical snapshot，再从真实 Task index 定位；旧 connection generation、未知 Task 或 malformed event 不得定位其他 Task或启动 Run。未连接时 Host 只保留最新一个进程内定位意图，连接后交付；它不进入产品历史或 Schedule store，不承诺跨进程通知重放。

Scheduled Task setEnabled response 的 `enabled` 表示本次提交并完成 timer reconciliation 后的实际状态；恢复时发现 binding 已变化或 timer 不可用，可以返回 false。Renderer 必须刷新 canonical snapshot 解释当前状态，不能把请求值当作恢复成功的证据。

Scheduled Task 的 skipped occurrence 可携带 `taskId`，仅当 reason 为 `previous_task_running` 时表示阻塞它的真实 Task，不代表新建 Task；此前没有记录 blocker 的 null 值仍有效。

`metawork.tasks.delete` 只接受 `{ taskId }`，已归档和未归档 Task 均可提交。成功返回 `{ taskId, deleting: true }`，表示 Product Control 已受理唯一删除意图；它不声称 Task 已经物理删除。Task snapshot 以 `deletionStatus = idle | deleting | failed` 发布该 runtime-only 产品用例：`deleting` 时 Renderer 等待后续 snapshot 移除 Task，`failed` 时保留 Task 及原归档状态，显式重试资格由 `deleteBlocker` 发布。Product Control 自行收口 Attachment、等待 worker/checkpoint quiescence、提交 Task store；Renderer 不重复提交正常推进、不编排 Session teardown，也不解析 checkpoint、close failure 或 worker reference。

每个 Task snapshot 必须发布 `unreadCompletionRunId: canonical decimal u64 | null`。非空时必须精确引用该 Task `runs` 中最新的 terminal Run，且其 `terminal.outcome = completed`；不存在成功完成、最新 terminal 是其他 outcome，或该 Run 已由 Product receipt 确认时必须为 null。Renderer 不从 Run 数组另建未读真源。

`metawork.tasks.markCompletionSeen` 只接受 `{ taskId, runId }`，两者都是非零 canonical decimal u64；返回 `{ taskId, runId, marked }`。只有该 Task 仍存在、未进入删除流程，且 `runId` 仍是最新 terminal `completed` Run 时才能推进 receipt 并返回 `marked=true`；重复、迟到、归档已确认或目标消失统一返回 `marked=false`，不得清除后来 Run 的提醒。成功 mutation 发布新的 snapshot revision，但不改变 Task `recentOrder`，也不单独强制 history commit；receipt 随 Product 的下一既有 durable boundary 或 clean shutdown 合并持久化。Renderer 只能在中央 Task 工作面真实暴露且 document 可见、窗口有焦点时调用；Settings、搜索、窄窗左栏、非停靠 Task Panel、断连和同步失败期间不能确认。该命令没有用户可见错误或自动重放；结果不确定时继续以 canonical snapshot 为准。

`metawork.skills.setEnabled` 是 revision 1 内的原地 hard cut command。payload 精确为 `{ scope, workspaceId, expectedWorkspaceEpoch, skillPolicyKey, state, expectedCatalogRevision, expectedSelectionRevision }`：`scope = personal` 时两个 Workspace 字段必须为 null 且 `state = enabled | disabled`；`scope = project` 时两个 Workspace 字段必须是已授权 Manual Workspace 的 canonical identity，且 `state = inherit | enabled | disabled`。`skillPolicyKey` 必须属于对应 current catalog，不能用易随内容变化的 concrete `skillId` 代替。成功返回 `{ applied: true, selectionRevision, reason: null }`，业务拒绝返回 `{ applied: false, selectionRevision: null, reason }`；非法 shape、越权或非 canonical identity 仍 fail closed。Snapshot 中每个 `skillCatalog` 含 nullable `selectionRevision`，每个 descriptor 含 effective `enabled`；ready/degraded catalog 的两份 revision 均非空，其他状态均为 null。`skillManagement` 含 `enablementAvailability`，asset 含 nullable `skillPolicyKey`、nullable effective `enabled`、nullable `enablementState`、`canSetEnabled` 与 nullable `selectionRevision`；Personal 的 state 只取 enabled/disabled，Project 的 state 可以 inherit。管理 authority 与 enablement authority 分离，能够精确映射当前 catalog member 的 external asset 也可启停，但仍不可因此获得导出、重新导入或卸载 authority。

每个 Task snapshot 必须发布 `modelIntent: null | { modelRef: { sourceId, modelId }, selectionRevision, state }`。非空时 revision 为非零 canonical decimal u64；`state = committed | outcome_unknown`。前者是已保存的 Task 意图，后者是等待 canonical 读回的精确候选，不表示选择成功，也不能接纳新 Run。该字段不包含 credential、endpoint 或连接句柄，可以与实际 `binding.model`、历史 Run 和 global default 不同，也允许目标暂时离开目录。旧记录缺少可证明的完整来源时发布 null；Renderer 不猜测来源或拒绝这类合法历史。

已有 Task 的模型选择使用 `metawork.tasks.selectModel`，payload 精确为 `{ taskId, expectedSelectionRevision, targetModelRef: { sourceId, modelId }, expectedSourceGeneration, expectedCatalogGeneration }`，结果为 `{ accepted, taskId, selectionRevision, reason }`。Task 意图为空时 expected revision 为 `"0"`，否则必须匹配当前意图；来源和目录 generation 必须非零并匹配目标 ready 来源。目标可以来自任一可用 Metask 或 Custom Provider，不依赖 global default、当前 binding、默认配置 replacement 或 attachment 是否已恢复。成功返回新的非零 selection revision 和 null reason；拒绝时 revision 为 null，reason 精确接受 `model_changed | stale_catalog | task_unavailable | task_busy | shutting_down | capacity_reached | persistence_unavailable | persistence_failed | persistence_outcome_unknown`。命令只提交无 secret 意图，不触碰当前 Run/Session，不推进 binding epoch。配置了历史存储时必须 confirmed commit；明确失败回滚原意图，结果不确定保留原 canonical witness 并通过既有历史恢复读回决定提交或回滚。Renderer 不自动重放超时或不确定的 mutation，不用本地 pending map 代替 Host 投影。尚未安装的新意图在执行前由 Host 重新解析完整配置并确保安装匹配，失败不得静默使用旧模型或 global default。

Conversation recovery 使用同一 revision 1 数据面上的 `metawork.tasks.restore`。payload 精确为 `{ taskId, expectedBindingEpoch }`，通常结果精确为 `{ accepted, taskId, attemptId, reason }`；`attemptId` 仅在 accepted 时为 canonical decimal `u64`，reason 仅在 rejected 时取 `binding_changed | task_unavailable | recovery_unavailable | capacity_reached | session_releasing | session_capacity | session_close_failed | shutting_down`。Bridge 只负责严格 decode、Task authority 与结果 encode，不读取 checkpoint、不决定 eligibility、不调用 Agent。该 command 可由用户 Retry 或发送路径内部调用；Host 可以据 canonical Product facts 选择 checkpoint restore job，或在没有 checkpoint/covered/pending history 时同步 fresh attach 空 Conversation。两者都返回 accepted attempt identity，Renderer 必须等待同一 Task 的 canonical snapshot 确认 attachment 后才能提交 `tasks.run`，不得重放历史输入。AgentCore complete 与 degraded restore 都通过同一既有 attachment/continuation shape 表示成功；degraded 的 Permission accounting 继续只由 `restorePermission` 表示，不新增 command result、Snapshot 字段或 revision。结果不确定或 Renderer timeout 时只能 resync snapshot，不能自动重放。

`tasks.create` 与 `tasks.restore` 的 Session 名额拒绝使用独立原因：`session_releasing` 表示已开始或正在关闭空闲 Session，用户稍后显式重试；`session_capacity` 表示没有可立即释放的名额；`session_close_failed` 表示仍占名额的 Task 关闭失败。仅最后一种拒绝额外且必须包含非零 canonical u64 `blockingTaskId`，其余结果禁止该字段；Renderer 使用该 Task 的安全标题或 identity 指明需要处理的对象，不误报模型配置失效或持久历史损坏。创建前的 Schedule 脱敏失败分别返回 `schedule_persistence_unavailable | schedule_persistence_failed | schedule_persistence_outcome_unknown`，均为尚未创建 Task 的明确拒绝。明确的 create 拒绝不消耗草稿，下次用户提交可重新创建；timeout/未知结果仍只允许 resync，不自动重放创建、输入或恢复。

Pending permission projection 使用 `{ requestId, runId, order, redacted, kind: "permission", toolNamespace, tool, toolBinding, args, presentation, availableChoices, policyGeneration, canonicalArgumentsDigest, candidate }`，其中 `candidate` 精确为 `null | { ruleId, scope: "exact_arguments" } | { ruleId, scope: "file_target", target }`。`availableChoices` 由 AgentCore 当前 request 的 `responses[]` 计算；Session choice 只有在 candidate 存在时才可发布。`file_target` 只接受 built-in Write/Edit，target 必须非空且来自 Core canonical target；目标命中敏感过滤时 Host 发布 null candidate 并移除 Session choices。`exact_arguments` 不携带 target，未知 scope、混合字段和非法工具组合必须拒绝。target 只供呈现，不进入 response command 或充当 Renderer authority。Renderer 只能提交 `deny_once | deny_session | allow_once | allow_session` 中实际出现在 `availableChoices` 的 choice；不得提交 `policyGeneration`、digest、candidate `ruleId` 或原始 AgentCore response。Agent 从 pending request 回填 ABI 字段并完成最终校验。Digest 与 candidate 只用于同 Task 的诊断比较，不是 Renderer grant authority。

Pending `presentation` 精确为 `null | { kind: "command", command, description } | { kind: "read" | "write" | "edit" | "web_fetch", target }`。仅 builtin Bash/Read/Write/Edit/WebFetch 可按对应参数类型发布，未知工具、同名 host/MCP、参数无法解码或摘要超出独立呈现预算时为 null，并显示脱敏后的原始参数；不得因重复呈现扩大 snapshot 容量。不得从 Shell 文本分类 effect。`description` 为 nullable Agent 原用途说明，其他字符串为 Host 脱敏的请求字段，不是执行结果或安全证明。解码后的字段命中敏感过滤时原始 `args` 隐藏，即使摘要因预算被省略也必须如此，防止 JSON escape 重建已隐藏的秘密；typed presentation 不生成 scope 或 choice。Decoder 拒绝与 tool namespace/name 不一致、未知或混合的 presentation。

Permission occurrence 在 `uiHistory` 中额外携带 `agentRequestId` 与 nullable `permission` 摘要。摘要字段固定为 `requestId`、`matchedRuleId`、`toolNamespace`、`toolName`、`toolBinding`、`canonicalArgumentsDigest`、`decision`、`source`、`policyGeneration`、`usedSessionRule`、`callbackOutcome`；它只包含非 secret identifier 和脱敏决策结果，不包含原始参数、credential 或可重放 response。Restore 后 Task snapshot 的 `restorePermission` 仅是本次 restore 的 `{ restoredRules, invalidatedRules }` 运行健康投影，不能被 Renderer 当作本地 grant cache。

根 `permissions` 精确增加 `availableModes` 与 `defaultMode`，保留 `availableProfiles` 与 `defaultProfile` 表达对应 Core profile；模式集合及映射由[产品需求](requirements.md#55-审批与输入)定义。Decoder 拒绝数字、数组、未知或重复模式以及 default mode/profile 不一致。Task snapshot 增加 `approvalMode` 与 `permissionReviewState=idle|reviewing|needs_user`；模式只读并由 Task 自己的事实派生，不用全局 default 补写。人工与完全访问只能处于 `idle`，自动评审的已回答请求也恢复 `idle`。不存在会话中 mode mutation command 或独立委托 command。

Task detail 的 `permissionReviewExplanation` 精确为 `null | { cause, reason }`，只在当前请求的 `permissionReviewState=needs_user` 时发布对象；导航 summary 不携带理由。`cause` 只接受 `unavailable | reviewer_concern | rejection_limit | context_incomplete | timeout | call_failed | invalid_response | capacity | input_changed | state_changed`。分类来自 Host 的实际退出路径，不从模型理由推断。`reason` 仅在 `reviewer_concern | rejection_limit` 时可以是非空、无控制字符、最多 512 UTF-8 字节的 Host 脱敏文本，其他 cause 必须为 null。对象绑定 Task 当前 pending request，不跨请求复用，也不进入持久化或 `uiHistory`。Renderer 将理由标明为审核模型说明，不将它用作 authority 或系统效果证明。

每条 `uiHistory` 记录精确增加 `answeredBy=user|reviewer|null` 与 nullable `reviewReason`。同时必含 nullable `review={outcome,cause,reason}`：outcome 为 `allow_once | deny | needs_user | failed | not_started`，cause 为 nullable 当前审核原因 enum，reason 为 nullable、最多 512 UTF-8 字节的非空白、无控制字符 Host 脱敏模型理由。模型三种判定必须有 reason，failed/not_started 的 reason 必须为 null；reviewer 的 outcome 与决定、reason 与旧 reviewReason 一致。人工与取消的 reviewReason 仍必须为 null，审核理由只在 review.reason 中。旧持久历史缺 review 解释为未记录；当前 wire 始终显式投影 null。当前 pending 解释保存在内存，只有回答或取消的唯一终态记录才保存 review。取消记录的来源必须为 null，用户决定不带理由；审核器只允许本次 `allowed_once|denied`，对应 Run 必须 interactive 且 profile 为 `approval_required`。非空理由必须是有界、非空白、无控制字符的 Host 脱敏 UTF-8 字符串；wire 接纳历史格式已有的 detail 容量，不以模型当前更小的输出预算拒绝旧合法记录。AgentCore 摘要的 `source=callback` 不区分人工与审核器，Renderer 必须使用 Product 的 `answeredBy`，不能从它或理由自行生成可提交 response。

根 `capabilities.conversationRecovery` 当前为 true。每个 Task 延续唯一 continuation 模型：`continuationAvailable` 表示现在可启动下一 Run，`continuationUnavailableReason` 精确取 `session_poisoned | closing | task_archived | session_recovery_required | session_recovery_in_progress | session_recovery_failed | persistence_unavailable | checkpoint_unavailable | execution_rebind_required | workspace_unavailable | authority_unavailable | runtime_unavailable | history_read_only` 或 null，`continuationRecoveryAvailable` 表示当前 snapshot 下允许 Renderer 在普通发送的内部前置步骤提交 restore；它不产生独立的恢复按钮或卡片。`history_read_only` 表示该 Task 只能以忽略未知字段的方式读取，必须同时 `continuationRecoveryAvailable = false`，Host 拒绝其 Run、restore、模型与审批模式选择、重命名、归档和删除。`execution_rebind_required` 只表示当前 protocol/model authority 不能承载该 Task，不能用于表达历史 generation 与当前 generation 不等；Renderer 也不能把它解释为 Conversation 身份失败。Task lifecycle 精确取 `open | closing`，不存在 `closed`；删除用例另以 `deletionStatus = idle | deleting | failed` 表达，删除与 `archived` 独立，未归档 Task 也可以进入 `deleting` 或 `failed`；`deleting` 必须对应 `closing` lifecycle。active operation 可取 `restore`。Decoder 必须联合校验这些字段：attached 可继续态不能同时声称可恢复；required/failed 只有在精确 checkpoint recovery 或无 checkpoint 且无 included/pending history 的 fresh recovery gate 成立时才可发布 recovery available，Task/Workspace identity、Execution target readiness 与 runtime readiness 在两种模式都必须成立，Skill/MCP/Permission/projection readiness 不属于这些 gate；in-progress 必须对应 restore operation；archived/closing、普通 Run/compact 或 capability=false 时不得发布恢复前置步骤。不得新增并行的 `task.recovery` 状态对象。

每个 Run 与 Compact snapshot 必须包含 `conversationCoverage = included | excluded`。`included` 表示该 operation 属于当前 live Conversation 或最新 checkpoint 的恢复上下文，覆盖内部 pending/covered差异；`excluded` 表示它只保留在 Product history，不会出现在恢复后的 AgentCore上下文。Renderer 不得从 phase、outcome、id 或 checkpoint 状态推断此字段；只要 Task 存在 excluded operation，主阅读流必须保留其历史并显示部分历史未包含在恢复上下文的提示。该提示不能覆盖 continuation truth，也不能把所有 unavailable reason 统一解释为“必须新建 Task”。

Skill management 使用同一 revision 1 数据面发布 bounded preview/detail/projection 与 typed import/export/reimport/uninstall mutation；command catalog、Zig DTO、TypeScript runtime decoder、snapshot fixture 和 automation 必须完全一致，不建立第二 transport 或局部 revision。

`skills.detail` 成功响应的 `definition` 是只读展示用的作者正文。Host 去掉文件头部元数据和由 MetaWork 写入的精确资源定位说明。导入预览继续呈现源定义，已安装文件与导出包继续遵循 Product artifact 合同。

`skills.chooseImport` 精确接收 `{ kind: package | directory, target }`。target 精确为 `{ kind, workspaceId, expectedWorkspaceEpoch, installId }`，四字段必填；personal 三个 identity 为 null，project 只携带非空 Workspace id/epoch，reimport 只携带原 installId。Host 原生 picker 不使用普通短 command timeout。取消返回 `{ status: cancelled }`，准备失败返回 `{ status: rejected, reason }`；成功返回 `{ status: prepared, previewId, operationId, preparationRevision, sourceKind, scope, effect, installId, invocationName, displayName, description, definition, fileCount, totalBytes, blocker }`。scope 精确为 `{ kind: personal | project, workspaceId, workspaceEpoch }`，personal 两 identity 为 null；effect 为 create、update 或 replace_directory，只有 update 含非空 installId。正文和 metadata 由 Product 安全投影；不得携带源路径或摘要。

`skills.prepareImport` 精确接收 `{ previewId, preparationRevision, target }`，对有效 grant 改选 typed 目标后返回同一 prepared/rejected shape；target 为 null 只放弃尚未提交的准备，返回 cancelled，不取消任何 transaction。改选只推进 preparationRevision，不延长原 grant 的五分钟有效期。`skills.install` 与 `skills.reimport` 精确接收 `{ previewId, preparationRevision, confirmation: create | update | replace_directory }`，后者只接受 update。目标由 Host 准备记录拥有，不接收 scope、installId、allowReplace 或 raw path 的替代 payload。所有 identity/revision 采用 canonical decimal u64 string，installId 沿用 opaque hex identity；格式错误 fail closed。

Bridge 先核验 window/connection/grant/revision，再由 Product 完成生命周期、Task 静止和准备校验，最后在同一同步调用中一次性消费 grant 并提交。接纳前 busy/容量不足保留仍有效 grant，消费后失败不复活。断连、新来源和显式放弃撤销未提交准备；已提交事务独立收口。mutation 继续返回 `{ accepted, installId, verificationPending, reason }` 的既有互斥 shape；pending 不是成功可用，transport 失败不得自动重放。

`skillManagement.importOperation` 必填，值为 null 或有界最近事实 `{ id, preparationRevision, effect, phase, scope, installId, invocationName, reason, canConfirm, canDiscard, blocker }`。phase 为 prepared、pending_verification、ready、rolled_back、recovery_required、rejected、cancelled、outcome_unknown；同步提交不伪造后台 progress。canConfirm/canDiscard 只表示 Product 当前准备资格，不替代 Bridge grant 有效性；非 prepared 不可确认或放弃。结果不持久化、至多一份，查询不推进事务；Renderer 以 operationId/revision 关联命令和投影，并丢弃失效 audience/连接/范围的迟到预览。typed reason 的闭合集合由 Product ImportReason 与严格 wire decoder 对齐，来源读取、定义缺失/歧义/格式、布局、路径、类型、归档损坏、超限、源/目标变化、准入拒绝、文件失败和 outcome_unknown 必须保持可区分。

Skill asset 的 `managementState` 包含派生的 `recovery_required`，不改变持久化 Asset.state 或事务 phase。该状态必须有 installId，并关闭 canExport/canReimport/canUninstall；canRetry 仅可在 management ready 且 Host 的当前恢复/验证准入成立时为 true。现有 Retry command 不变，其物理恢复与验证分派由 Host 决定；ready/external 或 store 不可信时不得宣称可 Retry。恢复、原操作错误与全局 revision 发布的关系由 [Product 架构](product-architecture.md#24-skill-authority-与本地资产)定义。

MCP 管理使用同一 revision 1 snapshot 与 command 数据面，原地 hard cut 为 transport-discriminated catalog：既有 typed server commands 之外提供 `metawork.mcp.applyConfiguration`，payload 为 `{}` 或 `{ serverId }`：前者显式重开全部失败结果，后者只重开指定 canonical Desired 成员的失败结果，其他成员的失败不会随之重试；不得暴露 generic upsert 或第二 OAuth callback data plane；手动 header/env/client secret 只允许经 captureSecret 专用 payload 提交；HTTP create/update 可显式携带 `sensitiveEndpoint: true`，此时 endpoint 是 password 表单的一次性 secret 输入，Host 立即交给凭据事务，Bridge 不记录、缓存或投影。未标记地址仍执行公开字段校验。既有逐服务 command 携带 canonical decimal `expectedDesiredGeneration`，create 以外还携带目标 `serverId`；`applyConfiguration` 按上述独立 payload 规则重试 Host 当前配置；create/update 仍只接收结构化 command + ordered arguments 或严格 HTTP endpoint，不接受 shell string。`applyConfiguration` 返回 `started | busy | rejected | unavailable`，只重试把 Host canonical desired 应用到正式 Runtime，不接受 Renderer 提供配置。完整精确命令集由 `app.zon`、Zig 与 TypeScript catalog 同步定义。

create 的结果为严格 `{ outcome, desiredGeneration, serverId }`；其他 mutation 不增加 serverId。`saved` 必须返回确认创建的稳定 identity 与 generation，`saved_recovery_required` 仅在 canonical target 已知时携带 id；其他结果的 id 为 null。Product 在 preparation 释放前取得 owned identity 回执，Renderer 不比较 snapshot 集合或按名称寻找目标。

公共 `context.mcpInstallation` 精确为 `{ operations, notice }`，所有 scope 均交付。operations 的严格 shape 由 typed Bridge schema 拥有：绑定 server/Task/Run、revision 与 desired generation，包含安全显示名、阶段、分类失败、公开 origin、可取消性和缺失手动凭据槽名称；不投影原始请求、完整敏感 URL、凭据值或 locator。notice 为 null 或只绑定来源 Task/Run 的接纳失败提示。Task 与 MCP 页消费同一操作事实，不解析工具文本。`metawork.mcp.cancelInstallation` 仅允许 `zero://app`，精确 payload `{ serverId, installationRevision }`，使用标准 MCP mutation result；旧 revision 不能取消后来操作。`captureSecret.slot` 可使用 `{ kind: installation_credential, name }`，继续要求 expectedDesiredGeneration、精确 server 和专用 password 输入，Host 验证当前缺失槽；输入提交前、revision/generation/目标变化及离页均清除，不重放。旧 proposal、proposalId 与 dismissInstallProposal 不再是活跃 wire；手动 create 不附加提议身份。安装 ready 是完成历史，服务后续停用或目录失效由正常 MCP 管理状态显示，不把历史改写成连接中。

`metawork.mcp.probeHttpDraft` 是首次手动添加的异步检测，接收 `{ expectedDesiredGeneration, displayName, endpoint }`。Host 使用与手动添加一致的默认 HTTP 配置，对单个未保存候选执行隔离 Runtime activation。结果仅为 `{ outcome: connected | authentication_required | access_denied | oauth_automatic | oauth_existing | failed | busy | rejected | unavailable } 或 { outcome: redirected, endpoint }`。只有解析并校验 OAuth 资源和授权服务器元数据后才返回 OAuth 结果，有注册 endpoint 时返回 `oauth_automatic`。探测收到 307 或 308 时，Host 解析唯一 Location，可返回同源、通过 endpoint 校验且不含 Host 已知凭据的绝对地址。Renderer 可提交一次新的无凭据探测。Host 不返回原始 Location，正式连接和带凭据的验证不跟随重定向。检测不写 registry、读取凭据或改变正式 Runtime。

`metawork.mcp.verifyAndAddHttpDraft` 接收 `{ expectedDesiredGeneration, displayName, endpoint, headers: [{ name, value }] }`，最多四个请求头。值经一次性 password 表单转交 Host，Bridge 不缓存或投影，Host 在隔离 Runtime 验证同一份配置。握手通过且原请求仍有效时，Product 使用当前 generation 重新校验并用既有凭据事务保存连接和值。回复为标准 create 回执或 `{ outcome: failed | busy | unavailable }`。验证失败或断连丢弃候选及临时凭据。

`approveConnection` 只服务 schema 1 迁移留下的 legacy unapproved server；普通 Add/Replace 不经过该 command。`captureSecret` 接收 `{ expectedDesiredGeneration, serverId, slot, secret }`，secret 是用户在 Renderer password input 中显式填写的非空、有界原值；Bridge 同步转交 Host，沿用原有 slot、generation、approval 与事务校验并写入系统 credential store，不记录、缓存、投影或返回 secret。`mcpSecretCapture` 表示此凭据提交能力，不依赖原生输入弹窗。未提交输入在提交、取消、关闭详情、离页、generation 变化或管理不可用时清除，不回填已存值、不持久化、不自动重放。`authorizeOAuth` 只对 approved Streamable HTTP OAuth server 启动全局唯一、server-bound operation，并继续保留独立的 Host consent；当前目标连接失败且未加载的 ready OAuth 授权允许用户显式重新登录，资格由 Host 校验。`testConnection` 使用 `McpServerIdentity` payload，结果精确为 `started | busy | stale_generation | needs_authentication | rejected | unavailable`；started 表示 Host 已启动一个隔离候选 Runtime 的真实 activation，不表示测试已成功。完成状态只经 snapshot/notification 发布，不返回 raw catalog 或 diagnostic。`refreshCatalog` payload 为空，只刷新当前正式 Runtime catalog，不应用 pending connection configuration 或隐式启动 OAuth。

根 `capabilities` 必须包含 boolean `mcpManagement`、`mcpConnectionApproval`、`mcpSecretCapture` 与 `mcpOAuth`，以及非负安全整数 `mcpSecretMaxBytes`。该上限来自 Host 实际注入 MCP management 的 credential storage 字节限制；management 不可用时为 0，可用时必须大于 0。Renderer 按此值执行 UTF-8 字节校验并插值显示提示，不自行定义上限；Host 仍独立校验。根 `mcp` 必须精确包含 `availability`、`managementHealth`、`operation`、`configurationApply`、`authorizationOperation`、`desiredGeneration`、`runtimeAlignment`、`redacted`、`servers`、`retainedMemberCount`、`applyFailureCount`、`runtimeUncertain` 与 `runtimeTimeoutLimitMs`：`configurationApply = idle | applying | failed`，其余 enum 保持既有定义。没有可信 canonical desired或 management outcome unknown 时 configurationApply 必须 idle、generation null、alignment unknown、servers 为空且 authorization operation idle。三个 count 字段（含 server 的 `taskReferenceCount`）均为非负安全整数。`runtimeTimeoutLimitMs` 是 Host 的有效单次连接/目录管理 timeout 上限，必须为正 u32，来自唯一 Product MCP contract 常量，所有管理健康状态均发布。server `timeoutMs` 仍是配置原值，工具调用不应用此管理上限；Renderer 使用该上限提示管理操作的执行行为，不硬编码数值，也不静默重写历史配置。`retainedMemberCount` 计数因 Task 引用而保留的已停用或删除的实际成员；已删除成员没有 Desired server row。`applyFailureCount` 只计当前目标仍匹配且未重开的失败结果，后续其他成员成功不能清掉它。无可信 Desired 时两个根 count 为 0、`runtimeUncertain = false`。`mcpManagement = false` 时发布完整 fail-closed baseline。任何不变量不满足都使 Renderer snapshot decode fail closed。

每个 server 使用唯一 opaque `id` 与唯一 `namespace`，并精确包含 `displayName`、`transport = stdio | streamable_http`、`authMode = none | static | oauth`、`negotiation = automatic | modern_only | compat_only`、正整数 `timeoutMs`、nullable typed `connection`、`approvalStatus`、`authorizationStatus`、boolean `canAuthorize`、`desiredEnabled`、`runtimeStatus`、`newTaskAccess`、已清洗的 `safeDiagnostic`、`connectionTest`、`tools`、`taskReferenceCount` 与 `applyStatus`。`taskReferenceCount` 只计匹配该实际应用版本的进程内 Task 引用。`applyStatus = current | pending | waiting_auth | applying | rejected | failed | capacity | unknown` 描述成员处理结果，`current` 不证明连接或 catalog 健康；`waiting_auth` 表示当前目标等待授权恢复，不能投影为正在连接或失败。`authorizationStatus = refreshing` 表示 Host 正在更新 grant，不允许 Renderer 取消或重放该非幂等 effect。`canAuthorize` 由 Host 使用命令相同的当前授权准入策略派生，Renderer 仍须与 `capabilities.mcpOAuth` 求交；ready 但未加载且当前目标连接失败时可以为 true，Renderer 不能仅从 ready 推断登录入口关闭，也不能自行把裸 401/403 当成 grant 过期。`rejected` 不归因为该服务的网络故障。`capacity` 表示当前成员应用受连接容量限制，计入 `applyFailureCount`，Renderer 用该类型提示用户关闭不再使用的任务后重试。单步串行期间至多一个 row 为 `applying`，其他 row 保留自己的健康和准入状态。`connectionTest` 精确为 `{ status: untested | testing | connected | failed, toolCount, issueCount }`，只存在于当前进程 projection；配置 mutation 清除旧结果，Host 重启后回到 untested。`connection` 对有效、未被 credential scrub 的 STDIO 精确发布 command、ordered arguments、nullable cwd 与 environment name/status；对 Streamable HTTP 精确发布 endpoint、header name/status、registration kind、用户提供的 client id、token endpoint auth method 与 client-secret status。敏感地址额外发布 `sensitiveEndpoint: true`，endpoint 仅为 origin；普通地址省略该字段。配置无效或已触发 credential scrub 时 `connection = null`，Renderer 不得猜测或允许盲目替换。

Host 将 Desired Registry 的完整非敏感 typed connection、authorization operation、Runtime Manifest disposition、Agent opaque Activation health 与 Admission Authority 合成为 projection。environment/header value、credential locator、client secret、token/code/PKCE、动态注册所得内部材料、raw OAuth metadata、raw diagnostic、schema body、fingerprint 和 AgentCore handle 不进入 projection；Renderer 不直接解码或镜像 AgentCore MCP schema。`redacted` 只表示 Host 确实移除了可发布文本。Core 接管结果未知时，独立可信的 committed Desired 仍可显示，但必须 `runtimeUncertain = true`、alignment unknown、availability unavailable、所有 row `applyStatus = unknown`、成员计数为 0，且不得发布已发现工具或新 Task 工具权限；连接、catalog 和授权外部 effect 冻结。不得用 last-known Desired 伪装 canonical state；persistence outcome unknown 仍隐藏 Desired。

Renderer 的 Slash Resolver 只在 Composer 首 token 处理 `/` 手势。单一 Command registry 当前只由 `App` action controller 复用既有 New task 动作；Command 原文在 Renderer 消费，不产生 Run。Skill 候选来自当前 Workspace catalog projection，未选工作目录的新任务草稿使用顶层 personal catalog projection。选择后形成带稳定 identity、pinned revision 与 positional arguments 的 tagged draft，经 `tasks.sendInput` 提交。Command/Skill 同名时裸名称归 Command，Skill 使用 `/skill:name`；Renderer 不读取 Skill body、物理路径或 policy。

`models.defaultSelectionDisplayName` 为必需的 nullable string，仅在保存了非空 Metask 起始偏好显示名时为字符串。新任务 Composer 依据[产品需求](requirements.md#52-账号provider模型与执行配置)将它解析为目录中的当前 `ModelRef`，创建命令继续提交精确模型 ID 和当前 generation。

退役 `metawork.models.configureMetaskSelection` 与 `metawork.models.selectDefault` Renderer command，不提供旧 payload 兼容。起始偏好仅由 Host 在交互 Task 创建成功或主动模型意图 confirmed commit 后 best-effort 保存；自动创建、目录更新或浏览历史不更新。偏好写失败不改变已确认 Task 结果，根 Models.errorCode 发布 `preference_not_saved` 独立非阻塞提示；Provider errorCode 不产生此值。

生图模型由 Host 的 Models owner 自动解析，不提供 Renderer 选择或清除命令。退休 `metawork.models.configureMetaskImageSelection` 不再注册或允许；Renderer 不能提交图片 model、endpoint、credential、目录顺序或生成参数。执行授权仍在每个 Run admission 通过即时 lease 取得，不由设置操作授予。

`models` 不再发布专用 `imageGeneration` 选择、revision 或候选投影；对话 Provider 与 Composer 只消费对话模型列表。Host 的图片模型解析、候选所有权和目录回退规则由 [Product 架构](product-architecture.md#21-models-aggregate-与-account-handoff)拥有。Renderer 通过现有工具及审批详情显示真实调用结果，不保存或重建图片执行 authority。

Models canonical 显式恢复使用 `metawork.models.resetStore`，payload 精确为 `{ expectedRevision }`，返回既有 Execution command result。该命令只在同一 snapshot 的 `models.persistenceHealth = recovery_required` 时可呈现，Bridge 只严格解析 Product revision；Product Control 与 Models owner 在执行时必须再次确认 recovery eligibility。执行时 Host 重新读取并严格解码 canonical：合法当前 schema 被非破坏性重装，中断测试完成确定性收敛；读取失败或资源耗尽拒绝且不写盘；只有文件缺失或严格确认损坏才安装当前空 schema 1。成功表示 canonical 已恢复为可信 Models 状态，不保证配置被清空，也不表示旧 bytes 被迁移、归档或启发式解释。`ready` 与 `unavailable` 必须拒绝；Renderer 不提交路径、文件内容、schema、reset mode、generation 或重放标志。该命令不修改 Account、Workspace、Task、Run 或对话历史，既有 Task-owned execution binding 不被重写。

Custom Provider credential 替换使用 `metawork.models.customProviders.replaceCredential`，payload 精确为 `{ providerId, expectedProviderRevision, apiKey }`。`apiKey` 是用户在本地桌面 Renderer 中显式填写的非空 opaque string，UTF-8 bytes 不得超过 4096；Bridge 只做严格 shape/容量校验并在本次同步调用中转交 Models，不得记录、缓存、投影、返回或异步保留该字段。Models 使用既有两阶段事务，先持久撤销旧 readiness，再写入 credential vault，最后以新的 provider/source generation 恢复为待测试状态。任一中途失败都不得让旧 readiness 配上新 credential；已有 Task/Run 的 owned binding 不受影响。

`models.providers[].models[]` 精确包含 `id`、`displayName` 与 `metadata`。metadata 精确包含 `maxInputTokens`、`maxOutputTokens` 和 `capabilities`。capabilities 精确包含 nullable boolean `textInput`、`imageInput`、`pdfInput`、`audioInput`、`videoInput`、`batch`、`citations`、`codeExecution`、`structuredOutputs`，以及 `output = { text, image, audio, video, embedding }`、`thinking = { supported, adaptive, enabled }`、`effort = { supported, low, medium, high, max }`、`contextManagement = { supported, clearThinking20251015, clearToolUses20250919, compact20260112 }`；各成员均为 nullable boolean。Metask 的缺失/null 能力投影为 false，Custom Provider 的未知声明保留 null。服务声明不直接授予产品能力。

metadata 的两个 token 字段为 null 或正数 canonical decimal u64 string。所有 wire key 均必需，由 Host serializer 与 Renderer strict decoder 同步消费；metadata 不进入 selection command payload。Custom model metadata command 使用相同能力与 token 字段，Host 保存所有已声明的能力。当前 metadata 不包含 `limits`；API token 字段来源与缺失语义以 [Product 架构](product-architecture.md) 为准。

Custom Provider mutation 使用同一 revision 1 数据面上的 `metawork.models.customProviders.create | update | replaceCredential | remove`，内置官方模板创建与地址修改分别使用 `metawork.models.builtinProviders.create | updateBaseUrl`，custom model 集合使用 `metawork.models.customModels.add | replace | remove | test`。custom create 接收 `{ displayName, protocol, normalizedBaseUrl, apiKey, model? }`；builtin create 精确接收 `{ providerId, baseUrl, apiKey, model? }`，可选 `model` 与 custom model add 使用同一 typed definition（必需 `id`，可选 `displayName` 与 `metadata`）；缺省时创建空模型集合，存在时必须在 credential effect 前验证并与来源一同提交最终 metadata candidate，不能创建默认选择或 readiness。其中 `providerId` 只能是 `deepseek | kimi | minimax | glm | hunyuan`，`baseUrl` 是不含 credential、query 或 fragment 的 HTTPS URL，或 HTTP loopback URL。builtin updateBaseUrl 精确接收 `{ providerId, expectedProviderRevision, baseUrl }`，其中 `providerId` 是已创建 Provider 的 source identity。Models 根据 builtin identity 固定 display name 与 protocol，并把 Base URL 映射为该 protocol 的精确 completion endpoint；Renderer 和 Bridge 不提交或推断 protocol。`apiKey` 与 replaceCredential 相同，只能作为调用期 secret 一次性转交 Models credential vault。通用 update/remove 使用 `providerId + expectedProviderRevision`；内置模板 Provider 必须拒绝通用 update，但允许专用 updateBaseUrl、replaceCredential 与 remove。地址变更必须刷新 provider/source generation，并按 Models 既有语义撤销旧 endpoint 上的模型 readiness；已有 Task/Run 的 owned binding 不受影响。test 精确使用 `{ model: ModelRef, expectedProviderRevision, expectedSourceGeneration, expectedCatalogGeneration }`；add 使用 `{ providerId, expectedProviderRevision, expectedCatalogGeneration, model }`，replace/remove 使用完整 `ModelRef` 并携带 expected provider revision 与 catalog generation。Bridge 只接受上述精确结构，不定义旧 payload、别名、归一化或兼容分支。Host 负责 endpoint/protocol、model membership、metadata、credential 状态和全部 revision/generation 校验。删除来源最后一个模型时同时移除该来源并持久排队凭据删除；同厂商或相同 endpoint 的新增来源按独立 source id 与 credential slot 隔离，不由 Bridge 或 Renderer 选择并复用已有来源。

Models snapshot 中的 `builtinProviderPresets[]` 精确发布 `id + displayName + protocol + defaultBaseUrl + apiKeyUrl + documentationUrl + modelIds`；`protocol` 与 `defaultBaseUrl` 是 Models-owned 模板事实，用于 Renderer 呈现默认值和 endpoint 预览，不代表用户当前保存的地址；`modelIds` 为 Host-owned 官方模型 ID 预设数组，成员是非空且不超过 256 UTF-8 bytes 的字符串，只用于添加表单，不代表 readiness 或实时授权目录；不得发布 completion endpoint、credential 或 logo。`customProviders[]` 精确发布 `id + builtinProviderId + displayName + protocol + normalizedBaseUrl + state + credentialStatus + enabled + providerRevision + sourceGeneration + catalogGeneration + models`，其中 `builtinProviderId` 为上述四个 identity 之一或 null；其 `models[]` 成员发布 `id + displayName + metadata + metadataProvenance + testStatus + ready`。Provider 不发布 `selectedModel` 或 Provider 级 `testStatus`；新任务起始偏好只存在于 nullable `defaultSelection`，测试状态只属于具体模型。`state = configuring | ready | disabled` 由当前 source generation 是否存在至少一个 ready model及 credential/enabled 共同决定。成功 probe 建立该精确模型的 ready proof；同一 authority 上的失败重测只改变 latest status，不撤销 proof。任务直接提交完整模型目标，起始偏好仅为 Host-owned metadata，不产生执行配置。根 `capabilities` 必须精确包含 boolean `customProviderManagement`、`customProviderSecretCapture` 与 `customModelTest`；revision 1 保留 `customProviderSecretCapture` wire name，其 true 表示 secret-bearing create/replace typed command 与系统 credential storage 同时可用。Host 只在 management、credential storage 与模型测试均可用时把三者同时发布为 true，任一缺失全部为 false。该判断只消费当次实际 capability，不以平台名建立静态 allowlist；Renderer 只有三者均为 true 才显示 Models 内的自定义模型管理。

根 `account` 精确包含 `{ state, canCancel, accountId, displayName, emailHint, phoneHint, concurrencyLimit, errorCode, safeDiagnostic, summary }`；authenticated 只要求非空 `accountId`，`displayName/emailHint/phoneHint` 均为可空的best-effort资料提示，`concurrencyLimit` 为nullable非负整数，其中 `null` 表示资料不可用、`0` 表示 Metask 后端的不限并发语义；其他状态的字符串identity字段都为空且`concurrencyLimit`为null；完整邮箱和手机号不得越过Bridge。`errorCode=none` 时 `safeDiagnostic` 必须为空。`summary` 精确为 `{ operation, usageEligibility, wallet, usage, history }`，operation取 `idle | refreshing`，usageEligibility取 `unknown | disabled | enabled`。wallet精确为 `{ availability, balanceU, syncedAt, errorCode, safeDiagnostic }`；usage精确为 `{ availability, today, total, syncedAt, errorCode, safeDiagnostic }`，today精确包含 `{ inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens, totalTokens, actualCostU }`，total精确包含 `{ totalTokens, actualCostU }`；history精确为 `{ availability, startDate, endDate, days, syncedAt, errorCode, safeDiagnostic }`，days的每项精确包含 `{ date, inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens, totalTokens, actualCostU }`。availability取 `unavailable | loading | ready | stale`；日期为nullable `YYYY-MM-DD`，ready/stale范围必须从周一开始并覆盖最近53个周列（365–371个日历日），days最多371项且日期严格递增、唯一并位于闭区间；数值均为nullable canonical decimal string，`syncedAt`为nullable canonical decimal Unix milliseconds string。非authenticated时summary必须是idle + unknown + 三个unavailable空值；ready/stale必须携带完整对应数据和同步时间，unavailable/loading不得携带数据；usageEligibility=disabled时usage/history必须unavailable且无错误。成功的history响应允许Renderer把返回范围内未列出的日期显示为零，失败或stale转换不得由缺失日期伪造零值。Account不得出现provider、catalog、model、selection、source、authorization generation、raw run mode、Task admission、API Key或Custom Provider。根`models`精确包含 `{ availability, persistenceHealth, providers, defaultSelection, selectionRevision, operation, errorCode, builtinProviderPresets, customProviders }`。不得发布`connections`或`ModelConnection`。`persistenceHealth`精确取`ready | recovery_required | unavailable`：前者表示canonical可用，中者表示file capability存在但canonical不可信且允许显式reset，后者表示capability不存在且没有reset action。当前内置provider为 `{ id: "metask", displayName, recommended: true, catalogState, principalRef, models, catalogGeneration, sourceGeneration, errorCode, safeDiagnostic }`；Account授权不可用时其catalogState为`needs_authentication`，models数组为空，但无secret的来源authority与起始偏好可以保留。`defaultSelection`是nullable完整`ModelRef`起始偏好，允许引用已离开目录的模型；其revision不授予执行资格。移除metaskSelection/metaskSelectionRevision投影，Metask只有来源authority和目录。Renderer不因偏好不在目录而拒绝合法Snapshot。`catalogState=ready` 表示当前权威目录已接纳，不保证目录非空或 intent 可解析；空目录使用 `errorCode=no_models`。每次执行由Host校验明确目标的membership、source/catalog generation与对应授权。

根 `newTaskAdmission` 精确包含 `{ available, reason }`，只表达通用创建资格，不含 active binding 或 replacement state。reason 精确为 `none | shutting_down | workspace_unavailable`；可用时 reason 为 none。具体模型、Workspace 与其他能力仍由对应 Host owner 在命令接纳时校验，偏好有效性不影响该通用资格。

`capabilities` 在既有 Task/Schedule persistence health 旁精确发布 `taskHistoryRecoveryAvailable` 与 `scheduledTaskRecoveryAvailable`，并在 `taskHistoryRecoveryAvailable` 之后发布 `retainedTaskHistoryCount`：当前版本无法恢复、按原字节保留的 Task record 数量，十进制 wire integer，不随 commit 清零。两者只在对应 Application file capability 存在且 health 为 `read_failed | corrupt | write_failed | outcome_unknown` 时为 true；`ready | degraded | unavailable` 必须为 false。显式命令分别为 `metawork.tasks.recoverHistory` 与 `metawork.scheduledTasks.recoverStore`，payload 精确为 `{ expectedRevision }`，结果精确为 `{ outcome }`，outcome 取 `recovered | stale_revision | not_required | unavailable | failed | outcome_unknown | shutting_down`。命令只请求对应 Product owner 用当前内存真相替换 store；Renderer 不提交路径、文件内容、reset mode 或重放标志。

`connect` 是 product delivery 的 bootstrap 边界。Host 必须在合同身份与 revision 校验成功后才建立 `ProductDelivery` connection；既有 `requireWindow()` 门禁随后统一保护 Account、Task、event 和 snapshot 产品路径。协商前只允许显式列出的无状态 bootstrap/smoke 命令，不得读取或修改产品状态。合同不匹配返回 typed terminal bootstrap error，Renderer 不把它当作瞬时断线重试。

Zig/TypeScript 的 identity、revision 和完整 command catalog 必须精确一致，`app.zon` allowlist 不得缺项或多项；Host serializer → TypeScript decoder 与 TypeScript bootstrap payload → Host decoder 必须有跨语言 fixture/行为测试。Renderer 内同一 wire enum 的 TypeScript type 与 runtime decoder 必须消费同一值目录，不能维护彼此独立的 union 与 allowlist；Host 新增产品 cause 时，serializer、Renderer 值目录、文案和跨语言 fixture 必须在同一变更中收齐。Renderer 始终 runtime decode Host payload；malformed payload 或 decoder/serializer contract mismatch 一律进入 fail-closed view-sync failure，不能猜测字段或静默降级。

采用结构派生的对象以发布 owner 的纯 Zig wire 类型与显式编码声明为唯一结构定义，实际 Host serializer 必须消费同一定义；Renderer 类型、字段集合、基础 decoder 与共享运输限制从中生成，禁止另行手写维护被接管的表达。Product 的投影类型不得反向依赖 Bridge；Bridge 运输描述符由 Bridge 发布。结构生成不接管脱敏、权限、对象关联或业务状态校验，也不得要求先物化完整 Snapshot 对象图或突破既有流式写入、同步借用与容量预算。不支持的编码必须在构建时明确失败。生成结果随源码提交，其新鲜度及跨语言验证由[验证规范](validation.md#标准入口)负责。

结构诊断只报告发生差异的对象路径、缺少的已知字段及额外字段数量，缺字段名称的条数与总长度必须有界；不得输出任意输入 key、字段值或原始 payload。未知 enum 值不回显原文。结构拒绝不自动证明运行组件版本不同，不触发兼容解码或命令重放。

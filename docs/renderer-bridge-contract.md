# MetaWork Renderer Bridge 合同

> 状态：`metawork.renderer-bridge` 固定 revision 1
> 日期：2026-08-04

顶层模块职责见 [MetaWork 高层架构](architecture.md)。本文件是 Renderer 与 Application 之间 command、event、Snapshot、连接与运输语义的唯一架构真源；具体源码目录见 [工程结构与所有权](project-structure.md)，持续验收入口见 [验证规范](validation.md)。

## 1. Bridge 定位

Bridge 是 Renderer 与 Application 之间的入站协议边界。它只负责验证调用来源与启动窗口 identity、严格解码 payload、把合法输入转换为产品命令、调用 Application、编码 typed result，并通过 Snapshot/Event 运输发布产品投影。Bridge 不决定 Task 是否可以运行、Workspace 是否有效、Agent 是否应取消、credential 是否可以替换或历史如何持久化；这些判断必须由 Application 内对应 owner 完成。

Bridge 的唯一产品数据面由具体 `Dispatcher` 内部的 `ProductDelivery` 统一拥有：connection generation、revision retry/timer、snapshot identity 和 snapshot transport storage 都不再存放在 App。Dispatcher 通过明确的 `*Workbench` 同步生成 snapshot；App 只注入 Native emit/timer/dialog/window-chrome/main-thread capability，并按顺序组织 shutdown。`hidden_inset_tall` 的 WebView 标题栏通过受限 bootstrap chrome command 提交 native press、minimize、toggle-maximize、system-menu、close 或只读 state 意图，不依赖 ProductDelivery 是否连接。Bridge policy 先约束 origin，Dispatcher 再精确匹配 App-owned 单一启动窗口 identity、payload 与主线程；Windows platform seam 仅在 manifest 仍声明该唯一启动窗口时解析并验证对应 native window，不能用 Renderer 提交的 HWND 或未经验证的当前活动窗口代替 identity mapping。Renderer 只保存用于呈现 affordance 的瞬时最大化投影，窗口状态仍以 Host 查询为准。该通道不建立第二产品数据面。automation 只能提供受控账号、临时 Workspace authority 和桌面驱动，不注册测试专用协议、不跟踪产品 generation，也不建立平行传输协议。

## 2. ProductDelivery 与 Snapshot transport

Host view snapshot 使用 Bridge `Dispatcher` 内部 `ProductDelivery` 独占的 16 MiB 有界存储，不受 Bridge 单次 1 MiB result 上限反向约束。该容量覆盖 512 KiB Task projection、最大 Account API Key/model catalog、Workspace/Task Skill catalog 结构、JSON 最坏转义和全部结构上界。Dispatcher 同时拥有 callback gate、workspace grants、handler registry 和 `*Workbench`，产品 command 的 decode、authority、domain call 与 response encode 不再经过 App。Workbench writer 只能在同步调用期间借用这块 output buffer；返回后 Bridge 独占 encoded bytes，禁止保存 Workbench borrowed view。Renderer 通过带 snapshot identity 的 256 KiB 分块读取完成 resync；begin 写入前先使旧 descriptor 失效，序列化失败后旧 identity 必须保持 stale，不能继续读取已被部分覆盖的 store。revision 通知和 snapshot 拉取分别保留 pending/retry 状态，瞬时发送或读取失败不能把旧视图标记为最新。revision retry 同时受 attempt 和 deadline 预算约束，耗尽或 retry timer 不可用时当前 event connection fail closed，但不终止后台 Agent Run。新 event generation 建立时会使旧 snapshot descriptor 失效；Renderer 若仍持有旧 generation Promise，必须在旧 Promise 退出后继续完成新 generation 的实际 resync，不能把等待旧 Promise 误判为同步成功。Bridge 异步保留的 payload 必须自有；App shutdown 先 stop Bridge ingress、关闭 delivery connection 并取消 timer，在 Native platform loop 上确认同步 handler quiescence，然后 detach Workbench，最后才独立释放 delivery buffers。

## 3. Renderer Bridge wire contract

Host 与 Renderer 随同一应用包原子发布，不承担旧 Renderer/新 Host 或新 Renderer/旧 Host 的兼容。bootstrap 必须拒绝合同 identity 或经用户批准后出现的 revision 错配；固定 revision 策略下，`connect` 无法通过 revision 数字识别同 revision 的陈旧开发产物。严格 command catalog 和 payload decoder 只能在实际命令或结构差异被触及时失败，不能检测纯 wire 语义错配。此类错配属于 unsupported development state，必须通过 clean rebuild、清理缓存或重新安装恢复；原子打包用于降低发生概率，不构成 runtime compatibility guarantee。Renderer Bridge contract 覆盖全部 product command、event 和 snapshot wire surface；它与产品版本、AgentCore ABI、bundle manifest schema 相互独立。

Renderer Bridge 使用独立合同身份 `metawork.renderer-bridge`，快速开发阶段固定 revision 为 `1`。Host 与 Renderer 随同一应用包原子发布，任何 command、event、payload 字段或 wire 语义变化都直接原地 hard cut，不为临时合同形态递增 revision、不维护兼容层，也不在 snapshot 内维护第二个局部版本。`contractRevision` 仍精确匹配，用于拒绝非当前固定标识，但不承诺识别同 revision 的开发产物错配。任何合同类版本标识的变更都必须先得到用户显式同意；对本文件即包括 Renderer Bridge revision。

当前 `metawork.tasks.run` 只有 `input.kind = text | skill` 的 tagged payload，旧 `prompt` 不兼容；`tasks.create` 必须携带 nullable `expectedSkillCatalogRevision`。Skill 没有 `runSkill` 第二入口。Workspace/Task catalog、typed Run history 和 Skill terminal cause 只从 Workbench snapshot 发布；显式 catalog refresh 也只通过 Bridge 调用 Workbench transaction，Bridge 不持有 catalog lease、不解析 slash、不读取 Skill body。

Skill management 使用同一 revision 1 数据面发布 bounded preview/detail/projection 与 typed import/export/reimport/uninstall mutation；command catalog、Zig DTO、TypeScript runtime decoder、snapshot fixture 和 automation 必须完全一致，不建立第二 transport 或局部 revision。

Renderer 的 Slash Resolver 只在 Composer 首 token 处理 `/` 手势。单一 Command registry 当前只由 `App` action controller 复用既有 New task 动作；Command 原文在 Renderer 消费，不产生 Run。Skill 候选只来自当前 Workspace/Task catalog projection，选择后形成带稳定 identity、pinned revision 与 positional arguments 的 tagged draft，再沿唯一 `tasks.run` 路径提交。Command/Skill 同名时裸名称归 Command，Skill 使用 `/skill:name`；Renderer 不读取 Skill body、物理路径或 policy。

`connect` 是 product delivery 的 bootstrap 边界。Host 必须在合同身份与 revision 校验成功后才建立 `ProductDelivery` connection；既有 `requireWindow()` 门禁随后统一保护 Account、Task、event 和 snapshot 产品路径。协商前只允许显式列出的无状态 bootstrap/smoke 命令，不得读取或修改产品状态。合同不匹配返回 typed terminal bootstrap error，Renderer 不把它当作瞬时断线重试。

Zig/TypeScript 的 identity、revision 和完整 command catalog 必须精确一致，`app.zon` allowlist 不得缺项或多项；Host serializer → TypeScript decoder 与 TypeScript bootstrap payload → Host decoder 必须有跨语言 fixture/行为测试。Renderer 始终 runtime decode Host payload；malformed payload 或 decoder/serializer contract mismatch 一律进入 fail-closed view-sync failure，不能猜测字段或静默降级。

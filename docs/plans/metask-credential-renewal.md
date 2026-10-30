# Metask 会话凭据续期实施方案

Account 刷新 access token 后，MetaWork 将新 token 交给同一连续授权下的已有执行。主会话直接调用 Metask AgentCore 的 `updateCredential`；自动审批从续期后的 attachment 准备本次 Completion，自动标题和生图在执行各自请求时读取最新 token。模型、地址、权限和对话继续沿用原执行配置，已完成的工具不重放。

本文为实施计划，不是 decision record。审批保持现有 prepare/start 结构，续期与新 Run 的 catalog gate 分离；第 7 节采用锁定 ABI 内可证明的退役边界，接受活动 operation 的保留量随轮换次数增长。容量按真实 owned 项动态分配，保留完整跨对象清洗和实际分配失败的拒绝语义。实现和验证进展由代码、测试、Git 与 TinyKG DAG 拥有，不将计划描述当作已验收结果。

## 1 问题和依据

旧问题是 Account、Models 和 Task 各自持有凭据副本，Account 换了 token，旧 Task 仍可能继续使用原副本。[Issue 3](https://github.com/shuzuan-org/metawork/issues/3#issuecomment-6362114861)记录了旧会话持续失败、同模型重绑定后恢复的样本，但未直接证明失败 HTTP 状态或 token 到期原因。其后修复通过空闲边界的 checkpoint、关闭和恢复事务安装新凭据。

[Issue 62](https://github.com/shuzuan-org/metawork/issues/62)记录了长时间等待审批后模型请求失败、新旧任务均不能执行、重启恢复的样本。它是本次回归场景；目录和 Account 恢复可能另有原因，不能仅凭接入 Core 接口关闭该 issue。

本方案以 2026 年 10 月 30 日仓库 revision `b3a0704441a103f395280d55aa4cfb74bbcad2b7` 的静态检查为依据：

| 位置 | 与本次修改直接相关的事实 |
| --- | --- |
| [Windows lock](../../build_support/agentcore-bundle.windows-x86_64.lock.json)及 canonical staged binding | 锁定 ABI revision 26；官方 Session API 已包含 revision 25 加入的 `updateCredential` |
| [Agent Session](../../src/agent/session.zig) | MetaWork 尚未提供凭据更新包装；已有 Session reference 和 close/quiescence 协议可复用 |
| [Models coordinator](../../src/app/models_coordinator.zig) | Account 代次变化后取得 lease，取消旧 catalog job，再开始目录请求；执行续期尚无独立交付入口 |
| [Product Control](../../src/product/control/runtime.zig)及 [Task execution binding](../../src/product/task/execution_binding.zig) | 同 scope 轮换仍通过来源比较和重绑定更新凭据 |
| [Task runtime](../../src/product/task/runtime.zig)、[review job](../../src/product/control/permission_job.zig)、[Run worker](../../src/product/task/execution.zig) | 自动审批和自动标题复制执行凭据；审批 Completion 在 worker 启动前创建 |
| [图片执行](../../src/agent/image_generation.zig)及 [图片准备](../../src/app/models_coordinator.zig) | endpoint、model、credential 在 Run preparation 时复制，随后同 Run 的图片调用复用它们 |
| [Run state](../../src/product/task/state.zig) | `redactionSecrets()` 固定返回主执行和图片两份凭据，尚不能表达一次 Run 内多次 token 轮换 |
| [Metask 生命周期测试](../../tests/integration/lifecycle/metask_credential_test.zig) | 现有 Account／Models／Task 组合使用 synthetic Core ABI；需要保留其授权测试，并追加真实 canonical Core 的 HTTP 回归 |

官方 `SessionUpdateCredentialFnV1` 的合同是：成功后发送的请求使用新凭据，包括重试、此前创建的 provider 和仍在等待连接的请求；已发送请求保留旧凭据且不中断。调用可以与 Run 重叠，并发调用线性化。失败保留旧凭据，永不返回 `BUSY`。输入为 1 至 16384 字节的可打印 ASCII。

这些是依赖接口的合同，不是本次产品链路已验证的结果。MetaWork 保持现有 4096 字节产品上限，并在更新入口满足 Core 更严格的字节校验；不扩大全局凭据容量或改变 Custom Provider 输入合同。

## 2 范围和用户行为

本次覆盖 Metask 对话 Session、该执行的自动审批与自动标题，以及每个 Run 已接纳的 Metask 生图配置。Scheduled Task 和后台 Task 使用相同执行路径，不另建定时任务续期实现。

| 场景 | 目标行为 |
| --- | --- |
| 同 scope 正常刷新 | 自动安装新 token，保留逻辑 Session、Run、对话、模型和权限 |
| 请求已经发出 | 继续使用它自己的旧 token，不取消、不重发 |
| Run 正在等审批或执行工具 | 更新 Session；后续模型请求使用新 token，原审批和工具只执行一次 |
| 空闲 Session 或尚未执行的 queued Run | 原位更新；纯 token 变化不导出 checkpoint、不关闭或恢复 Session |
| 新自动审批请求 | 主线程从续期后的 attachment 复制凭据，沿现有流程立即创建 Completion 并启动线程 |
| 自动标题或图片调用尚未开始 | 执行时读取最新已安装凭据；不使用 Run preparation 时复制的旧 token |
| 图片请求已经派发 | 原请求继续；同一 Run 的下一次显式生图调用取得新 token，不自动重试生图 |
| 退出、换账号、重新登录 | 结束旧 scope 的续期资格，新登录凭据不得进入旧执行，即使 principal 相同 |
| 目录刷新慢、失败、空目录或当前模型移除 | 已接纳执行的同 scope 凭据续期独立完成；新执行仍遵守目录和授权 gate |
| 真正改变模型、endpoint、protocol 或能力输入 | 继续执行相应模型切换、能力更新和恢复事务 |
| 更新某个 Session 失败 | 只收口受影响执行，其他合法执行仍可更新；不回滚已提交的 Account token |

保留现有 logout 合同：退出不伪造已接纳 Run 的热撤权，不自动强杀它。旧执行可以按原生命周期消费已经拥有的凭据，直到完成或真实失败，但不再取得新 scope 的凭据。hard expiry 和 clock failure 继续阻止新 Run、cold restore 及其他新的执行接纳；本次不增加对 Core 每个请求的 Account 拦截器，也不承诺在 Account 无法刷新时已有 Run 永远可继续。

不增加 Renderer token 路径、新设置、刷新按钮、数据库迁移、checkpoint 格式、Bridge command 或新公开 Run cause。不升级依赖、不修改 bundle lock、verifier、allowlist 或仓库 Gate。

## 3 Owner 和数据路径

```text
Account 成功提交刷新
  → Application 取得同一次当前 scope 证明和 owned lease
  → Product Control 按实际执行来源和 scope 选择消费者
      → Task 经 retained Session Access 调用 Agent.updateCredential
      → Task 发布新的 Host 凭据快照，供独立请求读取
      → Run 图片执行发布同 scope 的图片凭据快照
  → Application 继续既有 Models catalog refresh
```

Account 仍独占 OAuth、refresh、principal、scope、authorization generation 和凭据持久化。它不知道 Task、Session 或图片消费者。Account 与 Models 不互相 import。

Application 在现有 Account commit observer 路径中组合调用：先向 Product Control 交付执行续期，再处理 catalog job 的 cancel/join 和刷新。通过独立、窄的 Product-owned renewal port 注入此能力，不让 Models aggregate 持有 Task，不把它并入通用 Models management facade。

Product Control 决定哪个已有执行可接收凭据；Task 持有执行及其 Host 凭据生命周期；Agent 独占 Core API、handle 和并发调用。worker 只取得独立存活的 credential reader，不持有 Account、Models coordinator、Product Control 或 Task aggregate 指针。

主会话凭据与图片凭据必须分别登记：主模型为 Custom Provider 时，GenerateImage 仍可能使用 Metask；不能仅筛选 Metask 主会话而漏掉这类 Run，也不能把 Account token 写入 Custom Provider 主会话、审批或标题请求。

## 4 配置版本与凭据版本

复用 Account 已有的两个值，不再建立第三套授权版本：

- `scope` 表示连续授权。同一登录下刷新保持 scope；退出或重新登录结束它。
- `authorization_generation` 表示 Account 当前凭据代次。收到的 generation 必须等于当次 Account proof，installed 相等则跳过；不靠数值大于判断新旧，因此重复通知幂等、陈旧通知不能覆盖当前代次，也不自行假设永久递增。

Task attachment 增加进程内已安装凭据代次。图片执行在 preparation 时额外保存自己的 scope 和已安装代次；当前 `OwnedImageExecution` 尚未保存这两项，必须由 Application 从本次 Account 证明补入，不能从主 Task、目录 generation 或 model id 推断。

`execution_generation` 继续标识已接纳的执行绑定；凭据续期成为该绑定的显式例外，不再承诺同一 binding 终身使用相同 secret bytes。纯 token 更新不推进 durable binding epoch，不改写历史 Run 的 generation、模型、协议或意图 revision，也不触发历史 adoption transaction。旧历史不具有当前授权效力。

Models 的 `source_generation` 和 catalog CAS 含义保持不变。它仍可因 credential 轮换推进。以下步骤仅适用于已有 attachment 上的新 Run 接纳，不适用于 Account 刷新后主动给已有执行续期。新 Run 仍核验当前目录、membership、来源和 Account generation，不能仅因 `source_generation` 变化就重建，也不能无条件忽略变化：

1. 先通过当前 Account scope 和 catalog admission 校验。
2. 比较实际 provider reference、protocol、endpoint、模型及需要安装的能力输入。
3. 仅有 credential／其来源代次变化时，安装当前凭据并更新进程内来源证明；其余变化走原事务。
4. 模型从目录移除、目录失效或 authority 不满足时，仍拒绝新的执行，不能因已有 Session 可续 token 就放行。

已有执行的主动续期只检查当前 Account proof、原 scope、实际执行来源和消费者生命周期，不调用 Models catalog admission gate。此时目录仍可能绑定旧 generation 或正在刷新；它的拒绝不能反向阻断本次凭据交付。

已有 Run 的续期按实际 installed execution 选择消费者，不按下一轮 model intent 或全局默认选择。用户在 Metask Run 中选了下一轮 Custom Provider 时，当前 Run 仍可续 Metask token；反向场景不得把 Metask token 交给当前 Custom Provider。

## 5 主会话更新协议

新增 Agent-owned `Session.updateCredential` 包装，并通过 [Task Session gateway](../../src/product/task/agent_session.zig) 的 retained `Access` 暴露。接口名称以现有命名规范落地；不将 raw Core handle 或 SDK 类型传入 Product。

每个消费者按以下顺序更新，不建立跨所有 Task 的分布式事务：

1. 主线程读取当前 Account proof 和 lease，确认 scope、generation 匹配；Account 暂不可用时关闭续期资格，不读取旧 catalog token 补齐。
2. 确认消费者仍属于原 scope、实际来源为 Metask、未进入关闭或销毁；检查目标代次未被安装或处理。
3. 预分配新的不可变凭据快照和必要的脱敏保留项，校验容量和 Core 输入。所有可能失败的准备都在 Core 调用前完成。
4. 先将新 token 登记到既有 projection/history 安全流程，失效旧安全代次的缓存和待写候选，确保后续输出已能识别它。沿用现有异步清洗和 purge 屏障，不把“已登记”表述为磁盘清理完成，也不等待全库清理才调用 Core。
5. 取得 retained Session Access。Agent 在状态锁内登记此次外部调用，再释放状态锁调用官方 API；完成后重新持锁收口。close 必须等待更新调用和 Access 释放。不得持有可能被 callback 使用的状态锁跨 Core 调用，也不得等 Run 结束才换 token。
6. Core 返回 `OK` 后，以不分配、不会失败的交换安装 Host 当前快照与代次。这是该消费者的续期成功提交点；之后开始的独立请求取得新快照。
7. 失败时不安装 Host 新版本，不回滚 Account，不用旧 token 静默继续新的执行。按第 9 节收口；为安全登记的新 token 按既有保留规则清理。

Product 正常路径仅由主线程串行提交更新，不设置后台重试队列，不在每个生命周期 tick 重试同一失败代次。Agent 包装仍需防护与 Run、abort、close 和 shutdown 的并发；Core 的线性化不替代 Product 的代次检查。

Account proof 已表明存在新代次，但 owned lease 分配失败时，不得沿用当前 coordinator 的 `catch return` 静默结束。Application 以不含 secret 的失败结果通知 Product Control，由它阻止受影响消费者继续接纳，并按第 9 节收口；这与正常 logout 或授权暂不可用的处理分开，不能把资源失败伪装成用户退出。

`idle`、`queued`、`running`、`waiting_ui` 支持原位更新。手动 Compact 从 `compact_queued` 到执行完成及独立 `checkpointing` 期间先记录非 secret 的待同步需求，在安全边界重新读取当前 lease；避免 queued Compact worker 与更新竞争进入 Core。不根据“可与 Run 重叠”推断官方接口已承诺与所有其他 Core 操作重叠。Run 内的自动压缩仍属于官方 Run 更新合同。

成功更新不改变活动 Run id、UI request id、additional-input adoption count、工具 receipt、Session disposition、权限或 skill/MCP grants。

## 6 Host 凭据快照和独立请求

在 Task owner 内增加一个内聚的执行凭据模块，负责不可变 token 快照、当前快照交换、reader 生命周期和脱敏保留。它服务于已有实际消费者，不建立通用 credential broker、Provider registry 或跨进程协议。

每个可续期的已接纳执行持有窄 reader。reader 只允许取得当前凭据的有界 owned copy，或借用受引用保护的不可变快照；不访问 Account，也不发现模型或 endpoint。主线程是唯一写入者。reader 与快照可独立存活到 worker 和 callback 静止，交换不改写任何已有读者正在使用的 buffer。

### 6.1 自动审批

保持现有 `prepareNextPermissionReview → startPermissionReview → Completion.init → spawn` 结构。这些步骤在同一次主线程调用中完成，Account observer 无法插入其中；没有空槽时直接转人工，不存在 prepared review 等候派发的队列。

第 5 节安装成功后，attachment 的当前凭据视图即是新版本。`preparePermissionReview` 从该视图复制本次执行配置，随后仍在主线程创建 Completion、取得 cancellation handle 并立即启动 job。保持现有 job ownership、deadline、取消和 join 协议，不把 Completion 创建移入 worker，也不给审批新增 reader 或取消交接状态。

准备已完成并启动的审批属于已有独立请求，即使线程稍后才得到调度，也继续持有本次不可变副本；之后发生刷新不替换它。审批保留原 request／policy／delegation identity；轮换不额外执行一次评审，失败仍转人工，不重试或自动允许。

### 6.2 自动标题

标题 target 仍取自原 Run，但删除 Run preparation 时即克隆 token、直到主 Run 结束才消费的 Metask 路径。Run job 保留冻结 target 与 credential reader，在现有 `generateAutomaticTitle` 中读取当前快照，然后调用已有 `Completion.init`。Custom Provider 继续使用其原 owned credential，不借用 Account token。

标题 Completion 仍在原 worker 位置创建，沿用现有取消检查、watchdog 和请求 deadline，不引入新的 cancellation handle 发布状态机。失败只结束本次标题尝试并保留原临时标题，不使主 Run 失败。

对标题和图片的 MetaWork-owned 单次 HTTP 请求，凭据快照点是正式执行该请求、构造 Completion／图片 header 之前；已经派发、正在 DNS／连接／HTTP 的请求保留原副本。此边界不冒充 Core 更细的“等待连接时仍可换 token”保证。Completion 内部保持不可变，不增加 Account 感知或刷新逻辑。

### 6.3 生图

Run preparation 仍冻结图片 target、model、output capability、调用额度和是否可用。只有其中的 credential 改为本 Run 专属 reader，沿用其最初接纳的 Metask scope。

Agent 的图片 callback 在每次有效调用准备 HTTP 时取得本次快照。Application 不在 callback 中调用 Account 或主线程 aggregate；reader 的窄接口是唯一跨 owner 输入，不向 Agent 交付 Product scope/generation。执行副本保持到该次 I/O 和 output 静止。

Account 通知独立更新 Run 图片 reader；即使主模型是 Custom Provider，图片仍可正常续期。最初 unavailable 的图片配置始终 unavailable，刷新不授予新工具能力。模型目录刷新、切换和 logout 不改变已冻结的图片 target，不以新的默认图片模型替换它。

不能取得安全副本时返回现有图片失败类别；未发请求记为 unavailable 或 capacity，已发请求按真实结果收口。禁止因 401、403、轮换或取消自动重发生图，保留费用与结果未知的现有语义。图片续期失败可以关闭后续图片派发，不必把成功的 Custom Provider 主 Run 伪造成失败。

## 7 旧凭据退役与保留成本

### 7.1 撤回按刷新次数终止 Run 的设计

撤回上一版“一个 Run 累计保留全部版本，达到 64 份后终止”的方案及为它增加的 2048 项／8 MiB 进程额度。它会把长时间审批等待变成必然失败，且使 history commit 的已知凭据扫描随刷新次数增长。提高额度不能解决这个问题。

不再承诺活动 operation 的保留量与刷新次数无关。锁定 ABI 下，一个长期不返回的 operation 可以跨过任意多次轮换，Host 没有可证明的更早退役点。每份 token 沿用 4096 字节上限；保留量按实际字节和引用 metadata 核算，随尚未收口的 operation 经历的不同 token 数线性增长。不能以一个人为的轮换总次数限额终止 Run，也不能隐藏真实 allocation failure 或丢弃仍有职责的副本。

### 7.2 hard expiry 不能单独决定脱敏退役

Account 的 `expires_at` 决定该 token 能否用于新的授权接纳，不证明已发出的请求已经结束、携密事件已经 drain 或历史维护完成。反例是请求用 A 发出后阻塞，A 过期并刷新为 B，此时才返回包含 A 的错误正文或诊断；按到期时间移除 A 会漏掉清洗。工具结果、已保留 payload 和未知写入结果也可能晚于授权到期才被处理。

因此 `expires_at` 可以作为后续执行有效性校验的信息，不能作为唯一的脱敏删除条件。现有 [Product 安全合同](../product-architecture.md)按已知凭据、owned 生命周期和清洗责任判断释放，没有“已过期即可公开”的例外。

“每个来源最多两份 token”也尚无依据：Account 固定提前 60 秒刷新，服务端允许更短的 TTL，短 TTL 下可能在旧 token 到期前再次刷新；重新发起授权和延迟完成的旧请求也不能用固定两份概括。

### 7.3 锁定 ABI 内的退役条件

区分当前可执行快照、实际请求持有的副本，以及保护未消费输出和持久化维护的脱敏保留项。`updateCredential OK`、`usage`、`retry_notice`、`output_segment_*` 和 `waiting_ui` 都不能证明某个旧 token 已经没有在飞使用。采用现有 operation 返回和 Host drain，不再寻找 ABI 未承诺的请求级边界，也不将实施挂在 Core 扩展需求上。

旧 token 被替换时，登记当时所有实际安装过该值的消费者及其正在进行的 operation。以下三项同时满足后才退役：

1. 相关 Core Run／Compact 全部返回，且各自的 canonical event drain barrier 已完成；不能因某个 Session 先完成就清掉另一 Session 仍需要的同值副本。
2. Host 持有旧副本的审批、标题和图片请求全部结束并 join，其结果已进入所属 owner 的安全交付流程。尚未开始的标题／图片只读当前 reader，不固定占用旧版本。
3. 旧值涉及的产品文本、保留 payload、未知写入结果以及既有 history／WAL／迁移源维护已按原协议清洗和确认；释放前完成最后一次清洗。

空闲 Session 替换旧值且不存在未完成的前一 operation／drain 时，不新增 Core operation 保留职责，只等待真实 Host 请求和维护责任结束。新 operation 只登记它可能使用的当前值及之后安装的版本，不继承已经退役的全部历史。快照替换与 operation admission／terminal 观察在既有主线程和 Session lifetime 下排序，不能遗漏替换时已经开始的 operation。

保留项的所有权挂在 operation 或独立请求上；相同字节可以共享不可变存储和引用，不能共享或延长授权 scope。operation 收口后及时移除其引用，维护尚未完成时由既有维护 owner 保留必要副本。上述三项关闭的是旧版本的保留职责；若其他 Session、Models 或其他合法 owner 仍把同值作为当前凭据持有，仍不能清零其存储或从已知检查移除。当前 source reader 只保留当前可执行版本，不成为会话所有历史 token 的永久仓库。

### 7.4 所有权局部不等于清洗范围局部

不采纳“旧 token 只可能出现在安装过它的 Session 输出中，所以不进入全局已知检查”的假设。其他 Task 可以接收用户输入、读取共享文件或获得外部工具内容；这些内容的字节不受原 Session 身份约束。现有 [Product 安全合同](../product-architecture.md)要求新构建投影继续检查所有 live credential。

因此保留项可以由 operation 拥有，但在责任结束前仍须向 Product 已有的全局 credential visitor 和安全检查可见。不能从 `visitExecutionCredentials`、文件预览、其他 Task 的 projection 或 history 完整性验证中排除它们来获得性能结果，也不修改或弱化 verifier。首次获知和最终释放仍完成原有跨对象清洗。

撤回“全局扫描成本不随轮换次数增长”的无条件验收承诺。当前 `containsKnownHistoryCredential` 对每个已知值分别检查全量候选；保留 K 个旧值时，它的成本可能随 K 增长。必须记录实际 K、保留字节、候选大小、history commit 及主线程连续时间，遵守原有执行隔离 Gate。若实测超预算，需在保持完整匹配语义的前提下另行收口实现，不能通过缩小安全范围、跳过验证或放宽预算通过。

worker 的凭据视图必须稳定，覆盖跨 chunk、UTF-8、JSON 解码和未决后缀。purge 或迁移源清洗失败继续保留必要副本和未完成状态；重复借用或相同字节刷新不重复进行全库维护。

### 7.5 现有 128 项容量仍需适配

除了撤回的方案额度，当前 `Product Control.syncHistoryCredentials` 的临时收集数组和 `Application history_store.Store.credentials` 各有 128 项容量。保留多代旧值而不处理它们，会使长等待仍可能触发 `complete = false` 或 `credential_capacity_failed`，不能声称删除 64 项规则就已解决容量问题。

统一采用按真实保留量增长的内部容器。Product Control 在同步调用期间只收集借用的稳定 slice，以动态 pointer index 去重，收集分配失败仍传递 `complete = false`。Application history store 为每份凭据单独分配稳定 owned 节点，动态 index 只移动指针，不通过 realloc 搬运 secret buffer；节点保存既有 retained、SQL、legacy 和 memory 维护标记，职责解除后清零再释放。

节点或 index 分配失败必须保持维护未完成，不截断集合或把不完整集合标为 complete，不遗忘未完成清洗。4096 字节单凭据限制、现有 verifier 和拒绝结果均保留。这是内部表示修改，不改变数据库格式或 Core，也不引入新的固定轮换总次数限额。扫描成本继续按第 7.4 节实测验收。

## 8 接纳与生命周期竞态

| 边界 | 实施要求 |
| --- | --- |
| Account 通知丢失或重复 | 新执行接纳仍读取当次 proof；发现 installed generation 不匹配就同步一次。重复成功通知无额外 Core 调用；失败不被轮询自动重试 |
| 新 Run 和排队输入 | 先通过当前 Account 和目录 gate，再确保凭据已安装；纯 token 更新不改 binding epoch、不重锚排队输入、不重复消费已采用输入 |
| 尚未采用的 additional input | 原 Run 可继续接收；确需下个 Run 时复用既有续跑状态机，去掉仅为换 token 建立的恢复步骤，取消不复活 |
| 当前模型意图已切换 | 当前 Run 续其实际来源的凭据；下一轮仍按已提交意图解析完整配置 |
| detached Task | 不为了通知而创建 Session 或把它纳入长期 token 缓存；显式恢复前读取当前 lease，同进程 scope 连续性仍有效 |
| restore candidate 在 worker 期间遇到刷新 | 保留现有恢复接纳校验；过时的 scope 或执行配置拒绝发布并走原关闭流程，不给 candidate 热更新凭据。后续显式恢复重新取得当前配置 |
| history adoption 已提交或 outcome unknown | 先完成原 canonical 事务的确认，不改写未知候选或重放 effect；token-only 不新增历史事务，候选发布前仍重验当前授权 |
| Task close/delete/archive | 先关闭 renewal admission；已取得 Access 和 reader 的调用完整静止后才释放。旧 route 的更新结果不得作用于新 attachment |
| 手动 Compact 或 checkpoint | 执行中的非 Run Core 操作按第 5 节推迟更新，记录非 secret 待同步需求，边界后自主推进，不依赖其他 Task 发消息唤醒 |
| logout、重新登录、账号替换 | 封闭原 scope 的续期写入，保留已接纳执行必要的旧副本；新 scope 无法复活旧 reader 或 Task |
| shutdown | Account observer 停止后拒绝新更新；join 更新调用、Run／review／title／image worker 和 close owner，再释放 credential reader 和 Agent Runtime |

同一 Account generation 更新多个消费者时允许逐个成功。一个 Session 已关闭或失败，不阻止其他消费者安装；不回滚成功 Session 到旧 token。无需扫描历史 Run 正文来查找更新目标，复用当前 live attachment／operation 的路由和既有容量边界。

## 9 失败处理与诊断

| 结果 | 控制动作和对外结果 |
| --- | --- |
| 重复或已失效通知 | 不调用 Core、不写凭据、不改变历史；当前未完成的更早尝试不能覆盖新代次 |
| closing、detached、shutdown 或消费者 route 已变 | 拒绝本次交付并释放准备项；不把正常关闭误记为新的 provider failure |
| 输入非法、预分配失败、脱敏容量不足、Core 明确拒绝 | 不提交新 Host 代次；关闭本执行新的派发／admission。活动主 Run 请求既有受控终止，idle attachment 保持不可执行，等待显式操作收口或重试 |
| Core 返回未知 status、`BUSY` 或不符合合同的状态 | Agent 标记 dependency contract failure，按现有 poisoned／close 路径收口，不降级到旧凭据或 checkpoint 换 token |
| 单独的审批／标题／图片快照失败 | 审批转人工、标题保留临时值、图片返回既有 unavailable／capacity；不重试、不自动批准或额外收费 |
| 新 token 已安装后远端返回 401／403／5xx | 按原请求失败分类收口；不据此删除 Account 凭据、重新登录、换模型或重跑整个 Run |

给现有 Agent termination latch 增加内部 typed 凭据更新失败信号，不借用 `user_cancel`、event failure 或 provider failure 伪造原因。Product 映射到已有 `agent_failure`、`resource_limit` 或 `dependency_contract_failure`，并在现有安全 diagnostic 中使用固定短码和用户可读说明。仅此内部信号不新增公开枚举、持久字段或 wire shape。

终态继续由既有 first-writer-wins 终止信号、真实 worker terminal 和 event drain barrier 共同收口；已完成的 Run 不倒改为失败，与用户取消、正常完成竞争时不额外产生第二个 terminal。终止是请求，不能声称已撤销刚刚发出的 HTTP 或已完成工具。Core 更新失败后无法保证“再没有一个旧请求发出”，应如实保留停机窗口内的真实结果和副作用。

不对同一失败通知自动循环尝试。用户下一次明确发送或恢复时，可以在当次有效授权和完整 admission 下进行一次新的准备；真正的 machine guard/Gate 拒绝仍为强制结果，不得以该重试机制绕过。

## 10 修改位置和合同收口

| 范围 | 修改内容 |
| --- | --- |
| `src/app.zig`、`src/app/models_coordinator.zig` | commit observer 接入窄 renewal port；先续已有执行，再处理目录工作；图片 preparation 绑定独立 scope／generation |
| `src/product/control/ports.zig`、`src/product/control/runtime.zig` | 区分 Account-only 续期资格与 Account＋Models 的新执行 gate；选择实际消费者、结果收口及 admission preflight |
| `src/product/task/` | 内聚的凭据快照／reader 模块；attachment 已安装代次、Run 图片代次、多版本脱敏、续跑和恢复接线 |
| `src/agent/session.zig`、`src/agent/session/control.zig` | 包装官方更新，复用 reference／quiescence，内部 typed failure 与关闭竞争 |
| `src/product/task/agent_session.zig` | 通过唯一 retained Access gateway 转交更新，不提供旁路 |
| `src/product/task/runtime.zig`、`src/product/task/execution.zig` | 审批从已续期 attachment 克隆本次凭据；标题读取 reader，删除提前克隆 token 的路径。保持 `permission_job.zig` 的创建、取消和 join 结构 |
| `src/agent/image_generation.zig` 与 Session 图片 callback | 冻结 target，按每次调用读取 token；不可变请求副本及清零 |
| `tests/agent/`、`tests/product/`、`tests/integration/` | 按下节失败模式分层验证，不以 synthetic Core 替代真实 Core 请求行为 |

实施时，以下真源分别承担自己的合同，不在多处复制字段、容量或路径清单：

- [Product 架构](../product-architecture.md)：续期资格、配置／凭据边界、目录独立性、Task／Run／恢复事务和脱敏生命周期。删除仅为 token 轮换必须重建 Session 的规则。
- [AgentCore 集成契约](../agentcore-integration.md)：更新包装、并发／close、已发送请求语义和图片输入生命周期。清理与当前行为冲突的 credential 稳定借用描述。
- [Completion 架构](../completion-architecture.md)：独立请求保持冻结 target；审批在原主线程准备点取得当前凭据，标题在原 worker 执行点读取凭据，Completion 内仍不可变；不加入 Account owner 或刷新逻辑。
- [Account 架构](../account-architecture.md)：在现有 handoff 章节说明 Application 可将有效 lease 用于已接纳执行的同 scope 续期，保留 OAuth 持久化与 logout owner。
- [验证规范](../validation.md)：登记新的在飞轮换验证责任与真实 Core 入口，修正被替代的旧期望；普通测试数量和实现路径仍由测试／构建拥有。

仅在发现已有产品需求明确承诺整个 Run 的凭据不可变时，定向修改该条并链接 Product 真源；本方案不需要新增交互或 UI 设计合同。保持 public API、持久数据、Bridge payload、ABI 接受政策和 dependency artifact 不变；若实现发现必须改变其中任一项，先列出具体变化与兼容影响，不擅自扩大本计划。

## 11 回归与验收

### 11.1 最小充分测试矩阵

| 测试层 | 必须观察的结果 |
| --- | --- |
| 凭据模块 inline tests | 快照交换与 reader 并发、字节去重、版本隔离、分配失败零交付、最后引用清零；安全退役与预算用例须随第 7 节闭合，worker 不借用 aggregate |
| Agent fake ABI | 状态和 status 穷举、非法字节、关闭／abort／shutdown 引用、未知 status 和不允许的 BUSY fail closed、Core OK 后 Host 无失败提交 |
| 真实 canonical Core＋本地 HTTP fixture | A 请求先发出并阻塞，更新 B 后释放 A；A 保持原凭据，下一轮请求、工具后的请求及 Core retry 使用 B；同一 Session 不中断且工具只执行一次 |
| 真实 Core 的连接等待与重试 | 用可控连接槽、服务端 barrier 和可重试响应建立等待／重试窗口，在正式 transport／服务端核对实际合成凭据；无法可靠建立该窗口时记录未完成，不以 Host 构造请求时间推定网络发送时刻或将该项记为通过 |
| Account／Application／Models／Task 组合 | 真实 Account refresh 提交驱动更新；catalog 阻塞、失败、空目录、移除当前 intent 时已有 Run 仍续期，新 admission 分别按原 gate 拒绝 |
| idle、queued、追加输入 | 纯轮换 Session create／restore／close 次数不增加；model intent 与 binding epoch 不变；排队或未采用输入精确执行一次，取消不复活 |
| scope 隔离 | 同账号重新登录、换账号、logout 后拒绝旧执行续期；Custom Provider 主执行不接收 Account token，Custom 主模型的 Metask 图片 reader 仍独立更新 |
| 自动审批 | attachment 更新后 prepare 使用新 token；已 prepare／spawn 的评审遇到后续刷新保持原副本和 identity，取消、deadline、无空槽转人工均保持现有结构 |
| 自动标题 | 长 Run 后标题派发用最新 token；失败保留临时标题；结束后结果仍按当前完整凭据集合清洗 |
| 生图 | 同 Run 两次显式调用之间刷新，前一请求不重发、后一用新 token；原 unavailable 不变可用，target 不变，费用和 output receipt 语义不变 |
| 恢复与关闭 | candidate 返回、adoption pending／unknown、scope 替换、route 替换、手动 Compact、Task 删除及 shutdown 竞争均无悬空引用、过期发布或重复终态 |
| 脱敏与持久化 | A/B/C token 分散在工具、标题、诊断、JSON、跨 chunk／UTF-8、历史候选、文件预览和 diff 中均不泄漏；旧 token 只有在第 7 节确定的观察和清洗责任全部闭合后才退役，purge 失败不报 ready，重复借用无重复全库维护 |
| 长等待与安全退役 | 审批等待跨大量轮换后仍按原操作继续；保留字节按实际轮换数增长并在三项退役条件全部满足后释放；A 到期后的晚到响应、未 drain 事件和 retained history 仍清洗。记录全局扫描与主线程成本，不宣称其与轮换次数无关 |
| 跨对象清洗与既有容量 | 将 A 放入另一 Custom Provider Task 的合成输入／工具结果和文件预览仍须清洗；覆盖超过既有 128 项后的完整传递、维护、释放及真实分配失败，不将不完整集合标为 complete |
| 更新失败 | 每类准备／Core 失败可控注入；新代次不误报 installed，其他消费者不回滚，主 Run 真实收口，既有副作用和成功 source Run 保留 |

时间推进使用 Account 既有可控时钟，审批／HTTP 使用 barrier，不靠等待 14 小时或任意 sleep 制造成功。fake ABI 只证明 Host 状态控制；真实 Core fixture 必须经过正式 Agent wrapper、Product Task、Application 更新通知及生产 HTTP transport，不能只写一个直调 SDK probe 代替产品接线。

测试 fixture 的 Authorization 只在进程内比较合成值。输出仅记录请求序号、代次标签、工具次数和分类，不保存 header 或真实 token。

### 11.2 标准验证入口

复用现有构建和 test graph，必要时向当前 root 增加用例，不建立长期独立 probe 作为成功入口：

```text
node scripts/verify-staged-agentcore-bundle.mjs
zig build test-agent-lifecycle
zig build test-lifecycle
zig build test-task-model-selection
zig build test-account
zig build test-image-run-preparation
zig build test-completion
zig build test-permission-review
zig build test-permission-review-http
node --test scripts/architecture-boundaries.test.mjs
native test . --yes
git diff --check
```

运行时按当前平台和标准脚本解析 canonical bundle，不手写替代依赖路径。定向测试用于开发反馈，最终正式 Native graph 验证新增模块依赖和共享 owner。缺少 staged bundle 明确失败。纯方案文档本轮只检查链接、残留引用和 diff，不运行以上 runtime tests。

在当前 Windows 平台的正式桌面 automation 增加审批等待期间多次刷新、批准后继续、Custom 主模型的 Metask 生图、idle 下一轮与关闭场景，使用隔离 profile 和合成网络。核心同步逻辑不机械扩展四平台矩阵；macOS 的锁屏／唤醒、系统定时器和真实服务样本属于独立平台证据，需要相应平台实测，不能由 Windows 或可控时钟测试代替。

真实 Metask 验收在已有授权的开发／隔离测试入口中进行；不得为本方案自动读取、改写或作废真实凭据。通过跨自然刷新和审批继续取得请求、回复和副作用证据后，才能报告真实服务场景通过。

## 12 实施顺序和完成条件

| 阶段 | 交付内容 | 阶段完成条件 |
| --- | --- | --- |
| 前置 | 按第 7 节三项条件确定保留生命周期；两处容量采用动态 index 和稳定 owned 节点，保留全局清洗语义 | 无需 Core 新语义；超过 128 项和分配失败回归通过。接受保留量随未收口 operation 的轮换数增长，扫描成本以实测和现有 Gate 验收 |
| 一 | 前置项通过后，随实现更新相关合同；凭据快照、安全退役及持久化接线；Agent wrapper 与 retained Access；接通一个真实 Metask 主会话刷新链路 | 一个活动 Run 跨 A→B→C 后继续原 Session，真实 Core 的后续请求用新 token，所有版本均安全清洗，工具无重放，失败和关闭回归通过 |
| 二 | 替换 idle／queued／追加输入的 token-only 恢复路径；恢复候选沿用原接纳校验；目录与凭据 gate 分离 | 纯 token 轮换不再 create／close／restore；新执行仍受目录、scope 和 hard-expiry gate 约束 |
| 三 | 审批保持原结构并克隆已续期快照；标题和图片在执行时读 reader；补齐 Custom 主模型图片 scope，接入阶段一的安全生命周期 | 三条独立请求路径和 A/B/C 脱敏测试通过，取消／shutdown／资源失败无泄漏 |
| 四 | 全部关联 roots、正式 Native graph、architecture guard、当前平台桌面和必要的真实服务验收 | 移除过时 active path 和旧测试期望，结果与未验证平台边界明确，文档与实现一致 |

每阶段保持原功能可运行，新增控制能力随实际消费者接线。中间提交不以 feature flag 或失败 fallback 永久保留两条 token 续期路径；阶段二完成后删除仅为换 token 的 checkpoint 恢复分支，保留仍负责真正配置变化和能力恢复的事务。

整体验收要求：主 Run、自动审批、标题和生图均不再因准备时的旧 token 而错过已成功安装的续期；纯轮换不重建 Session、不重放工具、不改用户模型选择；scope 隔离、关闭、失败和脱敏仍成立。Issue 3 的历史结论不重写；Issue 62 只有在其新旧任务不可用、目录恢复和审批继续的完整现象通过后才具备关闭依据，其他残留原因单独记录。

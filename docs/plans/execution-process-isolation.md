# 执行进程隔离实施方案

日期：2026-11-17。关联：[MetaWork #197](https://github.com/metask-ai/metawork/issues/197)。

状态：方案待评审。方向不是开放问题：[高层架构](../architecture.md)第 5 节已把单 AgentCore Worker 定为已选择的正式方向，并要求正式 Worker 独立定义 versioned transport、capacity/backpressure、ownership、correlation、credential、disconnect、Run cause 与 shutdown。本文逐项定清这八项，并划出一期边界。

本文是实施方案，不是 decision record，不替代现行规范。`docs/plans/` 是临时文档，最终会被移除，所以凡属于契约的结论必须同时落进耐久文档；这一点写进第 9 节的完成条件，不是可选的收尾动作。方案通过不表示代码、性能或平台验收通过。

本文不复用任何 spike 的帧格式、握手或代码。延迟探针是测量工具，它的框架不是协议，也不证明 Worker 已实现。

## 1. 目标与范围

问题是进程拓扑：AgentCore 静态链接进桌面 Host，各 Task 的 Session 由进程内 Executor 工作线程执行、共享同一地址空间，因此 AgentCore 执行或回调路径上的进程级致命故障带走整个 Host 和其中全部正在运行的 Task。

本轮目标是把 AgentCore 的执行搬进一个独立进程，使两侧的进程级致命故障各自收口，并且不把 Product 的事实权威、持久化权威或终态判定一起搬走。

一期交付的用户可见收益必须如实陈述：**它不修掉 2026-11-16 那次真实事故的损失。** 那次故障发生在 UI 侧的 toast 激活路径，拆分后 UI 侧 fatal 依然中断全部 Task；一期换来的只是「崩了还是全断，但不丢上次 checkpoint 之后的增量，重启从断点续」。真正消除损失的是 AgentCore 侧 fatal 不再带走 UI 这半边，而该方向目前没有现场发生率数据（见[验证规范](../validation.md)未闭合缺口表）。把一期说成解决了 #197 的用户损失是错的。

不在本轮范围：每 active Session 一个 Worker；active Run 的跨进程 in-flight recovery；Session 迁移；工具重放或自动续跑；修改 AgentCore、SDK 或 canonical bundle；向 AgentCore 仓库提任何请求；解析或改写 checkpoint 字节。

## 2. 真源与改动入口

缝画在 **Product ↔ Agent 这道缝，不是 ABI**。决定缝只能画在这里的结构事实：`src/agent/session.zig` 的 `runText`/`runMultimodal` 是阻塞式 ABI 调用，Run 结束才返回，所以每个在飞 Run 占一个线程，而那个线程必须与 Runtime 同进程。`host_worker_count = 16`（`src/app.zig:116`）、`worker_stack_bytes = 4 MiB`（`src/product/control/executor.zig:36`）的池子因此整体属于执行侧；`src/product/task/execution.zig` 的 `executeRun` 与其 agent handoff 状态机两端都在执行侧，不跨界。

前置重构已经落地（PR #211），一期不必再做：`src/agent/contract.zig` 是 archive-free 的契约模块根，`src/agent/session/surface.zig` 是纯数据声明，`src/agent/session/port.zig` 是 vtable 端口、`port_impl.zig` 是唯一的进程内实现。`src/product/` 整目录已无 `metawork_agent` 导入，Product 经 `metawork_agent_contract` 与 port 面访问 Agent。

但 port 面**不是**边界的全部调用面，本文先前那句「换掉 `port_impl.zig` 这一组 vtable 就是边界的全部调用面」是错的，实施第 3 步时核出来的。除 port 的 52 个方法之外，Product 还在进程内**直接调用 Agent 自有 opaque 句柄上的方法**，这些调用一条都不经过 `port.zig`：

| 句柄 | Product 直接调用的方法 | 调用点 |
| --- | --- | --- |
| `McpActivation` | `serverHealth` 12、`catalogServers` 8、`catalogGeneration` 8、`catalogAgeMs` 6、`catalogTools` 4、`takeSelection` 3、`catalogIssues`、`deinit` | `mcp/{runtime,state,view,refresh_job}.zig`、`task/runtime.zig` |
| `McpSelection` | `selectedTools` 13、`deinit` | 同上 |
| `McpRestoreSelection` | `isEmpty` 5、`clone`、`deinit` | 同上 |

合计约 59 处。它们全部是 MCP 形状的，所以归第 4 步；但第 4 步因此不只是「重建 transport owner」，还包括把这三个类型在 Product 侧的表达从 opaque 句柄换成数据投影。

方向上这不应该变成 59 个新 RPC：这些读取的都是句柄创建后不再变化的数据，所以正确的形状是**投影随 activation/selection 过界一次，UI 侧本地回答这些读取**，与 `catalog.Projection` 过界的处理同构。`takeSelection` 与各 `deinit` 是例外，它们改变 exec 侧状态，必须成为 port 调用。该方向待评审，本文不先按它改步骤划分。

| 入口 | 本轮角色 |
| --- | --- |
| `src/main.zig` / `src/app.zig` | 在进入 Native SDK runner、建窗口之前按模式分叉；exec 模式不得进入 `runWithOptions` |
| `src/agent/session/port.zig` | 跨进程实现要满足的既有方法集与错误集；本轮不改语义 |
| `src/agent/session/port_impl.zig` | 保留为 exec 侧的进程内实现 |
| 新增 exec 侧 vtable 实现 | UI 侧的转发 stub，填同一组 `RuntimePort` / `SessionPort` / `RunPort` / `RunControl` |
| `src/agent/event_pump.zig` | 容量与背压语义不变，限额仍由 UI 侧 pump 执行 |
| `src/app/fault.zig` | `Role` 增加 exec 值与其自己的 install 调用、自己的标记锚 |
| `src/product/task/checkpoint_store.zig`、`persistence.zig` | staged 导出的接纳路径与 orphan 引用集 |

## 3. 责任与结构约束

| Owner | 责任 |
| --- | --- |
| UI 进程 Product | 产品事实、Task/Run 状态机、持久化与恢复权威、投影；在飞 Run 终态判定；staged 导出的接纳决定 |
| UI 进程 Application | 启动与关闭 exec、链路健康、事件读取线程与出站写线程、UI 侧故障记录 |
| exec 进程 Agent | AgentCore Runtime/Session/Conversation/callback、host 工具、MCP transport、GenerateImage/Video、checkpoint 导出与恢复的字节读写、自动标题 Completion |
| exec 进程 Application | 自己的平台 capability 组合、exec 侧故障记录、UI 不可达后的收口 |
| Bridge / Renderer | 不感知拆分；不新增命令面，不新增状态 |
| Storage | 不取得跨进程职责；SQL 合同不变 |

结构约束：

- exec 不取得持久化 authority。它可以写自己拥有的 staging 区，但 Task 行的提交权仍在 Product owner；无人接纳的字节按[高层架构](../architecture.md) §3.7 只是待分类证据。
- exec 是同一个产品、同一个二进制、同一份签名的可信组件，不是新的敌对安全主体。但链路与 Bridge 同级：严格解码、ownership 与 identity 到达时重新校验、malformed fail closed。
- Workspace trust 由 UI 断言、exec 消费。exec 不能自行建立 trust，也不能把收到的路径当成已验证的 Product authority。
- 不把产品投影搬到 exec 再送增量过来，那会把 `applyEvent` 的产品状态机劈成两半。
- 不把 `decodeCoreEvent` 挪到 UI 主线程。
- 不新增第二套事件模型、第二套 cause 域、SQL 列、触发器或迁移。

## 4. 八项关注点

### 4.1 versioned transport

同一个 exe 带模式参数，不做两个可执行文件：ABI 常量、`core_manifest_sha256`、帧协议因此物理上同源，安装器与 macOS 签名链零改动，净体积增量只有协议与分叉代码。

但同源不等于不需要握手。两种偏斜真实存在：升级后旧 exec 仍在运行而新 UI 启动；同一数据目录被两个安装共用（0.2.3 已发生过一次同数据目录事故）。因此附着时必须握手，字段为 exec transport revision、产品 version、`core_manifest_sha256`、AgentCore ABI version/revision。任一不符一律拒绝附着并退出，不协商、不降级、不以旧 revision 继续——与第 1 节既有的 AgentCore 消费规则同义。exec transport revision 是独立的合同标识，不从产品 release version 或 ABI revision 推导，变更须按[高层架构](../architecture.md)第 7 节先取得用户明确同意。

帧：`u32 length | u8 kind | payload`，kind 区分 event、request、response、ui_request、ui_response、control。request/response 带调用相关 id（见 4.4）。超过 64 KiB 的 payload 分片，使一个 control 帧最多排在一个分片之后。

错误域必须是 typed 的。`surface.Error` 是 71 项的封闭集合且是契约的一部分，跨进程后它必须有显式的 wire 映射；加上 port 的 `Allocating` 带来的 `OutOfMemory` 共 72 个码。对端给出未登记的码时 fail closed 为契约违约，**不得**退化成一个通用失败码——那会让 Product 把链路问题记成 Agent 终态原因。映射的完整性不靠人工维护的表保证：方法与错误两张注册表都在编译期双向闭合，少一项不编译。

### 4.2 capacity / backpressure

既有容量机制不变，也不新增：事件单条上限 `MAX_RUN_INPUT_IMAGE_DATA_BYTES_V1 + 64 KiB`，队列 global 512 条 / 32 MiB、per-session 128 条 / 8 MiB，以及 control 预留额度，全部仍由 UI 侧 `EventPump` 执行。

背压沿管道自然传导，方向正确：UI 的 pump 满 → reader 不读 → 管道满 → exec 的写方阻塞，而写方就是 Core 回调线程。这与今天 `enqueueWaiting` 阻塞 Core 回调线程是同一语义——Run 被拖慢，事件不丢。

出站方向有一条硬约束：**UI 主线程绝不做阻塞管道写。** 主线程要守[验证规范](../validation.md)的投影预算，而管道缓冲满时的阻塞写是唯一能直接打穿该预算的写法。出站走有界队列加专用 writer 线程，并且：control 与终止类帧取预留额度，保证 Stop 不被大帧挡住；非 control 的主线程调用在队列满时返回 typed busy，映射到 Product 既有的接纳与重试状态（凭据续期已有 `deferred` 与重试状态机），**不得**把容量压力伪造成用户 timeout、用户拒绝或 Agent terminal cause。

parked UI 请求的并发上限是 16（`max_pending_ui_requests = host_worker_count`），不是更小的数；收口设计要按 16 个同时 park 的 Core 回调线程来算。

自动审批复核的并发上限 `permission_job.capacity = 8` 随复核一同搬到执行侧，不得在搬家时蒸发。它与上面那 16 是两件事：16 是可以同时 park 的请求数，8 是其中能同时跑复核的数，所以 auto 模式下仍可能有 park 的请求在等复核槽位。

事件与终态共用同一条有序数据队列，这不是实现细节而是一条必须保住的不变量：`event` 帧与承载 Run 终态的 `response` 都走数据队列，只有不分片的 `control` 帧可以在分片之间插入，所以**一个 Run 的终态不可能先于它自己的事件到达**。正是这一条让读取方可以把「我的 pump 里这条 route 没有待处理事件」读成「该终态所属 Run 的全部事件都已到达」。把终态挪到 control、或者开第二条数据通道，都会无声地破坏它——读取方只会看到更少的事件并据此认为流已完整。

### 4.3 ownership

`src/agent/**` 连同它提供给 AgentCore 的活对象整体属于 exec；`src/product/**`、`src/bridge`、`src/storage`、Renderer 留在 UI。下列是含函数指针的活对象，不可能序列化，必须跟 Runtime 一起走：

| 活对象 | 跨进程后的归属 |
| --- | --- |
| Runtime 初始化的 `mcp_input`（`*McpRuntimeInput`，内含每 server 的 `*TransportOwner`） | 参数本身不过界。UI 只送配置 generation 与 server 声明，exec 侧自建 transport owner；启动顺序因此是 UI 读配置 → 送 exec → exec 建 Runtime |
| MCP transport owner | exec 侧需要进程 spawn、Windows Job 对象、HTTP 栈与 MCP 凭据/OAuth。MCP 帧绝不回传 UI |
| GenerateImage / GenerateVideo | exec 侧要 HTTP、输出目录与凭据副本；产物以路径进事件信封 |
| DeliverFile 交付根 | exec 侧要同一个根 |
| checkpoint sink / source | 字节回调，exec 直接读写文件；字节不过界 |
| credential source | exec 侧自持副本，密钥因此过界（见 4.5） |
| catalog lease | lease 留 exec，投影过界。`catalog.Projection` 的内容是扁平数据，但结构体本身带着 `storage: *anyopaque`（它自己的 arena），所以过界的是去掉该字段后的那些字段，不是结构体原样 |
| 终态与 compact 终态 | `TerminalResult` 与 `CompactTerminalResult` 不是纯数据：它们持 `allocator` 与 `diagnostic_storage`，是自己那份诊断字节的 owner。过界的是诊断字节与 receipts 本身，所有权留在产生它的一侧 |
| `rg.exe` | 跟 exec 走；它本来就随包分发并由 Core spawn |

UI 侧保留的，一条都不交出去：Product 持久化与恢复权威、Task/Run 状态机、投影构建、Bridge 命令面，以及 checkpoint 记录向 Task 行的提交。

### 4.4 correlation

必须分清三个身份空间，不能合并：

1. **调用相关 id**，逐次调用，只用于匹配 response 与释放等待，不持久化、不进产品语义。
2. **route id**，Runtime 在进程内分配的 session id（`next_session_id`），exec 侧权威，不持久化。本轮不改。
3. **Product 指定的 session/run 关联身份**，由 UI 在 Session 创建与恢复时给出，exec 持有至 Session 结束。

第三项是新增的，而且**一期必须真正携带它，不是只预留字段**。理由是一期自己的成立条件：exec 在 UI 已死时 staged 的 checkpoint 记录要能被接纳，记录就得完整，而 `state.CheckpointExportContext` 要求 `task_id`、`binding_epoch`、terminal anchor、`last_run_id`、`last_compact_id` 与 model——其中 Product 侧那几项只能由 UI 事先给出。所以最小内容是 `task_id` 与 `binding_epoch`，加上 Run 粒度的 Run id。二期增加的是活体清单查询与重新绑定，不是这个身份本身。

不能用既有的 `checkpoint_logical_session_id` 代替：它由 AgentCore 指定、只随 checkpoint 存在（没 checkpoint 的 Task 恰恰是在飞 Run 要紧的那个）、不标识 Run，还会把 Product 的 Task 身份反向绑到 AgentCore 指定的值上。

故障记录侧的关联已经就位：breadcrumb 条目本身带 `task_id` 与 `run_id`，这正是[高层架构](../architecture.md)第 5 节所说「Run 行只需与记录可关联」。拆分后 exec 要装自己的 breadcrumb 环，因为 AgentCore fatal 时在执行的 Run 只有 exec 知道。

### 4.5 credential

凭据会经链路过界，exec 进程里也会有明文副本：Metask token（Run 本身、compaction、自动标题、自动审批的复核）、生图/生视频 binding、MCP static/client secret 与 OAuth 结果、Custom Provider key。按已定决定，自动标题、自动审批复核与图像、视频 HTTP 都留执行侧，所以这些凭据的持有者数量不增加，只是换了进程。把复核留在 UI 侧会让 UI 进程仅为一个用途持有一份 Metask 凭据，并凭空多出一个续期点——#175 那个缺口正是「每个模型入口各自负责续期」长出来的。复核另有两条独立理由：它运行期间有一个 Core 回调线程 parked，留 UI 侧会让 UI 的存活成为 Run 推进的前提；而 auto 模式下 UI 不可达时按 4.6 解除 parked 请求，会连带解除一批本来不需要人的请求，违背用户选 auto 的本意。设计稿「不碰 AgentCore」那条理由不转移：它回答的是要不要扩 AgentCore 的 permission 协议，对落在进程边界哪一侧不构成理由。

两个持有者今天的凭据处理并不对称，搬家时不得把弱的那一份带过去：自动标题走 `.copy()` 加 `defer credential.deinit()`，是第 6 节要求的 bounded copy；复核直接透传 `config.api_key`，生命周期挂在 `prepared` 上。

**交付根过界之后是边界输入,必须在执行侧重新校验。** 进程内声明该 root 的就是确认过它的那一方,所以「canonical」是事实;过界之后它只是对端断言的一个字符串,而第 6 节明确 trusted Workspace 只能由 Host 原生选择和确认产生、且 Host 要重新校验路径与资源范围。所以执行侧不得把收到的 root 当成已经可信,须按写路径既有的约束(在 root 之下解析,而不是信任名字)重新校验。这与上面那条脱敏顺序是同一形状:**一个在进程内免费的性质,过界后必须被明说**,否则它会在搬家时静默消失。

**复核的脱敏必须留在过界之前、由持有该数据的 Product 一侧完成。** 复核输入含工具参数与用户历史，今天 `scrubPermissionArguments` 先跑、再建 Completion，顺序是对的；搬到执行侧后这个顺序必须保持，否则未脱敏的用户历史跨进程。这是本次移动**新造出来**的要求，不是既有约束。

要求：

- 通道只用子进程继承的匿名管道，exec **不开任何 socket、不开命名管道**，本机其他用户没有可连的端点。
- 密钥不走 `argv`、不走环境变量。
- `execution_credential.Source` 的 `secureZero` 语义在 exec 侧照搬；跨界缓冲在释放时清零。
- 链路是[高层架构](../architecture.md)第 6 节「secret 不得进入 event、snapshot、日志、raw diagnostic、产品历史、checkpoint record 或持久化 metadata」的一个新载体：带凭据的帧不记日志、不进 trace、不进诊断计数之外的任何输出。
- exec 侧要组合 Foundation HTTP，因为自动标题是 run job 线程上的 Host 侧 Completion 调用，不是 Core 调用。
- 续期在忙时仍返回 `deferred`，UI 侧既有重试状态机不变。

### 4.6 disconnect

检测两侧各用既有信号，不发明新的心跳：exec 侧看父进程句柄 signaled、stdin EOF 与写帧失败；UI 侧 `EventReadyNotification.unavailable` 本来就是「消费者不可用」，拆分后由链路健康提供同一个值，`requestWake` 的既有语义不变。

UI 不可达时 exec 的一期收口顺序是固定的，顺序本身是正确性要求：

1. 停止接纳新 Run 与新 Session。
2. **先解除全部 parked UI 请求**，按 ABI 既有的 UI 不可用返回路径（`UI_UNAVAILABLE`，必要时 `UI_FATAL`）。这一步必须在前：park 着的 Core 回调线程不解除，它的 Run 到不了终态，后面的导出就无法进行。解除方式不得实现成给人类 decision wait 设置 deadline——那违反第 4 节既有规则。
3. 对在飞 Run 发终止，复用 `app_shutdown` 既有形状。
4. 导出 checkpoint 并 stage（见 4.7 与第 5 节）。
5. 干净退出，并写自己的退出标记。

无 UI 超过宽限期即自我收口退出，避免孤儿进程。

断连后「排空观察」不能被读成「已完整观察」。`EventDrainStatus.pending(route_id)` 返回 0 时，Product 会把该 Run 的事件流判为完整并收口（`settleTerminalOutputAfterEventDrain` 与 `finalizeMarkedTerminalRunsAfterEventDrain` 都以 `!= 0` 跳过）。这个读法只对**来自 exec 的终态**成立，依据正是 4.2 的顺序不变量。但 `markTerminalRunsBeforeEventDrain` 只要 Run 有终态负载就打标记，不问终态由谁写下，所以凡是 Product 在**本地**写下的终态——begin-run 失败、本地契约失败，以及一期新增的「exec 不可达」——`pending() == 0` 对 exec 尚未发出的事件什么都没说。单进程里这无害，因为 pump 就是唯一的缓冲；拆开后管道与 exec 的出站队列是第二个缓冲，字节可以丢在那里。

因此一期的规则是：**链路断开时，UI 侧为受影响的在飞 Run 记录事件交付缺口，而不是记录一次干净排空。** 不新增词汇，既有的就够：`terminal.event_delivery_lost` 经 `recordEventProjectionFailure` 表达，也就是架构既有的「记录完整性与执行结果是不同事实」。`EventDrainStatus` 因此要能分辨「已排空」与「链路已断」，不能只返回一个 `usize`；这项改动属于第 6 步，而不是 transport 那一步——在「exec 不可达」这个本地终态存在之前，第二个缓冲并不存在。

Windows Job 的归属有两个方向，而且它们相反，写错任何一边都是静默的。**不得把 exec 挂在 UI 的 Windows Job 上**（`KILL_ON_JOB_CLOSE`，MCP 子进程在用的那种）：那等于对称死亡，2026-11-16 那次事故照样带走全部 Task，方案收益只剩一半。**同时 exec 必须成为 MCP 子进程 Job 的所有者**，MCP 才会随 exec 一同收口；今天 `Job.init` 由发起连接的那一侧创建、`deinit` 关闭唯一引用从而终止整棵树，所以这件事随 transport owner 搬到 exec 而自动成立——前提是句柄确实由 exec 持有，不是由 UI 创建后传过去。

这两条都不会在功能测试里暴露：挂错了 MCP 照常工作、Run 照常跑完，只有真崩的时候才显出 exec 被 UI 的 Job 带走。所以它需要自己的验收场景，而不是靠实现时记得。

exec 死亡时 UI 侧：令牌桶重启，5 分钟窗口内至多 3 次，超限进入稳定的「执行不可用」态——历史可看、可导出，不能跑新 Run——而不是崩溃重启循环。该阈值是产品选择，没有频率数据支撑，#197 自己也没有。在飞 Run 的恢复复用既有的 `restoreTaskConversation` 从 checkpoint 重建，不发明 Session 迁移，也**不得**把这条既有的 checkpoint recovery 报告成 in-flight Run 或 Worker crash recovery。

### 4.7 Run cause

不新增 `RunCause` 值，`cause` 域不动。理由有三：进程级致命故障的事实来源是故障记录而不是 Run 行；一期 UI 不可达时的终止复用 `app_shutdown` 的既有形状；而新增一个值会把本线与 #177 上未决的 `RunCause` 迁移 scope 绑死，迁移对发版有真实成本。

需要讲清的是 UI 已死时 Run 行由谁写：没有人写。exec 无法提交任何产品行，所以该 Run 的终态由下次启动的既有恢复判定给出（持久化中非终态即 interrupted）。这不是缺陷，而是权威划分的结果；记录负责说明那次是致命故障、故障地址属于哪一侧、当时在执行哪些 Run，Run 行只需与之可关联。

链路容量压力同样不得变成 Run cause（见 4.2）。

### 4.8 shutdown

正常退出仍由 UI 发起，既有的 Application 关闭顺序（Control executor 停止、Runtime shutdown、lifecycle 同步）保持不变，只在其间插入跨进程一步：UI 发关闭 → exec 停接纳、终止并等待 Run、按今天的路径导出 checkpoint（字节流回 UI，由 UI 提交记录）→ exec 退出 → UI 回收并清理自己的标记。exec 内部仍走 `Runtime.shutdown` 与 `session.close(.app_shutdown)`。

强杀只作为宽限期之后的兜底，不作为正常路径。

故障标记需要一处具体改动：今天的启动/退出标记落在单实例租约上，而租约只有 UI 持有。exec 因此需要自己的标记锚——一份由 exec 拥有、以 UI 的 pid 与进程启动时间为键的租约文件，使「exec 上次退出不干净」同样成为事实而不是推断。配套地 `fault.Role` 增加 exec 值与其自己的 install 调用。

## 5. 一期边界与一期必须预留项

一期在内：模式分叉与进程启动关闭；versioned transport 与握手；Runtime 及其活对象整体搬迁；UI 侧转发 vtable；事件流与背压；parked 请求解除；UI 不可达的下行收口；staged 导出及其接纳；exec 侧故障记录与标记；Product 指定的关联身份的携带。

一期不做、留给二期：exec 不退而等 UI 重启接管；UI 启动时先向 exec 查活体清单再决定重新绑定（而不是按持久化非终态判定）；向新 UI 重投 pending UI 请求（`copyPendingUiRequest` 现成，不得静默丢弃）；每 active Session 一个 Worker。

一期必须预留或携带的东西只有一类，就是落在 **Session 创建与恢复协议**上的那些字段：Product 指定的关联身份（按 4.4，一期即须携带）、以及二期活体清单应答所需的字段位。不预留则二期要重开协议。

staged 导出的接纳路径必须具体，这是一期最容易做成「看起来对」的地方：

- stage 区在 checkpoint FileStore 之外、由 exec 拥有，内容是 blob 加一份自描述的待接纳记录（`task_id`、`binding_epoch`、generation、byte_size、digest、`logical_session_id`、`last_run_id`、`last_compact_id`、model、terminal anchor）。
- 不得直接写进 FileStore 的 task 目录。`cleanupOrphans` 的引用集由内存中 Task 行的 `durable.checkpoint` 构成，没有行指向的 blob 会被删掉——直接 stage 进去等于把证据交给清理逻辑。
- 接纳由 Product owner 在下次启动、读入 Task 行之后、orphan 清理之前执行。插入点是确定的：`restoreTaskState` 之后、`reconcileCheckpointStoreNoFail` 之前，也在 `recoverInterruptedNoFail` 之前，因为被接纳的 checkpoint 会改变该 Task 的续跑起点。校验 digest 与 identity，与该 Task 当前 checkpoint 比较 generation 与 terminal anchor，接纳则按正常提交路径写入并把 blob 纳入 FileStore，拒绝则保留为证据并明确记录，不静默丢弃也不自动修复。
- 拒绝或接纳失败不得阻塞启动，也不得使 Task 不可用。

## 6. 分阶段

| 步骤 | 工作与完成条件 |
| --- | --- |
| 1 | 模式分叉与进程生命周期：exec 模式在建窗口前分出，UI 能启动、关闭、回收 exec；握手字段齐备且不符即拒绝。此步不搬 Runtime，Agent 仍在 UI 侧，用于单独验证分叉与握手 |
| 2 | transport：帧、分片、typed 错误映射、调用相关 id、出站有界队列与 writer 线程、control 预留额度。以既有 port 方法集逐一对照，不得出现无映射的方法或错误 |
| 3 | Runtime 与活对象搬迁（不含 MCP）：欠 wire shape 的载荷逐项落形状、exec 侧句柄表、UI 侧转发 vtable 填满 `RuntimePort`/`SessionPort`/`RunPort`/`RunControl` 的 52 个方法、exec 侧 dispatcher，以及生图/生视频/交付根/checkpoint sink 落位。**完成判据是注册表由编译器判定闭合，不是「某个件数做完」**：`crossings.zig` 的 `owed()` 归零、每条记录与编译器一致、每个 mirror 都经 `requireStructural` 接受，`method.zig` 的 52 个转发全部填满。手数出来的 16 是**下界而不是总数**——读 port 枚举不出边界已经两次了（句柄方法 59→68；`CallbackRejection` 的 `?anyerror`，而且它的注释还写着「只含固定枚举和计数」），剩下的项里再挖出新的属于正常，不是计划出错。报告按「闭合了没有」报，不按「做了几项」报 |
| 4 | MCP 搬迁：UI 只送配置 generation 与 server 声明，exec 侧自建 `McpRuntimeInput` 与 transport owner，进程 spawn、Windows Job 归属、HTTP 栈与 OAuth 都在 exec 侧组合。完成条件含 4.6 的 Job 归属两个方向，以及第 7 节那条真杀 UI 之后 exec 与 MCP 子进程都还活着的验收 |
| 5 | 关联身份：Session 创建与恢复协议带上 Product 指定身份；exec 侧持有至 Session 结束；二期字段位留出 |
| 6 | disconnect 下行收口：按 4.6 的五步顺序实现，parked 解除先于终止；exec 孤儿自我收口；`EventDrainStatus` 分辨「已排空」与「链路已断」 |
| 7 | staged 导出与接纳：按第 5 节实现 stage 区、自描述记录与启动接纳，并确认 orphan 清理不吃掉待接纳条目 |
| 8 | exec 侧故障记录：`Role` 增加 exec、自己的 install 与标记锚；两半各写各的记录 |
| 9 | 契约同步与证据：按第 8 节改耐久文档，按第 7 节取得验收结果，报告完成 |

各步同步修改实际变化的规范和测试，不保留平行 active path，不发布只搬了进程而未实现收口的中间状态。

## 7. 验证与预期结果

| 场景 | 必须观察的结果 |
| --- | --- |
| 握手字段任一不符 | 明确拒绝附着并退出，不降级、不以旧 revision 继续；UI 侧呈现执行不可用而非伪造 Run 失败 |
| 正常 Run 全链路 | 事件顺序、终态、回执、权限审批与今天逐项一致；Renderer 与 Bridge 无感知变化 |
| UI pump 饱和 | 背压传到 exec 的 Core 回调线程，Run 变慢、事件不丢；无 Host fatal、无 Session poison |
| 真杀 UI 进程后的 Job 归属 | exec 与它的 MCP 子进程都还活着，走完 4.6 的收口顺序后自行退出；两者都没有被 UI 的 Job 带走。功能通过不构成证据，判据是真杀之后谁还在 |
| 链路在飞 Run 中途断开 | 受影响的 Run 不被判为事件流完整：要么没有终态因而不打排空标记，要么本地终态同时带事件交付缺口。`pending() == 0` 本身不构成「已完整观察」 |
| 终态与事件的到达顺序 | 同一 Run 的全部事件先于其终态被读取方看到；只有 control 帧可以提前。该不变量有专门的回归，不靠人读代码保证 |
| 出站队列饱和时 Stop | control 预留额度放行，Stop 不被大帧挡住；非 control 调用返回 typed busy 并走既有重试，不产生用户 timeout 或 Agent terminal cause |
| 主线程预算 | 拆分后仍满足[验证规范](../validation.md)的投影预算；主线程无阻塞管道写，用真实链路而非 fixture 计时 |
| 16 个 Run 同时 park 于 UI 请求，UI 随后消失 | 全部 parked 请求按 ABI 既有不可用路径解除，16 个 Core 回调线程全部释放，无一常驻；解除不是超时 |
| exec 导出了但 UI 已死 | 杀掉 UI 进程（不杀 exec）且 Run 在飞：exec 完成解除、终止、导出、stage 后自行干净退出；stage 区有完整自描述记录；下次启动接纳成功，Task 从断点续，增量不丢 |
| 同一场景下的 orphan 清理 | 待接纳条目在接纳之前不被 `cleanupOrphans` 删除；接纳后纳入 FileStore 并被引用集覆盖 |
| staged 记录损坏或与当前 Task 行冲突 | 明确拒绝并保留为证据，启动不被阻塞，Task 仍可用，不自动修复、不静默丢弃 |
| AgentCore 侧致命故障 | UI 存活，其余 Task 继续；exec 侧记录存在且归因到 AgentCore 模块区间，breadcrumb 给出当时在执行的 Run；UI 侧按既有恢复路径处理，不报告为 in-flight Run recovery |
| UI 侧致命故障 | UI 侧记录存在且标明由 UI 写出；exec 走 4.6 收口；下次启动「上次退出不干净」只提示一次 |
| exec 连续死亡 | 令牌桶生效，超限进入稳定的执行不可用态，历史可看可导出；无崩溃重启循环 |
| 凭据过界与续期 | exec 无 socket、无命名管道端点；密钥不在 `argv`、不在环境变量、不在任何日志与 trace；忙时 `deferred` 与既有重试不变；Run、compaction、自动标题、生图各自用到更新后的值 |
| MCP 与 host 工具 | MCP 子进程由 exec spawn 并随 exec 收口，MCP 帧不回传 UI；生图/生视频产物以路径进信封；DeliverFile 回执不丢不重 |
| 正常退出 | 既有关闭顺序不变，checkpoint 按今天路径由 UI 提交；exec 不被强杀；两半的退出标记都被清理 |

按失败模式选择 Agent、Product 与必要 integration 测试；跨进程场景属于 probe/platform acceptance，须用真实 exec 子进程，不能以同进程 fixture 替代。「UI 已死而 exec 存活」的场景必须真杀 UI 进程，不得用模拟不可达替代，因为被验证的恰好是进程消失后的收口。平台矩阵与标准入口遵循[验证规范](../validation.md)。

## 8. 合同同步

| 真源 | 对应变化 |
| --- | --- |
| [高层架构](../architecture.md) | 故障域表的架构地位更新；八项的结论；exec transport revision 作为独立合同标识；exec 不取得持久化 authority |
| [AgentCore 集成契约](../agentcore-integration.md) | 跨进程后的生命周期、线程、callback、背压、UI 请求解除与 shutdown 顺序 |
| [Product 架构](../product-architecture.md) | Session 创建与恢复协议的关联身份；staged 导出的接纳事务；执行不可用态 |
| [产品需求](../requirements.md) | 执行不可用、从断点续与「增量不丢但 Task 仍中断」的用户可观察语义 |
| [验证规范](../validation.md) | 两个故障方向的验收条款与证据状态；跨进程场景的测试归属 |
| [工程结构与所有权](../project-structure.md) | 模式分叉入口与 exec 侧模块归属 |
| [Windows 分发](../windows-distribution.md)、[macOS 分发](../macos-distribution.md) | 仅在确认同一个 exe 方案对打包签名零改动后记录该事实；若结论变化须重新评审 |

不修改 AGENTS.md、Storage 合同、SQL、迁移清单、`RunCause` 枚举域、ABI 或依赖 lock。若发现必须改变这些边界，先给出具体必要性并重新评审，不以实施方便扩大范围。

## 9. 最终验收

一期完成须同时满足：

- 第 6 节九个步骤各自的完成条件达成，无平行 active path。
- 第 7 节的场景全部取得结果，其中跨进程与真杀 UI 的场景有绑定日期、revision、平台、artifact 与入口的证据。
- 八项关注点在[高层架构](../architecture.md)中各有结论，而不是只在本文里。
- **属于契约的结论已全部进入第 8 节所列耐久文档。** 本文是临时文档，最终会被移除；移除前若有结论只存在于本文，视为未完成。
- 一期的用户可见范围如实记录：UI 侧 fatal 仍中断全部 Task，收益限于不丢增量与断点续跑；AgentCore 侧 fatal 的隔离收益尚无现场发生率证据。不得以一期完成宣称 #197 的用户损失已消除。
- `docs/plans/execution-process-isolation.md` 与本轮产生的 `docs/evidence/` 临时条目在收口时移除。

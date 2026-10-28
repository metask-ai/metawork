# MCP 生命周期与可用性一致性方案

日期：2026-10-27；最近修订：2026-10-28。状态：根据 REQUEST CHANGES 修订，尚未实施产品修改。

本方案从 MCP 的完整架构确定 #18、#26、#29 的修复边界，沿用现有 Product、Agent、Application、Task 和 Renderer owner。它是本轮实施方案，不是 decision record，也不替代现行规范；拟议的用户行为或跨 owner 合同调整，须在对应实现切片中同步更新唯一真源。

## 1. 结论与目标

推荐以 **共享 Runtime 目录的有效期管理、不打断有效授权的主动刷新和真实状态投影** 为主线。优先消费当前 canonical AgentCore，不预设升级依赖、重建 Session 或修改 MCP 模块结构。

目标是：

1. 服务完成正式连接和工具授权后，新 Task 在目录仍有效时实际取得对应工具；后台刷新不造成周期性准入中断；真实到期、目录撤回或配置应用失败时，页面准确说明当前能力。
2. 同一 Task 跨过目录 TTL 后，通过正式目录刷新继续使用原先选择的工具；一次性批准仍只覆盖本次调用，后续合法调用继续询问。
3. 配置候选被整体拒绝、目录刷新失败、单个服务不可达、工具未授权分别呈现，不能相互冒充。
4. 刷新不扩大既有 Task 的工具集合，不改用户审批模式，不重放已开始的 Run 或工具，也不依赖页面读取推进执行。

本轮不承诺让包含新故障服务的配置绕过 Core 原子 apply，也不扩大 OAuth、transport、平台、持久化或 ABI 的支持范围。

## 2. 依据与证据边界

| 项目 | 已取得的结果 | 仍需验证的内容 |
| --- | --- | --- |
| #18 | 原 0.2.7、原 canonical bundle、2025 STDIO，显示工具可供新 Task 使用后等待 31 秒，创建结果变为 `unavailable` | 原 Task18/19 的准确触发原因，以及修复后真实桌面跨 TTL 的正向调用 |
| #29 | 有效期内连续调用逐次审批；目录过期后，历史工具名调用没有新 callback，返回 `permission_denied`，没有新增 RPC | 原 Task52 的完整时间线；刷新、schema/source 变化和权限连续性的联合行为 |
| #26 | 正式 declarative apply 会拒绝包含新不可达服务的完整候选；先安装健康配置再拒绝混合候选，Core 仍保留原健康配置 | 冷启动及配置变更的真实 Product/Renderer 呈现；不能仅凭 Core 保留旧配置就开放新 Task |
| 原 Session 延续 | 正式 interop 用例验证：目录过期后调用 `Runtime.activateMcp`，随后原 Session 的相同工具重新实际执行并再次询问批准；未调用 Selection replacement，也未导出/恢复 Conversation | 新增工具、schema/source 变化、会话 allow/deny 的负向测试 |
| 刷新期间的 ABI 准入 | 当前 canonical bundle 上，固定原 selectors 和原 checkpoint，在刷新前、服务 `tools/list` 被屏障挂起期间、刷新完成后，直接通过官方 SDK 创建与恢复均成功，工具数保持 1；目录 generation 确实更新 | Host 去除错误屏障后的 Product 创建、detached restore、模型 rebind 与发布交接竞争 |
| 单服务失败的发布 | 同一 ABI 用例注入 `tools/list` 错误，Core 仍发布新目录；新建返回 `invalid_mcp_selection`，恢复成功但工具收缩为 0 | 全局 refresh 失败且未发布新目录的保留路径，以及多服务的局部健康投影 |

当前 canonical Core 的实现是：Session 保留原 selectors 与预期 schema identity，每个 Run 从当前 Runtime catalog materialize 一个独立 view。因此，**共享目录刷新可以服务既有 Session，Host 不需要向旧 Session 安装最新全局 Selection**。这个结论只覆盖来源和工具语义仍匹配的刷新，不证明连接替换后的来源隔离。

可复核前提由 [正式 interop 源码](../../tests/agent/mcp_interop_test.zig)拥有，入口为 `zig build test-mcp-interop --summary all`。本轮 canonical identity、用例名称、命令与结果保存在[评审验证证据](../evidence/mcp-refresh-admission-20261027.json)，不依赖被忽略的缓存目录。历史发行版复现只作为问题线索，不代替当前回归。

ABI 的 `McpSelectionV1` 只有 selectors，没有 Host generation 字段。因此上表证明的是**原 selectors 在刷新期间及之后仍可被 Core 接受**，不是 Core 接受任意旧 Host generation。Host 仍须验证 Selection 的 owner、已发布 authority、配置/来源和 deadline，Core 的实际拒绝仍是强制结果。本地 fixture 不替代原 macOS 26.6.2、真实模型、HTTP/OAuth 服务或发行包验收。

## 3. 现行合同与职责

实施依据为 [Product MCP authority](../product-architecture.md#25-mcp-authority)、[AgentCore 消费合同](../agentcore-integration.md)、[MCP 产品行为](../requirements.md#510-mcp-服务)、[MCP UI](../ui-design.md#54-mcp-服务)、[Renderer Bridge](../renderer-bridge-contract.md)及[验证规范](../validation.md)。

| 事实 / 工作 | 唯一负责边界 | 本轮处理 |
| --- | --- | --- |
| Desired Registry、connection approval、credential locator、允许的工具 | Product MCP | 保持现有事务与持久化，不为刷新修改配置或推进 desired generation |
| 正式配置是否接管及 Runtime Manifest | Product MCP；Application 执行 apply 协调 | 只根据官方 apply 结果提交，拒绝和未知结果不能成为 loaded proof |
| Catalog、Activation、官方刷新及 Selection | Agent；Core 拥有协议和 Run materialization | 把 freshness、generation 和有界健康事实准确交给 Product，不在 Host 解析第二套 MCP 协议 |
| 刷新调度、Admission Authority、失败恢复策略 | Product MCP | 一个共享刷新作业、一个串行化边界，统一检查有效期与异步结果身份 |
| 输入所有权、Run 准入与取消 | Product Task；Control 协调 MCP 依赖 | 保持现有输入推进；仅在 P1 后仍有复现时评估复用现有同步点，不预设新准备状态机 |
| Run 的工具集合与权限判断 | AgentCore | 使用原 Session selectors，从合法目录构造本 Run view；Host 不伪造 grant 或把 TTL 当作权限批准 |
| 页面状态和恢复动作 | Product projection → Bridge → Renderer | UI 只展示事实、提交明确动作，不运行刷新定时器或替 Host 决定任务能力 |

Task 创建时的 MCP authority fact 保持不可变。无 selection 创建的 Task 不因后来刷新自动取得工具；冷恢复仍遵循既有安全收缩合同。

## 4. 目录有效期与刷新

### 4.1 保存同一代观测

Product MCP 在现有运行态中保存每个正式 catalog server 的保守失效时点、目录 generation 和必要的刷新调度信息。它们由官方 `fresh` / `ttl_remaining_ms` 派生，只存在于进程内，不进入 registry、Task history 或 Renderer 的授权数据。

- TTL 从官方观测起算，不能从主线程接收 completion 的时间重新起算。
- Agent 在读取官方 descriptor 的边界记录 Host 单调时钟观测；如果不能取得足够精确的采样点，使用调用前时点作保守下界。不能用旧 enqueue 时间与新 completion 时间混算，或通过估计网络耗时延长有效期。
- completion 安装时重新比较当前时间；已过期的 Selection 不得发布为 ready。
- 单调时钟不可用、溢出或观测不完整时，不能证明 freshness 的能力不得标为可接纳。
- 多服务按各自有效期判定，已过期项不得继续支撑 `availableToNewTasks`。只从经正式校验的目录和 Selection 构造可用集合，不由 UI 或字符串列表重新编译权限。

### 4.2 主动刷新与到期处理

取消现有“剩余 TTL 不超过 30 秒就不安排主动刷新”的实现条件。保留一个 owner 定时器，调度最近的刷新、失效或允许重试时点。沿用当前提前量规则 `min(remainingTTL / 4, 5 秒)`，默认约 30 秒目录将在约 25 秒触发刷新；具体常量由代码拥有。

**作业正在刷新，不等于已发布的 authority 失效。**对来源、配置和授权未变化、且原 deadline 尚未到达的提前量刷新：

- Product enqueue/start 不调用 `blockAdmission(.refreshing)`；保留当前 Activation 和 Admission，不将 new Task access 改为 unavailable。
- Agent 不在 `beginMcpRefresh` 清空已发布 generation。刷新串行化状态与准入状态分开判断；`createMcpSelection`、admission copy、restore selection、create/restore route 都必须能消费仍有效的已发布 authority。
- 新目录在 Core 内原子发布，Agent completion 与 Product 安装之间也不得制造无依据的 generation 拒绝窗口。实现应围绕现有 Activation/Selection owner 完成有界交接，保留 provenance 校验，不接受任意历史 generation；必须用 completion 暂停点测试交接过程。Core 在此期间合法撤回原 Selection 时，按 §5.1 以 null Selection 创建普通 Task，不能要求已撤回的 MCP 仍可用。
- Product 的 `authorityStable` / restore authority 判断同样不能仅因纯后台刷新作业存在就否定仍有效的 authority。
- 新 Activation 安装时一次提交对应 Selection、generation、deadline 和健康事实；不能先清空旧状态再等待网络结果。
- 原 deadline 到达时立即收缩；不等刷新完成，也不把请求已开始当作新的 freshness。

到期、配置 apply、OAuth/reauth 或明确撤销仍按各自现行合同设屏障。纯主动刷新不能借用这些失效语义，刷新 completion 也不能恢复被其他事务撤销的 authority。

**失败要区分是否发生正式目录发布：**

- 只有官方结果能证明没有替换当前目录，且原配置/授权仍匹配时，才保留旧 authority 至其原 deadline。不能因请求失败提前作废，也不能延长。
- 单服务刷新错误可能是一次成功的目录发布，失败服务会从新目录移除。此时立即消费新目录的真实收缩；不得保留旧 Selection 冒充该服务仍获 Core 接受。本轮 ABI 反例已覆盖此情况。
- `.unavailable`、malformed、OOM 和未知结果不能一律解释为“未发布”。P0/实现测试须核对正式返回值与发布语义；无法证明旧目录仍可接纳时明确失败，不维护影子目录。

对极短 TTL，区分“到期使能力失效”和“允许再次执行网络刷新”：

- 网络刷新有最小间隔；不能形成毫秒级循环。到期仍及时收缩，短 TTL 可以明确不可用。
- 成功后按新观测重排；重复 timer 和请求只合并到一个共享作业。
- 失败后不立即自调用，不在输入推进中无限重试。重试策略须有最小间隔、退避和明确的暂停/恢复条件；不预设永久每 30 秒请求远端。具体数值在请求量与失败测试后由统一代码策略确定。
- 队列满、wake/arm 失败与网络失败分开处理。旧 authority 只在其原 deadline 内成立；无法安排工作时记录 typed 调度失败，查询不执行恢复。

### 4.3 restore 准入与状态投影

`restoreAdmissionAvailable` 当前把刷新和容量混成一个布尔结果，Control 随后可能进入 `sessionPressureError` 并释放无关 idle Session。将这类调用改为可区分的内部结果：可准入、真实容量不足、MCP 事务屏障、Runtime 不可用；具体类型由其 owner 定义。

- 有效 authority 上的后台刷新允许 detached restore 和模型 rebind 正常进行。
- 只有真实 Session 容量不足才进入既有容量回收路径；MCP busy/失效不能驱逐无关 Session，也不能报成 `SessionCapacity` / `SessionReleasing`。
- 到期或 apply/reauth 的实际屏障沿现有生命周期返回准确结果或复用已有等待点，不新增通用等待框架。审计全部布尔准入调用者，避免只修一个入口。
- UI 保留有效服务的健康与可用事实，后台刷新不让页面每约 25 秒闪成不可用/refreshing。显式刷新可显示操作进度；到期、正式目录收缩及实际失败才改变对应能力状态。

### 4.4 串行化与资源

apply、refresh、OAuth durable mutation 继续共享现有 MCP 串行化边界。refresh busy 时合并请求，保留 pending 原因；新配置取代旧请求后，迟到 completion 只释放自己的 owner。

刷新不占用主线程执行 IO，也不让 Run worker 阻塞等待同一 executor 内排队的刷新作业。实现先以单 worker、队列压力和权限等待场景验证现有执行接线；若证明现有共享执行容量不能满足推进，才在 Product Control 内给现有 MCP job 配置一个有界控制 lane，并同步其 shutdown 合同。该调整必须针对实际等待环，不以目录整理为理由。

## 5. 新 Task 与既有 Task 的执行路径

### 5.1 新 Task

创建入口在现有事务中确认 Admission 的 generation、有效期、配置和授权事实。页面读取不承担状态推进。

- 已发布 authority 有效时复制 Selection，得到 `ready(selected)` 或 `ready(none)`；同时存在纯后台刷新不改变此结果。
- 真实到期、配置未应用、Core 正式撤回或无法证明有效时，按现行合同创建普通 Task 并明确返回 `unavailable`，在允许的边界登记刷新。
- 无 Selection 创建的 Task 不在以后偷偷补工具，不自动重建，不改变创建事实。
- 页面是当前观测，真正创建结果是最终事实；真实失效或 Core 拒绝与点击之间的竞争必须准确呈现。

**创建时回退必须覆盖 Core 发布与 Product 安装之间的竞争。**后台刷新中的某个服务 `tools/list` 失败时，Core 可能已经发布收缩目录，Product 却仍持有原 Admission。原 Selection 此时会被 Core 合法拒绝；该拒绝只能使本次 Task 的 MCP 为 `unavailable`，不得使普通 Text Task 创建失败。处理方式遵循现行 [Task admission 合同](../product-architecture.md#25-mcp-authority)：

1. Agent 的 Session create 错误映射保留 `.invalid_mcp_selection → error.InvalidMcpSelection`，不再压成 `CoreCallFailed`；同时保留 `McpNotRefreshed` 和 Host generation/provenance 检查产生的 `StaleMcpSelection`。Core 拒绝必须是符合 ABI 的失败结果、且没有返回 live Session handle；未知 status、异常 handle 或其他合同异常仍返回 `CoreCallFailed`，不伪装为 MCP 可恢复拒绝。
2. Control 在带 Selection 的 Task 创建尝试收到 `McpNotRefreshed`、`InvalidMcpSelection` 或 `StaleMcpSelection` 时，走同一条有界回退：确认失败候选及预留资源已清理，将创建输入的 `mcp_selection` 置为 null、`mcp_authority` 置为 `unavailable`，沿现有 `openTask` 路径再创建一次。模型、Skill、审批模式和 Workspace 输入保持原值；只提交一个 Task，不留下失败候选、重复历史或容量占用。
3. 回退时让被拒绝的原 MCP Admission fail closed，并登记 authority 同步：优先消费在途刷新 completion，必要时沿现有单作业/owner timer 路径登记刷新；busy 时保留 pending，enqueue 失败也不向普通 Task 创建传播。不得为此等待网络、重新尝试旧 Selection，或伪造所有服务均不可达。
4. null Selection 的创建至多尝试一次，不形成重试循环。真实 Session 容量不足仍走既有容量处理；OOM、关闭、通用 `CoreCallFailed` 及 null 创建自身的错误按原语义返回，不扩大为任意错误的静默回退。此处是尚未成功创建的候选回退，不重放 Run、工具或已提交 Task；之后目录恢复也不为该 Task 补装 MCP。

### 5.2 既有 Task：先验证 P1，再决定残留处理

共享目录刷新已证明能服务原 Session，Core 每个 Run 使用 `run_tolerant` materialization，过期或失效工具会收缩。本轮不预设 per-Session facts API、来源 proof API、10 秒准备预算、每输入一次准备状态机、进入 Core 前的额外 freshness gate，或从 Run worker 交回 Task 的新路径。

P1 完成后先复测同一 Task 跨 TTL 连续调用。只有仍可复现“Run 到达时目录已过期”的残留窗口，才评估最小增量：

- 已有共享刷新进行中时，在提交 Run 前复用现有输入推进/刷新 completion 同步点观察该次结果；不得占住 Run worker 等同一 executor，也不得新增跨 owner 队列或另设固定 10 秒等待。
- 没有刷新时，在既有调度限制内登记一次请求；普通对话按 Core 的 tolerant 语义继续，并提供准确的 MCP 不可用诊断，不循环等待或重试。
- 准备后排队至真正执行之间跨过 deadline，也由 Core 收缩；不为低概率窗口引入输入退回路径。

上述处理是条件性候选，不是默认实施阶段；必须有 P1 后的失败样本、明确可复用同步点和独立验证收益才进入实现。若现有同步点不适用，先报告残留行为及成本，不恢复整套执行准备设计。

### 5.3 Session 和执行不变量

Session 原 selectors、Conversation 和审批模式保持不变。once 决策逐次询问，session grant 的适用性由 Core 判断。Host 不捕获 `permission_denied` 后刷新并重发工具；Core 已开始的 Run、工具调用、response 丢失和取消都不触发重放。

来源隔离的额外 Host 检查须等待 §6 资格 Gate 结果。不能在未证明缺口前同时增加 source proof、最终检查与输入回退三套机制。

## 6. 旧 Session 的能力上限与依赖资格

保持现行禁止热替换 Selection 的合同，不调用 `McpApi.updateSelection` 给旧 Session 安装当前全局工具。

| 变化 | 目标行为与验证要求 |
| --- | --- |
| 同来源、同工具语义，仅目录 generation 更新 | 原 Session 下一 Run 可继续调用；逻辑 Session、Conversation、审批模式和原 selectors 不变 |
| 新增全局服务或工具、扩大 allowlist | 旧 Session 不取得新增能力 |
| schema 或权限 binding 变化 | 接受 Core 的失效/收缩结果，不把旧 session grant 当作新工具授权 |
| endpoint、command/argv/cwd、namespace 或其他原来源 identity 改变 | 旧 Task 不得被静默导向新来源。先核对 `server_binding_identity`、Core provenance 与现有 Host 来源指纹各自覆盖范围；只对被证实的缺口提出最小 owner 修复，不预设新增来源 proof API |
| 停用、删除、撤销授权 | 新 Task 立即按已提交事实收缩；旧 Session 的后续工具行为遵循现行 Core 和产品合同，不追加即时撤权承诺 |
| 模型切换、同进程 restore、冷恢复 | 沿现有恢复输入与 ceiling；MCP 修复不得扩大恢复后的能力或重新获得 null 原选择 |

**实施前的依赖资格 Gate：**除已验证的同来源刷新外，必须用当前 canonical bundle 验证同 ID 替换来源、schema 变化和新增工具。当前源码的 Run materialization 会读取最新 catalog，不能据此推定来源隔离天然正确。

若官方表面不能保持所需边界，明确记录具体失败和最小上游修复要求，走 canonical release/lock 验证；不得修改 SDK、私有 Core 数据或 binding identity 生成规则绕过。Host 不以重建 Session、复制旧工具表或另建 Runtime 静默补救。该 Gate 未通过时不能关闭 #29 的完整验收。

## 7. 配置应用失败与服务状态

保留 Core 整体 apply 的原子接受语义，按不同结果分别处理：

| 正式事实 | Product 与 UI 的结果 |
| --- | --- |
| Desired 已保存，apply 进行中 | 保留用户配置；显示正在应用，新配置不成为 loaded proof |
| apply `rejected` / 明确失败 | `configurationApply=failed`，新 Task MCP 准入按现有 fail-closed 合同阻止；不把所有服务写成网络不可达 |
| apply 已接管，但首次 activation 失败 | Manifest 反映实际已接管内容；新配置没有可用 Admission，呈现整体目录/激活失败 |
| 既有配置的后台刷新失败 | 按 §4.2 区分未发布失败和新目录收缩，不一律清空仍有效的 authority |
| 正式 Activation 明确给出某服务 unavailable | 才能把该服务标成不可达；其他服务按各自正式观测呈现 |
| 只有旧配置或旧目录观测 | 仅在其来源与当前展示目标一致、且观测仍有效时展示对应健康事实；不得用旧 endpoint 的成功证明新 endpoint 已连接 |
| 没有该服务的正式观测 | 使用现有 `not_loaded` 等可表达状态，配合整体 apply failure；不伪造具体失败服务 |
| persistence outcome unknown | 沿既有 recovery_required / unknown 规则，不能把 last-known desired 当作 canonical |

优先使用现有 `configurationApply`、`runtimeAlignment`、`runtimeStatus`、`newTaskAccess`、`safeDiagnostic` 与 connection test 分层。`availability` 必须独立反映真实 Runtime/catalog 情况，不能通过把单项改成 `not_loaded` 意外得到全局 ready。

如现有 wire 无法区分必要事实，再对最小 typed 字段做同版本 Host/Renderer 迁移，更新 Bridge 唯一真源、两侧 decoder 和跨语言 fixture；不引入第二管理命令面。详情中的孤立连接测试仅是诊断，不能覆盖正式状态或恢复正式 Admission。

本方案对 #26 的完成定义是准确表达原子 apply 失败并保留正确恢复路径。若目标升级为“任何新坏服务均不阻塞其他服务配置生效”，那是独立的 Core 接受政策变化，不包含在当前修复里。

## 8. 并发、故障与关闭

- 所有 completion 绑定 operation identity、desired/configuration generation、server 来源及适用 consent epoch；迟到结果不覆盖新状态。
- OAuth token 更新、reauth、配置 apply 和 catalog refresh 保留原边界；刷新不能恢复已被明确撤销的后续新 Task authority。
- 单服务失败时只消费官方 catalog 中仍成立的健康事实；全局 malformed、OOM、未知结果不能被当成局部成功。
- Stop、归档、删除、审批模式切换与 binding 变化沿现有输入与作业身份校验；迟到刷新不改变已取消输入，也不追溯影响后来的新输入。
- Renderer reload、切页或断连不取消 Host 意图，也不触发刷新重放。
- 关闭顺序保持：禁止新管理/准入与 timer → 取消/settle 并 join 作业 → 释放 Admission/Activation → 释放 Runtime、connector 和 transport。不能把逻辑取消当作 worker 已退出。
- 不增加 secret、原参数、schema、locator 或可重放 response 的日志/历史/快照路径。诊断只记录有界阶段、generation、reason、等待耗时与既有 typed provenance。

## 9. 实施顺序与变更范围

建议一个 `feat/mcp-lifecycle` 专题分支，保留当前测试改动，按可验证的依赖顺序提交；不在 main 上直接实施，不自动 push 或 merge。

| 阶段 | 工作 | 主要范围 | 完成条件 |
| --- | --- | --- | --- |
| P0：资格与反例 | 固定现有复现；原 selectors 在刷新前/中/后的创建恢复及单服务失败发布已通过；继续补来源替换、schema/工具扩展、grant 连续性和未发布失败测试 | `tests/agent/mcp_interop_test.zig`、本地 MCP/Provider fixture；必要的 Product seam | 同来源刷新正向通过；不安全行为有精确失败证据和 owner，不靠放宽期望掩盖 |
| P1：freshness 与准入 | 保守 deadline、默认 30 秒主动刷新；保留有效 authority；原子交接；create 保留 typed 拒绝并以 null Selection 回退；restore 区分容量；后台刷新不闪烁；短 TTL、失败与迟到结果 | Agent MCP/Session、Product MCP、Control 准入及必要投影、Application timer 接线 | 有效目录上刷新中创建/恢复/rebind 成功；Core 已收缩但 Product 未安装时普通 Task 仍创建成功且 MCP 为 unavailable；不误驱逐 idle Session；跨 TTL 真实调用通过 |
| P2：条件性残留窗口 | P1 后仍有可复现失败才评估 §5.2 最小同步；没有残留则不实施 | 优先复用既有 Control 输入推进和 MCP completion | 用样本证明必要性；不新增 worker 退回、固定准备预算、Selection 热替换或重放 |
| P3：失败投影 | apply/global activation/per-server health 分离，页面动作与诊断一致 | Product MCP view、Application completion、Renderer MCP 页面及必要 Bridge fixture | 冷启动混合配置、运行中新增坏服务、停用恢复和配置未知结果都真实呈现 |
| P4：联合验收 | 当前 canonical、当前平台正式应用与包复验，逐 issue 关联证据 | 正式测试图、MCP 桌面验收 | 所有必需 Gate 通过，issue 原始样本已复测或准确登记剩余条件 |

先根据 P0 结果完成必要的合同确认，再进入对应产品切片。通过单一阶段不能关闭整个专题；上游依赖阻塞不会阻止不依赖它的 Host 修复，但必须保留未完成项。

## 10. 真源更新范围

本次仅制定方案，不提前修改现行规范。实现时按实际合同变化更新：

- Product 已发布 authority、目录到期、刷新及 restore 协作若改变合同：`docs/product-architecture.md` 对应章节。
- Agent 公开的 freshness、generation 交接或依赖消费语义若改变合同：`docs/agentcore-integration.md`。
- 用户可观察的可用性、诊断与恢复行为若改变合同：`docs/requirements.md`；具体 UI 呈现由 `docs/ui-design.md` 拥有。P2 未实施时不预写执行准备合同。
- 只有 wire/command 真正变化才修改 `docs/renderer-bridge-contract.md` 与相应机器 catalog；只修现有投影不机械修改合同。
- 只有验证责任、正式入口或长期证据/缺口改变才更新 `docs/validation.md`。实现细节、计数和 hash 继续由代码、lock、测试和证据拥有。

不修改 AGENTS.md，不机械同步 README 或无关架构文档。配置格式、凭据归属和外部 identifier 默认保持。

## 11. 验收矩阵

| 失败模式 | 最小充分层 | 核对内容 |
| --- | --- | --- |
| 主动刷新：enqueue、Core IO、Core 发布到 Product 安装；包括 Core 已发布收缩而 Product 尚未安装 Admission 的暂停点 | canonical ABI + Product MCP/Control completion 暂停点 | 目录仍有效时新建、detached restore、模型 rebind 可用；收缩暂停点上原 Selection 被合法拒绝后，普通 Task 通过 null Selection 创建成功，create result 与 Snapshot 均为 unavailable；同步已登记且失败候选已释放；不误驱逐 idle Session |
| create 错误映射和回退边界 | Agent Session create 状态测试 + Product Control 创建测试 | 分别覆盖 `McpNotRefreshed`、`InvalidMcpSelection`、`StaleMcpSelection`；每次仅一次 null 创建、一个已提交 Task，其他输入不变；busy/同步 enqueue 失败不阻止创建；未知 status、异常 handle、通用 `CoreCallFailed` 与 null 创建失败不被吞掉；无泄漏、重复历史或 Run 重放 |
| 默认 TTL、极短 TTL、超时、队列延迟、时钟失败、timer arm/wake 丢失 | Product MCP 状态/运行态测试，注入时钟与 executor | 有效期不延长；到期收缩；退避有界；查询频率不影响执行 |
| 失败未发布与单服务失败已发布、原目录到期 | canonical interop + Product MCP tests | 前者仅保留至原 deadline；后者按新目录收缩，不维护影子 authority |
| 完成时已过期、配置变更抢先、OAuth/reauth 竞争 | MCP runtime / Control tests | generation 与来源一致；迟到 owner 仅释放自身；不会恢复旧授权 |
| 单 worker、queue pressure、所有 Run 正在等审批 | Product lifecycle | 刷新推进不存在 worker 互等；取消和关闭能收口 |
| 原 Session 到期后刷新 | canonical Agent interop | 同一 Session/Conversation、真实 RPC、once 再询问、无历史重放、无 Selection replacement |
| session allow / deny、schema/source 变化、新增服务/工具 | canonical interop + Product lifecycle | 原 grant 不错误扩张；来源不漂移；失效可解释；普通对话按合同继续 |
| 新 Task 跨 TTL | Product → Agent → 本地 STDIO/HTTP | 2025-11-25、2025-06-18 与 2026-07-28；实际工具调用，不能只断言 snapshot |
| Run 排队至执行间过期、持续刷新失败 | canonical interop；P1 后按样本追加最小 lifecycle 测试 | tolerant 收缩与诊断准确，无 Run 重放；仅存在残留时评估 P2 |
| HTTP/OAuth 长时间开启、超时、429 与持续失败 | 有请求计数的 fixture + 真实服务有界观测 | 记录刷新频率、全量请求数、限流和失败重试；验证间隔、退避及暂停/恢复，不把无限轮询当作无成本 |
| 混合配置冷启动、运行中增加坏服务、撤销与停用恢复 | Application/Control + Renderer suite | apply 结果、Manifest、服务 health、new Task access、恢复动作一致 |
| 关闭、断连、重复 timer 和重复 completion | lifecycle / 当前平台 vertical | 无复活、无重复 RPC、无提前回收、无 Renderer 驱动推进 |

开发期运行相关 `test-product-mcp-*`、`test-product-control-mcp`、`test-mcp-interop`、受影响 Task/Agent lifecycle root。Renderer 变化运行 typecheck、MCP page suite；wire 变化追加 Bridge 与跨语言 fixture。共享 owner/module graph 或 lifecycle 修改进入正式 Native graph 与 architecture guard。

真实平台先覆盖原报告的 macOS 场景及当前 canonical artifact；Windows 只有存在独立失败模式时追加对应执行证据，不因改脚本名或 lock 路径扩大矩阵。缺 canonical bundle 明确失败。自动化通过不代替原发行包与真实服务复测。

## 12. 交付与关闭标准

- 交付实现、按 owner 的回归、必要真源修改和精确 artifact/源码绑定的验证结果。
- #18：正常连接并授权后跨默认 TTL，包括目录仍有效的主动刷新期间，新 Task 能真实调用；Core 已撤回旧 Selection 而 Product 尚未安装的窗口里，普通 Task 仍创建成功，MCP 明确为 unavailable；恢复/rebind 不误报容量、不驱逐无关 Session；真实到期/正式撤回竞争才收缩，页面不闪烁或保留伪可用。
- #29：原 Task 在同来源目录刷新后继续调用，允许一次不演变成永久 allow/deny；模式切换和 checkpoint 保留权限事实，失败不重放工具。
- #26：配置应用失败不冒充所有服务网络失败；正确保留用户配置、原正式事实与 fail-closed 新 Task 准入；明确恢复动作可以重新提交正式 apply。
- 原始时间线未核实、来源隔离资格失败、平台未复测或 required evidence 缺失时，明确保留对应 issue/验收未完成状态。

本轮先完成方案与关键前提验证，产品实施以本方案评审后的范围为准。

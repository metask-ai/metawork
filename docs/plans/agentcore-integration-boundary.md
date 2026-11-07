# AgentCore 集成边界完善方案

日期：2026-11-07。状态：A–D 已实施并分阶段提交；相关回归、正式 Native 图、strict check 和当前 Windows canonical 专项已验证。全仓库 Node 的范围外失败单独列于文末，不计为通过。

Agent 是 MetaWork 对 Metask AgentCore 的封装与集成边界。本次先修复 Stop 投递与归因、Session 技术状态收口，再拆开输出协议接受与 Product 内容保留。Product 继续拥有产品终态和恢复策略；SDK 类型继续复用，不建立平行执行模型。

本文件是实施方案，不是 decision record，不替代现行真源。实现、合同和验证按阶段一起交付，方案通过不代表运行验收完成。

## 1 目标与范围

### 1.1 修改总览

本次保留现有封装结构，围绕已确认的故障闭合五条修改主线：

| 主线 | 当前问题 | 修改与交付 | 主要责任 |
| --- | --- | --- | --- |
| Stop 投递与归因 | 准入窗口未成功投递后丢失意图；未生效 Stop 覆盖真实失败 | starting 上有界补发、成功事实单调、明确实际效果；Product 依据事实归因 | Agent 与 Product policy |
| Host 故障 | Stop 先占控制槽后，真实 Host 故障类型丢失 | 独立记录首个真实故障，区分关闭引起的 callback 结束 | Agent 交付事实，Product 选择 cause |
| Session 健康 | 静态 status 无法区分部分 facade poison；checkpoint 后健康滞后 | 有限终态检查、歧义组合单次 describe、checkpoint 后最新状态同步 | Agent 判定，Product 应用 |
| 合法输出保留 | fork 段外 text、continued 尾部及更宽松 index 被错判 | 仅检查公开保证；保留过程和不完整回复，维持锚点及安全 provisional | Agent 接受，Product 保留和呈现 |
| Product 小改与接口收口 | 用量可能部分更新、分类错误，Run/compact 从 raw 字段猜调用过程 | 四字段原子累计、Host 错误分类、明确调用事实接口 | Product 与 Agent 公共接口 |

接受规则和例外集中在第 4 至 8 节，实施顺序在第 9 节，场景与最终完成条件在第 10、12 节。整理不新增已评审范围之外的机制。

### 1.2 范围与固定选择

普通 Run 是主要改造范围。继续复用 SDK 的 typed Status、StopReason 和 payload，经 Agent 公共入口消费；Product 保留纯策略、内容保留、历史和恢复建议。工具 digest 和 receipt 保持现有机制，用量累计继续由 Product 拥有。

不升级 bundle，不修改 SDK、ABI、Bridge wire、SQLite schema 或 checkpoint 格式。不增加 Run 自动重放，不建立全量自有 CoreEvent、用量快照事件、工具注册表或 envelope 工具 key 搬迁。

compact 同步明确调用事实访问接口及 checkpoint 后健康同步；仅追加受共享生命周期改动实际影响的验证，不借此重做 compact、Completion 或 MCP 管理语义。

## 2 真源与改动入口

- [高层架构](../architecture.md)：Agent 与 AgentCore 的边界及对 SDK 类型消费的限制。
- [AgentCore 集成契约](../agentcore-integration.md)：Stop、事件、终态、线程、错误及 Session 生命周期。
- [AgentCore ABI 接受规则](../agentcore-abi-v1.md)：canonical SDK、依赖身份和外部合同接受。
- [Product 架构](../product-architecture.md)：产品原因优先级、内容保留、历史和恢复。
- [UI 设计规范](../ui-design.md)：模型失败入口、过程文本和不完整回复的呈现。
- [验证规范](../validation.md)：测试归属、正式入口和长期证据。

依赖身份由当前平台 canonical lock 唯一拥有。所有新增硬拒绝规则必须能定位到该 lock 的 source.commit 对应的正式合同；同源实现用于发现接受边界和合同冲突，不能据此推造完整的 phase 到 StopReason 对应表。

本轮已按锁定 commit 静态核对下列来源，后续修改须继续绑定实际选用的 lock：

| 上游位置 | 对本方案的约束 |
| --- | --- |
| doc/AGENTCORE_BINARY_ABI.md 的 callback 和输出段合同 | terminal 的有限保证、index 递增、segment 字段配对和 byte count |
| 同一 ABI 文档的 fork Skill 合同 | fork 子执行公开 text 和 usage 进入外层普通事件流，与“每个 text 都在段内”的泛化表述存在冲突 |
| src/agentcore/event_projection.zig 的 model_tool 投影 | 子执行转发 text、stream_done、usage 等事件，不转发 segment 标记 |
| src/core/agent_loop.zig 的工具前输出关闭及续写 | 父段可先关闭；continued 后可因取消、回合上限或下一次模型流失败直接结束 |
| src/agentcore/abi_v1.zig 的终态与 budget 收尾 | terminal 先于最终 checkpoint stop code 替换，不能要求完整一对一对应 |
| 同一 ABI 的 abort 和失败收口 | STALE_RUN、TOO_LATE、Core 准入和 Session poison 必须分别观察 |

这些核对是静态依据；fork、continued 及 Stop 准入竞态须按第 10 节复现，不将静态核对写成运行通过证据。

| 本仓库位置 | 本次变更 |
| --- | --- |
| [Agent Session](../../src/agent/session.zig) | Stop 投递、starting 补发、有限终态对账和 Session 处置 |
| [Agent 执行值](../../src/agent/session/control.zig) | 终止事实、Run 与 compact 的明确调用事实访问接口 |
| [事件解码](../../src/agent/session/wire.zig) | 保持 SDK 解码和单事件有效性，不复造事件 schema |
| [事件队列](../../src/agent/event_pump.zig) | 保持所有权、预算与背压，验证 starting 补发先于 enqueue；不新增段外文本或工具 key 字段 |
| [Product 事件应用](../../src/product/task/state.zig) | 合法输出保留、四字段用量原子更新和产品记录 |
| [Product 任务运行时](../../src/product/task/runtime.zig) | drain、内容提交和残余错误的正确收口 |
| [Product Control 事件消费](../../src/product/control/runtime.zig) | InvalidUsage 等错误分类及终止编排，B、C 均触及 |
| [Product 执行交接](../../src/product/task/execution.zig) | Run 与 compact 消费调用事实、终态发布和 checkpoint |
| [Product 纯策略](../../src/product/task/policy.zig) | 使用终止生效事实，修正晚到 Stop 的 cause 和恢复入口 |

## 3 责任与结构约束

Agent 封装调用、所有权、并发静止、必要协议接受和 Core Session 技术状态。Product 负责产品终态选择、业务优先级、内容脱敏与保留、历史、展示和恢复。

不将整个 policy.zig 搬进 Agent。Agent 交付控制请求是否送达、是否实际阻止执行或观察到中止等事实；Product 根据这些事实执行产品规则。permission_required 的显式优先级仍由 Product 定义。

第一阶段直接补充现有 Session 中必要的固定状态和收尾函数，不预先建立协议观察框架。只有出现独立、内聚且可单独验证的状态转换时，才提取同 owner 内部文件。

SDK 的 Status、StopReason、phase 和只读 payload 可经 Agent 公共入口复用。Product 不直接 import SDK，也不获取 ABI handle、SDK 函数表、borrowed callback 存储或通用系统 effect。实施时同步修正 architecture.md 中“只能消费 MetaWork 自有类型”的绝对表述，保留上述安全与依赖边界。

## 4 A 阶段 Stop 投递与实际生效

### 4.1 控制事实

保留 termination_signal 的 first-writer-wins 控制语义，并提供一个只读终止观察。它需要区分以下含义，具体以窄 view 或字段实现，不复制另一份信号状态：

| 事实 | 含义 |
| --- | --- |
| 未请求 | 当前 Run 没有对应终止请求 |
| 调用前阻止 | 请求已在进入 Core 前阻止本轮执行 |
| 等待准入投递 | 已请求，但尚未有可确认接收该 Run 的 Core 准入 |
| abort 已接受 | Core 对精确 Run 的 abort 返回 OK，尚不能据此断言最终中止 |
| 未接受或未送达 | 保存 STALE_RUN、INVALID_STATE、TOO_LATE、其他拒绝或无准入即返回等明确原因 |
| 观察到中止 | 合法最终 STOP_ABORTED，关联本轮控制事实 |
| 受控关闭结束 callback | 由明确的关闭拒绝或唤醒分支结束交互，记录控制作用而不伪造 Host 故障 |
| 未按请求中止 | 本轮以其他可信结果结束，保留未生效或无法确认原因 |
| 结果不可信 | 合同失败等条件使实际效果不能确定，不猜测为用户取消 |

最终观察由 Agent 汇总并冻结。未请求时收到 STOP_ABORTED 也不能伪造用户 Stop；没有终态时不把 abort=OK 扩写为已经停止。模型错误仍按主结果或补充观察的合法关系交付。

### 4.2 准入窗口与 starting 补发

core_call_in_progress 只能说明 Host 已进入调用交接区间，不能作为 Core 已接纳 run_id 的证明。将逻辑终止请求与 abort 投递进度分开：

1. 请求到达时登记精确 Run ID、generation 和逻辑终止意图；调用前可以阻止执行时直接收口。该意图包含 Stop、RunControlLease、close 和 shutdown，不能只检查 cancel_requested，因为 close 不设置它。
2. 已进入调用交接区间时允许发送首次 abort。准入前没有收到 OK 的返回均不能清除逻辑意图：预算 preflight 的 checkpointing 可返回 INVALID_STATE，尚未接纳 Run 可返回 STALE_RUN。两者都不能据此判定终止已经送达。
3. 在有效 starting callback 中，只要本轮有终止意图且尚未记录到 abort=OK，就登记一次准入后补发，不按先前返回码白名单筛选。补发登记和锁外调用必须发生在事件 enqueue 之前，保证 ConsumerStopped 等提前返回不跳过它。
4. 若 starting 到达时首次 abort 尚在途，只记录补发需求，不等待也不并发调用；首次调用结束后重新检查逻辑意图、准入和成功记录，仍未成功才执行这一次补发。
5. 匹配 Run 的 abort=OK 是单调事实。后续 STALE_RUN、TOO_LATE、INVALID_STATE 或其他非 OK 不得覆盖成功记录；原始诊断可保留各次回应。终止请求已接受仍不等同于最终已经中止。
6. 准入确认后的补发每 Run 至多一次，不建立计时器或无限重试。Run 已结束、generation 不匹配或已经成功时不再补发；补发仍未被接受则保留最终原因，不循环重试。准入前的任何非 OK 不能阻止有效 starting 上的这一次机会。
7. close 和 shutdown 使用同一投递状态，不以 raw_abort_status_code 非空跳过 pending 投递。Core 在准入前拒绝且没有 starting 时不补发，最终记录实际拒绝及未送达事实。

abort 登记、完成、pending 检查和 Run 结束使用现有 Session 同步边界；实际 Core 调用在锁外。保留 abort 静止屏障，销毁或下一轮准入前所有已登记调用必须结束。starting 中发起匹配 abort 采用 ABI 已允许的 callback 调用路径，不引入新 worker。

### 4.3 Product 归因修正

A 阶段同步修改 policy.zig 中 ABI 失败、tool_error、api_error 三个分支，移除“signal 非空就覆盖 cause”的规则：

- 外部中断以调用前阻止、实际 STOP_ABORTED 或明确的受控关闭 callback 结束事实为依据，不能仅凭 signal 非空就覆盖结果。
- TOO_LATE、未送达、已接受但最终以其他原因结束，不覆盖可信的 provider_failure 或 tool_failure；这一规则不适用于确已改变最终结果的中止。
- Stop 先占据 signal 槽、随后发生真实 Host 故障时，消费独立的首个 Host 故障事实。例如 enqueue 失败后 CALLBACK_FAILED 应得到 event_pipeline_failure，而不是空 cause 或用户取消。
- 因 close 合法结束 UI callback、没有真实 Host 故障时，保留 session_close；不能因出现 UI_FATAL 就伪造 ui_pipeline_failure。
- permission_required 的产品优先级继续明确保留；其他策略按现行产品合同执行，不从 abort code 自行推导新优先级。
- credential_update_failure 由对应更新操作的真实失败记录确认，不由 signal 的存在性证明。与模型 401、TOO_LATE 并存时，本方案明确选择已确认 Host 凭据故障优先：dependency_contract 映射为 dependency_contract_failure，resource_limit 映射为 resource_limit，rejected 映射为 agent_failure。非合同违约的合法模型详情作为补充观察保留，恢复建议为 none；合同违约抑制公开模型详情。这个产品优先级不声称 abort 生效，也不声称模型 401 由更新失败造成。
- 无法确认效果时保留实际已知结果与未知事实，不虚构“由你停止”。

明确改变晚到 Stop 的用户可见归因：401 模型失败后 Stop 返回 TOO_LATE，且没有独立的真实 Host 故障，应仍为 failed/provider_failure，保留 authentication 详情及适用的账号或模型设置恢复入口。相反，在 finalizing 时被接受的 Stop 可合法改变最终结果为 STOP_ABORTED，并且没有 model_error，应按实际中止收口。修改相应纯策略用例、Product 合同和用户提示验证，不再声称本次完全保持旧策略行为。

## 5 A 阶段 有限终态对账与 Session 状态

### 5.1 最小 terminal 观察

将 terminal_run_state_seen 改为可空 terminal phase，用于保存一条终态及检测重复。当前布尔量只参与 model_error 顺序检查，结束路径并不读取它，新增的结束校验是实际新增责任。

不在 A 中复制 Product 已有的展示 sequence 或完整阶段状态机。保留现有 Run identity、starting 与输入窗口检查，新增的终态硬校验仅限：

1. STATUS_OK 必须恰好观察到一次 terminal。
2. STATUS_OK 且 STOP_ABORTED 时，terminal 必须为 aborted。
3. STATUS_OK 的 terminal 不得为 poisoned。

不要求 max_turns 与 failed 对应，不建立其他 StopReason 与 phase 的完整映射。checkpoint stop code 可能在 terminal 后调整，不能据此拒绝合法结果。

非 OK 返回不要求 terminal 存在，不读取未定义 StopReason，也不因先收到 completed/failed、随后投递该事件失败而返回 CALLBACK_FAILED，就判为额外合同违约。

### 5.2 fatal 与最终返回

分别记录 callback 的 fatal 回应和首个真实 Host 故障类型。复用现有 event、UI、event pump、notifier、credential update 等有界 reason，在真实失败点按 Run 身份登记；不能从可能已被较早 Stop 占据的 termination_signal 反推，也不能只保存布尔值。

首个 Host 故障既用于最终对账，也作为 Product 归因的依据。控制槽继续 first-writer-wins，故障观察拥有独立的首次记录；二者在下一轮准备时清空并随结果转移。已有首次 callback 拒绝诊断继续提供边界和计数，不复制无界正文日志。

受控关闭的合法 UI 拒绝、唤醒和 UI_FATAL 单独记录控制原因，不算 Host 故障。该判断由实际关闭分支产生，不能因为 Session 恰在 closing 就掩盖同时发生的真实解码、身份或接管故障。

callback fatal 后 Core 返回 OK 属于违约；callback 内已捕获 terminal、随后 enqueue 或其他接管失败，Core 返回 CALLBACK_FAILED 属于正常 Host 故障收口。Stop 后才发生这一故障时仍应保留其类型。受控关闭导致的 callback 结束则保留 session_close，不凭 fatal 回应伪造事件或 UI 故障。

### 5.3 Session 状态及时收口

完成时 Session disposition 由 Agent 按下表决定，已开始的 closing 保持关闭，明确的合同违约优先隔离：

| 观察与返回 | 判定 |
| --- | --- |
| STATUS_OK | 先通过第 5.1 节有限约束，再按成功返回合同处理 |
| terminal=poisoned | 禁止复用，不被静态 status 表覆盖 |
| 已有有效 starting，但非 OK 返回没有 terminal | 按已开始执行后的失败隔离，不额外要求它属于 terminal 缺失违约 |
| 没有有效 starting | 依据 ABI 的准入必发 starting 保证，应用该 operation 的静态接受和处置表；不得将这个准入前信号无限泛化为“没有任何 Host effect” |
| starting 加 terminal=failed 加该 operation 静态可复用的非 OK status | 仅这类歧义组合调用一次 session_describe，以 lifecycle 区分 idle 与 facade poisoned；BUSY 保持已有处置并记录本次未确认 |
| 其余合法非 OK | 按当前锁定 operation 的处置表，不推造更多 phase 与状态码关系 |

歧义组合存在两种合法来源：Skill materialization 失败后 Session 可回到 idle；finishBudgetedRun 或 reconcileBudgetedRunError 的收尾失败可能只污染 facade，terminal 却仍为 failed。RESOURCE_LIMIT 是其中一种状态，其他静态可复用的 Skill 失败 status 也可能受收尾 OOM 影响，不能只按一个错误码筛选。相同输入事实不能支持单纯隔离或单纯复用。

在 Core 返回、输入/callback/abort 已静止且 Session 操作 lane 仍被当前收尾持有时，只对上述组合执行一次正式 describe。复用既有 SDK 调用、身份校验和 owned bytes 释放方式，读取 lifecycle：idle 则可复用，poisoned 则隔离；BUSY 可由健康的后台 job 引起，保持已有处置并记录本次未确认，不将其判成确认失败或 Core 违约。这个 BUSY 例外允许下一次调用继续由 Core 的准入检查把关，不能宣称已证明 idle，也不因它额外重试 describe。其他调用失败、身份错误或描述无法可信解析时采用 Host 安全隔离。分配或解码失败明确成为这次确认失败，不冒充已观察到 Core poisoned。其他路径不增加 describe，不建立轮询、fallback 或额外探针。

在最终处置决定完成后才能发布 TerminalResult 或允许 Session 回到 idle。必须证明合法 materialization 失败与后台 job 的 BUSY 不会被误隔离；成功 describe 已确认的 facade poison 不会报告 reusable。BUSY 未确认时可能要到后续 Core 准入才发现 facade poison，是本方案明确接受的安全边界。

### 5.4 明确调用事实

普通 Run 的 TerminalResult 和 compact 的 CompactTerminalResult 都提供 coreWasInvoked() 或同义只读方法。它复用既有 raw 返回记录，不并行保存可漂移的布尔值，只表示 Core 函数曾被调用。

execution.zig 中两条 checkpoint 后处理和策略中的 pre-Core 判断改为使用该接口。raw 字段保留诊断用途，不再作为这些业务分支的条件。此项不扩展 compact 的控制和终态规则。

### 5.5 checkpoint 后的实时健康同步

Run 或 compact 完成时的 disposition 是不可变历史快照。后续 exportCheckpoint 可能再使 Agent Session 失效，Product 的 attached.health 必须在 checkpoint 后处理完成时同步，不能等待下一次 Run 才发现。

沿现有 checkpoint postprocess completion 交付 Agent outcome 已有的 disposition；调用在产生 typed outcome 前失败时，通过 Agent 公开的当前 Session 状态读取确认，不根据 checkpoint 错误名猜测健康。主线程按现有操作身份和后处理归属应用该状态，之后才解除后处理门禁或接纳下一轮。

终态观察与 checkpoint completion 的到达顺序均须覆盖：先应用执行终态快照，再应用更新的 checkpoint 后状态，或保留待应用的后处理事实直到终态折叠完成。旧 reusable 快照不能覆盖新的失效状态；旧操作的迟到 completion 不能覆盖后来操作。复用现有 postprocess/worker 同步，不新增全局健康缓存。此次同步不改写已提交 Run 的 outcome 或完成时 disposition。

## 6 B 阶段 输出接受与内容保留

### 6.1 硬校验范围

只有锁定合同明确承诺的输出约束才可成为 callback fatal 或终态违约。使用最小元数据检查：

- 同一时刻最多一个已声明的 open segment。
- begin/end 的 index、turn、group 与原始 UTF-8 byte count 配对。
- 已声明 segment 的 index 严格递增，允许跳号，不要求连续，不额外要求从零开始。
- 不增加 ABI 未承诺的 retry-group 关系，不把 Product 当前实现中的限制原样搬入 Agent。

字节计数发生在脱敏与保留之前，不复制正文。正常已声明 open segment 的结束义务与 callback/传输异常中断分别处理；closed continued group 不属于未闭合 segment。

### 6.2 段外 text

当前锁定输入存在 fork Skill 公共文本不携带 segment 标记的投影。Agent 接受合法段外 text，不据此猜测来源一定是 fork，也不伪造 index、turn、group 或 final。Product 已有 open_output_segment，可据此选择内容保留路径，envelope 不新增同一事实。

Product 将连续段外文本保留为独立的过程内容，复用现有每 Run 内容预算与脱敏机制，禁止与 continued 或最终回答缓冲混用。产品位置使用现有 output part 序号：从第一个 chunk 起，pending 段外内容就计入 outputPartCount，并进入 provisional 投影。其间采纳的追加输入锚点应位于该过程 part 之后，长 fork 的安全文本应可逐步阅读。提交为 commentary 后承接同一个 part 序号，不重复计数或重排，不新增位置字段或 schema。

provisional 只发布已完成凭据清洗的字节及合法占位，未决脱敏后缀始终留在 Host；尚无安全可发布字节时保留计数槽位，不暴露原始后缀。pending 的计数和投影均从现有保留状态派生，不能等 commentary_ends 提交后才创建 part。

提交边界固定为下一次 output_segment_begin 处理之前，以及本轮 terminal drain 完成之前。到达边界时，先完成该过程内容未决后缀的完整凭据清洗，预留正文与 commentary_ends 所需空间，再原子提交一个产品 commentary 边界，清空该段外 pending 内容；不能把未决后缀留给下一个 framed segment 或最终答案。容量不足沿既有保留不完整机制收口，不泄露未清洗后缀。未决段外内容、continued 尾部和 framed segment 的提交按既定产品顺序协调。

同步移除生产路径中“段外 text 一律 InvalidOutputSegment”的拒绝，更新对应集成和呈现合同。fork 的来源不可区分性作为接受边界保留，不能通过 Skill 名称过滤、关闭合法 Skill 或本地 SDK patch 绕开。

### 6.3 结尾 continued

continued 表示当前段已关闭、内容待后续续写。后续段可能因 abort、max_turns 或下一次流打开失败而不出现，包括 STATUS_OK 的合法结束。

Agent 接受该收尾，明确区分“segment 缺少 end”和“已关闭的 continued 尚无最终段”。后者不判合同违约，不污染 Session。

Product 在终态 drain 时保留已接受且已保存的 continued 内容，按不完整回复呈现，实际 Run outcome 仍由执行结果决定。提交遵守既有 fallible reserve、脱敏和原子正文提交规则；预算不足标记保留不完整，不把丢弃正文当成协议修复。

不同 group 的产品保留规则不能变成 Core 的额外拒绝条件。仅按显式语义合并，不从工具边界或 stream_done 推断最终答案。

### 6.4 drain 与错误归属

保留 Product terminal event-drain 屏障。Agent 的协议收尾事实、事件交付缺口和 Product 保留缺口分别消费，不能互相替代。

B 阶段同时修改 task/state、task/runtime 和 control/runtime 的应用及错误分类。Product 不再拥有已迁移的 Core 输出协议判断；自身保留、记录、receipt 或事务错误仍按对应 Host/Product 故障处理。

逐项检查剩余真正的 Core 违约报告路径：发现后必须通过 Agent 所属 Session 的安全收口撤销使用资格，不能只修改旧 Run 的显示或对已经结束的 Run 请求一次无效 abort。需要新增接口时仅提供按当前有效 Session 身份隔离和停止在途操作的窄能力，不形成通用控制 facade。

## 7 C 阶段 Product 输入与用量小改

### 7.1 追加输入

保留 Agent SubmittedInputs 对登记、receipt、采纳顺序及终态计数的协议责任。Product 继续做本地记录关联、活动位置、历史和接续资格检查。

两层规则不同本身不是问题。本次不迁移整个产品输入模型，不删除必要的本地一致性检查。对产品记录缺失或内部矛盾采用明确的产品错误分类，不无依据标为 Core 协议违约。

### 7.2 用量

usage 留在 Product，继续消费 SDK 明确规定的 delta，保持唯一消费者和现有数据格式。

将四个累计字段先计算到临时值，全部 checked-add 成功后一次赋值。溢出时四字段全部保持更新前状态，不 wrap、不饱和、不产生部分更新。

在 control/runtime 的事件错误分支中，将 InvalidUsage 从 dependency contract failure 分类移出，作为 Host 统计/事件处理失败明确收口。不能因累计表示范围不足就宣称某个合法 SDK delta 违反 Core 合同。保留已有故障通知、取消和后续任务安全处理，不引入 Agent 用量累计、副本快照或新增事件。

### 7.3 工具与 receipt

维持现有 Product 经 Agent 公共 toolRouteDigest 进行 Run 内关联的方式，保留 file_changes 的关联职责，不向 owned envelope 添加 digest 字段，不建立工具 ledger。

文件 receipt 继续按真实成功 tool_result 的内容匹配；图片 receipt 沿既有关联路径消费。不得将它们统称为同一工具 key 机制，也不借本方案重写两种 receipt 的授权和释放责任。

## 8 资源与同步规则

| 情况 | 行为 |
| --- | --- |
| 调用前必要资源无法准备 | 明确拒绝，释放候选，不进入 Core |
| 正常队列暂时饱和 | 不持 Session 锁地可取消背压 |
| 普通 Stop | 保持必要事件消费，同时完成准确的请求投递 |
| close 或消费路径关闭 | 唤醒等待、记录交付缺口、完成取消与静止，不由缺口反推 Core 违约 |
| 产品保留容量不足 | 标记记录缺口，保持真实执行结果 |
| 已允许降级的补充观察不足 | 按合同降级 |
| 关键 Host 接管失败 | 走明确 Host 失败路径，不声称过程完整 |
| 已证实 Core 合同违约 | 拒绝、收尾并阻止不安全复用 |

不削弱现有 fail-closed guard，不把“容量不足不能 fatal”泛化到无法继续安全处理的 Host 故障。也不为了把所有校验前移而将合法 Core 观察升级为 fatal。

Session 锁只保护有界状态更新和调用登记。Core effect 调用、队列等待和 Product effect 在锁外执行。歧义终态的一次 session_describe 保留明确的锁内只读例外：该 SDK 入口不回调 Host，Run 操作槽与静止屏障仍由当前收尾持有，Session 锁阻止凭据 mutation 和 close 穿过确认；不把此例外扩展到 Run、abort 或队列等待。starting 补发不建立循环重试；首发、补发、返回和 close 通过同一 abort 调用登记保证静止。

## 9 实施阶段与完成条件

### 9.1 A 阶段 Stop 与执行事实

按消费者需要完成以下改动，全部闭合后才算 A 完成：

1. 在现有 Session 中拆清逻辑终止意图与投递进度，修正 Stop、RunControlLease、close、shutdown 的 starting 补发，并保证成功记录单调。
2. 接入只读终止事实及独立首个 Host 故障，修改 Product 的三个归因分支；同时覆盖恢复入口、受控关闭和凭据故障的已定策略。
3. 增加三条有限 terminal 对账及 fatal 返回一致性检查，按 Session 判定表处理单次 describe、BUSY 例外和静态接受结果。
4. 沿 checkpoint postprocess 同步最新健康，处理终态和后处理通知的两种到达顺序。
5. Run 与 compact 统一使用明确调用事实接口，移除本方案涉及的 raw 存在性分支。

完成条件：两类准入窗口不丢 Stop；未生效请求不覆盖真实失败；真实 Host 故障有确定 cause；健康 Skill 与后台 job 不误隔离；已确认 facade 和 checkpoint 失效及时反映，BUSY 未确认的安全边界明确。

A 的收益必须由正常依赖条件下的行为修复证明，不能只证明恶意 Core 返回被拒绝。补发、归因、健康和消费者改动必须一起交付。

### 9.2 B 阶段 合法输出与协议边界

先修复合法输出的接受与保留，再同步收口协议检查的唯一责任：

1. 接受段外 text，完善 Product pending 内容的 outputPartCount、安全 provisional、输入锚点和 commentary 提交边界。
2. 保留结尾 continued，按不完整回复呈现，并保持实际执行 outcome。
3. 将明确受合同保证的 segment 检查收口到 Agent，同步移除 Product 的重复或过严规则，禁止按连续 index 或未承诺 retry-group 拒绝。
4. 维持 terminal drain、内容脱敏和保留预算，修正 task 与 Control 事件消费中的错误分类；真实违约的 Session 安全收口仍须闭合。

完成条件：fork、三种 continued 尾部和跳号 index 均合法；已声明 segment 的真实字段或 byte 错误仍拒绝；追加输入锚点、provisional 和冷历史稳定；合法输出不污染 Session。

### 9.3 C 阶段 Product 小改

1. 用四个临时值完成 usage checked-add，再原子提交；InvalidUsage 改为 Host 失败分类。
2. 核对输入协议 ledger 与产品记录关联的责任，保留各自必要检查，修正无依据的 Core 违约归类。
3. 确认工具 digest、file_changes 和两种 receipt 的现有路径保持，无新搬迁层。

完成条件：统计溢出不产生部分更新，不误报 Core 违约；输入关联和接续不回归；没有新增用量累计副本或工具身份机制。

### 9.4 D 阶段 合同与验证收尾

实现与受影响真源在 A、B、C 各阶段同步更新，D 负责最终一致性复核、无职责旧路径清理及正式验收，不把必要合同修改推迟到最后。

完成条件：单一 active path，SDK 复用及 Product 策略边界清楚，第 10 节适用的当前平台场景和第 12 节全部验收条件有对应证据。

各阶段完成相关消费者和最小充分验证后再进入下一阶段。不先搭空结构，也不为实施迁移保留长期双路径。

## 10 验证与预期结果

### 10.1 必须闭合的场景

| 场景 | 预期 |
| --- | --- |
| 401/authentication 已发生，随后 Stop，abort=TOO_LATE | failed/provider_failure；详情与适用设置恢复入口保留，不显示为用户停止 |
| tool_error 后 Stop 来晚 | 保留 tool_failure，不用未生效请求覆盖原因 |
| Core 调用前 Stop | 不进入 Core；终止事实为调用前阻止 |
| Host 进入调用交接区间但 Core 尚未准入，首个 abort=STALE_RUN | starting 后匹配补发；Run 实际中止；同一请求不因重复 Stop 丢失 |
| 预算 preflight 处于 checkpointing，首个 abort=INVALID_STATE | 有效 starting 上仍补发；不因旧拒绝或 cancel_requested 跳过；扩大窗口后 Stop 与 close 均有效 |
| close 未设置 cancel_requested，且队列已 ConsumerStopped | 逻辑关闭意图仍触发 enqueue 前补发，close 不等到自然完成 |
| 任一次匹配 abort 已返回 OK，后来产生非 OK 回应 | 成功事实不回退，不重复补发，不由后写结果掩盖已接受 |
| 首个 abort 尚在途时 starting 到达 | 只登记补发需求，无并发重复 abort，首个返回不覆盖补发结果 |
| close/shutdown 遇到上述窗口 | pending 请求继续投递；abort、callback、Run 全部静止后才销毁，无无限等待 |
| Core 准入前拒绝且无 starting | 不循环补发；保留实际拒绝和未送达事实 |
| 正常 OK 缺少或重复 terminal、STOP_ABORTED 对应非 aborted、OK 配 poisoned | 仅这些已确认约束判违约 |
| 收到 terminal 后该 callback 接管失败，返回 CALLBACK_FAILED | 合法 Host 故障收口，不额外因 phase/status 不同判违约 |
| max_turns/completed、tool_loop/failed、terminal 后 budget stop 替换 | 接受，不采用完整一对一映射 |
| callback fatal 后 Core 返回 OK | 依赖违约，不发布可信成功或允许复用 |
| Stop 先占槽，后续真实 enqueue/接管失败，返回 CALLBACK_FAILED | 独立 Host 故障可归因为 event_pipeline_failure 等确定类型，不得到空 cause 或伪造用户取消 |
| close 导致合法 UI_FATAL，未发生真实 Host 故障 | 保持 session_close，不伪造 ui_pipeline_failure |
| 已确认 credential_update_failure 与 401、TOO_LATE 并存 | 按依赖违约、资源或拒绝的明确产品优先级归因；合法模型详情只作补充，无恢复动作 |
| Stop 在 finalizing 被接受，最终 STOP_ABORTED 且无 model_error | 按实际中止收口，不强保留 provider_failure 或捏造模型详情 |
| 准入后 resource_limit 且 terminal=poisoned | 完成结果和实时 Session 均不可复用，下一轮拒绝，无需等下一次调用才发现 |
| starting、failed、静态可复用非 OK，describe=idle 或 poisoned | 覆盖 RESOURCE_LIMIT 和其他 Skill 失败 status；每条路径仅一次 describe，健康可继续，facade poison 被隔离 |
| 上述组合 describe=BUSY，存在健康后台 job | 不隔离、不重试、不标 Core 违约；记录未确认并保留 Core 后续准入把关 |
| 上述组合 describe 有其他错误或解析失败 | 明确确认失败并隔离，不假称观察到 poisoned |
| exportCheckpoint 后 Session 失效，终态与后处理通知按两种顺序到达 | attached.health 在下一轮准入前同步；旧 reusable 快照不覆盖新健康，历史执行结果保持 |
| fork Skill 子执行只有段外 text | 接受为过程内容；在下次 begin 或 terminal drain 提交 commentary 边界，清洗后缀，无正文并入 final |
| 段外 text 的凭据跨多个 chunk，随后父级 final | 凭据不泄漏、过程内容和最终答案分开、commentary_ends 已闭合；不新增 envelope 上下文事实 |
| 长 fork 尚未提交 commentary，其间追加输入被采纳 | 首个 chunk 起 pending part 已计数且可安全 provisional 阅读，输入锚点在其后；提交后序号不跳变，无新字段或 schema |
| continued 后 abort、max_turns、下一次流打开失败 | 已保留正文作为不完整回复收口；outcome 各自保持真实，Session 按真实状态处理 |
| segment index 跳号或不存在 ABI retry-group 保证 | 不因旧 Product 限制误拒绝 |
| 已声明 segment 字段不配对、byte count 错误 | 明确协议失败，Session 安全收口 |
| 用量第四字段溢出 | 四字段均保持旧值；Host 失败分类，不能标为 Core 违约 |
| Product 保留不足、队列关闭或补充观察丢失 | 与 Core 协议错误分别处理，保持 drain 和必要安全收尾 |

### 10.2 验证方法

先使用可控 fixture 明确放大 idle 和预算 preflight 两类调用交接区间，允许首个 abort 分别返回 STALE_RUN、INVALID_STATE，分别覆盖 Stop、RunControlLease 和 close；同时注入成功后出现较晚非 OK 回应，证明成功记录单调。不以窗口自然出现概率作为通过条件，也不把 preflight 时长随历史增长的推断写成测量结果。

随后用当前 canonical Core 跑真实调用链，确认 starting callback 内 abort 可用、enqueue 前有限补发有效以及后续 Session 行为。歧义组合覆盖 RESOURCE_LIMIT 与其他静态可复用非 OK，分别验证一次 describe 的 idle、poisoned、后台 job 引起的 BUSY 以及身份/解析失败；checkpoint 后健康同步覆盖通知的两种到达顺序。

fork 场景必须使用实际可被模型调用、声明 context fork 的 Skill；continued 场景通过本地 Provider fixture 产生 token 截断，分别触发取消、回合上限和下一次流打开失败。确认正文、outcome、恢复入口和 Session 状态，不能只看 callback 次数。

状态转换放在 Agent 的最小测试层，线程和静止在 lifecycle 层，产品 cause、保留及错误分类在 Product 层，跨 owner 行为用对应组合链验证。测试预期以批准后的语义为依据，旧用例不能阻止修正已确认的错误行为。

### 10.3 当前平台入口

当前 Windows x86_64 使用：

    node scripts/verify-staged-agentcore-bundle.mjs
    zig build test-agent-lifecycle -Dtarget=x86_64-windows-msvc
    zig build test-lifecycle -Dtarget=x86_64-windows-msvc
    zig build test-office-pipeline -Dtarget=x86_64-windows-msvc

本次涉及共享生命周期和事件消费链，完成时运行适用的正式 Native 图和当前平台 canonical 组合验证。完整仓库入口为 npm test，正式检查为 npm run check；不提前增加新 build step。

桌面输出和模型错误分别在独立 PowerShell 进程中设置一种专项模式，再运行 Windows wrapper：

    $env:METAWORK_OUTPUT_VERTICAL_ONLY = '1'
    node scripts/run-agentcore-vertical-windows.mjs

    $env:METAWORK_MODEL_ERROR_ONLY = '1'
    node scripts/run-agentcore-vertical-windows.mjs

专项补足或复用 fork、continued、晚到 Stop 的覆盖，记录真实业务结果和冷历史。其他平台只在独立失败模式需要时追加。缺 canonical staged bundle 明确失败，不跳过依赖用例报告成功。

## 11 合同同步

| 真源 | 必须处理的内容 |
| --- | --- |
| architecture.md | 明确 Agent 公共入口可受控复用 SDK data-only 类型，同时禁止其他 owner 直接消费 SDK、ABI handle 和 callback 存储 |
| agentcore-integration.md | Stop 意图与成功记录、两类准入窗口、首个 Host 故障、有限 terminal 对账、单次 describe、checkpoint 后实时状态、fork 与 continued 合法收尾、Run/compact 调用事实 |
| product-architecture.md | 三个终态分支消费终止与 Host 故障事实，TOO_LATE 和 credential 归因、checkpoint 最新健康应用顺序、Host 统计分类及段外文本提交边界 |
| ui-design.md | 段外文本作为过程内容、continued 尾部不完整回复、模型失败恢复入口的实际呈现 |
| validation.md | STALE_RUN/INVALID_STATE 窗口、成功记录单调、Stop 后 Host 故障、受控关闭、歧义 describe、checkpoint 状态同步、fork 和 continued |

产品需求只在发现现有可观察承诺需要修正时修改对应章节；不机械复制实现摘要。通知 unavailable 的旧同步重试条款与关闭取消条款同时统一。

不修改 AGENTS.md、bundle lock、machine guard、allowlist 或 verifier。现有 Bridge wire、历史和 checkpoint 格式继续遵守原合同；产品原因及合法输出保留的行为修正明确记录，不再以“纯重构”掩盖。

## 12 最终验收

以下条件全部成立才完成：

- Agent 管理调用、所有权、静止和 Session 技术状态，SDK 复用和 Product 纯策略保持明确。
- 终止是否生效、为何未送达或未中止由 Agent 提供只读事实；Product 不再拼接 raw status 和 signal 猜测。
- 有效 starting 上有本轮终止意图且无 abort 成功记录就有一次 enqueue 前补发机会，不按之前状态码筛选；成功记录单调，close/shutdown 不依赖 cancel_requested，也不漏 join。
- Stop=TOO_LATE 且无独立 Host 故障时，不覆盖实际 provider/tool failure，适用恢复入口保留；finalizing 中接受并实际生效的 Stop 按 aborted 收口。
- Stop 后真实 Host 故障仍有独立类型和确定 cause；受控关闭 UI_FATAL 不是 Host 故障，credential 故障优先级明确。
- terminal 只执行已确认的三条 OK 约束；合法非 OK 故障和 budget 调整不被误拒绝。
- Session 状态按明确判定表处理；starting、failed 加静态可复用非 OK 仅 describe 一次，不误伤健康 Skill materialization；BUSY 保持现状并明确未确认，其余成功确认的 facade poison 及时隔离；checkpoint 后最新健康在下一轮准入前同步，旧快照不覆盖它。
- fork 段外文本从首个 chunk 起纳入现有 outputPartCount 与安全 provisional 投影，输入锚点及提交后序号稳定；在下次 begin 或 terminal drain 安全提交过程边界，不泄露未决脱敏后缀、不并入 final；continued 尾部合法保留，Session 不受假违约污染。
- 输出规则不强于锁定合同；真违约的安全处置与交付、保留缺口分别闭合。
- 用量四字段原子更新，InvalidUsage 按 Host 失败分类；工具 digest 和 receipt 保持原机制，没有新迁移层。
- Run 和 compact 都退出以 raw status 存在性驱动本方案涉及的业务分支。
- 当前平台 canonical 场景、最小充分回归、正式验证和对应真源一起完成；静态审查与运行证据分别记录。

## 14 实施与验证记录

实施分支为 `feat/agentcore-integration-boundary`。A1（`80a1fcdd`）完成取消投递与真实 Host 故障归因；A2（`ec3db70d`）完成有限终态与健康交付；B（`4bcc144f`）完成 Agent 输出校验和 Product 合法内容保留；C（`4950dab5`）完成用量原子累计与本地错误分类。未升级 SDK/bundle、ABI、wire、schema 或 checkpoint 格式，没有工具 key 搬迁。

当前 Windows canonical Core 已通过实际 fork、pending 输入锚点、continued 后取消/下一流失败/max_turns、Session 复用和冷历史；实际 starting callback 中 abort、finalizing 接受 Stop 与 terminal TOO_LATE 分别验证。checkpoint 失效覆盖终态与后处理两种通知顺序。最终自查补齐 closing 中先校验 UI 再受控拒绝、Run 收尾不覆盖已开始的 closing，以及 callback lease 覆盖 fatal 记录。移除失去写入方的 Product terminal-drain 协议诊断链，保留历史格式中的旧分类。模型错误专项驱动已对齐现有菜单/诊断对话框，未修改 Renderer 产品实现。

运行日志保留于 `.zig-cache/agentcore-boundary-*.log`，边界场景快照位于 `.zig-cache/agentcore-boundary-evidence/agent-boundary.json`。这些可重现的自动化记录不进入长期平台证据账本。

正式 `npm test` 的 Node 阶段出现四项范围外失败：两个 dev 用例受既有 5173 端口占用影响；另两项为未修改的 Renderer 依赖方向和 Task MCP 建议按钮用例。后两项独立重跑仍失败，相关 frontend 与测试相对实施前 revision 没有差异；未修改其 guard、实现或既有开发进程。首轮 Native 暴露的两处旧 Product 状态预期已按本方案修正。最终正式 Native 图通过（253/253 steps，1840 passed / 10 skipped），`npm run check` 通过；Windows 输出交付、Agent 边界、模型错误三个专项及 Agent/Office 针对回归通过。`npm test` 整体仍因上述四项 Node 失败不通过，不绕过或弱化 guard。

评审后补充收口：段外提交容量不足和 final/partial 后续输出按保留缺口处理，后续 frame 不因本地保留失败失去接受状态，已保存回答与历史保持合法。Host 工具实际 fatal 记录故障或受控关闭事实，并参与 fatal/OK 对账；缺少边界事实的 CALLBACK_FAILED 才使用后备归因。describe 锁内只读例外已明确。本轮补充修复已通过评审。新增回归已先复现输出容量/后续段与 Host fatal 故障；修复后相关根、正式 Native 图（253/253 steps，1844 passed / 10 skipped）和 strict check 通过，本轮未重跑完整 Node 或桌面专项。独立复核提及的旧 Product→Agent Stop 交接竞态仅作为待复核线索，不在此轮修改。

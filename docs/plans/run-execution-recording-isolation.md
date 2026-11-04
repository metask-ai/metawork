# Run 执行与记录隔离方案

日期：2026-11-04。关联：[MetaWork #72](https://github.com/shuzuan-org/metawork/issues/72)。

状态：方案复审 APPROVE。实现已按依赖分步提交，覆盖有界 drain、可取消背压、真实执行结果与记录缺口、回执交接和移除 16；当前验证结果及剩余边界见文末，详细证据由 Git 与 TinyKG 任务 DAG 跟踪。正文额度、分预算和截断政策按用户决定延后另议。

本文是实施方案，不是 decision record，不替代现行规范。实施时同步更新第 10 节列出的相关真源；方案通过不表示代码、性能或平台验收通过。

## 1. 复盘结论与目标

问题的核心是记录链路取得了终止执行的权力：展示容量不足会使 Run 失败，队列消费超时还会令 callback fatal 并 poison Session。MetaWork 自设的 16 回合限制缩短了执行，掩盖了这些问题；只调大数字会把问题推入正常任务路径。

本轮目标是：**记录和展示容量不足只影响记录完整性，不再决定 Run 的生死。** 执行结果、记录完整性和已确认成果分别表达，最后废弃 MetaWork 自设的 16 回合策略。

复盘中应保留的取舍：

- 先闭合消费活性、关闭等待和终态屏障，再解除执行限制。
- 复用已有 owner、队列、Session 计数、RequiredWake、回执和历史字段；新机制须有实际缺口支持。
- 停止原因使用既有 cause 映射，不能把诊断细分扩成数据库改造。
- 区分源码核实、产品选择和运行时证据，不用方案评审替代实测。

## 2. 范围与责任

本轮选择可取消背压：队列满时生产者等待，消费恢复后继续；消费者即将停止时显式解除等待。保证消费压力不直接造成 Host callback fatal 或 Session poison，不承诺 GUI 停止消费时执行无限推进，也不绕过 Core 的存活监视。

| Owner | 责任 |
| --- | --- |
| Agent | 官方协议接受、执行控制、事件所有权、队列背压、Session 待消费计数、本地缺口、回执及 TerminalResult |
| Product Task / Control | 先核算后保留、执行结果和记录完整性、Run/compact 收口、历史校验与接续；仍在主循环提交产品事务 |
| Application | RequiredWake 接入、主循环调度，以及取消、close、shutdown 的组合顺序 |
| Bridge / Renderer | 运输并呈现 Host 明确提供的结果和完整性，不推断原因或推进执行 |
| Storage | 沿用既有同步 SQL contract，不取得事件消费或 Agent 生命周期职责 |

本轮不新增独立事件消费线程、正文存储、数据库 writer、事件扫描器、平行 decoder、SQL 列、触发器、迁移、cause 枚举或全局资源准入机制；不修改 AgentCore、SDK 或 canonical bundle，不向 AgentCore 提需求；不做 active Run 恢复、自动续跑或工具重放。

单事件接受边界保持现状：file_changes 沿用已登记降级，其余超限继续 fail closed。该边界是 Host 接受政策，不代表 ABI 有通用事件大小上限，也不宣称所有工具路径已逐项证明不会超限。

## 3. 消费、背压与终态屏障

### 3.1 有界 drain

主循环每次 drain 同时受事件数和墙钟预算约束，任一耗尽即返回主循环；有剩余事件时请求后续 wake，不在同一调用栈反复消费到全局队列空。保留跨 Session 公平性和控制容量。

时间预算在事件处理边界检查，不能打断单次同步提交。预算由唯一代码配置拥有，具体数值通过测量选择；单事件处理和提交耗时仍须满足既有主线程性能 Gate，不能只凭 drain 有界承诺 Stop 的固定响应时间。

### 3.2 正常背压和 Stop

合法事件完成 callback 侧接受校验和必要 owned copy 后尝试入队。队列 count/bytes 暂时不足时等待空间，取消以 100ms 消费 deadline 返回 EVENT_FATAL 的策略。

等待不得持有阻止消费者、abort 或 close 推进的 Session/Runtime 锁。普通 Stop 沿既有控制路径传递，主循环继续消费，使背压自然解除，不主动丢弃可消费事件。实际 allocator failure 不等于普通保留预算不足。

### 3.3 close、shutdown 与通知关闭

消费者即将停止推进的 close/join、主线程 shutdown/join 和 Agent Runtime 独立关闭路径，必须在等待 worker/callback 退出之前：

1. 在精确 Session/Run/generation 上安装粘性的“不再等待事件消费”状态。
2. 经既有控制路径请求取消，并唤醒等待入队的 callback；不能只唤醒 UI request。
3. 未入队的合法事件记录本地缺口、释放未转移的 owner，返回 EVENT_CONTINUE。该 Run 后续事件不再次等待；真实协议违约仍走原失败路径。
4. callback/Core/worker 静止后接收 TerminalResult，处理队列尾部、本地缺口、回执和既有生命周期屏障，最后释放资源。

缺口使用不依赖饱和事件队列的有界状态。已入队事件仍归队列所有，不重复释放或交接；新 Run 不继承旧退出状态。返回 EVENT_CONTINUE 只避免本地退出升级为 poison，checkpoint 能否导出仍由真实 Session disposition 和关闭顺序决定。

Agent 消费通知经 Application 端口接入既有 RequiredWake，复用其非阻塞 request、pending 合并和交付能力；drain 预算耗尽后也经此请求下一次 wake。不另加通知线程、pending 队列、周期 timer 或重试循环，不假设主循环存在通用周期调度入口。

通知返回 unavailable 表示消费路径已关闭，进入上述粘性退出；不返回 EVENT_FATAL，也不等待未来重试。RequiredWake 对真实底层通知违约的既有失败处理保持不变。

### 3.4 Run 和 compact 按 Session 收口

复用 EventPump 的 SessionUsage.count，只增加按精确 Session route 查询待消费数的接口，不新增事件序列。沿用同一 Session 的 Run/compact 互斥：下一项操作须等当前操作事件收口后才接纳。

Run 正式终态须同时满足：

- Core/Agent terminal 已发布，callback、输入提交和 abort 的既有静止条件成立；
- 该静止事实成立后，本 Session 待消费数为零，且主线程已处理完取出的事件；
- 本地缺口和 TerminalResult 补交回执已被 Product 接纳；
- 文件修改、checkpoint 等原 owner 屏障按各自合同处理完毕。

compact 同步采用“terminal 发布、callback 静止、本 Session 事件处理完毕”的屏障，之后才设置 event_stream_finalized。两者都不等待其他 Session 停止产出，不因一次有界 pass 返回就提前收口。

shutdown 在生产者静止后可重复执行有界 pass 处理有限尾部，不能仅 drain 一次就释放残留对象。若已知本地缺口覆盖段结束事件，未闭合段按记录不完整收口；完整轨迹仍严格校验，不能因存在无关缺口吞掉真实违约。

## 4. 核算、降级与执行结果

### 4.1 核算先于内容保留

| 事实 | 保留前必须完成的工作 | 容量不足时 |
| --- | --- | --- |
| 输出段 | 核算 index/turn/group、状态、完整原文字节数及 disposition | 标记实际提交组的缺口，不能用截断后的字节数校验 Core |
| Tool | 核算调用 identity、状态和必要计数，不依赖展示槽 | 省略详情或普通展示记录；后续 progress/result 不因无展示槽而失败 |
| 输入采纳 | 复用 callback 登记和终态 accepted/adopted counts 对账 | 不取消真实采纳，不伪造未采纳 |
| 可信回执 | 按第 6 节核验和交接 | 不因普通 Tool 展示容量不足丢失 |

核算与保留在原 owner 内分开，不另建 CoreEvent 协议。造成缺口的 owner 明确发布本地事实，下游不能凭残缺轨迹推断 Core 违约。

### 4.2 只有容量类错误降级

applyEvent 的 catch 必须明确分类，删除“除两种协议错误外都算 consumer_rejected”的兜底：

| 类型 | 处理 |
| --- | --- |
| 内容保留容量不足，如 ProjectionCapacity、ToolCapacity | 事实核算已完成后记缺口，继续执行，不请求终止 |
| InvalidOutputSegment、InvalidInputAdoption 等真实协议错误 | 记录依赖违约并终止 |
| InvalidDeliveryReceipt | 按实际合同或安全失败处理并终止，不能降级 |
| OutOfMemory 及其他非容量错误 | 由原失败 owner 处理并终止，不伪装成可忽略缺口，也不一概归因为 Core 违约 |

现有 ToolCapacity 中由“展示槽缺失”引出的错误须在核算与保留分离时消除，不能只在外层 catch 吞掉后宣称核算已完成。

### 4.3 记录完整性不覆盖执行结果

复用 event_projection_failure：consumer_rejected 只表达记录缺口，不覆盖实际 outcome/cause，也不单独终止 Run。dependency_contract_failure 仍表达真实失败，可覆盖已有 consumer_rejected，反过来不行。记录状态可从空直接成为任一事实，之后只向更严重的违约升级；所有写入点及终态 drain 都须遵守，不能“先写者赢”。

同步修正 completion_seen：所引用 Run 的正式 Product outcome 为 completed 即可，不再要求 event_projection_failure 为空。markCompletionSeen、归档的 acknowledgeLatestCompletion、历史编码、加载和 validateCandidate 保持一致。完成但有记录缺口的 Run 被查看或归档后，整份候选历史仍可保存；真正依赖违约的 Product outcome 不为 completed，仍不算完成。

正常完成后的输入接续依据 Session reusable、可信输入计数、binding 和原资格判断，仅展示缺口不一概禁止；真实违约、采纳不确定、失败/停止或不可用 Session 不自动接续。

本轮复用既有持久化列、枚举和完整性字段，不改 SQL、SQL codec 或迁移清单。completion_seen 涉及现有 SQL 关系列的组合校验，不新增持久化 JSON 字段或枚举。Product 架构历史版本条款的整理另行处理，不绑在本方案；若实施确实需要新的持久化表达，须先给出具体缺口评审。

## 5. 正文政策延后

用户决定本分支先完成底层修复，正文额度、分预算、截断和独立存储后续单独处理。本轮不引入新的正文保留或截断政策，也不将 G1 作为本分支的前置选择。

输出仍遵守 segment 的已有定性、continued/discarded 语义和凭据清洗规则；不得因本轮简化而静默改变最终回复完整性。正文容量路径若与正在修改的记录降级发生直接冲突，须明确指出边界，不能以“G1 已批准”处理。实施边界：沿用现有额度，内容无法完整保留时继续核算原始字节；已提交内容仍走原清洗，最终回复用既有 partial 表达，所有已知缺口通过独立的 recordingIncomplete 提示。这里不选择新的前缀长度、额度分配或持久存储方案。

## 6. 交付回执与生图引用

沿用现有有界 Agent 槽和 TerminalResult，不新增 Product 到 Agent 的确认协议：

1. callback 将合法 tool_result 与可信槽精确匹配，不能仅按工具名认定成果。
2. 入队成功后才移除 Agent 槽；入队与所有权转移须正确处理消费者立即取走事件的竞态。
3. Product 先核验、记录回执，再处理可降级的 Tool 展示。
4. 已合法匹配但因关闭未入队的回执随 TerminalResult 转移，与队列路径按稳定 identity 去重，恰好处理一次。
5. 未观察到合法匹配结果的槽不能无条件变成已交付，也不能从文件存在反推交付成功。

生图采用相同交接规则，引用继续放在 Tool.file_refs。带可信生图引用的最小 Tool 记录保留原 identity、顺序、必要状态和引用，详情可省略，记录不可随普通 Tool 淘汰；不新增 Run 级集合，不混入只接纳 DeliverFile 的 run.outputs。

实施核实：既有共享文本预算也会拒绝可信 locator，不能仅保护 Tool 槽。可信成果元数据沿用已有数量、字段长度和历史存储边界，仍经原 Host 清洗；普通详情预算不再拒绝该元数据。该区分同时落到实时接纳、冷恢复和释放，持久化格式不变。

此前未保留 Tool 行时，交接须携带可核验的原 Tool identity，淘汰普通详情或记录后补成最小记录，不能依赖丢失的文本反推。槽位容量关系已核实可行，共享字节额度仍需实施核对；不据此建立新的全局预留或准入机制。

引用沿用凭据清洗、locator authority、恢复和文件访问校验，不新增交付或读取授权。队列、TerminalResult、迟到消费、close/shutdown、Task 删除和 deinit 覆盖同一所有权规则；已确认回执不因记录缺口失效。

## 7. 停止原因、执行上限与恢复边界

policy.zig 仅拆开当前合并且 cause 为 null 的分支，复用已有值：

| AgentCore stop_reason | Product phase / outcome | Product cause |
| --- | --- | --- |
| max_turns | stopped / stopped | resource_limit |
| tool_loop | stopped / stopped | tool_failure |

保留真实依赖违约和外部 termination signal 的原决策优先级，不新增 cause 或通过诊断文本反向解析控制决策。诊断仍走既有有界清洗与安全呈现通路。

容量降级、控制和收口路径落地后，最后删除 MetaWork 自设的 16，改用 SDK 的 MAX_TURNS_V1。该值是锁定 ABI 必填参数的依赖边界，不变成用户对话次数限制、产品设置或自动续跑策略。

Run 受控终止保留 stopped；Task 可等待新的用户意图，这不等于存在同步 waiting_ui 请求。修正 awaiting_user 文档歧义，不新增 Run phase。

背压可能阻止 Core 继续读取流并触发其存活监视。保留真实 Core 结果和可证明的 Host 观察，不凭停顿时长改写 provider category，不关闭 watchdog，也不承诺统一的“暂停 120 秒才失败”。

本轮不实现 active Run checkpoint。崩溃或 poison 后，未进入成功 checkpoint 的 Conversation 不能恢复，Product 历史和 Workspace 文件可能仍在；向用户明确此边界。只消费已确认 opaque checkpoint，不解析私有 transcript、不回放工具、不伪造空 Conversation 恢复，已发生的文件效果不回滚。

## 8. 实施顺序

| 步骤 | 工作及完成条件 |
| --- | --- |
| 1 | 有界 drain，Run/compact 按 Session 计数收口；验证跨 Session 公平性，测量单事件和提交耗时 |
| 2 | 可取消背压、RequiredWake 和关闭前粘性唤醒；验证普通 Stop、close、shutdown 不死锁、不因本地退出 poison |
| 3 | 核算与保留分离，明确错误分类和违约升级，修正 completion_seen 与输入接续，落实回执尾部交接和生图最小记录；正文政策按第 5 节延后 |
| 4 | 修正既有 cause 映射和相关文档歧义；前述机制可用后最后删除 16，使用 MAX_TURNS_V1 |
| 5 | 完成真实执行、桌面及历史重开验收，收集性能与 watchdog 证据后报告完成 |

各步同步修改实际变化的规范和测试，不保留平行 active path，不发布只删除限制而未修复容量语义的中间状态。每个 DAG 子任务完成后检查验证和改动完整性，评估是否及时提交；未通过必要验证的实现不能标为完成。

同步提交先测量，再决定是否需要合并；文本合并同样只在测量证明必要后考虑。若实施优化，须保持持久边界、提交失败/未知结果、凭据清洗、输出顺序及 encoded_bytes/json.len 等所有权不变量，不能预设合并没有语义影响。

## 9. 验收与待核对事项

| 场景 | 必须观察的结果 |
| --- | --- |
| 正常任务跨过原 16 回合 | 同一执行继续并正常结束，无 Host 自动续跑或重放 |
| Tool、过程说明或输出保留不足 | 先完成核算，执行终态真实，缺口明确；无展示槽不使后续事件失败 |
| 暂停 drain 直至队列饱和后恢复 | 内存有界，callback 背压，恢复后顺序消费，无 Host fatal/poison |
| 持续并发产出并注入慢提交 | drain 返回主循环，其他 Session 和 Stop 获得调度；记录实际处理耗时 |
| 队列饱和时普通 Stop | 主循环继续消费，不主动制造缺口，等待真实取消结果 |
| 主线程真实阻塞 | Stop 等主线程恢复后处理；不能用仅暂停 drain 的模拟替代此场景 |
| close/shutdown/join 与 RequiredWake 关闭竞态 | 先唤醒再等待，后续不再阻塞，无本地 poison、lost wake、空转或重复释放 |
| Run/compact 终态后仍有本 Session 尾部事件 | 处理完本 Session 后收口；其他 Session 持续产出不阻塞，也不提前 finalized |
| 先有缺口，后有真实违约 | 真实违约覆盖 consumer_rejected 并终止，后续缺口不能反向覆盖 |
| 无效回执、OOM 等非容量错误 | 不进入可继续的容量降级分支，保持实际失败归因并终止 |
| segment continued/discarded/partial/final 与跨 chunk secret | 按完整原文字节核算，废弃内容不发布，保留内容及历史重清洗不泄露凭据 |
| 交付、生图遇到 Tool 淘汰、全局字节压力或关闭 | 回执不丢不重，最小生图记录保留，历史重开可见，不新增授权 |
| 完成但有缺口后查看、归档、保存和重开 | completion_seen 合法，整份历史及其他 Task 继续保存；真实违约不算完成 |
| max_turns、tool_loop 和单事件超限 | 既有 cause 映射准确；单事件接受 Gate 保持现状，无 SQL 或 migration 变更 |
| Run 中崩溃或 poison 后恢复 | 只恢复已确认 checkpoint，明确缺失范围，文件不回滚、不自动重放 |

实施时仍须核对生图最小记录的共享字节额度、单事件/同步提交成本，以及背压对 Core watchdog 的实际影响。它们是实施和验收责任，不是新增产品选择，也没有运行时证据可供提前宣告通过。

按失败模式选择 Agent、Product 及必要 integration 测试；Bridge/UI 变化追加跨语言 fixture、typecheck 和受影响 Renderer suite。生命周期与真实执行链使用 canonical staged bundle，缺依赖明确失败，不能跳过后报告通过。具体入口、性能 Gate 和平台矩阵遵循[验证规范](../validation.md)。

## 10. 规范归属

本文整理阶段不修改现行真源。实施仅同步实际改变的合同：

| 真源 | 对应变化 |
| --- | --- |
| [产品需求](../requirements.md) | 正常执行、记录缺口及恢复边界的用户可观察语义 |
| [AgentCore 集成契约](../agentcore-integration.md) | 背压、控制唤醒、缺口、回执、Run/compact 屏障和停止映射 |
| [Product 架构](../product-architecture.md) | 核算与保留、真实结果与完整性、完成已读、输入接续及成果引用 |
| [Renderer Bridge 合同](../renderer-bridge-contract.md) | 必要的完整性表达；保持现有正文预算合同，不新增 cause 或自动递增 revision |
| [UI 设计规范](../ui-design.md) | 执行结果、记录/正文不完整和恢复限制的呈现 |
| [验证规范](../validation.md) | 活性不变量、验收责任与经验证后形成的长期证据 |

不修改 AGENTS.md、Storage 合同、SQL、迁移清单、cause 枚举域、ABI 或依赖 lock。若发现必须改变这些边界，先提供具体必要性并重新评审，不能以实施方便扩大范围。

## 11. 本轮实施验证

- 分步提交：`735931fa` 有界 drain，`88600ae6` 背压与关闭，`4372b5ca` 结果/记录隔离及完成已读，`0e649b35` 可信回执，`230adf9e` 移除 16 与既有 cause 映射；无 SQL、迁移、依赖 artifact 或 AgentCore 修改。
- canonical Core 的单 Run 完成 40 次 Bash 调用、41 次 Provider 请求；超过 32 个 Tool 展示槽后仍 completed/reusable，缺口进入历史，无自动续跑或重放。
- 生产队列积压至少 100 个事件，20ms 注入提交延迟下，drain 约 39.6ms 后返回，Stop 后仍有 95 个待消费事件，约 486.6ms 后正式 cancelled/reusable，未标记本地事件交付丢失。这是 Debug framed writer 调度实验，不是 SQLite 基准或固定 SLA。
- 正式 Node/Renderer 测试 1,234 passed、2 existing skipped，typecheck 与严格 Native 静态检查通过。相关 Control/lifecycle/image roots 542 passed、3 existing skipped；Office canonical pipeline 9 passed，包含饱和慢提交和跨 16/32 场景。
- macOS arm64 实际 automation 桌面 active-input vertical 通过 Stop、后续新意图、输入接续、Skill 等待、超时对账及冷重启不重放。现有 Office 桌面入口另通过实际 DeliverFile 回执与冷历史投影；其 direct Run 接回已有 fresh-catalog 等待 helper。architecture/Office guards 45 passed，fmt/diff 检查通过。
- 完整 Native 图实际执行为 1,694 passed、11 skipped、7 failed，另有 CoreFoundation 链接失败；干净基线 `7720b2b3` 上的定向 MCP platform/interop/configuration/app roots 复现完全相同的 7 个失败及链接错误。本轮未改动或豁免这些 Gate，完整图不得报告通过。
- 长时间背压下的 Core watchdog 和生产 SQLite 的完整历史性能分位未测；不承诺无限暂停或固定 Stop 时延。单次同步提交仍不可被 drain 预算打断，active Run checkpoint 恢复仍不在本轮范围。

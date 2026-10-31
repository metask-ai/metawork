# Agent 运行状态整改方案

本轮修复活动提示的错误覆盖与收口规则，并保留能够帮助用户理解工作的活动信息。复用现有 RunPhase、RunActivity、正文和 Tool records：生命周期决定任务是否在运行、等待或结束；活动提示表达当前运行过程的最近已知工作；正文和工具记录承载具体证据。

方案已通过两轮评审，无阻塞项；实现和验收仍待完成。本文是实施计划，不是 decision record 或已验证实现的描述。状态消费、wire、呈现和验证分别遵守 [AgentCore 集成契约](../agentcore-integration.md)、[Renderer Bridge 合同](../renderer-bridge-contract.md)、[UI 设计规范](../ui-design.md) 和 [验证规范](../validation.md)。实施时同步收口与本方案不一致的现有改动和真源章节。

## 1 复盘结论与修复边界

已确认的产品缺陷在事件消费与呈现层：通用 `progress` 会在模型请求前发出，却被 Product 用来覆盖 typed activity；`stream_done` 被误作 Run 收尾；工具数量从记录重算或未充分呈现。修复应保留 Core 的明确阶段依据，同时允许模型内容信号提供更具体的活动提示。

真实模型样本确认模型确实返回过大量 `thinking` 内容，但不能据此把全部耗时解释为思考，也不能仅凭同一标签持续较久判定产品故障。模型或网关性能是否合理不属于本轮状态修复结论。

本轮遵守以下边界：

1. **生命周期与活动分开。** `RunPhase` 决定产品是否运行、等待或结束；`RunActivity` 表达运行过程的最近已知活动。thinking、writing 无须成为 Core phase 才有展示价值。
2. **观察不等于精确计时。** 缺少 `thinking_end` 限制精确时间划分；保留思考活动不表示期间一直在思考，不统计纯思考时长，也不用定时器换词。
3. **正文分段与执行阶段分开。** `segment_end` 只关闭或定性内容，不触发执行阶段回退。`stream_done` 清除本流活动观察，不建立 finalizing 或 completed。
4. **工具数量与物理并发分开。** 数量表示未闭合调用尝试，可能等待执行、被拒绝或已在预取中执行。保留有依据的单工具类别。
5. **只消费现有 canonical SDK。** 本轮不向 AgentCore 提新需求，不修改依赖、公开协议或持久化格式，不建立平行状态平台或新增模块。

## 2 桌面竞品依据

仅参考 Codex Desktop 和 Claude Desktop 的官方产品资料。下表描述资料公开的体验，不据此推断未公开的内部状态机或把其他客户端的协议当成桌面设计。

| 参考                                                                                                                 | 官方资料支持的体验                                         | 本方案采用的原则                                               |
| -------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------- | -------------------------------------------------------------- |
| [Codex Desktop 产品介绍](https://openai.com/index/introducing-the-codex-app/)                                        | 独立任务线程、切换任务和检查工作变更                       | 用户能够监督任务整体进程并检查具体结果                         |
| [Codex Desktop 更新记录](https://learn.chatgpt.com/docs/changelog?date=2026-10-15)                                   | 自动审批有独立过程反馈；任务完成、权限请求和提问有对应通知 | 忙碌、等待介入和完成清楚区分                                   |
| [Claude Thinking 说明](https://support.claude.com/en/articles/8664678-change-the-model-effort-and-thinking-settings) | Thinking 指示、计时和可展开的思考摘要                      | 保留思考活动的可辨识性；可展示摘要须有自己的内容合同           |
| [Claude Desktop 的 Cowork 说明](https://support.claude.com/en/articles/13345190-get-started-with-claude-cowork)      | 步骤进展、工作方式说明和执行中引导                         | 过程信息与整体任务状态一起呈现，沿用真实 commentary 和工具记录 |

这些资料用于确定任务监督、活动辨识和用户介入的产品目标；实现沿用现有状态与内容对象，不直接展示 Core private thinking。

## 3 状态模型与所有权

沿用现有 owner 和依赖方向。Agent 负责官方 SDK 解码、callback 身份、事件入泵和生命周期；Product Task 消费 typed observation 并派生唯一 RunActivity；Renderer 本地化和呈现产品事实，不解析 Provider SSE、不推进执行。

| 事实                                                             | 责任                                                                  |
| ---------------------------------------------------------------- | --------------------------------------------------------------------- |
| Product active phase、terminal payload 和 event-drain barrier    | 控制产品生命周期及最高优先级呈现                                      |
| 已验证的 Core phase、turn、transition sequence 和 in-flight 集合 | 提供运行背景、硬阶段和调用数量                                        |
| 当前模型响应的活动观察                                           | 只记录 none、thinking 或 writing 及其有效范围，不保存正文或事件时间线 |
| retry attempt、max、delay                                        | 只丰富当前 retrying，不独立建立阶段                                   |
| output segment、commentary、response 分类                        | 负责内容生命周期及既有明确收尾依据                                    |
| Tool records、progress、result 和文件证据                        | 负责单次调用记录，不反向改写 Core phase                               |

模型活动观察是 Product Task 内一个有界运行时字段，取值为 `none / thinking / writing`，复用现有事件消费路径。Core 活动依据的可信度须独立表达：现有 `agent_observation_degraded` 还用于上下文和 retry 详情等诊断，不能直接等同于 Core phase 已失效。优先复用可表达该事实的现有状态，必要时仅增加一个运行时可信度标记；不保存内容副本、事件时间线或第二份终态。

作用域规则依赖已核实的事件顺序：Core 在对应公开事件之前发出 `run_state`；每轮开始的 `progress` 推进 turn 并先发 generating 快照。因此 retry 详情到达时已有 retrying 依据，工具一致性检测则须等对应记录更新后进行。实施使用 [当前平台 exact lock](../../build_support/agentcore-bundle.macos-aarch64.lock.json) 所指向的 canonical SDK，不将这份计划作为依赖版本真源。

## 4 活动派生和优先级

先处理产品生命周期，再为普通 running 选择互斥分支：

1. 正式 Product terminal facts 已形成：activity=null，展示既有 outcome/cause。
2. worker 已发布 terminal、但完整 drain 尚未完成：activity=finalizing，不能提前发布产品 completed。
3. Product queued、waiting_ui、stopping：分别展示排队、等待用户和停止。
4. **Core 活动依据已失效：** 直接按第 5.1 节显示降级，不再用保存的旧 phase、数量或 retry 详情派生活动。
5. **没有失效证据，但尚未建立有效 Core phase：** 显示 starting；已有明确收尾事实按下段处理。不从内容、Tool 列表或时间猜造执行阶段。
6. **已有可信 Core phase：** starting、waiting_ui、retrying、compacting、executing_tools、finalizing 及 Core terminal observation 按明确语义呈现，优先于模型内容；只有 generating 才使用本次响应的最近已知模型活动，`none` 对应 waiting_model。

同一 Run 已成功提交 final/partial response 分类时，沿用既有在无 Core phase 或可信 generating 中显示 finalizing 的规则，优先于模型活动观察；不覆盖明确的工具、等待、重试、压缩阶段，不把 partial 解释为成功完成。Core 依据失效时使用第 5.1 节的降级分支。正式终态仍须等待结果映射和 drain。

| 事实                                   | 既有 wire activity             | 建议中文              | 建议英文                   |
| -------------------------------------- | ------------------------------ | --------------------- | -------------------------- |
| queued                                 | queued                         | 排队中                | Queued                     |
| starting                               | starting                       | 正在准备              | Getting started            |
| generating，当前响应尚无更具体活动观察 | waiting_model                  | 正在处理              | Working                    |
| generating，最近收到有效 thinking 增量 | thinking                       | 正在思考              | Thinking                   |
| generating，最近收到有效正文增量       | writing_response               | 正在输出内容          | Generating content         |
| executing_tools，已知 N 项未闭合尝试   | executing_tools，inFlight=N    | 正在处理 N 项工具调用 | Processing N tool calls    |
| executing_tools，数量未知              | executing_tools，inFlight=null | 正在处理工具调用      | Processing tool calls      |
| waiting_ui                             | waiting_user                   | 等待你处理            | Needs attention            |
| retrying                               | retrying_provider              | 正在重试模型请求      | Retrying the model request |
| compacting                             | compacting_context             | 正在整理上下文        | Organizing context         |
| stopping                               | stopping                       | 正在停止              | Stopping                   |
| 有效收尾依据                           | finalizing                     | 正在收尾              | Finishing                  |

文案表示产品正在处理的逻辑活动，不承诺模型或工具此刻的 CPU 行为。“正在输出内容”不预判正文最终是 commentary 还是 final。展示“正在思考”不开放推理正文，也不产生“思考了 N 秒”的统计。

## 5 模型活动观察的生命周期

Core 活动依据可信时，仅在当前 Run、有效 generating 范围内接纳模型活动观察；依据失效后按 5.1 节接纳新的内容观察。有效非空 thinking 增量记录 thinking；通过现有输出分段验证的非空 text 增量记录 writing。重复同类观察不单独重复发布 activity revision，正文变化仍按现有规则发布。

以下边界清除旧模型活动观察：

- 进入新 Run、新 turn，或 Core phase 离开 generating。
- generating 范围内开始新的模型响应内容流；现有 output_segment_begin 可用于重置观察范围，但不能把它解释为“开始写回复”。
- generating 范围内本次 stream_done；这是清除本次内容观察，不是 Run 收尾。
- Product 停止、等待用户或 terminal 收口使当前模型活动不再具有呈现资格。

同一个 generating、同一个 turn 的重复有效 run_state 不因为 sequence 推进而机械清空观察。离开后重新进入 generating，必须使用新的观察范围。低优先级内容事件不能恢复工具、审批、重试或终态之前的活动。

segment_end 的 commentary、continued、discarded 分支只处理正文；它们不自行建立“等待模型”“思考”或“输出”的运行转换。输出分段与 Provider stream 的边界职责分别验证，不能依赖它们在当前实现中恰好相邻。

当前公开信号无法确定最后一次 thinking 到工具参数生成之间的精确切换点。因此标签可能在没有新活动观察时保持到明确的响应流边界；这是最近已知活动的显示约定，不能用来计算真实思考时长。本轮接受此观察粒度。

### 5.1 Core 活动依据失效时的显示规则

失效必须有具体证据，不按经过时间或任意诊断标志推断：

- Product 拒收影响当前 Run 活动依据的 run_state，例如身份或 phase 转换不合法。现有 Agent/SDK 的 fatal 拒绝和 termination 路径仍然生效；显示降级不能把拒收变成接纳。单纯忽略重复或过期 sequence 不自动判定最新已接受快照失效。
- 经过当前 Run 路由与工具事件校验后，消费完相应 tool_start/result，比对最后快照的 agent_in_flight_tools 与当前 running 记录数。快照先于对应公开事件到达，必须在对应记录更新后比对，不能在两个事件之间误判。此处只做计数一致性检测，不保存整份快照的 ID 或摘要集合；记录数只用于判断依据是否失效，不替代正式 inFlight。
- 锁定 Core 存在因内部工具集合上限而停止中间快照、终态仍发快照的实现路径；它是需要覆盖的依赖行为，不是应硬编码的新 public contract。检测依靠上述可观察不一致，不假定存在公开的“已停止快照”事件。

失效时停止投影旧阶段、旧调用数量、单工具类别与 retry 详情，并清空旧模型活动。停止投影不等于删除原有校验依据：最后已接受的身份、sequence、phase 等仍按既有规则用于后续校验。Product terminal、drain、queued、waiting_ui、stopping 的高优先级保持不变。普通 running 使用 waiting_model 的通用“正在处理”；之后新的合法 thinking/text 可更新最近活动，stream_done 清除本流内容观察，不能收尾 Run。降级内容只代表当前 Run 最近观察，不承诺其嵌套模型来源。

后续通过原有 identity、sequence 和 phase 校验的新快照可以恢复 Core 依据；恢复时重置模型活动范围，并与对应工具边界复核。先前拒收的事件不因此重放或取得 authority。若原有校验拒绝恢复，则继续保守显示，由既有结果和 drain 收口，不放宽 guard。

上下文数值或 retry 详情单独无效，不当然使 Core phase 失效；该区别必须有回归。容量或安全失败照原合同终止，不能通过降级继续执行。当前默认 Product 工具记录上限先于 Core 的内部工具集合上限，真实默认链路应验证原有容量拒绝；停发快照轨迹用确定性回放或显式测试限额观察，不提高生产限额。

## 6 工具信息与需要用户介入的事项

inFlight 只来自同一有效 Core run_state 的集合大小。沿用 nullable wire 规则和现有接受边界，accepted executing_tools 空集合显示未知数量，不由 Tool records 重算，不发送已知零值。Tool start/progress/result 更新所属调用记录，不能覆盖 Core phase 或集合。

保留已有单工具类别信息，例如“检查工作区”“更新内容”“运行操作”，不降成一律只显示数量。Core 依据可信、已知未闭合数量为 1 且记录一致时，沿用当前有序 start/result 配对和单条 running 记录显示类别；多项、未知名称、记录尚未到齐或已降级时显示数量或通用文案。Tool 的 running 文案采用“处理中 / In progress”，名称、安全摘要和结果继续在既有可展开记录中呈现。

SDK 已提供 `tool_call_id/name`，Product 已有 `toolRouteDigest/findTool` 关联机制；单工具类别确需精确匹配时，在 Host 复用这些字段。身份关联只服务类别显示，不扩展为整份快照的 ID 集合，不持久化 raw ID，也不将 raw ID 送给 Renderer。快照先到、记录后到的短暂不一致只影响该次类别可用性。

等待用户、自动审批、请求停止和不同步继续沿用既有提示与操作入口。retry_notice 只丰富有效 retrying 范围，离开阶段或进入新 turn 后详情失效；不猜失败一定来自连接。auto_compact 更新结果，阶段退出仍由有效 Core 观察决定。

复用既有 Bridge union 中的 `thinking`、`writing_response` 和 nullable 工具数量，不新增 wire 字段。Renderer 只呈现 Host 派生的产品事实；工具身份关联在 Host 内完成。

## 7 反例复核与回归要求

下面是方案必须满足的反例，不代表正式实现已经通过测试。

| 轨迹                                                        | 期望                                                                                         |
| ----------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| generating → thinking → 长时间没有新种类事件                | 可以保持最近已知思考活动；不能声称全部经过时间都是纯思考，不能凭时长判故障                   |
| generating → text → commentary segment_end，Core phase 不变 | 内容块关闭；不存在 Core 阶段回退，不凭块关闭猜下一项活动                                     |
| generating → stream_done → 工具调用                         | 清除本流内容观察；不能先 finalizing，再靠工具事件恢复执行                                    |
| 执行工具或等待用户期间到达内容事件                          | 正文按原协议处理；主活动不被低优先级内容覆盖                                                 |
| 同 phase、同 turn 的 run_state 重复采样                     | 不反复退回通用标签；新 turn 或重新进入 generating 不沿用旧观察                               |
| 多个 stream、continued、discarded、partial 和 retry         | 内容保留或撤回正确；旧活动与 retry 详情不跨作用域泄漏；partial 不冒充完成                    |
| 当前 Core 集合与 Tool records 到达不同步                    | 按对应 start/result 更新后的有序边界核对；过渡期不误报，可信单工具类别保留                   |
| 拒绝、排队或预取调用                                        | 数量与文字不承诺实际 dispatch、成功或物理并发                                                |
| Core completed、worker terminal 与完整 drain 分别到达       | drain 前不发布产品终态，之后 activity=null；迟到事件沿既有合同处理                           |
| 嵌套模型工具、子代理或隔离 Skill                            | 核实实际外层事件投影；子流不能覆盖父级工具、等待或终态                                       |
| run_state 被拒收后仍有合法内容                              | 不接受被拒事件；旧 Core 活动与数量失效，合法新内容可提供降级活动，正式终态仍由原有提交链收口 |
| 工具事件继续但快照停止                                      | 相应记录更新后的不一致触发显示降级，不长期展示旧调用数；后续合法快照可恢复，原校验不放宽     |
| context/retry 详情无效但 phase 有效                         | 只降级对应详情，不误判整个 Core phase 失效                                                   |
| 重复或过期快照被忽略                                        | 不误伤当前可信依据                                                                           |
| 降级后的恢复快照仍被原校验拒绝                              | 继续降级，不能清空校验历史以强行恢复                                                         |
| 默认工具容量先耗尽                                          | 保留原有明确容量失败，不为复现内部上限扩容或继续执行                                         |
| reload、切换 Task、不同步、停止请求                         | 沿用 Host 事实和既有反馈；Renderer 不另起执行状态机                                          |

特别检查正文分段、身份或嵌套来源的依赖拒绝。不能放宽 framing、修改 allowlist、绕过 verifier 或跳过用例来使映射通过；发现独立依赖缺口时按真实阻塞范围报告。

## 8 实施范围和顺序

1. **固定基线。** 记录实际 checkout、commit 和未提交 diff，逐项复核已有修改；保留正确的 progress 修复、typed phase 校验、调用计数和 terminal drain，不假定其他机器或 worktree 已具有这些改动。
2. **实现 Product 投影。** 在 Product Task 内按第 4、5 节收口活动派生、模型观察范围及可信度恢复；工具记录、通用 progress、正文块结束和时钟均不得接管执行阶段。
3. **接通 Renderer 呈现。** 保留 thinking、writing_response 的独立文案及单工具类别，呈现可信数量、未知数量、审批和停止反馈；降级时停用旧类别与数量。正文和工具记录继续承载具体证据。
4. **同步领域真源。** 按实际合同变化收口 [AgentCore 集成契约](../agentcore-integration.md)、[Renderer Bridge 合同](../renderer-bridge-contract.md) 和 [UI 设计规范](../ui-design.md)，分别定义消费、wire 和呈现，不复制同一规则。
5. **完成验收。** 在对应 owner 的现有测试中命中第 7 节失败模式，再完成正式调用链和当前平台真实窗口验收。旧测试结果或元数据模拟不能作为本次实现的验收结果。

主要改动落在 `src/product/task/state.zig`、Product serializer、现有 task Renderer、i18n、跨语言 fixture 和受影响 suites。requirements、顶层 architecture、project-structure、AGENTS 和存储 schema 不因本轮实现机械修改。

## 9 验证和完成标准

实施后按验证规范完成受影响文件的格式检查，并运行以下关联入口：

```sh
npm run check
node --test scripts/run-presentation.test.mjs scripts/task-panel.test.mjs scripts/workbench-contract.test.mjs scripts/bridge-client.test.mjs
zig build test-product-control -Dtarget=aarch64-macos --summary all
zig build test-lifecycle -Dtarget=aarch64-macos --summary all
node scripts/test-agentcore-vertical-macos.mjs
git diff --check
```

缺少 canonical staged bundle 时明确失败。只有存在独立平台失败模式才扩大矩阵，当前平台通过不代表其他平台已验收。

真实窗口使用重新启动的 npm run dev，确保 Native 与 Renderer 配对；Native、Bridge 或 wire 语义变化不能只依赖 HMR。通过有限的极短回复、一次短 Write 和有界页面生成观察思考、正文、工具、收尾及正式终态。重试、审批、压缩与异常顺序使用确定性 fixture/vertical，不为触发它们反复付费调用模型。

验收关联同一 Run 的 typed 事件、Host activity 和实际显示，允许 ProductDelivery 合并极短阶段。总耗时继续标为“本轮已用时”，不显示思考专用计时或从标签反推耗时。诊断只保留必要的类型、计数、时间和字节长度，不记录推理正文、参数、credential 或原始响应；临时 instrumentation 验收后移除。

完成须同时满足：有用活动信息保留；优先级与观察范围正确；正文和生命周期分开；数量与文案不夸大事实；public contract、安全和依赖 gate 完整；正式回归和真实桌面通过。元数据上的规则推演只用于发现反例，不能替代以上验收。

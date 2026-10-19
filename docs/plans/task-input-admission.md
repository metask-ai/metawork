# Task 连续发送实施方案

用户可以持续输入和发送，Task 接收消息后负责决定何时插话、等待或启动下一轮。前端不选择执行 Run，不等待执行准备，也不因 Run 启动、停止或收尾而拒绝有效发送。

本轮补齐 Task 的消息处理职责，复用现有 Run、动态插话、未采纳输入接续和生命周期机制。本文是实施计划，不是 decision record；运行代码和规范合同尚未修改。

## 1 问题与目标

当前 Composer 根据快照选择 idle 或 active Run，发送前还编排 Skill 准备和会话恢复。Host 再按该执行目标的真实状态决定是否接纳。前端承担了执行决策，快照与真实状态的竞争又把内部切换暴露成发送拒绝。

受控 lifecycle 测试已经复现：Run completed、active operation 已清除、checkpoint settled，但标题 worker 尚未退出时发送返回 task_busy。这证明执行收尾会挡住发送；不能据此认定截图中的那次拒绝必然由标题生成触发。

调整后的成功边界是 Task 已取得消息所有权，不是 SDK 已接收插话或新 Run 已启动。Session、worker lease、checkpoint 等门禁继续保护实际执行，不再决定普通消息能否接收。

范围包括已有 Task 和首次创建期间的文本、Skill、已完成 staging 的附件消息。内容无效、附件尚未准备好、断连、Task 不可写、真实 authority 失效或容量耗尽仍如实处理；内部执行阶段不能成为拒绝理由。

## 2 职责边界

| 层次 | 职责 |
| --- | --- |
| Renderer | 编辑草稿、添加附件、提示内容错误，提交目标会话、消息和停止意图，关联回执并展示状态 |
| Bridge | 校验 wire、来源窗口和连接，调用产品入口，传递结果及 Snapshot；不组合执行步骤 |
| Task aggregate | 独占消息接纳、待处理输入、顺序和状态；决定插话、等待或下一轮准备；处理采纳、接续、停止、失败及任务内资源生命周期 |
| Product Control | 协调 Workspace、Models、Skill、Attachment、Schedule 与共享 Executor 的跨 aggregate 准入、资源转移及发布事务；将依赖结果交回 Task |
| Agent | 提供公共执行能力、Session 控制、SDK receipt 和事件事实，维护调用、取消及销毁屏障 |

Host 是运行位置，不是消息规则的领域 owner。Task 仍是 Product Control 持有的 aggregate，不新增顶层 owner；Control 不持有第二份消息队列，不复制 Task 的局部调度规则。

Task 通过现有窄能力和依赖事实推进，不导入 Models runtime、其他 aggregate 的内部实现或 SDK。Skill、Models、附件暂存和 Agent 的状态机仍归原 owner，不把它们全部搬进 Task。

## 3 消息接收与推进

### 接收事务

普通发送只表达“向这个 Task 交付这条消息”。移除 Composer 的 idle／active Run 目标和执行 binding epoch 前置选择；窗口、连接、Task、Workspace 与资源 authority 继续由对应边界验证。模型选择沿用独立的用户操作，不靠前端猜测 binding 决定能否发送。

一次接收在主线程完成以下事务：

1. 验证真实接收资格、内容和预算，由 Control 协调一次性附件 grant 与所需资源的线性移交。
2. Task 预留安全展示记录，取得执行输入的唯一 owned copy，并追加到有界待处理列表。
3. 确立该 operationId 已接收的事实；当前文本 Run 已就绪且队首可插话时，可以在同一次主线程处理中同步投递，其他情况由 lifecycle wake 推进，最终发布 revision 并返回接收结果。

接收边界前失败不发布已接收，也不能部分消费附件。接收边界后的投递结果不能反向将消息改判为未接收，而是更新该消息的执行状态。接收不等 Executor、标题、checkpoint 或其他长操作；允许就绪文本通过现有 Agent 同步控制调用立即投递，不强制另等一次 wake。

### Task 状态与数据

复用现有 operationId 关联一次提交，以列表顺序表示先后，不新增持久化消息序号或回执账本。Task 接收记录只增加必要事实：接收时间、安全 input 投影、等待或投递中状态、执行关联及运行时失败原因。具体失败原因只供当前进程展示，不序列化到历史；执行原文也只在 Host 内存中持有。

消息依次从等待进入投递中，再交给现有 Run 根输入或 additional input 记录。operationId、接收时间和展示位置随所有权移交保留；取消或未执行的失败记录只保留安全内容。原记录与执行记录不能同时投影出两个用户气泡。

Task 待处理数量由 Product Limits 唯一配置，原文和附件复用现有共享字节及文件预算。队列容量与 Core 每 Run 的累计提交额度分开；转移所有权不能重置配额。接收前预留安全展示记录，实际同步投递前沿现有路径预留 additional input 候选和结果空间，避免 SDK 已产生效果后无法登记结果。

队首领取和实际 Run admission 在同一主线程事务中完成，自身等待预留不能阻挡自身执行；其他显式 run 请求不能从中间空隙抢先。重复 lifecycle wake 不重复领取，也不为已取消消息重新建立准备。

### 推进规则

接收时的就绪检查和现有 lifecycle wake 共用 Task 的同一队首推进逻辑，Control 仅完成相应跨对象事务和效果调度：

| 当前事实 | 队首处理 |
| --- | --- |
| 文本 Run 可插话，队首为普通文本 | 走现有 Agent submitInput |
| Run queued／starting，尚未 ready | 等待 readiness 或终态变化 |
| 当前是 Skill Run，或队首含 Skill／附件 | 等当前操作收口，按新 Run 执行 |
| Run 已结束，但事件、worker 或 checkpoint 未收口 | 保留消息，等待原有执行门禁 |
| 标题、compact、restore 或合法配置准备进行中 | 保留消息，等待已登记步骤收口 |
| 无 active operation，依赖及执行准入均满足 | 领取队首，走现有新 Run admission |

前端 ensureSkills、ensureContinuation 不再编排发送前置步骤。Task 记录所需准备，Control 调用对应 owner，结果回到 Task；同一准备只登记一次，明确失败不循环修复。

每 Task 同时最多一个输入投递调用，新消息不得越过较早等待的 Skill 或附件。SDK 明确未接收的 not ready、stale、stopping、too late 等时序结果仍归 Task 等待，仅在相关事实变化后推进。Host 可证明当前 Run 提交额度已耗尽时等待下一轮，不反复调用 SDK；invalid input、会话不可用、checkpoint budget required 及不能证明为暂时额度限制的 resource limit 独立按真实失败处理，不无限重试或自动 compact。

已被 SDK 接收但正常终态确认未采纳的输入，继续按现有后缀合并、单条预算和一次接续语义执行，先于后来输入。复用原合并函数，待处理列表引用原 Run 记录，不复制安全正文或建立平行执行路径。新 Run 已准入后发生 enqueue 或执行失败，保留该 Run 的真实终态，不能退回队列再试。

### 同步投递与现有生命周期保护

复用主线程上现有的 RunControlLease.submitInput → submitControlledInput 同步调用。官方 Session submit_input 与 abort 同属可和匹配 Run 并发的控制能力，不需要等待 Run 完成，不能仅因接口同步就为其增加 Executor job、独立提交通道或异步结果归并。

每 Task 同时最多一次投递，receipt 在调用返回后立即安装。采纳事件早于 receipt 的合法竞争、Run 返回前等待已登记调用退出、SDK 借用结束前原文保活，以及 stop 的取消顺序，均保留现有 Agent 与 Product 保护；不新增等待异步提交结果的正式终态屏障，不提前释放 worker lease。已有 Agent 人为延迟调用的测试继续验证调用静止，不据此增加产品级“SDK 卡住仍可交互”的承诺。

## 4 前端交互与首次创建

点击发送后分离本次提交与当前草稿，立即允许编辑和发送下一条。每次提交独立结算，旧回执不能清空新文字、附件或切换后的会话草稿。

消息展示只区分正在提交、等待处理和明确失败等用户可理解状态；执行后沿用普通消息展示。未获确认不显示已接收，等待结束不把消息时间改成 Run 启动时间，不重复生成气泡。Run phase 和 inputReady 可用于展示，不再用来选择普通发送路径或禁用有效发送。

首次创建复用现有 create 命令。一个新会话只发起一次创建，创建期间有界保留用户明确点击发送的本地提交。取得真实 Task identity 后按点击顺序交付，不等前一条发送回执；前端在这里仅处理对象 identity 和传输顺序，不判断执行是否就绪。

创建失败、结果未知或连接 generation 失效时，不自动重建或重放本地提交；逐条保留失败或未确认状态。切换页面不能重定向原提交。创建期间停止会取消此前尚未交付的提交；若 Task 已创建则保留该对象，迟到的创建回执不能继续发送已取消消息。

Task 已接收消息由 Task 独立推进，切页或 Renderer 断连不取消。尚未取得 Task identity 的本地提交没有 Host 接收保证，不建立后台发件箱、草稿别名协议或跨重连补发机制。

## 5 必要的 Bridge 调整

| 接口 | 调整 |
| --- | --- |
| metawork.tasks.sendInput | 普通 Composer payload 调整为 taskId、operationId、input；结果表达 accepted 或 rejected，不以 started／submitted 作为接收条件 |
| Task Snapshot | 发布接收可用性及未移入 Run 的安全提交记录；等待、取消和失败有明确状态，实际 Run 输入保留同一 operationId 关联 |
| metawork.tasks.stop | 新增以 taskId 为目标的任务停止入口，沿用已有停止按钮 |
| metawork.tasks.create | 保留现有产品对象创建语义，不与首次执行合并 |
| metawork.tasks.cancel | 保留绑定指定 Run 的公开语义，迟到调用不能停止后续 Run |
| metawork.tasks.run | 保留显式新 Run 语义，有更早待处理输入时不得抢先执行；Composer 不再走此路径 |

sendInput 的接收结果只需 taskId、operationId、outcome 和 nullable reason，不承诺实际执行 Run identity。SDK accepted、adopted、unknown 等事实留在执行记录。DTO 的字段名与跨字段约束在实现时按同一 Bridge 合同切片固定，两侧 decoder 和 fixture 同步修改。

现有 Task 级 sendInputResult 只有一个槽，不能作为连续消息的唯一对账来源。用 Task 提交记录和 Run 输入上的 operationId 确认对应消息；查不到记录不能反推未接收。operationId 继续用于关联，不增加自动重试、持久化 ACK 或跨重启幂等承诺。

同一来源窗口、同一 connection generation 内，Bridge 必须按 Renderer 发起调用的顺序进入 Host 主线程接收事务；同一 Task 的 A、B、C 不能因响应先后或异步准备而交换接收顺序。Renderer 可以不等前一条响应就发起下一条，响应完成顺序不作为消息排序依据。此顺序保证写入 Bridge 合同，并由真实 Bridge 命令接收路径的测试验证，不能只测试前端列表顺序，也不扩大为跨窗口或跨连接的全局顺序。

实施前核对实际消费者。Host 与 Renderer 按当前成套发布规则同步迁移，不留旧、新 Composer 双路径；发现稳定外部消费者时先处理兼容合同，不擅自破坏公开接口。新增 stop 同步收口 app.zon allowlist、Dispatcher 和 guard。

## 6 停止与异常处理

Task 在处理一次 stop 时，同步标记当时已有等待项及接续取消，并请求停止当时实际存在的 operation。已经领取成下一轮 Run 的消息同样受这次停止影响，不能由前端先取消等待再取消 Run 拼接。后来接收的消息属于新意图，等待真实停止结束后推进，不被迟到终态追溯取消。

| 情况 | 处理 |
| --- | --- |
| SDK 明确拒绝且未产生接收效果 | 临时时序结果继续等待，真实失败结束对应消息 |
| SDK 已接收，随后正常完成且确认未采纳 | 走既有一次接续，不重复已采纳消息 |
| SDK 结果 unknown | 保留原 Run 的未知事实及合同失败保护，不改投其他 Run |
| Bridge 回执未知 | 按 operationId 对账，不自动重发；允许用户继续提交新消息 |
| 当前操作意外失败 | 首次收口时结束当时等待消息的自动推进，显示未执行；后来新输入不被旧回调取消 |
| 必要准备或配置确认失败 | 消息明确未执行，不静默使用旧配置、换模型或循环修复 |
| 归档、删除、authority 撤销或退出 | 终结受影响等待项，按原 owner 的清理及 join 顺序释放资源 |

stop 只表达停止请求，不承诺撤回已经发生的 SDK 效果；已完成同步提交的 receipt 和采纳事实继续如实保留。Task 取消对应消息的后续接续，原文和 lease 的释放仍遵守既有 Agent 调用静止屏障。

模型沿现有逐 Run 合同处理：当前 Run 保持已安装配置，后续 Run 在实际 admission 时采用 Task 当时有效的下一轮选择。本轮不增加逐条消息冻结模型；选择或持久化确认未知时等待权威结果，新增运行时消息不能改写已冻结的确认 witness，也不能被旧候选安装覆盖。

等待和投递中的约束纳入现有自动审批检查，不因尚未送达 Core 而被忽略；消息不能作为授权或权限回答。credential、原文、附件 grant 及源文件路径不进入安全消息投影、日志或持久化 metadata。

接收附件时即由 Control 完成到 Task-owned 资源的移交，不能将一次性 grant 或栈上 callback 留到未来。原文、文件和预算始终只有一个 owner；仅等待消息使用的资源在取消时释放，已经交给 Agent 的资源沿原 Task 生命周期保留。

沿用现有 best-effort 安全历史保存，不增加崩溃后可靠投递。安全消息及必要执行关联可保存，具体失败原因与执行原文不落盘；接收失败和接续失败的原因均只在内存中投影。重启后的未完成提交只显示中断或未执行，不恢复具体原因，也不能从历史还原执行。脱敏和永久 scrub 覆盖新增安全记录与关联字段。

## 7 改动范围与实施顺序

| 代码范围 | 改动目的 |
| --- | --- |
| src/product/task/ | 接收记录、队首策略、准备状态、现有同步投递、停止及失败处理、投影和安全历史字段 |
| src/product/control/ | 接入 Task 动作，协调跨对象准入、附件转移与现有执行资源；收口既有 continuation 推进入口 |
| src/bridge/ 与 app.zon | 新接收及停止合同、Snapshot、Dispatcher、allowlist |
| frontend/src/bridge/ | 配对类型、decoder、client 与跨语言 fixture |
| frontend/src/app/App.tsx 与 frontend/src/features/composer/ | 统一提交入口、独立草稿版本、首次创建关联，移除执行路径选择和准备等待 |
| frontend/src/features/tasks/ | 组合等待和执行消息，按 operationId 保持关联与去重 |

按四步交付一个完整纵向切片：

1. 定义最小接收、状态与停止合同，实现 Task 接收事务和 owner 测试。
2. 接入 Control 和 Agent 现有同步提交能力，统一新消息和既有接续推进，验证停止及结果竞争。
3. 接入 Bridge 与 Renderer，完成连续提交、首次创建、逐条对账和普通消息展示，删除被替代的 Composer 分支。
4. 同步规范，完成当前平台正式调用链验证；不能以接口已存在或按钮已放开代替交付。

不新增顶层 owner、通用队列服务、数据库或后台发件箱；不增加逐条取消、编辑重排、持久化消息编号或全局时间线重构。不以提前释放标题 worker、并发操作 Session、修改 SDK 或弱化 verifier 换取接收。

## 8 合同更新与验收

实施时按职责分别更新真源，不把本计划作为长期规范：

| 真源 | 必要调整 |
| --- | --- |
| [产品需求](../requirements.md) | 连续接收、有限等待、停止及恢复保证，替换旧单条待发送描述 |
| [UI 设计规范](../ui-design.md) | 持续发送、首次创建、消息状态与停止交互 |
| [Product 架构](../product-architecture.md) | Task 接收及推进职责、Control 跨对象事务、所有权、并发与恢复 |
| [Renderer Bridge 合同](../renderer-bridge-contract.md) | Task 目标、accepted 回执、逐条 Snapshot 关联、stop、多调用及同连接命令接收顺序 |
| [AgentCore 集成契约](../agentcore-integration.md) | 继续复用同步控制调用、SDK 借用及调用静止屏障；仅消费责任确有变化时调整，不为本轮引入异步机制或修改 SDK／ABI |
| [验证规范](../validation.md) | 接收与执行分别验收；旧 readiness／Skill 拒绝与标题门禁继续约束执行，不再约束消息接收 |

验收按实际失败模式安排：

| 层次 | 必须观察的结果 |
| --- | --- |
| Task owner | 顺序、容量、等待与投递状态、正常未采纳接续、stop 只作用于已有输入、失败不复活旧消息；具体失败原因不写入历史，重启只显示中断或未执行 |
| Control lifecycle | 卡住标题、checkpoint、启动、compact、restore 时仍接收；释放后按序执行，Session 操作不重叠；关联 Schedule 先确认原结果 |
| Agent／投递生命周期 | 复用既有同步 receipt、采纳事件竞争及调用静止回归；就绪文本可在接收的同一次处理中投递，原文不提前释放 |
| Bridge | 新 wire 严格解码；不等响应连续发起 A、B、C 时 Host 按 A、B、C 接收，响应延迟或乱序不改变接收顺序；A 回执丢失且 B 已接收时分别对账；旧 generation 不产生新效果或污染新草稿 |
| Renderer | A、B、C 连续发送；创建及回执延迟时只创建一个 Task、顺序正确；各 Run phase 走同一发送入口；IME、附件和新草稿正确 |
| 当前平台 desktop vertical | canonical Core 上验证真实插话、等待后新 Run、未采纳接续、停止竞争、失败、断连和重启不重放；桌面及约 390px、深浅主题无重复气泡和溢出 |

Renderer 不连接时，Task 仍能推进已接收消息。Task 消息 policy 必须有 Task owner 测试，不能只靠 Control 或 UI 测试证明。

按[标准验证入口](../validation.md#标准入口)运行 typecheck、受影响 Renderer suite、Bridge fixture、Native owner、lifecycle 和当前平台 vertical；module graph 或 allowlist 变化追加对应 guard。canonical staged bundle 缺失或 verifier 拒绝必须明确失败，不跳过 Core。仅存在独立平台失败模式时扩展平台矩阵。

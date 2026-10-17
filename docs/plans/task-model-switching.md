# Task 模型切换整改方案

用户可以在同一 Task 中选择下一轮使用的模型，包括其他连接和协议提供的模型。全局默认模型只决定新任务的初始选择；Task 模型意图、当前内部 Session 和已经接纳的 Run 分别拥有自己的状态。切换保留上下文，在原授权仍然有效时保留能力，既不因为全局配置变化锁死选择器，也不借切换取得新能力。

本文记录本轮整改范围和验收要求，不是 decision record，也不替代规范。实施使用当前 canonical Metask AgentCore，沿用现有 Models、Task、Agent、Bridge 和 checkpoint，不以升级 Core 为前提。验证结果由正式测试和任务验收证据记录。

## 1 验证依据

2026 年 10 月 17 日，在 MetaWork revision `8964ac52128cbcc258ae03685753f004664d3db9`、Windows x86_64、AgentCore `0.6.0-dev+4e826cef9799`、ABI v1 revision 19 上完成官方 SDK 探测，canonical bundle 校验通过。

| 验证 | 结果 | 能支持的结论 |
| --- | --- | --- |
| 四种协议之间的文本、图片、真实 Read 调用历史切换与返回 | 48 组通过 | Chat、Responses、Anthropic、Gemini 的 4×4 组合可跨连接恢复上下文、逻辑 Session 身份及操作前沿，不重放历史工具 |
| checkpoint 读取失败后的原配置恢复 | 1 组通过 | 目标失败后可以使用未改变的恢复点恢复原会话 |
| 带 Skill、MCP、权限状态的同进程切换 | 8 组通过 | 原授权保持、恢复输入扩大、授权收缩、MCP schema 改变及失败回退均有实际行为验证 |

第三组使用真实 Skill 文件、独立本地 HTTP MCP 服务、真实权限回调及内置文件工具，发生 191 次模型协议请求和 14 次 MCP 工具调用。授权写入成功，会话拒绝和 Host 显式拒绝仍生效，新文件目标仍需询问，未选择的 MCP 使用真实模型工具名调用也被拒绝。扩大恢复时的 Skill/MCP 输入没有扩大历史任务的能力；撤销授权或改变工具 schema 会安全失效并返回 typed report。失败回退保留原模型、授权和 checkpoint 字节。

这些探测使用本地模型协议 fixture 和合成凭据，验证的是当前 Core 的协议、状态和授权行为，不证明外部供应商实际兼容性，也不替代正式 MetaWork 调用链验收。图片和工具历史的 4×4 组合来自第一组；带完整授权状态的探测覆盖同连接换模型，以及 Anthropic 到其他三种协议，不能合并表述为全部授权组合已经覆盖。

本地原始证据分别位于 [.zig-cache/execution-switch-probe-20261017/evidence.json](../../.zig-cache/execution-switch-probe-20261017/evidence.json) 与 [.zig-cache/execution-authority-probe-20261017/evidence.json](../../.zig-cache/execution-authority-probe-20261017/evidence.json)，包含依赖身份、探测输入 hash、请求、结果和文件副作用。这些路径是本机临时材料；正式回归必须进入标准测试入口，不能依赖缓存目录存在。

## 2 整改前的问题与整改边界

整改前，Task 模型选择虽然已使用 source-qualified `ModelRef`，接纳条件仍依赖全局 installed execution 与 Task pinned execution 的一致性，并限制 source 和 protocol。已有 Custom Provider Task 不能切换；全局连接 authority 变化还会使旧任务只读。运行中的 pending model 只保存模型字符串且只存在于进程内，不能表达完整的下一轮连接意图。

整改前的跨连接恢复另有独立接线缺口：[recovery_job.zig](../../src/product/task/recovery_job.zig) 的冷恢复输入将 Skill catalog、policy 和 MCP selection 设为 null；[attachment.zig](../../src/product/task/attachment.zig) 也未保留足够的原始 MCP 恢复输入。直接复用这一冷恢复策略会丢失能力。Agent 的 MCP selection 还绑定 Runtime 与 catalog generation，不能修改旧 generation 或拿最新全局 selection 直接代替。

本轮收口模型选择、执行重绑定、能力连续性、对应 UI/Bridge 与持久化。沿用现有生命周期、事务和资源 owner，不新增路由平台、第二套权限引擎、Provider codec、checkpoint 格式或后台调度服务。普通历史恢复、Skill 显式刷新、MCP 全局配置管理和 Schedule 凭据政策继续由各自合同负责。

## 3 用户行为

| Task 状态 | 选择模型后的行为 |
| --- | --- |
| 新任务草稿 | 可从可用来源选择模型；创建时解析完整执行配置，不先借用全局默认连接再替换模型名 |
| 空闲任务 | 保存该 Task 的模型意图，下一次 Run 接纳前使 Session 与意图一致 |
| Run、工具或权限等待中 | 可以保存下一轮选择，当前 Run 继续使用已经冻结的连接和模型；不打断工具或重放审批 |
| 有排队输入 | 保留输入；它尚未成为 Run，实际接纳时使用当时已提交的 Task 模型意图 |
| detached 任务 | 可以保存模型意图；发送时按合法的恢复资格和目标配置建立 attachment，不承诺重建进程前的全部能力 |
| 正在关闭、删除或已归档 | 遵循原有生命周期限制，不把这些限制表述成不支持换模型 |

多个连续选择按成功提交的 revision 排序；下一轮采用最新已提交意图。Host 已接纳的 Run 不再随选择变化。保存失败不显示成功，切换失败保留用户选择和草稿，并显示实际仍安装的模型；重新发送只能再次尝试所选目标，不能偷偷改用旧模型或默认模型。

选择器区分“下一轮所选模型”和“当前 Run 使用的模型”，运行时显示“下一轮生效”。可用候选来自 Models 的各可用来源，Metask 与 Custom Provider 使用同一选择流程。全局默认值变化不改写既有 Task。

目录确实变化导致目标失效、凭据不可用或命令 revision 过期时仍明确拒绝，并刷新 Host 投影、保留输入；不能删除并发校验或无限重试。通用的“模型已变化，请重新选择”只在确实需要重新选择时使用，其他失败按原因呈现。

目标模型无法承载已有媒体或上下文时保留原件与历史，准确返回能力或容量失败；不能删除图片、截断历史、自动换模型或静默 compact 来伪造切换成功。实际远端接纳失败仍作为该次调用失败处理，不能由本地目录声明推定成功。

## 4 状态与职责

| 状态 | Owner 与规则 |
| --- | --- |
| 全局默认选择 | Models 拥有；用于新任务初始值，不约束旧任务可选目标 |
| Task 下一轮模型意图 | Task 持久保存 `ModelRef(source_id, model_id)` 与单调 selection revision，不包含 credential、连接句柄或权限规则 |
| 目标执行配置 | Models 按精确 ModelRef 解析；Product Control 持有本次 owned candidate，包含 protocol、endpoint、credential 与来源 authority |
| 已安装执行配置 | 既有 Task attachment 持有 owned execution；与用户意图分开，允许因切换失败暂时不一致 |
| Run 使用的配置 | Run admission 成功时冻结，不随全局配置、目录或后续选择改变 |
| 能力恢复输入 | 在现有 attachment、Skill snapshot/lease 与 Agent Session owner 中补齐进程内 owned 输入；SDK 原始描述、MCP schema 和 secret 保持在对应 Host/Agent 边界 |

复用 Models 已有 ModelRef 和解析能力，去掉仅为同一 active default execution 服务的 Task 选择条件；不另建模型目录或 resolver。目录 generation 校验负责目标是否仍可解析，Task selection revision 负责用户意图是否被并发覆盖，两者不互相代替。

Task 意图提交不推进执行 binding epoch。连接或协议的实际重绑定只有在候选成功发布时推进既有 binding epoch，后续 Run 关联新 binding；仅模型变化沿用既有模型历史责任。历史 Run 保留当时事实，不能用新模型覆盖。未提交的失败或取消不推进成功 binding；已确认的 durable binding 必须先采用，后续回退按新的单调 epoch 提交，不能撤回已确认历史。

排队输入的旧 binding anchor 需在 Task 控制事务中与成功重绑定协调，不得通过跳过 epoch 校验执行，也不得把合法模型切换误判为用户输入过期。Run、compact、restore/rebind 共用既有 active operation 槽；模型意图写入不直接触碰忙碌的 Session。

## 5 执行路径与切换事务

模型选择命令先完成目标校验和 Task 意图持久提交；真正执行前再确保已安装 Session 与该意图一致。只保留两种接线：

- 现有连接、credential authority、protocol、Workspace 与能力输入均未变化，仅模型变化：在 idle 边界调用官方 `setModel`，核验并更新实际模型事实。
- 执行连接或 protocol 变化：沿既有 Task operation、worker 与 checkpoint owner 执行 export、关闭和 restore。目标 Host config 完整来自目标连接，能力输入来自原 Task 的有效 authority。

跨连接事务按以下顺序执行：

1. 在 Product Control 线程冻结本次 selection revision、原 binding/Workspace identity、目标 owned execution 和能力恢复输入，取得 Task operation 槽。预留既有提交与清理所需的资源。
2. 校验目标来源和能力输入仍然有效。候选准备失败时保留旧 Session；目标 credentials 不借用原连接，也不落入 Bridge 或历史。
3. 让当前操作、权限请求、事件和 checkpoint 收口；export 并按现有 checkpoint 事务建立可验证恢复点。关闭旧 Session 前必须拥有可用恢复点及原执行配置，导出失败则结束本次尝试。
4. 关闭并释放旧 Session，保留原执行配置和能力恢复输入直至事务结束。同 Runtime 的逻辑 Session 身份冲突不允许同时保留两个 live handle；关闭失败不继续 restore。
5. 用目标连接的完整 Host config 恢复原 checkpoint，经官方 SDK 解码 report，校验逻辑身份、覆盖前沿、Workspace、idle 状态与能力结果。先遵循现有 checkpoint 模型 expectation 恢复，再调用 `setModel` 设置目标模型，不要求旧模型存在于目标目录，也不发送中间模型请求。
6. 在候选发布前重验本次 Task revision、来源 authority、Workspace 与生命周期。沿现有 durable commit 和 coverage 边界提交实际 binding/model 事实，再发布候选；成功后销毁旧配置和临时 owner，才能接纳 Run。

若期间用户提交了更新选择，本次候选不得按旧 revision 发布。丢弃候选、恢复可用基线后再处理最新意图，或明确结束为待重试；不得对已经失效的尝试继续发送模型请求。模型意图命令和实际安装结果都只发布 Host 事实，Renderer 不做成功预测。

## 6 能力连续性

Skill 使用原任务 pinned catalog/lease、启用选择与默认拒绝 policy，校验 Runtime 和 Workspace 绑定；不能用当前全局开启列表扩大旧任务。MCP 保留原任务的精确 selector 和授权来源，必要时在当前 catalog 下重新验证并构造合法 selection；不得篡改 generation、绕过 `StaleMcpSelection` 或换成全局最新 selection。

MCP 的连接来源校验由 Host 承担：探测已观察到，仅改变 `configuration_fingerprint`、工具 schema 保持相同时，Core 仍可能返回 `complete`。因此 restore report 的成功不足以证明连接来源未变。相关 server 连接配置或授权来源不兼容时，应在关闭旧 Session 前明确拒绝本次重绑定；不能通过保持 server id 和工具名沿用旧授权。无关 server 或目录刷新不应单凭 generation 数值变化使任务永久无法切换，应重验原任务的精确选择。

Permission 的 session allow/deny 从 Core checkpoint 恢复，现有 approval mode、shell policy、内置工具集合及权限交互按同一来源传入。不通过 Product 历史重放审批响应，不复制一次性批准，不新增用户规则配置产品；Host 正式路径原本为空的显式规则保持为空。

原 authority 不变时必须保留能力。Core 合法报告授权收缩或 schema 失效时，可接受安全的 degraded Session，并将受限能力状态准确呈现；不能把空 Skill/MCP 当作正常切换输入，也不能为了显示完整恢复而扩大授权。Conversation 恢复与能力是否完整分别判断。

## 7 失败与恢复

| 失败位置 | 必须保留的结果 |
| --- | --- |
| 意图保存、目标准备或 checkpoint 导出失败 | 保留此前 durable 状态与旧 live attachment，明确失败 |
| 旧 Session 关闭失败 | 保留真实 attached/closing owner，拒绝伪恢复，不继续创建冲突 Session |
| 目标 restore、setModel、身份校验或发布前校验失败 | 清理候选，使用原恢复点和原执行配置尝试一次回退；不发送用户输入 |
| 回退成功 | 原上下文可用，所选目标仍为待应用或失败状态；不能把回退解释为已经运行目标模型 |
| 回退失败或候选销毁失败 | 保留 checkpoint 和 poisoned/closing owner，明确不可运行，沿既有恢复与 shutdown 清理责任处理 |
| 持久化结果不确定 | 沿现有 outcome-unknown 恢复边界处理，保留可能被引用的 artifact，不发布确定成功、不猜测已回滚 |

回退仍遵守当时有效的授权上限，不能恢复已撤销能力。任何失败均不修改或解析 opaque checkpoint，不重放历史消息、工具或审批，不自动更换模型，不无限重试。进程中断后以 durable Task 意图、binding 和 checkpoint coverage 恢复；未提交的临时候选不成为新任务或新历史事实。

## 8 实施顺序与合同更新

按可工作的纵向切片推进，每一步完成相关回归，不维护两套 active 选择机制：

1. 贯通 Task ModelRef/revision、Models 完整解析、Bridge typed command/result、Host snapshot 和 Composer。新任务直接使用所选连接，已有 Task 可在运行时保存下一轮意图；先闭合同连接换模型与保存失败行为。
2. 在现有 owner 中补齐能力恢复输入，接通跨连接/跨协议 rebind、候选提交与失败回退；复用 export/restore primitives，冷恢复与同进程切换只在恢复输入和接纳条件上区分，不复制第二套生命周期实现。
3. 收口 queued input、close/shutdown、来源变化、迟到事件和进程中断；删除旧 `pending_model` 字符串路径、active-default 一致性限制和过时的只读分支，完成真实产品 vertical。

规范按各自 owner 更新：产品行为见[产品需求](../requirements.md)，交互状态见[UI 设计规范](../ui-design.md)，意图提交、Run 边界、rebind 与历史一致性见[Product 架构](../product-architecture.md)，wire command/result/snapshot 见[Renderer Bridge 合同](../renderer-bridge-contract.md)，能力与 restore 消费见[AgentCore 集成契约](../agentcore-integration.md)。仅在正式验证责任或长期证据结论改变时更新[验证规范](../validation.md)；不机械修改其他真源或 `AGENTS.md`。

Task 新意图涉及持久化扩展，必须在现有 history/version owner 下给出旧数据读取和新数据写出的明确规则。历史中能证明 source 的才构造对应 ModelRef；不能证明时保留历史、显示需要选择，不能从当前全局默认值猜测来源。不得丢弃旧消息、binding 或 checkpoint，不默许破坏稳定格式；需要不兼容迁移时须在实施前另行明确授权。本文的整理不执行任何数据迁移或产品合同变更。

## 9 验收条件

完成条件是正式 MetaWork 行为正确，不是孤立 SDK 探测再次通过：

- Metask 与 Custom Provider 可按同一流程在原 Task 中选择模型；跨连接、跨协议均能继续上下文。全局默认或 credential generation 变化不直接锁死选择器。
- 新任务使用完整所选目标；运行中修改只影响后续 Run；排队输入采用接纳时最新已提交意图。连续选择、陈旧命令和迟到候选不会错用连接，保存失败不丢失旧意图或输入。
- 正式 Agent/Task 调用链保留图片、Skill、MCP 和工具调用结果，不通过 Product transcript 重建上下文，不重放 effect。授权不变时能力不丢失，新增全局能力不被带入，撤销或 schema 改变后不越权。
- 会话授权与拒绝、Host 权限模式、新路径审批和 MCP 来源核验均有独立拒绝用例。无关 catalog 刷新可重新验证，相关连接变更不能仅凭 Core `complete` 获得旧授权。
- export、close、restore、setModel、candidate cleanup、持久化与回退各失败点均有可观察结果；包含关闭、退出、权限等待、取消和进程中断，不泄漏 owner 或凭据，不发布虚假成功。
- 旧 Task 数据、binding 历史、checkpoint coverage 与 operation id 高水位保持正确；持久化扩展有实际旧样本和失败恢复验证。
- 按[标准入口](../validation.md#标准入口)执行 Renderer typecheck、受影响 suite、跨语言 Bridge fixtures、正式 Native test graph 及相关 lifecycle/vertical。当前 Windows 完成成套构建和实际界面验收；只有独立的平台失败模式才扩大平台矩阵。canonical bundle 缺失明确失败，不能跳过 AgentCore 后报告成功。

现有 SDK 探测的核心保留与拒绝用例应进入正式测试，由正式调用链验证。实际外部供应商兼容性使用受控授权环境单独验证，不将本地 fixture 的成功表述为远端承诺。

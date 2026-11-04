# 原生对话框异步重构方案

状态：代码已实施，平台证据见 [E-MACOS-DIALOG-ASYNC-20261104](../evidence/native-dialog-async-macos-20261104.json)。Windows、隐藏窗口 OAuth consent 及证据列出的专项仍未验收；正式 Native 图的既有失败另行保留，未声明全图通过。本文不是 decision record，不替代领域真源。

日期：2026-11-04。源码分析基线：`f52470ed1e7c1663114de654cf1de9f9b4edfa94`；Native SDK：`0.11.0-fork.5`。实施前重新核对实际工作树、依赖和受影响调用点。

## 1. 目标与边界

统一将 MetaWork 自有的原生 open/save/message 调用迁移到 SDK 正式异步 API，让用户等待对话框期间应用继续处理 timer、wake 和后台完成事件。[MetaWork #65](https://github.com/shuzuan-org/metawork/issues/65) 是验收场景之一。

设计结论：Application 保留带集中能力检查的薄转发 port；Dispatcher 拥有需要异步等待的 Bridge 命令；SDK 继续拥有原生请求、排队与显示。保存和 MCP 等调用方只调整对话框前后的衔接。

| 本轮修改 | 本轮保持 |
| --- | --- |
| 对话框 request/cancel port、结果 DTO、异步回调适配 | SDK transport、原生显示队列、平台实现 |
| Bridge pending、调用方必要的输入保活及取消收口 | Schedule、Agent 事件泵、Session、队列和执行策略 |
| Save As 等待选择与原文件工作的衔接 | 文件 worker、hash/stage/publish/discard、保存提交点 |
| MCP 确认分页、确认等待互斥及继续段 | OAuth 协议、注册/交换/刷新、持久化和调度 |
| 对应测试和真实原生对话框验收 | 产品对象、grant/配额、command wire、snapshot 和持久化格式 |

允许修改调用方文件，但每处改动必须直接服务于“同步返回改成异步继续”。不扩展为相关领域模块重构，不增加 timer、线程、Renderer 服务或兼容路径。

依据：[高层架构](../architecture.md#35-native-sdk)、[Product 架构](../product-architecture.md)、[Renderer Bridge 合同](../renderer-bridge-contract.md)、[工程结构与所有权](../project-structure.md)、[验证规范](../validation.md)。

## 2. SDK 约束

当前 SDK 已有 requestOpenDialog/requestSaveDialog/requestMessageDialog、cancelDialog 和 completion；旧同步 API 仍保留，需要主动迁移。

- SDK 复制 options/tag；completion descriptor/context 由调用方保活，paths 仅在回调期间有效。
- completion 在后续 wake 交付，不内联进入发起调用；cancel 不保证同步完成，撤销后仍可能收到 selected。
- SDK 停止时可直接 abandon 请求而不调用 completion，本地清理不能依赖它。
- SDK 已实现 parent 排队与容量控制，不在 MetaWork 复制显示队列。
- 异步能力缺失时 SDK 可能同步 fallback，必须在 Application 发起前拒绝该情况。
- SDK message 的 button 默认 primary，只有 outcome 为 selected 时才能读取它。

macOS open/save 使用 sheet 或非阻塞 completion。无可见 parent 的 message 会在新的 loop turn 中运行 parentless runModal，必须单独实机验收其 timer/wake 行为。

## 3. Owner 与接口

### 3.1 Application：薄转发 port

沿现有 Adapter 的平台边界提供异步 request/cancel，不新增 Application dialog manager、请求表、显示队列或独立 dialog 服务。

port 只做四件事：

1. 集中检查 Runtime 和公开的 request/poll/cancel/wake 能力，查询与每次发起共用同一判断；缺失时明确返回现有错误/unavailable，不能进入同步 fallback。supportsMcpConnectionApproval 也改用该判断。
2. 接收 options、parent window、关联 identity 和 completion，经 Runtime 正式 API 发起并返回 opaque handle。
3. 用无状态 trampoline 转换 SDK completion 签名和 DTO，不把 Runtime 参数传给调用方。
4. 按 handle 转发 cancel，不接管业务输入、responder 或请求记录。

Dispatcher 继续经 port 调用，测试通过该 port 注入延后结果、取消和失败。Product 使用 MetaWork-owned 请求/结果/completion，不依赖 SDK Runtime 类型。

DTO 使用 tagged union：文件结果仅 selected 携带 paths/count，message 结果仅 selected 携带 button，另有 cancelled/failed。转换时先判 outcome，取消或失败不能因默认 primary 被当成批准。

### 3.2 回调 lifetime

稳定的 Dispatcher、Product Runtime 或 MCP coordinator 持有 completion descriptor/context。tag 只携带短的单调操作 identity；回调到 owner 后查 pending，不把栈变量、JSON slice、可移动槽位或可能提前释放的 OAuth Flow 交给 SDK。

撤销时先关闭原 operation 的使用资格，按对应路径结算并转发 cancel；迟到回调查不到原 identity 即丢弃。业务 pending 可释放，稳定 callback context 仍保活到 SDK abandon 或事件派发停止。composition 在销毁 owner 前保证这一顺序，正常和异常 stop 都覆盖。

### 3.3 Dispatcher：pending dialog 表

Workspace、Automatic Root、Skill 导入/导出和 MCP approve 由同步 handler 改为 AsyncHandler。它们没有原有 responder 存续路径，由 Dispatcher 的一张有界 pending dialog 表统一管理。

表项持有 owned request id、responder、connection generation、window id、单调 operation id、取消 handle 和 tagged continuation。continuation 只保存原入口的最小输入，不借用解析树或 Product 内部指针。容量固定且不超过 SDK 公开 dialog 请求上限，满时立即拒绝，不保留半登记请求。

| 阶段 | 要求 |
| --- | --- |
| 发起 | 先校验、复制输入、预留表项，再请求对话框；发起失败统一结算 |
| 完成 | 按 operation id 查表，重验连接及领域资格后继续；终态 helper 取走 responder、移除关联，再响应并释放 |
| 断连 | breakConnection 当场撤销并结算，不等待迟到 result；使用原取消 shape 或既有 handler_failed envelope |
| 重连 | connectEvents 安装新 generation 前复用旧连接撤销路径，覆盖 disconnect/pagehide 丢失 |
| 退出 | assertQuiescent 和 detach owner 前撤销并结算表项，独立断言表为空；同步 lease 数不能代替这项检查 |

每个 responder 恰好结算一次，响应发送失败不重试；SDK respond 路径自身释放其 slot，不能访问内部 release。callback lease 随当次 handler 返回而释放，不跨用户等待持有。

统一附件批次和 Output 保留现有槽位，不重复持有同一 responder。旧 attachments.choose 选择前没有 staging 槽，使用 pending 表的独立 continuation，选定后按原路径预留 staging 并一次性移交 responder，不增加 preparing 批次。

### 3.4 错误边界

AsyncHandler 和 completion 都使用 checked wrapper。入口的 payload/分配/准入/发起错误转换为 responder.fail(request_id, handler_failed, @errorName(err))，不能逃逸为 SDK callback failure。

登记前由入口结算，登记后由 pending owner 结算；移交或终态后的 responder 不再使用。completion 编码、继续段和结果转换错误也必须进入原 terminal helper，不能只交给 SDK on_result 记日志。没有 Bridge responder 的 OAuth consent 使用 §4.2 的 flow 收口。

## 4. 调用方适配

| 入口 | 必要适配 |
| --- | --- |
| 统一附件 picker | AttachmentInFlight 保存 dialog handle 和本次 max_files；继续时核对 connection/window/batch，再进入原 staging |
| 旧 attachments.choose | 仅增加选择等待的 pending，不增加 preparing、产品调用方或专门真实 picker smoke |
| Workspace | 回调核对原连接，继续原 grant/openWorkspace 路径 |
| Automatic Root | 保留原 expectedGeneration，选择后 canonicalize 并执行原 CAS，不自动换新 generation |
| Skill 导入 | 保存 kind/target identity，选择后重验原目标并进入原 preparation |
| Skill 导出 | 保存 install_id，选择后按原逻辑查找和 export，不新增资产 revision |
| Save As | 使用 §4.1 的异步 prepare 衔接原文件工作 |
| MCP approval/consent | 使用 §4.2 的确认级取消和逐页继续 |

统一附件的 max_files 原为 handler 局部值，须随槽保存；回调既检查原 remainingFiles 限制，也保留 Product 当刻实际配额准入。cancelAttachmentAdd、断连/重连和 shutdown 均取消原 dialog handle；尚无 staging job 时立即结算附件 responder、清理 preparing。选择完成后清除 handle，迟到结果不作用于新批次。探测、复制、DOM bytes 和拖放路径不变。

### 4.1 Save As

把同步 OutputFileSave.prepare_fn 拆成异步 prepare/cancel。Product 持有原 completion id 对应的冻结 pending target，Dispatcher 继续持有 output slot；等待 picker 不占 worker，不启动文件工作期限，也不误报为 lane 已 queued。

| 接口步骤 | 约定 |
| --- | --- |
| begin | Dispatcher 提供 completion id、default name、稳定 callback descriptor；Application 检查能力后发起 picker 并返回 handle |
| borrow_source | selected 回调内，Application 按 id 同步借源；Dispatcher 检查请求 active 后向 Product 借原 pending target 的 OutputFileSaveInput，拒绝则不构建 effect |
| 构造 effect | 在同一次主线程回调、paths 仍有效时，用借来的 source 和所选 path 调用原 Save.init，生成 OwnedOutputSave；借用到构造结束即终止 |
| complete | Application 返回 selected(OwnedOutputSave)、cancelled 或明确失败；Dispatcher 继续 Product admission 或先清 pending target 再结算原 slot |
| cancel | 原 owner 撤销请求，按保存 handle 转发 cancel；无 job 时当场结算，不等待 SDK result |

目标路径仅在 Application 回调内使用并移入原 owned effect，Product/Renderer 不接收它。Application 不保存请求/source/descriptor，不把源或路径塞进 tag。source 借用、Save.init、结果转换失败均进入同一 complete 错误路径，不能重新捕获新源替代原源。

后半段必须回到 Dispatcher，共用原 admission 处理 helper：queued 后复查 slot 是否存在/已取消，必要时 cancelOutputCheck，然后 updateOutputTimer；immediate 走 completeOutputAction。原 worker、hash/stage/publish/discard 和发布决定保持。

cancelOutputCheck 同时覆盖 pending target 与已有 job，返回结果至少区分：

| 返回值 | Dispatcher 收口 |
| --- | --- |
| pending_cancelled | Product 已释放 target，无未来 lane completion；取消 dialog，立即 completeOutputAction，回收 responder/slot |
| job_cancelling | 等原 job 物理静止及 completion，不提前释放 worker 资源 |
| committed | 拒绝取消，保留真实 I/O 终态 |
| not_found | 未知或已终态不重复响应；若仍有活动 slot，检查待消费终态并完成收口，不能假定未来会回调 |

cancelOutputAction、cancelOutputConnection、queued 后 cancel-first 共用该 helper。系统 Save 框的 Cancel、平台 failed、借源/effect 构造失败也走同一释放路径：先清 Product pending target，再结算 responder/slot。helper 接受实际 terminal state，取消为 cancelled，失败保留 save_failed/unavailable 等分类。

Task 切换 abort、断连和 shutdown 同样覆盖无 job 阶段。重复/迟到 effect 释放而不入队、不重复响应。实际入队后复用原 250 ms output timer/wake 驱动 expire；保存提交前后仍遵守原取消与终态规则。

### 4.2 MCP 原生确认

同步 confirmMcpDetails 循环改为 coordinator-owned 的异步分页：持有同一份 owned 正文和页位置，每次仅发一页。中间页只 Next/Cancel，只有最后一页可批准；任意页取消/失败都不批准。正文与 OAuth 材料保持 Host-only，不进入 Bridge pending、Renderer、日志或 snapshot。

返回给 Dispatcher 的取消 handle 是完整 confirmation identity。当前页 SDK dialog id 由 coordinator 持有并逐页更新；取消确认必须找到当前页，不能保存第一页 id 作为整次确认 handle。OAuth 同样在原 operation 下管理确认级身份和当前页 id。

Legacy approval 在现有 coordinator 中增加有界 pending approval identity，不创建 OAuth flow 或 durable transaction。authorizeOauth、testConnection、applyConfiguration、captureSecret 和重复 approve 的互斥检查覆盖它，所有终态清除占用。

| Host port | 约定 |
| --- | --- |
| begin approval | 接收原 operation id、expected generation、server id 和稳定 completion，验证并启动确认，返回确认级 handle；首个请求失败直接返回原错误，不内联 completion |
| cancel approval | 撤销原确认、清等待占用并取消当前 SDK 页；Dispatcher 当场结算原 responder |
| approval completion | 返回相同 operation id 和 confirmed/既有 outcome/错误；第二页起任意 request 失败也走这条路径，不能只记录日志 |

confirmed 仅表示完整用户确认。coordinator 发送前重验确认身份、stopping、desired generation/server 和 apply/test/flow，清本次等待占用；Dispatcher 随后核对原表项、connection/window、mcpServerOperationBusy，再调用原 Product 批准事务。Product 仍做最终 guard，校验至提交在同一次主线程继续调用中完成。

Product ManagementOutcome 经 Host port 复用现有 mapManagementOutcome 唯一映射，并由 mcp_bridge_adapter 暴露，不在 Dispatcher 复制。unchanged 仍映射 rejected；回调期 busy 也映射既有 rejected，入口既有 busy 响应不变。随后必须走 finishMcpHostMutation，保留 apply、notifyCommitted 和结果编码；不用会返回 unchanged 的 finishMcpMutation，本次等待占用不能阻挡自身 apply。

OAuth 保留原 operation/attempt、awaiting_consent、deadline 及后续协议。每页和最终继续段核对原身份、取消及期限；cancelAuthorization、finishFlow、shutdown 在清 flow 前取消当前 confirmation。callback context 指向稳定 coordinator，不指向 Flow。

OAuth completion 使用独立 checked wrapper：下一页、DCR 准备、bindAndOpen 或结果转换失败，取消确认并调用原 finishFlow，复用其 job/durable-operation 清理并发布变化通知。错误只处理原 operation，不能残留 self.flow 或结束后来 flow。job == null 的原控制流只补 dialog 取消，不另建状态机或 timer。

catalog refresh 继续运行，若批准时原 mutableManagement 拒绝，按现有 rejected/失败收口，不新增互斥、重放或刷新策略。Renderer reload 不自动取消全局 OAuth operation。

## 5. Renderer、guard 与范围外观察

保留 Workspace/Root、Skill picker/export、附件和 Save As 的用户控制等待；MCP legacy approval 单独取消默认短 command timeout，不全局放大 timeout。结果 decoder、按钮、文案和交互流程保持，不自动重放取消、超时或未知结果。

每个 command 恰好注册一次。architecture guard 的 Application 转发断言由 showOpenDialog 更新为 requestOpenDialog，并增加 src 中不存在同步 showOpenDialog/showSaveDialog/showMessageDialog 调用的反向检查；不能删除依赖边界检查或为生产旧路径加静默 allowlist。

SDK 跨 document 响应误配的机制已由源码确认：JS request id 每 document 从 1 计数，complete 只按 id 匹配，response slot 无 document 身份。当前 Renderer 没有主动 reload 路径，本轮立即结算撤销请求以缩小窗口，不声称修复 SDK transport，也不将其设为预先升级 SDK 的条件。若实测阻碍本轮入口正确收口，报告最小复现及受阻入口，走必要上游修复，不访问私有 slot 或绕行。

## 6. 自动化与真实验收

### 6.1 自动化回归

| 范围 | 必须观察的结果 |
| --- | --- |
| 薄转发 port | 每次发起前集中检查；缺能力不调用 request/同步 API；结果延后交付；测试经 port 注入；Application 无请求表 |
| pending / 错误 | 准入、发起、编码和 completion 错误只结算一次、不逃逸；断连/新 connect/stop 表为空；超过 SDK response slot 容量的串行取消仍可继续 |
| 回调 lifetime | owned 输入安全、旧 identity 不命中新槽；正常/异常 stop 均无迟到 effect，不依赖 SDK completion 清理 |
| 附件 | max_files/handle 保留，无 job 取消关闭 picker、释放 preparing、结算；原批次/连接失效拒绝继续 |
| Workspace / Skill | 原连接、Root CAS、导入目标失效不提交；导出保持原 install_id 查询语义 |
| Save As | 系统 Cancel、failed、显式取消、Task abort、断连、shutdown 均释放 pending target、回收 slot 并结束 invoke；循环后仍可继续 |
| Save As 后半段 | 借源/effect 错误和迟到 effect 收口；queued 复查 cancel 并启动原 timer；缺 wake 仍 expire；job 取消等静止、committed 拒绝取消；路径不进入 Product/Renderer |
| MCP approval | 等待互斥、connection/配置/busy 重验、后续页失败、unchanged 映射、apply/notify 全部走原结果；等待占用不阻挡自身收尾 |
| MCP confirmation | 同一确认级 handle 能取消第二页/最后页；cancelled/failed 即使底层 button=primary 也不批准 |
| OAuth | 下一页/DCR/bind/open 错误 finish 原 flow 并通知；无孤儿窗口、残留 busy 或误结束新 flow；可继续合法操作 |
| wire / Renderer | 原 encoder/decoder 一致，用户等待不被普通短 timeout 截断；无自动重放 |

复用 `zig build test-sdk-consumption`、受影响的 `zig build test-lifecycle` 和 `zig build test-mcp-app`；运行 `npm --workspace @metawork/renderer run check` 及实际受影响 suites。共享 wiring 按仓库规则运行正式 Native graph、`node --test scripts/architecture-boundaries.test.mjs` 和当前平台 build。canonical bundle 缺失明确失败，不跳过后报告成功。

### 6.2 原生平台验收

open/save/message 各覆盖真实确认、取消和退出，有真实产品调用方的迁移入口执行 smoke。旧 attachments.choose 保留自动化/合同回归，不新增专用真实 picker 场景。路径注入不能证明真实原生验收。

1. 真实附件选择器跨越计划到期，关闭前已创建唯一 occurrence/Task；确认和取消分别覆盖，重复计划仍守原非重叠/补触发规则。
2. 附件及 Workspace 选择器打开期间，已有 Agent 持续消费事件，用屏障/时间证据证明消费发生在关闭前。
3. Save As 等待时后台推进；确认后原保存链路成功；各取消/失败场景无资源增长，已提交保存报告真实终态。
4. MCP 多页仅最后页可批准，同一确认 handle 可关闭当前页；取消/后续页失败不继续授权。
5. macOS 主窗口隐藏时的 parentless OAuth consent：嵌套 runModal 期间 timer、wake 和退出仍推进，不能用可见 parent 的 sheet 结果替代。
6. Windows 每个中间页和最终批准页分别用 Esc 与关闭按钮取消，均不得批准；不能只测试 Cancel 按钮或最后一页。
7. 对话框期间断连、目标失效、窗口关闭及退出，旧操作不复活，新操作可受理。

macOS/Windows 分别做对话框专项，不扩展为完整 OAuth、Office、Provider 或分发矩阵。记录精确源码、artifact、SDK/AgentCore、平台、入口和结果；未取得的平台证据保留缺口。

## 7. 实施顺序

| 步骤 | 交付与出口 |
| --- | --- |
| 1 | 薄转发 port、结果 union、Dispatcher pending 及统一错误/取消/退出回归 |
| 2 | 附件、Workspace/Root、Skill 调用适配，原目标与原 wire 回归 |
| 3 | 按 §4.1 和 §4.2 已确定的接口分别提交 Save As 与 MCP 适配，完成无 job/多页/失败收口 |
| 4 | 删除旧同步 active path，更新并运行 guard、正式 graph/build，完成原生平台验收与证据 |

第 3 步前重新核对实际工作树的 MCP drain、自动 apply 与互斥。评审提及 7d2ae395 后每次 wake 尝试 apply；本地分析仍是 f52470ed，不把未核验后续代码当成事实。实施时验证 pending approval 下 busy 可由既有后续 wake 推进，结束确认后仍能 apply，不新增调度或重试路径。

## 8. 完成条件与文档

- 全部入口经异步 port，无同步/异步平行 active path；Application 无请求表，SDK Runtime 不进入 Product。
- 所有 responder、pending target、preparing、effect 和 confirmation 各有唯一终态；取消后无泄漏或迟到领域 effect。
- 原 wire、持久化、owner 和领域行为保持，正式检查及所声明的平台验收通过。
- 仅按实际长期合同变化更新对应真源；验证规范的选择器缺口在真实证据取得后更新，历史失败不改写成通过。
- 检查链接、锚点、残留引用和 git diff --check。计划不作为实现完成证据，不机械同步 AGENTS 或多份规范。

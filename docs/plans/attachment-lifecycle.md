# 附件限制与生命周期复盘方案

日期：2026-10-31。状态：方案已实施并提交，本机验证及资源实测完成；完整 Node suite 与平台手势验收尚未闭合。关联：[Issue #76](https://github.com/shuzuan-org/metawork/issues/76)。

本轮收窄方案已取得独立 APPROVE，Blocking findings 为 none；当前实现保留 128 条记录；macOS 实测与未闭合项见[验收证据](../evidence/attachment-limits-20261031.json)。本文不是 decision record，不替代现行合同。本轮重新区分代码事实、设计必要性与未验证假设，先修正已经证实的限制耦合，复用现有资源保护和生命周期。

## 1. 方案结论与范围

修复单条消息上限被误用为全局资源容量的问题。每条消息仍最多 8 个附件；全局存活记录使用独立固定池，128 条作为待内存验收的候选。共享原件字节额度、Task 待处理输入预算和既有资源结算保持原语义。

实施收口四项改动：

1. 区分单条/单批数量与全局存量，覆盖 Product slots、Bridge grant、add_debt 和完整 drain。
2. 按草稿累计数量校验，统一 beginAdd 携带剩余名额；Host 在资源检查与复制前拒绝超量。
3. 保留删除失败的追踪；add_debt 饱和返回 CleanupFailed，消除 unreachable。
4. 按数量、资源和清理失败分别呈现准确文案。

不新增阶段配额、图片总预算、资源查询命令或占用界面，不改变 Task 接收、原件存储与执行结算的 owner。评审通过的是这组机制和范围；容量当前按本机实测保留，真实系统手势和其他平台表现仍待验收。

## 2. 实施前核对的根因与已有机制

| 事实                                  | 依据与含义                                                                                                                                                 |
| ------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 单条消息上限被用于全局 Product 池分配 | `src/product/control/runtime.zig` 用 max_attachments_per_draft 填 attachment.Limits.max_files；`src/product/attachment.zig` 据此分配全部 slots             |
| Bridge 同样耦合单批和存量             | `src/bridge/attachment_grant.zig` 的 max_grants 同时约束批次、resolve 和 grant 表；Dispatcher.add_debt 也按此分配                                          |
| 前端缺少累计检查                      | `frontend/src/app/App.tsx` 直接拼接旧附件与新批次；现有小池偶然挡住了第 9 个附件                                                                           |
| 当前添加入口统一                      | `frontend/src/bridge/client.ts` 的 createAttachmentAdd 只调用 beginAdd；当前 Renderer 不调用旧 choose、addDropped 或 receive 命令                          |
| Task 接收已经取得 owned payload       | `src/product/task/state.zig` 的 OwnedRunInput.cloneSelected 复制正文、附件名称、预览和引用；Task.receiveInput 同时受队列数量及共享 payload 字节预算约束    |
| 交接已发生                            | `receiveTaskInput` 成功后调用 borrow.retainForTask 与 external.accept；前者将状态设为 task_owned 并释放 Entry 的 preview/reference，后者消费 Bridge grants |
| waiting 原件有真实用途                | 原件已移到 Task namespace，消息等待期间仍需要；takeInputResourceAction 在进入 Run 或消息终结后发出保留/删除决定                                            |
| 现有原件工作集已有共享预算            | max_staged_attachment_bytes 与 used_bytes 包含正在接收、ready、borrowed、waiting 原件及未结清的删除债务；Run 接纳结算后退出该工作集                        |
| picker 复制前可知数量                 | Host 已持有 selected.count；beginPreparing 却会更早检查资源，因此需一起修正准入顺序                                                                        |

Issue 的补充证据确认占用者是未发送草稿。Run 失败后仍保留该草稿不是泄漏证据；问题与上下文长度无关，也没有证据证明只发生于 Windows。本次未运行 Windows 实机复现。

## 3. 产品规则

1. 每条用户消息最多 8 个附件，图片和普通文件合计，单文件上限保持现行规则。这里的单位是一次用户提交，不是整个 Run 或 Task。
2. 多次添加累计计算。5+3 成功，7+2 整批拒绝新批次，保留原 7 个；不静默截断、部分成功或丢弃旧附件。
3. 发送后下一条消息重新计算数量名额，其他草稿与历史不占它的 8 个名额；全局资源不足仍可拒绝，不承诺无限接收。
4. 保留多草稿、连续编辑、Scope/generation 保护和旧回执不覆盖新草稿。普通导航、Run 完成或失败不删除未发送附件。
5. 已接收消息归 Task；未知接收结果按 operationId/Snapshot 对账，不自动重发。取消、执行、删除和恢复沿现有生命周期结算原件。
6. 超量提示数量问题，资源不足给出资源提示，清理失败如实保留债务；不要求用户删除当前页不存在的文件，不猜测失败一定来自磁盘或其他草稿。

数量名额独立不等于各消息独占磁盘或内存。严格的 Task 公平性、草稿保底资源和互不挤占是额外产品承诺，本次不从“每条消息 8 个”推导出来。

## 4. 实施设计

### 4.1 分离消息上限与记录容量

保持单消息和单批上限不变，为 Product 全部存活资源配置独立的固定记录容量，当前默认采用 128 条。Bridge grant 表与 add_debt 使用同一存量上界；记录、grant、debt 和完整 drain 的容量来自唯一配置，不各自维护更小的限制。

| 按存量容量配置                                                        | 继续按单批/单消息上限配置                                                                         |
| --------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| Product slots、Bridge grant 表、Dispatcher.add_debt、takeAll 完整输出 | takeReceiveBatch、resolve、descriptors、metadata、issued、发送 attachment IDs、path/file 数量校验 |

逐项审计原 max_grants 使用点，不能直接把该常量从 8 改到 128，导致单批 guard 同时放宽。固定槽位保持下标和身份稳定，不引入动态扩容、metadata 记账或额外授权预留协议。

add_debt 去重后，每个存活项须对应至少一个不同的 Product 记录；batch 与单附件跟踪不能重叠。rememberAddDebt 饱和显式返回 CleanupFailed，不走 unreachable；保留 Product debt、已有映射及必要 batch 关联，不能丢追踪后在重试中误报 cleaned/released=false。

### 4.2 复用现有保护，不新增阶段配额

保留 max_staged_attachment_bytes 的现有共享原件工作集语义和默认值，不新增草稿原件与待执行原件两套额度，也不在 Task 接收点引入新的额度转移事务。继续复用 Task pending 数量、canonical payload 字节、单图编码输出和有界 I/O lane 等现有保护。

原件在等待期间仍计入附件工作集；这是真实资源保护，不是占用了下一条消息的数量名额。原件进入 Run 保留域后、或取消并物理删除后，按现有结算退出工作集；删除失败继续占原资源记录和额度。

不新增全局图片预览预算。先计算和测量现有单图上限与候选记录容量形成的内存边界，再判断是否必须增加保护，见第 6 节。这不表示内存可以无限使用，也不把“没增加预算”当作已经通过压力验证。

### 4.3 在复制前检查草稿剩余数量

Renderer 冻结 scope、generation、operation identity 与当前草稿数量，计算 remainingFiles。为 0 就地拒绝，不打开 picker；DOM files/Native paths 数量已知时提前预检，不读取正文。

统一 metawork.attachments.beginAdd 增加可选 remainingFiles?: number，类型为 JSON u32。当前 Renderer 明确发送，Host 使用 min(单批上限, remainingFiles)，该字段只能收紧上限。0 返回 too_many_files；负数、非整数、超出 u32 范围或错误类型按非法 payload 拒绝。缺省保持既有 revision 1 的单批接受语义，不增加双协议、主动 fallback 或 Host 草稿对象。

picker 前的 prepareAttachmentAdd/beginPreparing 只登记互斥操作、identity、shutdown 和 authority。拿到 selected.count 后先判断数量，再进行资源检查、清理重试、预留、文件探测与复制；这样 7+2 即使工作集已满也先报告数量错误。旧 choose 保留原单批数量校验，所有来源共用同一资源核心。

ready 返回后仍验证当前 scope/generation 和累计数量，再同步 handoff。这是防御迟到结果和草稿变化，不是正常 picker 复制完成后才执行的主准入检查。Host 在实际消息提交时仍独立验证不超过单条上限。

### 4.4 保留生命周期，修正错误呈现

不重写已有 Task 接收和资源结算：borrow/move → Task owned payload → retainForTask/消费 grants → waiting → Run 保留或未执行删除。接收前失败回滚候选并保留未消费 authority；接收成功、回执丢失或 Run 准入后 enqueue 失败均不恢复 token 或重放消息。

取消或断连先撤销资格并观测 writer 静止，再清理；删除失败保留可追踪 debt。已接收消息不因 Renderer 断连取消，Task 原件不因普通草稿清理被删除。正常 shutdown、Task 删除和异常恢复继续遵守现有合同。

错误文案最小调整：

| 原因                                  | 呈现                                           |
| ------------------------------------- | ---------------------------------------------- |
| too_many_files / 本地累计超量         | 每条消息最多添加 8 个附件，保留原草稿          |
| staging_capacity                      | 附件资源暂时不足，本次未添加。请稍后重试       |
| cleanup_failed                        | 附件清理未完成，部分资源仍被占用。请稍后重试   |
| input_busy、文件过大/不可用           | 沿现有对应提示，不混称为空间不足               |
| sendInput capacity_reached / 未知结果 | 沿既有消息状态与对账，不覆盖新草稿、不自动重传 |

不新增 reason、capacity 查询、分页、占用 UI、全局配额条、草稿统计或 allowlist。

## 5. 改动范围与实施顺序

### 5.1 改动位置

| 位置                                                                                                                 | 改动责任                                                                     |
| -------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| `src/product/attachment.zig`、`src/product/control/runtime.zig`                                                      | 单条/单批上限与固定存量分离，保留原件字节记账；调整 preparing 与资源检查顺序 |
| `src/product/control/attachment_staging.zig`                                                                         | 复用通过数量校验的批次、冻结 File/源句柄、有界 worker 和 completion 再授权   |
| `src/bridge/attachment_grant.zig`、`src/bridge/dispatcher.zig`、`src/bridge/handlers.zig`                            | grant/add_debt/drain 上界、显式债务饱和、remainingFiles、复制前拒绝          |
| `frontend/src/bridge/`、`frontend/src/features/composer/`、`frontend/src/app/App.tsx`、`frontend/src/i18n/messages/` | 累计 helper、冻结剩余数、client/fixture 同步、handoff 防御和文案             |
| Task runtime/state、`src/product/attachment_store.zig`                                                               | 以现有生命周期回归为主；只修正本次直接造成的不一致，不新建预算或资源 owner   |

### 5.2 实施顺序与完成条件

| 阶段                  | 工作                                                           | 完成条件                                                             |
| --------------------- | -------------------------------------------------------------- | -------------------------------------------------------------------- |
| 1. 固定故障           | 建立小截图多草稿、累计超量与 debt 超过 8 个的回归              | 用例能观察原故障及其 owner，不能只检查新常量                         |
| 2. 资源核心           | 拆分单条/单批和存量容量，保留现有字节结算；调整 preparing 顺序 | 所有 max_grants 使用点分类完成，debt 饱和和完整 drain 均安全         |
| 3. Bridge 与 Renderer | remainingFiles、复制前检查、草稿累计防御、fixture 与文案       | 三种来源行为一致，旧 revision 1 缺省语义及 scope/generation 保护通过 |
| 4. 运行验收           | 真实接收/执行/取消链路、平台输入与内存压力                     | R01–R10 有对应证据，实测决定是否接受 128 条候选                      |
| 5. 合同收口           | 按第 9 节更新实际变化的合同，审查代码、测试与文档一致性        | 报告实现结果、最终参数和未完成的平台证据，不以评审通过代替运行验证   |

实施过程中沿用已有 Task 接收和结算；不先实现已撤回的多套预算。若实测要求改变资源政策，带数据重新评审，不能在本次实现中悄悄扩大设计。

## 6. 尚未验证的资源边界

### 6.1 编码预览的上界与实测

Attachment Runtime 每个资源记录最多持有一份编码预览，单图已有 1,400,000 bytes 上限。按当前 128 条记录，单看该 owner 持有的预览，静态上界是 179,200,000 bytes，约 171 MiB。

这不是进程内存上限：Task pending payload 的 owned copy、正在处理的原件读取、codec 工作集、容器/名称、Renderer 以及 Agent 相关内存另有生命周期。retainForTask 会释放草稿侧预览，但接收提交前的复制峰值仍须测量。现有 lane/codec 并发边界不因记录池变大而扩大。

已记录旧实现 8 图基线，以及本次实现的 8/32/128 图负载、Task 接收/Stop、重复循环与 8 × 100 MB 字节额度耗尽恢复。当前保留 128 条默认容量。采样只覆盖 Host，初始 RSS 差异较大，不能据此推导性能改善；观测峰值也不是内存上限。数据、artifact identity 与限制统一保存在验收证据中，Windows 和真实系统手势仍待补。

若候选容量的内存表现不可接受，应带着测量结果重新选择记录容量，或评审独立预览预算/预览存储方式；不能暗中降质量、放宽 codec/Agent 限制或省略压力用例。任何新增保护仍要说明对非图片和多草稿的影响。

### 6.2 共享资源与存储边界

共享原件工作集和记录池仍可被多个 Task 的 waiting 文件或 debt 耗尽。普通文件原件不进入 pending payload 字节预算，不能靠正文/引用额度证明它不会填满记录池。必须测到真实拒绝及释放后的恢复；增大容量只推迟饱和，不提供公平或隔离。

现有默认原件字节额度为 800,000,000 bytes，恰好等于 8 × 单文件上限 100,000,000 bytes。一份装满最大文件的草稿仍能耗尽该共享额度，使其他添加被拒绝。这是本次保留的资源约束；R01 用 Issue 中的小截图验证数量耦合修复，满字节额度的拒绝与恢复由 R09 单独验证。

异常退出后可能存在尚未执行但已进入 Task namespace 的原件。没有可靠持久化归属证明时，不能解析 opaque checkpoint 或扫描猜测删除。本次保留现有原件恢复和 Task 删除边界，不新增 journal、垃圾回收、整目录硬配额或磁盘公平策略。

如果产品进一步要求“任一 Task 排队多少消息都不能影响其他草稿”，应先明确可承诺的资源范围及准入政策，再单独评审；单纯增加 Q、V 或池大小不能自动兑现该承诺。

## 7. 验收与验证

本机已执行相关 owner、Bridge、Renderer、Native/lifecycle 和真实 macOS Host 资源验证；矩阵定义目标，逐项覆盖与平台限制以验收证据为准。未把模拟或路径注入标为真实系统手势通过。

### 7.1 验收矩阵

| 编号 | 必须观察的结果                                                                                                                                                       |
| ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| R01  | 一份草稿放入 Issue 规模的 8 张 JPEG 截图（每张约 90–170 KB，总量远低于共享字节额度），其他 Task/New task 仍可添加；多次添加 5+3 成功、7+2 整批拒绝；原内容不变       |
| R02  | Run、waiting 消息和新草稿共存，在现有共享字节预算及记录容量内可继续添加；没有将单消息名额累计到整个 Task                                                             |
| R03  | DOM/Native/picker 均在复制前拒绝超量；资源满时数量超限仍优先命中 too_many_files；创建/复制/codec 次数为零                                                            |
| R04  | remainingFiles 缺省兼容、合法收紧、0/非法值和篡改不能突破 Host 上限；旧结果和切页不覆盖新草稿                                                                        |
| R05  | 超过单批上限的 grant/add_debt 存量可追踪；完整 disconnect drain；debt 重复、交叉关联、临界及人工饱和不 panic、不丢追踪、不误报 cleaned                               |
| R06  | 接收前 allocation/move/projection 失败保留原 authority；接收后响应丢失或 Run enqueue 失败不重放、不恢复 token；提交后草稿侧预览释放                                  |
| R07  | Stop、任务失败/删除、断连、shutdown 与异常恢复沿既有 owner 结算；Run 原件保留至 Task 删除，取消的未执行原件删除，删除失败继续占额度与记录                            |
| R08  | 一个或多个 Task 的普通文件 waiting 在 payload 未满时填满记录池；明确资源拒绝，进入 Run 或取消并物理清理后可显式重试，其他内容不损坏                                  |
| R09  | 8 × 100,000,000 bytes 原件耗尽现有默认共享字节额度后，其他添加明确拒绝，释放后恢复；记录耗尽、单图格式/大小失败和分配失败分别有明确结果，不静默跳过 guard 或假装释放 |
| R10  | 第 6 节的内存基线、常用与极限负载、接收复制峰值及重复循环有证据；若峰值不满足要求，参数与设计不能被标为已验收                                                        |

### 7.2 验证层与证据

在正式 owner 测试、Bridge/Renderer fixture 与真实 lifecycle 分层观察；真实桌面另外验证 Windows 原报告、DOM/WebView2 与 New task 加号，macOS picker/Native 路径、两平台图片粘贴、公开 SDK codec 和 writer 取消。模拟不能替代手势和 codec，文本插话 Windows 脚本不能替代附件 vertical。

执行按[验证规范](../validation.md)：Renderer typecheck 与受影响 attachment/composer/contract suites；Product Control/Task roots；正式 Native graph；canonical bundle 下的 lifecycle；必要平台与内存压力证据。没有 staged bundle、平台或其他 required evidence 时明确失败或列为未完成，不绕过 verifier。标准入口的完整 Native graph 通过；完整 Node suite 有 3 处失败，其中 2 处在旧基线稳定复现，另一处未复现且未归因。`npm run check`、受影响 suites 与完整 lifecycle 通过。

## 8. 复盘与取舍

此前方案将“资源必须有界”直接推导成“需要多套预算”，又把“Task 取得消息所有权”与“原件立即退出共享账本”混为一谈。代码已经复制 owned payload、消费 grant 并释放草稿侧预览；waiting 原件继续登记，是为了执行与清理，不能据此判定交接有缺陷。

因此撤回独立草稿原件额度 D、待执行原件额度 Q 和图片预览额度 V。现有共享原件预算、Task payload 预算与单图编码上限先继续承担保护职责；记录容量独立配置有直接故障依据，予以保留。严格公平、阶段隔离或独立预览预算需要额外产品要求与实测依据，不能由本 Issue 自动推导。

竞品公开文档可以参照用户可见的限制和交互，不能证明其内部采用某组预算。历轮评审发现并收口了 add_debt、复制前数量校验、无必要的诊断接口与动态扩容；最新 APPROVE 确认收窄方案无阻塞问题，不替代参数合理性和运行证据。

## 9. 文档与合同边界

本文是实施计划与复盘，不是 decision record，也不替代领域真源。本次已按下表更新实际改变及本链路需澄清的合同：

| 真源                                                                            | 范围                                                                                      |
| ------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| [产品需求 §5.3](../requirements.md#53-task)                                     | 单条消息累计数量、多草稿及共享资源约束；不新增阶段配额                                    |
| [UI 设计 §8.2](../ui-design.md#82-文件附件)                                     | 所有来源复制前准入、整批拒绝及准确提示                                                    |
| [Product 架构 §2.6](../product-architecture.md#26-文件-attachment-staging)      | 单消息与存量分离、既有共享工作集及资源结算，不引入 Q/V；精确澄清消息接收与显式 Run 提交点 |
| [Renderer Bridge 合同](../renderer-bridge-contract.md#文件-attachment-commands) | remainingFiles 的可选接受/收紧和缺省兼容；不增加命令、reason 或 Snapshot 字段             |
| [验证规范](../validation.md)                                                    | 原故障、容量与债务边界、回执/生命周期及内存证据                                           |

不修改 app.zon、AGENTS.md、顶层 owner、依赖方向、store 路径、history schema、checkpoint、AgentCore ABI 或 bundle。完整附件能力的既有平台与性能缺口继续保留。

此前核对的[Gemini 上传说明](https://support.google.com/gemini/answer/14903178?hl=en)、[Claude 上传说明](https://support.claude.com/en/articles/8241126-upload-files-to-claude)、[ChatGPT Work 概览](https://learn.chatgpt.com/docs/enterprise/chatgpt-work-overview)与[OpenCode 附件说明](https://dev.opencode.ai/v2/docs/attachments/)仅作为公开产品行为参照，不证明本方案内部机制是竞品惯例。本方案依据本仓库的失败链路与既有合同制定；内部实现与参数的合理性由对应回归和实测检验。

## 10. 实施提交与追踪

实施分支为 `feat/attachment-message-limits`；TinyKG 根任务为 `1540`，子任务 `1541`–`1546` 分别跟踪基线、资源核心、Host、Renderer、验证与合同收口。每项结束时均检查是否可提交，并在 task-close 证据中记录决定。

已提交方案、资源解耦、Host 准入、Renderer 和资源验收；本节随最后的合同收口提交。TinyKG 对最后一条 `1546 depends_on 1545` 返回 `CycleCheckUncertain`，未修改 guard 或替换关系绕过；实际等到 `1545` 完成后才认领收口任务。该依赖边的缺失是跟踪工具限制，不应宣称已成功写入。

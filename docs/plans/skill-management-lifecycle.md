# Skill 管理生命周期调整方案

状态：待实施方案，非现行合同、非 decision record。2026-10-31 复评结论为 **APPROVE / Blocking findings: none**，交付一可进入实施；复评提出的交付二排空规则与验收边界已纳入本文。评审通过不表示实现、测量或平台验收已经完成。

## 1. 复盘与交付决定

本次问题来自能力供给链中的确认、授权、资产事务与执行绑定衔接不一致。整体架构决定 owner 和不变量，具体交付按已证实的问题收敛；不按 issue 数量拆实现，也不预先建立新的安装子系统。

复盘形成以下决定：

- 流程正确性与执行隔离分开交付。来源检查、目标确认、grant 消费和结果呈现可在现有同步事务上修正，无须等待异步改造。
- 同步调用本身不足以证明必须拆事务 phase。先测量文件工作对响应和执行推进的影响，再决定是否启动交付二。
- 异步改造必须同时处理执行容量、全局 store writer 和跨 aggregate 准入。独立线程只能解决工作排队，不能代替提交与恢复协议。
- 锁定对象按实际资源和 effect 区分：整个 management store 的写入串行；Run 可见 target 的修改要求 scope 静止；私有 backup 清理只需 writer；回滚通过排空避免新 Run 持续补入。

| 交付 | 范围 | 启动与完成边界 |
| --- | --- | --- |
| 一：流程修复 | Product 准备记录、统一包规则、目标分类、准入后一次消费、typed 诊断、Bridge/Renderer 接入、验证结果关联 | 可直接实施并独立验收；保留同步文件事务，不预建线程池、reservation、异步 phase 或取消 API |
| 二：文件执行隔离 | 独立文件 lane、store 级 writer、confirmed/candidate、scope reservation、rollback drain、异步恢复与关闭 | 由 §4 的测量证据触发；一旦启动，所有 management persist 入口一起接入，不能只迁移 import |

交付二未启动时明确记为未实施，不添加空测试，也不以交付一通过来证明其并发或平台行为。

## 2. 架构边界与保持不变的合同

能力供给链保持为：

```text
Renderer 管理意图
  → Bridge 连接授权与 typed command
  → Product Control 跨 aggregate 准入
  → Product Skill 本地资产事务、来源与 policy
  → Agent / AgentCore catalog acquisition + lease
  → Product Skill current authority
  → Product Control 在新 Run 前协调 Task/Session 绑定
  → Agent 执行
```

依据：[高层架构](../architecture.md#3-边界职责)、[Product owner 与事务模型](../product-architecture.md#1-owner-与事务模型)、[Skill 合同](../product-architecture.md#24-skill-authority-与本地资产)、[Agent catalog ownership](../agentcore-integration.md#skill-catalog-ownership)。

| Owner | 本方案职责 |
| --- | --- |
| Renderer | 编辑范围、呈现预览与变更影响、显式确认、消费 Host action facts；不猜测安装或恢复状态 |
| Bridge | 严格 wire、window/connection、opaque grant；不缓存源路径、正文或 Product 私有状态，不决定替换 policy |
| Product Control | Workspace/Task authority、quiescence、revision、执行容量和关闭；交付二增加 scope reservation 与 drain，不吸收 Skill 局部 policy |
| Product Skill | 来源与准备事实、目标分类、资产事务、typed outcome、catalog reconciliation；不读取 Task 私有状态，不依赖 Native SDK |
| Agent | 官方 catalog、identity 和 lease；不安装资产、不决定产品 scope |
| Application | 原生 picker、窄 effect 组装、wake 和整体生命周期；不新增 Product Control 内部用例的 coordinator |

inventory/Transactions、sources/enablement、Core catalog/Agent lease、Task/Session binding 分别是资产、用户策略、当前运行时能力和实际执行的唯一权威。`install_id`、`skill_id`、`skill_policy_key`、Workspace id/epoch 与 Bridge generation 不互相替代。

本方案保留：

- commit 重读并核对源内容；确认后源变化继续拒绝，不静默安装预览快照。
- 既有资源定位说明变换及幂等规则；源摘要证明批准输入，安装摘要对应实际发布字节，原始来源不变。
- 现有 journal 格式、phase、backup 和冷恢复解释；inventory、enablement、source store 格式不变。
- 精确 catalog reconciliation 决定候选是否可用；临时不可验证仍为 `pending_verification`。
- 已接纳 Run 保留原绑定，后续交互 Run 经既有准备边界采用 current authority；Schedule 不因此取得 Skill。
- Skill 持久化健康与 Workspace identity 分配、记录退休和 slot 复用的现有联动。

不新增市场、远程来源、拖放、单文件转换、批量导入、任意深度搜索、通用事务引擎或 AgentCore API；不修改依赖接受政策或弱化 machine guard。详情、导出、来源设置与 enablement 仅修改本方案直接要求的边界。

## 3. 交付一：完整流程修复

### 3.1 Product 拥有准备事实

当前 Bridge grant 保存路径、摘要和 metadata，preview 又不绑定目标。改为 Product Skill 持有一个有界准备槽，初始至多一条，包括 owned source descriptor、解析出的根、源摘要、预览 metadata、目标意图、目标预期事实及单调 preparation revision。

准备槽是内部临时资源，不是新产品对象、持久化 import session 或第二份安装记录。不保留等待用户确认的解压树、打开源句柄或全包内存；预览临时文件在同步准备返回前清理。提交时共用同一来源检查实现，重新解析根、核对源摘要并构造安装副本；复制后摘要不一致继续拒绝。

Bridge grant 只绑定 preparation identity/revision、window/connection 和有效期。Product 不接收 Native window id 或 Bridge generation。目标变更推进同一准备记录 revision，使旧确认失效；不额外增加 plan identity，不延长原授权有效期，也不续发已被拒绝的授权。断连、放弃或新来源选择撤销对应未提交准备，不撤销已提交事务。

### 3.2 目录、归档与导出使用一致的包规则

`package.zig` 拥有机械检查、manifest 和摘要，不复制完整 Core parser、winner/conflict 算法。

| 项目 | 确定规则 |
| --- | --- |
| 定义与根 | 排除允许的 metadata 后，候选内只允许一个精确大小写的 `SKILL.md`；它位于所选根或唯一的一层 wrapper |
| 歧义 | 多个定义、多个候选根、更深嵌套、缺少定义分别明确拒绝；根已有定义仍检查额外定义 |
| 示例 | `SKILL.md + examples/demo/SKILL.md`、`wrapper/SKILL.md + wrapper/sub/SKILL.md` 均拒绝；目录与归档不分叉 |
| metadata | 共享排除 `.git`、`__MACOSX`、`.DS_Store`、`Thumbs.db`、AppleDouble `._*` 的规则 |
| 安全与容量 | metadata 不豁免原始归档的路径、类型、重复项、压缩方式和容量校验；保留 no-follow、regular-file、源变化及复制后摘要检查 |
| 导出 | 规范 archive root；导出前通过相同合法性检查，成功输出必须能重新导入；不删除作者资源来“修好”输入 |
| 输出大小 | store-only ZIP 须将 header/目录开销计入 importer 的现有 32 MiB 输入上限；展开资源不超过 64 MiB 并不保证输出可接受。超限具体报错，不留下成功产物，不放宽上限 |

多定义拒绝沿用现有 artifact 合同，由目录向归档规则对齐。新增 wrapper/metadata 接受与目录多定义拒绝在实施时同步对应合同；现有不合规受管目录不在启动时自动改写或删除，导出/重新导入给出明确修正原因。

### 3.3 确认绑定目标与变更影响

安装范围只允许个人或一个已注册、已授权的 Manual Workspace；不从当前 Task 路径推断安装 authority，不向 Automatic Workspace 开放项目管理。

| 目标事实 | 用户确认的意图 | 唯一事务路径 |
| --- | --- | --- |
| 目标不存在 | 新增到指定 scope | publish，生成新 `install_id` |
| 同 scope 已有可管理受管资产 | 更新这条资产 | reimport，保留原 `install_id` 和 policy 关系 |
| canonical root 存在未登记目录，且能证明既有替换 authority | 替换这个精确目录 | 既有 unmanaged replacement/backup 事务 |
| 外部管理、authority 不明、待恢复或身份不匹配 | 当前不可提交 | typed blocker，不接管其他来源的同名 winner |

不再通过一次失败安装来发现冲突，也不使用可套到其他目标的独立 `allowReplace`。确认绑定 scope/epoch、目标分类、安装 identity/版本及已观察目录摘要/身份；正式变更前再检查，变化后要求重新准备与确认，不自动换目标。磁盘检查仅承诺当前 no-follow/文件事务能力可证明的范围，不宣称通用跨进程 filesystem CAS。

显式 reimport 始终绑定原 install identity 与 invocation，不借此改名或迁移 scope。普通导入可识别受管更新，但必须确认其影响。保留未登记目录替换的既有恢复实现和测试职责。

### 3.4 先准入，再一次性消费

来源准备不修改 canonical root、不占 Task active-operation 槽，允许在 Task 运行期间预览。正式提交在一个同步 owner 调用内完成：

1. Bridge 校验当前连接授权、preparation identity/revision 和显式确认。
2. Product Control 校验 Workspace id/epoch/root/authorization、相关 Task quiescence 和 shutdown。
3. Product Skill 校验 management/source 健康、现有 verification/recovery gate、源摘要和目标预期。
4. 所有接纳前检查成功后，在同一个主线程决定中消费 grant，进入现有 publish/reimport；期间不引入异步间隙。

接纳前 busy 或容量不足不调用 `consume`，保留仍有效准备供显式重试。源/目标变化使相应准备失效，要求重新准备。过期、失效或已消费授权继续严格拒绝；不自动重发、恢复或修改 `State.consume` 的拒绝规则。进入事务后的失败也不恢复已消费授权。

### 3.5 Bridge、Renderer 与结果关联

保留 `skills.chooseImport`、`install`、`reimport` 动作名。交付一增加 `skills.prepareImport` 支持显式目标变更/重新准备；exact wire 与 manifest、handlers、client、fixture 同批收口，不接受旧 payload fallback，不预登记交付二的 API。

- `chooseImport` 经 Application 原生 picker 取得来源，携带页面初始 scope/重新导入目标，由 Product 同步准备；picker 取消与 typed 校验失败区分，原生选择不使用普通短 transport timeout。
- `prepareImport` 只接收并校验有效 opaque preparation grant 和 typed 目标意图，不接收路径、不延长授权，也不消费正式提交的一次性确认；推进 revision 并撤销旧确认。
- `install/reimport` 提交准备 identity/revision 与显式确认，scope 和原资产预期由 Host 记录拥有。
- 交付一不增加事务取消入口，也不改变 uninstall/Retry 的执行模型。

入口改为紧凑来源菜单：选择安装包或文件夹后进入既有原生 picker，再进入预览/确认；保留 Native SDK 两种选择模式。默认沿用页面个人/项目范围，确认时始终显示目标和新增/更新/替换影响。源 metadata 与安装内容变换提示有明确含义，不混报大小或文件数。

诊断至少区分来源不可用、定义缺失/多个定义/布局不支持、非法路径或类型、包损坏、容量超限、源/目标变化、busy、文件失败与结果未知；需要不同后续动作的事实不合并为通用失败。安全原因进入 typed code，Renderer 本地化，不显示 raw 异常或源路径。

`skillManagement` 提供有界当前/最近操作关联：opaque identity、实际 phase、可空 install identity、scope、安全显示、typed reason 和 action facts；最多保留一份终态结果。预览正文走 typed command，物理路径、原生 handle、摘要、raw diagnostic 和完整包内容不进入 Snapshot。

阶段按实际事实投影为准备、可确认、提交、等待验证、可用、已回滚、需恢复、拒绝、取消或结果未确认；同步实现不伪造可查询的后台进度。preparation revision、请求 audience 或 scope/epoch 变化后丢弃迟到结果，断连禁用提交。传输失败只触发 resync 与“结果未确认”，不自动重试可能已生效的安装。

### 3.6 发布、验证与执行衔接

沿用现有 Reconciliation，绑定精确 install identity、operation、scope/epoch 与 request generation。普通 refresh、其他来源 winner 或陈旧查询不能完成管理事务。

| 结果 | Product 行为 |
| --- | --- |
| 候选可用 | 完成事务与私有备份清理，发布真实资产状态 |
| Core 明确且可归因的 definition/resource/conflict 失败 | 恢复旧资产或撤回新资产；真实回滚结束后报告结果 |
| catalog 暂不可验证、尚未运行或不能归因 | 保留 durable `pending_verification`，提供 Host 允许的 Retry/Uninstall |
| 文件恢复或清理失败 | 根据实际 phase 显示 `recovery_required`；不能用 catalog 成功覆盖文件失败 |
| 持久化结果未知 | 保留 journal/artifact，按现有 health 冻结并进入既有恢复路径 |

发布 durable pending 后即可返回，不等待 catalog 开始/完成。个人变更和项目变更沿现有 affected scope invalidation、latest reschedule、generation 与 lease 生命周期处理；不主动重绑所有 Session。后续交互 Run 经 `prepareTaskSkills` 和 idle binding 采用 current authority，历史不改写。

准备失败不 poison Session、不伪造 Run cause。Snapshot 和结果查询只读取事实，不推进安装、重试、回滚或 Run。重启不复活未确认准备，不新增操作历史，继续严格恢复现有 durable transaction。

## 4. 测量与交付二启动条件

交付一完成时，对精确 revision、当前平台与 artifact 分别测量：预览、源复核、解包/复制、journal persist、文件发布/恢复、验证结果处理的连续主线程耗时。覆盖常用小包、上限内多文件/大文件、目录与压缩包，并比较无 Run 与默认四个 Run 持续运行时的表现。

记录 picker 返回到预览、控制动作响应、event pump 推进和 Run 终态；区分源 I/O、事务 I/O 与 view 构建，不将 view 时间预算直接套成文件事务预算。根据[执行隔离合同](../product-architecture.md#31-产品视图与执行推进)判断是否有文件工作导致的可复现响应冻结、已有 deadline 失败或执行推进受阻。

存在此证据才启动交付二；没有证据则交付一独立验收，交付二保持未实施。一次测量只证明对应 artifact/平台，不扩大为其他 target 的结论；不通过改队列、放宽超时或跳过验证掩盖失败。

## 5. 交付二：有证据后实施的文件执行隔离

本节为条件设计，不是交付一的前置任务。启动时同步迁移全部 writer 和调用方，不保留同步 fallback。

### 5.1 独立文件 lane

Product Control 创建和关闭一个独立 bounded Skill file lane，初始一个 worker、固定有界队列，复用 Executor 实现与窄 job port。长 Run 同步占用共享池 worker；准备和文件 phase 不进入该池。lane 执行重读、哈希、解压、复制和 management 文件 effect，不等待用户，不执行 AgentCore catalog 查询。

owner 线程负责 admission、generation、事务决策和完成接纳；worker 只持 owned payload、冻结 root/store capability 和必要文件资源，不持 Runtime、State、Transactions 或可变 inventory 指针。stale completion 只释放资源。

隔离保证仅为：已经通过 Product 准入并取得 lane 容量的文件 job 不排在 Run worker 后面。catalog 仍在现有共享查询池，单个 verification attempt 仍可使各 scope 的下一次 management/source mutation 返回 busy；本交付不承诺消除该全局 verification gate 或 catalog 饥饿。

### 5.2 整个 management store 的唯一 writer

writer 的资源身份是 `skill-management.json`，scope 无关不豁免。所有全量 inventory 持久化入口统一接纳：

| 写入口 | 必须覆盖 |
| --- | --- |
| 新增、更新、未登记目录替换、卸载 | journal、rename phase、发布和清理 |
| Retry、失败后一次恢复、启动恢复 | 全部恢复 phase 与提交 |
| Workspace 重新授权 | `recoverTransactionsForScopeNoFail` 的写入链 |
| record 退休 | `transactions.retire`，及 retirement/hidden slot reuse gate |
| catalog 验证结果 | commitReconciliation、rollbackReconciliation、markReconciliationUnavailable 与其写入 |

owner 分开保存最后确认的 inventory 和在途 candidate。effect packet 从当前 confirmed inventory/store generation 派生为 owned bytes；Snapshot、其他编码、Workspace 最大 id 和退休判断读取 confirmed 事实，并检查 writer busy/health。只有当前 writer identity/generation 的成功 completion 才提交 candidate；失败/未知结果沿既有冻结规则处理。

其他写入口返回 typed busy 或保留现有有界 lifecycle/reconciliation intent，不能同步绕过 persist。跨 scope 请求取得 writer 后重新从最新 confirmed inventory 构造，不能提交排队前编码的全文件 bytes。sources/enablement 保留各自物理 writer 与既有联动，不读未确认 management candidate。

writer busy 不等于 corrupt，不自动禁止所有新 Workspace id，但不能完成依赖同一 store 写入的退休或 slot 复用。事务实现仍由 management.zig 拥有，按现有 phase 拆出 owned effect 与 completion 接纳；沿用 journal、candidate/backup 命名和冷恢复，不建立第二套 writer、staging journal 或恢复算法。

### 5.3 scope reservation 与发布边界

Product Control 统一协调 reservation：personal 影响全部相关 Task，project 影响对应 Workspace，范围沿用现行 quiescence。来源准备不占用 reservation；正式文件工作在 Task 静止、writer/完成容量可用后接纳，授权消费与接纳仍为一个 owner 线程决定。

reservation 期间阻止冲突新 Run、自动接续、restore/rebind、Session mutation 和 scope 变更的实际接纳；普通消息继续接收，Stop/取消等收尾操作可用。target 移动期间也阻止相关 catalog query、definition/export 读取和冲突 policy/source 写入；已在途相关查询先静止。私有 backup cleanup 不增加 scope 屏障。

文件发布的释放点必须明确：journal 已 durable 进入 `reconciliation_pending`、文件 worker 静止、pending 与 authority 变化已发布，即释放本次 reservation 和 writer。随后调度精确验证；已入队、QueueFull 或尚未开始均保持 durable pending，不等待 catalog，也不设含糊的“长期不可验证”阈值。

### 5.4 验证成功只清理，失败回滚先排空

成功的 commitReconciliation 只提交结果、结束 inventory transaction、删除本事务私有 backup/candidate，不再修改 Run 可见 target。因此只需全局 store writer，不要求 Task 静止；纯 metadata 的 markUnavailable 相同。仍校验事务 identity、scope、phase 和私有路径 authority。

rollback/recovery 按实际 effect 分类；修改 Run 可见 target 才需 scope reservation。对候选的精确失败验证在同一个 owner 决定中：使失败 authority 失效，并登记 transaction-bound rollback drain，停止该 scope 的新 Run、自动接续及冲突 mutation 进入。已有 operation 正常收口，消息接收与 Stop 保持可用，不取消或重放已接纳 Run。

drain 不持全局 writer。每次 operation 结束先推进 drain，再接纳相关新输入；全部静止后取得 reservation，writer 可用时执行回滚。已具备执行条件的回滚优先于未接纳的新管理写，不抢占在途 effect。进展不依赖 wake 碰巧命中空闲时刻，但仍取决于已有 operation 真正结束，不对权限等待宣称固定时限。

drain 绑定 install/transaction、scope/epoch 和验证代次。取得 writer 后从最新 confirmed inventory 复核；回滚及 authority 变化收口后释放。失败、未知结果或 authority 失效保留必要的恢复事实与能力阻断，显式 Retry 按既有恢复资格接续，不恢复已证明失败的候选、不无限重放安装。

### 5.5 Workspace 生命周期

同 scope drain/reservation 存在时，移除在 `prepareRemoval` 之前返回 typed busy，epoch、authorization 和移除状态均不改变；不新增“已请求未开始”状态。已经 `.removing` 的 Workspace 拒绝新管理提交，沿既有两阶段移除。

无关 scope 可进入 removing，但全局 writer 在途时不得完成 Skill record 退休或隐藏 slot 复用。无冲突重新授权可发布 authority，其附带恢复写入等待全局 writer；同 scope root/epoch 变更在 drain/reservation 期间返回 busy。所有路径都不能用同步 recover/retire 绕过 writer。

### 5.6 取消、进展与 shutdown

交付二才增加 `skills.cancelImport` 及异步 responder；uninstall/Retry 与全部 persist 入口一起迁入 file lane/writer，不因此新增卸载或 Retry 的取消协议。详情/导出只增加必要的冲突读取准入。

取消只在首次 journal persist packet 交给 writer 之前受理：等待前置复制静止，清理未发布资源，不恢复已消费 grant。packet 一旦交付就关闭取消 gate，不等 success acknowledgement；此后只继续现有 phase 或失败恢复，不新增 durable cancelled 转移。

接纳前容量不足无文件变更、不消费确认；进入事务后至多一个在途 effect 和一个待推进 phase，completion/wake 推进同一操作，准备工作不能抢占其必要 phase 容量。首次 persist 后换页或断连不撤销事务。

shutdown 停止新接纳、撤销未提交准备，收口已交付 effect 和持久化确认，再停止 lane、释放 FileStore。无法继续或结果未知的 durable phase 留给现有冷恢复。effect、responder、reservation 与资源 exactly once 释放；物理删除失败保留有界 cleanup debt，不能通过取消/重连假装返还容量。私有 staging 清理不扫描 canonical root。

## 6. 实施顺序与代码归属

| 阶段 | 工作 | 退出条件 |
| --- | --- | --- |
| 一 A：Product 准备与包规则 | package/state/runtime/management_runtime 收口准备、根、目标、摘要；复用现有 publish/reimport | 准备不改 canonical，源变化拒绝，受管更新保留 identity，成功导出可 reimport |
| 一 B：同步调用方接入 | Control 准入顺序、Bridge grant/wire、页面 scope/菜单/确认、结果关联 | 一次确认只接纳一次，目标影响明确，具体错误可恢复，迟到/断连不重放 |
| 一 C：独立验收与测量 | 行为测试、当前平台链路、文件工作测量 | 交付一可交付；单独报告交付二有无启动证据 |
| 二 A：证据触发后隔离文件工作 | management/ports 的 phase effect、confirmed/candidate、全局 writer、Control 独立 lane | 全部 persist 入口串行，无未确认 phase 外泄，旧 journal 冷恢复成立 |
| 二 B：跨 aggregate 进展 | Control reservation、drain、移除/退休 gate、验证释放点、取消/关闭 | 排空不饥饿，成功 cleanup 不等 Task，catalog 不占文件 reservation，资源 exactly once |
| 二 C：整体验收 | 正式 Native graph、故障/压力测试及平台文件行为 | 无同步 persist 绕行，交付二边界和恢复矩阵闭合 |

优先在现有 owner 内调整，只有 owned job 资源释放和 phase 执行确有内聚/测试收益时才拆内部文件。不新增顶层 Import aggregate、通用 facade，或让 Application 编排同一 Product Control 内部事务。每批同步收口必要调用方，移除被替代路径，不预建交付二接口或长期兼容层。

## 7. 验证与验收

按实际改变的失败模式选择 owner 和观察层；两批分别报告结果。

| 交付 | 观察层 | 必须证明 |
| --- | --- | --- |
| 一 | package inline | root/wrapper、多个定义一致拒绝、metadata 与安全/容量限制、摘要稳定、输出大小与导出再导入 |
| 一 | Skill runtime/Transactions | 准备 revision、目标变化、managed/unmanaged 分流、源变化、既有失败恢复与摘要变换 |
| 一 | Control/Bridge + 跨语言 fixture | scope/epoch、先准入再消费、严格 shape、raw path 拒绝、取消/拒绝/未知结果区分、过期/消费 grant 不复活 |
| 一 | Renderer DOM | 项目默认范围、目标重确认、替换不复用 token、具体错误、pending/rollback、迟到与断连、焦点和窄窗 |
| 一 | 当前平台真实链路与测量 | 目录/ZIP 导入、同名更新、坏候选回滚、普通/typed Skill 资源读取；记录实际响应与 event pump 影响 |
| 二 | store 并发/故障注入 | A persist 暂停时，B 重新授权恢复、retire、验证结果均不并发写；取得 writer 后从最新 confirmed 派生；各 phase 失败/未知/cleanup 与冷恢复 |
| 二 | Control/生命周期 | Run/restore/rebind、scope 变更与 target effect 互斥；消息/Stop 可用；移除 busy 不改状态，退休/复用检查全局 writer |
| 二 | 验证结果进展 | Task 连续运行不挡私有 backup 清理；失败验证登记 drain，连续输入/auto-continuation 不抢先补入；personal/project 分别覆盖 |
| 二 | lane/调度 | 已获准入和 lane 容量的 job 不等待四个长 Run；catalog queued/QueueFull 时文件 reservation 已释放；全局 verification busy 仍如实保留 |
| 二 | 取消/关闭与平台 | queued/copy cancel、首次 persist 后拒绝取消、stale completion、队列满、wake、join、cleanup debt；Windows sharing/rename 行为实测 |

正式验证先执行 `node scripts/verify-staged-agentcore-bundle.mjs`。当前入口包括：

```sh
npm --workspace @metawork/renderer run check
node --test scripts/skills-center.test.mjs scripts/skill-sources-interaction.test.mjs scripts/workbench-contract.test.mjs scripts/bridge-client.test.mjs scripts/architecture-boundaries.test.mjs
npm test
npm run build:debug
```

新增测试进入现有发现/graph；共享 owner、module graph 与跨 aggregate 生命周期变化执行正式 Native graph，不以直接 `zig test` 替代。缺少 canonical bundle 或 required evidence 明确失败，不能跳过 AgentCore 后报告成功。

共有状态机先在当前平台验证；Windows/macOS 的 picker、文件占用/rename、大小写与窗口交互有独立失败模式，发布前完成对应平台验收。压力、event pump 隔离和真实模型/Skill 链路不能由 SSR 或关键词 guard 替代，不机械扩大到无关 target。

交付一以确认内容/目标一致、一次消费、导出可重导入、真实验证结果和既有恢复不变为验收核心。交付二另证明 store 唯一 writer、target effect 互斥、回滚排空、成功清理无需 Task 静止以及取消/关闭资源收口；不宣称消除了全局 verification busy。

Issue #31、#32、#42 仅作为输入和交互验收样例；关闭依赖实际证据，不因方案落盘、评审通过或普通测试通过而关闭。

## 8. 合同与文档更新边界

实施时只更新真实改变的合同，方案本身不提前改变真源：

| 真源 | 对应变化 |
| --- | --- |
| [Product 架构](../product-architecture.md) | 交付一准备/提交所有权及 artifact 规则；交付二才加入独立 lane、store writer、reservation、drain 与异步恢复 |
| [Bridge 合同](../renderer-bridge-contract.md) | 本批实际 command、grant/结果 shape、operation projection、未知结果和取消语义 |
| [产品需求](../requirements.md) | 可观察的目标确认、输入接受与后续动作 |
| [UI 规范](../ui-design.md) | 来源入口、预览确认、等待验证、错误恢复与焦点 |
| [app.zon](../../app.zon) | 仅登记实际接通的 command allowlist，不弱化拒绝规则 |
| [验证规范](../validation.md) | 仅在验证责任、标准入口或长期平台证据变化时更新 |

不修改 AGENTS.md、不镜像其他真源、不改 SDK/bundle，不替换既有受管资源说明合同或将本文当作 superseding decision。普通测量只有仍决定实施选择时才保留为必要证据，不建立 active archive。

## 9. 评审决定归纳

| 评审主题 | 本文采用的决定 |
| --- | --- |
| 共享 Run 池饥饿 | 独立 file lane；catalog 保留原查询池；性能范围见 §5.1 |
| scope writer 不足 | 所有 management persist 使用同一个 store writer；confirmed/candidate 分离，见 §5.2 |
| Workspace 移除状态 | drain/reservation 时 prepareRemoval 前返回 busy；退休另查全局 writer，见 §5.5 |
| 多定义与输出不可重导入 | 目录向现有严格归档规则对齐；输出体积含 ZIP 开销，见 §3.2 |
| 改造规模缺少证据 | 同步修复独立交付，测量触发交付二，见 §1、§4 |
| 取消引入额外事务转移 | 首次 persist packet 交给 writer 即关闭取消，见 §5.6 |
| 验证结果可能饥饿 | 成功 cleanup 只用 writer；target rollback 先 drain 后 reservation，见 §5.4 |
| 验收承诺过宽 | 仅承诺已获准入的文件工作不排在 Run 后；保留全局 verification busy，见 §5.1、§7 |

上述决定已合入正文，不保留逐轮补丁式方案或被否决的 active 路径。本文整理未修改运行时代码；交付一尚待实施，交付二尚待测量与启动判断。

# SQLite 历史接入：事务盘点与最小方案

状态：讨论草案，未授权产品实现、数据迁移或格式切换。日期：2026-10-27。
代码基线：`2cef8fd310840e8089bc6c289c8af04157b5ceda`；讨论分支：`feat/sqlite-storage`。

本方案以实际解除 #12 的每 Task 16 个 Run、#25 的累计 50 个 Task 限制为目标。上一分支只完成历史/执行分离、Session 压力回收和有界搜索，不能据此关闭两条 issue。既有非 SQLite 容量测量和追加文件提案保留原样，不作为本方案实施依据。

真源：[Product 事务与历史](../product-architecture.md)、[Storage 合同](../storage-architecture.md)、[Bridge](../renderer-bridge-contract.md)、[验证](../validation.md)。以下是待评审的实施选择，不修改现有真源。发生实际合同变更时才同步对应章节。

## 1. 已核对的现状与范围

- Application 仍注入 `task_persistence` 的整份 `bytes` capability；普通保存、确认保存、结果读回和显式恢复都消费它。只把这些 bytes 塞进 SQLite BLOB，仍会整库编码/重写，不能解决问题。
- Storage 已有一个稳定地址的 Database、同步 SQL capability、原子 mutation batch、迁移身份、WAL/FULL、取消及 shutdown；不重做 backend。
- Product Control 已有 1–8 历史迁移，但只由隔离测试消费；现有 SQL 实验甚至明确以 `UnsupportedOutputRecords` 拒绝成果记录（`tests/product/history_schema_test.zig:953`）。不能直接把测试 codec 当 production adapter，也不能把“建表成功”等同于“历史已接入”。
- 仍存在 Task 50、Run 16、Compact 16、审批环形缓冲 8、跨 Task 共享 1.5 MiB 投影预算，以及全局 framed 文件 16 MiB 上限。只改其中一项会把故障推到下一层。

本轮只替换 Workspace/Task 产品历史存储。Account、Models、Schedule 定义/occurrence、Skill、MCP 配置保持各自 store；checkpoint blob、附件和 File Changes artifact 保持现有文件 owner 和目录。SQL 保存引用，不把这些文件一并塞进数据库。

复用单连接、现有 SQL capability 和已有审批/恢复 worker；不引入 ORM、通用 repository、连接池、第二查询连接、自定义日志、双写、FTS 或完整异步事务引擎。首版仍恢复精简后的全部历史到内存，Host 搜索继续使用已有 Unicode 匹配；不同时建设磁盘历史缓存系统。

## 2. 事务边界盘点

下表区分三类确认方式：

- **尽力保存**：内存接纳是当前进程事实；磁盘失败/TaskBusy 不撤回已接纳操作，待后续补写。准备、身份校验或不可恢复编码错误与 I/O 失败不同，仍可在发布/执行前拒绝。
- **必须确认**：只有存储确认提交，才安装候选、交付权限或释放资源；明确失败回滚候选，结果未知保留原候选及相关资源，按该业务原有规则收敛。
- **外部两阶段**：文件或 Agent effect 与历史数据库不是同一个事务；保留现有先后次序，不能用 SQL 事务伪造跨文件原子性。

表中的“共同保存”是最小业务一致性闭包，不代表每次重写列出的全部对象。没有变化的历史正文不进入提交。

| 编号与操作 | 最小共同保存的数据 | 确认、失败及恢复 | 当前入口证据 |
| --- | --- | --- | --- |
| T01 打开/重新授权 Workspace | Workspace 身份、epoch、可见性、顺序；root 身份/顺序高水位；发生替换时包含被替换的记录 | 尽力保存；准备失败可撤销 candidate；目录授权和 Skill 注册不成为数据库权限 | C: `openWorkspaceInternal`，3587 |
| T02 移除 Workspace | 移除意图对应的 Workspace 状态/epoch；最终状态变化及高水位；关联 Task 的关闭/coverage 变化按实际后续阶段提交 | 尽力保存；Session 异步关闭与最终移除分阶段；不删用户工作目录 | C: `removeWorkspaceAtEpoch`，3971/3993/3998 |
| T03 交互式创建 Task | 新 Task header、所属 Workspace/Automatic owner、相关顺序及 root 高水位/默认审批偏好 | 尽力保存；数据库失败不回滚已经接纳的 Task；启动不创建恢复 Session | C: `createTaskInWorkspaceInternal`，4118；`prepareTaskInWorkspaceInternal` |
| T04 接收消息、采纳追加输入 | 安全输入/submission、消息/展示高水位；采纳后的 additional input receipt/state；队列记录移交与 Run 关联一起保存 | 尽力保存；接受/未知结果不重发；原文 payload 和失败 reason 不落盘 | C: `sendInput`，5018；R: `receiveInput`、`finishWaitingInput`、`submitInputImpl` |
| T05 接纳新 Run/一次接续 | Run header、输入/submission、Task active operation/执行事实/顺序与 generation 高水位、Workspace 顺序；转入时包含源 additional input 和目标 Run | 尽力保存；原子保留 transferred 关联；提交执行失败后再记录已发生的终态，不重放输入 | C: `admitTaskRunInternal`，5393/5399；R: `PreparedRun`、`markInputTransferred` |
| T06 Tool/输出/文件变化事件 | 变化的 Run 输出、可信 Outputs 回执或 Tool/File Change row，以及所需 order、usage、诊断/状态；生成图片的引用/位置与 Task 展示高水位一起保存；父记录未落盘时包含父链 | 在现有 durable boundary 尽力保存；流式片段只标 dirty，不新增每 token 提交 | C: `applyEvent`，6316；`recordEventProjectionFailure`，6344；`recordDependencyContractFailure`，6354 |
| T07 Run 终态、自动标题 | event drain 后的完整安全回答、terminal/coverage/时间/usage、Task active 状态和顺序；实际变化的标题 | 终态发布后尽力保存；不得回滚 Agent 已完成的执行，保存失败不能提前释放有引用的执行资源 | C: `finalizeMarkedTerminalRunsAfterEventDrain`，6860；`syncLifecycleFacts`，6078 |
| T08 Compact 接纳/终态 | Compact record、Task active operation/高水位；终态及后续 checkpoint 分别按真实边界保存 | 接纳/终态尽力保存；Compact 有独立容器，不占 Run 槽；后续 checkpoint 见 T13 | C: `compactTaskAtBinding`，5433/5438；`cancelCompact`，5458；R: lifecycle |
| T09 Stop/取消/归档/关闭 Session | 安全取消记录、等待输入安全状态、Task/Run/Compact 实际变更；detach 收敛的 coverage | 尽力保存；取消只执行一次；Session 的 lease/关闭线程不落盘 | C: `stopTask`，5044；`cancel`，5498；`detachTaskSession`，5546；`setTaskArchived`，5673 |
| T10 人工权限响应 | UI 决定、来源、脱敏摘要及 order；相关 Run/Task 顺序 | 尽力保存后 deliver；deliver 失败回滚自己的候选并补写，不能据历史推定授权已交付 | C: `respondUi`，5522/5528/5533；R: `PreparedUiResponse` |
| T11 自动审批交付 | T10 的决策和 reviewer 安全理由；必要父链；交付失败后撤回决定的补写 | **必须确认**后才 deliver；失败/未知不交付权限。第二次补写处理 deliver 失败，不等于自动重试工具 | R: `acceptPermissionReview`，2937/2946；C: `commitPermissionReviewCandidate`，5994 |
| T12 选择下一轮模型意图 | Task ModelRef 与 selection revision；不改 active Run execution 或 live binding | **必须确认**；明确失败 rollback；未知保留精确候选，读回后 complete/rollback | C: `selectTaskModel`，5176；`pending_model_intent` / `approval_history_unknown` |
| T13 checkpoint 成功、失败/失效记录 | 新 checkpoint reference、anchor、attempt，以及受覆盖 Run/Compact 的 coverage；缺 blob 时 reference/anchor 同改 | 成功替换及失效删除**必须确认**；overlay 与 checkpoint 同事务。attempt 失败按原逻辑恢复/保留；旧 blob 只在确认后退休 | R: `syncCheckpointPostprocess`，4240/4254/4263；`reconcileCheckpointStoreNoFail`，4147 |
| T14 审批模式切换：基线提交 | 基线 checkpoint、anchor/attempt 和 coverage；保留旧 profile/delegation/revision | **必须确认，现有 worker**；先确认基线才能修改 Agent；失败不授权切换 | R: `prepareApprovalCommit`，1447；C: `encodeApprovalCandidate`，4695；`syncApprovalChanges` |
| T15 审批模式切换：目标提交 | 新 profile/delegation/approval revision、新 checkpoint、coverage、anchor/attempt | **必须确认，现有 worker**；成功后安装模式；失败按现有恢复流程回到基线；未知禁止采纳候选和清理 blob | 同 T14；R: `acceptApprovalCommit`，1530；C: history result reconciliation |
| T16 Execution 重绑定基线 | 原 Session 可恢复的 baseline checkpoint 与 coverage | **必须确认，现有 worker**；确认后才关闭原 Session；不复制其线性所有权 | R: `syncRebindPreparation`，5719；C: `queueTaskRuntimeBinding`，9181 |
| T17 恢复/重绑定目标 adoption | binding epoch、execution generation/protocol/model、checkpoint epoch/目标 reference、相应 coverage；其 ModelRef 意图保持独立 | **必须确认，现有 worker**；成功才安装候选 Session；失败关闭候选；未知保留候选和精确提交 witness | R: `syncRecoveryCompletions`，5919；C: `queueTaskRuntimeBinding` |
| T18 定时任务接纳 | 已准备的 Automatic Workspace + 命名 Task + Run intent + root 高水位 | **必须确认**再 submit。失败 rollback；未知回滚内存但保留物理目录。Schedule occurrence 自己的文件提交仍是另一边界，不改成跨 store exactly-once | C: `prepareScheduledAdmission`，4333；`scheduleTaskLaunch`，8356；`commitPreparedScheduleCandidate`，8920 |
| T19 物理删除 Task | Task 及全部子记录删除；Automatic Workspace 的删除；保留不复用的高水位 | **必须确认**后释放历史/删除 checkpoint、附件、artifact。失败/未知恢复内存候选，保留全部文件 | R: `syncDeletions`，3482；C: `commitTaskRuntimeWithoutTask`，8971 |
| T20 checkpoint/artifact/附件文件 | 先完成既有文件 durable effect，再保存引用及相关位置；SQL 删除确认后才删文件 | 外部两阶段；失败可遗留 orphan；未知不删可能仍被引用的文件；只有可信完整历史才能 orphan cleanup | C: `drainFileChangeCompletions`，2317；R: `reconcileCheckpointStoreNoFail`、`cleanupFileChangeStoreNoFail`；现有附件 owner |
| T21 重命名、已读、默认偏好等元数据 | 只改具体 header/receipt/root 偏好，不携带所属 Task 的全部 Run | 重命名/偏好尽力保存；completion receipt 目前只改内存，随下一 durable boundary/正常退出保存，强杀可丢最后未提交 receipt | C: `renameTask`，5559；`markTaskCompletionSeen`，5680；R: `markCompletionSeen` |
| T22 首次获知凭据与内存清洗 | 实际被改写的持久单位；更早版本及迁移残留的安全清除单独协调 | 不把每次借用/释放升级为整库重写；不允许 SQL 更新后遗留已知凭据却宣称清除完成 | C: `learnProjectionCredential`、`retireProjectionCredential`，9568/9574；R: redaction；§7 |
| T23 正常退出、重启 normalization、显式恢复 | 退出补齐 dirty；重启将无 live owner 的非终态转 interrupted、pending coverage 转 excluded、未完成消息/文件观测按现有规则收敛 | 不恢复原文、不重放工作；unknown 先读回，不能拿新内存状态覆盖待确认候选；损坏恢复仍需显式操作 | C: `shutdownExecutor`，7830；`recoverTaskHistory`，5738 起；R: restore/normalize |

本表只盘 history 边界；Account/OAuth、Provider/MCP/Skill 配置、Schedule 定义文件及用户成果导出不属于同一个 history 事务。模型来源变化导致的 Task 重绑定已由 T16/T17 覆盖，不能把其他 store 一并迁进来。

C = [Product Control runtime](../../src/product/control/runtime.zig)，R = [Task runtime](../../src/product/task/runtime.zig)。行号固定对应上述基线；函数名用于后续定位。

确认链的实际调用点归并如下，不能漏掉“隐藏在 effect 后面”的路径：

- R 的同步 effect：自动审批 2937/2946，删除 3482，checkpoint 验证/attempt/候选 4147/4240/4254/4263。
- R 的异步确认入口：重绑定基线 5719、恢复目标 5919，经 C:9181 进入现有 history worker。
- C 的直接确认：模型意图 5176、Schedule 候选 8356；checkpoint/删除通过 C:8911–8988 的窄 adapter 回到保存路径。
- 审批基线/目标、普通 dirty 补写、模型 unknown 读回与恢复 binding，最终由 [approval_job](../../src/product/task/approval_job.zig):148 执行 `commitConfirmed/resolveCommit`。目前 worker 接收的是主线程已经编码好的全库 bytes。
- `commitTaskStateBestEffort` / `NoFail`（C:9220/9231）吞掉 TaskBusy 和写失败；`markTaskCompletionSeen`、凭据清洗等没有独立 commit。这些都依靠下一次全库保存顺带补写，增量接入必须明确接替。

## 3. 最小运行结构与保存协议

### 3.1 Owner、文件与线程

- 正式路径提议为现有 workbench 目录中的 `workbench-history.sqlite`；与 `workbench-history.store` 身份分离，WAL/SHM 由 SQLite 管理。不开新全局数据库，也不修改旧 framed 文件追加新帧。
- Application 创建稳定地址的 Database，Product Control 借用 `sql.Database`；业务 SQL、loader、dirty 和恢复 policy 归 `control/persistence/`。不让 Task/Renderer 持有 connection 或执行任意 SQL。
- 保留现有调用方式：当前同步确认仍同步，审批/恢复已经异步的仍使用原有 worker。worker 接收深拷贝的业务变化和 witness，不再接收全库 bytes，不读 Runtime/Task/Run 指针。
- 普通保存遇到现有 history job/候选屏障时只记 dirty，不等待 worker 占用的连接。只有一个进程内历史写入者；不另建通用调度器。
- 停止接纳 → 收口并 join 使用数据库的 Run/审批/恢复工作 → 消费终态与确认 → 最终保存 → 释放 Product → Storage shutdown/destroy。Database 必须活得比所有借用者长。

### 3.2 待保存集合，不能只信调用方“这次改了什么”

按真实持久单位维护 dirty 标记与修改版本：root、Workspace header、Task header、Run header、Tool/File Change、Compact、审批决定、等待/追加消息；删除保留 tombstone。标记在拥有数据的变更层完成，worker 的原始观察在 Host 接纳为 durable fact 时标记。待保存入口直接登记有身份的单位，不能每次提交遍历全部历史来重新猜测 dirty。

跟踪空间与对象/删除意图一起预留；不能先改数据，随后因申请 dirty 容器失败而漏标。read receipt、流式输出、凭据清洗、失败补写和 TaskBusy 跳过同样登记。历史编号与修改版本分开，不用 Product UI revision 代替。

一次保存冻结 dirty 的版本及必要父链/跨记录依赖，输出若干**各自完整的业务原子组**：

1. SQL 同一事务包含该组的全部数据和提交 witness。新父记录未落盘时必须随子记录写入。
2. 可以先后提交互不依赖的组，不能把 checkpoint/coverage、转入关联、删除或审批候选拆开。
3. 确认后，仅清除实际提交且内存版本未再变化的标记；unknown 不清除。失败积压没有排空时，不因另一个 Task 局部提交成功就把保存状态恢复正常。
4. 普通补写一轮应覆盖当时全部 dirty 组；必须确认的关键组只以自身及依赖的确认结果交付权限/安装候选，其余失败积压继续保留，不能谎称整个历史已保存。
5. SQL 触发的级联/范围更新也必须更新对应版本账目。checkpoint coverage 可用与现有 overlay 完全相同条件的集合 UPDATE，不能把每个旧 Run 编成一条无界 statement 列表。

测试在补写完成、dirty 清空后，独立读取 SQL 历史并与内存的完整 canonical 参考状态比较；不能复用 dirty 选择器作为参考。刻意漏标必须让比较失败。每个必须确认的事务另验其整体 before/after，不能等最终全绿掩盖中间不一致。

### 3.3 候选隔离和 unknown

审批模式、模型意图、checkpoint、重绑定、删除等继续使用现有 Prepared/overlay 机制。冻结的是该事务的明确候选；临时 overlay 不加入普通 dirty，不让在途候选进入别的保存。确认成功才安装并结算版本；失败回滚自己的候选，不能撤销别的已接纳修改。

将全文件字节比较替换为一个**仅记录最后一次提交**的 witness：在 history root 保存 generation 和该次冻结业务变更的摘要，随同一 SQL 事务写入。保存候选时同时保留此前 witness；不建设通用事务日志或重放表。

SQLite 返回 `outcome_unknown` 时按现有 Storage 规则 poison instance。暂停数据库新写入，保持交互内存事实/dirty 和资源引用；通过 Application 关闭旧借用并重开同一文件，验证 schema 后读回：匹配候选 witness 才确认已提交；匹配此前 witness 才确认未提交；不匹配或读不出则保持恢复待处理。禁止重发 Run/权限/原用户命令，也不能用后来内存重新生成一个候选冒充原事务。只有一个写入者且 unknown 后禁止新写，最后 witness 才足以判定。

普通尽力保存确认未提交后可重新投影**当前安全状态**；这是补写历史，不是重放业务 effect。必须确认的事务仍按 T11–T19 各自规则采纳/回滚。数据库重开不能把未完成 schema/损坏自动清空，读回确认也不等于跨重启 exactly-once。

## 4. 只做必要的 schema 与 Storage 调整

沿用现有身份、BLOB u64、typed JSON、外键及业务校验；不把每个字段拆成表。但当前 schema 的几个聚合 JSON 不适合解除累计上限：

| 当前载体 | 提议的最小变化 | 具体必要性 |
| --- | --- | --- |
| `tasks.compacts_json` | 独立 Compact row | Compact 数持续增长，不让每次修改 Task header 重写全部 Compact |
| `tasks.ui_history_json` | 独立 UI 决定 row | 移除 8 条覆盖，逐条保留/更新/查询，不反复编码全审批历史 |
| `tasks.input_submissions_json` | 按 submission 存安全等待记录 | 接纳、取消、移交只改该记录；64 条消息的编码总量可能超过单次 SQL 值预算 |
| `runs.additional_inputs_json` | 按 additional input 存 row | receipt/采纳/转入独立更新；避免改一次 receipt 携带整轮追加文本 |
| `Run.outputs` 尚未进入实验 schema | 随 Run 保存有界 typed 成果 metadata | 补上当前生产字段，保留 identity、locator、size/digest、redacted；不存文件内容或授权 |
| 当前 retained/read-only frame | 保存有身份的原 payload；与正常行分开加载 | 保留旧版本无法理解的历史与高水位，不因迁移静默丢记录 |
| history root | 最后 witness、初始化标记/来源指纹 | unknown 判定与大规模导入的发布边界，不用文件存在表示迁移成功 |

其余有界 input、commentary offsets、File References、单个 ModelRef 等继续用已有 typed JSON；不改为 EAV，逐项对照当前 `StateWire/restoreTask` 的字段和恢复语义，不把只覆盖旧 schema 的 SQL 往返当完整性证明；不保存 runtime reason、原始 payload、credential 或 live Session。旧迁移身份不原地重写；通过后续迁移新增所需结构，旧聚合列不再作为运行时写入/查询权威。若保留物理旧列是当前 DDL 能力限制，只保留固定空占位，不保留双份 active 数据或两条读取路径。尚未部署的隔离 SQL fixture 随新的生产接受规则收口，不承诺未经批准的开发数据库兼容。

**当前 64 statements / 8 MiB 参数与结果不是已经证明足够的业务上界。** 完整 Run 可涉及 32 个 Tool、256 个 File Change，加上父链、消息与覆盖关系；单条旧合法保留 frame 也可能大于当前 SQL query 预算。不能借用现有限额拒绝本来合法的迁移数据，不能拆开原子事务，也不能改用绕过 authorizer 的 raw SQLite。

最小处理是先为每一种原子组生成最大合法 fixture，计算 statement/参数/最大值及查询结果的真实上界。集合 UPDATE/DELETE 避免随历史总量展开；独立 dirty 组分次提交。仍不够时，只对现有 bounded `mutate/query` 和 engine LENGTH 作有证据的最小额度调整，保留有限数组、单一 COMMIT、authorizer 与 outcome 语义；不开放交互式 transaction handle、callback transaction 或任意 PRAGMA。具体常量由代码和边界测试拥有，不能凭本文先拍一个大数字。额度推导和评审必须在任何用户数据切换之前完成。

## 5. #12/#25 必须连同内存和视图一起解除

### 5.1 容器及预算

- Task、Run、Compact 使用拥有 heap record 的可增长指针集合，避免扩容搬动 worker 持有的 record。只给确有跨阶段引用的对象稳定地址，不为每个 UI 小记录额外建立 owner 层。
- 移除 50/16/16 作为累计历史接纳/恢复限制；UI 历史不再环形覆盖。持久化校验、身份高水位、视图和测试同步修改，不只改 `app.zig` 常量。
- Automatic Workspace 的容量当前由 Task 容量参与分配；Skill 的 Workspace 注册表又沿用这个容量。注册元数据随历史增长，不能在去掉 50 后卡在旧数组；catalog 的真实工作、内容预算和 Session lease 仍独立有界，不为纯历史创建查询或 Session。手动 Workspace 的独立产品限制不借此任意放开。
- 历史结构、已保存正文及其实际 allocation capacity 改计独立历史预算，不挤占原有 1.5 MiB live/catalog 投影计数。worker、原文输入、附件、Session、单字段/单次工具结果和视图缓存继续受各自预算控制。
- 首版全历史常驻；历史预算是资源限制，不是“无限”。同一预算要能装回此前已经接纳的历史；启动若资源不足，明确报告恢复受限并保留原库，不能覆写或将空内存伪装成 ready。以 256 MiB 作为待验证候选，最低规模要求为 100 Task × 256 Run、每 Run 约 4 KiB 正文并含审批和 metadata。必须先测精简结构的常驻和峰值；若候选不能覆盖验收规模，实施前调整并说明，不偷偷增加淘汰/缓存系统，也不把失败当通过。
- 历史预算不足在接纳前拒绝并保留输入；为已接纳 Run 的终态、拒绝权限、取消及必要恢复预留控制空间。流式输出超预算按既有有界投影语义处理，不能出现执行完了却无法记录安全终态。磁盘满保留 dirty 和明确保存失败，不删历史。历史配额是跨 Task 的全局资源预算，拒绝仅影响新接纳，不把数据库误报为损坏，不撤销已接纳的执行；历史读取、取消、安全拒绝及既有删除路径仍可用。UI 精确区分历史配额、Session 名额和保存失败，不都伪装成槽位满。归档不释放历史字节，不能误导用户“归档即可腾空间”。

### 5.2 有界读取

Run 正文与 Unicode Host 搜索复用上一分支。需要补齐的只是随着计数放开而失去上界的 Task 导航、Run manifest、Compact 和审批列表：沿既有 typed scope/cursor 分页，使用稳定 identity 与已有历史/安全版本规则，不建设新分页框架。

审批/Compact 在面板里继续可追溯到所属 Run，不能只返回最近几条冒充完整历史。每个块分别绑定 item/编码字节上界，Renderer 把未返回当作未载入，不当作删除；`worstCaseSnapshotBytes` 不再靠累计 Task/Run 数或共享正文总量证明安全。相关 Bridge shape 改动集中在这一项，其他产品流程不改。

SQL loader 在启动门禁内 keyset 分页读取，row 先构建 provisional candidate，仅 query terminal 为 ok 才采纳；预算失败释放候选后缩小只读批次，不能接纳一半结果。单条合法 row 也必须落在已推导的最大值内。loader 期间禁止业务写入/其他借用者，最后完整校验再发布，所以跨查询观察一致，不需要增加读连接或交互式读事务。

## 6. 新文件初始化、迁移与恢复

正式数据库文件名现在就与旧 store 区分；不等性能探针之后再定格式身份。Application 只打开路径与执行授权 effect，Product 决定初始化/迁移/恢复资格。

1. **已存在 ready SQL 历史**：验证迁移身份和业务 root，完整 loader 校验。只读 SQL；旁边后来出现的旧 `.store` 不再触发自动合并或覆盖。
2. **不存在 SQL 历史**：只有旧 canonical 和唯一恢复/quarantine artifact 都不存在，才能初始化为空。存在旧合法 canonical 则只导入当前支持的 framed 格式；不扩展到旧 JSON/任意开发 frame。
3. **导入先准备**：冻结并校验来源身份，解析原文件；保留合法数据、可识别的只读/retained payload 和计数，按当前规则 normalization，验证其 artifact 引用。无法完整分类或来源读取失败时停在迁移待处理，保留旧文件，不将损坏当空库。
4. **大导入不要求一个无界事务**：在新 SQL 文件内先提交 `copying + 来源指纹` 标记，分有限批次导入；没有 ready root 的这些行不是业务权威，尚不发放 Product capability，也不接纳用户操作。完成后读回完整验证，最后一个事务写 root/高水位并将初始化标记改为 ready，这是唯一业务发布点。
5. **中断**：仅在能证明是本程序未发布的 copying 数据、来源未变且原文件仍完整时，清除该未发布内容后从头导入；不做逐记录恢复日志。未知状态、来源变更或 root 缺失但有无标记的业务数据必须报错，不能猜测为空。最终发布 unknown 先重开读回 ready 标记及来源身份，不能直接清空重来。
6. **旧文件与降级**：发布、重开验证之前原文件不改动。成功后旧文件只是受管迁移证据，不再是 active authority；不建设永久未脱敏备份。凭据维护必须覆盖它，允许在确认导入全部事实后受控退休；未导入的 quarantine/未知材料不得随手删除。旧构建看不到新历史，但不能覆盖 SQL。新版本返回时始终以已确认 SQL 为准；不承诺降级后新增的旧历史自动合并。
7. **损坏与文件**：完整 SQL 中的业务局部失效按 owner 规则隔离，SQLite 文件/迁移身份不可信则不自动重建。显式恢复处理完整 DB/WAL 状态，不只 rename 主文件。checkpoint/附件/artifact 维持原目录和身份；只在完整可信 root/引用集合成立后做 orphan cleanup，unknown、degraded/未分类保留记录存在时不冒险删文件。

正常启动的 normalization 要保存后才能取得未来恢复/清理所需的确认；不能因启动时没有活跃 worker，就漏掉 pending→excluded、interrupted、未完成 File Change 的 incomplete 与消息降级。它不触发原有模型输入重放。

## 7. 凭据与 WAL：只补必要的安全能力

继续在写入前按全部当前已知凭据检查**所有字符串/JSON/BLOB 业务内容**，不只检查 SQL 文本。实际被清洗的单位进 dirty；候选冻结后新获知凭据时，关闭新的历史写入入口，等在途写入明确收敛，再完成当前状态清洗，不提前报告安全完成。

普通 bearer 借用/释放不触发全库重写。首次未知→已知按 owner 安装前的观察判断；扫描包括已载入内容以外的保留 payload、迁移材料及历史存储。不能凭内存没命中或裸字节扫描没命中，证明 SQLite 旧页和 WAL 不含残留。启动时，所有当前已知凭据也必须参与这次进程的初始存储校验；不能因 Account owner 已先持有该值就跳过历史检查。

首版提议：从新数据库第一次写入前启用并回读 `secure_delete=ON`；Product 完成匹配行的安全更新后，由 Storage 的窄维护能力完成并验证 WAL TRUNCATE checkpoint，确保退役页版本不继续由受管 WAL 保留。首次获知没有当前匹配时仍需结算可能的旧 WAL；这是必要的 WAL 清理，不是整库重写。普通重复借用/释放不做这一项。不使用虚拟表/FTS，避免其额外保留边界。

这两项是**当前 backend 尚无的窄增量**，先作为接入前验证项，不宣称已满足：公开 SQL 仍不能执行任意 PRAGMA/VACUUM；只加固定 profile 和可验证的维护结果，具体 C API 留在 Storage。BUSY/IO/unknown 不当作清理成功；保留该次必要 credential lease，阻止把未清理的候选作为安全保存结果。对不可理解且无法安全改写的 retained payload 明确报维护未完成，不丢数据或伪造无命中。迁移原件/受管临时文件必须同样清理，不能 SQL 干净而旁边原文件仍含凭据。

这里的保证限于应用受管文件与既有文件删除/替换边界，不声称擦除外部备份、OS/swap 或 SSD 的取证残留。安全路径若不能在现有单连接 owner 下证明成立，停在用户数据切换之前；不临时造影子数据库/根索引系统。

依据：[secure_delete](https://sqlite.org/pragma.html#pragma_secure_delete) 对普通表更新/删除的擦除及虚拟表限制；[TRUNCATE checkpoint](https://sqlite.org/c3ref/wal_checkpoint_v2.html) 成功时截断 WAL。逻辑行更新不等于旧版本清理。

## 8. 最小实施顺序与停止条件

| 步骤 | 交付与边界 | 进入下一步前必须成立 |
| --- | --- | --- |
| A 核实单元与额度 | 本盘点落到测试 fixture；测 post-refactor 历史内存、最大合法 SQL 原子组/值/查询；已有单连接同步提交与 WAL 维护的 Windows 成本、安装包增量 | 明确生产额度；合法输入无暗中新限制；安全清除验证成立。只做窄 probe，不切换用户数据 |
| B 最小 SQL 往返 | 在隔离目录复用现有 backend/schema，补必要累计表、witness、loader、copying→ready 与受限导入；不改生产 Application | 新旧事实完整对照、unknown 读回、迁移中断、opaque 保全、artifact 引用和安全清理全部通过 |
| C 接上真实持久化路径 | 一次性替换 bytes capability 为 history-specific 变化与冻结候选；dirty/确认协议接入 T01–T23；Application 生命周期切换 | 普通及必须确认路径工作；原有审批/恢复 worker 不重做；移除旧 production writer，不双写或静默 fallback |
| D 解开累计容量 | 稳定的可增长 Task/Run/Compact、审批保留、自动 Workspace/Skill 注册元数据、独立历史预算；补导航/manifest/Compact/UI 分页 | 16/50/8/16 不再作为历史名额；所有视图有界；真实小 Session 预算下不丢历史/重复执行 |
| E 发布前验收 | 正式 Native/Bridge/Renderer、canonical Core、迁移/故障/容量及实际 SQLite I/O 测量；同步实际变化的唯一真源 | 下节完整通过才可关闭 #12/#25；每个可工作的 DAG 子任务完成后评估独立提交 |

不将 C 里的同步调用方全部改成异步状态机。同步 API 不保证主线程一定够快：现有 WAL/FULL 会同步存储，自动 checkpoint 也可能发生在触发提交的线程。A 必须量到这些尾部延迟，不能只看均值或放宽 durability。只有某个实际路径不满足既有执行/展示门槛时，才单独复用已有 executor 并评审该路径的交接；不能在实现途中悄悄扩大为全局异步框架。[SQLite WAL 性能说明](https://sqlite.org/wal.html#performance_considerations)

A 的候选历史预算、Storage 额度、同步提交/安全维护实测与生产包体积是前置 Gate，本文没有把它们写成已测通过。任一结果推翻首版全历史常驻或默认同步的假设，先回到评审调整最小方案，再做 C。此阶段不批准用户数据迁移，也不执行任何删除旧 store 的动作。

## 9. 最小完整验收

1. **#12**：同一 Task 至少 256 个 Run，保留最旧/中间/最新的输入、正文、工具、审批和关联；正常退出/强杀重启后完整，重启后还可继续；Compact 连续超过 16 次，审批超过 8 次不覆盖。
2. **#25**：累计至少 100 个 Task，含超过 50 个已归档 Task，再创建/继续新 Task；同时覆盖共享手动 Workspace 与默认 Automatic Workspace。真实 live Session 设 2，验证压力关闭、关闭失败、显式重试及 checkpoint/Skill/MCP/Permission 连续性，不扩大 Session 数。
3. **跨 Task 容量**：100 × 256 的合法合成历史，正文累计显著超过 1.5 MiB、持久数据超过 16 MiB；实际内存/峰值落在 A 的预算内，能运行、保存、重启、搜索、翻页和读取最旧审批/Compact。大规模 codec/storage 场景不要求进行 25,600 次真实模型请求；真实 Core 另覆盖跨 16/50 门槛的生命周期。
4. **原子性逐项命中**：T11–T19 每条确认路径注入提交前失败、COMMIT unknown、返回后崩溃和读回失败；checkpoint 在途叠加普通保存后失败，重启仍能恢复；coverage/reference、审批/profile 和跨 Run 转入关系不出现一半。
5. **补写**：分别制造 TaskBusy、写失败、仅改已读状态；只触发一次无关 Task 的正常 durable boundary，待补写完成后正常退出和强杀重启。故意漏标触发独立完整对照失败；版本已变化不能被旧 worker 清掉。
6. **接纳与外部 effect**：自动审批确认失败/unknown 不交付权限；人工响应沿原语义；Schedule 候选未知保留目录且不重放；Task 删除未确认不删 blob/附件/artifact；no-fail 终态、拒绝权限和取消的控制空间始终可用。
7. **迁移/恢复**：旧文件不变到 ready 发布；每个导入批次后强杀；来源变化、缺 root、有残留 quarantine、版本过新、局部未知 frame 与损坏分别处理；旧构建使用旧文件后新 SQL 不被覆盖或重复导入；不只测试小历史往返。
8. **凭据**：新建后未知值写入、改写后仅留旧 WAL、长文本跨页/JSON 转义/多个字段、retained payload 和迁移源分别命中；可安全改写的正例在首次获知后受管文件不残留该已知值，无法理解/安全改写的 retained payload 必须明确保持维护未完成，不能通过丢弃它来通过测试。清理失败保持未完成。连续 64 个图像 Run 的重复借用/释放不新增全库扫描、WAL 安全清理或重写；测试与日志不记录凭据原文。
9. **性能与体积**：实际测每次必须确认的提交 P50/P99/最大值、10 次审批的整轮附加等待、启动/重放时间、常驻和峰值内存、DB/WAL 维护及单位 Run/持续负载的实际 I/O。注明 logical 参数量、进程 I/O 与物理写入的口径，不把预设事件数乘文件大小冒充实测，不为采样造产品 VFS。生产 SQLite 编译增量按相同构建配置实测。既有 Debug 32.9481 ms、Release 16.8729 ms 的视图失败保留，SQLite 不自动解决；新增持久化及原视图成本分开归因，既有 Gate 不放宽。

本次只交付这份盘点与草案。没有产品代码、SQL、build、合同或测试实现变更；没有迁移、建库、重新跑性能或替换旧文件。下一次得到实施授权后，先执行 A，而不是直接切换保存路径。

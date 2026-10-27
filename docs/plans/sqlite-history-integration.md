# SQLite 历史接入：事务盘点与最小方案

状态：整合讨论稿，未授权产品实现、数据迁移或格式切换。日期：2026-10-27。
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

## 2. 整合后的唯一候选路线

先接通历史的增量事务与可靠恢复，再解除累计计数和共享预算限制，最后用实际产品路径验收。目标、业务边界、资源上限和证据是不同层，不能用“SQLite 已接上”代替 #12/#25 完成。

| 范围 | 本稿选择 | 本次明确不扩展的部分 |
| --- | --- | --- |
| 数据 | 单个独立历史 SQL 文件，普通更新只写变化单位；文件内容保留原 owner | 其他业务 store、双写、整库 BLOB、新自定义日志 |
| 生命周期 | Application 持有一个 Database，Control 借用；沿用已有同步路径和审批/恢复 worker | 连接池、第二读连接、统一异步事务引擎 |
| 运行期 | 精简历史先全部常驻，执行资源独立；Host 继续有界分页和 Unicode 搜索 | 磁盘历史缓存、FTS、coverage 子系统 |
| 正确性 | dirty + 修改版本、完整原子组、有限合批、一个最后 witness、owner 原有确认方式 | 事件溯源、通用重放、跨 store exactly-once |
| 导入/恢复 | 未发布临时库完整校验、WAL 收尾并关闭后发布；既有应用内恢复入口 | copying 标记、来源进度库、实验 schema 兼容层 |
| 容量验收 | 100 Task × 256 Run、超过旧正文/文件上限、真实小 Session 预算恢复 | 只提高 16/50、把 256 MiB 候选当已证明的峰值 |

23 项业务边界和实际调用点集中在附录 A。正文只定义这条候选路线，早期补丁和评审历史由 Git 保留；§10 记录本次反例复盘，而不是第二份实施规则。

## 3. 最小运行结构与保存协议

### 3.1 Owner、文件与线程

- 正式路径提议为现有 workbench 目录中的 `workbench-history.sqlite`；与 `workbench-history.store` 身份分离，WAL/SHM 由 SQLite 管理。不开新全局数据库，也不修改旧 framed 文件追加新帧。
- Application 创建稳定地址的 Database，Product Control 借用 `sql.Database`；业务 SQL、loader、dirty 和恢复 policy 归 `control/persistence/`。不让 Task/Renderer 持有 connection 或执行任意 SQL。
- 保留现有调用方式：当前同步确认仍同步，审批/恢复已经异步的仍使用原有 worker。worker 接收深拷贝的业务变化和 witness，不再接收全库 bytes，不读 Runtime/Task/Run 指针。
- 普通保存遇到现有 history job/候选屏障时只记 dirty，不等待 worker 占用的连接。只有一个进程内历史写入者；不另建通用调度器。
- 停止接纳 → 收口并 join 使用数据库的 Run/审批/恢复工作 → 消费终态与确认 → 最终保存 → 释放 Product → Storage shutdown/destroy。Database 必须活得比所有借用者长。

### 3.2 待保存集合，不能只信调用方“这次改了什么”

按真实持久单位维护 dirty 标记与修改版本：root、Workspace header、Task header、Run header、Tool/File Change、Compact、审批决定、等待/追加消息；删除保留 tombstone。标记在拥有数据的变更层完成，worker 的原始观察在 Host 接纳为 durable fact 时标记。待保存入口直接登记有身份的单位，不能每次提交遍历全部历史来重新猜测 dirty。

跟踪空间与对象/删除意图一起预留；不能先改数据，随后因申请 dirty 容器失败而漏标。read receipt、流式输出、凭据清洗、失败补写和 TaskBusy 跳过同样登记。历史编号与修改版本分开，不用 Product UI revision 代替。修改版本由对应稳定 owner 的单调序列发号，不能随槽位复用、候选 rollback 或同一 UI request 重新建记录而重置；防止旧批确认把同 identity 的新决定误当成已保存。它是进程内确认版本，不新增持久事件序列。

一次补写先确定本轮待处理的单位和依赖；正文按**当前有限批次**冻结、提交并释放，再处理下一批，不先深拷贝全部积压。原子组是最小不可拆单位，不是必须独占一次 COMMIT 的单位：

1. 一个事务可以包含多个兼容的完整普通 dirty 组，新父记录未落盘时必须连同父链装入。共享 root/Workspace/Task header 不算冲突：同一身份、同一冻结版本只生成一份行变化；若值/版本不同，在 Host 重新冻结该批，不依靠 SQL 最后写入覆盖。只合并、不拆组，事务同时成功或失败；一个 witness 覆盖整个去重后的事务。
2. 根据 A 实测并核定的 statement、参数字节及冻结内存额度尽量合并，达到额度后另起事务。不能为了填满批次拆开 checkpoint/coverage、转入关联或删除；单组已超限则按 §4 解决额度，不能拆碎伪装成功。
3. 必须确认的候选默认保持现有独立确认及其必要依赖，不为合并而等待或夹带无关积压；不把临时 overlay、在途/unknown 候选混进普通补写，不新增多候选调度机制。
4. 每批确认后，仅清除该批实际提交且内存版本未再变化的标记；failed/unknown 不清除。后批失败不撤销前批已经确认的结果，剩余积压保留；不能因另一个 Task 局部提交成功就把保存状态恢复正常。
5. 普通补写一轮覆盖当时全部普通 dirty 组，但一次调用的 COMMIT 数由装箱后的批次数决定，不固定为组数。必须确认的组只以自身及依赖的确认结果交付权限/安装候选，不能谎称整个历史已保存。
6. 删除 Task 的完整组吸收其尚未保存的子记录，不能先删后又从旧 dirty 队列插回。删除确认前 tombstone 与必要 owned 数据保持存活；若父记录从未写入，删除应能确认“最终不存在”，不因 DELETE 为零行而失败或补建父链。
7. SQL 触发的级联/范围更新也必须更新对应版本账目。checkpoint coverage 可用与现有 overlay 完全相同条件的集合 UPDATE，不能把每个旧 Run 编成一条无界 statement 列表。

合并不等于保证同步调用一定够快。A 必须包含 1/10/100 个 dirty Task 的整轮补写，分别由审批在途、写失败后恢复、首次凭据清洗、启动 normalization 形成；记录事务数、实际 I/O、冻结/SQL 各段及连续主线程墙钟和全部排空的尾延迟。先测单组再测合并批次，不能用单次 COMMIT 的均值代替整轮成本；若仍不满足现有 Gate，先评审该具体补写路径的有界执行，再接生产，不退回每组一次同步 COMMIT。

测试在补写完成、dirty 清空后，独立读取 SQL 历史并与内存的完整 canonical 参考状态比较；不能复用 dirty 选择器作为参考。刻意漏标必须让比较失败。每个必须确认的事务另验其整体 before/after，不能等最终全绿掩盖中间不一致。

### 3.3 候选隔离和 unknown

审批模式、模型意图、checkpoint、重绑定、删除等继续使用现有 Prepared/overlay 机制。冻结的是该事务的明确候选；临时 overlay 不加入普通 dirty，不让在途候选进入别的保存。确认成功才安装并结算版本；失败回滚自己的候选，不能撤销别的已接纳修改。

将全文件字节比较替换为一个**仅记录最后一次提交**的 witness（提交身份及摘要）：在 history root 保存 generation 和该次冻结业务变更的摘要，随同一 SQL 事务写入。保存候选时同时保留此前 witness；普通合并批次的摘要覆盖批内所有组，unknown 时整批冻结，不能把同一个事务判成部分成功；不建设通用事务日志或重放表。

SQLite 返回 `outcome_unknown` 时按现有 Storage 规则 poison instance。暂停数据库新写入，保持交互内存事实/dirty 和资源引用；旧 Database 的全部使用者退出并释放借用后，Application 才能关闭/替换 instance，向 owner 注入新 capability；不能销毁后让旧 job 再使用悬空 capability。

重开同一文件、验证 schema 后读回：候选 witness 匹配表示观察到新状态，此前 witness 匹配表示观察到旧状态；不匹配或读不出则保持恢复待处理。**读到新状态还不等于恢复了 durable 确认。** 当前 `FileStore.resolveCommit`（基线 :254–270）在读回后还调用 `syncCommit`，SQLite 接入不能省掉对应责任：在禁写屏障内经 Storage 的 checkpoint/同步确认窄能力，按 WAL/FULL 配置完成可验证的同步，再重新核对 witness，才结算 committed/failed 并解除屏障。复用 §7 已需增加的维护能力，不另建确认日志；A 先核对并隔离验证引擎原语，B 实现窄能力后须故障注入证明屏障有效；不能以 SELECT 成功、close 成功或 `CHECKPOINT_NOOP` 冒充。BUSY/IO/unknown 时保留原候选和 unknown。

禁止重发 Run/权限/原用户命令，也不能用后来内存重新生成一个候选冒充原事务。最后 witness 足够判定的前提是只有一个写入者、unknown 后禁止新写、原候选完整保留，且上述持久确认已完成；它不声称单凭可读字节就证明断电持久性。

读回只确认原事务的存储结果，不统一重装整份冻结 DTO，也不补发 effect。T11 自动审批若已因 unknown 撤回，后来确认写入也不能再交付旧权限；当前人工决定继续按新版本补写。T17 已确认的 binding 按现有 owner 规则接受其 canonical metadata，authority 变更时关闭候选，不回退已确认 epoch。

删除须多保留一个具体 owner 边界：当前 R:3482 把 unknown 回退为 `.failed`，而 R:3356/7976 可以放弃部分失败的删除；旧全量保存还能重写该 Task 全部旧 Run，增量保存不能依赖这个补救。SQL 删除 unknown 期间，删除 owner 保留原候选及该 Task 的未决确认：历史可读，安全关闭仍可进行，禁止新输入、改名、取消归档和重复删除写；无关 Task 的交互内存操作继续。确认删除已提交才释放资源；确认未提交才恢复普通失败/重试/放弃。不能以一次新的 Task header 更新恢复了父行，就误以为被删掉的旧 Run 也已恢复。

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
| history root | 最后一次提交 witness | 判定运行期提交 unknown；导入在临时文件中完成，不在库中增加 copying 标记或来源指纹 |

其余有界 input、commentary offsets、File References、单个 ModelRef 等继续用已有 typed JSON；不改为 EAV，逐项对照当前 `StateWire/restoreTask` 的字段和恢复语义，不把只覆盖旧 schema 的 SQL 往返当完整性证明；不保存 runtime reason、原始 payload、credential 或 live Session。现有迁移 1–8 从未进入生产 history 路径，仅由隔离实验消费。首个生产 schema 采用**一次硬切**：整理并合并为一个新的初始迁移，直接定义实际需要的表与字段；移除被替代的实验迁移输入、废弃 JSON 列/触发器及其 fixture 依赖，不把固定空占位和额外 loader 校验带进生产。不支持从实验 SQL 数据库升级的兼容路径，也不能据此清空遇到的未知文件；正式旧用户数据来源仍只有 framed store。

生产接受身份从首个发布的 schema 开始固定，此后的迁移只追加，既有 checksum/prefix 校验不弱化。实施前再核对 Application/build/release 的实际消费；若发现任何已经承诺保留的 SQL 数据身份，停止硬切并单独评审，不靠“测试库”标签抹掉真实数据。此处只修订未来方案，本次不修改 SQL、迁移校验器或合同真源。

**当前 64 statements / 8 MiB 参数与结果不是已经证明足够的业务上界。** 完整 Run 可涉及 32 个 Tool、256 个 File Change，加上父链、消息与覆盖关系；单条旧合法保留 frame 也可能大于当前 SQL query 预算。不能借用现有限额拒绝本来合法的迁移数据，不能拆开原子事务，也不能改用绕过 authorizer 的 raw SQLite。

最小处理是先为每一种原子组生成最大合法 fixture，计算 statement/参数/最大值及查询结果的真实上界。集合 UPDATE/DELETE 避免随历史总量展开；独立 dirty 组按额度合并成有限批次。仍不够时，只对现有 bounded `mutate/query` 和 engine LENGTH 作有证据的最小额度调整，保留有限数组、单一 COMMIT、authorizer 与 outcome 语义；不开放交互式 transaction handle、callback transaction 或任意 PRAGMA。具体常量由代码和边界测试拥有，不能凭本文先拍一个大数字。额度推导和评审必须在任何用户数据切换之前完成。

## 5. #12/#25 必须连同内存和视图一起解除

### 5.1 容器及预算

- Task、Run、Compact 使用拥有 heap record 的可增长指针集合，避免扩容搬动 worker 持有的 record。只给确有跨阶段引用的对象稳定地址，不为每个 UI 小记录额外建立 owner 层。
- 移除 50/16/16 作为累计历史接纳/恢复限制；UI 历史不再环形覆盖。持久化校验、身份高水位、视图和测试同步修改，不只改 `app.zig` 常量。
- Automatic Workspace 的容量当前由 Task 容量参与分配；Skill 的 Workspace 注册表又沿用这个容量。注册元数据随历史增长，不能在去掉 50 后卡在旧数组；catalog 的真实工作、内容预算和 Session lease 仍独立有界，不为纯历史创建查询或 Session。手动 Workspace 的独立产品限制不借此任意放开。
- 历史结构、已保存正文及其实际 allocation capacity 改计独立历史预算，不挤占原有 1.5 MiB live/catalog 投影计数。worker、原文输入、附件、Session、单字段/单次工具结果和视图缓存继续受各自预算控制。另行计量当前冻结 SQL 批次、参数绑定副本与 SQLite 自有分配的瞬时峰值；历史 256 MiB 候选不是整个进程或导入峰值的保证。
- 首版全历史常驻；历史预算是资源限制，不是“无限”。同一预算要能装回此前已经接纳的历史；启动若资源不足，明确报告恢复受限并保留原库，不能覆写或将空内存伪装成 ready。以 256 MiB 作为待验证候选，最低规模要求为 100 Task × 256 Run、每 Run 约 4 KiB 正文并含审批和 metadata。必须先测精简结构的常驻和峰值；若候选不能覆盖验收规模，实施前调整并说明，不偷偷增加淘汰/缓存系统，也不把失败当通过。
- 历史预算不足在接纳前拒绝并保留输入；为已接纳 Run 的终态、拒绝权限、取消及必要恢复预留控制空间。审批决定及其 dirty 元数据的空间在请求对用户发布前预留；无法预留的新请求在发布前安全拒绝/取消，并使用已预留终态记录资源失败，不能到用户点“拒绝”才申请历史空间。流式输出超预算按既有有界投影语义处理，不能出现执行完了却无法记录安全终态。磁盘满保留 dirty 和明确保存失败，不删历史。历史配额是跨 Task 的全局资源预算，拒绝仅影响新接纳，不把数据库误报为损坏，不撤销已接纳的执行；历史读取、取消、安全拒绝及既有删除路径仍可用。UI 精确区分历史配额、Session 名额和保存失败，不都伪装成槽位满。归档不释放历史字节，不能误导用户“归档即可腾空间”。

### 5.2 有界读取

Run 正文与 Unicode Host 搜索复用上一分支。需要补齐的只是随着计数放开而失去上界的 Task 导航、Run manifest、Compact 和审批列表：沿既有 typed scope/cursor 分页，使用稳定 identity 与已有历史/安全版本规则，不建设新分页框架。

审批/Compact 在面板里继续可追溯到所属 Run，不能只返回最近几条冒充完整历史。每个块分别绑定 item/编码字节上界，Renderer 把未返回当作未载入，不当作删除；`worstCaseSnapshotBytes` 不再靠累计 Task/Run 数或共享正文总量证明安全。相关 Bridge shape 改动集中在这一项，其他产品流程不改。

SQL loader 在启动门禁内 keyset 分页读取，row 先构建 provisional candidate，仅 query terminal 为 ok 才采纳；预算失败释放候选后缩小只读批次，不能接纳一半结果。单条合法 row 也必须落在已推导的最大值内。loader 期间禁止业务写入/其他借用者，最后完整校验再发布，所以跨查询观察一致，不需要增加读连接或交互式读事务。

## 6. 临时库导入、发布与应用内恢复

正式文件保持 `workbench-history.sqlite`，旧格式保持 `workbench-history.store`；不混装，也不靠改旧文件帧来阻止降级。Application 只执行已授权的文件/Database 生命周期 effect；初始化、迁移、健康和恢复资格仍由 Product 决定。

### 6.1 临时库是唯一导入候选，正式文件发布是唯一提交点

1. Application 已取得 canonical data root 的 Primary lease 后，先观察正式 SQL、旧 canonical 和现有恢复证据。若正式 SQL 已存在，先按正式历史观察，不能当作可随手丢弃的导入残留。
2. 没有正式 SQL 时，在同目录、本程序独占且可识别的私有临时路径创建导入库。新库和后续空库初始化使用相同流程，不增加库内 copying 标记、持久来源指纹、逐记录进度或断点续传。
3. 读取当前旧来源，分有限事务导入；保留合法事实、可识别的 read-only/retained payload、高水位及 artifact 引用，按当前规则 normalization。完整 loader 读回、业务/引用/安全校验和 root 初始化成功，才允许准备发布；初始化 witness 绑定完整已校验候选的业务摘要，不只是最后一批的计数。分批 COMMIT 只使临时库中的数据完整，不授予产品权威，也不发放正式数据库 capability。
4. 发布前确认来源仍是本次导入的观察；变化则放弃未发布导入，重新读取当前来源，不把它升级成永久迁移错误。该检查只需本次 owned 观察，不写进数据库；持续变化时返回应用内重试，不无限循环。
5. 在临时库完成并验证 WAL TRUNCATE checkpoint，所有使用者退出、Database shutdown/destroy 完成。确认必要内容已经在主文件、没有待应用的 WAL，才通过同目录发布 effect 将**已关闭的临时主文件** rename 为正式文件并执行现有平台要求的 durable sync。不能 rename 使用中的 SQLite、带未结算 WAL 发布主文件，或把旧 sidecar 拼给新库。[SQLite 文件与 journal 配对约束](https://sqlite.org/howtocorrupt.html)
6. 正式目标原应不存在；发布前复查，出现赢家则重观察，禁止覆盖。只有发布被确认 committed，随后重开并验证正式库，才交出 runtime capability。WAL/关闭/发布 effect 的跨平台正确性由 A/B 验证；不为通过而新增未经架构接受的低层调用。
7. 发布结果 unknown 时先重观察正式目标：验证为原候选后，还须在全部 SQLite 借用退出/连接关闭的条件下完成 Application 的文件名/目录 durable sync 确认，再重开校验，才能确认成功；仅能读到目标不够。明确未发布才能重做；不能判定就保留候选和原件，通过应用内重试继续观察，不清空待定文件或重放用户命令。若发生进程退出，下次启动以是否有完整可信的正式库分流，不能只因有文件就视为 ready。

**未发布的普通导入可以直接丢掉重来，不要求旧来源未变。** 下次启动若正式库不存在，就在确认无活跃 owner 后清理本程序识别的普通导入临时库及其 sidecar，再按当前来源重新导入。临时路径、数据目录归属和临时文件用途须能确认，清理失败则应用内重试，不能删除不明文件。显式恢复过程中保留的候选和 quarantine 属于恢复证据，不按普通导入缓存自动清理。

### 6.2 每一种停止观察都有应用内动作

| 当前观察 | 默认行为 | 应用内恢复/重试 |
| --- | --- | --- |
| 正式 SQL 完整有效 | loader 验证后以它为唯一历史权威 | 正常使用；旁边后来出现的 `.store` 不自动合并或覆盖它 |
| 正式 SQL 不存在，旧 canonical 合法 | 自动按 §6.1 导入，直到发布前不改变原文件 | 临时 IO/发布失败提供重试；旧来源改变时按当前来源重做，不要求用户删临时文件 |
| 正式 SQL、旧 canonical 和恢复证据都不存在 | 以同一临时库流程初始化当前空历史 | 初始化失败保留 typed health，应用内重试；没有发布就不宣称保存可用 |
| 正式 SQL 不存在，旧 `.store` 可读但无法识别/解码，或仅有既有 quarantine/未完成恢复证据 | 不自动清空；从当前可用的内存事实运行，显示 history 诊断，不冻结所有交互 | **开放既有 `recoverTaskHistory` 显式入口**，校验 revision 后按 §6.3 保全原件并发布当前内存历史；初始内存为空时即初始化空 SQL，不要求手动删文件 |
| 正式 SQL 不存在，只有本程序普通导入临时库 | 它从未发布，不作为历史真相 | 清理后从当前旧来源重做；来源变更不阻止重做；若当前来源也不能分类，转上一行的显式恢复 |
| 正式 SQL 的 schema 过新（`VersionUnknown`） | 当前版本无法解释，不等于数据损坏；保留正式库及 sidecar，不退回 `.store` 或把空内存当可信历史 | 只提示使用支持该 schema 的新版本；本进程不持久化历史，不迁移、quarantine 或替换正式库；不开放显式恢复，直接调用恢复命令也须拒绝 |
| 正式 SQL 被本版本判定为不可信：格式损坏、缺 root、迁移身份/校验不匹配（`MigrationMismatch`）或数据损坏 | 分别发布观察，保留原件；可信局部数据仍按现有隔离规则保留，不把它当首次启动或偷偷退回 `.store` | 没有进程内待定确认屏障时，允许用户通过既有显式恢复，将当前可信内存历史发布为新 SQL，原 SQL/sidecar 保全到 quarantine；不能把 `VersionUnknown` 归入本行 |
| 路径/权限/磁盘/文件读取等物理 IO 失败 | 不假定为空，不回滚当前有效内存事实，不伪造保存正常 | 应用内重试打开/保存；可以可靠执行保全 effect 时允许显式恢复，否则明确报告失败，空间/权限可用后重试 |
| runtime commit 或恢复发布 outcome unknown | 保留原候选及资源，阻止新的数据库写入 | 入口优先做原 witness/目标读回及同步，不得直接 quarantine 进程内待确认事务或另建空库；确认结果后才继续补写或恢复。读不出时提示重试；按既有 shutdown 收敛并重启后，再由正式文件观察进入对应显式恢复分支，不能伪称已确认，也不要求删证据 |

“普通保存不可用”和“恢复 effect 不可用”必须分开。即使正式 Database 尚未能打开，Application 仍可提供受限的临时库、保全和发布 effect，让 Product 发布符合上表资格的恢复动作；不能仅因为没有 `sql.Database` 就把合法恢复入口一并关掉。`VersionUnknown` 的禁写资格同时约束普通保存、退出补写、凭据维护和恢复 effect，不能通过另一个入口替换正式库。真正无法执行文件 effect 时给出可重试的物理失败，不承诺绕过权限。

### 6.3 复用现有显式恢复语义，不要求用户操作文件

沿用 `recoverTaskHistory(expected_revision)` 的用户动作、revision 检查和 typed 结果，以及 [FileStore.recover](../../src/product/task/persistence.zig) 当前“先准备 replacement，再 quarantine 原件，再 durable publish”的保全顺序。先按 §6.2 校验恢复资格；`VersionUnknown` 即使用户点击恢复也拒绝，不准备 replacement、不移动原件。复用的是入口与语义，不能把 SQLite bytes 原样交给旧 framed `FileStore.recover`，也不为过渡先生成一个新的旧格式 canonical。

- 先处理原 unknown：优先读回原 witness，不得把未确认事务当损坏重置。可进行显式恢复时，冻结**点击恢复时的可信内存状态**；若用户已经在保存不可用期间创建了有效 Task，恢复须保存这些事实，不能一律清空。
- 当前内存为空才形成空 SQL；在独立的恢复候选临时库中构建、完整校验、结算 WAL 并关闭。准备失败时不移动原件。
- 发布前停止并收敛正式库全部借用者。旧 `.store` 或正式 DB 的现存组件按授权移入唯一 quarantine；SQL 以 DB/WAL/SHM 的完整现存集合保全，不只 rename 主文件，更不能删除可能仍需要的 WAL。已有隔离证据不覆盖、不自动清理，也不猜测性地拼回主库。
- 保全途中断/失败不删除任何旧证据：明确能恢复原位置时按现有语义恢复；否则保持可诊断的恢复待处理，并允许用户从同一入口重试。canonical 缺失且有恢复证据绝不是首次启动；再次恢复可保全仍在原位置的组件，不能要求用户手工删文件。
- 确认正式路径不存在旧 sidecar 后，以与 §6.1 相同的关闭候选发布规则安装 replacement。只有发布及同步被确认 committed 且重开验证成功才恢复 ready；failed 保留原件与内存，unknown 保留精确候选，按 §6.1 读回和同步目标，不自动再发恢复意图。跨多文件的隔离过程不冒充一个原子 rename，唯一新权威切换仍是已关闭 replacement 的发布。

### 6.4 旧版本、normalization 和 artifact

普通导入发布前旧文件保持原样；成功后它只是受管迁移证据，不再是 active authority，也不是永久未脱敏备份。凭据维护覆盖它；确认全部事实导入后才允许受控退休，未分类的 quarantine 不自动删除。仅消费 framed store 的旧构建看不到新历史，但不能覆盖新 SQL；已接入 SQLite 的旧构建遇到较新 schema 时，必须按 §6.2 禁写，不能借显式恢复把新库移入 quarantine。新版本返回仍读可信正式 SQL，不承诺合并降级期间的旧历史。

正常启动 normalization 继续保存 pending→excluded、interrupted、未完成 File Change 的 incomplete 与消息降级，再取得后续恢复/清理所需的确认，不重放模型输入。checkpoint、附件和 artifact 目录/身份保持；只有完整可信历史及引用集合成立才清理 orphan，unknown、degraded 或未分类证据仍在时禁止冒险清理。

## 7. 凭据与 WAL：只补必要的安全能力

继续在写入前按全部当前已知凭据检查**所有字符串/JSON/BLOB 业务内容**，不只检查 SQL 文本。实际被清洗的单位进 dirty；候选冻结后新获知凭据时，关闭新的历史写入入口，等在途写入明确收敛，再完成当前状态清洗，不提前报告安全完成。

普通 bearer 借用/释放不触发全库重写。首次未知→已知按 owner 安装前的观察判断；扫描包括已载入内容以外的保留 payload、迁移材料及历史存储。不能凭内存没命中或裸字节扫描没命中，证明 SQLite 旧页和 WAL 不含残留。启动时，所有当前已知凭据也必须参与这次进程的初始存储校验；不能因 Account owner 已先持有该值就跳过历史检查。

首版提议：从新数据库第一次写入前启用并回读 `secure_delete=ON`；Product 完成匹配行的安全更新后，由 Storage 的窄维护能力完成并验证 WAL TRUNCATE checkpoint，确保退役页版本不继续由受管 WAL 保留。首次获知没有当前匹配时仍需结算可能的旧 WAL；这是必要的 WAL 清理，不是整库重写。普通重复借用/释放不做这一项。不使用虚拟表/FTS，避免其额外保留边界。

这两项是**当前 backend 尚无的窄增量**，先作为接入前验证项，不宣称已满足：公开 SQL 仍不能执行任意 PRAGMA/VACUUM；只加固定 profile 和可验证的维护结果，具体 C API 留在 Storage。这项固定 WAL 维护/同步屏障同时承担 §3.3 的提交读回持久确认；两种调用仍分别由保存 owner 和安全 owner 判定，不新增两个维护框架。BUSY/IO/unknown 不当作清理成功；保留该次必要 credential lease，阻止把未清理的候选作为安全保存结果。对不可理解且无法安全改写的 retained payload 明确报维护未完成，不丢数据或伪造无命中。迁移原件/受管临时文件必须同样清理，不能 SQL 干净而旁边原文件仍含凭据。

安全任务必须能取得现有有界 owned credential lease 和预留登记空间；no-fail 获知/释放回调只登记/清洗，不新增可能失败的临时分配或无限 secret 缓存。若现有 owner 无法保证这项生命周期，A/B 的安全验证不能通过，不能先接生产再补。

这里的保证限于应用受管文件与既有文件删除/替换边界，不声称擦除外部备份、OS/swap 或 SSD 的取证残留。安全路径若不能在现有单连接 owner 下证明成立，停在用户数据切换之前；不临时造影子数据库/根索引系统。

依据：[secure_delete](https://sqlite.org/pragma.html#pragma_secure_delete) 对普通表更新/删除的擦除及虚拟表限制；[TRUNCATE checkpoint](https://sqlite.org/c3ref/wal_checkpoint_v2.html) 成功时截断 WAL。逻辑行更新不等于旧版本清理。

## 8. 最小实施顺序与停止条件

| 步骤 | 交付与边界 | 进入下一步前必须成立 |
| --- | --- | --- |
| A 核实单元与额度 | 本盘点落到测试 fixture；测 post-refactor 历史内存、最大合法 SQL 原子组/值/查询；已有单连接同步提交与 WAL 维护的 Windows 成本、1/10/100 个 dirty Task 合并补写的整轮尾延迟、engine 链接体积估计 | 识别并约束成本/安全风险，提出额度候选和测量边界。只做窄 probe，不实现完整 writer、不接触用户数据 |
| B 最小 SQL 往返 | 在隔离目录复用 backend，整理首个生产 schema，补必要累计表、witness、loader、关闭临时库发布及显式恢复；不改生产 Application | 新旧事实完整对照、unknown 读回及同步失败、迁移/恢复中断、来源变更重做、应用内恢复、opaque 保全、artifact 引用和安全清理全部通过 |
| C 接上真实持久化路径 | 一次性替换 bytes capability 为 history-specific 变化与冻结候选；dirty/确认协议接入 T01–T23；Application 生命周期切换 | 普通及必须确认路径工作，真实 SQL 批次/维护成本复核；原有 worker 不重做；移除旧 production writer，不双写或静默 fallback |
| D 解开累计容量 | 稳定的可增长 Task/Run/Compact、审批保留、自动 Workspace/Skill 注册元数据、独立历史预算；补导航/manifest/Compact/UI 分页 | 16/50/8/16 不再作为历史名额，实际 Runtime 容量与内存/峰值复核通过；所有视图有界；真实小 Session 预算下不丢历史/重复执行 |
| E 发布前验收 | 正式 Native/Bridge/Renderer、canonical Core、迁移/故障/容量及实际 SQLite I/O 测量；同步实际变化的唯一真源 | 下节完整通过才可关闭 #12/#25；每个可工作的 DAG 子任务完成后评估独立提交 |

不将 C 里的同步调用方全部改成异步状态机。同步 API 不保证主线程一定够快：现有 WAL/FULL 会同步存储，自动 checkpoint 也可能发生在触发提交的线程。A 必须量到这些尾部延迟，不能只看均值或放宽 durability。只有某个实际路径不满足既有执行/展示门槛时，才单独复用已有 executor 并评审该路径的交接；不能在实现途中悄悄扩大为全局异步框架。[SQLite WAL 性能说明](https://sqlite.org/wal.html#performance_considerations)

A 只做能改变决策的最小隔离测量：现有精简记录/实际附属数量的内存样本、目标原子组的额度推导、代表性同步/维护/合批 SQL 成本和 engine 链接体积估计。它不是尚未实现的 B/C/D 的最终证据，不要求先偷偷实现整套产品才能获得测量。A 发现方案不可行就先修订；不能把结构估算、模拟 workload 或引擎小程序称作真实产品验收。

B/C 以最终 schema/SQL builder 复核原子组额度、读回同步、安全维护和真实提交成本；D 以稳定增长容器、真实 Runtime 和 startup loader 复核内存/峰值；E 才记录实际生产构建的包体积及全部容量、平台和性能结论。所有这些实现与测量先在隔离目录/profile 验证，用户数据切换必须等对应门槛闭合。本文不授权执行 A，也没有任何新实测通过的声明。

## 9. 最小完整验收

1. **#12**：同一 Task 至少 256 个 Run，保留最旧/中间/最新的输入、正文、工具、审批和关联；正常退出/强杀重启后完整，重启后还可继续；Compact 连续超过 16 次，审批超过 8 次不覆盖。
2. **#25**：累计至少 100 个 Task，含超过 50 个已归档 Task，再创建/继续新 Task；同时覆盖共享手动 Workspace 与默认 Automatic Workspace。真实 live Session 设 2，验证压力关闭、关闭失败、显式重试及 checkpoint/Skill/MCP/Permission 连续性，不扩大 Session 数。
3. **跨 Task 容量**：100 × 256 的合法合成历史，正文累计显著超过 1.5 MiB、持久数据超过 16 MiB；实际内存/峰值落在 A 的预算内，能运行、保存、重启、搜索、翻页和读取最旧审批/Compact。大规模 codec/storage 场景不要求进行 25,600 次真实模型请求；真实 Core 另覆盖跨 16/50 门槛的生命周期。
4. **原子性逐项命中**：T11–T19 每条确认路径注入提交前失败、COMMIT unknown、返回后崩溃和读回失败；checkpoint 在途叠加普通保存后失败，重启仍能恢复；coverage/reference、审批/profile 和跨 Run 转入关系不出现一半。增加“新 witness 可读，但后续同步屏障失败”：仍须保留 unknown，不交付权限、不释放受保护文件；同步并复核成功后才确认。自动审批 unknown 后用户人工拒绝，旧确认不得补发许可或覆盖新决定；删除 unknown 后尝试取消归档/发送/改名须被该 Task 的确认屏障拒绝，读回后原历史或删除结果保持一致。
5. **补写**：分别制造 TaskBusy、写失败、仅改已读状态；只触发一次无关 Task 的正常 durable boundary，待补写完成后正常退出和强杀重启。故意漏标触发独立完整对照失败；版本已变化不能被旧 worker 清掉；同一 request 的候选 rollback 后重建也不能复用确认版本；两个 Task/多个事件共享同一 root/父 header 时只写一次且不丢事实。创建写入失败后删除该 Task，不补建它，不重插 dirty 子项。
6. **接纳与外部 effect**：自动审批确认失败/unknown 不交付权限；人工响应沿原语义；Schedule 候选未知保留目录且不重放；Task 删除未确认不删 blob/附件/artifact；no-fail 终态、拒绝权限和取消的控制空间始终可用。
7. **迁移/恢复**：普通导入发布前旧文件不变；每个临时库导入批次、checkpoint、关闭、rename/sync 与 quarantine 中间点强杀。完整复现“导入中崩溃 → 旧 release 改写 `.store` → 新版重启”：未发布导入自动按最新来源重做，不永久报来源变更。可读但无法分类的旧 store、仅有 quarantine、正式 SQL 缺 root/校验不匹配/损坏、IO 失败分别在应用内重试或合法显式恢复，均不要求手动删文件；恢复保存当前有效内存事实，准备失败不移动原件，unknown 不重放。另测 SQL schema N+1 → release N → N+1：旧 release 报 `VersionUnknown` 并提示使用新版本，普通保存、退出补写和直接调用恢复命令都不能发布 replacement 或移动正式库及 sidecar 到 quarantine；返回新版后原历史完整，不需手动恢复文件。旧构建使用旧文件后已发布 SQL 不被覆盖或重复导入；不只测试小历史往返。
8. **凭据**：新建后未知值写入、改写后仅留旧 WAL、长文本跨页/JSON 转义/多个字段、retained payload 和迁移源分别命中；可安全改写的正例在首次获知后受管文件不残留该已知值，无法理解/安全改写的 retained payload 必须明确保持维护未完成，不能通过丢弃它来通过测试。清理失败保持未完成。连续 64 个图像 Run 的重复借用/释放不新增全库扫描、WAL 安全清理或重写；测试与日志不记录凭据原文。
9. **性能与体积**：实际测每次必须确认的提交 P50/P99/最大值、10 次审批的整轮附加等待、启动/重放时间、常驻和峰值内存、DB/WAL 维护及单位 Run/持续负载的实际 I/O。另测 1/10/100 个 dirty Task 的整轮排空尾延迟及连续主线程停顿，分别覆盖审批期间积压、磁盘满/写失败恢复、首次凭据清洗与启动 normalization；报告完整组合并前后的 COMMIT 数、批次额度、准备与 SQL 耗时和实际 I/O，不按组数固定做 N 次 COMMIT。注明 logical 参数量、进程 I/O 与物理写入的口径，不把预设事件数乘文件大小冒充实测，不为采样造产品 VFS。生产 SQLite 编译增量按相同构建配置实测。既有 Debug 32.9481 ms、Release 16.8729 ms 的视图失败保留，SQLite 不自动解决；新增持久化及原视图成本分开归因，既有 Gate 不放宽。峰值须包含一个最大冻结批次与 SQLite 参数/页缓存分配，不用只统计安全正文的数字冒充进程总量。

## 10. 四轮复盘与“为什么”

本次使用四组不同轨迹复盘；发现的缺口已整合进正文与验收，不把同一遍文字反复读四次当成验证。下面记录的是设计推理及其反例，不是运行测试已通过。

| 轮次 | 追问 | 反例/结论及落点 |
| --- | --- | --- |
| 一：提交正确性 | 为什么业务原子组不必独占一个 COMMIT？ | 审批阻塞/磁盘满后 100 个 dirty Task 若各自同步提交，会放大 sync 次数；完整组合批，共享父 header 去重，witness 覆盖整批，见 §3.2 |
| 一：提交正确性 | 为什么有 dirty 集合还需要 owner 单调版本和独立全量对照？ | 旧 worker 确认、UI 候选 rollback 后同 identity 重建会出现 ABA；漏标又不会自己进入集合。版本不能复用，漏标反向用例必须能失败，见 §3.2/§9 |
| 一：提交正确性 | 为什么读回 witness 匹配还不能交付权限？ | 读到文件缓存中的新状态并不补上原失败的同步；旧 FileStore 还有 syncCommit。新增窄持久确认屏障，失败继续 unknown，见 §3.3 |
| 二：生命周期/恢复 | 为什么不把所有 unknown 都统一 complete 或 rollback？ | 自动审批不能晚到补发权限，已确认 binding 又不能倒退 epoch。仍由各自 owner 收敛，见 §3.3 和附录 T11/T17 |
| 二：生命周期/恢复 | 为什么删除 unknown 不能立刻变成可放弃的普通失败？ | SQL 可能已经删掉全部旧 Run；若马上取消归档再发消息，仅补写新 header/Run 会遗漏旧历史。该 Task 保留确认屏障，其他 Task 不冻结，见 §3.3 |
| 二：生命周期/恢复 | 为什么临时库 rename 前后还要结算 WAL、关闭和同步？ | 热 WAL 或未关闭 connection 不能当成独立文件移动；rename 可见也不自动等于发布持久。全部借用退出后发布，unknown 先读回并同步，见 §6 |
| 三：容量/性能 | 为什么 256 MiB 不能直接当进程峰值承诺？ | 全部积压深拷贝、SQLite 绑定副本和页缓存会叠加；只冻结当前有限批次，最终 Runtime/loader 复核，而不是只量正文，见 §3.2/§5/§8 |
| 三：容量/性能 | 为什么用户点拒绝前就要预留审批记录？ | 满额后才分配会让安全拒绝或终态失去历史空间；新请求发布前预留，预留失败在发布前安全收敛，见 §5.1 |
| 三：容量/性能 | 为什么 A 不能宣布实际容量和包体积已达标？ | A 还没有 B/C/D 的最终 SQL builder、增长容器和生产链接；隔离估算标清范围，后续阶段必须复核，见 §8 |
| 四：范围/复杂度 | 为什么先保留全历史内存，而不一起做按需加载？ | 已有精简记录、Session 回收、有界视图和搜索可复用；先用内存实测否证该选择，不预建另一套缓存/一致性系统，见 §1/§5 |
| 四：范围/复杂度 | 为什么不保留实验迁移 1–8 的空列和兼容代码？ | 它们未进入生产持久化，固定空占位没有用户数据职责；首发 schema 干净硬切，发布后才冻结，checksum 不弱化，见 §4 |
| 四：范围/复杂度 | 为什么导入中断后不按来源指纹续传？ | 旧 release 可能在中间改写 `.store`；未发布临时库可重做，正式 SQL 不回退，不增加进度状态机，见 §6 |

复盘后仍需实测/验证：256 MiB 候选与实际峰值、最大合法 SQL 原子组和值、合批尾延迟、持久确认/凭据清理屏障、有界 credential lease、跨平台关闭文件发布和最终包体积。设计理由不能替代这些证据；失败则回到对应选择，不能靠放宽 Gate 或展开通用框架绕过。

本次交付仅为整合后的方案和静态反例复盘。没有执行 A、修改产品/SQL/测试实现或规范真源，没有迁移、建库、性能新实测及旧文件替换。下一步仍需明确实施范围，不能据本稿把 #12/#25 或既有性能待办标为完成。

## 附录 A：事务边界与源码依据

下表区分三类确认方式：

- **尽力保存**：内存接纳是当前进程事实；磁盘失败/TaskBusy 不撤回已接纳操作，待后续补写。准备、身份校验或不可恢复编码错误与 I/O 失败不同，仍可在发布/执行前拒绝。
- **必须确认**：只有存储确认提交，才安装候选、交付权限或释放资源；明确失败回滚候选，结果未知保留原候选及相关资源，按该业务原有规则收敛。
- **外部两阶段**：文件或 Agent effect 与历史数据库不是同一个事务；保留现有先后次序，不能用 SQL 事务伪造跨文件原子性。

表中的“共同保存”是最小业务一致性闭包，不代表每次重写列出的全部对象。没有变化的历史正文不进入提交。源码列指出当前入口；确认语义默认沿用当前 owner，增量接入必要的新约束已在正文说明，T19 的 unknown 屏障也在表内明确标注。

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
| T19 物理删除 Task | Task 及全部子记录删除；Automatic Workspace 的删除；保留不复用的高水位 | **必须确认**后释放历史/删除 checkpoint、附件、artifact。明确失败恢复普通失败；unknown 恢复内存但保留该 Task 的未决删除确认屏障（§3.3），保留全部文件 | R: `syncDeletions`，3482；C: `commitTaskRuntimeWithoutTask`，8971 |
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

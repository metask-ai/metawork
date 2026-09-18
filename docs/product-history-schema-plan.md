# Product 任务历史 Schema 实施方案

状态：用户已于 2026-09-18 授权按最终方案实施。制定日期：2026-09-18。本文件是阶段实施计划，不替代现行架构合同；授权范围包括本方案明确的窄合同依赖与对应门禁调整，不包括生产数据迁移或恢复策略变更。

## 1. 目标、范围与当前基线

本阶段交付 Product Control 所属的无状态 schema 模块、首版任务历史数据库结构及真实 Storage 验证。首批数据范围为 Workspace、Task、Run 与它们已经拥有的持久化历史。用户看到的会话继续对应 Task，不增加 Session 产品对象或顶层 owner。

本阶段不启用生产数据库，不改变 Renderer/Bridge，不切换现有 history FileStore，不读写用户数据库，不迁移或删除旧文件，不增加 ORM、通用事务框架、动态 schema registry 或后台数据库服务。Application 开库、业务 SQL adapter、旧数据处理与产品恢复是后续独立接入阶段；本方案明确其前置要求，不能以 schema 验证通过代替这些工作完成。

### 1.1 基线与实施前的内容核对

- 制定时业务基线为 main，HEAD e9856f036f845875d0e292255cfebddb794421af；字段清单包含该版本的合法持久事实。
- 本次复盘开始时工作区已在 feat/storage-foundation，HEAD 6c62e3a31de3b4b7ac5ce49fce1cfc3ea7b7da14，仅本计划未跟踪；本轮没有切换分支。该提交包含已评审通过的 Storage 修复，但不包含上述 main 后续新增的全部业务字段。
- Storage 修复解决实际查询列数、ALTER 参数解释和 NOMEM/TOOBIG/FULL 分类，保留既定 temp/PRAGMA/metadata 限制。实施前按内容确认目标同时包含这组修复与业务基线的新增字段；已具备的内容不重复合入。需要整合时保留两边有效变更，不能直接覆盖整份新文件。
- 旧验证只证明旧提交。纳入并完成合同模块拆分后，必须按最终组合运行相应验证。
- 业务基线的 RunWire 包含 submitted_at_unix_ms，必须与 finished_at_unix_ms 一并覆盖；不能因当前 Storage 分支较旧而删掉该字段。两者为独立、可空的历史事实，不能互相推导。

TinyKG 依据：已完成实施 task 2840、验证 2847/2848、逐 DAG 子任务评估提交的用户反馈 2841。本次规划 task 2849 只负责方案交付，不表示实施开始。

### 1.2 完成后的准确表述

可声明：Product schema 能通过纯 SQL 合同定义完整的首版历史结构；真实 Storage 可以创建、验证和重新打开隔离测试库；业务字段的数据库表达和后续接入约束已明确。

不能声明：现有会话已存入 SQLite、旧数据已迁入、生产恢复已可用、所有容量场景已具备单批原子保存能力，或 macOS 原生运行已由交叉编译证明。

## 2. 明确的架构决策

### 2.1 允许的依赖

本方案明确提出开放 Product Control 所属 schema 窄模块对 Storage SQL contract 的依赖。这是对“Storage 尚无正式消费者”阶段门禁的显式调整，Product 依赖 Storage 的方向本身保持不变。

```text
Product schema ────────> Storage SQL contract
Storage backend ───────> 同一个 Storage SQL contract
Storage backend ───────> 固定 SQLite 实现

Application ──────────> Product schema + Storage backend
                         仅在后续生产接入阶段新增
```

本阶段不向 Product Control Runtime、业务 aggregate、Bridge 或 Application 批量注入完整 Storage backend。schema 作为具名窄模块进入构建和测试即可，不为使模块“有消费者”而改写生产初始化。

### 2.2 合同模块的唯一身份

以现有 src/storage/sql.zig 为根建立具名合同模块，建议导入名 metawork_storage_sql；schema 模块建议具名 product_control_history_schema。

Storage root、SQLite backend、内部 migration/connection、conformance 与 schema 均消费同一合同 module 实例。清理原有对同一 sql.zig 的内部相对导入，避免同时以两种模块身份定义 Migration、Database 等类型。保留 src/storage.zig 已公开的 sql、sqlite 导出形状，通过转出唯一合同模块保持 public API；不复制类型，不创建兼容实现。

合同模块本身不链接 SQLite、不依赖 Product、Application、Agent 或 Native SDK。backend 的 C 源码、编译参数与官方固定依赖继续由现有构建入口拥有。

### 2.3 同步调整的四处

| 位置                                     | 本阶段修改                                                                                |
| ---------------------------------------- | ----------------------------------------------------------------------------------------- |
| build.zig                                | 建立唯一 SQL contract 与 schema module，接入正式 Native test graph；SQLite 仍只归 backend |
| docs/architecture.md §3.6                | 明确 schema 已获准消费合同；仍准确说明生产数据库尚未接入                                  |
| docs/project-structure.md                | 明确 schema 归 Product Control、具名窄模块消费者和依赖方向                                |
| scripts/architecture-boundaries.test.mjs | 将阶段性全面禁止改为精确消费者检查，保留 SQLite 与业务的长期隔离                          |

边界测试同时检查实际 module root、导入消费者和 C 链接归属，不能只通过换 import 别名避开原正则。保留 Storage 不反向依赖业务、SQL contract 不含 SQLite、非 backend 不直接使用 SQLite C 接口的断言。

若 Storage 架构的生命周期 API 或基础限制没有变化，不为新增业务重复改写其机制合同。Product 侧新增的数据库结构与未来兼容语义由 Product 架构唯一承载，其他文档链接它。

## 3. Schema 模块封装

拟议文件：

```text
src/product/control/persistence/
  schema.zig
  migrations/
    0001_task_history.sql
```

只创建有真实内容的文件；不创建预留目录、空迁移或占位 Runtime。

schema.zig 的核心公开产物只有静态 migrations: []const sql.Migration。版本从 1 连续递增，清单显式列出 version、name 和 @embedFile 的 SQL。当前目标版本从清单推导，确有消费者时才提供派生访问，不维护第二份手写版本号。

模块无连接、allocator、运行状态、health、开库或恢复方法。Application 未来将清单传给 Database.create；schema 不再次封装 apply/createTables。

新库和升级共用同一份迁移链，不并行维护“最新建表脚本”和另一套升级 SQL。第一条迁移不插入业务运行状态；建立空表后，业务 bootstrap 数据由未来持久化 owner 的普通原子写入产生。

schema version 只表示结构版本，不表示业务已初始化。未来 loader 必须区分“所有业务表为空、尚待 bootstrap”和“已有业务行但缺少 history_state”的不完整状态；后者不得当作新库自动补默认值。ready 需要有效的 history_state 与完整 aggregate 校验，不能只看 Database.create 成功。

### 3.1 清单与字节约束

- 编译期调用 sql.validMigrations，拒绝断号、空名称、空 SQL、NUL 和超限。
- 编译期检查每条 SQL 不含 CR，SQL 文件采用 UTF-8、LF、无 BOM，并检查有效 UTF-8。
- .gitattributes 只针对本迁移目录固定 text eol=lf，避免无关 SQL 文件整仓重写。
- 对较大的嵌入 SQL，显式给纯校验配置足够且有界的 comptime evaluation quota；不因默认分支配额不足删除校验。
- 这些检查不解析 SQLite 语法，也不能防止历史 SQL 多出一个 LF。已作为需保留数据库身份的历史迁移保持字节不变；合法性、格式和历史不变性分别验收。
- 未发布且从未成为需保留数据身份的草案可以在评审中调整；不能把内部实现 hard-cut 自动解释为允许改写已落盘身份。需要重置既有数据时必须另有明确恢复/迁移决策。
- v1 DDL 使用现有生产 authorizer 支持的建表与索引。采用普通表并显式声明必要类型约束；不依赖 STRICT 表后续 ADD COLUMN 的可用性。DROP COLUMN、RENAME、内部 PRAGMA 引发的能力缺口继续有效，不通过 schema 绕过。

## 4. 数据表达规则

以下 U64、Bool 等只是文档简写，不实现自定义 schema DSL 或生成器。

### 4.1 数值、文本和可空语义

| 类别                                         | 数据库表达                             | 原因与约束                                                                                                   |
| -------------------------------------------- | -------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| 完整 u64 身份、epoch、generation、顺序、计数 | 固定 8 字节 big-endian BLOB            | Storage 整数为 i64；这种表示不截断高位。DDL 检查 typeof 为 blob、长度为 8；要求非零的字段额外拒绝全零        |
| 布尔值                                       | INTEGER，非空，检查存储类型与 0/1 范围 | 约束落盘值；绑定前仍由 mapper 检查输入类型，不能声称 affinity 转换前的类型也被 DDL 拒绝                      |
| 有界数组 ordinal、u32 位置/数量              | INTEGER，显式非负或正值与上界          | 不复用业务 ID；ordinal 只恢复既有数组顺序                                                                    |
| 提交/完成时间                                | nullable INTEGER                       | 当前合法 wall-clock 值处于 i64 范围；正值和现有时间上界在保存/加载校验中验证，null 原样保留                  |
| 自由字符串、字符串身份、路径、模型名         | 原始 UTF-8 字节 BLOB                   | 保留现有 codec 接受的嵌入 NUL；读写两端按 Product 规则校验 UTF-8、字节长度和领域语义                         |
| 有限 enum/tag                                | TEXT，按现有取值集合检查               | 已有合法值均不含 NUL；不把任意用户字符串当 enum                                                              |
| SHA-256 digest                               | 固定 32 字节 BLOB                      | 当前 wire 的 64 字符小写 hex 解码后存入，读回恢复 canonical 小写 hex；不混用 64 字节 ASCII 与 32 字节 digest |
| 有界嵌套数据                                 | nullable 或非空 TEXT JSON              | 用 Zig 严格编解码；不依赖 SQLite JSON 扩展、JSON 路径查询或自动生成模型                                      |

U64 编码必须覆盖 0、i64 最大值、i64 最大值加一、u64 最大值，以及等值、范围和排序行为。编码可表达的范围不等于每个业务字段都可取该值：例如已用 ID 与 next_id 的关系仍须满足原校验，完整 fixture 不能为覆盖边界而构造非法状态。SQL 中不对这种编码直接 SUM、加一或依赖 AUTOINCREMENT；身份分配和耗尽检查继续归 Product。等长 big-endian BLOB 的数值顺序与 SQLite 字节排序一致，仍须经固定引擎回归验证。[SQLite 比较与排序规则](https://www.sqlite.org/datatype3.html#comparison_expressions)

这里的字符串 BLOB 是固定的字段表达，不是遇到 NUL 才切换类型的 fallback。现有 persistence.validText 只检查 UTF-8、空值与长度，Storage TEXT 则禁止 NUL，不能通过截断、删除字符或扩大 Storage 权限消除差异。自由字符串一律按字节存取；枚举与严格生成的 JSON 使用 TEXT，JSON 内 NUL 必须转义。查询不要将这些 BLOB CAST 为 TEXT；加载时仍执行 Product 校验，不能把 BLOB 绕过 UTF-8 检查当作可用数据。

所有 nullable 字段保留 null 与非 null 的区别。completion_seen_run_id 的 null 与 0 均按现有接受语义保留，不能为了外键便利把有效旧状态改成非法状态。

结构化 JSON 保留其完整当前字段、u64 数值精度、null/空数组差异、redacted/truncated 标记；由 Zig 按强类型解析，不经过 JavaScript number。辅助 JSON 只存附属结构，不把整个 history 或整个 Task 编码成一个大 blob。

### 4.2 身份、顺序与历史事实

- Workspace、Task 保留现有 ID；Run 的数据库主键至少带 task_id，不假定不同 Task 的引擎 run_id 全局唯一。
- 不建立新的“数据库 Session ID”、业务 store UUID 或跨 store 身份规则。
- recent_order、Run/compact ordinal、工具 activity order、UI history ordinal 分别保留，时间戳不承担顺序。
- Task 当前 binding 与 Run 执行时的 provenance 分别保存。模型变化不得回写过去 Run 的模型与 generation。
- Task 中 workspace_epoch/root 与 Workspace 当前 epoch/root 的关系按现有校验保留；不新增二者 epoch 必须相等的错误约束。
- active_operation 只保存现有可持久化的 kind/id 证据，以供重启收敛；不保存 live Session、指针、worker、credential 或当前执行权威。
- 现有 Workspace 跨 store 身份连续性缺口不由本 schema 创建新身份来解决，也不得因为表中有外键就声称已解决。

## 5. 首版表与完整字段映射

表名是本方案的建议，实施评审后统一固定。辅助 ordinal 是关系化表达所需的存储顺序，不增加产品身份。

拆表依据是已有独立身份、父子归属、顺序与更新/裁剪需求，不是每个 Zig struct 各建一表。仅附属于父记录、没有独立查询和生命周期的结构保留为有界 JSON；固定小结构可展开为列。下列表结构必须先通过 §6 的容量预检，数量不是验收目标。

| 表               | 主键与归属                                   | 对应持久字段                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| ---------------- | -------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| history_state    | singleton INTEGER = 1                        | StateWire.default_permission_profile；next_workspace_id、next_workspace_recent_order、next_task_id、next_task_recent_order                                                                                                                                                                                                                                                                                                                                                    |
| history_failures | ordinal；与有效 Task 分开                    | TaskFailureWire.task_id、recent_order、reason；保留可隔离损坏后的诊断记录，不强制引用已经丢弃的 Task                                                                                                                                                                                                                                                                                                                                                                          |
| workspaces       | id: U64                                      | WorkspaceWire 的 id、epoch、kind、canonical_root、display_name、visible、recent_order                                                                                                                                                                                                                                                                                                                                                                                         |
| tasks            | id: U64；workspace_id 引用 workspaces        | TaskWire 的 id、recent_order、completion_seen_run_id、workspace_id、workspace_epoch、workspace_root、title、title_redacted、archived、permission_profile、permission_interaction、binding 的全部四个字段、next_run_generation、active_operation 的 kind/id、checkpoint_anchor、checkpoint_attempt                                                                                                                                                                             |
| runs             | (task_id, id)；引用 tasks                    | RunWire 的 id、generation、execution_generation、execution_protocol、execution_model、permission_profile、permission_interaction、input_json、assistant、assistant_redacted、commentary_ends_json、assistant_output_kind、assistant_output_start、submitted_at_unix_ms、finished_at_unix_ms、phase、outcome、cause、usage 四计数、file_change_observation、diagnostic、diagnostic_truncated、diagnostic_redacted、event_projection_failure、next_activity_order；另有 ordinal |
| run_tools        | (task_id, run_id, id)；引用 runs             | ToolWire 的 id、order、name、input、progress、content、state、is_error、elapsed_ms、三个 truncated 标记、redacted、file_refs_json；另有 ordinal                                                                                                                                                                                                                                                                                                                               |
| run_file_changes | (task_id, run_id, id)；引用 runs             | FileChangeWire 的 id、order、kind、status、display_path、from_display_path、before_bytes、after_bytes、artifact 的完整四字段、diff_complete、redacted；另有 ordinal                                                                                                                                                                                                                                                                                                           |
| task_compacts    | (task_id, id)；引用对应 runs 的 after_run_id | CompactWire 的全部字段，包括 phase、cause、before/after_context_tokens、usage、diagnostic 及两个标记；另有 ordinal                                                                                                                                                                                                                                                                                                                                                            |
| task_ui_history  | (task_id, request_id)；引用对应 runs         | UiRecordWire 的 request_id、run_id、order、kind、state、detail、item_count、detail_truncated、redacted、agent_request_id、permission_json；另有 ordinal                                                                                                                                                                                                                                                                                                                       |
| task_checkpoints | task_id；引用 tasks                          | CheckpointWire 的 blob、session、anchor 全部字段；无记录表示 checkpoint=null                                                                                                                                                                                                                                                                                                                                                                                                  |

不得新增只有表名、尚无对应事实的 messages、sessions 或 events 通用表。Run 现有 input/assistant 组织与其工具记录继续保留；不引入原始事件日志或 event sourcing。

### 5.1 嵌套字段的穷尽映射

字段别名显式对应：RunWire.commentary_ends 写入 runs.commentary_ends_json；ToolWire.file_refs 写入 run_tools.file_refs_json。Tool 的 input_truncated、progress_truncated、content_truncated 分列保存；Compact 的 before_context_tokens、after_context_tokens 分列保存，不能合并为一个摘要值。

| 输入结构                  | 落点与必须保留的字段                                                                                                                                                            |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| BindingWire               | tasks 的 binding_epoch、execution_generation、protocol、model                                                                                                                   |
| OperationWire             | tasks.active_operation_kind / active_operation_id，二者同时为空或同时存在                                                                                                       |
| RunInputWire              | runs.input_json：kind、text、skill_id、catalog_revision、invocation_name、display_name、argument_values、attachments、redacted                                                  |
| AttachmentWire            | input_json.attachments：kind、format、display_name、size_bytes、redacted；不纳入附件原文、图片 bytes、grant 或临时路径                                                          |
| UsageWire                 | runs、task_compacts 各自保存 input_tokens、output_tokens、cache_read_input_tokens、cache_creation_input_tokens                                                                  |
| Tool 的 FileReferenceWire | run_tools.file_refs_json：id、title、display_path、kind、locator_kind、locator、range；range 保留 start/end 的 line、column                                                     |
| PermissionSummaryWire     | task_ui_history.permission_json：request_id、matched_rule_id、tool_namespace、tool_name、tool_binding、decision、source、policy_generation、used_session_rule、callback_outcome |
| FileChangeArtifactWire    | run_file_changes 的 nullable artifact 字段组：run_generation、change_order、digest、byte_size；组内同时为空或完整存在                                                           |
| CheckpointBlobWire        | task_checkpoints：generation、byte_size、digest                                                                                                                                 |
| CheckpointSessionWire     | task_checkpoints：logical_session_id、last_run_id、last_compact_id、model                                                                                                       |
| CheckpointAnchorWire      | task_checkpoints：terminal.kind/id、binding_epoch                                                                                                                               |

现有校验要求 file_change_observation 与 file_changes 同空同有。因此 observation 为 null 时恢复 file_changes=null；非 null 且无子行时恢复 []；有子行时按 ordinal 恢复数组。无需另存 presence 标记。若 observation 为 null 却出现子行，aggregate 加载必须拒绝这种不一致，不能静默忽略。file_refs_json 等无对应现有标记的可空数组仍分别保留 SQL NULL 与 JSON []。历史权限摘要只描述过去决策，不能重新成为 permission admission 的依据。

StateWire 的 workspaces/tasks/failures、TaskWire 的 runs/compacts/ui_history/checkpoint、RunWire 的 tools/file_changes 均由上述关系承接；RecoveredState 的 arena、运行时计数等内存资源不落库。Failure 记录来自既有持久输入，不发明自动修复算法。

### 5.2 约束与索引

DDL 负责类型、非空、布尔值、固定长度、主键和结构性外键。默认使用 NO ACTION，不以级联删除替代 Task 删除的生命周期编排。子表写入与删除顺序由对应业务用例规划。

普通 SQLite 表的复合/非 INTEGER 主键不隐含 NOT NULL，CHECK 表达式得到 NULL 也不会拒绝。因此所有必需列、复合主键和必需外键各分量显式 NOT NULL；非空 U64 使用 typeof/length 组合，nullable U64 使用“IS NULL 或完整类型与长度条件”；ordinal、u32、时间等整数列检查非空值的存储类型为 integer，并检查各自范围，布尔额外限定为 0/1。可选字段组用显式 IS NULL/IS NOT NULL 写成“全空或全有”，不能只比较可空值。DDL 约束落盘状态，输入绑定类型和读回结果仍需 mapper 校验。[SQLite 主键与 CHECK 语义](https://www.sqlite.org/lang_createtable.html#the_primary_key)

必须覆盖：

- Task 必须关联存在的 Workspace；Run 和附属记录不得关联其他 Task 的同名 Run。
- 每个父对象下 ordinal 唯一；runs 同时具有 (task_id, id) 主键和 UNIQUE(task_id, generation)。每个 Run 内 Tool、FileChange 各自的 id/order 唯一。
- UI request_id 在 Task 内唯一，UI order 在同一 Run 内唯一。
- assistant_output_kind/start 同空同有，active_operation 的 kind/id 同空同有，artifact 可选字段组完整。
- workspaces.canonical_root 的精确唯一性与现有 canonical 校验一致，不新增跨平台不成立的大小写折叠。
- 未明确存在的数据记录不能通过 IF NOT EXISTS、IGNORE 或 REPLACE 静默吞掉冲突。

Tool、FileChange、UI 的 wire.order 统一映射为物理列 activity_order，保留原顺序语义，避免使用 ORDER 关键字作未引用列名。[SQLite 关键字](https://www.sqlite.org/lang_keywords.html)

索引从明确查询产生：Task 的 recent_order/id、workspace_id/archived/recent_order/id；Run 的 task_id/ordinal；Tool/FileChange 的 task_id/run_id/activity_order；Compact/UI 的 task_id/ordinal。相同用途已由主键或 UNIQUE 覆盖时不重复建索引。不预建全文搜索、标签、任意 JSON 查询或统计索引。

以下仍归 Product 校验：Automatic Workspace 恰好归属一个 Task、next_* 高于已用身份/顺序、Task 与 Workspace 的历史身份关系、active operation 至多一个、checkpoint binding/anchor、现有 Tool/UI 与 Tool/FileChange 的 order 跨表互斥、FileChange 派生 ID 与 artifact 路由、observation/子行一致性、模型/permission 相容关系、字段字节预算和安全清理。SQL 外键不能替代这些不变量，也不能无依据扩大旧校验的拒绝范围。

## 6. 读写与容量可行性验证

这是本阶段的“结构能否承接真实调用”验证，不是生产 adapter。

### 6.1 测试支撑的边界

新增专用 test root，使用具名 schema、唯一 SQL contract 和真实 Storage backend。测试 mapper 仅存在于测试支撑中，将有效的现有持久事实写入隔离库再读回；不把测试函数导出给 Product Runtime，不偷偷新增生产 repository。

mapper 对本计划 §5 的字段逐项验证：按“输入类型 + 字段路径”列出落点、编码、空值语义和断言；同名字段不能只靠全文检索算作覆盖。fixture 使用可区分的非默认值和独立预期，辅以 null/空值变体，不从待测 mapper 生成期望。生产 adapter 实施时可以迁移这些有职责的函数并删除旧测试副本，不能长期维护两个 active mapper。现有 FileStore/codec 在本阶段保持生产职责。

测试支撑只做明确的 fixture 绑定、读取与比较，不建立通用 repository。Row 及其 slice 仅在 receiver 回调期间有效，必须当场复制到测试所有的有界存储；终态不是 ok 或复制/解码失败时整次结果作废，不能保留已交付的半份数据。

schema 正常编译不应因测试而依赖 Product Runtime/AgentCore；正式 Native graph 可以消费现有历史 fixture 做跨模块语义验证。

### 6.2 必须承认的容量边界

当前 history 编码上限是 16 MiB；Storage 普通 mutation 上限为 64 条 SQL、单条 64 个参数、整批 8 MiB 参数，单次 query 上限 8 MiB/8192 行。SQLite 行长度限制也受已设定 profile 约束。

因此不得先写“整个历史全量 SQL 保存必定可行”。本阶段应记录真实有效 fixture 的：

- 行数、最大单行字节、每条参数数、每批 statement 数及参数总量；
- 首次空库写入、一次 Run 保存、附属记录更新、删除/裁剪、多次保存失败后全量补齐的规模；
- 按当前真实 Limits 构造的容量边界，包含大文本、多 Tool/FileChange 以及整体有效性约束，不能只把各独立上限机械相乘；
- U64 编码、JSON 转义、SQL 和列名预算带来的实际开销。

容量核算前移到物理表结构定稿之前：从现有保存调用确定必要原子单位，估算上述规模并用具体绑定布局核对，不先把“每行一条 SQL”当作必然方案，也不把多行 INSERT 当作免费突破参数上限。先覆盖一个有效的最小完整历史和具有较多 Tool/FileChange 的合法单轮；已知不容纳时回到表达与范围评审，再决定是否继续该版 DDL。不能做完全部 mapper 才首次检查接口能否承载数据。

为小而有效的 fixture 证明一次完整事务往返；对超限 fixture，明确证明当前 API 的拒绝和数据不变。测试可以分次构建“大已有数据库”来评估查询，但不得把分批构建称为已实现原子全量保存。

本阶段不提高 Storage Limits、不新增交互式 transaction handle，不建立 revision staging 表来规避批次限制。若本阶段选定的必要原子单位无法容纳，停止冻结 v1，形成带具体输入、必要原子边界和最小接口需求的方案修订项，不能把“证明拒绝”当作这项正向验收通过。完整恢复/失败补齐若依赖尚未设计的生产策略，则单独记录后续接入阻塞项；本阶段可以交付已验证的结构候选，但不得据此冻结面向用户的格式或声称生产容量问题已解决。

### 6.3 后续 adapter 必须保持的行为

- 正常保存可以按实际变化组织 DML；保存失败后，仍需把此前未保存的内存事实补齐。
- Task 交互持久化继续遵循 best-effort；Schedule occurrence、Task 删除等保留自己的 required durable 边界。
- Workspace/Task 同一用例要求一起保存的关系必须由一次确认的原子提交承接。
- query 回调内容在 terminal ok 前是 provisional；多表、多次 query 不自动拥有同一快照。生产接入必须定义单一业务访问调度与 writer authority，不能以单连接逐操作串行等同于整个加载过程一致。
- 不分段重放已产生外部 effect 的 Run/Tool/Permission intent；outcome_unknown 与 definite failure 分开处理。

## 7. 迁移、验证与历史稳定性

### 7.1 必须通过的结构验证

1. 空隔离库执行唯一 v1 清单，表、列类型、PK、FK、CHECK、索引符合设计；meta 表仍只归 Storage。
2. 小而有效的完整历史 fixture 往返；覆盖所有字段、null/[]、提交时间、完成时间、provenance、redaction 标记、输出分段、附件元信息、checkpoint 引用和失败诊断。先由现有 codec 确认含 NUL 的自由字符串 fixture 有效，再证明 SQL 字节往返不变；编码边界包含多字节 UTF-8、JSON 转义、digest 的 hex/32 字节转换。非法 UTF-8 BLOB 必须由 mapper 拒绝。
3. 稳定的 U64 边界值精确往返，排序与相等查询正确，非法长度/type/零值按字段语义被拒绝。
4. 孤儿关系、跨 Task Run 误引用、重复 ID/generation/ordinal、复合主键含 NULL、非法布尔/非整数 ordinal 和可选字段半缺失得到预期拒绝，失败批次不留下半份历史。分别验证 observation=null、observation 非空但无子行、非空数组，以及缺少 history_state 却有业务行的 aggregate 拒绝；区分 DDL 拒绝与 Product 校验拒绝，不混记。
5. 同一清单重开后数据和迁移 identity 不变。
6. 测试专用 v1→v2 迁移链验证非空库升级、允许的普通加列/索引及回填、后续迁移失败时完整回滚。v2 仅在测试中构造，不加入生产清单充数。
7. 已有迁移被改字节、包括末尾 LF 变化时，打开返回 MigrationMismatch；库较新时返回 VersionUnknown。测试固定旧输入/已有数据库，不能在期望和实际中同时引用同一份被改的新清单而自证正确。
8. 重启收敛相关历史事实保留：未完成 Run/compact、FileChange 状态、active_operation 证据可由既有 Product 恢复语义消费；不伪造 live attachment 或运行成功。
9. 容量测量与超限反例按 §6 给出明确结论。

测试通过公开 Storage API 和生产 authorizer 完成。普通 query 同样拒绝 sqlite_schema/sqlite_master，不能把查询系统目录列为可执行验收步骤。表、列与索引定义核对唯一 DDL；约束有效性通过公开读写的正反例验证，迁移身份通过重开结果验证。不能使用裸 SQLite、关闭权限、读取受保护 metadata 或改 PRAGMA 来证明 schema 已受支持。

### 7.2 编译、模块与平台验证

- schema 清单的纯编译检查与真实 Storage 测试均接入正式 Native test graph。
- 可以新增窄入口 zig build test-product-history-schema，必须复用正式 graph 的相同 module/fixture，不建立平行构建配置。
- 同一最终源码运行 Debug、ReleaseSafe、ReleaseFast 的 schema 测试；合同模块拆分后运行 test-storage 及正式 Native graph、architecture boundaries。
- 标准命令以 docs/validation.md 与当时 build.zig 为准；正式 graph 缺少 canonical staged AgentCore bundle 必须明确失败，不跳过后声称成功。
- 当前正式组合入口为 npm test，包含 bundle 校验、Node 与正式 Native graph；边界测试的定向入口为 node --test scripts/architecture-boundaries.test.mjs。最终提交按影响执行 npm run format:check 和对应构建检查。
- 本阶段仅有平台无关合同与 SQL 结构变更，按仓库规则使用当前平台验证；若出现平台独立失败模式再追加对应平台证据。不得机械扩大矩阵，也不得声称 macOS 原生已验证。
- LF/嵌入字节需验证 Git 属性与实际内容，不把当前 Windows 文件恰好为 LF 当作跨平台保证。
- 本规划回合只检查 Markdown、链接、引用与 diff，不运行上述 runtime 测试。

## 8. 后续生产接入的明确前置项

以下工作有明确 owner，但不属于本阶段交付。schema.zig 不获得这些职责。

| 项目                                             | Owner 与必须完成的合同                                                                                                    |
| ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------- |
| 正式数据库位置、writer authority、创建/注入/关闭 | Application 实现，Product 提供领域要求；关闭需停止入口、收敛所有借用者后释放                                              |
| MigrationMismatch / VersionUnknown               | Product Control 分类数据观察、持久化可用性和业务 admission；Application 转交开库结果，不自动删除/初始化空库               |
| 旧 framed history 的处理                         | Product Control 明确格式迁移或用户显式恢复策略；未批准前仍由现有文件路径拥有权威                                          |
| 显式恢复与中断恢复                               | Product 决定候选和资格，Application 执行有界文件 effect；数据库、WAL、checkpoint/file-change 引用及中途失败均纳入独立方案 |
| 完整保存与增量重试                               | Product Control/Task persistence 定义业务提交单位、失败后补齐与 outcome_unknown 重新观察                                  |
| 同步调用与异步调度                               | 按现有 owner/main-loop/worker 模型设计，完成时重新校验 authority；不能从同步 API 推导可以阻塞 UI                          |

VersionUnknown 不是损坏；MigrationMismatch 不是清空许可。现有 workbench-history.store 的 quarantine 规则不自动成为所有 SQL 库的恢复算法，也不能用一次主文件 rename 证明 WAL 数据已完整保留。

后续规划必须处理 canonical 缺失但恢复产物仍存在、用户保留旧库/使用匹配版本、共享数据库影响范围，以及 Skill 等其他 store 对 Workspace 身份的引用。没有这些合同，不能把 SQL schema 部署到真实用户路径。

现有 credential/private reasoning 清理边界保持；附件原文、checkpoint bytes、FileChange diff payload 继续由既有对应 store/owner 管理，首版数据库只承接已有安全 metadata/reference。

## 9. 实施 DAG 与逐任务提交

本节是已获用户实施授权的 DAG。规划 task 2849 与复盘 task 2852 已完成；实施任务、依赖、提交和验证状态由 TinyKG 与本轮 goal 记录。

```text
A 目标基线与已批准修复核对
  ↓
B 字段接受范围与必要原子单位的容量预检
  ↓
C 唯一合同、schema、依赖规则与最小真实验证一并闭合
  ↓
D 真实引擎往返、约束、升级与容量验证
  ↓
E 最终 graph/文档验收与交付

E 完成 ≠ 生产接入完成
生产接入须另行完成第 8 节前置合同与第 6 节容量问题
```

| 任务 | 具体工作                                                                             | 完成条件                                                                                             | 提交评估                                                      |
| ---- | ------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------- | ------------------------------------------------------------- |
| A    | 核对目标已含 Storage 修复与业务新字段；仅在缺少时整合对应变更                        | 记录准确组合基线，保留用户改动；有合并才按相应风险验证                                               | 已具备则记录无需提交；发生整合则记录提交 hash                 |
| B    | 对照既有 codec 的字段接受范围；核算最小完整历史及较多 Tool/FileChange 的必要原子单位 | 形成具体字段映射与绑定预算；明确能继续、需改表示或需修订范围，不把已知不容纳留到最后                 | 有可保留的 fixture/核算验证则提交；仅分析则记证据，不造空提交 |
| C    | 唯一 SQL contract、schema 消费者、v1 DDL、静态清单、编译期检查、LF 与精确依赖规则    | 同批完成类型身份统一、真实空库与最小往返、最低约束、模块边界验证；不存在依赖未来任务才能成立的消费者 | 作为一个完整改动提交，不拆出未消费的合同或未验证的门禁放行    |
| D    | 全字段 fixture、升级与错误反例、容量评估、测试 mapper                                | 支持和拒绝范围均有真实证据；所有数据字段有归属；不掩盖生产接入限制                                   | 闭合后独立提交测试与必要修正，记录剩余容量接入项              |
| E    | 最终 graph、各优化模式、合同与计划清理、TinyKG 证据                                  | 同一 revision 验证；准确交付范围；无 stale 任务                                                      | 有独立文档变更则提交；只有证据时记录无需额外提交              |

每个 DAG 子任务结束立即评估完整性、验证和独立提交价值，记录 hash 或暂缓原因。不要求每个动作独立提交，也不无理由把已闭合改动积压到最后。

依赖是完成条件的真实先后，不只是文件编辑顺序。C 内合同拆分、schema 与最小测试相互配套，作为同一工作包关闭；D 只增加完整覆盖，不为 C 补一个本应已存在的消费者。B 或 D 发现必要原子单位不成立时，先修订方案，不将任务机械标为完成继续下游。

用户已明确要求存入最终方案并使用 goal 开始实施。本轮按核对后的工作树创建新的 feat/ 分支，不把此前分支名或 main 状态视作仍未变化。

## 10. 文件影响与交付检查

| 文件或范围                                                       | 预计职责                                                              |
| ---------------------------------------------------------------- | --------------------------------------------------------------------- |
| src/storage.zig、src/storage 内合同引用、build.zig               | 唯一合同模块身份与必要构建重组；保留 public 导出和既有 engine profile |
| src/product/control/persistence/schema.zig                       | 唯一迁移清单与编译期校验                                              |
| src/product/control/persistence/migrations/0001_task_history.sql | 首版数据库结构                                                        |
| .gitattributes                                                   | 本迁移目录 SQL 字节规范                                               |
| schema 专用测试 root / tests/support 下对应 fixture              | 真实公开 API、全字段往返与容量反例；精确路径在实施中按内聚性确定      |
| architecture/project-structure/Product 架构及对应 guard          | 开放窄合同依赖、结构 owner 和验证边界                                 |
| docs/validation.md                                               | 仅在新增正式入口/验证责任时更新，不镜像测试数量或当前 hash            |

不修改 AGENTS.md、app.zon、Bridge revision、产品版本、AgentCore ABI/bundle 或已安装外部 SDK。不为通过验证删除 guard；授权的 gate 变更只落实本方案 §2 的明确依赖。

本计划在本阶段实施验收结束后可按阶段材料约定移除；需要跨会话保留的批准决定、证据与后续任务写入 TinyKG。用户未将本文件指定为稳定 decision record，不因此建立永久版本合同。

## 11. 方案复盘结论

2026-09-18 进行三轮源码与合同自查。本轮没有实施 DDL 或运行引擎测试；下面的修订是方案结论，运行结果仍由实施验收提供。

### 11.1 第一轮：范围、owner 与实施依赖

- 为什么 schema 统一归 Product Control：同库迁移需要一个顺序权威，内容属于 Product；Storage 提供执行机制，不拥有业务表设计。schema 无独立生命周期，所以不增加顶层 owner。
- 为什么只依赖 SQL contract：schema 只需迁移类型；Application 后续组合 backend。依赖开放必须显式修改合同与 guard，不能靠 import 别名钻空子。
- 为什么不能照旧写“先合入修复”：复盘工作区已经包含修复，却缺少后续 main 的业务字段。前置条件应是目标内容齐全，而非执行一次固定的合并动作，已在 §1、任务 A 修正。
- 为什么合并合同与 schema 工作包：原 B 的完成条件依赖 C 的真实消费者，C 又等待 B 完成，形成任务依赖矛盾。现改为在 C 同时闭合合同、消费者、门禁和最小验证。

### 11.2 第二轮：表达是否完整，约束是否真实

- 为什么“字段全列出”仍可能丢数据：旧 codec 允许嵌入 NUL，而 Storage TEXT 不允许。原稿统一 TEXT 的建议会缩小接受范围；现将自由字符串固定映射为 UTF-8 字节 BLOB，JSON 转义和 enum TEXT 分别处理，并增加真实往返反例。
- 为什么删除额外 presence 列：既有 observation 已承诺与 file_changes 同空同有，再加标记会复制事实并引入矛盾状态。采用原有判别条件即可保留 null/[]，同时拒绝不一致子行。
- 为什么 PK/CHECK 还要细写：普通 SQLite 的主键与 CHECK 有明确 NULL 语义，笼统的“加约束”不能保证非空和可选组完整。补入显式非空、存储类型、全空/全有检查，以及现有 Run generation、FileChange order 唯一性。
- 为什么不能把所有极值塞入一个 fixture：完整 u64 表达范围与业务字段合法范围不是同一件事。编码极值单独验证，完整状态继续满足计数器、身份与顺序关系。
- 为什么区分 wire 名与 SQL 表达：order 使用 activity_order 物理列名；digest 明确为 hex 与 32 字节转换。字段映射按类型和路径核对，不以同名词出现即认为覆盖。

### 11.3 第三轮：验证是否可执行，完成是否名副其实

- 为什么前移容量检查：表结构决定行数、参数和提交成本，后置检查可能在实现整套 mapper 后才发现必要事务装不下。任务 B 先核算实际绑定，不能容纳就调整候选方案，不先冻结格式。
- 为什么改掉系统目录查询验收：现有公开 query 也拒绝 sqlite_schema/sqlite_master。验收改为 DDL 核对、公开读写正反例和重开行为，不新增测试特权。
- 为什么建表成功不等于 ready：迁移链不创建业务状态，loader 必须分清尚未初始化和缺少 history_state 的不完整数据。Product 仍拥有 health、admission 与恢复；schema 不兜底重置。
- 为什么容量拒绝测试不等于支持：它只能证明边界行为。必要原子单位、完整恢复和失败补齐分别给出结论，生产可行性仍未解决时不得据此宣布可切换。

这些问题的共同原因是原稿较重视字段清单和按文件拆任务，对“旧数据接受范围 → SQL 表达 → 公开 API 限制 → 可执行验收”的逐段核对不足。修订保留原有分层方向，收紧数据表达、工作包与证据要求；不借复盘扩大 Storage 权限、引入新 owner 或提前切换生产。

## 12. 核对依据

- [SQL 类型、限制和迁移校验](../src/storage/sql.zig)
- [Storage backend 与 capability](../src/storage/sqlite.zig)
- [Storage 迁移身份执行](../src/storage/sqlite/migrations.zig)
- [现有完整历史 wire 与 codec](../src/product/task/persistence.zig)
- [Product Control 历史提交与恢复编排](../src/product/control/runtime.zig)
- [Task 运行时身份分配](../src/product/task/runtime.zig)
- [产品需求](requirements.md)
- [高层架构](architecture.md)
- [Product 架构](product-architecture.md)
- [工程结构](project-structure.md)
- [Storage 架构](storage-architecture.md)
- [验证规范](validation.md)
- [架构边界测试](../scripts/architecture-boundaries.test.mjs)

本文件的字段清单绑定 §1 的规划基线。实施前重新对照当前类型；若新增字段，更新本阶段映射与 fixture，不能以规划期间的清单覆盖后来合法新增的数据。

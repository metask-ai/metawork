# MetaWork Storage 架构

> 状态：Storage SQL contract、直接 SQLite backend 与 conformance 的 source of truth；Application 与 Product 尚未接入

本文定义 MetaWork 自有的 SQLite 基础存储能力。Storage 只提供无业务语义的 SQL、事务、迁移和数据库生命周期机制；基础能力完成不等于批准迁移或接入任何现有 Product 数据。

Storage 的顶层边界见[高层架构](architecture.md)，源码 owner 见[工程结构与所有权](project-structure.md)，验证责任见[验证规范](validation.md)。

## 1. 决策与范围

当前实现直接链接固定版本的 SQLite，并通过 backend-neutral contract 隔离 C API：

```text
future Product owner
  └─ owns schema and migration SQL
       ↓
MetaWork Storage SQL contract
       ↓
single direct SQLite connection
```

基础层采用以下 hard-cut 决策：

1. 一个 SQLite connection 同时执行 query、mutation 和 migration；没有并发吞吐证据前不引入读连接、连接池或 snapshot 协调。
2. API 同步阻塞；Storage 不创建 worker、不调度 deadline、不自动重试。
3. concrete `Database` 由 allocator 创建在稳定地址，借出的 capability 只在 owner shutdown/destroy 前有效。
4. query、mutation、migration 和 Storage metadata 使用不同的最小权限 authorizer；connection 空闲时默认 deny-all。
5. mutation 是一次提交的 statement batch，不开放跨 callback、线程或 owner 的交互式 transaction handle。
6. 文件数据库使用 `WAL + synchronous=FULL`；在没有性能证据时优先承诺已返回 commit 的断电持久性。
7. migration identity 由 Storage-owned metadata table 保存，不使用 `PRAGMA user_version` 作为身份或兼容路径。

当前范围严格限制在 `Storage`、SQLite build profile、对应测试与本真源。它不包括 Application composition、正式数据库路径、Product schema、旧数据迁移、双写、运行时 fallback 或现有 store 的删除。

## 2. Owner 与依赖方向

Storage 拥有：

- backend-neutral value、statement、mutation、row、migration、limits 和 outcomes；
- 参数绑定、只读 query、原子 mutation batch、行数期望和 migration identity；
- SQLite connection、authorizer、engine profile、limits、interrupt、shutdown 和错误分类；
- backend conformance、SQLite 集成、故障和 crash-recovery 验证。

Storage 不拥有业务表、Product health/retry/recovery policy、应用数据目录、production identity 或顶层启动顺序。`src/storage/sql.zig` 不得导入 Product、Application、Bridge、Renderer、Native SDK 或 SQLite C 类型；SQLite C 值只存在于 concrete backend 内。

未来 Product owner 采用 SQL 时必须另行定义 schema、migration 内容、恢复和业务并发不变量。未来 backend adapter 必须完整满足本合同；不得以兼容层、双写或静默 fallback 弱化合同。

模块 owner 固定为：

```text
src/storage.zig                         # Storage module root
src/storage/sql.zig                     # backend-neutral public contract
src/storage/conformance.zig             # shared backend contract tests
src/storage/sqlite.zig                  # public concrete owner and lifecycle orchestration
src/storage/sqlite/connection.zig       # SQLite C API, profile, limits, authorizers, bind/row/error
src/storage/sqlite/migrations.zig       # migration metadata, checksum and atomic application
tests/support/storage_crash_fixture.zig # child-process WAL recovery fixture
```

不继续按 helper 数量拆文件；只有出现新的 owner、生命周期或独立可测试不变量时才增加模块。

## 3. Backend-neutral SQL contract

### 3.1 输入类型

```zig
pub const Value = union(enum) {
    null_value,
    integer: i64,
    real: f64,
    text: []const u8,
    blob: []const u8,
};

pub const Statement = struct {
    sql: []const u8,
    params: []const Value = &.{},
};

pub const ChangeExpectation = union(enum) {
    any,
    exactly: u64,
};

pub const Mutation = struct {
    statement: Statement,
    expected_changes: ChangeExpectation = .any,
};
```

动态值必须通过 parameter binding 传入。SQL、migration name 和 `TEXT` 不得包含 NUL；`TEXT` 必须是 UTF-8，`REAL` 必须 finite。Value 约束同时适用于输入参数和返回 row；SQL 表达式产生的非法 TEXT/REAL 必须在 callback 前拒绝。BLOB 不受 TEXT 的 NUL/UTF-8 限制。

`Database.query` 只接受一个只读 statement。`Database.mutate` 将非空 mutation array 放入一个 `BEGIN IMMEDIATE` transaction；每条 statement 必须是无返回 row 的 DML。`exactly` 使用该 statement 的 `sqlite3_changes64` 结果校验，任一 mismatch 返回 `conflict` 并回滚完整 batch。

Storage 不开放 `RETURNING`、prepared statement、transaction handle、PRAGMA、DDL mutation、ATTACH/DETACH 或临时 schema。增加这些能力必须由真实 consumer 和对应失败模式证明，而不是预留抽象。

### 3.2 Row 与 streaming

`Row`、column name、`TEXT` 和 `BLOB` 只在同步 `RowReceiver` callback 内有效；需要保留的数据由调用方深拷贝。callback 可以调用其他 `Database`，但不得直接或间接重入当前正在派发它的同一 instance，重入返回 `rejected`。

列数、列名和值必须对应本次实际执行的结果，所有返回列都参与值校验和结果预算。其他 instance 对同一文件完成迁移后，查询不能继续使用执行前的旧结果形状；零行查询返回 `ok` 且不产生 callback。

query 是有界 streaming，不承诺 all-or-nothing row delivery。receiver 必须把已收到的 row 当作 provisional candidate，只有 terminal outcome 为 `ok` 才能采纳；若达到 result limit、被取消或后续 step 失败，先前 callback 不会撤销。Storage 不以最多 8 MiB 的内部深拷贝伪造原子结果。

### 3.3 Outcomes

```zig
pub const QueryOutcome = enum {
    ok, busy, cancelled, corrupt, rejected, resource_exhausted,
    definite_io_failure, unavailable,
};

pub const MutationOutcome = enum {
    committed, conflict, constraint, busy, cancelled, corrupt, rejected,
    resource_exhausted, definite_io_failure, outcome_unknown, unavailable,
};
```

`busy` 只表示 SQLite/file contention，不能表示进程内 gate 等待。`unavailable` 表示 instance 正在停止、已经停止或已 poisoned。Storage 不自动重试；重试需要业务幂等性，因此属于未来 caller policy。

query/mutation 的 `resource_exhausted` 包含内存不足、SQLite 内容长度超限、存储容量耗尽及 wrapper 结果预算超限；这些公开结果不进一步细分原因。migration 的打开错误采用第 5 节的分类。

mutation 在 `COMMIT` 失败后结合 `sqlite3_get_autocommit` 和 rollback 结果分类：能够证明事务未提交时返回原始 definite outcome；无法证明 commit 或 rollback 最终状态时返回 `outcome_unknown`，poison 当前 instance，并拒绝后续 mutation。只有 SQLite backend 能观察这些事实，不能把该判断上移给 caller。

statement 失败时 SQLite 可能已自动回滚（例如 `OR ROLLBACK`、写入取消或资源错误）；尚未尝试 `COMMIT` 且已确认事务结束时，保留原始 definite outcome，不再把重复 `ROLLBACK` 的失败当作结果未知。事务结果与连接健康分开：已确认提交或回滚后，恢复 idle authority 失败仍须 poison instance，但不得改写已知结果。

### 3.4 Limits

- ordinary SQL text：64 KiB；migration SQL：1 MiB；
- 单 statement params：64；单 mutation batch：64 statements；
- 单 query parameters：1 MiB；单 mutation batch parameters：8 MiB；
- 单 query：最多 8K rows、8 MiB result bytes；
- SQLite engine 同步设置 `LENGTH`、`SQL_LENGTH`、`VARIABLE_NUMBER`、`ATTACHED=0` 和 `WORKER_THREADS=0` limits。

超限返回 `resource_exhausted` 或在 backend dispatch 前返回 `rejected`，不得截断后伪装成功。

## 4. SQLite authority

每次 public operation 在 prepare 前切换到对应 authorizer，结束后恢复 deny-all：

| authority | 允许 | 强制拒绝 |
| --- | --- | --- |
| query | main schema 的 SELECT/READ/FUNCTION/RECURSIVE | DML、DDL、transaction/savepoint、PRAGMA、ATTACH/DETACH、temp schema、Storage metadata |
| mutation | main schema 的 INSERT/UPDATE/DELETE 及其读取表达式 | DDL、transaction/savepoint、PRAGMA、ATTACH/DETACH、temp schema、Storage metadata、row-producing statement |
| migration | main schema 中符合下述能力边界的 DDL 与 backfill DML | transaction/savepoint、PRAGMA、ATTACH/DETACH、temp schema、Storage metadata |
| metadata | migration metadata 的建表、读取和追加 | public caller 不可获得该 authority |
| internal transaction | Storage 自己准备的 BEGIN/COMMIT/ROLLBACK | 其他 SQL action |

authorizer 按 SQLite action 的真实参数语义检查目标对象及关联表；作用于 metadata 的 index、trigger、ALTER 等不能绕过隔离。metadata authority 只允许 Storage 自有 SQL 所需动作，不授予存储的 trigger/view，未知动作默认拒绝。

authorizer 不是 SQL 文本关键字过滤器。`sqlite3_stmt_readonly` 和 statement shape 仍作为第二层检查，但不能单独承担 transaction control 隔离，因为 SQLite 会把部分 transaction statement 标记为 readonly。

## 5. Migration identity

Storage 在同一数据库创建：

```sql
CREATE TABLE _metawork_storage_migrations(
  version INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  checksum BLOB NOT NULL CHECK(length(checksum)=32)
);
```

migration version 从 1 严格连续。checksum 是 SHA-256，输入依次为 big-endian u32 version、NUL、name bytes、NUL、SQL bytes。open 时按 version 读取 persisted rows，并验证它们是当前 migration input 的精确前缀：

- persisted row 多于当前 target：`VersionUnknown`；
- version gap 或非法 metadata：`Corrupt`；
- name 或 checksum 不同：`MigrationMismatch`；
- pending migration SQL 与对应 metadata insert 在一个 `BEGIN IMMEDIATE` transaction 内提交；
- identity insert 必须实际追加一条记录；提交前验证最终完整身份序列，公开版本必须与已验证记录一致，不能仅从输入数量推导；
- 任一失败完整 rollback；无法确认 migration commit 结果时返回 `MigrationOutcomeUnknown`。

普通 query/mutation 不能读取或修改 metadata table。当前没有多 Product owner schema registry；基础层只建立不可伪造的单一 migration 序列，未来 owner 组合必须另行决策。

`schemaVersion()` 表示该 instance 打开时验证的迁移版本；其他 instance 随后迁移同一文件不会刷新此值。它不表示实时文件 schema 版本，也不能作为查询结果形状不会变化的保证。

### 5.1 迁移能力边界

迁移支持符合 authority 规则的建表、普通加列、索引、触发器、视图与数据回填，并支持 `ALTER TABLE ... ALTER COLUMN ... SET NOT NULL` 和 `DROP NOT NULL`。SET NOT NULL 必须校验已有数据，存在 NULL 时整批 pending migration 失败并回滚。

当前迁移不承诺 SQLite 的全部 DDL。以下能力缺口由既定权限边界产生，必须明确拒绝并回滚：

| 操作 | 限制原因 |
| --- | --- |
| `ALTER TABLE ... DROP COLUMN` | 引擎内部还会访问 temp 系统目录，受 temp 禁令限制 |
| RENAME TABLE、RENAME COLUMN | 引擎内部更新 temp 系统目录，受 temp 禁令限制 |
| 带 CHECK 的 ADD COLUMN、STRICT 表上的 ADD COLUMN、带 NOT NULL 的生成列 ADD COLUMN | 引擎内部执行 `pragma_quick_check`，受 PRAGMA 禁令限制 |

ALTER 的 schema 与目标表必须按该 action 的参数语义验证；列名不能被解释成 schema。纠正参数解释不授予 temp、PRAGMA 或 metadata 豁免，也不向 query、mutation、metadata authority 开放 ALTER。官方重建表流程涉及 RENAME，不能作为当前已支持的通用替代方案；调用方不能绕过 Storage 执行这些操作。

### 5.2 迁移资源错误

SQLite 的错误原因在内部保留，到公开边界再按操作语义映射。迁移失败且能够确认事务未提交时，`sqlite.OpenError` 使用以下分类：

| 原因 | 打开错误 |
| --- | --- |
| 内存分配失败，包括 `SQLITE_NOMEM` | `OutOfMemory` |
| 迁移内容超过 SQLite 长度限制，即 `SQLITE_TOOBIG` | `MigrationFailed` |
| SQLite 存储容量耗尽，即 `SQLITE_FULL` | `StorageFull` |

`StorageFull` 表示引擎报告容量耗尽，也包括数据库页数上限；它不等同于路径不可用、内存不足，也不保证物理磁盘已经写满。wrapper 自身的预算/溢出错误不能冒充内存分配失败。上述分类不覆盖事务确定性判断：无法确认 commit 或 rollback 最终状态时仍返回 `MigrationOutcomeUnknown`。

## 6. Connection profile

文件数据库必须逐项设置并回读确认：

```text
journal_mode = WAL
synchronous = FULL
foreign_keys = ON
busy_timeout = 250 ms
mmap_size = 0
SQLITE_DBCONFIG_DEFENSIVE = 1
SQLITE_DBCONFIG_TRUSTED_SCHEMA = 0
```

任何设置未生效都 fail closed，不能继续使用旧值。特别是 `journal_mode=WAL` 的 statement 即使返回 `SQLITE_OK` 也可能返回未切换的实际模式，因此必须检查结果 row。内存数据库使用独立 profile，不要求 WAL 或 mmap。

build 固定 SQLite 3.53.4 official amalgamation，并启用 `THREADSAFE=2`、`OMIT_LOAD_EXTENSION`、`DQS=0`、`TRUSTED_SCHEMA=0` 和默认 WAL synchronous FULL。不得使用系统 SQLite、浮动版本或第二份 engine symbol。

## 7. Lifecycle、并发与取消

```text
Database.create(io, allocator, target, migrations) -> *Database
  -> borrow capability
  -> synchronous query/mutate
  -> optional interrupt
  -> shutdown
  -> destroy
```

instance 使用一个 `std.Io.Mutex` 和 `std.Io.Condition` 串行 operation，不持有 spinlock 执行 SQL。异线程调用等待 gate；同线程 callback 重入立即拒绝。

`shutdown` 原子停止 admission，唤醒 waiting caller，调用 `sqlite3_interrupt` 请求取消 active operation，等待它离开，再关闭 connection。它允许异线程并发调用并保持幂等。同步 callback 不能等待自身退出，因此在 active operation 的同一线程调用 `shutdown` 或 `destroy`，必须立即返回 `error.ReentrantOperation`，且不改变 owner 状态。

owner 在 `destroy` 前必须停止并 join 全部其他使用者，包括 gate waiter、并发 shutdown caller 和其他 borrowed capability 使用者；通常顺序为 shutdown、收敛使用者、destroy。`destroy` 保证 shutdown 后释放 stable owner，不提供与其他 caller 并发销毁的隐式引用计数。caller 不得在 `destroy` 后使用 borrowed capability。

`interrupt` 只请求取消当前 operation；SQLite 返回 `SQLITE_INTERRUPT` 时映射为 `cancelled`。取消是协作式请求，不强制中断 caller callback，也不保证胜过即将完成的提交；callback 必须自行返回，shutdown 才能完成。Storage 不创建 timer 或 deadline worker。

## 8. 验证 Gate

本合同的验证责任、标准入口、平台矩阵与未闭合证据统一由[验证规范的 Storage 基础层验证](validation.md#storage-基础层验证)定义。测试必须观察本合同中的权限隔离、持久化身份、事务结果与连接健康、借用生命周期和恢复不变量；测试数量或单次全绿不能替代这些证据。

当前基础层仍不创建 production `app.db`，不改变任何 Workbench store、Account persistence、Application startup/shutdown 或 Product mutation path。

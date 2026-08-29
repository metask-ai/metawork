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

动态值必须通过 parameter binding 传入。SQL、migration name 和 `TEXT` 不得包含 NUL；`TEXT` 必须是 UTF-8，`REAL` 必须 finite。

`Database.query` 只接受一个只读 statement。`Database.mutate` 将非空 mutation array 放入一个 `BEGIN IMMEDIATE` transaction；每条 statement 必须是无返回 row 的 DML。`exactly` 使用该 statement 的 `sqlite3_changes64` 结果校验，任一 mismatch 返回 `conflict` 并回滚完整 batch。

Storage 不开放 `RETURNING`、prepared statement、transaction handle、PRAGMA、DDL mutation、ATTACH/DETACH 或临时 schema。增加这些能力必须由真实 consumer 和对应失败模式证明，而不是预留抽象。

### 3.2 Row 与 streaming

`Row`、column name、`TEXT` 和 `BLOB` 只在同步 `RowReceiver` callback 内有效；需要保留的数据由调用方深拷贝。callback 可以调用其他 `Database`，但不得直接或间接重入当前正在派发它的同一 instance，重入返回 `rejected`。

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

mutation 在 `COMMIT` 失败后结合 `sqlite3_get_autocommit` 和 rollback 结果分类：能够证明事务未提交时返回原始 definite outcome；无法证明 commit 或 rollback 最终状态时返回 `outcome_unknown`，poison 当前 instance，并拒绝后续 mutation。只有 SQLite backend 能观察这些事实，不能把该判断上移给 caller。

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
| migration | main schema 的 DDL 与 backfill DML | transaction/savepoint、PRAGMA、ATTACH/DETACH、temp schema、Storage metadata |
| metadata | migration metadata 的建表、读取和追加 | public caller 不可获得该 authority |
| internal transaction | Storage 自己准备的 BEGIN/COMMIT/ROLLBACK | 其他 SQL action |

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
- 任一失败完整 rollback；无法确认 migration commit 结果时返回 `MigrationOutcomeUnknown`。

普通 query/mutation 不能读取或修改 metadata table。当前没有多 Product owner schema registry；基础层只建立不可伪造的单一 migration 序列，未来 owner 组合必须另行决策。

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

`shutdown` 原子停止 admission，唤醒 waiting caller，调用 `sqlite3_interrupt` 取消 active operation，等待它离开，再关闭 connection。`shutdown` 幂等；`destroy` 先保证 shutdown，再释放 stable owner。caller 不得在 `destroy` 后使用 borrowed capability。

`interrupt` 只请求取消当前 operation；SQLite 返回 `SQLITE_INTERRUPT` 时映射为 `cancelled`。Storage 不创建 timer 或 deadline worker。

## 8. 验证 Gate

基础层完成至少需要：

- backend-neutral fake conformance；
- memory SQLite integration；
- file reopen、WAL/FULL/profile/limit verification；
- transaction/savepoint escape、DDL/PRAGMA/metadata authority negative tests；
- expected-changes conflict 与完整 rollback；
- migration prefix/checksum、unknown version、atomic rollback；
- busy、constraint、cancel、resource、corrupt 和 outcome-unknown fault mapping；
- blocking no-spin concurrency、shutdown/interrupt convergence；
- child-process crash 后 reopen/hot-WAL recovery；
- `test-storage` Debug、ReleaseSafe、ReleaseFast；
- Windows 与 macOS 原生文件数据库 suite；cross-compile 不能替代原生运行；
- architecture guard 证明 Storage 没有进入 Application/Product graph。

当前基础层仍不创建 production `app.db`，不改变任何 Workbench store、Account persistence、Application startup/shutdown 或 Product mutation path。

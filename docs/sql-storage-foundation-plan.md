# MetaWork SQL 基础存储能力方案

> 状态：Storage foundation 已实施；Application 与 Product 接入未实施
> 日期：2026-08-20

本文定义 MetaWork 自有的 SQLite 基础存储能力。SQLite 是产品必须具备的长期基础设施，不以 Native SDK relational capability 是否完整为前提；Native SDK 后续可以替换数据库访问适配层，但不接管产品 schema、数据所有权或恢复策略。

本方案的基础能力边界已落实到[高层架构](architecture.md)、[工程结构与所有权](project-structure.md)和[验证规范](validation.md)。[Product 内部架构](product-architecture.md)仍定义现有持久化行为；本文件不授权迁移、删除或重写任何现有持久化数据。

## 1. 决策

建立一个小型、无业务语义、MetaWork-owned 的 `Storage SQL` contract，并先用直接 SQLite 后端完整实现：

```text
Product owner
  ├─ owns schema / migration SQL / health / recovery / concurrency policy
  ↓
MetaWork Storage SQL contract
  ├─ current backend: direct SQLite
  └─ future backend: Native SDK relational adapter
                         ↓
                    same app.db
```

核心结论：

1. SQL 基础能力不再等待 Native SDK 公开 Zig row decoder；
2. 当前直接链接官方 SQLite，并通过窄后端隔离 C API；
3. 数据库文件、schema 和 migration version 是 MetaWork/Product 的长期资产，不属于某个后端；
4. Native SDK 后续满足完整合同后原位替换后端，继续打开同一个 `app.db`，不复制、不双写、不迁移用户数据；
5. 直接后端与未来 Native SDK 后端必须同时通过同一套 conformance tests。

## 2. 当前交付范围

首版只完成一个可独立验收的 `Storage` 模块：

- 用显式 caller-provided path 打开和关闭文件数据库，以及测试用内存数据库；
- parameterized read-only query；
- 多 statement、单 `BEGIN IMMEDIATE` transaction exec；
- `NULL`、`INTEGER`、finite `REAL`、UTF-8 `TEXT` 和 `BLOB`；
- typed borrowed row callback；
- 有界输入、参数和结果；
- 连续、append-only、原子执行的 schema migrations；
- 精确失败分类和完整 rollback；
- 直接 SQLite 后端的真实集成测试。

本阶段不接入 Application 启动和 shutdown，不解析正式数据目录，不创建 production `app.db`，不向任何 Product owner 注入 capability，不把任何现有业务 persistence 切换到 SQL，也不创建测试用途的正式产品表。

## 3. 非目标

当前阶段不做：

- Workbench history、Conversation、checkpoint、Account 或 MCP 数据迁移；
- Application composition、正式 database path、production/automation namespace 或 `app.zon` capability；
- 修改任何上层 owner、restore、startup、shutdown 或 mutation 路径；
- 替换或删除 `workbench-history.store`、frame、checksum、atomic replace 或现有 locks；
- 定义 Workspace、Task、Run、Conversation 或其他产品 schema；
- 改变现有单实例、single-writer、mutation fence、degraded health 或 crash recovery 合同；
- ORM、query builder、Repository、全局 `StorageManager` 或 schema registry；
- key-value、blob store、credential、远程同步、多数据库或跨 owner transaction；
- direct/Native SDK 双后端运行、双写、运行时 fallback 或自动数据复制。

未来产品 owner 采用 SQL 时，必须单独定义其 schema、迁移内容、并发、持久性、损坏处理和恢复不变量。基础模块的存在不等于批准迁移现有数据。

## 4. Owner 与依赖方向

### 4.1 Storage

Storage 拥有：

- 后端无关的 SQL value、statement、row、migration、limits 和 outcomes；
- parameter binding、read-only query、transactional exec 与 migration 的机械语义；
- 直接 SQLite 后端及后端 conformance suite；
- SQLite engine profile 和数据库兼容边界。

Storage 不拥有：

- 业务表、索引、trigger 或 migration SQL；
- 产品 health、重试、恢复、checkpoint、数据保留或并发 policy；
- 应用数据目录、production/automation identity 或顶层生命周期。

`storage` 公共合同不得导入 Workbench、Account、Agent、Bridge、Renderer、Application、Native SDK 或 SQLite C 类型。

### 4.2 Product owner

每个 Product owner 拥有自己的 schema 与 migration 内容，并通过 Storage 提交。业务代码只能依赖 Storage contract，不得导入 SQLite C API、直接后端或 Native SDK relational 类型。

`PRAGMA user_version` 作为整个 `app.db` 的 schema version，因此首个正式 consumer 落地前必须明确数据库级 migration owner 和多个 Product owner 的组合顺序。本阶段只有空 migration plan，不提前设计跨 owner schema registry。

### 4.3 Future Application integration

未来 Application 接入时负责：

- 解析 canonical database directory；
- 选择唯一后端；
- 在 Product owner restore 前 open + migrate；
- 注入 `storage.Database`；
- shutdown 时先停止消费者，再关闭数据库。

Application 只做 composition 和生命周期控制，不持有 schema、SQL 或业务状态。上述接入不属于本次实施范围；本次只保证 Storage backend 能以显式 path 独立 open/migrate/close。

### 4.4 Native SDK

Native SDK 不是 SQL 数据 owner。未来 adapter 只把其 relational binding 机械映射到同一个 Storage contract；是否使用 SDK 是实现选择，不改变 Product 对 SQLite 数据的所有权。

## 5. 最小模块

```text
src/storage.zig             # module root
src/storage/sql.zig         # 稳定 SQL contract 与基础类型
src/storage/sqlite.zig      # 当前直接 SQLite 后端
src/storage/conformance.zig # 后端共享合同测试，仅进入 test graph
```

直接 SQLite 是 Storage 的一个具体 backend，不是 Application compatibility layer，也不是第二个 Product owner。它通过 `storage.Database` 与调用方隔离 SQLite C API，不得扩展成通用数据库框架。Native SDK adapter 可完整替代后删除 `src/storage/sqlite.zig` 和直接 SQLite build dependency；`src/storage.zig`、`src/storage/sql.zig` 与 conformance contract 保留。

不为未来消费者预建 repository、manager、facade 或空 schema 层。

## 6. 稳定 SQL contract

### 6.1 Value、Statement 与 Migration

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

pub const Migration = struct {
    version: u32,
    name: []const u8,
    sql: []const u8,
};
```

动态值必须通过 params 绑定。Storage 不提供 SQL 字符串拼接 helper，也不解释表名、列名或业务标识。

Migration 只提供基础执行机制：

- version 从 1 开始严格连续，已经发布的 migration 不修改、不重排；
- 当前 `user_version` 大于二进制目标版本时 fail closed；
- 所有 pending migrations 与最终 `user_version` 更新在一个 `BEGIN IMMEDIATE` transaction 中完成；
- 任一 migration 失败则整体 rollback，数据库版本保持不变；
- migration SQL 和 migration 何时加入由对应 Product owner 决定。

### 6.2 Database

```zig
pub const Database = struct {
    context: *anyopaque,
    query_fn: *const fn (
        context: *anyopaque,
        sql: []const u8,
        params: []const Value,
        receiver: RowReceiver,
    ) QueryOutcome,
    exec_fn: *const fn (
        context: *anyopaque,
        statements: []const Statement,
    ) ExecOutcome,

    pub fn query(
        self: Database,
        sql: []const u8,
        params: []const Value,
        receiver: RowReceiver,
    ) QueryOutcome;

    pub fn exec(
        self: Database,
        statements: []const Statement,
    ) ExecOutcome;
};
```

Storage capability 不公开 path、connection、prepared statement、transaction handle 或 PRAGMA。`storage.sqlite.Database` 是 concrete backend owner，负责以显式 path open/migrate/close，并可借出后端无关的 `storage.Database` capability；借用 capability 不得比 concrete instance 活得更久。未来 Application 只持有该 instance，不复制其资源。

首版不公开交互式 transaction 对象。多个 mutation 必须作为一个 `exec` statement array 一次提交，避免 transaction 跨 owner、线程或 callback 逃逸。`exec` 中每条 statement 都必须是 SQLite 判定为非 read-only、且执行完成不产生 row 的 mutation；`SELECT` 等 read-only statement 返回 `misuse`，并回滚整个 batch。

### 6.3 Row 与 borrowed lifetime

```zig
pub const Row = struct {
    pub fn columnCount(self: Row) usize;
    pub fn columnName(self: Row, index: usize) []const u8;
    pub fn value(self: Row, index: usize) Value;
};
```

- `Row`、column name、`TEXT` 和 `BLOB` 只在同步 receiver 调用内有效；
- receiver 外需要保留的数据由调用方深拷贝；
- receiver 不得保存 row、slice 或 backend context；
- receiver 可以调用其他 `Database`，但不得直接或间接调用当前正在派发它的同一个 `Database`；通过正常参数校验的 nested `query`/`exec` 返回 `misuse`，外层 query 继续按自身结果完成；
- 同一 `Database` 的异线程调用由 backend 安全协调，但合同不承诺等待或并行；进程内协调不映射为 `busy`，file/memory 的连接拓扑不形成不同的公开再入语义；
- callback 不跨线程异步派发；
- 结果超过合同上限时整个 query 返回 `rejected`，不得截断后伪装成功；
- 大结果由调用方显式使用 `LIMIT` 与 keyset pagination，Storage 不隐式分页或缓存。

直接后端从 SQLite column API 构造 `Row`，不编码或复制 Native SDK 私有 page dialect。未来 adapter 使用 Native SDK 正式公开 decoder，Storage contract 不随 wire format 改变。

### 6.4 Outcomes

```zig
pub const QueryOutcome = enum {
    ok,
    busy,
    io_failed,
    corrupt,
    misuse,
    rejected,
};

pub const ExecOutcome = enum {
    ok,
    constraint,
    busy,
    io_failed,
    corrupt,
    misuse,
    rejected,
};
```

open/migration 使用独立的 typed error/outcome，至少区分路径或权限失败、busy、corrupt、migration failed 和 newer schema version。

`user_version` 的 Storage metadata namespace 固定为 `0...9999`：范围内高于调用方 migration target 的值是合法但当前未知的 `VersionUnknown`；负数或超出 namespace 的值违反 Storage metadata invariant，返回 `Corrupt`。

后端不把错误折叠为 bool，不自动重试，不把失败 query 解释为空结果，也不把失败 exec 解释为成功。`corrupt` 是数据库级事实；Storage 不承诺旧 frame store 的“单记录损坏隔离”，具体 health 与 mutation fence 由使用该 schema 的 Product owner 定义。

### 6.5 Limits

首版采用并测试与当前 Native SDK relational surface 一致的公共子集：

- SQL 文本：64 KiB；
- 单 statement params：64；
- 单 exec statements：64；
- 单参数 `TEXT`/`BLOB`：1 MiB；
- 单 exec 参数累计：8 MiB；
- 单 query：最多 8K rows、8 MiB 结果；
- `TEXT` 必须是有效 UTF-8，`REAL` 必须 finite；
- SQL、name 和 text 输入不得包含 NUL。

直接后端不需要模拟 Native SDK 的 256-row/256-KiB encoded page，因为 page 是 SDK transport 细节，不属于 Storage contract。未来 adapter 可以在内部逐 page 解码，但对 Product 仍表现为相同的同步 row stream 和总量上限。

## 7. 直接 SQLite 后端

### 7.1 Dependency

使用 SQLite 官方 amalgamation 作为显式、固定版本和固定 hash 的 build dependency，直接通过 SQLite C API 实现窄后端：

- 不使用操作系统偶然存在的 SQLite；
- 不复制 Native SDK 私有 SQLite wrapper、page parser 或内部源码；
- 不再引入一层第三方 ORM/wrapper；
- 禁止 loadable extensions；
- 依赖升级必须运行文件兼容、migration、事务和故障映射测试。

当前锁定 SQLite 3.53.4 官方 amalgamation；固定 URL 与 hash 进入 `build.zig.zon`，不使用 `latest`、系统 SQLite 或浮动下载地址。后续升级仍须同时满足 Native SDK SQLite 兼容性和目标平台构建验证。

### 7.2 Engine profile

持久化数据库使用与当前 Native SDK 可观察语义一致的 profile：

```sql
-- writer connection
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
PRAGMA busy_timeout=250;
PRAGMA foreign_keys=ON;

-- reader connection
PRAGMA busy_timeout=250;
PRAGMA foreign_keys=ON;
PRAGMA query_only=ON;
```

- 一个 serialized writer connection；
- 一个 read-only/query-only reader connection；
- 持久化文件数据库使用上述双连接；普通 `:memory:` 是 per-connection database，因此内存 target 使用一个连接兼任 reader/writer，不能打开两个彼此隔离的空数据库；
- query 只允许 SQLite 判定为 read-only 的单 statement；
- exec 只接受不产生 row 的 mutation statement；read-only statement 返回 `misuse`，完整 statement array 使用一个 `BEGIN IMMEDIATE` transaction，任一失败完整 rollback；
- 参数数量必须与 statement 实际 placeholder 数量一致；
- 禁止 `ATTACH`/`DETACH`、load extension 和通过普通 query/exec 修改受保护 PRAGMA；
- close 前等待同步调用退出，不让 SQLite pointer 或 borrowed bytes 逃逸。

这些是可测试的后端语义，不暴露成业务可调配置。首版不增加连接池、后台 checkpoint thread、自动重试或可配置 PRAGMA。

### 7.3 Durability

`WAL + synchronous=NORMAL` 在应用进程崩溃时保留已提交事务，并保持数据库一致性；在 OS crash 或突然断电时，最近已经返回成功的事务仍可能回滚。直接后端从第一天就与当前 Native SDK 使用相同语义，因此后续替换不存在隐式的 `FULL → NORMAL` 降级。

任何 Product owner 接入前都必须确认该 durable boundary 是否可接受。如果产品要求“commit 返回后即使断电也必须保留”，应先把 engine profile 明确升级为 `FULL`，并把 Native SDK 支持等价 profile 设为未来切换的硬 Gate，而不是在两个后端之间静默改变承诺。

## 8. Storage instance lifecycle 与未来 path 约束

本次 Storage API 接受显式 database target，不读取环境变量、产品 identity 或 OS app-data policy：

```text
caller-provided path / in-memory target
→ storage.sqlite.Database.open + migrate
→ borrow storage.Database
→ finish all synchronous calls
→ storage.sqlite.Database.deinit
```

open/migration 失败时不产生可用 capability。`deinit` 前调用方必须停止新调用并等待现有同步调用返回；Storage 不建立全局 lifecycle state machine，也不推测上层 shutdown 顺序。

未来正式接入必须把 canonical database 固定为 `<runner app-data directory>/app.db`，并证明直接后端与 Native SDK 实际打开同一个绝对路径。这个约束用于保证后端原位替换不迁移数据，但 path 解析、production/automation identity、目录创建和 Application wiring 均不属于本次 DAG。

本阶段不打开现有 Workbench 目录，不删除其 OS exclusive lock，也不声称 SQLite/WAL 自带应用单实例保证。未来 Product 数据迁入 SQL 时，single-instance 或 schema-level multi-process concurrency 必须由对应整体方案明确认领。

## 9. Native SDK 原位替换

Native SDK adapter 进入正式路径前必须同时满足：

1. 有公开、稳定、有界的 Zig row/value decoder；
2. 能打开 canonical runner data directory 下同一个 `app.db`；
3. 支持同一 Value、limits、read-only query、`BEGIN IMMEDIATE` exec 和 migration 语义；
4. 使用相同 `WAL`、`synchronous`、foreign key、busy timeout 和 query-only profile，或经产品明确批准变更；
5. 对 constraint、busy、I/O、corrupt、misuse 和 rejected 的映射通过 conformance tests；
6. 已使用的 SQLite SQL/features 与 SDK 内置 SQLite 版本和 compile options 兼容；
7. direct backend 完全关闭后 SDK 才打开文件；
8. 启用 `app.zon` 的 Native SDK `sqlite` capability 与删除直接 SQLite amalgamation build dependency 必须在同一个可构建变更内完成，任何正式构建不得同时链接两份提供 `sqlite3_*` symbol 的 engine。

切换步骤只有：

```text
release N: direct backend closes app.db normally
release N+1: Native SDK backend opens the same app.db
             → schema version check
             → quick/integrity validation required by rollout
             → normal startup
```

不生成新数据库，不复制表，不重写 schema，不双写，也不保留运行时 fallback。SQLite 文件、`-wal` 和 `-shm` 必须由前一后端正常关闭/恢复；切换测试覆盖未 checkpoint WAL、干净关闭、应用崩溃后重启和 newer schema rejection。

这属于后端原位替换，不是用户数据迁移。若 Native SDK 无法满足任一条件，MetaWork 继续使用直接 SQLite 后端；SQL 基础能力本身不被阻塞。

## 10. 实施 DAG 与提交边界

### A. Contract 与 conformance harness（已完成）

- 添加 `storage` module、SQL types、limits、borrowed lifetime 和 outcomes；
- 建立后端共享 conformance harness；
- 使用最小 test backend 验证调用合同，不接 Product。

完成后评估一次提交：合同、测试和 build graph 必须共同形成可编译、可评审的边界，不为单个类型或文件拆微提交。

### B. Direct SQLite backend（已完成）

- 锁定官方 SQLite dependency；
- 实现 open/migrate/query/exec/close 与 engine profile；
- 用真实 file/memory database 跑完整 conformance、read-only-in-exec rejection、单连接 memory visibility、rollback、reopen 和 corruption/error mapping tests。

完成后评估一次提交：dependency、backend 和命中其失败模式的测试应在同一提交，不留下只有依赖或只有半个 backend 的状态。

### C. Storage module 收口（已完成）

- 把直接 backend 和 SQLite C API 限定在 `src/storage/sqlite.zig`；
- 更新 project tree、validation 与 architecture guard，禁止上层直接导入 concrete backend 或 SQLite；
- 确认正式应用 module graph 尚未 open database、未接 Product、未声明 Native SDK sqlite capability。

完成后评估一次提交：模块边界、source of truth 和 guard 作为一个 owner slice 收口；如果与 B 高度耦合则合并进 B，不制造纯文档碎片提交。

### D. Storage foundation verification（已完成当前平台自动化）

- 正式 Native test graph；
- architecture guard、format 和 `git diff --check`；
- Windows 当前平台 temporary file database 验证；
- macOS 构建与真实平台测试在出现独立平台失败模式或进入正式 Product 接入前执行；Windows 结果不替代目标平台证据；
- 确认 Workbench persistence 与现有 lock 未改变。

验证修正并入引入问题的最近一个 coherent commit；不创建“修测试”碎片提交。只有独立根因才新增提交。

Native SDK adapter replacement 是未来独立 DAG，不属于本次实现。

## 11. 验收标准

- Product 只能看到 MetaWork Storage types，看不到 SQLite/Native SDK 类型；
- query 与 exec 均使用参数绑定，动态值不拼 SQL；
- migration 连续、append-only、原子，newer schema fail closed；
- exec 任一 statement 失败后无部分写入；
- exec 遇到 read-only 或产生 row 的 statement 时返回 `misuse` 并完整回滚；
- reader 无法写入，普通 exec 无法绕过受保护操作；
- 内存 target 的 query 能看到同一 instance 中 exec 写入的数据，不因错误双连接而隔离；
- UTF-8、finite real、NUL、params、SQL 和结果上限全部 fail closed；
- callback borrowed lifetime 无逃逸；
- reopen 后数据与 `user_version` 保持；
- Storage 只使用测试显式提供的 temporary path 或内存 target，不创建 production `app.db`；
- concurrent/busy、constraint、I/O 和 corrupt 不被折叠；
- 现有 Workbench store、exclusive lock、恢复和 mutation fence 行为零变化；
- 文档与 guard 明确 direct backend 的唯一位置、边界和未来删除条件。

## 12. 收敛结论

- SQLite 是 MetaWork 的长期基础能力，不是 Native SDK capability 的附属品；
- 当前先在 Storage 模块内以直接 SQLite 后端完整交付，不再被 SDK decoder 缺口阻塞；
- Storage 只拥有无业务 SQL 机制，Product owner 继续拥有 schema 与持久化语义；
- 本次不接 Application 或任何 Product；未来正式 `app.db`、schema 和数据保持稳定，Native SDK 只做后端原位替换；
- 两个后端对齐同一 engine profile 和 conformance contract，因此正常切换不迁移用户数据；
- 本次仍不迁移 Workbench、不删除旧 store、不改变现有锁和恢复合同。

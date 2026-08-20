# MetaWork SQL 基础存储能力方案

> 状态：提案，尚未实施
> 日期：2026-08-20

本文只定义 MetaWork 接入 Native SDK relational SQLite 的无业务基础能力。它不迁移任何现有产品数据，不定义 Workspace、Task、Run、Conversation 或 checkpoint schema，也不替换当前 `workbench-history.store`。

在本方案落实到现行 source of truth 前，[高层架构](architecture.md)、[Product 内部架构](product-architecture.md)和[工程结构与所有权](project-structure.md)仍是当前有效规范。本文件不授权修改或丢弃任何已持久化数据。

## 1. 决策

新增一个小型、MetaWork-owned 的 `Storage` 模块，为 Product owner 提供同步、有界、无业务语义的 SQL capability：

```text
Native SDK relational SQLite
        ↓ Runtime binding
Application mechanical adapter
        ↓
MetaWork Storage SQL contract
        ↓
future Product owner
```

Storage 不是持久化业务 owner，不拥有 schema、migration 内容、产品 health、恢复、重试、checkpoint、数据迁移或进程单实例 policy。

## 2. 目标

首版只完成：

1. 通过 Native SDK 正式 Runtime API 接入 engine-owned `app.db`；
2. 提供 parameterized query 与多 statement 单事务 exec；
3. 提供 MetaWork-owned SQL value、statement、typed borrowed row、limits 和 outcome；
4. 隔离 Native SDK 类型与 encoded page，不把底层 wire dialect 传播到 Product；
5. 明确 binding 生命周期、production/automation namespace 和实际 durability 边界；
6. 用隔离测试证明真实 Native SDK binding 到 Storage contract 的映射。

## 3. 非目标

当前阶段不做：

- Workbench history schema、SQL 或迁移；
- checkpoint metadata、blob 对账或孤儿清理；
- 替换或删除 `workbench-history.store`、frame、checksum、atomic replace 或现有 locks；
- 全局 writer lease、应用单实例或只读第二实例；
- product-level corruption health、mutation fence 或 crash recovery；
- ORM、query builder、Repository、全局 `StorageManager`；
- key-value、blob、credential、远程同步、多数据库或跨 owner transaction；
- 通用 transaction marker、自动重试或结果对账表。

未来任何产品数据采用 SQL，都必须单独定义 owner schema、持久性要求、并发/排他、失败恢复和数据迁移；不得把本基础模块的存在视为迁移批准。

## 4. Owner 与依赖

依赖规则：

- `storage` 不导入 Workbench、Account、Agent、Bridge、Renderer、Application 或 Native SDK；
- `storage` 公共合同不暴露 Native SDK 类型、数据库路径、连接或 encoded page；
- `app/storage.zig` 可以同时导入 Native SDK 与 `storage`，但只做 limits、value、statement、row 和 outcome 的机械映射；
- Application 只取得 binding、构造 capability 并控制其生命周期，不持有 schema、SQL 或产品状态；
- Product owner 未来只导入 `storage`，不得导入 `app/storage.zig` 或 Native SDK relational 类型。

## 5. 最小模块

```text
src/storage.zig      # module root
src/storage/sql.zig  # SQL contract 与基础类型
src/app/storage.zig  # Native SDK binding adapter
```

不为了未来消费者预建 repository、schema registry、migration facade、health manager 或统一 store registry。首版只有一个 `Database` capability。

## 6. SQL contract

### 6.1 Value 与 Statement

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
```

动态值必须通过 params 传递。Storage 不提供字符串拼接 helper，也不解释表名、列名或业务标识。

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

    /// 全部 statements 在一个 Native SDK SQLite transaction 中执行。
    pub fn exec(
        self: Database,
        statements: []const Statement,
    ) ExecOutcome;
};
```

Storage 不提供 open、close、path、PRAGMA 或 migrate。Native SDK/Application 拥有物理数据库与 binding 生命周期。

### 6.3 Row 与 borrowed lifetime

```zig
pub const Row = struct {
    pub fn columnCount(self: Row) usize;
    pub fn columnName(self: Row, index: usize) []const u8;
    pub fn value(self: Row, index: usize) Value;
};
```

- `Row`、column name、TEXT 和 BLOB 只在同步 receiver 调用内有效；
- receiver 外需要保留的数据由调用方深拷贝；
- receiver 不得保存 row、page、slice 或 adapter context；
- adapter 必须先完整验证 Native SDK page，再逐 row 同步投递；malformed page fail closed，不投递部分 page；
- 大结果由调用方显式使用 `LIMIT` 和 keyset pagination，Storage 不隐式查询、分页或缓存。

### 6.4 Outcome

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

这些值只表达 Native SDK relational 调用结果，不定义产品 health 或恢复动作。adapter 不把失败折叠为 bool，不重试，不把失败查询解释为空结果，也不把失败 exec 解释为成功。

Native SDK relational binding 当前不会从同步 query/exec 产生 `cancelled`。adapter 对未来或不符合正式 engine contract 的意外 outcome 必须 fail closed；若上游正式扩展可达 outcome，Storage 合同应同步精确演进。

### 6.5 Limits

Storage 固定并测试当前依赖可观察的限制：

- SQL 文本：64 KiB；
- 单 statement params：64；
- 单 exec statements：64；
- 单参数 TEXT/BLOB：1 MiB；
- 单 exec 参数累计：8 MiB；
- 单 page：256 rows、256 KiB；
- 单 query 累计：8K rows、8 MiB。

adapter 在调用 Native SDK 前执行等价验证。Storage 不声明更高容量，不截断输入或结果，也不把 limit failure 伪装成底层 I/O failure。

## 7. Native SDK 接入

### 7.1 Build 与 Runtime

完成前置 Gate 后：

1. `app.zon` 声明 `sqlite` capability；
2. build 使用 Native SDK 正式 relational/migration 生成链，不直接链接 SQLite；
3. Native SDK runner 根据 Application identity 打开 engine-owned `app.db`；
4. `App.start` 从 `native_sdk.Runtime` 的正式 relational surface 取得 binding；
5. `app/storage.zig` 构造 `storage.Database`；
6. binding 缺失、database open 或 migration 失败均在 capability 可用前 fail closed。

当前阶段没有业务 consumer，不创建空 schema migration，也不为证明接线写测试专用产品表。真实 adapter 测试使用 Native SDK in-memory relational database 和 test-only migration/fixture。

### 7.2 Zig row decoder Gate

当前 Native SDK query callback 返回 encoded page，只公开结构校验，没有公开 Zig row/value decoder。MetaWork 不复制内部 page dialect。

正式实现 query adapter 前，Native SDK 必须提供稳定的公开 Zig 解码表面，例如：

```zig
native_sdk.relational_store.PageReader
native_sdk.relational_store.Row
native_sdk.relational_store.ColumnValue
```

decoder 必须有界、拒绝 malformed/trailing bytes、验证 UTF-8 与 finite REAL，并明确所有 borrowed slice lifetime。没有该公开能力时，不以私有 parser、JSON 包装、Product 消费 encoded bytes 或只实现 exec 的半套接口绕过。

2026-08-20 已核查当前锁定的 Native SDK 0.9.2 和 npm 正式发布的 0.9.5：两者均只有 `validEncodedPage`，没有公开 Zig row decoder。因此当前 Gate 未通过。

### 7.3 Durability 事实

Native SDK 0.9.2 与 0.9.5 的 durable relational database 均固定使用 WAL + `synchronous=NORMAL`。Storage 首版如实记录该事实，不宣称 `exec ok` 能在 OS crash/断电后保留最近事务，也不自行执行 PRAGMA 改变 SDK-owned connection。

这不阻塞无业务 SQL capability，但任何 durable 产品数据接入前必须决定该语义是否满足产品要求；若要求 power-loss durable commit，则需先取得 Native SDK WAL + `FULL` 或等价、可验证的 profile。参考 [SQLite PRAGMA synchronous](https://www.sqlite.org/pragma.html#pragma_synchronous)。

## 8. Lifecycle 与 namespace

relational binding 只在 Native SDK Runtime 生命周期内有效：

```text
Native SDK 打开 app.db
→ 创建 Runtime
→ App.start 取得 binding 并构造 Storage.Database
→ Application/未来 owner 同步使用
→ App.stop 断开所有引用
→ Native SDK 销毁 Runtime 与 app.db
```

Storage 不建立第二套 lifecycle state machine。测试必须证明 callback 不逃逸、`App.stop` 后不调用 capability、Application 不复制或延长底层连接生命周期。

Application 使用 `app.zon` identity 作为正式 Native SDK runner identity；`-Dautomation=true` artifact 使用从它单向派生的 `.automation` runner identity。这样 SDK-owned `app.db`、window state 与 log namespace 即使脱离 harness 启动也不会命中 production。真实 automation harness 仍额外隔离 `HOME`/`APPDATA`/`LOCALAPPDATA`，不能用 harness 环境替代 artifact 自身的 identity 隔离。

本阶段不统一现有 MetaWork file roots，也不引入 writer lease；只要求相同 profile 稳定命中相同 `app.db`，不同 profile 必须物理隔离。

## 9. 实施顺序

1. 取得 Native SDK 公开 Zig row decoder；
2. 验证 production/automation runner identity 派生与物理隔离；
3. 添加 `storage` module 与 build graph；
4. 实现 SQL contract、limits 和 fake-binding 单元测试；
5. 实现 Native SDK adapter 与真实 in-memory relational 测试；
6. 启用 `app.zon` `sqlite` capability，并验证 Runtime binding lifecycle；
7. 更新 architecture、project structure 和 validation 中的基础 capability 边界。

步骤 1、2 是启用正式 capability 的 Gate。不得先提交私有 decoder、共用 production database 或 exec-only 半成品。

## 10. 验证

- Storage unit：value/statement、preflight limits、borrowed row lifetime、receiver 顺序、outcome 不丢失；
- decoder fixture：null/integer/finite real/text/blob、多 page、边界容量以及 malformed/trailing/invalid UTF-8 拒绝；
- Application adapter：真实 Native SDK in-memory query/exec、参数映射、statement transaction rollback；
- lifecycle：binding 在 `App.start` 已安装，`App.stop` 后无调用或 callback；
- namespace：production 与 automation 解析到不同 engine-owned `app.db`，同 profile 稳定；
- build guard：`app.zon` capability、module graph、禁止直接 SQLite dependency 和私有 page parser；
- 正式 Native test graph：当前平台最小充分验证。

本阶段不运行 Workbench history、checkpoint migration 或数据兼容测试，因为没有改变这些路径。

## 11. 收敛结论

- 当前只接入无业务 SQL 基础能力；
- Storage API 只有 parameterized query、transactional exec、typed borrowed row、limits 和精确 outcome；
- Native SDK 拥有 SQLite engine、`app.db`、connection、PRAGMA、migration 执行和物理生命周期；
- Application 只做 binding 的机械适配与生命周期控制；
- 不迁移 Workbench，不删除旧 store，不新增 writer lease，不决定产品 durability/corruption policy；
- production/automation runner identity 已在 Application 基础接线中独立收口；公开 Zig decoder 是启用完整 query capability 前剩余的上游 Gate；
- 未来产品持久化必须另立方案，基于真实业务不变量决定 schema、single-writer、durability、corruption、checkpoint 和数据迁移。

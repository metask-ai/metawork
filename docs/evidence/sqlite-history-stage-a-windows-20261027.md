# SQLite history：A 阶段隔离验证结果

> 日期：2026-10-27。结论：A 已执行，发现容量/额度与尾延迟不满足直接接入的假设；停止在 A，不进入 B–E，不切换用户数据。

这是一份一次性测量记录，不是规范或生产验收。方案见 [SQLite 接入方案](../plans/sqlite-history-integration.md)；[原始采样、输入/二进制 SHA-256、环境和统计](sqlite-history-stage-a-windows-20261027.json) 是数字依据。

探针已单独提交为 `d787c64cbec9a04294a084bdbd5a1f230736f517`。采样输入中的 runner hash 对应该提交；采样后仅修正 runner 的 JSON 输出为 LF，并等价转换本证据文件的换行，未修改任何采样数据。ReleaseFast/Debug 探针断言、原始数据一致性检查和 `zig build test-storage -Doptimize=ReleaseFast -p .zig-cache/sqlite-history-a/storage-check` 均通过；这不改变下列业务 Gate 未通过的结论。

## 范围与复现

- 产品/方案基线 `43e2c0a1562d32d5a5a1e0e323a93e6d5d3386d6`，分支 `feat/sqlite-storage`。测量时工作树含此前已有的容量/写放大材料；本轮未修改它们的内容，也未运行其旧入口。新 probe 和 build 接线的输入 hash 均在原始证据中。
- Windows 10.0.19045，12th Gen Intel(R) Core(TM) i7-12700KF，20 个逻辑 CPU，内存 32604 MiB；Defender 服务、杀毒和实时防护均开启。Zig 0.16.0，native x86_64-windows-msvc；ReleaseFast、Debug 分开执行，不并行测量。
- SQLite 来自 build.zig.zon 的固定 canonical 输入；3.53.4，THREADSAFE=2，并复用现有编译选项。没有使用系统 SQLite、Python SQLite、源码副本、自定义 VFS 或生产 profile。
- 每种配置 3 个独立进程；每种提交轨迹每进程 31 个样本，共 93 个。分位数使用 nearest-rank，因此此样本量的 P99 恰好等于 max，不能当成长期分布保证。未剔除冷启动点；各场景按固定顺序执行，单组的两条轨迹实际上等价，不能据微小差异推断优化。
- 原始日志和合成数据库在 JSON 指定的 .zig-cache 隔离目录，均非用户数据；仓库保存可复现源码和结构化原始采样，不保存实验 DB。

```powershell
zig build build-sqlite-history-a-probes -Doptimize=ReleaseFast -p .zig-cache/sqlite-history-a/release
zig build build-sqlite-history-a-probes -Doptimize=Debug -p .zig-cache/sqlite-history-a/debug
python -X utf8 scripts/measure-sqlite-history-a.py --modes release debug --repetitions 3 --output docs/evidence/sqlite-history-stage-a-windows-20261027.json
```

## 1. 容量与峰值

调用现有 validateCandidate、restoreTask、Runtime 和真实释放路径，使用隔离的候选数量/正文预算；未改 production limits。每个 Task 附 8 条审批和 16 条 Compact，恢复出的所有 Run.execution 均为 null；退出跟踪分配和投影计数归零。100×256 的创建/继续执行、累计审批解除和真实 loader 不在这个样本中。

| 样本 | 计入原投影计数 MiB | Runtime 实际请求 MiB | Release 峰值 private MiB | Debug 峰值 private MiB |
| --- | ---: | ---: | ---: | ---: |
| 100×256，4 KiB 正文、无 Tool | 100.93 | 167.31 | 219.21 | 221.52 |
| 100×256，1 KiB 正文、2 个 Tool 各 1 KiB | 76.52 | 363.21 | 425.25 | 427.56 |
| 1×256，4 KiB 正文、32 个 Tool 各 4 KiB | 33.11 | 69.02 | 95.64 | 97.95 |

峰值列包含输入 fixture、Runtime、一次实际 7 MiB 冻结值，以及现有 backend 的绑定副本和 SQLite C 分配；Windows peak private 观察到了不经过 Zig allocator 的分配。该重叠样本使用 memory DB，**不是未来最大冻结批次 + 文件 WAL + 真实 SQL loader 的最终峰值**。输入 fixture 共享正文切片，真实 loader 的独立解码副本会不同；没有排空 OS 文件缓存，不声称冷磁盘启动。

主要解释有源码依据：restoreTool 在没有 file_refs 时也按 max_file_refs_per_tool 分配 32 个可空引用槽。当前 FileReferenceView 为 128 B，可空布局还需额外空间；51,200 个 Tool 的这部分预留已在分配跟踪中计入。RunRecord 为 2,608 B，独立 RunExecution 为 616 B；首版精简 Run 之外，附属集合仍有容量成本。不能把 projection_charged_bytes 当全部历史内存。

累计审批也不能直接沿用旧内存布局扩容：当前 UiRecord 为 1,920 B。按结构大小推导，25,600 轮各 1/10 条决定，仅记录本体分别约 46.88/468.75 MiB；这是**结构估算，不是尚未实现的累计审批 Runtime 实测**。当前样本只保留每 Task 8 条，不能据它宣布未来完整审批历史能落在 256 MiB 内。

**决策**：256 MiB 暂不作为可发布的全历史/总进程峰值承诺。D 前至少按实际数量恢复 Tool 引用、审查累计 UiRecord 的内联预留，并把历史拥有的正文、记录、附属数组和跟踪元数据统一计量；再用最终 loader/容器复测。只做这几处有测量依据的精简，不因此引入按需加载系统；也不直接把全局配额调大来宣布通过。

## 2. SQL 单元、值和查询边界

| 已执行的反例/测试 | 结果 | 意义 |
| --- | --- | --- |
| 按现有字段/数量上限生成并通过 wire 校验及真实 restore 的 32 Tool + 256 File Change | 实际 Runtime 请求 78,118,360 B；正文计数 77,860,584 B | 在候选 256 MiB 内合法；不声称当前 1.5 MiB live admission 会接纳 |
| 一个 Tool 的 32 个 File Reference 采用现有 typed JSON | file_refs_json 7,870,209 B；加 name/input/progress/content 后绑定文本至少 8,918,785 B | 已超过 8 MiB 参数额度；单行还含其他字段，不能拿“每字段有界”证明 engine LENGTH 足够 |
| 同类 32 个 Tool 的上述绑定合计 | 至少 285,401,120 B | 是闭包估算；**不是** 32 个独立 dirty Tool 必须构成一个事务的证据，不据此拍 512 MiB 批次 |
| 256 个 File Change 编成一个 JSON 参数 | 12,633,467 B | naive bulk JSON 也不能直接放进 8 MiB；逐行写则仅 Tool + File Change 就有 288 条 |
| 现有 public backend 接收 65 statements | rejected | 64 上限真实生效，未改 Gate |
| canonical engine LENGTH=8 MiB，写 7 MiB/8 MiB/8 MiB+1 zeroblob | 7 MiB 成功；后两者 SQLITE_TOOBIG | 行头也占长度，不能认为 8 MiB payload 在 8 MiB LENGTH 下可存 |
| 256 行 × 4 KiB 的 bounded query | ok，1,048,576 B | Release 约 0.62–0.68 ms，Debug 约 0.95–1.09 ms；只是合成行扫描 |
| 同一表全量 query | resource_exhausted，已回调 2,047 行/8,384,512 B | 必须丢弃 provisional 结果；最终 loader 需要有界分页 |

该反例用合法 UTF-8 控制字符观察 JSON 的六倍展开，不是普通正文的典型值。最坏值与典型延迟分别报告。旧格式保留 payload 可能接近 16 MiB，现有 8 MiB 值/结果额度同样不能未经设计就拒收它。

T01–T23 的 A 结论按保存形态归组：T01–T06/T09/T21 是具体 header、receipt、消息的有限变化；T07 命中上述单 Tool 反例；T08 命中 File Change 计数/JSON反例；T10–T12 是小决定/ModelRef（本次提交轨迹代表，不冒充最终业务 builder）；T13–T17 的 coverage 必须用集合 UPDATE 与 checkpoint 元数据共同保存，不能展开全部历史；T18 新建父链必须共同提交；T19 按子表集合删除；T20 仍为外部文件两阶段；T22/T23 的积压必须按完整独立组分批。此处是**形态与反例盘点，不是最终 schema 下 23 条最大原子组均已获证**；current quota 已被反例否证，按 A 的停止条件先停，不提前实现完整 builder 来凑证明。

**决策**：当前 64/8 MiB 不能原样进入 C。B 开始前需要明确一个最大原子组的实际参数布局：保留 Tool 的 typed JSON 并小幅提高有据的有限额度，还是按实际引用拆出必要行；比较该局部选择即可，不另建通用事务/分片框架。64 statements 是否需改、engine/参数/结果各需多少，由选定表达和最大组 fixture 决定；本次未改变常量，也没有实测一个更高额度后把它定为产品值。

## 3. 同步提交、合批和 I/O

使用现有 public Database 的正常 mutate 路径，WAL + synchronous=FULL，默认自动 checkpoint 不禁用。每个独立普通组含 Task 已读位置、4 KiB Run payload、审批决定 3 个变化；每批另有 1 个去重 root witness，因此最多 21 组合成 64 statements。数据库预置 100 Task × 256 Run，文件 118,022,144 B；这是带实际历史规模的代表性 SQL 工作负载，表/整数主键不是最终产品 schema。测量范围从组装本次 mutations 到整轮 mutate 完成；尚无真实 dirty selector/冻结 writer，不能把数值称作完整 Host 路径。公开 backend 仍是当前 profile，尚未新增 production secure_delete 设置；安全清理另由 ON 配置的原语样本验证，不能认为已测完未来生产安全 profile 的全部提交成本。

| 配置 | dirty 组 | 合并 | COMMIT 数 | P50 ms | P99/max ms | 每轮进程写入 P50 B |
| --- | ---: | --- | ---: | ---: | ---: | ---: |
| release | 1 | 否 | 1 | 1.968 | 4.004 | 16,480 |
| release | 1 | 是 | 1 | 1.952 | 2.979 | 16,480 |
| release | 10 | 否 | 10 | 20.456 | 29.816 | 164,800 |
| release | 10 | 是 | 1 | 1.948 | 3.006 | 53,560 |
| release | 100 | 否 | 100 | 210.833 | 307.916 | 1,648,000 |
| release | 100 | 是 | 5 | 13.896 | 21.981 | 473,800 |
| debug | 1 | 否 | 1 | 2.887 | 6.084 | 16,480 |
| debug | 1 | 是 | 1 | 2.897 | 3.132 | 16,480 |
| debug | 10 | 否 | 10 | 24.935 | 31.067 | 164,800 |
| debug | 10 | 是 | 1 | 2.947 | 4.843 | 53,560 |
| debug | 100 | 否 | 100 | 258.745 | 322.985 | 1,648,000 |
| debug | 100 | 是 | 5 | 15.738 | 28.791 | 473,800 |

进程 I/O 来自 GetProcessIoCounters，统计真实 transfer bytes/operations，包含触发的自动 checkpoint，**不是物理 NAND 写入，也没有把 COMMIT 数伪称为实测 fsync 次数**。10 次需要逐次确认的审批不能跨工具执行合并：上述小组轨迹的 10 次确认 Release 中位约 20.46 ms、最大 29.82 ms，进程写入中位 164,800 B；这不是完整 Run 含所有 tool result/标题/checkpoint 的 I/O，也未做每小时压力外推。审批期间积压、写失败恢复、首次凭据清洗、normalization 在本 probe 中复用相同 pending 组 SQL 轨迹，**未在四个真实业务入口分别制造故障**。

**决策**：完整独立组合并有效，不需要撤回同步必须确认语义。但一次排空 100 组即使合批仍超过 16 ms，不能声称普通主线程调用可同步清掉任意积压。10 个小组/一次提交的样本可作为后续有界补写的候选，不能直接升为生产预算；最大合法大值、真实冻结、自动 checkpoint 及 Windows UI/event pump 仍须复核。C 前只评审具体补写入口的有限工作与既有 worker 复用，不把所有调用方改成异步框架；既有性能 Gate 不变。

## 4. SQLite 窄能力可行性

| 实验 | 已观察到的结果 | 仍不能证明 |
| --- | --- | --- |
| 现有 backend 的 lost-ack hook | COMMIT 后返回 outcome_unknown；后续写 unavailable | 全部 IO 错误/rollback 分支已被本次重测 |
| 同引擎子进程 FULL 提交 witness=777 后 TerminateProcess，不执行析构 | 正常进程能读到 777；有旧 reader 时 TRUNCATE 返回 BUSY，WAL 非空，必须保持 unknown | 读到即 durable、掉电完整性、可直接重放 effect |
| reader 退出后 TRUNCATE 并重读 | rc=OK、log=done=0、WAL=0、witness 仍为 777 | 生产 owner/lifecycle API 已存在 |
| 从建库开始 secure_delete=ON；DB 与旧 WAL 均实际命中合成值；更新后持有旧 reader | 清理 BUSY 不能宣称成功；释放 reader、TRUNCATE、关闭后 DB/WAL/SHM 无该明文 | JSON 转义/多字段/opaque/迁移证据的全部清理，或存储设备安全擦除 |
| 全部连接关闭、WAL 结算后 MoveFileEx WRITE_THROUGH 发布 | 重开 witness 正确，integrity_check=ok | 任意中间点强杀/掉电、multi-file quarantine、其他平台 |

Release 的 3 次成功同步 checkpoint 为 5.346, 5.505, 4.859 ms；合成凭据清理的最后一次 checkpoint 为 6.764, 6.054, 7.284 ms。含 reader 的 BUSY 路径在两个配置约 346–360 ms；busy_timeout=250 ms 不是主线程墙钟的硬上限。发布 rename 本身约 0.32–0.56 ms，不含前面建库/校验/checkpoint。

原语通过 C 探针调用，未加进 public Database，也未开放 Product raw SQL/PRAGMA。官方语义依据：[checkpoint_v2](https://sqlite.org/c3ref/wal_checkpoint_v2.html)、[WAL](https://sqlite.org/wal.html)、[secure_delete](https://sqlite.org/pragma.html#pragma_secure_delete)。这些实验支持 B 实现窄的确认/维护能力，并不支持 C 直接接入。

凭据异步 owner 还有独立缺口：当前 learnProjectionCredential/retireProjectionCredential 是 void/no-fail 的借用切片回调，现状只有同步内存清洗，没有证明可在回调前预留一次磁盘维护所需的有界 owned lease。A 未引入 secret cache 或异步清洗。B 安全验证必须先闭合这项所有权；不能把本次 synthetic SQLite 明文消失当成产品凭据生命周期已安全。

## 5. 链接体积估计与后续决定

| 配置 | tiny main 无 backend B | tiny main 使用 backend B | 增量 B |
| --- | ---: | ---: | ---: |
| release | 1,247,232 | 2,414,080 | 1,166,848 |
| debug | 2,465,792 | 10,545,664 | 8,079,872 |

Release 增量 1,166,848 B（约 1.11 MiB），包含可达的 Storage backend 和 SQLite，不是 sqlite3.c 的独立净重，也不是最终 MetaWork 主包/安装器增量；同一 tiny main 的有/无分支以编译期选项区分，未压缩，PDB 不计入 EXE。E 才做实际产品包体积 Gate。

本轮到此停止。SQLite 的所需原语有可行证据，整库重写没有必要回归；但现有 8 MiB 额度、256 MiB 的内存解释以及“同步一次清完全部积压”的假设均不能直接作为接入依据。后续若授权，只先收敛局部记录表达/有界额度、有限补写与 credential lease 的方案，再进入隔离 B；不自动推进 C/D，不关闭 #12/#25，不改变既有视图性能待办。

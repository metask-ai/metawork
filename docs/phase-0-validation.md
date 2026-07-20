# MetaWork Phase 0 验证计划

> 状态：Phase 0A Gate 0 至 Gate 7 已通过；Account Gate A1/B 已完成，Gate A2/C 等待外部合同
> 平台：Phase 0A macOS-first；Phase 0B 后续验证 Windows

Phase 0 用最小真实原型验证技术栈和关键风险，不交付完整产品。当前 AgentCore development bundle 使用 ABI v1 revision 2；这是精确开发基线，不是 stable support policy。同步 baseline 不包含 async suspend/resume、跨进程恢复、strict Workspace security、正式 Host tools、typed Output/FileChange/plan-progress 或 plan/custom UI control。

## 1. 里程碑定义

### 同步 macOS baseline

Gate -1 至 Gate 6 通过后，得到一个同进程 macOS 同步原型。它证明 UI、Bridge、AgentCore、built-in tools、同步审批、取消、事件泵和 shutdown 可以形成真实垂直链路。

### 完整 Phase 0A

同步原型之后还必须通过 Gate 7 fault-domain spike，并形成进程模型结论，才能称 Phase 0A 完成。

### 后续发布与能力演进

Account/Metask 登录集成、content-addressed cache、remote/empty-cache/offline 发布、stable ABI support policy、async resume、strict Workspace security、正式 Host tools 和 Windows Phase 0B 在 Phase 0A 同步验证之后推进。Account 集成不能削弱已经通过的 Gate 0–7。

## 2. 最小垂直链路

```text
React input
→ Native SDK Bridge
→ Zig Workbench
→ typed AgentCore bundle SDK
→ synchronous session_run
→ CoreEvent / synchronous UiRequest / RunResult
→ bounded Host event pump
→ Native SDK Bridge
→ React structured UI
```

模型 Provider SSE 必须止于 cc-zig。React 不接触原始 SSE，也不从终端字符推断 Agent 状态。

## 3. Gate 顺序

```text
Gate -1 specs
→ Gate 0 Native SDK smoke
→ Gate 1 artifact-only raw contract probe
→ Gate 2 Host lifecycle/security foundation
→ Gate 3 cc-zig typed SDK completion
→ Gate 4 formal AgentCore Host + bounded test sink
→ Gate 5 event pump/Bridge
→ Gate 6 in-process macOS prototype
→ Gate 7 fault-domain decision
```

Gate 未通过时不得用 source dependency、MetaWork 自制协议、无界队列或放宽安全语义绕过。

### Account integration DAG

```text
Account A contract/spec
→ Account B pure state machine
→ Account C platform/Metask integration
→ Account D App/Workbench integration
→ Account E Bridge/schema
→ Account F Renderer
→ Account G end-to-end validation
```

Account DAG 的唯一规范任务状态由 TinyKG root 160 管理；本文档只定义仓库内可复现的验收条件。每个子任务完成真实验证后必须进行 Linus review，合理修正到通过或无可采纳意见；只有形成独立、完整、可回滚边界时才创建本地 Conventional Commit。

#### Gate A1：本地合同与规范

- 产品、架构、工程目录和验证文档统一为五个产品 module responsibilities；
- 独立纯 `metawork_account_contract`，不导入 Native SDK、AgentCore 或产品 runtime；
- compile-time limits、Account 双状态、command sink、脱敏 view/fact、typed ExecutionTarget、owned secret transfer 和稳定 ErrorCode；
- production 配置不以环境变量、Renderer 或 Bridge 为合同来源；
- [Metask Account API 合同](metask-account-contract.md)明确记录外部确认状态。

#### Gate A2：外部合同确认

外部合同拆成两个独立门槛：

- C1 OAuth/login 已由 Metask 产品 owner 锁定：第一方 public client `metacode-cli`、`metacode:use`、固定 authority/endpoints、动态 IPv4 loopback callback 和 `/v1/profiles` identity。
- C2 API Key catalog schema 与 typed/fixed ExecutionTarget 仍需完成；它只阻塞目录、执行配置和 Task admission，不阻塞 C1。
- test endpoint 只能通过 test build module 显式注入；生产 build 不接受 endpoint/client/scope override。
- 不复制宽松 catalog 解析器，不根据模型名猜 provider。

#### Gate A1 退出证据

- Account contract 单元测试、architecture boundary test 和正式 Native build 通过；
- 所有 Renderer-facing view/result/snapshot 都无法承载 secret；
- owned execution transfer 的 live owner、move 和 secure-zero 释放路径有测试；
- 文档间没有“环境默认值”“Bridge credential”或“Account/Workbench runtime 互相导入”等冲突；
- Linus review 通过或没有需要采纳的建议。

#### Gate B：纯 Account 状态机

- 生产入口只能从 `restoring` 开始，不能绕过 credential restore 直接构造 signed-out；
- Account session、execution 与 operation 使用正交状态；attempt、catalog 和 execution generation 都有有界、fail-closed 的推进规则；
- command 和 worker completion 只生成 prepared transition，effect 先进入有界 worker queue，随后才执行 no-fail committed swap；
- matching 但非法的 completion 必须结束当前 attempt 并产生 typed failure，不能让状态永久停在 in-progress；
- 重配置失败保留旧 execution generation，OAuth refresh/reauth 失败不销毁仍可用的 committed execution；
- logout 必须先持久化 signed-out tombstone；只有 tombstone completion 成功后才提交内存 signed-out 并异步删除 retired credential generation；
- 每 attempt completion inbox 独占有界 MPSC queue 和 first-writer terminal mailbox；overflow、guaranteed wake failure、stale completion 和 shutdown 都有确定的 cleanup；
- RestoreReady 在校验失败时不能接管或泄漏 owned execution，所有 stale/rejected secret completion 在释放时 secure-zero。

Gate B 不等于 C1/C2 完成。C1 production OAuth client、profile decoder 和平台 credential store 由 Gate C1 验证；API Key/model decoder 与 ExecutionTarget 由 Gate C2 验证。

#### Gate C1：Metask OAuth 登录与账号生命周期

- 固定 authority/client/scope/redirect，PKCE S256 和 CSPRNG state/verifier；
- callback 只绑定动态 `127.0.0.1`，严格 request/query 上限，重复/unknown 参数 fail closed；
- token/profile strict decoder、response body 上限、HTTP status mapping 和固定 production origin；
- 单 attempt worker，cancel/deadline/shutdown 关闭 listener 并 join；
- Native SDK open URL 与 Keychain 操作只在主线程；
- OAuth A/B slot、marker-last、read-back、原子 account-only manifest、refresh rotation；
- logout 先提交 signed-out tombstone，credential cleanup failure 不复活账号；
- 登录成功停在 authenticated/account-only，ExecutionState none，Task admission 仍关闭。

#### Gate C2：执行目录与 ExecutionTarget

- 严格 API Key/model schema 和有界 catalog；
- typed/fixed provider、base URL、model 与 account/profile 归属；
- production origin/path allowlist，不从 Renderer、环境变量或模型名推断；
- 只有验证并提交 ExecutionConfig 后才打开 Workbench Task admission。

## 4. Gate -1：规范对齐

### 输入

- 当前 cc-zig bundle header、SDK、manifest 和 artifact-only consumer；
- MetaWork 产品、架构、集成和 ABI 文档。

### 验收

- 明确 development ABI identity、精确 bundle identity 与未来 stable support policy 的区别；
- 当前 v1 只声明同步能力；
- async pending/resume、持久化、strict Workspace security 和正式 Host tools 移入后续 capability；
- Renderer reload 与进程恢复明确分离；
- 现有 v1 不兼容变化必须换 ABI version，兼容增量必须用 capability；
- AGENTS、README 和所有 source of truth 无冲突。

## 5. Gate 0：Native SDK macOS React smoke

> 状态：已通过。实现与实测证据见 [Phase 0 Gate 0 验证报告](phase-0-gate-0-report.md)。

### 必须验证

- 固定 Native SDK 精确版本或 commit；
- React development server 加载；
- React production assets 加载；
- JavaScript → Zig command；
- 真实 Zig → React 传输方式；
- WebView/main thread 调用约束；
- command/result/event 最大 bytes；
- dev origin allowlist 与 release origin policy 分离；
- 文件/目录选择；
- 窗口创建、reload、close 和正常退出；
- Debug 与 Release macOS 构建。

### 禁止预设

- 不在验证前发明 `events.drain`；
- 不假定一定存在 native push API；
- 不让 Provider credential 进入 Bridge；
- 不先实现 AgentCore 或完整 Workbench UI。

### 退出证据

- 最小 React shell；
- dev/prod 可复现命令；
- 双向 Bridge trace；
- message size、线程和 origin policy 记录。

## 6. Gate 1：artifact-only raw contract probe

> 状态：已通过。实现与实测证据见 [Phase 0 Gate 1 验证报告](phase-0-gate-1-report.md)。

该 probe 是隔离依赖验收，不属于正式 Host。

### Bundle 校验

- 从显式绝对 bundle root 读取，不访问 cc-zig source tree；
- 校验 manifest schema、commit/build identity、ABI version、toolchain、target、architecture、deployment baseline 和 checksum；
- 校验静态库、C header、三个 Zig SDK 文件和系统链接输入；
- discovery symbol 存在；
- API table size/version/capability/function pointer 合法；
- target 缺失和 checksum mismatch 明确失败。

### source-free consumer

使用 Mock Provider 与临时 Workspace 验证：

- Runtime create/destroy；
- Session create/destroy；
- real synchronous Run；
- abort active Run；
- destroy busy、abort stale/too-late 和 invalid argument；
- tagged CoreEvent JSON callback；
- synchronous UI answered/unavailable/fatal；
- built-in Read、Bash、Edit；
- callback borrowed lifetime；
- Host/library-owned response/diagnostic release 恰好一次。

同一 probe executable 同时保留两条互补路径：raw ABI 部分直接使用 `wire.ApiV1`、`wire.SessionConfigV1` 和固定宽度 `*_code` 字段，证明 shipped binary facade；`verifyFormalHost()` 则通过 test-only `agent.Runtime.initWithApi()` 注入同一 function table，并使用 typed `SessionOpenOptions` 验证正式 Agent adapter。不得为了统一表面而删除 raw wire 覆盖，也不得让 formal adapter 继续使用已经淘汰的 raw option 字段。

可以额外验证 Host tool callback mechanics，但产品 Runtime 必须保持 `host_tool_count = 0`，不能用单 Session probe 证明多 Session Host tool 路由已成立。

### 退出证据

- probe 不进入正式 build target；
- 不复制 cc-zig source 或协议定义；
- 记录当前 raw SDK 缺失的 typed validators/codecs，作为 Gate 3 输入。

## 7. Gate 2：Host 生命周期与安全基础

测试可以注入 bundle `ApiV1` function table 的 deterministic fake；不得建立 `NativeSdkAdapter`、AgentCore Adapter 或新协议。

### 状态与 executor

- `Open.Idle / Open.Queued / Open.Running / Open.WaitingUi / Closing / Closed`；
- 每 Session 至多一个 in-flight Run；
- bounded executor，超过上限明确排队；
- queued Run 在 close 时取消且不进入 Core；
- UI wait 占用 executor slot但不阻塞 WebView/main thread。

### Close/shutdown

按固定顺序验证：

```text
reject new work
→ cancel queued Run
→ wake UI wait
→ set first-writer-wins TerminationSignal
→ abort active Run
→ join
→ callback refcount == 0
→ session_destroy
→ runtime_destroy after all Sessions
```

### Race matrix

- cancel vs natural completion；
- close idle/queued/running/waiting UI；
- callback fatal vs cancel；
- abort stale/too-late；
- double close/duplicate response；
- multi-Session Host shutdown；
- runtime destroy while busy；
- allocator OOM 与 diagnostic release。

### Credential/Workspace

- credential 仅从 Host environment/受控配置进入 Session config；
- Renderer、Bridge、event、log、snapshot 和测试 golden 不出现 key；
- Workbench canonical prompt、title、assistant、tool、UI 和 terminal diagnostic buffer 不保留 key；raw AgentCore tool ID 只形成不可逆 correlation digest；
- 当前只允许临时或明确 trusted Workspace；
- UI/文档不宣称 strict Workspace security。

### 当前实现与复现

Gate 2 基础实现当前位于 `src/agent/session.zig`，bounded executor 位于 `src/workbench/executor.zig`。生命周期验证入口位于 `tests/`，按 Agent、Workbench、Bridge/automation transport 和纵向竞态分组；它只从显式 `AGENTCORE_BUNDLE_ROOT` 导入 bundle SDK，并先按 `spikes/agentcore-contract/bundle.lock.json` 校验完整 manifest、checksum、平台、Zig 版本和 discovery symbol，不进入正式应用 build graph。

```bash
AGENTCORE_BUNDLE_ROOT=/absolute/path/to/validated/bundle \
  npm run test:lifecycle
```

需要同时执行仓库常规测试时使用同一个显式 bundle 环境运行 `npm run test:phase0a`；该命令不会在缺少 artifact 时静默跳过 Gate 2。正式 Native `test` step 必须显式构造并运行 App、Bridge、Workbench projection 和 Workbench executor test artifacts；named module 被产品 root import 不等于其 `test` declarations 已执行。

当前 deterministic function-table fake 覆盖 bounded executor、每 Session 单 Run、queued/active/UI-wait close、并发 close/shutdown、callback quiescence、generation-checked RunControl lease、close lease quiescence、pre-Core termination、first-writer typed TerminationSignal、immutable TerminalResult、stale/too-late abort status、Session/Runtime destroy retry、OOM、diagnostic release、credential snapshot 隔离和临时/trusted Workspace 的词法边界。测试进程有 30 秒上限，避免回归变成无限 CI hang。

这仍是 Gate 2 raw lifecycle foundation，不是正式 AgentCore Host：UI response 只验证 identity、唤醒和 close/shutdown 路径，固定返回 `UI_UNAVAILABLE`；事件和 UI JSON 不在 MetaWork 复制或解析。Gate 3 已在后续 clean bundle 上独立完成 typed SDK 验收。executor 容量仍尚未根据真实 trace 定标。

## 8. Gate 3：cc-zig typed SDK completion

> 状态：已通过。实现与实测证据见 [Phase 0 Gate 3 验证报告](phase-0-gate-3-report.md)。

正式 Host 开始前，bundle SDK 必须提供并测试：

- typed ABI function `Status` validation；
- typed `StopReason` validation；
- `CoreEvent` bytes/tag/payload decoder；
- `UiRequest` decoder；
- `UiResponse` encoder；
- null/length overflow、unknown code/tag、payload mismatch 错误；
- callback 参数名称和语义；
- callback threading、borrowed/owned/release 文档；
- source-free typed consumer；
- malformed/fuzz corpus 或等价的系统化负面测试。

MetaWork 不在本仓库复制类型或 JSON schema。Gate 3 consumer 只构造 bundle SDK 类型并调用其 validator/codec；未知和 malformed JSON 字面量仅作为负向输入，不构成协议实现。

当前 clean bundle 精确锁定在 metacodes `36637f314c0f1c41bb1a2267ced7ad6a46100003`（ABI v1 revision 2）。source-free consumer 位于 `spikes/agentcore-sdk-contract/`，可复现命令为：

```bash
AGENTCORE_BUNDLE_ROOT=/absolute/path/to/validated/bundle \
  npm run test:agentcore-sdk
```

`npm run test:phase0a` 使用同一个显式 bundle，依次重跑仓库测试、Gate 1 raw probe、Gate 2 lifecycle 和 Gate 3 typed SDK consumer；任何 artifact 缺失或 identity 漂移都会失败，不会跳过或回退源码。

revision 2 已提供 callback `RunContext` wire identity；Host tools 仍保持禁用，直到独立 capability Gate 定义产品工具、安全和路由政策。这不阻塞 built-in Read/Bash/Edit。

## 9. Gate 4：正式 AgentCore Host + bounded test sink

> 状态：已通过。实现与实测证据见 [Phase 0 Gate 4 验证报告](phase-0-gate-4-report.md)。

### 接入规则

- 直接使用 bundle typed SDK；
- 不增加 AgentCore Adapter 或镜像接口；
- Runtime/Session config 来自 Host 已校验状态；
- product `host_tool_count = 0`；
- callback 先校验再深拷贝；
- callback 只写 bounded test sink，不调用 WebView。

### ABI status 与 RunResult

- non-OK status：读取/release diagnostic，禁止读取 `RunResult`；
- OK status：SDK 校验 RunResult 与 StopReason；
- 六个 StopReason 使用无 `else` switch；
- unknown code 在 SDK 层失败并保留 raw code；
- `resource_limit` 与 admitted fatal Session poisoning 语义经过测试；
- `aborted` 结合 `TerminalResult.termination_signal` 由 Workbench 映射 cancelled/interrupted/failed。

### 同步 UI

- request 绑定 callback Session handle 与 current run ID；
- Renderer response 验证 Session、Run、request 和类型；
- stale/duplicate/mismatched response 拒绝；
- deadline 安全 deny/unavailable；
- cancel、close 和 shutdown 唤醒 wait；
- response owned buffer release 恰好一次；
- UI fatal 使 Run 退出，不 hang。

### callback failure

- validation/copy/test-sink capacity failure 返回 callback fatal；
- session_run 返回 non-OK callback status；
- typed TerminationSignal 保留具体 execution failure domain；
- 不误报用户取消，不读取 zeroed RunResult。

### 当前实现与复现

当前正式 Agent Runtime 实现位于 `src/agent/session.zig`，最小 FIFO bounded sink 位于 `src/agent/event_sink.zig`。deterministic fake 覆盖 lifecycle/typed callback/result/UI 测试；Gate 1 artifact-only probe 还会使用真实 bundle、Mock Provider 和正式 Agent Runtime 再跑同步 `AskUserQuestion`、typed event sink 与 terminal outcome。

```bash
AGENTCORE_BUNDLE_ROOT=/absolute/path/to/validated/bundle \
  npm run test:lifecycle

AGENTCORE_BUNDLE_ROOT=/absolute/path/to/validated/bundle \
  npm run probe:agentcore
```

Gate 4 通过时的 sink 只提供全局 event count 和单 event bytes 硬上限；当前实现已在 Gate 5 将它替换为有界 Event pump。历史 Gate 4 结论仍不得用来反推 Gate 5 已经通过，Gate 5 的独立证据见下节报告。

## 10. Gate 5：Event pump 与 Bridge

> 状态：已通过。容量输入见 [Gate 5 Event pump 容量测量与实现规格](phase-0-gate-5-measurement.md)，实现与实测证据见 [Phase 0 Gate 5 验证报告](phase-0-gate-5-report.md)。

### 容量维度

实施前根据 Gate 0 transport 数据和 Gate 4 AgentCore trace 固定：

- global count/bytes；
- per-Session count/bytes；
- max single event bytes；
- control reserved count/bytes；
- Bridge batch count/bytes/time；
- per-pump Session/event budget；
- detach retention count/bytes/time。

### 正确性

- callback 内 deep copy 后才返回；
- 同一 Session/Run 顺序稳定；
- 多 Session 公平轮转；
- `text_chunk` 无论是否合并都逐字节一致；当前 baseline 不在 pump 内合并。Workbench credential 清理必须覆盖跨 chunk credential、大量单字节 chunk、中间 snapshot 不发布未决 credential 前缀、terminal 后 drain barrier 提交普通尾部，并证明已提交 assistant 历史不会被后续 chunk 反复重扫；
- pump 不擅自折叠 `tool_progress` 或 `usage`，保持 bundle event 顺序和原始 bytes；Gate 6 的 Renderer projection 再按 SDK 语义覆盖或累计；
- tool/UI/run 控制事件不静默丢失；
- AgentCore/tool 线程不直接调用 WebView；
- control capacity 耗尽在 deadline 后 fatal，不无限阻塞。

### Renderer detach/reload

- Renderer transport failure 与 canonical event/projection failure 使用不同 typed path，不共享 Run cause；
- 有界 retention 内允许 Host snapshot/resync；
- 旧连接不能消费新连接事件；
- Gate 5 transport 保留 Session/Run identity、未 ack event 和 object，并拒绝旧 generation；Gate 6 完整链路再验证 reload 后 active UI request 的原 Session/Run/request；
- fetch/ACK 故障必须断开旧 generation 并重连，未 ACK 项在新 generation 重发，旧 batch 不得继续消费；
- 注入首次 reconnect 失败，验证 bounded backoff 后可建立新 generation；耗尽后必须进入显式 offline 状态；
- 注入 revision event 发送失败和 snapshot chunk 拉取失败，验证 pending revision 不丢失、重试合并到最新 revision，旧 snapshot identity 被拒绝；
- 注入 snapshot serializer 中途失败，验证此前 descriptor 已 stale，不能读取被部分覆盖的 store；
- 同时注入 revision emit 和 retry timer 失败，验证当前 generation fail closed；
- snapshot 自动重试预算耗尽后不得继续产生 Bridge 请求，恢复必须由新 generation 或用户显式操作触发；
- 以四个并发 pending UI request 计算 snapshot 最坏预算，并验证 512 KiB projection 可通过 8 MiB Host store 与 256 KiB 分块完整重建；
- snapshot 不包含 credential；
- Host/AgentCore crash 不伪装为 reload recovery。
- event delivery 失败前两阶段 batch 不 commit，断开后在新 generation 重发，不中止 Run；
- retention expiry 只释放 Bridge-owned transport copy，不改写 Workbench terminal history；
- shutdown 按 stop ingress → quiesce synchronous handlers → detach Workbench → deinit owned buffers 验证无 UAF/leak。

### 大 payload

只有真实 event/batch 超过 Native SDK 上限时才加入 object reference，并验证 opaque ID、Session/Run ownership、byte/count/TTL、fetch 校验和所有终止路径清理。

### Fatal 注入

- event decode/copy OOM；
- control queue deadline；
- canonical Workbench projection failure 按 Session/Run identity 请求 Agent 终止；
- TerminationSignal first-writer-wins，且不包含 Renderer transport；
- in-flight Run 被要求停止；
- 最终状态 failed，不误报 cancelled。

## 11. Gate 6：同进程 macOS 同步原型

### 依赖前置条件

当前产品基线迁移到 clean bundle `0.0.0-dev+36637f314c0f`、ABI v1 revision 2、112-byte API table。迁移只接受现行 manifest 和 SDK 表面，不保留旧格式、旧 revision 或旧协议兼容；bundle 先通过 manifest/checksum identity、artifact-only link/run、完整 typed SDK contract 和独立 clean consumer，再进入正式应用 build graph。历史 Gate 6 报告保留当时 `5fe198c` 的验收事实，本次迁移必须重新运行完整 Gate 6 macOS 链路。

本次迁移的完整复验命令、产物 hash 和边界见 [AgentCore ABI v1 revision 2 迁移验证报告](agentcore-revision-2-migration-report.md)。

### 最小 UI

- 自动化只打开受控临时 Workspace；产品 UI 由 Host 原生选择和原生确认签发一次性 trusted Workspace grant；
- 创建、切换和关闭 Session；
- 提交真实 Agent input；
- 流式文本；
- built-in Read/Bash/Edit tool cards；
- 同步 permission 或 question；
- stdout/stderr/exit code；
- stop/cancel；
- terminal Run state；
- WebView reload 后从存活 Host 恢复视图。

不要求完整视觉系统、数据库、async resume、strict Workspace security 或 Host tools。

### Workload matrix

不能用单一“10,000 events”冒充压力测试。矩阵至少覆盖：

| 维度         | 取值方向                                   |
| ------------ | ------------------------------------------ |
| Sessions     | 1、4、超过 executor slots                  |
| event rate   | 低、真实流式、高速 burst                   |
| event bytes  | 小 text、普通 tool、接近/超过 Bridge limit |
| duration     | 短 Run、持续 Run                           |
| UI waits     | 无、单个、全部 worker 同时等待             |
| Renderer     | 正常、slow、detach/reload                  |
| cancellation | provider stream、同步 wait、长 Bash        |

### 退出条件

- 无跨 Session 串台；
- 文本最终字节一致；
- executor/queue/Bridge 内存有界；
- UI main thread 保持响应；
- 全部 worker 等待 UI 时 response/cancel/shutdown 仍可执行；
- Session close 和 Host shutdown 无 hang/UAF/leak；
- reload 语义可信且不冒充进程恢复；
- release Native/Renderer 产物不包含 MetaWork 独有 automation command、origin、fixture payload 或 diagnostic token；Native SDK 自身共有的 product-runtime 字符串不作为 MetaWork 泄漏判据；
- Native automation scanner 自身的正反测试通过：SDK 共有 token 不误杀，任一 MetaWork fixture token 必须命中；
- 可复现的 build/test/run 命令进入仓库。

> 状态：已通过。可复现证据见 [Phase 0 Gate 6 验证报告](phase-0-gate-6-report.md)。

该状态首先记录历史 Gate 6 原型的验收事实。架构收口批次 A 至 D 已在 Apple Silicon macOS 使用仓库锁定 bundle 与本次 checkout 重新通过正式 Native test graph、Phase 0A formal adapter probe、release scanner、debug/release、macOS package 和 automation Gate 5/6；旧报告与旧 `zig-out` 产物仍不能替代本轮结果。

Gate 6 验收当时只能称“同进程 macOS 同步原型”；完成下述 Gate 7 后才达到完整 Phase 0A。

## 12. Gate 7：fault-domain spike

> 状态：已通过。实测数据、限制和进程模型决定见 [Phase 0 Gate 7 验证报告](phase-0-gate-7-report.md)。后续正式方向选择单 AgentCore Worker；当前应用仍是同进程 prototype。

故障注入必须放在独立测试进程，避免测试 runner 自身被 native crash 终止。

### 同进程 baseline

注入 AgentCore/tool panic、abort 或等价 fatal：

- Host 是否退出；
- 其他 Session 的影响；
- 已完成 Host snapshot 的可用边界；
- active Run 的最终可解释状态；
- 重启与人工恢复时间。

结果必须明确标记为零进程级隔离，不能美化。

### 最小 Worker harness

建立隔离、非产品化 spike，仅验证：

- Worker crash 时 Host 存活；
- 所属 Session 进入 failed/interrupted；
- 其他 Host UI 状态可用；
- 危险工具不自动重放；
- Worker 重启时间与资源成本；
- 最小 transport 的 message size、关联 ID 和断连语义。

不在此 Gate 建正式 Worker API、通用 IPC framework 或生产 supervisor。

### 决策输出

根据故障影响、恢复时间、资源、吞吐和复杂度：

- 接受同进程正式方向；
- 选择单 AgentCore Worker；
- 或列出缺失证据并继续验证。

没有数据不得默认单进程，也不得因为“IPC 更安全”直接建设复杂 Worker。

本 Gate 的结论是选择单 AgentCore Worker 作为后续正式故障域。该结论不冻结 spike IPC，不提供 Run 自动恢复，也不证明当前同进程应用已经具备隔离。

## 13. Phase 0A 完成判据

Phase 0A 完成时必须产出：

- 可运行的 macOS 同步垂直原型；
- Native SDK dev/prod/Bridge/size/origin 记录；
- cc-zig 精确 bundle identity、manifest 和 checksum；
- MetaWork artifact-only raw probe；
- cc-zig typed SDK source-free consumer；
- MetaWork typed SDK link/run 集成；
- Host lifecycle/race/diagnostic release 测试；
- event pump 容量、批量窗口、公平性和 workload matrix 数据；
- built-in Read/Bash/Edit、同步 permission 和 cancel 记录；
- 六个 StopReason 的 typed exhaustive mapping；
- Renderer reload 与进程恢复边界记录；
- 同进程与最小 Worker fault-domain 报告；
- 进程模型明确结论或有证据的继续验证决定；
- 仓库内可复现 build/test/run 命令；
- 更新后的 requirements、architecture、integration 和 ABI 文档。

原型“能跑起来”不是完成；内存边界、失败语义、shutdown 和 fault domain 必须有数据。

## 14. Phase 0A 当前非目标

- 完整产品视觉系统；
- `.native` Renderer；
- 通用 Desktop/AgentCore Adapter；
- 正式数据库和迁移体系；
- async pending/suspend/resume；
- Session/Conversation 跨进程恢复；
- strict Workspace security 认证；
- 产品 Host tools；
- content-addressed cache 和远程 artifact 服务；
- 正式 Worker IPC；
- 自动更新服务；
- 完整 IDE、PTY 或 Terminal Emulator；
- Windows 交付。

## 15. Phase 0B：Windows

macOS Phase 0A 完成后单独验证：

- Native SDK Windows WebView dev/prod；
- JS↔Zig Bridge；
- cc-zig Windows target bundle；
- hidden non-interactive shell、stdout/stderr、timeout 和 process tree；
- window lifecycle、file dialog 和正常退出；
- Debug/Release 构建与可复现分发包；
- 签名和更新路径；
- 与 macOS 相同语义 code/capability 的兼容性。

Windows 失败不反向否定已通过的 macOS baseline，但阻止项目宣称跨平台交付完成。

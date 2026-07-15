# MetaWork Phase 0 验证计划

> 状态：待执行；Gate 顺序已按 AgentCore ABI v1 同步能力收敛
> 平台：Phase 0A macOS-first；Phase 0B 后续验证 Windows

Phase 0 用最小真实原型验证技术栈和关键风险，不交付完整产品。当前 AgentCore bundle 是 experimental ABI revision 1，同步 baseline 不包含 async suspend/resume、跨进程恢复、strict Workspace security 或正式 Host tools。

## 1. 里程碑定义

### 同步 macOS baseline

Gate -1 至 Gate 6 通过后，得到一个同进程 macOS 同步原型。它证明 UI、Bridge、AgentCore、built-in tools、同步审批、取消、事件泵和 shutdown 可以形成真实垂直链路。

### 完整 Phase 0A

同步原型之后还必须通过 Gate 7 fault-domain spike，并形成进程模型结论，才能称 Phase 0A 完成。

### 后续发布与能力演进

content-addressed cache、remote/empty-cache/offline 发布、stable ABI support policy、async resume、strict Workspace security、正式 Host tools 和 Windows Phase 0B 在 Phase 0A 同步验证之后推进。

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

## 4. Gate -1：规范对齐

### 输入

- 当前 cc-zig bundle header、SDK、manifest 和 artifact-only consumer；
- MetaWork 产品、架构、集成和 ABI 文档。

### 验收

- 明确 experimental ABI revision 1 与 stable support policy 的区别；
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
- 校验静态库、C header、两个 Zig SDK 文件和系统链接输入；
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
→ set first-writer-wins HostCause
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
- 当前只允许临时或明确 trusted Workspace；
- UI/文档不宣称 strict Workspace security。

## 8. Gate 3：cc-zig typed SDK completion

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

MetaWork 不在本仓库复制缺少的类型或 JSON schema。Gate 3 未通过，工作停在 raw probe 与生命周期基础，不进入正式 Host。

Host tool 内部 session ID 到 MetaWork Session/Run 的合同仍未定义时，Host tools 继续禁用；这不阻塞 built-in Read/Bash/Edit。

## 9. Gate 4：正式 AgentCore Host + bounded test sink

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
- 九个 StopReason 使用无 `else` switch；
- unknown code 在 SDK 层失败并保留 raw code；
- `suspended` / `backgrounded` 因缺少 payload 映射 dependency contract failure；
- `aborted` 结合 HostCause 映射 cancelled/interrupted/failed。

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
- HostCause 保留具体原因；
- 不误报用户取消，不读取 zeroed RunResult。

## 10. Gate 5：Event pump 与 Bridge

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
- `text_chunk` 合并后逐字节一致；
- `tool_progress` 覆盖旧状态；
- `usage` 按事件真实语义累计或替换；
- tool/UI/run 控制事件不静默丢失；
- AgentCore/tool 线程不直接调用 WebView；
- control capacity 耗尽在 deadline 后 fatal，不无限阻塞。

### Renderer detach/reload

- 区分临时 detach 与不可恢复 pipeline failure；
- 有界 retention 内允许 Host snapshot/resync；
- 旧连接不能消费新连接事件；
- reload 后 active UI request 仍验证原 Session/Run/request；
- snapshot 不包含 credential；
- Host/AgentCore crash 不伪装为 reload recovery。

### 大 payload

只有真实 event/batch 超过 Native SDK 上限时才加入 object reference，并验证 opaque ID、Session/Run ownership、byte/count/TTL、fetch 校验和所有终止路径清理。

### Fatal 注入

- event decode/copy OOM；
- control queue deadline；
- unrecoverable Bridge send/pipeline failure；
- HostCause first-writer-wins；
- in-flight Run 被要求停止；
- 最终状态 failed，不误报 cancelled。

## 11. Gate 6：同进程 macOS 同步原型

### 最小 UI

- 打开临时或明确 trusted Workspace；
- 创建、切换和关闭 Session；
- 提交真实 Agent input；
- 流式文本；
- built-in Read/Bash/Edit tool cards；
- 同步 permission、question 或 plan request；
- stdout/stderr/exit code；
- stop/cancel；
- terminal Run state；
- WebView reload 后从存活 Host 恢复视图。

不要求完整视觉系统、数据库、async resume、strict Workspace security 或 Host tools。

### Workload matrix

不能用单一“10,000 events”冒充压力测试。矩阵至少覆盖：

| 维度 | 取值方向 |
| --- | --- |
| Sessions | 1、4、超过 executor slots |
| event rate | 低、真实流式、高速 burst |
| event bytes | 小 text、普通 tool、接近/超过 Bridge limit |
| duration | 短 Run、持续 Run |
| UI waits | 无、单个、全部 worker 同时等待 |
| Renderer | 正常、slow、detach/reload |
| cancellation | provider stream、同步 wait、长 Bash |

### 退出条件

- 无跨 Session 串台；
- 文本最终字节一致；
- executor/queue/Bridge 内存有界；
- UI main thread 保持响应；
- 全部 worker 等待 UI 时 response/cancel/shutdown 仍可执行；
- Session close 和 Host shutdown 无 hang/UAF/leak；
- reload 语义可信且不冒充进程恢复；
- 可复现的 build/test/run 命令进入仓库。

Gate 6 结束只能称“同进程 macOS 同步原型”。

## 12. Gate 7：fault-domain spike

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
- 九个 StopReason 的 typed exhaustive mapping；
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

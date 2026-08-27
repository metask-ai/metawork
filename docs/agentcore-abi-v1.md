# MetaWork AgentCore ABI v1 消费合同

> 状态：macOS arm64/x86_64 已锁定 AgentCore `a4a908a39b36`，Windows x86_64 GNU 继续锁定 `e5a423697f78`；三者均为 ABI v1 revision 14 exact artifact；不声明 stable support policy
> 所有者：Metask AgentCore 负责 facade、bindings、bundle 和 ABI 政策；MetaWork 负责 exact artifact 消费、Host 生命周期和产品 capability gate

本文定义 MetaWork 对 Metask AgentCore binary ABI version 1 的 target-specific 消费边界。线程、事件泵和 Host 生命周期见 [AgentCore 集成契约](agentcore-integration.md)，验证入口见 [验证规范](validation.md)。

## 1. Target-specific baseline

所有 target policy 与 repository lock 只接受 ABI v1 revision 14 的 target-specific exact artifact，不识别或加载任何旧 revision。macOS 两个 target 精确锁定 clean source commit `a4a908a39b3625dca89c34f91f21f450288f3832`、package version `0.1.0-dev+a4a908a39b36`；Windows x86_64 GNU 继续锁定 clean source commit `e5a423697f7853d8d609950b5d7e2d7c1ac2e83a`、package version `0.1.0-dev+e5a423697f78`。每个平台仍以自己的完整 manifest bytes 与 payload checksum 独立锁定：

| Target             | Build       | Link input            | Repository lock                                         |
| ------------------ | ----------- | --------------------- | ------------------------------------------------------- |
| Windows x86_64 GNU | ReleaseSafe | `advapi32`、`crypt32` | `build_support/agentcore-bundle.windows.lock.json`      |
| macOS arm64        | ReleaseSafe | 无                    | `build_support/agentcore-bundle.macos.lock.json`        |
| macOS x86_64       | ReleaseSafe | 无                    | `build_support/agentcore-bundle.macos-x86_64.lock.json` |

固定合同按 target 为：

- `binary_abi_version = 1`；
- `binary_abi_revision = 14`；
- root `binary_abi_table_size = 64`；Runtime、Session、SessionControl、Skill、MCP 子表大小分别为 24、40、64、32、40 bytes；
- revision 14 不再发布 root capability bitset；required surface 由 exact root 与五个 mandatory 子表共同定义；
- 唯一 discovery symbol 为 `metask_agentcore_get_api`；
- struct size 必须精确匹配，Host 提供的 reserved 字段必须全部为零；
- 每个平台按完整 manifest bytes 和 payload checksum 独立锁定，不能用 source commit 推断 artifact bytes 可互换。

MetaWork 不接受目标 policy 之外的 ABI revision，不保留 function-table 分流、旧类型别名、shim、兼容 parser、双 bundle 或静默 fallback。需要回退时只能回退整个 MetaWork 变更和对应 exact artifact，运行时没有降级路径。

当前 revision 14 尚处 experimental 状态。artifact 已删除 AgentCore Completion 类型、status 与八个 entry，将原扁平 function table hard cut 为 root + Runtime、Session、SessionControl、Skill、MCP 五个 mandatory 子表，并把唯一 Runtime create 签名扩展为可空 `RuntimePluginConfigV1`。MetaWork 正式 Runtime 传 null plugin config，独立 Completion 继续由 MetaWork 自己提供。revision、root/child table size 与 repository lock 的 exact manifest/header/bindings checksum 必须一起匹配；MetaWork 不为 revision 13 的扁平表、capability bitset、Completion ABI 或旧 callback shape 保留条件编译、运行时 shim 或 target-specific 例外。

### revision 8 的执行状态事件

revision 8 新增 `CAP_RUN_STATE_OBSERVATION` 和 `CoreEvent.run_state`。事件携带单调 `transition_seq`、`phase`（starting、generating、executing_tools、waiting_ui、retrying、compacting、finalizing、completed、failed、aborted、poisoned）、turn、累计 tool call 数及当前 in-flight tool 数组。Windows 与 macOS 的 staged probe 都使用非首值 Host Run ID `7` 确认 callback envelope 的 Run identity 与 `run_state.run_id` 一致，首个观测序号为 `1`；Windows 取证可由 2026-08-13 的 Git object `51e0fcc847e7b832b628f6c64183525dd8300710` 定位。MetaWork 将该事件限制为 runtime-only observation/status 投影，不写入或决定 Workbench `RunPhase`，不产生持久终态；projection 层重复/过期或关联/边界校验失败只丢弃该 observation 并标记 runtime-only degraded，不以 `consumer_rejected` 终止用户 Run。callback 边界的非法 wire/UTF-8、`run_id == 0` 或无法安全解码的文本仍按既有 `invalid_event` 合同失败当前 Run。重启后仍按未完成 Run 的既有恢复规则收口。该一次性 probe 的结论已进入本合同和 Workbench 回归，active tree 不再保留重复脚本。

## 2. Bundle 与 SDK 边界

正式应用只消费 canonical `.agentcore/bundles/<target-id>`：

- candidate root 只用于 probe 和 stage；
- stage 只复制 manifest whitelist 到 target-specific store；正式 build/test/package 从 resolved target 对应 bundle 消费官方 `bindings/zig` package，不访问 AgentCore 实现源码或外部 build tree；
- resolved build target 必须精确选择同名 bundle；不存在“当前 bundle”、last-stage selection、target fallback 或跨 target library 复用；
- verifier 精确校验 schema、target、toolchain、build、link、ABI、payload whitelist/checksum、唯一 discovery symbol 和 repository lock；
- artifact 缺失、source dirty、unknown target、extra file、symlink、checksum、identity 或 ABI 不匹配都必须失败；
- 禁止 Git/path implementation dependency、源码复制、archive 直链、`latest`、可变 tag 和 source fallback；
- `agent/` 只通过 bundle 官方 `bindings/zig` package 获取 ABI types、typed protocol、module 和 link graph。

MetaWork 不复制 header、raw enum、event tag、Permission/Skill/MCP JSON schema、facade code 或 SDK validation。官方 SDK 是 AgentCore `Status`、`StopReason`、`CoreEvent`、`UiRequest`、`UiResponse`、Permission、Skill、MCP、Session description 与 restore report 的唯一协议来源。MetaWork Completion 的 result/stop reason/error 是独立自有类型，不来自该 SDK。

macOS `a4a908a39b36` SDK 新增 `output_segment_begin` / `output_segment_end` typed event variant。本次升级仅完成 SDK 编译适配和事件队列接收，Product 继续按既有 `text_chunk` 行为投影文本，不启用新的分类、持久化或 Renderer 语义；Windows 不在本次升级范围内。

## 3. Target function table

`ApiV1` root 与五个 mandatory child table 必须全部存在、大小精确、reserved 为零且通过 SDK discovery：

- root：owned buffer release 与 Runtime、Session、SessionControl、Skill、MCP 子表指针；
- Runtime：create/destroy；
- Session：create/destroy、typed Run、Run abort；
- SessionControl：restore/describe、model、Permission rules、manual compact/abort 与 checkpoint export；
- Skill：Workspace catalog resolve/release 与 Skill policy bind；
- MCP：Runtime configuration apply/refresh/describe 与 Session selection replacement。

必需 entry 不等于 MetaWork 产品自动开放对应能力。MCP 子表的 `apply_configuration` 必须存在，MetaWork 使用它提交完整 declarative MCP server replacement。Host 为每次 apply 生成非零 desired revision，严格校验 status、report size、disposition、desired/active revision 与 reserved fields；只有 `APPLIED` 才转移 replacement ownership并推进正式 registry generation，`SUPERSEDED`/`REJECTED` 保留旧配置，malformed report fail closed。测试 fake 必须覆盖 applied/rejected 与签名/报告校验。

revision 14 只有一个 Runtime `create` entry。第二个参数是可空 `RuntimePluginConfigV1`；当前 MetaWork 不授予 process-plugin 或 Host stream-tool authority，因此正式 Runtime必须传 null。后续开放 plugin authority 必须另过 capability gate，不能建立第二条 Runtime create 路径。

### revision 14 Completion hard cut

AgentCore Completion handle、request/result/event、stop reason、status、上限与八个 function entry 已从 exact artifact 删除。MetaWork 没有 AgentCore Completion adapter、fixture slots、类型映射、状态映射、运行时 fallback 或调用路径；独立 Completion 合同、上限、取消与 Provider codec 全部由 [Completion 自有能力设计](model-completion-architecture-plan.md)和 MetaWork-owned 测试定义。

## 4. Runtime 与 Session create

fresh Session 只使用 `SessionHostConfigV1` 与 `SessionCreateConfigV1`：

- Host config 持有 provider、permission mode、shell policy、credential、base URL、Workspace root/home、built-in allowlist、Skill binding、Permission rules、MCP selection 和 durable budget；
- create config 持有 Host config 与 model；
- credential、root/home、model 和 allowlist 在同步 create 边界内借用，AgentCore 按合同复制；
- Skill catalog 与显式 `SkillPolicyV1` 成对传入；Workbench 先按稳定 `skill_policy_key` 编译启用策略，再把当前 catalog 中获准执行的 concrete `skill_id` 写入 `granted_skill_ids`；无 catalog 时 policy 必须为 null；
- catalog 只通过 `SkillApi.resolveCatalog` 取得；默认 `.agents/skills` 与受控 `additional_sources` 的候选校验、冲突解析和 winner 选择由 AgentCore 负责。刷新后的 catalog 与 policy 只通过 idle-only `SkillApi.bindPolicy` 原子重绑；
- MCP authority 是完整 replacement：create config 的 `mcp_selection = null` 表示 empty view；`McpApi.updateSelection` 的 selection pointer 必须非 null，合法的零 selector descriptor 表示清空当前 view；
- 每个 `McpServerV1` 必须携带非零、非 secret 的 `configuration_fingerprint`；`McpConnectorV1` 必须提供成对的 `retain_connector` / `release_connector`，Host owner 只有在全部 Core retain 与 active connection 都释放后才可销毁；
- `request_tool_stream` 是 mandatory `tools/call` 路径：Host 验证 borrowed `HostResultSinkV1` 的 layout、reserved、writer 与上限，把完整 JSON-RPC response 从 byte zero 同步写入 sink，并在 callback 返回前释放 transport response；sink failure、越界、secret、取消和非法 HTTP status 必须 fail closed；
- Host transport 支持 `2026-07-28`、`2025-11-25` 与 `2025-06-18` 三个 exact era；`automatic` 可以由 AgentCore 协商并 exact reopen，MetaWork 不把 MCP era 当作 ABI revision 兼容；
- `McpRequestFnV1` 的非 response 结果必须留下 `http_status = 0` 与 canonical empty body；stdio response 必须使用 status 0 且 body 非空；Streamable HTTP 收到任何完整最终响应时必须返回 `MCP_EXCHANGE_RESPONSE` 并保留真实 status，body 可以为空；非空 body 继续执行上限、secret guard 与 exactly-once release；
- HTTP Host 只报告 transport observation，不把完整 400 折叠成 `MCP_EXCHANGE_SERVER_ERROR`，也不解析 `-32022`、`-32601` 或 JSON-RPC identity。只有 AgentCore 可以在 `automatic + disposable modern probe` 上把 HTTP 400 判为 legacy evidence，并关闭 probe 后以 exact classic connection 重新验证；401/403、其它 4xx/5xx、timeout/network 和 actual request 都不借该路径降级；
- 当前正式 Application 仍使用 `permission_rules = null`、`durable_budget = null` 与 `RUN_JOURNAL_EPHEMERAL`；新 Session 的 `mcp_selection` 来自 Workbench 当前 committed opaque activation 或为 null，既有 Session 不因启动期产品状态变化被替换；null durable budget 使用 AgentCore canonical defaults。active-Run durable journal 在正式 crash-evidence/recovery policy 落地前不启用；
- 每个 Session 至多一个 in-flight Run/compact/mutation；Runtime 必须活得比全部 Session 和 catalog lease 长。

旧 AgentCore Session/Conversation 不迁移、不打开，也不通过重新提交历史文本伪造恢复。升级后按 target 创建对应 revision 的 Session，不存在任何旧 revision 的 discovery、加载或回退路径。

## 5. 当前消费与 capability gate

当前正式产品消费：

- Model Connection 测试使用 Agent-owned 独立 one-shot Completion；它不调用 AgentCore Completion，也不创建 Runtime、Session、Task、Run history 或 durable Conversation；
- Workbench Task 标题生成使用首个 Run 已固定 ExecutionConfig 的 Agent-owned 独立 one-shot Completion；它不调用 AgentCore Completion，也不创建新的 Runtime、Session、Run history 或 durable Conversation，失败只触发 Workbench 本地回退；
- shared Runtime；
- Runtime-owned MCP server descriptors、connector 生命周期与 catalog refresh/describe；
- 新 Session 的 MCP selection 与经 AgentCore Run 执行的 MCP tools；
- immutable Skill catalog query/lease；
- fresh Session create/destroy；
- typed Text/Skill Run 与 abort；
- AgentCore bundle 支持的 built-in Read/Bash/Edit/AskUserQuestion；其中 MetaWork Agent 的产品集合不开放 AskUserQuestion；
- manual compact；
- post-terminal checkpoint export 与 Session description；
- verified checkpoint source 驱动的 Session restore 与 restore report/description 对账；
- ABI 提供 synchronous AskUserQuestion 与 Permission；当前 MetaWork Agent 只开放 Permission 产品路径；
- typed Core event 和 Permission provenance。

以下 revision 14 ABI 能力仍关闭，直到各自完成产品 owner、安全、持久化和恢复验收：

- Runtime MCP configuration live apply；
- persistent Permission rules；
- 正式 Host tools；
- process-plugin tools 与 Host stream tools；
- durable active-Run journal；
- async UI continuation；
- Worker crash recovery。

当前 restore 只用于正常 Application 重启后重建 finalized Conversation 的 Session attachment。`SessionRestoreConfigV1` 不携带 model，因此 Host 首先以 Checkpoint 自己的 `SessionBinding.model` 满足 AgentCore restore expectation；restore 产出 candidate 后，Host 在 commit 前再以当前 Task model binding 调用 idle-only `SessionControlApi.setModel`。Checkpoint 模型是历史事实，不与当前 Account 默认模型或 Task 当前模型做全局相等比较；candidate 的模型设置失败必须销毁 candidate 并把本次 restore 作为可重试失败收口。Host 不向 restore 提供 logical Session ID。AgentCore 将当前 authority 与 checkpoint state 取交集，Host 只能提交重新取得且不宽于历史事实的 Skill/MCP authority。该消费不声明 Worker crash、in-flight Run、async pending 或 suspend/resume recovery。

## 6. Callback、事件与 Permission

所有 Event/UI/Host-tool callback 都携带 callback-scoped `RunContext`。Host 必须在同一 Session lock 内验证：

- layout、reserved、pointer、length 和 UTF-8；
- 原始 Session handle；
- active run ID；
- Session-lifetime stable session ID；
- callback lifetime ref admission。

错误 handle/run/session identity、同 Run 或跨 Run identity 漂移、malformed payload、ownership failure 或关键 control event 无法入队都返回 fatal 并 poison Session。跨 callback 保留的 borrowed bytes 必须在返回前深拷贝；callback 不调用 WebView，也不 re-enter Run/destroy。

Permission request 是 SDK 校验后的 flat typed object，包含 request/session/run/tool call/tool identity、canonical arguments digest、policy generation、允许 responses 和可选 candidate。Host 必须：

- 将 request 的 session/run identity 与同次 callback `RunContext` 精确比较；
- response 回显 request ID 与 policy generation；
- Session-scoped choice 只在 candidate 存在时使用，并回显 exact candidate rule ID；
- 拒绝 stale、duplicate、错误类型和错误 Session/Run response；
- 把 `permission_provenance` 作为 control event 处理，不得当作 unknown observation 丢弃。

AskUserQuestion response 继续使用按 question 排列的 `values[]`。UI wait 是没有 deadline 的同步 active Run 子状态；只由 answered、cancel、close 或 shutdown 结束，Host 不得替用户让待决请求过期。

## 7. Status、RunResult 与 StopReason

Host 先校验 function `Status`，再按 operation-specific status set 决定哪些结果字段可读：

- `STATUS_OK`：完整校验 `RunResultV1.struct_size`、reserved、checkpoint outcome、result flags 和 typed StopReason；
- `STATUS_CHECKPOINT_BUDGET_REQUIRED`：Run 未 admission，只读取合同定义的 `struct_size`、`checkpoint_outcome_code`、`result_flags`、`durable_usage_bytes` 和 `required_checkpoint_bytes`；outcome 必须是 budget-required，Session 保持可重试；
- 其他非 OK status：不得读取 `RunResultV1` 的结果字段，只读取并释放 diagnostic；
- unknown status、属于其他 operation 的 known status、unknown StopReason/outcome/flag 或 StopReason 与 checkpoint outcome 不一致都属于 dependency contract failure。

Run、manual compact 与 Session Skill mutation 分别维护 operation-specific status disposition，不能从“SDK 已知 status”推断某个 entry 接受该 status，也不能用一份全局 allowlist 代替。revision 14 的 `checkpoint_budget_required` 对这三条当前消费路径都是合法、可恢复的非 OK 结果：操作向上失败收口，但 Session 保持 reusable；只有不属于该 operation 的 known status 才按 dependency contract failure 处理。revision 13 的 `completion_unsupported_response` 已从官方 Status 删除，MetaWork 的独立 Completion 使用自己的 typed failure，不把该旧 code 保留为 AgentCore status。

checkpoint export 与 Session describe 是另外两条 operation-specific 消费路径。export 中经本地 sink 原因验证的 `checkpoint_io` 不污染 Session；restore 侧 checkpoint status 不是 export 合法结果。`out_of_memory`、`core_error`、malformed OK 或 callback/dependency contract failure 保守关闭 Session admission。describe 的 resource/busy/argument failure 可重试，内部 fatal 与 malformed result 同样关闭 admission。`checkpoint_budget_required` 对这两个 entry 都不是合法结果，必须显式按 dependency contract failure 收口。export 的 generation 只按 opaque `u64` 保存，ABI 未定义非零或单调性，Host 不得自行断言。

checkpoint restore 是第三条独立 disposition。`checkpoint_corrupt`、`checkpoint_unsupported`、`checkpoint_incompatible`、`logical_session_conflict` 与 verified source 的 I/O failure 只失败本次 candidate；unknown/malformed OK、restore report 与持久 expectation 不一致或依赖合同失败必须 fail closed 并销毁 candidate。source `read_fn` 允许短读；canonical revision 14 probe 必须重新确认 Core 持续读取到 EOF。启动 size/hash verify 是 eligibility 事实，job 内同一 source handle 的再校验是 commit 前的权威检查，流式 digest 只作为完整消费时的额外交叉验证。

`CheckpointExportResultV1.digest` 的算法在 revision 14 合同中未定义。MetaWork 不把该字段冒充内容哈希或据此拒绝合法 export；checkpoint store 的文件名、`CheckpointRecord.blob` 和启动校验统一使用 Host 在 sink 中对实际 bytes 独立计算的 SHA-256。若上游未来定义 raw digest 语义，须先补充 ABI 合同与 candidate probe，再决定是否增加独立校验，不能静默替换产品 content hash。

八个 StopReason 必须无 `else` 穷尽映射：

| StopReason                    | Workbench 结果                                                     |
| ----------------------------- | ------------------------------------------------------------------ |
| `end_turn`                    | completed                                                          |
| `max_turns`                   | stopped / awaiting_user                                            |
| `aborted`                     | 按 immutable `TerminationSignal` 映射 cancelled/interrupted/failed |
| `tool_error`                  | failed                                                             |
| `api_error`                   | failed                                                             |
| `tool_loop`                   | stopped / awaiting_user                                            |
| `checkpoint_budget_exhausted` | stopped / resource_limit                                           |
| `checkpoint_resource_limit`   | stopped / resource_limit                                           |

`checkpoint_budget_required` 当前向产品失败收口，不自动 export checkpoint 或重放 Run。pre-admission validation、Skill rejection、resource limit、busy 和 stale failure 保持 Session reusable；admitted fatal status 或 callback/dependency contract failure poison Session。

## 8. Ownership 与 shutdown

- owned diagnostic、UI response、catalog descriptor 与 SDK parse owner 各自 release 恰好一次；
- catalog handle 只由创建它的 Runtime release；Session 只同步借用 catalog；
- callback response ownership 只有在返回 answered 时转移给 Core；最终 identity 复检失败时 Host 释放已编码 bytes；
- MetaWork-owned Completion 不借用 Runtime 或 Session；一次调用和它的 cancellation watchdog quiescent 后才可销毁 Completion；
- Run 返回后仍须等待 active callback 和 abort call quiescence；
- shutdown 顺序固定为停止 ingress、取消 queue、唤醒 UI wait、abort/join、等待 callback/control ref、destroy Session、release catalog、destroy Runtime、最后释放 transport。

transport failure 不能伪造 Run cause；只有 canonical event/projection failure 可以按 Run identity 请求终止。

## 9. Bundle payload

每个 bundle 只允许 manifest 声明的 target library 与共同 SDK payload：

```text
lib/libmetask_agentcore.a          # macOS
lib/metask_agentcore.lib           # Windows，与上一项互斥
include/metask/agentcore.h
bindings/zig/build.zig
bindings/zig/build.zig.zon
bindings/zig/src/{root,protocol,types}.zig
bindings/rust/{Cargo.toml,Cargo.lock,link.cfg,build.rs,examples/,src/}
README.md
manifest.json
```

manifest schema 1 精确记录 package/source、toolchain、target、build、link、contract 和除 manifest 自身外的完整 `{path, sha256}` whitelist。bundle 内散文若与 manifest 或官方 SDK 冲突，按 dependency defect fail closed，不能放宽 verifier。

## 10. 接收门槛

candidate acceptance：

- exact manifest bytes、payload checksum、target、toolchain、ABI 和 filesystem whitelist 校验；
- 官方 Zig package source-free discover/link/run；
- candidate probe 前后内容不变；
- 每个 target 的 artifact/lock 独立，结果不能互相替代。

staged Host gate：

- staged verifier 与 bundle guard；
- mandatory function-table discovery；
- root 与五个 mandatory child table 的 exact layout/non-null entry、revision 13 root 和旧 revision 14 root fail-closed 测试；
- mandatory Runtime create 的 null plugin config、MCP apply、connector retain/release、非零 configuration fingerprint、MCP response status/body ownership、`request_tool_stream` byte-zero sink/limit/cancel/failure、三个 exact MCP era，以及 `automatic` 收到裸 HTTP 400 后 exact reopen 的 interop；
- MetaWork-owned Completion 的三 Provider 非流式 codec、typed failure、取消与 credential 清零测试；
- Session create config、ephemeral run-journal mode、Permission identity/response echo/provenance 测试；
- status-before-result、checkpoint partial-result、八个 StopReason 与 unknown/mismatch fail-closed 测试；
- Run、manual compact 与 Session Skill mutation 的 operation-specific status disposition，以及 budget rejection 后 Session reuse 测试；
- event/UI malformed、close/abort/join/callback quiescence race；
- lifecycle、正式 Native test graph、Debug/Release build；
- 当前平台真实 AgentCore vertical；
- architecture guard 证明正式 build 只消费 canonical bundle，且只有 `agent/` import SDK。

Linux 或其他 target 必须新增独立 policy、lock、artifact 和平台验证。缺少目标 revision 14 artifact 时直接失败，不得保留旧 ABI 作为替代。

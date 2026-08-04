# MetaWork AgentCore ABI v1 revision 6 消费合同

> 状态：revision 6 已作为唯一 development baseline hard cut；不声明 stable support policy
> 所有者：Metask AgentCore 负责 facade、bindings、bundle 和 ABI 政策；MetaWork 负责 exact artifact 消费、Host 生命周期和产品 capability gate

本文定义 MetaWork 对 Metask AgentCore binary ABI version 1 revision 6 的唯一有效消费边界。线程、事件泵和 Host 生命周期见 [AgentCore 集成契约](agentcore-integration.md)，验证入口见 [验证规范](validation.md)。

## 1. 唯一 baseline

两个 target 都锁定 clean source commit `a5b3821c17b337d33f40f903df12484b01f92010`，package version 为 `0.1.0-dev+a5b3821c17b3`，Zig 0.16.0、strip=true、requires C runtime：

| Target                       | Build        | Link input                  | Repository lock                                    |
| ---------------------------- | ------------ | --------------------------- | -------------------------------------------------- |
| macOS arm64，最低 macOS 13.0 | ReleaseSafe  | 无 system library/framework | `build_support/agentcore-bundle.macos.lock.json`   |
| Windows x86_64 GNU           | ReleaseSmall | `advapi32`、`crypt32`       | `build_support/agentcore-bundle.windows.lock.json` |

固定合同为：

- `binary_abi_version = 1`；
- `binary_abi_revision = 6`；
- `binary_abi_table_size = 216`；
- `capabilities = 524287`（`0x7ffff`）；
- 唯一 discovery symbol 为 `metask_agentcore_get_api`；
- struct size 必须精确匹配，Host 提供的 reserved 字段必须全部为零；
- 每个平台按完整 manifest bytes 和 payload checksum 独立锁定，不能用 source commit 推断 artifact bytes 可互换。

MetaWork 不接受其他 ABI revision，不保留 function-table 分流、旧类型别名、shim、兼容 parser、双 bundle 或静默 fallback。需要回退时只能回退整个 MetaWork 变更和对应 exact artifact，运行时没有降级路径。

## 2. Bundle 与 SDK 边界

正式应用只消费 canonical `.agentcore/bundle`：

- candidate root 只用于 probe 和 stage；
- stage 只复制 manifest whitelist，正式 build/test/package 不访问 AgentCore 实现源码或外部 build tree；
- verifier 精确校验 schema、target、toolchain、build、link、ABI、payload whitelist/checksum、唯一 discovery symbol 和 repository lock；
- artifact 缺失、source dirty、unknown target、extra file、symlink、checksum、identity 或 ABI 不匹配都必须失败；
- 禁止 Git/path implementation dependency、源码复制、archive 直链、`latest`、可变 tag 和 source fallback；
- `agent/` 只通过 bundle 官方 `bindings/zig` package 获取 ABI types、typed protocol、module 和 link graph。

MetaWork 不复制 header、raw enum、event tag、Permission/Skill/MCP JSON schema、facade code 或 SDK validation。官方 SDK 是 `Status`、`StopReason`、`CoreEvent`、`UiRequest`、`UiResponse`、Permission、Skill、MCP、Session description 与 restore report 的唯一协议来源。

## 3. revision 6 function table

`ApiV1` 的全部非可选 entry 都必须存在并通过 SDK discovery：

- Runtime create/destroy、Skill catalog query/release；
- Runtime MCP refresh/describe；
- Session create/restore/destroy/describe；
- model、Skill、Permission rules 与 MCP selection replacement；
- typed Text/Skill Run、Run abort；
- manual compact、compact abort；
- checkpoint export；
- owned buffer release。

必需 entry 不等于 MetaWork 产品自动开放对应能力。未消费的 entry 在 production 不被调用；测试 fake 仍必须提供签名正确、明确失败的 stub，确保 function-table 校验真实覆盖 revision 6。

## 4. Runtime 与 Session create

fresh Session 只使用 `SessionHostConfigV1` 与 `SessionCreateConfigV1`：

- Host config 持有 provider、permission mode、shell policy、credential、base URL、Workspace root/home、built-in allowlist、Skill binding、Permission rules、MCP selection 和 durable budget；
- create config 持有 Host config 与 model；
- credential、root/home、model 和 allowlist 在同步 create 边界内借用，AgentCore 按合同复制；
- Skill catalog 与显式 all-enabled selection 成对传入；无 catalog 时 selection 必须为 null；
- 当前 `permission_rules = null`、`mcp_selection = null`、`durable_budget = null`；null durable budget 使用 AgentCore canonical defaults；
- 每个 Session 至多一个 in-flight Run/compact/mutation；Runtime 必须活得比全部 Session 和 catalog lease 长。

旧 AgentCore Session/Conversation 不迁移、不打开，也不通过重新提交历史文本伪造恢复。升级后只创建 revision 6 Session。

## 5. 当前消费与 capability gate

当前正式产品消费：

- shared Runtime；
- immutable Skill catalog query/lease；
- fresh Session create/destroy；
- typed Text/Skill Run 与 abort；
- built-in Read/Bash/Edit；
- manual compact；
- synchronous AskUserQuestion 与 Permission；
- typed Core event 和 Permission provenance。

以下 revision 6 ABI 能力仍关闭，直到各自完成产品 owner、安全、持久化和恢复验收：

- MCP server/catalog/selection 与 MCP tool execution；
- checkpoint export/store/restore；
- Session description 驱动的跨进程 recovery；
- persistent Permission rules；
- 正式 Host tools；
- async UI continuation；
- Worker crash recovery。

因此 Bridge 继续发布 `conversationRecovery = false` 和 `session_recovery_unsupported`。ABI 已具备 checkpoint 原语并不等于 MetaWork 已具备 Conversation recovery。

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

AskUserQuestion response 继续使用按 question 排列的 `values[]`。UI wait 是同步 active Run 子状态；deadline、cancel、close 和 shutdown 必须唤醒它。

## 7. Status、RunResult 与 StopReason

Host 先校验 function `Status`，再按 operation-specific status set 决定哪些结果字段可读：

- `STATUS_OK`：完整校验 `RunResultV1.struct_size`、reserved、checkpoint outcome、result flags 和 typed StopReason；
- `STATUS_CHECKPOINT_BUDGET_REQUIRED`：Run 未 admission，只读取合同定义的 `struct_size`、`checkpoint_outcome_code`、`result_flags`、`durable_usage_bytes` 和 `required_checkpoint_bytes`；outcome 必须是 budget-required，Session 保持可重试；
- 其他非 OK status：不得读取 `RunResultV1` 的结果字段，只读取并释放 diagnostic；
- unknown status、属于其他 operation 的 known status、unknown StopReason/outcome/flag 或 StopReason 与 checkpoint outcome 不一致都属于 dependency contract failure。

Run、manual compact 与 Session Skill mutation 分别维护 operation-specific status disposition，不能从“SDK 已知 status”推断某个 entry 接受该 status，也不能用一份全局 allowlist 代替。revision 6 的 `checkpoint_budget_required` 对这三条当前消费路径都是合法、可恢复的非 OK 结果：操作向上失败收口，但 Session 保持 reusable；只有不属于该 operation 的 known status 才按 dependency contract failure 处理。

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
- Windows 与 macOS artifact/lock 独立，结果不能互相替代。

staged Host gate：

- staged verifier 与 bundle guard；
- mandatory function-table discovery；
- Session create config、Permission identity/response echo/provenance 测试；
- status-before-result、checkpoint partial-result、八个 StopReason 与 unknown/mismatch fail-closed 测试；
- Run、manual compact 与 Session Skill mutation 的 operation-specific status disposition，以及 budget rejection 后 Session reuse 测试；
- event/UI malformed、close/abort/join/callback quiescence race；
- lifecycle、正式 Native test graph、Debug/Release build；
- 当前平台真实 AgentCore vertical；
- architecture guard 证明正式 build 只消费 canonical bundle，且只有 `agent/` import SDK。

Linux 或其他 target 必须新增独立 policy、lock、artifact 和平台验证。缺少目标 revision 6 artifact 时直接失败，不得保留旧 ABI 作为替代。

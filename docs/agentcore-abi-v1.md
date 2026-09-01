# MetaWork AgentCore ABI v1 合同

> 所有者：Metask AgentCore 定义 binary ABI、官方 bindings 与 bundle；MetaWork 定义 Host 对该 ABI 的接受和安全消费规则。

本文只定义 MetaWork 接受什么 AgentCore binary ABI，以及 Host 必须如何发现、校验、调用和释放它。Agent、Product 与 Renderer 如何消费能力见 [AgentCore 集成契约](agentcore-integration.md)，测试入口与平台证据见 [验证规范](validation.md)。

## 1. 范围与机器真源

MetaWork 接受 binary ABI version 1。各 target 的 toolchain、build、link、source identity、manifest bytes 与 payload checksum 由 repository lock 唯一定义：

- [Windows x86_64 GNU lock](../build_support/agentcore-bundle.windows.lock.json)
- [Windows arm64 GNU lock](../build_support/agentcore-bundle.windows-aarch64.lock.json)
- [macOS arm64 lock](../build_support/agentcore-bundle.macos.lock.json)
- [macOS x86_64 lock](../build_support/agentcore-bundle.macos-x86_64.lock.json)

lock 只有满足当前 revision 接受规则时才可消费；尚未取得新 artifact 的 target 保持 fail closed，不得用旧 lock、其他 target 或伪造 manifest 补齐。

本文不复制这些易变值。source commit 相同不证明不同 target 的 artifact bytes 可互换；每个 target 必须独立满足自己的完整 lock。

ABI revision、function-table layout、required entry、symbol 或稳定外部格式发生变化时，必须先取得用户显式批准，再同步更新 lock、本文合同与对应验证。MetaWork 不保留旧 revision 分流、类型别名、shim、兼容 parser、双 bundle、target fallback 或静默降级。回退只能回退完整的 MetaWork 变更与对应 exact artifact，运行时没有旧 ABI 替代路径。

## 2. Bundle 与 SDK 接受边界

正式应用只消费 resolved build target 对应的 canonical `.agentcore/bundles/<target-id>`：

- candidate root 只用于 probe 和 stage；
- stage 只复制 manifest whitelist，正式 build、test 与 package 只读取 staged bundle；
- resolved target 必须精确选择同名 bundle，不读取 last-stage 状态，不跨 target 复用 library；
- verifier 必须精确校验 schema、target、toolchain、build、link、ABI、唯一 discovery symbol、payload whitelist/checksum 与 repository lock；
- artifact 缺失、source dirty、unknown target、extra file、symlink、checksum、identity 或 ABI 不匹配都必须失败；
- 禁止 implementation source dependency、源码复制、archive 直链、`latest`、可变 tag 与 source fallback。

schema 1 manifest 必须包含 `runtime_assets`，当前精确接受一个 ripgrep declaration：`name/version/revision/path/upstream/license/role` 全部必填，不接受未知字段。Windows 路径为 `bin/rg.exe`，macOS 为 `bin/rg`；执行文件与 `bin/ripgrep-LICENSE-MIT` 必须同时在 `files` 中由 checksum 锁定。具体版本、revision 与 checksum 只由 manifest/lock 拥有。开发构建与正式 runtime package 必须部署这两份 payload，不从环境或其他源码树获取替代品。

上游 Runtime 仍拥有 ripgrep resolver；其 `RG_BIN`、`PATH`、Host 同目录及系统位置选择语义不由 MetaWork 重实现。随包 checksum 证明部署身份，不证明在存在环境覆盖时实际执行的路径；当前 ABI 没有 Runtime-scoped 工具路径注入或所选路径证明。发布验证必须在不依赖外部 rg 的环境执行真实 Glob/Grep。MetaWork 不通过 Agent 改写进程全局环境，也不声称已实现运行时工具路径强制锁定。

正式 `agent/` 只通过 bundle 的官方 `bindings/zig` package 获得 ABI types、typed protocol、module 与 link graph。MetaWork 不复制 header、raw enum、event tag、Permission/Skill/MCP schema、facade code 或 SDK validation；官方 SDK 是这些协议形状的唯一真源。bundle 散文不能放宽 manifest、lock、官方 header 或 bindings，互相冲突时按 dependency defect fail closed。

## 3. ABI identity 与 function table

接受的 ABI identity 为：

- `binary_abi_version = 1`；
- `binary_abi_revision = 16`；
- discovery symbol 仅为 `metask_agentcore_get_api`；
- root `binary_abi_table_size = 64`；
- Runtime、Session、SessionControl、Skill、MCP 子表大小依次为 24、40、64、32、40 bytes；
- root 与全部五个子表均为 mandatory；struct size 必须精确匹配，Host 提供的 reserved 字段必须全部为零。

`ApiV1` surface 为：

- root：owned buffer release，以及 Runtime、Session、SessionControl、Skill、MCP 子表指针；
- Runtime：create、destroy；
- Session：create、destroy、typed Run、Run abort；
- SessionControl：restore、describe、model、Permission rules、manual compact/abort、checkpoint export；
- Skill：Workspace catalog resolve/release、Skill policy bind；
- MCP：Runtime configuration apply/refresh/describe、Session selection replacement。

每个 required table、entry 与 reserved field 都必须通过官方 discovery 和 SDK validation。ABI 中存在 entry 只证明 Host 必须能正确理解该表面，不代表 MetaWork 产品已经开放对应能力。

Runtime 只有一个 `create` entry，第二个参数是可空 `RuntimePluginConfigV1`；不得为不同 plugin 配置建立第二条 create ABI 路径。MCP `apply_configuration` 接受完整 declarative replacement：Host 必须使用非零 desired revision，并校验 status、report size、disposition、desired/active revision 与 reserved fields；只有 `APPLIED` 转移 replacement ownership，`SUPERSEDED` 或 `REJECTED` 不得取得该 ownership，malformed report 必须 fail closed。

当前 `SessionHostConfigV1.protocol_kind_code` 将调用方明确选择的协议映射为对应 ABI 编码：`openai_responses` 使用 `OPENAI_PROTOCOL_RESPONSES`；`openai_chat_completions`、`anthropic_messages` 和 `gemini_native` 使用 `PROTOCOL_DEFAULT`。这里的 `PROTOCOL_DEFAULT` 只表示 ABI 编码，不定义 MetaWork 的默认协议；协议选择合同见 [Completion 架构](completion-architecture.md#3-provider-与协议)。`RunInputV1` 的 parts/count 与 reserved layout 由官方 helper 构造；revision 16 新增 `RUN_INPUT_PART_DOCUMENT`、`MAX_RUN_INPUT_DOCUMENT_DATA_BYTES_V1` 与 `document_input_unsupported`，但不改变 `RunInputPartV1` layout 或 function table。Agent Session 当前仍只接受有序图文输入，公共输入、ownership 和预算合同见 [AgentCore 集成契约](agentcore-integration.md#agent-session-图片输入)，Product 入口仍只提交 Text/Skill。

`image_input_unsupported` 只属于本次 Run 含图片时的 admission 拒绝，此时 Session 保持 reusable；在 Text、Skill、仅文本 parts、compact、mutation、export、describe 或 restore 路径出现时属于 dependency contract failure。MetaWork 当前不会构造 document part，因此 `document_input_unsupported` 在全部 operation 中均属于 dependency contract failure；不能因为 SDK 认识这些值就在错误的 operation 或输入形状上放行。

本次 revision hard cut 不提供旧 checkpoint 的兼容适配、迁移或跨 revision 恢复承诺；不主动删除或改写已有产品历史或 checkpoint，无法恢复时沿现有 typed failure 路径明确失败。当前 revision 的 export/restore 完整性与生命周期验证仍为必需。

该 ABI 不包含 AgentCore Completion handle、request/result/event、stop reason、status 或 function entry。MetaWork 不为已删除表面保留 adapter、fixture slot、类型映射或 fallback；MetaWork-owned Completion 不是本 ABI 的一部分，其合同见 [Completion 架构](completion-architecture.md)。

## 4. 调用、callback 与 ownership

Host 必须遵守官方 SDK 为 config、slice、handle、owned result 和 callback 参数定义的所有借用与释放边界，并额外满足：

- create 调用中借用的 credential、path、model、allowlist 与 config slice，在同步调用返回前保持稳定；Core 只可依 ABI 明示规则复制或 retain；
- Skill catalog handle 只由创建它的 Runtime release；Session 对 catalog 的使用不转移 handle ownership；
- `McpConnectorV1` 的 `retain_connector` 与 `release_connector` 必须成对，Host owner 只能在全部 Core retain 与 active connection 释放后销毁；
- borrowed `HostResultSinkV1` 必须先校验 layout、reserved、writer 与上限；response 从 byte zero 同步写入，callback 返回前释放 transport response；
- owned diagnostic、UI response、catalog descriptor、SDK parse owner 与 callback response 各自 release 恰好一次；ownership 只有在 ABI 明示的成功结果上转移；
- 每个 Session 至多一个 in-flight Run、compact 或 mutation；Runtime 必须活得比全部 Session、callback 与 catalog lease 长。

所有 Event、UI 与 Host-tool callback 都携带 callback-scoped `RunContext`。Host 必须在同一 Session synchronization boundary 内校验 layout、reserved、pointer、length、UTF-8、原始 Session handle、active run ID、Session-lifetime stable session ID 与 callback lifetime admission。

错误 handle/run/session identity、同 Run 或跨 Run identity 漂移、malformed payload、ownership failure，或关键 control event 无法进入有界队列，都必须返回 fatal 并 poison Session。跨 callback 保存的 borrowed bytes 必须在 callback 返回前深拷贝；callback 不得调用 WebView，也不得 re-enter Run 或 destroy。

Permission request 与 response 必须保持 SDK typed identity：request 的 session/run identity 与同次 `RunContext` 精确一致；response 回显 request ID 与 policy generation；Session-scoped choice 仅在 candidate 存在时使用并回显 exact candidate rule ID；stale、duplicate、错误类型或错误 Session/Run response 必须拒绝。`permission_provenance` 是 control event，不能作为 unknown observation 丢弃。

## 5. Status、result 与 operation disposition

Host 必须先校验 function `Status`，再按该 operation 的合法 status set 决定结果内存是否可读：

- `STATUS_OK`：完整校验对应 result 的 struct size、reserved、enum、flag 与跨字段一致性；
- `STATUS_CHECKPOINT_BUDGET_REQUIRED` 用于 Run 时：Run 未 admission，只读取合同允许的 `struct_size`、`checkpoint_outcome_code`、`result_flags`、`durable_usage_bytes` 与 `required_checkpoint_bytes`，且 outcome 必须为 budget-required；
- 其他非 OK status：除该 status 明示的 partial result 外，不读取 result 字段，只读取并释放 diagnostic；
- unknown status、属于其他 operation 的 known status、unknown enum/flag 或跨字段矛盾都属于 dependency contract failure。

Run、manual compact、Session Skill mutation、checkpoint export、Session describe 与 checkpoint restore 必须分别维护 operation-specific disposition；不能从“SDK 认识某个 status”推断所有 entry 都接受它，也不能用全局 allowlist 代替。

- Run、manual compact 与 Session Skill mutation 接受各自合同中的 `checkpoint_budget_required`，操作失败但 Session 保持 reusable；
- export 中只有经本地 sink 原因验证的 `checkpoint_io` 可作为不污染 Session 的 I/O 失败；restore-only status 不能作为 export 结果；
- describe 的 resource、busy 与 argument failure 可重试；export/describe 的 `checkpoint_budget_required`、malformed OK 或非法 status 必须按 dependency contract failure 处理；
- export/describe 的 `out_of_memory`、`core_error`，以及 callback/dependency contract failure，必须保守关闭 Session admission；
- restore 的 `checkpoint_corrupt`、`checkpoint_unsupported`、`checkpoint_incompatible`、`logical_session_conflict` 与 verified source I/O failure 只失败本次 candidate；malformed OK、report 与 expectation 不一致或 dependency contract failure 必须销毁 candidate 并 fail closed。

checkpoint source `read_fn` 允许短读，Host probe 必须确认 Core 会持续读取到 EOF。export generation 是 opaque `u64`，ABI 不承诺非零或单调，Host 不得自行增加该不变量。

`CheckpointExportResultV1.digest` 在本 revision 中没有定义算法。Host 不得把它解释为内容哈希，也不得据此拒绝合法 export；需要内容完整性时必须对实际 streamed bytes 独立计算。上游若定义 raw digest 语义，必须先更新本合同与 candidate probe，不能静默改变现有内容身份。

所有 typed `StopReason` 必须无 `else` 穷尽处理；unknown raw value 必须在 SDK validation boundary 失败并保留诊断值。StopReason 到 Product/Workbench 终态的映射不属于本 ABI 合同，见 [AgentCore 集成契约](agentcore-integration.md#11-runresult-与-stopreason)。

## 6. 生命周期与接收 Gate

Run 返回后，Host 仍须等待 active callback 与 abort call quiescence。销毁顺序必须满足 ABI ownership：先停止新 ingress 并唤醒 callback wait，再 abort/join operation，等待 callback/control reference 归零，随后 destroy Session、release Runtime-owned catalog，最后 destroy Runtime。跨 owner 的完整应用关闭编排由 [AgentCore 集成契约](agentcore-integration.md)定义。

candidate 或 staged bundle 至少必须通过以下不可绕过的 ABI Gate：

- exact manifest、payload、target、toolchain、ABI、symbol 与 filesystem whitelist 校验；
- 官方 Zig package source-free discovery、link 与最小调用；
- root、五个 mandatory child table、entry、layout 与 reserved field 校验；
- callback identity、borrowed/owned memory、operation-specific status/result 与 malformed input 的 fail-closed probe；
- candidate probe 前后 artifact 内容不变；
- 每个 target 独立取证，任何其他 target 的结果都不能替代。

具体命令、测试矩阵和长期平台证据只由 [验证规范](validation.md)维护。缺少目标 lock 对应的 exact artifact 时直接失败，不得以旧 ABI、其他 target 或跳过真实 AgentCore 调用替代。

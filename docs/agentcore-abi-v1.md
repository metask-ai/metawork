# MetaWork AgentCore ABI v1 合同

> 所有者：Metask AgentCore 定义 binary ABI、官方 bindings 与 bundle；MetaWork 定义 Host 对该 ABI 的接受和安全消费规则。

本文只定义 MetaWork 接受什么 AgentCore binary ABI，以及 Host 必须如何发现、校验、调用和释放它。Agent、Product 与 Renderer 如何消费能力见 [AgentCore 集成契约](agentcore-integration.md)，测试入口与平台证据见 [验证规范](validation.md)。

## 1. 范围与机器真源

MetaWork 接受 binary ABI version 1。各 target 的 toolchain、build、link、source identity、manifest bytes 与 payload checksum 由 repository lock 唯一定义：

- [Windows x86_64 MSVC lock](../build_support/agentcore-bundle.windows-x86_64.lock.json)
- [Windows arm64 MSVC lock](../build_support/agentcore-bundle.windows-aarch64.lock.json)
- [macOS arm64 lock](../build_support/agentcore-bundle.macos-aarch64.lock.json)
- [macOS x86_64 lock](../build_support/agentcore-bundle.macos-x86_64.lock.json)

lock 只有满足当前 revision 接受规则时才可消费；尚未取得新 artifact 的 target 保持 fail closed，不得用旧 lock、其他 target 或伪造 manifest 补齐。

Windows x86_64 与 arm64 的正式消费目标均为 MSVC；Host、官方 Zig package 与 bundle 必须使用相同 architecture、OS 和 MSVC ABI。旧 GNU target、bundle 与混合 ABI identity 均拒绝，不保留 GNU 构建、staging 或运行 fallback。MSVC 编译依赖已安装的 Visual C++ 工具链与相应架构的 Windows SDK；构建成功不替代对应架构的真实运行与分发验收。

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

schema 1 manifest 还必须包含精确的 `shared_library = { path, entry_point, install_name, needed }` declaration。Windows 路径为 `lib/metask_agentcore.dll` 且 install name 为 null；macOS 路径为 `lib/libmetask_agentcore.dylib` 且 install name 为 `@rpath/libmetask_agentcore.dylib`；entry point 仅为 `metask_agentcore_get_api`。静态库与共享库都必须由 `files` checksum 锁定，loader dependencies 由 exact lock 拥有。MetaWork 继续通过官方 Zig package 静态链接；接受共享库 payload 不建立运行时动态加载路径或 DLL fallback。

上游 Runtime 仍拥有 ripgrep resolver；其 `RG_BIN`、`PATH`、Host 同目录及系统位置选择语义不由 MetaWork 重实现。随包 checksum 证明部署身份，不证明在存在环境覆盖时实际执行的路径；当前 ABI 没有 Runtime-scoped 工具路径注入或所选路径证明。发布验证必须在不依赖外部 rg 的环境执行真实 Glob/Grep。MetaWork 不通过 Agent 改写进程全局环境，也不声称已实现运行时工具路径强制锁定。

正式 `agent/` 只通过 bundle 的官方 `bindings/zig` package 获得 ABI types、typed protocol、module 与 link graph。MetaWork 不复制 header、raw enum、event tag、Permission/Skill/MCP schema、facade code 或 SDK validation；官方 SDK 是这些协议形状的唯一真源。bundle 散文不能放宽 manifest、lock、官方 header 或 bindings，互相冲突时按 dependency defect fail closed。

## 3. ABI identity 与 function table

接受的 ABI identity 为：

- `binary_abi_version = 1`；
- `binary_abi_revision = 24`；
- discovery symbol 仅为 `metask_agentcore_get_api`；
- root `binary_abi_table_size = 80`；
- Runtime、Session、SessionControl、Skill、MCP、Goal、Team 子表大小依次为 24、48、80、32、40、40、24 bytes；
- root 与全部七个子表均为 mandatory；struct size 必须精确匹配，Host 提供的 reserved 字段必须全部为零。

`ApiV1` surface 为：

- root：owned buffer release，以及 Runtime、Session、SessionControl、Skill、MCP、Goal、Team 子表指针；
- Runtime：create、destroy；
- Session：create、destroy、typed Run、Run abort、active-Run input submission；
- SessionControl：restore、describe、model、Permission rules、manual compact/abort、checkpoint export、idle-only prompt profile replacement、idle-only Permission mode replacement；
- Skill：Workspace catalog resolve/release、Skill policy bind；
- MCP：Runtime configuration apply/refresh/describe、Session selection replacement；
- Goal：get、set、update、clear；
- Team：describe、poll。

每个 required table、entry 与 reserved field 都必须通过官方 discovery 和 SDK validation。ABI 中存在 entry 只证明 Host 必须能正确理解该表面，不代表 MetaWork 产品已经开放对应能力。

MetaWork 不调用 Goal、Team 或 active-Run input submission。Runtime 的 `enable_teams` 为零，Session create/restore 的 `team` 为 null，不建立 Goal continuation Run；运行中排队发送继续由 Product 持有并在既有完成边界接纳。`input_adopted` 和 `goal_updated` 虽由官方 SDK 解码，当前 Agent 消费边界仍明确拒绝；所有 Run 返回的 `input_accepted_count / input_adopted_count` 必须为零，非零属于 dependency contract failure，不能静默取得 Conversation 覆盖事实。

MetaWork 对全部 Run 显式设置 `TIME_CONTEXT_SYSTEM`，`utc_offset_minutes` 为零，Host `context_blocks` 为 null、count 为零。AgentCore 在普通文本与多模态 Run 开始时生成官方 `currentDate` block，使用 Core 进程的系统时区；Skill Run 按官方语义不增加日期 block。MetaWork 不采样、格式化、补写或建立另一条日期注入路径；恢复历史中的旧日期上下文交由 Core 原样消费。

revision 21 的 Host model-capability declarations 当前保持空，不改变 Models 与 Session 的既有能力消费边界。官方 `describe.image_input` observation 由 SDK 完整验证，不进入产品投影。模型图片能力未确定时的 `image_input_capability_unknown`，按下述图片 admission 拒绝规则消费。

`SessionCreateConfigV1.prompt_profile` 与 `RunOptionsV1.context_blocks/context_block_count` 使用官方 layout，其他 reserved 字段必须继续为零；不得用旧 struct layout 调用新 ABI。`set_prompt_profile` 是 mandatory entry，但 MetaWork 当前不开放 prompt customization，Session 创建传入 Agent-owned 固定产品身份 profile（见 [集成契约](agentcore-integration.md#session-产品身份)）。日期上下文进入 Core 的本轮用户记录，Conversation/checkpoint 保留遵循官方语义，不修改 Session 产品身份 profile。官方 SDK 完整校验 `describe.prompt` 与 `prompt_manifest` observation，Agent 明确消费该 observation 而不投影或持久化它；这不建立产品 prompt editor 或提示审计能力。

`update_permission_mode` 是 revision 19 新增的 mandatory entry。只能在 Session idle，且 Run、Permission callback、compact、export、mutation 和取消排空均已静止时调用。真正变化必须推进 `policy_generation`、撤销全部 Session-scoped allow/deny grants，并保留显式 deny、Skill、sandbox 和其他安全约束；相同 mode 是 no-op，保留 generation 和 grants。明确拒绝（含 `checkpoint_budget_required`）不得改变 mode、generation、grants 或 policy fingerprint。成功后 Host 必须通过官方 typed `describe.permission_mode` 和 `policy_generation` 核对结果。产品切换、恢复和提交职责由 [AgentCore 集成契约](agentcore-integration.md)定义。

Runtime 只有一个 `create` entry，第二个参数是可空 `RuntimePluginConfigV1`；不得为不同 plugin 配置建立第二条 create ABI 路径。MCP `apply_configuration` 接受完整 declarative replacement：Host 必须使用非零 desired revision，并校验 status、report size、disposition、desired/active revision 与 reserved fields；只有 `APPLIED` 转移 replacement ownership，`SUPERSEDED` 或 `REJECTED` 不得取得该 ownership，malformed report 必须 fail closed。

当前 `SessionHostConfigV1.protocol_kind_code` 将调用方明确选择的协议映射为对应 ABI 编码：`openai_responses` 使用 `OPENAI_PROTOCOL_RESPONSES`；`openai_chat_completions`、`anthropic_messages` 和 `gemini_native` 使用 `PROTOCOL_DEFAULT`。这里的 `PROTOCOL_DEFAULT` 只表示 ABI 编码，不定义 MetaWork 的默认协议；协议选择合同见 [Completion 架构](completion-architecture.md#3-provider-与协议)。`RunInputV1` 的 parts/count 与 reserved layout 由官方 helper 构造；当前 revision 只定义文本与图片 part，不定义 document part、文档输入上限或文档能力拒绝 status。公共输入、ownership 和预算合同见 [AgentCore 集成契约](agentcore-integration.md#agent-session-多模态输入)。

`image_input_unsupported` 和 `image_input_capability_unknown` 仅作为本次 Run 含图片时的 admission 拒绝；在 Text、Skill、仅文本 parts、compact、mutation、export、describe 或 restore 路径出现时属于 dependency contract failure。`goal_conflict` 不属于 MetaWork 当前开放 operation 的合法 status。不能因为 SDK 认识这些值就在错误的 operation 或输入形状上放行。

binary ABI 接受政策只接受当前 revision，不建立旧 ABI 调用路径。升级必须保留已有产品历史与 checkpoint；旧 checkpoint 只交由当前官方 Core 的 restore 消费，不建立 Host 兼容 parser 或迁移格式。替换 artifact 的恢复 Gate 必须使用上一版 Core 导出的非空原始 checkpoint，核对 Session identity、运行与 checkpoint 元数据，并以恢复后的实际 Run 证明旧 Conversation 被消费；仅空 Session 恢复不足以通过。无法恢复时沿 typed failure 明确失败，保留原始 bytes，不静默创建空 Conversation。该 Gate 不承诺任意未来 revision 的跨版本恢复；当前 revision 的 export/restore 完整性与生命周期验证仍为必需。

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

Run、manual compact、Session Skill mutation、Permission mode mutation、checkpoint export、Session describe 与 checkpoint restore 必须分别维护 operation-specific disposition；不能从“SDK 认识某个 status”推断所有 entry 都接受它，也不能用全局 allowlist 代替。

- Run、manual compact、Session Skill mutation 与 Permission mode mutation 接受各自合同中的 `checkpoint_budget_required`，操作失败但 Session 保持 reusable；
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

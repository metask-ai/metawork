# MetaWork AgentCore ABI v1 revision 5 消费合同

> 状态：revision 5 baseline 已在两个平台完成；Windows follow-up artifact 已完成 exact lock、probe 与 build，真实 vertical 仍被既有 titlebar preflight 阻断；不声明 stable support policy
> 所有者：Metask AgentCore 负责 facade、bindings、bundle 和兼容政策；MetaWork 负责精确消费验证

本文记录 MetaWork 对 AgentCore binary ABI version 1 revision 5 的消费边界。线程、事件泵和 Host 生命周期见 [AgentCore 集成契约](agentcore-integration.md)，当前验收要求见 [验证规范](validation.md)。verifier、两个 target 的 repository lock、canonical staged bundle、official SDK 与共享 Agent Session 已 hard cut。既有 Workbench、Bridge、Renderer 产品合同不因本次依赖升级变化。

## 1. 版本含义

当前 Windows development bundle 已更新到 clean source commit `72655b68b882945f5b47125ddcba1023b0667a17`；macOS development bundle 仍锁定 clean source commit `f0141f878d36f2bd5a76b097507cf19cbbbb174b`，等待平台 owner 独立更新。两者分别锁定完整 manifest 与 payload checksum，都是 ABI v1 revision 5、168-byte API table、required capabilities `0x0fff`、Zig 0.16.0、strip=true 并需要 C runtime；macOS 使用 ReleaseSafe，Windows 使用 ReleaseSmall：

| Target                         | Version                  | Source commit                              | Provenance             | Link input            | 状态                    |
| ------------------------------ | ------------------------ | ------------------------------------------ | ---------------------- | --------------------- | ----------------------- |
| macOS arm64（最低 macOS 13.0） | `0.1.0-dev+f0141f878d36` | `f0141f878d36f2bd5a76b097507cf19cbbbb174b` | `source.dirty = false` | 无 system library     | exact lock 与验证已完成 |
| Windows x86_64 GNU             | `0.1.0-dev+72655b68b882` | `72655b68b882945f5b47125ddcba1023b0667a17` | `source.dirty = false` | `advapi32`、`crypt32` | exact lock/probe/build 已完成；vertical preflight 受阻 |

revision 5 是从 revision 4 进行的 breaking function-table hard cut：API table 增加 Session model mutation、manual compact、Skill selection 与 Host permission-rules capability；`session_refresh_skill_catalog` 被 `session_update_skills` 取代，Session create 和 Skill update 都显式携带 selection。每个 target 仍由完整 manifest bytes/checksum 独立锁定，不能凭相同 source commit 推断 artifact 可互换，也不等于 stable ABI support policy。

Windows 当前 follow-up bundle 不改变 ABI 或 MetaWork 产品合同；它把 AgentCore 默认 Skill discovery 收敛为 `<workspace_home>/.agents/skills` 与 `<workspace_root>/.agents/skills`，同名 Skill 由 Workspace 来源覆盖 Home 来源，两个根相同时只扫描一次。MetaWork 不依赖 AgentCore 隐式扫描 `.claude/skills`、`.metacodes/skills` 或系统级目录。

- repository lock 保存完整 manifest，并精确锁定 package/source、target、toolchain、link contract、ABI 和所有 payload checksum；
- 每个锁定 artifact 都必须是 clean provenance；MetaWork 只信任完整 manifest bytes 与 payload checksums，而不从 commit 推断 artifact bytes；
- 对一个固定 bundle，ABI version/revision、layout、整数 code、callback 签名和语义不得漂移；
- 未来不兼容的 layout/code/ownership 变化必须发布新的 ABI revision/version；
- 兼容增量能力必须通过 capability 和新的 bundle identity 显式表达；
- v1 revision 5 struct size 必须精确匹配且全部 reserved 字段为零；MetaWork 不接受 revision 4 的 136-byte API table、旧 `session_refresh_skill_catalog`、其他 revision 或旧 `session_run`；
- 唯一 discovery symbol 是 `metask_agentcore_get_api`；旧 symbol 不得进入 active code；
- 新 observation tag 可以由新 bundle identity 兼容增加，旧 SDK 将其保存为 owned unknown observation；
- MetaWork 不复制 facade、header、code、event tag 或 UI JSON schema。

目标 v1 baseline 证明同步桌面垂直链路，不把后续产品需求塞进一个并不存在的 ABI。

## 2. 目标 v1 baseline 必须具备的能力

| 能力              | 目标合同                                                                                                          |
| ----------------- | ----------------------------------------------------------------------------------------------------------------- |
| API discovery     | 从 `metask_agentcore_get_api` 获取并校验 ABI v1 revision 5、168-byte table 与 required capabilities `0x0fff`      |
| Runtime           | 创建/销毁共享 Runtime；按 Workspace root/home/epoch query immutable Skill catalog snapshot                        |
| Catalog ownership | query 返回 Host handle 与 descriptor buffer；descriptor、SDK parsed value、catalog handle 各自按合同释放          |
| Session           | 创建/销毁 Session；catalog 与显式 Skill selection 成对绑定，并仅在 idle 时通过 `session_update_skills` 原子替换   |
| Session mutation  | ABI 提供 model、Skill、permission-rules replacement 与 manual compact；MetaWork 当前只消费 all-enabled Skill 更新 |
| 同步 Run          | `session_run_input` 接收 tagged Text/Skill input；每 Session 至多一个 active Run                                  |
| built-in tools    | Session 可按 allowlist 使用 AgentCore built-in Read/Bash/Edit 等工具；Skill authority 只能进一步收窄              |
| callback identity | Event、UI 和 Host tool callback 共享 validated `RunContext`：Session handle、run ID、Session-lifetime session ID  |
| 结构化事件        | callback 输出现有 tagged `CoreEvent` JSON，并绑定 `RunContext`                                                    |
| 同步 Host UI      | callback 接收 `RunContext` + `UiRequest` JSON，并同步返回 answered/unavailable/fatal 与 response JSON             |
| abort             | 其他线程可以按 Session/Run 请求 user/timeout abort                                                                |
| 结果              | 成功 ABI 调用返回 stop reason code、turn count 和 tool count                                                      |
| 错误              | ABI status 与 diagnostic 独立于有效 `RunResult`；Skill pre-admission status 保持 Session reusable                 |
| 所有权            | borrowed callback views、owned buffers、catalog handle 和 Session snapshot 的生命周期与 release 责任明确          |

目标 bundle 也声明 synchronous Host tool capability，但 MetaWork 产品路径暂不使用，原因见第 6 节。

## 3. 目标 v1 明确不包含

- async UI continuation；
- `.pending` → `SuspendInfo` → `resumeRun`；
- Conversation/Session 跨进程持久化和重建；
- crash 后原地恢复同步 permission；
- strict Workspace security 保证；
- MetaWork Session/Run 可验证映射的正式 Host tools；
- `UiBackend.poll()` 生产消费链路或生成期实时 steering；
- Worker IPC；
- Linux 或其他尚未锁定的 target bundle；
- MetaWork 数据库、产品事件 envelope、Renderer view model 或 WebView API。
- typed Workbench `Output`、`FileChange` 或 plan-progress；
- plan approval 或 custom UI control。

这些能力必须通过后续 capability、兼容 bundle 更新或新 ABI revision 明确引入，不能根据内部 native Zig 类型推断它们已经存在。

## 4. Runtime、Session 与 Run 生命周期

ABI v1 的 Run 是同步调用，但 MetaWork 必须通过 bounded executor 调度：

- Runtime 必须活得比其全部 Session 长；
- 每个 Session 至多一个 in-flight Run；
- 空闲 Session 不长期占用 executor slot；
- 同步 UI wait 仍属于 active Run，并占用 slot；
- queued Run 在 Session close 时取消，不得在 close 后进入 Core；
- `session_destroy` 遇到 active Run 可以返回 busy，Host 不得假设 library 会替调用方等待；
- callback 不得 re-enter Run 或 destroy；
- callback `ctx` 必须活到 Run join 且全部 callback 退出之后。

Session close 的规范顺序是：

```text
mark Closing
→ reject new Run / cancel queued Run
→ wake synchronous UI wait
→ set first-writer-wins TerminationSignal
→ request abort for active Run
→ join Run job
→ wait callback refcount == 0
→ session_destroy
→ mark Closed
```

abort 返回 stale/too-late 时仍必须 join 已有 Run job，再决定最终状态。double close 和重复 abort 必须幂等或返回明确错误，不能 double free。

## 5. Event callback 与 typed SDK

`CoreEvent` 是 Agent 结构化事件的唯一来源。当前 wire payload 是 callback-scoped tagged JSON bytes。

正式 Host 必须：

- 先用 bundle SDK 校验 callback `RunContext` 的布局、reserved 字段、length、pointer 和 UTF-8；
- 在同一 Session lock 内比较原始 Session handle 与 active run ID，并原子首次绑定或比较 Session-lifetime session ID；
- 在上述完整 identity 成功后才取得 callback lifetime ref；错误 handle/run/session ID 或 identity 漂移必须返回 fatal 并 poison Session；
- UI callback 在发布 request 和最终提取 response 时必须在 Session lock 下重新确认现有 identity/dependency-contract 状态健康；并发 identity failure 后禁止返回 answered，已编码但尚未转移的 response 由 Host 释放；
- 先用 Metask AgentCore bundle SDK 校验 bytes view、JSON tag、payload shape 和嵌套字段；
- 在 callback 返回前深拷贝所有需要异步保留的 bytes；
- 携带正确 Session handle 与 run ID 进入 Host envelope；
- 不重新定义平行的 Agent event 类型体系；
- 不从 callback 直接调用 WebView；
- 无法验证、复制或入队关键事件时返回 callback fatal；canonical consumer notification 暂时 unavailable 时先执行有界 retry/deadline，耗尽后才返回 callback fatal，且不得撤销 pump 对 owned event 的所有权；
- callback 返回后的 Renderer/Bridge transport failure 不属于 ABI callback failure，不得直接 abort Run。

candidate acceptance 通过 exact artifact 校验和官方 Zig package 的 source-free discover/link/run 证明 bundle 可消费；该代码不得进入正式 Host，也不复测上游 ABI facade。

正式 Host 的硬门槛是 Metask AgentCore bundle SDK 至少提供：

- typed ABI function `Status` validator；
- typed `StopReason` validator；
- 校验后的 `CoreEvent` decoder/view；
- 校验后的 `UiRequest` decoder/view；
- `UiResponse` encoder；
- unknown code/tag、非法 length/null、payload mismatch 的明确错误；
- callback 参数语义、线程和 ownership 文档。

上述 SDK 是随 bundle 编译进消费者的 Metask AgentCore-owned source layer，不要求改变 C ABI layout，也不允许 MetaWork 自己补一份协议副本。

生产 build graph 只把 SDK 注入 `agent/` 的 catalog、event sink、event pump 和 Session 实现。App 通过 Agent Runtime 完成 ABI discovery；Workbench 只消费 Agent module root 暴露的 SDK-validated owned/typed 表面；Bridge wire DTO 不引用 SDK enum、owner 或 handle。该边界避免复制协议，同时阻止 transport 与产品层直接依赖 bundle module。

目标 revision 5 bundle 的 `CoreEvent` 提供十个 known observation tags：`text_chunk`、`tool_start`、`tool_progress`、`progress`、`tool_result`、`usage`、`context_warning`、`auto_compact`、`retry_notice` 和 `stream_done`。有效的新 observation tag 被解码成 owned `UnknownCoreEvent`；迁移后的 Host 在 SDK 完成结构、ownership 和 byte-bound 校验后立即释放并忽略它，不让未知产品语义消耗事件泵容量，也不得把 raw tag/payload 传给 Renderer。

目标 baseline 没有 typed `FileChange`、`Output` 或 plan-progress 事件。MetaWork 因此只能投影可验证的工具活动，并保持 `Files changed` / `Outputs` 模块隐藏；不得解析 Bash/Edit 参数或 stdout 猜测文件变更，也不得把普通新文件自动归类为 Output。

### 更早 experimental 表面的历史收口

| 旧表面                                            | revision 5 处理                                                                   |
| ------------------------------------------------- | --------------------------------------------------------------------------------- |
| direct `ParsedCoreEvent.value`                    | 必须先处理 `DecodedCoreEvent.known/unknown`                                       |
| `stream_begin`、current-tool 与 diagnostic events | 从公开 observation contract 删除，MetaWork 不复制                                 |
| `plan_approval`、`custom` UI                      | 从 v1 control contract 删除，产品路径隐藏                                         |
| `suspended`、`backgrounded`、`budget` StopReason  | 从 v1 删除，unknown code fail closed                                              |
| `resource_limit` Status                           | 新增；pre-admission failure，Session 可复用                                       |
| revision 3 `session_run`                          | 删除；Text 使用 SDK `sessionRunText`，Skill 使用 SDK `sessionRunSkill`            |
| flat AskUserQuestion answers                      | 删除；按 question 传递有序 `values[]`，多选值不得用展示字符串拼接                 |
| admitted fatal status                             | `out_of_memory`、`core_error`、`callback_failed`、`internal_error` poison Session |
| permission mode codes                             | 只使用 SDK 常量；不保留旧数值映射                                                 |
| revision 4 `session_refresh_skill_catalog`        | 删除；以 `session_update_skills` 原子替换 catalog 与显式 selection                |

revision 5 的新 mutation entry 是 ABI 必需函数，不等于 MetaWork 产品能力自动开放。当前 Host 在 Session create 与 catalog refresh 中固定使用“全部启用、无 exception”的 Skill selection，并保持 `permission_rules = null`；不注册 set-model、manual compact、permission-rule 或 Skill toggle 产品入口。fake API 只为未消费 entry 提供满足 function-table 校验的最小失败 stub，不模拟上游实现。

## 6. 工具与 Workspace

### built-in tools

目标 baseline 的 Read/Bash/Edit 使用 AgentCore built-in tools：

- Runtime 发布允许的 built-in catalog；
- Session allowlist 再限制对模型可见和可 dispatch 的工具；
- permission 未得到同步明确批准前，危险动作不得发生；
- Bash 使用非交互子进程，不依赖 PTY；
- 测试使用临时或用户明确 trusted 的 Workspace 和受控命令。

目标 v1 明确不声称已完成 symlink、`..`、不存在写入目标、sandbox 和进程树等 strict Workspace security 全矩阵。该矩阵属于后续安全 capability。

### Host tools

目标 revision 5 的 Host tool callback 也携带 `RunContext`，wire identity 已可验证；但 MetaWork 尚未定义产品级 Host tool catalog、权限、Workspace 与路由政策。因此：

- artifact-only probe 可以验证 Host tool callback/release mechanics；
- MetaWork 产品 Runtime 的 `host_tool_count` 必须为零；
- 不通过每 Session 一个 Runtime、全局 mutable current-session 或 TLS 绕过产品边界；
- 将来启用前必须建立独立 capability Gate 和多 Session security/contract test。

## 7. 同步 UI request

目标 v1 UI request 是同步 callback：

```text
AgentCore callback
→ Host SDK validates RunContext and decodes UiRequest
→ atomically bind/compare callback Session handle + active Run + stable session ID
→ enqueue control item for Renderer
→ callback waits on Host condition/channel
→ user answer / deadline / cancel / close / shutdown
→ SDK encodes UiResponse or return unavailable/fatal
→ callback returns and Run continues or unwinds
```

约束：

- Bridge/main thread 不得等待 callback；
- 每个 active Run 同时最多一个 UI wait；
- response 必须校验 Session、Run、request identity 和类型；
- stale、重复、错误 Session/Run 的响应必须拒绝；
- deadline 默认安全 deny/unavailable，不能无限挂起；
- cancel、Session close 和 Host shutdown 必须唤醒 wait；
- crash 后等待状态失效，Run 为 interrupted，工具不得自动继续；
- 这不是 async pending，不产生可持久化 `SuspendInfo`。

## 8. Status、RunResult 与 StopReason

ABI function status 与有效 Run 结果是两层不同语义：

```text
status != OK
→ 读取并 release diagnostic
→ 映射 ABI/callback/core 调用失败
→ 禁止读取 RunResult

status == OK
→ SDK 校验 RunResult layout/code
→ SDK 校验 StopReason
→ Host 穷尽映射
```

六个 StopReason code 必须被 SDK 接受并由 Host 无 `else` 穷尽处理：

| StopReason   | 当前同步 baseline 映射                                                                                   |
| ------------ | -------------------------------------------------------------------------------------------------------- |
| `end_turn`   | `completed`                                                                                              |
| `max_turns`  | `stopped` + `awaiting_user`                                                                              |
| `aborted`    | Workbench 根据 immutable `TerminalResult.termination_signal` 映射 `cancelled` / `interrupted` / `failed` |
| `tool_error` | `failed`                                                                                                 |
| `api_error`  | `failed`                                                                                                 |
| `tool_loop`  | `stopped` + `awaiting_user`                                                                              |

wire abort reason 只提供目标 v1 的中断机制；用户取消、timeout、Session close 和 application shutdown 进入 active Run 的 typed `TerminationSignal`。callback 内失败优先直接返回 callback fatal；callback 返回后只有 canonical event/projection failure 可以按 Run identity 请求 abort。`Run.execute()` 在 ABI 返回后产出同时包含 typed/raw status、StopReason、abort status 和最终 latch 的 immutable `TerminalResult`。Renderer/Bridge transport failure 由 Workbench policy 处理，不进入 Agent termination state。

Status 还包括 `resource_limit`、`skill_catalog_invalid`、`stale_catalog`、`skill_not_found`、`invalid_skill_arguments`、`skill_policy_violation`、`skill_unavailable` 和 `stale_compact`。Status enum 是全局 code 集，不代表每个函数都能返回每个 known code；Host 必须按 run、abort、Skill update、destroy 的 operation-specific status set 验证，unknown 或属于其他 operation 的 known status 都 fail closed。Session 创建时绑定的 provider model 对全部 Run 和 Skill fork child 都是固定的；Skill 声明空值或 `inherit` 时继承 Session model，声明其他 model 时以 `skill_unavailable` 在 admission 前失败，不允许覆盖 Task execution binding。pre-admission validation、Skill rejection、resource-limit、busy 和 stale-run failure 保持 Session 可复用；admission 后的 `out_of_memory`、`core_error`、`callback_failed` 或 `internal_error` poison Session，之后的 Run/abort 返回 `invalid_state`，仅 destroy 仍有效。Skill update 的普通非 OK status 保持 Session 可复用，`invalid_state` 表示 Session 已 poisoned。

## 9. Bundle 交付

revision 5 bundle 精确包含 target-specific library 与共同 SDK payload：

```text
lib/libmetask_agentcore.a          # macOS
lib/metask_agentcore.lib           # Windows；与上一项互斥
include/metask/agentcore.h
bindings/zig/build.zig
bindings/zig/build.zig.zon
bindings/zig/src/{root,protocol,types}.zig
bindings/rust/{Cargo.toml,Cargo.lock,link.cfg,build.rs,examples/,src/}
README.md
manifest.json
```

若 bundle 内的 Markdown 说明与 repository lock 锁定的 manifest 或官方 bundle SDK 冲突，以机器可读合同为准，并将冲突记录为 Metask AgentCore 依赖缺陷；不得据散文说明放宽或改写 MetaWork 的消费行为。

manifest schema 1 必须精确记录：

- `vendor = "metask"`、`name = "agentcore"`、package version；
- `source { commit, dirty }`；
- `toolchain.zig_version`；
- `target { id, architecture, os, abi, zig_target, rust_target }`；
- `build { optimize, strip }`；
- `link { requires_c_runtime, system_libraries, system_frameworks }`；
- `contract { binary_abi_status, binary_abi_version = 1, binary_abi_revision = 5, binary_abi_table_size = 168, capabilities = 4095 }`；
- 除 manifest 自身外的完整 `{path, sha256}` payload whitelist。

公司内部初步开发期，candidate bundle 直接来自本机精确路径 `metacodes/zig-out/agentcore/<target>`。MetaWork 根据 manifest target 选择显式 target policy 与 exact repository lock，对 candidate 做 artifact-only probe，并经 `agentcore:stage` 复制到 `.agentcore/bundle`；正式 build/test/package 只消费 staged root。当前不建设 resolver、cache、artifact repository 或跨机器分发。未知 target、artifact 缺失或校验失败时明确失败，禁止 generic/source fallback。

正式 Zig build 必须通过 staged `bindings/zig` package 获取 `metask_agentcore` module。MetaWork verifier 负责 exact lock/checksum/target/ABI 信任；官方 package 负责 module、capability/function-table 校验和 link graph。任何 active build 中的 revision 4 function table、`session_refresh_skill_catalog`、旧 table size/capability set、手工 Skill schema、SDK module graph 或 archive 直链都属于迁移失败。

## 10. revision 5 接收门槛

### candidate bundle acceptance

- 当前变更涉及的 target 使用 artifact-only consumer，只访问 candidate bundle，不访问 AgentCore 实现源码；未进入变更范围的 target 不替代也不反向阻塞当前验收；
- exact manifest bytes、payload checksum、target、toolchain、layout 和唯一 discovery symbol 校验；
- 隔离 Zig consumer 通过 candidate 官方 `bindings/zig` package 完成 source-free `Api.discover()`、link 和运行；
- probe 结束后再次校验 candidate，证明消费过程没有改写 bundle。

candidate probe 不导入 MetaWork Agent，也不承担 Runtime/Session、真实 agent loop 或产品语义验收；这些必须在 candidate stage 后由正式 Host gate 完成。

### staged 正式 Host gate

> macOS 与 Windows revision 5 exact artifact、candidate/stage、typed SDK discovery、Agent catalog ownership、typed Text/Skill Agent surface 和各自真实 Native vertical 已通过；macOS 另完成 Debug、Release 与签名 package 验收。两个 target 的结果互不替代；revision 4 不构成兼容要求。

- typed SDK 完成并通过 source-free consumer；
- status-before-result 和 diagnostic release 测试；
- 六个 StopReason 穷尽编译与 unknown code 测试；
- event/UI request malformed payload 测试；
- close/abort/join/callback quiescence race 测试；
- 同步 UI deadline/cancel/close/shutdown 测试；
- event pump fatal 能停止 in-flight Run；
- MetaWork 从真实 bundle 完成 link/run 集成。
- 每个平台的 Debug/Release/package 或 executable/module tests 必须使用该平台独立 staged identity；
- `.app` 不携带 AgentCore archive、header、Zig/Rust binding 源文件或 `.agentcore` staging 内容；
- architecture tests 证明正式 build 只从官方 dependency module 获取 SDK，且只有 `agent/` import `metask_agentcore`。

### stable policy

- v1 layout、function table 和 UI/control tags 不原地扩展；
- observation tags 可以兼容增加，旧 SDK 以 owned unknown observation 保留；
- MetaWork 每次仍锁定精确 bundle identity 和 checksum，不把 ABI stability 等同于自动升级；
- 支持周期、远程分发、Windows 正式分发与后续 Linux target 仍按独立发布政策推进。

Windows development baseline 已单独验证目标产物、系统链接输入、Debug/Release 和桌面自动化，但未完成安装、签名和更新。Linux 后续必须新增独立 lock、target policy、probe 和平台验证，不反向阻塞现有 macOS/Windows baseline。

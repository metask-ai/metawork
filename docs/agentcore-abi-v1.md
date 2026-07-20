# MetaWork AgentCore ABI v1 消费基线

> 状态：development ABI v1 revision 2；同步 macOS baseline 锁定精确 clean bundle，不声明 stable support policy
> 所有者：metacodes（原 cc-zig）负责 facade、SDK、bundle 和兼容政策；MetaWork 负责消费验证

本文记录 MetaWork 对当前 AgentCore binary ABI version 1 的真实消费边界。线程、事件泵和 Host 生命周期见 [AgentCore 集成契约](agentcore-integration.md)，验收顺序见 [Phase 0 验证计划](phase-0-validation.md)。

## 1. 版本含义

当前锁定的 metacodes development bundle `0.0.0-dev+36637f314c0f`（commit `36637f314c0f1c41bb1a2267ced7ad6a46100003`）发布 ABI v1 revision 2 的固定布局 header、Zig SDK、静态库和 manifest。API table 为 112 bytes。它是 macOS arm64、最低 macOS 13.0、Zig 0.16.0、ReleaseSafe、strip=true、链接 libc 的 clean artifact。这个精确开发基线不等于 stable ABI support policy。MetaWork 对它采用以下规则：

- 每次消费锁定精确 bundle identity、metacodes commit、target、toolchain 和 checksum；
- 对一个固定 bundle，ABI version/revision、layout、整数 code、callback 签名和语义不得漂移；
- 未来不兼容的 layout/code/ownership 变化必须发布新的 ABI revision/version；
- 兼容增量能力必须通过 capability 和新的 bundle identity 显式表达；
- v1 revision 2 struct size 必须精确匹配且全部 reserved 字段为零；MetaWork 不接受旧 104-byte API table 或旧 callback 签名；
- 新 observation tag 可以由新 bundle identity 兼容增加，旧 SDK 将其保存为 owned unknown observation；
- MetaWork 不复制 facade、header、code、event tag 或 UI JSON schema。

当前 v1 先证明同步 macOS 垂直链路，不把后续产品需求塞进一个并不存在的 ABI。

## 2. 当前 v1 baseline 必须具备的能力

| 能力              | 当前合同                                                                                                         |
| ----------------- | ---------------------------------------------------------------------------------------------------------------- |
| API discovery     | 从唯一 discovery symbol 获取并校验 ABI v1 revision 2 function table、112-byte size 和 required capabilities      |
| Runtime           | 创建/销毁共享 Runtime；Runtime 持有内置工具目录和 callback 引用所需基础设施                                      |
| Session           | 创建/销毁 Session；Session 持有 Provider、Conversation、permission memory、Workspace 输入和 Run 状态             |
| 同步 Run          | 文本输入进入真实 agent loop；一次 `session_run` 同步返回；每 Session 至多一个 active Run                         |
| built-in tools    | Session 可按 allowlist 使用 cc-zig built-in Read/Bash/Edit 等工具                                                |
| callback identity | Event、UI 和 Host tool callback 共享 validated `RunContext`：Session handle、run ID、Session-lifetime session ID |
| 结构化事件        | callback 输出现有 tagged `CoreEvent` JSON，并绑定 `RunContext`                                                   |
| 同步 Host UI      | callback 接收 `RunContext` + `UiRequest` JSON，并同步返回 answered/unavailable/fatal 与 response JSON            |
| abort             | 其他线程可以按 Session/Run 请求 user/timeout abort                                                               |
| 结果              | 成功 ABI 调用返回 stop reason code、turn count 和 tool count                                                     |
| 错误              | ABI function status 与 diagnostic buffer 独立于有效 `RunResult`                                                  |
| 所有权            | borrowed callback views 和 Host/library-owned buffer 的生命周期与 release 责任明确                               |

当前 bundle 也声明 synchronous Host tool capability，但 MetaWork 产品路径暂不使用，原因见第 6 节。

## 3. 当前 v1 明确不包含

- async UI continuation；
- `.pending` → `SuspendInfo` → `resumeRun`；
- Conversation/Session 跨进程持久化和重建；
- crash 后原地恢复同步 permission；
- strict Workspace security 保证；
- MetaWork Session/Run 可验证映射的正式 Host tools；
- `UiBackend.poll()` 生产消费链路或生成期实时 steering；
- Worker IPC；
- Windows 或其他 target bundle；
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
- 先用 cc-zig bundle SDK 校验 bytes view、JSON tag、payload shape 和嵌套字段；
- 在 callback 返回前深拷贝所有需要异步保留的 bytes；
- 携带正确 Session handle 与 run ID 进入 Host envelope；
- 不重新定义平行的 Agent event 类型体系；
- 不从 callback 直接调用 WebView；
- 无法验证、复制或入队关键事件时返回 callback fatal；canonical consumer notification 暂时 unavailable 时先执行有界 retry/deadline，耗尽后才返回 callback fatal，且不得撤销 pump 对 owned event 的所有权；
- callback 返回后的 Renderer/Bridge transport failure 不属于 ABI callback failure，不得直接 abort Run。

隔离的 artifact-only raw contract probe 可以使用 bundle 现有 raw SDK 表面证明 artifact 能调用，并记录 SDK 缺口；该代码不得进入正式 Host。

正式 Host 的硬门槛是 cc-zig bundle SDK 至少提供：

- typed ABI function `Status` validator；
- typed `StopReason` validator；
- 校验后的 `CoreEvent` decoder/view；
- 校验后的 `UiRequest` decoder/view；
- `UiResponse` encoder；
- unknown code/tag、非法 length/null、payload mismatch 的明确错误；
- callback 参数语义、线程和 ownership 文档。

上述 SDK 是随 bundle 编译进消费者的 cc-zig-owned source layer，不要求改变 C ABI layout，也不允许 MetaWork 自己补一份协议副本。

生产 build graph 只把 SDK 注入 `agent/` 的 event sink、event pump 和 Session 实现。App 通过 Agent Runtime 完成 ABI discovery；Workbench 只消费 Agent module root 暴露的 SDK-validated owned/typed 表面；Bridge wire DTO 不引用 SDK enum、owner 或 handle。该边界避免复制协议，同时阻止 transport 与产品层直接依赖 bundle module。

当前精确 baseline 的 `CoreEvent` 提供十个 known observation tags：`text_chunk`、`tool_start`、`tool_progress`、`progress`、`tool_result`、`usage`、`context_warning`、`auto_compact`、`retry_notice` 和 `stream_done`。有效的新 observation tag 被解码成 owned `UnknownCoreEvent`；当前 Host 在 SDK 完成结构、ownership 和 byte-bound 校验后立即释放并忽略它，不让未知产品语义消耗事件泵容量，也不得把 raw tag/payload 传给 Renderer。

当前 baseline 没有 typed `FileChange`、`Output` 或 plan-progress 事件。MetaWork 因此只能投影可验证的工具活动，并保持 `Files changed` / `Outputs` 模块隐藏；不得解析 Bash/Edit 参数或 stdout 猜测文件变更，也不得把普通新文件自动归类为 Output。

### 从 experimental revision 的直接迁移

| 旧表面                                            | 当前 revision 2 处理                                                              |
| ------------------------------------------------- | --------------------------------------------------------------------------------- |
| direct `ParsedCoreEvent.value`                    | 必须先处理 `DecodedCoreEvent.known/unknown`                                       |
| `stream_begin`、current-tool 与 diagnostic events | 从公开 observation contract 删除，MetaWork 不复制                                 |
| `plan_approval`、`custom` UI                      | 从 v1 control contract 删除，产品路径隐藏                                         |
| `suspended`、`backgrounded`、`budget` StopReason  | 从 v1 删除，unknown code fail closed                                              |
| `resource_limit` Status                           | 新增；pre-admission failure，Session 可复用                                       |
| admitted fatal status                             | `out_of_memory`、`core_error`、`callback_failed`、`internal_error` poison Session |
| permission mode codes                             | 只使用 SDK 常量；不保留旧数值映射                                                 |

## 6. 工具与 Workspace

### built-in tools

当前 baseline 的 Read/Bash/Edit 使用 cc-zig built-in tools：

- Runtime 发布允许的 built-in catalog；
- Session allowlist 再限制对模型可见和可 dispatch 的工具；
- permission 未得到同步明确批准前，危险动作不得发生；
- Bash 使用非交互子进程，不依赖 PTY；
- 测试使用临时或用户明确 trusted 的 Workspace 和受控命令。

当前 v1 明确不声称已完成 symlink、`..`、不存在写入目标、sandbox 和进程树等 strict Workspace security 全矩阵。该矩阵属于后续安全 capability。

### Host tools

revision 2 的 Host tool callback 也携带 `RunContext`，wire identity 已可验证；但 MetaWork 尚未定义产品级 Host tool catalog、权限、Workspace 与路由政策。因此：

- artifact-only probe 可以验证 Host tool callback/release mechanics；
- MetaWork 产品 Runtime 的 `host_tool_count` 必须为零；
- 不通过每 Session 一个 Runtime、全局 mutable current-session 或 TLS 绕过产品边界；
- 将来启用前必须建立独立 capability Gate 和多 Session security/contract test。

## 7. 同步 UI request

当前 v1 UI request 是同步 callback：

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

wire abort reason 只提供当前 v1 的中断机制；用户取消、timeout、Session close 和 application shutdown 进入 active Run 的 typed `TerminationSignal`。callback 内失败优先直接返回 callback fatal；callback 返回后只有 canonical event/projection failure 可以按 Run identity 请求 abort。`Run.execute()` 在 ABI 返回后产出同时包含 typed/raw status、StopReason、abort status 和最终 latch 的 immutable `TerminalResult`。Renderer/Bridge transport failure 由 Workbench policy 处理，不进入 Agent termination state。

Status 还包括 `resource_limit`。pre-admission validation/resource-limit/busy/stale-run failure 保持 Session 可复用；admission 后的 `out_of_memory`、`core_error`、`callback_failed` 或 `internal_error` poison Session，之后的 Run/abort 返回 `invalid_state`，仅 destroy 仍有效。

## 9. Bundle 交付

当前 bundle 至少包含：

```text
target-specific AgentCore library
C header
cc-zig-owned Zig SDK facade
cc-zig-owned typed protocol module
cc-zig-owned ABI types module
manifest
```

manifest 必须记录精确 metacodes commit/build identity、binary ABI version/revision、AgentCore API identity、Zig toolchain、resolved target、architecture、OS/ABI、构建模式、系统链接输入和每个文件 checksum。当前 revision 2 字段布局只按精确 lock 消费；MetaWork 不兼容旧字段名或旧 `files` 形状。

当前 MetaWork 从显式 bundle root 消费。同步 baseline 通过后，本地 content-addressed cache 和远程 artifact repository 必须继续使用相同 layout、identity 和 checksum 规则。artifact 缺失或校验失败时构建明确失败，禁止 source fallback。

## 10. 当前 v1 接收门槛

### raw contract probe

- macOS arm64 artifact-only consumer 不访问 cc-zig 实现源码；
- manifest、checksum、target、toolchain 和 API table 校验；
- Runtime/Session/run/abort/destroy；
- real agent loop、CoreEvent、同步 UI；
- built-in Read/Bash/Edit 在临时 Workspace 中运行；
- callback borrowed/release mechanics；
- busy/stale/too-late/invalid argument 等基本错误。

### 正式 Host gate

> Gate 4 的正式 Host 消费已通过；证据见 [Phase 0 Gate 4 验证报告](phase-0-gate-4-report.md)。该结果不包含 Gate 5 Bridge/event-pump 完整容量语义。

- typed SDK 完成并通过 source-free consumer；
- status-before-result 和 diagnostic release 测试；
- 六个 StopReason 穷尽编译与 unknown code 测试；
- event/UI request malformed payload 测试；
- close/abort/join/callback quiescence race 测试；
- 同步 UI deadline/cancel/close/shutdown 测试；
- event pump fatal 能停止 in-flight Run；
- MetaWork 从真实 bundle 完成 link/run 集成。

### stable policy

- v1 layout、function table 和 UI/control tags 不原地扩展；
- observation tags 可以兼容增加，旧 SDK 以 owned unknown observation 保留；
- MetaWork 每次仍锁定精确 bundle identity 和 checksum，不把 ABI stability 等同于自动升级；
- 支持周期、远程分发与 Windows target 仍按独立发布政策推进。

Windows 在 Phase 0B 单独验证目标产物和系统链接输入，不反向阻塞 macOS baseline。

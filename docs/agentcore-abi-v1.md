# MetaWork AgentCore ABI v1 消费需求

> 状态：目标能力已确认；binary layout、状态码数值和 capability bit 尚未冻结
> 所有者：cc-zig 负责实现、SDK、bundle 和兼容性政策；MetaWork 负责消费验证

本文定义 MetaWork 对首个可用 AgentCore 预编译库的需求，不规定 cc-zig 的内部类型、提交拆分或具体函数名。线程、事件泵、Host 状态与恢复语义见 [AgentCore 集成契约](agentcore-integration.md)。

## 1. 冻结原则

当前只冻结能力与行为，不冻结 wire layout：

- cc-zig 可以继续调整内部 `AgentRuntime`、`AgentSession`、工具目录和请求状态机；
- native Zig `pub` API 只是 cc-zig 源码接口，不等于 MetaWork 可消费的 binary ABI；
- 具体导出 symbol、函数表、struct layout、raw code 和 capability bit 由 cc-zig 在真实 consumer 验证后确定；
- ABI facade、public SDK definitions 和内部类型映射由 cc-zig 单一维护；
- MetaWork 不复制 cc-zig 协议，也不把 cc-zig source tree 纳入正式 build graph。

只有 cc-zig artifact-only consumer 和 MetaWork 真实 bundle 集成都通过后，ABI v1 才能标记 stable。

## 2. v1 必须具备的语义能力

| 能力 | MetaWork 要求 |
| --- | --- |
| Runtime 生命周期 | 可创建共享的 AgentCore 运行环境；有 Session 存活时不得销毁其依赖资源 |
| Session 生命周期 | 创建、销毁并持有 Provider、Conversation、权限记忆、Workspace 和 Run identity |
| 真实 Run | 文本输入进入真实 agent loop；Conversation 跨 Run 保留；每 Session 至多一个 in-flight Run |
| 结构化事件 | 输出 cc-zig 完整 `CoreEvent`，包括文本、工具、usage、context、retry 和 diagnostics |
| 真实工具 | 至少覆盖 Read、Bash、Edit；发布目录和实际 dispatch 使用同一 Session 工具权限上限 |
| Workspace | 接收规范化 Workspace root；文件和 shell 工具不得绕过 Workspace 与 Host 权限政策 |
| Host 请求 | 支持 question、permission、plan approval 和 custom 请求/响应，不退回 stdin/TUI |
| 挂起恢复 | pending 请求产生可持久化挂起状态；响应校验后恢复，同一动作不得重复执行 |
| 取消与失败 | 按 Session/Run 中断；区分用户取消、timeout 和 Host infrastructure failure |
| 结果与错误 | 返回完整 `StopReason`、turn/tool 计数、可选挂起信息和独立 ABI 调用错误 |
| 状态恢复 | cc-zig 提供足够信息，使 Conversation/checkpoint 能在进程重启后安全恢复 |
| 所有权 | callback 借用数据与 library-owned 结果有明确、可测试的生命周期和释放方式 |

上述名称是语义分类，不预先指定 capability bit 名称或数值。

## 3. Runtime、Session 与 Run 边界

cc-zig 当前可以继续演进内部 owner，但正式库必须保证：

- Runtime 只持有可共享、长生命周期的运行基础设施；
- Session 持有会话私有状态，不与其他 Session 串用 Workspace、工具白名单、Conversation 或 permission memory；
- Run 是同步执行单元，由 MetaWork 的有界 executor 调度；
- 空闲 Session 不长期占用执行线程；
- Session 销毁必须等待当前 Run 返回，并清理所有 Session-owned 执行单元；
- 取消是唯一必须支持从其他线程命中当前 Run 的控制操作；
- callback failure 必须让 Core 停止运行，不能只更新 Host UI 状态。

这些是行为要求，不要求 ABI 原样暴露 cc-zig 的 native owner 或 config struct。

## 4. 事件与回调

`CoreEvent` 仍是 Agent 结构化事件的唯一来源。ABI facade 必须穷尽映射固定 cc-zig 版本的全部事件变体，public SDK 必须校验 raw tag、payload size 和嵌套 view 后再提供类型化访问。

回调语义必须满足：

- 携带可路由到正确 Session 和 Run 的 identity；
- 同一 Session/Run 的事件交付顺序明确；
- callback 可能来自 AgentCore 或工具线程；
- callback 内所有 view 默认只在返回前有效；
- MetaWork 在 callback 返回前深拷贝所有异步保留数据；
- AgentCore/tool 线程不得直接调用 WebView；
- Host 无法复制或接收关键事件时，callback 能报告 fatal 并终止当前 Run。

ABI 不导出 Provider SSE、终端字节流或 MetaWork Host envelope。

## 5. 工具与 Workspace

cc-zig 负责工具 schema、Provider tool serialization 和执行语义。MetaWork 传入 Workspace 与工具权限上限，并对 Renderer 请求执行 Host 安全校验。

v1 验收必须证明：

- Session 只向模型发布允许的工具；
- Provider 伪造未发布工具名时不能进入实际 dispatch；
- Read 和 Edit 的最终解析路径不能越出 Workspace，包括 symlink、`..` 和不存在的写入目标；
- Bash 使用非交互子进程，不依赖 PTY，并受到 Workspace、permission、sandbox、timeout 和进程树清理约束；
- permission 未明确批准前，Write/Edit/Bash 等危险动作没有发生；
- Host 实现的工具若进入 v1，必须与内置工具使用同一发布和 dispatch 权限边界，并定义参数校验和结果释放责任。

MetaWork 不要求 v1 暴露 native `ToolDefinition`、内部 registry、allocator 或通用 `HostServices`。

## 6. Host 请求与 suspend/resume

请求通道与事件通道分离：

- `CoreEvent` 是 Core → Host 的单向通知；
- Host 请求是 Core → Host → Core 的有类型请求/响应；
- request identity 必须绑定 Session、Run 和具体请求；
- answered、pending、unavailable 和 fatal 必须可区分；
- pending 时不得读取未填写的响应，也不得提前执行受保护动作；
- 当前每个 turn 只支持一个可恢复挂起点；
- 只有顶层 Run 可以挂起，subagent 请求必须明确失败；
- stale、重复、错误 Session、错误 Run 和错误响应类型必须被拒绝；
- restore/resume 后工具或审批结果只能消费一次。

permission 是否与其他 Host 请求共享同一内部实现由 cc-zig 决定，但 v1 必须通过“挂起 permission → 保存 → 恢复 → 批准 → 恰好执行一次”的端到端测试。

## 7. StopReason、错误与内存

九个 `StopReason` 必须全部保留：`end_turn`、`max_turns`、`aborted`、`tool_error`、`api_error`、`tool_loop`、`suspended`、`backgrounded`、`budget`。

- cc-zig facade 对内部 enum 做无 `else` 的穷尽映射；
- bundle SDK 校验 raw code 后提供类型化 enum；
- MetaWork 再对 SDK enum 做无 `else` switch；
- ABI 调用错误与一次有效 Run 的 `StopReason` 分开；
- `.aborted` 必须保留足够原因，使 Host 能区分 cancelled、interrupted 和 failed；
- native Zig slice、enum、optional、error union、tagged union 和 allocator 不得跨 binary ABI；
- 跨 ABI 数据只能是 callback-scoped borrowed view，或由明确 release 操作释放的 library-owned 数据。

具体 code 数值和 struct layout 在最终冻结阶段确定。

## 8. Bundle 交付

cc-zig 正式提供的 bundle 至少包含：

```text
target-specific AgentCore library
cc-zig-owned public SDK definitions
manifest
```

manifest 必须记录精确 cc-zig commit/release、binary ABI version、AgentCore API version、Zig toolchain、target、architecture、构建模式、系统链接输入和每个文件的 checksum。

开发期 bundle 可以由 cc-zig 写入本地 artifact source；正式流程再上传远程。切换分发来源不能改变 MetaWork 的链接方式。MetaWork 必须锁定精确 identity 和 checksum，禁止 `latest`、可变 tag、源码 fallback 和 checksum 不匹配后继续构建。

## 9. v1 不要求

- `UiBackend.poll()` 或生成期实时 steering；
- 当前 Run 内任意 `queue_message` 注入；
- subagent UI 挂起与父子恢复编排；
- 后台 Worker/进程协议；
- 动态 MCP、skills、Swarm、Cron；
- CLI、REPL、TUI、PTY、WebView 或 MetaWork Bridge API；
- MetaWork 数据库、产品事件 envelope 或 Renderer view model。

`backgrounded` 仍保留为 cc-zig `StopReason`，但不代表 v1 已完成 MetaWork 后台转移产品能力。

## 10. 冻结门槛

ABI v1 layout、状态码数值、capability bits 和兼容政策只能在以下验证后冻结：

- macOS arm64 artifact-only consumer 不访问 cc-zig 实现源码；
- 真实 agent loop 和完整事件 decode；
- Read/Bash/Edit、Workspace 越界拒绝和 permission；
- pending、持久化、Session 重建和 resume；
- user/timeout/Host-failure abort；
- busy、stale、重复响应、错误 tag、未知 code、OOM 和 callback fatal；
- 九变体 `StopReason` 的 facade 与 SDK 双重穷尽测试；
- MetaWork 从真实 bundle 完成 link/run 集成；
- bundle manifest、checksum 和空 cache 获取验证。

Windows 使用同一语义与 code 集合，但在 Phase 0B 单独验证目标产物和系统链接输入；macOS Phase 0A 不等待 Windows。

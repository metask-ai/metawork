# MetaWork 桌面核心工具接入方案

> 状态：Windows 与 macOS 普通 Task 统一使用完整工具集合；受限 profile 的 Session 收窄否定侧探针仍是独立证据项
>
> 范围：将已由 Windows 与 macOS bundle 共同验证的 AgentCore built-in 工具名称接入现有 MetaWork Runtime/Session 路径
>
> 目标：在不增加第二套执行器、工具协议或权限数据面的前提下，让支持的桌面 target 使用同一套工具 profile。

本文只定义桌面工具名称接入，不替代 [AgentCore ABI v1 消费合同](agentcore-abi-v1.md)、[AgentCore 集成契约](agentcore-integration.md)、[Product 内部架构](product-architecture.md)、[Renderer Bridge 合同](renderer-bridge-contract.md) 或 [验证规范](validation.md)。

## 1. 目标范围

当前桌面目标工具固定为 11 个 AgentCore built-in 名称：

```text
Read / Write / Edit / Glob / Grep
Bash / BashOutput / KillShell
AskUserQuestion
WebSearch / WebFetch
```

其中现有产品路径已经使用 `Read / Bash / Edit / AskUserQuestion`；新增接入是 `Write / Glob / Grep / BashOutput / KillShell / WebSearch / WebFetch`。

对 MetaWork 来说，`WebSearch` 和其他 built-in 一样只是传给 AgentCore 的精确工具名。MetaWork 不实现 WebSearch executor，不注册 Host tool，也不解析 Provider SSE。Windows 与 macOS library 中出现的 11 个名称和对应描述只能作为实现侧证据；正式开放仍以各 target 的真实 Session 探针和 vertical 证据为准。

## 2. 本次不处理的内容

- 尚未通过对应 bundle verifier 和 Session 探针的其他平台工具可用性；本 hard cut 不建立第三交付面；
- AgentCore catalog、binding identity 或 ABI revision 变更；当前 revision 8 名称数组已足够完成本次名称接入；
- ABI Host tools、MCP 工具合并、第二套 ToolManager 或 MetaWork 自建进程/网络执行器；
- permission contract 重构；沿用 [会话权限系统重构方案](permission-system-refactor-plan.md)；
- WebSearch 的 provider 差异、网络策略和外部服务可用性；这些不是工具名称 admission 的身份问题；
- bundle 中其他实现名称，例如 `Task`、`Agent`、`ApplyPatch`、`CodeMap`、`Cron*`、`NotebookEdit` 等。

## 3. 根因与现状

当前缺口是 MetaWork 侧工具集合没有接入 profile，而不是 AgentCore ABI 缺少工具执行接口：

- `src/agent/session/wire.zig` 的桌面默认工具集合此前固定为四个名称；
- Runtime 创建时只发送这四个 `builtin_tools`，`host_tool_count` 仍为 0；
- Session fresh create 和 restore 都从 `allowed_tools` 生成 Session 级收窄；
- `src/workbench/projection.zig` 创建正式 Task Session 时没有传入新的工具选择，因此此前始终依赖四工具默认值；
- Runtime 级集合必须是当前 target 已验证工具的并集，Session 级 `allowed_tools` 只能在其内收窄；只改 Session 名称而不扩充 Runtime 集合不会完成接入。

当前 Windows 与 macOS bundle 分别使用其 target-specific 静态库，对应 lock source 均为 `df554537aea946776946238b657ad29b20f0c852`（ABI v1 revision 8）。该证据不替代真实 Session 运行证据。

## 4. 最小架构

只保留现有 owner 边界：

| Owner | 职责 |
| --- | --- |
| AgentCore | built-in 工具执行、参数/结果、CoreEvent、UI request 和生命周期 |
| Workbench | 桌面工具 profile、Task admission、工具 readiness 投影 |
| Application | 创建共享 Agent Runtime 并注入现有生命周期 capability |
| Bridge/Renderer | 展示已验证的 capability，提交白名单化 intent |

产品定义一个普通 Task 的完整集合，以及两个受限集合：

| Profile | 桌面工具名称 |
| --- | --- |
| `full` | `Read`、`Write`、`Edit`、`Glob`、`Grep`、`Bash`、`BashOutput`、`KillShell`、`AskUserQuestion`、`WebSearch`、`WebFetch` |
| `local` | `Read`、`Write`、`Edit`、`Glob`、`Grep`、`Bash`、`BashOutput`、`KillShell`、`AskUserQuestion` |
| `network` | `WebSearch`、`WebFetch` |

普通桌面 Task 使用 `full` profile，因此能看到本次已接入的 11 个 built-in 名称；`local` / `network` 只用于明确的受限 Task。Profile 不是新的执行层。Workbench 在创建 Task 时选择已通过当前 target 探针的名称集合，并通过 Session `allowed_tools` 传入；Application 创建的共享 Runtime 注册已验证名称并集。受限 profile 的收窄语义仍需独立否定侧证据。未知名称、未验证名称和空选择都必须阻止 admission，不能静默降级或把空集合编码成 `allowed_tools = null`。

## 5. 分阶段实施

### Phase 0：各桌面 bundle 与名称探针

1. 使用对应 target lock 校验 `.agentcore/bundle`；
2. 运行现有 verifier、API discovery、Runtime/Session create 和 lifecycle probe；
3. 对 11 个名称逐个运行受控 Session prompt，记录名称是否被接受、对应 CoreEvent/tool result、终态和错误；
4. 在 Runtime 注册已验证名称并集、Session 只传 `local` 集合的条件下，使用确定性的 provider fixture 提交 `WebFetch` tool-use（以及至少一个其他被排除名称），确认 AgentCore 返回拒绝/不可用而不产生工具执行结果；
5. 仅将肯定侧和否定侧都通过的名称/收窄语义写入 target verified set。

### Phase 1：接入现有四工具

保持 `Read / Bash / Edit / AskUserQuestion` 的既有行为，新增：

- Runtime builtin 集合由四个默认名称改为桌面 verified set；
- Workbench Task admission 显式传入 `local` 或 `network` profile；
- 现有 lifecycle、permission occurrence、projection 和 reload/cancel/terminal 回归继续通过。

### Phase 2：接入新增名称

按探针结果逐个加入：

- `local`：`Write / Glob / Grep / BashOutput / KillShell`；
- `network`：`WebSearch / WebFetch`。

每个名称都必须有一次真实执行记录和对应失败路径；只修改 allowlist 字符串不构成接入完成。

## 6. 验收条件

- 每个已支持桌面 target 的 staged bundle 与对应 lock 完全匹配，且 verifier 通过；
- 每个已支持桌面 target 的 11 个名称都有可定位的 Session 探针结果；
- Runtime `builtin_tools` 是 verified set 的并集，Session `allowed_tools` 只做收窄；local 排除 `WebFetch` 的否定侧运行证据仍是 network profile 正式开放前的独立 Gate；
- Workbench 不再依赖四工具默认值，profile 选择通过真实 Task admission 进入 Session；
- `WebSearch` 在 MetaWork wire 层仍只有一个工具名，不产生 provider-specific identity；
- unknown name、未验证名称和空选择 fail closed；
- `host_tool_count` 保持 0，MCP、permission、shutdown 和 AgentCore 协议继续使用各自 source of truth；
- 验证分别声明 Windows x86_64 GNU 与 macOS arm64 的可用性；不推断其他平台可用性；
- Renderer/Bridge 只显示当前 target verified set 中的真实 capability。

## 7. 依赖文档

- [AgentCore ABI v1 消费合同](agentcore-abi-v1.md)
- [AgentCore 集成契约](agentcore-integration.md)
- [会话权限系统重构方案](permission-system-refactor-plan.md)
- [Renderer Bridge 合同](renderer-bridge-contract.md)
- [验证规范](validation.md)

## Verification note

Phase 0 implementation evidence (Windows and macOS staged bundles, 2026-08-14): the target-specific tool-name probe verified the locked bundle and created a Session for each of the 11 names on the current target. It used `shell_policy=unrestricted` because AgentCore correctly rejects shell names when shell policy is disabled. This proves name admission under the required shell condition; it does not replace per-tool execution evidence. The one-time name probe was removed after its conclusion entered this contract and the ordinary Task profile regression.

- The desktop Application selects `full` for ordinary production Workbench Tasks, so the 11 verified built-ins are exposed to the model on both supported targets. `local` and `network` remain explicit restricted profile options.
- The desktop restore path carries the same profile as fresh Task creation, so restart cannot silently fall back to a smaller default set.
- The real vertical exercises the local built-ins in one AgentCore Run; `WebSearch` and `WebFetch` are exposed by the ordinary `full` profile as AgentCore built-in names, without a second executor or provider-specific MetaWork implementation.
- The restart corruption found during the vertical was caused by the persistence projection serializing bounded permission buffers as JSON arrays. `permissionSummaryWire` now returns the typed wire struct and preserves slices; `zig build test-lifecycle -Doptimize=Debug` and the Windows vertical both pass.
- The name probe remains positive-side evidence for all 11 names. No provider fixture or second executor is added merely to manufacture a WebFetch denial; the negative-side Session narrowing probe remains a separately tracked network-profile gate.

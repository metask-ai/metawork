# MetaWork 桌面核心工具接入方案

> 状态：Windows 与 macOS 普通 Task 统一使用 MetaWork Agent 固定工具集合
>
> 范围：将已由 Windows 与 macOS bundle 共同验证的 AgentCore built-in 工具名称接入现有 MetaWork Runtime/Session 路径
>
> 目标：在不增加第二套执行器、工具协议或权限数据面的前提下，由 Agent 模块统一定义符合 MetaWork 产品语义的工具能力面。

本文只定义桌面工具名称接入，不替代 [AgentCore ABI v1 消费合同](agentcore-abi-v1.md)、[AgentCore 集成契约](agentcore-integration.md)、[Product 内部架构](product-architecture.md)、[Renderer Bridge 合同](renderer-bridge-contract.md) 或 [验证规范](validation.md)。

## 1. 目标范围

当前 MetaWork Agent 固定开放 10 个 AgentCore built-in 名称：

```text
Read / Write / Edit / Glob / Grep
Bash / BashOutput / KillShell
WebSearch / WebFetch
```

AgentCore bundle 仍是面向所有消费者的通用能力全集，并继续支持 `AskUserQuestion`；MetaWork 不修改 bundle 或 ABI，只在 Agent 产品化边界中不注册、不向 Session 开放该工具。需要补充信息时使用普通 Assistant 回复与下一次 Composer 输入。

对 MetaWork 来说，`WebSearch` 和其他 built-in 一样只是传给 AgentCore 的精确工具名。MetaWork 不实现 WebSearch executor，不注册 Host tool，也不解析 Provider SSE。Windows 与 macOS library 中出现的 11 个名称和对应描述只能作为实现侧证据；正式开放仍以各 target 的真实 Session 探针和 vertical 证据为准。

## 2. 本次不处理的内容

- 尚未通过对应 bundle verifier 和 Session 探针的其他平台工具可用性；本 hard cut 不建立第三交付面；
- AgentCore catalog、binding identity 或 ABI revision 变更；当前锁定 bundle 的名称数组已足够完成本次名称接入；
- ABI Host tools、MCP 工具合并、第二套 ToolManager 或 MetaWork 自建进程/网络执行器；
- permission contract 重构；沿用 [会话权限系统重构方案](permission-system-refactor-plan.md)；
- WebSearch 的 provider 差异、网络策略和外部服务可用性；这些不是工具名称 admission 的身份问题；
- bundle 中其他实现名称，例如 `Task`、`Agent`、`ApplyPatch`、`CodeMap`、`Cron*`、`NotebookEdit` 等。

## 3. 根因与现状

当前缺口是 MetaWork 侧工具集合没有接入 profile，而不是 AgentCore ABI 缺少工具执行接口：

- `src/agent/session/wire.zig` 定义 MetaWork Agent 的固定 built-in 集合及精确 wire name；
- Runtime 注册和 fresh/restore Session allowlist 必须使用同一集合，`host_tool_count` 仍为 0；
- Workbench 不持有 built-in profile、wire name 或 `allowed_tools`，只消费 Agent 形成后的执行能力；
- bundle 已验证能力是外部上限，MetaWork Agent 集合是产品化子集；bundle 支持但产品未开放不是 admission failure。

Exact target artifact、ABI identity 与验证状态分别由 [AgentCore ABI v1 消费合同](agentcore-abi-v1.md)和[验证规范](validation.md)记录；本计划不复制版本事实。

## 4. 最小架构

只保留现有 owner 边界：

| Owner           | 职责                                                                          |
| --------------- | ----------------------------------------------------------------------------- |
| AgentCore       | built-in 工具执行、参数/结果、CoreEvent、UI request 和生命周期                |
| Agent           | MetaWork Agent 能力塑形、固定 built-in 集合、Runtime 注册和 Session allowlist |
| Workbench       | Task admission、执行秩序和产品状态；不选择 built-in 工具                      |
| Application     | 创建共享 Agent Runtime 并注入现有生命周期 capability                          |
| Bridge/Renderer | 展示已验证的 capability，提交白名单化 intent                                  |

当前产品没有用户可见的 built-in 工具模式，因此不建立 `full/local/network` profile。Agent 模块向 Runtime 注册固定集合，并在 fresh create 与 restore 时把同一非空集合写入 Session `allowed_tools`；公开 Session options 不允许调用方扩大或收窄它。未知名称、未验证名称和空集合必须阻止 Agent 初始化，不能静默降级或把空集合编码成 `allowed_tools = null`。

## 5. 分阶段实施

### Phase 0：各桌面 bundle 与名称探针

1. 使用对应 target lock 校验 `.agentcore/bundles/<target-id>`；
2. 运行现有 verifier、API discovery、Runtime/Session create 和 lifecycle probe；
3. 对 bundle 声明的名称逐个运行受控 Session probe，记录名称是否被接受、对应 CoreEvent/tool result、终态和错误；
4. 只有同时通过 target probe 与 MetaWork 产品验收的名称才加入 Agent 固定集合。

### Phase 1：形成 MetaWork Agent 能力面

- Agent 固定集合接入 `Read / Write / Edit / Glob / Grep / Bash / BashOutput / KillShell / WebSearch / WebFetch`；
- `AskUserQuestion` 保持 bundle capability，但不进入 Runtime 注册或 Session allowlist；
- 删除 Application/Workbench profile plumbing，fresh 与 restore 只消费 Agent 固定集合；
- lifecycle、permission occurrence、projection、cancel/terminal 和恢复回归继续通过。

## 6. 验收条件

- 每个已支持桌面 target 的 staged bundle 与对应 lock 完全匹配，且 verifier 通过；
- 每个已支持桌面 target 的 bundle 工具探针结果仍可定位，且不把 bundle 支持误写为 MetaWork 产品开放；
- Runtime `builtin_tools` 与 fresh/restore Session `allowed_tools` 精确等于 MetaWork Agent 固定集合；
- `AskUserQuestion` 不在该集合中；Agent capability gate 的否定测试还必须证明对应 ABI request 在 pending 产品状态建立前 callback fatal；
- Workbench 与 Application 不持有 built-in profile 或工具名称；
- `WebSearch` 在 MetaWork wire 层仍只有一个工具名，不产生 provider-specific identity；
- unknown name、未验证名称和空选择 fail closed；
- `host_tool_count` 保持 0，MCP、permission、shutdown 和 AgentCore 协议继续使用各自 source of truth；
- 验证分别声明 Windows x86_64 GNU、macOS arm64 与 macOS x86_64 的可用性；不推断其他平台可用性；
- Renderer/Bridge 只显示当前 target verified set 中的真实 capability。

## 7. 依赖文档

- [AgentCore ABI v1 消费合同](agentcore-abi-v1.md)
- [AgentCore 集成契约](agentcore-integration.md)
- [会话权限系统重构方案](permission-system-refactor-plan.md)
- [Renderer Bridge 合同](renderer-bridge-contract.md)
- [验证规范](validation.md)

## Verification note

Phase 0 implementation evidence (Windows and macOS staged bundles, 2026-08-14): the target-specific tool-name probe verified the locked bundle and created a Session for each of the 11 bundle names on the current target. It used `shell_policy=unrestricted` because AgentCore correctly rejects shell names when shell policy is disabled. This proves AgentCore capability, not MetaWork product exposure. The one-time probe was removed after its conclusion entered this contract.

- The Agent module exposes 10 built-ins to the model on both supported targets; Application and Workbench do not select a profile.
- Fresh and restore Session paths apply the same fixed Agent-owned allowlist.
- The real vertical exercises the applicable built-ins in one AgentCore Run; `WebSearch` and `WebFetch` remain AgentCore built-in names without a second executor or provider-specific MetaWork implementation.
- The restart corruption found during the vertical was caused by the persistence projection serializing bounded permission buffers as JSON arrays. `permissionSummaryWire` now returns the typed wire struct and preserves slices; `zig build test-lifecycle -Doptimize=Debug` and the Windows vertical both pass.
- The name probe remains positive-side bundle evidence for all 11 names; the Agent-layer regression separately proves that `AskUserQuestion` is absent from MetaWork's 10-tool product surface.

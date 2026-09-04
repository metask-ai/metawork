# AGENTS.md

本文件适用于整个 MetaWork 仓库。它只定义执行入口、真源路由和仓库级不可绕过 Gate，不替代产品、架构、合同或验证规范，也不镜像当前实现状态。

## 开始工作前

先检查工作树并保留用户已有改动，再定位并读取与当前任务直接相关的真源章节。只有当变更影响整份文档的 owner、跨章节不变量或稳定格式时才需要阅读全文；只有规范性合同发生变化时才同步更新真源。涉及多个独立合同时才读取和修改多份真源。

| 触及或修改的范围 | 真源 |
| --- | --- |
| release version、产品 identity 与 Bridge command allowlist | [`app.zon`](app.zon) |
| 产品对象、能力是否存在、用户可观察行为与范围 | [产品需求](docs/requirements.md) |
| 已开放能力的 UI、交互、视觉、响应式与呈现 gate | [UI 设计规范](docs/ui-design.md) |
| 顶层 owner、依赖原则、进程、故障域与安全边界 | [高层架构](docs/architecture.md) |
| Product 跨对象事务、并发、恢复及其与 Agent 的协作 | [Product 架构](docs/product-architecture.md) |
| Account 状态、事务、Metask 合同、持久化、并发与恢复 | [Account 架构](docs/account-architecture.md) |
| Renderer Bridge wire、command、event、Snapshot 与 transport 语义 | [Renderer Bridge 合同](docs/renderer-bridge-contract.md) |
| module root、目录 owner 与代码依赖映射 | [工程结构与所有权](docs/project-structure.md) |
| MetaWork 对 AgentCore Session、工具、Skill、Permission 与生命周期的产品消费 | [AgentCore 集成契约](docs/agentcore-integration.md) |
| AgentCore binary ABI 与 bundle 接受语义 | [AgentCore ABI v1 合同](docs/agentcore-abi-v1.md) |
| AgentCore target-specific exact artifact identity | `build_support/agentcore-bundle.*.lock.json` |
| Agent-owned Completion、Provider codec、Transport 与取消 | [Completion 架构](docs/completion-architecture.md) |
| Storage SQL contract、backend、limits、migration 与 lifecycle | [Storage 架构](docs/storage-architecture.md) |
| macOS 构建、签名、公证与分发合同 | [macOS 分发](docs/macos-distribution.md) |
| Windows 安装器、Authenticode 与分发合同 | [Windows 分发](docs/windows-distribution.md) |
| 测试归属、验证入口、长期证据与未闭合能力 | [验证规范](docs/validation.md) |

`README.md` 只负责项目入口和快速开始，不是规范。

## 文档更新门槛

文档只定义跨实现必须长期成立的合同、不变量、owner 边界和验证责任。以下变化必须更新对应真源：

- 用户可观察的产品对象、能力、行为、范围、交互或呈现 gate 发生变化；
- public API、wire contract、持久化格式、外部集成合同、ABI 接受政策或稳定 artifact 格式发生变化；
- owner、依赖方向、进程或故障域、安全、并发、生命周期或恢复不变量发生变化；
- 支持平台、分发承诺、验证责任、标准入口、长期证据结论或已登记能力缺口发生变化。

实现修复、同一 owner 内部重构、普通测试调整，以及不改变合同的 artifact rebuild、commit、checksum、lock 或 bundle refresh 不要求修改规范文档。当前路径、数量、hash、覆盖明细和实现进度等机器可判定事实由唯一代码、类型、manifest、lock、生成输入或测试拥有；具有外部语义的 identifier、wire name 和 version policy 仍由对应合同定义。阶段计划、迁移过程和一次性 probe 不进入规范，除非用户明确要求建立 decision record。用户明确建立的 decision record 以文档路径作为稳定身份；只有用户明确批准 supersede 时才能替换其语义，并须同步修正全部引用。普通计划、复盘和实施记录不因标记为“最终”或“待实施”自动成为 decision record。

普通实现允许零文档修改；单一合同变化通常只修改一份真源。其他文档只链接唯一真源，不复制需要同步维护的摘要。发现既有非规范性实现镜像时不要继续机械同步；若清理不在当前任务范围，应向用户报告，只有文档治理或相关合同清理本身属于当前任务时才删除或改写。

## 工作方式

- 收口当前任务直接造成的代码、测试和 allowlist 不一致，不扩展到未经请求的相邻重构。
- 不为内部实现保留平行 active path、无要求的兼容层或静默 fallback；public contract 或用户明确批准的迁移需要兼容时，以对应合同为准。
- 只有在没有 active contract、回归或长期证据职责时，才删除失去职责的实现、fixture 和阶段材料；Git 历史负责恢复，不建立 active archive。
- 选择满足当前要求的最简单实现。模块拆分必须有具体的 owner、内聚性、依赖隔离、生命周期或可测试性收益，不以行数、目标目录树或未来 capability 为理由。
- 机器 identifier、外部路径、symbol 和 wire name 保持精确；产品文字使用 MetaWork、Metask 和 Metask AgentCore。
- 同一事实只在一份 source of truth 中定义。机器可判定事实优先由唯一机器真源拥有；散文只定义其外部语义、约束和理由。
- feature、fix、refactor、test 或 artifact refresh 默认不修改本文件。只有仓库级执行政策、真源路由或不可绕过 Gate 本身变化时才修改；修改必须能说明它为何适用于未来无关任务，以及为何不能由机器 guard 或领域真源承担。

## 不可绕过的 Gate

- 当前请求未明确授权时，不得破坏 public API、持久化数据或格式、外部集成合同及其他稳定外部格式；明确授权的迁移仍必须同步收口实现、验证和对应真源。
- 必须遵守对应架构真源定义的 owner 与依赖方向，不得通过反向 import、通用 facade、直接系统 effect 或平行协议绕过 owner。
- credential 和 secret 默认只能存在于对应 Host owner 与执行所需的有界 owned copy。唯一例外是用户在本地桌面客户端显式填写的 Model Connection API Key：它可以在 Renderer 表单和 `create`/`replaceCredential` typed Bridge command 中短暂存在，Bridge 不得记录、缓存或投影，Models 必须立即交给系统 credential storage；任何 secret 仍不得进入日志、event、snapshot、产品历史或持久化 metadata。Account、OAuth、MCP 与其他 secret 不得借此建立 Renderer/Bridge 数据路径。
- 外部依赖只通过架构批准的 canonical 输入消费；不得使用源码复制、可变版本或静默 fallback 绕过依赖验证。
- machine guard、allowlist 与 fail-closed verifier 的拒绝是强制结果。除非用户明确请求对应政策变化，不得修改或弱化它们，也不得用等价重试、替代路径或跳过验证绕过拒绝；required evidence 或 dependency 缺失时必须明确失败。

## 验证规则

按实际失败模式选择能观察该问题的最小充分测试层；测试文件位置不能反向决定 owner。

- 纯文档删除或改写：检查链接、锚点、残留引用和 `git diff --check`；不运行 runtime 测试。
- Renderer/TypeScript：运行 typecheck 与受影响的 Renderer suite；合同变化追加跨语言 fixture 和 Bridge tests。
- 平台无关 Zig：运行对应 Zig test root；共享 owner 或 module graph 变化运行正式 Native test graph。
- architecture、allowlist 或 bundle verifier：运行对应 guard，以及能命中该失败模式的当前平台 build/probe。
- lifecycle、真实 ProductDelivery 或 AgentCore 调用链：运行对应 lifecycle/vertical；只有存在独立平台失败模式时才追加平台验证。
- 不因修改 `build.zig`、脚本名或 lock 路径机械扩大平台矩阵；若错误会在下一次 build/test 中平台无差异地 fail closed，当前平台验证即可。

标准命令、平台矩阵和长期证据规则以 [验证规范](docs/validation.md) 为准。缺少 canonical staged bundle 时必须明确失败，不能跳过 AgentCore 用例后报告成功。

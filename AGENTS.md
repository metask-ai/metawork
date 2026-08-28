# AGENTS.md

本文件适用于整个 MetaWork 仓库。它只定义执行规则、真源路由和不可绕过的 Gate，不替代产品、架构、合同或验证规范。

## 开始工作前

先检查工作树并保留用户已有改动，再按实际触及的边界读取对应 source of truth。变更语义时同步更新同一真源；不要在 README、AGENTS、测试说明或相邻文档中建立第二份定义。

| 触及或修改的范围                                            | 必须读取的真源；语义变化时同步更新                                    |
| ----------------------------------------------------------- | --------------------------------------------------------------------- |
| 产品对象、行为与范围                                        | [docs/requirements.md](docs/requirements.md)                          |
| UI、交互、视觉、响应式与 capability gate                    | [docs/ui-design.md](docs/ui-design.md)                                |
| 技术选型、系统 owner、进程与安全边界                         | [docs/architecture.md](docs/architecture.md)                          |
| Product owner、事务、并发、恢复及其与 Agent 的协作           | [docs/product-architecture.md](docs/product-architecture.md)          |
| Account 状态、事务、Metask 合同、持久化、并发与恢复          | [docs/account-architecture.md](docs/account-architecture.md)          |
| Renderer Bridge command、event、Snapshot 与 transport       | [docs/renderer-bridge-contract.md](docs/renderer-bridge-contract.md)  |
| active tree、目录 owner 与依赖方向                          | [docs/project-structure.md](docs/project-structure.md)                |
| AgentCore Session、工具、Skill、Permission 与生命周期       | [docs/agentcore-integration.md](docs/agentcore-integration.md)        |
| AgentCore bundle、ABI 与 required capability                | [docs/agentcore-abi-v1.md](docs/agentcore-abi-v1.md)                  |
| Agent-owned Completion、Provider codec、Transport 与取消    | [docs/completion-architecture.md](docs/completion-architecture.md)    |
| Storage SQL contract、backend、limits、migration 与 lifecycle | [docs/storage-architecture.md](docs/storage-architecture.md)        |
| macOS 本地签名、Developer ID、DMG、公证与发布验证           | [docs/macos-distribution.md](docs/macos-distribution.md)              |
| Windows 安装器、Authenticode 与发布验证                     | [docs/windows-distribution.md](docs/windows-distribution.md)          |
| 测试归属、验证状态、证据、回归入口与能力缺口                 | [docs/validation.md](docs/validation.md)                              |

`README.md` 只负责项目入口和快速开始，不是规范。

## 工作方式

- 同一个根因涉及的代码、测试、allowlist 和文档一次收完整；不要留下只改名字、只搬文件、兼容层或平行路径。
- 删除已经失去职责的实现、fixture 和阶段文档；Git 历史负责恢复，不建立 active archive 或“以防万一”的 fallback。
- 已批准或挂起决策引用的文档路径是稳定身份。只有用户显式批准 supersede 时才能替换其语义，并须同步修正全部引用。
- 选择满足当前要求的最简单实现。只有形成独立 owner 或可测试不变量时才拆模块，不为行数、目标目录树或未来 capability 创建空层。
- 机器 identifier、外部路径、symbol 和 wire name 保持精确；产品文字使用 MetaWork、Metask 和 Metask AgentCore。
- 同一事实只在一份 source of truth 中定义；其他文档只能链接或提供不产生新语义的摘要。

## 不可绕过的 Gate

### 合同与能力

- `app.zon` 是 MetaWork release version 与产品 identity 真源；根 npm、Renderer 和 Zig package 必须精确镜像。
- Renderer Bridge revision、persistence、AgentCore ABI 和 bundle schema 是彼此独立的合同。任何合同版本或稳定外部格式变化都必须先得到用户显式批准。
- `app.zon`、Zig 与 TypeScript 的 Renderer Bridge command catalog 必须精确一致。
- 当前 command catalog、required capability、工具集合和产品开放能力以对应真源为准。ABI 中存在不等于产品已开放；未通过 Requirements 与 Validation Gate 的能力必须保持隐藏并 fail closed。

### Owner 与依赖方向

- React + Tailwind 是唯一正式 Renderer。不得建立第二套 Renderer、通用 Desktop Interface、平行协议或统一 facade。
- Application 只做 composition、平台 capability 注入、生命周期驱动和跨 owner 编排；Account、Product Control、Agent 与 Bridge 分别拥有自己的领域状态。下层 owner 不得反向导入 `src/app/` 实现。
- Product Control 独占 Workspace、Task、Run、产品历史、共享 Executor、admission 及其内部 shutdown 顺序；Agent 独占 Runtime、Session、Conversation 和 AgentCore 集成。Agent 不得取得 Scheduler 或反向管理 Product Control 资源。

### 外部依赖与平台能力

- 正式应用只消费 canonical `.agentcore/bundles/<target-id>` 及其中的官方 `bindings/zig` package。禁止 AgentCore 源码依赖、源码复制、可变版本、静默 fallback 或 MetaWork-owned ABI/事件镜像。
- 系统 effect 优先使用 Native SDK Runtime API。低层 SDK 原语或平台 API 只能存在于 Architecture 与 Validation 已逐项登记的 compatibility seam；任何 MetaWork 代码都不得访问、解释或强转 `PlatformServices.context`。

### 安全、并发与生命周期

- credential 和 secret 只能存在于对应 Host owner 与执行所需的有界 owned copy；不得进入 Renderer、Bridge、日志、event、snapshot 或产品历史。
- 每个 Session 至多一个 in-flight operation，队列、worker、事件和 payload 必须有界。跨 callback 保留的 borrowed bytes 必须在返回前深拷贝。
- shutdown 必须先停止 ingress，唤醒并收口 wait，abort/join worker 并等待 callback quiescence，再按 owner 逆序释放；transport failure 不得伪造产品 Run cause。

## 验证规则

验证前先确定：哪份真源定义了不变量、哪个 owner 负责、失败时唯一指向什么问题，以及哪个测试层能以最小充分成本观察它。测试位置不能反向决定 owner。

- 纯文档删除或改写：检查链接、锚点、残留引用和 `git diff --check`；不运行 runtime 测试。
- Renderer/TypeScript：运行 typecheck 与受影响的 Renderer suite；合同变化追加跨语言 fixture 和 Bridge tests。
- 平台无关 Zig：运行对应 Zig test root；共享 owner 或 module graph 变化运行正式 Native test graph。
- architecture、allowlist 或 bundle verifier：运行对应 guard，以及能命中该失败模式的当前平台 build/probe。
- lifecycle、真实 ProductDelivery 或 AgentCore 调用链：运行对应 lifecycle/vertical；只有存在独立平台失败模式时才追加平台验证。
- 不因修改了 `build.zig`、脚本名或 lock 路径机械扩大平台矩阵。若错误会在下一次 build/test 中平台无差异地 fail closed，当前平台验证即可。

标准命令、平台矩阵和长期证据规则以 [docs/validation.md](docs/validation.md) 为准。缺少 canonical staged bundle 时必须明确失败，不能跳过 AgentCore 用例后报告成功。

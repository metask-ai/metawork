# AGENTS.md

本文件适用于整个 MetaWork 仓库。它只定义执行规则和不可绕过的护栏，不替代产品、架构或合同文档。

## 开始工作前

按任务实际触及的边界阅读 source of truth：

| 变更范围                                                      | Source of truth                                                    |
| ------------------------------------------------------------- | ------------------------------------------------------------------ |
| 产品对象、行为与范围                                          | [docs/requirements.md](docs/requirements.md)                       |
| UI 信息架构、交互与 capability gate                           | [docs/workbench-ui-design.md](docs/workbench-ui-design.md)         |
| 技术选型、系统 owner 与安全边界                               | [docs/architecture.md](docs/architecture.md)                       |
| active tree、目录 owner 与依赖方向                            | [docs/project-structure.md](docs/project-structure.md)             |
| AgentCore 线程、事件、所有权和生命周期                        | [docs/agentcore-integration.md](docs/agentcore-integration.md)     |
| AgentCore bundle、ABI 与 required capability                  | [docs/agentcore-abi-v1.md](docs/agentcore-abi-v1.md)               |
| Metask OAuth、catalog、ExecutionTarget 与 Account persistence | [docs/metask-account-contract.md](docs/metask-account-contract.md) |
| 验证状态、证据和持续回归入口                                  | [docs/validation.md](docs/validation.md)                           |

`README.md` 只负责项目入口与快速开始，不是规范。

## 工作方式

- 开始修改前检查工作树，保留用户已有改动，不清理或覆盖无关文件。
- 同一个根因涉及的代码、测试、allowlist 和文档一次收完整；不要拆成只改名字、只搬文件或留半套兼容层的连续小变更。
- 删除已经失去职责的实现、fixture 和阶段文档；Git 历史负责恢复，不建立 active archive、第二份规范或“以防万一”的平行路径。
- 只有形成独立 owner 或可测试不变量时才拆模块；不为行数、目标目录树或未来 capability 创建空层。
- 机器 identifier、外部路径、symbol 和 wire name 保持精确；产品与说明文字使用 MetaWork、Metask 和 Metask AgentCore。
- `app.zon` 是 MetaWork release version 真源；根 npm、Renderer 和 Zig package 版本必须精确镜像。Bridge、persistence、AgentCore ABI 与 bundle schema 不随产品版本联动。任何合同类版本标识的变更都必须先得到用户显式同意。
- 变更规范时同步检查实现和验证影响；变更实现时检查对应 source of truth 是否仍准确。

## 架构护栏

### Renderer 与 Bridge

- React + Tailwind 是唯一正式 Renderer；不建立 `.native` 替代层、第二套 Renderer 或通用 Desktop Interface。
- Native SDK 直接构成 Zig Host，不增加 `NativeSdkAdapter` 或框架替换层。
- Renderer Bridge 产品合同是 `metawork.renderer-bridge` 固定 revision 1。快速开发阶段直接原地 hard cut command、event、payload 与 wire 语义；不得为临时合同形态递增 revision、保留兼容层或在 snapshot 内建立局部 schema version。`connect` 精确匹配 identity/revision 后才开放产品路径；任何 revision 变更必须先得到用户显式同意。
- `app.zon`、Zig 和 TypeScript command catalog 必须完全一致。Renderer 对 Host payload 做 runtime decode；Host 执行 origin、command、payload、Workspace、Task 和权限校验。
- Bridge 只拥有 command ingress 与 `ProductDelivery` transport；产品状态和 Run policy 归 Workbench。automation 只能驱动真实产品路径，不注册测试专用协议或第二数据面。

### AgentCore 依赖

- 正式应用只消费 canonical `.agentcore/bundle` 与官方 `bindings/zig` package。外部 bundle root 只用于 candidate probe/stage；禁止源码依赖、源码复制、Git/path implementation dependency、`latest`、可变 tag 和静默 fallback。
- Metask AgentCore 是 binary ABI facade 和 Agent 结构化协议的唯一 owner。MetaWork 不复制 ABI code、event tag、UI JSON schema，不维护上游 facade/SDK 的平行测试套件，也不建立 `AgentEvent` / `WorkbenchEvent` 镜像协议。
- 正式 Host 只使用 bundle SDK 校验后的 typed `Status`、`StopReason`、`CoreEvent`、`UiRequest` 和 `UiResponse`。unknown、malformed、ownership 或 notification failure 必须 fail closed；详细处理以 AgentCore 两份 source of truth 为准。
- 当前产品不注册 ABI v1 Host tools；Read/Bash/Edit 使用 AgentCore built-in tools。MetaWork 不解析 Provider SSE，也不以 PTY/xterm/终端字节流作为 Agent 协议。

### Owner、并发与生命周期

- App 只做 composition 和平台 capability 注入；Account 拥有 credential 与 ExecutionConfig；Workbench 拥有 Workspace/Task/Run、Executor 和产品历史；Agent 拥有 Runtime/Session/Conversation；Bridge 拥有 Renderer transport。
- Workbench 独占 executor、queue、workers、admission 和 shutdown。Agent Runtime 不接收 Scheduler capability，不反向 enqueue 或销毁 Workbench 资源。
- 每个 Session 至多一个 in-flight Run；队列和 worker 数量必须有界。Conversation 与跨 Run 状态属于 Session，不能引用 run-scoped arena。
- AgentCore/tool 线程不得调用 WebView。跨 callback 保留的 borrowed bytes 必须在返回前深拷贝；control event 不得静默丢弃。
- shutdown 必须先停止 ingress、唤醒 wait、abort/join 并等待 callback quiescence，再断开 owner，最后释放 transport 和 Runtime。不得用 transport failure 直接伪造 Run cause。

### Account、安全与能力声明

- production provider、model、base URL 和 API Key 只来自已锁定的 Metask Account contract；禁止环境默认值、Renderer 字段或 Bridge payload 注入。
- credential 只由 Host Account 和 Workbench-owned runtime config 持有，不得进入 Renderer、Bridge、日志、event、snapshot 或产品历史。
- 当前只允许临时或用户明确 trusted 的 Workspace。strict Workspace security、持久 permission、正式 Host tools、plan approval、custom UI、Output 和 FileChange 未通过能力验收前必须隐藏，不得由 Renderer 猜测或模拟。
- 当前应用仍是同进程 prototype。单 AgentCore Worker 是后续方向；Worker 落地前不得宣称具备进程隔离、crash recovery 或跨进程 Conversation 恢复。

## 文档变更路由

- 产品需求变化更新 `docs/requirements.md`。
- UI 交互规则变化更新 `docs/workbench-ui-design.md`。
- 技术决策或 owner 变化更新 `docs/architecture.md`；实际目录和依赖变化更新 `docs/project-structure.md`。
- AgentCore 线程、所有权、生命周期和 Shell 行为变化更新 `docs/agentcore-integration.md`。
- AgentCore ABI、bundle、required capability 或兼容门槛变化更新 `docs/agentcore-abi-v1.md`。
- Metask Account 外部合同或 persistence revision 策略变化更新 `docs/metask-account-contract.md`。
- 验收矩阵、长期证据、持续回归入口和能力缺口变化更新 `docs/validation.md`。
- 同一事实只在一份规范中定义；其他文档链接或做不产生新语义的摘要。

## 验证规则

按实际失败模式选择最小充分验证，不按“碰过某类文件”机械扩大平台矩阵：

- 纯文档删除或改写：检查链接、锚点、残留引用和 `git diff --check`；不运行 runtime 测试。
- Renderer/TypeScript：运行 typecheck 与受影响的 Renderer suite；合同变化同时运行跨语言 fixture 和 Bridge tests。
- 平台无关 Zig：运行对应 Zig test root；共享 owner 或 module graph 变化运行正式 Native test graph。
- 架构、allowlist 或 bundle verifier：运行 architecture/bundle guard，以及能命中该失败模式的当前平台 build/probe。
- lifecycle、真实 ProductDelivery 或 AgentCore 调用链：运行对应 lifecycle/vertical；只有存在独立平台失败模式时才追加 macOS 或 Windows 验证。
- 不能仅因修改了 `build.zig`、脚本名或 lock 路径就要求全平台回归。若错误会在下一次 build/test 中 fail closed 且平台无差异，当前平台验证即可。

标准命令和平台矩阵以 [docs/validation.md](docs/validation.md) 为准。缺少 canonical staged bundle 时必须明确失败，不能跳过 AgentCore 用例后报告成功。普通可重现测试结果不写入长期证据账本；报告中只声明实际执行过的命令与结果。

# MetaWork 验证规范

> 状态：初始技术验证已经收口；本文维护当前验证状态、可复现命令、证据索引和覆盖缺口

本文是验证控制面，不是产品或技术设计文档。它只回答四个问题：验证什么、依据哪份规范、证据在哪里、还缺什么。产品行为以 [产品需求](requirements.md) 为准，系统决策以 [高层架构](architecture.md) 为准，AgentCore 生命周期和 ABI 分别以 [AgentCore 集成契约](agentcore-integration.md)与 [ABI v1 消费合同](agentcore-abi-v1.md)为准。

## 1. 状态含义

| 状态 | 含义 |
| --- | --- |
| 已验证 | 在精确 commit、平台和 artifact 上有可定位执行证据；后续代码变化仍必须持续回归 |
| 自动化已覆盖 | 当前 test graph 有绑定到该不变量的确定性测试；不等同于真实平台或外部服务验收 |
| 人工验收待完成 | 实现和自动化可能存在，但真实窗口、平台、可访问性或产品判断尚无完整证据 |
| 尚未实现 | 只有需求或架构边界，不得从当前 baseline 推导为可用能力 |

状态必须绑定证据，不能仅凭代码存在、关键词扫描或历史聊天记录升级。

## 2. 当前证据账本

早期编号式计划和阶段报告已经从 active tree 删除。仍然支撑当前结论的执行记录以精确 Git object、保留的 artifact migration 报告和 repository lock 定位，不恢复成第二套规范文档。

| 验证对象 | 规范来源 | 可定位证据 | 已验证结论与限制 |
| --- | --- | --- | --- |
| AgentCore ABI v1 revision 3 macOS baseline | [ABI v1 消费合同](agentcore-abi-v1.md) | [revision 3 migration 报告](agentcore-revision-3-migration-report.md)；MetaWork commit `f0e39f43b520ce97b4c390d590d2807019b9c4a3`；`build_support/agentcore-bundle.macos.lock.json` | 2026-07-21 在精确 dirty-provenance arm64 macOS bundle 上通过 candidate/stage、typed SDK、正式 Host、Debug/Release、桌面自动化和 package；不声明 stable ABI |
| Metask Account 与真实 AgentCore Run | [产品需求](requirements.md)、[Metask Account API 合同](metask-account-contract.md) | `git show dbaaf81b0217d4016944960ee8621e9a23274f05:docs/phase-0-validation.md` 中 2026-07-20 的真实链路记录 | 打包 `.app` 完成 OAuth、profile、API Key/model catalog、execution persistence，以及 `gpt-5.5`、`deepseek-v4-pro` AgentCore Run；不证明 Task-first 人工交互矩阵完成 |
| Windows development baseline | [高层架构](architecture.md)、[ABI v1 消费合同](agentcore-abi-v1.md) | `git show dbaaf81b0217d4016944960ee8621e9a23274f05:docs/windows-phase-0b-report.md`；`build_support/agentcore-bundle.windows.lock.json` | 2026-07-21 在 clean x86_64 GNU bundle 上通过 candidate SDK probe、Native Debug/Release 和桌面自动化；不包含安装、签名、更新或完整安全矩阵 |
| fault-domain 方向 | [高层架构](architecture.md) | `git show dbaaf81b0217d4016944960ee8621e9a23274f05:docs/phase-0-gate-7-report.md` | 独立 crash 对照证明同进程为零进程级隔离，并选择单 AgentCore Worker；该一次性 harness 不进入 active tree，产品 Worker 尚未实现 |

Git object 只保存一次性执行事实；当前行为与边界始终以 active source of truth 为准。若规范与旧证据冲突，旧证据不得覆盖当前规范，也不得被当作新代码已经回归的证明。

普通自动化结果可由当前 test graph 重现，不进入长期证据账本，也不冠以会在下一次代码提交后立即失真的“当前回归”状态。提交是否通过由对应 commit 的真实执行结果负责；只有稳定发布、artifact migration 或无法由普通自动化重现的平台/外部服务事实保留在上表。

## 3. 持续回归入口

### 平台无关与当前开发环境

```bash
npm ci
npm run format:check
npm run check
npm test
```

`npm test` 必须覆盖 Renderer runtime、Zig serializer 与 TypeScript decoder 共用的投影 fixture、架构边界、AgentCore bundle 校验、child-process wrapper 和正式 Zig test graph。缺少 canonical staged bundle 时必须明确失败，不能跳过 AgentCore 相关用例后继续报告成功。

### macOS

```bash
npm run build:debug
npm run build:release
npm run package:macos
```

涉及 AgentCore candidate、正式 Host、Renderer reload、产品数据面或生命周期时，按变更范围增加：

```bash
AGENTCORE_BUNDLE_ROOT=/absolute/path/to/bundle npm run probe:agentcore
npm run test:lifecycle
npm run test:agentcore-vertical:macos
```

AgentCore vertical 是当前真实桌面自动化入口，同时验证真实 `ProductDelivery` 主线程 revision emit、Renderer reload、snapshot 恢复和 AgentCore Run；automation 不建立第二套 Renderer 数据面。一次性阶段聚合脚本和 fault-domain harness 不再保留。

### Windows development baseline

```powershell
npm run agentcore:stage -- C:\absolute\path\to\x86_64-windows.win10...win11_dt-gnu
npm run test:windows:bringup
```

macOS 与 Windows 结果不能互相替代。安装器、签名、更新、file dialog、process tree、timeout 和完整 security matrix 需要独立证据。

## 4. Task-first Account 验收矩阵

产品行为由 [产品需求的 Metask Account、恢复与 Workbench 章节](requirements.md)定义；下表只记录覆盖状态和证据。

| 验证项 | 自动化证据 | 状态与缺口 |
| --- | --- | --- |
| 未登录或后台准备期间保留 Workbench、Workspace 选择和 New task 草稿 | `scripts/composer-render.test.mjs`: `an Account prerequisite blocks sending without blocking the Workspace draft`；`scripts/workbench-navigation.test.mjs`: `Composer drafts survive a WebView reload scope and fail safely when storage is unavailable` | 自动化已覆盖；macOS/Windows 真实窗口待复核 |
| Task/Run admission 只服从 Host 状态和 Workspace grant | `src/workbench/projection.zig`: `Workbench starts without execution and fails Task admission closed`；`scripts/first-task-flow.test.mjs`: `the first send cannot bypass the Host-issued workspace grant` | 自动化已覆盖 |
| 登录先提交 account-only，再进入独立 catalog generation | `src/account/state.zig`: `login commits account-only before a separate catalog generation`；`src/app.zig`: `Account coordinator commits login and execution as separate gates` | 自动化已覆盖 |
| 历史选择、单候选自动推进，只有真实歧义要求用户选择 | `scripts/account-panel.test.mjs`: `background catalog preparation does not ask for a manual load step`、`only a real catalog ambiguity asks for the matching choice` | Renderer 表面已覆盖；Host automatic-selection branch 缺少专门行为测试，整体仍为部分覆盖 |
| OAuth 等待可重新打开或取消，callback/deadline 能唤醒 | `src/account/state.zig`: `Host product readiness exposes login recovery without Renderer inference`；`scripts/account-panel.test.mjs`: `authorization wait can reopen or cancel without exposing the OAuth URL`；`src/account/loopback.zig`: `attempt deadline closes the listener and wakes a blocked accept` | 自动化已覆盖；系统浏览器启动失败仍需真实平台记录 |
| catalog failure、retry 和 restart-required 均有恢复动作 | `src/account/catalog.zig`: `catalog status mapping is fail closed`；`src/account/state.zig`: `restore failure enters a terminal restart-required state`；`scripts/account-panel.test.mjs`: `retryable and restart-required failures never leave an actionless spinner` | 主要状态已覆盖；网络切换、离线和服务端慢响应待平台验证 |
| Bridge mutation timeout 后 resync，结果不确定时不重放 | `scripts/bridge-client.test.mjs`: `a wedged mutation times out once and is never replayed by the Bridge client`；`scripts/frontend-boundaries.test.mjs`: `timed-out mutations resync from Host state without automatic replay` | 自动化已覆盖 |
| Renderer reload、snapshot generation 和 stale chunk fail closed | `scripts/snapshot-client.test.mjs`: `Workbench snapshot assembly rejects a stale chunk`；`scripts/snapshot-demand.test.mjs`: `snapshot retry is exhausted once per generation and requires an explicit reset`；`scripts/workbench-connection.test.mjs`: `explicit recovery replaces a generation whose snapshots stay unavailable` | 自动化已覆盖；长时间 detach 与真实窗口重建压力待完成 |
| `en-US` / `zh-CN`、键盘、focus、窗口尺寸和 200% text | `scripts/i18n.test.mjs`: `English is the complete source catalog and zh-CN has exact key parity`、`application product copy is catalog-backed` | 仅文案 catalog 自动化；真实 macOS/Windows UI、可访问性和产品审核待完成 |

人工证据未完成时，本矩阵不得整体标记为“已验证”。静态 boundary test 只能证明代码结构，不替代对应行为测试。

## 5. Renderer Bridge contract 验收

规范性策略见 [高层架构的 Renderer Bridge wire contract](architecture.md#71-renderer-bridge-wire-contract)。当前合同身份为 `metawork.renderer-bridge`，revision 为 `1`；snapshot 不再维护局部版本。

持续回归必须证明：

- connect identity/revision 匹配时才建立 product delivery connection；
- 未协商或 mismatch 时，Account、Task、event 和 snapshot 产品路径全部被现有门禁拒绝；
- 不兼容是 terminal bootstrap error，Renderer 不执行瞬时重试；
- Zig/TypeScript revision 与 command catalog 精确一致；
- Host serializer → TypeScript decoder、TypeScript command payload → Host decoder 均有跨语言 fixture/行为测试；
- snapshot 只由完整 Bridge contract revision 覆盖，不重新引入局部 schema version。

## 6. 尚未验证的能力

本节只防止错误能力声明；行为和技术边界仍由对应 source of truth 定义。

| 能力 | 规范来源 | 当前状态 |
| --- | --- | --- |
| 单 AgentCore Worker 与 crash semantics | [高层架构](architecture.md)、[AgentCore 集成契约](agentcore-integration.md) | 方向已确定，产品 transport/supervisor 尚未实现 |
| async pending、suspend/resume 和跨进程 Conversation 恢复 | [产品需求](requirements.md)、[AgentCore 集成契约](agentcore-integration.md) | 当前 ABI 不提供，不得宣称可用 |
| strict Workspace security、正式 Host tools 和持久权限规则 | [产品需求](requirements.md)、[高层架构](architecture.md) | 尚未完成独立安全验收 |
| typed Output、FileChange、plan progress/approval 和 custom UI | [产品需求](requirements.md)、[ABI v1 消费合同](agentcore-abi-v1.md) | 当前 ABI 不提供，对应 UI 必须隐藏 |
| Windows distribution 与 Linux target | [产品需求](requirements.md)、[高层架构](architecture.md) | Windows 仅 development baseline；Linux 尚未接入 |

## 7. 证据维护规则

- 本文只维护验证状态、证据索引、复现命令和覆盖缺口，不重新定义产品或技术合同。
- 只有具备长期审计价值的稳定发布、artifact migration 或不可由自动化重现的真实平台/外部服务结果才单独保留证据；开发期阶段叙事在结论进入 source of truth、测试或本账本后删除。
- 每条“已验证”必须能定位到日期、commit、平台、artifact/外部依赖、命令或结果；仅写“Git 历史里有”不合格。
- 同一事实只保留一个规范性定义；其他位置链接该定义。证据可以证明某个版本满足规范，但不能成为第二份规范。
- `rg`、格式检查和文件存在性检查只属于卫生验证，不能替代合同、运行时和平台行为测试。

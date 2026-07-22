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
| Metask Account 与真实 AgentCore Run | [产品需求](requirements.md)、[Metask Account API 合同](metask-account-contract.md) | `git show dbaaf81b0217d4016944960ee8621e9a23274f05:docs/phase-0-validation.md` 中 2026-07-20 的真实链路记录 | 打包 `.app` 完成 OAuth、profile、API Key/model catalog、execution persistence，以及 `gpt-5.5`、`deepseek-v4-pro` AgentCore Run；不证明登录优先、设置、模型选择或成熟 Workbench 人工交互完成 |
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

## 4. 登录优先与成熟 Workbench 验收矩阵

产品行为由 [产品需求的 Metask Account、恢复与 Workbench 章节](requirements.md)定义；下表只记录覆盖状态和证据。

| 验证项 | 当前证据 | 状态与缺口 |
| --- | --- | --- |
| cold restore 不闪现 disabled Workbench；signed out 只显示独立登录界面和唯一主动作 | `frontend/src/app/App.tsx` 在 Host readiness 为 `ready` 前只挂载 `AccountGate`；`scripts/account-panel.test.mjs`: `signed-out readiness is an independent surface with one primary action`；`scripts/frontend-boundaries.test.mjs`: `login-first composition gates every Workbench surface on Host readiness` | Renderer gate 与旧 Composer prerequisite 清理已覆盖；真实 Native cold window 仍需平台视觉验收 |
| 登录先提交 account-only，再自动进入独立 catalog generation；`execution_ready` 前不开放 Workbench | `src/account/state.zig`: `login commits account-only before a separate catalog generation`；`src/app.zig`: `Account coordinator commits login and execution as separate gates`；`frontend/src/app/App.tsx` 的 `AccountGate` 分支 | Host 提交链与 Renderer Workbench gate 已覆盖；真实 OAuth 到 ready 的 Native 窗口连续性仍待平台验收 |
| OAuth 等待可重新打开或取消，callback/deadline 能唤醒 | `src/account/state.zig`: `Host product readiness exposes login recovery without Renderer inference`；`scripts/account-panel.test.mjs`: `authorization wait can reopen or cancel without exposing the OAuth URL`、`Account cancel stays available while an ordinary command is locally busy`；`src/account/loopback.zig`: `attempt deadline closes the listener and wakes a blocked accept` | Host 与新独立登录表面均有行为证据；系统浏览器失败和真实窗口仍待验证 |
| 历史选择、单候选自动推进，只有真实 API/模型歧义要求用户选择 | `scripts/account-panel.test.mjs`: `background catalog preparation does not ask for a manual load step`、`only a real catalog ambiguity asks for the matching choice` | 新首次启动选择 UI 已覆盖真实歧义和无手动加载入口；Host automatic-selection branch 仍需在端到端链路复验 |
| OAuth identity 成功后 catalog failure、retry、no keys/models 和 restart-required 不退回未登录 | `src/account/catalog.zig`: `catalog status mapping is fail closed`；`src/account/state.zig`: `restore failure enters a terminal restart-required state`；`scripts/account-panel.test.mjs`: `retryable and restart-required failures never leave an actionless spinner` | 状态内核、新登录表面与双语恢复文案已覆盖；Metask 管理入口、离线/慢响应和真实平台仍待验证 |
| Workspace 是独立 projection，空 Workspace、最近使用、重新授权、移除与聚合 Task signal 可恢复 | `src/workbench/projection.zig`: `Workspace registry owns empty selection recent use authorization and capacity`、`Workspace projection derives aggregate Task signals and removal preserves history`；`tests/workbench/executor_lifecycle_test.zig`: `Workspace removal interrupts live Runs without deleting Task history`、`Workspace removal failure remains a retryable Workspace fact`；`scripts/composer-render.test.mjs`: `Workspace removal failure survives refresh with an honest retry surface`、`an available Workspace exposes removal while a removing Workspace blocks new work`、`removing the final empty Workspace leaves a stable focus destination`；revision 2 跨语言 fixture、decoder 与 Bridge command tests | Workbench owner、optimistic epoch、Task 稳定归属、授权 admission、聚合、两阶段移除与 Workspace 级失败事实已进入 revision 2 产品合同；目录能力在同一 Host 选择命令内消费，Renderer 只持有 Workspace identity，不再从 Task 路径派生或持有 grant |
| API 在设置页切换，模型在 New task Composer 显示；设置与 Composer 默认值一致 | 当前只有紧凑 `AccountPanel`；没有正式 settings route | **尚未实现**；必须覆盖脱敏目录、模型 pending/error、管理入口和键盘交互 |
| 默认 API/模型变化不自动改绑已有 Task；已有 Task 保留当前 execution binding epoch，只有显式 rebind 可创建新 epoch | `src/workbench/projection.zig`: `default replacement preserves Task generation and installs the next admission default`、`execution replacement gate rejects live Task state and admits closed history`、`released Task credential is permanently scrubbed from every product projection`、`clearing the last default execution scrubs its credential before secure zero`、`known credential matching chooses the longest overlapping secret`、`opaque credential redaction is UTF-8 safe across product inputs and assistant chunks`、`assistant redaction withholds a UTF-8 codepoint across credential chunks`；`src/app.zig` 分离 default 与 identity replacement | 当前进程内 Task-owned execution generation、错误 generation admission、旧/新 credential 投影清洗、最长匹配、opaque credential 的完整 codepoint 与跨 chunk 清洗、Run/RunRef identity 与关闭/删除/关机清理已覆盖；binding epoch history 与跨重启 rebind 仍未实现 |
| Host 重启后历史 Task 不静默采用当前默认配置；精确恢复或显式 rebind 均保留旧 Run 事实 | 当前 persistence revision 2 只恢复一个默认 execution family；当前不承诺跨 Host Task history，AgentCore 也不提供跨进程 Conversation 恢复 | **尚未实现**；目标先恢复只读 history，再按能力提供从历史新建 Task、exact-match restore 或 `rebind_required`；需要 binding descriptor/epoch persistence、optimistic epoch、原子新 Session 和配置边界事件测试 |
| New task 以 Composer 为主；运行后转为工作轨迹；Inspector 没有内容时不占固定列宽 | `scripts/composer-render.test.mjs`: `New task opens as an editable Composer with its execution context`、`New task does not render or reserve an empty activity panel`；`scripts/first-task-flow.test.mjs`: `cancelling first-send Workspace selection preserves the draft boundary` | New task Composer、真实本地任务示例、首次发送选择 Workspace、取消保留草稿和模型/Workspace 上下文已实现；960 px 与 1320 px 仅作为窄窗/常规桌面回归样本，不是产品最小尺寸或固定设计基线；已有 Task 的固定 `TaskActivity` 仍待 Inspector 子任务替换，不得据此宣称整行完成 |
| Inspector 有稳定的 Task 标题栏开关，不因普通 Run start/terminal、usage 或工具活动自动开合；打开后保持到用户关闭或切换 Task | 当前 `TaskActivity` 是常驻右栏，不具备按 Task 显隐状态 | **尚未实现**；需覆盖标题栏开关与 `aria-expanded`、上下文详情入口、Needs your attention 单次自动打开、terminal Last run summary、Task 切换、窄窗口覆盖层和正文宽度稳定性 |
| mutation pending 按账号、Workspace、Task 和请求作用域隔离，不因单一 busy 冻结整个界面 | `frontend/src/app/App.tsx` 按 Account、Workspace、Task identity、Run cancellation、UI response 与 connection 分域；`scripts/workbench-store.test.mjs`: `pending scopes isolate unrelated mutations and reject duplicate admission` | 当前 Renderer 已移除全局 `busy !== null` gate；Task pending 可跨 Task 并存且同 scope 同步拒绝重复 admission，取消与请求保留独立逃生路径；后续 Bridge hard cut 仍需持续回归 timeout 后只 resync、不重放 |
| New Task admission 使用已安装默认 generation；既有 Task 的后续 Run 使用当前 binding epoch，两者都服从 Workspace authorization/epoch 和相应 gate | `src/workbench/projection.zig`: `Workbench starts without execution and fails Task admission closed`、`default replacement preserves Task generation and installs the next admission default`、`delete waits for RunRef quiescence and stale generations fail validation`、`product Task identity is independent from Agent Session route identity`、`event projection failure routes by Agent Session identity not product Task identity`；`scripts/first-task-flow.test.mjs`: `the first send cannot bypass the Host-projected Workspace identity` | 当前进程内 generation/binding/Workspace epoch admission、稳定产品 Task identity、内部 Session route、projection failure、RunRef identity 与 shutdown 已覆盖；rebind epoch race 等待后续 capability |
| Bridge mutation timeout 后 resync，结果不确定时不重放 | `scripts/bridge-client.test.mjs`: `a wedged mutation times out once and is never replayed by the Bridge client`；`scripts/frontend-boundaries.test.mjs`: `timed-out mutations resync from Host state without automatic replay` | 自动化已覆盖；新 scoped pending 不得破坏该边界 |
| Renderer reload、snapshot generation 和 stale chunk fail closed | `scripts/snapshot-client.test.mjs`: `Workbench snapshot assembly rejects a stale chunk`；`scripts/snapshot-demand.test.mjs`: `snapshot retry is exhausted once per generation and requires an explicit reset`；`scripts/workbench-connection.test.mjs`: `explicit recovery replaces a generation whose snapshots stay unavailable` | 自动化已覆盖；长时间 detach 与真实窗口重建压力待完成 |
| `en-US` / `zh-CN`、键盘、focus、窗口尺寸和 200% text | `scripts/i18n.test.mjs`: `English is the complete source catalog and zh-CN has exact key parity`、`application product copy is catalog-backed` | 仅文案 catalog 自动化；登录、设置、模型选择、Inspector 和真实 macOS/Windows 可访问性待完成 |

人工证据未完成时，本矩阵不得整体标记为“已验证”。静态 boundary test 只能证明代码结构，不替代对应行为测试。

## 5. Renderer Bridge contract 验收

规范性策略见 [高层架构的 Renderer Bridge wire contract](architecture.md#71-renderer-bridge-wire-contract)。当前合同身份为 `metawork.renderer-bridge`，revision 为 `2`；snapshot 不再维护局部版本。

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
| 登录优先 Renderer、独立 Workspace projection、Task-bound ExecutionConfig/rebind、设置页与稳定 Inspector | [产品需求](requirements.md)、[Workbench UI 设计](workbench-ui-design.md)、[高层架构](architecture.md) | 登录优先 Renderer gate、revision 2 Workspace wire/Renderer、当前进程 Task-owned execution binding facts 与 Host Workspace owner 已自动化覆盖；跨重启 rebind、正式设置页和 Inspector 仍未完成，不得整体宣称可用 |
| Windows distribution 与 Linux target | [产品需求](requirements.md)、[高层架构](architecture.md) | Windows 仅 development baseline；Linux 尚未接入 |

## 7. 证据维护规则

- 本文只维护验证状态、证据索引、复现命令和覆盖缺口，不重新定义产品或技术合同。
- 只有具备长期审计价值的稳定发布、artifact migration 或不可由自动化重现的真实平台/外部服务结果才单独保留证据；开发期阶段叙事在结论进入 source of truth、测试或本账本后删除。
- 每条“已验证”必须能定位到日期、commit、平台、artifact/外部依赖、命令或结果；仅写“Git 历史里有”不合格。
- 同一事实只保留一个规范性定义；其他位置链接该定义。证据可以证明某个版本满足规范，但不能成为第二份规范。
- `rg`、格式检查和文件存在性检查只属于卫生验证，不能替代合同、运行时和平台行为测试。

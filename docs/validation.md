# MetaWork 验证规范

> 状态：初始技术验证已经收口；本文维护持续回归归属、当前验证状态、可复现入口、长期证据和覆盖缺口

本文是验证控制面，不是产品或技术设计文档。它只回答四个问题：依据哪份规范验证什么、由哪个测试层负责、证据在哪里、还缺什么。产品行为以[产品需求](requirements.md)为准，系统边界以[高层架构](architecture.md)和[Product 内部架构](product-architecture.md)为准，Renderer、AgentCore 与外部合同分别由对应 source of truth 定义。

普通测试名称、实现位置和逐项断言由当前 test graph 与测试源码负责，不在本文建立第二份目录。只有测试层或归属规则、验证入口、长期证据、平台状态或覆盖缺口变化时才更新本文。

## 状态与证据纪律

| 状态           | 含义                                                                         |
| -------------- | ---------------------------------------------------------------------------- |
| 已验证         | 在精确 commit、平台和 artifact 上有可定位执行证据；后续变化仍须持续回归      |
| 自动化已覆盖   | 当前 test graph 有绑定到该不变量的确定性测试；不等同于真实平台或外部服务验收 |
| 人工验收待完成 | 实现和自动化可能存在，但真实窗口、平台、可访问性或产品判断尚无完整证据       |
| 尚未实现       | 只有需求或架构边界，不得从当前 baseline 推导为可用能力                       |

状态必须绑定证据，不能仅凭代码存在、关键词扫描或历史聊天记录升级。普通自动化结果可由当前 test graph 重现，不进入长期证据账本；只有稳定 artifact migration、无法由普通自动化重现的平台行为或外部服务事实保留独立证据。

一次性证据可以由精确 Git object 保存，但旧证据不得覆盖 active source of truth，也不得证明后续代码仍然通过。每条长期证据必须能定位日期、commit、平台、artifact 或外部依赖、执行入口和结果。

## 持续回归

持续回归按失败模式归属，不按文件类型堆叠覆盖：

### 测试归属

新增或修改测试前，必须能确定四件事：它保护哪份 source of truth 中的哪条可观察不变量、该不变量属于哪个 owner、测试变红时唯一指向什么失败模式，以及哪个测试层能以最小充分成本观察该失败。owner 按行为责任而不是当前调用路径或文件位置判断；只有失败必须跨越两个以上 owner 才能出现时，才进入 integration 层。

一个测试可以用多条断言证明同一个失败模式，但不能把彼此独立的失败模式塞进同一场景。同一合同允许在不同观察边界保留测试，例如纯状态转换与线程 quiescence；若 owner、失败模式和观察边界都相同，则只保留一个权威失败点。答不出上述四项的测试不进入长期回归。

| 层级                        | 唯一职责                                                                                       |
| --------------------------- | ---------------------------------------------------------------------------------------------- |
| Zig inline test             | 单模块的纯状态转换、codec、容量和资源所有权不变量                                              |
| Storage conformance         | backend-independent SQL contract 与 concrete backend 的事务、profile、文件和错误映射           |
| `tests/agent/`              | Session、callback、ABI、Agent Runtime 生命周期与并发                                           |
| `tests/workbench/`          | Executor、产品事务、持久化、恢复和产品并发                                                     |
| `tests/integration/`        | 必须跨两个以上 owner 才能出现的组合失败                                                        |
| Renderer/Node               | 通过函数调用、DOM 或 SSR 观察的 Renderer 行为，以及跨语言 fixture                              |
| architecture guard          | owner 依赖方向、禁止依赖、精确 allowlist、catalog 一致性、release isolation 和 test graph 接线 |
| probe / platform acceptance | candidate artifact、尚无确定性复现的依赖问题，或真实平台能力                                   |

源码扫描不得代替产品行为、响应式布局、CSS、文案或函数内部顺序测试；architecture guard 不断言测试数量。删除疑似重复的并发或 lifecycle 测试前，必须临时破坏对应不变量并确认保留侧会失败。probe 的结论进入合同和持续回归后，从 active tree 删除一次性资产，并在对应合同保留可定位出处。

### 默认入口

```bash
npm ci
npm run format:check
npm run check
npm test
```

`npm test` 是确定性回归总入口，必须先校验 canonical staged AgentCore bundle 和 Renderer 类型，再运行全部 `scripts/*.test.mjs` 与正式 Native test graph。Node 与 Native 阶段顺序执行并在末尾汇总失败；任一侧不得遮蔽另一侧。缺少或不匹配的 bundle 必须失败，不能跳过 AgentCore 用例后报告成功。

candidate probe、真实桌面验收、签名、公证和发布验证不进入 `npm test`，也不得被其结果替代。

### 定向入口

| 范围                      | 入口                                                                            | 使用条件                                                                                    |
| ------------------------- | ------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| 单个 Node/Renderer suite  | `node --experimental-strip-types --test scripts/<suite>.test.mjs`               | Renderer、Bridge client、fixture 或工程脚本的单一失败模式                                   |
| Agent/Workbench lifecycle | `node scripts/run-lifecycle-tests.mjs`                                          | Session、Executor、恢复、并发或 shutdown                                                    |
| 单个 lifecycle 不变量     | 设置 `LIFECYCLE_TEST_FILTER` 后运行 lifecycle 入口                              | 只缩小开发反馈；提交前仍运行完整关联 root                                                   |
| Storage foundation        | `zig build test-storage`                                                        | SQL contract、conformance、direct SQLite backend、migration、文件恢复与 engine profile      |
| Account OAuth loopback    | `metawork-account-loopback` 与 `metawork-oauth-loopback-transport` module tests | Account callback policy/invalid budget，以及 Application listener/cancel/deadline/sink 组合 |
| MCP owner                 | `build.zig` 中对应的 `test-mcp-*` step                                          | configuration、OAuth、transport、Runtime、catalog、interop 或 Application composition       |
| AgentCore candidate       | staged verifier 与对应 `run-agentcore-*-probe.mjs`                              | 新 artifact 或尚未进入合同的外部行为                                                        |
| 平台能力                  | 本文后续 Windows/macOS 入口                                                     | 真实窗口、系统 credential、签名、公证或平台生命周期                                         |

`build.zig` 是正式 Zig test graph 的注册真源；architecture guard 必须证明所有 active external test root 已接线。`scripts/*.test.mjs` 由总入口自动发现，不维护文件数量或手工清单。

MCP catalog freshness 的真实边界回归属于 `test-mcp-interop`：fixture 给 modern catalog 注入短 TTL，并覆盖同一 model/selection 到期时的 typed `McpNotRefreshed`、refresh 后成功，以及短 TTL 不启动高频后台 timer、过期后按需重建 Admission。纯 Workbench 测试验证 earliest safe TTL 到绝对 monotonic deadline 的单次转换、主动刷新下限，以及 OAuth/refresh 串行边界内 pending request 不丢失；它不伪造 AgentCore freshness 状态。

Product Account 的目录身份固定为 `src/product/account.zig` 与 `src/product/account/`；architecture guard 必须证明旧 `src/account.zig`、`src/account/` 不存在，全部 build root 指向新路径，同时公开 module identity 仍为 `metawork_account` 与 `metawork_account_contract`。

Product MCP 的目录身份固定为 `src/product/mcp.zig`、`src/product/mcp/configuration.zig`、`src/product/mcp/state.zig`、`src/product/mcp/policy.zig`、`src/product/mcp/view.zig` 与 owner-defined testdata；architecture guard 必须证明旧 `src/workbench/mcp_configuration.zig`、`src/workbench/testdata/` 不存在，Workbench projection 显式消费 `metawork_product_mcp` 且 `workbench.zig` 不再转发 configuration/state/policy/view API。该目录迁移不改变 owner：Workbench 仍拥有产品 MCP 状态、事务、admission、executor worker、完整 snapshot 编排与交付；configuration 只允许依赖 Agent-owned `agent_mcp_http_protocol` 窄叶子，state 与 policy 可以有意依赖 `metawork_agent` 公共 Activation/Selection/allowlist 类型，但 policy 不得持有 Agent Runtime 或 Workbench 资源，view 只允许依赖 configuration/state 并通过 callback-scoped 文本投影借用 Workbench 的 credential 遮蔽规则，四者都不得依赖 Application、Bridge、Account、Native SDK 或 AgentCore。state guard 还必须锁定完整 freshness 字段与 TTL-to-deadline 规则并证明 `McpRefreshJob` 留在 Workbench；policy guard 必须证明 authorization/reauthorization/Admission/refresh binding/generation/query 策略已离开 Workbench，且 Agent selection 创建、durable commit、timer/job 与 revision publication 留在 Workbench；view guard 必须证明旧 MCP View 派生函数已从 Workbench 删除、refresh job 仅以 bool fact 输入、模块无状态且 Renderer contract fixture 在 hard cut 前后逐字节一致。

Product Skill kernel 的目录身份固定为 `src/product/skill.zig` 及 `src/product/skill/{runtime,management_runtime,ports,state,policy,view,catalog,enablement,management,package}.zig`；architecture guard 必须证明旧 `src/workbench/catalog_snapshot.zig`、`src/workbench/skill_package.zig`、`src/workbench/skill_enablement.zig`、`src/workbench/skill_management.zig` 及其旧 module identity 不存在。Workspace projection、Task runtime 与 recovery job 都经 `metawork_product_skill.catalog` 消费同一 catalog；Workbench 只持一个 `skill_runtime.Runtime` aggregate，Workspace 不再持 `CatalogControl`，旧 inventory/transactions/health/staging/reconciliation/catalog slot/generation 散字段及其本地类型定义不得回流。`runtime.zig` 必须独占 Personal/Workspace tagged catalog authority、Workspace binding、catalog job、request generation、reschedule、stale completion 丢弃与 shutdown 收口，并独占 enablement CAS、candidate compile、encode/FileStore commit、no-fail authority swap、reconciliation 与 persistence failure invalidation；它只消费 `ports.zig` 的 enqueue/cancel、query/release 和 notifier capability；`state.zig` 持有 live management/enablement aggregate 与 reconciliation latch。二者都不得取得 Workbench、具体 Executor、Agent Runtime/Session 或线程。`policy.zig` 必须独占 persistence failure、scope enablement/selection revision、inventory invocation 与 catalog compile/recompile 的纯决策；projection 不得重新定义这些函数，policy 不得取得 FileStore/commit、Workspace/Task composition、Agent Runtime/Session、catalog job、executor、thread、revision publication 或 snapshot writer。`view.zig` 必须独占 catalog/management snapshot 子树的派生与编码，只能依赖 Product Skill state/policy/catalog/management，并以 callback-scoped projector/provider 借用敏感文本与 Workspace scoped catalog facts；它不得取得 Workbench/Workspace/Task composition、Agent、FileStore、job、executor、thread、revision publication 或完整 snapshot buffer。Application 直接持有两类 FileStore，Bridge 直接消费 management data-only 类型，二者都不经 Workbench facade；Workbench 只经总 Runtime 消费本地资产用例，内部 `management_runtime` 与 `management` 经 `product_skill_package` 消费同一 package kernel。十个 kernel 都不得依赖 Application、Bridge、Account、Native SDK 与 AgentCore；catalog query/job 与 scoped authority lifecycle 必须归 Runtime，具体 Executor/Agent Runtime 只经 ports 绑定；picker、Workspace authority/Task quiescence 校验、时间事实、完整 snapshot 根编排与 publication 必须留在组合层；management mutation/recovery/reconciliation 必须归 Product Skill；enablement FileStore commit 必须在 Runtime，projection 中不得出现 store/health/file_store 直接访问。定向 runtime/state/policy/view 测试、Workbench lifecycle 测试与 architecture guard 必须共同覆盖 slot availability/release、health mapping、Personal/Workspace effective policy、敏感文本遮蔽、原有 snapshot 字节合同、恢复语义及完整 module wiring。

Product Task View 的结构验收固定为：`product/task/view.zig` 独占 Task/Run/Compact/pending-UI/UI-history snapshot 子树的派生与编码，并只依赖 Task state/policy/recovery、Product Skill catalog 和 Agent 公共 permission DTO；全局 credential-safe 文本、canonical catalog writer 与 pending-UI typed observation 只能以 callback-scoped projector 借入。guard 必须反向证明旧 `writeRun`、`writeCompact`、`writeUiHistory`、`writePendingUiProjection` 与 `taskCatalogProjection` 不再由 projection 定义，View 不持有 Workbench、Session、executor、thread、allocator、credential、durable commit、revision 或完整 snapshot writer；同时正向证明组合层只经 Product Task `Access` 取得 pending-UI observation，并仍拥有完整 snapshot 根编排、容量 buffer、revision 与交付。Renderer contract fixture 必须在 hard cut 前后逐字节一致。

Product Task kernel 的目录身份固定为 `src/product/task.zig` 与 `src/product/task/`；architecture guard 必须证明旧 `src/workbench/task_persistence.zig`、`checkpoint_record.zig`、`checkpoint_store.zig`、`owned_task_execution.zig`、`task_runtime.zig`、`task_deletion.zig`、`task_recovery.zig`、`task_recovery_job.zig` 及其旧 module identity 全部不存在，projection、Application store lifecycle 与 lifecycle fixture 经 `metawork_product_task` 消费唯一实现，`workbench.zig` 不再转发 Task/Checkpoint concrete store 或 persistence capability/health 类型。该目录迁移不改变 wire、store path 或 executor；Product Task kernels 可以依赖 Account contract、Product Skill catalog 与 Agent 公共类型，但不得依赖 Application、Bridge、Native SDK、AgentCore 或 Workbench composition module，recovery job 不得取得 Workbench executor。architecture guard 还必须证明 `state.zig` 独占 Task/Run/Compact aggregate、Agent event 应用与 terminal event-drain gate，`policy.zig` 独占 Agent Run/Compact/begin/checkpoint terminal 分类、interruption/cause 映射、Task lifecycle/active-operation/continuation/recovery query 与 Session disposition transition，`persistence.zig` 独占 capability/health、Task/Run/Tool/Compact/UI/checkpoint wire projection、恢复重建、enum 与跨记录校验，Run/Compact 产品记录不保存 `Workbench`、`TaskView` 或 `Session` 反向指针；projection 只保留 Workspace frame 组装、callback-scoped bounded/redaction projection、Agent event/termination effect、terminal publication、durable commit、revision、snapshot 与 executor job context。persistence guard 必须反向证明旧转换函数不在 projection、Task persistence 不持有 Workbench/executor/thread/revision/snapshot writer，并正向证明根级组装与 durable commit effect 仍留组合层。policy guard 必须反向证明其不持有 Workbench、executor、thread、Agent Runtime、persistence commit、revision 或 snapshot writer，并正向证明组合层仍持有上述 effect。executor job 显式区分稳定 cancellation identity 与短寿命 execution context；executor 单测覆盖两者地址不同的 queued cancel，并验证取消回调在返回前完成。Task state 定向测试与 Workbench lifecycle 测试必须共同覆盖 terminal fact 和 assistant 未决尾部在 final drain 前不可见、event application 失败触发 termination、late event 不改写已发布终态、persistence hard cut 前后 wire/恢复/degraded 语义不变及 event wire hard cut 前后不变。

Product Task Session gateway 的结构验收固定为：`product/task/agent_session.zig` 是 Product 侧唯一允许出现裸 `*agent.Session`、`agent.SessionRoute`、`agent.SessionRestoreRoute` 与 `Runtime.releaseClosedSession` 的文件；`runtime.zig` 的 attached 状态只持 `Binding`，closing 状态只额外保存 close-worker 独占 Binding 与不可变 route id fact，recovery candidate 只持 `Binding + CheckpointRestoreReport`，projection 只持 scoped/worker-owned `Access`。guard 必须同时禁止 raw Session getter、Task 外 route 逃逸和 projection 直接 Session API 调用，并允许 `SessionDisposition`、`RunControl/RunControlLease`、route id 与 restore report 等 typed facts。lifecycle tests 必须覆盖 queued cancel/worker exactly-once Access、close 等待 Access quiescence、close worker 与主线程 Binding 隔离、terminal event drain 前 route id 稳定、Runtime shutdown join 后 Binding 不可再用，以及 `max_sessions = 1` 下 model rollback/persistence outcome unknown 收口后 slot 可复用。

Storage foundation 的自动化必须同时覆盖内存 target 与测试显式提供的 temporary file path，并在 Debug、ReleaseSafe 至少各运行一次定向入口。共享 conformance 负责 backend-independent 行为，包括 receiver 对同一 Database 的直接再入拒绝；direct backend tests 负责 `WAL + synchronous=NORMAL` profile、单连接内存可见性、Database 级间接再入与异 Database 调用、migration 原子性与版本 namespace、完整 batch rollback、reopen、busy/corrupt/invalid output 和结果上限。architecture guard 负责证明 SQLite C API 与 amalgamation 只进入 Storage concrete backend、上层尚未导入 Storage/SQLite、`app.zon` 尚未声明 Native SDK `sqlite` capability。上述结果只证明基础能力，不证明 production `app.db`、Product schema、业务迁移、单实例或断电 durable policy 已接入。

Product Skill 的 local-asset guard 必须正向证明总 Runtime 只经内部 `management_runtime.zig` 闭合目录/归档 preview、已安装 definition 读取、canonical `.skill` 导出、install/reimport/uninstall/retry、staging、恢复与 catalog reconciliation；该内部 owner 可以依赖唯一 package/management/policy/state kernels，但不得取得 Workbench、Task/Workspace view、具体 Executor、Agent Runtime/Session 或线程。Workbench 对应公开方法只能做 Workspace authority/Task quiescence gate、时间事实与 revision publication；projection 不得直接调用 package 实现、Transactions、staging root、persistence failure mapping 或 catalog reconciliation。

Product Skill 的公开表面 guard 必须证明 `product/skill.zig` 只导出 runtime、ports、catalog、enablement 与 management；package、policy、state、view、management_runtime 不得从聚合入口导出。Workbench projection 只允许直接消费 Runtime/ports 和 Task 所需的 catalog 叶面，不得直接 import 内部 kernel、重新拼装 View 输入、访问 `.skill.state`，或取得 `CatalogSlot`/`CatalogControl` 可变指针；Task admission/refresh/recovery 只能消费 immutable typed authority，catalog redaction 与 uninitialized refresh 判断必须经 Runtime operation。Runtime 必须是内部 View 派生与 management runtime 的唯一 live aggregate 入口。

## 长期证据账本

### Metask Account 与真实 AgentCore Run

- **规范**：[产品需求](requirements.md)、[Account 内部架构](account-architecture.md)、[Metask Account 合同](metask-account-contract.md)。
- **证据**：`git show dbaaf81b0217d4016944960ee8621e9a23274f05:docs/phase-0-validation.md` 中 2026-07-20 的真实链路记录。
- **结论**：打包 `.app` 完成 OAuth、profile、API Key/model catalog、execution persistence，以及 `gpt-5.5`、`deepseek-v4-pro` AgentCore Run。该证据不证明后续 Renderer、设置、模型选择或平台交互仍然通过。

### AgentCore target baseline

- **规范**：[高层架构](architecture.md)、[ABI v1 消费合同](agentcore-abi-v1.md)。
- **证据**：Windows x86_64 GNU、macOS arm64 与 macOS x86_64 均锁定 clean source commit `1183550f15b4eef27799076ee0908e9667d849a0` 的 target artifact；repository lock 与 bundle tests 验证 manifest/target/ABI identity。各 target vertical 结果以本节对应平台记录为准。
- **结论**：三个 target artifact 均为 ABI v1 revision 9、280-byte table、required capabilities `0x3fffff`。三份 lock、artifact 和 target 结果不能互相替代。

2026-08-13 的 Windows staged run-state probe 可由 Git object `51e0fcc847e7b832b628f6c64183525dd8300710` 定位：Host Run ID `7` 的 callback identity 与 `run_state.run_id` 一致，首序号为 `1`，并观察到 `starting → generating → finalizing → completed`。结论已进入 ABI 合同和 Workbench 回归，因此 active tree 不再保留该一次性 probe。

### Fault-domain direction

- **规范**：[高层架构](architecture.md)。
- **证据**：`git show dbaaf81b0217d4016944960ee8621e9a23274f05:docs/phase-0-gate-7-report.md`。
- **结论**：独立 crash 对照证明当前同进程方案没有进程级隔离，并选择单 AgentCore Worker 作为后续方向；产品 Worker 尚未实现。

## Native SDK 能力路径

[高层架构](architecture.md#35-native-sdk)定义正常 Runtime 路径、一级兼容和二级兼容。本节只登记当前兼容 seam、已知违规、验证状态和删除条件；实现机制仍由架构与源码负责。

architecture guard 必须保持 `PlatformServices.context` 零 allowlist。原始 `PlatformServices` 和 Win32/AppKit/GTK 调用只能存在于下列逐项登记的路径；每项必须绑定精确 capability、平台、allowlist、行为验证和删除条件。关键词扫描只证明结构边界，不能替代 Runtime 状态、真实平台行为或 shutdown。

### 当前兼容 seam

- `src/native_sdk_compat/system_webview_drag_region/macos.zig` — `system_webview_window_chrome` 一级兼容。当前仅调用 SDK 公开 `startWindowDrag` 原语；macOS 行为尚未验收。Runtime 提供并通过对应 drag-region 验收后删除。
- `src/native_sdk_compat/system_webview_startup_window/windows.zig` — 共享 startup window identity plumbing，不是独立 capability。只向 drag、window-controls 与 secure-input seam 提供一个经身份校验的 opaque binding；所有消费者删除后连同 allowlist 和捕获测试删除。
- `src/native_sdk_compat/secure_input/windows.zig` — `secure_input` 二级兼容。Windows 编译、结构、Unicode、确认/取消、真实 Agent Run 和 clean shutdown 已验收；UIA password 与长时间输入仍待验收。Runtime secure-input API 经 Windows 验收后删除实现、allowlist 和专用测试。
- `src/native_sdk_compat/secure_input/macos.zig` — `secure_input` 二级兼容。macOS 编译、modal 行为、VoiceOver 明文检查和 shutdown 尚未取得目标平台证据。Runtime secure-input API 经 macOS 验收后删除实现、allowlist 和专用测试。
- `src/native_sdk_compat/system_webview_drag_region/windows.zig` — `system_webview_drag_region` 二级兼容。普通拖动和最大化拖动恢复已验收；edge snap、双击标题栏、系统菜单、touch/pen 尚未验收。Runtime drag-region API 经 Windows 验收后删除实现、allowlist 和 pointer probe。
- `src/native_sdk_compat/system_webview_window_controls/windows.zig` — `system_webview_maximize_restore`、`system_webview_maximized_state` 与 `system_webview_user_close` 二级兼容。controls、maximize/restore、close-policy hide/reopen 与 clean shutdown 已验收。Runtime 对应能力逐项验收后删除相应 action/state；三项全部替换后删除共置文件、HWND binding、allowlist 和 probe。

`src/app/window.zig` 的显式退出使用 `Runtime.showMessageDialog` 与 `Runtime.closeWindow`，属于正常 Runtime 路径，不进入兼容 allowlist。

### 已登记架构缺口

- `src/app/platform.zig`、`src/app/window.zig` 与 `src/app/account_platform_binding.zig` 仍有 Runtime 已覆盖能力的直接低层调用，Application adapter 仍长期持有原始 `PlatformServices`。后续按独立 routing DAG 收口，不扩大为兼容 allowlist；Account Product owner 已只消费 MetaWork-owned ports，这一剩余缺口不再反向传播 Native SDK authority。
- `src/app/platform.zig` 的 main-loop `wake` 尚未形成单项兼容 seam；先确认 SDK 缺口，再隔离并验证线程与 shutdown。

因此，单个 window-chrome seam 通过不等于全仓 Native SDK 能力路径合规；上述缺口未收口前，全仓 gate 保持打开。

## 平台与 artifact 验收

`-Dautomation=true` artifact 必须把从 `app.zon` identity 派生的 `.automation` identity 传给 Native SDK runner，使 SDK-owned data/window/log namespace 即使脱离 harness 启动也不命中 production；正式 artifact 必须继续精确使用 `app.zon` identity。架构 guard 与 Native test graph共同验证派生关系，真实 automation harness 仍使用隔离的 `HOME`/`APPDATA`/`LOCALAPPDATA`，两层隔离不能互相替代。

### macOS

首次使用真实 Account 前，按[macOS 开发与分发签名](macos-local-development.md)选择 Apple Development identity：

```bash
node scripts/setup-macos-local-signing.mjs setup
node scripts/stage-agentcore-bundle.mjs /absolute/path/to/aarch64-macos-bundle
node scripts/stage-agentcore-bundle.mjs /absolute/path/to/x86_64-macos-bundle
npm run build:debug
npm run build:release
npm run package:macos
```

跨平台开发入口与 Apple Development 签名规则由 `dev.mjs` 负责，setup 只复用该开发 owner；Developer ID、应用与 DMG 签名、公证、staple、Gatekeeper、Finder 左到右拖拽布局、磁盘映像及挂载内容的身份与完整性规则由 `package-macos.mjs` 负责。两个 owner 必须保持双向隔离。Native SDK 必须先按 resolved build target 从 `.agentcore/bundles/<target-id>` 生成未签名 `.app`；应用签名前必须把 64 × 64 托盘 PNG stage 到与运行时相对路径一致的 `Contents/Resources/assets/icons/tray-icon.png`，并以 `lipo` 确认主程序恰好为该 target 的单一架构，随后只执行一次 Developer ID 应用签名，并在同一入口检查格式、尺寸、源资产一致性、Renderer、metadata 与签名 policy。`package:macos` 默认 `all`，依次产出小写 `metawork-<version>-macos-arm64.dmg` 与 `metawork-<version>-macos-x64.dmg`；`npm run package:macos -- arm64` 或 `-- x64` 只产出所选单一架构。入口不得根据 last-stage state 推断架构，也不生成 Universal、preview 或 ZIP。普通 check/test/build 不得访问个人证书、Finder 或 notary profile；`package:macos` 成功证明当前图形用户会话生成的可分发磁盘映像，不等于更新能力完成。

Keychain 跨重建授权稳定性当前为 **人工验收待完成**：在同一精确 commit 上让 Debug app 写入并读取 Account credential，完全退出并重新构建，再次恢复 Account，确认没有出现新的 Account Keychain 授权框。首次选择签名私钥产生的系统授权不属于 Account Keychain 失败。

涉及 AgentCore candidate、正式 Host、Renderer reload、产品数据面或生命周期时，按变更范围增加：

```bash
AGENTCORE_BUNDLE_ROOT=/absolute/path/to/bundle node scripts/run-agentcore-restore-probe.mjs
AGENTCORE_BUNDLE_ROOT=/absolute/path/to/bundle node scripts/run-agentcore-provider-test.mjs
node scripts/run-lifecycle-tests.mjs
node scripts/test-agentcore-vertical-macos.mjs
```

macOS artifact、Native vertical、secure input、window chrome 与真实 WebView 可访问性必须独立采集，不能由 Windows 结果替代。

### Windows development baseline

```powershell
node scripts/stage-agentcore-bundle.mjs C:\absolute\path\to\x86_64-windows.win10...win11_dt-gnu
node scripts/run-windows-bringup.mjs
node scripts/test-window-chrome-windows.mjs --resize-session-only
node scripts/test-window-chrome-windows.mjs
```

`run-windows-bringup.mjs` 必须覆盖 staged verifier、restore probe、bundle/lifecycle tests、正式 test graph、Debug/Release build 和真实 Windows vertical，并明确报告 revision 9。window-chrome 的 resize/session gate 与 pointer/controls gate 分开报告：程序化 resize 只能证明 Native window、最小尺寸和同一 Renderer session，不能替代真实鼠标 edge resize、work-area clamp 或 WebView 焦点验收。

当前已验收普通拖动、最大化拖动恢复、Renderer controls、close-policy hide/reopen 与 clean shutdown。top/bottom/四角 resize、edge snap、双击标题栏、系统菜单、touch/pen 和完整 UIA 焦点仍需独立证据。

`node scripts/run-agentcore-abort-timing-probe.mjs --staged` 用于取证 `session_abort` 返回后是否仍有 callback 投递；结果尚未采集，因此该 probe 保留。Windows distribution、安装/更新、完整 process-tree/timeout/security matrix 和 Linux target 不由 development baseline 证明。

### Windows 安装 artifact

```powershell
npm run package:windows
```

该入口必须先完成正式 Release build，再使用 Native SDK `package --target windows` 生成独立 runtime stage；stage gate 精确验证 app.zon version/App ID、ReleaseFast、Windows GUI subsystem、主程序、WebView2 loader、应用图标与 Renderer assets，随后才允许 Inno Setup 6.7.3 或兼容的 7.x 生成小写 `metawork-<version>-windows-x64-setup.exe`。最终 gate 要求精确文件存在、具有 PE identity 且输出 SHA-256。安装器按用户安装、注册开始菜单与卸载入口，不要求管理员权限。

`npm run package:windows -- --signing required` 是同一入口的正式 Authenticode 模式。它必须从 Windows SDK 发现 x64 SignTool，以精确 SHA-1 thumbprint 选择当前用户证书库身份，使用 SHA-256 文件摘要和 RFC 3161 SHA-256 时间戳；MetaWork-owned EXE、Inno signed uninstaller 与最终安装器必须由同一 SignTool definition 签署，Microsoft-owned DLL 保留并验证原厂签名。每个可直接验证的 PE 都必须通过 `signtool verify /pa /all /v`，任何缺失配置、签名、时间戳或验证失败必须 fail closed。普通 unsigned mode 不读取签名身份，不能满足该 Gate。

当前自动化覆盖 metadata、Inno/SignTool 发现与 capability gate、Native runtime stage 结构、GUI subsystem、精确签名参数、单 EXE identity 和直接 PE 的 Authenticode verification；当前 signed Windows artifact 已完成一次隔离目录 silent install/uninstall smoke，直接验证安装器、实际落盘主程序与 `unins000.exe` 的 `/pa /all /v` Authenticode policy、Certum EV signer、RFC 3161 时间戳和零 warning，并确认 WebView2 loader 原厂签名、Renderer assets、图标、安装目录与卸载注册表清理。该 smoke 只能在没有同 App ID 正式安装的干净环境执行，避免覆盖真实用户安装状态，因此不内嵌进普通 package 命令。交互式 wizard、开始菜单启动、托盘驻留下升级替换和 Windows 10/11 平台矩阵仍是人工验收待完成。普通 check/test/build 与未签名 package 不得访问签名身份。安装器能力不证明自动更新、channel、回滚或迁移能力。

### Checkpoint artifact boundary

revision 9 不继承旧 artifact 的 checkpoint 样本或通过结论。Windows 与 macOS 必须分别使用各自锁定 artifact 重新采集平台 vertical；旧版本结果不能替代。checkpoint digest 与产品预算的规范性语义见[AgentCore 集成契约](agentcore-integration.md)和[ABI v1 消费合同](agentcore-abi-v1.md)。

## 尚未验证的能力

本节只防止错误能力声明；行为和技术边界仍由对应 source of truth 定义。

- 单 AgentCore Worker、进程级 crash semantics、async pending、suspend/resume 和跨进程 in-flight Run recovery 尚未实现。当前只支持正常 Application 重启后从 latest finalized checkpoint 显式恢复 Conversation attachment。
- strict Workspace security、正式 Host tools 和持久权限规则尚未完成独立安全验收。
- typed Output、FileChange、plan progress/approval 和 custom UI 不由当前 ABI 提供，对应 UI 必须保持关闭。
- Task 当前进程内 execution binding 和模型切换已有自动化；显式 execution rebind 的跨重启 epoch/history 与竞态尚未实现。
- MCP 的真实第三方 server、平台 credential/network、secure capture、browser/callback 和 issuer 行为尚未完成跨平台验收；marketplace 不在当前范围。
- 系统关机或用户显式退出 MetaWork 期间的准点执行、登录前系统服务和远端云调度尚未实现。当前只保证窗口关闭而 Host 仍运行时继续调度，并在下次启动协调至多一个 missed occurrence。
- Windows signed Inno artifact 已完成隔离目录静默安装/卸载与 Authenticode 验收；交互式 wizard、开始菜单启动、托盘驻留下升级替换、Windows 10/11 平台矩阵、更新和 Linux target 尚未完成。

## 维护规则

- 同一事实只在一份 source of truth 定义；本文链接规范，不复制产品或技术合同。
- 普通可重现测试不进入长期证据账本；提交是否通过由该 commit 的真实执行结果负责。
- 只有具备长期审计价值的稳定 artifact、平台或外部服务事实保留独立证据；阶段叙事在结论进入合同、测试或账本后删除。
- 新增普通测试、测试改名或测试文件移动不要求更新本文；测试层或归属规则、验证入口、平台状态、长期证据或覆盖缺口变化时才更新。
- `rg`、格式检查、文件存在性和源码关键词检查只属于卫生或结构验证，不能替代合同、运行时和平台行为测试。

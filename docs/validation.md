# MetaWork 验证规范

> 状态：初始技术验证已经收口；本文维护持续回归归属、当前验证状态、可复现入口、长期证据和覆盖缺口

本文是验证控制面，不是产品或技术设计文档。它只回答四个问题：依据哪份规范验证什么、由哪个测试层负责、证据在哪里、还缺什么。产品行为以[产品需求](requirements.md)为准，UI 信息架构、交互与视觉以[UI 设计规范](ui-design.md)为准，系统边界以[高层架构](architecture.md)和[Product 架构](product-architecture.md)为准；Renderer Bridge、AgentCore、Completion、Storage 与外部合同分别由对应 source of truth 定义。

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

| 范围                     | 入口                                                                            | 使用条件                                                                                    |
| ------------------------ | ------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| 单个 Node/Renderer suite | `node --experimental-strip-types --test scripts/<suite>.test.mjs`               | Renderer、Bridge client、fixture 或工程脚本的单一失败模式                                   |
| Agent/Product lifecycle  | `node scripts/run-lifecycle-tests.mjs`                                          | Session、Product Control、Executor、恢复、并发或 shutdown                                   |
| 单个 lifecycle 不变量    | 设置 `LIFECYCLE_TEST_FILTER` 后运行 lifecycle 入口                              | 只缩小开发反馈；提交前仍运行完整关联 root                                                   |
| Storage                  | `zig build test-storage`                                                        | SQL contract、conformance、direct SQLite backend、migration、文件恢复与 engine profile      |
| Account OAuth loopback   | `metawork-account-loopback` 与 `metawork-oauth-loopback-transport` module tests | Account callback policy/invalid budget，以及 Application listener/cancel/deadline/sink 组合 |
| Agent Completion         | `agent/completion.zig` 与 `agent/provider_probe.zig` 定向 test root             | 三 Provider 非流式 JSON codec、typed failure、请求取消、credential 清零与 Probe lifecycle   |
| MCP owner                | `build.zig` 中对应的 `test-mcp-*` step                                          | configuration、OAuth、transport、Runtime、catalog、interop 或 Application composition       |
| AgentCore candidate      | staged verifier 与对应 `run-agentcore-*-probe.mjs`                              | 新 artifact 或尚未进入合同的外部行为                                                        |
| 平台能力                 | 本文后续 Windows/macOS 入口                                                     | 真实窗口、系统 credential、签名、公证或平台生命周期                                         |

`build.zig` 是正式 Zig test graph 的注册真源；architecture guard 必须证明所有 active external test root 已接线。`scripts/*.test.mjs` 由总入口自动发现，不维护文件数量或手工清单。

Agent Completion 的确定性测试使用 MetaWork-owned fake Transport，覆盖三个 Provider 的非流式 request/result、text/usage/stop 映射、Tool wire fail-closed、非 2xx typed rejection、请求前取消、阻塞 perform 被外部取消唤醒，以及 credential 和 sensitive header copy 清零。Application Transport 沿用仓库已有的 `std.Io.Select` buffered fetch/cancel 模式；生产使用系统 CA，不接受 Completion 专用证书配置，也不维护本地 CA/leaf 测试 fixture。

MetaWork Agent capability 的确定性回归归 `tests/agent/`：Runtime 注册与 fresh/restore Session allowlist 必须精确等于 Agent-owned 的十个 built-in，`AskUserQuestion` 必须缺席，unknown/empty set 必须 fail closed，`host_tool_count` 保持零；当前 compatibility permission 回归同时覆盖 request `responses[]`、`exact_arguments` candidate、四种 choice、Session grant、provenance、restore 对账和 capability gate。bundle 名称 probe 只证明外部 artifact 上限，不能替代 Agent 产品集合回归，也不形成长期维护的独立工具计划。

PermissionProfile 按执行频率与 owner 分层验证，不以一个 UI fixture 代替全链路：锁定 canonical bundle 的 candidate probe 先证明每个拟采用 `PermissionMode + ShellPolicy` 组合的 exact tool/request/effect 行为；Agent tests 固定配置编码、fresh/restore 一致性、idle mutation 生效点与 fail-closed；Product Control lifecycle 固定 Settings default 只影响新 Task、Task effective profile、Run provenance、active operation 拒绝切换与撤权；Schedule lifecycle 固定 definition-pinned noninteractive profile、未覆盖操作 typed stop、`needs_attention` 和不得产生同步 UI wait；Renderer suite 固定 capability 缺失时入口不存在、部分能力只显示真实档位、选择动作不追加第二个确认 modal。`standard` 还必须以 typed risk/effect 和 tool 执行前 commit boundary 的确定性 fixture 证明请求频率，而不能从 Bash 字符串或展示文案推导。

锁定 aarch64 macOS artifact 的权限模式行为由 `node scripts/run-agentcore-permission-probe.mjs --staged` source-free 重现。该 probe 精确校验 bundle lock，并覆盖 `accept_edits` 的 Workspace 内 Edit/Write、Workspace 外 Write 与 Bash，`full_access` 的普通 effect 与 protected path，显式 deny/ask/allow 优先级，callback unavailable，Session grant 的同 Session 复用与 checkpoint restore，`full_access` 无虚构 grant 的 restore，以及 `disabled | sandboxed | unrestricted` 的代表性 shell effect。它是 candidate/artifact gate，不进入正式 Host，也不能替代 Product profile、Schedule、Bridge 或 Renderer 回归。

权限体验的回归单位是“缺少一次真实用户决定”，不是 Tool callback 数量。每个正式 profile 的场景矩阵至少覆盖：Manual Workspace picker 已授权后不再请求 trust；当前 Workspace 内常规 edit；Workspace 外 edit；只读与有副作用的 Bash；MCP/Skill 既有 authority；操作系统原生授权；同一 Session 重复操作；Renderer reload；cancel/close/shutdown；fresh Task、checkpoint restore 与 Scheduled occurrence。预期为自动执行、一次同步请求或 typed stop 三者之一，任何重复请求都必须唯一指向 authority、profile 或 effect fact 的变化。

MCP catalog freshness 的真实边界回归属于 `test-mcp-interop`：fixture 给 modern catalog 注入短 TTL，并覆盖同一 model/selection 到期时的 typed `McpNotRefreshed`、refresh 后成功，以及短 TTL 不启动高频后台 timer、过期后按需重建 Admission。纯 Product Control 测试验证 earliest safe TTL 到绝对 monotonic deadline 的单次转换、主动刷新下限，以及 OAuth/refresh 串行边界内 pending request 不丢失；它不伪造 AgentCore freshness 状态。

MCP 启动解耦由 `test-mcp-app` 验证 Application composition、empty Runtime Manifest proof 与 configuration-apply 失败收口，由 Agent lifecycle 验证 canonical empty Runtime 的 null authority 和 declarative apply，由 `test-product-mcp-policy` 验证 initial blocked Admission 仍只向普通 Task 提供 null selection，由 `test-workbench-mcp` 验证完成事务只更新后续新 Task。真实第三方 server 或平台首窗不是该确定性测试的替代品。

Product Control hard cut 的结构验收固定为：`src/product/control.zig` 与 `src/product/control/` 形成唯一组合 owner 源码身份，Runtime 拥有已安装 execution、Workspace/Task history、Task/Skill/MCP/Schedule/Workspace aggregate、共享 Executor、跨 aggregate admission/reconciliation、revision、完整 snapshot 与 shutdown 顺序；旧 `src/workbench.zig`、整个 `src/workbench/` 目录及 `metawork_workbench` module identity 必须不存在。迁移不得改变 Renderer Bridge revision 1、snapshot bytes、command/event wire、`workbench-history.store`、checkpoint 或其他 persistence 格式。

Product Control 的 Account/execution 结构验收固定为：`src/product/control/account_execution.zig` 是脱敏 Account read model、当前 installed execution、Model Connection binding、replacement/redaction token 和相关 authority decision 的唯一 kernel；Runtime 只能持一个 `account_execution.State`，不得重新定义或平行保存 `AccountProjection`、`ActiveExecution`、replacement/redaction preparation 或 custom binding。该 kernel 只依赖 Account contract，不得依赖其他 Product aggregate、Agent、Application、Bridge、具体 Executor、线程或 Native SDK，也不得从 `product/control.zig` 公开。最大 8 个 Model Connection × 每个 16 个模型的 Account fact commit 与 view 读取必须在初始化后零分配；测试使用 failing allocator 把下一次 allocation 设为失败。Task 模型切换测试必须覆盖：exact Metask authority 下 pinned model 已离开目录仍可选择有效候选、默认 replacement 后旧 generation 被拒绝、Model Connection Task 不消费 Metask catalog；Renderer 纯 policy 测试必须使用同一 provider/source/generation/catalog gate。architecture guard 必须锁定 module graph、唯一 State 持有、私有字段不得回流和 test-only seam。

Product Workspace 的结构验收固定为：`src/product/workspace.zig`、`src/product/workspace/runtime.zig`、`view.zig` 与 `automatic_root.zig` 是唯一实现；Runtime 独占 bounded registry/record、identity/recent-order、manual/automatic lifecycle、authorization/trust、restore/redaction、typed authority 和 concrete automatic allocator，Product Control 只能持一个 Workspace Runtime，不得重新持有 Workspace array/counter、local transition、concrete allocator 或 snapshot object writer。Workspace 的 open/removal/order/automatic allocation 使用线性 preparation 或 typed operation；共享 Workspace+Task history commit、persistence health、Task/Skill/File Preview 协调、revision 与完整 snapshot 根仍归 Product Control。View 只能借用 callback-scoped opaque provider 读取 Task signals、Skill catalog 和 credential-safe 文本写出，不得导入其他 aggregate 或保留 capability。Application 只创建并移交 opened AutomaticRoot；聚合根不得发布 record、registry slice、mutable pointer、concrete allocator 或内部 kernel identity。architecture guard 必须锁定新旧路径/module identity、公共面与禁用依赖；Product Control exact snapshot fixture、Workspace lifecycle、automatic root、正式 Native graph 和 `git diff --check` 必须通过。

Scheduled Task 是 Product Control 持有的 live Product Schedule aggregate：`src/product/schedule/runtime.zig` 独占 bounded store、persistence transaction/health、timer/background policy、notification 与完整 occurrence saga，`state.zig` 独占 recurrence/definition/occurrence 状态转换，`persistence.zig` 独占 schema 1 codec、恢复校验和 concrete FileStore，`view.zig` 独占 `scheduledTasks` snapshot 子树编码并只接受 callback-scoped 文本投影器。Product Control 只以 opaque `TaskEffects` 提供 active 查询、单次 launch 与 terminal fact，不能读取或调用 Claim/Due/PendingCompletion、begin/finish 阶段；architecture guard 必须证明旧 Workbench 路径及 `src/product/control/schedule*`、旧 module identity 不存在，Product Control 只导入 `metawork_product_schedule` 公共面且不得出现 Store/Item/ItemView、occurrence wire 字段、事务阶段或子树编码，Application store lifecycle 只直接消费 persistence leaf，`product/control.zig` 不转发 concrete store。该 hard move 不改变 `scheduled-tasks.json`、schema、wire、recurrence 或 timer/admission 行为。Product Control lifecycle tests 还必须覆盖 execution install/clear 前 Schedule credential scrub 的 durable commit、commit 失败时零 ownership transfer、每次 Schedule candidate commit 对当前默认与全部 live Task execution credential 的持久化前清洗，以及真实 manual occurrence 的 submitted/completed 和 launch rejection 终态；architecture guard 必须锁定 Account handoff 的 prepare-before-install/clear 协议。

Application 侧的 ExecutionHandoff、AgentEventConsumer、McpManagementPort、McpOauthPort 与 ScheduleHost 必须由独立 `metawork_product_control_ports` module 发布，并全部使用 `*anyopaque` context + 函数指针；port 字段、返回值和 coordinator 源码不得出现 `product_control.Runtime`，不得返回内部 aggregate 或可变状态指针。`account_coordinator.zig`、`agent_event_coordinator.zig`、MCP coordinator、`window.zig` 与 `platform.zig` 不得导入完整 `metawork_product_control`；只有 `app.zig` composition root 可以持有完整 Runtime 并构造 capability。architecture guard 必须同时验证 module graph 与源码禁词，而不是只验证调用点改名。所有 capability 使用者必须先 shutdown/join，Product Control 才能 deinit；worker payload 不得保存 capability。

迁移期间 `file_preview.zig` 必须先成为具名 module，消除从组合实现的相对导入；Executor 与 File Preview 随后在同一 owner cut 中迁入 Product Control，File Preview 只消费窄 enqueue capability。`project-structure.md` 只描述 active tree，因此每个实际 hard cut 必须与对应 tree、module graph、guard 和文档更新同一提交落地，不能提前声称目标目录已经存在。

Product Account 的目录身份固定为 `src/product/account.zig` 与 `src/product/account/`；architecture guard 必须证明旧 `src/account.zig`、`src/account/` 不存在，全部 build root 指向新路径，同时公开 module identity 仍为 `metawork_account` 与 `metawork_account_contract`。

Product MCP 的目录身份固定为 `src/product/mcp.zig`、`src/product/mcp/configuration.zig`、`src/product/mcp/state.zig`、`src/product/mcp/policy.zig`、`src/product/mcp/view.zig`、`src/product/mcp/ports.zig`、`src/product/mcp/refresh_job.zig`、`src/product/mcp/runtime.zig` 与 owner-defined testdata；architecture guard 必须证明旧 `src/workbench/mcp_configuration.zig`、`src/workbench/testdata/` 不存在，Product Control Runtime 显式消费 `metawork_product_mcp` 且 `product/control.zig` 不再转发 configuration/state/policy/view API。该目录迁移不改变顶层 owner：Product MCP Runtime 拥有 live state、refresh job identity、timer capability，以及 apply/test/refresh、management/OAuth durable transaction 与 runtime-auth-failure 生命周期，Product Control 仍拥有具体 Executor、跨 owner coordinator、revision publication、完整 snapshot 编排与交付；configuration 只允许依赖 Agent-owned `agent_mcp_http_protocol` 窄叶子，state 与 policy 可以有意依赖 `metawork_agent` 公共 Activation/Selection/allowlist 类型，但 policy 不得持有 Agent Runtime 或 Product Control 资源，view 只允许依赖 configuration/state、只由 Runtime 调用，并通过 callback-scoped 文本投影借用 Product Control 的 credential 遮蔽规则。ports 只能发布窄 effect capability；refresh job 必须独占 worker payload/callback/atomic outcome，且禁止持有 Product Control、Product MCP Runtime、McpProductState、具体 Executor、线程或裸 Agent Runtime；Runtime 必须持有 state 与 refresh job identity，并闭合 refresh request/start/sync、apply/test 与 shutdown settlement，同时禁止导入 Product Control、Application、Bridge、Account、Native SDK 或线程。state guard 还必须锁定完整 freshness 字段与 TTL-to-deadline 规则；policy guard 必须证明 authorization/reauthorization/Admission/refresh binding/generation/query 策略已离开 Product Control，Runtime guard 必须证明 timer/job completion 与 management/OAuth durable commit 已归 live aggregate，且 revision publication 留在 Product Control；view guard 必须证明旧 MCP View 派生函数已从 Product Control 删除、refresh job 仅由 Runtime 以 bool fact 输入、模块无状态、projection 不直接导入 state/policy/view，且 Renderer contract fixture 在 hard cut 前后逐字节一致。

聚合公共面还必须由 architecture guard 证明：`product/mcp.zig` 只发布 `contract`、Runtime、Ports、必要 typed DTO 与 test-only seam，生产 build graph 不向它注入 state/policy/view/refresh-job；Product Control 与 Application 不得经聚合根直接导入这些内部 kernel，且 production projection 中不得出现 `McpProductState`、`McpRefreshJob` 或 `mcp_policy`。

Product Skill kernel 的目录身份固定为 `src/product/skill.zig` 及 `src/product/skill/{runtime,management_runtime,ports,state,policy,view,catalog,enablement,management,package}.zig`；architecture guard 必须证明旧 `src/workbench/catalog_snapshot.zig`、`src/workbench/skill_package.zig`、`src/workbench/skill_enablement.zig`、`src/workbench/skill_management.zig` 及其旧 module identity 不存在。Workspace projection、Task runtime/view 与 attachment 经 `metawork_product_skill.catalog` 消费同一 catalog；recovery job 必须从 module graph 移除该依赖并禁止任何 Product Skill import/query；Product Control 只持一个 `skill_runtime.Runtime` aggregate，Workspace 不再持 `CatalogControl`，旧 inventory/transactions/health/staging/reconciliation/catalog slot/generation 散字段及其本地类型定义不得回流。`runtime.zig` 必须独占 Personal/Workspace tagged catalog authority、Workspace binding、catalog job、request generation、reschedule、stale completion 丢弃与 shutdown 收口，并独占 enablement CAS、candidate compile、encode/FileStore commit、no-fail authority swap、reconciliation 与 persistence failure invalidation；它只消费 `ports.zig` 的 enqueue/cancel、query/release 和 notifier capability；`state.zig` 持有 live management/enablement aggregate 与 reconciliation latch。二者都不得取得 Product Control、具体 Executor、Agent Runtime/Session 或线程。`policy.zig` 必须独占 persistence failure、scope enablement/selection revision、inventory invocation 与 catalog compile/recompile 的纯决策；projection 不得重新定义这些函数，policy 不得取得 FileStore/commit、Workspace/Task composition、Agent Runtime/Session、catalog job、executor、thread、revision publication 或 snapshot writer。`view.zig` 必须独占 catalog/management snapshot 子树的派生与编码，只能依赖 Product Skill state/policy/catalog/management，并以 callback-scoped projector/provider 借用敏感文本与 Workspace scoped catalog facts；它不得取得 Product Control/Workspace/Task composition、Agent、FileStore、job、executor、thread、revision publication 或完整 snapshot buffer。Application 直接持有两类 FileStore，Bridge 直接消费 management data-only 类型，二者都不经 Product Control facade；Product Control 只经总 Runtime 消费本地资产用例，内部 `management_runtime` 与 `management` 经 `product_skill_package` 消费同一 package kernel。十个 kernel 都不得依赖 Application、Bridge、Account、Native SDK 与 AgentCore；catalog query/job 与 scoped authority lifecycle 必须归 Runtime，具体 Executor/Agent Runtime 只经 ports 绑定；picker、Workspace authority/Task quiescence 校验、时间事实、完整 snapshot 根编排与 publication 必须留在组合层；management mutation/recovery/reconciliation 必须归 Product Skill；enablement FileStore commit 必须在 Runtime，projection 中不得出现 store/health/file_store 直接访问。定向 runtime/state/policy/view 测试、Product Control lifecycle 测试与 architecture guard 必须共同覆盖 slot availability/release、health mapping、Personal/Workspace effective policy、敏感文本遮蔽、原有 snapshot 字节合同、恢复语义及完整 module wiring。

Product Task View 的结构验收固定为：`product/task/view.zig` 独占 Task/Run/Compact/pending-UI/UI-history snapshot 子树的派生与编码，并只依赖 Task state/policy/recovery、Product Skill catalog 和 Agent 公共 permission DTO；全局 credential-safe 文本、canonical catalog writer 与 pending-UI typed observation 只能以 callback-scoped projector 借入。guard 必须反向证明旧 `writeRun`、`writeCompact`、`writeUiHistory`、`writePendingUiProjection` 与 `taskCatalogProjection` 不再由 projection 定义，View 不持有 Product Control、Session、executor、thread、allocator、credential、durable commit、revision 或完整 snapshot writer；同时正向证明 Runtime 内部只经 Product Task `Access` 取得 pending-UI observation，组合层只调用 Runtime 的 Task projection operation，并仍拥有完整 snapshot 根编排、容量 buffer、revision 与交付。Renderer revision 1 canonical fixture 必须与当前 Zig writer 和 TypeScript exact decoder 同步；合同 hard cut 时原子替换 fixture 和两端实现，不保留旧字段或双写。

Product Task execution 的结构验收固定为：`product/task/execution.zig` 独占 Run/Compact job payload 与 execute/cancel callback，具体 Executor 只 enqueue 这些 callback。payload 只能持稳定 record、scoped Session Access、具名 effect capability 和对应 worker-reference atomic；guard 必须禁止 Product Control、Task aggregate、Task runtime、具体 executor 与裸 Session 指针，并证明自动标题 credential clone 只在 Run job 中存在、record 不持有 credential owner、job destroy 对 clone 执行 secure-zero。

Product Task live aggregate 的结构验收固定为：`product/task/runtime.zig` 独占 Task collection、identity/recent order、failure ledger、attachment/operation、late-terminal、recovery poison、durable unknown freeze 与 Agent shutdown facts，`attachment.zig` 独占原 per-Task resource union；Product Control 只能持一个 `task_runtime.Runtime` aggregate，不得重新持有上述散字段或直接调用内部 kernel；Runtime 必须闭合 Task create、Run/Compact start/cancel、UI response、model selection、detach、recovery、event application、Task projection 与 shutdown transition。共享 Workspace+Task history health 与唯一 commit effect留组合层，Runtime 只观察 `committed | failed | outcome_unknown`，unknown 后 mutation 必须 fail closed。Recovery start 必须由 `CoreRecoveryAuthority + RecoveryAdmissionFacts` 的唯一 typed decision 校验 Task/binding、checkpoint/terminal anchor、Workspace id/kind/epoch/root/authorization 与 Automatic owner、当前 execution 的 provider/model readiness、persistence/checkpoint store/Agent Runtime readiness、attachment/operation/archive/shutdown；Workspace visible、历史与当前 execution generation 相等、Skill/MCP/Permission readiness 与 projection capacity 禁止进入 admission。recovery completion 必须分别精确重查 source Task/binding H 与 start 时 target execution G；H≠G 时必须先 durable 推进 Task generation、binding epoch 与 checkpoint anchor epoch，再安装 attachment。旧 Run 保留逐 Run generation，混合 H/G 历史必须完整 round-trip；明确 adoption commit failure 回滚，outcome unknown 冻结 mutation。Skill refresh 与 MCP generation 变化不得使 candidate stale；定向测试必须逐维证明 stale source/target candidate 被丢弃且不会自动重试，Product Control lifecycle 还必须覆盖 H→G restart、restore 飞行中的 Workspace removal 与 execution replacement，证明组合层提供的实时 authority 事实能够拒绝候选且不泄漏 Agent Session slot。Run/Compact terminal product fact 的可见性不得等待同一 executor job 的 checkpoint export 完成；controlled checkpoint 测试必须在释放 export 前观察到 terminal。 Recovery vertical 必须覆盖 Automatic Workspace → Text Run(H) → checkpoint → restart(G) → restore/adopt → second Text Run(G)、Automatic owning Task/visible=false、恢复 worker 零 Skill catalog query、AgentCore degraded Skill/MCP/Permission invalidation 后 Text 可继续、Manual 显式 Skill refresh、MCP runtime_busy/runtime_refresh_required、Workspace removal/execution replacement/shutdown stale discard，以及 corrupt/missing/cancel/cleanup 无资源泄漏。

Product Task kernel 的目录身份固定为 `src/product/task.zig` 与 `src/product/task/`；architecture guard 必须证明旧 `src/workbench/task_persistence.zig`、`checkpoint_record.zig`、`checkpoint_store.zig`、`owned_task_execution.zig`、`task_runtime.zig`、`task_deletion.zig`、`task_recovery.zig`、`task_recovery_job.zig` 及其旧 module identity 全部不存在，Product Control Runtime、Application store lifecycle 与 lifecycle fixture 经 `metawork_product_task` 消费唯一实现，`product/control.zig` 不再转发 Task/Checkpoint concrete store 或 persistence capability/health 类型。该目录迁移不改变 wire、store path 或 executor；Product Task kernels 除 recovery job 外可以按职责依赖 Account contract、Product Skill catalog 与 Agent 公共类型，但不得依赖 Application、Bridge、Native SDK、AgentCore 或 Product Control composition module；recovery job 不得取得 Product Control executor，也不得导入 Product Skill。architecture guard 还必须证明 `state.zig` 独占 Task/Run/Compact aggregate、Agent event 应用与 terminal event-drain gate，`policy.zig` 独占 Agent Run/Compact/begin/checkpoint terminal 分类、interruption/cause 映射、Task lifecycle/active-operation/continuation/recovery query 与 Session disposition transition，`persistence.zig` 独占 capability/health、Task/Run/Tool/Compact/UI/checkpoint wire projection、恢复重建、enum 与跨记录校验，Run/Compact 产品记录不保存 `Product Control`、`TaskView` 或 `Session` 反向指针；projection 只保留 Workspace frame 组装、callback-scoped authority/projection/commit ports、Agent event pump、revision、完整 snapshot 根与具体 Executor 本体；Task create、Run/Compact、cancel、UI、model、detach、recovery、event application、terminal publication、Task 子树与 shutdown transition 归 Runtime，Run/Compact job context 与 execute/cancel callback 归 `execution.zig`。聚合根只允许公开 Runtime、typed operation/port/fact、history 与 checkpoint store；production projection/build graph 不得直接 import 内部 kernel，测试只能经 `builtin.is_test` seam 取得 fixture。persistence guard 必须反向证明旧转换函数不在 projection、Task persistence 不持有 Product Control/executor/thread/revision/snapshot writer，并正向证明根级组装与 durable commit effect 仍留组合层。policy guard 必须反向证明其不持有 Product Control、executor、thread、Agent Runtime、persistence commit、revision 或 snapshot writer，并正向证明组合层仍持有上述 effect。executor job 显式区分稳定 cancellation identity 与短寿命 execution context；executor 单测覆盖两者地址不同的 queued cancel，并验证取消回调在返回前完成。Task state 定向测试与 Product Control lifecycle 测试必须共同覆盖 terminal fact 和 assistant 未决尾部在 final drain 前不可见、event application 失败触发 termination、late event 不改写已发布终态、当前 persistence wire 的精确 round-trip、过期开发 shape 的 frame 隔离/degraded 行为及 event wire hard cut 前后不变。

Output-segment 状态机验收必须覆盖 begin/text/end 严格顺序与 control reserve、index/turn/group/bytes 校验、同 group continued 合并、多个 commentary group 的稳定边界、源内容为空的 commentary 不建项、跨组 credential 使安全边界相等时仍保留项、边界容量在正文变更前 fail closed、final/partial 定性、discard rollback，以及 terminal 未闭合状态映射为 dependency contract failure。Product Task persistence 必须 round-trip commentary ends、final/partial 分类、安全正文起点与精确 projection failure 类型，并拒绝缺字段、递减、越界、非 UTF-8 边界、末端与 response 起点不一致及未知 enum。Bridge 验收必须覆盖 typed output/activity/context exact keys、commentary array 上界、terminal/provisional/responseKind/phase/context source 的跨字段 fail-closed、跨 commentary item/response 和 provisional buffer 的 credential redaction，以及 aggregate snapshot budget。Renderer DOM 验收必须覆盖 Assistant 主叙事中多个独立 commentary Markdown block、可回滚纯文本 provisional、过程底部原位更新的唯一 activity、active/terminal technical work 默认折叠、明确展开后的按序 Tool summary 与 Tool→overview 单详情定位、弱化的 terminal 操作数量摘要、final/partial Markdown、partial+terminal 唯一 composite notice、Task+Run disclosure 隔离、Context/usage 的零值与 cache-only 边界、中英文 catalog parity、键盘/ARIA、reduced-motion 和窄屏无横向溢出；不得出现 raw thinking/event timeline、Tool input/progress/result 主区副本或 `file_changes` UI。

Agent 对话 Renderer 的 vertical 验收必须覆盖 [正式渲染机制](ui-design.md#72-agent-对话渲染机制)：使用带时间间隔的多段 Agent 输出与 Tool/Run observation，至少证明正式 terminal fact 发布前出现多个递增 Snapshot revision，并观察到 commentary、`tool_start → tool_result`、activity、waiting_user 与对应的多次 ProductDelivery notification。Bridge revision notification 可以在 32ms 窗口内合并到最新 revision，但不得把跨窗口 revision 延迟到 terminal。provisional/discard、retry 和 final/partial 的状态迁移继续由 output-segment、Bridge decoder 与 Renderer DOM typed fixture 闭合验证；真实 vertical 还必须报告 `textDeliveryGranularity`，当前 AgentCore Provider facade 若只在 provider message boundary 交付文本，必须如实报告 `provider_message_boundary`，不得把它写成 chunk streaming 已通过。只在 terminal 后检查最终文本存在、一次性发送完整 fixture delta、用动画模拟推进或仅验证静态 DOM，均不能作为“用户持续感知到 Agent 正在推进”的完成证据；若所有真实 Snapshot 只在 terminal 到达，应归为 ProductDelivery/Host delivery 缺陷而不是 Renderer 补帧问题。

带 scripted Provider response 的 vertical 只证明 Host、Bridge 与 Renderer 能在上游提供多段 commentary 时持续交付，不能证明真实 Provider 会在每个 Tool turn 产生 commentary，也不能单独作为真实长任务过程密度已经验收的证据。真实 Account 运行的报告必须分别记录 closed commentary 数、纯 Tool assistant turn 数与 terminal 前 activity 序列，并把“上游没有提交更多可见文本”和“已提交文本未被持续投影”区分开。当前另有一个独立 Product activity 缺口：无 Tool identity 的 `CoreEvent.progress`（包括空 `tool_name` 的 turn-boundary notification）仍会覆盖为 `executing_tools`；在后续状态投影修复完成前，不能用该 generic activity 证明 Tool 执行状态准确。

Product Task Session gateway 的结构验收固定为：`product/task/agent_session.zig` 是 Product 侧唯一允许出现裸 `*agent.Session`、`agent.SessionRoute`、`agent.SessionRestoreRoute` 与 `Runtime.releaseClosedSession` 的文件；`runtime.zig` 的 attached 状态只持 `Binding`，closing 状态只额外保存 close-worker 独占 Binding 与不可变 route id fact，recovery candidate 只持 `Binding + CheckpointRestoreReport`，Runtime attachment 与 worker job 持 scoped/worker-owned `Access`，projection 不持 Binding、Access 或 Session route。guard 必须同时禁止 raw Session getter、Task 外 route 逃逸和 projection 直接 Session API 调用，并允许 `SessionDisposition`、`RunControl/RunControlLease`、route id 与 restore report 等 typed facts。lifecycle tests 必须覆盖 queued cancel/worker exactly-once Access、close 等待 Access quiescence、close worker 与主线程 Binding 隔离、terminal event drain 前 route id 稳定、Runtime shutdown join 后 Binding 不可再用，以及 `max_sessions = 1` 下 model rollback/persistence outcome unknown 收口后 slot 可复用。

Storage 的自动化必须同时覆盖内存 target 与测试显式提供的 temporary file path，并在 Debug、ReleaseSafe 至少各运行一次定向入口。共享 conformance 负责 backend-independent 行为，包括 receiver 对同一 Database 的直接再入拒绝；direct backend tests 负责 `WAL + synchronous=NORMAL` profile、单连接内存可见性、Database 级间接再入与异 Database 调用、migration 原子性与版本 namespace、完整 batch rollback、reopen、busy/corrupt/invalid output 和结果上限。architecture guard 负责证明 SQLite C API 与 amalgamation 只进入 Storage concrete backend、上层尚未导入 Storage/SQLite、`app.zon` 尚未声明 Native SDK `sqlite` capability。上述结果只证明基础能力，不证明 production `app.db`、Product schema、业务迁移、单实例或断电 durable policy 已接入。

Product Skill 的 local-asset guard 必须正向证明总 Runtime 只经内部 `management_runtime.zig` 闭合目录/归档 preview、已安装 definition 读取、canonical `.skill` 导出、install/reimport/uninstall/retry、staging、恢复与 catalog reconciliation；该内部 owner 可以依赖唯一 package/management/policy/state kernels，但不得取得 Product Control、Task/Workspace view、具体 Executor、Agent Runtime/Session 或线程。Product Control 对应公开方法只能做 Workspace authority/Task quiescence gate、时间事实与 revision publication；projection 不得直接调用 package 实现、Transactions、staging root、persistence failure mapping 或 catalog reconciliation。

Product Skill 的公开表面 guard 必须证明 `product/skill.zig` 只导出 runtime、ports、catalog、enablement 与 management；package、policy、state、view、management_runtime 不得从聚合入口导出。Product Control Runtime 只允许直接消费 Runtime/ports 和 Task 所需的 catalog 叶面，不得直接 import 内部 kernel、重新拼装 View 输入、访问 `.skill.state`，或取得 `CatalogSlot`/`CatalogControl` 可变指针；Task admission/refresh/recovery 只能消费 immutable typed authority，catalog redaction 与 uninitialized refresh 判断必须经 Runtime operation。definition read/export 的 canonical root 解析与打开必须留在 Runtime/management runtime，projection 不得出现 `openSkillRoot`、`CanonicalRoot` 或 `.agents/skills` 路径拼接。Runtime 必须是内部 View 派生与 management runtime 的唯一 live aggregate 入口。

## 长期证据账本

### Metask Account 与真实 AgentCore Run

- **规范**：[产品需求](requirements.md)、[Account 架构](account-architecture.md)。
- **证据**：`git show dbaaf81b0217d4016944960ee8621e9a23274f05:docs/phase-0-validation.md` 中 2026-07-20 的真实链路记录；2026-08-10 使用 production `metawork-app` / `metawork:use` refresh generation 复核当前无 Profile-ID 路径。
- **结论**：2026-07-20 的打包 `.app` 完成当时的 OAuth、profile、API Key/model catalog、execution persistence，以及 `gpt-5.5`、`deepseek-v4-pro` AgentCore Run；该旧证据不证明后续 Renderer、设置、模型选择或平台交互仍然通过。2026-08-10 的复核确认 `/api/v1/auth/me` 返回 HTTP 200 与匹配用户，错误的 `/api/v1/auth/oauth/userinfo` 返回 HTTP 400 `invalid scope`，OAuth API Key catalog 与 API Key bearer model catalog 均不需要 Profile header；这些结论现由 Account 合同和回归测试持续约束。

### AgentCore target baseline

- **规范**：[高层架构](architecture.md)、[ABI v1 消费合同](agentcore-abi-v1.md)。
- **证据**：macOS arm64/x86_64 与 Windows x86_64/arm64 GNU 均锁定 clean source commit `b66e3d4c11ab220fd9d0826a6841fc61ae90270e`；四者均为 ABI v1 revision 14 exact artifact。四个 target archive 的 manifest payload checksum、target 架构与 discovery symbol 已验证并原子 stage。
- **结论**：所有 target policy 只接受 ABI v1 revision 14 与 64-byte root table，required surface 由 root + 五个 mandatory child table 定义；没有 revision 13 fallback。macOS x86_64 的真实 desktop vertical 仍须在对应目标环境独立采集。

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
- `src/native_sdk_compat/app_single_instance/windows.zig` — `app_single_instance` 二级兼容。精确 Win32 symbol allowlist、data-root lease 的二次取得/释放恢复、current-user Named Pipe 单次有界 transport、Coordinator 的 listener-closed/lease-held 重新竞争与 cold-start endpoint 重试、20 个真实进程冷启动竞争、隐藏/最小化窗口激活、argv/cwd 转交、显式退出后的 graceful restart、clean shutdown、强制终止后的 lease 恢复、development/automation 正式构建与 macOS 分支隔离已在 Windows 验证；显式退出确认后的 ingress-before-close 顺序、前台资格转交 API 与 `showWindow`/`focusWindow` 请求由精确结构 guard 覆盖，交互式失败提示和真实安装升级仍待人工平台验收。Native SDK 提供并通过同等实例仲裁与 activation 验收后删除实现、allowlist 和专用测试。
- `src/native_sdk_compat/app_single_instance/macos.zig` — `app_single_instance` 二级兼容。精确 POSIX/CoreFoundation symbol allowlist、`confstr(_CS_DARWIN_USER_TEMP_DIR)` 私有 endpoint、128-bit 有界名称与 aarch64 macOS 交叉语义编译已通过；0600 socket、peer UID、并发转交、固定失败提示、clean shutdown、残留 socket 和 crash recovery 尚未取得 macOS 目标平台证据。Native SDK 提供并通过同等实例仲裁与 activation 验收后删除实现、framework link、allowlist 和专用测试。
- `scripts/native-sdk-compat/macos-icon-composer.mjs` — `macos_icon_composer_package` 打包期兼容，不属于 Application Runtime 一级/二级路径。当前只允许 Xcode `actool` 26.6（bundle 24765）把单一无 glass/effect 的 `assets/icons/MetaWork.icon` 编译为 `Assets.car` 与 fallback ICNS，在未签名 `.app` 中替换 Native SDK 临时 ICNS 并写入标准 icon metadata。源结构、PNG 字节一致性、编译参数、工具版本、输出集合、resource digest、plist identity 和签名前顺序已有 Node test 与本机真实 `actool` compile 证据；Developer ID/DMG/notarization 和 macOS 26 Finder/Dock 明暗模式视觉验收尚未执行。Native SDK 正式提供同等 `.icon` artifact 能力并通过全部验收后删除 seam、测试和 allowlist。

`src/app/window.zig` 的显式退出使用 `Runtime.showMessageDialog` 与 `Runtime.closeWindow`，属于正常 Runtime 路径，不进入兼容 allowlist。

### 已登记架构缺口

- `src/app/platform.zig`、`src/app/window.zig` 与 `src/app/account_platform_binding.zig` 仍有 Runtime 已覆盖能力的直接低层调用，Application adapter 仍长期持有原始 `PlatformServices`。后续按独立 routing DAG 收口，不扩大为兼容 allowlist；Account Product owner 已只消费 MetaWork-owned ports，这一剩余缺口不再反向传播 Native SDK authority。
- `src/app/platform.zig` 的 main-loop `wake` 尚未形成单项兼容 seam；先确认 SDK 缺口，再隔离并验证线程与 shutdown。

因此，单个 window-chrome seam 通过不等于全仓 Native SDK 能力路径合规；上述缺口未收口前，全仓 gate 保持打开。

## 平台与 artifact 验收

构建必须显式或按受控默认值选择 `development | release | automation` artifact kind。development 精确保留当前 `app.zon` runner identity、Windows `MetaWork`、macOS `MetaWork Dev`、`<base>.account` 与 `<base>.mcp`；`-Dautomation=true` 必须与 `-Dartifact=automation` 同时成立，并派生 `.automation` runner、`MetaWork Automation`、`.automation.account` 与 `.automation.mcp`。release identity 未完整登记前必须在 build/package 阶段 fail closed。architecture guard 与 Native test graph 必须验证已启用 artifact 的 runner/data/Account/MCP namespace 不重合；真实 automation harness 仍使用隔离的 `HOME`/`APPDATA`/`LOCALAPPDATA`，两层隔离不能互相替代。

### macOS

首次使用真实 Account 前，按 [macOS 分发的本地签名规则](macos-distribution.md#本地签名非分发)选择 Apple Development identity：

```bash
node scripts/setup-macos-local-signing.mjs setup
node scripts/stage-agentcore-bundle.mjs /absolute/path/to/aarch64-macos-bundle
node scripts/stage-agentcore-bundle.mjs /absolute/path/to/x86_64-macos-bundle
npm run build:debug
npm run build:release
npm run package:macos
```

跨平台开发入口与 Apple Development 签名规则由 [macOS 分发的本地签名章节](macos-distribution.md#本地签名非分发)定义并由 `dev.mjs` 负责，setup 只复用该开发 owner；Developer ID、应用与 DMG 签名、公证、staple、Gatekeeper、Finder 左到右拖拽布局、磁盘映像及挂载内容的身份与完整性规则由同一平台文档的正式分发章节定义并由 `package-macos.mjs` 负责。两个实现 owner 必须保持双向隔离。`package-macos.mjs` 必须先验证 canonical bundle，再以版本 allowlist 内的 Xcode `actool` 编译一次 `assets/icons/MetaWork.icon`，随后按 resolved build target 让 Native SDK 从 `.agentcore/bundles/<target-id>` 生成未签名 `.app`。应用签名前必须把编译所得 `Assets.car` 与 `MetaWork.icns` 逐字节 stage 到 `Contents/Resources`，删除 SDK 的 `AppIcon.icns`，把 `CFBundleIconFile` 与 `CFBundleIconName` 精确设为 `MetaWork`，同时把 64 × 64 托盘 PNG stage 到运行时相对路径 `Contents/Resources/assets/icons/tray-icon.png`；任一资源、metadata 或工具链变化都 fail closed。完成资源 gate 后以 `lipo` 确认主程序恰好为该 target 的单一架构，随后只执行一次 Developer ID 应用签名，并在签名后再次检查 Icon Composer resource digest、Renderer、托盘资源、metadata 与签名 policy。`package:macos` 默认 `all`，两种架构必须复用同一次 actool 输出并依次产出小写 `metawork-<version>-macos-arm64.dmg` 与 `metawork-<version>-macos-x64.dmg`；`npm run package:macos -- arm64` 或 `-- x64` 只产出所选单一架构。入口不得根据 last-stage state 推断架构，也不生成 Universal、preview 或 ZIP。普通 check/test/build 不得访问 Icon Composer compiler、个人证书、Finder 或 notary profile；`package:macos` 成功证明当前图形用户会话生成的可分发磁盘映像，不等于更新能力完成。macOS 26 的 Finder、Dock 与运行中已打包应用须在 Light/Dark 下独立确认没有非设计渐变；至少一套 macOS 26 以前的系统须确认 fallback ICNS，未取得这些视觉证据前不得报告图标最终验收完成。

Keychain 跨重建授权稳定性当前为 **人工验收待完成**：在同一精确 commit 上让 Debug app 写入并读取 Account credential，完全退出并重新构建，再次恢复 Account，确认没有出现新的 Account Keychain 授权框。首次选择签名私钥产生的系统授权不属于 Account Keychain 失败。

涉及 AgentCore candidate、正式 Host、Renderer reload、产品数据面或生命周期时，按变更范围增加：

```bash
AGENTCORE_BUNDLE_ROOT=/absolute/path/to/bundle node scripts/run-agentcore-restore-probe.mjs
AGENTCORE_BUNDLE_ROOT=/absolute/path/to/bundle node scripts/run-agentcore-provider-test.mjs
node scripts/run-agentcore-permission-probe.mjs --staged
node scripts/run-lifecycle-tests.mjs
node scripts/test-agentcore-vertical-macos.mjs
```

macOS artifact、Native vertical、secure input、window chrome 与真实 WebView 可访问性必须独立采集，不能由 Windows 结果替代。

### Windows development baseline

```powershell
node scripts/stage-agentcore-bundle.mjs C:\absolute\path\to\x86_64-windows.win10...win11_dt-gnu
node scripts/run-windows-bringup.mjs
zig build test-single-instance -j2 -Dartifact=development
node scripts/test-window-chrome-windows.mjs --resize-session-only
node scripts/test-window-chrome-windows.mjs
node scripts/test-single-instance-windows.mjs
```

`run-windows-bringup.mjs` 必须覆盖 staged verifier、restore probe、bundle/lifecycle tests、正式 test graph、Debug/Release build 和真实 Windows vertical，并报告 verifier 实际读取的 staged ABI identity，不硬编码 revision 文案。真实 vertical 还必须观察同步 Renderer Bridge command 的 `main_thread=true`，缺失该事实或观察到 false 均失败；该断言证明同步 handler 占用平台主线程，因此只能承载有界即时工作，并构成 File Preview 必须使用 Native SDK async registry + Product Control worker lane 的回归依据。window-chrome 的 resize/session gate 与 pointer/controls gate 分开报告：程序化 resize 只能证明 Native window、最小尺寸和同一 Renderer session，不能替代真实鼠标 edge resize、work-area clamp 或 WebView 焦点验收。

`test-single-instance` Zig step 确定性覆盖 listener 已关闭但 lease 延迟释放时 Secondary 成为新 Primary、Primary 已持 lease但 endpoint 延迟出现时转交成功，以及 owner 在完整 deadline 内始终不可达时 fail closed。`test-single-instance-windows.mjs` 使用临时 `APPDATA`/`LOCALAPPDATA` 和 automation artifact，不接触 development 或正式用户数据。它必须让 20 个真实 OS process 同时竞争同一 canonical data root，证明恰好一个 Primary 到达 Runtime、其余 Secondary 在转交 argv/cwd 后正常退出；随后覆盖隐藏窗口与最小化窗口的显示/恢复、显式退出后的 clean restart、强制终止后的 lease 恢复以及最终 clean shutdown。该 vertical 证明真实进程仲裁和窗口状态恢复；显式退出确认后先停止 ingress 再关闭主窗口、前台资格 API 与 `focusWindow` 请求仍由精确结构 guard 证明，Windows 是否最终授予前台属于系统策略，不能用测试强制置前来伪造。

当前已验收普通拖动、最大化拖动恢复、Renderer controls、close-policy hide/reopen 与 clean shutdown。top/bottom/四角 resize、edge snap、双击标题栏、系统菜单、touch/pen 和完整 UIA 焦点仍需独立证据。

`node scripts/run-agentcore-abort-timing-probe.mjs --staged` 用于取证 `session_abort` 返回后是否仍有 callback 投递；结果尚未采集，因此该 probe 保留。Windows distribution、安装/更新、完整 process-tree/timeout/security matrix 和 Linux target 不由 development baseline 证明。

### Windows 分发

具体安装器、Authenticode 与发布边界见 [Windows 分发](windows-distribution.md)。

```powershell
npm run package:windows
npm run package:windows -- arm64
```

该入口默认选择 x64，显式 `arm64` 选择 ARM64；两种架构都必须先完成对应 target 的正式 Release build。Windows build graph 把 `assets/icons/app-icon.ico` 编译为主程序的 PE 图标资源，再由 Native SDK `package --target windows` 生成架构隔离的 runtime stage 并保留同一 ICO 的外部副本。stage gate 精确验证 app.zon version/App ID、ReleaseFast、Windows GUI subsystem、主程序与 WebView2 loader 的目标 PE machine、应用图标与 Renderer assets，随后才允许 Inno Setup 6.7.3 或兼容的 7.x 生成小写 `metawork-<version>-windows-x64.exe` 或 `metawork-<version>-windows-arm64.exe`。安装器、卸载项、开始菜单和可选桌面快捷方式统一消费该 ICO，最终 gate 要求精确文件存在、具有 PE identity 且输出 SHA-256。安装器按用户安装、注册开始菜单与卸载入口，不要求管理员权限。

`npm run package:windows -- --signing required` 与 `npm run package:windows -- arm64 --signing required` 是同一入口对应架构的正式 Authenticode 模式。它们必须从 Windows SDK 发现 x64 SignTool，以精确 SHA-1 thumbprint 选择当前用户证书库身份，使用 SHA-256 文件摘要和 RFC 3161 SHA-256 时间戳；MetaWork-owned EXE、Inno signed uninstaller 与最终安装器必须由同一 SignTool definition 签署，Microsoft-owned DLL 保留并验证原厂签名。每个可直接验证的 PE 都必须通过 `signtool verify /pa /all /v`，任何缺失配置、签名、时间戳或验证失败必须 fail closed。普通 unsigned mode 不读取签名身份，不能满足该 Gate。

当前自动化覆盖 metadata、架构选择、Inno/SignTool 发现与 capability gate、Native runtime stage 结构、GUI subsystem、主程序与 WebView2 loader 的精确 PE machine、精确签名参数、单 EXE identity 和直接 PE 的 Authenticode verification；当前 signed Windows x64 artifact 已完成一次隔离目录 silent install/uninstall smoke，直接验证安装器、实际落盘主程序与 `unins000.exe` 的 `/pa /all /v` Authenticode policy、Certum EV signer、RFC 3161 时间戳和零 warning，并确认 WebView2 loader 原厂签名、Renderer assets、图标、安装目录与卸载注册表清理。2026-08-28 在 MetaWork `763cf78` 与 AgentCore `b66e3d4c11ab220fd9d0826a6841fc61ae90270e` 上完成 `npm run package:windows -- arm64 --signing required`：ARM64 主程序与最终安装器均通过 `/pa /all /v`，Certum EV signer、RFC 3161 时间戳、WebView2 loader 微软原厂签名均验证成功且为零 warning，最终安装器 SHA-256 为 `830d524cb35000a342687658b5aaf561d003f6149a26775747aae8c810a732a5`；该证据不替代 ARM64 安装启动验收。隔离安装 smoke 只能在没有同 App ID 正式安装的干净环境执行，避免覆盖真实用户安装状态，因此不内嵌进普通 package 命令。交互式 wizard、开始菜单启动、托盘驻留下升级替换和 Windows 10/11 平台矩阵仍是人工验收待完成。普通 check/test/build 与未签名 package 不得访问签名身份。安装器能力不证明自动更新、channel、回滚或迁移能力。

### Checkpoint artifact boundary

revision 14 不继承旧 artifact 的 checkpoint 样本或通过结论。每个平台必须取得并锁定 revision 14 exact artifact 后重新采集 platform vertical；旧版本结果不能替代，缺少 artifact 的平台直接失败。checkpoint digest 与产品预算的规范性语义见[AgentCore 集成契约](agentcore-integration.md)和[ABI v1 消费合同](agentcore-abi-v1.md)。

## 尚未验证的能力

本节只防止错误能力声明；行为和技术边界仍由对应 source of truth 定义。

- 单 AgentCore Worker、进程级 crash semantics、async pending、suspend/resume 和跨进程 in-flight Run recovery 尚未实现。当前只支持正常 Application 重启后从 latest finalized checkpoint 显式恢复 Conversation attachment。
- `accept_edits | full_access` 与 `disabled | sandboxed | unrestricted` 的代表性 exact behavior 已在当前 aarch64 macOS canonical bundle 上完成 artifact probe；其他 target、Product Task profile persistence、Agent idle mutation、撤权、Run provenance 和 Scheduled noninteractive 尚未实现并完成验收。`standard` 所需 typed risk/effect 与执行前 commit boundary 也尚不存在，因此当前 UI 必须隐藏全部 profile 选择并继续使用 `accept_edits + unrestricted` compatibility baseline。
- strict Workspace security、正式 Host tools 和持久权限规则尚未完成独立安全验收；它们不阻止后续产品化不宣称 Sandbox 的 PermissionProfile，但也不能由 profile 反向证明已经具备。
- File Preview 的确定性回归必须覆盖：Snapshot file reference 只发布 `id/title/displayPath`；request 精确绑定 Task/Run/reference 且拒绝旧单-id/额外 path shape；async command 不出现在同步 registry；2-worker/8 in-flight 独立 lane 的 no-follow、root containment、regular-file、256 KiB/行/UTF-8/control 分类与 metadata changing；completion 的 Workspace/locator reauthorization、current/historical credential 与截断前缀遮蔽；非 ready 空正文；Renderer generation stale-result 丢弃、Task/reference 失效关闭、桌面和约 390px Drawer、键盘/焦点/横向溢出；shutdown join/drain/settle exactly once。当前自动化覆盖 wire、owner 与 bounded read/redaction 核心不变量；真实桌面 Drawer 的 Windows/macOS 视觉、键盘和窄屏验收仍为人工验收待完成，不影响 typed File Preview 路径的自动化状态。
- 当前四个 target ABI package 均已提供 typed `file_changes` observation，但 Product FileChange 的 owner、持久化、恢复与投影尚未验收；typed Output、plan progress/approval 和 custom UI 仍不由当前 ABI 提供。对应 UI 必须保持关闭。
- AgentCore Skill catalog lease 是否固定 Skill body/resources 的历史快照尚未取得独立合同证据；当前只承诺 pinned catalog/policy identity 与显式 refresh，不宣称未 refresh 的外部内容必然可按历史字节执行。AgentCore 也不提供 shadowed candidates 或完整 resolution trace，Skill UI 只能展示 resolved winner 与 typed issues。
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

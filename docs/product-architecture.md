# MetaWork Product 架构

本文定义 Product 内部 owner、跨 owner 与跨 aggregate 事务、并发、生命周期、持久化和恢复、Product-owned 稳定交换 artifact，以及 Product Control 与相邻 Agent 执行边界的协作。它不定义用户可观察产品行为、Account 内部状态机、Renderer Bridge wire、AgentCore ABI、源码 leaf graph 或当前验证状态；这些内容分别以[产品需求](requirements.md)、[Account 架构](account-architecture.md)、[Renderer Bridge 合同](renderer-bridge-contract.md)、[AgentCore 集成契约](agentcore-integration.md)、[工程结构与所有权](project-structure.md)和[验证规范](validation.md)为准。顶层进程、故障域和安全边界见[高层架构](architecture.md)。

## 1. Owner 与事务模型

Product 由两个 named owner 组成，跨 owner 用例由对应的 Application coordinator 编排：

- Account 拥有 Metask identity、catalog、credential、Metask preference、source generation、source candidate 构造及其内部事务与恢复；
- Product Control 拥有全局默认来源、Execution aggregate、Product execution generation、已安装的默认 ExecutionConfig、Schedule credential scrub、pending candidate、Workspace、Task、Skill、MCP、共享 Executor、跨 aggregate admission、canonical 产品 projection、revision、产品历史与关闭顺序。Execution aggregate 独占通用 Protocol/ExecutionConfig/source-candidate 合同、user-managed Model Connection registry、credential vault port、测试状态、默认 binding、持久化与恢复。

Agent 位于 Product 之外，拥有 MetaWork 对 AgentCore Runtime、Session、Conversation、callback、event pump 与 terminal execution fact 的集成生命周期。Product Control 只调用 Agent 的公共执行能力，不管理 Agent Runtime 生命周期、不读取其内部状态，也不借 Agent 获取通用 I/O。Application 创建和关闭 Agent、安排主线程 wake，并协调 Account 与 Product Control；它不持有领域运行状态，也不独立决定这些 owner 的 policy。

Application 必须分别组装 Account coordinator 与 Execution coordinator。前者只编排 Account Runtime terminal commit 与 optional Metask source candidate 的线性 no-fail handoff；后者只绑定 Execution credential vault、Agent-owned connection probe 与 Execution 管理生命周期。Execution registry 的 CRUD、默认来源选择、恢复、Schedule scrub 和已安装 execution 交接属于 Product Control 内部事务，不得由任一 Application coordinator 通过公开的 `begin/prepare/commit/install/end` 步骤重新拼装。Account unavailable 与 Execution unavailable 必须独立启动、降级和关闭。

Execution、Workspace、Task、Schedule、Skill 与 MCP 是 Product Control 持有的 aggregate，不形成新的顶层 Product owner。各 aggregate 独占自身状态机、局部事务与持久化 policy；Product Control 只拥有必须同时观察多个 aggregate、execution、publication 或生命周期事实的不变量，不能把局部 policy 重新吸收到组合层。

Product 事务只使用三种机制：

1. **aggregate-local transaction**：对应 aggregate 完成 candidate、effect、typed outcome 与 committed install；
2. **cross-owner handoff**：Application coordinator 在主线程按已定义顺序转移线性所有权，任何 payload 只在明确的 take、install 与 commit 点移动一次；
3. **asynchronous reconciliation**：worker 只持 owned payload、窄 effect capability 和不可变或 atomic facts，完成回到主线程后按完整 authority token 重新校验，stale 结果只销毁、不安装、不自动重放。

Product 不建立统一事务引擎、通用 command bus 或 Product event bus。跨边界 capability 必须按用例裁剪，不得暴露完整 Runtime、内部 aggregate、可变状态指针或 raw getter；其具体语言表示和 leaf module 由代码与 build graph 决定。

## 2. 跨边界事务

### 2.1 Execution aggregate 与 Account handoff

Account 和 Product Control 是同级 owner，彼此不导入对方 Runtime。Product Execution 是 Product Control 持有的 aggregate，不是第三个顶层 owner；它发布不依赖 Account、Application、Bridge 或 Agent 的纯 `Protocol`、`ExecutionTarget`、`OwnedSourceCandidate`、`ExecutionConfig`、Model Connection command/view 和线性 owned config 合同。Account、Task、Schedule 与 Product Control 都只消费这份合同，不复制 enum，也不通过 Account 合同中转。

Metask execution 的运行时数据流为：

```text
Account resolve Metask selection
→ Application coordinator controlled transfer
→ Product Control installed-execution ownership
→ Agent Session consumption
```

Model Connection execution 的数据流为：

```text
Execution registry + Application credential vault
→ Execution resolve
→ Product Control installed-execution ownership
→ Agent Session consumption
```

两条来源最终都必须形成同一份显式 protocol、endpoint、model、credential、Product execution generation 与服务实例引用。Metask 先产生不含 Product generation 的 `OwnedSourceCandidate`；只有 Product Control 可以分配 execution generation 并将其转成 `ExecutionConfig`。Metask 引用为 `metask:<api-key-id>`，Model Connection 引用为 `model_connection:<connection-id>`；引用标识配置对象，不包含 credential，也不能替代 generation。Account source generation 与 Product execution generation 不要求数值相等。默认 execution、Task attachment 和后台任务各自持有所需的 owned copy；Session、恢复、连接测试及自动标题消费同一份解析结果，不根据厂商、endpoint、模型名或服务实例引用重新选择 protocol。服务实例引用不进入 durable history 或 Renderer。Product 层不定义 `ProviderKind`、厂商分类、协议反推或平行 enum；Agent 对 AgentCore ABI 的 provider code 映射仍是 Agent-owned transport 细节。

Model Connection 使用显式的 `openai_responses | openai_chat_completions | anthropic_messages | gemini_native` protocol。前三者分别要求完整 `/v1/responses`、`/v1/chat/completions`、`/v1/messages` endpoint，Gemini Native 使用由消费者追加 model 与 operation path 的 base URL。endpoint 只允许 HTTPS 或用户明确配置的 loopback HTTP，并拒绝 control character、userinfo、query/fragment credential、过长 URL 和协议路径不匹配；Renderer 不能拼接或覆盖规范化 endpoint。当前不做 model discovery，用户提交有界 model id。

Execution registry 与 Account identity/catalog 独立。不同连接即使 credential 相同也保持不同 connection id；更新名称、endpoint、protocol、credential 或模型保留 connection id，但 endpoint、protocol 或 credential 变化产生新的 connection generation。首次成功的 Agent-owned one-shot Completion test 使当前 generation ready；失败重测只更新 latest test status，不撤销已 ready generation、当前默认 execution 或跨重启 binding。同一 ready connection 选择模型只产生新的 opaque execution generation；既有 Task 与 Session 不热替换。

Metask handoff 的 committed-state 写路径为：

```text
Account worker construct candidate (no preference write)
→ Account preference effect admission and durable write
→ exact reread on outcome unknown (candidate | old | third value)
→ Account commit terminal state/catalog/preference intents
→ publish secret-free Account fact/authority
→ no-fail transfer candidate ownership to Product Control
→ Product validates authority and durably scrubs Schedule
→ assign/retain Product execution generation and install, or retain one pending candidate
→ publish one canonical Product revision
```

Account 在 terminal commit 前是 candidate 的唯一 owner；preference 明确失败、effect admission 失败、旧值重读、stale、cancel 或 shutdown 必须由 Account secure-zero candidate。Account terminal commit 后，Application coordinator 以窄 no-fail sink 恰好一次转移 candidate，不能持有、读取或复制 credential。Product 接管后的 Schedule I/O、scrub、generation 分配、安装与恢复可以失败，但失败只形成 Product fact，不调用 Account abort、不回滚 preference，也不补写 Account error。

是否需要 default replacement 只由 Product Control 根据当前 default/active source 与操作类型决定，Account 不发布 replacement policy，Application coordinator 也不预先开启 default replacement。当前 Model Connection 为默认 source 时，普通 Metask catalog/preference mutation 只更新 Account-owned preference，Product 消费并销毁 candidate，不阻塞 Task admission、不改动 active execution。显式切换回 Metask 是 Product-owned command：Product 建立 source-selection operation，再请求 Account 按 committed preference 解析 candidate；只有 candidate、Schedule scrub 与 durable custom-default clear 全部成功后才安装。失败继续保留当前 Model Connection，并通过 Execution projection 发布精确错误。

Model Connection 设为默认的写路径为：

```text
Execution resolve candidate + credential
→ Product Control begin replacement and complete all fallible durable scrub preparation
→ Execution atomically commit registry default + execution generation
→ Product Control no-fail install ExecutionConfig and binding
→ publish canonical projection
```

registry commit 前的 scrub preparation 明确失败时，registry 与已安装 execution 都保持旧值；registry commit 明确失败时清除 preparation 并保持旧值；commit 成功后只允许 no-fail ownership transfer。Connection CRUD/test 不隐式改变默认 source。

每个 Account prepared transition 的 commit 仍在主线程单一 turn 内完成；candidate construction 与 preference effect 可以跨 worker completion，但只能由同一 Account attempt 串接。实际 Product execution 安装只能发生在 preference 已确认、Account terminal commit 与 candidate handoff 之后。Product sink 接管 ownership 本身必须 no-fail；后续 fallible effect 只能改变 Product projection。

Product Control 的 replacement/reconciliation gate 只串行化本次默认 execution 交接与相关新 Task admission。已有 Task、Session、Run 和 worker 已经取得的 owned ExecutionConfig 按原生命周期收口，不热替换、不等待 Account identity 变化，也不被 logout 伪造为已撤权。只改变默认模型且不改变 credential/source authority 时，Account source generation 与 Product execution generation都可以保持；是否允许已有 Task 改变模型必须由该 Task 精确持有的 protocol、generation 与当前 authoritative catalog 共同决定。

Account candidate 在 terminal commit 前的 Account effect admission、preference 明确失败和旧值重读都保留旧 committed preference 并清零 secret；第三种持久化观察进入 Account preference recovery。candidate 转移后，Product 可以安装、暂存或销毁，但不得拒绝 Account commit。已经 durable commit 的 identity/token rotation/preference 仍从已观察 phase 收口，不能伪造回滚；结果不确定的 mutation 一律精确重读且不得自动重放。

Renderer reload、断连或命令 timeout 只影响交互与 resync，不能取消 Host 中的 deadline、mutation 或 terminal completion，也不能代表这条 commit 链失败。Renderer Account selection 只提交无 secret identifier 与 expected catalog generation；Product source/Execution command 使用自己 projection 的 generation。Renderer 不参与 prepare、commit 或 credential transfer。

Identity replacement、default execution replacement 与 durable Task history 是三个边界。durable history 只保存解释执行来源所需的 protocol、model、不透明 execution generation 与 binding facts，不保存 Account identity、Model Connection identity、API Key metadata、credential locator、完整 ExecutionConfig 或可重建 secret 的信息。

Canonical snapshot 同样保持 owner 边界：根 `account` 只投影 Account-owned Metask identity、catalog、selection、取消能力与稳定错误，不投影 source/Product generation；根 `execution` 由 Product Control 投影 durable default、process-local active source/generation、replacement/availability、新 Task admission 与 Model Connection。两者可以独立处于 ready/unavailable，例如 Account 已恢复而 Schedule 或 Execution 恢复失败时仍必须发布合法 snapshot，不能伪造 active Metask execution，也不能令整个 Workbench fail closed。新 Task 尚未存在，其 admission 由 Product Control 决定；Task 创建后，其 Run、Session、binding、阻塞与恢复只由 Product Task 自身事实决定，Account mutation 不构成全局 Task gate。

Product 对每个 Metask authority 最多持有一个 pending candidate，绑定 `account_id + api_key_id + model_id + source_generation`。任一绑定事实变化、默认来源切换到 Model Connection、logout、shutdown 或新 candidate 取代旧 candidate时必须 secure-zero。Schedule store 不可信或 scrub 失败时不得安装 candidate；若存在待退役 active credential，Product 保留其 owner直到 scrub/clear 明确提交。pending candidate 不持久化：冷启动由 Account 恢复 committed preference 后重新解析 candidate，Product 再次 scrub；store 仍不可信时发布 recovery 并等待 canonical hard reset，不回滚 Account preference或跳过 scrub。

`model-connections.json` 是 Execution aggregate 的独立原子 registry，继续位于既有产品数据目录并保持既有 wire shape；它只保存 connection id、display name、protocol、normalized endpoint、有界 model metadata、credential/test status、generation、默认 binding 和待完成 credential deletion tombstone。API credential 只进入系统安全存储；既有 Keychain/service identity 和以 connection id 派生的 account identity 保持不变。旧 `provider` 字段不读取、不迁移、不双写，包含旧 shape 的 registry fail closed 且不得被自动覆盖。

连接删除先提交 credential cleanup tombstone，再删除系统 credential，最后原子清除 tombstone；创建先提交目标 id tombstone，再写 credential，最后以一次 registry commit 替换为完整连接。启动与后续 mutation 必须排空 tombstone。确认 credential 缺失时撤销对应 default 并持久化 `credential_status = missing`；安全存储暂时不可读不能被误写成已确认缺失。Execution 恢复与 Account identity 恢复相互独立，一方 unavailable 不得使另一方的持久化事实被清空或覆盖。

### 2.2 Workspace 与 Task admission

Workspace 是 Product Control-owned 产品对象；产品语义和用户操作以[产品需求](requirements.md)为准，wire 以[Renderer Bridge 合同](renderer-bridge-contract.md)为准。本节只定义 Workspace、Task、ExecutionConfig 与 Agent Session 之间的 admission 和提交关系。

Manual Workspace 与 Automatic Workspace 共用一个 registry 和 Task 引用关系，`kind` 在 record 生命周期内不可改变。Manual intent 必须重新校验 Workspace identity、epoch 与 authorization；Automatic intent 必须取得 Application 注入的 automatic-root capability。Renderer 不提交物理路径、automatic root 或目录授权 token。

Task 创建在产生外部 effect 前必须证明：

- 当前默认 ExecutionConfig 与 expected generation 仍有效；
- Workspace intent、ownership、epoch 与 authorization 有效；
- Workspace、Task、Agent Session 与 projection 容量可用；
- Product Control 尚未进入 replacement 或 shutdown。

Automatic admission 在完成上述证明后才创建候选目录、临时 Workspace record、Agent Session 和 Task record。发布前的任何失败必须释放 Session 与候选 record，并只回滚本次创建且仍为空的目录；Task 已 durable 发布后的 Run admission 或执行失败不能回滚真实 Task 或目录。Manual admission 对 registry、recent order 与 Task 引用的变化必须与 Task candidate 一同提交，不能发布只更新一半的关系。

每个 Task 在创建时取得 owned ExecutionConfig 和 immutable binding epoch。默认配置变化不热替换已有 Task；显式改变 Task execution 必须在 Task idle、authority 精确且持久化 candidate 可提交时形成新的 binding。Run、manual compact 与 Conversation recovery 共享 Task-owned active-operation 槽；删除和 Session replacement 是独立生命周期用例，必须与该槽互斥并等待已有 operation 收口，不能通过不同入口并发改变同一个 attachment。

PermissionProfile 与 ExecutionConfig 分别拥有自己的产品事实：Product Control 只持后续新 Task 的默认值，并在 Task create admission 时复制；Product Task 持有创建后不可变的 effective profile、interaction fact 与逐 Run provenance。当前开放 `approval_required | full_access`，两者分别映射 AgentCore `accept_edits | full_access`，ShellPolicy 均保持 `unrestricted`；该映射不创建 Sandbox、Workspace trust 或持久 permission rule。默认值变化不改写已有 Task，fresh create 与 checkpoint restore 必须提交同一 profile；当前 ABI 没有可消费的 idle mode mutation，不能用规则拼装、Renderer preference 或跨 profile restore 模拟。

Automatic Workspace record 只有在 owning Task 已物理删除且相关 Run event、worker、Session 和 catalog lease 全部 quiescent 后才能释放。真实目录不因 Task 删除、shutdown 或重启被递归删除，也不能通过扫描遗留目录猜测或恢复 Product record。

### 2.3 Scheduled Task

Schedule aggregate 拥有 Scheduled Task definition、触发游标、occurrence history、persistence health 与 occurrence reconciliation。Application 只提供持久化、wall clock、单一平台 timer、notification 和后台窗口生命周期 capability；它不决定 recurrence、missed occurrence 或 Task admission policy。

到期 callback 只唤醒 Schedule reconciliation，不能直接调用 Agent。一个已接纳 occurrence 必须通过 Product Control 的既有 Task 创建、命名和 Run admission 形成真实 Task，并复用同一 Workspace、ExecutionConfig、Executor、Session、event pump、permission、persistence 与 snapshot 路径；不得建立绕过这些 Gate 的 schedule queue、worker 或 AgentCore 调用路径。

Schedule definition 固定自己的 PermissionProfile；每个 occurrence 在 launch 时复制当时的 definition profile，并以 `noninteractive` interaction 创建 Task/Run。后续 definition update 只影响未来 occurrence，不改写历史 Task。Agent 遇到第一个未覆盖 permission request 时不得发布 pending UI 或等待 Renderer，而要提交 stop fact 并唤醒 canonical Product event consumer 请求中止；只有真实 Run 收口后才能发布 `permission_required`，Schedule 随后进入 `needs_attention`。

Schedule 只持久化已提交的 occurrence 与 Task identity，不持有 Product Control capability、可变 Task 指针、API credential 或 live Session。Task launch 的明确失败按 occurrence transaction 收口；结果不确定时不得重放可能已经创建 Task 的 launch。系统通知只消费已提交的 occurrence/Task terminal fact，通知失败不能回滚产品事实或伪造 Run cause。

Schedule 引用的 execution authority 在触发时必须重新校验；不能用历史 generation 猜测或恢复 credential。Schedule store 是独立持久化边界，其 credential scrub 必须作为 durable candidate commit 完成，不能只修改内存 projection。

Schedule persistence recovery 仍由 Schedule aggregate 决策：只有 typed non-ready health 才发布 action，命令必须校验全局 revision。Schedule 先对当前内存 store 执行 credential scrub 并编码 canonical candidate；Application 对旧 canonical 执行 hard delete，再以 durable atomic replace 写入 candidate，不生成 backup、quarantine 或 migration artifact。明确失败保持旧 health 与内存 store，outcome unknown 保持 timer fail-closed；只有 committed 才转为 ready 并重新 arm。

### 2.4 Skill authority 与本地资产

Product Skill aggregate 拥有本地资产 inventory、management transaction、enablement policy、Workspace catalog authority 与其持久化健康。Agent 拥有 AgentCore catalog acquisition、opaque lease 与运行时 catalog identity；Application 只注入 FileStore、受限文件能力和原生 picker。Product Control 负责 Workspace/Task authority、shared Executor admission、全局 revision 与完整 snapshot，不读取 Skill 内部 state 或拼装物理路径。

Personal 或 Manual Workspace 的 committed Skill authority 必须不可分地拥有 immutable catalog snapshot、policy revision 与对应 Agent lease。catalog acquisition、policy mutation 或本地资产 reconciliation 先形成完整 candidate，并在提交时重新校验 Workspace identity/epoch、catalog identity、policy revision、相关 active operation 与 shutdown。stale candidate 只销毁并释放 lease，不安装、不自动重试。

Enablement mutation 先构造受影响 authority 的完整 candidate，再提交无 secret policy store，最后 no-fail 替换 committed authority。明确 write failure 保持旧 authority；outcome unknown 必须冻结新的 Skill authority mutation 和 Skill admission，不能降级为全启用。尚无 committed authority 的 Workspace 不得锁死无关 scope 的 mutation，但以后取得 catalog 时必须按最新 committed policy 编译。

Task 创建时同步借用当前 Workspace authority 并取得独立 pinned snapshot/lease；已创建 Task 不因 catalog refresh、enablement toggle、安装、替换或删除自动重绑。idle Task 只能通过显式 refresh，在 Agent 成功替换 Session catalog 后提交新的 pinned authority。Conversation recovery 不以 Skill readiness 作为资格，也不向 restore 注入旧 Skill authority；恢复后由既有显式 refresh 重新取得。

本地资产 import、reimport、uninstall 与 retry 使用同一 staged transaction：preview capability 绑定 source、内容摘要、目标 scope 与有效期；commit 重新校验 capability、目标 Workspace authority、冲突 generation 和相关 Task quiescence；publish 后必须完成 Agent catalog reconciliation。明确且可归因于候选的失败回滚 candidate/backup；catalog 暂时不可验证时保留可恢复 transaction 并发布 `pending_verification`，不能声称 ready。恢复只能完成或回滚已登记 transaction，不扫描、接管或删除 canonical root 外的目录。

### 2.5 MCP authority

Product Control 拥有 MCP Desired Registry、connection approval、OAuth consent、credential locator、Runtime Manifest、Admission Authority、mutation/recovery 与 Task admission。Agent 拥有 connector/backend 生命周期、AgentCore descriptor、declarative Runtime apply、Activation、catalog 与 Selection。Application 只执行 child、network、系统 credential、OAuth、HTTP auth snapshot 与跨 owner coordination，不拥有 MCP JSON-RPC、产品状态或 admission policy。Account 与 MCP 不共享 ownership、credential service 或 persistence。

Desired Registry、Runtime Manifest 和 Admission Authority 是三个不同事实：

- Desired Registry 表达已 durable 提交的用户意图；
- Runtime Manifest 表达正式 Agent Runtime 已接管的 descriptor，或无法接管的无 secret absence proof；
- Admission Authority 表达新 Task 当前可以同步借用的已验证 Selection，或明确的 blocked reason。

MCP mutation 必须从 canonical Desired 构造完整 candidate，先提交 registry，再由 Application coordinator 构造 Runtime input、调用 Agent declarative apply、取得正式 Activation，最后由 Product Control 原子安装 Manifest、Activation 与 Admission Authority。正式 apply 成功只影响之后创建的 Session；已有 Session 保持创建时已复制的 authority，不热替换或即时撤权。

registry commit 明确失败时保持旧 Desired 与 authority；commit 结果不确定时不能宣称 canonical generation，必须保留 recovery fact 并冻结后续 mutation。Agent apply 拒绝、malformed report、resource limit 或 activation failure 形成 typed failure 并保持 fail-closed admission，不能把未接管的 descriptor 标记为 loaded。candidate Runtime test 与正式 Runtime 隔离，不安装 Manifest、Admission 或 Task authority。

Application 启动时只创建一次 canonical empty Agent Runtime；恢复出的 Desired 必须在 Product Control 与 coordinator 就绪后沿与后续 mutation 相同的 apply 路径安装。empty create 后 apply 是正常启动协议，不是失败 fallback 或第二条 Runtime path。Agent Runtime create 失败终止启动；外部 MCP child、network、handshake 或 catalog failure 只能使相关 MCP authority unavailable，不能关闭普通 Text Task admission。

MCP apply、OAuth operation、refresh、运行时 reauthorization 与新 Task admission 共享 Product Control 的串行化边界。浏览器等待和网络请求不得持有该边界，只携带 server-bound operation identity；完成时必须按 operation、server/connection fingerprint、consent epoch 与当前 generation 重新授权。stale 结果只清理自身资源。目标 server 进入 OAuth 或 reauthorization 时必须先提交排除它的 reduced authority，不能无关地冻结其他 server 或普通 Text Task。

freshness failure 必须使旧 Admission fail closed 并触发现有异步 refresh；原 Task create、restore 或 mutation 不自动重放。refresh、apply 或 OAuth 已占用执行边界时必须保留 pending 事实，不能丢弃触发。关闭时先停止 MCP management、OAuth/refresh timer 与新 Task admission，再 settle/join worker，释放 Admission 与 Activation，最后由 Agent owner 释放 transport 与 Runtime。

### 2.6 图片与 PDF attachment staging

Attachment staging 是 Product Control 内部、非持久、无用户 identity 的候选资源 owner，不形成新的顶层 Product owner 或 Renderer 产品对象。Application 只通过 Native SDK 原生 picker 取得用户选择，并把完成一次有界读取所需的窄 selected-file capability 注入 Product；Bridge 只拥有 source/window/connection authority 以及 Renderer opaque token 到 Product staging identity 的 grant，不能持有 raw bytes、路径或 Product 内部指针。Renderer 只持 token 与安全 display metadata。

Product Control 使用独立于 Run、File Preview、catalog、restore 与 MCP 的 bounded attachment lane。一次多选按批次原子 staging：worker 只读取普通非空文件，按文件签名校验 PNG、JPEG、WebP 或 PDF，并同时服从 canonical AgentCore 单文件限制、Product 文件数和 raw staging 总预算；任一候选失败必须清零本批已经读取的字节且不发布部分 token。选择路径只活到 worker 建立 owned bytes，不能进入日志、Snapshot、持久化或后续发送时重读。Application/SDK 无法提供满足 no-follow 与稳定读取语义的 capability 时必须明确拒绝，不得回退到 Renderer upload 或主线程无界读取。

staging 状态精确为 `staging | ready | borrowed | consumed | released | failed`。Bridge 在 `tasks.run` 前校验 token 属于当前 connection/window、均为 ready 且不重复；Product Task 在同一 admission 内 borrow bytes、构造有序 Agent `RunInput.multimodal` 并完成 `prepareRun`。Run 写入当前进程 Product Runtime 的接纳点是 token 消费 linearization point：此前失败恢复全部 staging 为 ready，此后无论 history save、enqueue、transport 或 Agent terminal 如何收口都不得恢复或自动重放 token。Agent 在 `prepareRun` 返回后已拥有编码输入，Product 必须清零 raw staging；enqueue 失败形成既有 pre-execution interrupted Run。

用户移除、Bridge disconnect/document generation replacement、明确 release、Product shutdown 和未被接纳的 owner 释放都必须 exactly-once 清零 raw bytes。staging 不使用 wall-clock TTL；每 connection slot、每文件和全局 raw byte budget 保证资源有界。Task durable history 只保存 attachment 的 redacted basename、kind、format、size 与顺序；不保存 token、路径、raw bytes、Base64、digest 或 provider wire。AgentCore checkpoint 继续独占 Conversation 媒体历史。

### 2.7 Identity 与 credential redaction

Product Task identity、Agent Session route identity、execution generation、Workspace identity、Skill policy identity 和 MCP server identity 各自属于对应 owner，不共享生成器，也不能依赖数值相等。跨边界只传递完成当前校验所需的稳定 identity 和 generation，不传递内部指针或 secret-bearing owner。

Credential redaction 是 owner 释放协议，而不是 snapshot 时的偶然过滤：

1. 安装新 credential 前，先清洗所有可能包含它的既有产品文本；
2. 替换或清空默认 execution 前，清洗 Workspace、Task、Run、Tool、UI 与 Schedule 的 durable candidate；
3. 释放 quiescent Task-owned ExecutionConfig 前，再用即将释放的 credential 清洗该 Task 的全部产品历史；
4. durable commit 成功后才能转移或 secure-zero 对应 credential ownership；
5. serializer 继续扫描所有 live credential，作为提交前的第二道防线。

Schedule scrub 明确失败或 outcome unknown 时不得提交新的 Product Execution default，也不得转移默认 execution ownership。Account preference 由 Account 独立 durable commit，不等待 Product scrub；Account terminal commit 后，Product 以 no-fail sink 接收 candidate，再执行可失败 scrub。scrub 未提交时 Product 保留唯一 pending candidate 与旧 active credential owner、关闭不匹配的新 Task admission并发布 Execution recovery；恢复成功后同进程重试，不回滚或重写 Account fact。

Credential 是 opaque bytes。redaction 必须覆盖流式跨 chunk 与 UTF-8 codepoint 边界；多个 credential 前缀重叠时采用最长匹配，不能因替换 secret 产生非法 UTF-8 产品事实。credential、locator、Authorization header 和可重建 secret 的 metadata 不进入 Bridge、Renderer、日志、产品历史或 checkpoint record。

## 3. 并发与生命周期

- 每个 Agent Session 至多一个 in-flight operation；Run、manual compact、Session mutation 与 destroy 互斥。Conversation recovery 按 §2.2 的 Task-owned active-operation 槽互斥，成功提交后才形成新的 Session attachment；
- 每个 Session 在创建时绑定 immutable ExecutionConfig generation；默认配置变化不热替换 live Session，显式 Task rebind 也必须形成新的 Session attachment；
- Product Control 创建、排队、取消并关闭 bounded Executor；Agent Runtime 不接收 scheduler capability，worker 只能从 Product Control admission 进入 Agent 调用；
- worker job 只持 owned payload、稳定 record reference、scoped Agent Session access 和完成本次工作所需的窄 capability，不保存 Product Control、aggregate Runtime 或主线程可变状态指针；
- queued cancel、worker completion、terminal publication 与 worker reference 必须各自 exactly once 收口。terminal fact 在通知、释放引用或触发外部 owner 前完成 write-once publication；
- Bridge/main thread 不执行长耗时 Agent 调用，也不等待 permission。Renderer response、snapshot failure 与 transport disconnect 只作为 typed transport fact 进入 Product policy，默认不能中止后台 Run 或覆盖 terminal cause；
- Attachment staging 使用独立 bounded execution lane；native picker 返回后，文件读取、签名校验和 owned raw bytes 建立都在 worker 执行。completion 回主线程后必须重新校验 batch、connection/window grant、shutdown token 与 staging identity；stale completion 只清零 candidate。raw bytes 只在 Product staging 与 `prepareRun` 的 borrowed lifetime 内存在；
- File Preview 使用独立于 Run、catalog、restore 与 MCP 的 bounded execution lane。worker 只接收深拷贝的 root-relative locator 和读取上限；完成回主线程后重新校验 Task、Run、Workspace authority 并执行 credential redaction。raw bytes 不进入 Product history、Snapshot、持久化或日志；
- File Changes 使用独立单 worker、有界 in-flight 的 artifact lane。diff 在入队前按当前及历史 Task credential 脱敏，worker 只持有 immutable Task/run/change identity、owned diff 和专用 store capability；完成回主线程后重新校验 Product artifact ownership。stale 或 Task 已删除的成功写入立即回收，读取结果在跨 Bridge 前再次校验引用仍属于同一 Task/Run/change；
- async completion 必须按开始时冻结的 attempt、object identity、epoch/generation、attachment 与 shutdown token 全量重新校验。任一 token stale 都只销毁 candidate，不安装、不自动重放原请求；
- capability 只在同步调用或明确的 worker lifetime 内借用；关闭开始后不得建立新的 job、timer、callback 或 responder 对 owner 的引用。

Application 关闭 Product 路径时必须遵守以下顺序：

1. 停止 Bridge ingress、新 Product admission、Schedule/MCP timer 与会产生新工作的 coordinator；
2. 停止独立 execution lane，并在主线程 drain completion、重新授权、脱敏且 settle responder 恰好一次；
3. 取消 queued/running Product jobs，join Executor，并等待 Task access、worker reference 与 aggregate completion quiescent；
4. 停止 Product 对 Agent 的新调用，再由 Agent 执行其完整 Runtime shutdown；
5. 完成最终 event drain 与 lifecycle sync，才释放残留 attachment、execution authority、aggregate 和 Product Control；
6. Execution 停止新管理命令、join 连接测试并释放 credential vault port；Account committed shutdown effect 取消自身 timer、join attempt worker 并清空 Account 平台 port；随后 Application 才释放两个彼此独立的平台 binding。

Agent Session、callback、UI request、event pump、close race、错误映射和 Agent Runtime 内部销毁顺序只由[AgentCore 集成契约](agentcore-integration.md)定义；Product/Application 不得拆开或替代 Agent-owned shutdown fence。

## 4. 产品历史、持久化与恢复

### 4.1 持久化权威、状态与恢复通则

本节只统一 Product Control store 的状态语义；Account persistence 由[高层架构](architecture.md#37-持久化权威与故障语义)和 [Account 架构](account-architecture.md)定义。

每个 Product Control store 必须分别建模三条轴，禁止再用单一 `corrupt` 或 `fail closed` 推导全部行为：

| 轴          | 稳定语义                                                                                                                                                                                        |
| ----------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 数据观察    | `absent` 表示 owner 能证明没有当前 store；`ready` 表示完整当前格式；`degraded` 表示当前格式中可隔离的局部记录失效；无法识别的格式、当前格式损坏和物理读取失败是不同事实                         |
| commit 结果 | `committed` 表示 durable candidate 已成为 canonical；`failed` 表示能够证明没有提交；`outcome_unknown` 表示无法证明新旧哪一方 canonical，必须重观察，不能自动重放可能产生外部 effect 的原 intent |
| 产品可用性  | interactive mutation、durable save、自动执行、权限/approval admission、cleanup 与显式 recovery 分别由 owner 决定；其中一个不可用不能伪造其他能力不可用，也不能冻结无关 aggregate                |

对外 wire 可以在不需要不同用户动作时合并内部诊断，但不得用更强的词误导用户；一旦不同事实需要不同迁移、文案或恢复动作，Bridge 必须先增加相应 typed contract，Renderer 不从诊断文本或文件名猜测。`unavailable` 表示能力或物理 store 没有建立，不等于空数据、损坏或首次启动。

具体格式演进、迁移、恢复单位和 replace transaction 只由各 aggregate 的既有章节与实现拥有；本节不建立跨 owner 的通用恢复算法。尚未形成一致合同或真实能力的机制登记在[验证规范](validation.md)中，不得从本节推导新的 wire、磁盘布局或用户操作。

### 4.2 Durable history 与 runtime attachment

Product history 保存用户可观察且跨重启仍有意义的 Workspace、Task、用户消息、已提交 assistant 输出、Tool 结果、File Changes metadata/artifact reference、UI 决策、Run/compact terminal fact、execution provenance 与 checkpoint reference。完整产品范围以[产品需求](requirements.md)为准。

Durable Task record 与 runtime attachment 必须分离。durable record 不保存 live Agent Session、catalog lease、pointer、atomic、worker/control payload、credential 或 `closed` 产品终态；runtime attachment 线性拥有 Agent Binding、ExecutionConfig 与必要 lease 的唯一使用和归还责任。Task detach 或 replacement 必须先关闭并归还 live Binding，不能丢弃或复制所有权。

Run/compact 的 terminal result 由 Agent 以自包含事实返回，Product 在预留 record 中 no-fail、write-once 提交后才能通知、释放 worker reference 或推进后续事务。queued-before-execute 由 Product 生成独立的 pre-execution terminal fact；Agent Session snapshot 只描述 live lifecycle，不承担历史 terminal truth。

Task 删除是跨持久化、checkpoint、event、Session 和 worker reference 的独立 Product 生命周期用例，不占用 active-operation 槽；其 `idle | deleting | failed` 状态只存在于当前 Runtime，不进入 durable Task record。删除意图可以先进入 `deleting`，但只有相关 active operation、checkpoint、terminal event、Session access 和 worker reference 全部收口且 durable history commit 成功后才能物理移除 record。明确失败或结果不确定只使本次删除进入可诊断失败；用户可以重试删除，Task 的其他可用操作与整个 Workbench 不得因此冻结。

### 4.3 `workbench-history.store`

`<MetaWork data dir>/workbench/workbench-history.store` 是 Workspace 与 Task 产品历史的 canonical 本地 store，不是 AgentCore checkpoint、缓存或通用 Storage SQL backend。Application 在 restore 前取得其进程级 OS writer lock，并把有界 load 与 atomic commit capability 注入 Product；Product 拥有 codec、跨记录校验、恢复 policy 和 persistence health。

当前合同只接受 canonical framed store，不读取、不迁移、不双写旧 JSON envelope、被替代的开发期 frame shape，或仍以 `provider` 表达 execution binding 的 record；Task 与 Run 只接受 `protocol` / `execution_protocol`。store 不存在表示首次启动。Workspace 与 Task record 独立校验；单条可隔离损坏进入 `degraded` 并保留其他有效历史。store 无法打开或全局结构不可信时不得覆盖原文件，Product 从空的内存历史继续运行并发布诊断；明确写失败或 commit outcome unknown 只表示当前内存历史尚未可靠保存，后续 mutation 必须重新尝试完整 snapshot。上述状态都不是 Product Task、Workspace 或 Renderer 的全局 admission gate。

非健康 history store 的显式 recovery 必须校验全局 revision，并由 Product 编码当前内存 Workspace/Task snapshot；Application 只能把当前 canonical 文件改名为唯一 quarantine artifact，再通过既有 durable atomic replace 安装该 candidate。读取/codec 失败时当前内存为空，因此形成 canonical empty history；write failure 或 outcome unknown 时保存当前进程仍持有的有效历史。失败不得清空内存或删除原文件，outcome unknown 继续发布 typed health；只有 committed 才恢复 ready。Renderer 不接触文件名、路径或 bytes，quarantine artifact 不进入 snapshot、日志或自动清理。

交互式 Product Task mutation 以内存 Runtime 为当前进程真源，持久化是 best-effort projection；保存失败不得回滚已经接纳的新建、Run、模型选择、权限响应、重命名、归档、取消或 Workspace 导航 mutation。Schedule occurrence 是独立的无人值守边界：Product Control 必须为其 Task create、命名与 Run intent 注入 required durable effect，任一步未可靠提交都拒绝本次 occurrence，Schedule 按既有 transaction 进入可诊断状态，但不得冻结其他 Product Task。Task 物理删除仍遵守 §4.2 的 commit-before-release 边界。

store 读取上限为 16 MiB。commit 必须在同一目录完成 durable atomic replace，并区分 `committed | failed | outcome_unknown`；临时文件命名、frame header、checksum 算法和 codec 内部布局由唯一实现与测试拥有，不在本文镜像。

Host 重启从通过校验的 store 重建 durable history 和 detached attachment。没有 live owner 的 non-terminal Run/compact 保守收口为 interrupted，不重放输入、工具、permission 或结果不确定 mutation；其 File Changes `collecting` 若存在必须收口为 `incomplete` 并保留已记录项。旧历史缺少 File Changes 字段时恢复为 `null`，不能伪造空观测。未完成 Tool 不进入恢复 projection，已经 durable 完成的 Tool result 保留。

### 4.4 File Changes artifact transaction

`<MetaWork data dir>/workbench/file-change-blobs/` 是 Product Task 专用的 credential-safe unified-diff store，不是 checkpoint 目录、当前 Workspace 镜像或通用 Artifact Framework。Application 持有进程级 writer lock 和 store/lane 生命周期；Product Task history 只保存 Task、run generation、change order、size 与 SHA-256 identity，不保存完整 diff 或物理路径。

写入先完成 no-follow、resolve-beneath、私有权限、文件 sync 与同目录原子 rename，成功 completion 重新校验 owner 后才把 reference 安装进 history。队列满、diff/record/path/projection 容量不足、存储失败或 shutdown 只使现有 metadata 保留、diff unavailable 且 observation 单调变成 incomplete；这些补充审查失败不得产生 generic consumer rejection、终止 Session 或改写 Run outcome。

可信启动只在 Task history health 为 ready 时根据完整 reference 集合删除临时文件和明确 orphan；history 不可用、degraded 或不可信时禁止 orphan cleanup。读取必须重新校验 identity、size、digest 和 UTF-8，missing/corrupt 作为 typed unavailable 结果返回。Task record 只有在 durable history 删除提交成功后才删除对应 artifact 目录；删除期间迟到的异步成功写入因无 Product owner 而立即回收。

### 4.5 Checkpoint transaction

AgentCore checkpoint blob 与 Product checkpoint record 是两个提交边界。每个成功收口且 Session 可复用的 Run/compact 可以在 terminal product fact 发布后导出 checkpoint；blob 必须先 durable commit，随后 Product 才能把引用它的 checkpoint record 提交进 Task history。

checkpoint record 只保存：

- blob 的 Task/generation/size/digest identity；
- AgentCore description 中恢复消费者需要的无 secret Session facts；
- Product 提交时的最新 terminal 与 binding anchor。

它不保存 credential、catalog handle、permission rule、raw Conversation、临时 export metrics 或 live Session identity。

新 blob 明确成功但 history record 明确失败时，blob 可以暂时成为孤儿；record commit outcome unknown 时必须把相关 blob 当作可能的 orphan 保留，但不能冻结 Product Task，后续完整 history commit 可以建立新的 canonical snapshot。可信启动先校验 record 引用 blob 的 identity，再清除明确失效的 record，最后反向删除无 record 的 orphan。Product history degraded 或 checkpoint store 不可信时不得执行孤儿清理，以免删除未知 Task 的有效数据。

### 4.6 Conversation attachment recovery

Conversation recovery 是 detached Task 的 attachment 重建事务，不是 transcript 重放、Task 克隆或新的 Product owner。恢复资格必须同时证明：

- source Task、binding、checkpoint 与 terminal anchor 未变化；
- Workspace identity、kind、epoch、root、authorization 与 Automatic owner 精确；
- target ExecutionConfig protocol 相同、能够承载 Task model，且其 generation 在 start 到 commit 期间保持不变；
- persistence、checkpoint store 与 Agent Runtime 可用；
- Task 未归档、删除、运行其他 operation、replacement 或 shutdown；
- 当前 recovery attempt 和 poison 状态允许进入。

历史 execution generation 只证明历史 Run 使用过哪个 execution，不是恢复当前 credential 的句柄，也不要求等于 target generation。Skill、MCP、Permission 和 projection continuity 是恢复后的可选能力状态，不是 Conversation 恢复资格；AgentCore 合法返回 degraded Session 时，Product 接受已恢复 Conversation，并让不可重建 authority 保持安全失效。

用户显式发起恢复后，Product 冻结完整 source/target authority 并提交 bounded recovery job。job 不保存 Task/Workspace 指针，不查询 Product Skill，不构造 MCP Selection，也不取得 durable permission rule；它只验证 checkpoint source 并调用 Agent restore。I/O、Agent Runtime、capacity、cancellation 与 typed AgentCore refusal 必须作为 attempt 结果返回，不能折叠成一个终局连接失败。

成功 candidate 回到主线程后必须再次校验全部 source/target token、attachment、archive/removal、replacement 与 shutdown。stale candidate 只销毁。若 target generation 与 durable binding 不同，先以一个 durable adoption transaction 同时推进 Task binding、binding epoch 与 checkpoint anchor，commit 成功后才安装 attachment；明确失败销毁 candidate 并保留 detached Task，outcome unknown 冻结后续 mutation。进程若在 durable adoption 后、attachment install 前退出，下次启动从已推进的 binding/anchor 重新恢复，不改写历史 Run provenance。

## 5. `.skill` 交换 artifact

`.skill` 是 MetaWork 对外可交换的 ZIP envelope。规范 archive root 必须直接包含精确大小写的 `SKILL.md` 及同一 Skill 的相对资源；导入普通 `.zip` 时，只允许 archive root 本身或唯一 wrapper directory 成为候选 Skill root。多个 `SKILL.md`、多个候选根或缺少 root 均失败。

导入必须在目标 root 之外 materialize 为 staged tree，并拒绝 absolute、drive/UNC、空、`.`、`..`、NUL、非 UTF-8、重复归一化、Windows 保留名和尾随点/空格路径；symlink、hardlink、device、socket、FIFO 与其他特殊 entry 一律拒绝。Importer 只读取或复制 regular bytes，不执行脚本、不解析远程链接、不访问网络。

稳定资源上限为：

- 最多 512 个 regular files；
- 解压总量最多 64 MiB；
- 单文件最多 16 MiB；
- UTF-8 相对路径最多 512 bytes；
- 单 path component 最多 128 UTF-8 bytes；
- `.skill` 压缩输入最多 32 MiB。

export 服从同一文件与路径边界，使用稳定相对路径顺序，不包含绝对路径、provenance store、credential、`.git` 或平台 metadata。具体 ZIP library、staging 目录、hash 实现和文件事务 helper 由代码与测试拥有；上述 envelope、拒绝规则和容量属于稳定 artifact 合同。

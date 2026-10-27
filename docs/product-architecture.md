# MetaWork Product 架构

本文定义 Product 内部 owner、跨 owner 与跨 aggregate 事务、并发、生命周期、持久化和恢复、Product-owned 稳定交换 artifact，以及 Product Control 与相邻 Agent 执行边界的协作。它不定义用户可观察产品行为、Account 内部状态机、Renderer Bridge wire、AgentCore ABI、源码 leaf graph 或当前验证状态；这些内容分别以[产品需求](requirements.md)、[Account 架构](account-architecture.md)、[Renderer Bridge 合同](renderer-bridge-contract.md)、[AgentCore 集成契约](agentcore-integration.md)、[工程结构与所有权](project-structure.md)和[验证规范](validation.md)为准。顶层进程、故障域和安全边界见[高层架构](architecture.md)。

## 1. Owner 与事务模型

Product 由两个 named owner 组成，跨 owner 用例由对应的 Application coordinator 编排：

- Account 只拥有 Metask OAuth identity、access/refresh credential、authorization generation 及其内部事务与恢复；
- Product Control 拥有 Models aggregate、Product binding generation、已安装的默认 ExecutionConfig、Schedule credential scrub、Workspace、Task、Skill、MCP、共享 Executor、跨 aggregate admission、canonical 产品 projection、revision、产品历史与关闭顺序。Models aggregate 独占通用 Protocol/ExecutionConfig/source-candidate 合同、Metask provider/catalog、Provider-local 与 global default selection、user-managed Custom Provider registry、credential vault port、测试状态、持久化与恢复。

Agent 位于 Product 之外，拥有 MetaWork 对 AgentCore Runtime、Session、Conversation、callback、event pump 与 terminal execution fact 的集成生命周期。Product Control 只调用 Agent 的公共执行能力，不管理 Agent Runtime 生命周期、不读取其内部状态，也不借 Agent 获取通用 I/O。Application 创建和关闭 Agent、安排主线程 wake，并协调 Account 与 Product Control；它不持有领域运行状态，也不独立决定这些 owner 的 policy。

Application 必须分别组装 Account coordinator 与 Models coordinator。前者只编排 Account Runtime terminal commit；后者只取得 Account 的窄 authorization lease，并绑定 Models Metask catalog worker、credential vault、Agent-owned model probe 与 Models 管理生命周期。Account commit 后，Application 先发布 Account fact，再通知 Models observer；observer 只能请求当次 lease、查询无 secret 的当次授权证明或声明授权不可用，不能读取 Account 内部 token owner或把 Models 结果写回 Account。用户在桌面 Renderer 中显式填写的 Custom Provider API Key 只经专用 create/replace typed command 调用期转交 Models credential mutation；Bridge 不保留副本，Models 立即将其写入 credential vault，canonical metadata、projection、result、event、日志和历史均不得包含该值。Models desired commit、Schedule scrub 和已安装 execution reconciliation 属于 Product Control 内部事务，不得由 Application coordinator 重新拼装。

Models、Workspace、Task、Schedule、Skill 与 MCP 是 Product Control 持有的 aggregate，不形成新的顶层 Product owner。各 aggregate 独占自身状态机、局部事务与持久化 policy；Product Control 只拥有必须同时观察多个 aggregate、execution、publication 或生命周期事实的不变量，不能把局部 policy 重新吸收到组合层。

Product 事务只使用三种机制：

1. **aggregate-local transaction**：对应 aggregate 完成 candidate、effect、typed outcome 与 committed install；
2. **cross-owner handoff**：Application coordinator 在主线程按已定义顺序转移线性所有权，任何 payload 只在明确的 take、install 与 commit 点移动一次；
3. **asynchronous reconciliation**：worker 只持 owned payload、窄 effect capability 和不可变或 atomic facts，完成回到主线程后按完整 authority token 重新校验，stale 结果只销毁、不安装、不自动重放。

Product 不建立统一事务引擎、通用 command bus 或 Product event bus。跨边界 capability 必须按用例裁剪，不得暴露完整 Runtime、内部 aggregate、可变状态指针或 raw getter；其具体语言表示和 leaf module 由代码与 build graph 决定。

## 2. 跨边界事务

### 2.1 Models aggregate 与 Account handoff

Account 和 Product Control 是同级 owner，彼此不导入对方 Runtime。Models 是 Product Control 持有的 aggregate，不是第三个顶层 owner；它发布不依赖 Account、Application、Bridge、Agent 或消费方的纯 `Protocol`、`ModelRef`、`ExecutionTarget`、`OwnedSourceCandidate`、`ExecutionConfig`、Models command/view 和线性 owned config 合同。Task 与 Schedule 只能消费这份纯合同，不能导入 Models runtime/root/ports；Account 不消费 Models 的任何 module，也不定义或转发模型类型。

Metask provider 的运行时数据流为：

```text
Account authenticated authorization
→ Application takes one bounded authorization lease
→ Models Metask catalog worker
→ Models commits provider catalog and desired selection
→ Product Control reconciles desired binding into installed execution
→ Agent Session consumption
```

Models 可以独立于全局默认值，按精确 `ModelRef` 与预期 source/catalog generation 解析完整 owned execution candidate。protocol 与 endpoint 只取目标来源的声明，Custom Provider 还必须有当前 source generation 的 readiness proof；来源、目录、模型或 credential 不可用时明确失败，不回退到默认值。解析不修改 Provider-local/global selection，已交付 candidate 不受后续目录或 credential 状态变更改写。Task 等消费者的操作资格与安装事务仍由 Product Control 所有。

Custom Provider execution 的数据流为：

```text
Renderer password form → typed Bridge create/replace → Models credential mutation
→ Models credential vault + registry/default selection
→ Product Control reconciles Models desired binding into installed execution
→ Agent Session consumption
```

两条来源最终都必须形成同一份显式 protocol、endpoint、model、credential、source generation 与 Product binding generation。Models 解析 source 时产生不含 Product generation 的 `OwnedSourceCandidate`；只有 Product Control 可以分配 binding generation 并将其转成 `ExecutionConfig`。Metask source id 固定为 `metask`；Models 按目标模型 `capabilities.endpoints` 中明确 `supported = true` 的端点选择 protocol，固定优先级为 `messages → anthropic_messages`、`responses → openai_responses`、`chat_completions → openai_chat_completions`。缺失、null、false 或只有 status 声明的端点不参与选择；端点内部 input/output 不作为第二套能力判定。所选 protocol 分别绑定固定的 `https://app.metask-ai.com/v1/messages`、`/v1/responses`、`/v1/chat/completions` URL；不按模型名猜测、不因执行失败自动换协议重发。目录与调用 credential 均来自当前 OAuth authorization lease；Custom Provider source id 为稳定 Provider id。`ModelRef = source_id + model_id` 是模型身份，display name 永远不是 identity。source generation、selection revision、catalog generation、provider revision 与 Product binding generation是不同轴，不能互相替代或假设有序。

同一 Metask catalog 请求和有界解析同时分类对话与生图用途，共享目录 owner、快照和刷新生命周期，不建立第二目录 worker。对话候选排除明确支持 `images_generations` 或 `videos` 的成员；生图候选只要求 `capabilities.endpoints.images_generations.supported == true`，混合声明仍只进入生图用途。缺失、null、false、名称、旧 alias 或 `output.image` 都不能补授生图资格。生图成员不要求或伪装成对话 protocol。两类成员共用总量上限和严格已知字段校验；Renderer 只取得对话候选，对话候选为空不等于图片能力不可用。目录声明只表示服务能力，不保证特定返回格式或生成成功。

默认 execution、Task attachment 和后台任务各自持有所需的 owned copy；Session、恢复、模型测试及自动标题消费已经解析的配置，不根据厂商、endpoint、模型名或 source id 重新选择 protocol。Task 的明确模型意图可以保存非 secret source id；credential locator 不进入 durable Task history。Product 层不定义供执行分派使用的 `ProviderKind`、厂商分类、协议反推或平行 protocol enum；内置官方配置模板的稳定 identity 只选择 Models-owned 配置策略，创建后仍展开并持久化为明确 protocol 与 endpoint。Agent 对 AgentCore ABI 的 provider code 映射仍是 Agent-owned transport 细节。

Custom Provider 使用显式的 `openai_responses | openai_chat_completions | anthropic_messages | gemini_native` protocol。前三者要求 endpoint path 分别以 `/responses`、`/chat/completions`、`/v1/messages` 结尾，从而保留官方 API 所需的版本或产品前缀；Gemini Native 使用由消费者追加 model 与 operation path 的 base URL。自定义表单向用户呈现 API Base URL，并按显式 protocol 确定性生成标准 endpoint；内置 DeepSeek、Kimi、MiniMax 与智谱 GLM 模板直接提供已复核的官方 endpoint。Host 仍独立规范化并严格校验 scheme、host、path、长度和控制字符，Renderer 不能绕过该校验或把 query credential 注入 Run。当前不做 model discovery；Models 原子管理有界的 custom model definition 集合。新建 Provider 可以在 credential 已安全保存后以空集合处于 `configuring`，不能解析、测试或成为默认来源；首个模型通过既有 add mutation 加入，删除最后一个模型则回到同一空集合状态并清理指向它的默认 intent。每个成员使用完整 `ModelRef`，保存 nullable capability/token metadata及其 `unknown | user_declared | provider_declared | runtime_verified` provenance。用户提交的声明只能标记为 `user_declared`，一次连通性 probe 不能把未验证的 capability metadata升级为 `runtime_verified`。

每个 custom model 的 readiness proof 精确绑定当前 source generation，latest probe status与 readiness分离：成功 probe建立 proof，随后对同一 authority 的失败或中断重测只更新 latest status；endpoint、protocol或credential改变会生成新 source generation并清除该 Provider 全部旧 proof。普通 model metadata add/replace/remove只推进 provider revision和catalog generation，不自动 probe或设为默认；identity被替换/删除时只清理指向该完整 `ModelRef` 的默认 intent，不查询或改写消费方。

Models registry 与 Account identity 独立。不同 Provider 即使 credential 相同也保持不同 Provider id；更新名称、endpoint、protocol、credential 或模型保留 Provider id，但影响 source authority 的变化产生新的 source generation。首次成功的 Agent-owned one-shot Completion test 使当前 generation ready；失败重测只更新 latest test status，不撤销已 ready generation或已交付 binding。Models 的 Provider edit/delete 不查询 Task/Session/Run 等消费者，也不以 `execution_in_use` 拒绝；Product Control 只在 desired commit 后独立 reconcile 新 admission 与 active default，既有消费者保持自己的 owned binding。

Metask catalog completion 只交付完整 owned 目录与 transient credential，不在 Application worker 选择模型。Models 负责恢复对话 intent：同一 principal 的已存选择仍保留，目录移除或排除它时不得静默换模型；只有当前 principal 无历史 intent 时才从合格目录初始化首项。同一模型的声明使选定 protocol 改变时，保留模型 intent 与 selection revision，更新 source authority 并由 Product Control 为新的默认执行建立新 generation；已有 Task/Run/pending 的 owned protocol 不热切换。新 Task 明确选择按目标来源解析完整 protocol、endpoint 与 credential，不借用 active default 的执行配置；未明确选择时仍校验默认 admission。已有 Task 模型切换的接纳边界由 Task 合同定义，不因 Models 能解析其他 protocol 而隐式重绑定。目录成功接纳与 intent 当前可解析性分别判断，失格 intent 不阻止发布可供重新选择的目录。合法空目录推进 catalog generation 并发布 `no_models`，不得解释成普通 transport failure 或复用旧目录给新的 resolve 放行。Product Control 在成功目录 completion 后重新 reconcile，即使 desired selection 未变化也必须关闭不可解析默认的 New Task 与 Schedule admission；已有消费者的 owned binding 与已接纳 pending mutation 按原生命周期保留。

Metask 的输入能力仅来自 `capabilities.input.{text,image,pdf,audio,video}.supported`，输出能力仅来自 `capabilities.output.{text,image,audio,video,embedding}.supported`；只有 boolean true 表示支持，缺失、null、false 均投影为不支持，非法已知字段类型使整个目录响应无效。旧 `*_input/*_output`、`input.document` 与端点内部 input/output 不解析、不回退；PDF 支持只由 `input.pdf.supported` 声明，格式列表不能授予能力。Models 有界持有全部已知声明并随目录复制和替换，下游 metadata 保存这些事实；图片输入声明随已解析执行配置冻结并交给 Agent，Session 创建、恢复与模型切换的消费合同见 [AgentCore 集成契约](agentcore-integration.md)。声明不增加第二套模型用途 gate，也不自动开放 MetaWork 尚未实现的附件或输出功能。

Metask 当前只消费模型根级 `max_input_tokens` 与 `max_tokens`，分别保存为 metadata 的输入与输出 token 上限；暂不解析或应用 `capabilities.limits`，也不从其中回退、补齐或推断根级字段。Token 值只接纳十进制非负 JSON integer，零、缺失、null 表示未知；负数、字符串、浮点、指数或 u64 溢出使整个目录无效。所有已知字段校验在模型筛选之前完成。其他限制的字段校对与消费另行确定。Custom Provider 的声明仍允许 null 表示未知，已有持久数据省略新增能力字段时保持其原有声明；本地配置中的已退役 `metadata.limits` 只在读取时丢弃，不能覆盖 token 或能力，后续写出不再包含它，其他未知持久字段仍拒绝。

Account authorization 与 Models catalog 的 committed-state 路径为：

```text
Account commits verified identity/credential generation
→ Product Control copies the secret-free Account fact
→ Application notifies Models coordinator
→ coordinator takes one owned authorization lease
→ Models prepares catalog attempt bound to principal + authorization generation
→ Application worker uses the OAuth access token to load `/v1/models`
→ Models rejects stale generation or commits catalog/selection/source generation
→ Product Control reconciles Models desired authority into active execution
```

authorization lease 由 Account 构造、Application 在单个 catalog job 中线性持有并清零。Models 只接收 attempt、principal、authorization generation 与 owned catalog completion；Models module 不导入 Account，也不持久化 OAuth token。成功 completion 把 access token 的 owned copy 作为当前 Metask source 的 transient execution credential，下一次 authorization generation 变化会重新加载目录并替换该 copy。credential 改变必须建立新的 source generation，不能因 principal、模型或 protocol 相同而复用旧 authority；已选模型失格或合法空目录也不阻止来源版本更新，保留的模型意图仍不可执行，其他合格模型按新 authority 解析。纯 credential 轮换不改变用户的模型 selection revision。Application 另向 Product Control 提供主线程、无 secret 的当次授权校验 capability，返回 Account-owned authorization generation 与连续授权 scope；每次 Metask 新执行接纳及恢复候选发布前重新查询，匹配 Models 已接纳目录的 authorization generation，不能由 cached authenticated view、目录仍存在或 Task model intent revision 相同推断授权有效；catalog worker 不拥有 committed state，陈旧 completion 只能销毁。Models 的失败不调用 Account abort、不改变登录状态，也不补写 Account error。

authorization loss 的顺序相反：Application cancel/join 仍在运行的 Metask catalog job并销毁 lease，Models 将 Metask provider 置为 `needs_authentication`、清除 transient catalog credential与可解析目录。无 secret 的 Metask Provider-local/global selection intent 保留；custom source 不变。若 global default 指向 Metask，Product Control 随后关闭新的 Task admission并清除 active default；已经交给 Task/Run 的 binding 不热回收、不改写；后续新执行仍须通过当次授权检查，既有进程内 Task 不得自动借用退出或重新登录后的授权。

Models desired selection 与 Product Control active binding 的写路径为：

```text
Models validates source-qualified ModelRef and expected revision
→ Models atomically commits durable desired selection
→ Product Control observes desired/active mismatch and closes new admission
→ Product Control resolves one owned candidate
→ Product Control performs Schedule credential scrub preparation
→ Product Control installs ExecutionConfig and records active authority
→ publish canonical projection
```

Metask `metaskSelection` 只是 Provider-local intent，只有 `defaultSelection` 才是 Product Control 消费的 global desired intent；前者有效而后者为空时不得安装 ExecutionConfig，`newTaskAdmission` 必须保持 unavailable。恢复只能显式提交现有完整 `ModelRef` 到 `selectDefault`，随后走上述正常 reconcile，不得由 Product Control 猜测首个模型、硬编码模型名或手工推进 execution generation。

Models desired commit 不等待、查询或受制于任何消费者。后续 resolve、scrub 或 install 失败时，desired state 保持已提交，active state保留旧 binding或进入 unavailable；失败不回滚 Models，也不改写 Account。Connection CRUD/test 不隐式改变 global default，普通 metadata mutation 只修改 Models-owned connection事实。

每个 Account prepared transition 的 commit 仍在主线程单一 turn 内完成。Models catalog 可以跨 worker completion，但只由 Models attempt 与 authorization generation 接纳。实际 Product execution 安装只能发生在 Models desired state提交之后；后续 fallible effect 只能改变 Product active/recovery projection。

Product Control 的 replacement/reconciliation gate 只串行化本次默认 execution 交接与相关新 Task admission。已有 Task、Session、Run 和 worker 已经取得的 owned ExecutionConfig 按原生命周期收口，不热替换、不等待 Account identity 变化，也不被 logout 伪造为已撤权。Models 改变默认模型时更新 selection revision；同一 source identity、source generation 与 protocol 内的默认模型变化复用 Product binding generation，credential、endpoint、protocol 或 source authority 变化才建立新 generation。新 Task admission 必须同时 compare-and-swap active generation 与 selection revision，不能由 model id 单独推断，也不能让旧 Renderer snapshot 静默采用新默认模型。

New task 明确模型选择使用完整 `ModelRef + source generation + catalog generation`，由 Models 精确解析该来源的 protocol、endpoint、model 和 credential。它可以选择任一 ready 来源，不依赖 global default admission，也不改写全局默认；null 选择才按默认 admission CAS 创建。不得把来源不同的选择降格为仅替换默认配置的 model 字段。

既有 Task 的模型选择由 Task owner 准备完整 ModelRef 与独立 revision 的 history overlay，Product Control 验证目标来源并完成 confirmed commit；选择不调用忙碌的 Session，不改变当前 Run 或实际 binding。明确失败回滚 overlay；未知结果保留精确历史候选与原意图，复用既有 history worker 读回，确认前禁止该 Task 新 Run 和再次选择。确认提交后保留新意图，确认未提交则恢复原意图；不能用后来状态重写未知候选来推断原结果。尚未安装的新意图在执行接纳前重新解析目标；已安装的同一意图保持自己的模型、protocol 与 endpoint，不借用目录刷新或全局默认改变用户意图。Metask 在同一连续授权 scope 内正常轮换 credential 时，idle Task 在下一次 Run 接纳前按原完整 ModelRef 解析当前授权的配置，通过既有基线 checkpoint 确认、旧 Session 关闭、目标恢复与 binding 提交事务安装新 credential 和 execution generation；在飞 Run、自动审批及后台执行仍消费本 Run 的原冻结配置，排队输入只能在事务成功后执行一次，不重放已有 Run 或工具。运行中已接收但尚未采用的追加输入也须在消费前完成该准备：pending payload 跨有界重绑定保留，仅在成功提交并发布原事务的目标 binding 后更新其运行期接纳 epoch，随后启动一次续跑；取消、恢复失败或授权失效明确结束该批次并释放 payload，不重发已采用的输入、不复活已取消的批次。scope 只在 Host 进程内由 Task 生命周期持有，Session detach 不删除该连续性约束；退出、重新登录或身份替换后不自动跨 scope 续期。hard expiry、clock 不可用、目录失败或候选在发布前失去授权时明确阻止新的执行，失败的准备不自动重试、不静默回退到旧 credential，不清空 Conversation；既有恢复事务可按原边界恢复原 attachment，但它仍须在下一次接纳时通过授权和 credential 版本检查。只有 provider reference、来源 generation、protocol、endpoint 和 credential 均与 attachment 一致时才可只调用 setModel；其余情况需要执行重绑定，不得继续用原配置发送。

Account identity/token rotation与 Models registry是独立 durable authority；任一方的提交、恢复或 outcome unknown 不得由另一方解释或回滚。Account 只回答当前授权能否产生 lease 或无 secret 的执行接纳证明，Models 只回答 provider/source 能否解析，Product Control 只回答 desired binding 是否已经安装并可用于新 admission。

Renderer reload、断连或命令 timeout 只影响交互与 resync，不能取消 Host 中的 deadline、mutation 或 terminal completion。Renderer Account command 只涉及登录、取消和退出；Models command 使用 source-qualified identifier 与对应 expected revision。除用户显式提交 Custom Provider create/replace 或 MCP captureSecret 时一次性转交手动凭据外，Renderer 不参与 prepare、commit、authorization lease 或 credential transfer；该表单值不属于可恢复 UI 状态。

Identity replacement、default execution replacement 与 durable Task history 是不同边界。history 保存实际 protocol、model、不透明 execution generation、binding facts，以及独立的无 secret Task model intent（完整 ModelRef 与单调 selection revision）；不保存 Account identity、API Key metadata、credential locator 或可重建 secret 的信息。

Canonical snapshot 同样保持 owner 边界：根 `account` 只投影 Account identity、取消能力与稳定错误；根 `models` 投影 provider catalog、Provider-local/global desired selection、Models generations/revisions、persistence health与 Custom Provider；根 `newTaskAdmission` 只投影 Product Control 当前安装的 active `ModelRef`、generation、selection revision、replacement/availability和新 Task admission。每个 Task 的 modelIntent 投影独立的下一轮选择，binding 与 Run execution 保留实际安装及历史事实；`modelSelectionAvailability` 由 Product Control 根据 Models 的可用候选计算，不以默认 replacement 或 Task attachment 为选择前提。Task view 只序列化，Renderer 不重建 authority。三者可以独立处于 ready/unavailable；例如 Account authenticated但 Metask catalog失败，或 Models desired已经提交但 Product scrub/install失败，都必须是合法 snapshot，不能伪造 active execution，也不能令整个 Workbench fail closed。

Models 每次 resolve 只产生一个调用方 owned candidate，绑定精确 `ModelRef + source_generation + protocol`；candidate 不持久化。Product Control 在 installed binding取得 ownership后负责其 credential清零。Schedule store 不可信或 scrub失败时不得安装候选；Models desired state保持不变，Product 发布 mismatch/recovery并等待重试，不能跳过 scrub。

`models.json` schema 2 是 Models aggregate 的唯一 canonical store。它保存 Metask 的无 secret Provider-local intent、source-qualified global default、selection revision、Custom Provider 的 id/display name/protocol/normalized endpoint、有界 model metadata、credential/test status、provider/source/catalog revision 和待完成 credential deletion tombstone；不保存 OAuth token、API credential、credential locator、migration marker 或 Product binding generation。Custom Provider API credential 只进入系统安全存储。schema 2 的 Metask intent 不含 API Key identity，Metask `source_id` 固定为 `metask`；系统没有 `ModelConnection` 对象，也不识别或映射 `connections` 字段。

生图模型不形成用户选择、独立 revision 或持久化 intent。既有 schema 1/2 文件中的退休 `metask_image` 字段仅在读取时丢弃，正常提交不再输出；对话 intent、global default、revisions 和 Custom Provider 必须完整保留，不为清理该字段新增启动写入。

生图默认模型与正式服务 target 的机器定义由 [Models 值合同](../src/product/models/contract.zig)唯一拥有。每次 Run preparation 优先采用当前目录中具备明确生图资格的默认模型；默认模型缺失或不合格时，按该次目录返回顺序采用第一个具备生图资格的成员。没有合格成员时返回不可用，不从对话默认、名称、输出 metadata 或旧持久选择推断模型。此回退仅在请求发送前解析配置，不构成发送失败后的自动重试或模型切换。

图片执行 candidate 只在 Models 接收当次 Host authorization lease 的借用输入后构造：principal、authorization generation 必须与已接纳目录匹配；目录加载中或授权不可用均拒绝新解析。Models 在同一主线程调用内解析模型并复制该次 lease 的有界 credential，不借用 catalog 缓存的执行 token，也不获取、刷新或持久化授权。其 owned model、固定 Metask Images Generation target、catalog generation 与 credential 构成独立配置，不包含对话 protocol、Product execution generation、principal 或授权代次。消费者不提交或覆盖模型与 URL；已交付副本不随目录或 logout 热替换，执行 owner 静止后清零释放 credential。

首次 bootstrap 读取 schema 2，并仅为既有 schema 1 Metask intent 提供一次确定性迁移：丢弃旧 `api_key_id`，把旧 `metask:<api-key-id>` selection source 归一为固定 `metask`，保留 model、revision、generation 与 Custom Provider 事实，下一次提交写回 schema 2。canonical 文件不存在时，在一次 Models transaction 中初始化空的 schema 2；`preferences.json`、`custom-providers.json` 及其 decoder、归档和迁移 marker 不属于当前 authority，也不参与恢复或 fallback。除此之外的缺失字段、未知 shape 或损坏必须 fail closed，不能猜测 generation/revision、默认来源或静默清空已有事实。

Models persistence health 精确区分：当前 canonical 可用为 `ready`；Models file capability 存在但 canonical 读取、严格解码或提交结果不可信为 `recovery_required`；file capability 本身不存在为 `unavailable`。只有 `recovery_required` 允许用户确认显式恢复；Models owner 与 Product Control 必须在执行时重新校验该资格。恢复执行时先重新读取并严格解码 canonical：合法 schema 1/2 必须重装且不得清空，其中 schema 1 按上一段迁移，中断的 `testing` 状态确定性收敛为 `failed`，并在确认提交后恢复 `ready`；读取失败或资源耗尽拒绝恢复且不得写盘；只有文件缺失或严格解码确认损坏时，才允许用当前可信内存事实安装空的 schema 2 store。`ready` 与 `unavailable` 都拒绝该命令，Renderer 不能为其显示恢复动作。恢复不猜测解释或归档旧 bytes，不改写 Account、Workspace、Task、Run 或对话历史；既有 Task 已拥有的 ExecutionConfig 继续按原生命周期收口。

Provider 删除先提交 credential cleanup tombstone，再删除系统 credential，最后原子清除 tombstone；创建先提交目标 id tombstone，再写 credential，最后以一次 registry commit 替换为完整 Provider。credential 替换先持久撤销旧 readiness 和对应 default，再覆盖同一稳定 Provider credential locator，最后以新的 provider/source generation 恢复为待测试状态；写入或最终提交失败时 Provider 必须保持 `missing/configuring`，不得让旧 readiness 配上新 credential。启动与后续 mutation 必须排空 tombstone。确认 credential 缺失时撤销对应 default 并持久化 `credential_status = missing`；安全存储暂时不可读不能被误写成已确认缺失。Execution 恢复与 Account identity 恢复相互独立，一方 unavailable 不得使另一方的持久化事实被清空或覆盖。

### 2.2 Workspace 与 Task admission

Workspace 是 Product Control-owned 产品对象；产品语义和用户操作以[产品需求](requirements.md)为准，wire 以[Renderer Bridge 合同](renderer-bridge-contract.md)为准。本节只定义 Workspace、Task、ExecutionConfig 与 Agent Session 之间的 admission 和提交关系。

Manual Workspace 与 Automatic Workspace 共用一个 registry 和 Task 引用关系，`kind` 在 record 生命周期内不可改变。Manual intent 必须重新校验 Workspace identity、epoch 与 authorization；Automatic intent 必须取得 Workspace Runtime 当前已安装的 automatic-root capability。Renderer 不提交物理路径、automatic root 或目录授权 token。已严格恢复的可见 Manual record 保留用户先前的目录选择：Workspace owner 重新解析精确 canonical root 并打开目录验证实际可用性，成功恢复为 available，失败保留 record 为不可用供重新选择；不把重启本身视为撤销选择，不恢复已移除记录的可见性、不改变 epoch，也不接受路径已重定向的目录。此检查不代表后续文件访问永久成功，执行仍遵循既有准入和实际 I/O 结果。

Manual、Scheduled 首次创建及后续 Run、自动 follow-up 共用图片准备规则：Product 在 admission 中取得当前 Workspace authority，Application Models coordinator 借用 Account 当次 authorization lease，将 principal、授权代次与 bearer 交给 Models 解析默认或目录回退模型。准备不发起登录、刷新、目录请求或生成，也不创建文件；主线程 handoff 不需要第二份选择快照或 CAS。没有合格模型、授权过期、解析拒绝或 Application 图片准备资源不足时，本 Run 的图片配置为空，文本接纳继续；同一 Run 不因后续授权或目录变化而升级、替换配置或自动重发，下一 Run 重新准备。effect capability 只提供执行输入，不改变 Host Tool 注册集合。

Product 的每 Run owned 图片 candidate 与输出 effect 在准备失败、回滚或执行结束后按所有权释放。Agent 的执行副本在 callback/I/O 静止后清零；Product 的独立投影清理副本须等该 Task 的 worker 静止且该 Run canonical event drain 已完成，先清洗已知产品投影再清零释放。增量文本、工具字段、权限记录、review、标题及终态诊断同时覆盖对话和图片 credential；未决文本后缀不能因新增凭据类型而提前公开。上述图片配置、secret 和 effect owner 都是临时执行数据，不进入历史或 checkpoint；恢复后的新 Run 重新取得当前配置。

图片输出的 Workspace authority 由 Product 在 Run admission 校验并冻结，Application 文件 effect 只复制执行所需的 Workspace identity、epoch 与有界 canonical root，不保存可变 Task/Workspace 指针。捕获不打开目录或预创建文件；Agent 只借用窄 output port，Application 对象必须存活到全部调用与文件 I/O 静止。实际效果在 worker 上逐级以 no-follow 打开并检查目录句柄类型，拒绝 symlink/reparse 跳转；Host 在固定 `generated-images/` 内以随机名称独占创建文件，不覆盖既存文件，名称冲突只在同一次落盘中有界换名。文件名和 receipt 在写入前准备，完整写入、同步、命名文件及目录身份复核均在关闭前完成，关闭后返回 committed receipt。该结果不承诺崩溃持久性或对任意 Workspace 写入者的完整原子隔离。

已提交文件保留，后续取消不能撤销 saved 事实；未提交失败仅尝试删除本次创建且当前身份仍一致的文件。文件移动、替换或清理 I/O 失败时保留现场，以本次返回值报告 `cleanup_incomplete` 和 Host 生成的 attempted path；它不是文件仍位于该路径或已被删除的证明。不建立共享 last-error、持久 cleanup debt、启动扫描或自动重生成。取消通过现有可取消 I/O 会合，返回前必须等待文件操作及清理静止；不能把受控会合的关闭证据扩展为任意阻塞系统调用均有严格时限。Manual 文件属于用户 Workspace，Automatic 目录继续遵循既有移除合同。

Workspace owner 以 `<MetaWork data dir>/workbench/automatic-workspace-root.store` 作为唯一 canonical 配置。文件只接受 schema 1 的 `{ mode: system_default, custom_root: null } | { mode: custom, custom_root: canonical absolute path }`，不持久 revision、effective root、Workspace identity 或 Task 引用，也不读取旧格式、不迁移、不静默 fallback。进程内非零 `generation` 只服务于 command CAS；Host 重启后由新 connection/snapshot 建立新的 freshness 边界，没有 durable object 引用该 generation。Application 只提供 Native SDK 解析的 system-default path、该文件 capability 和 Host 原生 picker；路径模式、健康、交易和是否可分配均由 Workspace owner 决定。

启动时文件缺失才能原子初始化 system default；读失败、严格解码失败、unknown schema 和 incomplete recovery artifact 均保留 canonical 并发布 typed non-ready health。显式 reset/recovery 必须先将旧 canonical exact bytes 改名为唯一 quarantine artifact，再安装当前 schema；明确失败恢复旧 canonical，结果不确定保留 pending evidence 并禁止新 Automatic admission。普通 choose/reset 交易按 `expectedGeneration`校验，由 Host 取得候选路径并 canonicalize/stat，Workspace 再校验路径长度和 registry 冲突、打开候选 Root、原子提交配置，最后以不失败的内存交换安装新 allocator 并推进 generation/Product revision。明确写失败保留旧设置与 allocator；outcome unknown 禁止后续 automatic allocation；picker cancel 无副作用。

custom root 必须为随机 child 预留路径容量，且不得等于 Manual record、不得等于或位于已存在的 Automatic record 内；它可以是既有 Automatic record 的祖先。路径比较在 Windows 语义下大小写不敏感，其他平台按 byte-exact canonical path。任一历史 Automatic record 的精确 root 始终拒绝 Manual open，不得因当前 allocator 已切换而把该 record 重解释为 Manual。

Task 创建在产生外部 effect 前必须证明：

- 当前默认 ExecutionConfig 与 expected generation 仍有效；
- Workspace intent、ownership、epoch 与 authorization 有效；
- Workspace、Task、Agent Session 与 projection 容量可用；
- Product Control 尚未进入 replacement 或 shutdown。

Automatic admission 在完成上述证明后才创建候选目录、临时 Workspace record、Agent Session 和 Task record。发布前的任何失败必须释放 Session 与候选 record，并只回滚本次创建且仍为空的目录；Task 已 durable 发布后的 Run admission 或执行失败不能回滚真实 Task 或目录。Manual admission 对 registry、recent order 与 Task 引用的变化必须与 Task candidate 一同提交，不能发布只更新一半的关系。

每个 Task 在创建时取得 owned ExecutionConfig 和 immutable binding epoch。默认配置变化不热替换已有 Task；显式改变 Task execution 必须在 Task idle、authority 精确且持久化 candidate 可提交时形成新的 binding。Run、manual compact 与 Conversation recovery 共享 Task-owned active-operation 槽；删除和 Session replacement 是独立生命周期用例，必须与该槽互斥并等待已有 operation 收口，不能通过不同入口并发改变同一个 attachment。

Task aggregate 独占普通消息的接收、顺序、推进、停止及失败状态。Renderer 只提交 Task、operationId 与内容；Control 只协调 Workspace、Models、Skill、Attachment、Schedule 与执行资源，不持有第二份队列或复制 Task 的调度规则。Task 在主线程先取得唯一 owned payload 与安全投影预留，接收不等待 Run readiness、标题、checkpoint、compact、restore 或合法配置准备；真实 authority、内容和容量失败仍明确拒绝。

Task 使用有界待处理列表和现有 lifecycle wake。队首文本可在已就绪文本 Run 中通过现有 RunControlLease 同步 submitInput；Skill、附件、未就绪或收尾阶段等待。空闲后队首领取和普通 Run admission 在同一主线程事务中完成，自身预留不阻挡自身，显式 run 不得越过队首。必要准备只登记一次，Control 调用对应 owner；明确失败不循环修复。瞬时时序拒绝保留等待，真正的无效输入、依赖/预算失败结束该消息，unknown 保留真实合同失败，不改投。复用 Session 同步控制能力，不建立 submit Executor job 或异步回执归并屏障。

接收 metadata 随所有权移入根输入或 additional input，保留 operationId、原接收时间与展示位置且只投影一次。原文复用共享内存预算；附件接收时由 Control 协调一次性 grant 与原件移交 Task，等待期间不得保存栈上 callback 或 grant。未交付资源在取消时由原 owner 清理，已交付原件沿 Task 生命周期保留，清理失败保留原 owner 的有界 cleanup debt。安全历史保存展示记录与执行关联，具体失败原因只在内存；重启的未执行消息中断且无 raw payload，不从历史重建执行。

Task 在调用前预留有界 identity、安全消息投影及独立的原文 owned copy；Agent 调用仍只同步借用输入。原文预留失败必须先于 Core 效果拒绝，拒绝释放候选，接受保留 receipt sequence，合同失败保留 unknown。安全投影归属于原 Run，只供历史展示、对账和权限上下文使用，不能成为执行来源。原文仅在 Host 内存中按 Runtime 共享预算持有，单条遵守普通输入容量，数量与累计字节不得超过 Agent 发布的 Core 上限；Runtime 原文缓存总量不超过累计字节上限，合并临时缓冲另限为一个普通输入。原文不进入日志、Snapshot 或历史，收口和销毁必须清零释放，释放不重置 Core 已接受的累计额度。事件 input_adopted 提供真实 turn 与活动顺序；终态在 event-drain barrier 后以 Agent 权威计数收口接受前缀为 adopted/unadopted，计数无效时剩余记录为 unknown，已知采纳事实保留。仅由计数确认的采纳不伪造活动位置。

自动评审的转人工原因归 Task 的当前请求运行时状态所有，第一次有效结算同时保存原因及已投影的有界理由，后续 worker 清理不得覆盖；身份失效时清理，迟到结果不得创建人工提醒。Control 只报告它实际观察的容量、支持边界、启动或调用失败，不把技术故障当作模型存疑；watchdog 使用取消令牌结束调用仍须保留其 timeout 事实，取消后的模型建议不得生效。原因不新增持久化字段、审计 occurrence 或日志系统；wire shape 由 [Renderer Bridge 合同](renderer-bridge-contract.md) 定义。

自动审批必须完整保留当前 Run 根输入及该 request 创建时 Agent 已确认采纳的追加输入前缀，不得截断当前约束后批准。历史仅收集同 Task 的根输入和 `adopted` 追加输入，排除 `pending/unadopted/unknown/transferred`；按真实采纳顺序构成完整 Run 组，从最近历史向前选连续组，首个放不下即停止，再按时间顺序提供。当前请求与当前 Run 优先占用预算，历史在 Host 最后一次脱敏后依据实际 JSON 编码预算保留最近连续后缀，明确给出省略消息数量。省略本身不使请求转人工，不能补猜被省略的授权；历史窗口不能保证包含窗口外的早期限制。当前 commentary 只是既有不可信背景，不加入历史 Tool 输出、自动摘要或 Agent 自选证据。prepare 与接纳 allow_once 时均检查 Task 等待输入、该 Run 的已接受未采纳输入和正在进行的 submit 调用，存在任一项则结束自动审核并交给人工，不等待输入、不重复审核；有效 deny 保留原语义。插话不能作为权限授权或替代 UI 回答。Stop 沿用独立 abort 入口；Agent 关闭提交窗口并等待已登记调用返回后，才能导出 checkpoint、发起其他 Core 调用或销毁 Session。worker 的退出清理及通知对象仍须保持到最后 lease 释放和全部 worker join；shutdown 关闭所有新 admission。

Task 只在来源 Run 正常 completed、完整事件排空后计数整体可信、Session reusable 且无输出投影故障时，为确定未采纳且原文完整的消息建立运行时接续预留；已采纳和未知消息不带走。停止、失败、中断、预算或轮数停止均不接续。确认采纳的原文立即清零释放，其余原文在取消、失败或目标取得输入所有权后释放。批次按提交 identity 合并全部未采纳原文，以两个换行分隔，分隔符计入普通输入字节上限；超限整批结束，不截断、不拆分。每个来源至多尝试一次，恢复或重复 lifecycle wake 不重新激活。

Task 决定等待来源事件、Session 调用、worker lease 与 checkpoint 全部收尾，Control 协调跨对象结果；checkpoint 失败结束本批。有关联待确认 Scheduled occurrence 时，必须先确认原 Run 结果并成功写盘，复用 pending occurrence 与 persistence health，并观察本次确认的明确失败（包括未改变健康状态的分配或编码失败）；不能让后续 Run 替换 Schedule 观察的终态，不等待系统通知送达。失败或未知取消相关批次，恢复存储不复活；无关 Task 不受此门禁影响。等待期间 Task 接收新消息，拒绝冲突的显式新 Run、compact 与 restore，但不伪造来源 Run 的 active phase。收尾完成后，认领与一次普通准入在同一主线程同步完成，不发布中间空闲状态；准入仍检查 binding、工作目录、模型、审批、容量、存储与 shutdown，不能被自身预留阻挡。

Task stop 在同一次主线程事务里取消当时已有等待消息与接续，并请求停止当前 operation；此后接收的消息等待停止完成，不被旧 stopped/cancelled 终态取消。独立真实失败首次收口时结束当时等待项，之后新输入不被旧回调追溯取消。指定 Run cancel 的取消意图绑定来源 Run，独立于普通 cancel_requested。有效 Stop、归档、删除、移除 Workspace、关闭 Task、显式退出、实际审批修改或 authority 失效，在目标接纳前均结束本批；来源已 terminal 仍可停止预留，旧来源 Stop 不影响已接纳目标。取消只覆盖当时已有的消息；若审批修改后来源仍在运行，随后新接收的插话可以形成新批次，但不得恢复旧消息的接续。隐藏窗口、切页面或 Renderer 断连不取消 Host 意图。来源转入关联与真实目标 Run 在同一候选历史中发布；准备失败且目标回滚时恢复未采纳，普通准入已接纳的目标即使 enqueue 失败也保留真实终态与转入关联。沿用普通 admission 的 best-effort 历史写入语义，不从写入错误推断执行未接纳、不自动重试。目标后续失败或停止不回流来源；完成通知与未读回执语义保持现状。

Product Task 还拥有绑定 Run identity 的 completion receipt。durable `completion_seen_run_id` 只记录 Renderer 已明确观察的当前最新 terminal `completed` Run；Product projection 只在该 Run identity 与 receipt 不同且它仍是最新 terminal outcome 时发布未读 identity。acknowledgement 必须同时携带 Task/Run identity，迟到、重复、其他 outcome、已删除 Task 或已被新 terminal Run 取代的请求无副作用；它不改变 Task `recent_order`。归档在同一 Task mutation 中确认当前 completion。Renderer 只报告中央 Task 工作面是否真正暴露，不从本地缓存、选择状态或时间推断 canonical receipt。

Product Control 拥有全局的新 Task 默认 `ApprovalMode`，在 create admission 时复制；成功提交交互式 Task 时，同一 canonical mutation 记住其模式，并随 Task 历史进行同一次 best-effort projection commit，admission 拒绝、回滚和 noninteractive Scheduled occurrence 均不得改变。历史写入失败不回滚已发布的交互式 Task 或进程内默认值，后续完整 snapshot 按现有恢复规则重试持久化。旧合法历史缺少模式默认值时，从原默认 profile 恢复人工审批或完全访问；不得把新默认值覆盖到已有 Task。

Product Task 持有当前 effective profile、是否采用自动评审、interaction fact 与单调 approval revision；每个 Run 保留创建时的 profile 与 interaction provenance。`ApprovalMode` 从 Task 的唯一 profile 和评审事实派生，不建立平行的模式或委托真源；自动评审选择随 Task 持久化恢复。显式切换在同一 interactive Task、Workspace、Session 和 Conversation 中完成，Manual 与 Automatic Workspace 都适用；noninteractive Scheduled occurrence 不开放切换。新 Task 默认模式仍由 create transaction 独立拥有，已有 Task 切换不改变默认值。模式的产品语义及 Core profile 映射见[产品需求](requirements.md#55-审批与输入)。

审批切换 admission 同时校验 Task identity、binding epoch 与 approval revision，拒绝 stale、并发 mutation、归档、删除和 shutdown。相同模式无副作用；真正提交推进 approval revision，防止 A→B→A 使旧意图重新有效。人工与自动评审共享同一 Core profile：切到自动评审可以为当前未回答 request 启动一次评审，切回人工立即使旧 review identity 失效并请求取消，保留当前 request，不能等待审核线程退出或接纳已排队的旧结果。涉及 Core profile 的切换先按需取消 Run，再等待真实 terminal、event drain、callback、abort 与 checkpoint 静止；不能把取消受理当作静止，也不得重放挂起工具或自动发送下一条输入。

Product Control 拥有审批事务与有界 worker；Agent 是官方 Session mode mutator 的唯一消费者。切换前先确认覆盖当前 Conversation 的旧 checkpoint；Core 成功后写入新 immutable blob，再原子确认 Task 当前模式、revision 与 checkpoint reference，确认后才开放下一 Run 并异步退休旧恢复点。mutation 前失败保持旧模式；mutation 后导出或 metadata 明确失败必须关闭变更后的 attachment，再按已确认旧基线与旧模式恢复，禁止用反向 mutation 回滚已撤销的 Session grant。结果未知时保留旧恢复点、candidate 与原 history packet，阻止冲突写入和执行，只以显式 canonical readback 决定采用哪份事实；取消或 shutdown 不得隐式重写、读回或重放。detached Task 先按已提交模式恢复 attachment，再执行此次切换，不能以目标模式 restore 模拟 mutation。已明确拒绝且不被 canonical checkpoint 引用的 candidate blob 交由同一有界 retirement owner 清理；结果仍未知时不得删除 candidate 或旧恢复点。

权限诊断是 Product Task history 的有界审计投影，不是第二个 policy engine。Pending request 与 resolved occurrence 可以投影 AgentCore 已提供的 canonical arguments digest、policy generation 和 candidate/rule identity，并与既有 tool identity、decision source、Session rule 命中和 restore 结果共同用于解释重复请求。Product 不记录原始参数、credential 或可重放 response，不从 digest/tool text 推断 effect，也不自行匹配或生成 grant。

Automatic Workspace record 只有在 owning Task 已物理删除且相关 Run event、worker、Session 和 catalog lease 全部 quiescent 后才能释放。真实目录不因 Task 删除、shutdown 或重启被递归删除，也不能通过扫描遗留目录猜测或恢复 Product record。

automatic-root 配置不进入 `workbench-history.store`、checkpoint 或 file-change blob，也不改变其 schema。A→B 切换后，既有 Task/Workspace 继续使用已记录的 A child，只有后续新 Task 从 B 分配；A 不可用时历史仍可读，但需要该路径的 restore/run 明确不可用。Scheduled occurrence 每次触发都通过同一当前 allocator admission，不在 definition 中固化 automatic root。

### 2.3 Scheduled Task

Schedule aggregate 拥有 Scheduled Task definition、触发游标、occurrence history、persistence health 与 occurrence reconciliation。Application 只提供持久化、wall clock、单一平台 timer、notification 和后台窗口生命周期 capability；它不决定 recurrence、missed occurrence 或 Task admission policy。

到期 callback 只唤醒 Schedule reconciliation，不能直接调用 Agent。一个已接纳 occurrence 必须通过 Product Control 的既有 Task 创建、命名和 Run admission 形成真实 Task，并复用同一 Workspace、ExecutionConfig、Executor、Session、event pump、permission、persistence 与 snapshot 路径；不得建立绕过这些 Gate 的 schedule queue、worker 或 AgentCore 调用路径。

Schedule definition 固定自己的 PermissionProfile；每个 occurrence 在 launch 时复制当时的 definition profile，并以 `noninteractive` interaction 创建 Task/Run。后续 definition update 只影响未来 occurrence，不改写历史 Task。Agent 遇到第一个未覆盖 permission request 时不得发布 pending UI 或等待 Renderer，而要提交 stop fact 并唤醒 canonical Product event consumer 请求中止；只有真实 Run 收口后才能发布 `permission_required`，Schedule 随后进入 `needs_attention`。

Schedule 只持久化已提交的 occurrence 与 Task identity，不持有 Product Control capability、可变 Task 指针、API credential 或 live Session。Task launch 的明确失败按 occurrence transaction 收口；结果不确定时不得重放可能已经创建 Task 的 launch。真实 Task 一旦已经创建，其 identity 必须先保留在 Schedule 的 live candidate；后续 Schedule commit 失败时保留该 candidate 并关闭 timer，显式 recovery 可提交当前真相，进程重启则由 durable `claimed` fact 收口为 `host_interrupted`，两条路径都不得重复 launch。Task 仍存在但未 terminal 时跳过，Task 已永久不可用时把该 occurrence 收口为 `unavailable`；单条不可用记录不得阻塞后续 occurrence reconciliation，也不得伪装成 Task 执行失败并发送失败通知。系统通知只消费已提交的 occurrence/Task terminal fact，通知失败不能回滚产品事实或伪造 Run cause。

Schedule 的可执行定义保存 Models-owned `ModelRef + source_generation + selection_revision + protocol`。每次触发先精确比较当前 Models default 与 Product Control 已安装 authority，再由 Product Control 当次 resolve 并把当前进程内 generation 交给新 Task；Schedule 不保存或比较该 Product generation。因此同一 source authority 的冷启动 generation 变化不使计划失效，而 selection revision 会阻止 A→B→A 静默复用。Catalog 或 execution authority 暂未就绪时只取消 timer 并停止新 resolve，不得把瞬态 unavailable 写成 `needs_attention`；获得完整可用 binding 后才判断 captured authority 是否真正变化。Metask authorization 丢失只使依赖 Metask 的新触发不可解析；custom source 与已经交付给 Task/Run 的 owned binding 不被追溯撤销。编辑 paused definition 必须保留 paused 状态。Schedule store 是独立持久化边界，其 credential scrub 必须作为 durable candidate commit 完成，不能只修改内存 projection。

Schedule persistence recovery 仍由 Schedule aggregate 决策：只有 typed non-ready health 才发布 action，命令必须校验全局 revision。Schedule 先对当前内存 store 执行 credential scrub 并编码 canonical candidate；Application 先完整 stage 并 sync replacement，再把旧 canonical 改名为唯一 quarantine artifact，最后安装新 canonical。明确安装失败必须恢复旧 canonical；中断或结果不确定时，精确的 pending marker 必须使下次启动 fail closed，不能伪装成首次启动。用户再次确认恢复时，Application 必须先把旧 backup 改名保留为 quarantine、删除未安装 candidate，最后删除 pending marker 并 sync，再开始新的恢复事务；孤立 temp、backup 或相似文件名本身不改变 canonical 的可读性。只有 committed 才转为 ready 并重新 arm；quarantine 只用于人工恢复，不进入 decoder、snapshot 或自动迁移。

Schedule store 只有唯一 canonical `schema_version = 1`，definition 的完整 binding 是不可分割的 `ModelRef + source_generation + selection_revision + protocol`。启动只严格解码当前 shape；旧 shape、未知 version 与未知字段都按 corrupt fail closed，不存在 legacy decoder、migration transaction、迁移中间状态或运行时 fallback。Renderer 只能看到完整可执行 binding，不承担历史身份推断或重绑流程。

### 2.4 Skill authority 与本地资产

Product Skill aggregate 拥有本地资产 inventory、management transaction、enablement policy、Workspace catalog authority 与其持久化健康。Agent 拥有 AgentCore catalog acquisition、opaque lease 与运行时 catalog identity；Application 只注入 FileStore、受限文件能力、原生 picker 和经过验证的内置 Skill 根。Product Control 负责 Workspace/Task authority、shared Executor admission、全局 revision 与完整 snapshot，不读取 Skill 内部 state 或拼装物理路径。

内置来源根与可选的组件 source lifetime 在 owner 线程作为一对输入捕获到 catalog job，排队前复制路径并保留引用。之后替换来源只影响后续捕获，不能让旧 job 使用新版本的 lifetime。查询期间由 job 保留资源，成功后由 [Agent catalog lease](agentcore-integration.md#skill-catalog-ownership) 接续；排队拒绝、取消、检查失败、stale completion 和 shutdown 都必须释放各自拥有的引用。旧组件的文件删除不能依据 Task 历史或绝对路径文本推断引用；只有进程内引用静止后才能回收。 来源切换由 Product owner 线程接收已验证的根与同一个 lifetime；切换前检查 shutdown、相关 request generation 容量及未完成的资产 reconciliation，拒绝时保留旧输入。成功时同时推进 personal 和已授权 Workspace 的查询 generation，使旧 completion 失去提交资格，并合并后续发现 intent；不修改已有 Task 的 pinned authority，不重放工具。Application 保留旧 current 引用到该 handoff 成功后再退休。

Skill 持久记录只按 Workspace id 归属；`skill-enablement.json` 与 `skill-management.json` 保持唯一 canonical `schema_version = 1`，格式原地硬切，不持久化 Workspace epoch，严格解码当前格式，不存在旧格式 fallback、折叠、迁移、quarantine 或恢复动作。能读取但无法按当前格式解码的数据直接失去 authority，store 从空状态继续，并在同次启动中以 atomic replace 写入空的当前格式；替换成功才是 `ready`，任何替换失败均为 `corrupt`，文件读取失败为 `read_failed`。Workspace epoch 只做 command、job 与 completion 的 freshness 校验，移除开始时推进、不回退；任何路径都不得用 epoch 推断记录归属。身份连续性由 Workspace identity allocator 保证：启动时 allocator 必须高于有效 Skill 记录引用的最大 id；两个 Skill store 只要有一个是 `read_failed`、`corrupt` 或 `outcome_unknown`，就不能证明 canonical 中哪些 id 仍有 authority，此时禁止分配任何新的 Workspace id（Manual 与 Automatic），`newTaskAdmission` 与 `automaticWorkspaces` capability 同步发布不可用，只允许重新授权已存在的 record，直到后续启动严格读取或替换成功。普通 mutation 的 `write_failed` 仍保留已知的内存与 canonical id authority，不阻止分配新 id。记录只在隐藏 record 被 slot 复用、id 永久退出 registry 时退休：复用前 Control 先确认两个 Skill store 均为 `ready` 或 `unavailable` 且该 id 没有 durable transaction，否则保留隐藏 record 并按既有容量规则拒绝新增。退休只删 policy/inventory 记录，不触碰目录；各 store 独立提交，失败按各自 health 规则冻结。没有已注册 owner 的记录不可管理，也不做任何启动时的归属推断或清理。

Personal 或 Workspace 的 committed Skill authority 必须不可分地拥有 immutable catalog snapshot、policy revision 与对应 Agent lease。catalog acquisition、policy mutation 或本地资产 reconciliation 先形成完整 candidate，并在提交时重新校验 Workspace identity/epoch、catalog identity、policy revision、相关 active operation 与 shutdown。stale candidate 只销毁并释放 lease，不安装、不自动重试。

Enablement mutation 先构造受影响 authority 的完整 candidate，再提交无 secret policy store，最后 no-fail 替换 committed authority。明确 write failure 保持旧 authority；outcome unknown 必须冻结新的 Skill authority mutation 和 Skill admission，不能降级为全启用。尚无 committed authority 的 Workspace 不得锁死无关 scope 的 mutation，但以后取得 catalog 时必须按最新 committed policy 编译。

Manual Task 创建时同步借用可用 Workspace authority 并取得独立 pinned snapshot/lease；缺席时保留 uninitialized，后续显式 idle refresh 绑定。Automatic 交互 Task 先提交真实 Task 和 Session，再以 owning Task 的 root/home/epoch 查询与 idle 绑定准备首个 Run；同一 Task 的 loading/ready/degraded/unavailable 通过既有 catalog projection 发布，loading 期间 Run 接纳拒绝，失败保留 Task 与草稿，不启用部分 authority。Conversation recovery 不以 Skill readiness 为资格，也不向 restore 注入旧 Skill authority；Automatic 可用 Session 安装后再次执行初始准备。准备不属于 Schedule required admission，不为 noninteractive occurrence 创建 catalog job。已有 pinned authority 不因目录、policy 或来源变化自动替换，仍只有显式 idle refresh 在 Agent 成功后提交新 pinned snapshot。

本地资产 import、reimport、uninstall 与 retry 使用同一 staged transaction：preview capability 绑定 source、内容摘要、目标 scope 与有效期；commit 重新校验 capability、目标 Workspace authority、冲突 generation 和相关 Task quiescence；publish 后必须完成 Agent catalog reconciliation。明确且可归因于候选的失败回滚 candidate/backup；catalog 暂时不可验证时保留可恢复 transaction 并发布 `pending_verification`，不能声称 ready。恢复只能完成或回滚已登记 transaction，不扫描、接管或删除 canonical root 外的目录。

恢复 durable `prepared` transaction 时，只有 transaction 记录了 backup 才检查 target/backup 物理状态：target 存在且 backup 不存在表示 rename 尚未发生或回滚已恢复；target 不存在且 backup 存在时必须先原子恢复 backup，再幂等删除未发布 candidate；两者同时存在或同时缺失必须保留全部 artifact 与 transaction 并 fail closed。fresh install 没有 backup，target 与 backup 同时缺失是正常的未发布状态。恢复磁盘事实后才能清除 transaction 或临时 inventory owner；任一步持久化结果不确定必须将 management health 置为 `outcome_unknown`，明确写失败置为 `write_failed`，两者都阻止后续 management mutation，直到重启严格加载 canonical 后重新尝试恢复；不得用当前领先于磁盘的内存 phase 开放普通 mutation。状态/phase 或 health 的变化均通过 Product revision 发布，即使原操作仍返回错误、或资产已从内存清除。

文件事务明确失败后，在仍持有该次授权 root 且 inventory 可信时，只对失败 install_id 尝试一次既有 phase 恢复；失败不自动循环。`pending_verification` 只适用于 state 与 `reconciliation_pending` phase 同时成立的资产，其余有 recovery 的资产派生为 `recovery_required`；包括已 `reconciled` 但清理文件尚未完成的情况。现有 Retry 按同一判定进行物理恢复或登记新的精确 catalog verification，不能把恢复成功当作验证成功。物理恢复仍要求当前 root authority、相关 Task quiescence、无 active reconciliation、目标 scope 无 job/reschedule 与未 shutdown，但不依赖来源配置可信；配置尚不可信时不排队验证。资源、目录访问和时钟失败保留事务，不误改 canonical health。启动/重新授权恢复与显式 Retry 共用同一物理 phase 实现；不重新加载并替换飞行中的 inventory。

固定兼容来源选择也由 Product Skill 拥有，与单 Skill enablement、inventory 和 Task pinned authority 分离。来源配置以独立 `skill-sources.json`、schema 1、单调 revision 做持久 CAS；首次缺失须先持久提交默认关闭值才建立可信配置。读取预算为 4096 bytes：恰好达到预算仍完整解码，超出预算单独标记 `too_large`，不得按损坏处理或解码前缀。损坏/后续缺失可显式 reset；读取失败、超限、不支持格式和结果不确定只允许按 capability 重读，不得自动覆盖。恢复 token 绑定当前恢复代次，reset 写入前重新读取；若文件已恢复合法，保留其真实值并以高于已观察 revision 的新提交重建 authority。

来源 mutation 以 Claude/Codex 品牌为单位：同一 CAS candidate 同时设置该品牌的个人和项目值、保留另一品牌，一次持久提交且 revision 至多推进一次；不提供逐目录写入口。schema 1 保留四个真实根的值，加载已有部分启用配置时不自动归一化。candidate 先持久提交，再 no-fail 安装选择并使实际受影响 current authority 失效；个人值变化影响 personal 与所有已授权 Workspace，只有项目值变化时不使 personal 与个人来源限定的 Automatic authority 失效。明确写失败保留旧可信选择与 authority；持久结果不确定冻结新的来源/管理 mutation 与 Skill authority，但不追溯撤销已有 Task pinned lease、普通 Text 或 durable management transaction 的恢复职责。根检查在有界 worker 中执行，仅授权固定相对目录；不存在的可选根可缺席，不可读、不支持类型或变化的根不得被静默跳过后发布部分 authority。AgentCore 仍独占 Skill 解析及 winner/conflict 判定，Product 不实现候选 fallback。

本地开发内置来源由 Application 从 `METAWORK_LOCAL_SKILL_ROOT` 开发启动配置取得并 canonicalize，release artifact 不消费该入口；Product Skill 以固定 source instance ID `metawork.builtin`、个人归属的 additional source 参与 personal 管理查询和已授权 Workspace 查询。该根不属于兼容来源开关或管理 inventory，不复制到用户 Skill 目录，不授予 import/reimport/uninstall 文件权限；同名冲突与 Workspace 优先级仍由 AgentCore 裁决。Application 保持借用路径到 Product shutdown 完成，catalog job 在排队前复制根路径并独立持有；配置的根缺失、不可读或不满足 canonical directory 约束时整个查询失去 authority，不发布部分 catalog。未配置时不推断安装路径或启用其他来源；该开发入口不形成 release 安装包承诺。

Automatic 的 Skill query authority 来自 owning interactive Task 的可用 Session，不来自 Manual 选择器的 visible 标记。它只消费已启用的个人兼容根与内置根，按 User policy 编译 resolved winners；workspace-local winner 或未知 provenance 必须禁用，不能选取被它遮蔽的个人候选。工作文件、ZIP 解压目录和其中的 SKILL.md 都不构成 Skill 授权；Automatic 不开放项目 policy override 或安装/卸载管理权限。初始准备、显式 refresh 和 job completion 都重新核验 owner、epoch、来源配置、policy 与投影容量。删除撤销查询 authority，并等待 catalog job、Session 与 Task worker 静止后才提交 Workspace record 退休和 Task 专用原件/artifact 目录删除；Automatic 的实际工作目录继续遵守既有保留合同；shutdown 先停止 admission、join jobs，再释放全部 catalog lease。

每个查询 scope 至多保留一个 job 与一个 latest reschedule intent。来源提交时即推进 request generation；旧 generation、选择或 Workspace epoch 的结果只释放，不得因 A→B→A 恢复同值而发布。shared Executor 的 QueueFull 保留 intent，沿既有 completion/wake 与 Control sync 有界轮转重试；其他错误结束该 intent 并等待显式刷新，不增加 timer、watcher 或无限自动重试。来源查询不隐式刷新 Task。

管理资产关联必须同时证明 query purpose、provider、固定 source identity/scope 与 invocation，不能仅凭同名 winner 借用外部来源的健康、policy 或文件权限。管理记录与同名 external winner 可同时存在。验证 job 绑定 install identity、operation、scope/epoch 和 request generation；普通刷新不得完成 pending transaction，取消只清理匹配的 active verification，不丢弃 durable pending。发布验证还必须核对授权目标的实际 package 与 candidate 摘要；卸载验证证明该精确管理目标不存在，不要求其他来源的同名 Skill 一并消失。

#### 内置 Office Skill

Application 发布随主包压缩携带的完整 Office Skill、必要 helper 和 OOXML 校验资源。资源按内容哈希发布到自有目录，不覆盖已有版本；发布失败只撤销 Office 来源，应用继续启动。不维护基础/完整双来源或组件版本 catalog lease；准备依赖不替换来源，不要求刷新已有 Task。资源入口必须是明确的绝对路径，不从 AgentCore 临时物化目录的父路径推断程序位置。旧资源目录首版不自动清理。

Office 的机器输入按 Windows x64/arm64 与 macOS arm64/x64 精确选择私有 Python、Node 和目标 wheel，验收范围由[验证规范](validation.md#office-skill-与私有环境验证)记录。解释器和各自文档库同处一个按环境内容命名的目录；Windows x64 的既有发行、锁、身份及 Python/Node 独立准备保持。身份采用选定发行记录 JSON、对应库锁和布局标记的同一 SHA-256 构造，不包含 Skill 文案、业务脚本、下载量或用户目录。输入和 namespace 只由 Office manifest/lock 定义，生成常量不是第二份 authority。不探测组合系统解释器和全局包，不新增 Host 工具、Product 环境对象、Bridge/Snapshot、current 指针、版本选择、修复或回收状态机。依赖准备由 Agent 经现有 Shell 和权限执行；对话下载同意不授予文件权限，full_access 不增加额外产品安装 Gate。

依赖根为 Windows `%LOCALAPPDATA%/MetaWork/OfficeDependencies` 与 macOS `$HOME/Library/Application Support/MetaWork/OfficeDependencies`，不从 Task Workspace、应用数据名称或 Core 临时 Skill 路径推导。同一用户下相同内容身份有意跨构建和 Task 复用，测试以独立 HOME/LOCALAPPDATA 隔离。正式路径项必须为真实目录，符号链接或异常占位对象须保留并拒绝；不原地修改是行为合同，不保证文件系统只读或隔离同用户进程。

macOS 首次新建 Node 需要已准备的固定私有 Python，通过其标准库执行 Darwin 排他发布；Node 就绪后的检查、复用和执行不依赖 Python。准备器不得隐式下载此前置环境。Agent 按实际缺失部分说明 Python/Node 各自或合计的预计下载量并取得同意，再按 Python→Node 顺序准备；仅需 Python 时不下载 Node。Windows 继续独立准备两种语言。所有入口均为明确绝对资源路径，macOS 通过 `/bin/sh` 调用，不要求物化文件有执行位。

固定准备入口只接受 Python、Node 两个目标。独立临时目录下载、完整校验、安装锁定库并验证后，以不覆盖的同卷原子改名发布。macOS 只使用 `renameatx_np(RENAME_EXCL)`，不以普通 rename、复制或 `mv -n` 替代。并发允许重复构建，输家从赢家的真实解释器启动新进程核验后复用；新增目标发布后同样必须从最终路径启动新进程检查可搬移性。发布后检查失败保留正式目录并报告不可用，不回滚删除。取消或超时先停止并 join 自有子进程，不能确认后代已停止时保留自身 stage，不扫描其他残留。临时共享冲突允许有限短重试，永久错误明确失败。正式目录不原地修改、不自动隔离或删除；改名成功不能证明无人使用。校验失败须说明不可用和精确目录，提供人工恢复指引：停止所有使用该目录的 Task 与外部脚本，退出应用并确认没有使用进程后，由用户明确选择只清理这一目录，再重新启动并同意准备；无法确认使用者已停止时保持原状，不清理父目录、其他环境或文档。Python 不用搬移的 venv，包只接受带哈希的固定 wheel；Node 以独立锁文件安装且禁用安装脚本。薄调用脚本只设置单次解释器/库路径，不隐式下载、不改 Task 长期环境，不提供沙箱保证。

读取用户镜像、代理和证书配置沿用包管理器机制，不写用户配置；关键安装目标、内容身份和安装行为仍固定，不自建配置解析或选源系统。固定来源、信任和主包资源接受规则分别见 [Windows 分发](windows-distribution.md#office-skill-与私有依赖)与 [macOS 分发](macos-distribution.md#office-skill-与私有依赖)。普通启动不下载、全量哈希或自检环境，也不登记健康数据库。首版不自动更新、修复或回收，明确接受旧目录积累。

### 2.5 MCP authority

Product Control 拥有 MCP Desired Registry、connection approval、OAuth consent、credential locator、Runtime Manifest、Admission Authority、mutation/recovery 与 Task admission。Agent 拥有 connector/backend 生命周期、AgentCore descriptor、declarative Runtime apply、Activation、catalog 与 Selection。Application 只执行 child、network、系统 credential、OAuth、HTTP auth snapshot 与跨 owner coordination，不拥有 MCP JSON-RPC、产品状态或 admission policy。Account 与 MCP 不共享 ownership、credential service 或 persistence。

Desired Registry、Runtime Manifest 和 Admission Authority 是三个不同事实：

- Desired Registry 表达已 durable 提交的用户意图；
- Runtime Manifest 表达正式 Agent Runtime 已接管的 descriptor，或无法接管的无 secret absence proof；
- Admission Authority 表达新 Task 当前可以同步借用的已验证 Selection，或明确的 blocked reason。

MCP mutation 必须从 canonical Desired 构造完整 candidate，先提交 registry，再由 Application coordinator 构造 Runtime input、调用 Agent declarative apply、取得正式 Activation，最后由 Product Control 原子安装 Manifest、Activation 与 Admission Authority。正式 apply 成功只影响之后创建的 Session；已有 Session 保持创建时已复制的 authority，不热替换或即时撤权。

registry commit 明确失败时保持旧 Desired 与 authority；commit 结果不确定时不能宣称 canonical generation，必须保留 recovery fact 并冻结后续 mutation。Agent apply 拒绝、malformed report、resource limit 或 activation failure 形成 typed failure 并保持 fail-closed admission，不能把未接管的 descriptor 标记为 loaded。candidate Runtime test 与正式 Runtime 隔离，不安装 Manifest、Admission 或 Task authority。

Application 启动时只创建一次 canonical empty Agent Runtime；恢复出的 Desired 必须在 Product Control 与 coordinator 就绪后沿与后续 mutation 相同的 apply 路径安装。empty create 后 apply 是正常启动协议，不是失败 fallback 或第二条 Runtime path。Agent Runtime create 失败终止启动；外部 MCP child、network、handshake 或 catalog failure 只能使相关 MCP authority unavailable，不能关闭普通 Text Task admission。

MCP apply、catalog refresh、durable OAuth mutation 与运行时 reauthorization 共享 Product Control 的串行化边界；浏览器授权等待不占用该边界，只携带 server-bound operation identity。浏览器等待期间，其他 server 的 OAuth refresh 和 reduced-authority catalog refresh 仍可运行；进入单一 durable `oauth_operation` 后才按事务串行。所有 completion 必须按 operation、server/connection fingerprint、consent epoch 与当前 generation 重新授权，stale 结果只清理自身资源。目标 server 进入 OAuth 或 reauthorization 时必须先提交排除它的 reduced authority，不能无关地冻结其他 server。

普通 Text Task admission 不属于 MCP 边界：MCP 未就绪、refresh/apply/OAuth 在途或 freshness failure 都不得拒绝 Task 创建。创建时只复制当刻安全可用的 Selection；不可用时以 null Selection 创建，并在 Task 的进程期 immutable authority fact 中区分 `ready(selected)`、`ready(none)` 与 `unavailable`。该事实进入 Snapshot 和 create result，不进入 Task persistence，冷启动恢复的历史 Task 为 `unavailable`，Renderer 不得据此热附加 MCP。freshness failure 必须使旧 MCP Admission fail closed 并触发现有异步 refresh；原 restore 或 mutation 不自动重放。边界忙时必须保留 runtime authorization failure 与 refresh pending 事实；refresh enqueue 失败必须由 owner timer 有界重试。关闭时先停止 MCP management、OAuth/refresh timer 与新 MCP admission，再 settle/join worker，释放 Admission 与 Activation，最后由 Agent owner 释放 transport 与 Runtime。

### 2.6 文件 attachment staging

Attachment staging 是 Product Control 内部候选资源 owner，原件存储属于 Product 附件能力，不形成新的顶层 Product owner 或 Renderer 产品对象。Application 组装 store、持有独占 writer lock，并注入公开 Native SDK 图片预览能力；Product 决定分类、配额、接纳与清理。输入可以是系统 picker/Native SDK 拖放提供的本地路径，或 Renderer 从本次 DOM File 提取的有界字节块。Bridge 只拥有 source/window/connection authority、批次关联及 Renderer opaque token 到 Product identity 的 grant，不缓存正文、原路径或 Product 指针。

路径输入在 Product 登记唯一 preparing 批次后，使用独立 bounded attachment lane 探测普通非空文件。每个源文件只 no-follow 打开一次；主线程按探测元数据预留整批配额后，把冻结的 store identity 与已打开源句柄交给有界复制 job，并在同一源句柄上确认前后 stat 不变；用户源路径只活到候选建立，不进入日志、Snapshot、持久化或发送时重读。DOM 字节输入只接收本次 File 的连续块，不宣称具备路径身份或 stat 保证；每个主窗口连接至多一个接收批次，在开始时预留完整数量和原件字节配额，逐块写入 store，不分配文件总大小的接收 buffer。预留和 ready/borrowed 附件共用总配额，不能被 picker 绕过；它不等于进程总内存上限。

两个入口都整批原子 staging，共用单文件、数量和总容量限制。Product 按签名识别 PNG/JPEG/WebP，并通过 Application 注入的 codec 验证和生成有界 PNG；其他非空普通文件保留为不透明原件，不校验 UTF-8 或 NUL。图片和其他文件共用单文件上限，不按扩展名或 MIME 分类；非图片仍使用既有 file grant，不新增 binary wire kind。所有来源共用一个 Product 输入批次与固定容量的资源槽；整批元数据和数量、字节配额必须在创建任何原件前完成校验与预留。失败必须撤销整批候选 authority；只有确认物理删除的原件才返还配额。删除失败的 identity 保留为有界 cleanup debt，不发布 descriptor，不阻止其他合法 ready/borrowed 附件；后续显式添加可有界重试清理，不能用重连或取消假装释放。原件的存储 identity 只由 Host 生成。未发送原件位于 store 的 staging namespace，重启清除该 namespace，已接纳原件不因此丢失。

staging 状态精确为 `staging | ready | borrowed | consumed | released | failed`。Bridge 在 `tasks.run` 前校验 token 属于当前 connection/window、均为 ready 且不重复。Product 在 Task authority 校验后将原件移入 Task namespace并构造有界、不可信资料引用；图片同时提供有界 PNG，非图片原件不嵌入 prompt。顺序为可空用户文字 part 后接 chip 顺序的图片预览/原件引用。含非图片文件时用户指令必须非空。Agent 消费普通 text/image part，按文件格式选择可用 Skill 与工具；文本仍可用既有 built-in Read/Grep，不增加 AgentCore ABI、host tool 或 Provider-specific document path。准备失败回滚至可重试 staging；Run 接纳是 token 消费 linearization point，此后即使 history save、enqueue、transport 或 terminal 失败也不得恢复或重放 token。

已接纳原件完整保留在 Task namespace，文件名由 Host 随机 identity 与有界 ASCII 安全后缀构成；非图片保留原名称的安全后缀，缺失或不安全后缀使用中性后缀，图片使用已识别格式；既有持久化原件路径保持不变，Model 引用指向 owned copy，不指向用户源文件；附件输入历史只投影原名称、类型、原图片格式、原大小和顺序。Task 删除必须在 Session、executor 和 worker lease 静止后释放整个 Task 原件目录。Product 不解析 opaque checkpoint，不从模型文本反推附件 identity，也不自动将路径或原件正文写入附件输入 Snapshot、Task history metadata 或日志；Agent 按需读取产生的 Tool 记录继续遵守既有有界投影与脱敏合同。恢复继续使用原 checkpoint 中的引用与保留的原件；原件无法读取时明确失败，不能改读用户源路径或伪造空内容。

本地开发归档资源由 Application 通过 `METAWORK_LOCAL_ARCHIVE_HELPER` 取得、canonicalize 并验证为普通文件；可选的 `METAWORK_LOCAL_ARCHIVE_PYTHON` 显式指定解释器，存在时同样严格校验，配置损坏明确失败，不切换其他来源。release 不消费该开发入口。未指定解释器不撤销 helper 入口，也不证明系统缺少 Python；Agent 经既有 Bash/权限机制根据任务需要检查可用的 Python、调用 helper，并依据实际工具结果说明缺失依赖或处理失败，Product 不新增环境状态或专门提示。Application 仅注入有界资源描述，不替 Product 执行解包；Product Attachment 初始化时验证并复制描述及依赖要求，在非图片原件引用中把产品提供的调用方法与不可信文件资料分开，不新增 Snapshot、Bridge command、Product 持久化格式或 Skill policy。归档资源是 Product Control 提供的执行方法，ZIP 不加入 Skill catalog；Office 自包含资源从同一 canonical helper 生成。

受支持的 ZIP 与 Office 解包流程使用有界 helper：在库分配成员 metadata 前限制目录与真实成员数，校验路径、类型、碰撞和压缩方式，并对实际解压字节计数，不能只相信声明大小。默认在 Task 工作区操作；显式基目录与输出的路径关系由 helper 校验，该调用参数不取得不可篡改的 Task authority。输出为基目录中新建的数据子目录，不合并或覆盖既有目标。正常失败清理本次目录并保留原件；未完成标记只在完整校验成功后移除，强杀残留不能被报告为成功或覆盖复用，不增加后台回收或改变 Automatic 工作目录保留政策。归档中的 SKILL.md 是普通数据，不能被流程安装、执行或提升为授权来源；Automatic winner 授权继续遵守 §2.4。该流程不构成对任意 Bash 或完整进程资源隔离的安全承诺。

### 2.7 Identity 与 credential redaction

Product Task identity、Agent Session route identity、execution generation、Workspace identity、Skill policy identity 和 MCP server identity 各自属于对应 owner，不共享生成器，也不能依赖数值相等。跨边界只传递完成当前校验所需的稳定 identity 和 generation，不传递内部指针或 secret-bearing owner。

Credential redaction 是 owner 释放协议，而不是 snapshot 时的偶然过滤：

1. 安装新 credential 前，先清洗所有可能包含它的既有产品文本；
2. 替换或清空默认 execution 前，清洗 Workspace、Task、Run、Tool、UI 与 Schedule 的 durable candidate；
3. 释放 quiescent Task-owned ExecutionConfig 前，再用即将释放的 credential 清洗该 Task 的全部产品历史；
4. durable commit 成功后才能转移或 secure-zero 对应 credential ownership；
5. 新构建的投影块在交付前继续扫描所有 live credential，作为提交前的第二道防线；仅在内容版本和安全代次均未改变时，才允许复用已经检查过的编码块。

Models desired default 在自身 registry transaction 中先提交，不等待 Schedule scrub。Schedule scrub 明确失败或 outcome unknown 时不得安装新的 active execution；Product Control 保留旧 active credential owner、关闭 desired/active 不匹配的新 Task admission并发布 recovery。恢复成功后按当前 Models desired authority重新 resolve和安装，不回滚 Models，也不改写 Account fact。

Credential 是 opaque bytes。redaction 必须覆盖流式跨 chunk 与 UTF-8 codepoint 边界；多个 credential 前缀重叠时采用最长匹配，不能因替换 secret 产生非法 UTF-8 产品事实。除 Custom Provider create/replace 与 MCP captureSecret command 的调用期手动凭据外，credential 不进入 Bridge 或 Renderer；credential、locator、Authorization header 和可重建 secret 的 metadata 永远不进入 projection、result、event、日志、产品历史或 checkpoint record。

## 3. 并发与生命周期

- 每个 Agent Session 至多一个 in-flight operation；Run、manual compact、Session mutation 与 destroy 互斥。Conversation recovery 按 §2.2 的 Task-owned active-operation 槽互斥，成功提交后才形成新的 Session attachment；
- 每个 Session 在创建时绑定 immutable ExecutionConfig generation；默认配置变化不热替换 live Session，显式 Task rebind 也必须形成新的 Session attachment；
- Product Control 创建、排队、取消并关闭 bounded Executor；Agent Runtime 不接收 scheduler capability，worker 只能从 Product Control admission 进入 Agent 调用；
- 审批事务使用独立于 Run 池的有界控制执行容量；所有 Run 等待权限回复时，模式保存和审批委托仍必须能够完成，不能形成 Run 等待委托、委托保存又等待 Run worker 的依赖环。checkpoint/mutation、history confirmation、canonical readback 与退休复用同一审批 Job 和已有持久化协议，不建立第二套 writer 真源；主线程 admission、Task lease、Session idle fence、结果确认屏障和 source/target freshness 仍适用。关闭时取消 queued/running job，join 该 lane，再接纳确认事实与释放其引用；
- worker job 只持 owned payload、稳定 record reference、scoped Agent Session access 和完成本次工作所需的窄 capability，不保存 Product Control、aggregate Runtime 或主线程可变状态指针；
- queued cancel、worker completion、terminal publication 与 worker reference 必须各自 exactly once 收口。terminal fact 在通知、释放引用或触发外部 owner 前完成 write-once publication；
- Bridge/main thread 不执行长耗时 Agent 调用，也不等待 permission。Renderer response、snapshot failure 与 transport disconnect 只作为 typed transport fact 进入 Product policy，默认不能中止后台 Run 或覆盖 terminal cause；
- Attachment staging 使用独立 bounded execution lane；native picker 返回后，先进行 worker 探测，再由 Product 全量预留并提交有界复制。DOM 初始化、单块写入与原件同步/UTF-8 校验也使用短生命周期 job，不建立等待 Renderer 的常驻 worker。取消撤销后续写入资格，等待已冻结 writer lease 的 completion 和句柄关闭，再清理候选并确认；shutdown 必须先停止输入并 join 该 lane，随后才释放 store。completion 回主线程后必须重新校验 batch、connection/window grant、shutdown token 与 staging identity，再进行公开 Native SDK 图片预览准备；stale completion 撤销候选并按物理清理结果保留必要 debt。图片 codec 必须在其公开合同要求的 Native loop thread 调用，原件、预览与模型引用的生命周期由[附件能力](#26-文件-attachment-staging)定义；
- File Preview 使用独立于 Run、catalog、restore 与 MCP 的 bounded execution lane。worker 只接收深拷贝的 root-relative locator 和读取上限；识别图片及实际大小后才在 lane 锁内预留图片额度，文本不占原图槽，文件 IO 不在锁内执行。完成回主线程后重新校验 Task、Run、reference locator、Workspace authority；文本执行 credential redaction，图片完整原件（含容器尾部）按主线程步骤预算扫描凭据后交给受连接授权的分块传输，不执行 Native 解码或转码。原图预算覆盖读取、completion 与 grant，不在移交间隙释放额度；取消、期限、安全代次及 shutdown 统一回收，worker 未物理结束时不能提前确认已释放。raw bytes 不进入 Product history、Snapshot、持久化或日志；具体容量及 wire 由 [Renderer Bridge 合同](renderer-bridge-contract.md#file-preview-command) 唯一定义。共享容器 leaf 只报告格式、尺寸、动画和结束位置，生图严格结束策略与预览允许尾部策略分别由调用方拥有；
- 文档预览的物理资源调度由 Product Control 拥有，转换不占 File Preview lane。XLSX 的只读网格与保存值版面属于同一冻结源、同一资源及授权生命周期，切换不重新准备；版面不支持/超限只撤销该视图，独立验证的网格可以继续使用。源正文、实际网格与可用的生成 PDF 文字在任何内容发布前通过当前安全代次的凭据检查；Application 只发布 owned 文档 effect：worker 准备、读取和清理，主线程仅在 worker 完成后借用材料，清理成功后释放组件 pin；尚未排队的新 effect 可直接放弃。每份资源串行执行，关闭先撤销读取并取消在途工作，不能把逻辑 handle 消失当作物理槽归还。无法确认进程静止或清理失败的资源保留槽位和引用，不自动重试取得删除权限；shutdown 先 join 执行，再在 worker 清理，主线程最终释放。该内部调度边界不授予 Renderer 内容权限；Runtime 仍须独立校验目标、Task/Workspace、连接、安全代次、期限及正文凭据检查，Bridge 合同未开放的文档操作不得据此暴露；
- 文档源冻结区分交付成果和普通文件引用：成果必须与交付时的大小、摘要一致；普通引用由 worker 捕获实际源身份，再验证复制及后续读取的同一份字节，不能在源变化后静默重新采纳新版本。会话的授权 policy 只在主线程调用期间借用，不保存在 worker effect 中。发布摘要或内容前须在当前安全代次下完成提取正文和实际网格投影字符串的有界分步检查，匹配跨步边界的已知 credential；命中、检查失败或未完成均不得发布 ready。检查范围不包含 OCR，栅格字节扫描不替代正文检查。一次页面读取核验源并冻结该次传输的页面字节；分块运输重新校验 Product authority、安全代次和连接 grant，不在主线程重复文件哈希。页传输释放与文档会话释放分别收口；撤销、组件变更和期限失效不得交付迟到内容。正式 Runtime、Bridge 和 timer 接入须各自验收，内部会话状态机或注入 policy 的回归不能单独证明整条产品链路；
- Host 生图文件引用使用 Agent 验证的当次保存凭据，来源随既有 file reference 持久化；旧记录缺省为普通引用，恢复不解析工具文本补授来源。该来源只允许直接图片预览，不等同于 typed Output 或文件变更；
- File Changes 使用独立单 worker、有界 in-flight 的 artifact lane。diff 在入队前按当前及历史 Task credential 脱敏，worker 只持有 immutable Task/run/change identity、owned diff 和专用 store capability；完成回主线程后重新校验 Product artifact ownership。stale 或 Task 已删除的成功写入立即回收，读取结果在跨 Bridge 前再次校验引用仍属于同一 Task/Run/change；
- async completion 必须按开始时冻结的 attempt、object identity、epoch/generation、attachment 与 shutdown token 全量重新校验。任一 token stale 都只销毁 candidate，不安装、不自动重放原请求；
- capability 只在同步调用或明确的 worker lifetime 内借用；关闭开始后不得建立新的 job、timer、callback 或 responder 对 owner 的引用。

自动评审的审批权与历史仍由 Task 拥有；独立 `permission/review` leaf 只构造有界输入、发送固定策略并严格解码一次无 Tool Completion 的建议。Product Control 拥有独立、有界的 job 执行与回收，不借用被同步 callback 占用的 Run executor。job 只持有深拷贝输入、冻结 execution binding、独立取消 token 与身份令牌，不持有 Task/Run 指针、Session access 或 Task worker lease。取消中和尚未回收的 job 仍占容量；shutdown 必须先取消并 join 全部审核 job，再释放 Completion、execution binding 及其依赖的 transport owner。删除 Task 不等待审核 job 的 Task lease，迟到结果由身份重新校验丢弃。

Task 拥有捕获的自动评审模式、当前请求状态、结果接纳与审批历史。preparation 只转移有界 owned 输入和完整身份令牌，用户文本或明确选择的 Skill/附件 metadata 可解释意图；未提供的 Skill 指令、附件内容和脚本效果不得被猜测为授权。超限或准备失败保留原人工等待，同一请求不因轮询重试，只在新的请求重新准备。 固定 Host 生图工具的评审输入还必须携带 Agent 拥有的实际效果说明，明确可能收费、失败或中断后可能已生成及不可自动重试；只按精确 Host namespace/name 取得该事实，同名 built-in/MCP 或模型参数不能提供或覆盖它。效果事实不授予权限，不携带 credential 或推测价格，也不改变[产品需求](requirements.md#55-审批与输入)定义的自动评审资格。

审核上下文仅包含当次用户意图、最近一段 Agent 文字、工具名、参数和工作目录；超限拒绝而不截断。Product 在发送前脱敏已知 credential，并按 JSON 解码后的字符串处理转义值；敏感 key、无法可靠投影的 MCP/host 参数及其他缺失证据回到人工。上下文和原始参数仅存在于有界内存，用完清零，不进入日志或历史。策略引用、lifecycle 注释不进入模型请求。建议理由经过 projector 脱敏后才进入 `answered_by=user|reviewer` 和 nullable `review_reason` 审计，取消记录没有决定来源；旧合法历史未带来源时仍按原用户决定恢复。Completion 生命周期由[Completion 架构](completion-architecture.md#6-取消与生命周期)定义；模型判断不是安全边界。

准备与提交均在 Host 主线程经过 Task authority。结果接纳必须精确匹配 Task、Run、generation、binding、Workspace epoch、route、request、policy 与评审 generation，并重新确认当前 Workspace authorization 和当次 `responses[]`。`allow_once` 只映射 `allow_once`，`deny` 只映射 `deny_once`；其他建议、失败、取消、超时、容量或准备不足均 settle 为人工，不重试同一请求，不使原 Core request 过期。人工与自动共用既有 prepare/deliver 入口，谁先被 Host 接纳谁生效；人工 prepare 立即使旧评审失效。自动 candidate 必须 confirmed durable commit 后才能 deliver，失败或 outcome unknown 回滚并保留人工等待，不沿用人工决定的 best-effort 保存路径。
人工回答入口的前置生命周期同步不得先接纳自动评审结果；有效人工回答通过当前 Task/Run/request 与当次 choice 校验后，在 Task prepare 中使对应评审失效。过期、非法或无法校验的人工响应不能撤销有效评审；已经先被 Host 提交的自动决定也不能被后来回答撤回。
投递失败后按现有事务回滚并重新提交该观察。Task 状态失效不等于 worker 已静止：Control 必须取消、等待 Completion/watchdog 与 worker 收口后才能释放准备数据和 credential，不能用 Task 删除阻塞或遗留 lease 代替该责任。

Application 关闭 Product 路径时必须遵守以下顺序：

1. 停止 Bridge ingress、新 Product admission、Schedule/MCP timer 与会产生新工作的 coordinator；
2. 停止独立 execution lane，并在主线程 drain completion、重新授权、脱敏且 settle responder 恰好一次；
3. 取消 queued/running Product jobs，join Executor，并等待 Task access、worker reference 与 aggregate completion quiescent；
4. 停止 Product 对 Agent 的新调用，再由 Agent 执行其完整 Runtime shutdown；
5. 完成最终 event drain 与 lifecycle sync，才释放残留 attachment、execution authority、aggregate 和 Product Control；
6. Models 停止新管理命令，cancel/join Metask catalog与模型测试 worker并释放 credential vault port；Account committed shutdown effect取消自身 timer、join attempt worker并清空 Account 平台 port；随后 Application 才释放两个彼此独立的平台 binding。

Agent Session、callback、UI request、event pump、close race、错误映射和 Agent Runtime 内部销毁顺序只由[AgentCore 集成契约](agentcore-integration.md)定义；Product/Application 不得拆开或替代 Agent-owned shutdown fence。

### 3.1 产品视图与执行推进

Product aggregate 独占产品事实、局部事务和执行资格。Product Control 投影只读取已经提交的事实，生成用于展示的摘要、页面上下文、当前 Task 和有界历史，不接纳 Run、不推进 lifecycle、不提交历史。Bridge 可达的版本、Workspace、Task、catalog、permission 与视图查询适用同一约束。Application 按明确 command、Agent event、worker completion 和 lifecycle wake 安排业务推进；有无 Renderer、读频率、分块和重试不得改变必要的推进路径。

投影按稳定产品 identity 和内容版本维护有界编码缓存。无关 Task 的正文不参与局部展示更新；terminal Run 的脱敏、coverage 或关联事实变化仍须使对应块失效。缓存只保存可重建的产品视图，不成为产品事实或持久化的第二 owner。容量不足时淘汰可重建块，不能缩小产品限制、丢失历史访问能力或把合格数据永久变成不可显示。

大视图读取使用 Product-owned 的单个有界冻结计划。begin 冻结同一提交的 owned 事实；工具展示解析以有界准备步消费冻结输入，不能推进业务或重新采样 aggregate。准备期的原始工具 JSON 与 credential 副本仅在 Host 临时 owner 内存在，完成或取消即清除；两者不得进入缓存、Bridge payload 或 worker。ready 计划只持已脱敏的 owned 内容、结构和内容版本，按编码预算逐步写入调用期借用的运输 buffer。工具展示的同步与分步消费共用唯一 formatter；解析、脱敏、JSON 编码和缓存回填仍由 Product 拥有，Bridge 只承运准备状态、读取 identity 和 bytes，Renderer 只等待并渲染。版本比较基于精确的脱敏源内容，不能为取得长度或确认稳定版本而先同步编码完整正文；缓存只接纳源内容仍有效的结果。普通业务更新可以使当前缓存失效，但不会把已冻结读取拼接成多个提交；安全失效、读取替换和关闭则直接撤销计划。

安全代次归 Product Control。安装、替换或释放 credential 仍须遵守原地清洗与 durable commit 协议；清洗本身不推进代次。已知凭据按精确字节值及现有 Host owner 判定，包含与对话来源独立的 Account access token；Account 仅通过主线程调用期 visitor 提供脱敏检查或有界冻结读取副本，Product 不长期保留其 token，Account 授权代次提交时撤销旧安全投影。重复取得或释放仍有其他 owner 持有的同值副本不改变安全边界，不额外建立长期凭据副本。真实凭据集合或执行安全 authority 变化使旧代次缓存和在途展示结果失效；即使外围 command 随后失败，也必须主动发布安全失效。缓存命中只在内容版本和安全代次均匹配时成立，新构建内容继续执行交付前的完整检查。Renderer 接收安全代次并清除过期缓存；它不持有 credential，也不执行脱敏。

主线程上的展示构建、编码、复制和分块处理必须满足[验证规范](validation.md#产品视图与执行隔离验收)的连续时间预算。首先使用有界范围与稳定块复用；只有测量表明仍超预算时，才引入有界分片或独立执行容量。异步投影不能持有 credential、Product Runtime 或可变 aggregate 指针，只接受 owned 数据或不可变输入；接纳结果前重新校验对象、连接、内容版本和安全代次。不能以编码已经移出主线程为由接受仍然超预算的脱敏操作。

持久化和 credential 事务仍由原 owner 决定，展示缓存不改变持久化格式或 commit 语义。两类操作的主线程成本必须与投影成本分开测量；若任一同步路径在展示压力下使 event pump 超时或改变 Run 终态，仍属于执行隔离验收的阻塞项，不得通过放宽队列、超时或跳过安全检查掩盖。

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

#### 展示位置事实

Task 主线程独占用户消息接收与可信生成图片引用接纳的单调展示序号。消息 submission 保存原 Run/输出槽位锚点及可空展示序号；生成图片引用保存可空 `{ after_output_count, presentation_order }`。消息在接收时、图片在首次安全投影接纳时取号，提交前验证完整候选并一起安装引用与位置。采纳、转入、重复投影、预览重试及相同引用刷新保留位置，新结果使用独立 identity。展示序号不复用工具活动 order，不证明执行或回复因果。

高水位随 Task 保存，裁剪不降低；序号允许空洞，已提交记录的序号不回用，溢出或非法关系明确失败。图片引用、锚点和高水位进入同一历史快照；保存失败沿用既有健康及 outcome_unknown，不扩展执行幂等保证。锚点按容量校验，允许撤回后超过现存输出数。

canonical Task record 的 `presentation_format=1` 明确启用位置编码：`next_presentation_order` 必填；submission 及生成图片引用的 `presentation_state` 必须为 `anchored | legacy`。anchored 必须含合法位置，legacy 必须显式为空且仅表示受控读取的旧事实；新接收/生成记录只能写 anchored。旧 Task 无 format 时只按既有 canonical 旧字段受控读取为位置未知，下一次写回显式保留 legacy；新版缺字段或非法状态不得退作旧历史。保持原 framed store、损坏隔离、原 payload 保护与恢复机制，不伪造旧数据顺序。Renderer 展示规则由 [UI 设计规范](ui-design.md#72-agent-对话渲染机制) 唯一拥有。

插话 `transferred` 只表示输入已交给同一 Task 内真实存在且顺序更后的目标 Run，不表示原轮采纳或目标执行成功；必须保留 receipt，且不能携带原轮采纳活动锚点。其他状态不得关联转入目标。旧记录缺少可空转入关联时仅解释为没有转入事实，不推测目标；等待接续、失败原因和原文均为运行时事实，不由恢复重新激活。

追加消息的安全文本、identity、receipt sequence、采纳状态、真实采纳活动锚点及提交时的输出槽位锚点随所属 Run 持久化；不持久化可执行 payload。输出槽位锚点只数已闭合 commentary 及已分类回答或可安全投影的临时尾部（含脱敏占位），不把尚未提交的敏感后缀计入；它在同步提交前预留，接受或未知时保留，拒绝时释放，不随采纳状态变化。临时尾部可能被丢弃，因此锚点允许超过剩余输出段数，不能按当前正文长度拒绝。旧历史缺少消息数组解释为空；有追加消息的记录必须包含合法锚点，不兼容未部署的缺锚点记录，不引入迁移或位置推测。恢复将仍为 pending 的消息降为 unknown，仅供阅读，不提交给新 Session。Task 安全接收记录及 Run 输入保留逐条 operation 关联，用于响应丢失对账；不发布单槽结果，也不建立持久 ACK 或跨重启 exactly-once 承诺。重载、断连和导航不撤销 Core 已接受的输入，也不触发重发。

Product history 保存用户可观察且跨重启仍有意义的 Workspace、Task、用户消息、已提交 assistant 输出、Tool 结果、File Changes metadata/artifact reference、UI 决策、Run/compact terminal fact、execution provenance 与 checkpoint reference。完整产品范围以[产品需求](requirements.md)为准。

Durable Task record 与 runtime attachment 必须分离。durable record 不保存 live Agent Session、catalog lease、pointer、atomic、worker/control payload、credential 或 `closed` 产品终态；runtime attachment 线性拥有 Agent Binding、ExecutionConfig 与必要 lease 的唯一使用和归还责任。Task detach 或 replacement 必须先关闭并归还 live Binding，不能丢弃或复制所有权。

Task 的下一轮模型意图是可空的 `ModelRef` 与非零 selection revision，独立于已安装 binding 以及历史 Run 的 execution 事实。它只保存有界、有效 UTF-8、无控制字符的来源和模型 identity，不含 credential 或连接 authority。旧 Task frame 缺少该可选字段时保持未知意图，不能从当前全局默认选择推断来源；读写继续保留原 binding、Run 历史与 checkpoint。该附属记录在既有 framed history 内编码，不改变 frame identity 或替换历史存储。

Run 的 execution generation 与 protocol 是接纳时冻结的历史事实，同一 generation 必须使用同一 protocol。非终态 Run 及属于当前 Task generation 的 Run 必须与当前 binding protocol 一致；旧 generation 的终态 Run 可以使用不同 protocol，连接切换不得重写或隔离这些合法历史。

审批模式由 Task 当前 profile 与自动评审事实派生，连同非零 approval revision 随 Task 恢复；合法旧 metadata 缺少 revision 时从初始 revision 恢复，不重写历史 Run 的 profile。全局 default mode 独立持久化，缺少新字段的合法旧 metadata 从原 default profile 派生，缺少 Task 自动评审事实时保持人工。历史 Run 的 profile 可以不同于 Task 当前 profile，UI 审计按所属 Run 的 profile 与 interaction 校验，不能因当前模式变化丢弃合法旧决定。运行期 generation、当前评审 identity 和 in-flight job 不进入 durable history，恢复不得重放待决评审或审批。UI 历史只保存来源、typed permission 摘要与脱敏有界理由，不保存原始输入或模型输出；旧非取消 UI 决定缺少来源时按用户恢复，取消保持无来源。历史决定、理由和摘要本身不具有当前授权效力。

Run/compact 的 terminal result 由 Agent 以自包含事实返回，Product 在预留 record 中 no-fail、write-once 提交后才能通知、释放 worker reference 或推进后续事务。queued-before-execute 由 Product 生成独立的 pre-execution terminal fact；Agent Session snapshot 只描述 live lifecycle，不承担历史 terminal truth。

Run durable record 在 Product 接纳输入时至多一次记录 nullable wall-clock 提交时间。时钟不可用或旧 canonical record 缺少该字段时保持 null；恢复不得迁移、推断或用完成时间与加载时间补写。该事实只描述输入接纳，不承担 Agent 开始执行、排队耗时或事件时间线语义。

Run 接纳执行时可以保留 runtime-only 单调起点；Product 在完整 terminal event-drain barrier 首次形成正式终态时用同一单调时钟冻结 nullable 最终耗时，并随 Run durable history 持久化。该值包含排队、批准等待和重试，写入后不可修改；时钟不可用、回拨或旧 canonical record 缺少该字段时保持 null，恢复不得用提交/完成 wall-clock、Tool elapsed、加载时间或 Run 顺序推断补写。active Run 的当前耗时只从 runtime-only 起点采样，不进入 durable record。

Task 删除是跨持久化、checkpoint、event、Session 和 worker reference 的独立 Product 生命周期用例，不占用 active-operation 槽；其 `idle | deleting | failed` 状态只存在于当前 Runtime，不进入 durable Task record。删除无需归档，受理不改变原 archived；受理时取消等待输入与接续并失效待决审批，Product Control 通过既有 operation owner 请求停止，禁止新 admission。删除意图可以先进入 `deleting`，但只有相关 active operation、checkpoint、terminal event、Session access 和 worker reference 全部收口且 durable history commit 成功后才能物理移除 record。明确失败或结果不确定只使本次删除进入可诊断失败；用户可以重试删除。Task 已回到 open 且安全时，恢复归档或未归档 Task 的显式新消息、归档在接纳同一 mutation 中清除 failed，拒绝不清除；仍 closing 或结果未知不得借此绕过原事务 gate。删除意图不持久化，重启不自动继续；Task 的其他可用操作与整个 Workbench 不得因此冻结。

### 4.3 `workbench-history.store`

`<MetaWork data dir>/workbench/workbench-history.sqlite` 是 Workspace 与 Task 产品历史的唯一 canonical store。Application 在 restore 前取得进程级 OS writer lock，拥有具体 Storage Database 和文件生命周期；Product Control 拥有 schema、逐行增量提交、跨记录校验与健康状态。普通业务提交不得写回旧 framed store，不双写。所有借用和历史 worker 收口后才关闭 Database。

Run 的成果元数据只能由 Agent 已验证的独立 Host 回执登记；普通工具文字、文件引用和 File Changes 不构成成果。记录归属其 Task/Run 与 Workspace，只保存非零成果身份、Workspace 相对 locator、交付时的大小和 SHA-256，不保存文件字节或组件版本。相同身份与相同内容重复到达不增加记录，身份冲突或超出有界容量必须拒绝。locator 经过现有 credential sanitizer；被脱敏或截断的 locator 丧失文件操作 authority，写入历史时必须为空。恢复仍须重新检查 Workspace authority 与当前文件内容，历史元数据本身不授予读取权限。该附属集合随所属 Run 的 SQL 记录保存，旧记录缺少 `outputs` 时恢复为空；不得重放交付动作。记录随既有 Tool result durable boundary 提交，保存失败继续遵守本节的 best-effort health 语义。

成果文件操作由 Product Control 按 Task/Run 与成果身份解析当前可信记录，拒绝尚未退出删除事务的 Task、失效 Workspace 以及脱敏或含已知 credential 的 locator。进入异步文件工作前须复制根路径、相对 locator、交付摘要和大小、Workspace 身份及安全代次；不得借用 Task 内部指针。该 owned 输入只是一次操作的冻结事实，不是持续授权：在 worker 返回后、发布内容或执行系统动作前，必须重新核对 Task/Run/成果、Workspace 根与代次、locator、交付内容身份和安全代次。文件读取还须独立证明实际字节；两项检查不能互相代替，也不替代 Bridge connection/window 的有效性检查。当前字节校验消费 Application 冻结的文件读取能力，使用独立、懒启动且有界的 worker，不占 File Preview lane；校验结果只包含状态，不持有文件内容。请求期限、取消与 shutdown 都须先停止执行并观测物理静止，再由主线程释放 effect 和冻结输入。定位源文件只在当前读取字节与交付大小、摘要一致、当前 Product authority 通过且 Bridge 请求仍有效之后，在主线程通过 Application 注入的窄 effect 调用 Native SDK Runtime；读取校验、显示路径或先前 ready 结果不能单独触发定位。取消、断连或安全代次变化不得在 worker 返回后补发系统动作。另存由 Application 的系统保存对话框选择目标，并返回只持有冻结源身份及所选目标的 owned effect；Product 和 Renderer 不接收该目标路径。worker 将实际读取的同一份字节校验后暂存，再等待主线程核对当前 Product authority 和 Bridge 请求；主线程的一次性发布决定是保存提交点。提交前撤销会唤醒 worker 丢弃，提交后取消须被拒绝，shutdown 等待已提交的发布完成。保存终态据实际 I/O 返回，不因之后的 Task、连接或安全代次变化虚构 cancelled；该结果不授予未来读取权限。失败保留已有目标，暂存清理失败必须单独报告。

正式 SQL 不存在时，单向导入旧 canonical framed store，保留合法事实、只读 payload、无法解释的完整记录及身份高水位；不读取更早的 JSON envelope 或开发期废弃格式。导入在同目录临时库中完成，经完整 loader 校验、WAL TRUNCATE 和连接关闭后才 rename 发布。原 framed 文件保留为受管迁移材料，仅安全维护可以清洗它。正式 SQL 一旦存在就不退回旧 store。缺 canonical 但存在恢复证据不是首次启动；未知 schema 版本不得保存、quarantine 或替换正式库，即使显式恢复也必须拒绝。损坏或不可读的当前版本历史不自动覆盖，沿既有显式恢复入口保全原件和现存 DB/WAL/SHM 组件，再发布经验证的关闭候选。

非健康 history store 的显式 recovery 必须校验全局 revision，并由 Product 编码当前内存 Workspace/Task snapshot；Application 只能把当前 canonical 文件改名为唯一 quarantine artifact，再通过既有 durable atomic replace 安装该 candidate。读取/codec 失败时当前内存为空，因此形成 canonical empty history；write failure 或 outcome unknown 时保存当前进程仍持有的有效历史。失败不得清空内存或删除原文件，outcome unknown 继续发布 typed health；只有 committed 才恢复 ready。Renderer 不接触文件名、路径或 bytes，quarantine artifact 不进入 snapshot、日志或自动清理。

交互式 Product Task mutation 以内存 Runtime 为当前进程真源，持久化是 best-effort projection；保存失败不得回滚已经接纳的新建、Run、模型选择、权限响应、重命名、归档、取消或 Workspace 导航 mutation。Schedule occurrence 是独立的无人值守边界：Product Control 必须为其 Task create、命名与 Run intent 注入 required durable effect，任一步未可靠提交都拒绝本次 occurrence，Schedule 按既有 transaction 进入可诊断状态，但不得冻结其他 Product Task。若 required commit 明确失败，Control 回滚候选并删除仍可证明未发布的 Automatic Workspace 空目录；若结果不确定，Control 同样回滚内存 Task/Run/Workspace 候选但必须保留物理目录，因为 canonical store 可能已经引用它。两种拒绝都保持 occurrence `task_id = 0`，不得伪造 interrupted Run 或 terminal cause。Task 物理删除仍遵守 §4.2 的 commit-before-release 边界。

completion receipt 是上述 best-effort Task projection 的低频视图事实。acknowledgement 只修改当前内存 Task 并发布 revision，不得为每个前台完成额外强制重写完整 history store；它随下一次既有 Task durable commit 或 clean shutdown 的最终 commit 合并写入。异常强杀可以丢失尚未进入 durable boundary 的最后一条 receipt，但不得损坏或回滚 Task/Run 历史。旧 Task record 缺少 receipt 字段时，必须在恢复出 canonical Task 并完成无 live owner 的 interrupted normalization 后，把当时最新 terminal `completed` Run 初始化为已读；当前 writer 始终写出明确数字，避免升级后把全部历史完成误报为新提醒。

旧 framed 导入源仍遵守其原有读取边界，正式 SQL 不继承整库 16 MiB 上限。普通提交通过 SQL 原子事务确认，区分 `committed | failed | outcome_unknown`；临时候选仅用于首次导入及显式恢复，关闭后同目录发布。具体额度、帧布局与 SQL 字段由唯一实现与测试拥有，不在本文镜像。

Host 重启从通过校验的 store 重建 durable history 和 detached attachment。没有 live owner 的 non-terminal Run/compact 保守收口为 interrupted，不重放输入、工具、permission 或结果不确定 mutation；所有在进程终止时仍为 `pending` 的 Run/compact 都原子转为 `excluded`，terminal operation 保留原 phase/outcome，non-terminal operation 再收口为 interrupted。其 File Changes `collecting` 若存在必须收口为 `incomplete` 并保留已记录项。旧历史缺少 Run 提交时间或 File Changes 字段时恢复为 `null`，不能伪造时间或空观测。未完成 Tool 不进入恢复 projection，已经 durable 完成的 Tool result 保留。

#### 4.3.1 History schema

Product Control 统一拥有同一个 history 数据库的结构和有序迁移清单，业务 aggregate 不独立执行迁移。schema 是无状态模块，直接产出 Storage 的 `sql.Migration`；版本从清单推导，新建与升级共用同一条迁移链。清单在编译期校验连续版本和有效 UTF-8/LF 字节，已成为需保留数据库身份的历史迁移不得原地改写。唯一建表 SQL 拥有精确列、约束与索引定义，文档不维护第二份字段表。

历史 SQL 表达保留原有完整 u64、可空状态、数组顺序与已有身份关系。独立表须有当前查询、更新或容量收益；随所属记录整体读写的有界附属集合使用 typed JSON，单个可选附属记录可以使用全空或全有的字段组。关系列中的 u64 用等长 big-endian BLOB 表达，自由字符串用 UTF-8 字节 BLOB 保留现有 codec 接受的 NUL，有限 tag 与有界嵌套 JSON 使用 TEXT。JSON 直接按 Product wire 类型编码和解码，u64 不经浮点中转，数组顺序与转义字符串必须无损。SHA-256 引用以 32 字节 BLOB 存储并与原有小写 hex 精确转换。

DDL 负责关系列的非空、存储类型、局部唯一性与父子关系；JSON 内的数量、字段、唯一性、引用以及跨记录语义由 Product 校验，不能把 SQL 写入成功视作历史有效。Product 继续校验 UTF-8 与字节预算，加载还须覆盖原编码器的恢复失败记录限制和实际 Task 恢复中的 checkpoint 校验，不能仅凭局部 candidate 校验或字段往返宣称可恢复。合并或移除物理表不能丢失恢复诊断，历史权限仍不具有当前授权效力。

schema 迁移仅建立空业务表，不建立默认 Runtime 状态。迁移完成不等于 history ready；loader 必须验证业务状态和完整关系，不能把已有业务记录但缺少根状态的库当作空新库。`MigrationMismatch`、`VersionUnknown` 与恢复资格归 Product Control，Application 只转交开库结果和执行被授权的文件 effect；不能自动清空、重建或把一次主文件 rename 当作完整 WAL 恢复。

生产使用单个串行写入者。每次提交将已确认行摘要与完整候选事实比较，只写变化及删除；此前失败、TaskBusy 跳过和被动已读回执都必须随后续候选补齐，只有整个候选被确认才恢复 ready。共享业务原子组不拆分，超出 Storage 单事务额度时明确失败。最后提交 witness 与变化同事务保存；结果不确定时保留精确候选、重开并读回 witness，再完成 Storage 同步确认，不重放业务 effect。凭据首次获知时清洗当前及保留历史，清除旧 WAL 版本；重复借用不重复触发维护，未完成清洗的有界凭据副本不得提前释放。历史写入 capability 冻结凭据安全代次；首次获知凭据后，旧代次候选即使尚未派发、且凭据后来已释放，也不得再写入。未确认事务只能读回原 witness，不能借换代重放；冻结缓冲释放时清零。历史 Task 数不消耗 Session 名额，Task、Run 和 Compact 集合按需增长；借用中的记录地址必须稳定，Run/Compact 仅在全部 worker lease 静止后移动容器。历史额度与 Renderer 单次快照、catalog 额度分开，达到历史额度保留既有历史并拒绝新增占用，不删除旧记录。

### 4.4 File Changes artifact transaction

`<MetaWork data dir>/workbench/file-change-blobs/` 是 Product Task 专用的 credential-safe unified-diff store，不是 checkpoint 目录、当前 Workspace 镜像或通用 Artifact Framework。Application 持有进程级 writer lock 和 store/lane 生命周期；Product Task history 只保存 Task、run generation、change order、size 与 SHA-256 identity，不保存完整 diff 或物理路径。

写入先完成 no-follow、resolve-beneath、私有权限、文件 sync 与同目录原子 rename，成功 completion 重新校验 owner 后才把 reference 安装进 history。队列满、diff/record/path/projection 容量不足、存储失败或 shutdown 只使现有 metadata 保留、diff unavailable 且 observation 单调变成 incomplete；这些补充审查失败不得产生 generic consumer rejection、终止 Session 或改写 Run outcome。

Task 删除必须等该 Task 的 FileChange read/write job 及 completion 被 owner 收口，才能释放 artifact 目录；其他 Task 的 job 不阻止它。

可信启动只在 Task history health 为 ready 时根据完整 reference 集合删除临时文件和明确 orphan；history 不可用、degraded 或不可信时禁止 orphan cleanup。读取必须重新校验 identity、size、digest 和 UTF-8，missing/corrupt 作为 typed unavailable 结果返回。Task record 只有在 durable history 删除提交成功后才删除对应 artifact 目录；删除期间迟到的异步成功写入因无 Product owner 而立即回收。

### 4.5 Checkpoint transaction

AgentCore checkpoint blob 与 Product checkpoint record 是两个提交边界。每个成功收口且 Session 可复用的 Run/compact 可以在 terminal product fact 发布后导出 checkpoint；blob 必须先 durable commit，随后 Product 才能把引用它的 checkpoint record 提交进 Task history。

Run/compact 的 durable coverage 精确取 `pending | covered | excluded`。`pending` 表示当前 live attachment 仍可能把 operation 纳入后续 checkpoint；`covered` 表示 canonical checkpoint 已知包含它；`excluded` 表示记录保留在 Product history，但不属于恢复后的 Conversation。checkpoint record commit 与其 coverage overlay 是一个 Product transaction：overlay 后 checkpoint 的 last ids 必须分别等于最大 covered Run/compact id，且不能剩余 pending；不满足即拒绝 commit 并记录 dependency contract failure。`excluded` 不得转回 `covered`，跨 attachment 也不存在 pending 继承。

checkpoint record 只保存：

- blob 的 Task/generation/size/digest identity；
- AgentCore description 中恢复消费者需要的无 secret Session facts；
- Product 提交时的最新 terminal 与 binding anchor。

它不保存 credential、catalog handle、permission rule、raw Conversation、临时 export metrics 或 live Session identity。

新 blob 明确成功但 history record 明确失败时，blob 可以暂时成为孤儿；record commit outcome unknown 时必须把相关 blob 当作可能的 orphan 保留，但不能冻结 Product Task，后续完整 history commit 可以建立新的 canonical snapshot。可信启动先校验 record 引用 blob 的 identity，再清除明确失效的 record，最后反向删除无 record 的 orphan。Product history degraded 或 checkpoint store 不可信时不得执行孤儿清理，以免删除未知 Task 的有效数据。

### 4.6 Conversation attachment recovery

Conversation recovery 是 detached Task 的 attachment 重建事务，不是 transcript 重放、Task 克隆或新的 Product owner。Product 分别维护 Product history 高水位、Conversation covered 前沿和 checkpoint 前沿，三者不得混为“最新终态”。checkpoint restore 资格必须同时证明：

- source Task、binding、checkpoint 与 terminal anchor 未变化；
- Workspace identity、kind、epoch、root、authorization 与 Automatic owner 精确；
- target ExecutionConfig 能够承载所选模型，且其 generation 在 start 到 commit 期间保持不变；已有显式模型意图时按精确来源解析完整配置，允许更换 protocol，不依赖全局默认；旧记录没有来源意图时仍按现有恢复资格匹配原模型与 protocol，不推断历史来源；
- persistence、checkpoint store 与 Agent Runtime 可用；
- Task 未归档、删除、运行其他 operation、replacement 或 shutdown；
- 当前 recovery attempt 和 poison 状态允许进入。

checkpoint 必须与 covered 前沿精确相等，并且不能存在 pending operation；`checkpoint <= Product history` 不是合法替代。checkpoint 之后允许存在且仅允许存在连续的 excluded 尾部。若历史中出现晚于 checkpoint 的 covered operation、checkpoint 前沿不是最大 covered id、anchor 未 covered/terminal 或存在 pending，恢复必须拒绝。所有新 Session 的 Run/compact allocator 都以各自 Product operation history 高水位为 floor，UI request allocator 则以 durable UI history 高水位为独立 floor；restore expectation 仍只使用 checkpoint 自己的精确 Run/compact ids，任何 allocation floor 都不得替代 expectation。

唯一无 checkpoint 恢复例外是：Task 没有 checkpoint record、covered 前沿均为零且没有 pending operation。此时 Product 可以在原 Task 上 fresh attach 空 Conversation，以完整 Product operation history 和 durable UI history 高水位初始化各自 allocator；全部 excluded 历史继续可见，不进入新上下文，也不自动重放。只要存在 covered 历史，checkpoint 缺失、损坏或 store 不可用都必须 fail closed。

历史 execution generation 只证明历史 Run 使用过哪个 execution，不是恢复当前 credential 的句柄，也不要求等于 target generation。Skill、MCP、Permission 和 projection continuity 是恢复后的可选能力状态，不是 Conversation 恢复资格；AgentCore 合法返回 degraded Session 时，Product 接受已恢复 Conversation，并让不可重建 authority 保持安全失效。

detached Task 的显式模型意图沿同一恢复事务提交：冻结该来源的当前 authority，先按旧 checkpoint 的模型 expectation 恢复，模型改变时设置目标模型并导出对应 checkpoint，确认实际 model/protocol/binding 后才能安装。原模型未变时可沿用原 checkpoint，不能为冷恢复额外制造新的覆盖事实。没有原 live attachment 时，不构造原连接 credential 或进程前的 Skill/MCP 恢复输入，也不执行原配置回退；失败保持原 Task、意图和历史，等待明确重试。目标来源或模型已失效时不得借用全局默认。无 covered 历史且没有 checkpoint 的 Task 仍可走既有 fresh attach 例外，并使用所选完整配置。

用户显式发起恢复后，Product 冻结完整 source/target authority 并提交 bounded recovery job。checkpoint restore 与上述空 Conversation fresh attach 使用同一恢复执行与提交边界；job 不保存 Task/Workspace 指针，不查询 Product Skill，不构造 MCP Selection，也不取得 durable permission rule，只按不可变输入验证 checkpoint source 并调用 Agent restore，或创建符合无 checkpoint 例外的空 Session。I/O、Agent Runtime、capacity、cancellation 与 typed AgentCore refusal 必须作为 attempt 结果返回；排队取消或一次失败结束本次 attempt，不得隐式重试或重放历史。

成功 candidate 回到主线程后必须再次校验全部 source/target token、attachment、archive/removal、replacement 与 shutdown。持久 adoption 前失效的 candidate 只销毁。若 target generation 与 durable binding 不同，主线程只编码有界、无 secret 的候选历史，由既有共享 bounded history writer 执行一次 durable adoption transaction，同时推进 Task binding、binding epoch 与存在的 checkpoint anchor；保存待决时，旧内存 binding 不变，candidate 与恢复 lease 保留，不能发布 attachment。确认提交后先接受 canonical binding，再重新校验 Session 安装资格；外部 authority 在保存期间失效时丢弃 Session，但不得回滚或覆盖已确认的 binding。明确失败结束 attempt 并拒绝 candidate；结果未知保留 exact 候选历史、Session 与 lease，冻结其他 history write/recovery，只有显式恢复动作可以排队执行不写入、不 quarantine 的 canonical 读回。读回仍未知或取消不得丢弃候选、隐式重试或推测结果；确认 candidate 或旧 canonical 后才分别接受或拒绝 adoption。事务期间的独立产品事实由后续共享 writer 补齐，补写失败不得由生命周期轮询自动重试。

被拒绝的恢复 candidate 必须线性转交同一有界 Session close/release owner，不得在主线程同步调用 Agent destroy，也不得短暂发布可执行 attachment。转交前脱敏产品事实并清除 candidate 的 Host credential 副本，关闭 owner 只保留资源释放所需 metadata 和 Binding。它没有已接纳的 Run，可以在恢复 lease 释放后直接进入异步关闭；关闭成功才 detach，关闭失败保留真实 closing/attached owner、诊断和不可执行状态。即使失败报告为 reusable，也不能将这个未获安装资格的 candidate 变成可执行 attachment；生命周期轮询不得自动重试，既有显式 Host close 动作仍可安全重试。

同进程显式模型意图要求更换连接或 protocol 时，沿本节同一 operation、恢复 worker、history writer 与关闭 owner 执行重绑定。原 attachment 必须 idle 且事件、worker 和权限 mutation 静止；先冻结完整目标配置、原配置和实际能力输入，导出并确认基线 checkpoint，才能关闭并释放原 Session。此时目标 protocol 不必等于原 protocol，但 checkpoint 的模型与操作前沿 expectation 仍使用原始精确事实；恢复后调用官方 `setModel`，再导出与目标实际模型一致的 checkpoint。不得同时保留两个相同逻辑 Session identity 的 live handle，或发送中间模型请求。

重绑定容量投影可以计入随后释放的当前 Task owned route；Runtime 必须核验该 route 仍由自身持有，并保持 shutdown、Core availability 与 MCP refresh 屏障。该观察不预留槽位，也不替代释放旧 Session 后的实际 restore admission；并发消费者占用槽位时仍明确失败。detached 恢复没有可释放的 owned route，继续要求空闲容量；poisoned 或 closing attachment 不能因此投影成可重绑定。

Skill 的原 pinned 投影留在 Task attachment，由主线程管理；worker 只接收 Agent-owned 恢复输入。原 Skill grant、MCP selector/来源与实际 permission mode、shell policy、interaction 是恢复上限，还须与 Product 当前 Workspace、来源开关和工具授权求交，发布前再次核验。选择 revision、Models source/catalog authority、审批 revision、Workspace 或生命周期变化使目标 candidate 失去安装资格；不能采用更新的全局能力列表来补齐或扩大原 Task。

目标确认前失败时，保留原模型意图和待发送输入。原 Session 已释放的，候选必须先经普通关闭 owner 清理，才允许使用原配置、同一基线和当前授权上限执行至多一次恢复；失败后保持真实 detached/closing 状态。回退不接纳 Run、不回放审批或用户输入，也不将原模型伪装成已安装的目标。确认目标 binding 后，合法排队输入的 anchor 在同一 Task 事务内随 epoch 推进；失败且未确认 binding 时不推进 anchor。若 authority 在 durable commit 期间变化，仍须先接受已确认的 canonical binding，再清理候选并独立提交必要的原配置恢复，不能倒退已确认的 epoch。

关闭必须接纳已确认的 durable binding，即使不再安装 Session；未知结果不能因关闭而重写历史或启动读回。释放 candidate 和 lease 后仍保留未知事务屏障，下一次启动从实际 canonical binding/anchor 恢复。进程若在 durable adoption 后、attachment install 前退出，下次启动同样使用已推进的 binding/anchor，不改写历史 Run provenance。

历史 Task 不占用永久 Session 名额。Session 容量不足时，Product 可以按近期使用顺序选择可恢复且完全静止的 attachment，沿既有异步 close/release owner 释放；不得取消 active operation、输入接续、权限事务、尚未消费的事件或 worker/artifact 引用来腾出名额。释放前保留同进程的 Skill/MCP 能力上限与目录投影，恢复沿现有 authority 收窄和候选提交边界，不保留执行 credential、SDK Session handle 或额外的持久化恢复事实。关闭待决只拒绝本次 admission，调用方显式重试，不接纳虚假的 Task/attempt，也不把 Session 压力映射为历史 Task 容量；关闭失败不得自动重试。未具备精确 checkpoint 或合法空 Conversation 恢复条件的 attachment 不参与压力回收。

graceful close/shutdown 必须先停止 admission，对已进入 AgentCore 的 operation 请求终止并等待真实 terminal/event drain，再等待 checkpoint postprocess 与全部 worker lease settled；只有此后才能把剩余 pending 标为 excluded、持久化最终历史并开始 Session close/release。checkpoint commit 与 pending exclusion 不得并发交错。已提交 history 但尚未进入 Core 的失败直接归为 excluded；尚未提交 history 的 prepared operation 不产生可排除记录。

Agent terminal fact 将当前 attachment 标记为 poisoned 后，Product 必须停止该 Session 的新 admission，并在 terminal event、checkpoint postprocess、Session access 与全部 worker lease 收口后自动进入同一 close/release 路径。只有 Session 已成功 close、Agent Runtime slot 已 release 且 Product 仍持有完整 owner 事实时，Task 才能 detach，并按本节的 checkpoint restore 或 fresh attach 规则继续；close 失败必须保留真实的 attached/closing attachment、execution authority 与资源 owner，不得伪装 detached、开放 recovery 或自动形成无界重试循环。已获接纳 attachment 的可复用 close failure 可以恢复原 admission；poisoned/closing failure 继续不可用，直到已有显式生命周期动作安全重试。

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

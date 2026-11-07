# MetaWork Product 架构

本文定义 Product 内部 owner、跨 owner 与跨 aggregate 事务、并发、生命周期、持久化和恢复、Product-owned 稳定交换 artifact，以及 Product Control 与相邻 Agent 执行边界的协作。它不定义用户可观察产品行为、Account 内部状态机、Renderer Bridge wire、AgentCore ABI、源码 leaf graph 或当前验证状态；这些内容分别以[产品需求](requirements.md)、[Account 架构](account-architecture.md)、[Renderer Bridge 合同](renderer-bridge-contract.md)、[AgentCore 集成契约](agentcore-integration.md)、[工程结构与所有权](project-structure.md)和[验证规范](validation.md)为准。顶层进程、故障域和安全边界见[高层架构](architecture.md)。

## 1. Owner 与事务模型

Product 由两个 named owner 组成，跨 owner 用例由对应的 Application coordinator 编排：

- Account 只拥有 Metask OAuth identity、access/refresh credential、authorization generation 及其内部事务与恢复；
- Product Control 拥有 Models aggregate、执行 generation 分配、Task-owned binding、实际 credential 的 Schedule scrub、Workspace、Task、Skill、MCP、共享 Executor、跨 aggregate admission、canonical projection、revision、历史与关闭顺序；Models 拥有来源、目录、纯起始偏好与精确配置解析，不持有进程级 active default execution。

Agent 位于 Product 之外，拥有 MetaWork 对 AgentCore Runtime、Session、Conversation、callback、event pump 与 terminal execution fact 的集成生命周期。Product Control 只调用 Agent 的公共执行能力，不管理 Agent Runtime 生命周期、不读取其内部状态，也不借 Agent 获取通用 I/O。Application 创建和关闭 Agent、安排主线程 wake，并协调 Account 与 Product Control；它不持有领域运行状态，也不独立决定这些 owner 的 policy。

Application 必须分别组装 Account coordinator 与 Models coordinator。前者只编排 Account Runtime terminal commit；后者只取得 Account 的窄 authorization lease，并绑定 Models Metask catalog worker、credential vault、Agent-owned model probe 与 Models 管理生命周期。Account commit 后，Application 先发布 Account fact，再通知 Models observer；observer 只能请求当次 lease、查询无 secret 的当次授权证明或声明授权不可用，不能读取 Account 内部 token owner或把 Models 结果写回 Account。用户在桌面 Renderer 中显式填写的 Custom Provider API Key 只经专用 create/replace typed command 调用期转交 Models credential mutation；Bridge 不保留副本，Models 立即将其写入 credential vault，canonical metadata、projection、result、event、日志和历史均不得包含该值。Models 来源提交、实际 credential 的 Schedule scrub 和 Task-owned execution 安装属于 Product Control 内部事务，不得由 Application coordinator 重新拼装。

Models、Workspace、Task、Schedule、Skill、MCP 与 Update 是 Product Control 持有的 aggregate，不形成新的顶层 Product owner。各 aggregate 独占自身状态机、局部事务与持久化 policy；Product Control 只拥有必须同时观察多个 aggregate、execution、publication 或生命周期事实的不变量，不能把局部 policy 重新吸收到组合层。

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
→ Models commits provider catalog and source authority
→ explicit Task/Schedule target resolves one owned execution candidate
→ Agent Session consumption
```

Models 可以独立于全局默认值，按精确 `ModelRef` 与预期 source/catalog generation 解析完整 owned execution candidate。protocol 与 endpoint 只取目标来源的声明，Custom Provider 还必须有当前 source generation 的 readiness proof；来源、目录、模型或 credential 不可用时明确失败，不回退到默认值。解析不修改起始偏好或 Task 意图，已交付 candidate 不受后续目录或 credential 状态变更改写。Task 等消费者的操作资格与安装事务仍由 Product Control 所有。

Custom Provider execution 的数据流为：

```text
Renderer password form → typed Bridge create/replace → Models credential mutation
→ Models credential vault + source registry
→ explicit Task/Schedule target resolves one owned execution candidate
→ Agent Session consumption
```

两条来源最终都必须形成同一份显式 protocol、endpoint、model、credential、source generation 与 Product binding generation。Models 解析 source 时产生不含 Product generation 的 `OwnedSourceCandidate`；只有 Product Control 可以分配 binding generation 并将其转成 `ExecutionConfig`。Metask source id 固定为 `metask`；Models 按目标模型 `capabilities.endpoints` 中明确 `supported = true` 的端点选择 protocol，固定优先级为 `messages → anthropic_messages`、`responses → openai_responses`、`chat_completions → openai_chat_completions`。缺失、null、false 或只有 status 声明的端点不参与选择；端点内部 input/output 不作为第二套能力判定。所选 protocol 分别绑定固定的 `https://www.metask-ai.com/v1/messages`、`/v1/responses`、`/v1/chat/completions` URL；不按模型名猜测、不因执行失败自动换协议重发。目录与调用 credential 均来自当前 OAuth authorization lease；Custom Provider source id 为稳定 Provider id。`ModelRef = source_id + model_id` 是模型身份，display name 永远不是 identity。source generation、selection revision、catalog generation、provider revision 与 Product binding generation是不同轴，不能互相替代或假设有序。

同一 Metask catalog 请求和有界解析同时分类对话与生图用途，共享目录 owner、快照和刷新生命周期，不建立第二目录 worker。对话候选排除明确支持 `images_generations` 或 `videos` 的成员；生图候选只要求 `capabilities.endpoints.images_generations.supported == true`，混合声明仍只进入生图用途。缺失、null、false、名称、旧 alias 或 `output.image` 都不能补授生图资格。生图成员不要求或伪装成对话 protocol。两类成员共用总量上限和严格已知字段校验；Renderer 只取得对话候选，对话候选为空不等于图片能力不可用。目录声明只表示服务能力，不保证特定返回格式或生成成功。

Task attachment 和后台消费者各自持有所需 owned copy；Session、恢复、测试和标题使用已解析完整配置，不按厂商、名称或 source id 猜测 protocol。Task model intent 可保存无 secret source id；credential locator 不进入历史。

Custom Provider 使用显式的 `openai_responses | openai_chat_completions | anthropic_messages | gemini_native` protocol。前三者要求 endpoint path 分别以 `/responses`、`/chat/completions`、`/v1/messages` 结尾，从而保留官方 API 所需的版本或产品前缀；Gemini Native 使用由消费者追加 model 与 operation path 的 base URL。自定义表单对前三种协议直接接收并提交完整 endpoint，不自动补路径；Renderer 仅按 URL path 的明确协议后缀确定待提交的 protocol，无效地址阻止提交，有效服务根地址只提供 Gemini Native 明确确认；Host 仍独立校验声明与路径，不按厂商、域名或失败请求猜测与切换；Gemini Native 则明确接收服务根地址，由执行消费者生成模型路径；内置 DeepSeek、Kimi、MiniMax 与智谱 GLM 模板直接提供已复核的官方 endpoint。Host 仍独立规范化并严格校验 scheme、host、path、长度和控制字符，Renderer 不能绕过该校验或把 query credential 注入 Run。当前不做 model discovery；Models 原子管理有界的 custom model definition 集合。新建 Provider 可以在 credential 已安全保存后以空集合处于 `configuring`，不能解析、测试或成为默认来源；create 可以携带首个模型；Models 在 credential effect 前校验完整 Provider 与模型输入，并在同一最终 metadata candidate 中持久化两者，不暴露只完成一半的配置。未携带模型的公开 create 仍允许空集合，后续模型由 add mutation 加入；删除最后一个模型时移除该来源，保留可能已失效的起始偏好身份，在同一 metadata candidate 中持久排队凭据删除，由既有 credential cleanup 收口；不会重新保留为空 Provider。创建不建立 readiness 或默认选择。桌面每次添加模型都创建独立来源及独立 credential slot，不复用已有 Provider；厂商预设 identity 与 protocol/endpoint 不是来源唯一键，同一厂商或 endpoint 的多份配置按稳定 source id 隔离，解码与编辑遵守同一规则。内置模板还提供 Host-owned 官方模型 ID 预设，只是填写建议，不替代实时目录或执行资格。每个成员使用完整 `ModelRef`，保存 nullable capability/token metadata及其 `unknown | user_declared | provider_declared | runtime_verified` provenance。用户提交的声明只能标记为 `user_declared`，一次连通性 probe 不能把未验证的 capability metadata升级为 `runtime_verified`。

每个 custom model 的 readiness proof 精确绑定当前 source generation，latest probe status与 readiness分离：成功 probe建立 proof，随后对同一 authority 的失败或中断重测只更新 latest status；endpoint、protocol或credential改变会生成新 source generation并清除该 Provider 全部旧 proof。普通 model metadata add/replace/remove只推进 provider revision和catalog generation，不自动 probe或设为默认；identity 被替换或删除时保留起始偏好身份，不查询或改写消费方。

Models registry 与 Account identity 独立。不同 Provider 即使 credential 相同也保持不同 Provider id；更新名称、endpoint、protocol、credential 或模型保留 Provider id，但影响 source authority 的变化产生新的 source generation。首次成功的 Agent-owned one-shot Completion test 使当前 generation ready；失败重测只更新 latest test status，不撤销已 ready generation或已交付 binding。Models 的 Provider edit/delete 不查询 Task/Session/Run 等消费者，也不以 `execution_in_use` 拒绝；后续执行按自身显式目标重新校验来源，既有消费者保持自己的 owned binding；来源编辑或删除不安装全局默认执行。

Metask catalog completion 只交付 owned 目录与 transient credential，不选择模型。Models 独立维护 principal、来源与目录 generation；每个目标 protocol 从当前目录精确解析，目录刷新不改写起始偏好或 Task 意图。

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
→ Models rejects stale generation or commits catalog/source generation
→ later explicit target admission independently resolves current authority
```

authorization lease 由 Account 构造，Application 负责在主线程交付或单个 catalog job 的相应生命周期内持有并清零。刷新时先向已接纳消费者交付所需 owned copy，再替换目录 job。Models 只接收 attempt、principal、authorization generation 与 owned catalog completion；Models module 不导入 Account，也不持久化 OAuth token。成功 completion 把 access token 的 owned copy 作为当前 Metask source 的 transient execution credential，下一次 authorization generation 变化会重新加载目录并替换该 copy。credential 改变必须建立新的 source generation，不能因 principal、模型或 protocol 相同而复用旧 authority；已选模型失格或合法空目录也不阻止来源版本更新，保留的模型意图仍不可执行，其他合格模型按新 authority 解析。纯 credential 轮换不改变用户的模型 selection revision。Application 另向 Product Control 提供主线程、无 secret 的当次授权校验 capability，返回 Account-owned authorization generation 与连续授权 scope；每次 Metask 新执行接纳及恢复候选发布前重新查询，匹配 Models 已接纳目录的 authorization generation，不能由 cached authenticated view、目录仍存在或 Task model intent revision 相同推断授权有效；catalog worker 不拥有 committed state，陈旧 completion 只能销毁。Models 的失败不调用 Account abort、不改变登录状态，也不补写 Account error。

authorization loss 时 Application cancel/join Metask catalog job并销毁 lease；Models 清除可解析目录及 transient credential并发布 needs_authentication，保留无 secret 起始偏好。只关闭 Metask 新解析与执行资格，custom 来源及既有 owned binding 不被全局暂停；既有 Task 不得借用新登录 scope。

Task 与 Schedule 的显式模型目标通过 Models 精确解析；起始偏好独立保存，不产生 execution authority：

```text
User submits explicit ModelRef and source/catalog generations
→ Models validates and resolves one owned candidate
→ Product Control prepares credential scrub and the owning Task/Schedule transaction
→ confirmed owner commit and execution installation
→ publish canonical projection
→ interactive confirmed choice may independently persist the starting preference
```

Metask 只保留 principal、授权、source generation 与目录 authority；protocol 由每个具体模型的当前目录解析，不依赖 Provider-local 选择。`defaultSelection` 仅为起始偏好，更新不解析 credential、不安装配置、不触发执行替换或 Schedule timer。仅偏好变化的提交未确认时拒绝该次记忆、保留旧内存偏好并独立诊断；两种可能 canonical 的来源 authority 相同，不撤销执行或冻结其他 Task。普通来源 mutation 的未知结果仍关闭其 canonical mutation 资格。

Models 配置与纯偏好事务不等待 Task 或 Schedule 消费者。Task 与 Schedule 显式解析后分别取得 owned candidate；后续安装或持久化失败只进入对应 owner 的恢复，不回滚 Models 或 Account。

Account prepared transition 在主线程单一 turn 内提交。目录由 attempt 与 authorization generation 接纳；每个实际消费者在创建、恢复或 rebind 时解析自己的候选，不安装全局默认配置。

Product Control 协调 Task-owned execution 安装与恢复，已有 Session/Run 按其 owned binding 收口。起始偏好及其 revision 不参与执行 generation、Task admission 或 credential ownership；execution generation 由执行 owner 分配，不随偏好变化推进。

New task 创建只接受完整 `ModelRef + source generation + catalog generation`。Models 精确解析该来源全部配置；没有 active default 或 null 选择路径，不把跨来源选择降格为替换某个默认配置的 model 字段。

既有 Task 的模型选择由 Task owner 准备完整 ModelRef 与独立 revision 的 history overlay，Product Control 验证目标来源并完成 confirmed commit；选择不调用忙碌的 Session，不改变当前 Run 或实际 binding。明确失败回滚 overlay；未知结果保留精确历史候选与原意图，复用既有 history worker 读回，确认前禁止该 Task 新 Run 和再次选择。确认提交后保留新意图，确认未提交则恢复原意图；不能用后来状态重写未知候选来推断原结果。尚未安装的新意图在执行接纳前重新解析目标；已安装的同一意图保持自己的模型、protocol 与 endpoint，不借用目录刷新或全局默认改变用户意图。

Metask 的凭据续期与新执行接纳分开：Account 刷新后，Application 在目录刷新前通过独立 capability 交付当前 lease；Product Control 只更新原连续 scope 内已接纳的执行，不经过 Models catalog gate。idle、queued、在飞或等待审批的 Session 使用官方原位更新，同步替换 attachment 的当前凭据；单纯轮换不改变 Task binding epoch、execution generation、模型意图、对话或权限，也不重建 Session、重放 Run 或工具。新的 Run 接纳仍校验 Account 与当前目录；目录 source generation 因轮换变化时，只有实际目标不变才确认新的来源证明。恢复候选沿用既有接纳校验，过时的配置或 scope 拒绝发布，不新增候选热更新或自动重试路径。

自动审批仍在主线程准备后立即派发，准备时复制 attachment 当前凭据；已发出的独立请求保留自己的副本。自动标题与生图在每次请求准备时读取其原 scope 内的当前凭据，目标、模型、可用性和 effect 生命周期保持冻结；读取失败使用各自既有失败语义，不回退到初始 token。生图的授权 scope 独立于主对话来源，不能把 Metask token 注入 Custom Provider Session。旧凭据仍参与全局脱敏，不能仅因过期或进入 waiting_ui 而删除；相关 operation 返回并经过 canonical event drain、Host 请求静止且历史维护完成后，才释放最后的保留副本。单个长 operation 的保留量及扫描成本可以随刷新次数增长，不以刷新次数上限终止 Run。

scope 由 Host Task 生命周期持有，Session detach 不删除连续性约束；退出、重新登录或身份替换后不跨 scope 续期，也不伪造已接纳 Run 的热撤权。hard expiry、clock 不可用、目录失败或候选失去授权仍阻止新的执行。实际 provider、protocol、endpoint 或 capability 改变继续走既有 checkpoint 与 binding 事务；仅模型改变且来源一致时使用 setModel。排队和未采用的追加输入保留精确一次语义，失败或取消明确收口，不能重放已采用输入或复活已取消批次。

Account identity/token rotation与 Models registry是独立 durable authority；任一方的提交、恢复或 outcome unknown 不得由另一方解释或回滚。Account 只回答当前授权能否产生 lease 或无 secret 的执行接纳证明，Models 只回答 provider/source 能否解析，Product Control 只回答具体 Task/Schedule 目标是否满足安装与执行接纳。

Renderer reload、断连或命令 timeout 只影响交互与 resync，不能取消 Host 中的 deadline、mutation 或 terminal completion。Renderer Account command 只涉及登录、取消和退出；Models command 使用 source-qualified identifier 与对应 expected revision。除用户显式提交 Custom Provider create/replace 或 MCP captureSecret 时一次性转交手动凭据外，Renderer 不参与 prepare、commit、authorization lease 或 credential transfer；该表单值不属于可恢复 UI 状态。

Identity transition、Task-owned execution 安装/释放与 durable Task history 是不同边界。history 保存实际 protocol/model、execution generation、binding facts 及独立 Task model intent，不保存 Account identity、credential locator 或可重建 secret。

Canonical snapshot 保持 owner 边界：Account 发布身份与授权事实，Models 发布来源、目录、起始偏好及健康，newTaskAdmission 只发布通用创建资格。Task modelIntent 是后续选择，binding/Run 是安装与历史事实；模型候选不以全局偏好或 attachment 已恢复为前提。无 intent Task 允许全部 ready 来源明确选模，不猜测旧来源。

Models 每次 resolve 只产生精确 `ModelRef + source_generation + protocol` 的调用方 owned candidate。Product Control 在 Task 创建、恢复/rebind 安装、凭据续期及释放边界执行产品文本与 Schedule durable scrub；完成必要持久提交后才安装、转移或 secure-zero 对应 credential。失败保留所需 owner 与诊断，不建立 default desired/active mismatch。

`models.json` 是 Models aggregate 的唯一 canonical store；当前 schema 3 保存 Metask 无 secret 来源 authority（principal 与 source generation）、source-qualified 起始偏好及其 revision、Custom Provider 的 id/display name/protocol/normalized endpoint、有界 model metadata、credential/test status、provider/source/catalog revision 和待完成 credential deletion tombstone。它不保存 Provider-local 模型选择、OAuth token、API credential、credential locator 或 Product binding generation；Custom Provider credential 只进入系统安全存储。Metask source id 固定为 `metask`。生图不形成用户选择、独立 revision 或持久化 intent。

Models 退役格式硬切前只提取可验证的 Custom Provider id 和已有待删除 id，合并去重后持久写入当前空 registry 的 credential deletion 队列；canonical 提交确认后才删除系统凭据，删除失败保留 tombstone 并跨重启重试。该过程不恢复旧 Provider、模型、偏好或执行 authority；无法完整保全清理义务时保留原文件并报告恢复失败。


生图默认模型与正式服务 target 的机器定义由 [Models 值合同](../src/product/models/contract.zig)唯一拥有。每次 Run preparation 优先采用当前目录中具备明确生图资格的默认模型；默认模型缺失或不合格时，按该次目录返回顺序采用第一个具备生图资格的成员。没有合格成员时返回不可用，不从对话默认、名称、输出 metadata 或旧持久选择推断模型。此回退仅在请求发送前解析配置，不构成发送失败后的自动重试或模型切换。

图片执行 candidate 只在 Models 接收当次 Host authorization lease 的借用输入后构造：principal、authorization generation 必须与已接纳目录匹配；目录加载中或授权不可用均拒绝新解析。Models 在同一主线程调用内解析模型并复制该次 lease 的有界 credential，不借用 catalog 缓存的执行 token，也不获取、刷新或持久化授权。其 owned model、固定 Metask Images Generation target、catalog generation 与 credential 构成独立配置，不包含对话 protocol、Product execution generation、principal 或授权代次。消费者不提交或覆盖模型与 URL；已接纳 Run 的目标、模型与可用性不随目录或 logout 热替换，其中 credential 按前述连续 scope 续期规则消费，执行 owner 静止后清零释放。

Bootstrap 只严格读取当前 canonical 格式。退休 schema 1/2 先保留 exact bytes quarantine，再以原子提交安装空的当前 store 并继续，不迁移、不双读、不重放旧记录。quarantine 或安装失败必须发布真实 persistence health，旧 bytes 不丢失；quarantine 不进入任何 active decoder。canonical 缺失时初始化空 store；`preferences.json` 与 `custom-providers.json` 不参与读取、恢复或 fallback。

Models persistence health 精确区分：当前 canonical 可用为 `ready`；file capability 存在但当前 canonical 读取、严格解码或提交结果不可信为 `recovery_required`；file capability 不存在为 `unavailable`。只有 `recovery_required` 允许显式 reset。恢复重新读取 canonical：当前合法格式非破坏性重装，中断 `testing` 状态收敛为 `failed` 后确认提交；读取失败或资源耗尽拒绝且不写盘；退休格式沿用 exact quarantine 后空 store 的 hard cut，当前格式缺失或损坏按原有 owner 恢复规则处理。commit outcome unknown 通过 exact readback 决议。恢复不得改写 Account、Workspace、Task、Run 或 checkpoint；Task-owned 配置按原生命周期收口。

Provider 删除先提交 credential cleanup tombstone，再删除系统 credential，最后原子清除 tombstone；创建先提交目标 id tombstone，再写 credential，最后一次 registry commit 替换为完整 Provider。credential 替换先持久撤销 readiness，再覆盖同一稳定 credential locator，最后以新的 provider/source generation 恢复为待测试状态；写入或最终提交失败保持 `missing/configuring`。确认 credential 缺失时持久化 `credential_status = missing`，安全存储暂时不可读不能误写为已确认缺失。上述操作不改写起始偏好；失效身份继续可见，执行消费者独立校验来源与具体模型。启动和后续 mutation 排空 tombstone，单个 vault 失败不阻塞其他 ID。


### 2.2 Workspace 与 Task admission

Workspace 是 Product Control-owned 产品对象；产品语义和用户操作以[产品需求](requirements.md)为准，wire 以[Renderer Bridge 合同](renderer-bridge-contract.md)为准。本节只定义 Workspace、Task、ExecutionConfig 与 Agent Session 之间的 admission 和提交关系。

Manual Workspace 的项目入口状态由 Workspace owner 独立持有，并进入 Product history；它不具有执行授权语义。项目移除只更新该状态，不删除 Workspace、推进 epoch、改变 trust/authorization、停止 Task 或释放 Session/Skill authority；空项目同样保留目录记录与授权。移除后的 Workspace 仍向 Renderer 投影，供已绑定的 Task 和草稿使用。左栏项目和 New task 的项目选项消费同一入口状态。重新选择同一已授权目录只恢复入口与导航顺序；授权确已不可用时才沿既有目录授权路径恢复。项目入口变更沿用 Product history 的 best-effort 持久化及健康语义，不借入口操作回收底层资源。

Manual Workspace 与 Automatic Workspace 共用一个 registry 和 Task 引用关系，`kind` 在 record 生命周期内不可改变。Manual intent 必须重新校验 Workspace identity、epoch 与 authorization；Automatic intent 必须取得 Workspace Runtime 当前已安装的 automatic-root capability。Renderer 不提交物理路径、automatic root 或目录授权 token。已严格恢复的可见 Manual record 保留用户先前的目录选择：Workspace owner 重新解析精确 canonical root 并打开目录验证实际可用性，成功恢复为 available，失败保留 record 为不可用供重新选择；不把重启本身视为撤销选择，不恢复已移除记录的可见性、不改变 epoch，也不接受路径已重定向的目录。此检查不代表后续文件访问永久成功，执行仍遵循既有准入和实际 I/O 结果。

Manual、Scheduled 首次创建及后续 Run、自动 follow-up 共用图片准备规则：Product 在 admission 中取得当前 Workspace authority，Application Models coordinator 借用 Account 当次 authorization lease，将 principal、授权代次与 bearer 交给 Models 解析默认或目录回退模型。准备不发起登录、刷新、目录请求或生成，也不创建文件；主线程 handoff 不需要第二份选择快照或 CAS。没有合格模型、授权过期、解析拒绝或 Application 图片准备资源不足时，本 Run 的图片配置为空，文本接纳继续；同一 Run 不因后续授权或目录变化而升级、替换配置或自动重发，下一 Run 重新准备。effect capability 只提供执行输入，不改变 Host Tool 注册集合。

Product 的每 Run owned 图片 candidate 与输出 effect 在准备失败、回滚或执行结束后按所有权释放。Agent 的执行副本在 callback/I/O 静止后清零；Product 的独立投影清理副本须等该 Task 的 worker 静止且该 Run canonical event drain 已完成，先清洗已知产品投影再清零释放。增量文本、工具字段、权限记录、review、标题及终态诊断同时覆盖对话和图片 credential；未决文本后缀不能因新增凭据类型而提前公开。上述图片配置、secret 和 effect owner 都是临时执行数据，不进入历史或 checkpoint；恢复后的新 Run 重新取得当前配置。

图片输出的 Workspace authority 由 Product 在 Run admission 校验并冻结，Application 文件 effect 只复制执行所需的 Workspace identity、epoch 与有界 canonical root，不保存可变 Task/Workspace 指针。捕获不打开目录或预创建文件；Agent 只借用窄 output port，Application 对象必须存活到全部调用与文件 I/O 静止。实际效果在 worker 上逐级以 no-follow 打开并检查目录句柄类型，拒绝 symlink/reparse 跳转；Host 在固定 `generated-images/` 内以随机名称独占创建文件，不覆盖既存文件，名称冲突只在同一次落盘中有界换名。文件名和 receipt 在写入前准备，完整写入、同步、命名文件及目录身份复核均在关闭前完成，关闭后返回 committed receipt。该结果不承诺崩溃持久性或对任意 Workspace 写入者的完整原子隔离。

已提交文件保留，后续取消不能撤销 saved 事实；未提交失败仅尝试删除本次创建且当前身份仍一致的文件。文件移动、替换或清理 I/O 失败时保留现场，以本次返回值报告 `cleanup_incomplete` 和 Host 生成的 attempted path；它不是文件仍位于该路径或已被删除的证明。不建立共享 last-error、持久 cleanup debt、启动扫描或自动重生成。取消通过现有可取消 I/O 会合，返回前必须等待文件操作及清理静止；不能把受控会合的关闭证据扩展为任意阻塞系统调用均有严格时限。Manual 文件属于用户 Workspace，Automatic 目录继续遵循既有移除合同。

Workspace owner 以 `<MetaWork data dir>/workbench/automatic-workspace-root.store` 作为唯一 canonical 配置。文件只接受 schema 1 的 `{ mode: system_default, custom_root: null } | { mode: custom, custom_root: canonical absolute path }`，不持久 revision、effective root、Workspace identity 或 Task 引用，也不读取旧格式、不迁移、不静默 fallback。进程内非零 `generation` 只服务于 command CAS；Host 重启后由新 connection/snapshot 建立新的 freshness 边界，没有 durable object 引用该 generation。Application 只提供 Native SDK 解析的 system-default path、该文件 capability 和 Host 原生 picker；路径模式、健康、交易和是否可分配均由 Workspace owner 决定。

启动时文件缺失才能原子初始化 system default；读失败、严格解码失败、unknown schema 和 incomplete recovery artifact 均保留 canonical 并发布 typed non-ready health。显式 reset/recovery 必须先将旧 canonical exact bytes 改名为唯一 quarantine artifact，再安装当前 schema；明确失败恢复旧 canonical，结果不确定保留 pending evidence 并禁止新 Automatic admission。普通 choose/reset 交易按 `expectedGeneration`校验，由 Host 取得候选路径并 canonicalize/stat，Workspace 再校验路径长度和 registry 冲突、打开候选 Root、原子提交配置，最后以不失败的内存交换安装新 allocator 并推进 generation/Product revision。明确写失败保留旧设置与 allocator；outcome unknown 禁止后续 automatic allocation；picker cancel 无副作用。

custom root 必须为随机 child 预留路径容量，且不得等于 Manual record、不得等于或位于已存在的 Automatic record 内；它可以是既有 Automatic record 的祖先。路径比较在 Windows 语义下大小写不敏感，其他平台按 byte-exact canonical path。任一历史 Automatic record 的精确 root 始终拒绝 Manual open，不得因当前 allocator 已切换而把该 record 重解释为 Manual。

Task 创建在产生外部 effect 前必须证明：

- 明确模型目标的 source/catalog generation、membership、protocol 与 credential authority 仍有效；
- Workspace intent、ownership、epoch 与 authorization 有效；
- Workspace、Task、Agent Session 与 projection 容量可用；
- Product Control 尚未进入 shutdown，相关 owner 没有阻止该事务的未决提交。

Automatic admission 在完成上述证明后才创建候选目录、临时 Workspace record、Agent Session 和 Task record。发布前的任何失败必须释放 Session 与候选 record，并只回滚本次创建且仍为空的目录；Task 已 durable 发布后的 Run admission 或执行失败不能回滚真实 Task 或目录。Manual admission 对 registry、recent order 与 Task 引用的变化必须与 Task candidate 一同提交，不能发布只更新一半的关系。

每个 Task 在创建时取得 owned ExecutionConfig 和初始 binding epoch。起始偏好变化不热替换已有 Task；显式改变 Task execution 必须在 Task idle、authority 精确且持久化 candidate 可提交时形成新的 binding。Run、manual compact 与 Conversation recovery 共享 Task-owned active-operation 槽；删除和 Session replacement 是独立生命周期用例，必须与该槽互斥并等待已有 operation 收口，不能通过不同入口并发改变同一个 attachment。

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

Schedule 的可执行定义保存 `ModelRef + source_generation + protocol`。Product Control 在每次 mutation 的明确改选及 occurrence 前按该项来源、模型、source generation、目录 membership、授权与 protocol 校验并 resolve；不比较起始偏好、不保存 Product execution generation。更新请求的 modelSelection 必填但可为 null，null 精确表示保留该 item epoch 下的原绑定；创建必须为非空目标。timer readiness与绑定reconciliation按每项计算，失效项不阻塞其他项。

完整 resolve 的瞬态拒绝只暂停该定义的进程内 timer admission，既不推进游标、写入 occurrence 或使定义失效，也不阻塞其他计划；已提交的来源/授权事实刷新或用户明确编辑后重新检查。claim 提交前必须完成启动后结果收口所需的内存预留。occurrence 结果只观察它创建的 Task 的初始 Run；后续用户 Run 不得替换待提交的结果。中断恢复必须处理全部未收口 claim；恢复准备失败也不得重新开放 timer。

自动 occurrence 的消费边界必须独立于有界历史持久化并保持单调；编辑、规则变更、暂停恢复及重启不得让未来游标回到已消费边界以内，已消费的单次计划不能因改名或恢复再次计时。旧记录缺少独立边界时，只依据仍保留的 timer occurrence 恢复边界，并纠正旧编辑/恢复路径回退的游标，不能据此丢弃定义。平台相对 timer 必须定期复核 wall clock。

Schedule persistence recovery 由 Schedule owner 决策；旧格式自动 hard cut 时先保留 exact quarantine，再安装空当前 store。当前格式的显式恢复校验全局 snapshot revision，先stage并sync当前内存候选，再保留旧canonical并安装；中断证据不丢失，再次恢复收口精确pending artifacts。只有提交确认后重新开放mutation与timer；quarantine不进入decoder或自动迁移。

Schedule store 保持 canonical `schema_version = 1`，严格保存 `ModelRef + source_generation + protocol`，删除 global selection revision。被替代旧格式先 exact quarantine 再原子安装空当前 store，无转换、双读或重放；失败保持真实错误。当前格式的提交、未知结果与显式恢复仍由 Schedule owner 处理，不用起始偏好作为恢复依据。

### 2.4 Skill authority 与本地资产

Product Skill aggregate 拥有本地资产 inventory、management transaction、enablement policy、Workspace catalog authority 与其持久化健康。Agent 拥有 AgentCore catalog acquisition、opaque lease 与运行时 catalog identity；Application 只注入 FileStore、受限文件能力、原生 picker 和经过验证的内置 Skill 根。Product Control 负责 Workspace/Task authority、shared Executor admission、全局 revision 与完整 snapshot，不读取 Skill 内部 state 或拼装物理路径。

本地导入准备由 Skill aggregate 有界持有一份：来源 locator、解析后的唯一 root、源摘要、元数据、目标 scope/epoch、目标 inventory identity 与实际内容摘要，以及单调 revision。准备、改选目标和放弃均不修改 canonical 文件或 durable inventory；准备允许已有 Task 运行，只投影正式提交的当前 blocker。改选 scope 必须复核来源并重新观察目标，产生新 revision；提交仅接受该 revision 与明确的 create、managed update 或未登记目录替换确认。managed update 保留 install identity，不能通过同名重新安装建立第二条记录。

正式提交由 Product Control 先同步生命周期并验证 scope、Task 静止与 Skill mutation admission，再由 Bridge 消费连接授权，在同一 owner 调用中交给 Skill 原有 transaction。Skill 重新核对来源 root/摘要和目标 identity/内容；变化必须重新准备，不能把旧确认应用到新字节或新目标。准备的连接撤销、替换或进程结束释放其临时资源；已经发布的 transaction 继续沿现有精确 catalog reconciliation 和恢复规则收口。当前/最近导入结果是进程内有界事实，读取只投影，不推进验证、恢复或重放导入，也不改变持久化 schema。

内置来源根与可选的组件 source lifetime 在 owner 线程作为一对输入捕获到 catalog job，排队前复制路径并保留引用。之后替换来源只影响后续捕获，不能让旧 job 使用新版本的 lifetime。查询期间由 job 保留资源，成功后由 [Agent catalog lease](agentcore-integration.md#skill-catalog-ownership) 接续；排队拒绝、取消、检查失败、stale completion 和 shutdown 都必须释放各自拥有的引用。旧组件的文件删除不能依据 Task 历史或绝对路径文本推断引用；只有进程内引用静止后才能回收。 来源切换由 Product owner 线程接收已验证的根与同一个 lifetime；切换前检查 shutdown、相关 request generation 容量及未完成的资产 reconciliation，拒绝时保留旧输入。成功时同时推进 personal 和已授权 Workspace 的查询 generation，使旧 completion 失去提交资格，并合并后续发现 intent；不修改已有 Task 的 pinned authority，不重放工具。Application 保留旧 current 引用到该 handoff 成功后再退休。

Skill 持久记录只按 Workspace id 归属；`skill-enablement.json` 与 `skill-management.json` 保持唯一 canonical `schema_version = 1`，格式原地硬切，不持久化 Workspace epoch，严格解码当前格式，不存在旧格式 fallback、折叠、迁移、quarantine 或恢复动作。能读取但无法按当前格式解码的数据直接失去 authority，store 从空状态继续，并在同次启动中以 atomic replace 写入空的当前格式；替换成功才是 `ready`，任何替换失败均为 `corrupt`，文件读取失败为 `read_failed`。Workspace epoch 只做 command、job 与 completion 的 freshness 校验，移除开始时推进、不回退；任何路径都不得用 epoch 推断记录归属。身份连续性由 Workspace identity allocator 保证：启动时 allocator 必须高于有效 Skill 记录引用的最大 id；两个 Skill store 只要有一个是 `read_failed`、`corrupt` 或 `outcome_unknown`，就不能证明 canonical 中哪些 id 仍有 authority，此时禁止分配任何新的 Workspace id（Manual 与 Automatic），`newTaskAdmission` 与 `automaticWorkspaces` capability 同步发布不可用，只允许重新授权已存在的 record，直到后续启动严格读取或替换成功。普通 mutation 的 `write_failed` 仍保留已知的内存与 canonical id authority，不阻止分配新 id。记录只在隐藏 record 被 slot 复用、id 永久退出 registry 时退休：复用前 Control 先确认两个 Skill store 均为 `ready` 或 `unavailable` 且该 id 没有 durable transaction，否则保留隐藏 record 并按既有容量规则拒绝新增。退休只删 policy/inventory 记录，不触碰目录；各 store 独立提交，失败按各自 health 规则冻结。没有已注册 owner 的记录不可管理，也不做任何启动时的归属推断或清理。

Personal 或 Workspace 的 committed Skill authority 必须不可分地拥有 immutable catalog snapshot、policy revision 与对应 Agent lease。catalog acquisition、policy mutation 或本地资产 reconciliation 先形成完整 candidate，并在提交时重新校验 Workspace identity/epoch、catalog identity、policy revision、相关 active operation 与 shutdown。stale candidate 只销毁并释放 lease，不安装、不自动重试。

Enablement mutation 先构造受影响 authority 的完整 candidate，再提交无 secret policy store，最后 no-fail 替换 committed authority。明确 write failure 保持旧 authority；outcome unknown 必须冻结新的 Skill authority mutation 和 Skill admission，不能降级为全启用。尚无 committed authority 的 Workspace 不得锁死无关 scope 的 mutation，但以后取得 catalog 时必须按最新 committed policy 编译。

交互 Task 的 Skill authority 在每个新 Run 的准备边界自动更新。Product Control 在消息接收、必要的 Conversation 恢复或模型切换完成后，以 owning Workspace 的 root/home/epoch 查询当前目录并应用 committed policy；只有 Session 空闲、原 Run 等共享 Session 的 operation 已收口时才原子绑定 catalog 和 grants，再创建 Run。已经接纳的 Run 与其插话保留原绑定；排队输入和自动接续形成新 Run 时重新准备。相同 catalog/selection 不重复绑定。Conversation recovery 不以 Skill readiness 为资格，恢复事务保持原有能力上限，新的运行准备在恢复安装完成后独立进行。Schedule 不因此取得 Skill 或启动 catalog job。

Composer 的下一轮候选来自 owning Workspace current authority。未选工作目录的新任务草稿使用 personal current authority 发现候选。带 Skill 版本对的 Automatic Task 创建请求先校验该 personal 版本对，再分配工作区。Task 仅在进程内保留该版本对，首条接纳的消息消耗它。匹配该版本对的首条 Skill 消息以当前 personal catalog 验真并捕获逻辑选择，随后按已有 Run 准备流程在 owning Workspace 下查询、重新校验并绑定执行授权。Session 的 pinned snapshot 只表示当前安装的执行绑定，不要求用户手动推进。显式 Skill 消息先按用户看到的 revision pair 和 concrete identity 验证，再捕获 Core 提供的逻辑 policy key、参数定义与 owned 参数；运行准备从当前 resolved winners 编译该逻辑选择，不根据显示名称或文件路径猜测。内容更新或无关目录变化可自动跟随；参数定义改变须保留输入并要求检查，禁用、删除或冲突不得执行。历史 Run 保存实际执行的身份与 revision，不重写旧历史，也不恢复或重放未执行的原文。

每条待执行输入只登记一次有界准备，按 Task/binding、Workspace epoch、来源与 policy 代次接纳查询完成；过期结果只释放。查询失败不能把 last-good 绑定当成更新成功：显式 Skill 输入失败并保留安全展示，普通 Text/multimodal 只有在可靠撤去 Skill grants 后才可继续；Session mutation 的合同失败按其真实生命周期收口。空 grants 是授权收缩，不伪造查询成功的空 catalog。停止、删除与 shutdown 撤销准备意图并收口 jobs/leases，不分配虚假 Run identity。

本地资产 import、reimport、uninstall 与 retry 使用同一 staged transaction：preview capability 绑定 source、内容摘要、目标 scope 与有效期；commit 重新校验 capability、目标 Workspace authority、冲突 generation 和相关 Task quiescence；publish 后必须完成 Agent catalog reconciliation。明确且可归因于候选的失败回滚 candidate/backup；catalog 暂时不可验证时保留可恢复 transaction 并发布 `pending_verification`，不能声称 ready。恢复只能完成或回滚已登记 transaction，不扫描、接管或删除 canonical root 外的目录。

恢复 durable `prepared` transaction 时，只有 transaction 记录了 backup 才检查 target/backup 物理状态：target 存在且 backup 不存在表示 rename 尚未发生或回滚已恢复；target 不存在且 backup 存在时必须先原子恢复 backup，再幂等删除未发布 candidate；两者同时存在或同时缺失必须保留全部 artifact 与 transaction 并 fail closed。fresh install 没有 backup，target 与 backup 同时缺失是正常的未发布状态。恢复磁盘事实后才能清除 transaction 或临时 inventory owner；任一步持久化结果不确定必须将 management health 置为 `outcome_unknown`，明确写失败置为 `write_failed`，两者都阻止后续 management mutation，直到重启严格加载 canonical 后重新尝试恢复；不得用当前领先于磁盘的内存 phase 开放普通 mutation。状态/phase 或 health 的变化均通过 Product revision 发布，即使原操作仍返回错误、或资产已从内存清除。

文件事务明确失败后，在仍持有该次授权 root 且 inventory 可信时，只对失败 install_id 尝试一次既有 phase 恢复；失败不自动循环。`pending_verification` 只适用于 state 与 `reconciliation_pending` phase 同时成立的资产，其余有 recovery 的资产派生为 `recovery_required`；包括已 `reconciled` 但清理文件尚未完成的情况。现有 Retry 按同一判定进行物理恢复或登记新的精确 catalog verification，不能把恢复成功当作验证成功。物理恢复仍要求当前 root authority、相关 Task quiescence、无 active reconciliation、目标 scope 无 job/reschedule 与未 shutdown，但不依赖来源配置可信；配置尚不可信时不排队验证。资源、目录访问和时钟失败保留事务，不误改 canonical health。启动/重新授权恢复与显式 Retry 共用同一物理 phase 实现；不重新加载并替换飞行中的 inventory。

固定兼容来源选择也由 Product Skill 拥有，与单 Skill enablement、inventory 和 Task pinned authority 分离。来源配置以独立 `skill-sources.json`、schema 1、单调 revision 做持久 CAS；首次缺失须先持久提交默认关闭值才建立可信配置。读取预算为 4096 bytes：恰好达到预算仍完整解码，超出预算单独标记 `too_large`，不得按损坏处理或解码前缀。损坏/后续缺失可显式 reset；读取失败、超限、不支持格式和结果不确定只允许按 capability 重读，不得自动覆盖。恢复 token 绑定当前恢复代次，reset 写入前重新读取；若文件已恢复合法，保留其真实值并以高于已观察 revision 的新提交重建 authority。

来源 mutation 以 Claude/Codex 品牌为单位：同一 CAS candidate 同时设置该品牌的个人和项目值、保留另一品牌，一次持久提交且 revision 至多推进一次；不提供逐目录写入口。schema 1 保留四个真实根的值，加载已有部分启用配置时不自动归一化。candidate 先持久提交，再 no-fail 安装选择并使实际受影响 current authority 失效；个人值变化影响 personal 与所有已授权 Workspace，只有项目值变化时不使 personal 与个人来源限定的 Automatic authority 失效。明确写失败保留旧可信选择与 authority；持久结果不确定冻结新的来源/管理 mutation 与 Skill authority，但不追溯撤销已有 Task pinned lease、普通 Text 或 durable management transaction 的恢复职责。根检查在有界 worker 中执行，仅授权固定相对目录；不存在的可选根可缺席，不可读、不支持类型或变化的根不得被静默跳过后发布部分 authority。AgentCore 仍独占 Skill 解析及 winner/conflict 判定，Product 不实现候选 fallback。

本地开发内置来源由 Application 从 `METAWORK_LOCAL_SKILL_ROOT` 开发启动配置取得并 canonicalize，release artifact 不消费该入口；Product Skill 以固定 source instance ID `metawork.builtin`、个人归属的 additional source 参与 personal 管理查询和已授权 Workspace 查询。该根不属于兼容来源开关或管理 inventory，不复制到用户 Skill 目录，不授予 import/reimport/uninstall 文件权限；同名冲突与 Workspace 优先级仍由 AgentCore 裁决。Application 保持借用路径到 Product shutdown 完成，catalog job 在排队前复制根路径并独立持有；配置的根缺失、不可读或不满足 canonical directory 约束时整个查询失去 authority，不发布部分 catalog。未配置时不推断安装路径或启用其他来源；该开发入口不形成 release 安装包承诺。

Automatic 的 Skill query authority 来自 owning interactive Task 的可用 Session，不来自 Manual 选择器的 visible 标记。它只消费已启用的个人兼容根与内置根，按 User policy 编译 resolved winners；workspace-local winner 或未知 provenance 必须禁用，不能选取被它遮蔽的个人候选。工作文件、ZIP 解压目录和其中的 SKILL.md 都不构成 Skill 授权；Automatic 不开放项目 policy override 或安装/卸载管理权限。初始准备、显式 refresh 和 job completion 都重新核验 owner、epoch、来源配置、policy 与投影容量。删除撤销查询 authority，并等待 catalog job、Session 与 Task worker 静止后才提交 Workspace record 退休和 Task 专用原件/artifact 目录删除；Automatic 的实际工作目录继续遵守既有保留合同；shutdown 先停止 admission、join jobs，再释放全部 catalog lease。

每个查询 scope 至多保留一个 job 与一个 latest reschedule intent。来源提交时即推进 request generation；旧 generation、选择或 Workspace epoch 的结果只释放，不得因 A→B→A 恢复同值而发布。shared Executor 的 QueueFull 保留 intent，沿既有 completion/wake 与 Control sync 有界轮转重试；其他错误结束该次准备，后续显式输入或重查可以重新请求，不增加 timer、watcher 或无限自动重试。管理发布只验证精确资产 scope，并标记依赖它的 current authority 需要重新查询；个人变更不能遗漏已授权项目，也不主动重扫全部项目。选择器打开和新 Run 准备通过同一 query 路径发现外部文件变化；普通查询不得完成管理 transaction。

管理资产关联必须同时证明 query purpose、provider、固定 source identity/scope 与 invocation，不能仅凭同名 winner 借用外部来源的健康、policy 或文件权限。管理记录与同名 external winner 可同时存在。验证 job 绑定 install identity、operation、scope/epoch 和 request generation；普通刷新不得完成 pending transaction，取消只清理匹配的 active verification，不丢弃 durable pending。发布验证还必须核对授权目标的实际 package 与 candidate 摘要；卸载验证证明该精确管理目标不存在，不要求其他来源的同名 Skill 一并消失。

#### 内置 Office Skill

Application 发布随主包压缩携带的完整 Office Skill、必要 helper 和 OOXML 校验资源。资源按内容哈希发布到自有目录，不覆盖已有版本；发布失败只撤销 Office 来源，应用继续启动。不维护基础/完整双来源或组件版本 catalog lease；准备依赖不替换来源，不要求刷新已有 Task。资源入口必须是明确的绝对路径，不从 AgentCore 临时物化目录的父路径推断程序位置。旧资源目录首版不自动清理。

XLSX 检查脚本经所属 Skill 的固定私有 Python 入口执行，只读取受控工作副本，不编辑候选或安装依赖。检查说明是有界、不可执行的声明；检查器区分断言不满足、说明错误、必要检查未支持与执行异常，选择器缺失、歧义或空跑不能形成通过。报告绑定实际受检候选的大小与 SHA-256，声明已执行的方法、范围及未执行项；无业务说明只报告基础检查，公式字符串和存储样式不等于重算或视觉验收。报告独占创建于新路径，属于可能含文档内容的普通 Workspace 文件，不写入日志、Snapshot，也不默认交付；它不是 Host authority。候选修改后必须复验；XLSX 工作流将检查身份与真实 DeliverFile 回执比较，不匹配时保留实际交付事实并明确检查不覆盖交付字节，不自动删除或重复交付。DOCX/PPTX 使用各自格式的检查流程，不由共有执行说明追加 XLSX 检查门槛。

PPTX 新建流程把固定创作依赖和严格检查作为一条生成链：格式专属处理只消费本流程新生成的工作副本，在有限且已验证的结构前提下写入新候选，不修改原件、依赖实现或其他包内内容。缺失的图表语义必须由创作意图明确给出，不能从错误结构猜测；不识别的变换前提明确拒绝。候选须全量通过原严格检查器，不豁免已有错误；格式工作流再核对业务内容及实际交付字节。处理既有用户文件仍走定向编辑与原件比较流程。结构通过、有限查看器兼容性证据与本次文件的视觉验收是不同事实，任何一个都不能替代未执行的检查。

Office 的机器输入按 Windows x64/arm64 与 macOS arm64/x64 精确选择私有 Python、Node 和目标 wheel，验收范围由[验证规范](validation.md#office-skill-与私有环境验证)记录。解释器和各自文档库同处一个按环境内容命名的目录；Windows x64 的既有发行、锁、身份及 Python/Node 独立准备保持。身份采用选定发行记录 JSON、对应库锁和布局标记的同一 SHA-256 构造，不包含 Skill 文案、业务脚本、下载量或用户目录。输入和 namespace 只由 Office manifest/lock 定义，生成常量不是第二份 authority。不探测组合系统解释器和全局包，不新增 Host 工具、Product 环境对象、Bridge/Snapshot、current 指针、版本选择、修复或回收状态机。依赖准备由 Agent 经现有 Shell 和权限执行；对话下载同意不授予文件权限，full_access 不增加额外产品安装 Gate。

依赖根为 Windows `%LOCALAPPDATA%/MetaWork/OfficeDependencies` 与 macOS `$HOME/Library/Application Support/MetaWork/OfficeDependencies`，不从 Task Workspace、应用数据名称或 Core 临时 Skill 路径推导。同一用户下相同内容身份有意跨构建和 Task 复用，测试以独立 HOME/LOCALAPPDATA 隔离。正式路径项必须为真实目录，符号链接或异常占位对象须保留并拒绝；不原地修改是行为合同，不保证文件系统只读或隔离同用户进程。

macOS 首次新建 Node 需要已准备的固定私有 Python，通过其标准库执行 Darwin 排他发布；Node 就绪后的检查、复用和执行不依赖 Python。准备器不得隐式下载此前置环境。Agent 按实际缺失部分说明 Python/Node 各自或合计的预计下载量并取得同意，再按 Python→Node 顺序准备；仅需 Python 时不下载 Node。Windows 继续独立准备两种语言。所有入口均为明确绝对资源路径，macOS 通过 `/bin/sh` 调用，不要求物化文件有执行位。

固定准备入口只接受 Python、Node 两个目标。独立临时目录下载、完整校验、安装锁定库并验证后，以不覆盖的同卷原子改名发布。macOS 只使用 `renameatx_np(RENAME_EXCL)`，不以普通 rename、复制或 `mv -n` 替代。并发允许重复构建，输家从赢家的真实解释器启动新进程核验后复用；新增目标发布后同样必须从最终路径启动新进程检查可搬移性。发布后检查失败保留正式目录并报告不可用，不回滚删除。取消或超时先停止并 join 自有子进程，不能确认后代已停止时保留自身 stage，不扫描其他残留。临时共享冲突允许有限短重试，永久错误明确失败。正式目录不原地修改、不自动隔离或删除；改名成功不能证明无人使用。校验失败须说明不可用和精确目录，提供人工恢复指引：停止所有使用该目录的 Task 与外部脚本，退出应用并确认没有使用进程后，由用户明确选择只清理这一目录，再重新启动并同意准备；无法确认使用者已停止时保持原状，不清理父目录、其他环境或文档。Python 不用搬移的 venv，包只接受带哈希的固定 wheel；Node 以独立锁文件安装且禁用安装脚本。薄调用脚本只设置单次解释器/库路径，不隐式下载、不改 Task 长期环境，不提供沙箱保证。

读取用户镜像、代理和证书配置沿用包管理器机制，不写用户配置；关键安装目标、内容身份和安装行为仍固定，不自建配置解析或选源系统。固定来源、信任和主包资源接受规则分别见 [Windows 分发](windows-distribution.md#office-skill-与私有依赖)与 [macOS 分发](macos-distribution.md#office-skill-与私有依赖)。普通启动不下载、全量哈希或自检环境，也不登记健康数据库。首版不自动更新、修复或回收，明确接受旧目录积累。

### 2.5 MCP authority

Product MCP 拥有容量一的进程内安装提议信箱与主线程待处理提议；Run admission 冻结窄 capability，Task owner 校验来源 Task/Run 有效性。Agent 在锁外解码有界公开草稿，callback 只 try-lock 转移 owner 并保留名额，解锁后 RequiredWake，不等待主线程。主线程取走仍占名额；已知凭据检查在接管及每次投影前执行，拒绝时释放并发布安全提示。用户 Add 在同一主线程事务内先核对可选 proposal id，确定保存后原子消费并返回 server id；失败不复活或自动重放。完成 Run 可保留建议，取消、删除和关闭清理；关闭先关 ingress，再取消/join Executor 和 Session，callback 静止后释放 owner，锁不跨唤醒或 join。提议不持久化，不依赖 Tool 展示槽，snapshot 容量独立预留其公开上限及结构开销。

Product Control 拥有 MCP Desired Registry、connection approval、OAuth consent、credential locator、Runtime Manifest、Admission Authority、mutation/recovery 与 Task admission。Agent 拥有 connector/backend 生命周期、AgentCore descriptor、declarative Runtime apply、Activation、catalog 与 Selection。Application 只执行 child、network、系统 credential、OAuth、HTTP auth snapshot 与跨 owner coordination，不拥有 MCP JSON-RPC、产品状态或 admission policy。Account 与 MCP 不共享 ownership、credential service 或 persistence。

敏感 HTTP endpoint 的有序地址片段只进入系统 credential storage；Desired 保存 origin、稳定 identity 和片段引用，公开投影只有 origin。OAuth 的授权 resource 与 endpoint 分开绑定：Host 在确认前暂存私有 resource 引用，授权事务将其转为 consent 的私有绑定，DCR 与恢复使用同一事务；公开 resource 行为保持不变。连接、授权、code exchange 和 refresh 只在 Host 中解析完整地址，临时 owned copy 在释放前清零；指纹只消费公开绑定与引用，不包含秘密或秘密 hash。

自动安装的 durable operation 绑定精确 server、来源 Task/Run 与真实用户消息引用；原始请求只按系统凭据容量分块保存，metadata 保留 origin、引用、revision 和阶段。先提交 disabled 目标，再取得凭据、认证并连接。首次工具集合与一次性授权标记在同一凭据事务中保存，先准备 Admission 再提交，恢复只复用已经保存的精确集合。ready 的首次发布还必须证明当前正式成员、目录和新 Task Admission 有效；完成后保留安装历史，当前可用性独立取正常 Admission，不因停用或过期把完成历史改成连接中。Stop 的取消 marker 可在 Core apply 未结束时独立提交，不等待 worker；它立刻否决新加载和新准入，后续再对账停用配置。marker 不改变 descriptor 或 credential 引用、不推进 desired generation；正常 target 变更仍推进 generation，取消与完成都按 operation revision 拒绝迟到结果。

安装来源只从同一 Task 的真实用户消息取证，支持跨 Run 的明确同意；后续撤销使旧请求失效，多个候选或不明确意图必须经 Host 确认。唯一失败目标按同 Task 与完整来源匹配，修复保留 server identity，不能按显示名或域名猜测。首次发现为空且允许列表仍为空的 `no_tools` 目标，在用户显式重试安装时可重新完成首次工具授权；重试时仍非空的允许列表保持原边界，目录刷新不得自动扩权。目录刷新占用 mutation 边界时保留已接纳的安装请求，由刷新完成事件继续推进；阶段提交后需继续结算的安装必须主动唤醒主线程，不能依赖来源 Run 或其他无关事件。OAuth 授权取消或未授权结束将本次安装结算为取消或失败，不自动重新打开浏览器；网络阶段消耗执行预算，人工确认和浏览器等待不消耗。

Product Control 在 MCP 全部创建和替换连接入口复用 Host 已知凭据 predicate，在持久化与 effect 前拒绝敏感公开字段；不以名称、熵值或全部 env 值扩展凭据集合，也不改写既有记录。创建回执在 preparation 释放前持有确认 target 的稳定 identity，只有确定保存结果可以返回它；后续凭据捕获仍由当前 generation、server、auth mode 与 slot 校验，不通过 snapshot 猜测 identity。

STDIO 启动诊断由 Application 的具体 transport owner 发布有界安全事实，绑定公开 server id、连接来源指纹与本次正式 apply attempt；引用计数保护其跨 worker/transport 生命周期，callback 只写原子事实并非阻塞唤醒，不持有或修改 Product。主线程通过窄 MCP port 接纳，与当前 Desired source 和已开始的 attempt 不符的晚到事实拒绝，隔离测试不进入正式诊断。Product 按成员保留事实，配置变化使旧事实失效；不把原始 stderr、系统错误文本或未确认退出码写入 snapshot、历史或 registry。EOF 仅证明 STDIO 关闭，不为取得诊断等待仍运行的 child；既有 Core failure ABI 与进程关闭协议不变。

Desired Registry、Runtime Manifest 和 Admission Authority 是三个不同事实：

- Desired Registry 表达已 durable 提交的用户意图；
- Runtime Manifest 表达正式 Agent Runtime 已接管的 descriptor，或无法接管的无 secret absence proof；
- Admission Authority 表达新 Task 当前可以同步借用的已验证 Selection，或明确的 blocked reason。

授权缺失的 absence proof 按连接是否真正需要加载对账：未具备加载条件时，consent、DCR 注册所得 client identity/secret locator 或 reauthorization 中间状态变化不能单独使正式 Runtime 失配；具备加载条件后仍须真实 apply 才能成为 loaded，不能将授权成功当作 Runtime 接管成功。static credential absence 仍绑定对应 credential 引用，不能借 OAuth 中间态规则放宽其校验。

MCP mutation 先提交 canonical Desired；Product Control 再以最后已确认的 Runtime Manifest 为起点，每步加入、替换或移除一个目标，构造完整成员集合。Application coordinator 只执行该步 preparation、Agent declarative apply 与正式 Activation；Product Control 逐步接纳 Manifest、Activation 与按当前授权派生的 Admission Authority，不等待整轮结束。Agent 复用未变化成员的 connector owner，不为每步复制整组执行资源。已有 Session 保持创建时的 authority 上限，由 Core 按实际来源和目录重新评估，不热替换其 Selection。

registry commit 明确失败时保持旧 Desired 与 authority；commit 结果不确定时不能宣称 canonical generation，必须保留 recovery fact 并冻结后续 mutation。正式拒绝只记录对应目标本次未接管，并保留仍可证明有效的旧 Runtime/catalog authority；新准入仍须按当前已提交授权、来源版本与原 deadline 过滤，不能恢复旧权限或重置 TTL。无法信任的 ABI/report 必须停止后续 MCP effect、关闭相应准入，并保留 Core 可能持有的资源直到安全释放；不能把未确认的 descriptor 标记为 loaded。已应用但 Activation 失败时保留接管事实，以既有有界目录刷新恢复 authority，不重新应用已确认的成员。candidate Runtime test 与正式 Runtime 隔离，不安装 Manifest、Admission 或 Task authority。 Application 只对尚未接管的 candidate 绑定本次 apply 的额外绝对 transport 预算；只有其 connector 尚不可能被 Session 使用时，该归属才成立。普通 candidate 在 APPLIED 后立即解除。首次安装的新成员在尚未发布新 Task authority 的作用域内，可将首次握手预算延续至同一 apply job 的 Activation 结算；结算即释放，已加载成员和工具调用均不借用该预算，也不得从 `purpose=actual` 推断用途。`timeout_ms` 按官方 SDK 的单次 RPC 语义消费；有效运行上限和 candidate 总尝试窗口由 Product MCP contract 的唯一常量拥有，历史较大值仍可读取且保留原值，Host 执行时收紧到公开投影的上限，Renderer 明确提示。已有成员时，candidate 总尝试预算为若干完整请求窗口，不能直接等同于一次 RPC timeout，也不按成员数量平分；空 Runtime 不施加额外总预算。Host timeout 上限只限制连接和目录管理回调；传给 SDK 的 descriptor 保留用户 timeout 原值，官方 `tools/call` 回调也原样传递 timeout，避免在任何一层压短长工具调用。独立连接测试采用相同管理上限；OAuth 保留自身有界 deadline。apply 与 refresh 不能并行执行，正式 apply 没有官方取消。调度先执行已到期且可执行的维护，再推进 candidate；不能用缩短用户请求 timeout 来保证目录永不过期，也不得重置或延长 TTL。每个来源的准入窗口以旧授权实际到期时刻 E 与新鲜目录、Admission 完成发布时刻 P 为界，缺口长度为 `max(0, P - E)`；P 包括实际串行等待、apply、Activation 或恢复刷新及发布耗时。只收缩失去有效证明的来源，其他来源继续按自己的 deadline 准入；窗口内创建的 Task 保持创建时 cap，后续不补授。每步结算后让维护获得一次调度机会，目录退避及 OAuth Host 全局时间下限期间仍可推进候选，不因一个已到期但尚不能调度的维护项永远阻塞收敛。

Product 使用同一纯成员规划结果驱动 alignment、选步与 row 状态；未加载、替换、资格失效、停用及删除均按实际成员和 Task 保留义务处理。已启用但不具备加载资格时，有引用保留实际版本，无引用则移除；等待认证或 approval 不构成持续调度的工作。没有可执行动作时停止自唤醒；全部候选失败且没有实际成员时结束 pending 状态，普通 Task 使用空 MCP authority。`runtimeAlignment = current` 表示目标已处理且结果已接纳，不表示全部服务健康。逐目标结果绑定来源版本；无关 Desired generation 或成员增加不重开失败。相关成员移除、替换可以在本轮结束后重开，单轮每个候选最多尝试一次；显式应用重试可重开失败结果，目录刷新不隐式重试未加入的来源。结果存储必须在 effect 前准备，后续失败不能抹掉此前已确认的接管。

Task 在 Session 创建前取得进程内 MCP 引用，引用保存原工具 cap、来源版本与当前显式授权上限，并承担逻辑服务的保留义务，不拥有凭据；创建失败、null authority 降级或 prepared rollback 必须释放引用。Task 的 Session 关闭、释放、恢复或模型切换不释放引用，只有 Task 删除明确提交后才释放；删除失败或结果未知必须保留。成员保留按 Task 对逻辑服务的引用计算，不因 enabled 来源替换而丢失；来源指纹只参与授权和恢复校验，保留计数本身不授权新版本，也不得阻止 enabled 来源替换。

Disable/Delete 排除该来源的新 Task authority；有 Task 引用时保留实际成员，最后引用释放后自动收敛移除。disabled Edit 只更新 Desired，已有引用继续使用已应用版本，重新启用后才尝试替换。恢复按该 Task 原 cap、checkpoint、当前显式撤权、可信来源和仍有效的 catalog 取交集；不以其他来源的 pending/删除状态作全局拒绝。Delete 保留删除前最后提交的工具授权上限，不能复活先前撤销项；enabled 来源变化仍须在关闭原 Session 前拒绝旧来源恢复。原本 null/空 authority 保持 null，进程引用不写入持久化格式，也不在冷启动重建已删除来源。OAuth grant 恢复必须证明 Desired 仍存在、连接获批且当前授权绑定有效；enabled 来源不以 Runtime 已加载为前提，disabled 来源仍须与实际版本一致且有 Task 引用。未加载目标使用当前授权连接失败后停止该绑定的自动 grant 恢复；该失败跨其他成员移除/替换触发的收敛轮次保持有效，不能在重新准备候选时丢失；相关配置或显式用户重试才能重开，无关成员变更、目录刷新、唤醒或再次到期不得重开。已知 expiry 只阻止新增或替换候选在授权恢复前执行，不改变成员资格、指纹或移除规则；等待授权是已处理的等待结果，由授权 completion、退避 timer 或显式用户操作重新推进。只有该 id 不存在实际已加载成员时，无法刷新且已过期的 grant 才因本地 expiry 进入重新授权；同 id 旧成员仍在线时，不因该时钟事实退休 grant 或调度移除。若待替换目标使用此类 grant，则记为可重试且可重新登录的失败，不宣称存在自动恢复。Delete 不续期，按现有事务立即退休凭据，已有执行副本只使用现存 access token 到自然到期。refresh 开始时固定未加载、当前 descriptor 匹配或同 id 旧 descriptor 仍在线的进程内 Product 证明，持久 marker 与 apply 串行化边界保证其交接。未加载目标可以独立提交新 grant；当前 descriptor 匹配时必须预备 HTTP snapshot rotation，slot 缺失或版本不匹配必须 recover。仅有同 id 旧 descriptor 时仍尝试轮换兼容 slot；slot 缺失或 consent epoch 不同则保留旧成员并独立提交新 grant，不能让旧成员的认证方式或旧 consent 退休当前授权；token revision 冲突仍必须 recover。主循环先结算已完成的目录工作再调度 MCP；已加载连接的到期维护优先，未加载授权恢复与普通候选交替，timer 只唤醒同一调度入口。浏览器交互授权期间保留全局 apply 限制，由页面明确说明等待状态。目录不可用不应与 OAuth 续期互相等待：可先持久提交 blocked/reduced Admission 后开始操作；不能证明已收缩授权、准备失败或接管结果未知时不产生外部 effect。


credential journal 的恢复资格必须同时来自可信 canonical registry 和 journal：generation 必须对应 base 或 target，candidate 与 retired locator 的当前引用关系也必须分别符合该阶段。任何 credential 删除前先完成整组关联检查；不从无法解码、未知格式或读取失败的 registry 推导删除资格，OOM 也不得被重分类为损坏。

损坏记录的隔离必须由持久 pending intent 绑定待处理文件的 exact bytes，先核验 registry 与 journal 的整组物理状态，再移动文件。registry 不可信时先隔离关联 journal，再保存原 registry，确认这些步骤后才建立当前空 registry；只损坏或不匹配的 journal 可以独立隔离并保留可信 registry。重启只完成 pending intent，不读取已完成隔离记录来重建 Desired 或产生凭据 effect；文件内容已变、状态冲突或持久化未确认时保持 recovery required/outcome unknown。每次恢复必须重新确认已移动文件的持久化屏障。

Application 启动时只创建一次 canonical empty Agent Runtime；恢复出的 Desired 必须在 Product Control 与 coordinator 就绪后沿与后续 mutation 相同的 apply 路径安装。empty create 后 apply 是正常启动协议，不是失败 fallback 或第二条 Runtime path。Agent Runtime create 失败终止启动；外部 MCP child、network、handshake 或 catalog failure 只能使相关 MCP authority unavailable，不能关闭普通 Text Task admission。

MCP apply、catalog refresh、durable OAuth mutation 与运行时 reauthorization 共享 Product Control 的串行化边界；浏览器授权等待不占用该边界，只携带 server-bound operation identity。浏览器等待期间，其他 server 的 OAuth refresh 和 reduced-authority catalog refresh 仍可运行；进入单一 durable `oauth_operation` 后才按事务串行。所有 completion 必须按 operation、server/connection fingerprint、consent epoch 与当前 generation 重新授权，stale 结果只清理自身资源。目标 server 进入 OAuth 或 reauthorization 时必须先提交排除它的 reduced authority，不能无关地冻结其他 server。

普通 Text Task admission 不属于 MCP 边界：MCP 未就绪、refresh/apply/OAuth 在途或 freshness failure 都不得拒绝 Task 创建。创建时只复制当刻安全可用的 Selection；不可用时以 null Selection 创建，并在 Task 的进程期 immutable authority fact 中区分 `ready(selected)`、`ready(none)` 与 `unavailable`。该事实进入 Snapshot 和 create result，不进入 Task persistence，冷启动恢复的历史 Task 为 `unavailable`，Renderer 不得据此热附加 MCP。freshness failure 必须使旧 MCP Admission fail closed 并触发现有异步 refresh；原 restore 或 mutation 不自动重放。边界忙时必须保留 runtime authorization failure 与 refresh pending 事实；refresh enqueue 失败必须由 owner timer 有界重试。关闭时先停止 MCP management、OAuth/refresh timer 与新 MCP admission，再 settle/join worker，释放 Admission 与 Activation，最后由 Agent owner 释放 transport 与 Runtime。

纯目录主动刷新不撤销仍有效的已发布 Admission；创建及恢复可以在原来源、配置、授权 ceiling 和保守 deadline 内继续借用它，Core 的正式收缩或拒绝仍是强制结果。Selection 与创建时 authority fact 必须在同一准入观察中取得，不能因两次 freshness 读取跨过 deadline 而彼此矛盾。deadline 从 Agent 的官方 descriptor 观测派生，并扣除排队与 completion 交付耗时；不能从安装时间重置 TTL。到期及时收缩，不以正在刷新或重试频率限制延长有效期。只有明确的未发布拒绝可保留旧目录至原 deadline；未知失败不能据此保留。恢复准入中的 MCP 事务屏障与 Runtime 不可用不得走 Session 容量回收路径。

Product MCP 的自动刷新共享单一作业并合并重复请求；极短 TTL 受最小网络间隔约束，持续失败有有界退避和暂停，普通 Task 输入不能重置预算或跳过退避。显式刷新或新配置可以恢复尝试；队列、timer/wake 与网络失败分别保留可诊断事实。查询只观察当前 freshness，不登记网络或恢复工作；正常推进由 Host timer、控制入口和 completion 承担。

无可信 challenge 的 HTTP 401/403 只形成绑定来源与 token revision 的拒绝事实，不自动退休 grant。手动重试仅凭该事实请求一次受控刷新；普通网络失败不触发无依据的刷新，已知过期仍遵守连接前恢复。当前目标失败且未加载的 ready 授权允许用户显式重新登录。重新登录在确认 consent 前取消不改变旧 grant；确认 consent 即提交新 epoch 并退休旧 access/refresh grant，之后取消、浏览器打不开或拒绝授权均不恢复旧 grant，停在 awaiting_tokens 并允许再次登录。旧 Runtime 成员继续遵循 Task 引用规则；无引用的待替换旧成员可能因当前 Desired 不再具备加载资格而移除。此行为必须在确认前告知用户，不能把取消解释为旧授权仍有效。disabled 来源的认证失败作为不再适用的终态确认，不退休 grant 或反复定时投递。失败候选只保留不在 active 集合中的候选 slot，形成一份待交付的有界引用集合，不作为实际成员或 rotation authority；Product 消费或判定过期后释放，分配失败由既有 OAuth 交付 timer 重试。

OAuth grant 的提前刷新时间在提交安装或启动恢复时固定；暂缺合法时间时，由后续显式生命周期观察补齐，查询保持纯读并暂用真实 expiry。Product 按 server、connection/consent 和 token revision 保留进程内有界退避，返回 `max(refresh_due, retry_not_before)` 最早的一台；marker 确认清除或目标刷新 begin 被拒后才推进相应重试状态，全局事务忙不归为单台服务器失败。旧 operation 不得影响新绑定；调度不得改写 grant 的真实 expiry。Product Control 只注入既有系统时钟的读能力，Application 继续拥有单个 OAuth timer 及其全局下限，不借用 Schedule 的 arm/cancel 或另建持久化调度状态。catalog refresh 等待 OAuth marker/apply/在途作业时由完成事件继续推进，不能以到期的 retry floor 形成毫秒轮询；独立的 freshness deadline 仍须及时失效准入。

Product Control 为该共享刷新作业持有独立于 Run 池的有界控制执行容量，所有 Run worker 等待人工审批或 Run 队列已满时，目录刷新仍须推进；此容量不执行 Run，不改变 MCP apply/OAuth/refresh 的既有串行化边界。关闭先停止 MCP admission/timer 并取消尚未开始的刷新，join 在途刷新后才接纳或丢弃其 completion、释放对应 owner；Agent Runtime 和 transport 必须活到该 join 完成。

关闭期间返回的正式 apply completion 仍须按当前绑定接纳已发生的 Runtime 接管事实并更新 Manifest，但不能重新安装 Activation、Selection、新 Task 准入或刷新任务；候选执行资源由完成交接的 owner 释放。stale completion 不消费候选，失败 completion 不能覆盖 shutting_down 边界。

### 2.6 文件 attachment staging

Attachment staging 是 Product Control 内部候选资源 owner，原件存储属于 Product 附件能力，不形成新的顶层 Product owner 或 Renderer 产品对象。Application 组装 store、持有独占 writer lock，并注入公开 Native SDK 图片预览能力；Product 决定分类、配额、接纳与清理。输入可以是系统 picker/Native SDK 拖放提供的本地路径，或 Renderer 从本次 DOM File 提取的有界字节块。Bridge 只拥有 source/window/connection authority、批次关联及 Renderer opaque token 到 Product identity 的 grant，不缓存正文、原路径或 Product 指针。

路径输入在 Product 登记唯一 preparing 批次后，使用独立 bounded attachment lane 探测普通非空文件。preparing 只登记身份和互斥，不以资源额度拒绝；来源数量确定后先校验数量，再进行清理重试和资源准入。每个源文件只 no-follow 打开一次；主线程按探测元数据预留整批配额后，把冻结的 store identity 与已打开源句柄交给有界复制 job，并在同一源句柄上确认前后 stat 不变；用户源路径只活到候选建立，不进入日志、Snapshot、持久化或发送时重读。DOM 字节输入只接收本次 File 的连续块，不宣称具备路径身份或 stat 保证；每个主窗口连接至多一个接收批次，在开始时预留完整数量和原件字节配额，逐块写入 store，不分配文件总大小的接收 buffer。预留和 ready/borrowed 附件共用总配额，不能被 picker 绕过；它不等于进程总内存上限。

单条消息/单批数量与全局存活记录容量分别约束。全局记录池在初始化时固定分配，草稿、待执行原件与删除债务共用；Bridge grant、清理关联及完整断连释放必须覆盖该存量上界，不能复用单批数量作为存量限制。删除债务关联去重后须对应不同的存活 Product 记录；关联容量不足明确失败并保留现有 batch/grant 追踪，不能 panic、丢失关联或误报已经清理。

两个入口都整批原子 staging，共用单文件、数量和总容量限制。Product 按签名识别 PNG/JPEG/WebP，并通过 Application 注入的 codec 验证和生成有界 PNG；其他非空普通文件保留为不透明原件，不校验 UTF-8 或 NUL。图片和其他文件共用单文件上限，不按扩展名或 MIME 分类；非图片仍使用既有 file grant，不新增 binary wire kind。所有来源共用一个 Product 输入批次与固定容量的资源槽；整批元数据和数量、字节配额必须在创建任何原件前完成校验与预留。失败必须撤销整批候选 authority；清理候选时，只有确认物理删除的原件才返还配额。删除失败的 identity 保留为有界 cleanup debt，不发布 descriptor，不阻止其他合法 ready/borrowed 附件；后续显式添加可有界重试清理，不能用重连或取消假装释放。原件的存储 identity 只由 Host 生成。未发送原件位于 store 的 staging namespace，重启清除该 namespace，已接纳原件不因此丢失。

staging 状态精确为 `staging | ready | borrowed | consumed | released | failed`。Bridge 在 `tasks.sendInput` 或 `tasks.run` 前校验 token 属于当前 connection/window、均为 ready 且不重复。Product 在 Task authority 校验后将原件移入 Task namespace并构造有界、不可信资料引用；图片同时提供有界 PNG，非图片原件不嵌入 prompt。顺序为可空用户文字 part 后接 chip 顺序的图片预览/原件引用。含非图片文件时用户指令必须非空。Agent 消费普通 text/image part，按文件格式选择可用 Skill 与工具；文本仍可用既有 built-in Read/Grep，不增加 AgentCore ABI、host tool 或 Provider-specific document path。准备失败回滚至可重试 staging。普通 Composer 以 Task 接收 `tasks.sendInput` 为 token 消费点：Task 取得 owned payload，Attachment 将原件标为 Task-owned 并释放草稿侧预览/引用，Bridge 消费 grants；waiting 原件仍占共享记录和原件字节额度。进入 Run 时保留原件并退出该工作集，未执行取消则在物理删除成功后返还资源，删除失败继续占用。显式 `tasks.run` 仍以 Run 接纳为 token 消费点。任一接纳成功后，即使 history save、enqueue、transport 或 terminal 失败也不得恢复或重放 token。

已接纳原件完整保留在 Task namespace，文件名由 Host 随机 identity 与有界 ASCII 安全后缀构成；非图片保留原名称的安全后缀，缺失或不安全后缀使用中性后缀，图片使用已识别格式；既有持久化原件路径保持不变，Model 引用指向 owned copy，不指向用户源文件；附件输入历史只投影原名称、类型、原图片格式、原大小和顺序。Task 删除必须在 Session、executor 和 worker lease 静止后释放整个 Task 原件目录。Product 不解析 opaque checkpoint，不从模型文本反推附件 identity，也不自动将路径或原件正文写入附件输入 Snapshot、Task history metadata 或日志；Agent 按需读取产生的 Tool 记录继续遵守既有有界投影与脱敏合同。恢复继续使用原 checkpoint 中的引用与保留的原件；原件无法读取时明确失败，不能改读用户源路径或伪造空内容。

本地开发归档资源由 Application 通过 `METAWORK_LOCAL_ARCHIVE_HELPER` 取得、canonicalize 并验证为普通文件；可选的 `METAWORK_LOCAL_ARCHIVE_PYTHON` 显式指定解释器，存在时同样严格校验，配置损坏明确失败，不切换其他来源。release 不消费该开发入口。未指定解释器不撤销 helper 入口，也不证明系统缺少 Python；Agent 经既有 Bash/权限机制根据任务需要检查可用的 Python、调用 helper，并依据实际工具结果说明缺失依赖或处理失败，Product 不新增环境状态或专门提示。Application 仅注入有界资源描述，不替 Product 执行解包；Product Attachment 初始化时验证并复制描述及依赖要求，在非图片原件引用中把产品提供的调用方法与不可信文件资料分开，不新增 Snapshot、Bridge command、Product 持久化格式或 Skill policy。归档资源是 Product Control 提供的执行方法，ZIP 不加入 Skill catalog；Office 自包含资源从同一 canonical helper 生成。

受支持的 ZIP 与 Office 解包流程使用有界 helper：在库分配成员 metadata 前限制目录与真实成员数，校验路径、类型、碰撞和压缩方式，并对实际解压字节计数，不能只相信声明大小。默认在 Task 工作区操作；显式基目录与输出的路径关系由 helper 校验，该调用参数不取得不可篡改的 Task authority。输出为基目录中新建的数据子目录，不合并或覆盖既有目标。正常失败清理本次目录并保留原件；未完成标记只在完整校验成功后移除，强杀残留不能被报告为成功或覆盖复用，不增加后台回收或改变 Automatic 工作目录保留政策。归档中的 SKILL.md 是普通数据，不能被流程安装、执行或提升为授权来源；Automatic winner 授权继续遵守 §2.4。该流程不构成对任意 Bash 或完整进程资源隔离的安全承诺。

### 2.7 Identity 与 credential redaction

Product Task identity、Agent Session route identity、execution generation、Workspace identity、Skill policy identity 和 MCP server identity 各自属于对应 owner，不共享生成器，也不能依赖数值相等。跨边界只传递完成当前校验所需的稳定 identity 和 generation，不传递内部指针或 secret-bearing owner。

Credential redaction 是 owner 释放协议，而不是 snapshot 时的偶然过滤：

1. Task 创建、恢复/rebind 安装或凭据续期取得新 credential 前，先清洗所有可能包含它的既有产品文本，包括 Schedule durable candidate；
2. 实际 credential 替换或释放前，清洗 Workspace、Task、Run、Tool、UI 与 Schedule 的相关 durable candidate；不依赖全局默认 execution；
3. 释放 quiescent Task-owned ExecutionConfig 前，再用即将释放的 credential 清洗该 Task 的全部产品历史；
4. durable commit 成功后才能转移或 secure-zero 对应 credential ownership；
5. 新构建的投影块在交付前继续扫描所有 live credential，作为提交前的第二道防线；仅在内容版本和安全代次均未改变时，才允许复用已经检查过的编码块。

Schedule 脱敏只在已加载计划内容命中待接纳或释放的 credential 时建立持久化前置条件；未命中时不得读取健康度或执行 I/O，也不得阻塞无关 Task。Schedule 脱敏由实际 credential 安装、续期及释放边界触发，覆盖新 credential 可能命中的既有计划文本及即将释放 credential 的历史；清洗失败或提交结果不确定时保留必要 owned credential 与恢复证据，禁止该次未完成保护的安装或释放。Models 纯偏好提交与该过程无关。

Credential 是 opaque bytes。redaction 必须覆盖流式跨 chunk 与 UTF-8 codepoint 边界；多个 credential 前缀重叠时采用最长匹配，不能因替换 secret 产生非法 UTF-8 产品事实。除 Custom Provider create/replace 与 MCP captureSecret command 的调用期手动凭据外，credential 不进入 Bridge 或 Renderer；credential、locator、Authorization header 和可重建 secret 的 metadata 永远不进入 projection、result、event、日志、产品历史或 checkpoint record。

### 2.8 版本提醒与下载交接

Update aggregate 独占正式版本比较、官方 manifest 接受规则、进程内检查时机和用户下载意图；Account、Models、Task 与 Agent 不参与该 authority。Application 只执行注入的 HTTP、timer、独立有界 worker 与系统 handler effect。worker 持有 owned 请求与窄 transport，不持有 Product/Native Runtime；完成回到主线程后由 Update 校验请求 identity、当前 release 和 admission。状态走现有 ProductDelivery context，URL 不进入 projection、日志或持久化。

官方 manifest 的必需字段为 `version` 与 `downloads`；后者按 `macos | windows` 与 `arm64 | x64` 提供已发布包的完整 URL。正式版本是无前导零的三个十进制 u32，按数值比较，不接受预发布、build metadata 或降级。已知字段严格验型、重复键与超限拒绝，未知扩展字段不产生行为。目标只能由 Host 构建目标选择，不能猜测另一架构或拼接文件名；缺少目标包仍可发布新版事实，下载不可用。服务地址与下载主机由唯一 Product 输入固定；下载仅接受官方 HTTPS 主机、无 userinfo/显式端口/fragment/空白控制字符的有界绝对 URL，保留 query 原字节。

后台检查只在显式启用的分发构建中，于主窗口就绪后延迟启动并按进程内单调时钟周期运行；手动检查可提前，同一时刻最多一个在途检查且共享结果。失败不立即重试，不阻塞其他产品路径；不持久化检查时间、远端 manifest 或忽略版本。有效 manifest 原子替换已确认 release，失败保留上次事实但不得声称本次已是最新。请求无账号凭据、产品内容或设备身份，TLS 正常验证、拒绝重定向，正文与耗时有界。

下载命令必须绑定用户看到的版本；Host 重新校验当前 release/目标/URL，不能改投较新版本。用户点击授权一次有界 HEAD 预检及随后系统浏览器交接：2xx 可交接，404/410 为明确失效，405/501 仅表示 HEAD 不支持、仍可按原授权交接；其他 HTTP、网络与超时保留暂时不可用的真实原因。预检不读取安装包正文，也不证明随后 GET 成功。打开前再次校验版本和 URL，预检结果只能消费一次。系统 handler 受理不等于下载完成或安装；失败只提示显式官网动作，绝不自动换目标、跳官网或重放 effect。

连接撤销使尚未交接的下载意图失效；检查结果可继续作为全局事实供新连接读取。shutdown 先关闭 Update admission、撤销 timer 并取消/join 独立 worker，之后才能释放依赖；迟到结果不得重新发布或打开浏览器。检查与预检不使用 Agent/Task Executor。后台完成的主线程 wake 丢失时只由同一 coordinator 的有界完成 timer 收口，不借 Renderer 轮询。

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
- 工作区目录与文件预览由 Product Control 按当前 Task membership 和 Workspace id/epoch/root/authorization 接纳，在既有 File Preview bounded lane 中执行，worker 只持有深拷贝事实。目录只枚举请求的一层，路径逐段 no-follow 打开，不授予工作区外路径或跟随链接的能力；文件预览复用文本脱敏与原图检查/传输。完成、图片分块、取消与 shutdown 继续检查当前授权；目录名在发布前检查当前已知凭据，命中条目整体省略，不发布被改写后仍可点击的 locator。目录与文件内容不写历史、Snapshot、日志或磁盘缓存；目录上限和 wire 由 [Renderer Bridge 合同](renderer-bridge-contract.md#workspace-file-browsing-commands) 唯一定义。
- 文档预览的物理资源调度由 Product Control 拥有，转换不占 File Preview lane。XLSX 的只读网格与保存值版面属于同一冻结源、同一资源及授权生命周期，切换不重新准备；版面不支持/超限只撤销该视图，独立验证的网格可以继续使用。源正文、实际网格与可用的生成 PDF 文字在任何内容发布前通过当前安全代次的凭据检查；Application 只发布 owned 文档 effect：worker 准备、读取和清理，主线程仅在 worker 完成后借用材料，清理成功后释放组件 pin；尚未排队的新 effect 可直接放弃。每份资源串行执行，关闭先撤销读取并取消在途工作，不能把逻辑 handle 消失当作物理槽归还。无法确认进程静止或清理失败的资源保留槽位和引用，不自动重试取得删除权限；shutdown 先 join 执行，再在 worker 清理，主线程最终释放。该内部调度边界不授予 Renderer 内容权限；Runtime 仍须独立校验目标、Task/Workspace、连接、安全代次、期限及正文凭据检查，Bridge 合同未开放的文档操作不得据此暴露；
- 文档源冻结区分交付成果和普通文件引用：成果必须与交付时的大小、摘要一致；普通引用由 worker 捕获实际源身份，再验证复制及后续读取的同一份字节，不能在源变化后静默重新采纳新版本。会话的授权 policy 只在主线程调用期间借用，不保存在 worker effect 中。发布摘要或内容前须在当前安全代次下完成提取正文和实际网格投影字符串的有界分步检查，匹配跨步边界的已知 credential；命中、检查失败或未完成均不得发布 ready。检查范围不包含 OCR，栅格字节扫描不替代正文检查。一次页面读取核验源并冻结该次传输的页面字节；分块运输重新校验 Product authority、安全代次和连接 grant，不在主线程重复文件哈希。页传输释放与文档会话释放分别收口；撤销、组件变更和期限失效不得交付迟到内容。正式 Runtime、Bridge 和 timer 接入须各自验收，内部会话状态机或注入 policy 的回归不能单独证明整条产品链路；
- Host 生图文件引用使用 Agent 验证的当次保存凭据，来源随既有 file reference 持久化；旧记录缺省为普通引用，恢复不解析工具文本补授来源。该来源只允许直接图片预览，不等同于 typed Output 或文件变更；
- File Changes 使用独立单 worker、有界 in-flight 的 artifact lane。diff 在入队前按当前及历史 Task credential 脱敏，worker 只持有 immutable Task/run/change identity、owned diff 和专用 store capability；完成回主线程后重新校验 Product artifact ownership。stale 或 Task 已删除的成功写入立即回收，读取结果在跨 Bridge 前再次校验引用仍属于同一 Task/Run/change；
- async completion 必须按开始时冻结的 attempt、object identity、epoch/generation、attachment 与 shutdown token 全量重新校验。任一 token stale 都只销毁 candidate，不安装、不自动重放原请求；
- capability 只在同步调用或明确的 worker lifetime 内借用；关闭开始后不得建立新的 job、timer、callback 或 responder 对 owner 的引用。

自动评审的审批权与历史仍由 Task 拥有；独立 `permission/review` leaf 只构造有界输入、发送固定策略并严格解码一次无 Tool Completion 的建议。Product Control 拥有独立、有界的 job 执行与回收，不借用被同步 callback 占用的 Run executor。job 只持有深拷贝输入、冻结 execution binding、独立取消 token 与身份令牌，不持有 Task/Run 指针、Session access 或 Task worker lease。取消中和尚未回收的 job 仍占容量；shutdown 必须先取消并 join 全部审核 job，再释放 Completion、execution binding 及其依赖的 transport owner。删除 Task 不等待审核 job 的 Task lease，迟到结果由身份重新校验丢弃。

Task 拥有捕获的自动评审模式、当前请求状态、结果接纳与审批历史。preparation 只转移有界 owned 输入和完整身份令牌，用户文本或明确选择的 Skill/附件 metadata 可解释意图；未提供的 Skill 指令、附件内容和脚本效果不得被猜测为授权。超限或准备失败保留原人工等待，同一请求不因轮询重试，只在新的请求重新准备。 固定 Host 生图工具的评审输入还必须携带 Agent 拥有的实际效果说明，明确可能收费、失败或中断后可能已生成及不可自动重试；只按精确 Host namespace/name 取得该事实，同名 built-in/MCP 或模型参数不能提供或覆盖它。效果事实不授予权限，不携带 credential 或推测价格，也不改变[产品需求](requirements.md#55-审批与输入)定义的自动评审资格。

审核必需输入包含当次用户意图、最近一段 Agent 文字、工具名、参数和工作目录；必需输入超限拒绝而不截断。历史用户指令从最新完整消息组向前选择连续后缀，按最终 JSON 编码使用全部剩余容量，首个放不下即停止并计数省略消息，不能使合法必需输入失败。当前 AgentCore 合同没有提供与待批请求绑定的完整前序工具调用事实，因此历史工具输入和结果不进入评审输入；Host 观测顺序、进度采样或单条 Permission provenance 不构成完整性证明，不据此选择旧脚本内容作为补证。Product 在发送前脱敏已知 credential，并按 JSON 解码后的字符串处理转义值；builtin、Host 与 MCP 统一复用现有参数脱敏和有界输入，不因 namespace 或没有工具描述整类回退；准备失败保留人工。上下文和原始参数仅存在于有界内存，用完清零，不进入日志或历史。策略引用、lifecycle 注释不进入模型请求。审核建议经 projector 脱敏后，先保存在当前请求运行期状态；转人工不预建 UiRecord，回答或取消时才随唯一终态记录保存可选 `review={outcome,cause,reason}`。复制早于 settle/invalidate，rollback 恢复当前解释。旧 `review_reason` 仍仅属于 reviewer 决定，人工和取消的模型理由只进入 `review.reason`；取消没有决定来源。请求解决前崩溃或终态保存失败可能丢失本次原因，不承诺完整审计；旧合法历史未带来源时仍按原用户决定恢复。Completion 生命周期由[Completion 架构](completion-architecture.md#6-取消与生命周期)定义；模型判断不是安全边界。

准备与提交均在 Host 主线程经过 Task authority。结果接纳必须精确匹配 Task、Run、generation、binding、Workspace epoch、route、request、policy 与评审 generation，并重新确认当前 Workspace authorization 和当次 `responses[]`。`allow_once` 只映射 `allow_once`，`deny` 只映射 `deny_once`；其他建议、失败、取消、超时、容量或准备不足均 settle 为人工，不重试同一请求，不使原 Core request 过期。人工与自动共用既有 prepare/deliver 入口，谁先被 Host 接纳谁生效；人工 prepare 立即使旧评审失效。自动 candidate 必须 confirmed durable commit 后才能 deliver，失败或 outcome unknown 回滚并保留人工等待，不沿用人工决定的 best-effort 保存路径。
Run 连续拒绝计数仅在自动 deny 经 confirmed commit 且 deliver 成功后增加；Task attachment 按 Run 身份持有，不持久化，请求级 invalidate 不清除跨请求计数，settle 的人工路径结束序列。连续第三次有效 deny 将当前请求以 `rejection_limit` settle 为人工，保留该次模型建议与原 callback，不自动 deliver，不提交未解决记录；用户成功回答后清零并恢复自动，rollback 保留当前解释，模式切换和新 Run 清零。不存在整轮人工接管、Core mode mutation 或自动重发。

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

Run 准入时预留固定容量的独立 owned 错误存储，Product 在 Agent 结果释放前按值复制合法 `model_error` 并随终态一次性发布；捕获不新增分配失败点，Run 关闭静止后唯一释放。其容量复用 Agent 公共错误值，不借用 Session 或 SDK 存储；冷历史仅为实际存在的错误分配该固定值，保持历史记录本体的既有内存上限。Host 使用既有 credential projector 清洗 message、code、type 与 request ID，分别保留上游截断和 Host 清洗/截断事实；后续首次获知、替换或释放凭据时再次清洗。该观察不改变 Agent 执行结果、Session disposition 或 Product 原有终态优先级；普通 ABI/callback 或后续 pipeline/合同失败附带的合法观察仅作补充。Agent Run identity 只作执行来源，不成为 Product 路由。错误正文不进入日志或 event pump，不从 diagnostic 反推详情。

来源类别在执行准入时从 Models 的真实来源冻结为 Metask 或 Custom Provider；历史缺失时保留未知，不从模型名、协议或当前绑定猜测。Product 纯策略根据 category、来源和主终态生成恢复建议，Renderer 只显示对应入口；鉴权/支付对 Metask 提供 Account 设置入口，对其他或未知来源提供模型设置入口。建议不改 Account 状态、余额、Models 可用性或当前 generation，不执行登录、支付、模型测试或整轮重放；`retryable` 只描述上游请求层。非 provider_failure 的补充观察不提供恢复动作，历史观察也不授予当前操作资格；准备重试仍由当前 Task 的既有 gate 决定，且只把可恢复文本填回 Composer。

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

审批模式由 Task 当前 profile 与自动评审事实派生，连同非零 approval revision 随 Task 恢复；合法旧 metadata 缺少 revision 时从初始 revision 恢复，不重写历史 Run 的 profile。全局 default mode 独立持久化，缺少新字段的合法旧 metadata 从原 default profile 派生，缺少 Task 自动评审事实时保持人工。历史 Run 的 profile 可以不同于 Task 当前 profile，UI 审计按所属 Run 的 profile 与 interaction 校验，不能因当前模式变化丢弃合法旧决定。运行期 generation、当前评审 identity 和 in-flight job 不进入 durable history，恢复不得重放待决评审或审批。UI 历史只保存来源、typed permission 摘要和审核 outcome/cause/脱敏有界 reason，不保存原始输入或模型输出；旧非取消 UI 决定缺少来源时按用户恢复，取消保持无来源。历史决定、理由和摘要本身不具有当前授权效力。

Run/compact 的 terminal result 由 Agent 以自包含事实返回，Product 在预留 record 中 no-fail、write-once 提交后才能通知、释放 worker reference 或推进后续事务。queued-before-execute 由 Product 生成独立的 pre-execution terminal fact；Agent Session snapshot 只描述 live lifecycle，不承担历史 terminal truth。

Run durable record 在 Product 接纳输入时至多一次记录 nullable wall-clock 提交时间。时钟不可用或旧 canonical record 缺少该字段时保持 null；恢复不得迁移、推断或用完成时间与加载时间补写。该事实只描述输入接纳，不承担 Agent 开始执行、排队耗时或事件时间线语义。

Run 接纳执行时可以保留 runtime-only 单调起点；Product 在完整 terminal event-drain barrier 首次形成正式终态时用同一单调时钟冻结 nullable 最终耗时，并随 Run durable history 持久化。该值包含排队、批准等待和重试，写入后不可修改；时钟不可用、回拨或旧 canonical record 缺少该字段时保持 null，恢复不得用提交/完成 wall-clock、Tool elapsed、加载时间或 Run 顺序推断补写。active Run 的当前耗时只从 runtime-only 起点采样，不进入 durable record。

Task 删除是跨持久化、checkpoint、event、Session 和 worker reference 的独立 Product 生命周期用例，不占用 active-operation 槽；其 `idle | deleting | failed` 状态只存在于当前 Runtime，不进入 durable Task record。删除无需归档，受理不改变原 archived；受理时取消等待输入与接续并失效待决审批，Product Control 通过既有 operation owner 请求停止，禁止新 admission。删除意图可以先进入 `deleting`，但只有相关 active operation、checkpoint、terminal event、Session access 和 worker reference 全部收口且 durable history commit 成功后才能物理移除 record。明确失败或结果不确定只使本次删除进入可诊断失败；用户可以重试删除。Task 已回到 open 且安全时，恢复归档或未归档 Task 的显式新消息、归档在接纳同一 mutation 中清除 failed，拒绝不清除；仍 closing 或结果未知不得借此绕过原事务 gate。删除意图不持久化，重启不自动继续；Task 的其他可用操作与整个 Workbench 不得因此冻结。

### 4.3 `workbench-history.store`

可信成果元数据和可省略的展示详情分开保留。交付回执与 Host 生图引用受既有每 Run 数量、路径及字段长度、历史存储和 Bridge 块边界约束，复制仍经过同一 Host 全量凭据清洗；它们不消耗可淘汰的普通文本详情额度，也不建立新的全局预留或准入机制。生图引用归属于不可淘汰的最小 Tool 记录，必要时省略普通 Tool 行；Tool 名称和产品身份的运行时计费标记不进入持久化格式，冷恢复由可信生图引用重建同一所有权。allocator failure 仍是 Host 失败，不伪装成普通容量缺口。

Agent worker 只在预留的 Run execution owner 中写入有界回执尾部，并随 terminal release publication 交给主线程。主线程在该 Session 队列消费完后，按稳定身份去重并接纳回执，再发布 Product 终态；worker 不直接修改 durable Task。其槽位、路径及原 Tool 关联不依赖展示事件队列，Task 删除与 Run retirement 遵循同一静止和释放屏障。


`<MetaWork data dir>/workbench/workbench-history.sqlite` 是 Workspace 与 Task 产品历史的唯一 canonical store。Application 在 restore 前取得进程级 OS writer lock，拥有具体 Storage Database 和文件生命周期；Product Control 拥有 schema、逐行增量提交、跨记录校验与健康状态。普通业务提交不得写回旧 framed store，不双写。所有借用和历史 worker 收口后才关闭 Database。

Run 模型错误作为可空 typed 附属值与该 Run 的终态在同一历史事务保存；保留安全文本、执行来源、typed 分类、请求重试事实及上游/Host 清洗截断事实。旧 SQL 和首次导入的旧 Run 缺少该值时恢复为 null，不从诊断文本重建。恢复只重建观察，不执行登录、支付、请求或工具；当前操作资格不得从历史错误继承。字段继续参与 SQL、只读/保留 payload 和候选的统一 credential 检查与再清洗，实际清洗须保留 Host redacted 事实。持久化通过追加迁移扩展已发布身份，不改写既有迁移。

Run 的成果元数据只能由 Agent 已验证的独立 Host 回执登记；普通工具文字、文件引用和 File Changes 不构成成果。记录归属其 Task/Run 与 Workspace，只保存非零成果身份、Workspace 相对 locator、交付时的大小和 SHA-256，不保存文件字节或组件版本。相同身份与相同内容重复到达不增加记录，身份冲突或超出有界容量必须拒绝。locator 经过现有 credential sanitizer；被脱敏或截断的 locator 丧失文件操作 authority，写入历史时必须为空。恢复仍须重新检查 Workspace authority 与当前文件内容，历史元数据本身不授予读取权限。该附属集合随所属 Run 的 SQL 记录保存，旧记录缺少 `outputs` 时恢复为空；不得重放交付动作。记录随既有 Tool result durable boundary 提交，保存失败继续遵守本节的 best-effort health 语义。

成果文件操作由 Product Control 按 Task/Run 与成果身份解析当前可信记录，拒绝尚未退出删除事务的 Task、失效 Workspace 以及脱敏或含已知 credential 的 locator。进入异步文件工作前须复制根路径、相对 locator、交付摘要和大小、Workspace 身份及安全代次；不得借用 Task 内部指针。该 owned 输入只是一次操作的冻结事实，不是持续授权：在 worker 返回后、发布内容或执行系统动作前，必须重新核对 Task/Run/成果、Workspace 根与代次、locator、交付内容身份和安全代次。文件读取还须独立证明实际字节；两项检查不能互相代替，也不替代 Bridge connection/window 的有效性检查。当前字节校验消费 Application 冻结的文件读取能力，使用独立、懒启动且有界的 worker，不占 File Preview lane；校验结果只包含状态，不持有文件内容。请求期限、取消与 shutdown 都须先停止执行并观测物理静止，再由主线程释放 effect 和冻结输入。定位源文件只在当前读取字节与交付大小、摘要一致、当前 Product authority 通过且 Bridge 请求仍有效之后，在主线程通过 Application 注入的窄 effect 调用 Native SDK Runtime；读取校验、显示路径或先前 ready 结果不能单独触发定位。取消、断连或安全代次变化不得在 worker 返回后补发系统动作。另存由 Application 的系统保存对话框选择目标，并返回只持有冻结源身份及所选目标的 owned effect；Product 和 Renderer 不接收该目标路径。worker 将实际读取的同一份字节校验后暂存，再等待主线程核对当前 Product authority 和 Bridge 请求；主线程的一次性发布决定是保存提交点。提交前撤销会唤醒 worker 丢弃，提交后取消须被拒绝，shutdown 等待已提交的发布完成。保存终态据实际 I/O 返回，不因之后的 Task、连接或安全代次变化虚构 cancelled；该结果不授予未来读取权限。失败保留已有目标，暂存清理失败必须单独报告。

正式 SQL 不存在时，单向导入旧 canonical framed store，保留合法事实、只读 payload、无法解释的完整记录及身份高水位；不读取更早的 JSON envelope 或开发期废弃格式。导入在同目录临时库中完成，经完整 loader 校验、WAL TRUNCATE 和连接关闭后才 rename 发布。原 framed 文件原样保留；成功迁移后不再读取、清洗、写回或自动合并它，本阶段不删除或自动隔离。既有 SQL（包括已发布版本创建的库）直接使用 SQL，不为核对旧来源重新读取 `.store`。正式 SQL 一旦存在就不退回旧 store。缺 canonical 但存在恢复证据不是首次启动；未知 schema 版本不得保存、quarantine 或替换正式库，即使显式恢复也必须拒绝。损坏或不可读的当前版本历史不自动覆盖，沿既有显式恢复入口保全原件和现存 DB/WAL/SHM 组件，再发布经验证的关闭候选。

framed 恢复分类必须包含实际 Task 恢复约束：仅解码或局部校验通过、但完整恢复失败的 Task 继续保留原帧，不能使整批导入或随后携带保留帧的正常保存失败。同 kind、同身份的多条保留帧仍是不同 occurrence，必须保留各自 payload、顺序事实和重复次数，不能按身份覆盖或按内容去重。Automatic Workspace 的 owner 无法恢复时，其 scope 原帧一并保留；只读映射只引用已恢复的 Task，高水位不因降级而倒退。默认审批偏好的导入回退复用 Runtime 判定并反馈启动降级事实，不改变历史 Task/Run 的权限；执行资源、I/O 或提交失败仍中止导入，不发布空候选代替有效记录。当前 SQL 加载与业务候选继续严格校验，导入恢复不构成静默 SQL 修复路径。

历史凭据检查与清洗共用字段分类：自由文本及携密内容须清洗，结构 tag、枚举及固定格式身份和摘要不因字节巧合被替换。只读记录须保留未知字段、数值精度与数组顺序；保留原帧的无损要求以安全清洗为例外，命中时可脱敏但不得丢记录或改变身份、顺序与重复次数。Control 持有的保留及只读原文、SQL 必须一并纳入维护，防止后续候选重新带回旧原文；未命中 payload 保持原文。已退出运行路径的旧 `.store` 原样留存，不参与凭据维护，也不为它延长 credential lease；该遗留副本可能保留明文，不承诺已清洗或清除，删除另行定义。维护复用现有安全代次及有界 credential lease，不能改动 worker 正在读取的 owned 输入或未知事务的确认依据；清洗失败继续保留必要 lease 和可诊断状态，未完成前不得报告安全 ready。

非健康 history store 的显式 recovery 必须校验全局 revision，并由 Product 编码当前内存 Workspace/Task snapshot；Application 只能把当前 canonical 文件改名为唯一 quarantine artifact，再通过既有 durable atomic replace 安装该 candidate。读取/codec 失败时当前内存为空，因此形成 canonical empty history；write failure 或 outcome unknown 时保存当前进程仍持有的有效历史。失败不得清空内存或删除原文件，outcome unknown 继续发布 typed health；只有 committed 才恢复 ready。Renderer 不接触文件名、路径或 bytes，quarantine artifact 不进入 snapshot、日志或自动清理。

交互式 Product Task mutation 以内存 Runtime 为当前进程真源，持久化是 best-effort projection；保存失败不得回滚已经接纳的新建、Run、模型选择、权限响应、重命名、归档、取消或 Workspace 导航 mutation。Schedule occurrence 是独立的无人值守边界：Product Control 必须为其 Task create、命名与 Run intent 注入 required durable effect，任一步未可靠提交都拒绝本次 occurrence，Schedule 按既有 transaction 进入可诊断状态，但不得冻结其他 Product Task。若 required commit 明确失败，Control 回滚候选并删除仍可证明未发布的 Automatic Workspace 空目录；若结果不确定，Control 同样回滚内存 Task/Run/Workspace 候选但必须保留物理目录，因为 canonical store 可能已经引用它。两种拒绝都保持 occurrence `task_id = 0`，不得伪造 interrupted Run 或 terminal cause。Task 物理删除仍遵守 §4.2 的 commit-before-release 边界。

completion receipt 是上述 best-effort Task projection 的低频视图事实。acknowledgement 只修改当前内存 Task 并发布 revision，不得为每个前台完成额外强制重写完整 history store；它随下一次既有 Task durable commit 或 clean shutdown 的最终 commit 合并写入。异常强杀可以丢失尚未进入 durable boundary 的最后一条 receipt，但不得损坏或回滚 Task/Run 历史。旧 Task record 缺少 receipt 字段时，必须在恢复出 canonical Task 并完成无 live owner 的 interrupted normalization 后，把当时最新 terminal `completed` Run 初始化为已读；当前 writer 始终写出明确数字，避免升级后把全部历史完成误报为新提醒。

旧 framed 导入源仍遵守其原有读取边界，正式 SQL 不继承整库 16 MiB 上限。普通提交通过 SQL 原子事务确认，区分 `committed | failed | outcome_unknown`；临时候选仅用于首次导入及显式恢复，关闭后同目录发布。具体额度、帧布局与 SQL 字段由唯一实现与测试拥有，不在本文镜像。

Host 重启从通过校验的 store 重建 durable history 和 detached attachment。没有 live owner 的 non-terminal Run/compact 保守收口为 interrupted，不重放输入、工具、permission 或结果不确定 mutation；所有在进程终止时仍为 `pending` 的 Run/compact 都原子转为 `excluded`，terminal operation 保留原 phase/outcome，non-terminal operation 再收口为 interrupted。其 File Changes `collecting` 若存在必须收口为 `incomplete` 并保留已记录项。旧历史缺少 Run 提交时间或 File Changes 字段时恢复为 `null`，不能伪造时间或空观测。未完成 Tool 不进入恢复 projection，已经 durable 完成的 Tool result 保留。

#### 4.3.1 History schema

Product Control 统一拥有同一个 history 数据库的结构和有序迁移清单，业务 aggregate 不独立执行迁移。schema 是无状态模块，直接产出 Storage 的 `sql.Migration`；版本从清单推导，新建与升级共用同一条迁移链。清单在编译期校验连续版本和有效 UTF-8/LF 字节，已成为需保留数据库身份的历史迁移不得原地改写。唯一建表 SQL 拥有精确列、约束与索引定义，文档不维护第二份字段表。

历史 SQL 表达保留原有完整 u64、可空状态与已有身份关系。Workspace 和 Task 顶层集合按身份升序恢复，容器槽位不属于持久化语义；导航保持业务排序，排序条件相同时按身份升序确定顺序。追加输入已有严格递增的身份顺序，按该身份恢复。Run、工具、文件变更、Compact、UI history 和输入提交保留原有数组顺序，不能以 generation 或 activity order 的唯一性推断数组递增；这些事实各有独立语义。独立表须有当前查询、更新或容量收益；随所属记录整体读写的有界附属集合使用 typed JSON，单个可选附属记录可以使用全空或全有的字段组。关系列中的 u64 用等长 big-endian BLOB 表达，自由字符串用 UTF-8 字节 BLOB 保留现有 codec 接受的 NUL，有限 tag 与有界嵌套 JSON 使用 TEXT。JSON 直接按 Product wire 类型编码和解码，u64 不经浮点中转，JSON 内数组顺序与转义字符串必须无损。SHA-256 引用以 32 字节 BLOB 存储并与原有小写 hex 精确转换。

DDL 负责关系列的非空、存储类型、局部唯一性与父子关系；JSON 内的数量、字段、唯一性、引用以及跨记录语义由 Product 校验，不能把 SQL 写入成功视作历史有效。Product 继续校验 UTF-8 与字节预算，加载还须覆盖原编码器的恢复失败记录限制和实际 Task 恢复中的 checkpoint 校验，不能仅凭局部 candidate 校验或字段往返宣称可恢复。合并或移除物理表不能丢失恢复诊断，历史权限仍不具有当前授权效力。

父子记录的物理删除由 Product 在同一事务内显式完成，外键延迟到提交检查且不得级联删除；遗漏子记录须使整个事务失败。单个可选 checkpoint 使用同一组完整字段表达 Run、Compact 与审批 anchor，不能按 anchor 种类分裂存储；审批 anchor 的 revision 上界同时受行内 SQL 约束和 Product 校验。局部约束与非主键唯一性必须可在既定 Storage 权限内演进，不以关闭外键或放宽 authorizer 作为升级前提。

持久化 JSON 的结构、枚举域或接受语义发生版本变化时，必须同步推进唯一 migration identity；即使没有 DDL 也须有标记迁移，使旧版本在解码前以 `VersionUnknown` 拒绝写入和替换。验证须覆盖允许持久化的枚举全集及未知值拒绝，不将运行时专用状态误当作持久化能力。

schema 迁移仅建立空业务表，不建立默认 Runtime 状态。迁移完成不等于 history ready；loader 必须验证业务状态和完整关系，不能把已有业务记录但缺少根状态的库当作空新库。`MigrationMismatch`、`VersionUnknown` 与恢复资格归 Product Control，Application 只转交开库结果和执行被授权的文件 effect；不能自动清空、重建或把一次主文件 rename 当作完整 WAL 恢复。

普通同步保存仅在调用期间借用 typed 候选；Repository prepare 必须独立拥有后续提交和确认需要的 SQL 参数、索引及 witness，不能保留对调用方内存的引用。已有跨线程审批及恢复任务独立拥有 typed 输入，沿用同一 writer、lease、完成通知和确认屏障。普通保存严格校验完整候选；任一 Task 无效时拒绝整次提交，保留内存事实并报告不含 secret 的 Task 身份及失败类别，不隐式降级成保留帧。旧 store 导入仍按逐条恢复规则降级。启动由 Application 移交 owned typed 恢复结果，Product 恢复后释放；SQL 加载不经过 framed 编解码，分页超出 Storage 预算时必须丢弃整页后缩小重读，不采纳部分结果。

生产使用单个串行写入者。每次提交将已确认行摘要与完整候选事实比较，只写变化及删除；此前失败、TaskBusy 跳过和被动已读回执都必须随后续候选补齐，只有整个候选被确认才恢复 ready。共享业务原子组不拆分；大候选按 Storage 输入额度分块，同一事务提交全部块及 witness，不把单块额度当作累计历史上限。每次新 prepare 由 Application 的安全随机源生成 32 字节不透明提交标识，随机失败拒绝写入；该标识与单调 generation 组成 witness，与变化同事务保存，不作为全量内容摘要。结果不确定时保留 Prepared 和原 token、暂停后续写入及磁盘清洗，重开并读回原 witness，再完成 Storage 同步确认，不重放业务 effect。凭据首次获知时清洗当前及保留历史，清除旧 WAL 版本；重复借用不重复触发维护，未完成清洗的有界凭据副本不得提前释放。旧迁移源不再参与日常清洗，不影响 SQL 保存及安全状态；SQL 本身的清洗及 purge 失败仍须保持原有屏障。历史写入 capability 冻结凭据安全代次；首次获知凭据后，旧代次候选即使尚未派发、且凭据后来已释放，也不得再写入。未确认事务只能读回原 witness，不能借换代重放；冻结缓冲释放时清零。历史 Task 数不消耗 Session 名额，Task、Run 和 Compact 集合按需增长；借用中的记录地址必须稳定，Run/Compact 仅在全部 worker lease 静止后移动容器。历史额度与 Renderer 单次快照、catalog 额度分开，达到历史额度保留既有历史并拒绝新增占用，不删除旧记录。

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
- target ExecutionConfig 能够承载所选模型，且其 generation 在 start 到 commit 期间保持不变；已有显式模型意图时按精确来源解析完整配置，允许更换 protocol，不依赖全局默认；旧记录没有来源意图时要求用户先明确选择模型，不推断历史来源或借用起始偏好；
- persistence、checkpoint store 与 Agent Runtime 可用；
- Task 未归档、删除、运行其他 operation、replacement 或 shutdown；
- 当前 recovery attempt 和 poison 状态允许进入。

checkpoint 必须与 covered 前沿精确相等，并且不能存在 pending operation；`checkpoint <= Product history` 不是合法替代。checkpoint 之后允许存在且仅允许存在连续的 excluded 尾部。若历史中出现晚于 checkpoint 的 covered operation、checkpoint 前沿不是最大 covered id、anchor 未 covered/terminal 或存在 pending，恢复必须拒绝。所有新 Session 的 Run/compact allocator 都以各自 Product operation history 高水位为 floor，UI request allocator 则以 durable UI history 高水位为独立 floor；restore expectation 仍只使用 checkpoint 自己的精确 Run/compact ids，任何 allocation floor 都不得替代 expectation。

唯一无 checkpoint 恢复例外是：Task 没有 checkpoint record、covered 前沿均为零且没有 pending operation。此时 Product 可以在原 Task 上 fresh attach 空 Conversation，以完整 Product operation history 和 durable UI history 高水位初始化各自 allocator；全部 excluded 历史继续可见，不进入新上下文，也不自动重放。只要存在 covered 历史，checkpoint 缺失、损坏或 store 不可用都必须 fail closed。

历史 execution generation 只证明历史 Run 使用过哪个 execution，不是恢复当前 credential 的句柄，也不要求等于 target generation。Skill、MCP、Permission 和 projection continuity 是恢复后的可选能力状态，不是 Conversation 恢复资格；AgentCore 合法返回 degraded Session 时，Product 接受已恢复 Conversation，并让不可重建 authority 保持安全失效。

冷恢复按 Task 的显式目标解析新的 owned 配置并分配 execution generation；安装确认后推进 Task binding epoch，历史 Run identity 保持不可改写。

detached Task 的显式模型意图沿同一恢复事务提交：冻结该来源的当前 authority，先按旧 checkpoint 的模型 expectation 恢复，模型改变时设置目标模型并导出对应 checkpoint，确认实际 model/protocol/binding 后才能安装。原模型未变时可沿用原 checkpoint，不能为冷恢复额外制造新的覆盖事实。没有原 live attachment 时，不构造原连接 credential 或进程前的 Skill/MCP 恢复输入，也不执行原配置回退；失败保持原 Task、意图和历史，等待明确重试。目标来源或模型已失效时不得借用全局默认。无 covered 历史且没有 checkpoint 的 Task 仍可走既有 fresh attach 例外，并使用所选完整配置。

用户显式发起恢复后，Product 冻结完整 source/target authority 并提交 bounded recovery job。checkpoint restore 与上述空 Conversation fresh attach 使用同一恢复执行与提交边界；job 不保存 Task/Workspace 指针，不查询 Product Skill，不构造 MCP Selection，也不取得 durable permission rule，只按不可变输入验证 checkpoint source 并调用 Agent restore，或创建符合无 checkpoint 例外的空 Session。I/O、Agent Runtime、capacity、cancellation 与 typed AgentCore refusal 必须作为 attempt 结果返回；排队取消或一次失败结束本次 attempt，不得隐式重试或重放历史。

成功 candidate 回到主线程后必须再次校验全部 source/target token、attachment、archive/removal、replacement 与 shutdown。持久 adoption 前失效的 candidate 只销毁。若 target generation 与 durable binding 不同，主线程只捕获独立拥有、无 secret 的 typed 候选历史，由既有共享 bounded history writer 执行一次 durable adoption transaction，同时推进 Task binding、binding epoch 与存在的 checkpoint anchor；保存待决时，旧内存 binding 不变，candidate 与恢复 lease 保留，不能发布 attachment。确认提交后先接受 canonical binding，再重新校验 Session 安装资格；外部 authority 在保存期间失效时丢弃 Session，但不得回滚或覆盖已确认的 binding。明确失败结束 attempt 并拒绝 candidate；结果未知保留 exact 候选历史、Session 与 lease，冻结其他 history write/recovery，只有显式恢复动作可以排队执行不写入、不 quarantine 的 canonical 读回。读回仍未知或取消不得丢弃候选、隐式重试或推测结果；确认 candidate 或旧 canonical 后才分别接受或拒绝 adoption。事务期间的独立产品事实由后续共享 writer 补齐，补写失败不得由生命周期轮询自动重试。

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

`.skill` 是 MetaWork 对外可交换的 ZIP envelope。规范 archive root 必须直接包含精确大小写的 `SKILL.md` 及同一 Skill 的相对资源；本地目录和 ZIP-compatible 安装包导入只允许所选根本身或唯一的一层 wrapper directory 成为候选 Skill root。排除平台 metadata 后，整个候选只允许一个精确 `SKILL.md`；多个定义（包括嵌套示例）、多个候选根、更深 wrapper 或缺少 root 均失败。预览与提交共用根解析规则，提交仍重新检查源摘要，不把预览当作可绕过源变化检查的安装快照。

导入必须在目标 root 之外 materialize 为 staged tree，并拒绝 absolute、drive/UNC、空、`.`、`..`、NUL、非 UTF-8、重复归一化、Windows 保留名和尾随点/空格路径；symlink、hardlink、device、socket、FIFO 与其他特殊 entry 一律拒绝。Importer 只读取或复制 regular bytes，不执行脚本、不解析远程链接、不访问网络。

稳定资源上限为：

- 最多 512 个 regular files；
- 解压总量最多 64 MiB；
- 单文件最多 16 MiB；
- UTF-8 相对路径最多 512 bytes；
- 单 path component 最多 128 UTF-8 bytes；
- `.skill` 压缩输入最多 32 MiB。

目录与归档从候选中排除 `.git`、`__MACOSX`、`.DS_Store`、`Thumbs.db` 和 AppleDouble `._*` metadata。排除不豁免原始归档的路径、entry 类型、重复路径、压缩方式和输入/展开容量校验，不授予 metadata 中的链接或特殊文件任何访问能力。

export 服从同一文件、定义唯一性和路径边界，使用稳定相对路径顺序，不包含绝对路径、provenance store、credential 或上述 metadata。成功导出的 `.skill` 必须能通过同一 importer 的机械检查，输出大小包含 ZIP header 和目录开销，超过压缩输入上限明确失败，不能只按展开总量判断。具体 ZIP library、staging 目录、hash 实现和文件事务 helper 由代码与测试拥有；上述 envelope、拒绝规则和容量属于稳定 artifact 合同。

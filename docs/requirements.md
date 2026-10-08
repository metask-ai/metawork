# MetaWork 产品需求

> 状态：v0.5，确立持续可达的成熟 Workbench、Task 执行配置与设置边界
> 日期：2026-07-22

## 1. 产品定义

MetaWork 是一款桌面端 **Agent Workbench**。它帮助用户在本地工作区中创建和管理 Task，观察 Agent 推理后的可见工作过程，处理工具审批，并查看最终结果。

MetaWork 的核心不是模拟终端或展示 Agent 执行流水，而是让用户围绕 Task 提交要求、在必要时介入并读取回复与结果。底层 Run、Tool、usage 和恢复事实只在其产品用途需要时进入界面。

本文只定义产品对象、行为、范围与能力要求；用户界面的信息架构、呈现、交互、视觉与 capability gate 由 [UI 设计规范](ui-design.md)统一定义。

## 2. 产品目标

- 提供清晰、稳定的桌面 Agent 工作入口；
- 支持一个或多个工作区及其 Task；
- 以结构化 UI 展示 Agent 文本、工具调用、进度、审批和结果；
- 允许多个 Task 独立运行和切换；
- 在取消、刷新、关闭和异常后给出明确且可信的状态；
- 首次启动直接进入 Workbench shell；可信 Snapshot 建立前不开放 mutation；
- 让用户在创建 Task 前清楚确认 Workspace 与模型，并把低频 API 管理收口到设置；
- 为未来的后台任务、持久化恢复、通知和多 Agent 协作保留合理产品边界。

## 3. 非目标

MetaWork 当前不定义为：

- 完整 IDE；
- Terminal Emulator；
- 旧 AgentCore CLI 的图形化字符镜像；
- 远程 Agent 托管平台；
- `.native` UI 迁移项目；
- 同时维护 React 和 `.native` 两套 Renderer 的产品。

终端能力未来可以作为一个明确的工具视图存在，但不构成 AgentCore 与 UI 的基础协议。

## 4. 核心对象

### Workspace

代表 Agent 工作所针对的本地目录、任务上下文和授权身份。Workspace 是独立产品对象，不得仅从已有 Task 的路径反向推导。Manual Workspace 由用户通过 Host 原生目录选择器明确选择或重新授权；选择器确认本身就是该目录的产品授权，不追加 `trust`、`Use this folder` 或 Renderer boolean。一个 Manual Workspace 可以承载零个、一个或多个共享文件上下文的 Task；Automatic Workspace 由 Workbench 在调用方请求系统分配时创建，一个独立目录精确归属一个 Task。两者共用同一个 Workspace registry、Task 引用和 AgentCore admission，`kind` 只表达目录取得方式；Renderer 不得从路径或目录名推断 `kind`。Workspace 当前不是 OS sandbox 或 strict security 边界；未来只有文件、进程、network、symlink 与 TOCTOU enforcement 通过独立 Gate 后，才能扩大其安全承诺。

### Task 与内部 Agent Session

Task 是用户可持续补充的产品工作上下文，归属于 Workspace，拥有消息、运行状态、Run 历史、Session maintenance 历史和不含 secret 的 execution binding 历史。Task 的模型 binding 独立于 Models 全局默认值：设置页模型只作为新建 Task 默认值；已有 Task 只有在 Models 当前 Metask catalog 与该 Task 精确持有的 source/protocol/binding authority一致时，才能在 Composer 选择下一轮模型。默认 credential、protocol、source 或 generation 已变化时，Task继续使用自身 pinned execution，模型控件只读。当前 Custom Provider binding不开放已有 Task模型切换。attached Task 在当前进程中持有一个内部 Agent Session 与 Conversation；Session 是执行生命周期术语，不是第二个产品对象或 Renderer 身份。Run、会改变 Conversation 的 maintenance operation 与 Conversation restore 共用一个 Product Task-owned active operation 槽，不能并发进入同一 Session。历史 Task 可以跨重启恢复为 detached 记录：已有 Conversation 历史时，Host 必须证明最新 checkpoint 精确覆盖所有 included operation，并证明 Task/binding、Workspace 与 ExecutionConfig authority；若从未形成 checkpoint 且全部历史都被明确排除在 Conversation 外，则可以在原 Task 上建立空 Conversation，并从 Product 历史高水位继续分配 operation id。两种路径都不得重放历史输入。Skill、MCP 与 Permission authority 是否完整恢复只决定恢复后的能力状态；它们失效时接受 AgentCore 的 degraded Session并安全收缩能力，不能否定 Conversation恢复成功。

当前 Agent Session 因运行失败进入 poisoned 后，Host 必须在本轮 terminal、checkpoint 与资源引用全部收口后关闭并释放该 Session，再把同一 Task 转为可恢复的 detached 历史；用户后续发送消息沿既有 Conversation restore/fresh attach 路径继续，不要求结束 Task 或创建新 Task。Session close 或资源 release 失败时必须保留真实的 attached/closing 状态并拒绝伪恢复，不能丢弃 owner、泄漏资源或自动无限重试。

MCP 不可用不得阻止普通 Text Task 创建。Task 标题附近的只读任务信息必须区分创建时已复制 MCP selection、MCP 已就绪但未选择工具，以及创建时 MCP 不可用；该事实不能被解释为可热附加能力，也不能包含 server、tool 或 credential 细节。

### Turn / Run

Turn 是用户提交的一次交互；Run 是 AgentCore 为该交互进行的一次实际运行。产品必须区分排队、运行、同步等待用户、已完成、已取消、失败和中断等状态。当前 ABI v1 提供的 `max_turns`、`tool_loop` 等受控停止不得伪装成完成或笼统失败；成本预算停止只有在 AgentCore 发布相应 typed capability 后才进入产品状态。

未来具备相应 AgentCore capability 后，再加入可恢复 `suspended`、持久化恢复和后台转换状态。

### Tool Call

代表 Agent 发起的一次工具调用，包含工具名、输入、进度、结果、错误和耗时。Tool Call 应通过结构化卡片展示，而不是依赖终端字符解析。

### File Changes

File Changes 是一次 Run 内由 AgentCore typed `file_changes` observation 记录的文件副作用审查事实，归属 Run 而不是单个 Tool。产品接纳 `created | modified | deleted | moved` 的 `applied | partial` 记录，包括嵌套 Agent 产生的记录；同一路径的多次修改在事实层保持多条稳定顺序，在 Review 呈现层聚合为一个文件区块。它不从 Tool 文本、Bash 输出、Git、Workspace 当前状态或 File Preview 反推，也不表示用户已经接受修改或文件仍保持当时内容。

### Approval / UI Request

代表 Agent 继续工作前仍缺少的授权决定；由用户回答，或在用户选择自动评审后由 Host 接纳审核器的本次建议。它不是 Tool 名称、Shell 语法或产品安全感的可视化。一个正式权限请求必须对应当前 authority 尚未覆盖、值得中断、可准确描述且执行层能兑现的具体能力或 effect；已由 Workspace picker、当前 Task authority、已配置服务或系统原生授权覆盖的决定不得重复询问。当前 MetaWork Agent 只开放 AgentCore 同步工具 permission；该请求仍是 compatibility baseline，不表示现有 payload 已具备上述完整 effect 语义。AgentCore ABI v1 虽支持结构化问题回答，但该 built-in 不进入 MetaWork Agent 能力集合。需要补充信息时，Agent 以普通 Assistant 回复结束当前 Run，用户通过 Composer 继续。同步等待期间 Run 仍占用 executor slot，不形成可持久化挂起点。计划审批、自定义结构化交互和 typed effect confirmation 只有在 AgentCore 发布相应控制协议并通过 MetaWork 产品验收后才进入产品范围。

### Account、Models 与 ExecutionConfig

Account 是 MetaWork 的 Metask 账号控制面，只负责 OAuth 登录、当前已验证 identity 与 Account credential 生命周期。Product Control 的 Models aggregate 是模型提供方，拥有内置 Metask provider、OAuth-authorized model catalog、Provider-local 与 global default selection、source generation、用户管理的 Custom Provider、模型持久化和解析合同。Account 的有效授权是 Metask provider 可用的前提，但两套体系不互相拥有：Account 退出使 Metask provider不能继续目录加载或新解析，不影响 custom source，也不回收已经交给 Task/Run 的 binding。Product Control 持有当前 active `ExecutionConfig` 与新 Task admission；配置包含 typed `protocol + model + base_url`、opaque credential 和 binding generation，Task 为实际运行取得 owned copy。durable Task 与历史记录不是 Account identity、Custom Provider identity 或 credential 的副本，只保存解释历史所需的 Workspace、protocol、model、opaque generation 和 binding facts。

### Scheduled Task

Scheduled Task 是 Workbench-owned 的持久自动化定义，独立描述“做什么、何时触发”。Task 是一次真实执行及其结果历史，Schedule 是触发规则，Skill 是独立的可复用执行方法；Scheduled Task 不保存 Skill identity、catalog revision 或参数，也不是 AgentCore Session、交互式 Task 草稿、Skill 子对象或第二套 automation 数据面。用户需要采用某个全局 Skill 时可以在任务指令中表达，但 occurrence 始终按普通 Text Run 重新经过当前 Execution、Workspace、容量和 shutdown admission，成功后创建一个新的真实 Task，再通过现有 bounded Executor 启动。每个 occurrence 都请求新的 Automatic Workspace，Scheduled Task 界面不提供 Manual Workspace 选择。Scheduled Task 只持久化无 secret 的指令、固定 PermissionProfile、触发游标、有界 occurrence 事实和 `ModelRef + source_generation + selection_revision + protocol`；不持有 API Key，也不持久化 Product Control 的进程内 execution generation。默认 profile、默认模型 authority 或 Workspace authority 变化时不得静默改绑或重放。occurrence 使用定义固定的非交互 authority，只能执行或以 typed reason 停止，不能进入同步 permission wait、临时升级或把通知当作远程审批通道。

### 持久数据与恢复

当前代码与合同决定新写入接受的格式；无法识别、损坏、读取失败、明确写失败和提交结果不确定是不同事实，不能相互冒充。旧磁盘内容不能仅因当前版本不接受就被描述为当前数据或已经迁移；是否保留或清理，以及具体迁移和恢复能力，均由对应 Product owner 的现有合同与真实能力决定，未闭合机制只登记为验证缺口。

交互式历史持久化异常不得冻结整个 Workbench，但 UI 必须持续可见地说明当前更改尚未确认保存。会控制重复外部 effect、权限或 credential 生命周期的持久 authority 不可信时，只对相关能力 fail closed，不得扩大到无关 Task。

## 5. 产品功能需求

以下是目标产品需求，不代表当前 ABI v1 baseline 已全部实现。

### 5.1 工作区

- 用户可以选择并打开本地 Workspace；
- Host 校验并保存 Workspace 的规范路径；
- Workspace 记录 immutable `kind = manual | automatic`。Manual Workspace 可承载多个 Task；Automatic Workspace 精确归属一个 Task，两种 kind 不允许对同一 canonical root 相互转换；
- Application 只通过 Native SDK `.data` 目录规则解析系统默认上级目录 `<MetaWork data dir>/workspaces`；Workspace owner 在独立的 schema 1 配置中持久化 `system_default | custom` 选择，custom 值是用户在 Host 原生目录选择器中确认的 canonical absolute path。Renderer、Bridge payload、cwd、home 和环境 fallback 都不能提交或决定该路径；
- 每个 automatic Task 使用 `<effective automatic root>/<16 位随机小写 hex>` 独立目录，同一 Task 的后续 Run 复用该目录。分配必须 exclusive create、有界重试、校验 canonical containment；失败不能回退到共享目录或另一个上级目录；
- automatic root 设置只影响修改后新建的 Task；已存在的 Workspace、Task、Run、Session、checkpoint 和历史记录继续引用创建时的 canonical root，不迁移、不扫描、不删除也不猜测旧目录。Scheduled occurrence 在每次触发时使用当时已提交的 effective root；
- 任一历史 Automatic Workspace 的精确 canonical root 都不能重新注册为 Manual Workspace；当前 effective automatic root 及其子目录也是保留命名空间。custom root 不得等于既有 Manual Workspace，不得等于或位于任一既有 Automatic Workspace 内；它可以是既有 Automatic Workspace 的祖先。用户通过原生 picker 明确选择 automatic root 的祖先仍只取得该 Manual Workspace authority，不因此获得 strict isolation；
- Workbench projection 必须把 Workspace 作为独立对象发布，至少包含稳定 identity、kind、显示名称、规范路径、当前授权状态和可汇总的 Task 信号；每个被 Task 引用的 Automatic Workspace 必须出现在同一 canonical snapshot；
- 没有 Task 的 Manual Workspace 仍然存在于 New task 的路径选择器中；最近使用与重新授权不能依赖 Renderer 从 Task 列表猜测。Automatic Workspace 不进入普通选择器、recent 或重新授权入口，但其 owning Task 仍可导航；
- New task 路径控件负责选择、添加和重新授权 Manual Workspace；设置页只提供 Automatic Workspace 上级目录的全局存储策略，不承担 Workspace 列表、打开、迁移、清理或重新授权。设置以覆盖 Workbench 内容区的长期 surface 呈现，保留窗口壳层和底层 Workbench 挂载，关闭后恢复原 Task、草稿、滚动和焦点；Renderer 不维护全局 active Workspace 镜像；
- 后台创建 Automatic Workspace 不修改 Manual Workspace recent order 或 Renderer New task draft scope；manual 与 automatic record 使用独立容量，后台 Task 不得耗尽用户打开 Workspace 的能力；
- automatic root 配置缺失时初始化为 system default；读取失败、损坏或未知 schema、配置提交结果不确定、以及已保存路径不可用时必须保留原事实并 fail closed，不得静默回退到 system default。这些故障只关闭 `automaticWorkspaces` capability 并对 automatic admission 返回 typed unavailable；Account、显式 Manual Workspace 和普通 Workbench 仍可运行；
- bounded Task/Workspace 产品历史跨 Host 重启恢复，但恢复后的 Task 只读且不得伪造 Agent Session 或 Conversation；Run、Task 删除、shutdown 和重启后 Automatic Workspace 目录保留，但不扫描目录恢复或猜测 Task/Workspace，目录浏览和磁盘清理属于后续独立能力；
- Task/Workspace 历史持久化是交互式主流程的 best-effort projection：历史读取、解码或写入失败时保留原文件与诊断，当前进程仍允许 Workspace 选择、新建 Task、Run、权限响应、取消与后续 mutation；读取或解码失败后本进程不覆盖不可信 store，明确写失败或结果不确定则在后续完整 snapshot 时重新尝试保存。Host 必须为非健康 store 发布 Product-owned 显式恢复动作；用户确认后，Application 只把当前 canonical 文件改名保留为 recovery copy，并原子写入 Product 编码的当前内存 snapshot，不读取、迁移或删除旧格式。只有 Task 物理删除和 Scheduled occurrence 等明确要求 durable-before-release/effect 的局部事务可以因本次提交失败而拒绝，拒绝不得冻结其他 Product Task 或整个 Workbench；
- 文件和工具能力最终必须受 Workspace 与显式权限约束；
- UI 能显示当前 Task 所属 Workspace；
- strict Workspace security 未验证前，产品必须明确限制使用范围，不能制造虚假的安全承诺。

### 5.2 账号、Provider、模型与执行配置

同一 source identity、source generation 与 protocol 内改变 global default model 只推进 selection revision，不改变 opaque Product execution generation；credential、endpoint、protocol 或 source authority 变化才建立新的 execution generation。新 Task 创建必须同时校验同一 snapshot 的 generation 与 selection revision，已有 Task 保留自己的模型并继续使用原 generation。

- 普通用户通过 Metask OAuth 登录，不需要手工填写 protocol、model、base URL 或 API Key；
- Metask managed Provider 使用 OAuth access token 直接访问固定的 `/v1/models` 与 Anthropic Messages `/v1/messages` endpoint，不存在第二次 API Key 选择或配置；用户管理的 Custom Provider 不要求 Metask 登录，但必须先显式创建、为其配置并验证模型，再安装到 Host-owned execution registry；
- `AccountView` 只发布 `state`、`canCancel`、经过验证的 `accountId`、best-effort `displayName`、由 Account Host 生成的可选登录邮箱/手机号脱敏提示、nullable非负整数并发额度（`null` 表示资料不可用，`0` 表示不限）、Account-owned稳定错误和无 secret 的 Metask账户摘要；资料字段缺失或异常不得阻止登录，完整邮箱和手机号不得越过 Bridge。当前摘要发布按 `Asia/Shanghai` 日历日对齐的最近 53 个周列的每日 Token历史及已记录费用、同步时间和安全错误；既有 nullable wallet/usage 投影保持 unavailable且不在界面伪造余额、今日或累计值。摘要不得包含 catalog、model、selection、source、execution、Task admission、Custom Provider、API Key、请求/RPM/TPM/响应时间、标准费用、订阅额度或模型分布。`ModelsView` 独立发布 Metask/custom source目录、Provider-local/global desired selection、Models revisions、persistence health与脱敏 Custom Provider；`NewTaskAdmissionView` 只发布 Product Control active binding、replacement、安装状态、新 Task admission与 active generation。三者不得互相伪装；
- Account 的 `checking | signed_out | authorizing | authenticated` 状态都不得替换 Workbench；登录、等待和取消动作只通过 Workbench 的账号入口与 Account 设置表达。可信根 Snapshot 建立前 Workbench 保持不可操作，确认根连接失败后才切换到独立连接恢复表面；已有 live Task 始终可查看和停止；
- 登录无效即进入 `signed_out`。Renderer 对建立 identity 只提供统一的 `beginLogin`，每次都开始新的 OAuth，不保留“重新认证”“重新打开登录页”“匹配上次账号”或重用 retained refresh token 的分支；retained refresh 只供一次冷启动 restore。已验证会话出现 `refresh_schedule_failed` 时提供独立的 `retryRefresh`，它只恢复 Host refresh 调度，不建立第二条登录路径；
- authenticated时，账户信息提供唯一“充值”动作，但不显示当前 OAuth 合同无法取得的余额。Renderer 只发送空 payload 的 typed command；Account Host 只在执行时构造并通过系统浏览器打开固定 Metask充值页，不接受 Renderer 提交 URL、token、account id或query，且该动作不改变 Account/Product状态；
- OAuth 浏览器授权、identity 提交和执行目录准备不得暴露内部 C1/C2、operation、generation 或凭据存储步骤；
- OAuth 成功提交 token rotation 并以 Userinfo 验证 authenticated identity 后，Application 必须把一份有界、可清零、绑定 authorization generation 的 lease交给独立 Models catalog continuation。仍有效的 Models-owned历史选择优先恢复；没有历史选择时按 Models 合同选择默认项；只有真实歧义才请求用户选择；
- Models continuation 失败不能把已验证 Account identity回滚成未登录，也不能根据显示名称、列表顺序或模型名猜测 source identity、protocol 或 target；
- 没有可用模型时必须保持已登录状态，说明目录不可用并提供 `重试`；只有 Host 拥有固定、安全的 Metask 管理入口时才显示 `在 Metask 中管理`，Renderer 不拼接外部 URL；
- 登录是 Account-owned操作；目录加载、模型选择和模型持久化是 Models-owned操作。Renderer 只渲染 Host 发布的状态和脱敏候选，不通过 `useEffect`、隐藏点击或本地定时器推进产品状态；
- 账号入口固定显示在左栏底部：已登录时按 `displayName → emailHint → phoneHint → 中性已登录文案` 的顺序显示身份；脱敏提示只用于呈现，不参与登录资格判断；未登录时显示登录动作。其轻量菜单同时提供产品级设置与“关于 MetaWork”入口；About 显示静态产品名、Metask 开发者归属和随应用构建注入的 canonical 产品版本，不属于 Account、Models 或 Bridge projection，在未登录与连接异常时仍可打开。接口不可用、Userinfo client 不匹配或响应不可信时不得从 token payload 推断 principal，也不得回退旧 identity；不得由 Renderer 推断，也不得在普通 catalog refresh 或后台定时路径主动更新；
- Account authenticated 后，Application 使用同一 generation-bound authorization lease 直接启动独立、单飞、有界的 history 同步；新的 OAuth gateway token 不得发送给旧 `/api/v1/auth/me` 或 `/api/v1/usage/dashboard/*`。history 从 `GET https://app.metask-ai.com/v1/usage/stats` 读取以周一为起点、截至上海当天的最近 53 个周列（365–371 个日历日）的稀疏日桶，并固定提交 `scope=user`、`granularity=day`、包含边界 `since` 与不包含边界 `before`；上海日历日边界由 Host 换算为 UTC。登录 identity 只以新 OAuth Userinfo 的非空 `sub`、精确 `client_id = metawork` 与非空 `authorization_id` 作为门槛，并把 `sub` 绑定到 token；`name/email/phone_number` 缺失或异常不得阻止登录。已经 authenticated 后，history 字段缺失、格式错误或请求失败不得回滚登录，已有值在失败时保留为 stale。history 严格校验响应声明的 `scope=user`、`granularity=day`、`timezone=Asia/Shanghai`、查询边界、日桶顺序、Token恒等式及桶合计；`cost_mu` 固定按毫 U 换算为 U。当前已发布响应不以 `unit` 或 `cost_complete` 为必需字段，因此每日金额只呈现为“已记录费用”，不得声称区间费用完整。只有整段响应成功且严格验证后，范围内缺失日期才解释为零使用；失败不得把缺失值补零。不得轮询或自动重试；
- 唯一的 global default selection 属于 `Models` 设置；页面以 `Provider → 默认模型` 的依赖链选择一份完整、source-qualified 的默认配置。Metask credential authority 由已登录 OAuth 会话隐式提供，不投影或选择第二层凭据；用户管理来源的 credential 由 Host 安全持有，也不在 Models 中显示或修改。用户管理来源的创建、endpoint、credential 与生命周期属于平级、独立的 `Providers` 设置；Provider 页面不得读取或修改 global default。Host 只在 management、API Key 直接写入系统 credential storage 与真实模型测试同时可用时整体开放 `Providers`，任一能力缺失都隐藏整个入口。开放判断只依据当次运行时 capability，不按 Windows/macOS 平台名建立静态 allowlist，也不能以不可完成或局部可用的表单提前暴露；
- 用户管理的 `CustomProvider` 是唯一 Provider 产品对象，不存在 `ModelConnection`、connection identity 或对应兼容层。其最小对象是稳定 `id + display_name + protocol + normalized_base_url + credential_status + provider_revision + source_generation + catalog_generation`，并拥有有界的 custom model definition 集合；刚保存且尚未在 Models 页添加模型的 Provider 可以以 `configuring + models=[]` 持久存在，不能解析、测试或成为默认来源。每个模型以 `source_id + model_id` 标识，携带 nullable capability/token metadata、明确 provenance、当前 source generation 的 readiness proof 和 `untested | testing | connected | failed` 最新测试状态。Provider 不拥有 default model 或 provider-local 默认选择；global default 只由 Models 页以完整 `ModelRef` 提交。unknown 不得伪装为 unsupported/verified，display name 永远不是 identity。`protocol` 精确取 `openai_responses | openai_chat_completions | anthropic_messages | gemini_native`，四者均可创建、恢复和选择。MetaWork 可以为 DeepSeek、Kimi、MiniMax 与智谱 GLM 发布只读官方配置模板；模板 identity 只记录该 Provider 来自哪份内置配置，固定显示名与 protocol，并提供官方默认 Base URL、API Key 获取地址和文档地址。用户可以显式用另一兼容 Base URL 覆盖官方默认值；Models 仍按模板 protocol 确定性生成 completion endpoint，不进入 Agent runtime 的 `ProviderKind`，也不允许根据模型名或 URL 反推厂商。当前不包含厂商图标。readiness 与 latest test status 必须分开；同一 source generation 已验证模型的失败重测不能撤销其 readiness 或正在使用的默认 execution。自定义 Provider 的 protocol 由用户创建时明确选择，不能根据模型名或 endpoint 猜测；
- 用户管理 Provider 的 API credential 由用户在本地桌面 `Providers` 表单中直接填写；Renderer 只能在 create/replace 操作的临时 password state 中持有完整值，并通过专用 typed Bridge command 一次性提交。Bridge 严格校验后立即转交 Models，Models 写入系统安全存储；metadata 以独立、无 secret 的 registry 原子持久化。提交成功、取消、离页或 revision 变化后不得把秘密保留为可恢复 UI 状态；明确失败时可以留在当前表单供用户修正重试，但不得持久化或进入 snapshot。任何路径都不能提交 Authorization header 或把 arbitrary URL/credential 直接注入 Run；
- 模型测试通过 Agent-owned Completion 发起一次有界的非流式请求，复用当前设置选择冻结的 ExecutionConfig，并由 MetaWork 的 Anthropic/OpenAI/Gemini 无 Tool codec 解析最终 JSON 响应；它不调用 AgentCore Completion，也不创建产品 Task、Run history 或持久 Conversation。第一版由用户明确提交 bounded model id，Host 保存其模型 metadata；自动模型发现不在当前范围；
- 当前模型必须显示在 New task Composer 附近，并显示为 `Provider · 模型`。global default只影响后续新 Task；已有 Task 显示当前 binding epoch 的 protocol、opaque execution generation 和模型，历史按 epoch 保留原事实。只有 §4 已定义的 exact Metask authority 允许为下一轮修改 Session 模型；authority 不一致时显示 pinned model 与只读原因，不提供跨 credential 或跨 Provider 的虚假热切换；
- Metask Provider-local selection 已有效但 global default 为空时，New task Composer 必须明确说明尚未设置可执行默认模型并提供进入 `Models` 设置的导航；Composer 不提交或改写 global default。active binding 就绪且其当前 source catalog 可验证时，New task 草稿可以为本次 Task 临时选择同一 source 中的另一个 ready 模型；该选择只在首次 `tasks.create` 时作为 source-qualified override 提交，不持久化为全局设置，不开放跨 credential 或跨 Provider 切换。选择失效时发送必须 fail closed 并要求重新选择，不能静默回退到默认模型。发送在 active binding 就绪前保持禁用；Renderer 不根据已显示模型、首个目录项或 Account 状态伪造 admission。已有 Task 在 §4 明确定义的 authority 下进行下一轮模型切换不属于 global default mutation；
- 进入设置只读取 Host 已提交的 `account` 与 `models` projection，不触发隐藏 mutation；Account 页的 `刷新账户用量` 只显式触发 Account summary 同步，Models 页的 `重新同步` 只显式刷新 Metask目录，两者不能互相代替。`Providers` 设置读取同一 Models-owned registry，并把内置厂商与自定义 API 分为两个层级：DeepSeek、Kimi、MiniMax 与智谱 GLM 始终作为主要厂商列表直接显示配置状态和“配置/管理”动作，不再经过“添加 Provider”或接入方式选择；自定义 API 作为次要分组，通过独立“添加自定义 API”入口进入全页表单。官方厂商页默认使用模板 Base URL，只采集 API Key；用户显式展开“使用其他地址”后才能编辑 Base URL，并看到最终 endpoint 与 credential 目标 host 提示。已配置厂商的地址修改与 API Key 替换是两笔独立 mutation，均不回填已有 secret；地址、protocol 或 credential authority 变化沿用 Models generation/readiness 失效语义。自定义 API 表单采集显示名称、四选一 protocol、API Base URL 与 API Key，并预览由 protocol 与 Base URL 确定的实际请求地址。保存成功、取消或离页后必须清除未提交 API Key 和草稿；两条路径都不在 Providers 页提供模型或默认模型动作。Models 页在选定 Provider 后直接展示其 ready 模型；Custom Provider 的模型仍可添加、逐个测试与删除，最终选择默认模型时才提交完整 `ModelRef`。已有默认配置必须直接投影，不能要求用户先重新选择或切换；
- 登录后无已存 Metask intent时，Models按目录顺序选择第一个可用模型作为初始 Provider-local intent；已存 intent仍有效时优先恢复。Metask model 准备与最终 global default 提交是 Models-owned、source-qualified transaction，使用各自 expected revision并原子写入 `models.json`；选择 Provider 只收窄后续候选，不能单独替换 global default，最终选择默认模型才提交完整 selection。设置页离开不回滚已提交的 Host事实，Renderer临时选中状态也不得成为恢复依据；
- OAuth access token 同时授权 Metask 账号 API、模型目录与模型调用；Models 只在有界进程内 credential 生命周期中持有执行所需副本，不持久化 token；
- 除用户正在填写且尚未提交的 Custom Provider API Key 外，Renderer 只能看到脱敏账号、模型、稳定错误码和状态，不得接触 OAuth token、已保存的完整 API Key、Authorization header、临时 OAuth URL 或凭据存储 locator；
- Product Control 只维护一个当前默认 ExecutionConfig，来源可以是 Metask managed connection 或 user-managed Custom Provider；Task 可以在 live Session、Run、job 或 worker 中保留必要的 owned copy。切换默认连接、API 或模型不得篡改或停止既有运行；最后一个真实运行时引用释放后必须 secure-zero；
- durable Task 和 Run 不保存 account id、OAuth token、完整 custom credential、credential locator 或 Custom Provider identity。恢复记录只保存 Workspace binding、protocol、model、opaque execution generation 和其他无 secret binding facts；运行时配置不可恢复时必须显式进入 `runtime_detached`/恢复路径，不得伪造 Session、secret 或可继续执行能力；
- 显式重新登录、切换账号、退出登录或清除设备凭据只按 Account 自身 identity/credential transaction 收口，不得等待 Models、Product replacement、Schedule scrub、Task、Session、Run、executor job 或 worker reference。既有 Task/Session 已拥有的 ExecutionConfig继续按原生命周期收口；成功退出只清除 Account-owned credential并发布 `signed_out`。Application随后使 Models的 Metask provider进入 `needs_authentication`，清除 transient目录/credential但保留无 secret intent；custom default不受影响。若 active default依赖 Metask，Product Control独立关闭新 admission并清除 active binding；任何失败都不回滚 logout；
- refresh token成功轮换后必须先原子提交新 token，后续 Models catalog失败不得回滚到已作废的旧 token；Account 只在 authenticated、principal匹配、generation有效且 access token 未到 hard expiry 时签发授权 lease，refresh skew 内的正常在飞目录操作保持有效；clock/timer arm失败必须发布可重试的 Account错误，hard expiry 后 fail closed。明确鉴权无效使 Metask provider无法产生新的解析，但已被 live Run拥有的配置按其生命周期正常收口；
- New Task尚未形成自身 aggregate，其 admission只由 Product Control根据 Models desired/active readiness与 Workspace authority决定：Metask default要求 Models能以当前授权解析且 active authority一致，user-managed Custom Provider要求 ready且已安装所选 source generation；两者都要求 Workspace intent可解析且 Product reconciliation/replacement未阻塞。Account只提供授权 lease，不能直接允许或阻塞 Product Task；
- production Account接入、内部状态、OAuth/identity transaction和提交必须符合 [Account 架构](account-architecture.md)。Metask OAuth-authorized model catalog、固定 protocol/endpoint、模型 metadata与选择属于 Models provider。Account C1先提交 token rotation，再以严格 Userinfo 交付 authenticated identity；Application用独立 authorization lease启动 Models continuation。Models desired commit不等待 Product/Schedule；Product在 resolve、scrub/install且 active authority一致前拒绝相关新 Task，但不能隐藏 durable history。既有 live Task的后续 Run只服从自身 binding、ExecutionConfig、Session与 active-operation gate。

### 5.3 Task

- Host 为每个 Task 发布模型选择可用状态，精确区分可用、目录加载、目录不可用、执行替换中、运行时分离、不支持的来源和 authority 已变化；Renderer 只按该状态显示可编辑菜单、暂时禁用菜单或带原因的只读模型，不跨根 projection 猜测权限。
- New task 草稿始终属于 Workbench，但只有 Product Control 发布 ready execution admission 后才能发送；Renderer 按 Workspace intent 隔离并可恢复。默认 Workspace intent 为 Automatic，界面显示“默认”，首次发送时才由 Host 创建 Automatic Workspace。用户可以在发送前切换到已授权或新选择的 Manual Workspace；
- New task 首次发送依次创建真实 Task 并启动第一个 Run，两步不能在界面中伪装成一个不可分失败状态：Task 创建失败或拒绝时留在 New task 并恢复原草稿；Task 已创建但 Run 启动失败或拒绝时进入该真实 Task、把输入恢复为 Task 草稿且不伪造已提交指令或 Running；命令 timeout 必须先刷新 canonical snapshot 决定实际页面和草稿 scope，不能自动重放可能有副作用的提交；
- 用户可以在 Workspace 中创建、切换、继续、归档和删除 Task；不存在独立的 Task `closed` 产品终态；
- 多个 Task 可以同时存在；
- 后台 Task 的运行状态不能因 UI 切换而丢失；
- 每条事件、审批和工具结果必须路由到正确 Task/Run；
- 每个 Task 在创建时记录无 secret 的 generation、protocol 与模型历史事实；不得固化 Account identity 或 API Key 元数据。全局默认变化不改写 Task 历史或 live Agent Session；
- 没有用户标题的 Task 在首个 Run admission 时立即使用旧的本地有界摘要作为临时标题，避免模型返回前退化为 identity 占位；Run 收口后再使用该 Task 已固定的同一 ExecutionConfig 通过独立 Completion 生成一个不超过 32 个 Unicode 字符的标题并替换临时值。该请求不创建 Session、Run history 或 Conversation，也不改变 Run outcome；失败、超时、拒绝或非法结果保留临时标题。用户在生成完成前后设置的标题都具有优先权，后台结果不得覆盖；
- 每个 Task 至多一个 active operation：当前可以是 non-terminal Run、manual compact 或 Conversation restore，包括 executor 中的 `queued` 状态；Run、compact 与 restore 互斥，当前 operation 结束前 Workbench 拒绝新的 Run、compact、restore 和其他 Session mutation，Renderer 只能保留未提交草稿；
- Renderer 产品合同为 `metawork.renderer-bridge` 固定 revision 1：`connect` 精确协商后才开放产品路径，snapshot 根节点由严格的无 secret `capabilities`、`account`、`models`、`newTaskAdmission`、`skillCatalog`、`skillManagement`、`mcp`、`workspaces`、`scheduledTasks` 与 `tasks` 组成且不维护第二个局部版本；Account 只发布 Metask identity 与授权状态，Models 独立发布 provider catalog、Provider-local/global selection、revision、persistence health 与 Custom Provider，`newTaskAdmission` 独立发布 Product Control active `ModelRef`、generation、selection revision 与新 Task admission；Renderer 只为 New task draft 保存可空 Manual Workspace identity 和 runtime-only 模型覆盖选择，Host 不发布全局 selected Workspace；`tasks.create` 提交严格的 `automatic | manual(workspaceId, expectedWorkspaceEpoch)` Workspace intent、必填 nullable `modelSelection` 及各 owner 对应的 expected generation/epoch，Host 重新校验 window、ownership、active source、catalog membership 与 admission；快速开发阶段的合同内容直接原地 hard cut，不接受或双写被取代的临时 payload；
- 预期的 Task/Workspace admission 拒绝必须作为严格 typed result 返回并由 Renderer 映射为产品文案；非法 payload、伪造 ownership 与不可信 origin 仍 fail closed 为 Bridge error，不得把内部 error name 显示给用户；
- 当前固定 revision 1 合同原子提供独立 Workspace projection 与 Task execution binding。一次性目录能力必须由选择命令在 Host 内创建并消费；用户在 Host 原生目录选择器中确认目录即完成 Manual Workspace 授权，不再追加重复的 trust 确认。Renderer 不接收路径授权 token，不从 Task 反推 Workspace，也不能通过可选字段继续发送被取代的临时 payload；
- Composer 可以通过系统多选文件选择器或操作系统文件拖放添加普通非空文件；两种入口必须形成相同的 connection/window-bound 一次性 staged authority，并共同服从 8 个文件、单文件和总暂存容量上限。拖放依据 Host 公布的接收模式，使用 Native SDK 路径事件或 DOM File 的有界字节输入，经专用 typed Bridge command 提交；不得持久化路径、文件句柄、raw bytes、Base64 或 digest；
- 经内容签名识别的 PNG、JPEG 与 WebP 图片，以及不超过 64 KiB、合法 UTF-8 且不含 NUL 的非空文本文件可以进入 Run。图片允许独立发送；草稿含文本附件时必须同时提供去除首尾空白后非空的用户指令。用户文字固定成为第一个 input part，附件按 chip 顺序提交并可混合图片与文本。文件扩展名不参与可信分类，MetaWork 不解析 Markdown、JSON 或其他格式；非 UTF-8、含 NUL、超限或其他二进制文件在整批 staging 时拒绝。URL、file ID、正文内图文交错、Skill 与附件混合、Scheduled Task 附件、粘贴、缩略图、图片转码、文档解析/预览/OCR 和历史下载/重新发送不属于该切片；
- 用户可见 Run 历史只保存经过 credential redaction 的附件名称、类型、可选图片格式、大小和顺序，不保存文本附件正文。MetaWork 不建立 raw 附件资产库；AgentCore Conversation 与 opaque checkpoint 继续拥有模型侧输入历史。恢复后的历史 Run 可以显示附件 metadata，但不能据此重放附件；需要重新提交时用户必须重新选择文件；
- 产品 Task identity 由 Workbench 独立、稳定地分配；内部 Agent/Gate 原始事件使用单独的 Session route identity 做路由，两者不得复用或假定数值相等。Session route identity 不进入产品 snapshot，Renderer 始终只看到唯一的产品 `taskId`。
- credential 不得因 owner 释放而重新出现在任何 Renderer projection。Host 在安装新 credential 以及 secure-zero 旧默认或 Task-owned credential 之前，必须永久清洗既有 Workspace、Task、Run、tool 和 UI history 投影；同时存在前缀重叠 credential 时按最长匹配脱敏。

### 5.4 Agent 交互

- 用户可以提交普通文本，或由图片与受限 UTF-8 文本附件组成的多模态输入并启动真实 Agent Run；文本附件只按原始 UTF-8 参考资料发送，不等于文档解析能力。模型目录中的 `imageInput` 只提供图片发送前提示，不能替代 Product admission 或 AgentCore typed capability 判断，也不能授权 Renderer 丢弃媒体、切换模型或降级成文本。目录仍可保留上游 `pdfInput` 元数据，但 MetaWork 不据此开放 PDF 输入；
- AgentCore → Host → Bridge 持续投影 Agent 可见输出，并把 commentary、final/partial response 与 provisional 区分为稳定过程说明、安全正文和可回滚临时文本；Renderer 必须在正式 terminal fact 前随真实 Snapshot revision 持续更新 Run 的工作过程，不能把已到达的过程事实藏到终态后一次性展示；
- `thinking_chunk` 正文不进入可见 output、Snapshot、持久历史或搜索；其事件类型只把当前安全状态细化为“正在思考”，`text_chunk` 到达后状态切换为“正在撰写回复”；
- macOS AgentCore 的 visible-output segment 由 `output_segment_begin/end` 权威定性：`commentary` 是可见过程说明，`continued` 与同 group 后续段合并，`final` 是完成答案，`partial` 是可见但未完成输出，`discarded` 必须回滚。Product Task 只把已闭合的可见组提交到 durable visible-output history，并以有界累计边界精确保留每个非空 commentary group，同时持久化 final/partial 分类及安全正文起点；Bridge revision 1 将其派生为有序 commentary array 与 response，而不是把全部过程压平成一个 Markdown body，同时只把 open/continued 中 credential-safe committed bytes 作为可回滚 provisional。open、continued 和 discarded 不形成 durable record，Renderer 也不得从 Tool、`stream_done` 或 StopReason 猜测这些语义；
- 主阅读流把 commentary 与 provisional 作为所属 Run 的 Assistant 过程叙事持续呈现，并在其下方只保留一个随 canonical activity 原位更新的 live status；Tool 记录是次要技术证据，默认折叠，只在用户明确展开后按 Host 顺序显示。每条 Tool 摘要固定为单行，包含名称、至多一项 Host 安全摘要、状态与真实耗时；摘要优先使用 description 或 progress，缺失时可以用结构化 fileRefs 的 displayPath 作为只读文字兜底，空间不足时省略而不换行。Tool input、progress 与 result 只在用户选择具体 Tool 后于所属行下方展开；
- UI 以唯一 Current activity 展示 thinking、writing、tool、retry、context compact 与 finalizing，不展示 Run token usage 表；Composer 仅在当前 Conversation 存在 Host pressure 观测时显示上下文提醒，不因最近 auto compact 历史单独占位，底层统计与压缩记录不因此删除；
- Agent 对话按 Run exchange 组织为用户输入及其元信息、单一 Assistant output、运行中的唯一 live status 与按需技术过程、待处理请求、文件更改、必要 terminal notice 和末行回复元信息，不存在的部分不占位。每个 closed commentary group 与尾部 provisional/final/partial 都使用同一 Assistant message 内按稳定 output ordinal 排列的安全 Markdown part，组间只以克制留白分隔，不做卡片、事件时间戳或 Tool 标签；provisional 从首批安全字节起即可呈现 Markdown，但在被 AgentCore 定性前必须禁止链接、文件预览、图片加载和复制等交互，discard 后立即消失。分类变化不得把同一 output part 搬到另一条消息或替换其 DOM 根。active status 始终位于当前输出底部并原位更新，不因 Tool 事件追加新的主阅读行。active Run 的技术过程与 live status 共用默认折叠的 process surface；Run terminal 后 live status 消失，没有 Tool 时 process surface 同步卸载，存在 Tool 时保留默认折叠的历史操作摘要，并允许在所属行原位展开 Tool 详情。用户输入元信息只允许复制动作与 Product 持久化的 Run 提交时间，回复末行只允许回复动作与 Product 持久化的 Run 完成时间；两者不得据此伪造 typed facts 之间不存在的严格时间线。具体 owner、槽位和迁移机制由 [UI 设计规范](ui-design.md#72-agent-对话渲染机制)定义；
- 已闭合 commentary、final/partial response 与安全 Markdown 文件预览中的 HTTP(S) 链接，以及对话中的 `mailto` 链接，只在用户显式点击后经 Host 交给系统默认 handler；WebView 不直接导航，Renderer 不用 `window.open` 或普通 anchor fallback。非法目标、Host/Bridge 不可用或系统打开失败必须在对应链接旁显示明确失败，不能静默无响应、自动重试或扩大协议范围；provisional 链接继续保持惰性文字；
- 用户可以一键复制任一 Product 已接纳的 Run 输入。普通文本保持 Host 投影的原文；Skill 输入复制为可读的 `/调用名 参数…`；多模态输入复制已投影文本与附件显示名，不读取附件内容、内部 locator 或本地路径。复制必须直接使用 typed input，而不是从 DOM 反向提取；旧历史即使没有提交时间也继续可复制；
- 用户可以一键复制任一已 terminal 且非空的 final/partial response。纯文本剪贴板内容必须是 Host 已投影的原始 Markdown，不能 trim、拼接或从 DOM 反向提取；富文本内容必须由同一 Markdown 经当前安全 GFM 渲染策略生成，不包含 commentary、provisional、思考过程、Tool、状态、耗时、按钮、隐藏文本、内部文件导航或远程图片。支持标准多格式剪贴板时一次写入 `text/html` 与 `text/plain`；明确不支持时只降级为完整 Markdown，权限、容量、转换或写入失败不得截断或显示成功。回复内代码块可独立复制其显示代码正文，不包含 Markdown 围栏、语言名、行号或界面文案；
- Product 在接纳 Run 输入与正式 terminal 收口时分别至多一次记录 wall-clock 提交时间和完成时间，并随 Run 历史持久化；时钟不可用或旧记录缺失时对应事实保持未知，不迁移、不由 Renderer 补写。用户输入在弱化的本地相对提交时间右侧提供复制动作；具有可复制回复的末行仍在复制动作右侧显示相对完成时间。两种时间都提供机器可读绝对值；相对文案自然推进不得发布 Product revision、改写历史或触发主阅读流滚动；
- terminal notice 必须使用 Product 已知的最具体稳定原因并给出匹配的恢复动作；模型服务错误、不可恢复的工具执行错误与模型不支持图片不得统一展示为泛化的 Agent 或网络故障。`provider_failure` 的主区 notice 必须说明本次回复是缺失还是只有部分内容；该 Run 失败提示下默认折叠的运行详情必须区分 MetaWork 未收到该 Run 的附加诊断与 Host 已接收但当前安全边界不允许在界面展示的附加技术诊断。两种诊断状态都不能被扩写成未经证明的鉴权、限流、网络或配置结论，主区默认提示也不得重复详情中的诊断边界。未通过 AgentCore 合同进入 Product 的 provider raw diagnostic 不得由 Renderer 猜测或从日志旁路读取；
- 每个历史 Run 必须保留并投影解释该次执行所需的精确无 secret provenance：opaque execution generation、protocol 与 model。失败诊断只能引用被选择的同一 Run 事实，不能使用 Task 当前 binding、Models 当前默认值或 Account 状态补写历史；Task 最近结果由有界 Run 历史中的最后一个 terminal 记录派生，不维护可能漂移的 Task 级结果副本；
- 过程叙事密度只取决于 AgentCore 实际提交的 commentary 与其他 typed observation；产品不要求每个 Tool turn 都产生 commentary，也不从 Tool 名称、参数、结果、耗时或 Renderer 本地计时合成 Agent 发言、模型意图或伪进度。上游没有新的可见文本时，主阅读流只原位更新已有 canonical activity，不以重复状态行填充空白；
- Host 为每个 Run 投影 typed File Changes 的 `collecting | complete | incomplete` 观测状态和有界记录；完整记录只表示已消费的 typed observation 没有已知丢失。oversized、队列或 Product 容量不足、非法 locator、diff 截断/存储失败和中断必须单调收口为 incomplete，但不得改变 Run 原有 outcome；
- Run 有可见记录时在回复后显示唯一文件数量和“审查更改”入口；incomplete 即使没有保留下来的记录也必须显示警告。“审查更改”在右侧 Task Panel 打开绑定明确 Task + Run 的连续差异文档：首个文件的首条记录立即读取并展示，后续文件及同文件记录在对应区块接近可见区域时按稳定 `order` 逐条读取；同一 `displayPath` 的多条记录汇入单一文件区块，不显示记录序号，底层记录身份、顺序和失败仍保持独立。这是 recorded diff 的呈现聚合，不从 Workspace 或 Git 伪造当前净差异。文件区块完整区分 create/modify/delete/move/partial、脱敏与缺失/损坏状态。第一版不提供跨次打开的 diff cache、Accept/Reject、Git 净 diff、Run 级增删行汇总、当前文件重读或 Output 推断；
- 用户可以在已有 finalized Run 且 Task 可继续时显式压缩当前 Conversation；manual compact 是 Workbench-owned Task maintenance operation，不创建 Turn/Run，不产生用户消息，也不把 `/compact` 原文送入 Bridge 或模型；
- manual compact 必须发布真实的 queued/compacting/stopping 与 terminal outcome；`compacted / no_change / degraded / aborted` 保持各自语义，before/after context token 只作为估算展示，compact provider usage 与 Run usage 分开记录；
- 用户可以取消当前 Run；
- 用户可以取消 active compact；Run 或 compact 的取消都必须等待 AgentCore 给出真实终止结果，不能只在 UI 中停止渲染。
- Application 重启后，点击左栏 Task 只负责导航和阅读历史，不得隐式恢复 Session、启动 Run 或重放任何输入；当用户发送下一条消息时，Renderer 可以先请求 Host 重建 attachment，必须等 canonical Snapshot 确认可继续后才能提交新 Run；
- 每个 Run/compact 历史必须发布它是否包含在恢复后的 Conversation 上下文中。被排除的记录仍完整可见，Task 主阅读流必须说明“部分历史不在恢复上下文”，但不得因此禁用已成功重建的 Composer；
- Conversation 恢复优先从最新已提交 checkpoint 重建 Agent Session attachment；仅当没有 checkpoint、没有 included/pending 历史时，才允许在原 Task 上 fresh attach 空 Conversation。恢复完成前禁止新 Run 和其他 Session mutation；已有 included 历史但 checkpoint 缺失、损坏或不精确时继续 fail closed。失败必须保留历史、给出稳定原因并仅在 Host 再次证明资格后允许用户重试。

### 5.5 审批与输入

- Authority、Interaction Policy 与 Sandbox 是三个独立维度：Authority 决定 Task 已取得的 Workspace、Shell、Skill、MCP 与系统能力；Interaction Policy 决定未覆盖操作是否询问；Sandbox 只描述执行时的物理约束。产品、UI 和验证不得把三者合并成一个“安全模式”；
- `PermissionProfile` 是 MetaWork-owned 的产品策略，当前只定义 `approval_required | full_access`。`approval_required` 表示常规 Workspace 编辑自动、其他当前策略未覆盖操作请求批准；`full_access` 表示 MetaWork 不再为常规工具操作请求批准，但 AgentCore 核心保护、操作系统权限、服务授权和进程身份仍可拒绝或要求处理。内部 AgentCore enum、ShellPolicy 和 rule schema 不得成为 Renderer 产品词汇；
- 正式 Session 按 Task-owned profile 使用 `approval_required → accept_edits + unrestricted` 或 `full_access → full_access + unrestricted`；前者会自动执行 Workspace 内 Write/Edit，并对 Workspace 外 Write 与明确有副作用的 Bash 发布同步 permission request。两档都不是 Sandbox、root 或运行不可信 Workspace 的安全保证；
- 用户选择的 `ApprovalMode` 为 `manual | auto_review | full_access`，分别呈现为人工审批、自动评审、完全访问。人工与自动评审都使用 `approval_required`，完全访问使用 `full_access`；自动评审不是第三个 AgentCore profile，也不是 Sandbox 或安全保证。首次默认为人工审批。New task 发送前选择本次模式；交互式 Task 成功创建后，MetaWork 全局记住该模式并随历史持久化，供重启后的新 Task 使用；创建失败或放弃草稿不改变默认值。选择动作本身构成本次授权，不追加确认 modal、独立委托开关或 Settings 权限入口；
- profile 在 Task 创建后不可变：Task 保存 effective profile，每个 Run 保存 provenance，checkpoint restore 必须使用同一 profile；归档 Task 阻止新 Run，删除 Task 收口 Session 并永久移除该 profile authority。已有 Task 只读显示自己的 profile，不得用 Session-local shadow state、规则拼装或 checkpoint replacement 模拟切换；
- Shell 是广泛执行 authority。`unrestricted` 只表示获准 Bash 不经过 AgentCore file sandbox，不等于 root，也不决定是否询问；产品不得以 Bash 前缀、命令字符串分类或 `exact_arguments` Session grant 宣称可靠 effect 边界；
- 当前过渡边界下，Task 捕获的审批模式与 profile 一同恢复，不因全局默认值或重启改变；已有 Task 只读展示模式，不开放会话中切换，也不能用 Session shadow、规则拼装或跨 profile restore 模拟。归档立即禁止新 Run，删除永久移除该 Task authority；
- 自动评审只适用于交互式 `approval_required` Task 的内置工具 permission。Host 使用该 Run 冻结的模型，额外发一次无 Tool Completion；只接纳当次 request 允许的 `allow_once` 或 `deny_once`，不生成 Session grant、不缓存“安全命令”。失败、超时、资源不足、证据缺失和 MCP 等不透明参数请求回到人工，不使原请求过期、不自动重试。模型判断不保证真实 effect；主 Agent 与审核器共享模型可能发生相关错误，额外 usage 计入用户账户；
- 审批卡的显示时机和自动评审呈现由 [UI 设计规范](ui-design.md#101-permission-request) 定义。有效人工决定与自动结果仍由谁先被 Host 接纳谁生效，后来的结果按过期处理；历史区分用户与审核器，并保存有界脱敏理由。取消、删除、关闭和 shutdown 后的迟到结果不得生效；
- 用户可以响应当前 typed permission；结构化 Agent 问答、计划批准或拒绝只有在对应 built-in/control capability 进入 MetaWork 产品集合并通过验收后才显示；
- 当前 permission 卡只能提交 AgentCore 当次 request 真实发布的 choice。主操作固定为“允许一次”；当 request 提供 Session scope candidate 时，“本会话允许相同参数”放在同一批准操作的展开选项中，拒绝保持独立操作。不得为了减少点击而伪造 request 未提供的 Session 或跨 Session 范围；
- Product 必须保留足以解释重复请求的有界诊断事实：Task/Run/request identity、tool identity/binding、canonical arguments digest、policy generation、candidate/rule identity、decision source、Session rule 命中与 restore 结果。它们只能来自 AgentCore typed request/provenance，不得记录原始参数、credential 或可重放 response，也不得用 tool 文本推断 effect；
- Renderer 可以用同一 Task 内的该诊断事实说明“为什么又请求”，但不维护本地 grant cache，不自行决定允许或实现自动评审。相同 digest 不等于可绕过 AgentCore；
- `approval_required` 的 Manual Workspace Task 可在当前 Run 已真实 terminal 后创建一个“以完全访问继续”的新 Task。新 Task 复用同一 Workspace identity 和源 Task 的 exact owned ExecutionConfig，profile 固定为 `full_access`，但必须创建独立 Session，不继承 Conversation、Run history、pending request 或 Session grant。这是停止后的新 Task，不是原 Task 热切换；
- Automatic Workspace 为单 Task 独占 authority，不得为此流程共享、转移、复制或偷换为新 Workspace。源 Task 不是 Manual Workspace、execution attachment 不可用、Run 未收口或 identity 已变化时，产品必须禁用该入口并说明原因，不回退到普通 New task 或当前默认模型；
- 审批和回答必须绑定 Task、Run 和请求标识，拒绝过期或重复响应；
- 同步等待必须支持 deadline、用户取消、Task close 和 Application shutdown 唤醒；
- 同步等待区间发生 Host/Core crash 后，Run 标记 `interrupted`，工具不得自动执行；
- 当前产品不创建、管理或展示跨 Session 持久权限规则；AgentCore candidate 只能形成当前 Session scope choice，不得被 Renderer 显示成永久授权，也不得被 Host 复制成平行规则存储；
- async pending、跨重启 pending request 恢复和 subagent suspend 不属于当前产品范围。

### 5.6 命令执行

- 普通 shell 命令以非交互子进程执行；
- UI 展示命令、stdout、stderr、exit code、耗时和错误；
- 普通命令不弹出 Terminal 窗口，也不依赖 PTY/ConPTY；
- 当前阶段明确拒绝或限制需要 TTY 的交互式程序。

### 5.7 状态与恢复

- 每个 Account attempt 必须拥有 Host deadline，并最终进入成功、可重试失败、用户取消或明确失败；浏览器未回调、网络悬挂、worker 启动失败和 completion/notification 异常不得永久保留 active operation；
- OAuth 等待超过正常感知时长时，界面只提供 Host-owned `取消登录`；Renderer 不接触授权 URL。目录等幂读取和已保存 refresh token 的瞬时失败可以有限重试，OAuth code exchange、持久化 mutation 和其他结果不确定操作不得盲目重放；
- Bridge command 或 view refresh 超时必须释放 Renderer 本地 busy 状态并进入 snapshot resync；结果不确定的 mutation 只能依据 Host snapshot 决定后续动作，不能由 Renderer 自动重复；
- Account cancel 是等待 OAuth callback 时的独立逃生动作，不能因普通 mutation busy 被禁用；callback 被主线程提交为 `token_exchange(login)` 后即跨过取消边界，Host 必须撤销 cancel 并等待唯一 terminal completion，不能自动重放 authorization code，也不能在磁盘已提交、main-thread completion 尚未消费的窗口把内存回滚到旧 generation。Bridge 暂不可用时 Host 的 5 分钟总 deadline（其中 exchange 最多占剩余时间与 30 秒的较小值）仍必须收口 attempt，Renderer reload 后从 snapshot 恢复可用动作；
- 用户消息、已完成 Agent 可见输出、工具结果、审批决策、关键 Run 状态和改变 Conversation 的 manual compact 应形成可靠状态边界；Run/compact admission 必须先建立稳定的 Workbench record，terminal payload 一经发布不可变，内部 Agent Session 关闭或销毁后 Task 历史仍可独立生成 snapshot；compact history 有界且 append-only，容量耗尽时拒绝新 compact，不覆盖既有 Conversation 边界；
- 当前 baseline 的 Renderer reload 只能从仍存活的 Host 恢复视图；
- Host 或 AgentCore 进程退出时，当前同步 Run 标记 `interrupted`，不得伪装完成；
- 崩溃后不得自动重放可能产生副作用的工具；
- AgentCore checkpoint export/restore 已接入 Application 重启后的 Conversation 恢复；它不是 transcript 重放，不恢复 checkpoint 之后未完成的 Run，不自动重放工具、permission 或结果不确定的 mutation；
- async pending、可恢复 suspend/resume、独立 AgentCore Worker crash recovery 和跨进程 in-flight Run 恢复仍属于后续 capability；
- 成本预算、轮数上限或工具循环熔断后，Task 进入等待用户状态，只有用户明确继续后才创建新 Run。

### 5.8 桌面能力

- 提供窗口与应用生命周期管理；
- MetaWork 默认按 artifact identity 与 canonical 产品数据目录保持单实例；development、release 与 automation 使用彼此隔离的 identity、数据目录和 credential service，可以并存，但同一 artifact 指向同一数据目录时只能有一个持有写入 authority 的 Host；
- 重复启动必须在初始化 Store 和其他业务 owner 之前把有界启动参数与当前目录转交给既有 Host；既有 Host 在主线程显示并请求聚焦主窗口，随后新进程退出。主窗口已关闭但 Host 仍在托盘或后台运行时仍属于既有实例；
- 数据目录 lease 是阻止双写的最终裁决。既有 Host 无响应或协议不兼容时不得绕过 lease 启动第二套 Store：交互式启动显示固定的可操作提示并以失败状态退出，automation 不显示系统对话框并以失败状态退出；
- 一体化标题栏由 Renderer 绘制窗口按钮并提交固定语义意图，Bridge 校验 transport authority 后交由 Application 通过 Native SDK Runtime API 或已登记 Native Compat seam 执行；Windows 用户双击有效标题栏候选区时切换最大化/还原，普通按下仍进入系统拖动语义，macOS 保留 Native SDK 与系统偏好定义的标题栏双击行为；Renderer 不持有原生窗口 identity、handle 或执行权；
- 提供受控的文件/目录选择；
- 为通知、更新和系统集成保留明确入口；
- Renderer 只能调用 Host 显式开放的领域命令。

### 5.9 Workbench 界面与任务组织

- Account 未登录只使 Metask provider 无法建立新的目录或解析；是否允许创建和发送新 Task仍只取决于 Product Control 的 ready execution admission。Workbench 持续展示 Workspace、durable Task 与执行历史，并允许查看和停止真实 live Run；
- Workbench 左栏承担稳定 New task、已接通的全局能力入口、全局 Task 列表与左下角账号入口；`新建任务`、`技能`、`MCP` 与 `定时任务` 使用同一紧凑一级菜单的相同行高、缩进和 active 语义，不用额外留白或独立大按钮制造虚假层级；只有真实接通的 capability 才显示对应入口。所有可见 Task 在同一连续列表中只出现一次，不按需要处理、运行、排队、最近或归档状态拆分栏目；状态由行内语义图标表达，排序由单一规则独立决定；
- New task 中央区域始终以 Composer 为主，当前模型和 Workspace 在发送前可见；API 管理不进入 Composer，模型与 Workspace 也不得混成不透明的单一“模式”；
- Task 启动后中央区域显示该 Task 的 Run exchanges，Composer 固定在底部。叙事、唯一 live status、审批和必要结果提示留在主阅读流；Work process 默认折叠，展开后可以在所属 Tool 行下方独立展开精确 Tool 详情。存在 Tool 的 terminal Run 保留折叠的 Work process 作为历史检查入口；完整详情使用有界代码面，不打开或替换右栏内容。Run 用量不进入对话或右栏展示。Composer 附近只按 Host pressure 显示当前 Conversation 的上下文提醒，pressure 消失后隐藏，历史自动压缩记录不单独展示。pendingUi 只派生“需要处理”定位入口，不自动开面板、滚动或抢焦点；用户点击时定位主区唯一原始请求，覆盖式右栏先关闭；
- 应用采用左侧栏、中央工作区、右侧栏的布局；栏的入口、显隐和尺寸属于应用布局，不属于 Task 或具体内容功能。左栏保存 240–480 px 范围内的绝对宽度；停靠时中央工作区与右栏以 Flex 按保存比例分配扣除左栏后的剩余宽度，两者都只设置 360 px 最小宽度，不设置固定最大宽度或固定比例范围。约束无法同时满足时右栏改为非模态 overlay，不压缩中央工作区；右栏只在停靠态允许调整，用户调整的实际像素换算为剩余宽度中的比例保存，窗口或左栏变化只按该比例重新分配。右侧栏开关在主工作界面常驻，无 Task 或无可展示内容时仍可打开真实空态。用户打开具体详情可显式展开右栏；切换或删除 Task、切换主页面、目标失效与普通 Run/审批变化只更新或清理内容，不自动改变右栏显隐或保存比例。显隐保持本窗口会话中的用户选择，不记录每 Task 显隐。设置覆盖层及窄窗左右栏互斥规则由 UI 规范定义。右栏不提供概览；文件预览以对话中的有效文件引用为主要入口，修改审查保留所属 Run 的入口，Tool 详情只在所属 Work process 内原位展开。右栏在当前 Task 内使用对象标签：可同时保留多个精确文件预览和一个 File Changes Review，Review 仍直接呈现同 Run 的连续差异文档，不建立列表页、详情页或返回层级。隐藏右栏保留当前 Task 的标签和已读取正文，关闭标签才释放对应资源；切换 Task 清空全部对象但不改变右栏显隐。身份失效必须在渲染前只移除受影响对象并阻止旧内容出现。面板不提供加号、任意文件浏览、文件树、编辑器、Git 操作或跨 Task 标签恢复；
- `queued / running / waiting_user` 的停止入口位于 Composer 的发送位置，并替换发送按钮；标题栏不重复提供 Task Stop。Composer 仍只保存本地草稿，停止请求必须等待 canonical terminal，transport acknowledgement 或 UI 状态变化都不能伪造 `Stopped`；
- 标题栏只承载 Renderer 绘制的窗口按钮、当前 Task 名称、搜索与异常状态等全局入口；不重复说明 Task 的 Workspace，正常连接状态、语言选择和工程诊断也不长期占据主视觉；
- 界面在任一时刻只突出一个与当前阶段一致的主动作；独立的导航和设置入口可以持续可见，但不得与主动作竞争；
- 首个正式版本采用单主窗口；多个 Task 可以后台运行，切换 Task 不停止执行；
- 成功完成提醒是绑定最新 terminal `completed` Run 的一次性未读产品事实，不是 Renderer 会话内装饰状态。用户只有在对应 Task 的中央工作面真实可见且应用位于前台时才确认该 Run；后台完成、全局页面、设置/搜索、窄窗侧栏或全宽 Task Panel 覆盖期间都不得误清。确认结果随 Task 历史在正常关闭后恢复，新成功 Run 使用新 identity 再次提醒；归档 Task 等价于明确处理当前完成提醒。该 receipt 不改变 Task 最近顺序，Renderer 不使用 `localStorage`、时间戳或标题推断；
- Renderer reload、断开连接以及 Bridge revision/snapshot failure 默认只影响视图同步和重连，不得终止后台 Agent Run；只有 Workbench 根据 canonical 产品状态作出的显式 termination 决策才能请求结束 Run；
- 左栏直接列出 canonical snapshot 中 owning Workspace 仍被投影的全部 Task，不提供全局 Workspace 切换器；每个 Task 的路径由自身上下文决定，后台请求不能因路径不同而从导航中消失。已移除 Workspace 的历史 Task 仍由 Workbench 保存，但随 Workspace 退出活动导航，重新授权恢复同一稳定 Workspace identity 后才重新出现；
- Task 是可持续补充、归档和删除的产品对象；Task lifecycle、当前 Run phase 和最近一次 Run outcome 是三类独立状态，Renderer 只能从 Workbench projection 派生展示标签；
- 中间区域只按产品 Run exchange 组织内容，不按 raw Tool callback 或 AgentCore event 构造时间线。主区可以展示 typed Tool 摘要，但不展示 Tool input/progress/result、usage、Run ID、raw AgentCore event 或 chain-of-thought。Renderer 只消费 typed `output/activity/tools`，不把可见回复提升为 Delivery、Output artifact 或最终成果；完成、失败、中断与恢复动作只依据独立 canonical outcome/cause；
- Run 执行期间的新输入不得暗示可以修改当前 Run；首版只保存 Renderer 草稿，等待当前 Run terminal 后由用户明确发送，不自动创建或启动下一次 Run；
- Composer 以 `/` 作为 context-aware 发现手势，统一显示 Renderer 注册的产品 Command 与当前 Workspace/Task catalog 投影的 Skill；Slash 文本本身不是 Agent 输入协议，Command 必须在 Renderer 消费且不得进入 Bridge、Task 历史或 AgentCore；
- Command 只复用已有产品动作，不迁移 CLI/TUI 的会话控制语义；V1 只注册 `/new` 与 `/compact`，前者打开既有 New task draft action，后者触发 Workbench-owned typed maintenance action；不注册 `/model`、`/status`、`/goal`、`/resume`、`/continue` 或其他已有正式界面、与桌面产品对象冲突、缺少 typed capability 的 identifier；
- Skill 选择形成单一、可移除的 typed Composer draft，同时保留稳定 Skill identity、catalog revision、selection revision 和 positional arguments；New task 使用 Workspace current catalog 与 current committed selection，已有 Task 使用其 pinned catalog 与 pinned selection。任一 revision 过期、Skill 已禁用或不可用时保留参数但禁止发送，必须显式刷新并重新选择，Renderer 不读取 Skill body、不猜测目录或权限；
- Skill 中心是 MetaWork 级的本地 Skill 管理 route，不跟随当前 Task 的路径上下文。它按个人与已注册 Manual Workspace 的项目范围展示 Skill 资产，并把需要处理的定义错误、资源错误和冲突置于正常 Skill 之前；用户可以搜索、查看说明/参数/资源/健康状态，从本地 `.skill`、`.zip` 或目录导入，导出 `.skill`，重新导入，卸载并显式刷新 catalog。Personal 列表的开关定义所有项目继承的用户默认值；Manual Workspace 项目列表以 `inherit | enabled | disabled` 三态覆盖该默认值，清除覆盖后重新跟随用户。当前 AgentCore `skill_id` 被视为逻辑调用身份，同 invocation 的 Personal/Project Skill 共用策略键，invocation 改名后策略不跟随；MetaWork 不猜测未公开的来源身份。当前不提供在线市场、远程更新、Skill 创建/编辑器、Preset、标签、排序、中央仓库或多 Agent 同步；
- Skill 管理资产与运行时 catalog 是两份不同真相。Workbench 拥有本地 package/inventory、安装 provenance、目标范围、安全文件事务和管理状态；AgentCore 继续独占 runtime discovery、canonical priority、winner/conflict、health 与 catalog revision。MetaWork 使用独立 `install_id` 管理资产，运行时身份仍是 `catalog_scope_id + skill_id`；Renderer 不从名称、路径或 invocation 猜测来源、范围、优先级或身份。MetaWork 未能在已授权 canonical Skill root 中解析并取得精确管理 authority 的现有 Skill 仍可按 AgentCore projection 展示，但必须标记为外部管理，隐藏导出、重新导入和卸载；
- Skill 中心在页面内提供 Claude、Codex 两个兼容来源勾选，默认关闭；每次操作同时启用或关闭该品牌的个人与全部已授权手动项目目录，`.agents/skills` 默认来源始终启用。不提供来源抽屉、逐目录开关、自由路径、排序或逐项目来源设置，Automatic Workspace 保持 Text-only。只发现当前 AgentCore 支持的 Skill，不继承其他工具的权限或配置。来源配置持久保存；已有个人/项目值不一致时如实显示部分启用，用户操作后才统一，不自动迁移选择。缺失目录不撤销勾选；保存成功与 catalog 就绪分别呈现。来源变化只影响新的 current authority，已有 Task 仍需显式刷新；目录问题即使没有 winner/资产仍可见，搜索不隐藏问题；
- Skill 启用状态是 Workbench-owned 的 User/Manual Workspace policy，默认启用，只持久化 disabled `skill_policy_key` 与 Workspace override，以及单调 `selection_revision`；持久键精确使用 User policy 或 `workspace_id + skill_policy_key`，不使用易随内容变化的 concrete `skill_id`，也不持久化 Workspace epoch。同一 Manual Workspace registry record 无论经历多少次移除失败或重新授权，其 policy 与本地安装记录都保留；只有该 id 退出 registry 才退休记录，Skill 文件不因此删除。Skill 持久文件只接受当前格式，不迁移、隔离或恢复被替代的数据；能读取但无法解码的记录直接放弃，MetaWork 从空的管理状态与策略继续，并在同次启动中原子写入空的当前格式，不要求用户清理或重启。自动替换失败或文件读取失败时拒绝分配新的 Workspace id（Manual 与 Automatic 均拒绝，New task admission 与 Automatic capability 同步显示不可用），已有 record 仍可重新授权；普通 mutation 的明确写失败仍保留已知 id authority，不阻止分配新 id，但在两个 Skill store 都允许安全退休前不得复用隐藏 Workspace slot。mutation 同时校验 Workspace 当前 epoch、catalog revision 和 selection revision，成功后只影响对应 current policy；已经创建的 Task/Session 不热替换，只有 idle Task 显式刷新才采用新 policy。Host 重启恢复 Conversation 时不查询或隐式重绑 Skill catalog，恢复后的 Task catalog 为 uninitialized；Manual Task 只有在 idle 状态显式刷新后才采用 Workspace 当前 catalog 与 committed policy，Automatic Task 保持 Text-only；
- 本地导入必须由 Host 原生文件/目录选择产生的一次性、window-bound staged capability 发起；Renderer 不提交任意物理路径。导入在目标范围外完成有界解压、路径/类型/容量检查和只读预览，经用户确认后原子发布到个人或指定 Manual Workspace 的 `.agents/skills`。明确属于候选 Skill 的 AgentCore definition/resource/conflict failure 必须回滚；catalog 暂时无法完成验证时保留已发布资产并进入 `pending_verification`，不能伪装成可用。替换或卸载不得与可能消费该范围的 active operation 并发，不得静默覆盖现有目录，并必须保留可恢复的事务前副本直到提交完成；
- 文件事务明确失败时尝试一次当前资产的安全恢复；仍未收敛的资产显示“需要恢复”，通过现有 Retry 重试，不能冒充“等待验证”或 ready。management 持久化失败时暂停管理并提示重启后重新加载、尝试恢复；恢复准入与冻结边界由 [Product 架构](product-architecture.md#24-skill-authority-与本地资产)定义；
- 用户创建或修改 Skill 仍通过普通 Text Run 与 AgentCore built-in Read/Edit 完成，不在 Skill 中心建立第二个创作或文件编辑器。Workspace 内的 `.agents/skills` 服从现有 Workspace authority；用户级目录只有在用户通过原生 picker 明确把目标 Skill 目录授权为 Manual Workspace 后才能修改。Skill 中心可以导航到预填的普通 Text draft；项目 Skill 创建完成后通过显式 catalog refresh 出现，个人 Skill 通过受控本地导入发布。一次 Run 使用已绑定 snapshot，不热替换正在执行的 Skill；文件变化只在显式 catalog refresh 后影响后续选择与 Run；
- Host 重启后恢复的历史 Task 先以 detached、可阅读状态出现；满足恢复资格时，用户选择左栏 Task 只看到已保存产品历史与普通 Composer，不显示恢复卡片、恢复按钮或专用 placeholder。用户首次发送新消息时，Renderer 在同一次发送意图内先提交 restore，等待 Host 确认 attachment 后再精确提交一次 Text Run；失败时保留草稿并显示可执行的失败说明，下一次普通发送可以重试。只有 source Task/binding、checkpoint ownership、Workspace/Task identity、Conversation、terminal state 与当前 execution target readiness 均可安全恢复后才允许该内部前置步骤；Skill/MCP/Permission continuity 缺失只产生 degraded 能力状态。历史 execution generation 不要求等于当前 generation：同 protocol 且当前 authority 可承载 Task model 时，restore 必须以 durable adoption 同步推进 Task generation、binding epoch 与 checkpoint anchor 后再安装 attachment，并保留旧 Run 的逐 Run provenance。该窄 adoption 只连接同一 Task 的 source Conversation 与当前可执行 target，不允许切换 protocol/model，也不构成通用 rebind；任意配置 rebind 或从历史创建新 Task 仍属于后续显式产品能力，当前实现不得用它们冒充恢复；
- Run 中 AgentCore `tool_result.file_refs` 提供的结构化文件引用是 File Preview 目标的唯一依据。Renderer 在过程说明与结果回复中将可无歧义匹配本 Run 已知引用的文件名称或链接呈现为内联预览入口；工作过程不提供文件预览入口，只允许把结构化 `displayPath` 作为 Tool 单行摘要中的只读文字。用户显式选择正文入口后才通过精确 `taskId + runId + fileReferenceId` 请求 Host 读取 Workspace 中的当前文件内容；预览进入 Task Panel 独占的文件预览视图，以当前路径为标题且不汇总显示全部引用文件；具体入口与切换行为由 [UI 设计规范](ui-design.md#121-文件预览)定义。该能力读取当前内容而非 Run 时版本，只在当前 Task 的已打开标签中保留已读正文，不跨标签关闭、Task 切换或应用会话缓存，不持久化、不自动刷新，也不把 reference 的 kind、Tool 名称、普通文本或 Bash 输出解释为文件变更、Output 或 citation；这些底层语义不要求以常驻提示或说明入口重复展示。Host 必须在独立有界 worker lane 中执行 no-follow、root-contained、regular-file-only 的最多 256 KiB UTF-8 文本读取，主线程在响应前重新校验 Task/Run/reference/Workspace authority，并以当前及历史 execution credential 做内容脱敏；非 ready 状态不得携带正文；
- `Files changed` 表示实际文件变更集合，`Outputs` 表示用户关心的交付结果，两者不得用“新建文件”或 File Preview reference 自动等同；File Changes 只消费 AgentCore typed `file_changes` observation，并在右侧 Task Panel 的连续 Review 文档中按文件首次出现顺序展示。同一 `displayPath` 的记录按稳定顺序汇入一个文件区块；首个文件的首条 recorded diff 立即按需读取，其余记录只在所属区块接近可见区域时逐条读取。同一个已打开 Review 可以同时保留已经读取的多个正文，隐藏右栏或切换其他标签后继续复用；关闭 Review 标签、替换目标或重新打开已关闭的 Review 后不得复用。Review 与每条 recorded diff 必须绑定同一 `taskId + runId + changeId`；关闭 Review 标签、切换 Task、目标 Run 或具体记录失效都必须使对应旧异步结果失效，单条记录失效只更新所属文件区块而不清空仍有效的 Review；普通 Run 生命周期变化不得关闭仍有效的历史 Review；typed Output 尚未提供，因此 Outputs 模块必须继续隐藏；
- Task 归档只隐藏日常列表且可恢复；归档、删除 Task 或移除 Workspace 前必须先终止其 queued/running/waiting/stopping Run。删除只允许已归档 Task；Workbench 接受一次删除意图后负责收口仍存活的 Session，并在 executor stable record reference、checkpoint 与全部资源 quiescent 后原子提交和物理释放，不要求用户为正常推进重复提交。删除进度以 runtime-only 的 `idle | deleting | failed` 产品事实发布，不持久化、不混入 Task lifecycle 或 Agent Session 状态；明确失败必须保留归档 Task 并等待用户显式重试，不能伪造成功、静默回弹或自动形成重试循环。若失败后 attachment 已恢复到可用状态，用户显式恢复归档表示放弃该次删除，Workbench 必须把删除状态原子重置为 `idle`；仍在 closing 的 Task 不开放恢复归档。删除 Task 记录不删除 Workspace 中的真实文件；移除 Workspace 先原子进入 `removing` 并推进 Workspace epoch、拒绝新 admission，全部 Task 收口后撤销当前 Host authorization 并退出活动导航；
- 全局搜索覆盖 Task、用户指令、完成消息和 Output 文件名；Workspace 只作为 Task 与 New task 的路径上下文，不作为独立导航结果；工具原始日志默认不进入普通搜索；
- `en-US` 是规范产品文案和回退语言，`zh-CN` 是首个完整 locale；Host 传递 structured code 与参数，Renderer 负责本地化。

### 5.10 MCP 服务

- `MCP` 是与 `新建任务`、`技能`、`定时任务` 同级的 MetaWork 全局页面，不跟随当前 Task 或 Workspace，左栏入口稳定显示。`capabilities.mcpManagement` 只声明 revision 1 的 typed 管理合同是否真实接通，不与 Runtime 是否 ready、registry 是否为空或管理事务是否暂时冻结做等值判断；`mcp.availability` 独立表示当前 Runtime/catalog 可用性。
- 成熟接入范围固定为 STDIO 与 Streamable HTTP、Tools，以及 `none | static | oauth` 三类授权。OAuth 只适用于 Streamable HTTP；STDIO 的 static credential 只经显式 environment name 注入，HTTP static credential 只经显式 header name 注入。Host 只允许 AgentCore 使用 `2026-07-28`、`2025-11-25` 与 `2025-06-18` 三个 exact era；显式 `modern_only` 与 `compat_only` 分别固定前两个，`automatic` 可以协商并 exact reopen 到三者之一。其他版本、legacy SSE、Resources、Prompts、Apps 与 Tasks 一律拒绝。MCP era 不构成旧 AgentCore ABI revision 的兼容路径。用户显式提交 Add/Replace 就是对该完整连接的授权：新 server 默认 enabled、connection-approved 且 tool allowlist 为空，新发现 tool 也默认不扩权。用户可以在详情中对当前已发现的工具做一次显式批量放行；该动作仍是全量 allowlist 重提交，且此后新发现的工具依旧默认排除。schema 1 迁移产生的 unapproved server 仍保留一次 legacy connect 动作，不让普通新建流程重复审核用户刚提交的配置。
- 添加服务是 transport-discriminated 的 typed 流程，不是 generic upsert。STDIO 配置只接受可执行文件、argv、可选 cwd、environment name 与对应 secret slot；不提供 shell string、命令替换、credential argv 或整个进程环境继承。Host 只从启动环境复制非敏感 executable search path，并在绝对 command 前置其所在目录，以支持 `/usr/bin/env` shebang 和 bare executable lookup；该 `PATH` 与 Windows `SystemRoot` 是不可由用户 environment slot 覆盖的受控基线，其他变量一律不继承。Streamable HTTP 配置只接受 endpoint、auth mode 和有界 header name；endpoint 只允许原始 authority 被完整、无歧义解析的 HTTPS 或精确 loopback HTTP，禁止 userinfo、query、fragment、authority percent encoding、空白、控制字符和反斜杠。Renderer 可以提交公开配置，并通过普通 password input 临时采集用户显式填写的 static secret 与 OAuth client secret，经专用 typed command 交给 Host 写入独立系统 credential service；输入生命周期与提交边界遵守 [Renderer Bridge 合同](renderer-bridge-contract.md)。
- 连接信任不建立独立于配置提交的常规审核步骤。Add/Replace 的确认按钮绑定 transport、endpoint 或 command/argv/cwd、environment/header name、auth mode 与协议策略，并在同一个 Desired Registry transaction 中写入 connection fingerprint；在用户提交之前不得启动 child、读取 credential、发网络请求或打开 OAuth browser。OAuth consent 仍是独立安全边界：connection-approved 后才执行无凭据、有界 discovery；本版 registration plan 明确为用户提供 client id 与 `none | client_secret_basic | client_secret_post` token endpoint auth method 的 `pre_registered`，或 authorization server metadata 明确提供 endpoint 时的 `dynamic_registration`，前者需要的 client secret 由上述 Renderer password input 提交。DCR confidential result 只有在 `client_secret_expires_at` 缺失或为 `0` 时才能进入现有 client-credential revision；非零 expiry 在没有 secret renewal owner 的本期必须按已可能产生远端 client 的 outcome unknown 收口。OAuth Consent 绑定 connection approval、canonical resource、exact issuer、requested scopes、redirect identity、registration kind、client identity 与 client-credential revision；callback 必须校验 state、PKCE S256、redirect identity，并按 2026-07-28 规则对出现的 `iss` 做 exact comparison。
- 页面采用成熟 MCP 客户端共有的“Desired Registry、当前 Runtime/catalog、新 Task authority”分层。Workbench 以 Desired Registry、与当前 Agent Runtime 同寿命的 Runtime Manifest、Agent Activation 和 Admission Authority 形成单一控制面：`desired enabled` 是用户意图，connection approval、auth readiness 与结构有效性共同决定服务是否具备 Runtime/Admission 资格；已批准但缺凭证的服务可以保持 enabled intent，却必须以 `needs_authentication` 排除在 Runtime 与新 Task authority 之外。新 Task 只消费 Admission Authority，禁止绕回 Agent current selection；既有 Task 保持 AgentCore 在创建时同步复制的 authority，不热替换或承诺即时撤权。
- MCP 配置是 Workbench-owned 的全局产品配置，不属于 Metask Account、Workspace 或 AgentCore 协议状态。Host 从 `<MetaWork data dir>/mcp/registry.json` schema 2 恢复稳定 identity/namespace、transport、auth mode、connection approval、OAuth consent/registration/grant 的非 secret 事实、credential locator、启停、timeout、协商策略、显式 tool allowlist，以及 nullable 顶层 `oauth_operation` marker；marker kind 只允许 `dynamic_registration | code_exchange | refresh`。Host 分别生成外部稳定 server identity 与 AgentCore namespace：identity 使用 `mcp-<20 位小写 hex>`，namespace 使用 `mcp_<20 位小写 hex>`，namespace 必须以 ASCII 字母开头且其余字符只允许 ASCII 字母、数字或 `_`，不能把 identity 直接复用为 namespace。旧 registry 中结构可恢复但不满足运行时语法的 namespace 只使对应 server 进入 `invalid_catalog`，不得污染整个 registry 或进入 Agent Runtime；用户删除后重新创建服务即可获得新 namespace。schema 1 只迁移既有 identity/config/allowlist/locator，并统一落为 disabled + unapproved。Registry 保持单一全局 desired generation、单一 credential transaction journal 和全 registry locator 引用差分，不保存 secret、token、authorization code 或 PKCE verifier。写入/清除 operation marker 是同一 registry 文件上的 operation-state commit，不推进 desired generation；只有 server target 变化才推进 generation。
- Runtime Manifest 只在内存中记录当前 Runtime 已接管的 loaded descriptor fingerprint，或 disabled、invalid、unapproved、missing-authentication、reauth-required 等未加载 server 的安全 absence proof；成功接管零个 server 的 Runtime 必须提交零 entry Manifest。Desired mutation 明确保存后，Application 从 canonical registry 重新 preparation，构造完整 replacement，调用 AgentCore Runtime MCP configuration apply，再执行正式 activation/tool discovery，并把新 Manifest、Activation 与 Admission Authority 作为同一完成事务安装；该路径不要求重启 MetaWork。`configurationApply = idle | applying | failed` 是公开的应用状态；`runtimeAlignment = restart_required` 只表示 desired 与当前正式 Runtime 尚未对齐的内部兼容事实，UI 必须翻译成 connecting 或可重试的 apply failure，不能要求用户重启。旧 connector owner 在 AgentCore retain 和 active connection 完全归零后回收，仍被既有 Session 使用时至少保留到对应引用释放，最迟由 Agent Runtime 销毁统一释放；既有 Session 继续使用创建时同步复制的 authority，新 Task 只在完成事务成功后取得新 authority。同一 OAuth consent epoch 内的 token revision 仍通过 CAS 原子替换 ref-counted HTTP auth snapshot。tool-only mutation 可以直接更新后续新 Task authority，不重建 transport。
- 每个 registry mutation 从 canonical desired 构建 immutable target，并携带 `expectedDesiredGeneration`。Renderer 从 Host projection 获得完整、typed 的非敏感连接配置，编辑时以该配置原样预填并重新提交完整目标；不得从 basename、数量或 origin 等摘要猜测旧值。Static credential locator 只在接收目标未改变时按同名 slot 沿用：STDIO 目标由 command、ordered argv 与 cwd 共同确定，HTTP 目标由 endpoint 确定；目标、auth mode 或 slot 变化使不再引用的 locator 经同一事务退休，display name、timeout 与协议策略变化不移动 credential。Runtime-compatible authority 变化先构建 owned candidate selection，随后按既有 journal/credential/registry 顺序持久化，明确成功后才 no-fail 安装 target 与 candidate。Runtime-incompatible target 安装 blocked admission；明确失败不改变旧 desired/authority；saved recovery required 安装已知 target 后冻结 mutation；outcome unknown 不宣称 canonical desired/generation，并阻止新 Task 取得 MCP。`oauth_operation` 活跃时拒绝同 server 的编辑/删除/授权 mutation；其他 server mutation 可以提交，但必须原样保留 marker。外部结果返回后不要求起始 global generation 仍相同，而是先按 operation id 和 server-bound fingerprints 校验当前 canonical registry，再从当前 generation 构建 target，确保无关 server 变更不会丢失或把已成功的远端 effect 误判为 stale。
- DCR、authorization-code exchange 与 refresh 都是不可回滚外部操作，统一使用持久 `oauth_operation`。操作开始前若目标 server 当前进入 Admission Authority，Workbench 必须先基于 current catalog 预构建排除该 server 的 owned selection；marker 落盘后 no-fail 安装 reduced authority，再允许发送请求，无法构建时不得产生外部 effect。每次 marker 绑定 kind、server、connection approval、consent draft/epoch 和适用 token revision；DCR success 构造 issued client identity 和可选 fresh client-secret locator，token success 构造 fresh token locators、schema 2 target、HTTP auth snapshot 与恢复目标 server 的 Admission candidate，再经既有事务提交并 no-fail 安装。明确收到未创建 client 的 DCR rejection 可以清除 marker 并进入 `client_registration_required`；`invalid_grant`、响应丢失、成功后落盘失败、结果不确定或启动发现遗留 marker 都进入 `reauth_required` 并保持 reduced authority，不得重放、回滚到旧 active token 或猜测成功。DCR outcome unknown 可能遗留一个远端 registration，UI 必须说明再次尝试可能新建 client，本期不声称远端 revoke。Cancel 在 non-idempotent request 发送前可以安全清除 ephemeral state；请求可能已发送后只能停止本地等待并提交 `reauth_required`，不能把 socket cancel 当作远端未执行。Application 只维护一个 earliest-expiry timer，把到期 server 提交给 Workbench 的全局单 OAuth operation；这不是通用 lease scheduler。401/403 challenge 只发布 typed reauthorization fact，scope step-up 必须取既有 requested scopes 与 challenge scopes 的 union 并重新 consent，不在失败请求内递归重试。
- MCP 配置准备、Agent Runtime 配置应用和 MCP 激活是三个不同失败边界：Registry/approval/credential 等可归因 MCP 故障发布 unavailable/degraded，普通 Task 仍可运行；正式 Agent Runtime init 或 AgentCore Runtime create 失败是 Application 启动失败。Application 正式以 canonical empty MCP Runtime 和零 entry Manifest 完成启动；恢复出的 Desired 由既有 configuration-apply coordinator 在后台执行完整 replacement 与 activation，外部 MCP child、network、handshake 和 catalog discovery 不进入 Application 或普通 Task 的 readiness 关键路径。apply 完成前创建的 Task 使用 null MCP authority并保持创建时语义，成功完成后只有新 Task 取得新 authority。普通 Add/Edit/Enable/Disable/Delete 在保存后自动启动正式配置应用，不要求用户先测试。首次用户主流程固定为添加服务、完成必要认证、自动连接并发现工具、显式选择工具、新 Task 可用；Add 的提交动作不声称默认关闭的工具已经开放，正式 catalog 已发现工具但 allowlist 仍为空时必须继续呈现选择工具这一步。`测试连接` 只作为按目标 server 启动隔离候选 Runtime 的诊断动作，并只把 `testing | connected | failed`、tool count 与 issue count 写入进程内安全 projection；它不替换正式 Runtime、不改变 Manifest/Admission、不创建 Task，也不持久化 catalog，不得覆盖列表主状态或成为正式失败恢复动作。Refresh、apply、mutation、OAuth operation、测试与新 Task admission 由现有 owner 串行化；shutdown 必须 join 这些 worker 后再释放管理 owner。
- 页面按需要处理、可用与已停用组织，桌面端使用与 Skill、Scheduled tasks 一致的居中有界管理页；连接列表占据完整页面宽度，只有用户明确选择服务或 Add/Edit 时才打开可关闭的右侧 drawer，空 registry、无选择或 drawer 关闭时不得预留第二列，窄窗 drawer 占满可用宽度。详情用 `Connection → MCP handshake → Tools` 轨迹呈现真实应用进度，工具授权紧随连接成功结果；连接测试保留为次级诊断。STDIO 的普通输入允许粘贴一条启动命令，Renderer 只进行有界、安全的引号/转义分词并拒绝 pipe、重定向、变量/命令替换，Bridge 仍只接收结构化 command + ordered argv，Host 绝不调用 shell。完整非敏感 typed connection、typed diagnostic 与工具目录可查看和预填编辑；environment/header value、credential locator、client secret、token/code/PKCE、动态注册所得内部材料、raw diagnostic、schema body、fingerprint 和 AgentCore handle 仍不得进入 snapshot。marketplace/import、publisher trust、Task/Workspace override、多账号、远程 token revoke 与既有 Session 热撤权不在本期范围。

### 5.11 定时任务

- `定时任务` 是与 `新建任务`、`技能` 同级的独立页面，不属于 Skill 中心、交互式 Task 或某个 Workspace 的子页面；页面不显示或选择 Workspace，每次 occurrence 直接请求新的 Automatic Workspace；
- 没有定义时，页面提供可采用的 Text 建议模板，并保留页首统一 `新建定时任务` 入口；不建立无法推导时间规则的伪自然语言快捷入口。Text 模板和普通定时任务都使用自动工作区，不要求用户先添加或选择 Manual Workspace。已有定义时切换为搜索工具栏，并按 `需要处理 / 进行中 / 已暂停 / 已完成` 组织。紧凑行显示名称、计划、下一次运行、最近结果及其真实 Task 链接，并提供编辑、暂停/恢复、立即运行和删除；
- 创建流程按名称、任务说明、权限、运行时间和确认摘要排列；权限默认采用当前新任务默认值，保存后固定在定义上；不提供 Workspace 或 Skill 配置、catalog revision 或参数配置，不得让空页面先暴露 protocol、generation、Unix seconds 或固定间隔秒数等工程字段；
- 首版支持一次性、每小时、每日、每周和由明确起点开始的固定间隔；Host 保存 canonical Unix time、locale-independent recurrence 与创建时 timezone identity，Renderer 只负责本地化显示和结构化编辑，不用本地 timer 推进产品状态；
- 每次自动或手动触发创建一个新的真实 Task。计划定义不复用旧 Conversation、不把结果复制成第二份聊天历史，也不绕过既有 Task/Run admission；
- 同一 Scheduled Task 的上一次 Task 仍有 non-terminal Run 时，自动触发必须跳过本次；不得并发重放同一计划或自动终止已有 Run。若历史中的 Task 已永久不可用，Schedule 必须把该 occurrence 收口为 `unavailable` 并继续检查其他待收口 occurrence，不能形成队头阻塞；
- 自动触发使用 `(scheduledTaskId, plannedAt)` 形成跨 Host 恢复稳定的 occurrence identity；后台 Host 延迟、休眠或重启恢复时最多接纳一个最新的到期 occurrence，过去的多个时间点不批量补跑，并在 occurrence history 中明确标记 delayed/skipped；
- Scheduled Task 定义、触发游标和有界 occurrence history 由 Workbench 在产品数据目录原子持久化。唯一 canonical `schema_version = 1`；每个定义必须完整保存 `ModelRef + source_generation + selection_revision + protocol`，不接受缺少 source identity 的旧 shape，不提供 legacy decoder、启动迁移或运行时 fallback。未知 version、旧 shape、损坏 bytes、commit 结果不确定或恢复校验失败必须 fail closed 并发布 typed persistence health，不得回退成可执行空列表或继续使用可能重复的游标。显式恢复由用户确认，Schedule 编码当前内存真相，Application 将原 canonical 改名为唯一 quarantine artifact 后原子安装新 store；中断由精确 pending marker 保持 fail closed，再次显式恢复必须先把旧 backup 收口为 quarantine、清除 temp 并最后清除 marker，随后才能开始新事务。孤立 artifact 和相似文件名不得阻止正常 canonical 读取；失败或中断不得让旧数据消失或伪装成首次启动，恢复成功后才重新开放 mutation 与 timer；
- 主窗口关闭使用后台/托盘形态而不是销毁 Host；后台 Host 继续 timer、Run、通知与待处理事实，托盘提供重新打开和显式退出。显式退出可以停止本机后台执行，但下次启动仍恢复定义并执行上述单次 missed-run reconciliation；
- 执行配置、Workspace authority、容量或 shutdown gate 不再满足时，计划进入明确的 `needs_attention`，停止继续计时并保留 typed 原因；用户必须编辑并确认当前事实后才能恢复；
- Scheduled Task 定义必须固定一份可持久化、可恢复的非交互 `PermissionProfile`；默认值后续变化不得改写既有定义，编辑生效前必须重新经过 definition admission。编辑 paused 定义只更新未来执行内容，不得静默重新启用；
- occurrence 不得进入同步 permission wait。若固定 profile 无法覆盖某个操作，当前 occurrence 以 typed `permission_required`（或经批准的等价产品原因）停止，并使定义进入 `needs_attention`；系统通知只能定位该真实 Task 和原因，不能承担远程批准、临时升级或继续原 Run 的职责；
- Scheduled Task 和 occurrence 不保存 credential、Authorization header、OAuth URL 或 AgentCore handle；计划标题和 Text instruction 进入产品 projection 前执行与 Task history 相同的有界复制和 credential 清洗；
- 每次 occurrence 必须精确校验定义的 `ModelRef + source_generation + selection_revision + protocol` 与当前 Models default，并由 Product Control 当次 resolve；selection revision 必须阻止 default 的 A→B→A 静默复用。Product Control 的进程内 generation 可以在冷启动后变化；只要 source authority 未变，该变化不得单独使 Scheduled Task 进入 `needs_attention`。Catalog 或 execution authority 尚未就绪属于瞬态 admission 事实，只停止 resolve、occurrence 与 timer，不得持久化为 definition failure。当 Metask 是定义引用的 provider 时，Account 退出使其对新 resolve 不可用并停止 occurrence；custom provider 不受 Account 状态影响，已创建 Task/Run 也不被追溯撤销；
- occurrence 完成、失败、跳过或等待用户时进入有界历史并发出系统通知；历史 Task 已永久不可用时只把 occurrence 收口为 `unavailable`，不得发送误导性的 Task 失败通知。通知点击只定位真实 Task/请求，不携带 secret 或建立第二状态面；通知不可用不得改变 Run terminal cause；
- AgentCore 只执行被 Workbench admission 后的单次 Run，不拥有 cron、时钟、timer、OS wake 或 Scheduled Task persistence。

## 6. 非功能需求

### 安全

- Renderer 是随 MetaWork 桌面应用一同构建、签名和发布的可信 UI 组件，精确定位以[高层架构](architecture.md#31-renderer)为准；Bridge payload 仍必须严格解码，Host 仍负责 Product authority、陈旧状态、归属、容量与生命周期校验；
- Renderer 可以消费 `app.zon` 已开放的 Native SDK WebView UI/input surface，并按具体领域合同短暂转交用户明确选择的本地输入，但不因此取得通用任意文件、进程或 OS action 能力；
- Host 命令默认拒绝，只开放白名单；
- 校验来源、payload、Workspace、Task/Run 归属和权限；
- production 执行配置只由 Models 的 Metask provider 或 custom source registry 解析，并经主线程一致性提交链安装到 Product Control；禁止环境默认值、Renderer 临时字段或 Bridge payload 直接注入 Run。Renderer 可以通过 Custom Provider typed mutation提交 protocol、Base URL 与一次性 API Key，但 Models 必须重新校验、写入 registry/vault，并只从已提交 authority 生成执行配置；
- 除用户显式填写的 Custom Provider API Key 与 MCP static/client secret 可以短暂存在于本地 Renderer password form 和各自专用 typed Bridge command 外，API credential 不得进入 Renderer 或 Bridge；任何 API credential 都不得进入日志、事件、view snapshot、response、产品历史或持久化 metadata；
- Host 接收后的 OAuth token、PKCE verifier、authorization code、完整 API Key 和 Authorization header 必须进入对应单 owner secret buffer；除调用期 Renderer/Bridge 用户输入凭据的 byte view 无法承诺原地清零外，所有 owned copy 在失败、取消、过期 completion、replacement 和 shutdown 路径都先不可消除地清零再释放；
- Host 必须在形成产品 projection 前移除已知 Host-held credential 和 schema 标记的 secret 字段，并对命令与工具输出设置明确上限和 truncation 状态；不得把秘密过滤责任推给 Renderer；
- 文件访问、进程启动和高风险工具最终必须经过能力控制；
- 不向 Renderer 暴露通用任意执行或任意文件接口。

### 可靠性

- 高频事件不能造成无限内存增长；
- 控制事件、工具结果和审批不能静默丢失；
- 单个 Task 的事件不得串入其他 Task；
- Task close 和 Application shutdown 必须等待 Run 与 callback 安全退出；
- 进程模型必须通过故障注入和恢复数据选择。

### 性能

- 文本流应保持可感知的实时性；
- 高频增量允许批量合并，但不得破坏最终内容；
- 大型工具结果应通过有界对象或文件引用展示，避免无限制穿过 WebView Bridge；
- 多 Task 运行时 UI 应保持响应；
- executor、事件泵和 Bridge 必须同时设置 count、byte 和时间边界。

### 平台

- macOS 是当前优先真实验证平台；
- [macOS 分发](macos-distribution.md)默认从两个固定 canonical AgentCore target store 依次生成 arm64 与 x64 DMG，也允许显式只构建其中一个；发布架构不能由上一次 stage 的隐式状态决定，两份 target-specific 产物独立锁定和验证，当前不建立 Universal 包；
- macOS 真实 Account 本地开发必须使用 [macOS 分发](macos-distribution.md#本地签名非分发)定义的 Apple 签发、带稳定 `TeamIdentifier` 的 `Apple Development` identity；自签名或 ad-hoc 签名不能作为 Keychain 跨构建授权稳定性的验收结果；
- Windows development baseline 已完成独立 artifact、Native SDK、Bridge、AgentCore 和桌面自动化验证，不能用 macOS 结果替代；
- [Windows 分发](windows-distribution.md)已提供按用户安装的 Inno Setup 单 EXE、显式 Authenticode 签名与静默安装/卸载验收路径；MSI、自动更新、交互式 Windows 10/11 和完整安全矩阵仍是后续分发交付；
- Linux 是后续目标平台；当前 bundle target-policy 和系统链接输入按 target 隔离，但不宣称已完成 Linux 构建或验收；
- 对进入验证范围的平台形成可复现的开发构建与可运行产物路径；进入分发阶段后再要求可分发包路径。

## 7. 当前交付层级

### 7.1 当前同步执行 baseline

当前核心执行路径为：

```text
Automatic Workspace 或经原生 picker 授权的 Manual Workspace → Task（持有内部 Agent Session）→ 用户输入 → 同步 Agent Run
→ 文本流 → Agent-owned 固定 built-in 集合 → 当前 `approval_required` compatibility permission
→ 工具结果 → 最终回复 → 取消/关闭 → Renderer reload 视图重建
```

它不包含独立 AgentCore Worker crash recovery、in-flight Run 恢复、async suspend/resume、strict Workspace security 或正式 Host tools。正常 Application 重启后的 finalized Conversation attachment 恢复按现有 checkpoint 合同独立提供，不扩大上述边界。

### 7.2 Account 与 Custom Provider 集成 baseline

当前在同步执行路径之前提供：

```text
Metask 登录或配置用户 Provider → Host 后台恢复/验证 API、credential 与模型
→ 仅在真实歧义时请求默认 Provider/模型 → ready ExecutionConfig
→ 进入 Workbench → 选择 Workspace / 编辑 New task 草稿
→ Composer 确认模型 → Task admission → 当前同步执行 baseline
```

Metask C1 OAuth/login 已按 `https://app.metask-ai.com`、`metawork`、`openid profile email` 与每次登录由 OS 分配端口的 `http://localhost:<dynamic-port>/auth/metask/callback` 发布合同锁定；Models-owned C2 catalog使用已通过 production复核的无 Profile-ID通用路径。Account先提交 token rotation，再严格验证 `/api/oauth/userinfo` 并提交以 `sub` 为 principal 的 identity；Application随后以 authorization lease启动独立 Models continuation，C2失败不得抹除已完成登录。用户连接使用 Models-owned typed protocol/endpoint/credential流程，不依赖 OAuth，但必须通过 [Completion 架构](completion-architecture.md)定义的 Agent-owned one-shot test。Workbench的新 Task admission以 Models desired与 Product active binding完全一致且 ready为条件，不能把仅有 authenticated identity、目录 intent或未验证连接误报成已经可以执行。

### 7.3 Fault-domain 结论

事件泵数据、生命周期压力测试和同进程/最小 Worker fault-domain spike 已完成。结论是选择单 AgentCore Worker 作为后续正式故障域；当前应用仍是同进程 prototype，正式 Worker、跨进程恢复和危险工具重放策略不属于当前交付。

### 7.4 Windows baseline

Windows x86_64 GNU 已进入当前开发 baseline；Windows arm64 GNU 已接入 Native Release 与 Windows 安装包构建，真实 AgentCore vertical、安装启动和平台行为仍待对应环境验收。exact artifact identity 以对应 target repository lock 为准；target availability、Native Debug/Release、真实 AgentCore vertical、干净退出与分发证据以[验证规范](validation.md)为准。精确 bundle、Renderer 与 MetaWork 平台无关测试通过不能替代这些平台证据。

### 7.5 后续产品能力

`PermissionProfile` 的 Task-create owner、same-profile fresh/restore、Run provenance 与 Scheduled noninteractive，以及 typed File Changes 审查已进入当前产品；async pending、更完整的跨重启 execution rebind、strict Workspace security、正式 Host tools、typed Output、plan progress/approval、custom UI、远程 artifact 发布与正式更新、独立 AgentCore Worker 和 Linux 接入均未进入当前产品，不能反向伪装成已具备。

具体验证矩阵见 [当前验证规范](validation.md)。

## 8. 待细化的产品问题

- Task 导出格式、敏感信息清理和重新导入语义；
- 多 Agent、子 Agent 和任务图在 UI 中的呈现；
- TerminalTool 是否进入后续正式产品范围。

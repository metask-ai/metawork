# MetaWork 产品需求

> 状态：v0.5，确立持续可达的成熟 Workbench、Task 执行配置与设置边界
> 日期：2026-07-22

## 1. 产品定义

MetaWork 是一款桌面端 **Agent Workbench**。它帮助用户在本地工作区中创建和管理 Task，观察 Agent 推理后的可见工作过程，处理工具审批，并查看最终结果。

Agent 面向用户简洁地以 MetaWork AI 助手介绍自己，不主动介绍底层执行内核、模型名称或模型厂商；仅在用户明确询问相关技术信息时，依据会话运行环境提供的事实回答，可用能力也以该环境为准。新建及恢复的内部 Session 使用同一产品身份，子代理保留委派任务角色并归属于 MetaWork。此身份由 Agent 层维护，不增加用户配置入口。

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

代表 Agent 工作所针对的本地目录、任务上下文和授权身份。Workspace 是独立产品对象，不得仅从已有 Task 的路径反向推导。Manual Workspace 首次由用户通过 Host 原生目录选择器明确选择；已保存的选择跨重启保留，Host 验证该精确目录仍存在且可打开后允许直接点选，不要求重复 picker 确认；目录失效或 canonical 路径已改变时才提示不可用并要求重新选择。选择器确认本身就是该目录的产品授权，不追加 `trust`、`Use this folder` 或 Renderer boolean。一个 Manual Workspace 可以承载零个、一个或多个共享文件上下文的 Task；Automatic Workspace 由 Workbench 在调用方请求系统分配时创建，一个独立目录精确归属一个 Task。两者共用同一个 Workspace registry、Task 引用和 AgentCore admission，`kind` 只表达目录取得方式；Renderer 不得从路径或目录名推断 `kind`。Workspace 当前不是 OS sandbox 或 strict security 边界；未来只有文件、进程、network、symlink 与 TOCTOU enforcement 通过独立 Gate 后，才能扩大其安全承诺。

### Task 与内部 Agent Session

Task 是用户可持续补充的产品工作上下文，归属于 Workspace，拥有消息、运行状态、Run 历史、Session maintenance 历史和不含 secret 的 execution binding 历史。Task 的下一轮模型意图独立于全局默认、实际 Session 配置和已接纳 Run，持久保存完整来源与模型及单调 revision。已有 modelIntent 且原来源仍存在的 Task Composer 只列出其已选 Provider 的 ready 模型；modelIntent 为空或原来源已不存在时，例外列出全部 ready 来源，由用户明确重选，不从历史模型名或偏好推测 Provider。无 intent 以 revision 0 提交并建立 revision 1；原来源已不存在时仍以当前 intent revision 提交，不能重置并发保护；全局默认 Provider 变化不改写已有 Task 的来源，默认 credential、protocol、source 或 generation 变化不单独锁死仍可用的模型选择。运行中选择只影响未来 Run，保存失败保持原意图，结果不确定须经历史恢复确认后才能发送；执行切换失败保留选择及草稿，不得静默换回原模型或默认模型。attached Task 在当前进程中持有一个内部 Agent Session 与 Conversation；Session 是执行生命周期术语，不是第二个产品对象或 Renderer 身份。Run、会改变 Conversation 的 maintenance operation 与 Conversation restore 共用一个 Product Task-owned active operation 槽，不能并发进入同一 Session。历史 Task 可以跨重启恢复为 detached 记录：已有 Conversation 历史时，Host 必须证明最新 checkpoint 精确覆盖所有 included operation，并证明 Task/binding、Workspace 与 ExecutionConfig authority；若从未形成 checkpoint 且全部历史都被明确排除在 Conversation 外，则可以在原 Task 上建立空 Conversation，并从 Product 历史高水位继续分配 operation id。两种路径都不得重放历史输入。Skill、MCP 与 Permission authority 是否完整恢复只决定恢复后的能力状态；它们失效时接受 AgentCore 的 degraded Session并安全收缩能力，不能否定 Conversation恢复成功。

记录和展示容量不足不得终止 Run 或改写真实执行结果；已知记录缺口必须在所属 Run 明确呈现，完成仍可被用户查看、归档并持久保存为已读。真实依赖违约和非容量 Host 失败仍须失败收口；具体消费边界见 [AgentCore 集成契约](agentcore-integration.md#8-event-pump)。

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

Account 是 MetaWork 的 Metask 账号控制面，只负责 OAuth 登录、当前已验证 identity 与 Account credential 生命周期。Product Control 的 Models aggregate 是模型提供方，拥有内置 Metask provider、OAuth-authorized model catalog、新任务起始偏好、source generation、用户管理的 Custom Provider、模型持久化和解析合同。Account 的有效授权是 Metask provider 可用的前提，但两套体系不互相拥有：Account 退出使 Metask provider不能继续目录加载或新解析，不影响 custom source，也不回收已经交给 Task/Run 的 binding。Product Control 按明确目标解析配置、分配 execution generation 并为每个 Task 安装 owned `ExecutionConfig`，不持有全局默认执行配置。配置包含 typed `protocol + model + base_url`、opaque credential 和 binding generation。durable Task 与历史保存 Workspace、无 secret 的模型意图及实际执行 binding facts，不保存 Account identity、credential 或完整 Provider 配置。

### Scheduled Task

Scheduled Task 是 Workbench-owned 的持久自动化定义，独立描述“做什么、何时触发”。Task 是一次真实执行及其结果历史，Schedule 是触发规则，Skill 是独立的可复用执行方法；Scheduled Task 不保存 Skill identity、catalog revision 或参数，也不是 AgentCore Session、交互式 Task 草稿、Skill 子对象或第二套 automation 数据面。用户需要采用某个全局 Skill 时可以在任务指令中表达，但 occurrence 始终按普通 Text Run 重新经过当前 Execution、Workspace、容量和 shutdown admission，成功后创建一个新的真实 Task，再通过现有 bounded Executor 启动。每个 occurrence 都请求新的 Automatic Workspace，Scheduled Task 界面不提供 Manual Workspace 选择。Scheduled Task 只持久化无 secret 的指令、固定 PermissionProfile、触发游标、有界 occurrence 事实和 `ModelRef + source_generation + protocol`；不持有 API Key，也不持久化 Product Control 的进程内 execution generation。默认 profile、起始偏好或 Workspace authority 变化时不得静默改绑或重放。occurrence 使用定义固定的非交互 authority，只能执行或以 typed reason 停止，不能进入同步 permission wait、临时升级或把通知当作远程审批通道。

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
- New task 路径选择器的已添加目录来自左栏项目，即使项目没有 Task；最近使用与重新授权不能依赖 Renderer 从 Task 列表猜测。Automatic Workspace 不进入普通选择器、recent 或重新授权入口，但其 owning Task 仍可导航；
- New task 路径控件负责选择、添加和重新授权 Manual Workspace；设置页只提供 Automatic Workspace 上级目录的全局存储策略，不承担 Workspace 列表、打开、迁移、清理或重新授权。设置以覆盖 Workbench 内容区的长期 surface 呈现，保留窗口壳层和底层 Workbench 挂载，关闭后恢复原 Task、草稿、滚动和焦点；Renderer 不维护全局 active Workspace 镜像；
- 项目是按 Manual Workspace 聚合 Task 的快捷入口。项目入口状态由 Host 保存并跨重启恢复；移除只移除入口，不删除 Workspace 或本地目录，不改变已有 Task 的目录关联、授权、Run 或 Session，空项目也遵循同一规则。已有任务继续在全局“最近”列表显示，排队、执行中与等待处理的任务保持原状态并可继续使用。用户通过 Host 原生目录选择器重新添加同一目录时恢复入口；已有有效授权保持原样，缺少授权时须先完成授权，取消选择或授权失败不添加入口。目录不可用不阻止移除入口。Automatic Workspace 仍随 owning Task 管理。
- 用户可以从项目右键菜单或绑定该项目的任务信息在系统文件管理器中直接打开该项目目录，不是打开父目录后选中文件夹；不切换当前 Task，不改变目录授权、任务状态或历史。只允许打开当前可用且未脱敏的已授权 Manual Workspace；目录缺失、身份变化或系统打开失败须明确反馈，不自动重试。
- 后台创建 Automatic Workspace 不修改 Manual Workspace recent order 或 Renderer New task draft scope；manual 与 automatic record 使用独立容量，后台 Task 不得耗尽用户打开 Workspace 的能力；
- automatic root 配置缺失时初始化为 system default；读取失败、损坏或未知 schema、配置提交结果不确定、以及已保存路径不可用时必须保留原事实并 fail closed，不得静默回退到 system default。这些故障只关闭 `automaticWorkspaces` capability 并对 automatic admission 返回 typed unavailable；Account、显式 Manual Workspace 和普通 Workbench 仍可运行；
- bounded Task/Workspace 产品历史跨 Host 重启恢复，但恢复后的 Task 只读且不得伪造 Agent Session 或 Conversation；Run、Task 删除、shutdown 和重启后 Automatic Workspace 目录保留，但不扫描目录恢复或猜测 Task/Workspace，目录浏览和磁盘清理属于后续独立能力；
- Task/Workspace 历史持久化是交互式主流程的 best-effort projection：历史读取、解码或写入失败时保留原文件与诊断，当前进程仍允许 Workspace 选择、新建 Task、Run、权限响应、取消与后续 mutation；读取或解码失败后本进程不覆盖不可信 store，明确写失败或结果不确定则在后续完整 snapshot 时重新尝试保存。Host 必须为非健康 store 发布 Product-owned 显式恢复动作；用户确认后，Application 只把当前 canonical 文件改名保留为 recovery copy，并原子写入 Product 编码的当前内存 snapshot，不读取、迁移或删除旧格式。只有 Task 物理删除和 Scheduled occurrence 等明确要求 durable-before-release/effect 的局部事务可以因本次提交失败而拒绝，拒绝不得冻结其他 Product Task 或整个 Workbench。历史 writer 暂忙时，已受理的 Task 删除等待可写后继续，确认后释放资源；
- 文件和工具能力最终必须受 Workspace 与显式权限约束；
- UI 能显示当前 Task 所属 Workspace；
- strict Workspace security 未验证前，产品必须明确限制使用范围，不能制造虚假的安全承诺。

### 5.2 账号、Provider、模型与执行配置

新 Task 必须提交完整 `ModelRef + expected source generation + expected catalog generation`；Host 精确解析目标来源、当前 protocol、endpoint 与 credential，建立 Task-owned execution binding。起始偏好不授予执行资格，不存在进程级 active default execution 或空选模创建路径。已有 Task 与 Run 保留自身 generation 和历史事实。

New task Composer 汇总 Metask 与所有 Custom Provider 的 ready 模型，以完整来源与 model id 区分候选。无草稿选择时显示 Host 保存的起始偏好；无偏好时要求明确选择，不自动采用目录首项。偏好或草稿选择失效时保留模型名称与草稿，允许选择其他合法候选，仅阻止无效发送，不回退其他模型。所有创建均提交显式完整目标；创建成功后保存 Task 模型意图。

- 普通用户通过 Metask OAuth 登录，不需要手工填写 protocol、model、base URL 或 API Key；
- Metask 模型用途与当前模型设置、Composer 的展示资格只由 `capabilities.endpoints` 判定：`messages`、`responses` 或 `chat_completions` 至少一个明确 `supported = true`，且 `images_generations`、`videos` 均未声明支持，才属于当前可选对话目录；同时支持对话和媒体生成端点的混合模型也排除。端点缺失、null 或 false 按不支持处理；全局及端点内部的 input/output、其他能力字段和模型名称不作为第二套用途判定。协议优先级由 [Models source 合同](product-architecture.md#21-models-aggregate-与-account-handoff)拥有。图片等输入能力不影响展示资格，Host 对设置选择与新的执行解析使用同一合格目录。
- Metask managed Provider 使用 OAuth access token 直接访问固定的 `/v1/models` 与 [Models 按明确端点声明选择的执行 endpoint](product-architecture.md#21-models-aggregate-与-account-handoff)，没有可用对话端点声明的成员不作为执行候选，不存在第二次 API Key 选择或配置；用户管理的 Custom Provider 不要求 Metask 登录，但必须先显式创建、配置并通过模型测试，实际执行时由 Host 解析为 Task-owned 配置；
- `AccountView` 只发布 `state`、`canCancel`、经过验证的 `accountId`、best-effort `displayName`、由 Account Host 生成的可选登录邮箱/手机号脱敏提示、nullable非负整数并发额度（`null` 表示资料不可用，`0` 表示不限）、Account-owned稳定错误和无 secret 的 Metask账户摘要；资料字段缺失或异常不得阻止登录，完整邮箱和手机号不得越过 Bridge。当前摘要发布按 `Asia/Shanghai` 日历日对齐的最近 53 个周列的每日 Token历史及已记录费用、同步时间和安全错误；既有 nullable wallet/usage 投影保持 unavailable且不在界面伪造余额、今日或累计值。摘要不得包含 catalog、model、selection、source、execution、Task admission、Custom Provider、API Key、请求/RPM/TPM/响应时间、标准费用、订阅额度或模型分布。`ModelsView` 独立发布 Metask/custom source 目录、起始偏好、Models revisions、persistence health 与脱敏 Custom Provider；`NewTaskAdmissionView` 只发布通用创建资格。精确 wire 以 [Bridge 合同](renderer-bridge-contract.md)为准。三者不得互相伪装；
- Account 的 `checking | signed_out | authorizing | authenticated` 状态都不得替换 Workbench；登录、等待和取消动作通过 Workbench 账号入口、Account 设置及新任务的模型准备引导表达；引导复用同一 Account 命令。可信根 Snapshot 建立前 Workbench 保持不可操作，确认根连接失败后才切换到独立连接恢复表面；已有 live Task 始终可查看和停止；
- 新任务首次缺少模型服务时提供可跳过的开始引导，用户可以登录 Metask 或在运行时能力允许时配置自己的模型服务；可用自定义模型不依赖 Metask 登录。引导只负责用户主动选择入口，不自动登录、配置或发送。跳过后保留草稿，并在输入区按 Host 事实说明模型阻塞原因及可用恢复动作；检查、加载、已有配置失效和存储恢复不得被笼统解释为首次配置。展示、跳过和返回规则由 [UI 设计规范](ui-design.md#141-首次启动) 定义。
- 登录无效即进入 `signed_out`。Renderer 对建立 identity 只提供统一的 `beginLogin`，每次都开始新的 OAuth，不保留“重新认证”“重新打开登录页”“匹配上次账号”或重用 retained refresh token 的分支；retained refresh 只供一次冷启动 restore。已验证会话出现 `refresh_schedule_failed` 时提供独立的 `retryRefresh`，它只恢复 Host refresh 调度，不建立第二条登录路径；
- authenticated时，账户信息提供唯一“充值”动作，但不显示当前 OAuth 合同无法取得的余额。Renderer 只发送空 payload 的 typed command；Account Host 只在执行时构造并通过系统浏览器打开固定 Metask充值页，不接受 Renderer 提交 URL、token、account id或query，且该动作不改变 Account/Product状态；
- OAuth 浏览器授权、identity 提交和执行目录准备不得暴露内部 C1/C2、operation、generation 或凭据存储步骤；
- OAuth 成功提交 token rotation 并以 Userinfo 验证 authenticated identity 后，Application 必须把一份有界、可清零、绑定 authorization generation 的 lease交给独立 Models catalog continuation。仍有效的 Models-owned历史选择优先恢复；没有历史选择时按 Models 合同选择默认项；只有真实歧义才请求用户选择；
- Models continuation 失败不能把已验证 Account identity回滚成未登录，也不能根据显示名称、列表顺序或模型名猜测 source identity、protocol 或 target；
- 没有可用模型时必须保持已登录状态，说明目录不可用并提供 `重试`；只有 Host 拥有固定、安全的 Metask 管理入口时才显示 `在 Metask 中管理`，Renderer 不拼接外部 URL；
- 登录是 Account-owned操作；目录加载、模型选择和模型持久化是 Models-owned操作。Renderer 只渲染 Host 发布的状态和脱敏候选，不通过 `useEffect`、隐藏点击或本地定时器推进产品状态；
- 账号入口固定显示在左栏底部：已登录时按 `displayName → emailHint → phoneHint → 中性已登录文案` 的顺序显示身份；脱敏提示只用于呈现，不参与登录资格判断；未登录时显示登录动作。其轻量菜单同时提供产品级设置与“关于 MetaWork”入口；About 显示静态产品名、Metask 开发者归属和随应用构建注入的 canonical 产品版本，这些静态元信息不属于 Account、Models 或 Bridge projection，版本检查结果独立由 Product 投影；在未登录与连接异常时仍可打开。接口不可用、Userinfo client 不匹配或响应不可信时不得从 token payload 推断 principal，也不得回退旧 identity；不得由 Renderer 推断，也不得在普通 catalog refresh 或后台定时路径主动更新；
- Account authenticated 后，Application 使用同一 generation-bound authorization lease 直接启动独立、单飞、有界的 history 同步；新的 OAuth gateway token 不得发送给旧 `/api/v1/auth/me` 或 `/api/v1/usage/dashboard/*`。history 从 `GET https://www.metask-ai.com/v1/usage/stats` 读取以周一为起点、截至上海当天的最近 53 个周列（365–371 个日历日）的稀疏日桶，并固定提交 `scope=user`、`granularity=day`、包含边界 `since` 与不包含边界 `before`；上海日历日边界由 Host 换算为 UTC。登录 identity 只以新 OAuth Userinfo 的非空 `sub`、精确 `client_id = metawork` 与非空 `authorization_id` 作为门槛，并把 `sub` 绑定到 token；`name/email/phone_number` 缺失或异常不得阻止登录。已经 authenticated 后，history 字段缺失、格式错误或请求失败不得回滚登录，已有值在失败时保留为 stale。history 严格校验响应声明的 `scope=user`、`granularity=day`、`timezone=Asia/Shanghai`、查询边界、日桶顺序、Token恒等式及桶合计；`cost_mu` 固定按毫 U 换算为 U。当前已发布响应不以 `unit` 或 `cost_complete` 为必需字段，因此每日金额只呈现为“已记录费用”，不得声称区间费用完整。只有整段响应成功且严格验证后，范围内缺失日期才解释为零使用；失败不得把缺失值补零。不得轮询或自动重试；
- 用户自行添加的模型统一在 `Models / 模型` 设置管理，不提供平级的 `Providers` 页面，也不要求先创建 Provider。该页只负责用户添加模型的配置管理、测试和删除，不展示 Metask 官方模型目录、目录同步或默认模型设置；任务使用的模型在输入区选择。底层 source-qualified selection 与执行资格仍归 Models 与 Product Control 管理。Metask credential authority 由已登录 OAuth 会话隐式提供；用户管理来源的 credential 由 Host 安全持有，通过添加或编辑模型时的连接设置创建、替换，已保存 secret 不显示或回填。管理模型或连接不得隐式修改 起始偏好。Host 只在 management、API Key 直接写入系统 credential storage 与真实模型测试同时可用时开放自定义模型管理，任一能力缺失都隐藏该分组，配置恢复仍可访问。开放判断只依据当次运行时 capability，不按平台名建立静态 allowlist；
- 普通 Task 通过固定 `GenerateImage` Host Tool 执行图片生成，不要求用户先选择生图模型，也不在 Models 设置提供生图选择。对话选择器只显示对话模型。Host 按 [Product 架构](product-architecture.md#21-models-aggregate-与-account-handoff)优先使用默认生图模型，不可用时在发送前采用当前 Metask 目录中第一个明确合格的图片模型；没有候选时图片能力不可用，文本仍可执行。每个 Run 冻结实际模型与授权；请求发出后的失败或取消不自动换模型重试。当前内部测试已启用，发布前仍须完成真实服务和工具集合迁移验收，恢复缺口以[验证规范](validation.md#generateimage-工具集合迁移的恢复缺口)为准。可能收费的事实通过工具说明和既有审批路径呈现，按内容签名识别并原样保存 PNG、JPEG 或静态 WebP，文件扩展名与返回 MIME 必须匹配实际格式；
- 普通交互 Task 可以通过 `GenerateVideo` 用文本生成一段短 MP4，Host 从当前 Metask 目录选择合格模型。生成经过既有工具权限机制，成片保存到当前 Workspace，`DeliverFile` 登记后从所属 Run 的 `Outputs` 取用。已提交的远端任务可能在本地停止后继续并计费，客户端报告已知结果且不自动重新提交。真实 Metask 服务验收以[验证规范](validation.md#generatevideo-验证)为准；
- 用户管理的对象是自行添加的模型；服务地址、protocol 与 API Key 是模型的配置，不提供独立 Provider 的创建、命名、选择或复用入口。每次添加都独立保存模型配置与凭据，不按厂商或 endpoint 合并。同一厂商、同一地址可以承载多份独立模型配置，编辑或删除其中一份不影响其他份。模型仍以稳定 `source_id + model_id` 标识，携带 nullable capability/token metadata、明确 provenance、当前 source generation 的 readiness proof 和 `untested | testing | connected | failed` 最新测试状态。unknown 不得伪装为 unsupported/verified，display name 永远不是 identity。protocol 精确取 `openai_responses | openai_chat_completions | anthropic_messages | gemini_native`。内置厂商预设只提供官方地址、固定 protocol、官方模型 ID 建议、API Key 获取地址和文档；不代表实时目录、账号授权或 readiness。图标按可信来源与内置厂商身份呈现，不根据模型名或地址猜测。内置厂商表单不展示或编辑地址与 protocol，需要其他地址或协议时使用自定义服务。已保存地址不因界面变化静默改写；readiness 与 latest test status 分开，同一 source generation 已验证模型的失败重测不能撤销其 readiness 或已有 execution；
- 用户管理 Provider 的 API credential 由用户在本地桌面 Models 页的模型添加或编辑表单中直接填写；Renderer 只能在 create/replace 操作的临时 password state 中持有完整值，并通过专用 typed Bridge command 一次性提交。Bridge 严格校验后立即转交 Models，Models 写入系统安全存储；metadata 以独立、无 secret 的 registry 原子持久化。提交成功、取消、离页或 revision 变化后不得把秘密保留为可恢复 UI 状态；失败后清除临时 API Key，非 secret 字段可留在当前表单供用户修正重试。任何路径都不能提交 Authorization header 或把 arbitrary URL/credential 直接注入 Run；
- 模型测试通过 Agent-owned Completion 发起一次有界的非流式请求，复用当前设置选择冻结的 ExecutionConfig，并由 MetaWork 的 Anthropic/OpenAI/Gemini 无 Tool codec 解析最终 JSON 响应；它不调用 AgentCore Completion，也不创建产品 Task、Run history 或持久 Conversation。第一版由用户明确提交 bounded model id，Host 保存其模型 metadata；自动模型发现不在当前范围；
- 当前模型必须显示在 New task Composer 附近；Composer 模型选择器和菜单项显示模型图标与名称；设置页管理自定义模型，任务信息中的来源与实际执行事实按 Task 合同呈现。任务信息显示任务已选 Provider，并按本轮或最近一轮 Run 记录展示实际模型与协议，不能将当前选择推断为历史执行来源。起始偏好只影响后续新 Task；已有 Task 显示当前 binding epoch 的 protocol、opaque execution generation 和模型，历史按 epoch 保留原事实。下一轮的目标解析、执行绑定与恢复遵守 [Product 合同](product-architecture.md#22-workspace-与-task-admission)，不能将意图保存显示为当前 Run 已切换；
- New task Composer 列出所有可执行来源的 ready 模型，Metask 在上，自定义模型在独立分组。模型菜单可操作性取决于合法候选及选模事务状态，不取决于当前选择是否有效；发送资格由 Host 对明确目标及其余执行条件独立校验。没有候选时提供对应授权、目录重试或配置恢复入口。
- 进入设置只读取 Host 已提交的 `account` 与 `models` projection，不触发隐藏 mutation；账户用量刷新和 Metask 官方目录的恢复分别归各自 owner，官方目录及重试不进入模型设置页。Models 页以自定义模型列表和“添加模型”为入口，不展示未配置厂商目录。添加弹窗的厂商选择器只列内置厂商预设与自定义服务：预设提供 Base URL、固定 protocol 与官方模型列表，用户填写 API Key 并选择模型；自定义服务填写完整请求 endpoint、API Key 与 bounded model ID，按标准 endpoint 路径自动识别 protocol；无效地址给出字段错误并阻止提交；有效服务根地址须明确确认为 Gemini Native，由应用生成模型路径；添加表单始终填写当前模型的 API Key，不列出或复用已有 Provider、地址或凭据。新来源与首个模型通过同一 create command 在同一最终 metadata candidate 中保存，全部输入在 credential effect 前校验；保存后保持未测试，不自动设为默认。列表提供逐模型测试、编辑和带确认的删除。内置厂商编辑只提供模型与 API Key，新添加模型的 API Key 独立保存；既有多模型配置编辑仍明确其共同影响；自定义服务允许编辑完整地址并按相同规则识别接口。编辑使用一个保存入口，依次提交有变化的地址、非空 API Key 与模型 ID，每步读取最新 canonical 状态后继续；明确失败披露已保存字段，结果未知停止并要求用户重新核对，不自动重放；地址、protocol 或 credential authority 变化沿用 Models generation/readiness 失效语义。列表只显示模型名称与测试状态，不显示 Provider 名称；删除最后一个模型时同时移除其连接配置，并通过持久凭据清理队列删除 API Key，不留下可供复用的空 Provider；
- Metask 来源 authority 只表达 principal、当前授权、source generation 与目录，不承担 Provider-local 模型选择。目录同步不创建或改写起始偏好，不选目录第一项；合法空目录保持登录并仅关闭该来源的模型执行资格。Models 按 [Product 持久化合同](product-architecture.md#21-models-aggregate-与-account-handoff)保存唯一 nullable `defaultSelection` 与 `selectionRevision`，语义为新任务起始偏好，没有执行消费者。Host 仅在交互 Task 创建成功或用户主动选模 confirmed commit 后独立 best-effort 记忆，偏好保存失败不反转 Task 成功；自动 occurrence、浏览历史与目录刷新不更新偏好。
- OAuth access token 同时授权 Metask 账号 API、模型目录与模型调用；Models 只在有界进程内 credential 生命周期中持有执行所需副本，不持久化 token；
- 除用户正在填写且尚未提交的 Custom Provider API Key 外，Renderer 只能看到脱敏账号、模型、稳定错误码和状态，不得接触 OAuth token、已保存的完整 API Key、Authorization header、临时 OAuth URL 或凭据存储 locator；
- Product Control 按明确模型目标建立 Task-owned ExecutionConfig；live Session、Run、job 或 worker 保留必要的有界 owned copy。起始偏好不持有配置，偏好变化不得篡改或停止既有运行；最后一个真实运行时引用释放后必须 secure-zero；
- durable Task 和 Run 不保存 account id、OAuth token、完整 custom credential、credential locator 或 Custom Provider identity。恢复记录只保存 Workspace binding、protocol、model、opaque execution generation 和其他无 secret binding facts；运行时配置不可恢复时必须显式进入 `runtime_detached`/恢复路径，不得伪造 Session、secret 或可继续执行能力；
- 显式重新登录、切换账号、退出登录或清除设备凭据只按 Account 自身 identity/credential transaction 收口，不得等待 Models、Product replacement、Schedule scrub、Task、Session、Run、executor job 或 worker reference。既有 Task/Session 已拥有的 ExecutionConfig继续按原生命周期收口；成功退出只清除 Account-owned credential并发布 `signed_out`。Application随后使 Models的 Metask provider进入 `needs_authentication`，清除 transient目录/credential但保留无 secret 起始偏好；只拒绝依赖该授权的新解析和执行，不全局关闭 custom 来源或已有 owned binding；任何失败都不回滚 logout；
- refresh token成功轮换后必须先原子提交新 token，后续 Models catalog失败不得回滚到已作废的旧 token；Account 只在 authenticated、principal匹配、generation有效且 access token 未到 hard expiry 时签发授权 lease，refresh skew 内的正常在飞目录操作保持有效；clock/timer arm失败必须发布可重试的 Account错误，hard expiry 后 fail closed。明确鉴权无效使 Metask provider无法产生新的解析，但已被 live Run拥有的配置按其生命周期正常收口。同一连续登录内 token 刷新后，已有 Metask 会话下一轮须使用有效的新凭据，保留模型和对话上下文，不要求用户新建会话或切换模型；准备失败时明确阻止发送，不重放工具。过期、退出或重新登录后，旧会话不能自动沿用失效凭据或借用另一次登录的授权；
- New Task尚未形成自身 aggregate，其 admission由 Product Control按明确提交的模型目标、来源与目录 generation、当前授权、Workspace authority和生命周期决定。起始偏好不授予执行资格，也不参与全局准入；Account只提供授权 lease，不能直接允许或阻塞 Product Task；
- production Account接入、内部状态、OAuth/identity transaction和提交必须符合 [Account 架构](account-architecture.md)。Metask OAuth-authorized model catalog、固定 protocol/endpoint、模型 metadata与选择属于 Models provider。Account C1先提交 token rotation，再以严格 Userinfo 交付 authenticated identity；Application用独立 authorization lease启动 Models continuation。Models 来源与目录提交不等待 Product/Schedule；Product按显式目标完成解析、credential scrub 与 Task-owned 安装前不得接纳相应执行，但不能隐藏 durable history。既有 live Task的后续 Run只服从自身 binding、ExecutionConfig、Session与 active-operation gate。

### 5.3 Task

- 加号选取与拖拽是同一文件添加能力的不同输入方式，共用整批接纳、类型识别、顺序、配额、取消与草稿结果；具体来源的路径身份或 DOM 字节读取失败仍如实区分。用户只看到正在添加和正在取消，不根据来源开放不同文件能力。
- Host 为每个 Task 发布模型选择可用状态，精确区分可用、目录加载、目录不可用、执行替换中、运行时分离、不支持的来源和 authority 已变化；Renderer 只按该状态显示可编辑菜单、暂时禁用菜单或带原因的只读模型，不跨根 projection 猜测权限。
- New task 草稿始终属于 Workbench，但只有 Product Control 发布 ready execution admission 后才能发送；Renderer 按 Workspace intent 隔离并可恢复。默认 Workspace intent 为 Automatic，界面显示“默认”，首次发送时才由 Host 创建 Automatic Workspace。用户可以在发送前切换到已授权或新选择的 Manual Workspace；
- New task 首次发送复用一个真实 Task 创建请求；创建期间可以继续编辑和发送，有界保留明确点击的提交。取得 Task identity 后按点击顺序交付，不等待上条发送回执。创建失败或未知逐条展示，不自动创建或补发；Task 已创建则保留对象，执行失败不伪造未接收或 Running；
- 用户可以在 Workspace 中创建、切换、继续、归档和删除 Task；不存在独立的 Task `closed` 产品终态；
- 多个 Task 可以同时存在；
- 后台 Task 的运行状态不能因 UI 切换而丢失；
- 每条事件、审批和工具结果必须路由到正确 Task/Run；
- 每个 Task 在创建时记录无 secret 的 generation、protocol 与模型历史事实；不得固化 Account identity 或 API Key 元数据。全局默认变化不改写 Task 历史或 live Agent Session；
- 没有用户标题的 Task 在首个 Run admission 时立即使用旧的本地有界摘要作为临时标题，避免模型返回前退化为 identity 占位；Run 收口后再使用该 Task 已固定的同一 ExecutionConfig 通过独立 Completion 生成一个不超过 32 个 Unicode 字符的标题并替换临时值。该请求不创建 Session、Run history 或 Conversation，也不改变 Run outcome；失败、超时、拒绝或非法结果保留临时标题。用户在生成完成前后设置的标题都具有优先权，后台结果不得覆盖；
- 每个 Task 至多一个 active operation：当前可以是 non-terminal Run、manual compact 或 Conversation restore，包括 executor 中的 `queued` 状态；Run、compact 与 restore 互斥，当前 operation 结束前 Workbench 拒绝新的 Run、compact、restore 和其他 Session mutation。Task 独占有界待处理消息，支持文本、Skill 与完成 staging 的附件，不占 active-operation 槽，不在接收时创建 Run。有效发送不因内部启动、停止或收尾被阻塞；Task 决定就绪插话、等待或下一 Run。Stop 只取消当时已有消息与当前 operation，之后的新输入保留。原文不持久化，重启后的未执行安全记录只显示中断；
- Renderer 产品合同为 `metawork.renderer-bridge` 固定 revision 1，严格协商后开放产品路径；Models 投影来源目录、起始偏好、generation/revision 与持久化健康，`newTaskAdmission` 只投影通用创建资格，不含 active execution。`tasks.create` 必须提交 Workspace intent、非空显式 `modelSelection` 及各 owner 的 expected generation/epoch。快速开发阶段原地 hard cut，不接受、转换或双写被替代 payload。
- 预期的 Task/Workspace admission 拒绝必须作为严格 typed result 返回并由 Renderer 映射为产品文案；非法 payload、伪造 ownership 与不可信 origin 仍 fail closed 为 Bridge error，不得把内部 error name 显示给用户；
- 当前固定 revision 1 合同原子提供独立 Workspace projection 与 Task execution binding。一次性目录能力必须由选择命令在 Host 内创建并消费；用户在 Host 原生目录选择器中确认目录即完成 Manual Workspace 授权，不再追加重复的 trust 确认。Renderer 不接收路径授权 token，不从 Task 反推 Workspace，也不能通过可选字段继续发送被取代的临时 payload；
- 普通文本及多模态输入的用户文字按 Product Control `Limits.max_user_message_bytes` 执行 UTF-8 字节发送上限。输入框不得静默截断；超限时保留完整可编辑草稿、明确提示并禁用发送。草稿保存预算独立于发送预算，支持超限草稿在有界容量内恢复；Skill 输入继续遵守独立的参数与总字节合同。
- Composer 可以通过系统多选文件选择器或操作系统文件拖放添加普通非空文件，也可以在普通文本输入框内主动粘贴剪贴板交付的图片 File；三种入口必须形成相同的 connection/window-bound 一次性 staged authority，并共同服从每条用户消息最多 8 个附件、单文件和共享总暂存容量上限。多次添加按当前草稿累计，超量整批拒绝新批次并保留原草稿；下一条消息重新计算数量名额。其他草稿和待执行原件仍共享有限资源，数量名额独立不承诺资源隔离。拖放依据 Host 公布的接收模式，使用 Native SDK 路径事件或 DOM File 的有界字节输入，经专用 typed Bridge command 提交；Renderer 不得持久化路径、文件句柄、raw bytes、Base64 或 digest；
- 经内容签名识别且可解码的 PNG、JPEG 与 WebP 图片，以及其他非空普通文件可以进入 Run。所有已支持类型共用 Product Control `Limits.max_attachment_file_bytes` 单文件上限；数量和暂存总配额分别由 `max_attachments_per_draft`、`max_staged_attachment_bytes` 定义，默认总配额由数量与单文件上限相乘得到，不额外降低单条消息的附件总量。图片允许独立发送；草稿含非图片文件时必须同时提供去除首尾空白后非空的用户指令。文件扩展名不参与可信分类，仅保留有界安全后缀供工具使用；MetaWork 不在接收阶段解析或执行文件内容。非图片原件作为 Task 本地文件供 Agent 按格式选择可用 Skill 和工具处理，文本可使用既有 Read/Grep 按需读取；图片原件完整保留，并为本次模型输入生成有界 PNG 预览。空文件、不可解码的已识别图片和超限文件在整批 staging 时拒绝；其他文件不要求 UTF-8 或无 NUL。URL、调用方 file ID、正文内图文交错、Skill 与附件混合、Scheduled Task 附件、非图片文件粘贴、接收阶段的文档解析/预览/OCR 和历史下载/重新发送不属于该能力；
- Office 是 MetaWork 的正式文档处理能力，产品目标是可用、好用。Windows 与 macOS 通过内置 DOCX、XLSX、PPTX Skill 提供读取、新建、针对性修改与交付检查；在明确支持范围内，产出内容必须正确，指定格式必须符合用户要求，核验结论必须与实际检查结果一致。环境准备、文档处理、检查、交付与继续修改应形成连贯流程，正常使用不要求用户掌握内部资源路径或自行编写处理脚本；失败须说明具体原因及可采取的后续操作。Skill 可发现不表示环境就绪；缺依赖不阻止普通 Task 或附件接收。复杂版式完整保真、旧二进制格式、宏执行与加密文档不在当前支持范围内。不提供公式重算、接受修订、渲染、缩略图、PDF 导出或产品内文档预览；可以设置 XLSX 打开时重算，但不得声称已计算或保证查看器重算。原件保持不变，编辑采用工作副本，未执行的检查不得报告为通过，未完成结果不得交付为成功；
- Office 按 Windows x64/ARM64 与 macOS arm64/x64 选择固定私有 Python、Node 和目标文档库；平台验收与未闭合项见[验证规范](validation.md#office-skill-与私有环境验证)。多个 Task 共用独立的用户级 Office 依赖根，不修改全局环境或用户工作区。macOS 首次准备 Node 前须显式准备固定私有 Python，已就绪的 Node 执行与复用不依赖 Python；Windows 两种语言保持独立准备。模型判断需求并先在对话中取得用户同意，再经既有 Shell 调用固定准备脚本；不新增安装卡片或强制审批 Gate，full_access 下没有额外产品拦截。主包不携带解释器和文档库，普通启动不下载。环境不原地升级、不自动修复、切换或回收；损坏时明确不可用，并提供精确目录的人工恢复指引；须先确认所有使用者已停止，再由用户明确选择清理和重新准备，不自动修改损坏目录。准备、执行和失败处理边界见 [Product Skill 合同](product-architecture.md#内置-office-skill)；
- 普通 ZIP 由 Agent 根据用户任务经既有 Bash 调用 MetaWork 提供的归档 helper，先查看目录，再按需解压，不作为独立 Skill 或专用 Tool。ZIP 只需要 Python 标准库，不要求 Office 依赖；解释器未预先配置不阻止附件接收或提供 helper 入口，依赖检查、调用与失败解释由 Agent 通过现有工具完成，不新增环境状态或专门弹窗。缺失依赖或拒绝的归档依据实际工具结果如实反馈，不在文件处理中全局安装依赖或提升权限。原件保持不变，编辑采用工作副本；未完成的解压输出不得被报告为成功或复用。执行方法与 helper 的局部检查、失败清理和权限边界见 [Product 附件合同](product-architecture.md#26-文件-attachment-staging)。
- 用户可见 Run 的附件输入历史只保存经过 credential redaction 的附件原名称、类型、原图片格式、原大小和顺序，不自动保存正文、原件路径或发送预览；Agent 按需读取产生的 Tool 记录继续遵守既有有界投影与脱敏合同。Product 拥有 Task 本地原件存储，未发送的候选随取消、移除、断连和关闭清理；普通 Composer 的附件随消息被 Task 接收后移交，等待期间继续占用共享资源；未执行消息取消后清理其原件。进入 Run 的原件保留至 Task 删除，以便应用重启和 Conversation 恢复后继续读取。接收前拒绝不消费附件 grant；接收后不因执行失败恢复已消费的附件。AgentCore Conversation 与 opaque checkpoint 继续独占模型侧输入历史，不得由 Product 解析 checkpoint 来推断附件内容或清理原件。历史 chip 不据此开放下载或重新发送；
- 产品 Task identity 由 Workbench 独立、稳定地分配；内部 Agent/Gate 原始事件使用单独的 Session route identity 做路由，两者不得复用或假定数值相等。Session route identity 不进入产品 snapshot，Renderer 始终只看到唯一的产品 `taskId`。
- credential 不得因 owner 释放而重新出现在任何 Renderer projection。Host 在安装新 credential 以及 secure-zero 旧默认或 Task-owned credential 之前，必须永久清洗既有 Workspace、Task、Run、tool 和 UI history 投影；同时存在前缀重叠 credential 时按最长匹配脱敏。

### 5.4 Agent 交互

- 每次普通文本或多模态 Run 开始执行时，由 AgentCore 官方日期上下文为模型提供本轮开始时的系统本地日历日期与时区信息，用于解释“今天”“近期”等时间参照，不提供具体钟点。排队、跨日、系统时区变化和 Conversation 恢复后的新 Run 按 Core 官方语义重新采样；同一本地日期且时区信息不变时，上下文正文不随时分秒变化。本地时区不可用时 Core 使用 UTC 日期并说明时区未知。用户明确指定的时区或参考日期仍有效，历史日期只描述旧 Run；该日期不能替代最新事实查询，知识截止日期不得作为当前日期参照。MetaWork 不改变用户输入、产品历史与复制内容，也不建立自有时钟或日期 fallback；当前 Core 的异常时钟行为与验证限制以[验证规范](validation.md)登记为准。

- 用户可以提交普通文本，或由图片与其他文件附件组成的多模态输入并启动真实 Agent Run；大文本文件经本地引用按需读取，不等于文档解析能力。模型目录中的 `imageInput` 只提供图片发送前提示，不能替代 Product admission 或 AgentCore typed capability 判断，也不能授权 Renderer 丢弃媒体、切换模型或降级成文本。目录仍可保留上游 `pdfInput` 元数据，但 MetaWork 不据此发送 Provider 原生 PDF part；PDF 文件仍按通用文件引用处理；
- AgentCore → Host → Bridge 持续投影 Agent 可见输出，并把 commentary、final/partial response 与 provisional 区分为稳定过程说明、安全正文和可回滚临时文本；Renderer 必须在正式 terminal fact 前随真实 Snapshot revision 持续更新 Run 的工作过程，不能把已到达的过程事实藏到终态后一次性展示；
- `thinking_chunk` 正文不进入可见 output、Snapshot、持久历史或搜索；其事件类型只把当前安全状态细化为“正在思考”，`text_chunk` 到达后状态切换为“正在撰写回复”；
- macOS AgentCore 的 visible-output segment 由 `output_segment_begin/end` 权威定性：`commentary` 是可见过程说明，`continued` 与同 group 后续段合并，`final` 是完成答案，`partial` 是可见但未完成输出，`discarded` 必须回滚。Product Task 只把已闭合的可见组提交到 durable visible-output history，并以有界累计边界精确保留每个非空 commentary group，同时持久化 final/partial 分类及安全正文起点；Bridge revision 1 将其派生为有序 commentary array 与 response，而不是把全部过程压平成一个 Markdown body，同时只把 open/continued 中 credential-safe committed bytes 作为可回滚 provisional。open、continued 和 discarded 不形成 durable record，Renderer 也不得从 Tool、`stream_done` 或 StopReason 猜测这些语义；
- 主阅读流把 commentary 与 provisional 作为所属 Run 的 Assistant 过程叙事持续呈现，并在其下方只保留一个随 canonical activity 原位更新的 live status；Tool 记录是次要技术证据，默认折叠，只在用户明确展开后按 Host 顺序显示。每条 Tool 摘要固定为单行，包含名称、至多一项 Host 安全摘要、状态与真实耗时；摘要优先使用 description 或 progress，缺失时可以用结构化 fileRefs 的 displayPath 作为只读文字兜底，空间不足时省略而不换行。Tool input、progress 与 result 只在用户选择具体 Tool 后于所属行下方展开；
- UI 以唯一 Current activity 展示 thinking、writing、tool、retry、context compact 与 finalizing，不展示 Run token usage 表；Composer 仅在当前 Conversation 存在 Host pressure 观测时显示上下文提醒，不因最近 auto compact 历史单独占位，底层统计与压缩记录不因此删除；
- Agent 对话按 Run exchange 组织为用户输入及其元信息、按插话位置分隔的连续 Assistant output、运行中的唯一 live status 与按需技术过程、待处理请求、文件更改、必要 terminal notice 和末行回复元信息，不存在的部分不占位。每个 closed commentary group 与尾部 provisional/final/partial 都使用按稳定 output ordinal 排列的安全 Markdown part，相邻且未被用户消息分隔的 part 连续呈现，组间只以克制留白分隔，不做卡片、事件时间戳或 Tool 标签；provisional 从首批安全字节起即可呈现 Markdown，但在被 AgentCore 定性前必须禁止链接、文件预览、图片加载和复制等交互，discard 后立即消失。分类变化不得把同一 output part 搬到另一阅读块或替换其 DOM 根。active status 始终位于本轮正文阅读流底部并原位更新，不因 Tool 事件追加新的主阅读行。active Run 的技术过程与 live status 共用默认折叠的 process surface；Run terminal 后 live status 消失，没有 Tool 时 process surface 同步卸载，存在 Tool 时保留默认折叠的历史操作摘要，并允许在所属行原位展开 Tool 详情。根用户输入元信息只允许复制动作与 Product 持久化的 Run 提交时间，回复末行只允许回复动作与 Product 持久化的 Run 完成时间；两者不得据此伪造 typed facts 之间不存在的严格时间线。具体 owner、槽位和迁移机制由 [UI 设计规范](ui-design.md#72-agent-对话渲染机制)定义；
- 已闭合 commentary、final/partial response 与安全 Markdown 文件预览中的 HTTP(S) 链接，以及对话中的 `mailto` 链接，只在用户显式点击后经 Host 交给系统默认 handler；WebView 不直接导航，Renderer 不用 `window.open` 或普通 anchor fallback。非法目标、Host/Bridge 不可用或系统打开失败必须在对应链接旁显示明确失败，不能静默无响应、自动重试或扩大协议范围；provisional 链接继续保持惰性文字；
- 用户可以一键复制任一 Product 已接纳的 Run 输入。普通文本保持 Host 投影的原文；Skill 输入复制为可读的 `/调用名 参数…`；多模态输入复制已投影文本与附件显示名，不读取附件内容、内部 locator 或本地路径。复制必须直接使用 typed input，而不是从 DOM 反向提取；旧历史即使没有提交时间也继续可复制；
- 用户可以一键复制任一已 terminal 且非空的 final/partial response。纯文本剪贴板内容必须是 Host 已投影的原始 Markdown，不能 trim、拼接或从 DOM 反向提取；富文本内容必须由同一 Markdown 经当前安全 GFM 渲染策略生成，不包含 commentary、provisional、思考过程、Tool、状态、耗时、按钮、隐藏文本、内部文件导航或远程图片。支持标准多格式剪贴板时一次写入 `text/html` 与 `text/plain`；明确不支持时只降级为完整 Markdown，权限、容量、转换或写入失败不得截断或显示成功。回复内代码块可独立复制其显示代码正文，不包含 Markdown 围栏、语言名、行号或界面文案；
- Product 在接纳 Run 输入与正式 terminal 收口时分别至多一次记录 wall-clock 提交时间和完成时间，并随 Run 历史持久化；时钟不可用或旧记录缺失时对应事实保持未知，不迁移、不由 Renderer 补写。用户输入在弱化的本地相对提交时间右侧提供复制动作；具有可复制回复的末行仍在复制动作右侧显示相对完成时间。两种时间都提供机器可读绝对值；相对文案自然推进不得发布 Product revision、改写历史或触发主阅读流滚动；
- terminal notice 必须使用 Product 已知的最具体稳定原因并给出匹配的恢复动作；模型服务错误、不可恢复的工具错误与图片输入不支持不得统一展示为泛化故障。`provider_failure` 有结构化模型错误时按 category 本地化，说明无可用回复或只有部分回复；默认折叠的运行详情展示 Host credential 清洗后的服务端 message、code/type、request ID、HTTP status、请求层重试事实及清洗/截断标记。独立 diagnostic 的 absent/withheld 与可见模型错误分别表达。补充观察不覆盖原有终态；历史错误保存后重启仍可查看，操作资格按当前状态判定。登录/支付问题只提供来源匹配的现有设置入口，不改 Account、余额或 Models authority；准备重试只将可恢复指令填回 Composer，不自动重放工具或附件。provider raw body、日志或未经 Host 清洗的文本不得成为展示旁路；
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
- 用户选择的 `ApprovalMode` 为 `manual | auto_review | full_access`，分别呈现为人工审批、自动审批、完全访问。人工与自动审批都使用 `approval_required`，完全访问使用 `full_access`；自动审批不是第三个 AgentCore profile，也不是 Sandbox 或安全保证。首次安装且没有历史设置时默认为自动审批，已保存的默认模式及已有 Task 模式不因升级或重启被覆盖。New task 发送前选择本次模式；交互式 Task 成功创建后，MetaWork 全局记住该模式并随历史持久化，供重启后的新 Task 使用；创建失败或放弃草稿不改变默认值。使用所选模式发送并创建 Task 构成本次授权，不追加确认 modal、独立委托开关或 Settings 权限入口；
- Task 保存当前 effective profile 和审批模式，每个 Run 保留创建时的 profile provenance，审批历史仍归属产生该请求的 Run。已有 interactive Task 可以在同一 Task、Session 和 Conversation 中显式切换三档模式，保留 Workspace、附件与历史；Manual 和 Automatic Workspace 都支持，noninteractive Scheduled occurrence 不开放切换。checkpoint restore 先使用已提交的当前 profile，不能以目标 profile restore、Session shadow 或规则拼装模拟切换；
- Shell 是广泛执行 authority。`unrestricted` 只表示获准 Bash 不经过 AgentCore file sandbox，不等于 root，也不决定是否询问；产品不得以 Bash 前缀、命令字符串分类或 `exact_arguments` Session grant 宣称可靠 effect 边界；
- Task 当前审批模式随 profile 恢复，不因全局默认值或重启改变；已有 Task 的模式切换只影响该 Task，不修改新 Task 默认值。人工切到自动审批时，本次明确选择可以启动当前未回答请求的评审；自动切回人工立即取消旧评审资格并显示当前人工请求，不等待审核器退出，迟到结果不得回答请求或写入审计。涉及完全访问的切换按需停止当前 Run，并等待真实收口后使用官方 Core mode mutation；不重放挂起工具、不自动发送下一条。真正改变 Core mode 会撤销 Session grants，相同模式无副作用；
- 模式切换受理不等于完成，以 Host 确认并发布的当前模式与结果为准。失败保留已确认的产品历史，结果未知期间阻止冲突切换与执行，并提供恢复说明；不能假装已经切换或自动重发意图。归档立即禁止新 Run，删除收口 Session 并永久移除该 Task authority。事务、旧恢复点和未知结果的处理由 [Product 架构](product-architecture.md#22-workspace-与-task-admission) 定义；
- 自动审批适用于交互式 `approval_required` Task 的 builtin、Host 与 MCP permission，统一复用当前 Run 的冻结模型、参数脱敏和独立无 Tool Completion；不因 namespace 或缺少工具描述整类转人工。只接纳当次 request 允许的 `allow_once` 或 `deny_once`，不生成 Session grant、不缓存“安全命令”。技术失败、超时、资源或输入预算不足，以及 `input_changed` 等有效性保护回到人工，不使原请求过期、不自动重试。模型判断不保证真实 effect，主 Agent 与审核器共享模型可能发生相关错误，额外 usage 计入用户账户；
- 自动审批默认允许任务内必要、常规且风险可接受的实施，不要求用户逐条指定命令、路径或工具。明确与任务无关且不属于合理准备、检查或验证的请求，即使无害或只读也拒绝；工作区外路径或未逐条指定命令本身不构成无关。明确越权、凭据探查、私有数据外传和绕过 Gate 等拒绝；不可逆破坏、对外发送和发布、购买、生产变更、持久安全配置变更、下载并执行未知脚本这六类具体效果，在尚需用户补充决定时转人工，已有具体授权不重复询问，不以一般存疑或开放风险兜底扩展人工范围。跨 Run 用户上下文使用 [Product 架构](product-architecture.md) 的有界连续窗口，历史省略本身不转人工，也不补猜不可见授权；窗口外限制可能不可见，须作为评测局限报告；
- 同一 Run 连续第三次有效自动拒绝判定只把当前请求转人工，前两次须已确认提交并交付；第三次不自动回答、不预建历史。用户成功允许或拒绝后清零，下一请求恢复自动，不停止 Run、不改变 Task 模式或全局默认值。自动允许、人工等待、新 Run 和明确模式切换结束原连续序列，无效 / 迟到结果不计数；
- 审批卡的显示时机和自动审批呈现由 [UI 设计规范](ui-design.md#101-permission-request) 定义。有效人工决定与自动结果仍由谁先被 Host 接纳谁生效，后来的结果按过期处理；历史区分用户与审核器，并保存有界脱敏理由。取消、删除、关闭和 shutdown 后的迟到结果不得生效；
- 用户可以响应当前 typed permission；结构化 Agent 问答、计划批准或拒绝只有在对应 built-in/control capability 进入 MetaWork 产品集合并通过验收后才显示；
- 当前 permission 卡只能提交 AgentCore 当次 request 真实发布的 choice。主操作固定为“允许一次”；当 request 提供 Session scope candidate 时，按 candidate scope 将“本会话允许相同参数”或“本会话允许该工具修改此文件”放在同一批准操作的展开选项中；文件作用域只覆盖当前工具对同一文件的后续修改，可包含不同内容，不跨 Write/Edit 工具、不跨文件，目标必须来自 Host typed projection，拒绝保持独立操作。不得为了减少点击而伪造 request 未提供的 Session 或跨 Session 范围；
- Product 必须保留足以解释重复请求的有界诊断事实：Task/Run/request identity、tool identity/binding、canonical arguments digest、policy generation、candidate/rule identity、decision source、Session rule 命中与 restore 结果。它们只能来自 AgentCore typed request/provenance，不得记录原始参数、credential 或可重放 response，也不得用 tool 文本推断 effect；
- Renderer 可以用同一 Task 内的该诊断事实说明“为什么又请求”，但不维护本地 grant cache，不自行决定允许或实现自动审批。相同 digest 不等于可绕过 AgentCore；
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
- 版本提醒不依赖登录：显式启用的分发构建启动后后台检查正式版本，长期运行时周期检查，关于提供手动检查；只在左下角账户行右侧显示独立“有新版”入口。点击后在关于查看版本并显式下载适配当前运行目标的安装包，由系统浏览器承担下载，系统 handler 受理不得呈现为下载完成。缺包、无效链接或临时错误保留明确原因并提供用户点击的官网入口，不自动改变目标、跳官网或中断 Task；不提供应用内下载进度、自动安装/重启、强制更新、忽略版本或持久化检查记录。版本接受、并发及生命周期见[Product 架构](product-architecture.md#28-版本提醒与下载交接)，呈现见[UI 设计规范](ui-design.md#58-左下角账号入口)；
- 为通知与其他系统集成保留明确入口；
- Renderer 只能调用 Host 显式开放的领域命令。

### 5.9 Workbench 界面与任务组织

- Account 未登录只使 Metask provider 无法建立新的目录或解析；是否允许创建和发送新 Task仍只取决于 Product Control 的 ready execution admission。Workbench 持续展示 Workspace、durable Task 与执行历史，并允许查看和停止真实 live Run；
- Workbench 左栏承担稳定 New task、已接通的全局能力入口、全局 Task 列表、项目导航与左下角账号入口；`新建任务`、`技能`、`MCP` 与 `定时任务` 使用同一紧凑一级菜单的相同行高、缩进和 active 语义，不用额外留白或独立大按钮制造虚假层级；只有真实接通的 capability 才显示对应入口。全局列表保留所有可见 Task，用户选择目录的 Task 另外在所属项目下展示，两处入口指向同一 Task；默认目录的 Task 只出现在全局列表。项目直接使用 canonical Manual Workspace identity，不建立独立对象或从路径推断目录取得方式。Task 不按需要处理、运行、排队、最近或归档状态拆分栏目；状态由行内语义图标表达，具体呈现与排序以 [UI 设计规范](ui-design.md#56-task-列表项目与排序) 为准；
- New task 中央区域始终以 Composer 为主，当前模型和 Workspace 在发送前可见；API 管理不进入 Composer，模型与 Workspace 也不得混成不透明的单一“模式”；
- Task 启动后中央区域显示该 Task 的 Run exchanges，Composer 固定在底部。叙事、唯一 live status、审批和必要结果提示留在主阅读流；Work process 默认折叠，展开后可以在所属 Tool 行下方独立展开精确 Tool 详情。存在 Tool 的 terminal Run 保留折叠的 Work process 作为历史检查入口；完整详情使用有界代码面，不打开或替换右栏内容。Run 用量不进入对话或右栏展示。Composer 附近只按 Host pressure 显示当前 Conversation 的上下文提醒，pressure 消失后隐藏，历史自动压缩记录不单独展示。pendingUi 只派生“需要处理”定位入口，不自动开面板、滚动或抢焦点；用户点击时定位主区唯一原始请求，覆盖式右栏先关闭；
- 应用采用左侧栏、中央工作区、右侧栏的布局；栏的入口、显隐和尺寸属于应用布局，不属于 Task 或具体内容功能。左栏保存 240–480 px 范围内的绝对宽度；停靠时中央工作区与右栏以 Flex 按保存比例分配扣除左栏后的剩余宽度，两者都只设置 360 px 最小宽度，不设置固定最大宽度或固定比例范围。约束无法同时满足时右栏改为非模态 overlay，不压缩中央工作区；右栏只在停靠态允许调整，用户调整的实际像素换算为剩余宽度中的比例保存，窗口或左栏变化只按该比例重新分配。右侧栏开关在主工作界面常驻，无 Task 或无可展示内容时仍可打开真实空态。用户打开具体详情可显式展开右栏；切换或删除 Task、切换主页面、目标失效与普通 Run/审批变化只更新或清理内容，不自动改变右栏显隐或保存比例。显隐保持本窗口会话中的用户选择，不记录每 Task 显隐。设置覆盖层及窄窗左右栏互斥规则由 UI 规范定义。右栏不提供概览；文件预览以对话中的有效文件引用为主要入口，修改审查保留所属 Run 的入口，Tool 详情只在所属 Work process 内原位展开。右栏在当前 Task 内使用对象标签：可同时保留多个精确文件预览和一个 File Changes Review，Review 仍直接呈现同 Run 的连续差异文档，不建立列表页、详情页或返回层级。隐藏右栏保留当前 Task 的标签和已读取正文，关闭标签才释放对应资源；切换 Task 清空全部对象但不改变右栏显隐。身份失效必须在渲染前只移除受影响对象并阻止旧内容出现。右栏内部提供可独立收起的工作区文件树区域，布局和空态以 [UI 设计规范](ui-design.md#11-按需详情与信息归属) 为准；文件树只读浏览当前 Task 已授权 Workspace 的目录，子目录按需加载，点击文件在右栏打开独立文件标签；不要求文件先出现在对话引用中，不递归扫描或扩大到工作区以外。面板不提供加号、任意路径读取、编辑器、Git 操作或跨 Task 标签恢复；
- Task 停止入口位于 Composer，动作显隐与键盘确认遵守 [UI 规范](ui-design.md#8-composer-与执行控制)。停止取消当时已有等待消息与当前 operation，之后的新消息等待停止完成；ack 不伪造 Stopped。标题栏不重复提供 Task Stop；
- 标题栏只承载 Renderer 绘制的窗口按钮、当前 Task 名称、搜索与异常状态等全局入口；不重复说明 Task 的 Workspace，正常连接状态、语言选择和工程诊断也不长期占据主视觉；
- 界面在任一时刻只突出一个与当前阶段一致的主动作；独立的导航和设置入口可以持续可见，但不得与主动作竞争；
- 首个正式版本采用单主窗口；多个 Task 可以后台运行，切换 Task 不停止执行；
- 成功完成提醒是绑定最新 terminal `completed` Run 的一次性未读产品事实，不是 Renderer 会话内装饰状态。用户只有在对应 Task 的中央工作面真实可见且应用位于前台时才确认该 Run；后台完成、全局页面、设置/搜索、窄窗侧栏或全宽 Task Panel 覆盖期间都不得误清。确认结果随 Task 历史在正常关闭后恢复，新成功 Run 使用新 identity 再次提醒；归档 Task 等价于明确处理当前完成提醒。该 receipt 不改变 Task 最近顺序，Renderer 不使用 `localStorage`、时间戳或标题推断；
- Renderer reload、断开连接以及 Bridge revision/snapshot failure 默认只影响视图同步和重连，不得终止后台 Agent Run；只有 Workbench 根据 canonical 产品状态作出的显式 termination 决策才能请求结束 Run；
- 左栏直接列出 canonical snapshot 中 owning Workspace 仍被投影的全部未归档 Task，不提供全局 Workspace 切换器；每个 Task 的路径由自身上下文决定，后台请求不能因路径不同或本机项目分组被移除而从导航中消失。Host 撤销 Workspace 授权并将其移出 Snapshot 时，历史 Task 仍由 Workbench 保存，但随 Workspace 退出活动导航，重新授权恢复同一稳定 Workspace identity 后才重新出现；已投影的归档历史仍可从设置只读查看，该入口不恢复 Workspace authorization；
- Task 是可持续补充、归档和删除的产品对象；Task lifecycle、当前 Run phase 和最近一次 Run outcome 是三类独立状态，Renderer 只能从 Workbench projection 派生展示标签；
- 中间区域只按产品 Run exchange 组织内容，不按 raw Tool callback 或 AgentCore event 构造时间线。主区可以展示 typed Tool 摘要，但不展示 Tool input/progress/result、usage、Run ID、raw AgentCore event 或 chain-of-thought。Renderer 只消费 typed `output/activity/tools`，不把可见回复提升为 Delivery、Output artifact 或最终成果；明确成果交付通过固定 Host 工具校验已有 Workspace 文件，其回执与最小历史记录分别遵守 [AgentCore 集成契约](agentcore-integration.md)和 [Product 架构](product-architecture.md)，不以普通文件引用或文件变化推断交付。完成、失败、中断与恢复动作只依据独立 canonical outcome/cause；
- 用户可以持续编辑并发送有效消息，Task 先接收，再决定就绪文本插话、等待或下一轮；内部执行阶段不能拒绝普通发送。Skill、附件与非就绪阶段也使用同一入口，保持顺序。Core 插话仍只支持普通文本 Run 的文本，在后续边界采纳，不中断模型流或工具，也不保证本轮采纳；文本不能替代权限或请求回答。正常 completed 且可信收尾后的确定未采纳后缀复用一次合并接续，超限、停止、失败、未知或取消不接续；新消息不混入该来源批次，按 Task 队首顺序处理。安全气泡与执行记录保持逐条关联，不重复正文，不从历史恢复执行。生命周期、wire 和交互分别由 Product、Bridge 和 UI 真源定义；
- Composer 以 `/` 作为 context-aware 发现手势，统一显示 Renderer 注册的产品 Command 与当前范围 catalog 投影的 Skill；Slash 文本本身不是 Agent 输入协议，Command 必须在 Renderer 消费且不得进入 Bridge、Task 历史或 AgentCore；
- Command 只复用已有产品动作，不迁移 CLI/TUI 的会话控制语义；V1 只注册 `/new` 与 `/compact`，前者打开既有 New task draft action，后者触发 Workbench-owned typed maintenance action；不注册 `/model`、`/status`、`/goal`、`/resume`、`/continue` 或其他已有正式界面、与桌面产品对象冲突、缺少 typed capability 的 identifier；
- Composer 在同一条消息内保存普通正文和一个可移除的 Skill 选择。草稿保存 Core 提供的逻辑 skill_policy_key、具体身份和双 revision，用于发送时的精确校验。已选工作目录的草稿和已有任务使用对应 Workspace current catalog。未选工作目录的新任务草稿在会话创建前即可用 `/` 发现并选择已启用的内置与个人 Skill，首次发送时创建 Automatic Workspace，校验选择后执行首条消息。交互 Task 在新 Run 前自动查询并绑定当前授权，已开始的 Run 与插话保持原绑定。同一逻辑能力的内容更新或无关目录变化自动保留参数并采用当前 winner；参数定义变化保留输入并要求检查，删除、禁用或冲突禁止对应执行。用户不需要逐任务刷新或选择版本；Renderer 不读取 Skill body，也不猜测来源与路径；
- Skill 中心是 MetaWork 级的本地 Skill 管理 route，不跟随当前 Task 的路径上下文。它按个人与已注册 Manual Workspace 的项目范围展示 Skill 资产，并把需要处理的定义错误、资源错误和冲突置于正常 Skill 之前；用户可以搜索、查看说明/参数/资源/健康状态，从本地 `.skill`、`.zip` 或目录导入，导出 `.skill`，重新导入，卸载并显式刷新 catalog。Personal 列表的开关定义所有项目继承的用户默认值；Manual Workspace 项目列表以 `inherit | enabled | disabled` 三态覆盖该默认值，清除覆盖后重新跟随用户。Core 提供的 `skill_policy_key` 是逻辑策略身份，具体 `skill_id` 用于精确执行；同 invocation 的 Personal/Project Skill 共用策略键，invocation 改名后策略不跟随；MetaWork 不猜测未公开的来源身份。当前不提供在线市场、远程更新、Skill 创建/编辑器、Preset、标签、排序、中央仓库或多 Agent 同步；
- Skill 管理资产与运行时 catalog 是两份不同真相。Workbench 拥有本地 package/inventory、安装 provenance、目标范围、安全文件事务和管理状态；AgentCore 继续独占 runtime discovery、优先级解析、winner/conflict、health 与 catalog revision。MetaWork 使用独立 `install_id` 管理资产，运行时身份仍是 `catalog_scope_id + skill_id`；Renderer 不从名称、路径或 invocation 猜测来源、范围、优先级或身份。MetaWork 未能在已授权 canonical Skill root 中解析并取得精确管理 authority 的现有 Skill 仍可按 AgentCore projection 展示，但必须标记为外部管理，隐藏导出、重新导入和卸载；
- 同一调用名由 AgentCore 先按项目级高于个人级解析，再在同一范围内按 `.agents/skills` > `.codex/skills` > `.claude/skills` > 内置 Skill 选择来源。Product 在组装已授权来源时配置固定优先级，不提供用户排序设置；管理页个人查询遵循相同来源顺序。只使用胜出定义，不合并同名内容；高优先级定义无效时明确报告问题，不自动回退低优先级候选；
- Skill 中心在页面内提供 Claude、Codex 两个兼容来源勾选，默认关闭；每次操作同时启用或关闭该品牌的个人与全部已授权手动项目目录，`.agents/skills` 默认来源始终启用。不提供来源抽屉、逐目录开关、自由路径、排序或逐项目来源设置，Automatic 交互 Task 使用内置与已授权个人来源，工作目录资料不授权为 Skill；Schedule 不因此取得 Skill。只发现当前 AgentCore 支持的 Skill，不继承其他工具的权限或配置。来源配置持久保存；已有个人/项目值不一致时如实显示部分启用，用户操作后才统一，不自动迁移选择。缺失目录不撤销勾选；保存成功与 catalog 就绪分别呈现。来源变化更新 current authority，已有交互 Task 在后续新 Run 的自动准备中采用；目录问题即使没有 winner/资产仍可见，搜索不隐藏问题；
- Skill 启用状态是 Workbench-owned 的 User/Manual Workspace policy，默认启用，只持久化 disabled `skill_policy_key` 与 Workspace override，以及单调 `selection_revision`；持久键精确使用 User policy 或 `workspace_id + skill_policy_key`，不使用易随内容变化的 concrete `skill_id`，也不持久化 Workspace epoch。同一 Manual Workspace registry record 无论经历多少次移除失败或重新授权，其 policy 与本地安装记录都保留；只有该 id 退出 registry 才退休记录，Skill 文件不因此删除。Skill 持久文件只接受当前格式，不迁移、隔离或恢复被替代的数据；能读取但无法解码的记录直接放弃，MetaWork 从空的管理状态与策略继续，并在同次启动中原子写入空的当前格式，不要求用户清理或重启。自动替换失败或文件读取失败时拒绝分配新的 Workspace id（Manual 与 Automatic 均拒绝，New task admission 与 Automatic capability 同步显示不可用），已有 record 仍可重新授权；普通 mutation 的明确写失败仍保留已知 id authority，不阻止分配新 id，但在两个 Skill store 都允许安全退休前不得复用隐藏 Workspace slot。mutation 同时校验 Workspace 当前 epoch、catalog revision 和 selection revision，成功后只影响对应 current policy；已经开始的 Run 不热替换，后续新 Run 自动准备并采用当前 policy。Host 恢复 Conversation 时向 AgentCore 传入空 Skill authority；Manual Task 在下一个交互 Run 前自动采用 Workspace 当前 catalog 与 committed policy。Automatic 交互 Task 安装可用 Session 后，在首个后续 Run 前完成 root/home/epoch 绑定的初始 catalog 查询与 idle 绑定；准备失败显式发布不可用，保留 Task 和草稿，普通运行不硬性要求某个 Skill；已有执行快照在后续新 Run 的安全准备边界自动替换，查询失败与授权收缩遵守 [Product Skill 合同](product-architecture.md#24-skill-authority-与本地资产)；
- 本地导入必须由 Host 原生文件/目录选择产生的一次性、window-bound staged capability 发起；Renderer 不提交任意物理路径。来源菜单区分安装包与文件夹，范围默认沿用页面个人/项目筛选；确认必须绑定实际范围、源内容和目标影响，区分新增、保留身份与启用策略的受管更新，以及已授权未登记目录替换。改选目标重新准备，源或目标变化要求重新确认；接纳前 busy 不消费有效确认，消费后不得复用。目录与归档接受规则以 [Product artifact 合同](product-architecture.md#5-skill-交换-artifact)为准，错误须提供对应的修正动作。导入在目标范围外完成有界解压、路径/类型/容量检查和只读预览，经用户确认后原子发布到个人或指定 Manual Workspace 的 `.agents/skills`。明确属于候选 Skill 的 AgentCore definition/resource/conflict failure 必须回滚；catalog 暂时无法完成验证时保留已发布资产并进入 `pending_verification`，不能伪装成可用。替换或卸载不得与可能消费该范围的 active operation 并发，不得静默覆盖现有目录，并必须保留可恢复的事务前副本直到提交完成；
- 受管导入与重新导入在源摘要校验后，向候选 `SKILL.md` 正文开头补充幂等的资源定位说明，保留作者 front matter、正文和附带资源，原始输入不变。preview 展示源 metadata 并说明安装与导出内容会被补充；grant 仍绑定源摘要，发布、恢复和 inventory 使用实际安装字节的摘要。说明中的 `${CLAUDE_SKILL_DIR}` 由 AgentCore 在激活时展开；其他工具未展开时使用其已知的 `SKILL.md` 所在目录，不将模板 token 当作路径或 shell 环境变量。安装位于共享标准目录，其正文对其他读取方及取得项目副本的协作者可见。导出保留实际安装说明，再次导入不重复添加；不在启动时改写既有安装、手工项目定义或外部管理来源，既有受管资产通过重新导入采用该行为。此说明不授予额外文件或执行权限，无法定位时如实报告，不搜索或猜测安装根；
- 文件事务明确失败时尝试一次当前资产的安全恢复；仍未收敛的资产显示“需要恢复”，通过现有 Retry 重试，不能冒充“等待验证”或 ready。management 持久化失败时暂停管理并提示重启后重新加载、尝试恢复；恢复准入与冻结边界由 [Product 架构](product-architecture.md#24-skill-authority-与本地资产)定义；
- 用户创建或修改 Skill 仍通过普通 Text Run 与 AgentCore built-in Read/Edit 完成，不在 Skill 中心建立第二个创作或文件编辑器。Workspace 内的 `.agents/skills` 服从现有 Workspace authority；用户级目录只有在用户通过原生 picker 明确把目标 Skill 目录授权为 Manual Workspace 后才能修改。Skill 中心可以导航到预填的普通 Text draft；项目 Skill 在下一次选择器检查或新 Run 准备时自动发现，个人 Skill 通过受控本地导入发布。一次 Run 使用已绑定 snapshot，不主动热替换；后续调用自动采用最新完成查询的授权结果。管理替换的 active-operation 保护保持，外部资源改写的真实 Core 拒绝不得伪装成旧版执行成功；
- 由更新版本保存、只因含当前版本无法识别的字段而不能完整读取的历史 Task 以只读方式出现：可阅读，不能发送、重命名、归档或删除，并说明需要更新的 MetaWork；完全无法读取的已保存 Task 不出现在列表中但原样保留，左栏说明其数量；
- Host 重启后恢复的历史 Task 先以 detached、可阅读状态出现；满足恢复资格时，用户选择左栏 Task 只看到已保存产品历史与普通 Composer，不显示恢复卡片、恢复按钮或专用 placeholder。用户首次发送新消息时，Task 先接收，由 Control 协调一次必要 restore，确认 attachment 后才按队首准入 Run；失败显示该消息未执行，不循环修复，之后新的显式消息可再次准备。只有 source Task/binding、checkpoint ownership、Workspace/Task identity、Conversation、terminal state 与当前 execution target readiness 均可安全恢复后才允许该内部前置步骤；Skill/MCP/Permission continuity 缺失只产生 degraded 能力状态。历史 execution generation 不要求等于当前 generation：同 protocol 且当前 authority 可承载 Task model 时，restore 必须以 durable adoption 同步推进 Task generation、binding epoch 与 checkpoint anchor 后再安装 attachment，并保留旧 Run 的逐 Run provenance。该窄 adoption 只连接同一 Task 的 source Conversation 与当前可执行 target，不允许切换 protocol/model，也不构成通用 rebind；任意配置 rebind 或从历史创建新 Task 仍属于后续显式产品能力，当前实现不得用它们冒充恢复；
- Run 中 AgentCore `tool_result.file_refs` 与 Agent 验证的 Host 生图保存凭据所形成的结构化文件引用是 File Preview 目标的唯一依据。Renderer 在过程说明与结果回复中将可无歧义匹配本 Run 已知引用的文件名称或链接呈现为内联预览入口；工作过程不提供文件预览入口，只允许把结构化 `displayPath` 作为 Tool 单行摘要中的只读文字。用户显式选择正文入口后才通过精确 `taskId + runId + fileReferenceId` 请求 Host 读取 Workspace 中的当前文件内容；预览进入 Task Panel 独占的文件预览视图，以当前路径为标题且不汇总显示全部引用文件；具体入口与切换行为由 [UI 设计规范](ui-design.md#121-文件预览)定义。该能力读取当前内容而非 Run 时版本，只在当前 Task 的已打开标签中保留已读正文，不跨标签关闭、Task 切换或应用会话缓存，不持久化、不自动刷新，也不把 reference 的 kind、Tool 名称、普通文本或 Bash 输出解释为文件变更、Output 或 citation；这些底层语义不要求以常驻提示或说明入口重复展示。Host 必须在独立有界 worker lane 中执行 no-follow、root-contained、regular-file-only 的有界读取：文本最多 256 KiB；静态 PNG、JPEG、静态 WebP 读取原图，经完整原件凭据检查和分块传输后由 WebView 解码。单图最多 10 MiB、16777216 像素、最长边 8192；超限明确拒绝，不再自动缩小。APNG 和动画 WebP 不支持；有效主图结束后的尾部数据允许保留并纳入大小、凭据和传输检查。Host 原图容量不足独立重新排队，文本不占图片槽；窗口累计图片容量不足明确反馈。主线程在交付前及分块时重新校验 Task/Run/reference/Workspace authority；文本以当前及历史 execution credential 脱敏，图片原件命中凭据时拒绝交付；实际解码完成前保持加载状态。安全代次、关闭或引用失效使已交付资源失效；非 ready 状态不得携带正文或图片。资源与传输额度见 [Renderer Bridge 合同](renderer-bridge-contract.md#file-preview-command)；
- Host 确认保存的生成图片在所属 Run 直接提供可点击的有界图片预览，点击图片复用右侧文件预览标签；内联预览接近可见区域时才请求，关闭 Task 或引用失效后丢弃迟到响应。旧记录缺少 Host 来源标记时不从工具 JSON 或路径补猜。预览只证明文件可以显示，不等于模型看过图片；不增加图库、typed Output 或任意路径读取能力；
- `Files changed` 表示实际文件变更集合，`Outputs` 表示用户关心的交付结果，两者不得用“新建文件”或 File Preview reference 自动等同；File Changes 只消费 AgentCore typed `file_changes` observation，并在右侧 Task Panel 的连续 Review 文档中按文件首次出现顺序展示。同一 `displayPath` 的记录按稳定顺序汇入一个文件区块；首个文件的首条 recorded diff 立即按需读取，其余记录只在所属区块接近可见区域时逐条读取。同一个已打开 Review 可以同时保留已经读取的多个正文，隐藏右栏或切换其他标签后继续复用；关闭 Review 标签、替换目标或重新打开已关闭的 Review 后不得复用。Review 与每条 recorded diff 必须绑定同一 `taskId + runId + changeId`；关闭 Review 标签、切换 Task、目标 Run 或具体记录失效都必须使对应旧异步结果失效，单条记录失效只更新所属文件区块而不清空仍有效的 Review；普通 Run 生命周期变化不得关闭仍有效的历史 Review；Outputs 只展示所属 Run 已明确登记的可信交付记录，按 capability 开放且空集合隐藏；路径脱敏时不显示文件名或位置，交付时大小不代表当前文件仍可用。文件动作仍须独立通过 Host 的当前授权与内容检查；
- Task 归档隐藏日常列表且可恢复，统一在设置的“已归档任务”管理；归档成功提示去向并提供撤销与查看。归档 Task 或撤销 Workspace 授权前必须先终止其 queued/running/waiting/stopping Run。Task 可直接删除，无需先归档；运行中可一次确认停止并删除，原归档状态不变。Workbench 接受一次删除意图后立即拒绝新输入与执行，取消等待输入和接续，停止当前 operation 并收口仍存活的 Session，并在 executor stable record reference、checkpoint 与全部资源 quiescent 后原子提交和物理释放，不要求用户为正常推进重复提交。删除进度以 runtime-only 的 `idle | deleting | failed` 产品事实发布，不持久化、不混入 Task lifecycle 或 Agent Session 状态；明确失败必须保留 Task 及原归档状态并等待用户显式重试，不能伪造成功、静默回弹或自动形成重试循环。若失败后 attachment 已恢复到可用状态，用户显式恢复归档，或未归档任务显式发送新消息、归档，表示放弃该次失败删除；只在新操作安全且被接纳时 Workbench 才能把删除状态原子重置为 `idle`；仍在 closing 的 Task 不开放恢复归档。删除 Task 记录不删除 Workspace 中的真实文件；撤销 Workspace 授权时先原子进入 `removing` 并推进 Workspace epoch、拒绝新 admission，全部 Task 收口后撤销当前 Host authorization 并退出活动导航；
- 全局搜索覆盖 Task、用户指令、完成消息和 Output 文件名；Workspace 只作为 Task 与 New task 的路径上下文，不作为独立导航结果；工具原始日志默认不进入普通搜索；
- `en-US` 是规范产品文案和回退语言，`zh-CN` 是首个完整 locale；Host 传递 structured code 与参数，Renderer 负责本地化。

### 5.10 MCP 服务

- `MCP` 是与 `新建任务`、`技能`、`定时任务` 同级的 MetaWork 全局页面，不跟随当前 Task 或 Workspace，左栏入口稳定显示。`capabilities.mcpManagement` 只声明 revision 1 的 typed 管理合同是否真实接通，不与 Runtime 是否 ready、registry 是否为空或管理事务是否暂时冻结做等值判断；`mcp.availability` 独立表示当前 Runtime/catalog 可用性。
- 成熟接入范围固定为 STDIO 与 Streamable HTTP、Tools，以及 `none | static | oauth` 三类授权。OAuth 只适用于 Streamable HTTP；STDIO 的 static credential 只经显式 environment name 注入，HTTP static credential 只经显式 header name 注入。Host 只允许 AgentCore 使用 `2026-07-28`、`2025-11-25` 与 `2025-06-18` 三个 exact era；显式 `modern_only` 与 `compat_only` 分别固定前两个，`automatic` 可以协商并 exact reopen 到三者之一。其他版本、legacy SSE、Resources、Prompts、Apps 与 Tasks 一律拒绝。MCP era 不构成旧 AgentCore ABI revision 的兼容路径。用户显式提交 Add/Replace 就是对该完整连接的授权：新 server 默认 enabled、connection-approved 且 tool allowlist 为空，新发现 tool 也默认不扩权。用户可以在详情中对当前已发现的工具做一次显式批量放行；该动作仍是全量 allowlist 重提交，且此后新发现的工具依旧默认排除。schema 1 迁移产生的 unapproved server 仍保留一次 legacy connect 动作，不让普通新建流程重复审核用户刚提交的配置。
- 添加服务是 transport-discriminated 的 typed 流程，不是 generic upsert。STDIO 配置只接受可执行文件、argv、可选 cwd、environment name 与对应 secret slot；不提供 shell string、命令替换、credential argv 或整个进程环境继承。Host 只从启动环境复制非敏感 executable search path，并在绝对 command 前置其所在目录，以支持 `/usr/bin/env` shebang 和 bare executable lookup；该 `PATH` 与 Windows `SystemRoot` 是不可由用户 environment slot 覆盖的受控基线，其他变量一律不继承。Streamable HTTP 配置只接受 endpoint、auth mode 和有界 header name；endpoint 只允许原始 authority 被完整、无歧义解析的 HTTPS 或精确 loopback HTTP，允许原样保留 query，禁止 userinfo、fragment、authority percent encoding、空白、控制字符和反斜杠。Renderer 可以提交公开配置，并通过普通 password input 临时采集用户显式填写的 static secret 与 OAuth client secret，经专用 typed command 交给 Host 写入独立系统 credential service；输入生命周期与提交边界遵守 [Renderer Bridge 合同](renderer-bridge-contract.md)。
- 公开 endpoint 与敏感 endpoint 使用同一连接 owner；敏感地址或有序模板片段只通过系统 credential storage 引用保存，registry 仅持公开 origin、Host 分配的稳定身份和凭据引用，真实地址只在有界 Host 执行副本中组装并校验 origin。Host 在所有创建/替换入口拒绝已登记凭据进入公开字段；显式敏感 endpoint 必须走 credential journal，不能保存为公开 URL。未知 URL path/query 凭据没有可靠通用识别，不建立站点或名称猜测规则。
- 用户在 Task 提供 MCP 安装链接后，Agent 通过固定 `InstallMcpServer` 提交结构化安装请求，Host 完成凭据获取、配置、连接、发现和首次精确工具授权。普通路径不再要求 Add 或手动选择工具；只有缺少凭据、OAuth 或需要确认的来源/跨 origin 凭据传递才交互。来源意图只取同一 Task 的真实用户输入，撤销必须生效，歧义不能自动放行；网页说明不构成授权。STDIO 持久启动命令仍受现有工具权限约束。Agent 不获取秘密或要求用户在对话中提供 Token；Host 按公开 HTTPS GET/JSON Pointer 计划获取或通过专用 password 表单接收。Agent 提交的完整 HTTP endpoint 默认按敏感地址存储，path/query 不进入公开 metadata。接纳只表示进行中，Task 卡片和 MCP 页发布真实结果；ready 首次发布必须证明新 Task authority 有效，既有 Task 不热增工具，后续新增工具不自动扩权。失败后同一 Task、同一来源的唯一失败目标原地修正，歧义明确拒绝；用户主动 Stop 撤销未完成安装，Run 正常结束不取消。

- 连接信任不建立独立于配置提交的常规审核步骤。Add/Replace 的确认按钮绑定 transport、endpoint 或 command/argv/cwd、environment/header name、auth mode 与协议策略，并在同一个 Desired Registry transaction 中写入 connection fingerprint；在用户提交之前不得启动 child、读取 credential、发网络请求或打开 OAuth browser。OAuth consent 仍是独立安全边界：connection-approved 后才执行无凭据、有界 discovery；本版 registration plan 明确为用户提供 client id 与 `none | client_secret_basic | client_secret_post` token endpoint auth method 的 `pre_registered`，或 authorization server metadata 明确提供 endpoint 时的 `dynamic_registration`，前者需要的 client secret 由上述 Renderer password input 提交。DCR confidential result 只有在 `client_secret_expires_at` 缺失或为 `0` 时才能进入现有 client-credential revision；非零 expiry 在没有 secret renewal owner 的本期必须按已可能产生远端 client 的 outcome unknown 收口。OAuth Consent 绑定 connection approval、canonical resource、exact issuer、requested scopes、redirect identity、registration kind、client identity 与 client-credential revision；callback 必须校验 state、PKCE S256、redirect identity，并按 2026-07-28 规则对出现的 `iss` 做 exact comparison。
- 页面采用成熟 MCP 客户端共有的“Desired Registry、当前 Runtime/catalog、新 Task authority”分层。Workbench 以 Desired Registry、与当前 Agent Runtime 同寿命的 Runtime Manifest、Agent Activation 和 Admission Authority 形成单一控制面：`desired enabled` 是用户意图，connection approval、auth readiness 与结构有效性共同决定服务是否具备 Runtime/Admission 资格；已批准但缺凭证的服务可以保持 enabled intent，却必须以 `needs_authentication` 排除在 Runtime 与新 Task authority 之外。新 Task 只消费 Admission Authority，禁止绕回 Agent current selection；既有 Task 保持 AgentCore 在创建时同步复制的 authority，不热替换或承诺即时撤权。
- MCP 配置是 Workbench-owned 的全局产品配置，不属于 Metask Account、Workspace 或 AgentCore 协议状态。Host 从 `<MetaWork data dir>/mcp/registry.json` schema 3 恢复稳定 identity/namespace、transport、auth mode、connection approval、OAuth consent/registration/grant 的非 secret 事实、credential locator、启停、timeout、协商策略、显式 tool allowlist，以及 nullable 顶层 `oauth_operation` marker；marker kind 只允许 `dynamic_registration | code_exchange | refresh`。Host 分别生成外部稳定 server identity 与 AgentCore namespace：identity 使用 `mcp-<20 位小写 hex>`，namespace 使用 `mcp_<20 位小写 hex>`，namespace 必须以 ASCII 字母开头且其余字符只允许 ASCII 字母、数字或 `_`，不能把 identity 直接复用为 namespace。旧 registry 中结构可恢复但不满足运行时语法的 namespace 只使对应 server 进入 `invalid_catalog`，不得污染整个 registry 或进入 Agent Runtime；用户删除后重新创建服务即可获得新 namespace。schema 1 只迁移既有 identity/config/allowlist/locator，并统一落为 disabled + unapproved；schema 2 单向迁移保留既有批准、工具选择和凭据引用，不因升级自动扩权。连接 timeout 表达单次请求等待时限；连接和目录管理按 Host 公布的有效上限执行，工具调用保留用户配置的 timeout。较大的历史保存值保留，界面说明上限只适用于管理操作。Registry 保持单一全局 desired generation、单一 credential transaction journal 和全 registry locator 引用差分，不保存 secret、token、authorization code 或 PKCE verifier。写入/清除 operation marker 是同一 registry 文件上的 operation-state commit，不推进 desired generation；只有 server target 变化才推进 generation。
- Runtime Manifest 只在内存中记录当前 Runtime 已接管的 loaded descriptor fingerprint，或 disabled、invalid、unapproved、missing-authentication、reauth-required 等未加载 server 的安全 absence proof；成功接管零个 server 的 Runtime 必须提交零 entry Manifest。Desired mutation 明确保存后，Product 从已确认的实际 Runtime 成员逐个规划加入、替换或移除；Application 仅为该步新候选 preparation，复用其他成员，并调用官方完整集合原子 apply。每步单独接纳 Manifest、正式 activation/tool discovery 与当前授权下的 Admission Authority；后续候选失败不回滚之前的成功，该路径不要求重启 MetaWork。`configurationApply = idle | applying | failed` 是公开的应用状态；`runtimeAlignment = restart_required` 只表示 desired 与当前正式 Runtime 尚未对齐的内部兼容事实，UI 必须翻译成 connecting 或可重试的 apply failure，不能要求用户重启。 `runtimeAlignment = current` 只表示目标已处理，仍可包含可重试的应用失败，不能据此声称所有服务健康。配置列表按成员共享 connector owner；释放旧列表不能释放仍被其他列表或 Core 使用的成员，具体资源在其 Host/Core 引用及 active connection 静止后回收，最迟由 Agent Runtime 销毁统一释放；既有 Session 继续使用创建时同步复制的 authority，新 Task 只在完成事务成功后取得新 authority。同一 OAuth consent epoch 内的 token revision 仍通过 CAS 原子替换 ref-counted HTTP auth snapshot。tool-only mutation 可以直接更新后续新 Task authority，不重建 transport。
- 每个 registry mutation 从 canonical desired 构建 immutable target，并携带 `expectedDesiredGeneration`。Renderer 从 Host projection 获得完整、typed 的非敏感连接配置，编辑时以该配置原样预填并重新提交完整目标；不得从 basename、数量或 origin 等摘要猜测旧值。Static credential locator 只在接收目标未改变时按同名 slot 沿用：STDIO 目标由 command、ordered argv 与 cwd 共同确定，HTTP 目标由 endpoint 确定；目标、auth mode 或 slot 变化使不再引用的 locator 经同一事务退休，display name、timeout 与协议策略变化不移动 credential。OAuth 编辑在 endpoint 与 registration plan 不变时保留 consent epoch、client identity、有效 grant、token revision 和 credential 引用；派生 fingerprint 按当前配置重算，目标或注册计划变化才重新授权。Runtime-compatible authority 变化先构建 owned candidate selection，随后按既有 journal/credential/registry 顺序持久化，明确成功后才 no-fail 安装 target 与 candidate。Runtime-incompatible target 排除来源版本不匹配项，仍有效的其他实际成员继续支撑新 Task authority；没有可用证明时发布相应的 blocked/null authority；明确失败不改变旧 desired/authority；saved recovery required 安装已知 target 后冻结 mutation；outcome unknown 不宣称 canonical desired/generation，并阻止新 Task 取得 MCP。`oauth_operation` 活跃时拒绝同 server 的编辑/删除/授权 mutation；其他 server mutation 可以提交，但必须原样保留 marker。外部结果返回后不要求起始 global generation 仍相同，而是先按 operation id 和 server-bound fingerprints 校验当前 canonical registry，再从当前 generation 构建 target，确保无关 server 变更不会丢失或把已成功的远端 effect 误判为 stale。
- DCR、authorization-code exchange 与 refresh 都是不可回滚外部操作，统一使用持久 `oauth_operation`。操作开始前若目标 server 当前进入 Admission Authority，Workbench 必须先基于 current catalog 预构建排除该 server 的 owned selection；marker 落盘后 no-fail 安装 reduced authority，再允许发送请求，无法构建时不得产生外部 effect。每次 marker 绑定 kind、server、connection approval、consent draft/epoch 和适用 token revision；DCR success 构造 issued client identity 和可选 fresh client-secret locator，token success 构造 fresh token locators、当前 registry target、HTTP auth snapshot 与恢复目标 server 的 Admission candidate，再经既有事务提交并 no-fail 安装。明确收到未创建 client 的 DCR rejection 可以清除 marker 并进入 `client_registration_required`；`invalid_grant`、响应丢失、成功后落盘失败、结果不确定或启动发现遗留 marker 都进入 `reauth_required` 并保持 reduced authority，不得重放、回滚到旧 active token 或猜测成功。DCR outcome unknown 可能遗留一个远端 registration，UI 必须说明再次尝试可能新建 client，本期不声称远端 revoke。能够可靠证明 non-idempotent request 尚未发送时，可以按当前 operation 清除 marker 并保留原授权事实，由 Product 决定后续重试；取消、超时和网络错误本身不构成未发送证明。用户 Cancel 在请求可能已发送后只能停止本地等待并提交 `reauth_required`，不能把 socket cancel 当作远端未执行。已经选中的完整响应不因清理阶段的取消失去已知结果，其采纳仍须通过当前绑定校验。Product 按安装或恢复 grant 时固定的有界提前刷新时间和按服务器退避选择下一台可刷新服务，真实 token expiry 不变；Application 只维护一个由 Product 返回资格时间驱动的 timer，并保留全局时间下限，把该 server 提交给 Workbench 的全局单 OAuth operation；这不是通用 lease scheduler。可信 Bearer challenge 发布 typed reauthorization fact，scope step-up 必须取既有 requested scopes 与 challenge scopes 的 union 并重新 consent，不在失败请求内递归重试。没有可信 challenge 的 401/403 只记录当前来源和 token 版本的 HTTP 拒绝，不自动判为过期或退休 grant；用户手动重试可以据此先受控刷新一次，普通网络故障不触发该刷新。当前目标连接失败且未加载时，ready 授权也允许用户原地重新登录；新 token 连接仍失败后停止自动恢复，等待显式用户操作或相关配置变化。
- MCP 启动遇到可读取但无法按已支持格式解码的配置时，保留原始字节并隔离，在安全完成关联事务隔离后安装当前空配置继续运行；合法旧格式沿现有迁移政策处理，未知格式保留原位并报告不可用。读取、资源耗尽或隔离失败保留真实诊断，不显示为正常空配置。隔离内容及可能遗留的系统凭据保留供人工排查和恢复，不据此自动使用或删除凭据；诊断不展示 locator，也不推断或报告遗留凭据的精确数量。
- Disable/Delete 后，该来源不再开放给新 Task；当前进程已有 Task 的引用可以保留实际连接，直到最后一个相关 Task 删除。停用期间 Edit 只保存配置，重新启用后才用新配置连接。旧 Task 恢复仍受已提交的工具撤销限制，删除不能恢复此前已撤销的工具；重启不重建已删除的来源。 停用且仍被引用的 OAuth 服务，仅在当前授权仍匹配实际运行版本时继续自动续期；删除的 OAuth 服务停止续期并立即退休系统凭据，旧 Task 中现有授权到期后不可用。
- MCP 配置准备、Agent Runtime 配置应用和 MCP 激活是三个不同失败边界：Registry/approval/credential 等可归因 MCP 故障发布 unavailable/degraded，普通 Task 仍可运行；正式 Agent Runtime init 或 AgentCore Runtime create 失败是 Application 启动失败。Application 正式以 canonical empty MCP Runtime 和零 entry Manifest 完成启动；恢复出的 Desired 由既有 configuration-apply coordinator 在后台执行完整 replacement 与 activation，外部 MCP child、network、handshake 和 catalog discovery 不进入 Application 或普通 Task 的 readiness 关键路径。apply 完成前创建的 Task 使用 null MCP authority并保持创建时语义，成功完成后只有新 Task 取得新 authority。首次手动添加远程服务时，「继续」发起无凭据的隔离握手与目录检测。第二步展示探测到的认证方式和注册能力，允许用户改选。公开访问和请求头认证在点击「添加服务」后按当前配置重新验证，握手通过才将连接和请求头凭据一起保存。检测到 OAuth 时可先保存连接和注册方式，服务进入待授权状态，由用户在详情中发起登录。授权成功并完成正式连接前，服务不可供新 Task 使用。检测或验证失败时保留表单的非敏感字段，取消后丢弃草稿。已保存服务的 Edit/Enable/Disable/Delete 在保存后自动启动正式配置应用，不要求用户先测试。正式连接并发现工具后，由用户显式选择工具供新 Task 使用。Add 的提交动作不声称默认关闭的工具已经开放，正式 catalog 已发现工具但 allowlist 仍为空时必须继续呈现选择工具这一步。`测试连接` 只作为按目标 server 启动隔离候选 Runtime 的诊断动作，并只把 `testing | connected | failed`、tool count 与 issue count 写入进程内安全 projection；它不替换正式 Runtime、不改变 Manifest/Admission、不创建 Task，也不持久化 catalog，不得覆盖列表主状态或成为正式失败恢复动作。Refresh、apply、mutation、OAuth operation、测试与新 Task admission 由现有 owner 串行化；shutdown 必须 join 这些 worker 后再释放管理 owner。
- 页面按需要处理、可用与已停用组织，桌面端使用与 Skill、Scheduled tasks 一致的居中有界管理页；连接列表占据完整内容区宽度。用户明确选择服务或 Add/Edit 时打开居中模态弹窗，关闭后返回列表上下文。详情用 `Connection → MCP handshake → Tools` 轨迹呈现真实应用进度，工具授权紧随连接成功结果；连接测试保留为次级诊断。STDIO 的普通输入允许粘贴一条启动命令，Renderer 只进行有界、安全的引号/转义分词并拒绝 pipe、重定向、变量/命令替换，Bridge 仍只接收结构化 command + ordered argv，Host 绝不调用 shell。完整非敏感 typed connection、typed diagnostic 与工具目录可查看和预填编辑；environment/header value、credential locator、client secret、token/code/PKCE、动态注册所得内部材料、raw diagnostic、schema body、fingerprint 和 AgentCore handle 仍不得进入 snapshot。marketplace、publisher trust、Task/Workspace override、多账号、远程 token revoke 与既有 Session 热撤权不在本期范围。

### 5.11 定时任务

- `定时任务` 是与 `新建任务`、`技能` 同级的独立页面，不属于 Skill 中心、交互式 Task 或某个 Workspace 的子页面；页面不显示或选择 Workspace，每次 occurrence 直接请求新的 Automatic Workspace；
- 没有定义时，页面显示“还没有定时任务”，通过页首统一 `新建` 入口创建，不展示建议模板。定时任务使用自动工作区，不要求用户先添加或选择 Manual Workspace。已有定义时支持搜索，并按 `已启用 / 已停用` 组织，异常停用的原因在任务行内说明。紧凑行显示名称、计划、下一次运行、最近结果及其真实 Task 链接，并提供编辑、暂停/恢复、立即运行和删除；
- 创建流程先填写名称和任务说明，模型及权限整合在任务输入框底部，再设置运行时间。新建与编辑共用唯一的时分选择器；新建仅提供单次、每天、每周、每月。每周可多选星期，每月可多选月内日期，初次切换分别默认今天的星期/日期，至少保留一项。已有计划未改时间或选择时保留原起点；明确修改时间、频率或日期选择时，以保存时刻之后下一个符合条件的日期和时间作为起点。模型可由有效起始偏好预填，必须展示最终选择；保存后固定于定义。编辑非模型字段保留原绑定；明确改选模型，或对 `execution_changed` 计划在编辑表单确认当前模型时，重新解析当前可用目标。目标不可用时必须另选可用模型，不得静默替换或继续提交失效绑定。权限默认采用当前新任务默认值并固定保存；不提供 Workspace 或 Skill 配置，也不展示 protocol、generation 或 Unix seconds 等工程字段。
- 时间规则支持一次性绝对时间、由明确起点开始的固定秒数间隔，以及指定 IANA 时区的每日、每周多个星期、每月多个日期的日历周期；已有每小时、每年规则继续保持原语义，不在新建菜单提供。日历周期保持起始 instant 对应的本地时间；不存在的本地时刻或日期跳过（如短月的 31 日、非闰年的 2 月 29 日），重复时刻只采用较早 instant，一次唤醒仍只接纳最新到期点。Host 保存 canonical Unix time、locale-independent recurrence 与显式提交的创建时 timezone identity，编辑不改变创建时区，旧定义缺失时保留 unknown；固定间隔不得自动转成日历周期。Renderer 只负责本地化显示和结构化编辑，不用本地 timer 推进产品状态；
- 每次自动或手动触发创建一个新的真实 Task。计划定义不复用旧 Conversation、不把结果复制成第二份聊天历史，也不绕过既有 Task/Run admission；
- 同一 Scheduled Task 的上一次 Task 仍有 non-terminal Run 时，自动触发必须跳过本次；不得并发重放同一计划或自动终止已有 Run。若历史中的 Task 已永久不可用，Schedule 必须把该 occurrence 收口为 `unavailable` 并继续检查其他待收口 occurrence，不能形成队头阻塞；
- 自动触发使用 `(scheduledTaskId, plannedAt)` 形成跨 Host 恢复稳定的 occurrence identity；后台 Host 延迟、休眠或重启恢复时最多接纳一个最新的到期 occurrence，过去的多个时间点不批量补跑，并在 occurrence history 中明确标记 delayed/skipped。Task 历史 writer 暂忙时，自动触发在认领前等待可写；立即运行返回暂忙，允许用户显式重试；
- Scheduled Task 定义、触发游标和有界 occurrence history 由 Workbench 原子持久化，canonical `schema_version = 1` 严格保存 `ModelRef + source_generation + protocol`，不保存 global selection revision。被 hard cut 替代的旧格式先将原文件 exact bytes quarantine，再原子安装空的当前 store 继续，不迁移、双读或重放旧计划；隔离或安装失败发布真实 I/O/持久化错误，不得假报成功。当前格式的普通提交、结果不确定及显式恢复继续由 Schedule owner 处理。每个计划按自身绑定验证，单个来源失效不得停止其他有效计划；偏好变化不参与 timer 或计划资格。
- 主窗口关闭使用后台/托盘形态而不是销毁 Host；后台 Host 继续 timer、Run、通知与待处理事实，托盘提供重新打开和显式退出。显式退出可以停止本机后台执行，但下次启动仍恢复定义并执行上述单次 missed-run reconciliation；
- 执行配置、Workspace authority、容量或 shutdown gate 不再满足时，计划进入明确的 `needs_attention`，停止继续计时并保留 typed 原因；用户必须编辑并确认当前事实后才能恢复；
- Scheduled Task 定义必须固定一份可持久化、可恢复的非交互 `PermissionProfile`；默认值后续变化不得改写既有定义，编辑生效前必须重新经过 definition admission。编辑 paused 定义只更新未来执行内容，不得静默重新启用；
- occurrence 不得进入同步 permission wait。若固定 profile 无法覆盖某个操作，当前 occurrence 以 typed `permission_required`（或经批准的等价产品原因）停止，结果记录在该 occurrence。该 Run 的权限配置仍与当前定义相同时，定义进入 `needs_attention`。系统通知只能定位该真实 Task 和原因，不能承担远程批准、临时升级或继续原 Run 的职责；
- Scheduled Task 和 occurrence 不保存 credential、Authorization header、OAuth URL 或 AgentCore handle；计划标题和 Text instruction 进入产品 projection 前执行与 Task history 相同的有界复制和 credential 清洗；
- 每次 occurrence 必须由 Product Control 按定义自身的 `ModelRef + source_generation + protocol`、当前来源授权与目录 membership 精确解析；起始偏好及其 revision 不参与校验，编辑并发由 item epoch 保护。Product Control 的进程内 generation 可以在冷启动后变化；只要 source authority 未变，该变化不得单独使 Scheduled Task 进入 `needs_attention`。Catalog 或 execution authority 尚未就绪属于瞬态 admission 事实，只停止 resolve、occurrence 与 timer，不得持久化为 definition failure。当 Metask 是定义引用的 provider 时，Account 退出使其对新 resolve 不可用并停止 occurrence；custom provider 不受 Account 状态影响，已创建 Task/Run 也不被追溯撤销；
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
→ 文本流 → Agent-owned 固定工具集合 → 当前 `approval_required` compatibility permission
→ 工具结果 → 最终回复 → 取消/关闭 → Renderer reload 视图重建
```

它不包含独立 AgentCore Worker crash recovery、in-flight Run 恢复、async suspend/resume、strict Workspace security 或用户自定义 Host tools。正常 Application 重启后的 finalized Conversation attachment 恢复按现有 checkpoint 合同独立提供，不扩大上述边界。

### 7.2 Account 与 Custom Provider 集成 baseline

当前在同步执行路径之前提供：

```text
Metask 登录或配置用户 Provider → Host 后台恢复/验证 API、credential 与模型
→ 用户确认完整模型目标 → Task-owned ExecutionConfig
→ 进入 Workbench → 选择 Workspace / 编辑 New task 草稿
→ Composer 确认模型 → Task admission → 当前同步执行 baseline
```

Metask C1 OAuth/login 的 authority、client、scope 与动态 loopback callback 以 [Account 架构](account-architecture.md#5-metask-oauth-与-identity-合同)为唯一合同；Models-owned C2 catalog使用已通过 production复核的无 Profile-ID通用路径。Account先提交 token rotation，再严格验证 `/api/oauth/userinfo` 并提交以 `sub` 为 principal 的 identity；Application随后以 authorization lease启动独立 Models continuation，C2失败不得抹除已完成登录。用户连接使用 Models-owned typed protocol/endpoint/credential流程，不依赖 OAuth，但必须通过 [Completion 架构](completion-architecture.md)定义的 Agent-owned one-shot test。Workbench 的新 Task admission 按显式目标与当前来源 authority 校验，具体合同见 [Product 架构](product-architecture.md#22-workspace-与-task-admission)；不能把仅有 authenticated identity、起始偏好或未验证连接误报成已经可以执行。

### 7.3 Fault-domain 结论

事件泵数据、生命周期压力测试和同进程/最小 Worker fault-domain spike 已完成。结论是选择单 AgentCore Worker 作为后续正式故障域；当前应用仍是同进程 prototype，正式 Worker、跨进程恢复和危险工具重放策略不属于当前交付。

### 7.4 Windows baseline

Windows 支持 x86_64 与 arm64，统一使用 [AgentCore ABI 合同](agentcore-abi-v1.md)定义的 MSVC 消费目标。exact artifact identity 以对应 target repository lock 为准；target availability、Native Debug/Release、真实 AgentCore vertical、干净退出与分发证据以[验证规范](validation.md)为准。精确 bundle、Renderer 与 MetaWork 平台无关测试通过不能替代这些平台证据。

### 7.5 后续产品能力

`PermissionProfile` 的 Task-create owner、same-profile fresh/restore、Run provenance 与 Scheduled noninteractive，以及 typed File Changes 审查和明确成果交付记录的持久化、恢复与呈现已进入当前产品；成果文件检查、定位与另存按当前授权和实际字节校验开放；另存只在系统对话框选择目标，提交后按实际结果呈现。继续修改入口在检查后准备同 Task 普通草稿，由用户手动发送，不代表文档已修改；实际修改仍沿既有 Agent、权限与 Skill 路径验收。文档预览的完整安装与应用纵向及 XLSX 版面检查仍须完成其验收。async pending、更完整的跨重启 execution rebind、strict Workspace security、用户自定义 Host tools、plan progress/approval、custom UI、远程 artifact 发布、自动安装更新、独立 AgentCore Worker 和 Linux 接入均未进入当前产品，不能反向伪装成已具备。

具体验证矩阵见 [当前验证规范](validation.md)。

## 8. 待细化的产品问题

- Task 导出格式、敏感信息清理和重新导入语义；
- 多 Agent、子 Agent 和任务图在 UI 中的呈现；
- TerminalTool 是否进入后续正式产品范围。

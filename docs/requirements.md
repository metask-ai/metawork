# MetaWork 产品需求

> 状态：v0.5，确立登录优先的成熟 Workbench、Task 执行配置与设置边界
> 日期：2026-07-22

## 1. 产品定义

MetaWork 是一款桌面端 **Agent Workbench**。它帮助用户在本地工作区中创建和管理 Task，观察 Agent 推理后的可见工作过程，处理工具审批，并查看最终结果。

MetaWork 的核心不是模拟终端或展示 Agent 执行流水，而是让用户围绕 Task 提交要求、在必要时介入并读取回复与结果。底层 Run、Tool、usage 和恢复事实只在其产品用途需要时进入界面。

## 2. 产品目标

- 提供清晰、稳定的桌面 Agent 工作入口；
- 支持一个或多个工作区及其 Task；
- 以结构化 UI 展示 Agent 文本、工具调用、进度、审批和结果；
- 允许多个 Task 独立运行和切换；
- 在取消、刷新、关闭和异常后给出明确且可信的状态；
- 首次启动先完成 Metask 登录与可执行配置准备，再进入真实可用的 Workbench；
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

代表 Agent 工作所针对的本地目录和权限范围。Workspace 是独立产品对象，不得仅从已有 Task 的路径反向推导。Manual Workspace 由用户明确选择或重新授权，一个目录可以承载零个、一个或多个共享文件上下文的 Task；Automatic Workspace 由 Workbench 在调用方请求系统分配时创建，一个独立目录精确归属一个 Task。两者共用同一个 Workspace registry、Task 引用和 AgentCore admission，`kind` 只表达目录取得方式；Renderer 不得从路径或目录名推断 `kind`。Workspace 最终应成为文件访问、工具执行和 Task 归属的安全边界。当前同步 baseline 只在临时或用户明确 trusted 的 Workspace 中验证，不能据此宣称 strict Workspace security 已完成。

### Task 与内部 Agent Session

Task 是用户可持续补充的产品工作上下文，归属于 Workspace，拥有消息、运行状态、Run 历史、Session maintenance 历史和不含 secret 的 execution binding 历史。Task 的模型 binding 独立于 Account 默认模型：设置页模型只作为新建 Task 默认值，已有 Task 可在 Composer 选择下一轮模型。attached Task 在当前进程中持有一个内部 Agent Session 与 Conversation；Session 是执行生命周期术语，不是第二个产品对象或 Renderer 身份。Run、会改变 Conversation 的 maintenance operation 与 Conversation restore 共用一个 Workbench-owned active operation 槽，不能并发进入同一 Session。历史 Task 可以跨重启恢复为 detached 记录；只有 Host 证明最新 checkpoint、Task/binding、Workspace 与 ExecutionConfig 身份精确，且 persistence、checkpoint store 与 Agent Runtime 可用时，用户才能显式重建原 Conversation attachment。Skill、MCP 与 Permission authority 是否完整恢复只决定恢复后的能力状态；它们失效时接受 AgentCore 的 degraded Session 并安全收缩能力，不能否定 Conversation 恢复成功。

### Turn / Run

Turn 是用户提交的一次交互；Run 是 AgentCore 为该交互进行的一次实际运行。产品必须区分排队、运行、同步等待用户、已完成、已取消、失败和中断等状态。当前 ABI v1 提供的 `max_turns`、`tool_loop` 等受控停止不得伪装成完成或笼统失败；成本预算停止只有在 AgentCore 发布相应 typed capability 后才进入产品状态。

未来具备相应 AgentCore capability 后，再加入可恢复 `suspended`、持久化恢复和后台转换状态。

### Tool Call

代表 Agent 发起的一次工具调用，包含工具名、输入、进度、结果、错误和耗时。Tool Call 应通过结构化卡片展示，而不是依赖终端字符解析。

### Approval / UI Request

代表 Agent 继续工作前需要用户作出的选择。当前 MetaWork Agent 只开放同步工具 permission；AgentCore ABI v1 虽支持结构化问题回答，但该 built-in 不进入 MetaWork Agent 能力集合。需要补充信息时，Agent 以普通 Assistant 回复结束当前 Run，用户通过 Composer 继续。同步等待期间 Run 仍占用 executor slot，不形成可持久化挂起点。计划审批和自定义结构化交互只有在 AgentCore 发布相应控制协议并通过 MetaWork 产品验收后才进入产品范围。

### Account、模型连接与 ExecutionConfig

Account 是 MetaWork 的 Metask 账号控制面，负责 OAuth 登录、当前已验证 identity、Metask API Key/模型目录、凭据安全存储和默认执行配置代际。Account 同时拥有用户管理的 Model Connection registry；它与 Metask identity、OAuth 状态和 Metask catalog 独立，但使用同一条 Host-owned execution safety boundary。Account 发布一个当前默认 `ExecutionConfig`，来源可以是 Metask managed connection 或 user-managed Model Connection；配置包含 typed `provider_kind + model + base_url`、API credential 和 `execution_generation`，Workbench 为实际运行取得 owned copy。durable Task 与历史记录不是 Account identity、Model Connection identity 或 credential 的副本，只保存解释历史所需的 Workspace、provider、model、opaque execution generation 和 binding facts。

### Scheduled Task

Scheduled Task 是 Workbench-owned 的持久自动化定义，独立描述“做什么、何时触发”。Task 是一次真实执行及其结果历史，Schedule 是触发规则，Skill 是独立的可复用执行方法；Scheduled Task 不保存 Skill identity、catalog revision 或参数，也不是 AgentCore Session、交互式 Task 草稿、Skill 子对象或第二套 automation 数据面。用户需要采用某个全局 Skill 时可以在任务指令中表达，但 occurrence 始终按普通 Text Run 重新经过 Account、Workspace、容量和 shutdown admission，成功后创建一个新的真实 Task，再通过现有 bounded Executor 启动。每个 occurrence 都请求新的 Automatic Workspace，Scheduled Task 界面不提供 Manual Workspace 选择。Scheduled Task 只持久化无 secret 的指令、触发游标和有界 occurrence 事实，不持有 API Key；默认执行配置或 Workspace authority 变化时不得静默改绑或重放。

## 5. 产品功能需求

以下是目标产品需求，不代表当前 ABI v1 baseline 已全部实现。

### 5.1 工作区

- 用户可以选择并打开本地 Workspace；
- Host 校验并保存 Workspace 的规范路径；
- Workspace 记录 immutable `kind = manual | automatic`。Manual Workspace 可承载多个 Task；Automatic Workspace 精确归属一个 Task，两种 kind 不允许对同一 canonical root 相互转换；
- Application 只通过 Native SDK `.data` 目录规则解析 `<MetaWork data dir>/workspaces` 并向 Workbench 注入可用或不可用 capability；Renderer、Bridge payload、cwd、home 和环境 fallback 都不能决定托管目录根；
- 每个 automatic Task 使用 `<MetaWork data dir>/workspaces/<16 位随机小写 hex>` 独立目录，同一 Task 的后续 Run 复用该目录。分配必须 exclusive create、有界重试、校验 canonical containment；失败不能回退到共享目录；
- automatic root 及其子目录是保留命名空间，不能注册为 Manual Workspace；用户明确选择 automatic root 的祖先仍服从当前 trust 语义，不因此获得 strict isolation；
- Workbench projection 必须把 Workspace 作为独立对象发布，至少包含稳定 identity、kind、显示名称、规范路径、当前授权状态和可汇总的 Task 信号；每个被 Task 引用的 Automatic Workspace 必须出现在同一 canonical snapshot；
- 没有 Task 的 Manual Workspace 仍然存在于 New task 的路径选择器中；最近使用与重新授权不能依赖 Renderer 从 Task 列表猜测。Automatic Workspace 不进入普通选择器、recent 或重新授权入口，但其 owning Task 仍可导航；
- New task 路径控件负责选择、添加和重新授权；设置页不再承担 Workspace 生命周期管理。设置以覆盖 Workbench 内容区的长期 surface 呈现，保留窗口壳层和底层 Workbench 挂载，关闭后恢复原 Task、草稿、滚动和焦点；Renderer 不维护全局 active Workspace 镜像；
- 后台创建 Automatic Workspace 不修改 Manual Workspace recent order 或 Renderer New task draft scope；manual 与 automatic record 使用独立容量，后台 Task 不得耗尽用户打开 Workspace 的能力；
- automatic root 无法初始化时只关闭 `automaticWorkspaces` capability，并对 automatic admission 返回 typed unavailable；Account、显式 Manual Workspace 和普通 Workbench 仍可运行；
- bounded Task/Workspace 产品历史跨 Host 重启恢复，但恢复后的 Task 只读且不得伪造 Agent Session 或 Conversation；Run、Task 删除、shutdown 和重启后 Automatic Workspace 目录保留，但不扫描目录恢复或猜测 Task/Workspace，目录浏览和磁盘清理属于后续独立能力；
- 文件和工具能力最终必须受 Workspace 与显式权限约束；
- UI 能显示当前 Task 所属 Workspace；
- strict Workspace security 未验证前，产品必须明确限制使用范围，不能制造虚假的安全承诺。

### 5.2 账号、模型连接与执行配置

- 普通用户通过 Metask OAuth 登录，不需要手工填写 Provider、model、base URL 或 API Key；
- Metask managed connection 继续遵循 OAuth、API Key catalog 和 fixed provider/base URL 合同；用户管理的 Model Connection 不要求 Metask 登录，但必须先显式创建、验证并安装到 Host-owned execution registry；
- `AccountView` 只发布 Metask 的 `state`、`catalogState`、脱敏 identity/catalog/selection、generation、`canCancel`、`canCreateTask` 和稳定错误；Model Connection 以独立的脱敏 connection projection 发布，不把 custom connection 状态塞进 Metask OAuth 状态机；不得发布 saved-account、readiness、primary action、operation、execution state、mismatch 或 reauthenticate 状态机；
- `checking` 与 `authorizing` 可以暂时占用登录表面；`signed_out` 在没有 ready user-managed Model Connection 时禁止新 Task admission，但不隐藏 Workspace、durable Task 或历史记录。Model Connection 设置入口在 management、secure capture、连接测试等产品能力形成完整 gate 前整体隐藏；已有 live Task 仍必须可查看和停止；
- 登录无效即进入 `signed_out`。Renderer 只提供统一的 `beginLogin`，不保留“重新认证”“重新打开登录页”“匹配上次账号”等分支；
- OAuth 浏览器授权、identity 提交和执行目录准备不得暴露内部 C1/C2、operation、generation 或凭据存储步骤；
- OAuth 成功提交 token rotation 并以 `/me` 验证 authenticated identity 后，Host 必须以独立、有界的 continuation 自动加载 API Key 和模型目录。仍有效的历史选择优先恢复；没有历史选择时，唯一候选自动采用；只有多个候选且没有合同明确的默认项时才请求用户选择；
- 自动 continuation 不能把 C2 失败回滚成未登录，也不能根据显示名称、列表顺序或模型名猜测默认值、Provider 或 target；
- 没有可用 API Key 或模型时必须保持已登录状态，说明缺少什么并提供 `重试`；只有 Host 拥有固定、安全的 Metask 管理入口时才显示 `在 Metask 中管理`，Renderer 不拼接外部 URL；
- 登录、目录加载、模型加载和持久化是 Host-owned 操作。Renderer 只渲染 Host 发布的状态和脱敏候选，不通过 `useEffect`、隐藏点击或本地定时器推进产品状态；
- 账号入口固定显示在左栏底部：已登录时只显示当前 OAuth `/me` 严格验证的用户名，未登录时显示登录动作。接口不可用、账号不匹配或响应不可信时不得回退 token `account_id` 或旧 identity；不得由 Renderer 推断，也不得在普通 catalog refresh 或后台定时路径主动更新；
- Metask API Key 切换属于 `账号` 设置；Renderer 只显示 Metask 返回的脱敏名称、Provider 与尾号，API 创建、秘密查看和管理仍由 Metask 完成。用户管理连接的底层对象不复用 Metask API catalog；当前独立 `模型连接` 设置入口保持关闭，不能以不可完成的表单提前暴露；
- Model Connection 的最小产品对象是 `connection_id + display_name + provider_kind + normalized_base_url + credential_status + generation_readiness + latest_test_status + model_catalog + connection_generation`。generation readiness 与 `untested | testing | connected | failed` 最新测试状态必须分开；已验证 generation 的失败重测不能撤销正在使用的默认 execution。当前开放的 provider 只有 OpenAI Chat Completions 和 Gemini Native；Anthropic Messages 在 AgentCore 原生 `x-api-key` 合同通过前保持不可创建、不可恢复和不可选择。provider 由用户创建时明确选择，不能根据模型名猜测；
- 用户管理连接的 API credential 只由 Host 写入系统安全存储，metadata 以独立、无 secret 的 registry 原子持久化。Renderer 只能提交 connection mutation 和 opaque connection identifier，不能提交完整 credential、Authorization header 或把 arbitrary URL 直接注入 Run；
- 连接测试通过 Agent-owned Completion 发起一次有界的非流式请求，复用当前设置选择冻结的 ExecutionConfig，并由 MetaWork 的 Anthropic/OpenAI/Gemini 无 Tool codec 解析最终 JSON 响应；它不调用 AgentCore Completion，也不创建产品 Task、Run history 或持久 Conversation。第一版由用户明确提交 bounded model id，Host 保存其模型 metadata；自动模型发现不在当前范围；
- 当前模型必须显示在 New task Composer 附近，并显示为 `连接 · 模型`。默认连接/模型只影响后续新 Task；已有 Task 显示当前 binding epoch 的 provider、opaque execution generation 和模型，历史按 epoch 保留原事实，不提供虚假的 live Session 热切换；
- 进入 `账号` 设置时，显式导航动作自动请求 Host 同步 Metask catalog；未来重新开放 `模型连接` 设置时才读取 Account-owned registry，connection health 只由用户显式执行 `测试连接` 更新。已有默认配置必须直接投影，不能要求用户先重新选择或切换；
- 登录后无已存偏好时，Host 自动选择目录中的第一个 API Key 完成默认配置；选择 API 后模型按 当前已选（若仍在目录）→ 已存偏好 → 目录首项 自动回退，用户随后可在设置中调整。重配置中已选 API Key 从账号消失时不自动切换凭证，停在选择态由用户显式决定。离开设置页视为放弃未完成的重配置：Host 取消停驻事务并恢复原有执行配置；首次配置无可回退项时保持设置页驻留 API 才能修改默认模型。页面直接使用 Host 已发布的脱敏目录和提交态，手动重新同步只作为网络失败、页面持续打开期间 Metask 外部目录变化等恢复动作。设置页同时提供可独立修改的默认 API、默认模型和与错误语义匹配的恢复动作；后续通用、通知、外观和高级设置共享同一设置框架，Workspace 生命周期仍由 New task 路径控件负责；
- OAuth token 只访问 Metask 账号 API；选定 API Key 才作为 AgentCore 模型调用凭据；
- Renderer 只能看到脱敏账号、Key 尾号、模型、稳定错误码和状态，不得接触 OAuth token、完整 API Key、Authorization header、临时 OAuth URL 或凭据存储 locator；
- Account 只维护一个当前默认 ExecutionConfig，来源可以是 Metask managed connection 或 user-managed Model Connection；Workbench 可以在 live Session、Run、job 或 worker 中保留必要的 owned copy。切换默认连接、API 或模型不得篡改或停止既有运行；最后一个真实运行时引用释放后必须 secure-zero；
- durable Task 和 Run 不保存 account id、Metask API Key id/name/suffix、完整 custom credential、credential locator 或 Model Connection identity。恢复记录只保存 Workspace binding、provider、model、opaque execution generation 和其他无 secret binding facts；运行时配置不可恢复时必须显式进入 `runtime_detached`/恢复路径，不得伪造 Session、secret 或可继续执行能力；
- 显式重新登录、切换账号、退出登录或清除设备凭据必须取得 Workbench identity replacement gate，以串行化 Account 当前身份和 Metask-owned 默认执行配置的替换，但不得等待、终止或改写既有 Task、Session、Run、executor job 与 worker reference。既有 Task/Session 已拥有的 ExecutionConfig 继续按原生命周期收口；成功退出清除 Account-owned 设备凭据和 Metask 默认，不宣称撤销已经交付给 live Task 的运行时配置，也不得撤销独立的 user-managed Model Connection 默认。identity gate 覆盖完整异步身份尝试：token 提交前取消或失败保留旧 Metask 默认；verified identity、已提交 token 后的 terminal failure 或成功退出只提交 Account 自身结果，随后立即结束 gate。API/model catalog 与新默认 ExecutionConfig 使用独立的 default replacement transaction，不延长 identity gate。OAuth 成功后以本次 token 返回的 `account_id` 替换本机账号，旧缓存 identity 不得否决显式登录；
- refresh token 成功轮换后必须先原子提交新 token，后续 catalog 失败不得回滚到已作废的旧 token；明确鉴权无效关闭新的执行 admission，但已被 live Run 拥有的配置按其生命周期正常收口；
- New Task admission 必须满足以下任一执行来源：Metask Account `authenticated + catalogState=ready` 且 Workbench 已安装所选默认 generation，或 user-managed Model Connection `ready` 且 Workbench 已安装所选 connection generation；两者都要求 Workspace intent 可解析且 replacement gate 未开启。Automatic intent 要求 automatic root capability；Manual intent 要求目标 Manual Workspace grant 与 epoch 有效；
- production Account 接入必须符合 [Metask Account API 合同](metask-account-contract.md)，内部状态、事务和提交必须符合 [Account 内部架构](account-architecture.md)。C1 OAuth/login 先独立提交 token rotation，再以严格 `/me` 交付 authenticated identity；C2 使用无 Profile header 的 OAuth API Key catalog 与直接 API Key model catalog，并从精确 `group.platform` 形成 fixed ExecutionTarget。Account 提交 `execution_ready` 且 Workbench 安装同一默认 generation 前禁止创建新 Task，但不能隐藏 durable history；既有 live Task 的后续 Run 服从其已拥有的运行时配置，不与当前默认 generation 做错误等值比较。

### 5.3 Task

- New task 草稿始终属于 Workbench，但只有登录和执行准备完成后才能发送；Renderer 按 Workspace intent 隔离并可恢复。默认 intent 为 Automatic，界面显示“默认”，首次发送时才由 Host 创建 Automatic Workspace。用户可以在发送前切换到已授权或新选择的 Manual Workspace；
- New task 首次发送依次创建真实 Task 并启动第一个 Run，两步不能在界面中伪装成一个不可分失败状态：Task 创建失败或拒绝时留在 New task 并恢复原草稿；Task 已创建但 Run 启动失败或拒绝时进入该真实 Task、把输入恢复为 Task 草稿且不伪造已提交指令或 Running；命令 timeout 必须先刷新 canonical snapshot 决定实际页面和草稿 scope，不能自动重放可能有副作用的提交；
- 用户可以在 Workspace 中创建、切换、继续、归档和删除 Task；不存在独立的 Task `closed` 产品终态；
- 多个 Task 可以同时存在；
- 后台 Task 的运行状态不能因 UI 切换而丢失；
- 每条事件、审批和工具结果必须路由到正确 Task/Run；
- 每个 Task 在创建时记录无 secret 的 generation、Provider 与模型历史事实；不得固化 Account identity 或 API Key 元数据。全局默认变化不改写 Task 历史或 live Agent Session；
- 没有用户标题的 Task 在首个 Run admission 时立即使用旧的本地有界摘要作为临时标题，避免模型返回前退化为 identity 占位；Run 收口后再使用该 Task 已固定的同一 ExecutionConfig 通过独立 Completion 生成一个不超过 32 个 Unicode 字符的标题并替换临时值。该请求不创建 Session、Run history 或 Conversation，也不改变 Run outcome；失败、超时、拒绝或非法结果保留临时标题。用户在生成完成前后设置的标题都具有优先权，后台结果不得覆盖；
- 每个 Task 至多一个 active operation：当前可以是 non-terminal Run、manual compact 或 Conversation restore，包括 executor 中的 `queued` 状态；Run、compact 与 restore 互斥，当前 operation 结束前 Workbench 拒绝新的 Run、compact、restore 和其他 Session mutation，Renderer 只能保留未提交草稿；
- Renderer 产品合同为 `metawork.renderer-bridge` 固定 revision 1：`connect` 精确协商后才开放产品路径，snapshot 根节点由严格的无 secret `capabilities`、`account`、`skillCatalog`、`skillManagement`、`mcp`、`workspaces`、`scheduledTasks` 与 `tasks` 组成且不维护第二个局部版本；Account 发布脱敏 catalog selection identifier 与 generation，Workspace 由 Host 独立发布，Task 固化 binding epoch 与显示事实；Renderer 只为 New task draft 保存可空 Manual Workspace identity，Host 不发布全局 selected Workspace；`tasks.create` 提交严格的 `automatic | manual(workspaceId, expectedWorkspaceEpoch)` Workspace intent，Account、Workspace 和 Task mutation 均提交对应 expected generation/epoch，Host 重新校验 window、ownership、catalog membership 与 admission；快速开发阶段的合同内容直接原地 hard cut，不接受或双写被取代的临时 payload；
- 预期的 Task/Workspace admission 拒绝必须作为严格 typed result 返回并由 Renderer 映射为产品文案；非法 payload、伪造 ownership 与不可信 origin 仍 fail closed 为 Bridge error，不得把内部 error name 显示给用户；
- 当前固定 revision 1 合同原子提供独立 Workspace projection 与 Task execution binding。一次性目录能力必须由选择命令在 Host 内创建并消费，Renderer 不接收路径授权 token，不从 Task 反推 Workspace，也不能通过可选字段继续发送被取代的临时 payload；
- 产品 Task identity 由 Workbench 独立、稳定地分配；内部 Agent/Gate 原始事件使用单独的 Session route identity 做路由，两者不得复用或假定数值相等。Session route identity 不进入产品 snapshot，Renderer 始终只看到唯一的产品 `taskId`。
- credential 不得因 owner 释放而重新出现在任何 Renderer projection。Host 在安装新 credential 以及 secure-zero 旧默认或 Task-owned credential 之前，必须永久清洗既有 Workspace、Task、Run、tool 和 UI history 投影；同时存在前缀重叠 credential 时按最长匹配脱敏。

### 5.4 Agent 交互

- 用户可以提交文本输入并启动真实 Agent Run；
- UI 流式显示 assistant 文本；
- `thinking_chunk` 正文不进入 Assistant、Snapshot、持久历史或搜索；其事件类型只把当前安全状态细化为“正在思考”，`text_chunk` 到达后状态切换为“正在撰写回复”；
- UI 展示工具开始、进度、结果、错误和耗时；
- UI 展示 token usage、上下文警告、重试和压缩等可见状态；
- 用户可以在已有 finalized Run 且 Task 可继续时显式压缩当前 Conversation；manual compact 是 Workbench-owned Task maintenance operation，不创建 Turn/Run，不产生用户消息，也不把 `/compact` 原文送入 Bridge 或模型；
- manual compact 必须发布真实的 queued/compacting/stopping 与 terminal outcome；`compacted / no_change / degraded / aborted` 保持各自语义，before/after context token 只作为估算展示，compact provider usage 与 Run usage 分开记录；
- 用户可以取消当前 Run；
- 用户可以取消 active compact；Run 或 compact 的取消都必须等待 AgentCore 给出真实终止结果，不能只在 UI 中停止渲染。
- Application 重启后，满足恢复资格的 open Task 必须在 Composer 中提供显式“恢复对话”动作；点击左栏 Task 只负责导航和阅读历史，不得隐式恢复 Session、启动 Run 或重放任何输入；
- Conversation 恢复只从最新已提交 checkpoint 重建 Agent Session attachment。恢复完成前禁止新 Run 和其他 Session mutation；失败必须保留历史、给出稳定原因并仅在 Host 再次证明资格后允许用户重试。

### 5.5 审批与输入

- Agent Session 默认使用 `accept_edits`：只读操作与当前 Workspace 范围内的 Write/Edit 自动允许，Workspace 范围外的编辑及 Bash 等其他危险操作仍须明确授权；显式 ask/deny 规则继续优先且不得被该默认模式绕过；
- 用户可以回答 Agent 问题；计划批准或拒绝只有在 AgentCore 发布 typed control capability 后才显示；
- 审批和回答必须绑定 Task、Run 和请求标识，拒绝过期或重复响应；
- 同步等待必须支持 deadline、用户取消、Task close 和 Application shutdown 唤醒；
- 同步等待区间发生 Host/Core crash 后，Run 标记 `interrupted`，工具不得自动执行；
- 目标产品支持用户主动创建和撤销 Host-owned 持久权限规则，但 UI 只能在 Host 声明当前请求可形成安全、范围明确的规则时显示 `Always allow`；
- 持久规则必须绑定稳定 Workspace identity、tool identity 与版本、operation 和规范化资源约束，并定义 Workspace、tool、脚本内容或安全能力变化时的失效规则；
- strict Workspace security 和对应规则匹配/审计能力未通过验证前，不得开放 Workspace 级文件规则；受控进程、process tree、network 和 environment 边界未通过独立验证前，不得开放项目脚本、Bash、Network 或 `Full access` 持久授权；
- async pending、跨重启恢复和 subagent suspend 只有在 AgentCore 发布明确 capability 后才能进入产品范围。

### 5.6 命令执行

- 普通 shell 命令以非交互子进程执行；
- UI 展示命令、stdout、stderr、exit code、耗时和错误；
- 普通命令不弹出 Terminal 窗口，也不依赖 PTY/ConPTY；
- 当前阶段明确拒绝或限制需要 TTY 的交互式程序。

### 5.7 状态与恢复

- 每个 Account attempt 必须拥有 Host deadline，并最终进入成功、可重试失败、用户取消或明确失败；浏览器未回调、网络悬挂、worker 启动失败和 completion/notification 异常不得永久保留 active operation；
- OAuth 等待超过正常感知时长时，界面只提供 Host-owned `取消登录`；Renderer 不接触授权 URL。目录等幂读取和已保存 refresh token 的瞬时失败可以有限重试，OAuth code exchange、持久化 mutation 和其他结果不确定操作不得盲目重放；
- Bridge command 或 view refresh 超时必须释放 Renderer 本地 busy 状态并进入 snapshot resync；结果不确定的 mutation 只能依据 Host snapshot 决定后续动作，不能由 Renderer 自动重复；
- Account cancel 是独立逃生动作，不能因普通 mutation busy 被禁用；但 credential persistence 一旦开始提交就跨过取消边界，Host 必须暂时撤销 cancel 并等待唯一 terminal completion，不能在磁盘已提交、main-thread completion 尚未消费的窗口把内存回滚到旧 generation。Bridge 暂不可用时 Host deadline 仍必须收口 attempt，Renderer reload 后从 snapshot 恢复可用动作；
- 用户消息、已完成 assistant 消息、工具结果、审批决策、关键 Run 状态和改变 Conversation 的 manual compact 应形成可靠状态边界；Run/compact admission 必须先建立稳定的 Workbench record，terminal payload 一经发布不可变，内部 Agent Session 关闭或销毁后 Task 历史仍可独立生成 snapshot；compact history 有界且 append-only，容量耗尽时拒绝新 compact，不覆盖既有 Conversation 边界；
- 当前 baseline 的 Renderer reload 只能从仍存活的 Host 恢复视图；
- Host 或 AgentCore 进程退出时，当前同步 Run 标记 `interrupted`，不得伪装完成；
- 崩溃后不得自动重放可能产生副作用的工具；
- AgentCore checkpoint export/restore 已接入 Application 重启后的 Conversation 恢复；它不是 transcript 重放，不恢复 checkpoint 之后未完成的 Run，不自动重放工具、permission 或结果不确定的 mutation；
- async pending、可恢复 suspend/resume、独立 AgentCore Worker crash recovery 和跨进程 in-flight Run 恢复仍属于后续 capability；
- 成本预算、轮数上限或工具循环熔断后，Task 进入等待用户状态，只有用户明确继续后才创建新 Run。

### 5.8 桌面能力

- 提供窗口与应用生命周期管理；
- 一体化标题栏由 Renderer 绘制窗口按钮并提交固定语义意图，Bridge 校验 transport authority 后交由 Application 通过 Native SDK Runtime API 或已登记 Native Compat seam 执行；Renderer 不持有原生窗口 identity、handle 或执行权；
- 提供受控的文件/目录选择；
- 为通知、更新和系统集成保留明确入口；
- Renderer 只能调用 Host 显式开放的领域命令。

### 5.9 Workbench 界面与任务组织

- 未登录只禁止创建和发送新 Task；Workbench 仍展示 Workspace、durable Task 与执行历史，并允许查看和停止真实 live Run；默认执行配置 ready 后才开放 Composer admission；
- Workbench 左栏承担稳定 New task、已接通的全局能力入口、全局 Task 列表与左下角账号入口；`新建任务`、`技能`、`MCP` 与 `定时任务` 使用同一紧凑一级菜单的相同行高、缩进和 active 语义，不用额外留白或独立大按钮制造虚假层级；只有真实接通的 capability 才显示对应入口，Task 按 `需要处理 / 正在运行 / 最近` 等行动优先级组织；
- New task 中央区域始终以 Composer 为主，当前模型和 Workspace 在发送前可见；API 管理不进入 Composer，模型与 Workspace 也不得混成不透明的单一“模式”；
- Task 启动后中央区域显示该 Task 的用户输入与 Assistant 回复，Composer 固定在底部；当前 Run 只追加一个临时 canonical 状态，待处理请求在回复之后、Composer 之前提供唯一操作面，terminal outcome 只在影响理解或恢复动作时出现。工具详情和 usage 不进入主阅读流，只决定按需 Task overview 是否有对应内容；普通 Run 开始或结束不自动开合 overview，只有新的待处理请求可以自动打开一次；
- `queued / running / waiting_user` 的停止入口位于 Composer 的发送位置，并替换发送按钮；标题栏不重复提供 Task Stop。Composer 仍只保存本地草稿，停止请求必须等待 canonical terminal，transport acknowledgement 或 UI 状态变化都不能伪造 `Stopped`；
- 标题栏只承载 Renderer 绘制的窗口按钮、当前 Task 名称、搜索与异常状态等全局入口；不重复说明 Task 的 Workspace，正常连接状态、语言选择和工程诊断也不长期占据主视觉；
- 界面在任一时刻只突出一个与当前阶段一致的主动作；独立的导航和设置入口可以持续可见，但不得与主动作竞争；
- 首个正式版本采用单主窗口；多个 Task 可以后台运行，切换 Task 不停止执行；
- Renderer reload、断开连接以及 Bridge revision/snapshot failure 默认只影响视图同步和重连，不得终止后台 Agent Run；只有 Workbench 根据 canonical 产品状态作出的显式 termination 决策才能请求结束 Run；
- 左栏直接列出 canonical snapshot 中 owning Workspace 仍被投影的全部 Task，不提供全局 Workspace 切换器；每个 Task 的路径由自身上下文决定，后台请求不能因路径不同而从导航中消失。已移除 Workspace 的历史 Task 仍由 Workbench 保存，但随 Workspace 退出活动导航，重新授权恢复同一稳定 Workspace identity 后才重新出现；
- Task 是可持续补充、归档和删除的产品对象；Task lifecycle、当前 Run phase 和最近一次 Run outcome 是三类独立状态，Renderer 只能从 Workbench projection 派生展示标签；
- 中间区域不按 Run/Tool 结构组织内容，不展示 Tool 调用、usage、Run ID、raw AgentCore event 或 chain-of-thought。`assistant` 只表示 Assistant 回复，Renderer 不把它提升为 Delivery、Output 或最终成果；完成、失败、中断与恢复动作只依据独立 canonical outcome/cause；
- Run 执行期间的新输入不得暗示可以修改当前 Run；首版只保存 Renderer 草稿，等待当前 Run terminal 后由用户明确发送，不自动创建或启动下一次 Run；
- Composer 以 `/` 作为 context-aware 发现手势，统一显示 Renderer 注册的产品 Command 与当前 Workspace/Task catalog 投影的 Skill；Slash 文本本身不是 Agent 输入协议，Command 必须在 Renderer 消费且不得进入 Bridge、Task 历史或 AgentCore；
- Command 只复用已有产品动作，不迁移 CLI/TUI 的会话控制语义；V1 只注册 `/new` 与 `/compact`，前者打开既有 New task draft action，后者触发 Workbench-owned typed maintenance action；不注册 `/model`、`/status`、`/goal`、`/resume`、`/continue` 或其他已有正式界面、与桌面产品对象冲突、缺少 typed capability 的 identifier；
- Skill 选择形成单一、可移除的 typed Composer draft，同时保留稳定 Skill identity、catalog revision、selection revision 和 positional arguments；New task 使用 Workspace current catalog 与 current committed selection，已有 Task 使用其 pinned catalog 与 pinned selection。任一 revision 过期、Skill 已禁用或不可用时保留参数但禁止发送，必须显式刷新并重新选择，Renderer 不读取 Skill body、不猜测目录或权限；
- Skill 中心是 MetaWork 级的本地 Skill 管理 route，不跟随当前 Task 的路径上下文。它按个人与已注册 Manual Workspace 的项目范围展示 Skill 资产，并把需要处理的定义错误、资源错误和冲突置于正常 Skill 之前；用户可以搜索、查看说明/参数/资源/健康状态，从本地 `.skill`、`.zip` 或目录导入，导出 `.skill`，重新导入，卸载并显式刷新 catalog。Personal 列表的开关定义所有项目继承的用户默认值；Manual Workspace 项目列表以 `inherit | enabled | disabled` 三态覆盖该默认值，清除覆盖后重新跟随用户。当前 AgentCore `skill_id` 被视为逻辑调用身份，同 invocation 的 Personal/Project Skill 共用策略键，invocation 改名后策略不跟随；MetaWork 不猜测未公开的来源身份。当前不提供在线市场、远程更新、Skill 创建/编辑器、Preset、标签、排序、中央仓库或多 Agent 同步；
- Skill 管理资产与运行时 catalog 是两份不同真相。Workbench 拥有本地 package/inventory、安装 provenance、目标范围、安全文件事务和管理状态；AgentCore 继续独占 runtime discovery、canonical priority、winner/conflict、health 与 catalog revision。MetaWork 使用独立 `install_id` 管理资产，运行时身份仍是 `catalog_scope_id + skill_id`；Renderer 不从名称、路径或 invocation 猜测来源、范围、优先级或身份。MetaWork 未能在已授权 canonical Skill root 中解析并取得精确管理 authority 的现有 Skill 仍可按 AgentCore projection 展示，但必须标记为外部管理，隐藏导出、重新导入和卸载；
- Skill 启用状态是 Workbench-owned 的 User/Manual Workspace policy，默认启用，只持久化 disabled `skill_policy_key` 与 Workspace override，以及单调 `selection_revision`；持久键精确使用 User policy 或 `workspace_id + workspace_epoch + skill_policy_key`，不使用易随内容变化的 concrete `skill_id`。mutation 同时校验 Workspace epoch、catalog revision 和 selection revision，成功后只影响对应 current policy；已经创建的 Task/Session 不热替换，只有 idle Task 显式刷新才采用新 policy。Host 重启恢复 Conversation 时不查询或隐式重绑 Skill catalog，恢复后的 Task catalog 为 uninitialized；Manual Task 只有在 idle 状态显式刷新后才采用 Workspace 当前 catalog 与 committed policy，Automatic Task 保持 Text-only；
- 本地导入必须由 Host 原生文件/目录选择产生的一次性、window-bound staged capability 发起；Renderer 不提交任意物理路径。导入在目标范围外完成有界解压、路径/类型/容量检查和只读预览，经用户确认后原子发布到个人或指定 Manual Workspace 的 `.agents/skills`。明确属于候选 Skill 的 AgentCore definition/resource/conflict failure 必须回滚；catalog 暂时无法完成验证时保留已发布资产并进入 `pending_verification`，不能伪装成可用。替换或卸载不得与可能消费该范围的 active operation 并发，不得静默覆盖现有目录，并必须保留可恢复的事务前副本直到提交完成；
- 用户创建或修改 Skill 仍通过普通 Text Run 与 AgentCore built-in Read/Edit 完成，不在 Skill 中心建立第二个创作或文件编辑器。Workspace 内的 `.agents/skills` 服从现有 Workspace authority；用户级目录只有在用户明确将目标 Skill 目录作为 trusted Workspace 授权后才能修改。Skill 中心可以导航到预填的普通 Text draft；项目 Skill 创建完成后通过显式 catalog refresh 出现，个人 Skill 通过受控本地导入发布。一次 Run 使用已绑定 snapshot，不热替换正在执行的 Skill；文件变化只在显式 catalog refresh 后影响后续选择与 Run；
- Host 重启后恢复的历史 Task 先以 detached、可阅读状态出现；满足恢复资格时，用户选择左栏 Task 只看到已保存产品历史与普通 Composer，不显示恢复卡片、恢复按钮或专用 placeholder。用户首次发送新消息时，Renderer 在同一次发送意图内先提交 restore，等待 Host 确认 attachment 后再精确提交一次 Text Run；失败时保留草稿并显示可执行的失败说明，下一次普通发送可以重试。只有 source Task/binding、checkpoint ownership、Workspace/Task identity、Conversation、terminal state 与当前 execution target readiness 均可安全恢复后才允许该内部前置步骤；Skill/MCP/Permission continuity 缺失只产生 degraded 能力状态。历史 execution generation 不要求等于当前 generation：同 provider 且当前 authority 可承载 Task model 时，restore 必须以 durable adoption 同步推进 Task generation、binding epoch 与 checkpoint anchor 后再安装 attachment，并保留旧 Run 的逐 Run provenance。该窄 adoption 只连接同一 Task 的 source Conversation 与当前可执行 target，不允许切换 provider/model，也不构成通用 rebind；任意配置 rebind 或从历史创建新 Task 仍属于后续显式产品能力，当前实现不得用它们冒充恢复；
- `Files changed` 表示实际文件变更集合，`Outputs` 表示用户关心的交付结果，两者不得用“新建文件”自动等同；当前 ABI v1 未提供这两类 typed event 时，相关模块必须隐藏；
- Task 归档只隐藏日常列表且可恢复；归档、删除 Task 或移除 Workspace 前必须先终止其 queued/running/waiting/stopping Run。删除只允许已归档 Task；Workbench 接受一次删除意图后负责收口仍存活的 Session，并在 executor stable record reference、checkpoint 与全部资源 quiescent 后原子提交和物理释放，不要求用户为正常推进重复提交。删除进度以 runtime-only 的 `idle | deleting | failed` 产品事实发布，不持久化、不混入 Task lifecycle 或 Agent Session 状态；明确失败必须保留归档 Task 并等待用户显式重试，不能伪造成功、静默回弹或自动形成重试循环。若失败后 attachment 已恢复到可用状态，用户显式恢复归档表示放弃该次删除，Workbench 必须把删除状态原子重置为 `idle`；仍在 closing 的 Task 不开放恢复归档。删除 Task 记录不删除 Workspace 中的真实文件；移除 Workspace 先原子进入 `removing` 并推进 Workspace epoch、拒绝新 admission，全部 Task 收口后撤销当前 Host authorization 并退出活动导航；
- 全局搜索覆盖 Task、用户指令、完成消息和 Output 文件名；Workspace 只作为 Task 与 New task 的路径上下文，不作为独立导航结果；工具原始日志默认不进入普通搜索；
- `en-US` 是规范产品文案和回退语言，`zh-CN` 是首个完整 locale；Host 传递 structured code 与参数，Renderer 负责本地化。

### 5.10 MCP 服务

- `MCP` 是与 `新建任务`、`技能`、`定时任务` 同级的 MetaWork 全局页面，不跟随当前 Task 或 Workspace，左栏入口稳定显示。`capabilities.mcpManagement` 只声明 revision 1 的 typed 管理合同是否真实接通，不与 Runtime 是否 ready、registry 是否为空或管理事务是否暂时冻结做等值判断；`mcp.availability` 独立表示当前 Runtime/catalog 可用性。
- 成熟接入范围固定为 STDIO 与 Streamable HTTP、Tools，以及 `none | static | oauth` 三类授权。OAuth 只适用于 Streamable HTTP；STDIO 的 static credential 只经显式 environment name 注入，HTTP static credential 只经显式 header name 注入。Host 只允许 AgentCore 使用 `2026-07-28`、`2025-11-25` 与 `2025-06-18` 三个 exact era；显式 `modern_only` 与 `compat_only` 分别固定前两个，`automatic` 可以协商并 exact reopen 到三者之一。其他版本、legacy SSE、Resources、Prompts、Apps 与 Tasks 一律拒绝。MCP era 不构成旧 AgentCore ABI revision 的兼容路径。用户显式提交 Add/Replace 就是对该完整连接的授权：新 server 默认 enabled、connection-approved 且 tool allowlist 为空，新发现 tool 也默认不扩权。用户可以在详情中对当前已发现的工具做一次显式批量放行；该动作仍是全量 allowlist 重提交，且此后新发现的工具依旧默认排除。schema 1 迁移产生的 unapproved server 仍保留一次 legacy connect 动作，不让普通新建流程重复审核用户刚提交的配置。
- 添加服务是 transport-discriminated 的 typed 流程，不是 generic upsert。STDIO 配置只接受可执行文件、argv、可选 cwd、environment name 与对应 secret slot；不提供 shell string、命令替换、credential argv 或整个进程环境继承。Host 只从启动环境复制非敏感 executable search path，并在绝对 command 前置其所在目录，以支持 `/usr/bin/env` shebang 和 bare executable lookup；该 `PATH` 与 Windows `SystemRoot` 是不可由用户 environment slot 覆盖的受控基线，其他变量一律不继承。Streamable HTTP 配置只接受 endpoint、auth mode 和有界 header name；endpoint 只允许原始 authority 被完整、无歧义解析的 HTTPS 或精确 loopback HTTP，禁止 userinfo、query、fragment、authority percent encoding、空白、控制字符和反斜杠。Renderer 可以提交被视为公开文本的配置，但 secret 没有 Renderer/Bridge 数据路径；static secret 与 OAuth client secret 只能由显式 Host secure-capture capability 直接写入独立系统 credential service。该 capability 只控制安全采集动作是否可用，不决定 static/OAuth 配置能否被表达；不存在时相关动作隐藏，服务保持可修复的缺失授权状态。
- 连接信任不建立独立于配置提交的常规审核步骤。Add/Replace 的确认按钮绑定 transport、endpoint 或 command/argv/cwd、environment/header name、auth mode 与协议策略，并在同一个 Desired Registry transaction 中写入 connection fingerprint；在用户提交之前不得启动 child、读取 credential、发网络请求或打开 OAuth browser。OAuth consent 仍是独立安全边界：connection-approved 后才执行无凭据、有界 discovery；本版 registration plan 明确为用户提供 client id 与 `none | client_secret_basic | client_secret_post` token endpoint auth method 的 `pre_registered`，或 authorization server metadata 明确提供 endpoint 时的 `dynamic_registration`，前者需要的 client secret 走 Host secure capture。DCR confidential result 只有在 `client_secret_expires_at` 缺失或为 `0` 时才能进入现有 client-credential revision；非零 expiry 在没有 secret renewal owner 的本期必须按已可能产生远端 client 的 outcome unknown 收口。OAuth Consent 绑定 connection approval、canonical resource、exact issuer、requested scopes、redirect identity、registration kind、client identity 与 client-credential revision；callback 必须校验 state、PKCE S256、redirect identity，并按 2026-07-28 规则对出现的 `iss` 做 exact comparison。
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
- 创建流程按名称、任务说明、运行时间和确认摘要排列；不提供 Workspace 或 Skill 配置、catalog revision 或参数配置，不得让空页面先暴露 provider、generation、Unix seconds 或固定间隔秒数等工程字段；
- 首版支持一次性、每小时、每日、每周和由明确起点开始的固定间隔；Host 保存 canonical Unix time、locale-independent recurrence 与创建时 timezone identity，Renderer 只负责本地化显示和结构化编辑，不用本地 timer 推进产品状态；
- 每次自动或手动触发创建一个新的真实 Task。计划定义不复用旧 Conversation、不把结果复制成第二份聊天历史，也不绕过既有 Task/Run admission；
- 同一 Scheduled Task 的上一次 Task 仍有 non-terminal Run 时，自动触发必须跳过本次；不得并发重放同一计划或自动终止已有 Run；
- 自动触发使用 `(scheduledTaskId, plannedAt)` 形成跨 Host 恢复稳定的 occurrence identity；后台 Host 延迟、休眠或重启恢复时最多接纳一个最新的到期 occurrence，过去的多个时间点不批量补跑，并在 occurrence history 中明确标记 delayed/skipped；
- Scheduled Task 定义、触发游标和有界 occurrence history 由 Workbench 在产品数据目录原子持久化；损坏、commit 结果不确定或恢复校验失败必须 fail closed 并发布 typed persistence health，不得回退成空列表或继续使用可能重复的游标；
- 主窗口关闭使用后台/托盘形态而不是销毁 Host；后台 Host 继续 timer、Run、通知与待处理事实，托盘提供重新打开和显式退出。显式退出可以停止本机后台执行，但下次启动仍恢复定义并执行上述单次 missed-run reconciliation；
- 执行配置、Workspace authority、容量或 shutdown gate 不再满足时，计划进入明确的 `needs_attention`，停止继续计时并保留 typed 原因；用户必须编辑并确认当前事实后才能恢复；
- Scheduled Task 和 occurrence 不保存 credential、Authorization header、OAuth URL 或 AgentCore handle；计划标题和 Text instruction 进入产品 projection 前执行与 Task history 相同的有界复制和 credential 清洗；
- occurrence 完成、失败、跳过或等待用户时进入有界历史并发出系统通知；通知点击只定位真实 Task/请求，不携带 secret 或建立第二状态面；通知不可用不得改变 Run terminal cause；
- AgentCore 只执行被 Workbench admission 后的单次 Run，不拥有 cron、时钟、timer、OS wake 或 Scheduled Task persistence。

## 6. 非功能需求

### 安全

- Renderer 按不可信调用方处理；
- Host 命令默认拒绝，只开放白名单；
- 校验来源、payload、Workspace、Task/Run 归属和权限；
- production 执行配置只由 Account 生成并由 Application coordinator 在主线程一致性提交链中安装到 Workbench；禁止环境默认值、Renderer 字段或 Bridge payload 直接注入 provider/base URL/credential。Renderer 只可提交 Account 当前脱敏 catalog 或 Model Connection projection 中的稳定 API/model/connection identifier，Account 必须重新校验并从对应锁定合同生成配置；
- Provider credential 不得进入 Renderer、Bridge、日志、事件或视图 snapshot；
- OAuth token、PKCE verifier、authorization code、完整 API Key 和 Authorization header 必须使用单 owner secret buffer，所有失败、取消、过期 completion、replacement 和 shutdown 路径都先不可消除地清零再释放；
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
- macOS 分发默认从两个固定 canonical AgentCore target store 依次生成 arm64 与 x64 DMG，也允许显式只构建其中一个；发布架构不能由上一次 stage 的隐式状态决定，两份 target-specific 产物独立锁定和验证，当前不建立 Universal 包；
- macOS 真实 Account 本地开发必须使用 Apple 签发、带稳定 `TeamIdentifier` 的 `Apple Development` identity；自签名或 ad-hoc 签名不能作为 Keychain 跨构建授权稳定性的验收结果；
- Windows development baseline 已完成独立 artifact、Native SDK、Bridge、AgentCore 和桌面自动化验证，不能用 macOS 结果替代；
- Windows 已提供按用户安装的 Inno Setup 单 EXE、显式 Authenticode 签名与静默安装/卸载验收路径；MSI、自动更新、交互式 Windows 10/11 和完整安全矩阵仍是后续分发交付；
- Linux 是后续目标平台；当前 bundle target-policy 和系统链接输入按 target 隔离，但不宣称已完成 Linux 构建或验收；
- 对进入验证范围的平台形成可复现的开发构建与可运行产物路径；进入分发阶段后再要求可分发包路径。

## 7. 当前交付层级

### 7.1 同步 macOS baseline

当前首先交付：

```text
临时或 trusted Workspace → Task（持有内部 Agent Session）→ 用户输入 → 同步 Agent Run
→ 文本流 → built-in Read/Bash/Edit → 同步 permission / question
→ 工具结果 → 最终回复 → 取消/关闭 → Renderer reload 视图重建
```

它不包含进程恢复、async suspend/resume、strict Workspace security 或产品 Host tools。

### 7.2 Account- and connection-integrated macOS 目标

下一阶段在不改写既有 baseline 证据的前提下增加：

```text
Metask 登录或配置用户模型连接 → Host 后台恢复/验证 API、credential 与模型
→ 仅在真实歧义时请求默认连接/模型 → ready ExecutionConfig
→ 进入 Workbench → 选择 Workspace / 编辑 New task 草稿
→ Composer 确认模型 → Task admission → 既有同步 macOS baseline
```

Metask C1 OAuth/login 已按 `metawork-app` / `metawork:use` 发布合同锁定；C2 使用已通过 production 复核的无 Profile-ID 通用路径。登录先提交 token rotation，再严格验证并提交 `/me` identity，随后直接启动 API Key/model catalog continuation；C2 失败不得抹除已完成登录。用户连接使用独立的 typed provider/endpoint/credential 流程，不依赖 OAuth，但必须通过 Host/AgentCore streaming test。Workbench 的新 Task admission 以完整 `execution_ready` 或 ready Model Connection 为条件，不能把仅有 authenticated identity 或未验证的连接误报成已经可以执行。

### 7.3 Fault-domain 结论

事件泵数据、生命周期压力测试和同进程/最小 Worker fault-domain spike 已完成。结论是选择单 AgentCore Worker 作为后续正式故障域；当前应用仍是同进程 prototype，正式 Worker、跨进程恢复和危险工具重放策略不属于当前交付。

### 7.4 Windows 接入 baseline

Windows x86_64 GNU 的当前 target availability 与 exact artifact identity 以 [AgentCore ABI v1 消费合同](agentcore-abi-v1.md)为准；是否形成与 macOS 同一产品语义的开发可执行 baseline，以 Native Debug/Release、真实 AgentCore vertical 和干净退出验收为准。精确 bundle、Renderer 与 MetaWork 平台无关测试通过不能替代这些平台证据。

### 7.5 后续产品能力

async pending、更完整的跨重启 execution rebind、Personal Skill 全局启用 policy、strict Workspace security、正式 Host tools、远程 artifact 发布、Windows 分发交付和 Linux 接入按独立 capability 与阶段推进，不能反向伪装成当前 v1 已具备。

具体验证矩阵见 [当前验证规范](validation.md)。

## 8. 待细化的产品问题

- Task 导出格式、敏感信息清理和重新导入语义；
- 多 Agent、子 Agent 和任务图在 UI 中的呈现；
- TerminalTool 是否进入后续正式产品范围。

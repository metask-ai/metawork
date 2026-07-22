# MetaWork 产品需求

> 状态：v0.5，确立登录优先的成熟 Workbench、Task 执行配置与设置边界
> 日期：2026-07-21

## 1. 产品定义

MetaWork 是一款桌面端 **Agent Workbench**。它帮助用户在本地工作区中创建和管理 Task，观察 Agent 推理后的可见工作过程，处理工具审批，并查看最终结果。

MetaWork 的核心不是模拟终端，而是把 Agent 工作表达为结构化的产品界面：消息、工具卡片、审批、任务状态、文件变更、错误和工作产物。

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

代表 Agent 工作所针对的本地目录和权限范围。Workspace 是独立产品对象，不得仅从已有 Task 的路径反向推导；即使尚无 Task，也应能保存、选择、移除和表达授权状态。Workspace 最终应成为文件访问、工具执行和 Task 归属的安全边界。当前同步 baseline 只在临时或用户明确 trusted 的 Workspace 中验证，不能据此宣称 strict Workspace security 已完成。

### Task 与内部 Agent Session

Task 是用户可持续补充的产品工作上下文，归属于 Workspace，拥有消息、运行状态、Run 历史和不含 secret 的 execution binding 历史。每个 live Task 在当前进程中持有一个内部 Agent Session 与 Conversation；Session 是执行生命周期术语，不是第二个产品对象或 Renderer 身份。历史 Task 可以跨重启恢复为只读记录；跨进程 Conversation 恢复或安全重建属于后续能力，未通过验收前不得显示虚假的“继续此 Task”。

### Turn / Run

Turn 是用户提交的一次交互；Run 是 AgentCore 为该交互进行的一次实际运行。产品必须区分排队、运行、同步等待用户、已完成、已取消、失败和中断等状态。当前 ABI v1 提供的 `max_turns`、`tool_loop` 等受控停止不得伪装成完成或笼统失败；成本预算停止只有在 AgentCore 发布相应 typed capability 后才进入产品状态。

未来具备相应 AgentCore capability 后，再加入可恢复 `suspended`、持久化恢复和后台转换状态。

### Tool Call

代表 Agent 发起的一次工具调用，包含工具名、输入、进度、结果、错误和耗时。Tool Call 应通过结构化卡片展示，而不是依赖终端字符解析。

### Approval / UI Request

代表 Agent 继续工作前需要用户作出的选择。当前 ABI v1 只提供工具 permission 和问题回答，并使用同步 request/response；等待期间 Run 仍占用 executor slot，不形成可持久化挂起点。计划审批和自定义结构化交互只有在 AgentCore 发布相应控制协议后才进入产品范围。

### Account 与 ExecutionConfig

Account 是 MetaWork 的 Metask 账号控制面，负责 OAuth 登录、账号/API Key/模型目录、凭据安全存储和默认执行配置代际。API Key 是低频账号资源，模型是创建 Task 时必须可见的执行上下文。Account 发布一个当前默认 `ExecutionConfig`，包含 typed `provider_kind + model + base_url`、API Key 和 `execution_generation`；Workbench 在 Task 创建时取得 owned copy，建立第一个 execution binding epoch，并把不含 secret 的 account/profile、generation、API/Provider 与模型事实固化到 Task。后续默认 API 或模型变化默认只影响新 Task admission，不静默修改既有 binding epoch；既有 Agent Session 继续使用当前 epoch 的配置，直到其全部 Task/Run/Session 引用安全释放。只有 §5.2 定义的显式历史 rebind 可以为既有 Task 创建新 epoch。

## 5. 产品功能需求

以下是目标产品需求，不代表当前 ABI v1 baseline 已全部实现。

### 5.1 工作区

- 用户可以选择并打开本地 Workspace；
- Host 校验并保存 Workspace 的规范路径；
- Workbench projection 必须把 Workspace 作为独立对象发布，至少包含稳定 identity、显示名称、规范路径、当前授权状态和可汇总的 Task 信号；
- 没有 Task 的 Workspace 仍然存在于切换器与设置中；最近使用、重新授权和移除不能依赖 Renderer 从 Task 列表猜测；
- 文件和工具能力最终必须受 Workspace 与显式权限约束；
- UI 能显示当前 Task 所属 Workspace；
- strict Workspace security 未验证前，产品必须明确限制使用范围，不能制造虚假的安全承诺。

### 5.2 Metask 账号与执行配置

- 普通用户通过 Metask OAuth 登录，不需要手工填写 Provider、model、base URL 或 API Key；
- 未登录时不进入 Workbench shell。首次启动只突出 `使用 Metask 登录`，Workspace、Task 列表、Composer 和空的活动面板不得提前伪装成可用产品；语言、诊断和退出等辅助入口可以低权重存在；
- OAuth 浏览器授权、登录恢复和执行目录准备构成同一个可恢复的首次启动流程，但不得暴露内部 C1/C2、operation、generation 或凭据存储步骤；
- OAuth 成功提交 `account_only` 后，Host 必须以独立、有界的 continuation 自动加载 API Key 和模型目录。仍有效的历史选择优先恢复；没有历史选择时，唯一候选自动采用；只有多个候选且没有合同明确的默认项时才请求用户选择；
- 自动 continuation 不能把 C2 失败回滚成未登录，也不能根据显示名称、列表顺序或模型名猜测默认值、Provider 或 target；
- 没有可用 API Key 或模型时必须保持已登录状态，说明缺少什么并提供 `重试`；只有 Host 拥有固定、安全的 Metask 管理入口时才显示 `在 Metask 中管理`，Renderer 不拼接外部 URL；
- 登录、目录加载、模型加载和持久化是 Host-owned 操作。Renderer 只渲染 Host 发布的 readiness、当前可用动作和脱敏候选，不通过 `useEffect`、隐藏点击或本地定时器推进产品状态；
- 首次 readiness 完成后才进入 Workbench；账号身份固定显示在左栏底部，点击后进入账号与模型设置、重新认证或退出，不能再次隐藏到 Composer prerequisite；
- API Key 切换属于 `账号与模型` 设置。Renderer 只显示 Metask 返回的脱敏名称、Provider 与尾号；API 创建、秘密查看和管理仍由 Metask 完成；
- 当前模型必须显示在 New task Composer 附近，并可从当前 API 的已验证模型目录快速选择。该选择更新后续新 Task 的默认执行配置；已有 Task 显示当前 binding epoch 的模型，历史按 epoch 保留原事实，不提供虚假的 live Session 热切换；
- 设置页同时提供默认 API、默认模型、目录刷新和与错误语义匹配的恢复动作；后续通用、Workspace、通知、外观和高级设置共享同一设置框架；
- OAuth token 只访问 Metask 账号 API；选定 API Key 才作为 AgentCore 模型调用凭据；
- Renderer 只能看到脱敏账号、Key 尾号、模型、稳定错误码和状态，不得接触 OAuth token、完整 API Key、Authorization header、临时 OAuth URL 或凭据存储 locator；
- Account 只维护一个当前默认 ExecutionConfig，但 Workbench 可以保留被既有 Task 引用的旧 generation owned copy。切换默认 API 或模型不得篡改、停止或重新配置既有 Task；旧 generation 只有在对应 Task、Agent Session、Run、executor job 与 `RunRef` 全部释放后才能清零；
- Workbench 必须为 Task persistence 保存不含 secret 的 execution binding descriptor 和 epoch history；Account persistence revision 2 仍只保存一个默认 execution family，不为每个 Task 复制 credential；
- 跨 Host 重启恢复历史 Task 时，只有 Host 证明 restored account/profile、API、model 与 generation 精确匹配且 Conversation 可以安全恢复，才能把 binding 标记为 available；否则 Task 只读并进入 `rebind_required` 或 `unavailable`，不得静默采用当前默认配置；
- 目标 rebind 流程必须展示旧配置与当前候选的脱敏差异，并在用户明确确认后由 Host 原子创建新 binding epoch 和新 Agent Session；旧 Run 历史、usage 和模型归属保持不可改写。如果只读 Task history persistence 先于跨进程 Conversation 恢复落地，该阶段只提供 `从此历史新建任务`；
- 切换账号、退出登录或清除设备凭据必须取得 Workbench execution replacement gate，并证明所有引用该账号 credential 的 Task、Agent Session、Run、executor job 与 `RunRef` 已安全终止；
- OAuth refresh 失败只进入 `reauth_required`，不自动判定现有 API Key 失效；只有 Metask 明确撤销/禁用或锁定 credential probe 返回确定鉴权拒绝，才关闭既有执行配置；
- New Task admission 必须同时满足 Account execution state 为 ready、Workbench 已安装所选默认 generation、Workspace grant 有效且默认安装/identity replacement gate 未开启，并在创建 Task 时固化第一个 binding epoch；既有 Task 的新 Run admission 改为校验其当前 binding `available`、owned generation 仍有效、Workspace grant 有效、没有 non-terminal Run 且 identity replacement 或该 Task 的 rebind gate 未开启，不能强迫它跟随 Account 当前默认 generation，也不能被无关的默认切换冻结；
- production Account 接入必须符合 [Metask Account API 合同](metask-account-contract.md)。C1 OAuth/login 独立交付 `account_only`；C2 只从 profile-aware API Key/model catalog 与精确 `group.platform` 形成 fixed ExecutionTarget。Account 提交 `execution_ready` 且 Workbench 安装同一默认 generation 前禁止进入 Workbench 或创建新 Task；既有 Task 的后续 Run 服从其 binding epoch，不与默认 generation 做错误等值比较。

### 5.3 Task

- New task 草稿只在登录和执行准备完成后进入 Workbench，由 Renderer 按 Workspace 隔离并可恢复；未选择 Workspace 时可以编辑临时草稿，但发送前必须取得 Host-issued Workspace grant；
- 用户可以在 Workspace 中创建、切换和关闭 Task；
- 多个 Task 可以同时存在；
- 后台 Task 的运行状态不能因 UI 切换而丢失；
- 每条事件、审批和工具结果必须路由到正确 Task/Run；
- 每个 Task 在创建时建立 execution binding epoch，固化 account/profile、generation、Provider/API identity 与模型；全局默认变化不改写当前 epoch、Task 历史或 live Agent Session；显式 rebind 只能在没有 non-terminal Run 且 Conversation capability 已验收时创建新的可审计 epoch；
- 每个 Task 至多一个 non-terminal Run，包括 executor 中的 `queued` Run；当前 Run 结束前 Workbench 拒绝第二次提交，Renderer 只能保留未提交草稿；
- Renderer 产品合同为 `metawork.renderer-bridge` revision 2：`connect` 精确协商后才开放产品路径，snapshot 根节点由严格的无 secret `capabilities`、`account`、`selectedWorkspaceId`、`workspaces` 与 `tasks` 组成且不维护第二个局部版本；Account 发布脱敏 catalog selection identifier 与 generation，Workspace 由 Host 独立发布，Task 固化 binding epoch 与显示事实；Account、Workspace 和 Task mutation 均提交 expected generation/epoch，Host 重新校验 window、ownership、catalog membership 与 admission；当前不接受或双写旧 contract revision；
- 预期的 Task/Workspace admission 拒绝必须作为严格 typed result 返回并由 Renderer 映射为产品文案；非法 payload、伪造 ownership 与不可信 origin 仍 fail closed 为 Bridge error，不得把内部 error name 显示给用户；
- revision 2 是独立 Workspace projection 与 Task execution binding 的原子 hard cut。一次性目录能力必须由选择命令在 Host 内创建并消费，Renderer 不接收路径授权 token，不从 Task 反推 Workspace，也不能通过可选字段继续发送 revision 1 payload；
- 产品 Task identity 由 Workbench 独立、稳定地分配；内部 Agent/Gate 原始事件使用单独的 Session route identity 做路由，两者不得复用或假定数值相等。Session route identity 不进入产品 snapshot，Renderer 始终只看到唯一的产品 `taskId`。
- credential 不得因 owner 释放而重新出现在任何 Renderer projection。Host 在安装新 credential 以及 secure-zero 旧默认或 Task-owned credential 之前，必须永久清洗既有 Workspace、Task、Run、tool 和 UI history 投影；同时存在前缀重叠 credential 时按最长匹配脱敏。

### 5.4 Agent 交互

- 用户可以提交文本输入并启动真实 Agent Run；
- UI 流式显示 assistant 文本；
- UI 展示工具开始、进度、结果、错误和耗时；
- UI 展示 token usage、上下文警告、重试和压缩等可见状态；
- 用户可以取消当前 Run；
- 取消必须等待 AgentCore 给出真实终止结果，不能只在 UI 中停止渲染。

### 5.5 审批与输入

- 工具 permission 默认拒绝，只有明确授权才允许执行；
- 用户可以回答 Agent 问题；计划批准或拒绝只有在 AgentCore 发布 typed control capability 后才显示；
- 审批和回答必须绑定 Task、Run 和请求标识，拒绝过期或重复响应；
- 同步等待必须支持 deadline、用户取消、Task close 和 App shutdown 唤醒；
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

- 每个 Account attempt 必须拥有 Host deadline，并最终进入成功、可重试失败、用户取消或明确的 restart-required 边界；浏览器未回调、网络悬挂、worker 启动失败和 completion/notification 异常不得永久保留 active operation；
- OAuth 等待超过正常感知时长时，界面必须提供 Host-owned `重新打开登录页面` 与 `取消登录`；Renderer 不接触授权 URL。目录等幂读取可以有限自动重试，OAuth code exchange、持久化 mutation 和其他结果不确定操作不得盲目重放；
- Bridge command 或 view refresh 超时必须释放 Renderer 本地 busy 状态并进入 snapshot resync；结果不确定的 mutation 只能依据 Host snapshot 决定后续动作，不能由 Renderer 自动重复；
- Account cancel 是独立逃生动作，不能因普通 mutation busy 被禁用；但 credential persistence 一旦开始提交就跨过取消边界，Host 必须暂时撤销 cancel 并等待唯一 terminal completion，不能在磁盘已提交、main-thread completion 尚未消费的窗口把内存回滚到旧 generation。Bridge 暂不可用时 Host deadline 仍必须收口 attempt，Renderer reload 后从 snapshot 恢复可用动作；
- 用户消息、已完成 assistant 消息、工具结果、审批决策和关键 Run 状态应形成可靠状态边界；Run admission 必须先建立稳定、带 generation 的 Workbench Run record，terminal payload 一经发布不可变，内部 Agent Session 关闭或销毁后 Task 历史仍可独立生成 snapshot；
- 当前 baseline 的 Renderer reload 只能从仍存活的 Host 恢复视图；
- Host 或 AgentCore 进程退出时，当前同步 Run 标记 `interrupted`，不得伪装完成；
- 崩溃后不得自动重放可能产生副作用的工具；
- 可 checkpoint 的 AgentCore suspend/resume 和跨进程 Conversation 恢复属于后续 capability；
- 成本预算、轮数上限或工具循环熔断后，Task 进入等待用户状态，只有用户明确继续后才创建新 Run。

### 5.8 桌面能力

- 提供窗口与应用生命周期管理；
- 提供受控的文件/目录选择；
- 为通知、更新和系统集成保留明确入口；
- Renderer 只能调用 Host 显式开放的领域命令。

### 5.9 Workbench 界面与任务组织

- 未登录与 Workbench 是两个明确界面阶段：首次启动只突出登录及其恢复动作；`execution_ready` 后才展示 Workspace、Task、Composer 和执行历史；
- Workbench 左栏只承担 Workspace/Task 导航与左下角账号入口；New task 是稳定主动作，Task 按 `需要处理 / 正在运行 / 最近` 等行动优先级组织；
- New task 中央区域始终以 Composer 为主，当前模型和 Workspace 在发送前可见；API 管理不进入 Composer，模型与 Workspace 也不得混成不透明的单一“模式”；
- Task 启动后中央区域转为可追溯工作轨迹，Composer 固定在底部；审批、当前活动、工具详情、usage 或真实结果只决定 Inspector 模块是否可用，不因普通 Run 开始或结束自动开合。只有新的待处理请求可以自动打开一次；打开后保持到用户关闭或切换 Task；
- 标题栏只承载窗口、当前 Task/Workspace、搜索与异常状态等全局入口；正常连接状态、语言选择和工程诊断不长期占据主视觉；
- 界面在任一时刻只突出一个与当前阶段一致的主动作；独立的导航和设置入口可以持续可见，但不得与主动作竞争；
- 首个正式版本采用单主窗口；多个 Task 可以后台运行，切换 Workspace 或 Task 不停止执行；
- Renderer reload、断开连接以及 Bridge revision/snapshot failure 默认只影响视图同步和重连，不得终止后台 Agent Run；只有 Workbench 根据 canonical 产品状态作出的显式 termination 决策才能请求结束 Run；
- 左栏只展开当前 Workspace 的 Task，Workspace 切换器必须汇总其他 Workspace 的运行、待处理和失败状态，不能让后台请求只依赖系统通知；
- Task 是可持续补充、归档和删除的产品对象；Task lifecycle、当前 Run phase 和最近一次 Run outcome 是三类独立状态，Renderer 只能从 Workbench projection 派生展示标签；
- 中间区域以用户指令、Agent 回复、工具活动、可用审批和结果构成可追溯时间线，不展示 raw AgentCore event 或 chain-of-thought；
- Run 执行期间的新输入不得暗示可以修改当前 Run；首版只保存 Renderer 草稿，等待当前 Run terminal 后由用户明确发送，不自动创建或启动下一次 Run；
- Host 重启后的历史 Task 默认只读；execution binding 和 Conversation 均可安全恢复时才允许继续。需要 rebind 时必须由用户明确确认并在时间线记录配置边界；当前 baseline 不承诺跨 Host Task history，若只读历史先行落地则只提供从历史创建新 Task；
- `Files changed` 表示实际文件变更集合，`Outputs` 表示用户关心的交付结果，两者不得用“新建文件”自动等同；当前 ABI v1 未提供这两类 typed event 时，相关模块必须隐藏；
- Task 归档只隐藏日常列表；归档、删除 Task 或移除 Workspace 前必须先终止其 queued/running/waiting/stopping Run；删除已关闭 Task 时若仍有 worker `RunRef`，只能标记 `delete_pending`，待引用归零后物理释放；删除 Task 记录不删除 Workspace 中的真实文件；移除 Workspace 先原子进入 `removing` 并推进 Workspace epoch、拒绝新 admission，全部 Task 收口后撤销当前 Host authorization 并退出活动导航；异步失败必须恢复可用状态并发布 Workspace 级失败事实，不能静默回弹；
- 全局搜索覆盖 Workspace、Task、用户指令、完成消息和 Output 文件名；工具原始日志默认不进入普通搜索；
- `en-US` 是规范产品文案和回退语言，`zh-CN` 是首个完整 locale；Host 传递 structured code 与参数，Renderer 负责本地化。

## 6. 非功能需求

### 安全

- Renderer 按不可信调用方处理；
- Host 命令默认拒绝，只开放白名单；
- 校验来源、payload、Workspace、Task/Run 归属和权限；
- production 执行配置只由 Account 生成并在 App 主线程的一致性提交链中安装到 Workbench；禁止环境默认值、Renderer 字段或 Bridge payload 注入 provider/base URL/credential。Renderer 只可提交 Host 当前脱敏 catalog 中的稳定 API/model selection identifier，Host 必须重新校验并从锁定合同生成配置；
- Provider credential 不得进入 Renderer、Bridge、日志、事件或视图 snapshot；
- OAuth token、PKCE verifier、authorization code、完整 API Key 和 Authorization header 必须使用单 owner secret buffer，所有失败、取消、过期 completion、replacement 和 shutdown 路径都先不可消除地清零再释放；
- Host 必须在形成产品 projection 前移除已知 Host-held credential 和 schema 标记的 secret 字段，并对命令与工具输出设置明确上限和 truncation 状态；不得把秘密过滤责任推给 Renderer；
- 文件访问、进程启动和高风险工具最终必须经过能力控制；
- 不向 Renderer 暴露通用任意执行或任意文件接口。

### 可靠性

- 高频事件不能造成无限内存增长；
- 控制事件、工具结果和审批不能静默丢失；
- 单个 Task 的事件不得串入其他 Task；
- Task close 和 App shutdown 必须等待 Run 与 callback 安全退出；
- 进程模型必须通过故障注入和恢复数据选择。

### 性能

- 文本流应保持可感知的实时性；
- 高频增量允许批量合并，但不得破坏最终内容；
- 大型工具结果应通过有界对象或文件引用展示，避免无限制穿过 WebView Bridge；
- 多 Task 运行时 UI 应保持响应；
- executor、事件泵和 Bridge 必须同时设置 count、byte 和时间边界。

### 平台

- macOS 是当前优先真实验证平台；
- Windows development baseline 已完成独立 artifact、Native SDK、Bridge、AgentCore 和桌面自动化验证，不能用 macOS 结果替代；
- Windows MSI/签名/更新和完整安全矩阵仍是后续分发交付；
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

### 7.2 Account-integrated macOS 目标

下一阶段在不改写既有 baseline 证据的前提下增加：

```text
Metask 登录 → Host 后台恢复或加载 API Key/模型
→ 仅在真实歧义时请求默认 API/模型 → ready ExecutionConfig
→ 进入 Workbench → 选择 Workspace / 编辑 New task 草稿
→ Composer 确认模型 → Task admission → 既有同步 macOS baseline
```

Metask C1 OAuth/login 与 C2 catalog/ExecutionTarget 合同均已锁定。登录先独立提交 `account_only`；产品编排随后启动独立 C2 continuation。API Key/model 选择只决定何时形成 `execution_ready`，不得反向成为 OAuth 前置条件或让 C2 失败抹除已完成登录。Workbench 首屏仍以完整 `execution_ready` 为进入条件，不能把 `account_only` 误报成已经可以工作。

### 7.3 Fault-domain 结论

事件泵数据、生命周期压力测试和同进程/最小 Worker fault-domain spike 已完成。结论是选择单 AgentCore Worker 作为后续正式故障域；当前应用仍是同进程 prototype，正式 Worker、跨进程恢复和危险工具重放策略不属于当前交付。

### 7.4 Windows 接入 baseline

Windows x86_64 GNU 当前提供与 macOS 同一产品语义的开发可执行 baseline：精确 bundle、source-free probe、Native Debug/Release、Renderer 生产资源、AgentCore vertical automation 和干净退出均已验证。它不是安装器或正式发布承诺。

### 7.5 后续产品能力

async pending、持久化恢复、strict Workspace security、正式 Host tools、远程 artifact 发布、Windows 分发交付和 Linux 接入按独立 capability 与阶段推进，不能反向伪装成当前 v1 已具备。

具体验证矩阵见 [当前验证规范](validation.md)。

## 8. 待细化的产品问题

- Task 导出格式、敏感信息清理和重新导入语义；
- 多 Agent、子 Agent 和任务图在 UI 中的呈现；
- TerminalTool 是否进入后续正式产品范围。

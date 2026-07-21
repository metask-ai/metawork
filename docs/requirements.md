# MetaWork 产品需求

> 状态：v0.4，加入 Task-first 交互、Account 后台编排与恢复边界
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
- 让用户先表达工作目标，把账号、目录和执行配置准备降为后台条件；
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

代表 Agent 工作所针对的本地目录和权限范围。Workspace 最终应成为文件访问、工具执行和 Task 归属的安全边界。当前同步 baseline 只在临时或用户明确 trusted 的 Workspace 中验证，不能据此宣称 strict Workspace security 已完成。

### Task 与内部 Agent Session

Task 是用户可持续补充的产品工作上下文，归属于 Workspace，拥有消息、运行状态和 Run 历史。每个 live Task 在当前进程中持有一个内部 Agent Session 与 Conversation；Session 是执行生命周期术语，不是第二个产品对象或 Renderer 身份。跨进程持久化恢复属于后续能力。

### Turn / Run

Turn 是用户提交的一次交互；Run 是 AgentCore 为该交互进行的一次实际运行。产品必须区分排队、运行、同步等待用户、已完成、已取消、失败和中断等状态。当前 ABI v1 提供的 `max_turns`、`tool_loop` 等受控停止不得伪装成完成或笼统失败；成本预算停止只有在 AgentCore 发布相应 typed capability 后才进入产品状态。

未来具备相应 AgentCore capability 后，再加入可恢复 `suspended`、持久化恢复和后台转换状态。

### Tool Call

代表 Agent 发起的一次工具调用，包含工具名、输入、进度、结果、错误和耗时。Tool Call 应通过结构化卡片展示，而不是依赖终端字符解析。

### Approval / UI Request

代表 Agent 继续工作前需要用户作出的选择。当前 ABI v1 只提供工具 permission 和问题回答，并使用同步 request/response；等待期间 Run 仍占用 executor slot，不形成可持久化挂起点。计划审批和自定义结构化交互只有在 AgentCore 发布相应控制协议后才进入产品范围。

### Account 与 ExecutionConfig

Account 是 MetaWork 的 Metask 账号控制面，负责 OAuth 登录、账号/API Key/模型目录、凭据安全存储和执行配置代际。产品只允许一个 active `ExecutionConfig`，包含 typed `provider_kind + model + base_url`、API Key 和 `execution_generation`。Workbench 只消费 Account 已验证并安装的配置，不读取 Renderer 输入、环境默认值或账号存储。

## 5. 产品功能需求

以下是目标产品需求，不代表当前 ABI v1 baseline 已全部实现。

### 5.1 工作区

- 用户可以选择并打开本地 Workspace；
- Host 校验并保存 Workspace 的规范路径；
- 文件和工具能力最终必须受 Workspace 与显式权限约束；
- UI 能显示当前 Task 所属 Workspace；
- strict Workspace security 未验证前，产品必须明确限制使用范围，不能制造虚假的安全承诺。

### 5.2 Metask 账号与执行配置

- 普通用户通过 Metask OAuth 登录，不需要手工填写 Provider、model、base URL 或 API Key；
- 首次启动不得把 Account 内部 operation 暴露为逐步配置向导。用户登录前即可选择 Workspace、编辑并保留 New task 草稿；只有 Task admission 和 Run 启动必须等待 ready ExecutionConfig；
- OAuth 成功提交 `account_only` 后，Host 必须以独立、有界的 continuation 自动加载 API Key 和模型目录。仍有效的历史选择优先恢复；没有历史选择时，唯一候选自动采用；只有多个候选且没有合同明确的默认项时才请求用户选择；
- 自动 continuation 不能把 C2 失败回滚成未登录，也不能根据显示名称、列表顺序或模型名猜测默认值、Provider 或 target；
- 没有可用 API Key 或模型时必须保持已登录状态，说明缺少什么并提供 `重试`；只有 Host 拥有固定、安全的 Metask 管理入口时才显示 `在 Metask 中管理`，Renderer 不拼接外部 URL；
- 登录、目录加载、模型加载和持久化是 Host-owned 操作。Renderer 只渲染 Host 发布的 readiness、当前可用动作和脱敏候选，不通过 `useEffect`、隐藏点击或本地定时器推进产品状态；
- 首次 readiness 完成后，账号入口降为 Workbench 中的轻量状态与设置入口；刷新目录、切换 Key/模型和退出不再占据 New task 主流程；
- OAuth token 只访问 Metask 账号 API；选定 API Key 才作为 AgentCore 模型调用凭据；
- Renderer 只能看到脱敏账号、Key 尾号、模型、稳定错误码和状态，不得接触 OAuth token、完整 API Key、Authorization header、临时 OAuth URL 或凭据存储 locator；
- 当前只允许一个 active ExecutionConfig；切换账号、API Key、模型或退出登录必须先取得 Workbench execution replacement gate，并证明没有 live/closing Task、Agent Session、Run、executor job 或 `RunRef`；
- OAuth refresh 失败只进入 `reauth_required`，不自动判定现有 API Key 失效；只有 Metask 明确撤销/禁用或锁定 credential probe 返回确定鉴权拒绝，才关闭既有执行配置；
- Task admission 必须同时满足 Account execution state 为 ready、Workbench 安装的 generation 一致且 replacement gate 未开启；
- production Account 接入必须符合 [Metask Account API 合同](metask-account-contract.md)。C1 OAuth/login 独立交付 `account_only`；C2 只从 profile-aware API Key/model catalog 与精确 `group.platform` 形成 fixed ExecutionTarget。Account 提交 `execution_ready` 且 Workbench 安装同一 generation 前禁止 Task admission。

### 5.3 Task

- New task 草稿是 Renderer-owned、按 Workspace 隔离的可恢复输入；Account 尚未 ready 时仍允许选择 Workspace 和编辑草稿，但不得伪装成已创建 Task、已排队或已提交 Run；
- 用户可以在 Workspace 中创建、切换和关闭 Task；
- 多个 Task 可以同时存在；
- 后台 Task 的运行状态不能因 UI 切换而丢失；
- 每条事件、审批和工具结果必须路由到正确 Task/Run；
- 每个 Task 至多一个 non-terminal Run，包括 executor 中的 `queued` Run；当前 Run 结束前 Workbench 拒绝第二次提交，Renderer 只能保留未提交草稿；
- Renderer 产品合同使用 schema v7：snapshot 根节点由严格的无 secret `account` 与 `tasks` 组成；Account 额外发布 Host-owned `readiness`、唯一 `primaryAction` 与 `canCancel`，Renderer 不从内部状态重建产品流程；Account 命令统一为 `metawork.account.*` 并只进入 App 注入的 `AccountCommandSink`，Task 命令统一为 `metawork.tasks.*`，payload/result 使用 `taskId`，应用关停 cause 使用 `app_shutdown`；不接受或双写 schema v6 及更早版本；
- 内部 Agent/Gate 原始事件可以使用 Session route identity，但该身份不得进入产品 snapshot，也不与 Task 建立双 ID 体系。

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
- Account cancel 是独立逃生动作，不能因普通 mutation busy 被禁用；Bridge 暂不可用时 Host deadline 仍必须收口 attempt，Renderer reload 后从 snapshot 恢复可用动作；
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

- Workbench shell、Workspace 选择和 New task 输入是首次启动的主界面；Account readiness 作为启动条件显示在任务输入附近，不使用阻塞全窗口的技术配置墙；
- 界面在任一时刻只突出一个下一步：登录、完成浏览器授权、选择真正有歧义的 Key/模型、处理失败或开始任务。后台 operation 使用低权重状态，不把内部步骤伪装成用户待办；
- 没有 Workspace 时 `选择 Workspace` 是唯一主动作；确定 Workspace 后草稿才获得归属，若 Account 尚未 ready，登录或处理 Account 是下一主动作；其余未满足条件只作为可理解的次级状态展示；
- 首个正式版本采用单主窗口；多个 Task 可以后台运行，切换 Workspace 或 Task 不停止执行；
- Renderer reload、断开连接以及 Bridge revision/snapshot/event delivery failure 默认只影响视图同步和重连，不得终止后台 Agent Run；只有 Workbench 根据 canonical 产品状态作出的显式 termination 决策才能请求结束 Run；
- 左栏只展开当前 Workspace 的 Task，Workspace 切换器必须汇总其他 Workspace 的运行、待处理和失败状态，不能让后台请求只依赖系统通知；
- Task 是可持续补充、归档和删除的产品对象；Task lifecycle、当前 Run phase 和最近一次 Run outcome 是三类独立状态，Renderer 只能从 Workbench projection 派生展示标签；
- 中间区域以用户指令、Agent 回复、工具活动、可用审批和结果构成可追溯时间线，不展示 raw AgentCore event 或 chain-of-thought；
- Run 执行期间的新输入不得暗示可以修改当前 Run；首版只保存 Renderer 草稿，等待当前 Run terminal 后由用户明确发送，不自动创建或启动下一次 Run；
- `Files changed` 表示实际文件变更集合，`Outputs` 表示用户关心的交付结果，两者不得用“新建文件”自动等同；当前 ABI v1 未提供这两类 typed event 时，相关模块必须隐藏；
- Task 归档只隐藏日常列表；归档、删除 Task 或移除 Workspace 前必须先终止其 queued/running/waiting/stopping Run；删除已关闭 Task 时若仍有 worker `RunRef`，只能标记 `delete_pending`，待引用归零后物理释放；删除 Task 记录不删除 Workspace 中的真实文件；移除 Workspace 同时撤销一次性 grant 并使其持久权限失效；
- 全局搜索覆盖 Workspace、Task、用户指令、完成消息和 Output 文件名；工具原始日志默认不进入普通搜索；
- `en-US` 是规范产品文案和回退语言，`zh-CN` 是首个完整 locale；Host 传递 structured code 与参数，Renderer 负责本地化。

## 6. 非功能需求

### 安全

- Renderer 按不可信调用方处理；
- Host 命令默认拒绝，只开放白名单；
- 校验来源、payload、Workspace、Task/Run 归属和权限；
- production 执行配置只由 Account 生成并在 App 主线程的一致性提交链中安装到 Workbench；禁止环境默认值、Renderer 字段或 Bridge payload 注入 provider/model/base URL/credential；
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
选择 Workspace / 编辑 New task 草稿 ↔ Metask 登录
→ Host 后台恢复或加载 API Key/模型
→ 仅在真实歧义时请求选择 → ready ExecutionConfig
→ Workbench Task admission → 既有同步 macOS baseline
```

Metask C1 OAuth/login 与 C2 catalog/ExecutionTarget 合同均已锁定。登录先独立提交 `account_only`；产品编排随后启动独立 C2 continuation。API Key/model 选择只决定何时形成 `execution_ready`，不得反向成为登录前置条件或让 C2 失败抹除已完成登录。

### 7.3 Fault-domain 结论

事件泵数据、生命周期压力测试和同进程/最小 Worker fault-domain spike 已完成。结论是选择单 AgentCore Worker 作为后续正式故障域；当前应用仍是同进程 prototype，正式 Worker、跨进程恢复和危险工具重放策略不属于当前交付。

### 7.4 Windows 接入 baseline

Windows x86_64 GNU 当前提供与 macOS 同一产品语义的开发可执行 baseline：精确 bundle、source-free probe、Native Debug/Release、Renderer 生产资源、event-delivery/vertical automation 和干净退出均已验证。它不是安装器或正式发布承诺。

### 7.5 后续产品能力

async pending、持久化恢复、strict Workspace security、正式 Host tools、远程 artifact 发布、Windows 分发交付和 Linux 接入按独立 capability 与阶段推进，不能反向伪装成当前 v1 已具备。

具体验证矩阵见 [当前验证规范](validation.md)。

## 8. 待细化的产品问题

- Task 导出格式、敏感信息清理和重新导入语义；
- 多 Agent、子 Agent 和任务图在 UI 中的呈现；
- TerminalTool 是否进入后续正式产品范围。

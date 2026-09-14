# MetaWork UI 设计规范

> 状态：MetaWork 全部用户界面的唯一设计 source of truth；未通过对应能力验收的界面不得出现
> 设计基线：MetaWork 自有的“明亮工作台 + 紫色任务流”；外部产品和参考图只用于提炼交互模式，不构成可复制的布局、品牌或组件规范

## 1. 文档职责

本文档定义 MetaWork 全部用户界面的规范语义。登录、Workbench、设置、全局能力页面、平台窗口呈现与后续 capability-gated 界面都以本文为唯一设计真源；其他文档只能链接或提供不产生新设计语义的摘要。

本文定义：

- 用户可见的信息架构与术语；
- Workspace、Task 和一次执行在界面中的关系；
- Task 内容、当前状态、审批、权限、结果与错误状态；
- 左、中、右三栏及输入区的职责；
- 品牌资产使用、Design Token、Foundation 组件与产品视觉；
- 国际化、主题、动效、响应式、平台适配、可访问性和验收矩阵。

本文档不替代其他 source of truth：

- 产品范围与行为以 [产品需求](requirements.md) 为准；
- 系统边界、Renderer/Host/AgentCore 职责以 [高层架构](architecture.md) 为准；
- AgentCore 事件、线程、所有权和生命周期以 [AgentCore 集成契约](agentcore-integration.md) 为准；
- AgentCore 产品能力与投影以 [AgentCore 集成契约](agentcore-integration.md) 为准；
- Renderer 的稳定 module root、目录 owner 与依赖方向以 [工程结构与所有权](project-structure.md) 为准；平台资产生成合同归对应分发文档与构建清单；
- 测试归属、平台证据和未验证能力以 [验证规范](validation.md) 为准。

品牌 SVG、用途图标、`metask-tokens.css`、Foundation 组件和产品样式是本文的可执行实现，不是并列规范。实现不得自行引入新的品牌 primitive、组件语义、页面布局或 capability 表达；发现实现与本文冲突时必须显式裁决并同步收口，不能反过来把偶然实现写成设计真相。

设计稿中出现但当前能力尚未满足的功能必须隐藏、禁用并解释，或明确标注为后续能力；不得用前端模拟状态制造已经可用的假象。

## 2. 产品设计命题

MetaWork 是面向本地工作区的桌面 Agent Workbench，不是终端模拟器、聊天应用、完整 IDE 或通用 Agent 门户。

Metask 登录和 ready ExecutionConfig 是进入 Workbench 的真实前置条件。首次启动必须诚实地以登录为唯一主动作，在 OAuth、目录准备和必要选择完成后才进入 Workspace、Task 与 Composer；不得提前展示一个大部分控件不可用的假 Workbench。

进入 Workbench 后，界面持续回答六个问题：

1. 当前在哪个 Workspace 和 Task；
2. 新 Task 将使用哪个模型；
3. 当前任务是否仍在工作；
4. 是否正在等待用户决定；
5. 已经完成、验证或失败了什么；
6. 最终产生了什么结果。

技术对象不直接成为产品文案。ABI、Host revision、Run ID、事件连接和原始诊断默认只进入 Advanced Diagnostics。

MetaWork 的视觉记忆点不是装饰性的暖色、通用衬线大标题、品牌吉祥物或大面积卡片，而是：

> Task 启动前，Composer 清楚表达 Workspace 与模型；Task 启动后，中间区域优先显示用户输入、Assistant 回复与当前需要处理的状态，不展示 Agent 执行流水。

首个正式视觉版本使用明亮中性工作面和公司紫色品牌系统。紫色只标记品牌、主动作、当前选择、键盘焦点和当前活动轨迹；成功、等待、失败与中断继续使用独立语义色并配合文字或图标。界面不能退化为暗色原型的亮色翻版，也不能只是把既有青绿色字面量替换成紫色。

### 2.1 当前 ABI v1 capability profile

当前 AgentCore 集成合同已为以下既有界面提供可验证数据；target availability 与平台证据见[验证规范](validation.md)，ABI 接受语义见 [AgentCore ABI v1 合同](agentcore-abi-v1.md)。Skill catalog、typed Skill Run 与 Composer Slash 使用同一 Workspace/Task snapshot 和 Run product path：

- 文本流、工具开始/进度/结果、Run progress、usage、context warning、auto compact、retry 和 stream done；
- tool permission 同步用户请求；AgentCore ABI 虽保留 Ask question，但 MetaWork Agent 不开放对应 built-in；
- Workspace current / Task pinned Skill catalog、typed Skill Run 与独立 Skill rejection；
- Run 状态、六种终止原因，以及 Session 是否仍可继续；当前 AgentCore typed `run_state` observation 由 Workbench 投影为 Current activity，并按 transition sequence 丢弃过期观察。

因此当前产品在 Task 内容区显示用户输入、Agent 可见输出、权限决策面、唯一当前状态、紧凑 Tool 摘要和必要的终止结果；Tool input/progress/result 按需进入右侧单条详情，不展示 Run 用量，context pressure 提醒按需出现在 Composer 附近，历史自动压缩记录不单独占据入口。普通信息不足时，Agent 通过可见回复说明问题并结束当前 Run，用户从 Composer 继续，不进入结构化 Question wait。工具记录只作为所属 Run 的可检查过程证据，不成为 raw event 时间线。当前 PermissionProfile 只定义并开放 `请求批准 | 完全访问`；Plan、plan approval、Outputs、空的 Files changed 概览模块、持久权限管理和 custom UI 均保持隐藏。Renderer 不解析工具参数、stdout 或普通文本来猜测这些状态；Current activity 只来自 Host 对受序列保护的 `run_state` 以及 typed text、Tool、retry、context 和 output control event 的产品投影。当前 Renderer 合同已提供独立 Workspace projection、Task-bound ExecutionConfig facts、正式设置 route、设置与 New task 共享的默认 API/模型选择，以及 New task 的 PermissionProfile 选择；跨重启 rebind 等仍须等对应 capability 落地后才能宣称可用，差距由 [验证规范](validation.md)明确记录。

上述边界同时约束 Agent 对话渲染：工作过程必须在 terminal 前随真实 Snapshot revision 可见，过程与正式回复保持主次层级，长任务中可以检查 Tool 摘要而无需离开阅读上下文；仍不得泄漏 private reasoning、从文本猜测结构化事实或提前开放 gated capability。该信息架构只呈现实际到达的 commentary 与 typed activity，不承诺 Provider 在每个 Tool turn 输出自然语言，也不允许 Renderer 为提高信息密度而生成中间对话、推断模型意图或补造进度。

### 2.2 Capability 标记

本文在每个依赖未落地合同的章节就地标记状态，不要求实现者只靠本节的全局免责声明推断：

- **当前**：现有锁定合同可以提供，仍需按验证矩阵确认具体实现；
- **目标**：产品行为已经批准，但必须等标注的 Host、Bridge、persistence 或 AgentCore capability 完整落地后才显示；
- **未来**：只保留设计边界，不进入当前实现范围；
- **混合**：章节同时包含当前与 gated 行为，具体条目必须继续标注。

未达到依赖条件的目标或未来 UI 必须保持隐藏，不能用 Renderer 推断、静态假数据或 disabled 空壳提前占位。

## 3. 用户可见对象与术语

> Capability：**混合**。Task/Run、Account 状态与当前事件对象已经存在；独立 Workspace、binding epoch history 和 typed Outputs 按各自目标 capability 落地。

### 3.1 对象关系

```text
Account
├── Metask identity and API catalog
├── Custom Provider registry
└── Default execution selection

Workspace
└── Task
    ├── Bound execution generation / model
    ├── User instructions
    ├── Agent responses and work activity
    ├── Current execution
    ├── Decisions and permissions
    └── Outputs
```

- `Workspace` 对用户显示为 `Workspace / 工作区`。
- `Account` 只负责 Metask 身份与授权；`Models` 将有效的 Account 授权映射为内置 Metask provider，并与用户管理的 Custom Provider 一起提供模型配置。Account 退出后 Metask provider 对新的 catalog/resolve 失效，自定义来源与已交付给既有 Task/Run 的 binding 不受影响。
- `Custom Provider` 是一个明确协议、endpoint、credential 状态和模型目录的 Host-owned 配置，不是第二个 Account identity。
- `Workspace` 是独立产品对象，不能只从 Task 路径反推。
- 产品对象就是 `Task / 任务`；每个 live Task 在当前进程中持有一个内部 Agent `Session`，但 Renderer 合同不暴露 Session 身份。
- `Turn` 和 `Run` 通常不直接命名，用当前活动、排队、停止和结果表达。
- 一项 Task 可以包含多次用户补充和多次执行；停止一次执行不会删除 Task。

当前 Renderer 产品合同为 `metawork.renderer-bridge` 固定 revision 1：`connect`精确协商后才开放产品路径，snapshot根节点包含无 secret `capabilities`、`account`、`models`、`newTaskAdmission`、`skillCatalog`、`skillManagement`、`mcp`、`workspaces`、`scheduledTasks`与 `tasks`且不维护局部版本。Account只发布 Metask identity/authorization状态；Models独立发布 provider catalog、Provider-local/global selection、persistence health与 Custom Provider；Product Control在 `newTaskAdmission`中发布当前安装的 active `ModelRef`、generation、selection revision与新 Task admission。三者可以形成合法的独立状态组合：界面保留账号、模型 intent、历史 Task与恢复动作，只禁用依赖当前 active execution的 New task发送，不把 Models或 Product admission失败误报成账号失效。Workspace独立于 Task发布，durable Task不携带 Account identity、API Key元数据或 connection credential locator。快速开发阶段直接原地 hard cut合同内容，不提供临时形态兼容层或可选字段退路；任何合同类版本标识的变更都必须先得到用户显式同意。Agent内部 Session route identity不属于 Renderer产品模型。

### 3.2 规范术语

`en-US` 文案定义产品语义，`zh-CN` 是首个完整本地化版本。

| English source       | 简体中文        | 使用说明                              |
| -------------------- | --------------- | ------------------------------------- |
| Workspace            | 工作区          | 本地目录和任务归属范围                |
| Task                 | 任务            | 用户可持续补充的工作上下文            |
| New task             | 新建任务        | 不使用 New session                    |
| Skills               | 技能            | MetaWork 用户 Skill 目录与健康        |
| MCP                  | MCP             | 可信服务、连接状态与已发现工具目录    |
| Account              | 账号            | Metask 登录、身份、授权与退出         |
| Providers            | Provider        | 用户管理的模型服务、协议、地址与凭据  |
| Models               | 模型            | 所有 Provider 的模型与全局默认模型    |
| Custom Provider      | 自定义 Provider | 用户创建并由 Models 持久化的 Provider |
| Model                | 模型            | 新 Task 的执行模型，不称模式          |
| Task Panel           | 任务面板        | 当前 Task 的统一右侧详情容器          |
| Task information     | 任务信息        | 创建时 authority 的只读说明           |
| Current activity     | 当前活动        | Agent 此刻正在进行的可观察动作        |
| Plan                 | 计划            | 只在有真实结构化计划时显示            |
| Outputs              | 结果文件        | 用户关心的最终交付，不称 Artifacts    |
| Files changed        | 文件变更        | Agent 实际修改过的文件集合            |
| Needs your attention | 需要你处理      | 权限审批或计划确认                    |
| Allow once           | 允许一次        | 仅批准当前请求                        |
| Stop task            | 停止任务        | 停止当前执行，不删除任务              |
| Stopping             | 正在停止        | 等待真实停止结果                      |
| Interrupted          | 意外中断        | 与明确失败区分                        |
| Show in Finder       | 在访达中显示    | Windows 为 Show in Explorer           |

## 4. 主窗口信息架构

> Capability：**当前**。登录优先 gate、独立 Workspace projection、左栏、New task、Settings overlay、Task 内容与统一 Task Panel 已进入当前 shell；未通过 capability gate 的模块与标签仍必须隐藏。

### 4.1 总体布局

```text
┌───────────────────────────────────────────────────────────────┐
│ Integrated title/command bar · context · search · controls    │
├──────────────┬────────────────────────────────┬───────────────┤
│ New task     │ New task Composer              │ Task Panel    │
│ Workspaces   │ or Task content                │ when useful   │
│ Task groups  │                                │               │
│              ├────────────────────────────────┤               │
│ Account      │ Composer / execution control   │               │
└──────────────┴────────────────────────────────┴───────────────┘
```

默认尺寸：

- 一体化命令栏：默认 52 px 产品视觉基线；Windows 沿用历史实现的 40 px 标题栏，macOS 交通灯安全区由 Host geometry 注入；
- 左栏：默认 248 px；常规桌面可通过分界线在 208–360 px 内调整并保存偏好，键盘聚焦分界线后可用方向键调整；窄窗 overlay 保持固定宽度；
- 左栏品牌区使用紧凑单行，只显示 `MetaWork` 字样，不把品牌区表现成第二层标题栏，也不重复使用首字母图标、产品说明或宣传副标题；
- Task Panel：默认 400 px，用户可通过左侧分界线在 320–640 px 内调整并保存偏好；只有扣除已打开左栏和 Task Panel 后中央 Task stage 仍不少于 480 px 才以固定列停靠，否则改用右侧非模态 overlay。入口、显隐和宽度属于应用布局，用户可独立开合或通过具体对象入口展开；无 Task、无内容时也允许打开空栏，不触发普通 Run 或审批状态驱动的自动开合；
- 已有 Task 不额外占用独立内容标题区；Task 名称只在顶部命令栏显示；
- 中间正文推荐最大宽度：760 px；
- 表格、diff、日志和文件预览可以使用中间区域的可用宽度；
- Native 主窗口声明 320 × 520 logical px 的系统最小尺寸，保证窗口不能被缩到 Renderer 已定义布局下限之外；960 × 680 仍只是窄窗口回归样本，不是固定设计画布；
- Task Panel 的停靠不使用固定 viewport 断点，而由 480 px 中央工作面下限决定；低于 820 px 时左栏和 Task Panel 互斥，低于 620 px 时 Task Panel 使用全宽 overlay；低于约 560 px 时命令栏隐藏次级文字。

左栏折叠后完全隐藏并把宽度归还中央工作面，不保留 56 px 图标栏，也不用匿名图标映射任意 Task。命令栏左侧始终保留打开/关闭入口，折叠状态与桌面宽度按用户偏好保存。右侧栏显隐与对象选择分别管理：常驻开关、关闭、Escape 与窄窗互斥操作控制显隐，打开具体对象可显式展开右栏。切换或删除 Task、切换主页面及目标失效只清空不再适用的内容，保持右栏显隐与宽度。显隐默认关闭，在本窗口会话中保持，不建立每 Task 记忆或新增持久化键。折叠只改变视图，不改变 Task、审批或运行状态。

### 4.2 窗口模型

首个正式版本采用单主窗口模型：

- 多个 Task 在同一窗口内切换；
- 后台 Task 不因切换而停止；
- 系统通知用于提醒后台 Task 等待用户、完成、失败或中断；
- 多窗口属于后续能力，不进入当前设计范围。

### 4.3 一体化窗口栏

主窗口使用 `hidden_inset_tall`：Renderer 命令栏承担自定义标题栏的产品视觉，不叠加独立的标准系统标题行。React 绘制产品 header、声明一个 drag candidate，并绘制带固定 `data-metawork-window-control` 语义的窗口按钮；browser-side Bridge 才能把这些声明转换为受限 Host command。Native SDK/OS 独占 native hit test、拖动循环、系统菜单、resize、close policy 与真实窗口状态。React component 不推断平台、不直接调用 transport，也不持有原生窗口 identity、handle 或执行权。

- 命令栏是窗口交互层，不表现为独立横向标题栏：不使用贯穿全窗的底边或异色横带；左侧 Task rail 的背景与竖分隔线必须延伸到窗口顶部，中央命令区与 Task 工作面使用同一 surface；
- macOS 保留系统交通灯；Windows 由 Renderer 绘制最小化、最大化/还原与关闭按钮。Host 只发布 `rendererControls` capability、`maximized` 真值和安全 inset，browser-side Bridge 将它们转换为 document dataset/CSS variables；React 不读取平台名或调用 transport，最大化与还原使用互斥的可访问按钮，由 Host 真值控制显隐；
- 产品 header 默认视觉基线为 52 px；Windows Renderer header 沿用历史实现的 40 px 高度，每个 window control 使用 46 px 命中宽度并贴齐窗口右缘。关闭 hover/focus 使用系统危险红色，其余按钮保持中性色。macOS 交通灯与可拖动 top band 的真实安全区以 Host geometry 为准；
- 命令栏只包含左栏开关、当前 Task 名称、全局搜索、只读任务信息、Task Panel 常驻开关和按需异常/审批定位入口；不在 Task 名称前重复 Workspace，`左栏开关` 只控制能力与 Task 导航，不兼任 Task Panel 开关；
- `WindowTitlebar` 只声明一个 drag candidate。browser-side Bridge 在 animation frame 内镜像该区域与按钮、输入、选择框、标签、链接、disclosure、可编辑内容和显式 no-drag 内容的交集排除区；区域数量、数值、viewport、native top band、document generation 和精确启动窗口 identity 均由 Host 重新校验，任何 malformed、stale、多 candidate 或越界输入都 fail closed；
- 窗口 resize/maximize/restore 由 Native SDK/OS 执行，并通过 Native SDK 正式 resize event 通知 browser-side Bridge；Bridge 在当前 document generation 内合并最新 viewport 与候选后执行 `sync`，不得因 resize、layout 或 command failure 重新 `connect`。React 不保存或推导窗口状态，只由 `maximized` Host 真值选择互斥按钮；
- Windows 不递归 subclass Chromium 的跨进程 child HWND，也不由 Renderer 模拟窗口位移；在 Native SDK 提供正式 System WebView drag-region 能力前，Host 只对同 generation、当前逻辑主鼠标键仍按下、实际 OS 光标属于已绑定 root 且命中最新 candidate-minus-exclusions 的手势发布 live-pointer drag，并把该手势交给 Windows caption move loop。Renderer 坐标不构成执行 authority，一次 drag 失败只结束当前手势，不使已验证 region snapshot 失效。macOS 对应请求只调用 Native SDK 0.8.0 的 `startWindowDrag`；React component 不注册 double-click 或 context-menu handler；
- window-chrome bootstrap capability 不依赖 ProductDelivery connection，使登录/连接失败页仍保留系统窗口行为。它只接受 connect/sync/disconnect、Host capability gate 控制的 live-pointer drag，以及绑定当前 document generation 的 `minimize | toggle_maximize | close` 固定语义动作；不接受 window id、任意 action 或独立 state query；
- 正常连接、恢复成功和普通操作成功不持续占据命令栏；只有同步失败、命令失败或其他确实需要用户行动的异常才显示状态入口；
- 异常状态按 connection、account、Workspace identity 或 Task identity 分域保存；并行 Task 的结果不得互相覆盖，命令栏只选择当前上下文中优先级最高的一项显示；
- 已有 Task 的标题附近提供键盘可达的“任务信息”纯图标只读入口，所有宽度均保留图标、完整 accessible name、tooltip 和可见焦点，不常驻文字标签；左栏折叠时仍可用，New task 与无 Task 时隐藏。右侧栏开关由应用外壳提供，在主工作界面的各内容页面常驻，使用匹配实际显隐的 accessible name 和 aria-expanded；无 Task 或无内容时仍可操作，不因任务暂无文件而隐藏或禁用。设置仍使用覆盖层，底层开关与工作面共同 inert，不丢失先前显隐选择。窄窗将命令栏审批定位收为有完整 accessible name 的图标按钮，保证两侧栏开关与搜索不会被长标签遮挡；
- 未登录界面的应用工具栏只保留产品 identity 与语言入口；语言不能藏进尚不可进入的设置；
- Renderer 关闭按钮必须进入平台的 user-close 语义并遵循 manifest `close_policy = hide`，后台 Application 与计划任务继续运行；重新打开由 Native SDK 托盘菜单进入 Application 的 `showWindow`/`focusWindow` capability，显式 Quit 才进入应用 shutdown；
- 不使用 `chromeless`；系统 resize frame、Snap Layout、拖动、双击、系统菜单、DPI 与高对比行为只按真实平台验收声明，不由 WebUI 模拟。Renderer 只绘制按钮并提交固定语义意图，不复制这些底层行为；
- 语言、API、模型和诊断进入设置或对应任务上下文，不常驻命令栏；
- 不在命令栏放 ABI、protocol、Host mode 等工程状态。

平台文案、路径、快捷键和文件管理器动作按 OS 切换。

## 5. 左栏：能力与 Task

> Capability：**部分当前、部分目标**。Renderer 合同已提供 MetaWork 顶层与 Workspace/Task 分离的 AgentCore Skill catalog projection；本地 package/inventory、详情与管理 mutation 是本次目标合同。shell 已提供稳定 New task、全局 Task 导航、行动优先分组和左下角账号入口；Skill 中心、消费 Host-owned management/Runtime/admission 事实的 MCP 页面与持久定时任务都作为同级全局能力进入该 shell。

### 5.1 Task 列表与路径上下文

登录后的左栏从上到下只承担五类稳定职责：品牌/窗口识别、New task、已接通的全局能力入口、Task 导航、左下角账号入口。搜索由标题栏或命令面板提供，不在窄侧栏重复占据首要位置。

- 左栏不显示 Workspace 标题、添加动作或切换器；它直接列出同一 canonical snapshot 中 owning Workspace 仍被投影的所有 Manual/Automatic Task，并按统一行动优先级分组。Workspace 移除后保留的历史 Task 不生成可点击的死入口；
- Task 被选择后使用自身绑定的 Workspace 路径，不提交额外的全局 Workspace 导航动作；不同路径下的后台 Task 都必须持续可见；
- New task 默认选择 Automatic Workspace，工作目录控件直接显示“默认”；此时不提前创建 Workspace 或 Task，首次发送才请求 Host 分配 Automatic Workspace。用户可以在发送前切换到已有 Manual Workspace 或打开原生目录选择器；用户确认目录后即完成授权并只更新草稿上下文，不得追加 trust 确认、自动创建 Task 或发送已有内容。Manual Workspace 直接显示 canonical directory，Automatic Workspace 统一显示“默认”，不得暴露随机目录或内部 kind 术语；
- New task 草稿按 Workspace 隔离。未绑定 Workspace 的临时草稿只在目标 Workspace 没有草稿时迁移；目标已有草稿时保留两边内容并打开目标草稿，不能覆盖或丢弃任一份；
- Workspace projection 的 `kind` 是 Host 事实；一个 Manual Workspace 可以承载多个 Task，Automatic Workspace 精确归属一个 Task；
- Composer 的工作目录控件只选择、添加或重新授权 New task 路径；设置页不提供 Workspace 生命周期管理。设置作为覆盖整个 Workbench 内容区的长期 surface 打开，保留窗口壳层和底层 Workbench 挂载，拥有自己的分区导航与内容滚动，关闭后恢复原工作面；
- 再次打开历史 Task 只保证可浏览记录；需要访问原目录时重新选择或授权，能否继续执行还必须服从 §6.4 的 Conversation 与 execution binding 规则；
- MetaWork 重启后，左栏直接使用 Workbench 恢复的 Task 列表和顺序；点击 Task 打开其已保存时间线，不自动创建新 Task、不重放最后一次输入，也不把恢复的 `interrupted` 显示成仍在运行；
- `taskHistoryPersistenceHealth = degraded` 只表示少数已保存 Task 无法恢复；由于新 Task 和其他有效历史仍可用且没有用户可执行的恢复动作，左栏不为它显示常驻提示。`read_failed / corrupt / write_failed / outcome_unknown` 显示非阻塞保存提示，但不得禁用 Composer、Task 操作、Workspace 选择、权限响应或取消。Host 发布 recovery available 时，提示内提供“使用新的存储继续”，并在就地确认中明确当前文件会保留为恢复副本；Renderer 只提交当前 snapshot revision，不选择路径或操作文件。取消不改变状态，失败保留提示，成功等待 Host snapshot 收口；
- Task 行不保留可见的文字状态标签。运行中使用紫色旋转 loading 图标，需要处理或失败使用对应语义图标；完成使用醒目的实心提示点作为一次性未读提醒，颜色沿用主操作色。Host 只为最新 terminal `completed` Run 发布 nullable 未读 identity；后台完成时显示，用户打开该 Task 后只有中央工作面未被 Settings、搜索、窄窗左栏或非停靠 Task Panel 覆盖，且应用页面可见并获得焦点时才确认并隐藏。当前可见 Task 完成后可直接确认，不闪烁自身提示点；遮挡、失焦、Bridge 失败或 stale acknowledgement 不得提前吞掉提醒。Task 再次完成新的 Run 时重新显示；归档等价于明确处理当前完成提醒，恢复时不复活旧提示点。
- Task 的重命名、归档/恢复和删除从内容区标题栏移除，统一通过左侧 Task 行的右键菜单访问。停止当前运行仍保留在内容区作为即时运行控制；不存在独立的“结束任务”动作。

### 5.2 全局能力入口

> Capability：**当前与受 gate 目标**。Skill 入口只依赖现有 AgentCore discovery/catalog；定时任务入口依赖 Workbench-owned 持久 schedule projection、后台 Host timer/notification 与真实 Task admission。MCP 入口与 route 已进入稳定 shell；当前合同由 Workbench typed 管理能力、Runtime/catalog availability 与新 Task authority 三类事实共同驱动，页面不得把其中任何一个状态冒充另一个。

`新建任务`、`技能`、`MCP` 与 `定时任务` 位于 Task 列表上方的同一个纵向紧凑菜单，不使用窄侧栏中的卡片宫格，也不通过额外分组间距制造父子关系：

左栏字体权重保持克制：产品名作为唯一品牌锚点保留强调，能力入口、分组标题与账号名称使用 medium，普通 Task 名称使用 regular，当前 Task 最多提升到 medium。选中、运行、提醒和失败状态由背景、侧边标记及语义图标承担，不通过整栏粗体重复表达。

```text
MetaWork

  +  New task
  /  Skills
  ⌁  MCP
  ◷  Scheduled tasks

Tasks
```

- 四个菜单项使用相同行高、左右 padding、图标列、字号、字重、hover 与 focus 样式；`New task` 不再使用独立填充按钮，快捷键只作为 tooltip 或不改变布局的尾部提示；
- 当前能力 route 使用 `--ui-action-selected-surface` 弱背景、`--ui-action-selected-content` 图标/文字和左侧 2 px 选中标识，并设置 `aria-current="page"`；选中不能只靠颜色；
- 一个能力可用时只显示一行；后续能力按真实 owner 与使用频率增加，不预留 disabled 占位、不用 `More` 收纳尚不存在的产品；
- 点击能力入口保留完整 Workbench 左栏和 Task 选择，只替换中央 route；点击 New task 或 Task 回到对应 Workbench route。Settings 覆盖整个 Workbench 内容区，保留窗口壳层和底层 Workbench 挂载，不重复显示或操作 Task 左栏；
- 能力页面打开期间后台 Task 继续运行，左栏的 `Needs your attention`、Running 与失败信号继续更新。

### 5.3 Skill 中心

> Capability：**当前合同**。页面在 AgentCore catalog/health projection 之上消费 Workbench-owned 本地 package、inventory、管理 mutation 与“用户默认 + Manual Workspace 覆盖”enablement policy；不要求 AgentCore 增加安装或来源身份 API，也不把管理 projection 当作 Session execution binding。

Skill 中心只有一个工作：管理 MetaWork 已知的本地 Skill 资产及用户/项目启用状态。Personal 开关定义所有项目继承的用户默认值；Project 开关写入当前 Manual Workspace 的显式 enabled/disabled 覆盖，并提供“恢复跟随用户”清除覆盖。创建和修改仍属于普通 Task；在线市场、远程更新、Preset、标签、排序、中央仓库和多 Agent 同步当前不存在，也不显示占位入口。

中央工作面沿用定时任务页的最大宽度、标题节奏、按钮和行动优先分组，使用与 Workbench 一致的紧凑卡片，而不是管理表格或外部市场视觉：

```text
Skills                                           [ Import skill ] [ Refresh ]
Manage skills available to MetaWork.

Compatible sources    [ ] Claude    [ ] Codex
Reads personal and all authorized project Skills. Existing tasks need a Skill refresh.

[ Search skills…                              ]  [ User defaults ] [ Project settings ]
                                                   Project: [ MetaWork ▾ ]

Needs attention                                                     2
┌────────────────────────────────┐  ┌────────────────────────────────┐
│ [doc] Release check          ···│  │ [doc] Documentation         ···│
│ Check versions, tests and build │  │ Keep project docs consistent.  │
│ MetaWork · /release      ⚠ Issue│  │ Personal · /docs      ⚠ Conflict│
└────────────────────────────────┘  └────────────────────────────────┘

Skills                                                              10
┌────────────────────────────────┐  ┌────────────────────────────────┐
│ [doc] Code review            ···│  │ [doc] Image guide            ···│
│ Review correctness and safety. │  │ Create consistent image briefs.│
│ Personal · /review      ● Ready │  │ Design · /image       ● Ready │
└────────────────────────────────┘  └────────────────────────────────┘
```

页面与卡片：

- 页面保留 Workbench 左栏和约 944 px 内容宽度；标题使用现有 24–28 px Display scale，一句产品说明后直接进入 controls，不增加 Hero、统计卡、渐变、来源 Logo 或装饰插画；
- Header 的 `Import skill` 是唯一主动作，`Refresh` 使用现有次级按钮。导入、重新导入或卸载成功后仍自动请求 catalog reconciliation；显式 Refresh 是恢复与外部文件变化入口；
- 页面一次只展示一个 policy context，不提供把 Personal 与全部 Project row 相加的 `All` 入口。默认 `User defaults` 只展示 `scope.kind = personal`；`Project settings` 只展示一个已选择 Manual Workspace 的 row，并严格同时匹配 Workspace id 与 epoch；
- Project selector 只包含 `kind = manual` 且 authorization available 的 Workspace，保持 Host authoritative recent order。当前选择仍存在时保持；失效后切换到第一个合法候选；没有合法 Workspace 时显示 `No configurable projects`，不得回退到其他 scope；
- 搜索只过滤当前 context 已提交 projection 的 display name、description、invocation 和 argument name；资产计数、待验证组与普通列表从 visible rows 派生。目录问题独立消费当前 catalog issues，不随资产搜索隐藏。切换 context 或 Workspace 时关闭已失效的资产详情；
- Personal row 标签为 `User defaults`；Project row 标签为 `Project settings · <Workspace display name>`。标签表达 policy context，不表达 Skill 文件来源；`sourceKind` 只用于已有 provenance 与管理动作；
- `pending_verification` 独立进入“等待验证”，其他资产进入 `Skills`；空分组不渲染，同一资产不重复。目录问题在资产之前按 code 和可空 invocation 独立展示与计数，即使没有 winner/资产也保持可见；asset issueCodes 仅解释关联问题，不再重复计为目录问题。不猜测冲突双方，不提供选择 winner 或通过单 Skill 启停消除冲突的动作；
- 常规桌面使用两列卡片，中等与窄窗降为一列。卡片使用 `canvas/paper`、`rule`、约 12 px 圆角和无常驻阴影；hover/focus 只增加极浅 brand 背景、边框和最多 1 px 位移；
- 卡片显示统一的线性 Skill 文档图标、display name、单行 description、范围、可选 monospace invocation 和带文字的状态。删除原 `/` 装饰；不显示安装量、`Installed` 或来源品牌徽章。能够精确映射对应 current catalog member 的 Personal 与 Project asset 都在卡片尾部显示独立 switch：Personal 使用 `已启用/已禁用`，Project 的 inherit 状态显示 `跟随用户设置`，显式覆盖额外显示 `恢复跟随用户`。external source kind 不自动剥夺启停 authority，但 catalog/selection 不可用或 identity 不可证明时不显示可操作开关；
- 状态颜色只复用 `live / amber / danger`，且必须同时显示文字或图标。来源、revision、资源数量和物理管理细节留在 drawer；
- 卡片是带标题的 `article/listitem`，打开详情的按钮、启用 switch、“恢复跟随用户”与可能存在的 `···` menu button 为并列元素，禁止嵌套 interactive element。开关最小命中区 44 px，checked 使用 `--ui-action-primary`，off 使用中性边框色，并始终有文字、键盘焦点与 disabled 状态；Renderer 不 optimistic 更新，等待 committed Snapshot 后再反映新状态；
- Skill invocation、display name、description、argument name、文件名和用户内容不翻译；页面标题、范围、状态、动作、错误和空状态进入完整 locale catalog。

兼容来源：

标题下、搜索与 policy context 筛选之外直接呈现“兼容来源”及 Claude、Codex 两个 Checkbox；每项同时控制个人与全部已授权手动项目目录。不保留来源 Drawer 或逐目录操作，不新增 route、Logo、排序、自由目录或设置草稿。一句辅助文案解释全局范围及已有 Task 需要刷新技能；默认目录与正常检测结果不占用常驻列表。

Checkbox 即点即提交，值只来自 committed snapshot，不乐观翻转；同品牌两个根都开/关才显示对应状态，已有值不一致显示可操作的 indeterminate 与“部分启用”，不自动写回。同一窗口来源写入/恢复互斥，pending 由 App 持有，页面切换不取消请求或解除互斥；其他导航仍可用。失败或超时 resync，不自动重放；stale CAS 提示确认新值。未知值显示禁用的 indeterminate 和“状态未知”，不能伪装 false 或与部分启用混淆。保存反馈、错误和恢复操作直接在设置下方呈现；重读/reset 严格消费 Host capability，超限与不支持格式不显示 reset。reset 明确只关闭 Claude/Codex 兼容来源，不删除 Skill、不修改单 Skill policy 或项目数据。

只在当前范围存在真实根检查错误时展示对应范围、来源与安全原因，不常驻展示 disabled/checking/missing/checked 清单；missing 不撤销勾选，checked 不承诺 Skill 可用或无冲突。个人刷新只使用 personal target；项目刷新提交点击时 Workspace id/epoch，不借用当前 Task，也不在无合法项目时回退个人。pending/error 与目标一起记录，旧项目或旧 epoch 的迟到结果不能显示到新目标。普通刷新失败保留 committed view；来源提交引发 authority 失效则服从新 snapshot。来源详情使用普通文本，origin 未知明确显示未知，不按品牌授予管理按钮。

详情 drawer：

- 点击卡片主体打开右侧 drawer；窄窗切为整页详情。顶部显示名称、description、范围和 health；正文依次显示 invocation/参数、安全渲染的 `SKILL.md`、资源/脚本/模板列表、结构化 issue 和折叠的安装信息；
- Markdown 禁止 raw HTML、script、远程 embed 和隐式网络加载；文件区只允许查看 package 内受支持的文本资源，不形成通用仓库或磁盘浏览器；物理路径、raw diagnostic、credential、内部 handle 和 hash 不进入普通详情；
- Drawer 底部提供 `Export .skill`、`Modify in new task` 和 `More`。`More` 仅在有精确管理 authority 时包含 `Re-import` 与 `Uninstall`；外部管理资产显示原因并隐藏不可执行动作；
- `Modify in new task` 只导航到预填普通 Text draft，不创建 Skill editor 或专用 Agent protocol。关闭 drawer 后焦点回到原卡片；异步刷新不抢焦点或关闭用户正在阅读的详情。

导入 drawer：

- `Import skill` 打开同一 drawer 体系，首屏突出 Host 原生 `Choose .skill or .zip`，次级入口为 `Choose folder`；当前产品合同尚未开放 Skill 导入拖放，因此不显示不可兑现的拖放热区，也不提供 GitHub、skills.sh、URL、市场或代理配置；Renderer 与 Native SDK UI/input 的边界以[高层架构](architecture.md#31-renderer)为准；
- Native 选择先生成 window-bound、一次性 staged capability；Renderer 只消费 opaque preview identity。Preview 显示名称、description、`SKILL.md`、文件清单、总大小、候选 invocation 和机械安全检查结果；导出同样通过 Host 原生目录选择取得一次性目标 authority，由 Host 生成规范文件名并写入，不让 Renderer提交路径；
- 用户选择 `Personal` 或一个已注册且已授权的 Manual Workspace。范围默认沿用页面筛选，但必须在最终确认中可见；没有合法目标时安装保持禁用并提供恢复动作；
- 同名目录、相同 invocation、project override 或 external asset 都必须在确认前说明精确影响，安全默认是取消；不提供自动重命名 invocation、静默覆盖或“仍然继续”绕过失败；
- `Import` 后 drawer 展示 progress。成功只在资产发布且 catalog 确认可用时成立；候选 definition/resource/conflict failure 回滚并保留 preview，catalog 暂时不可验证时显示 `Installed, awaiting verification` 与 Retry/Uninstall；页面导航和后台 Task 不被冻结。

状态、空状态与恢复：

- 未完成的文件恢复与 catalog 等待验证都进入“需要处理”分组，分别显示“需要恢复”和“等待验证”。详情沿用现有 Retry，严格消费 Host canRetry；需要恢复时不尝试读取可能正在移动的 definition，也不显示普通导出/替换/卸载动作。management 写失败或结果不确定必须在中心级说明重启后重新加载并尝试恢复，即使已没有资产行；不得承诺重启必定修复目录访问或文件占用。
- `ready` 展示已提交 inventory 与 health；`degraded` 保留可用资产并独立展示目录问题。issue 只使用 bounded code、scope 和可选 invocation，不显示 raw diagnostic；
- refresh pending 只禁用 Refresh 并显示 `Refreshing…`；失败保留最后 committed view 并提供 Retry，不清空成“没有 Skill”；
- 首次 `uninitialized/loading` 显示两列 card skeleton；`unavailable` 显示恢复说明与 Refresh；真正 ready/degraded 且当前筛选无资产才显示空状态；
- 全局空状态提供 `Import skill` 与 `Create in new task`。后者只打开预填 Text draft；返回 Skill 中心保留搜索、范围和选中的 Project，不持久化瞬时 drawer/progress；
- delete/uninstall 确认必须写明 personal 或具体 Project 范围，并把安全的 Cancel 作为初始焦点。成功后焦点移到相邻卡片或分组标题；失败保留资产和操作入口，不静默消失。

### 5.4 MCP 服务

> Capability：**目标合同**。Renderer 通过 revision 1 strict snapshot 与 transport-discriminated typed command 管理 Workbench-owned Desired Registry；Runtime/catalog availability、secure secret capture、OAuth operation 和 Admission Authority 是彼此独立的 Host capability/state。任一能力不可用时页面保持可达并只呈现真实可用动作。

MCP 页面与 Skill、Scheduled tasks 使用同一个全局管理页骨架：居中的有界内容区负责标题、搜索、状态分组和连接列表，详情与 Add/Edit 只在用户明确选择后进入可关闭的右侧 drawer。页面不得自动选择第一个服务，也不得在空 registry、无选择或 drawer 关闭时预留第二列。drawer 使用统一的遮罩、焦点陷阱、Escape、关闭按钮和触发点焦点恢复；窄窗占满可用宽度。整体沿用 Workbench 的标题尺度和克制中性色，只用紫色表示进行中的连接、绿色表示成功、琥珀色表示需要处理。

用户模型只有两层：连接服务、选择工具。首次主流程精确收敛为 `Add server → 完成必要认证 → 自动连接并发现工具 → 选择允许的工具 → 新 Task 可用`；同一时刻至多突出一个未完成动作。Add/Edit 保存后，Host 自动完成 preparation、认证条件动作、正式 Runtime apply、MCP activation 和工具发现；普通成功路径不要求先点 Test，也不要求重启 MetaWork。连接测试保留为连接详情内的次级诊断事实，不进入列表主状态、不覆盖正式 Runtime/Admission，也不作为顶部下一步动作。详情顶部的 `Connection → MCP handshake → Choose tools` 轨迹只呈现 Host 能证明的阶段；发现工具但 allowlist 仍为空时，最后一步保持 active 并提供 `Choose tools`，不能显示成流程已完成。

```text
MCP                                                        [ Add server ]
Connect external tools and choose what new tasks can use.

[ Search servers and tools                              ] [ Refresh ]

Needs attention
┃ Search             HTTP · OAuth    Sign in

Available servers
┃ GitHub             HTTP · OAuth    Connected       Enabled  [●]

Disabled
┃ Local database     stdio · static  Disabled        Disabled [○]

点击 GitHub 后：
                                           ┌ GitHub                       × ┐
                                           │ Connection → MCP → Choose tools│
                                           │ Connected    Ready       2/8   │
                                           │ Tool permissions              │
                                           │ Connection and auth           │
                                           └───────────────────────────────┘
```

- Header 只有 `Add server` 主动作与 `Refresh tools` 次级动作。列表占据完整管理页宽度；每个服务行都为带文字状态的启停 switch 保留固定位置，switch 与打开详情的主点击区是并列交互元素，不能嵌套，切换不自动打开 drawer。连接配置被遮蔽或 legacy approval 尚未完成时仍显示 switch，但以 disabled 状态配合同行的明确问题状态引导用户进入详情，不能直接移除控制而让启停能力不可发现。停用只收缩后续新 Task authority且可恢复，直接提交并显示已打开 Task 不变的结果；启用在没有已允许工具时同样直接提交，只有恢复非空 tool allowlist 时才确认并明确将重新开放的工具数量。点击连接的其余区域才打开 detail drawer；Add/Edit 与详情复用同一个 drawer surface，但保持各自清晰标题和提交动作。drawer 可关闭，关闭时保留列表滚动与筛选并把焦点还给原触发点；目标服务从 authoritative projection 消失时同样关闭并恢复到相邻列表上下文。操作仍在进行时不得因 backdrop 或 Escape 丢失未完成状态。Add 在 drawer 中显式选择 `STDIO` 或 `Streamable HTTP`。STDIO 普通路径提供 display name 与一条 launch command；Renderer 以不执行 shell 的 tokenizer 将引号/转义解析为 command + ordered argv，并拒绝 pipe、重定向、变量或命令替换。cwd、额外 argv、environment slot、auth、协议策略和 timeout 收入 Advanced settings。HTTP 普通路径提供 display name 与 endpoint，auth/registration/header 等高级设置保持 typed。OAuth 不出现在 STDIO；不提供 legacy SSE、JSON import 或 generic advanced blob。
- Add/Edit 的提交按钮分别使用 `Add server` / `Save connection`，其显式提交本身授权完整 typed connection，并在同一个 transaction 中保存 connection fingerprint；按钮不声称默认关闭的工具已经向 Task 开放，也不再让用户重复 `Review connection`。Add 默认 enabled 且 tool allowlist 为空，Edit 在底层仍提交完整 replacement，并对新目标重新生成 approval；提交前不产生 child/network/credential/browser effect。schema 1 迁移留下的 unapproved 配置才显示一次 `Connect and enable` legacy action，Renderer 不自行比较 fingerprint。
- Connection approval 后按 auth mode 收敛：None 进入 ready-to-enable；Static 对每个 secret slot 只显示 `Set / Replace / Missing` 和 Host secure-capture 动作，secret 从不进入 DOM、Bridge payload 或 snapshot，`mcpSecretCapture = false` 只使采集动作隐藏并明确显示 Host capability unavailable，不隐藏 Static 配置，也不清除用户的 enabled intent。OAuth 先显示 discovery progress，再由 Host-owned consent 展示 canonical resource、exact issuer、requested scopes、redirect 与 registration plan，用户确认后才打开系统浏览器。缺少 DCR 与 pre-registered client 时回到可操作的 `Existing client required`，不泛化成 unreachable。OAuth operation 全局占用时，其他 OAuth action 显示 busy，目标 server 的替换/删除/授权动作禁用；其他 server 管理和普通 Task 不被冻结。
- 分组顺序固定为 `Needs attention / Available servers / Disabled`，空分组不渲染；状态同时使用细色轨、文字和语义图标。正常产品状态收敛为 `Connecting / Connected / Needs attention / Disabled`。`configurationApply = applying` 显示 Connecting 并冻结冲突动作；`failed` 或 desired 与 Runtime 尚未对齐时显示“配置已保存，重试连接”，调用 `metawork.mcp.applyConfiguration`，不得出现重启要求。desired-disabled 服务始终归入 Disabled。
- 详情依次为连接轨迹、至多一个主要处理动作、Tool permissions、Connection and authentication、默认折叠的 Advanced settings 和危险操作。Tools 显示 discovered、desired allowed 与 available to new tasks 三个事实并提供真实 Checkbox；新发现工具默认关闭。Connection 显示完整 executable/endpoint 与授权状态；秘密值只显示 `Set / Replace / Missing`。`Test connection` 始终是连接详情内的可选诊断，不是正式 apply gate；其 testing/connected/failed 结果只显示在 Connection 区域。正式 Runtime 不可用时，顶部恢复动作只能调用正式 apply 或 refresh，不能用候选测试冒充恢复。`Refresh tools` 只刷新当前正式 Runtime catalog。
- Add/Edit/Enable/Disable/Delete 成功保存后自动 apply；Rename 与 tool-only mutation直接更新对应产品事实。apply 成功才原子安装新 Manifest/Activation/Admission，失败保留已保存 desired 并允许重试。已打开 Task 保持创建时 authority；UI 不暗示即时撤权。Delete、批量放行和恢复非空 tool allowlist 的 Enable 使用 modal confirmation；Disable 与不恢复工具权限的 Enable 直接提交。`runtimeAlignment = unknown` 或 management outcome unknown 时禁用普通编辑并隐藏未经确认的 desired 列表，但恢复文案也不得要求重启。
- Refresh 只刷新当前 Runtime catalog，不应用 pending connection configuration，也不隐式发起 OAuth。refreshing 时禁用会与 catalog/authority 冲突的动作；失败保持 fail-closed new Task access，不恢复旧 catalog selection。OAuth success/refresh 只有同一 consent epoch 的 token revision 可以原子替换 Runtime HTTP auth snapshot；已开始的请求完成后才释放旧 snapshot，既有 Session 的 tool selection 不变。`reauth_required` 禁止新 Task 获得该 server，但不宣称已撤销既有 Session authority。401/403 scope challenge 进入 `Sign in again`，consent 显示原 scopes 与新 challenge scopes 的 union，不自动循环重试失败 tool call。
- Host projection 发布完整非敏感 typed connection：STDIO 的 command/ordered argv/cwd/environment name，Streamable HTTP 的完整 endpoint/header name，以及用户选择的 OAuth registration plan、公开 client id 和 token endpoint auth method。environment/header value、credential locator、client secret、token、code、PKCE、动态注册所得内部材料、raw OAuth document、schema、fingerprint 和 AgentCore handle 仍不进入 Renderer。`redacted = true` 时明确说明 Host 移除了敏感文本，对应 `connection = null`；该状态优先于 approval/auth/desired presentation，进入只读恢复面，禁用 Connect、Enable、Edit、Test、Rename 与 tool mutation，只保留 Delete 后重新添加，不以摘要或空表单冒充旧配置。
- 所有 mutation 使用当前 `expectedDesiredGeneration`，长 OAuth 流程额外使用 opaque server-bound operation id；无关 server mutation 不使 operation stale，Renderer 不参与 rebase。outcome unknown 由顶层 management health 接管，不能盲目重试；启动发现遗留 OAuth operation 时只提供 `Sign in again`，不提供 Resume。Cancel 若发生在 DCR/token request 可能发送之后，结果必须显示 `Sign in again` 而不是 `Cancelled`。DCR outcome unknown 的说明必须明确再次尝试可能在远端创建另一个 client，不能暗示 MetaWork 已撤销或复用了未知 registration。
- 空 registry 是可管理的正常空状态，显示 Add server；management capability 未接通才显示不可用说明。没有 MetaWork-owned 可信 catalog、签名与 publisher verification 前不显示 marketplace、推荐、publisher trust、Resources、Prompts、Apps、Tasks、Workspace override 或占位入口。交互基线参考 VS Code、Claude、Cursor、Continue 与 Hermes Desktop，但不复制其配置格式、市场数据或信任结论。

### 5.5 定时任务

> Capability：**当前**。Workbench 拥有持久计划定义、recurrence、后台 timer admission、missed-run reconciliation、occurrence history 与通知事实；AgentCore 只执行触发后创建的真实 Run。主窗口关闭后 Host 继续在后台运行，重新启动后从 canonical store 恢复。

定时任务是与 Skill 中心同级的全局自动化页，不跟随当前 Task 的路径上下文，也不要求先创建交互式 Task。Task 回答“这一次做了什么”，Schedule 回答“何时自动触发”，Skill 回答“可选地如何执行”；页面不把三者做成父子信息架构。

没有已安排任务时，首屏先帮助用户找到值得自动化的工作，不展示空白工程表单：

```text
定时任务                                      [新建定时任务]

建议

◌  每日工作简报   工作日 8:00
   汇总今天的安排、待办和需要关注的工作

▣  每周项目回顾   周五 16:00
   将本周进展、决定和后续行动整理成状态更新

+  跟进监控       工作日 9:00
   定期检查指定事项，只在出现值得关注的变化时通知

```

空态直接展示建议模板，并由页首 `新建定时任务` 承担自定义创建；不增加无法可靠推导时间规则的自然语言快捷入口。已有定义时才切换为搜索工具栏，过滤标题和任务指令；下面按 `需要处理 / 进行中 / 已暂停 / 已完成` 分区呈现连续列表。建议不与用户定义混在同一状态分区。

- 建议行是可执行模板，不是静态示例。整行点击进入创建确认层，预填任务说明、recurrence 和通知；自定义创建始终使用页首统一入口，不建立第二种创建协议；
- 当前建议和自定义计划都直接使用自动工作区，不得因为标题或说明提到“项目”“工作区”或某个 Skill 就切换到 Manual Workspace；页面不显示 Workspace 配置；
- 页面沿用 Skill 中心最大阅读宽度与克制的连续列表，不使用统计卡、流程画布或常驻左右分栏。每行显示识别图标、名称、自然语言计划摘要、短说明、下一次/最近结果；hover 才显示 `···`，键盘 focus 时动作同样可见；
- 创建/编辑使用右侧 drawer，窄窗切为整页。按 `名称`、`任务内容`、`权限`、`运行时间`、`确认摘要` 排列，名称输入始终位于表单最上方。权限只显示已接通的 profile，新建时采用当前默认值，编辑时显示定义已固定的值；帮助文案明确无人值守运行在权限不足时停止并进入待处理，不提供临时升级或后台审批。任务内容只有一段 Text 指令，不提供 Workspace、Skill 类型切换、Skill 选择器、catalog revision 或参数配置；需要采用某个全局 Skill 时由用户在指令中说明。每次 occurrence 由 MetaWork 分配新的 Automatic Workspace，界面不要求用户理解或选择 Workspace；
- Host 投影 `automaticWorkspaces = false` 时，Text 模板仍可查看，但创建/编辑不可保存；不得静默采用当前或第一个 Manual Workspace；
- 时间选项优先呈现一次、每小时、每天、工作日、每周与每月，并明确本地 timezone；高级固定间隔可折叠，Renderer 只提交 Host 可验证的结构化 recurrence，不拥有 timer 或 occurrence；
- 保存前提供一句完整确认摘要，例如“每个工作日 08:00 运行「每日工作简报」，结果完成后通知我”；protocol、generation、Unix seconds 和 catalog revision 不进入产品文案；
- 新建和保存从同一 snapshot 的 Models global default 与 `newTaskAdmission` active authority 构造完整 source-qualified binding；Renderer 不展示 protocol/revision，也不从 Account 或裸 model id 猜测归属。保存、暂停/恢复、立即运行和删除使用 Host typed result 与 optimistic `scheduledTaskEpoch`。命令 timeout 后先刷新 canonical snapshot，不自动重放；
- 点击计划打开 detail drawer：上半部是定义与下一次运行，下半部是有界运行历史。每个 occurrence 链接到其真实 Task，并显示完成、失败、已跳过、延迟或等待处理；结果历史不复制 Task timeline；
- 删除计划不停止或删除已经创建的真实 Task；`立即运行` 也通过同一 occurrence 与 Task admission，不能建立测试/手动专用路径；上一次真实 Task 仍 non-terminal 时显示 `已跳过：上一次仍在运行`；
- 模型 authority、Workspace authority 或定义固定的非交互 PermissionProfile 不再满足时显示 `需要处理`，并要求用户编辑确认；立即运行与恢复启用在确认前禁用。occurrence 不得进入同步 Agent permission wait。未覆盖操作使该次运行以 typed 原因停止，通知只定位真实 Task 和处理原因，不提供远程批准、临时升级或继续原 Run；
- Schedule store 只使用当前 schema 1；旧 shape、未知 version 或损坏数据只进入通用持久化恢复确认面，不向 Renderer 发布迁移状态或历史 binding。确认恢复时必须明确说明原文件会保留为恢复副本；
- 每次 default occurrence 创建新的真实 Task 与 Automatic Workspace；同一 occurrence 所属 Task 的后续 Run 复用该目录。运行历史链接 Task，不展示 automatic `workspace-key`；目录保留不等于 Host 重启后恢复 Task。
- 页面不再显示“仅在 MetaWork 运行时触发”限制条。窗口关闭时 MetaWork 留在系统后台并继续计划；显式退出通过托盘动作完成并在确认中说明影响，重启后定义与触发游标从 Host store 恢复；
- 已有定义时的搜索使用 `type="search"`；分区是带可访问名称的 region/list；模板行、任务行和 overflow 动作都有明确 button 语义。drawer 打开后焦点进入标题/说明，`Escape` 或关闭动作回到原触发行；运行历史更新不抢焦点。

### 5.6 Task 分组与排序

Task 按行动优先级分组，而不是全部按时间混排：

```text
Needs your attention
Running
Queued
Recent
```

- 空分组自动隐藏；
- `Recent` 内部按更新时间排序；
- Task 列表项只显示任务名称与必要状态信号，不在名称下追加 Workspace、`Default / 默认`、模型或其他配置标签；同名 Task 仍保持原名称，由用户按需重命名，不用第二行元数据替代命名；
- 运行中、排队、等待用户、失败和中断使用图标和颜色共同表达；可访问名称通过 `aria-label` 和 tooltip 提供，不在行内保留文字状态标签；
- 后台 Task 产生待处理请求时必须进入 `Needs your attention`；
- 不能只用绿点、灰点区分状态。

### 5.7 创建、命名、归档与删除

- 点击 `New task` 只打开空白任务页；第一次发送后才创建真实 Task，避免空记录；
- 标题根据首条用户指令自动生成，用户可以重命名；
- 归档从日常列表隐藏，但保留记录和引用；
- 只有已归档 Task 提供删除；删除会先收口仍存活的 Session，再移除 Task 记录，不自动删除 Workspace 中生成或修改的文件；
- 删除进入 `deleting` 后禁用该 Task 的重命名、恢复归档和重复删除，等待 Host 自行推进；进入 `failed` 时保留归档 Task、显示失败信号并重新开放同一删除动作，Renderer 不显示或编排 checkpoint、Session release 等内部阶段。若此时 Task 已回到 `open`，用户也可以恢复归档并由 Host 原子清除失败的删除用例；仍为 `closing` 时只开放删除重试；
- 删除确认必须明确说明文件不会被删除；
- queued、running、waiting_user 或 stopping 的 Task 不能归档或删除；必须先停止或明确取消并等待真实 terminal 结果。

### 5.8 左下角账号入口

Workbench 左栏底部固定显示 Metask identity：头像或首字母、显示名和简短连接状态。它同时是账户与应用轻量菜单的触发器，不显示完整 API Key，也不承担模型快速选择。

点击后打开轻量菜单：

```text
张三
Metask 已连接

设置
关于
─────────────────────────
退出登录
```

- “关于”是本地产品级动作，位于设置之后、退出登录之前；菜单项不重复展示产品名或版本，也不新增常驻侧栏行、Workbench 一级导航或设置分区。点击后打开紧凑模态窗，只展示 canonical Logo、产品名、Metask 开发者归属和从 `app.zon` 构建注入的版本；只有已有真实、安全 consumer 的官网、隐私、许可或更新能力才显示对应入口，不渲染宣传文案、占位动作或死链接；
- About 不依赖 Account、Models、Bridge snapshot 或登录状态。没有 durable Task 而停留在独立登录/连接恢复表面时，使用同一弱化入口打开同一弹窗；菜单与触发器的无障碍名称必须表达“账户与应用”，不能继续声称只包含账号动作；
- 账号菜单中的退出登录在当前 Workbench 上直接打开危险操作确认框，不先导航到设置；确认文案说明本机 Account 凭据会被清除、本地 Task 与历史记录会保留。Account logout 不等待 Product execution replacement 或 Schedule scrub；后续 Product cleanup 失败由 Execution/Schedule recovery surface 表达，不能补写 Account error。账号设置可以保留同一 Host 命令的独立退出入口，但不是账号菜单退出的必经路径；
- 账号菜单只负责身份和导航；Metask API/model目录与用户管理的服务都进入 Models设置，不成为 Account字段；
- 未登录时保留本地 Workbench 历史，并把左栏账号入口切换成登录动作。

## 6. Task 生命周期

> Capability：**混合**。四轴 Run/Task 状态、单 Task 单 in-flight Run 与只读跨重启产品历史属于当前合同；Agent Session/Conversation continuation 和显式 rebind 属于目标能力。

### 6.1 核心规则

- 每个 Task 同时最多一个 active operation；当前 operation 可以是 Run、manual compact 或 Conversation restore，三者不能并发；
- 每个 Task 创建时建立第一个 execution binding epoch，固化不含 secret 的 protocol 与 opaque execution generation，并让对应 Agent Session 持有 owned ExecutionConfig；模型是独立的 Task binding，Product Control 以 `modelSelectionAvailability` 发布跨 owner 可用原因，Renderer 不比较 Models/New task/Task 字段重建 authority。切换不修改 `binding.epoch`；默认连接/API/credential authority 变化不静默改写已有 Task，并使其模型控件只读；
- 多个 Task 可以后台运行，超过 Host executor 能力时明确排队；
- 切换 Task 不停止执行；
- `Stop task` 只停止当前执行，不删除历史、输入或已有文件；
- 一次执行完成后 Task 回到空闲，可以继续补充要求；
- `Failed` 表示得到明确失败结果；
- `Interrupted` 表示 Host/Core 生命周期被破坏，结果可能不完整；
- 中断后不得自动重放可能有副作用的工具。

### 6.2 状态模型

不得把 Task 生命周期、当前 Run 阶段和最近一次 Run 结果压成一个 enum。Host projection 提供 Task 状态和逐 Run terminal 历史，Renderer 从最后一个 terminal Run 派生最近结果与展示标签，不接收或维护 Task 级结果副本。

| 状态轴               | 值                                                    | 含义                                            |
| -------------------- | ----------------------------------------------------- | ----------------------------------------------- |
| Task lifecycle       | `open / closing`                                      | 当前 attachment 是否正在收口                    |
| Archived             | `false / true`                                        | Task 是否参与日常列表                           |
| Deletion status      | `idle / deleting / failed`                            | 删除用例的等待、进行中与显式重试事实            |
| Active operation     | `none / run / compact / restore`                      | 当前占用唯一 Session operation 槽的操作种类     |
| Active Run phase     | `none / queued / running / waiting_user / stopping`   | `run` operation 的调度、工作或等待状态          |
| Active compact phase | `none / queued / compacting / stopping`               | `compact` operation 的调度、工作或取消状态      |
| Last Run outcome     | `none / completed / cancelled / failed / interrupted` | 最近一次 terminal Run 的结果，不关闭 Task       |
| View sync            | `ready / syncing / failed`                            | Renderer 是否拥有可安全 mutation 的最新投影视图 |

`draft` 是进入 Workbench 后、尚未创建真实 Task 的 Renderer 临时页面，不进入 Host Task lifecycle。它默认持有 Automatic Workspace intent，也可以切换到 Manual Workspace identity，并可持有不修改 global default 的 runtime-only 同源模型选择；发送前必须同时满足相应 Workspace admission、默认执行配置与所选模型 authority。一次 Run 完成后 `Active operation` 与 `Active Run phase` 回到 `none`，`Last Run outcome` 保留结果。Manual compact 完成后 active operation 同样回到 `none`，其 outcome 进入独立、有界、append-only 的 maintenance history，不改写最近一次 Run outcome。Conversation restore 完成后 active operation 回到 `none`；成功只改变 runtime attachment/continuation，失败只改变派生的 unavailable reason，二者都不新增 Run、消息或 maintenance history。

Execution binding availability 是下一次 admission 的独立前置事实，不得塞入上述四个状态轴或改写最近一次 Run 结果。Host projection 只发布 `available / rebind_required / unavailable` 及脱敏原因；Renderer 不根据当前默认模型自行判断能否继续。

### 6.3 展示标签与优先级

| 条件                                  | English UI           | 中文 UI      | 主要动作                    |
| ------------------------------------- | -------------------- | ------------ | --------------------------- |
| draft page                            | New task             | 新建任务     | 输入并发送                  |
| view sync = failed                    | View unavailable     | 视图暂不可用 | 重试同步，禁止危险 mutation |
| run phase = waiting_user              | Needs your attention | 需要你处理   | 回答、批准、拒绝或停止      |
| run phase = stopping                  | Stopping             | 正在停止     | 等待真实结果                |
| run phase = running                   | Working              | 正在工作     | 草拟下一条指令或停止        |
| run phase = queued                    | Queued               | 排队中       | 停止                        |
| no active Run + outcome = completed   | Completed            | 已完成       | 继续输入、打开结果          |
| no active Run + outcome = cancelled   | Stopped              | 已停止       | 继续输入或重试              |
| no active Run + outcome = failed      | Failed               | 失败         | 修复问题、重试或继续        |
| no active Run + outcome = interrupted | Interrupted          | 意外中断     | 查看说明并明确继续          |

表格按优先级匹配。`Completed` 等 terminal 标签只描述最近一次执行；归档状态由独立标记表达，不得覆盖需要处理或正在停止的运行状态。

连接失败必须按可恢复边界呈现：只有 bootstrap `connect` 明确返回 Renderer Bridge identity 或 revision 不匹配时，才显示“组件不匹配”并要求关闭后重建或安装；snapshot、revision notification 或 Host signal 的 malformed/unknown payload 仍然 fail closed、禁止 mutation，但显示对应的视图读取失败、技术来源和显式重新连接入口，不能伪装成已经证实的组件版本问题。

没有 active Run 且 execution binding 为 `rebind_required` 或 `unavailable` 时，左栏仍保留最近一次 Run 的 outcome；Composer 区域另外显示 `需要确认执行配置` 或 `当前无法继续`。不得用 binding 问题把历史结果改标成 Failed，也不得继续显示可发送输入造成错误暗示。

### 6.4 跨重启 Conversation 恢复与 execution rebind

> Capability：**已接通**。Workbench 可以从最新 finalized checkpoint 恢复原 Conversation attachment；这只覆盖正常 Application 重启，不代表独立 AgentCore Worker crash、in-flight Run 或 suspend/resume 已可恢复。显式 execution rebind 仍是未来能力。

当前恢复规则：

1. Host 从 bounded Workbench store 恢复 Workspace/Task、消息、Run/tool/UI 决策、compact 历史、无 secret execution binding 与 checkpoint record；不得把当前默认配置静默写入历史 Task；
2. 没有 live owner 的 non-terminal Run 或 compact 显示为 `Interrupted`，不显示 Running/Stopping，不自动重放输入、工具或 permission；
3. 点击左栏 Task 始终只是导航。满足资格的 detached Task 使用普通 Composer，不显示恢复卡片、恢复按钮、专用 placeholder 或其他 capability continuity 提示；用户发送第一条新消息时，Renderer 才在同一次发送意图内提交现有 restore，并等待 Host snapshot 确认 attachment 后继续提交该条 Run；选择、reload 或 timeout 不会自动触发 restore；
4. restore 只表现为该次普通发送的 preparing/busy 状态，期间禁用发送、compact 和重复提交，不显示 `Restoring conversation / 正在恢复对话`。左栏可以把该 Task 归入正在运行分组，但不能伪造 Agent Run 或 Stop 按钮；
5. restore 失败时保留可阅读历史、用户草稿与稳定原因，并显示准确、可执行的失败说明；Host 仍发布 `continuationRecoveryAvailable = true` 时，下一次普通发送重试同一前置流程，不建立专用 `Try again / 重试` 按钮。timeout 只触发 canonical snapshot resync，绝不重放 restore 或 Run；
6. 成功后 Host 原子发布 attachment 与 `continuationAvailable = true`，Renderer 只在这一状态确认后提交一次 Run。`continuationAvailable`、`continuationUnavailableReason` 和 `continuationRecoveryAvailable` 是同一 continuation 模型；不得建立第二个 `recovery.state` 或由 Renderer 猜测资格；
7. checkpoint、Task/Workspace/Execution identity、Agent Runtime 或 checkpoint store 任一恢复事实不满足时显示对应 unavailable 说明，不开放该历史 Conversation 的恢复发送。Workspace 是否因导航语义 `visible=false`、Skill catalog 是否 ready、MCP selection 是否可重建、Permission 是否仍有效、projection capacity 以及 Task persistence health 都不是 Product Task 的全局运行资格；这些可选能力缺失时 Host 可以发布成功但 degraded 的 attachment，普通 Text 立即可用，相关能力按各自现有显式流程恢复。Task store read/corrupt/write/outcome-unknown health 由 Host 发布，Renderer 只提示，不自行清空、修复、迁移或阻塞 mutation；
8. `closed` 不是 Task 产品状态。非归档 Task 只要 Host gate 允许，就应恢复 attachment 并继续；归档只控制日常列表可见性，删除才永久移除记录。

恢复要求 checkpoint record 与 Task execution binding证明 source Task/binding、protocol、Task binding epoch和 terminal anchor精确，当前 execution authority则作为独立 target readiness：protocol相同、Task pinned model仍在当前 Models catalog，且 restore start→commit期间 target generation不变。历史 H与当前 G可以不同；H≠G时 Host必须先以 durable adoption同步推进 Task execution generation、binding epoch与 checkpoint anchor epoch，commit成功后才安装 attachment，旧 Run的 generation/model/usage不改写。checkpoint的 model只用于满足 AgentCore restore expectation，并与其 terminal Run历史 model自洽校验；candidate提交前由 Host以 Task当前 model binding调用 `session_set_model`，不能把 checkpoint旧 model或 Models当前默认 model静默写回 Task。durable Task不保存 account、API Key或 Custom Provider identity，恢复不能从当前 Account/Models projection反推或补写这些字段。该 adoption只连接同一 Conversation的 source与兼容 target，不允许切换 protocol或 Task model；未来通用 rebind仍必须由用户明确发起，重新校验 Workspace和当前 catalog ownership，创建新 binding epoch/Session，并以不可改写的配置边界保留旧 Run、usage与模型归属；失败不得回退到静默默认值。

## 7. 中间区域：Task 内容

> Capability：**混合**。用户输入、Agent 可见输出、permission、typed activity、Tool 摘要与 Run 状态属于当前产品路径；typed Delivery、Outputs、FileChange 与 Plan 仍是未来 capability，当前不得从 Agent 文本或 Tool 记录推断。

中间区域使用同一套 MetaWork AI UI 基础语义：`Conversation` 组织阅读面，`Message` 表达用户与 Assistant 发言，`Activity` 表达当前过程与必要终止状态，`Intervention` 表达真正需要用户介入的决定，`Composer` 控制下一步输入，`Markdown` 与 `CodeBlock` 呈现回复内容。它们是 Renderer 视觉语法，不把 Bridge 或 AgentCore 对象直接变成组件。当前不存在第二套 Task 专用消息、状态、请求或输入表面，也不以 Tool、Reasoning、Question 或 Approval Card 建立平行组件分类。

### 7.1 内容模型

Task 按稳定 Run 顺序显示 `Run exchange`：用户指令之后依次是 `Assistant process narrative → Live status → Intervention → Response → Technical work evidence → Terminal notice`，不存在的部分不占位。process narrative 按 Host 保存的 closed commentary group 顺序连续承载多个 Markdown block，并在其后承载未定性的可回滚 provisional，是用户理解 Agent 当前方向的主阅读内容；block 只用正文留白区分，不增加卡片、时间戳、Tool 标签或阶段标题。live status 是位于当前过程底部、随唯一 Current activity 原位更新的一行状态；technical work evidence 才承载按 Host order 排列的 Tool 摘要，并默认折叠。它们属于同一 Run，不是不同说话者，也不构成 raw 事件时间线。Response 是已由 Host 定性为 final/partial 的正式主阅读内容。Renderer 只做纯 presentation derivation 和会话内 disclosure，不复制 Product 状态机。

### 7.2 Agent 对话渲染机制

Agent 对话不是 CoreEvent 列表、Tool timeline 或逐 chunk DOM append。它是 Product Task 已经定性的完整 Run projection，经 Bridge full Snapshot 进入 Renderer 后，再派生为稳定的 Run exchange。唯一 owner 链为：

```text
AgentCore typed CoreEvent
  → Product Task：output / activity / tools / terminal facts
  → Renderer Bridge revision 1：完整 Run snapshot
  → deriveRunPresentation(run)：纯 presentation derivation
  → TaskContent：稳定 Run exchange 槽位
  → RunProcess：active status 或 terminal technical evidence
```

各层职责不可互换：

- Product Task 独占 output-segment 定性、commentary 边界、provisional rollback、Current activity、Tool lifecycle、terminal outcome/cause 和 credential-safe projection；
- Bridge 运输完整 typed facts，不运输 raw event identity、时间线、private reasoning 或组件状态；
- `deriveRunPresentation()` 只派生 active、response/process visibility、Host-order Tool 列表、唯一 running Tool presentation 和 terminal notice 条件，不保存或推进产品状态；
- `TaskContent` 只按 Task/Run 稳定 identity 组合槽位，不把 Snapshot revision 当消息、不从文本或 Tool 内容推断新事实；
- Renderer 本地只拥有 Task+Run disclosure、Tool focus request、每 Task 阅读位置和 following-latest 等可丢弃 UI 状态；reload 后它们可以重置，不能写回 Product history。

每个 Run exchange 使用以下条件槽位，而不是为每类事件创建节点：

| 槽位                     | 出现条件                                                   | 更新方式                                                             |
| ------------------------ | ---------------------------------------------------------- | -------------------------------------------------------------------- |
| User instruction         | Run 存在                                                   | 历史稳定，不随 activity 更新                                         |
| Process narrative        | 至少一个非空 commentary、provisional 或必要 redaction note | closed commentary 只追加稳定 block；provisional 原位增长、迁移或回滚 |
| Active process surface   | Run 为 queued/running/waiting UI/stopping                  | 唯一 live status 原位替换；存在 Tool 时同一 surface 才可展开技术行   |
| Intervention             | 当前 Run 存在 pending UI                                   | 只显示唯一可操作控件，不伪装成 Assistant 文本                        |
| Response                 | Host 已发布非空 final/partial response                     | 安全 Markdown；出现不等于正式 Product terminal 已发布                |
| Terminal process surface | Run 已 terminal 且存在 Tool record                         | 位于 response 之后，弱化为默认折叠的“工作过程 · N 项操作”            |
| Terminal notice          | partial、非 completed outcome 或完成但无 response          | 与 partial 合并为唯一准确提示，不重复成功结果                        |

`RunProcess` 是 active 与 terminal 共用的同一 presentation surface，但生命周期位置和职责不同：

```text
active Run:
  narrative
  RunProcess = live status header + optional collapsed Tool body
  intervention
  response

terminal Run:
  narrative
  response
  RunProcess = weak technical summary + optional collapsed Tool body
  terminal notice
```

active→terminal 时，live activity 必须消失，technical evidence 移到正式回复之后；Task+Run disclosure choice 保持不变，不因 revision、Tool completion 或 terminal 自动展开/折叠。没有 Tool 的 terminal Run 不保留空 process surface。

#### Output projection 与可见迁移

Renderer 每次只读取当前完整 `RunOutput`，不在本地累积 text chunk：

| Host output 状态                              | Renderer 行为                                                  |
| --------------------------------------------- | -------------------------------------------------------------- |
| open/continued segment 有安全 committed bytes | 作为 commentary 后的纯文本 provisional 原位显示                |
| segment 关闭为 commentary                     | provisional 对应内容迁入新的稳定 commentary Markdown block     |
| segment 关闭为 final/partial                  | provisional 清空，内容进入独立 response Markdown 槽位          |
| segment 关闭为 discarded                      | provisional 从下一 Snapshot 消失，不保留撤回占位               |
| closed commentary 已持久化                    | terminal、reload 后仍按原 group 顺序恢复                       |
| response 已定性但 terminal 尚未发布           | response 可以显示，同时 active process surface 保持 finalizing |
| formal terminal 已发布                        | activity 必须为 null；未决 provisional 必须为空                |

因此 provisional 在 DOM 中迁移或消失是 output-segment 协议的产品语义，不是 Renderer 自行重排历史；commentary array index、Run identity 和 Tool product identity 才是稳定渲染 key。credential 清理可能使某个 commentary item 为空，但 Renderer 不合并相邻 item，也不改变后续边界。

#### Activity 与 Tool presentation

非 terminal Run 必须有唯一 canonical activity；terminal Run 必须没有 activity。Renderer 不复制 activity 状态机，只把 Host activity 本地化并做两项有界派生：phase 缺失时只能使用同 phase 的防御性通用标签，`executing_tools` 且恰有一个真实 running Tool 时可以把固定 Tool identifier 映射为“检查工作区”“更新内容”或“运行操作”。多个、零个或未知 Tool 时回退到 canonical activity，不读取参数、结果或历史 Tool 推断 Agent 当前意图。

Tool start/progress/result 只更新同一 Tool record 和 process surface，不在主阅读流追加行。active Run 中展开技术过程只用于检查当前证据；terminal 后相同 Tool records 转为弱化历史摘要。展开后的 Tool 行显示名称、状态、Host elapsed，并可附 Host 安全 description、有限 progress 摘录和已有 fileRefs；完整输入和结果在用户点击对应 Tool 后于 Task Panel 挂载，同刻至多一个对象详情。

#### Snapshot revision、阅读位置与稀疏输出

ProductDelivery 可以合并短窗口 revision，但跨窗口更新必须以新的完整 Snapshot 到达。Renderer 对每个 Snapshot 重新执行纯派生：commentary block 稳定追加、provisional 原位变化、activity 原位替换、Tool 行按 Host order 更新，不能把 revision 数或事件次数显示成进度。用户正在 following latest 时才自动滚动；用户上滚后任何流式更新都不得抢回位置，只显示 `Jump to latest`。

真实 Provider 没有提交新 commentary 或 provisional 时，主阅读流保持不变，只显示当前 canonical activity 和按需技术证据。Renderer 不重复状态行、不从 Tool 结果生成总结、不展示 thinking 正文，也不通过动画、计时器或伪百分比制造推进感。scripted Provider vertical 证明的是这套机制可以持续交付已存在的事实，不代表真实 Provider 的叙事频率。

#### 本轮耗时

活动状态旁可以弱化显示 Host 采样的“本轮已用时”，包含排队、等待批准和重试；仅表示经过时间，不表示进展或健康。Renderer 从完整 Snapshot 的本地接收时刻低频外推，切换 Task 不重新起算，reload 后使用新 Host 样本；terminal 后移除，不新增历史耗时展示。计时必须位于状态读屏 live region 之外，不触发逐秒播报、自动滚动或逐秒 Snapshot；计时变化不能用来生成叙事、推进状态或判断超时。排队与启动使用不同文案。

### 7.3 用户指令

- 使用浅紫色“任务指令”区块，最大宽度约为正文的 72%，靠右但不使用聊天尾巴、头像或左右双方气泡布局，也不重复显示“你”等归属标签；在窄窗口下可以放宽到约 88%；
- 首条指令建立 Task 目标，后续指令作为明确的补充或重试节点；普通界面不显示 Run ID；
- 附件以文件/目录 chip 展示名称、数量和大小；
- 已发送内容不能静默编辑历史；
- 未来的“编辑并重新运行”必须显式创建新的执行分支或新 Task。

### 7.4 Agent 回复

- 不使用头像和大气泡，使用正文排版；
- 支持 Markdown、表格、代码、引用和链接；
- commentary 作为 Assistant 过程叙事按 Host 提供的有序 group array 渲染为同一 Assistant message 内的独立 Markdown block；Renderer 不自行按换行切组，也不按 chunk 或 Tool 穿插伪造顺序。Host 发布新的 closed commentary group 后，主阅读流随 Snapshot revision 追加一个稳定 block；
- `final | partial` response 使用安全 Markdown；尚未收到 output-segment 定性的 provisional 紧随 commentary 以中性纯文本呈现，不称为草稿、不解释 Markdown，discard 后随下一 Snapshot 消失；流式生成只显示克制的单一活动指示；
- 不展示原始 chain-of-thought；`thinking_chunk` 只显示“正在思考”的安全状态，`text_chunk` 开始后显示“正在撰写回复”；Renderer 还必须把 Host 已投影的 Starting、Waiting model、Executing tools、Retrying、Compacting 与 Finishing 显示为本地化 Current activity，并在 Host 提供时显示 retry attempt/max/delay；不同 activity 必须保持可理解的差异，不能把整个 active Run 统一退化成一个不变的“正在工作”；
- output 只表示 Agent 可见输出，不标记为 Delivery、Output artifact 或最终成果；
- 不从回复文本解析活动、计划、文件变化或完成状态；不得为每条内容重复“Agent”标签或品牌头像。

### 7.5 当前状态、请求与结果

- active Run 只显示一个来自 canonical phase/activity 的紧凑 live status，并固定在当前过程底部原位更新；它不为 Tool start/progress/result 追加时间线记录。`executing_tools` 且恰有一个 typed running Tool 时，Renderer 可以依据固定 Tool identifier 映射为“检查工作区”“更新内容”“运行操作”等宽泛但真实的用户文案；不满足条件时回退到 canonical activity，不在主状态中暴露原始 Tool 名称、参数或命令；
- Tool 摘要属于次要 technical work evidence，active 与 terminal Run 都默认折叠；展开内容遵守本节 Tool 证据规则，不带入完整 input/result、usage 或 Run ID。terminal 摘要弱化为“工作过程 · N 项操作”，不单独强调已被整个 Run 恢复的 Tool failure；失败事实仍在展开详情中保留。disclosure choice 按 Task+Run 仅存于当前 Renderer 会话，不写入 Bridge 或持久化，也不随 revision 或终态自动翻转；late terminal observation 不得重新打开 live 状态；
- pending UI 位于当前 Assistant 回复之后、Composer 之前，并提供唯一可操作控件；
- `completed` 且已有 final response 时不追加重复的完成条；空 final response、停止、失败、中断或 dependency failure 只显示准确状态、原因与真实可用的恢复动作；partial response 与 terminal outcome 必须合并为唯一 notice，同时表达“回复未完整生成”和真实终止原因，不能再追加第二条 partial 警告；
- terminal cause 使用最具体的稳定本地化文案：`provider_failure` 显示“模型服务请求失败”，并在同一 notice 中说明本次 Run 未生成可用回复或只生成了可能不完整的部分回复；`tool_failure` 说明工具失败且 Agent 未能恢复，`image_input_unsupported` 明确要求更换支持图片的模型并重新选择图片；不得把三者统一写成“检查模型或网络”，也不得直接展示 provider raw body；
- `provider_failure` 的主区 notice 只表达失败原因、回复影响和匹配的恢复动作，不重复技术诊断边界；若该 Run 已有 Tool 记录，重试前提醒用户先检查工作过程，避免重复外部 effect；
- 失败 Run 的主区“查看运行详情”是该 notice 下的默认折叠 disclosure，仅展开时挂载诊断边界与精确 provenance：`absent` 表示 MetaWork 未收到该 Run 的附加诊断，`withheld` 表示当前安全边界不允许显示已收到的附加技术诊断；均不得猜测 401、API Key、限流、网络或设置问题。字段仅为稳定错误标识、精确 Run ID、该 Run 的 model 和 protocol，不使用当前 Task binding 或 Models 默认值，不默认展示 execution generation；折叠卸载诊断正文。只有当前 Task 真实可重试且输入区无待保留草稿时才沿用既有“准备重试”流程，动作文字必须明确只把指令重新填入 Composer；详情入口本身不触发重试、设置跳转、模型测试或任何外部操作；
- Renderer reload、成功同步、Tool completion 与 Compact history 不生成主区记录；只有同步失败、当前 maintenance 或内容可能不完整时显示相应状态。同步失败或 Bridge 不可用时，保留已有内容，但 active Run 的唯一状态改为“状态尚未同步”、停止活动动效并暂停耗时外推；恢复后以新 Host Snapshot 为准，不因静默时长推断 Agent 卡死，也不自动终止或重跑。停止命令尚未应答时显示“正在请求停止”；应答不等于终态，正式 stopping/terminal 仍由 Host 确认，失败沿用当前 Task 的操作反馈。

### 7.6 滚动与密度

- 用户位于底部时自动跟随最新内容；
- 用户向上查看历史时停止自动滚动；
- 出现 `Jump to latest`，不能强制抢回滚动位置；
- 流式更新不能破坏文本选择、输入焦点或当前阅读位置；
- 每个 Task 独立保存当前 Renderer 会话内的阅读位置和 following-latest 状态，切换 Task 不得继承另一个 Task 的位置；
- `Jump to latest` 是普通长内容阅读能力，不使用 Timeline 命名；不增加改变底层信息可见性的密度模式。

## 8. Composer 与执行控制

> Capability：**混合**。当前 Run gate、停止、本地草稿、New task 主视觉、默认模型选择和既有 Task execution binding 提示已经由当前 Renderer 合同表达；跨重启恢复与显式 rebind 仍是目标能力。

已有 Task 的 Composer 固定在中间区域底部，并为滚动内容预留空间。New task 的 Composer 位于工作面的视觉中心；Host 确认创建真实 Task 后，它再通过一次克制过渡落到底部。

New task 页面以 Composer 为绝对主视觉。其上方使用直接的行动标题和一句 Workspace 工作说明，不使用人格化欢迎语；Composer 下方不放示例、推荐卡片或快捷指令。输入框附近只放与“这次 Task 如何开始”直接相关的上下文：连接与模型、Workspace、文件附件和发送。API Key、连接编辑、账号目录刷新、权限默认值、显示密度与诊断不得堆入同一行。

```text
┌────────────────────────────────────────────────────┐
│ 描述你希望 MetaWork 完成什么……                   │
│                                                    │
│ 模型：当前连接 · 当前模型 ▾                  发送 │
└────────────────────────────────────────────────────┘
  Workspace：metawork ▾
```

模型选择规则：

- New task 默认显示当前 active Provider 与模型；当 Host snapshot 能证明 active source 的 current catalog 可用时，Composer 菜单可以为本次 Task 选择该 source 中的另一个 ready 模型。该 runtime-only 选择不修改 global default，不开放跨 credential 或跨 Provider 候选；重新打开 New task 时恢复 active default；
- 模型不可用或尚未设置 global default 时，Composer 提供进入 `Models` 设置的导航；不得显示完整 secret，也不得直接提交默认选择。草稿已选模型因 catalog/authority 变化失效时保留可见选择、禁用发送并要求重选，不能静默显示或执行默认模型；
- Models默认来源、Metask API/protocol/credential authority或 ready Custom Provider模型变化先更新 Models desired selection及对应 revision/source generation，再由 Product Control独立 reconcile active binding generation。两类变化都不热替换已有 live Task；detached历史 Task可在 §6.4的 Conversation restore中采用同 protocol、可承载其 pinned model的当前 credential authority，并通过窄 binding adoption提交新 generation，任意 protocol/model变化仍只能走未来显式 rebind；
- 已有 Task 的 Composer 显示当前 binding epoch 的模型事实，历史按 epoch 保留原模型；`available` 时菜单列出当前 Metask catalog 候选，即使 pinned model 已离开目录也允许切换到有效候选；`catalog_loading`、`catalog_unavailable` 与 `execution_replacing` 保留菜单但禁用并显示对应原因；`runtime_detached`、`unsupported_source` 与 `authority_changed` 只显示 pinned model 和原因，不展示必然被 Host 拒绝的菜单。以上状态只消费 Host 发布的 `modelSelectionAvailability`；
- 正在更新默认模型时只禁用相关选择和发送 admission，不冻结导航、历史阅读或其他 Task；
- 模型不可用时说明原因并给出刷新或设置入口，不能留下永久 disabled selector。

Composer 布局与输入规则：

- 模型控件位于输入框内部左下角，发送位于右下角；textarea 与底部工具带共同组成一个完整圆角容器，不得拆成相互竞争的表单块。Workspace 位于容器外下方的轻量 breadcrumb 行，不能做成第二个有边框卡片，也不能放回输入框上方形成第二条上下文栏；
- New task 的 global `defaultSelection` 为空时，Composer 在发送位置说明“未设置可执行的默认模型”并提供“打开模型设置”动作；发送保持禁用，直到用户在 `Models` 页明确选择且 Product Control 发布 active binding。Composer 不提交或修改 global default；非默认草稿选择只随首次 Task create 提交 exact source/catalog generation，创建失败时保留以便重试，创建成功后清除；
- New task 的 Workspace breadcrumb 默认选中“默认”，并可以在 Automatic 与已授权 Manual Workspace 之间切换，也可以打开原生目录选择器添加或重新授权；已有 Task 只显示其绑定 Workspace 事实，不提供虚假的切换；
- 输入框不允许用户拖拽改变大小。它随内容自动增高，达到约 7–8 行或视口高度的 28% 后改为内部滚动；
- Automatic intent 不是 Workspace 缺失；`automaticWorkspaces` 可用时普通 Text 可以直接发送。只有所选 Manual Workspace 缺失或授权失效时发送才保持禁用，并在 breadcrumb 中提供明确恢复动作；Workspace 选择和发送是两个独立动作。

Composer 是唯一 active operation 停止入口：

- `queued / running / waiting_user` 时在 Composer 发送位置显示 `Stop task`，替换发送按钮；
- manual compact 为 `queued / compacting` 时在同一位置显示 `Stop compacting`，替换发送按钮；
- `stopping` 时保留该位置的禁用停止按钮，阻止重复请求并等待真实结果；
- 顶部命令栏不重复显示 Task Stop，窗口控制和检查器入口保持全局职责；
- Stop acknowledgement 只表示请求已接受，界面继续等待 canonical snapshot 的真实 terminal；transport failure 不得伪造 `Stopped`。

### 8.1 Slash、Command 与 Skill draft

Slash 是 Composer 的输入手势，不是 CLI 模式。空 draft 的首个非空白字符为 `/` 时，输入框上方打开与 Composer 等宽的候选面；不位于首 token 的 `/`，以及 token 内仍含 `/` 的 URL、路径和代码片段不触发。单段绝对路径与 Slash identifier 在语法上不可区分，若未命中候选则按 unknown Slash 禁止发送，用户需要补充正文语境或改写。候选只有两处真值：

- `Commands` 来自 Renderer 单一 registry，只注册当前产品真实存在且适合从 Composer 发起的动作；
- `Skills` 来自 New task 当前 Workspace catalog，或已有 Task 的 pinned catalog；Renderer 不合并目录、不读取 Skill body，也不按名称跨 revision 猜测替代项。

菜单贴附于 Composer，而不是全局模态命令面板。Command 与 Skill 分组显示，使用确定性的大小写不敏感 prefix/substring 过滤；`ArrowUp / ArrowDown` 移动，`Enter / Tab` 选择，`Escape` 关闭但保留可见文本。菜单打开时 `Enter` 绝不能提交普通 Text；IME composition 期间不打开、过滤或执行。textarea 使用 combobox 语义，候选容器使用 listbox/group/option，并同步 `aria-expanded`、`aria-controls` 与 `aria-activedescendant`。不可用 Command 保留可发现性并显示真实原因。

Command 只是现有动作的键盘入口。选择后由 `App` action controller 消费，不创建 command history，也不把原始 `/command` 送入 Bridge。V1 registry 包含 `/new` 与 `/compact`：`/new` 从已有 Task 打开 New task；`/compact` 在已有 finalized Run、continuation available 且没有 active operation 时触发 typed Task maintenance action。不可用 Command 保留候选并明确显示各自的禁用原因；New task draft 中 `/new` 说明草稿已打开，`/compact` 说明尚无可压缩历史，不能让一个 Command 的 gate 覆盖另一个 Command。`/model`、`/status`、`/goal`、`/resume`、`/continue` 以及其他尚无正式产品 owner/合同的 CLI/TUI identifier 不注册。带尾随参数的 Command 不执行；无法解析的首 token Slash 保持可见但发送禁用，用户必须选择候选、删除 `/` 或改写为普通正文。Command 与 Skill 同名时，裸 `/name` 归 Command，Skill 通过 `/skill:name` 显式选择。

选择 Skill 后，文本 draft 原子变为结构化 draft：左侧能力轨显示可移除的 Skill identity，右侧按 descriptor 顺序显示 positional argument 输入。Renderer 保留 catalog 的 `maxValues`，未命名的可选 positional argument 由用户逐项添加或移除，字段数不得超过该上限和产品的 64 项硬上限；发送前同时校验完整 Skill Run 输入的 64 KiB UTF-8 字节预算。`/review src/main.zig` 的可见尾随文本成为第一个参数，不实现 shell quote/escape parser；每次 Run 至多一个 Skill。Skill 原始 Slash 文本不进入 Bridge 或历史，发送只产生 `{ kind: "skill", skillId, catalogRevision, argumentValues }`。

Skill draft 与 Text draft 一样按 Task/New-task scope 保存在 Renderer session storage；既有 raw Text draft 读取后在下一次写入时单向升级为 tagged storage，暂时超过 Run 提交预算的非空 draft 不得删除已有持久值。发送失败、拒绝或 timeout reconciliation 后恢复完整 tagged draft。catalog revision 或 identity 变化时保留 token 与参数，但显示 stale 说明并禁用发送；刷新是显式动作，成功后仍要求用户从新 catalog 重新选择。已有 Task 的 Workspace current catalog 尚不可用时，同一刷新动作先刷新 Workspace；Workspace ready 后再次执行才刷新 Task binding，不隐式监听、重放或跨 revision 替换。`loading / unavailable` 只影响 Skill 候选，普通 Text 保持可编辑、可发送。

| Task state             | Composer behavior                                                                        |
| ---------------------- | ---------------------------------------------------------------------------------------- |
| draft / idle           | 文本、附件、发送                                                                         |
| queued                 | 允许草拟但禁止发送；Composer 发送位置替换为停止入口                                      |
| running                | 允许草拟下一条指令但禁止发送，显示 `当前任务结束后发送`；Composer 发送位置替换为停止入口 |
| waiting_user           | 普通输入让位于时间线请求，底部提示 `Respond above to continue` 并保留本地草稿            |
| stopping               | 禁用输入，显示 `Stopping…`                                                               |
| compact queued/running | 允许编辑本地草稿但禁止发送；Composer 发送位置替换为停止入口                              |
| failed / interrupted   | 恢复输入，提供针对性的重试或继续动作                                                     |

表中的 `idle` 仍受 execution binding availability 约束；`rebind_required / unavailable` 时以 §6.4 的只读说明和动作替代发送控件。

输入区中的模式选择只有在语义明确时才出现。PermissionProfile 可以在 New task 发送前作为独立、明确标注的策略选择出现，但不得与模型、执行强度或显示密度混成一个“模式”；已有 Task 只读显示 Task-owned effective profile，不提供切换入口，也不显示第三档装饰或 disabled 预告。

运行中的输入不会发送给当前 Run，也不使用未验证的 `UiBackend.poll()` 模拟实时 steering。首版 Composer 只保存 Renderer 本地草稿，发送动作保持禁用并显示 `当前任务结束后发送`；当前 Run terminal 后由用户明确发送。不得自动提交、自动启动下一次 Run，或把草稿伪装成已排队状态。`queued` 只表示唯一已提交 Run 正在等待 Host executor，不表示当前 Run 后面还有另一条队列。未来只有在 AgentCore 发布 typed steering capability 后，才设计 `排队补充` 与 `立即打断` 的不同操作。

### 8.2 文件附件

Composer 工具带在模型控件之前提供一个带可访问名称的“添加文件”按钮，使用系统原生多选文件选择器并接受普通文件；用户也可以把操作系统文件拖入当前包含可编辑 Composer 的窗口，拖入时只在输入框范围显示克制的强调轮廓和“拖放文件以添加”提示。picker 与拖放只是文件接收入口，之后必须复用相同的附件 staging、结果和草稿；不提供 WebView file input 或粘贴替代入口。处理期间只允许一个添加操作，禁止再次添加和发送，文字仍可编辑；字节接收期间添加按钮提供“取消添加”，原生 picker 由系统取消。整批成功后才显示 chip；取消不改变已有草稿，typed rejection 在 Composer 就地说明原因且不产生部分 chip。离开当前 Composer scope 或关闭接收界面取消尚未移交草稿的操作；操作 identity 必须避免切换离开再返回后接纳迟到结果，已经 ready 的附件仍按下文规则保留。

ready 附件按选择顺序显示可换行的紧凑 chip，包含经过 Host 校验的 basename、文件类别与格式化大小，并提供逐项移除按钮。图片额外显示已识别格式；其他文件使用通用文件图标。chip 不显示绝对路径、缩略图、hash、上传进度或 provider wire。文件名保持原文且服从普通用户内容方向规则；超长名称截断，完整安全名称通过 title 与可访问名称提供。键盘焦点按选择顺序进入移除按钮，删除后移到相邻 chip 或“添加文件”。窄窗不得因附件列表产生页面横向滚动。

Text draft 可以为空，只要附件全部是 ready 图片；非空文字固定先于全部附件提交，chip 顺序就是 input part 顺序。经 Host 校验、不超过 64 KiB 的非空 UTF-8 无 NUL 文件以“文本文件”展示并可与图片混合发送；草稿只要含有文本附件，去除首尾空白后的用户指令就必须非空，否则发送按钮保持禁用，不额外显示常驻提示。非 UTF-8、含 NUL、超限或其他二进制内容在整批 staging 时以 typed reason 拒绝，不发布部分 chip。附件不能与 Skill draft 共存：选择 Skill 时若已有附件必须先由用户明确移除，附件存在时选择 Skill 也必须说明该限制，不能静默丢弃任一草稿。模型 metadata 明确声明不支持相应图片媒体时只显示非阻塞提示；发送能力和最终错误仍以 Host admission 与 AgentCore typed result 为准。

附件 token 与 metadata 只保存在当前 Renderer connection 的内存草稿；Task 切换可以保留，document generation replacement、reload 或 disconnect 后必须清除。Renderer 只允许保存一个不含名称、大小、类型和 token 的 generic marker，使 reload 后能提示“未发送的附件需要重新选择”。文字/Skill 仍按既有 tagged session storage 保存。New task 已创建但 Run 尚未接纳时，附件草稿和文字一起迁移到真实 Task；Run 被 Product 接纳后立即清空 draft chip，timeout 先 resync snapshot且不得自动重放。

历史用户指令的附件 chip 只显示已保存名称、类型、可选图片格式、大小和顺序，不含文本正文，不可点击、预览、下载或一键重新发送。AgentCore 返回 `image_input_unsupported` 时，该 Run 以准确 terminal notice 收口，Composer 继续可用，但附件已被已接纳 Run 消费，用户若要换模型重试必须重新选择原文件。

### 8.3 New task 首次发送

首次发送不是一个 UI 原子动作。Renderer 必须区分创建 Task 与启动第一个 Run：

```text
校验草稿与上下文
        │
        ▼
创建 Task
        │
        ▼
启动第一个 Run
        │
        ▼
以 canonical snapshot 呈现 queued / running / terminal
```

| 结果                        | 页面            | 草稿                          | 反馈                                                                            |
| --------------------------- | --------------- | ----------------------------- | ------------------------------------------------------------------------------- |
| 本地 admission 条件不满足   | 保持 New task   | 保留                          | 在 Workspace、Model 或 Composer 就地说明                                        |
| `create_rejected`           | 保持 New task   | 恢复 New task 草稿            | 显示 typed rejection 对应产品文案                                               |
| `create_failed`             | 保持 New task   | 恢复 New task 草稿            | 显示创建失败和恢复动作                                                          |
| Task 已创建，`run_rejected` | 切换到真实 Task | 恢复为该 Task 草稿            | 时间线不伪造已提交指令或 Running，显示启动被拒绝                                |
| Task 已创建，`run_failed`   | 切换到真实 Task | 恢复为该 Task 草稿            | 显示启动失败，不伪造 Running                                                    |
| Run accepted                | 切换到真实 Task | typed command accepted 后清除 | 等待 snapshot 发布 queued、running 或 terminal                                  |
| command timeout             | 先刷新 snapshot | 对账完成前保留                | 由 snapshot 决定留在 New task、进入空 Task 或进入 active Task，禁止自动重复提交 |

只有 Host 已确认创建真实 Task 后，New task 才切换成 Task 内容：行动标题淡出，Task Header 和已确认的用户输入出现，Composer 在约 220 ms 内落到底部，左栏出现真实 Task，焦点留在内容区。`prefers-reduced-motion` 下直接切换。Task 已创建但 Run 未成功启动时仍进入真实 Task，恢复 Task 草稿，不伪造 queued / running。

## 9. 审批与计划确认

> Capability：**混合**。tool permission 属于当前产品路径；Question 虽属于当前 AgentCore ABI，但未进入 MetaWork Agent 能力集合；Plan approval 和其他 typed request 必须等 AgentCore 发布对应 capability。

### 9.1 请求类型

以下请求使用不同语义和组件：

- Tool permission：由 AgentCore request 的 `responses[]` 驱动，当前可取 `Deny once / Deny for this session / Allow once / Allow for this session`；
- Plan approval：`Request changes / Start work`；
- 应用级危险操作：使用原生确认窗口或应用级 sheet。

待处理请求是当前 wait state，不是历史：它显示在当前 Assistant 回复之后、Composer 之前；响应完成后从主内容移除。左栏与当前 Task 的“需要处理”入口只负责提醒；顶部与右栏头部均可提供定位入口以保证全宽 overlay 可达，点击后定位原请求，不在多个位置重复生成可操作按钮。

权限请求只在当前 Task authority 未覆盖、用户决定确有必要、界面能准确说明 effect 且执行层能兑现该决定时出现。原生 Workspace picker、已选 PermissionProfile、当前 Task 已取得的 Workspace/Skill/MCP authority 和操作系统自己的授权都不得被 Renderer 再包装成“信任此工作区”或重复批准。当前 AgentCore payload 只能支撑 compatibility permission 时，卡片忠实显示其 typed tool/request 事实，不从命令文本猜测风险等级、安全性或持久作用域。

### 9.2 请求状态

请求响应后仍留在时间线中：

- Waiting for your approval；
- Sending your decision；
- Allowed once；
- Allowed for this session；
- Denied；
- Cancelled because the task stopped；
- No longer available。

用户点击后立即禁用重复操作，但只有 Host 确认接受后才能显示最终决定。UI wait 没有 Host deadline，只由 answered、cancel、close 或 shutdown 结束；Renderer reload 后必须从 Host 状态恢复，已取消或不再可用的请求不能重新变成可操作状态。

危险批准不能由裸 Enter 触发。

## 10. 权限策略

> Capability：**当前**。PermissionProfile 由 MetaWork 拥有，审批 occurrence 与 Session scope choice 由 AgentCore 拥有；当前产品不定义第三档或跨 Session 持久权限规则。

### 10.1 Permission request

审批卡片只能展示 AgentCore 当前 typed request 提供的 choice。`allow_once` 只批准本次请求；只有 request 带有精确 candidate 时才可展示 Session scope choice。Renderer 不得自行扩大 choice、持久化 grant、显示 `Always allow`，或从工具名称和命令文本推断作用域。

### 10.2 PermissionProfile

当前产品策略只有两档：

```text
请求批准
完全访问
```

- `请求批准`：常规 Workspace 编辑自动执行，当前策略未覆盖的操作请求用户决定；映射为 `accept_edits + unrestricted`；
- `完全访问`：MetaWork 不再为常规工具操作请求批准；AgentCore 核心保护、操作系统权限、服务授权和进程身份仍可拒绝或要求处理。它不是 root、Sandbox 或“信任 Workspace”。

首次默认使用 `请求批准`。New task 直接显示并允许修改本次选择；Task 成功创建后记住其 effective profile，作为下一次新建 Task 的默认值，创建失败或放弃草稿不改变默认值。选择 `完全访问` 的同一菜单动作就是该 Task 的明确授权，不再叠加第二个确认 modal。Task 创建后只读显示自己的 effective profile，Run history 保存 provenance；默认值变化不改写既有 Task，归档 Task 立即禁止新 Run，删除 Task 永久移除其 profile authority。已有 Task 不显示切换入口，Settings 不提供权限入口。

Renderer 只能显示 Host capability projection 声明已端到端支持的两档。两档都必须覆盖 Task-create authority、same-profile fresh/restore、Task persistence、Run provenance、Task archive/delete 和 Scheduled noninteractive；不得用 Renderer preference、AgentCore enum 名称或 mode-change restore 模拟。

## 11. 按需详情与信息归属

> Capability：**当前**。右侧栏是应用三栏布局的辅助容器，Task Panel 是其中承载任务内容的视图；布局开关不属于该视图或任一具体功能，不提供概览根页、日志时间线、任意文件浏览、文件编辑或 Git 操作。

主阅读流拥有叙事、唯一 live status、审批和失败恢复。默认折叠的 Work process 展开规则见 §7.2；点击后打开精确 `taskId + runId + toolId` 的单条详情，并随 Snapshot 更新。不复制整份 Tool 列表，不从 Tool 内容推断 Agent 发言、File Changes 或 Output。完整 input/progress/result 仅在活动详情中以纯文本/代码面挂载，不进入全局搜索或 live announcement。Host 提供可读 Bash 字段时，详情优先呈现 command、exit code、stdout/stderr，并明确空输出及不完整捕获；安全原始详情置于可展开区域。不可解释的结果直接保留安全原始详情，不从空输出推断目录为空或任务完成。

信息按事实的生命周期放置：

- Run 的 input/output/cache read/cache creation 统计不进入对话、任务信息或右栏，也不保留空 disclosure、隐藏组件或兼容入口；Host/Bridge 的统计、持久化和数据合同不变。不合并为 Task 用量，也不推算总运行耗时；
- Composer 仅在当前 attached Conversation 有 Host pressure 观测时显示对应 warning/critical 的可读提醒；只有用户打开后才展示最近观测说明和 current/auto-compact/blocking token 数。没有 pressure 时整块隐藏，即使存在 lastAutoCompact 历史也不创建入口；不展示压缩前后 token、dropped/kept、伪百分比、连续实时用量、raw source Run identity 或跨 attachment 历史。Host 清除 pressure 后提醒与已展开详情同步卸载，不由 Renderer 计时或历史推断恢复；
- Task 标题附近的“任务信息”使用独立 info 图标，仅在用户打开后只读展示固定 permission profile（受 capability gate 控制）与创建时 MCP 三态，不是实时连接状态，不暗示可热附加。不增加通用设置页或第二个概览；
- pendingUi 派生“需要处理”定位入口，不存已读或自动展开记忆；只有原始主区审批提供操作按钮。用户点击定位时，overlay 先关闭再滚动/聚焦原请求；停靠面板保持。新请求自身不触发滚动、焦点移动或面板开合，全宽覆盖时定位入口仍可达。

右栏显隐不属于内容目标。内容可以为空、当前文件预览、指定 Tool 详情或同 Run 修改审查，各内容互斥挂载；未选择有效对象时呈现通用空态。文件预览以对话内联引用为主要入口并保留工作过程的辅助入口，Tool 详情保留对应操作入口，记录审查保留所属 Run 的入口；不扫描文件系统、不自动读取正文。目标只保存身份，不复制 Tool 或 Snapshot 正文。Review 是按文件首次出现顺序纵向展开的连续差异文档，同一 `displayPath` 的稳定顺序记录汇入一个文件区块；不建立记录列表、单条详情页、返回层级、并行标签或旧概览兼容开关。

打开任何对象替换当前模式。关闭右栏清空目标和正文；再次打开保持空态，只有显式选择具体对象才展示详情，不恢复旧正文。切换 Task 清空旧目标，右栏保持用户已选择的显隐；无 Task 或离开任务页面时呈现空态。普通 Run 开始、终态和 Snapshot revision 不关闭仍有效的详情。Review 中单条记录失效只移除该记录及正文；所属 Run、全部记录或其他目标失效才清空目标；目标有效性不控制右栏显隐。

身份有效性必须在渲染前判定，不能仅依赖 effect 清理。文件读取与 diff 请求继续使用精确身份和递增 request generation；关闭、替换、Task 切换与目标失效后，晚到成功或失败都不能覆盖新内容。非活动正文卸载、已读取 bytes 清除；不声称已取消 Host IO。显式重开/刷新重新请求。

保留右栏宽度偏好及第 4 节的停靠/覆盖规则。面板头部提供关闭；键盘焦点返回真实 opener，opener 已消失或 disabled 时回到稳定的 Task Panel 开关。嵌套 menu/dialog/popover 优先处理 Escape，面板尊重 defaultPrevented。关闭右栏不改变 Task、审批或运行状态。

Plan、typed Outputs 与尚未开放的能力不渲染空壳或占位符。

## 12. 文件预览、文件变更与结果文件

### 12.1 文件预览

> Capability：**当前**。可预览目标只来自 AgentCore 已发布并由 Workbench 持久化的结构化 `tool_result.file_refs`；它是按需读取当前文件内容的只读能力，不是 Files changed 或 Output。

- 主要入口位于所属 Run 的已闭合过程说明与 final/partial 回复中：普通文字中的完整文件名、行内代码和显式 Markdown 文件链接，只有能匹配本 Run 结构化引用时才呈现为可点击内联入口。保持原文字与正文行高，使用链接色、下划线、完整 accessible name 和可见键盘焦点；点击直接在右栏预览，不要求展开工作过程。provisional 仍为纯文本；代码块、图片说明和外部链接不做文件识别，也不把未知文件文本伪装成可打开入口；
- 匹配只使用 Host `displayPath`、其显式相对写法及无歧义文件名，区分大小写，不查询文件系统、不从 Tool 参数拼装 authority。同一路径的重复引用为正文入口选择最后一条有序引用以读取当前内容，不宣称它是该句的历史版本或新文件身份；不同目录的同名文件不得仅按文件名选中，未匹配的本地 Markdown 路径不作为网页导航。引用晚到或失效随 Snapshot 更新可点击状态，不触发自动读取；
- 展开的工作过程仍按各 Tool 的 `fileRefs` 顺序提供辅助入口，保留原始来源，与 Tool 详情按钮独立，不嵌套交互控件。这里的文件按钮显示 `displayPath`，具备至少 44px 点击高度，长路径在窄窗内可换行。没有结构化引用时不占位，不把全部引用聚合到回复 footer 或右栏列表；
- 任一入口都按精确引用身份在 Task Panel 打开独占预览；只显示所选文件，不提供全部引用选择器。切换文件从对话内联入口或对应工具操作发起，不需要先打开 Tool 详情；
- 文件预览复用 Task Panel 的唯一头部：标题直接显示当前路径，右侧只提供刷新和关闭图标动作，正文不追加资源副标题、状态标签、常驻说明或信息入口。`.md`、`.markdown`（后缀不区分大小写）默认安全渲染文档，支持标题、列表、表格、引用与代码块，并在正文上方提供“预览 / 源码”切换；切换只使用已读取正文、不重新请求文件。刷新保持当前模式，切换精确文件目标或关闭后重开恢复默认模式，非活动视图不保留隐藏正文；
- Markdown 复用安全 Markdown 呈现边界，不执行内嵌 HTML 或脚本；图片只显示替代文字，不请求本地或远程资源；相对资源链接不作为应用导航，HTTP(S) 链接的显式点击仍服从 Host 导航策略，不新增资源读取或网络权限。文档主体纵向滚动，宽表格与代码块各自横向滚动；
- 普通文本、代码文件及其他已支持的文本格式显示中性等宽源码，保留空白并允许自身横向滚动，不增加模式切换。源码左侧显示从 1 开始的单列行号；行号与正文共用滚动容器，横向滚动时固定在左侧，不进入文本选择、复制内容或辅助技术朗读，只编号当前实际显示的文件前缀且不推断截断后的未读取行数。已识别且处于 Renderer 高亮预算内的代码文件自动渐进增强为主题适配的语法颜色，Markdown 的“源码”模式同样适用；未知格式、超出预算、模块加载失败、grammar 异常或高亮结果校验失败时静默保留完整纯文本，不自动猜测语言、不增加状态、重试、开关或语言选择。HTML、SVG 与 XML 即使显示 markup 语法颜色也始终只渲染惰性源码，不形成真实元素、执行脚本或加载资源，界面不为这一限制增加常驻提示或说明入口。只有具备经验证的独立隔离容器和受控资源读取能力后才能开放页面渲染，不能复用应用主页面执行 HTML 或放宽安全策略作为临时方案。文件预览不做 diff、range 高亮、自动刷新或文件 watcher；
- UI-only `loading` 不进入 Host wire；Host 状态精确映射为 `ready | missing | restricted | unsupported | changing | error`。`changing` 与 `error` 可以显式重试，其他非 ready 状态只解释原因且正文必须为空；`truncated` 和 `redacted` 以文字说明，不只依赖颜色；
- Renderer 每次打开、切换文件或刷新都推进 request generation。关闭预览或面板、切换对象或 Task、reference 从新 snapshot 消失或后续请求开始后，旧 Promise 即使完成也不得覆盖当前内容；非活动资源正文必须卸载并清除已读取 bytes，显式重开时重新请求；
- File Preview 只陈述“这个 Run 引用了哪个文件，以及它现在可读取的内容”。Renderer 不从 reference kind、Tool 名称、Assistant 文本、Bash 输出或文件后缀推断 create/modify/delete、Output、citation 或 Run 时版本。

### 12.2 Files changed 与 Outputs

> Capability：File Changes **当前**；typed Output **未来**。File Changes 只消费 AgentCore typed `file_changes` observation，不能从 Tool 文本、Bash 输出、Git、文件后缀或 File Preview reference 推断。它是已记录副作用的审查视图，不承诺 Workspace 当前净状态。

- 每个 Run 在 Assistant response 后、terminal“工作过程”之前显示紧凑的单行“文件更改”入口，使结果审查保持主于次要技术证据。至少一条记录时，整行使用一个原生按钮，只显示中性 diff 图标、“文件更改 · 唯一文件数”和“审查更改”动作；不使用卡片、图标底板、过程竖线或第二行状态，也不暴露内部修改记录次数。`incomplete` 在同一行明确提示记录可能不完整；`incomplete` 且零记录时只显示非交互警告，不提供空 Review 动作；其他零记录状态不占位；
- “审查更改”在既有右侧 Task Panel 打开，不建立独立 route 或占用整个工作区。Review 绑定一个明确 Task + Run，Task Panel 顶栏直接使用“审查更改”标题，下面立即进入按文件首次出现顺序排列的连续差异文档；不重复显示类型、标题或常规说明区。打开即请求并展示首个文件的首条 diff，同文件后续记录在该文件区块接近可见区域时按稳定 `order` 逐条接入，后续文件纵向衔接，不经过列表页、单条详情页或返回动作。打开时显式展开右栏；关闭或 Escape 返回真实入口并恢复焦点，入口失效时回到稳定 Task Panel 开关；
- 每个文件使用一个克制文件头区分身份和边界：文件名前以 Git 惯例的 `A/M/D/R` 等宽字母和对应语义色表示聚合后的 created/modified/deleted/moved，不再重复状态文字；partial 是正交的异常事实，只在文件名后显示 warning 图标，并以“更改可能未完整应用”的可访问说明解释。文件头继续显示完整可取得的 `displayPath`、moved 的 `from → to` 与增删摘要，不显示同路径记录序号。文件默认展开，整个文件头是带 `aria-expanded` 的原生按钮，点击、Enter 或 Space 只折叠/展开所属文件的 diff、加载状态和错误说明，文件身份及增删摘要保持可见；折叠状态只属于当前挂载的 Review，不持久化，也不触发尚未开始的按需读取。ready 后可从已经汇入该文件区块的 recorded diff 派生增删行数，但不得据此宣称 Workspace、Git 或 Run 的当前净变化。区块使用分隔线形成连续文档，不包装成可导航卡片；底层多条记录、稳定顺序、独立读取失败与 stale identity 不得因呈现聚合而丢失。停靠、左栏互斥和窄窗全宽 overlay 仅沿用 Task Panel 的统一响应式规则；
- diff 只通过 `metawork.files.diff` 读取 Product 已记录的 credential-safe unified diff。首条立即读取；其余区块仅在进入或接近 Review 可见区域时各自按需读取，不因打开而批量预取。已读取正文只在当前挂载的 Review 内并存，不形成跨次打开的 Renderer cache。每条请求绑定精确 `taskId + runId + changeId + request generation`；关闭右栏、切换对象/Task、目标 Run/记录消失或同记录后续请求开始，都必须使对应旧 Promise stale，不能覆盖其他记录或新 Review；
- ready diff 使用等宽 unified-diff 视图，显示新旧双行号与整行增删背景；Renderer 使用 hunk header 计算行号和可证明的未修改行缺口，但不重复显示原始 `@@ … @@` 文本。长行在正文区域横向滚动，路径可截断但必须能取得完整值。malformed 或未识别行安全降级为原文，不执行正文或依赖颜色表达唯一语义；
- `diffComplete=false`、redacted、observation incomplete、not recorded、capacity、missing 与 corrupt 都显示明确说明；ready artifact 不提供刷新，只有瞬时 capacity 或普通请求失败提供重试。第一版不合并为累计或 Git 净 diff，不汇总可能失真的 Run 级增删行数，不扫描 Workspace，不重读当前文件，也不提供语法 token 高亮、Accept/Reject、revert、stage 或 Output 标记；
- `Outputs` 仍指用户关心的最终交付文件、链接或结构化结果。不能仅凭 created 记录自动判断它是 Output；需要未来 typed Output 标记或用户明确标记。

### 12.3 Output 卡片

Output 至少显示：

- 文件名和类型；
- `Generating / Ready / Failed / Missing` 状态；
- 大小、条目数或简短摘要；
- Workspace 相对位置；
- `Open`、`Show in Finder/Explorer`、`Copy path`；
- 支持时提供预览。

本地文件使用 `Open` 或 `Show in Finder`，不使用网页语义的 `Download`；只有结果尚未保存到本地时才使用 `Save as…`。

同一路径被再次写入时显示 `Updated`，不在第一版构造虚假的完整版本控制。真实文件缺失或被外部修改时要重新检测并显示状态，不能继续提供无效的打开动作。

### 12.4 结果完成态

一次执行完成时，中间区域提供简洁交付摘要：

- 完成了什么；
- 处理数量和关键指标；
- 异常、警告或需要复核的内容；
- 结果文件；
- 建议的后续动作。

未来 typed Output 进入 Task Panel 时同步更新，但不重复整段完成说明。

## 13. 搜索、历史与后台任务

> Capability：**目标**。全局搜索、持久历史与后台通知需要对应 Workbench persistence/index 和平台通知能力；当前实现只保留信息边界，不提前显示假入口。

### 13.1 搜索

标题栏提供全局搜索，默认搜索：

- Task 标题；
- 用户指令与 Agent 完成消息；
- Output 文件名。

Workspace 只作为 Task 与 New task 的路径上下文，不生成独立搜索结果；搜索命中 Task 时可以显示其安全路径说明，但不能把 Workspace 结果伪装成隐式 New task 动作。

工具原始日志和 stdout/stderr 不进入全局搜索。用户只能在已经打开的工具详情中搜索当前已加载内容；当前不提供 `Detailed/Advanced` 全局搜索模式。

### 13.2 后台通知

只为需要行动或阶段性结果发送系统通知：

- Task 需要用户处理；
- Task 完成；
- Task 失败或中断。

不为每次工具调用和文本增量发送通知。同一待处理请求只通知一次；点击通知打开对应 Task 和请求卡片。

系统通知默认只显示 Task 标题和状态，不包含命令、路径、用户内容、Agent 输出或审批 payload；设置中允许进一步隐藏 Task 标题。锁屏可见内容遵循操作系统通知隐私设置。

## 14. 首次启动与设置

> Capability：**混合**。当前 Renderer 合同已提供登录优先、长期 Settings overlay，以及设置与 New task 共用的 Models-owned默认 API/模型选择；跨重启 execution rebind仍按独立 capability gate验收。

### 14.1 首次启动

首次启动是独立于 Workbench 的登录与执行准备界面。它保持短、诚实且可恢复：

1. 按系统语言显示 MetaWork identity、一句价值说明和唯一主动作 `使用 Metask 登录`；
2. 点击后由 Host 打开系统浏览器完成 OAuth，原位置进入 `等待 Metask 授权`；
3. 等待期间提供 `重新打开登录页面` 与 `取消登录`，Host deadline 必须最终收口；
4. OAuth成功后立即显示已连接 identity，并由 Host把 Account授权交给独立 Models continuation恢复或加载 API Key与模型；
5. Models历史 intent命中时自动恢复，唯一候选自动采用；只有无法由合同决定的真实 API/模型歧义才在同一首次启动界面请求选择；
6. 形成并安装 ready ExecutionConfig 后进入 Workbench New task；Account 已 authenticated 但 Product/Schedule recovery 尚未完成时，进入保留历史与全局 recovery action 的 Workbench shell，关闭相关 New task admission，不得自动跳到账号设置或用 Account surface 遮住恢复入口。

```text
MetaWork

使用本地 Agent 完成真实工作
连接 Metask 后即可选择 Workspace 并创建任务。

[ 使用 Metask 登录 ]
```

首次启动不显示四步进度条，不要求用户点击“加载 API Key”，不出现 C1/C2、protocol target、generation或 Keychain等技术术语。`checking`只显示稳定品牌与检查状态；`authorizing`只显示等待和取消，不提供“重新打开登录页”。OAuth已成功而 Models目录准备失败时保持当前 identity，在模型配置区提供目录重试；Models已就绪而 Schedule/Execution不可用时保持 Account/Models事实，在 Product recovery surface提供恢复。零 Task、Metask 为默认来源且登录无效时，`signed_out` 显示独立登录表面和唯一登录动作；已有 durable Task 时进入 Workbench shell并在左下角账号入口显示统一登录动作。Providers 设置是否出现只取决于完整 Host capability gate，不显示已保存账号、重新认证、账号不匹配或上一次登录信息。

冷启动检查或 OAuth 授权期间使用稳定的品牌状态。确认 `signed_out` 后，零 Task 的 Metask 默认路径显示独立登录表面；有 durable Task 时保留 Workbench 与本地历史。如果没有 ready Custom Provider，只关闭 New task admission。完整 Custom Provider capability gate 已成立的平台仍显示 Providers 设置，使用户可以在不登录 Metask 时创建并验证自定义来源；Gate 未成立的平台隐藏整个入口。确认 `authenticated` 后继续目录准备。任何 live Task 若仍在运行，必须继续可查看和停止。

### 14.2 设置结构

```text
General
└── Language

Account
├── Metask identity and authorization status
├── Metask account usage（balance + today/total Token and actual cost）
├── Refresh account usage
├── Sign in
└── Sign out and clear this device

Models
├── Global default model（Metask + user-managed Providers）
├── Metask API and model catalog
└── Refresh catalog

Providers（capability-gated）
├── Model providers（DeepSeek / Kimi / MiniMax / GLM）
├── Official provider setup and management（independent full page）
└── Custom API（secondary group and independent add page）

```

设置是覆盖整个 Workbench 内容区的正式全局 surface，不用狭窄 popover 承载目录选择、错误恢复和危险退出。它保留窗口壳层，底层 Workbench 继续挂载但不可操作；进入后不重复显示或操作 Task 左栏，也不改变离开前的 Task、草稿、滚动和焦点状态。窗口标题栏保持一致，页面内 `返回工作台` 是返回入口；左下角用户菜单只负责打开该 surface 和少量直接动作。

设置树只列当前阶段已经完整设计并通过 capability gate 的项目。显示密度不作为设置；`Appearance` 只有在第二套主题完成设计、可访问性和平台验收后才能加入，首个浅色版本不显示空入口。

设置树不提供权限分区或权限设置项。只有 Host capability projection 支持 PermissionProfile 时，New task 才显示两个真实选项并记住成功创建 Task 时的选择；不得显示第三档、假开关或“即将推出”。已有 Task 的 effective profile 只在 Task 自身 surface 只读展示。

`Providers` 只有在 management、API Key 写入系统 credential storage、模型测试和已开放 protocol admission 共同可用时才整体进入设置树；它与 `Models` 平级，不是 Models 的下一级。不能只显示不可完成的空壳或“能力不可用”页面。Host 按当次运行时 capability 决定是否开放，不按 Windows/macOS 平台名建立静态 allowlist；目标平台尚未形成完整验收证据时由验证规范保留风险事实，不把已有运行能力永久屏蔽为产品缺失。

Workspace 生命周期不属于 Settings surface。New task 路径控件负责选择、添加和重新授权 Manual Workspace；Automatic Workspace 只随 owning Task 导航。Renderer 只在当前 draft 内保存 Manual Workspace identity，不维护 `activeWorkspaceId` 或其他全局活动 Workspace 镜像。

`Account`规则：

- 只显示 Metask identity、授权状态、登录/取消、token refresh恢复、账户用量摘要和退出；不得把 API/model catalog、默认模型、Models错误或连接状态显示成 Account字段；
- authenticated且非 simple模式时，在现有设置 group/list语法中增加一个克制的“Metask账户用量”分组：余额为主要值，今日与累计各用一行显示 Token总量和实际费用，今日 Token分项按 `输入 / 输出 / 缓存创建 / 缓存读取` 作为辅助文本，组尾显示最近同步时间与唯一刷新动作。必须注明这些数字属于整个 Metask账户，不是 MetaWork单应用统计；金额单位统一为 U；
- wallet与usage独立按 unavailable/loading/ready/stale显示。已有值刷新失败时继续显示并标注“可能已过期”，不得清空成0；初次不可用只给局部、可操作说明，不把Account伪装成未登录。刷新只由用户点击或authenticated/generation建立后的Host自动同步触发；进入设置、Renderer reload、snapshot update和本地timer都不能触发；
- `usageEligibility = disabled`时不显示用量分组；unknown时只显示局部不可用说明与刷新动作，Renderer不得读取或推断raw run mode。不得显示email、account id、标准费用、请求数、RPM/TPM、响应时间、API Key数量、订阅额度、模型分布、趋势、最近请求、外部管理链接或装饰性图表；
- 已验证 identity 的 refresh timer 或 wall clock 无法安排时继续显示 `authenticated`，在 Account 设置错误区说明自动刷新未安排并提供唯一 `重试登录刷新`；该动作调用 Host `retryRefresh`，不得由 Renderer timer、reload 或普通 snapshot update 自动重放；hard expiry 后 Metask 新目录/解析由 Host fail closed；
- 重新登录或退出登录不得因 Models、Task、Session、Run、job、worker或 Task-owned credential的运行时引用而被阻止，也不得静默终止或改写这些引用；既有 Task按创建时取得的 ExecutionConfig继续收口；
- 退出登录必须说明 Account设备凭据会清理、Metask模型将暂时不可用于新 Task、自定义模型不受影响且历史保留；不能把它描述成对 live Task的热撤权。

`Models`规则：

- `persistenceHealth = recovery_required` 显示单一显式恢复确认面；文案必须说明 Host 会先尝试恢复合法配置，只有文件缺失或确认损坏时才清空，不得无条件承诺删除 Provider 或模型配置。操作成功后完全以新 snapshot 为准；失败保留恢复面，不由 Renderer 猜测磁盘结果或自动重放；
- 进入该设置 route只渲染 Host已提交的 Models projection，不触发隐藏同步；用户显式点击 `重新同步`时才刷新 Metask provider目录。已提交 intent在同步期间保持可读，`重新同步`只用于失败恢复或页面保持打开期间发生的 Metask外部变更，不能成为打开下拉框或切换默认值的前置步骤；
- 页面以一组连续的 `Provider → API Key → 默认模型` 控件显示并修改 global default，并在组头持续显示当前已提交的 `Provider · Model`；Provider 先限定 credential authority，API Key 再限定模型目录，只有最终选择默认模型时才提交完整 `ModelRef`。Models 是唯一允许提交 global default 的产品页面；
- API Key 列表对 Metask 显示名称、protocol、尾号和可用/需要处理状态；对 user-managed Provider 显示由 Host 安全持有的已保存 credential authority。两者都不显示完整 secret；
- protocol 是 Host 从 API catalog 确定的只读技术事实，只作为 API 名称下的次级元数据展示；Renderer 不提供 protocol、base URL 或 credential 编辑入口；
- 切换 Metask API 后加载其模型目录；切换 Provider 或 API Key 只准备并收窄当前候选，不会隐式替换 global default，也不改写 durable Task 历史或正在运行的 Session；
- 默认模型选择与 New task Composer 使用同一 Host-owned selection，不维护两份互相漂移的 Renderer preference；
- 既有 Task 只显示解释历史所需的 protocol、模型与 generation；不显示或保存 Account identity 与 API Key 元数据；
- 跨重启历史 Task 保持只读；设置变化不能使其静默采用当前默认值或伪造 Session；
- `在 Metask 中管理`只有在 Host发布固定安全入口后才显示；当前没有该 capability时不放置链接或假入口；
- Account为 `signed_out`时，Metask provider显示需要登录且不允许刷新/选择；无 secret的已选 intent可以保留，Custom Provider 与其模型仍可独立查看和管理。
- 选择 Custom Provider 后，模型步骤始终显示该 Provider 的全部模型和新增入口，不以“尚无模型”作为唯一可编辑状态；每个模型提供独立测试与带确认的删除动作，ready 模型才可提交为 global default。新增第二个及后续模型不得要求删除或覆盖已有模型；

设置页保留左侧分区导航与右侧内容的双栏布局。桌面双栏直接消费应用左侧导航轨的已保存宽度，使设置内容起点与 Workbench 分界线保持一致；设置页不建立第二份宽度状态或第二个拖动器。它是桌面控制面，不使用营销页式 Hero，也不为视觉饱满度增加无产品语义的卡片、渐变、玻璃材质或装饰性图表。顶部只保留与左侧导航对齐的返回入口，不重复展示全局设置标题和说明；标准窗口下当前分区标题和第一组设置必须在首屏形成紧凑、稳定的阅读起点；窄窗口可把分区导航收成横向行，但不得改变设置 owner 或复制页面状态。

设置视觉与控件遵循以下规则：

- 页面背景、工作面、交互组和浮层使用视觉系统中的 `surface-app` / `surface-work`、分隔线与真实抬升关系建立层级；普通设置行不逐项卡片化，只有 Provider、API Key 和模型这种依赖型配置形成连续交互组；
- 每个设置分区页面在内容列顶部使用一个醒目的页面标题；页面标题下用 13–15 px 的小分组标题组织设置项，具体控件再使用自己的字段标签。不得在页面标题、分组标题和字段标签之间重复写“设置”或同义标题；
- 页面标题约 22–26 px，设置主文案 13–15 px，辅助文案不小于 12 px；disabled 状态只改变语义色和对比度，不缩小字号；
- 语言、Provider、API Key 和模型统一使用经过键盘、焦点、碰撞和长列表验证的同一 headless Select primitive；正式设置页禁止依赖 WebView 平台主题的原生 `<select>`，也不建立另一套自绘菜单；
- compact 选择器只显示一个短值；API 使用 detailed 选择器，以 API 名称为主信息，以 protocol 为次级说明，以脱敏尾号为尾部数据。protocol 和尾号不得表现成可编辑字段；
- Provider、API Key 与默认模型控件在同一个工作面中以带步骤标记和连接线的连续配置链呈现，明确表达 `Provider → credential authority → source-qualified ModelRef`；不能再附加 Metask 专属配置块或第二个同名的默认模型控件。user-managed Provider 只有一份已保存 credential 时，API Key 步骤仍明确投影该 authority，但 credential 的创建、替换和删除只能进入独立 Providers 页面；
- API 切换开始后只冻结相关配置组；模型目录加载、选择和持久化不得冻结语言、导航、历史阅读或取消仍被 Host 接受的操作；
- 设置页把 Provider/API Key 候选准备与 global default mutation表现为一条分阶段的 Models-owned transaction；前两步只限定 source 与 credential authority，最后一步从该 source 的 ready 模型中提交唯一 global default。Metask provider-local 准备和最终 global default提交分别校验对应 catalog/source generation与 expected revision，再 durable提交 Models state；Custom Provider 使用其 provider revision 提交完整 `ModelRef`。Product后续 resolve/scrub/install失败时另行显示 desired/active mismatch与 recovery，不回滚 Models，也不把 Product failure显示成 Account mutation失败。Renderer可在 command acknowledgement前短暂回显用户请求，但收到 snapshot后必须以 Host projection为准；页面重建、失败和成功都不得依赖 Renderer临时状态恢复事务；
- 常规桌面宽度下左侧分区导航切换独立的设置分区页面，右侧一次只渲染当前分区；页面标题和左侧分区导航保持稳定，当前分区内容列可独立滚动。窄窗口改为顶部横向分区导航，但仍不让导航与内容共享滚动层；
- 浮层只在打开时使用克制的透明度与位置过渡；loading 指示只出现在真实运行的配置项，`prefers-reduced-motion` 下移除非必要动画；
- 当前分区导航必须有持续可见的选中态和 `aria-current`，不能只在 hover 时出现；focus ring、菜单选中勾选、状态色和文字共同表达状态。
- 桌面壳注册标准 `primary + ,` 设置快捷键，直接打开正式设置 route；快捷键只负责页面导航，不建立绕过 Account/Bridge gate 的第二命令面。

Account与 Models状态在设置中分别投影：Account按 `checking | signed_out | authorizing | authenticated`显示 identity action，并在authenticated时直接消费Host发布的summary子投影；Models独立按 `needs_authentication | loading | choosing | ready | failed | unavailable`显示provider配置。Account authenticated不能被summary或Models失败伪装成未登录，Account signed_out也不能隐藏Custom Provider。Renderer不从任一公开状态恢复内部operation，也不区分或展示credential persistence子步骤。

`Providers` 规则：

> 该入口按完整 Host capability gate 开放；支持的桌面平台只要三项运行能力同时可用即可导航。

- Renderer 同时校验 `customProviderManagement`、`customProviderSecretCapture` 与 `customModelTest` 三个 Host capability；只有三者均为 true 才显示整个设置入口。revision 1 保留 `customProviderSecretCapture` 字段名，但其 true 表示 create/replace API Key typed command 可用且 Models credential vault 可写，不再表示弹出原生输入窗。Host 只发布全 true 或全 false，并从实际 management、credential storage 与模型测试能力生成该组事实，不读取平台名决定产品可见性；不得提供“稍后补齐 credential”的半成品路径；
- Provider 首页以“模型厂商”和“自定义 API”两个分组建立明确主次。DeepSeek、Kimi、MiniMax 与智谱 GLM 四个 Host 模板始终逐行显示，不因尚未配置而隐藏；行内只显示名称、`未配置 / 尚未测试 / 可用 / 凭据需处理` 状态和单一 `配置 / 管理` 动作。自定义 API 位于带分隔的第二分组，只有该分组提供弱化的“添加自定义 API”动作；不再提供通用 `Add Provider`、厂商下拉框或“官方 / 自定义”radio 模式切换；
- 点击厂商行打开该厂商的独立全页，不使用列表内展开表单，也不成为 Models 的子页面。未配置状态默认直接使用 Host 模板发布的官方 Base URL，只要求 API Key；Base URL 输入默认隐藏，用户显式点击“使用其他地址”后才展开。展开区必须保留固定 protocol 的只读事实、实时展示最终 endpoint、提供恢复官方地址动作，并在地址偏离官方默认值时明确显示后续请求将把该 Provider API Key 发送到哪个 host；
- 已配置厂商的管理页把地址与凭据作为两项独立设置：Base URL 修改使用专用 revision-bound mutation，API Key 更新始终打开新的空 password input 并使用独立 credential replacement，不把两者合并成一笔表单提交。厂商显示名和 protocol 始终不可编辑；地址或 credential authority 变化推进 source generation 并使该 Provider 全部模型回到待验证状态。秘密永不回填，保存成功、取消或离页后清除临时值；当前不显示厂商 logo；
- 自定义 API 使用独立全页的单列连续表单，依次填写只用于 MetaWork 内识别的显示名称、protocol、API Base URL 与 API Key，不使用暗示连接步骤已经完成的装饰性流程图。填写 Base URL 后必须实时展示由 protocol 规则生成的实际请求地址，帮助用户在保存前确认最终 endpoint；API Key 使用可粘贴的 password input，不提供显示已保存值的能力，也不进入浏览器自动填充。自定义 API 精确开放 OpenAI Responses、OpenAI Chat Completions、Anthropic Messages 与 Gemini Native；选择协议只改变 Base URL 示例和后续 endpoint 生成规则，不得自动写入或覆盖输入框。Renderer 对前三者分别把用户填写的 Base URL确定性映射为 `{base_url}/responses`、`{base_url}/chat/completions` 与 `{base_url}/v1/messages`，Gemini Native 保持 Base URL并由既有消费者追加模型路径。Host 在提交时继续独立规范化 endpoint并校验 scheme/host/path/长度和控制字符；Renderer 不能把 arbitrary URL 或 query credential 直接交给 Run；
- `Test model` 只通过 Host/Agent Completion 发起有界请求，不创建 Task、历史 Run 或持久 Conversation；页面分别显示 generation readiness 和最新测试状态。已成为默认模型后仍可重测，失败只显示“最近测试失败”，不能把正在使用的 ready generation、默认选择或新 Task admission 静默撤销；
- 第一版不提供自动模型发现；Provider 保存后由 Models 页明确填写 bounded model ID并执行测试，Provider 没有 ready 模型时不能成为默认来源；
- global default 只在 Models 页作为一笔 Models-owned、source-qualified desired transaction提交；Providers 页不得因当前 Provider 是默认来源而禁用编辑或删除。Product Control随后独立 reconcile active binding，处理中只关闭相关新 Task admission，不回滚已提交 desired selection；
- Metask provider catalog与当前 custom default同时投影；custom default生效时模型设置仍可查看 Metask API/模型，并通过显式“设为新任务默认”提交同一个 global default command。Account只决定 Metask provider当前能否授权，不参与默认来源选择；
- 自定义 API 列表保留编辑和删除两个一级操作，API Key 更新位于编辑界面的凭据区域，不在列表行中抢占一级操作。credential storage 不可用时整个 Provider 设置入口隐藏，不提供局部编辑路径。endpoint、protocol 或 credential authority 变化推进 source generation并使该 Provider 全部模型回到待验证状态；普通 display/metadata 编辑只推进对应 provider revision/catalog generation。Provider 可以在模型集合为空时持久存在于 configuring 状态；两种 Provider 都通过 Models-owned custom model mutation添加或删除模型，不把模型伪装成 Provider 身份的一部分；
- Models 按 exact Provider identity 与 expected provider revision 校验编辑/删除，不查询 live Session、Run、job 或 worker，也不以 consumer usage 拒绝 mutation。若 mutation 使当前 desired default 不可解析，Product Control 独立关闭 new admission 并进入 reconciliation；既有 Task/Run 保持自己的 owned binding，不静默改绑，历史仍保留；
- Providers 页只管理 Provider 本身与 credential，不提供模型测试、默认模型、Workspace、权限策略、Task 历史或 AgentCore 内部状态。

Skill 中心、MCP 与定时任务按 §5.2–§5.5 进入 Workbench 一级能力导航；MCP 使用稳定入口，并分别消费 Host-owned management health、Runtime/catalog availability 与 new Task access。空 registry 是可管理空状态，management capability 未接通或 outcome unknown 才进入对应不可用/恢复面；Renderer 不从 Runtime ready 推导管理动作。其他连接器和 IM 频道仍只有在真实接通并形成清晰产品 owner 后才进入导航，不照搬其他 Agent 产品的信息架构。

## 15. 国际化

> Capability：**当前**。Locale ownership、structured code 与 catalog parity 约束立即生效；新增登录、设置、Task Panel 和 rebind 文案必须随对应功能同步补齐，不得先落单语言字符串。

### 15.1 Locale 策略

- `en-US` 是规范文案和最终回退语言；
- `zh-CN` 是首个完整本地化版本；
- 首次启动跟随系统语言；不支持的系统语言回退到 `en-US`；
- 用户选择的语言持久化；
- 切换语言不要求重启；
- 缺少翻译时回退英文并在开发/测试环境报告缺失 key。

代码使用稳定的语义 message ID，不使用英文原句作为 key：

```text
task.status.running
task.action.stop
approval.allow_once
```

Host/Core 传递状态 code 和结构化参数，Renderer 负责本地化。用户输入、Agent 内容、路径、文件名、命令、stdout/stderr、技能名和 MCP server 名称不翻译。

日期、时间、数量、货币和相对时间使用 locale-aware formatter，禁止字符串拼接。

### 15.2 测试 Locale

- `en-US`；
- `zh-CN`；
- 扩展约 30% 文案长度的 pseudo-locale；
- 缺失 key 回退；
- 运行时切换与 reload 后持久化。

## 16. 视觉与设计系统

> Capability：**当前与受 gate 目标**。明亮紫色视觉系统已经进入正式 Renderer；当前产品只开放浅色主题。Dark primitive 或语义映射的存在不代表深色产品主题已经通过设计、可访问性和平台验收，也不授权显示主题开关。

### 16.1 视觉方向

MetaWork 采用“明亮工作台 + 紫色任务流”的桌面工具方向。视觉个性来自克制的紫色交互信号、信息密度转换和本地执行语义，而不是暗色全局背景、暖米色加通用衬线、巨大品牌空态、吉祥物、渐变或每块内容一张圆角卡片。外部参考只用于判断主次关系，不能复制品牌字形、导航结构、输入框比例、图标或配色。

智能紫只表达品牌、关键操作、当前选择、键盘焦点与正在活动的真实路径。普通正文、图标、边框和面板使用中性色；成功、等待与失败使用独立语义色并同时提供文字、图标或形状。应用背景、普通卡片和完整首屏不得铺设大面积紫色渐变、发光、玻璃拟态或装饰性粒子；正常完成不使用庆祝动画。

### 16.2 品牌资产

- `assets/brand/logo-mark.svg` 是唯一手工维护的 MetaWork 标志几何资产；不同用途不得直接修改该文件，而应在独立画布中处理安全区、背景、视觉居中和必要的小尺寸适配；
- `assets/icons/app-icon.svg` 是应用图标用途母版，使用纯白背景；标志按画布中心缩放至约 88%，使可见主体约占画布宽度 70%。`assets/icons/app-icon.png`、`assets/icons/MetaWork.icon` 与 `assets/icons/app-icon.ico` 都从该视觉母版派生，不增加非设计渐变、shadow、specular 或 translucency；
- `assets/icons/tray-icon.svg` 使用透明背景，主体约占画布宽度 88%；macOS 作为 template image 使用，Windows 保留品牌色；
- favicon 或其他用途资产只有出现真实 consumer 时才新增。用途资产可以调整内容占比、视觉居中、背景和小尺寸细节，但不得重新设计基础几何；
- 图标编译、平台资源 staging、PE/ICNS/Assets.car、签名与打包验证属于工程和分发合同，分别由工程结构、平台文档与验证规范定义，不在本文复制实现步骤。

### 16.3 Design Token

当前批准的品牌 primitive 为：

| Token                        | Value     | Role                         |
| ---------------------------- | --------- | ---------------------------- |
| `--metask-primary`           | `#8A4ED1` | 智能状态、关键操作、激活路径 |
| `--metask-primary-deep`      | `#4B2DB5` | Hover、pressed 与高对比强调  |
| `--metask-primary-soft`      | `#E9E6FF` | 浅色主题弱强调背景           |
| `--metask-accent`            | `#B35BE8` | 运行中、智能活动和轻量状态   |
| `--metask-state-running`     | `#B35BE8` | 明确的运行与活动状态         |
| `--metask-state-warning`     | `#9C5B10` | 等待用户与警告               |
| `--metask-state-warning-ink` | `#7D4308` | 浅色表面上的警告文字         |
| `--metask-state-complete`    | `#4C9A72` | 完成、健康与校验通过         |
| `--metask-state-error`       | `#C85A5A` | 异常、失败与破坏性反馈       |
| `--metask-light-canvas`      | `#F7F8FA` | 浅色页面背景                 |
| `--metask-light-panel`       | `#FFFFFF` | 浅色面板                     |
| `--metask-light-panel-2`     | `#F1F2F5` | 浅色次级或抬升表面           |
| `--metask-light-text`        | `#191B21` | 浅色主题主要文字             |
| `--metask-light-text-muted`  | `#626775` | 浅色主题次要文字             |
| `--metask-light-border`      | `#DFE2E8` | 浅色主题边界                 |
| `--metask-dark-canvas`       | `#0F1115` | 深色主题页面背景 primitive   |
| `--metask-dark-panel`        | `#12141B` | 深色主题面板 primitive       |
| `--metask-dark-panel-2`      | `#181A23` | 深色主题抬升表面 primitive   |
| `--metask-dark-text`         | `#F4F5F7` | 深色主题主要文字 primitive   |
| `--metask-dark-text-muted`   | `#A7ABB7` | 深色主题次要文字 primitive   |
| `--metask-dark-border`       | `#2B2F3A` | 深色主题边界 primitive       |

Token 只有三层：

1. `--metask-*` 是品牌 primitive，逐字镜像本文批准的值；
2. `--ui-*` 是 Foundation semantic token，只表达 surface、content、action、status、focus、overlay 等组件语义；
3. Tailwind `@theme inline` 只是消费桥接层，不拥有新的视觉值。

Foundation 组件只消费 `--ui-*`；只有直接表现品牌或状态本身时才消费对应 `--metask-*`。产品 CSS、组件和其他文档不得复制另一套品牌 primitive。新增 semantic token 必须有当前 consumer，并优先由现有 primitive、surface 和 `color-mix()` 推导；若该 token 参与未来主题切换，Light/Dark 必须同时定义。`frontend/src/styles/metask-tokens.css` 是上述规则的实现镜像，不是独立设计真源。

### 16.4 字体、间距与形态

- `--metask-font-sans` 精确为 `Inter, "SF Pro Display", "PingFang SC", "Microsoft YaHei", Arial, sans-serif`；不依赖运行时网络字体，不使用通用 serif 制造空态“高级感”；
- `--metask-font-mono` 精确为 `"SFMono-Regular", Menlo, Monaco, Consolas, "Liberation Mono", monospace`；命令、路径、版本、稳定标识和数据才使用等宽字体，普通 Task、按钮、设置、状态和正文保持无衬线；
- 字号 token 固定为 `--metask-text-micro: 11px`、`--metask-text-label: 12px`、`--metask-text-control: 13px`、`--metask-text-body: 14px`、`--metask-text-lead: 16px`、`--metask-text-title: 18px`、`--metask-text-title-lg: 20px`、`--metask-text-display: 24px` 与 `--metask-text-display-lg: 28px`；默认正文为 14 px，主要阅读内容不得低于 13 px；
- 间距以 8 px 为基础节奏，紧凑桌面控件可以使用 4 px micro gap；优先复用 8 / 16 / 24 / 32 px，不为单个页面建立新的间距阶梯；
- 小型控件使用约 6 px 圆角，导航、按钮与输入使用约 7 px，卡片和命令面使用约 12 px，Composer 与大面板使用约 16 px；
- 按钮、输入和触控动作默认使用至少 44 px 命中高度；平台窗口按钮和明确的紧凑桌面控件只按各自已记录且经过键盘、DPI 与窄屏验收的规则例外；
- 组件层级依靠排版、间距、背景和分隔线建立。圆角只服务输入区、弹层和需要形成边界的交互组；普通消息、活动和设置项不默认卡片化，阴影只用于真实抬升层。

### 16.5 Foundation 组件

- `frontend/src/components/ui/` 只实现无业务语义的 Foundation primitive；业务 feature 通过公开 preset、slot 和 token 组合，不在产品 CSS 中重建 Button、Input、Dialog、Drawer、Popover 或状态体系；
- 同一区域只允许一个紫色主动作。次级动作使用中性表面与边界，危险动作使用异常红，不使用紫色表达删除；
- 按钮、输入、菜单、开关和弹层必须提供一致的 resting、hover、active、disabled 与 `focus-visible` 状态；操作名称、反馈和结果使用同一用户语言；
- 状态色必须同时配合文字、图标或形状。标签只描述类别或状态，不承担按钮功能；
- 卡片与面板使用边界、间距和表面层级组织信息，不依赖强阴影或渐变；同一页面不为不同模块发明互不兼容的卡片结构；
- Foundation primitive 不拥有 Workspace、Task、Run、AgentCore、Bridge command 或 capability gate；产品 feature 也不得反向修改 Foundation 的定位和 lifecycle 内部细节。

### 16.6 主题与动效

- 当前产品只开放浅色主题；`Appearance` 和主题切换在第二套主题完成完整设计、WCAG、约 390 px 窄屏及 Windows/macOS 平台验收前保持隐藏；
- 深浅主题必须保持相同 DOM 结构、内容顺序、信息密度和状态语义，只替换 surface、content、border、shadow 与 glow 变量；
- Task 输入、回复与行动状态通过排版和间距形成清晰关系，不用装饰线、节点或卡片伪造底层时序；
- 只让当前运行节点旋转，避免全屏多个 spinner；
- Hover / Press 只在约 100–120 ms 内改变颜色或背景，不做位移；Popover / Slash menu 使用约 120–150 ms 淡入和最多 4 px 位移；
- 左栏与 Task Panel 的平移或列宽变化约 160–180 ms；不能使用内容状态驱动高频开合；
- capability 到位后的新 Output 只使用约 160 ms 轻微淡入；
- 从 New task 到运行 Task 的布局变化使用一次约 220 ms 的克制过渡：Composer 从中央主视觉落到底部，Task 内容获得空间；不散布无意义入场动画；
- Task Panel 不随普通 Run 开始或 terminal 自动改变列宽；显隐只由用户布局动作改变，设置覆盖层与窄窗左右栏互斥除外，避免正文高频重排；
- 完成状态不使用庆祝动画；所有非必要动画为 `prefers-reduced-motion` 提供静态等价状态。

## 17. 空状态与异常状态

> Capability：**混合**。错误表达、Host/Core 中断、登录优先、独立 Workspace 和无伪 Resume 属于当前约束；execution rebind 与完整历史恢复按各自目标 capability 显示。

### 17.1 未登录

未登录不是 Workbench 空状态，而是独立登录界面。显示 MetaWork identity、一句直接说明和 `使用 Metask 登录`；不得渲染空 Workspace、空 Task、disabled New task 或空 Task Panel。等待浏览器授权、取消、重新打开、目录准备和真实歧义都在同一稳定位置演进。

### 17.2 New task

显示：

- 清晰的行动标题，不使用空泛欢迎语或人格化 Assistant 宣传；
- 一句话说明 MetaWork 将在当前本地 Workspace 中完成工作；
- 作为首屏主视觉的 Composer；
- 当前模型与 Workspace；
- 当真实能力边界影响本次执行时，显示准确、可操作的 authority 限制提示；不得显示泛化的“信任此工作区”。

没有 Workspace 时可以先输入临时草稿，但发送动作明确引导选择 Workspace；用户在原生目录 picker 中确认即完成 Manual Workspace 授权，不追加“Use this folder”或 trust 弹窗。Account 此时已经 ready，不再出现登录 prerequisite。

### 17.3 错误原则

错误说明必须包含：

1. 发生了什么；
2. 哪些结果可能不完整；
3. 用户可以采取什么动作；
4. 技术详情入口。

Account 错误必须保留本地 Workspace、Task 和草稿。OAuth 尚未完成时提供取消；已认证后的 Account refresh 调度失败保持 `authenticated`，在 Account 设置错误区提供显式 `重试登录刷新`；Models目录失败仍由 Models区域重试。凭据失效直接进入 `signed_out`，由普通登录建立新 identity。Product/Schedule error 不得进入 Account error 或触发 Account 设置 redirect；对应 recovery action 必须在 Account ready 时仍可见、可操作。错误动作必须与当前四态合同一致，普通异常不能留下无动作 spinner。

工具失败但 Agent 已恢复时不能把整个 Task 标记为失败。任务级失败才进入左栏 Failed 状态。

### 17.4 当前 baseline 限制

- Renderer reload 只能恢复仍存活 Host 中的视图；
- Host/Core 退出后当前执行显示 Interrupted；
- 不显示伪造的 Resume 或自动重放；
- strict Workspace security 未验证时必须明确限制适用范围；
- async pending、持久化恢复和后台 suspend 只有在真实 capability 存在后才能进入界面。

## 18. 可访问性与键盘

> Capability：**当前**。以下是所有已显示界面的最低验收要求；目标功能落地时必须同时满足，不能事后补做。

- 所有交互元素具有可见 focus 状态；
- 状态不能只依赖颜色；
- 图标按钮必须提供本地化可访问名称；
- Renderer 窗口按钮必须键盘可达；最大化/还原的可访问名称与 Host 发布的真实状态一致；
- 流式文本不按 token 频率向辅助技术播报，使用节流后的有意义状态；
- 任务完成、失败和待处理请求使用适度的 live region；
- 窄窗口、200% 文本缩放和长英文文案不得导致关键操作不可用；
- 支持 `Cmd/Ctrl + K` 搜索、`Cmd/Ctrl + N` 新建 Task、`Esc` 关闭浮层；
- 危险批准不绑定裸 Enter。

## 19. UI 验收矩阵

本矩阵按前文章节的 capability 标记启用：当前项必须持续通过；目标项随完整合同一起验收；未来项在 capability 到位前只验收“界面不存在”，不能把占位组件当作进度。

### 19.1 视图尺寸

- 1440 × 900；
- 1320 × 812（常规桌面回归样本）；
- 1100 × 720（Task Panel 根据 480 px 中央工作面下限切换 overlay 的边界）；
- 960 × 680（窄窗口回归样本）。

这些尺寸用于稳定复现布局问题，不是产品最小尺寸、固定设计画布或断点来源；断点应由内容拥挤、可达性与平台窗口行为验证得出。

### 19.2 Locale

- `en-US`；
- `zh-CN`；
- pseudo-locale；
- 缺失翻译回退。

### 19.3 Task 状态

- New task；
- Queued；
- Working；
- Needs your attention；
- Stopping；
- Completed；
- Stopped；
- Failed；
- Interrupted；
- View unavailable。

### 19.4 Account 与首次启动

- cold restore 不闪现 disabled Workbench；
- 首次 signed out、Metask 为默认来源且没有本地历史：独立登录表面直接提供唯一登录动作；不得制造 saved account、上一次登录或 mismatch 分支；
- OAuth 正常完成、浏览器未回调、重新打开、取消和 hard deadline；
- 历史选择命中、唯一 Key/模型自动推进；
- 多 API、多模型真实选择以及选择期间 reload；OAuth identity 成功后不退回未登录；
- catalog timeout/有限重试、OAuth exchange 失败、持久化确定失败与结果不确定；
- 无 API Key、无模型以及 Host 未提供管理入口时的可理解恢复文案；
- Bridge invoke timeout 后释放 busy、snapshot resync 后恢复 Host 动作；
- ready 后进入 Workbench，左下角显示 identity；重认证、设置和退出只按 Account busy/error scope 收口，Product execution/Schedule recovery 使用独立 scope；Account ready + Execution unavailable 时 recovery action 可见且不会被账号设置 redirect 遮挡。

### 19.5 Workspace、模型与设置

- Workspace 是独立 projection：空 Workspace、最近使用、重新授权、移除和跨 Workspace Task signal；
- 原生目录 picker 确认后直接完成 Manual Workspace 注册，不出现第二次 trust / `Use this folder` 请求，Renderer 不提交 `trusted` boolean；
- New task Composer 始终显示当前模型和 Workspace，上下文缺失时提供明确下一步而非静默 disabled；
- New task 首次发送覆盖本地 admission 不满足、`create_rejected`、`create_failed`、Task 已创建后的 `run_rejected` / `run_failed`、Run accepted 与 command timeout；每种结果都保持正确页面和草稿 scope，不伪造指令、Running 或失败定论；
- 当前 API 模型列表、模型切换 pending/error、设置与 Composer 默认值一致；
- 设置页切换默认 API 后加载对应模型，默认只影响新 Task admission，不自动改绑已有 Task；
- 已有 live Task 保留当前 execution binding epoch，默认变化不改写历史或 live Session；detached Task 的 Conversation restore 可按 §6.4 为兼容 credential target 建立 adoption epoch，任意 protocol/model 变化仍只有未来的显式 rebind 可以建立新 epoch；
- Host 重启后点击左栏 Task 只浏览已保存时间线，未完成 operation 显示 `Interrupted`；满足 Host 恢复资格时 Composer 保持普通输入形态，用户发送时在同一意图内执行 restore→Run，required、restoring 与 failed/retry 不形成独立恢复控件或文案。不得因导航自动 restore、伪造 Run/Stop、显示假的 rebind，或仅因当前默认配置看似匹配而开放发送；
- API 只在设置中显示脱敏名称、protocol 和尾号；完整 secret 不进入 DOM、snapshot、日志或错误；
- 左下账号入口在窄窗口、长姓名、重认证和 200% text 下仍可用。

### 19.6 内容状态

- 短文本和长文本流；
- 多个连续 Tool Call 保持独立的有界顺序摘要，不自动归并或追加主阅读流卡片；
- Bash 失败和长 stdout/stderr 使用有界预览；没有真实 Tool projection 时不显示假详情入口；
- Read 大量文件；
- Edit diff；
- one-time permission；
- permission 请求只针对当前 authority 未覆盖且执行层能兑现的决定；Workspace picker、Task profile、MCP/Skill authority 与系统授权不重复请求；
- capability 未验收时 Plan、plan approval、跨 Session 持久授权与 Output 完全不出现；File Changes 只在 Host `typedFileChanges=true` 时出现；
- File Changes 覆盖 created/modified/deleted/moved、applied/partial、同路径多记录聚合且底层身份独立、嵌套 Agent 记录、diff incomplete/redacted、observation incomplete、零记录丢失、missing/corrupt/capacity、Task 切换 stale response，以及宽窗/窄窗、键盘焦点和无颜色状态；
- 对应 capability 未来验收后，Plan 创建/更新、计划确认与 Output 的目标状态按各章节启用；
- 后台 Task 通知；
- Renderer reload 和视图重新同步。

### 19.7 权限策略

- Host 未发布 PermissionProfile capability 时不显示策略入口；当前只允许 `请求批准` 与 `完全访问` 两档；
- 默认 profile 只影响新 Task；Task effective profile 不可变，Run provenance、same-profile fresh/restore、Task archive/delete 和 Scheduled noninteractive 语义一致；已有 Task 不显示伪切换；
- `full_access` 文案明确保留 AgentCore 核心保护、操作系统权限、服务授权和进程身份边界，不宣称 root、Sandbox 或 Workspace trust；选择动作不再追加第二个确认 modal；
- 权限卡片只显示当前 request 支持的 once/Session choice，不显示跨 Session 持久授权；
- stale、duplicate、expired 和错误 Task/Run/request 响应必须被拒绝；
- Renderer reload 后当前请求状态从 Host 恢复，已响应或取消的请求不得重新可操作。

### 19.8 交互与可访问性

- 键盘完整操作；
- focus 不丢失；
- 用户上滚时不强制自动滚动；
- 每个 Task 在当前 Renderer 会话内恢复自己的阅读位置与 following-latest 状态，不泄漏另一个 Task 的位置；首次选择 Task 时定位最新内容；
- reduced motion；
- 状态在无颜色条件下仍可识别；
- 长英文、中文和 pseudo-locale 不溢出；
- `queued / running / waiting_user` 的可见 Stop 只出现在 Composer 发送位置；顶部命令栏不重复出现，`stopping` 阻止重复请求并等待真实 terminal；
- 右侧栏常驻开关可由键盘操作，无 Task 时也能独立开合；Task 切换、删除、目标失效不改变布局显隐或宽度；任务信息纯图标、上下文压力提醒与审批定位入口可由键盘操作，缺少 pressure 时不显示上下文入口；Run 用量和历史 auto compact 不独立展示；
- 右侧仅挂载一个 Tool、当前文件详情或同 Run File Changes Review；关闭回到真实 opener，opener 失效时回到稳定 Task Panel 开关。Review 直接挂载连续差异文档并保持明确 Task + Run 身份，不提供列表/详情层级或内部返回；Escape 关闭右栏并回到真实对话入口；
- 普通 Run start/terminal、新 pendingUi 和 usage revision 不自动开合右栏、不抢焦点；切换 Task、关闭或对象失效不泄漏旧详情和已读取 bytes，晚到 Promise 不覆盖新对象；
- 左栏折叠后完全隐藏且命令栏入口仍可达；Task Panel 关闭或 overlay 显示后功能不丢失；停靠态始终保留至少 480 px 中央工作面，低于 820 px 与左栏互斥，低于 620 px 使用全宽 overlay。
- Windows Renderer 窗口按钮在登录页与 Workbench 均可见、键盘可达；最小化、最大化/还原和遵循 `close_policy = hide` 的关闭命中真实窗口，按钮区域不进入 drag candidate；

### 19.9 视觉与 Foundation

- `ui-design.md` 是唯一设计规范，品牌资产、token CSS、Foundation 组件与产品样式只作为实现镜像；
- 品牌 primitive 与本文逐字一致，不存在 `brand-*`、组件局部色板或其他平行视觉值；
- Foundation 组件只消费 semantic token；Tailwind bridge 不引入新值，产品 feature 不重建基础控件；
- 智能紫只用于品牌、关键动作、当前选择、焦点和真实活动路径；成功、等待、失败与删除保持独立语义并提供非颜色提示；
- 当前 Light 主题在桌面与约 390 px 窄屏下完成对比度、键盘焦点、长中英文、横向溢出和 reduced-motion 检查；未经同等验收不得显示 Dark/Appearance；
- 标志、应用图标与托盘图标保持同一基础几何和各自用途安全区；平台生成资产不得引入未经设计的渐变、阴影或材质；
- 普通页面不使用大面积紫色渐变、玻璃拟态、装饰性节点、粒子、3D 透视或游戏 HUD。

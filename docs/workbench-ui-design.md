# MetaWork Workbench UI 设计

> 状态：维护登录优先、任务中心和 capability-gated 的成熟产品目标；未通过对应能力验收的界面不得出现
> 设计基线：MetaWork 自有的“明亮工作台 + 紫色任务流”；外部产品和参考图只用于提炼交互模式，不构成可复制的布局、品牌或组件规范

## 1. 文档职责

本文档把现有视觉稿补充为可实现、可测试的 Workbench UI 方案，定义：

- 用户可见的信息架构与术语；
- Workspace、Task 和一次执行在界面中的关系；
- Task 内容、当前状态、审批、权限、结果与错误状态；
- 左、中、右三栏及输入区的职责；
- 国际化、视觉、响应式、平台适配和验收矩阵。

本文档不替代其他 source of truth：

- 产品范围与行为以 [产品需求](requirements.md) 为准；
- 系统边界、Renderer/Host/AgentCore 职责以 [高层架构](architecture.md) 为准；
- AgentCore 事件、线程、所有权和生命周期以 [AgentCore 集成契约](agentcore-integration.md) 为准；
- 当前 ABI 能力以 [AgentCore ABI v1 消费基线](agentcore-abi-v1.md) 为准。

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

Windows 与 macOS 当前锁定的 development ABI v1 revision 9 已为以下既有界面提供可验证数据；Skill catalog、typed Skill Run 与 Composer Slash 使用同一 Workspace/Task snapshot 和 Run product path：

- 文本流、工具开始/进度/结果、Run progress、usage、context warning、auto compact、retry 和 stream done；
- tool permission 同步用户请求；AgentCore ABI 虽保留 Ask question，但 MetaWork Agent 不开放对应 built-in；
- Workspace current / Task pinned Skill catalog、typed Skill Run 与独立 Skill rejection；
- Run 状态、六种终止原因，以及 Session 是否仍可继续。
- revision 8 的 `run_state` 阶段观察；Workbench 将其投影为 Current activity 文案，并按 transition sequence 丢弃过期观察。

因此当前产品只在 Task 内容区显示用户输入、Assistant 回复、权限决策面、唯一当前状态和必要的终止结果；真实 usage 仅进入按需 Task overview。普通信息不足时，Agent 通过 Assistant 回复说明问题并结束当前 Run，用户从 Composer 继续，不进入结构化 Question wait。工具开始、进度和结果继续作为 Host 事实存在，但不作为面向用户的主叙事。Plan、plan approval、Outputs、Files changed、持久权限管理和 custom UI 均保持隐藏；它们在本文档中的设计是后续 capability 到位后的产品规范，不是当前实现承诺。Renderer 不解析工具参数、stdout 或普通文本来猜测这些状态；Current activity 的细粒度文案只来自 Host 对 AgentCore `run_state` 的受序列保护投影。当前 Renderer 合同已提供独立 Workspace projection、Task-bound ExecutionConfig facts、正式设置 route，以及设置与 New task 共享的默认 API/模型选择；跨重启 rebind 等仍须等对应 capability 落地后才能宣称可用，差距由 [验证规范](validation.md)明确记录。

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
├── Model Connection registry
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
- `Account` 是 Metask 身份与执行能力入口；Model Connection 是独立的用户管理执行入口，二者都可以提供默认配置。
- `Model Connection` 是一个明确协议、endpoint、credential 状态和模型目录的 Host-owned 配置，不是第二个 Account identity。
- `Workspace` 是独立产品对象，不能只从 Task 路径反推。
- 产品对象就是 `Task / 任务`；每个 live Task 在当前进程中持有一个内部 Agent `Session`，但 Renderer 合同不暴露 Session 身份。
- `Turn` 和 `Run` 通常不直接命名，用当前活动、排队、停止和结果表达。
- 一项 Task 可以包含多次用户补充和多次执行；停止一次执行不会删除 Task。

当前 Renderer 产品合同为 `metawork.renderer-bridge` 固定 revision 1：`connect` 精确协商后才开放产品路径，snapshot 根节点包含无 secret `capabilities`、`account`、`skillCatalog`、`skillManagement`、`mcp`、`workspaces`、`scheduledTasks` 与 `tasks` 且不维护局部版本；Model Connection projection 位于 `account.modelConnections`，精确默认 identity 位于 `account.selectedModelConnectionId`。Account 只发布 `state`、`catalogState`、Host 判定的 `canCancel` / `canCreateTask`、脱敏 catalog/connection selection 与 generation。Workspace 独立于 Task 发布，durable Task 不携带 Account identity、API Key 元数据或 connection credential locator。快速开发阶段直接原地 hard cut 合同内容，不提供临时形态兼容层或可选字段退路；任何合同类版本标识的变更必须先得到用户显式同意。Agent 内部 Session route identity 不属于 Renderer 产品模型。

### 3.2 规范术语

`en-US` 文案定义产品语义，`zh-CN` 是首个完整本地化版本。

| English source       | 简体中文     | 使用说明                            |
| -------------------- | ------------ | ----------------------------------- |
| Workspace            | 工作区       | 本地目录和任务归属范围              |
| Task                 | 任务         | 用户可持续补充的工作上下文          |
| New task             | 新建任务     | 不使用 New session                  |
| Skills               | 技能         | MetaWork 用户 Skill 目录与健康      |
| MCP                  | MCP          | 可信服务、连接状态与已发现工具目录  |
| Account              | 账号         | Metask 登录、身份、托管 API 与退出  |
| Model connection     | 模型连接     | 用户管理的 provider、服务地址与模型 |
| Model                | 模型         | 新 Task 的执行模型，不称模式        |
| Task overview        | 任务概览     | 按需活动摘要与详情，不称 Monitor    |
| Current activity     | 当前活动     | Agent 此刻正在进行的可观察动作      |
| Plan                 | 计划         | 只在有真实结构化计划时显示          |
| Outputs              | 结果文件     | 用户关心的最终交付，不称 Artifacts  |
| Files changed        | 文件变更     | Agent 实际修改过的文件集合          |
| Needs your attention | 需要你处理   | 权限审批或计划确认                  |
| Allow once           | 允许一次     | 仅批准当前请求                      |
| Always allow         | 始终允许     | 创建可撤销的持久权限规则            |
| Stop task            | 停止任务     | 停止当前执行，不删除任务            |
| Stopping             | 正在停止     | 等待真实停止结果                    |
| Interrupted          | 意外中断     | 与明确失败区分                      |
| Show in Finder       | 在访达中显示 | Windows 为 Show in Explorer         |

## 4. 主窗口信息架构

> Capability：**当前**。登录优先 gate、独立 Workspace projection、左栏、New task、Settings overlay、Task 内容与按需 Task overview 已进入当前 shell；未通过 capability gate 的 Task overview 模块仍必须隐藏。

### 4.1 总体布局

```text
┌───────────────────────────────────────────────────────────────┐
│ Integrated title/command bar · context · search · controls    │
├──────────────┬────────────────────────────────┬───────────────┤
│ New task     │ New task Composer              │ Task overview │
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
- Task overview：打开时 304 px；审批、活动详情、usage 或真实结果只决定模块是否可用，不触发普通 Run 的自动开合。除新的 `Needs your attention` 可自动打开一次外，显隐由用户控制并在 Run terminal 后保持稳定；
- 已有 Task 不额外占用独立内容标题区；Task 名称只在顶部命令栏显示；
- 中间正文推荐最大宽度：760 px；
- 表格、diff、日志和文件预览可以使用中间区域的可用宽度；
- Native 主窗口声明 320 × 520 logical px 的系统最小尺寸，保证窗口不能被缩到 Renderer 已定义布局下限之外；960 × 680 仍只是窄窗口回归样本，不是固定设计画布；
- 低于约 1100 px 时 Task overview 使用右侧非模态覆盖层或保持关闭；低于约 820 px 时左栏和 Task overview 都使用互斥覆盖层；低于约 560 px 时命令栏隐藏次级文字。

左栏折叠后完全隐藏并把宽度归还中央工作面，不保留 56 px 图标栏，也不用匿名图标映射任意 Task。命令栏左侧始终保留打开/关闭入口，折叠状态与桌面宽度按用户偏好保存。Task overview 内容只决定模块和入口是否可用；显隐只由用户动作、Task 切换或新的 `Needs your attention` 单次自动打开改变，并按 Task 保留当前应用会话内状态，不持久化为空面板偏好。折叠只改变视图，不改变 Task、审批或运行状态。

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
- 命令栏只包含左栏开关、当前 Task 名称、全局搜索和按需异常入口；不在 Task 名称前重复 Workspace，`左栏开关` 只控制能力与 Task 导航，不兼任 Inspector 开关；
- `WindowTitlebar` 只声明一个 drag candidate。browser-side Bridge 在 animation frame 内镜像该区域与按钮、输入、选择框、标签、链接、disclosure、可编辑内容和显式 no-drag 内容的交集排除区；区域数量、数值、viewport、native top band、document generation 和精确启动窗口 identity 均由 Host 重新校验，任何 malformed、stale、多 candidate 或越界输入都 fail closed；
- 窗口 resize/maximize/restore 由 Native SDK/OS 执行，并通过 Native SDK 正式 resize event 通知 browser-side Bridge；Bridge 在当前 document generation 内合并最新 viewport 与候选后执行 `sync`，不得因 resize、layout 或 command failure 重新 `connect`。React 不保存或推导窗口状态，只由 `maximized` Host 真值选择互斥按钮；
- Windows 不递归 subclass Chromium 的跨进程 child HWND，也不由 Renderer 模拟窗口位移；在 Native SDK 提供正式 System WebView drag-region 能力前，Host 只对同 generation、当前逻辑主鼠标键仍按下、实际 OS 光标属于已绑定 root 且命中最新 candidate-minus-exclusions 的手势发布 live-pointer drag，并把该手势交给 Windows caption move loop。Renderer 坐标不构成执行 authority，一次 drag 失败只结束当前手势，不使已验证 region snapshot 失效。macOS 对应请求只调用 Native SDK 0.8.0 的 `startWindowDrag`；React component 不注册 double-click 或 context-menu handler；
- window-chrome bootstrap capability 不依赖 ProductDelivery connection，使登录/连接失败页仍保留系统窗口行为。它只接受 connect/sync/disconnect、Host capability gate 控制的 live-pointer drag，以及绑定当前 document generation 的 `minimize | toggle_maximize | close` 固定语义动作；不接受 window id、任意 action 或独立 state query；
- 正常连接、恢复成功和普通操作成功不持续占据命令栏；只有同步失败、命令失败或其他确实需要用户行动的异常才显示状态入口；
- 异常状态按 connection、account、Workspace identity 或 Task identity 分域保存；并行 Task 的结果不得互相覆盖，命令栏只选择当前上下文中优先级最高的一项显示；
- 顶部命令栏在已有 Task 且 Task overview 可用时提供稳定的入口图标，accessible name 随状态使用 `打开任务概览 / 关闭任务概览` 并发布 `aria-expanded`；New task、无 Task 或没有任何可检查事实时不显示该按钮；
- 未登录界面的应用工具栏只保留产品 identity 与语言入口；语言不能藏进尚不可进入的设置；
- Renderer 关闭按钮必须进入平台的 user-close 语义并遵循 manifest `close_policy = hide`，后台 Application 与计划任务继续运行；重新打开由 Native SDK 托盘菜单进入 Application 的 `showWindow`/`focusWindow` capability，显式 Quit 才进入应用 shutdown；
- 不使用 `chromeless`；系统 resize frame、Snap Layout、拖动、双击、系统菜单、DPI 与高对比行为只按真实平台验收声明，不由 WebUI 模拟。Renderer 只绘制按钮并提交固定语义意图，不复制这些底层行为；
- 语言、API、模型和诊断进入设置或对应任务上下文，不常驻命令栏；
- 不在命令栏放 ABI、Provider、Host mode 等工程状态。

平台文案、路径、快捷键和文件管理器动作按 OS 切换。

## 5. 左栏：能力与 Task

> Capability：**部分当前、部分目标**。Renderer 合同已提供 MetaWork 顶层与 Workspace/Task 分离的 revision 9 Skill catalog projection；本地 package/inventory、详情与管理 mutation 是本次目标合同。shell 已提供稳定 New task、全局 Task 导航、行动优先分组和左下角账号入口；Skill 中心、消费 Host-owned management/Runtime/admission 事实的 MCP 页面与持久定时任务都作为同级全局能力进入该 shell。

### 5.1 Task 列表与路径上下文

登录后的左栏从上到下只承担五类稳定职责：品牌/窗口识别、New task、已接通的全局能力入口、Task 导航、左下角账号入口。搜索由标题栏或命令面板提供，不在窄侧栏重复占据首要位置。

- 左栏不显示 Workspace 标题、添加动作或切换器；它直接列出同一 canonical snapshot 中 owning Workspace 仍被投影的所有 Manual/Automatic Task，并按统一行动优先级分组。Workspace 移除后保留的历史 Task 不生成可点击的死入口；
- Task 被选择后使用自身绑定的 Workspace 路径，不提交额外的全局 Workspace 导航动作；不同路径下的后台 Task 都必须持续可见；
- New task 默认选择 Automatic Workspace，工作目录控件直接显示“默认”；此时不提前创建 Workspace 或 Task，首次发送才请求 Host 分配 Automatic Workspace。用户可以在发送前切换到已有 Manual Workspace 或打开原生目录选择器；选择完成后只更新草稿上下文，不得自动创建 Task 或发送已有内容。Manual Workspace 直接显示 canonical directory，Automatic Workspace 统一显示“默认”，不得暴露随机目录或内部 kind 术语；
- New task 草稿按 Workspace 隔离。未绑定 Workspace 的临时草稿只在目标 Workspace 没有草稿时迁移；目标已有草稿时保留两边内容并打开目标草稿，不能覆盖或丢弃任一份；
- Workspace projection 的 `kind` 是 Host 事实；一个 Manual Workspace 可以承载多个 Task，Automatic Workspace 精确归属一个 Task；
- Composer 的工作目录控件只选择、添加或重新授权 New task 路径；设置页不提供 Workspace 生命周期管理。设置作为覆盖整个 Workbench 内容区的长期 surface 打开，保留窗口壳层和底层 Workbench 挂载，拥有自己的分区导航与内容滚动，关闭后恢复原工作面；
- 再次打开历史 Task 只保证可浏览记录；需要访问原目录时重新选择或授权，能否继续执行还必须服从 §6.4 的 Conversation 与 execution binding 规则；
- MetaWork 重启后，左栏直接使用 Workbench 恢复的 Task 列表和顺序；点击 Task 打开其已保存时间线，不自动创建新 Task、不重放最后一次输入，也不把恢复的 `interrupted` 显示成仍在运行；
- `taskHistoryPersistenceHealth = degraded` 只表示少数已保存 Task 无法恢复；由于新 Task 和其他有效历史仍可用且没有用户可执行的恢复动作，左栏不为它显示常驻提示。`read_failed / corrupt / write_failed / outcome_unknown` 这类 canonical store 或提交状态不可相信时继续显示提示并禁用 mutation。历史读取失败或整体损坏不得伪装成空列表，`outcome_unknown` 明确要求重启，Renderer 不提供盲目重试同一命令的入口；
- Task 行不保留可见的文字状态标签。运行中使用紫色旋转 loading 图标，需要处理或失败使用对应语义图标；完成使用醒目的实心提示点作为一次性未读提醒，颜色沿用主操作色。提醒身份绑定到最新完成 Run，后台完成时显示，用户打开该 Task 且其工作面可见后视为已读并隐藏；Task 再次完成新的 Run 时重新显示。
- Task 的重命名、归档/恢复和删除从内容区标题栏移除，统一通过左侧 Task 行的右键菜单访问。停止当前运行仍保留在内容区作为即时运行控制；不存在独立的“结束任务”动作。

### 5.2 全局能力入口

> Capability：**当前与受 gate 目标**。Skill 入口只依赖现有 AgentCore revision 9 discovery/catalog；定时任务入口依赖 Workbench-owned 持久 schedule projection、后台 Host timer/notification 与真实 Task admission。MCP 入口与 route 已进入稳定 shell；当前合同由 Workbench typed 管理能力、Runtime/catalog availability 与新 Task authority 三类事实共同驱动，页面不得把其中任何一个状态冒充另一个。

`新建任务`、`技能`、`MCP` 与 `定时任务` 位于 Task 列表上方的同一个纵向紧凑菜单，不使用窄侧栏中的卡片宫格，也不通过额外分组间距制造父子关系：

```text
MetaWork

  +  New task
  /  Skills
  ⌁  MCP
  ◷  Scheduled tasks

Tasks
```

- 四个菜单项使用相同行高、左右 padding、图标列、字号、字重、hover 与 focus 样式；`New task` 不再使用独立填充按钮，快捷键只作为 tooltip 或不改变布局的尾部提示；
- 当前能力 route 使用 `brand-100` 弱背景、`brand-700` 图标/文字和左侧 2 px 选中标识，并设置 `aria-current="page"`；选中不能只靠颜色；
- 一个能力可用时只显示一行；后续能力按真实 owner 与使用频率增加，不预留 disabled 占位、不用 `More` 收纳尚不存在的产品；
- 点击能力入口保留完整 Workbench 左栏和 Task 选择，只替换中央 route；点击 New task 或 Task 回到对应 Workbench route。Settings 覆盖整个 Workbench 内容区，保留窗口壳层和底层 Workbench 挂载，不重复显示或操作 Task 左栏；
- 能力页面打开期间后台 Task 继续运行，左栏的 `Needs your attention`、Running 与失败信号继续更新。

### 5.3 Skill 中心

> Capability：**当前合同**。页面在 revision 9 catalog/health projection 之上消费 Workbench-owned 本地 package、inventory、管理 mutation 与“用户默认 + Manual Workspace 覆盖”enablement policy；不要求 AgentCore 增加安装或来源身份 API，也不把管理 projection 当作 Session execution binding。

Skill 中心只有一个工作：管理 MetaWork 已知的本地 Skill 资产及用户/项目启用状态。Personal 开关定义所有项目继承的用户默认值；Project 开关写入当前 Manual Workspace 的显式 enabled/disabled 覆盖，并提供“恢复跟随用户”清除覆盖。创建和修改仍属于普通 Task；在线市场、远程更新、Preset、标签、排序、中央仓库和多 Agent 同步当前不存在，也不显示占位入口。

中央工作面沿用定时任务页的最大宽度、标题节奏、按钮和行动优先分组，使用与 Workbench 一致的紧凑卡片，而不是管理表格或外部市场视觉：

```text
Skills                                           [ Import skill ] [ Refresh ]
Manage skills available to MetaWork.

[ Search skills…                              ]  [ All ] [ Personal ] [ Project ]
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
- 搜索过滤已提交管理 projection 的 display name、description、invocation 和 argument name。`All / Personal / Project` 是范围筛选；选择 Project 后显示已注册 Manual Workspace selector，不借用左栏 current Workspace，也不列出 Automatic Workspace；
- 异常、冲突和 `pending_verification` 进入 `Needs attention`，正常资产进入 `Skills`；空分组不渲染，同一 Skill 不在两个分组重复；
- 常规桌面使用两列卡片，中等与窄窗降为一列。卡片使用 `canvas/paper`、`rule`、约 12 px 圆角和无常驻阴影；hover/focus 只增加极浅 brand 背景、边框和最多 1 px 位移；
- 卡片显示统一的线性 Skill 文档图标、display name、单行 description、范围、可选 monospace invocation 和带文字的状态。删除原 `/` 装饰；不显示安装量、`Installed` 或来源品牌徽章。能够精确映射对应 current catalog member 的 Personal 与 Project asset 都在卡片尾部显示独立 switch：Personal 使用 `已启用/已禁用`，Project 的 inherit 状态显示 `跟随用户设置`，显式覆盖额外显示 `恢复跟随用户`。external source kind 不自动剥夺启停 authority，但 catalog/selection 不可用或 identity 不可证明时不显示可操作开关；
- 状态颜色只复用 `live / amber / danger`，且必须同时显示文字或图标。来源、revision、资源数量和物理管理细节留在 drawer；
- 卡片是带标题的 `article/listitem`，打开详情的按钮、启用 switch、“恢复跟随用户”与可能存在的 `···` menu button 为并列元素，禁止嵌套 interactive element。开关最小命中区 44 px，checked 使用 `#8A4ED1`/主动作 token，off 使用中性边框色，并始终有文字、键盘焦点与 disabled 状态；Renderer 不 optimistic 更新，等待 committed Snapshot 后再反映新状态；
- Skill invocation、display name、description、argument name、文件名和用户内容不翻译；页面标题、范围、状态、动作、错误和空状态进入完整 locale catalog。

详情 drawer：

- 点击卡片主体打开右侧 drawer；窄窗切为整页详情。顶部显示名称、description、范围和 health；正文依次显示 invocation/参数、安全渲染的 `SKILL.md`、资源/脚本/模板列表、结构化 issue 和折叠的安装信息；
- Markdown 禁止 raw HTML、script、远程 embed 和隐式网络加载；文件区只允许查看 package 内受支持的文本资源，不形成通用仓库或磁盘浏览器；物理路径、raw diagnostic、credential、内部 handle 和 hash 不进入普通详情；
- Drawer 底部提供 `Export .skill`、`Modify in new task` 和 `More`。`More` 仅在有精确管理 authority 时包含 `Re-import` 与 `Uninstall`；外部管理资产显示原因并隐藏不可执行动作；
- `Modify in new task` 只导航到预填普通 Text draft，不创建 Skill editor 或专用 Agent protocol。关闭 drawer 后焦点回到原卡片；异步刷新不抢焦点或关闭用户正在阅读的详情。

导入 drawer：

- `Import skill` 打开同一 drawer 体系，首屏突出 Host 原生 `Choose .skill or .zip`，次级入口为 `Choose folder`；当前 Native SDK 没有可信 drop capability，因此不显示不可兑现的拖放热区，也不提供 GitHub、skills.sh、URL、市场或代理配置；
- Native 选择先生成 window-bound、一次性 staged capability；Renderer 只消费 opaque preview identity。Preview 显示名称、description、`SKILL.md`、文件清单、总大小、候选 invocation 和机械安全检查结果；导出同样通过 Host 原生目录选择取得一次性目标 authority，由 Host 生成规范文件名并写入，不让 Renderer提交路径；
- 用户选择 `Personal` 或一个已注册且已授权的 Manual Workspace。范围默认沿用页面筛选，但必须在最终确认中可见；没有合法目标时安装保持禁用并提供恢复动作；
- 同名目录、相同 invocation、project override 或 external asset 都必须在确认前说明精确影响，安全默认是取消；不提供自动重命名 invocation、静默覆盖或“仍然继续”绕过失败；
- `Import` 后 drawer 展示 progress。成功只在资产发布且 catalog 确认可用时成立；候选 definition/resource/conflict failure 回滚并保留 preview，catalog 暂时不可验证时显示 `Installed, awaiting verification` 与 Retry/Uninstall；页面导航和后台 Task 不被冻结。

状态、空状态与恢复：

- `ready` 展示已提交 inventory 与 health；`degraded` 保留可用资产并把对应 issue 卡片置于 `Needs attention`。issue 只使用 bounded code、scope 和可选 invocation，不显示 raw diagnostic；
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
- 创建/编辑使用右侧 drawer，窄窗切为整页。按 `名称`、`任务内容`、`运行时间`、`确认摘要` 排列，名称输入始终位于表单最上方。任务内容只有一段 Text 指令，不提供 Workspace、Skill 类型切换、Skill 选择器、catalog revision 或参数配置；需要采用某个全局 Skill 时由用户在指令中说明。每次 occurrence 由 MetaWork 分配新的 Automatic Workspace，界面不要求用户理解或选择 Workspace；
- Host 投影 `automaticWorkspaces = false` 时，Text 模板仍可查看，但创建/编辑不可保存；不得静默采用当前或第一个 Manual Workspace；
- 时间选项优先呈现一次、每小时、每天、工作日、每周与每月，并明确本地 timezone；高级固定间隔可折叠，Renderer 只提交 Host 可验证的结构化 recurrence，不拥有 timer 或 occurrence；
- 保存前提供一句完整确认摘要，例如“每个工作日 08:00 运行「每日工作简报」，结果完成后通知我”；provider、generation、Unix seconds 和 catalog revision 不进入产品文案；
- 新建、保存、暂停/恢复、立即运行和删除使用 Host typed result 与 optimistic `scheduledTaskEpoch`。命令 timeout 后先刷新 canonical snapshot，不自动重放；
- 点击计划打开 detail drawer：上半部是定义与下一次运行，下半部是有界运行历史。每个 occurrence 链接到其真实 Task，并显示完成、失败、已跳过、延迟或等待处理；结果历史不复制 Task timeline；
- 删除计划不停止或删除已经创建的真实 Task；`立即运行` 也通过同一 occurrence 与 Task admission，不能建立测试/手动专用路径；上一次真实 Task 仍 non-terminal 时显示 `已跳过：上一次仍在运行`；
- 执行配置或 Workspace authority 变化时显示 `需要处理`，并要求用户编辑确认；需要 Agent permission 的 occurrence 链接到真实请求并发出系统通知，不把等待伪装成 schedule failure；
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

`execution_ready` 后，左栏底部固定显示 Metask identity：头像或首字母、显示名和简短连接状态。它是全局账号入口，不显示完整 API Key，也不承担模型快速选择。

点击后打开轻量菜单：

```text
张三
Metask 已连接

账号设置
模型连接
退出登录
```

- 账号菜单中的退出登录在当前 Workbench 上直接打开危险操作确认框，不先导航到设置；确认文案说明本机凭据会被清除、本地 Task 与历史记录会保留，确认后仍走 Host execution replacement gate，不能只清 Renderer 状态。账号设置可以保留同一 Host 命令的独立退出入口，但不是账号菜单退出的必经路径；
- 账号菜单只负责身份和导航；Metask API 目录进入账号设置，用户管理的服务进入模型连接设置；
- 未登录时保留本地 Workbench 历史，并把左栏账号入口切换成登录动作。

## 6. Task 生命周期

> Capability：**混合**。四轴 Run/Task 状态、单 Task 单 in-flight Run 与只读跨重启产品历史属于当前合同；Agent Session/Conversation continuation 和显式 rebind 属于目标能力。

### 6.1 核心规则

- 每个 Task 同时最多一个 active operation；当前 operation 可以是 Run、manual compact 或 Conversation restore，三者不能并发；
- 每个 Task 创建时建立第一个 execution binding epoch，固化不含 secret 的 Provider 与 opaque execution generation，并让对应 Agent Session 持有 owned ExecutionConfig；模型是独立的 Task binding，可在 Composer 为下一轮切换，切换不修改 `binding.epoch`；默认连接/API/模型变化不静默改写已有 Task；
- 多个 Task 可以后台运行，超过 Host executor 能力时明确排队；
- 切换 Task 不停止执行；
- `Stop task` 只停止当前执行，不删除历史、输入或已有文件；
- 一次执行完成后 Task 回到空闲，可以继续补充要求；
- `Failed` 表示得到明确失败结果；
- `Interrupted` 表示 Host/Core 生命周期被破坏，结果可能不完整；
- 中断后不得自动重放可能有副作用的工具。

### 6.2 状态模型

不得把 Task 生命周期、当前 Run 阶段和最近一次 Run 结果压成一个 enum。Host projection 分别提供以下状态，Renderer 只派生展示标签。

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

`draft` 是进入 Workbench 后、尚未创建真实 Task 的 Renderer 临时页面，不进入 Host Task lifecycle。它默认持有 Automatic Workspace intent，也可以切换到 Manual Workspace identity；发送前必须同时满足相应 Workspace admission 与默认执行配置。一次 Run 完成后 `Active operation` 与 `Active Run phase` 回到 `none`，`Last Run outcome` 保留结果。Manual compact 完成后 active operation 同样回到 `none`，其 outcome 进入独立、有界、append-only 的 maintenance history，不改写最近一次 Run outcome。Conversation restore 完成后 active operation 回到 `none`；成功只改变 runtime attachment/continuation，失败只改变派生的 unavailable reason，二者都不新增 Run、消息或 maintenance history。

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
3. 点击左栏 Task 始终只是导航。满足资格的 detached Task 在 Composer 上方显示历史已准备提示；用户发送第一条新消息时，Renderer 才提交现有 restore，并等待 Host snapshot 确认 attachment 后继续提交该条 Run；选择、reload 或 timeout 不会自动触发 restore；
4. restore 期间显示 `Restoring conversation / 正在恢复对话`，禁用发送、compact 和重复 restore。左栏把该 Task 归入正在运行分组，但不能伪造 Agent Run 或 Stop 按钮；
5. restore 失败时保留可阅读历史、用户草稿与稳定原因；Host 仍发布 `continuationRecoveryAvailable = true` 时显示 `Try again / 重试`。timeout 只触发 canonical snapshot resync，绝不重放 restore 或 Run；
6. 成功后 Host 原子发布 attachment 与 `continuationAvailable = true`，Renderer 只在这一状态确认后提交一次 Run。`continuationAvailable`、`continuationUnavailableReason` 和 `continuationRecoveryAvailable` 是同一 continuation 模型；不得建立第二个 `recovery.state` 或由 Renderer 猜测资格；
7. checkpoint、Task/Workspace/Execution identity、Agent Runtime、checkpoint store 或 Task persistence 任一核心 gate 不满足时只显示对应 unavailable 说明，不显示恢复按钮。Workspace 是否因导航语义 `visible=false`、Skill catalog 是否 ready、MCP selection 是否可重建、Permission 是否仍有效以及 projection capacity 都不是恢复资格；这些可选能力缺失时 Host 可以发布成功但 degraded 的 attachment，普通 Text 立即可用，相关能力按各自现有显式流程恢复。Task store read/corrupt/write/outcome-unknown health 由 Host 发布；Renderer 不自行清空、修复、迁移或重试持久数据；
8. `closed` 不是 Task 产品状态。非归档 Task 只要 Host gate 允许，就应恢复 attachment 并继续；归档只控制日常列表可见性，删除才永久移除记录。

恢复要求 checkpoint record 与 Task execution binding 证明 source Task/binding、provider、Task binding epoch 和 terminal anchor 精确，当前 execution authority 则作为独立 target readiness：provider 相同、Task pinned model 仍在当前 catalog，且 restore start→commit 期间 target generation 不变。历史 H 与当前 G 可以不同；H≠G 时 Host 必须先以 durable adoption 同步推进 Task execution generation、binding epoch 与 checkpoint anchor epoch，commit 成功后才安装 attachment，旧 Run 的 generation/model/usage 不改写。checkpoint 的 model 只用于满足 AgentCore restore expectation，并与其 terminal Run 的历史 model 自洽校验；candidate 提交前由 Host 以 Task 当前 model binding 调用 `session_set_model`，不能把 checkpoint 的旧 model 或 Account 当前默认 model 静默写回 Task。durable Task 不保存 account、API Key 或 Model Connection identity，恢复不能从当前 Account projection 反推或补写这些字段。该 adoption 只连接同一 Conversation 的 source 与兼容 target，不允许切换 provider 或 Task model；未来的通用 rebind 仍必须由用户明确发起，重新校验 Workspace 和当前 catalog ownership，创建新 binding epoch/Session，并以不可改写的配置边界保留旧 Run、usage 与模型归属；失败不得回退到静默默认值。

## 7. 中间区域：Task 内容

> Capability：**当前**。用户输入、Assistant 回复、permission 与 Run 状态属于当前产品路径；typed Delivery、Outputs、FileChange 与 Plan 属于未来 capability，当前不得从 Assistant 文本或 Tool 记录推断。

中间区域使用同一套 MetaWork AI UI 基础语义：`Conversation` 组织阅读面，`Message` 表达用户与 Assistant 发言，`Activity` 表达当前过程与必要终止状态，`Intervention` 表达真正需要用户介入的决定，`Composer` 控制下一步输入，`Markdown` 与 `CodeBlock` 呈现回复内容。它们是 Renderer 视觉语法，不把 Bridge 或 AgentCore 对象直接变成组件。当前不存在第二套 Task 专用消息、状态、请求或输入表面，也不以 Tool、Reasoning、Question 或 Approval Card 建立平行组件分类。

### 7.1 内容模型

中间区域按 Task 中 Run 的稳定顺序只显示用户输入与 Assistant 回复，不按 Run、Tool 或 AgentCore event 结构组织页面。当前执行状态、待处理请求和 terminal notice 是独立的临时或行动组件，不伪装成历史节点。

### 7.2 用户指令

- 使用浅紫色“任务指令”区块，最大宽度约为正文的 72%，靠右但不使用聊天尾巴、头像或左右双方气泡布局，也不重复显示“你”等归属标签；在窄窗口下可以放宽到约 88%；
- 首条指令建立 Task 目标，后续指令作为明确的补充或重试节点；普通界面不显示 Run ID；
- 附件以文件/目录 chip 展示名称、数量和大小；
- 已发送内容不能静默编辑历史；
- 未来的“编辑并重新运行”必须显式创建新的执行分支或新 Task。

### 7.3 Agent 回复

- 不使用头像和大气泡，使用正文排版；
- 支持 Markdown、表格、代码、引用和链接；
- 流式生成只显示克制的末尾活动指示；
- 不展示原始 chain-of-thought；`thinking_chunk` 只显示“正在思考”的安全状态，`text_chunk` 开始后显示“正在撰写回复”；Renderer 还必须把 Host 已投影的 Starting、Generating response、Executing tools、Retrying、Compacting 与 Finishing 显示为本地化 Current activity；存在 running tool 时显示“正在执行工具”，尚未取得可识别细粒度事件时显示“正在等待模型响应”，active Run 不能统一退化成“正在工作”；
- `assistant` 只表示回复内容，不标记为 Delivery、Output 或最终成果；
- 不从回复文本解析活动、计划、文件变化或完成状态；不得为每条内容重复“Agent”标签或品牌头像。

### 7.4 当前状态、请求与结果

- active Run 只显示一个来自 canonical phase/status 的紧凑临时状态；不得把 Tool 名称、输入、输出、usage 或 Run ID 带入主阅读流；
- pending UI 位于当前 Assistant 回复之后、Composer 之前，并提供唯一可操作控件；
- `completed` 且已有 Assistant 回复时不追加重复的完成条；空回复完成、停止、失败、中断或 dependency failure 只显示准确状态、原因与真实可用的恢复动作；
- Renderer reload、成功同步、Tool completion 与 Compact history 不生成主区记录；只有同步失败、当前 maintenance 或内容可能不完整时显示相应状态。

### 7.5 滚动与密度

- 用户位于底部时自动跟随最新内容；
- 用户向上查看历史时停止自动滚动；
- 出现 `Jump to latest`，不能强制抢回滚动位置；
- 流式更新不能破坏文本选择、输入焦点或当前阅读位置；
- 每个 Task 独立保存当前 Renderer 会话内的阅读位置和 following-latest 状态，切换 Task 不得继承另一个 Task 的位置；
- `Jump to latest` 是普通长内容阅读能力，不使用 Timeline 命名；不增加改变底层信息可见性的密度模式。

## 8. Composer 与执行控制

> Capability：**混合**。当前 Run gate、停止、本地草稿、New task 主视觉、默认模型选择和既有 Task execution binding 提示已经由当前 Renderer 合同表达；跨重启恢复与显式 rebind 仍是目标能力。

已有 Task 的 Composer 固定在中间区域底部，并为滚动内容预留空间。New task 的 Composer 位于工作面的视觉中心；Host 确认创建真实 Task 后，它再通过一次克制过渡落到底部。

New task 页面以 Composer 为绝对主视觉。其上方使用直接的行动标题和一句 Workspace 工作说明，不使用人格化欢迎语；Composer 下方不放示例、推荐卡片或快捷指令。输入框附近只放与“这次 Task 如何开始”直接相关的上下文：连接与模型、Workspace、附件（能力真实接通后）和发送。API Key、连接编辑、账号目录刷新、权限默认值、显示密度与诊断不得堆入同一行。

```text
┌────────────────────────────────────────────────────┐
│ 描述你希望 MetaWork 完成什么……                   │
│                                                    │
│ 模型：当前连接 · 当前模型 ▾                  发送 │
└────────────────────────────────────────────────────┘
  Workspace：metawork ▾
```

模型选择规则：

- New task 始终显示当前默认连接与模型；点击后只列出当前连接的 Host-validated 模型目录；
- 弹层顶部显示当前连接的脱敏名称与 Provider，并提供 `模型连接设置…`；不得显示完整 secret；
- 默认连接、Metask API/provider/credential authority 或 ready Model Connection 的模型变化更新 Account 当前默认 execution generation；只有同一已提交 Metask API 下修改默认模型时才只更新 Account preference、保持 generation 不变。两类默认变化都不热替换已有 live Task；detached 历史 Task 可在 §6.4 的 Conversation restore 中采用同 provider、可承载其 pinned model 的当前 credential authority，并通过窄 binding adoption 提交新 generation，任意 provider/model 变化仍只能走未来的显式 rebind；
- 已有 Task 的 Composer 显示当前 binding epoch 的模型事实，历史按 epoch 保留原模型；第一版不提供 live Session 热切换；
- 正在更新默认模型时只禁用相关选择和发送 admission，不冻结导航、历史阅读或其他 Task；
- 模型不可用时说明原因并给出刷新或设置入口，不能留下永久 disabled selector。

Composer 布局与输入规则：

- 模型控件位于输入框内部左下角，发送位于右下角；textarea 与底部工具带共同组成一个完整圆角容器，不得拆成相互竞争的表单块。Workspace 位于容器外下方的轻量 breadcrumb 行，不能做成第二个有边框卡片，也不能放回输入框上方形成第二条上下文栏；
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

输入区中的模式选择只有在语义明确时才出现。`Standard` 不能作为无定义装饰；模型、权限策略、执行强度和显示密度不能混成一个模式。

运行中的输入不会发送给当前 Run，也不使用未验证的 `UiBackend.poll()` 模拟实时 steering。首版 Composer 只保存 Renderer 本地草稿，发送动作保持禁用并显示 `当前任务结束后发送`；当前 Run terminal 后由用户明确发送。不得自动提交、自动启动下一次 Run，或把草稿伪装成已排队状态。`queued` 只表示唯一已提交 Run 正在等待 Host executor，不表示当前 Run 后面还有另一条队列。未来只有在 AgentCore 发布 typed steering capability 后，才设计 `排队补充` 与 `立即打断` 的不同操作。

### 8.2 New task 首次发送

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

待处理请求是当前 wait state，不是历史：它显示在当前 Assistant 回复之后、Composer 之前；响应完成后从主内容移除。左栏和 Task overview 只负责提醒，点击后跳转到原请求，不在多个位置重复生成可操作按钮。

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

## 10. 持久权限

> Capability：**未来**。Host-owned 持久权限、strict Workspace security 和对应恢复/撤销合同尚未验收，本章控件当前必须全部隐藏。

### 10.1 基本原则

MetaWork 的持久权限仍是未来 capability；当前 AgentCore 只提供 Run once 与 Session scope choice，Renderer 不得把 Session grant 显示成永久规则。

持久权限 capability 完成验收后，审批卡片才可提供：

```text
Deny    Allow once    Always allow…
```

点击 `Always allow…` 后显示实际作用域，不能直接永久放行所有操作。当前版本不显示该入口。

`Always allow…` 不是固定出现的按钮。只有 Host 对当前请求返回可持久化的 rule candidate，并且对应 Workspace security、匹配器、存储和审计 capability 已通过验证时才显示；否则审批卡片只提供 `Deny / Allow once`。Renderer 不得自行把一次性请求扩展成持久规则。

### 10.2 作用域

| 能力            | 目标持久授权范围                                                           |
| --------------- | -------------------------------------------------------------------------- |
| Read            | 指定文件、目录或 Workspace 内受约束范围                                    |
| Edit            | 指定文件、目录或 Workspace 内受约束范围；不自动包含删除                    |
| Delete          | 独立权限，不由 Edit 隐式获得                                               |
| Bash            | 已验证 executable identity + 固定/受约束 argv、cwd 和 environment policy   |
| Project script  | Workspace identity + script/lockfile identity + 内容摘要，不等同 Bash 前缀 |
| Network         | 固定 scheme、host、port 及明确 redirect/DNS policy                         |
| MCP / connector | Workspace + server identity/version + operation                            |

`bash`、`sh`、`python -c`、`node -e` 等可以承载任意代码的解释器不能伪装成安全的命令前缀规则。

每条规则至少绑定：stable Workspace identity、tool identity/version、operation、canonical resource constraint 和 rule schema version。Host 必须在实际执行点重新校验规则，不接受 Renderer 声称已经命中。

以下变化使规则失效或要求重新确认：Workspace 被替换或重新授权、tool/MCP identity 或 major capability 变化、项目脚本内容变化、executable resolution 变化、目标经过 symlink 或其他解析后越过授权边界。检查与使用之间仍存在无法消除的 TOCTOU 时，Host 必须拒绝持久命中并退回逐次审批。

strict Workspace security 未通过前，不开放 Workspace 级 Read/Edit/Delete 持久规则；受控进程执行、process tree、network 和 environment 边界未通过独立验证前，不开放 Project script、Bash、Network 或 `Full access` 持久规则。即便对应 Gate 已通过，`PATH` 前缀、任意 shell/interpreter、可变脚本名和未约束 environment 也不能成为可持久授权范围。

### 10.3 管理与撤销

若未来通过独立的 strict Workspace security capability 开放权限管理，应由对应的 Workspace authority surface 展示规则；当前 Settings surface 不提供 Workspace 权限或生命周期管理。每条规则至少显示：

- 允许的动作和资源范围；
- Workspace；
- 创建时间和来源 Task；
- 最近使用时间；
- 当前有效、需要重新确认或已失效的原因；
- 撤销动作。

命中持久规则时，时间线保留 `Allowed by workspace permission` 记录。撤销只影响后续操作；若相关 Task 正在运行，可以额外提供 `Revoke and stop task`。

持久权限不得进入 Renderer 自管存储、Task 导出或聊天内容，默认不云同步。

### 10.4 Full access

可以为未来预留：

```text
Ask for approval
Use saved permissions
Full access
```

`Full access` 只能在 Workspace 设置中单独开启，不能在普通审批卡片中顺手授予。它不是绕过边界的总开关：只有所有已启用 tool 都能被 Host 强制限制在已验证 capability 范围内时才允许出现；strict Workspace security、process 和 network 边界未真实成立前不得开放。

## 11. 按需 Task overview

> Capability：**当前**。按需 Task overview 只承载 Needs your attention、Current activity / Last run 与真实 usage，不提供历史 Run 或 Tool 浏览。

Task overview 是当前 Task 的按需结构化摘要，不是固定存在的第三栏、第二份回复记录、日志面板或执行审计器。New task、无 Task 和没有有效模块的普通 idle Task 默认不占用右侧列宽。

用户通过顶部命令栏右侧的 Task overview 按钮稳定打开或关闭面板；主内容不提供 Tool、diff 或 usage 详情跳转。

出现内容时模块优先级为：

1. Needs your attention；
2. Current activity / Last run summary；
3. Context and usage。

规则：

- 空模块隐藏；
- 需要用户处理始终置顶；
- Current activity 显示此刻可观察动作，不复制完整工具输出；
- Run terminal 后，已经打开的 Inspector 用真实 outcome、状态和 usage 转为 Last run summary；只有 Host 发布 typed Run duration 时才显示总耗时，当前不得从 Renderer 时钟猜测；不得因为 Current activity 消失而清空内容；
- Context and usage 显示真实 usage、预算、压缩或警告，不显示伪百分比；
- 用户打开 overview 后在当前 Task 内保持打开，直到主动关闭；切换 Task 时显示目标 Task 自己的会话内状态；
- 只有新的 `Needs your attention` 请求可以对当前 Task 自动打开 overview 一次，且不能抢走主区请求的键盘焦点；普通运行开始、usage 更新或 terminal 都不得自动切换显隐；
- 切换 Task 是允许重新决定布局的显式边界：新 Task 使用自己的会话内显隐状态和内容，绝不能短暂显示前一个 Task 的详情；窄窗口自动打开时使用覆盖层，不触发中栏重排；
- Inspector 折叠不影响通知、审批或 Task 状态；
- 同一可操作审批只在主区请求中提供按钮，overview 只能提醒并定位，不能复制第二套操作。

当前只显示 Needs your attention、Current activity / Last run 和 Context and usage；Tool、Plan 和 Outputs 不渲染空壳、占位符或“即将推出”模块。

## 12. 文件变更与结果文件

> Capability：**未来**。只有 AgentCore 发布 typed FileChange/Output 事件并完成验收后才显示本章模块；当前不能从工具文本或文件后缀推断。

### 12.1 两类对象

- `Files changed`：Agent 在 Workspace 中新增、修改或删除的全部文件；
- `Outputs`：用户关心的最终交付文件、链接或结构化结果。

Inspector 默认只列 Outputs，完整 Files changed 进入中间工具活动。不能仅凭“新建文件”自动判断它是 Output；需要 Agent 的结构化标记或用户明确标记。

### 12.2 Output 卡片

Output 至少显示：

- 文件名和类型；
- `Generating / Ready / Failed / Missing` 状态；
- 大小、条目数或简短摘要；
- Workspace 相对位置；
- `Open`、`Show in Finder/Explorer`、`Copy path`；
- 支持时提供预览。

本地文件使用 `Open` 或 `Show in Finder`，不使用网页语义的 `Download`；只有结果尚未保存到本地时才使用 `Save as…`。

同一路径被再次写入时显示 `Updated`，不在第一版构造虚假的完整版本控制。真实文件缺失或被外部修改时要重新检测并显示状态，不能继续提供无效的打开动作。

### 12.3 结果完成态

一次执行完成时，中间区域提供简洁交付摘要：

- 完成了什么；
- 处理数量和关键指标；
- 异常、警告或需要复核的内容；
- 结果文件；
- 建议的后续动作。

Inspector 同步更新 Outputs，但不重复整段完成说明。

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

> Capability：**混合**。当前 Renderer 合同已提供登录优先、长期 Settings overlay，以及设置与 New task 共用的 Host-owned 默认 API/模型选择；跨重启 execution rebind 仍按独立 capability gate 验收。

### 14.1 首次启动

首次启动是独立于 Workbench 的登录与执行准备界面。它保持短、诚实且可恢复：

1. 按系统语言显示 MetaWork identity、一句价值说明和唯一主动作 `使用 Metask 登录`；
2. 点击后由 Host 打开系统浏览器完成 OAuth，原位置进入 `等待 Metask 授权`；
3. 等待期间提供 `重新打开登录页面` 与 `取消登录`，Host deadline 必须最终收口；
4. OAuth 成功后立即显示已连接 identity，并由 Host 自动恢复或加载 API Key 与模型；
5. 历史默认命中时自动恢复，唯一候选自动采用；只有无法由合同决定的真实 API/模型歧义才在同一首次启动界面请求选择；
6. 形成并安装 ready ExecutionConfig 后进入 Workbench New task；在此之前不显示 Workspace 侧栏、Task 列表、Composer 或空 Inspector。

```text
MetaWork

使用本地 Agent 完成真实工作
连接 Metask 后即可选择 Workspace 并创建任务。

[ 使用 Metask 登录 ]
```

首次启动不显示四步进度条，不要求用户点击“加载 API Key”，不出现 C1/C2、Provider target、generation 或 Keychain 等技术术语。`checking` 只显示稳定的品牌与检查状态；`authorizing` 只显示等待和取消，不提供“重新打开登录页”。OAuth 已成功而目录准备失败时保持当前 identity，在设置中提供重试。登录无效直接成为 `signed_out`，进入 Workbench shell 后左下角账号入口显示统一登录动作；当前模型连接设置入口保持隐藏，不显示已保存账号、重新认证、账号不匹配或上一次登录信息。

冷启动检查或 OAuth 授权期间使用稳定的品牌状态。确认 `signed_out` 后进入 Workbench shell 并保留本地历史；如果没有 ready Model Connection，只关闭 New task admission，不暴露尚未形成完整 capability gate 的模型连接设置。确认 `authenticated` 后继续目录准备。任何 live Task 若仍在运行，必须继续可查看和停止。

### 14.2 设置结构

```text
General
└── Language

Account
├── Metask identity and connection status
├── API catalog and default API
├── Refresh or sign in
└── Sign out and clear this device

```

设置是覆盖整个 Workbench 内容区的正式全局 surface，不用狭窄 popover 承载目录选择、错误恢复和危险退出。它保留窗口壳层，底层 Workbench 继续挂载但不可操作；进入后不重复显示或操作 Task 左栏，也不改变离开前的 Task、草稿、滚动和焦点状态。窗口标题栏保持一致，页面内 `返回工作台` 是返回入口；左下角用户菜单只负责打开该 surface 和少量直接动作。

设置树只列当前阶段已经完整设计并通过 capability gate 的项目。显示密度不作为设置；`Appearance` 只有在第二套主题完成设计、可访问性和平台验收后才能加入，首个浅色版本不显示空入口。

`Model connections` 当前不进入设置树，也不出现在左下角账号菜单。只有 management、Host-owned secure capture、provider connection test、默认 execution transaction 和已开放 provider admission 共同通过产品 gate 后才能整体恢复入口；不能只显示不可完成的空壳或“能力不可用”页面。

Workspace 生命周期不属于 Settings surface。New task 路径控件负责选择、添加和重新授权 Manual Workspace；Automatic Workspace 只随 owning Task 导航。Renderer 只在当前 draft 内保存 Manual Workspace identity，不维护 `activeWorkspaceId` 或其他全局活动 Workspace 镜像。

`Account` 规则：

- 进入该设置 route 的显式导航动作自动请求 Host 同步一次最新 API/模型目录；已有默认配置且 API 仍有效时，Host 自动沿用该 API 并加载其模型目录，默认模型下拉框不依赖一次 API 修改才能启用。已提交默认值在同步期间保持可读，手动 `重新同步` 只用于失败恢复或页面保持打开期间发生的 Metask 外部变更，不能成为打开下拉框或切换默认值的前置步骤；
- API 列表显示 Metask 名称、Provider、尾号和可用/需要处理状态；不显示完整 secret；
- Provider 是 Host 从 API catalog 确定的只读技术事实，只作为 API 名称下的次级元数据展示；Renderer 不提供 Provider、base URL 或 credential 编辑入口；
- 切换默认 API 后加载其模型目录，并明确它只更新默认选择、不改写 durable Task 历史或正在运行的 Session；
- 默认模型选择与 New task Composer 使用同一 Host-owned selection，不维护两份互相漂移的 Renderer preference；
- 既有 Task 只显示解释历史所需的 Provider、模型与 generation；不显示或保存 Account identity 与 API Key 元数据；
- 跨重启历史 Task 保持只读；设置变化不能使其静默采用当前默认值或伪造 Session；
- `在 Metask 中管理` 只有在 Host 发布固定安全入口后才显示；当前没有该 capability 时不放置链接或假入口；
- 重新登录或退出登录不得因 Task、Session、Run、job、worker 或 Task-owned credential 的运行时引用而被阻止，也不得静默终止或改写这些引用；既有 Task 按创建时取得的 ExecutionConfig 继续收口。退出登录必须说明 Account 设备凭据清理和历史保留语义，但不能把它描述成对 live Task 的热撤权。

设置页保留左侧分区导航与右侧内容的双栏布局。桌面双栏直接消费应用左侧导航轨的已保存宽度，使设置内容起点与 Workbench 分界线保持一致；设置页不建立第二份宽度状态或第二个拖动器。它是桌面控制面，不使用营销页式 Hero，也不为视觉饱满度增加无产品语义的卡片、渐变、玻璃材质或装饰性图表。顶部只保留与双栏网格对齐的紧凑上下文栏：返回入口、单一页面标题和一句短说明；不重复产品眉题，不让标题区形成独立大块留白。标准窗口下当前分区和第一组设置必须在首屏形成紧凑、稳定的阅读起点；窄窗口可把分区导航收成横向行，但不得改变设置 owner 或复制页面状态。

设置视觉与控件遵循以下规则：

- 页面背景、工作面、交互组和浮层使用视觉系统中的 `surface-app` / `surface-work`、分隔线与真实抬升关系建立层级；普通设置行不逐项卡片化，只有 API、模型连接和模型这种依赖型配置形成连续交互组；
- 紧凑上下文栏的页面标题约 22–26 px，设置分区标题约 20–24 px，设置主文案 13–15 px，辅助文案不小于 12 px；disabled 状态只改变语义色和对比度，不缩小字号；
- 语言、API、模型连接和模型统一使用经过键盘、焦点、碰撞和长列表验证的同一 headless Select primitive；正式设置页禁止依赖 WebView 平台主题的原生 `<select>`，也不建立另一套自绘菜单；
- compact 选择器只显示一个短值；API 使用 detailed 选择器，以 API 名称为主信息，以 Provider 为次级说明，以脱敏尾号为尾部数据。Provider 和尾号不得表现成可编辑字段；
- API 与模型控件在同一个“执行默认配置”工作面中以带步骤标记和连接线的连续配置链呈现，明确表达 `API → 该 API 的模型目录 → 默认模型`，不能退化为两个互不相关的普通表单行；
- API 切换开始后只冻结相关配置组；模型目录加载、选择和持久化不得冻结语言、导航、历史阅读或取消仍被 Host 接受的操作；
- 设置页把每次默认配置 mutation 表现为一笔 Host-owned 事务：API/credential 变化使用候选 API/模型并在完整验证后原子替换 execution；同一已提交 API 下的默认模型变化只持久化模型 preference。已提交 API/模型始终是当前真值，进行中的值只显示为“待应用更改”或“正在保存”。Renderer 可在 command acknowledgement 前短暂回显用户刚发出的请求，但收到 snapshot 后必须以 Host projection 为准；页面重建、取消、失败和成功都不得依赖 Renderer 临时状态恢复事务；
- 常规桌面宽度下只让右侧设置内容列滚动，页面标题和左侧分区导航保持稳定；分区高亮跟随右侧内容的阅读位置。窄窗口改为顶部横向分区导航，但仍不让导航与内容共享滚动层；
- 浮层只在打开时使用克制的透明度与位置过渡；loading 指示只出现在真实运行的配置项，`prefers-reduced-motion` 下移除非必要动画；
- 当前分区导航必须有持续可见的选中态和 `aria-current`，不能只在 hover 时出现；focus ring、菜单选中勾选、状态色和文字共同表达状态。
- 桌面壳注册标准 `primary + ,` 设置快捷键，直接打开正式设置 route；快捷键只负责页面导航，不建立绕过 Account/Bridge gate 的第二命令面。

Account 状态在设置中的投影只遵循公开合同：

- `signed_out` 显示统一登录动作并禁用 Metask API mutation；Model Connection 仍可独立查看和管理；
- `authenticated + loading` 保留已提交默认值，相关控件显示 busy，`canCancel=true` 时显示取消；
- `authenticated + choosing` 只显示 Host 已发布的真实 API 或模型歧义；
- `authenticated + ready` 显示当前默认值且不常驻成功提示；
- `authenticated + failed` 保留 identity 和旧默认显示事实，提供重试并显示稳定错误；
- Renderer 不从这些状态恢复内部 operation，也不区分或展示 credential persistence 子步骤。

`Model connections` 规则：

> 当前入口关闭。以下规则保留为重新开放时必须同时满足的产品合同，不代表 Renderer 现在可以导航到该页面。

- Renderer 分别消费 `modelConnectionManagement`、`modelConnectionSecretCapture` 与 `modelConnectionTest` 三个 Host capability；management 不代表可以采集 secret。当前 Native SDK 缺少 trusted secure text-input 时，连接列表、测试和默认选择可以继续工作，但 Add/替换 credential 动作必须隐藏并显示能力不可用说明，不得回退到 DOM 密码框；
- 页面显示连接名称、Provider、脱敏服务地址、credential 状态、模型目录状态和可用动作；不显示完整 API Key，不回填秘密字段；
- `Add connection` 先选择协议，再填写连接名称、API Base URL 和模型 ID；API Key 通过 Host-owned secure capture 单独采集，不作为普通 Bridge 字段回传。当前只显示已通过 staged AgentCore provider contract 的 OpenAI Chat Completions 与 Gemini Native；不暗示支持 `/v1/responses`，Anthropic Messages 在原生 `x-api-key` 合同通过前不显示且 Host 拒绝 admission；
- Host 在提交时规范化 endpoint、校验 scheme/host/path/长度和控制字符，并根据 provider 生成 AgentCore 所需的 normalized base URL；Renderer 不能把 arbitrary URL 或 query credential 直接交给 Run；
- `Test connection` 只通过 Host/AgentCore 发起有界流式请求，不创建 Task、历史 Run 或持久 Conversation；页面分别显示 generation readiness 和最新测试状态。已成为默认连接后仍可重测，失败只显示“最近测试失败”，不能把正在使用的 ready generation、默认选择或新 Task admission 静默撤销；
- 第一版由用户明确填写 bounded model ID，不提供自动模型发现；连接没有可用模型时不能成为默认连接；
- 默认连接与默认模型作为同一笔 Host-owned execution transaction 提交；切换连接后只允许选择该连接的模型目录，不把不同连接的 model id 混在一个列表里；
- Metask identity/catalog 与当前 custom default 同时投影；custom default 生效时账号设置仍可查看 Metask API/模型，并通过显式 `新任务改用 Metask` 触发重建。Host 只有在 Metask execution 与 custom-default 清除都提交成功后才切换来源，失败时继续使用原连接；
- 编辑连接使用同一 typed 表单，秘密永不回填；当前无 secure capture 时只允许编辑名称、协议和 endpoint，不显示伪造的“替换 API Key”动作。endpoint 或 provider 变化生成新的 connection generation，并回到待测试状态；
- 删除或禁用连接前，Host 检查 live Session、Run、job 和 worker 引用。当前默认连接必须先切换到其他 ready 连接，Renderer 禁用其编辑/删除并解释操作顺序，Host 仍以 exact connection identity、generation 和 `execution_in_use` 做最终校验。既有 Task 不静默改绑；不可继续的 Task 显示 `需要重新选择模型连接`，历史仍保留；
- 连接页只管理连接本身和默认连接/模型，不提供 Workspace、权限策略、Task 历史或 AgentCore 内部状态。

Skill 中心、MCP 与定时任务按 §5.2–§5.5 进入 Workbench 一级能力导航；MCP 使用稳定入口，并分别消费 Host-owned management health、Runtime/catalog availability 与 new Task access。空 registry 是可管理空状态，management capability 未接通或 outcome unknown 才进入对应不可用/恢复面；Renderer 不从 Runtime ready 推导管理动作。其他连接器和 IM 频道仍只有在真实接通并形成清晰产品 owner 后才进入导航，不照搬其他 Agent 产品的信息架构。

## 15. 国际化

> Capability：**当前**。Locale ownership、structured code 与 catalog parity 约束立即生效；新增登录、设置、Inspector 和 rebind 文案必须随对应功能同步补齐，不得先落单语言字符串。

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

## 16. 视觉系统

> Capability：**当前**。登录、Workbench、设置和全部 capability gate 已存在；本章定义的明亮紫色视觉系统已经进入正式 Renderer，并由持续回归约束。它不授权显示尚未通过 capability gate 的数据或控件。

### 16.1 视觉方向

MetaWork 采用“明亮工作台 + 紫色任务流”的桌面工具方向。视觉个性来自克制的紫色交互信号、信息密度转换和本地执行语义，而不是暗色全局背景、暖米色加通用衬线、巨大品牌空态、吉祥物、渐变或每块内容一张圆角卡片。外部参考只用于判断主次关系，不能复制品牌字形、导航结构、输入框比例、图标或配色。

核心色板如下；公司发布正式品牌色时，`brand-*` 必须整体校准并重新验证，而不是只替换单个按钮：

| Token                 | Value     | Role                     |
| --------------------- | --------- | ------------------------ |
| `brand-700`           | `#4E38C2` | Pressed、高对比紫色文字  |
| `brand-600`           | `#5B46D8` | 主按钮、Focus ring       |
| `brand-500`           | `#6C5CFF` | Logo、当前轨迹、品牌识别 |
| `brand-100`           | `#EAE7FF` | 当前导航项、弱标签       |
| `brand-50`            | `#F6F4FF` | 紫色弱背景               |
| `ink-primary`         | `#25222D` | 主文字与标题             |
| `ink-secondary`       | `#6E6879` | 次级文字                 |
| `surface-app`         | `#F6F5FA` | 应用外层背景             |
| `surface-work`        | `#FFFFFF` | 中央工作面与浮层         |
| `surface-rail`        | `#F1EFF7` | Workspace / Task 左栏    |
| `surface-inspector`   | `#F7F6FA` | Inspector                |
| `rule`                | `#E3E0E9` | 分隔线                   |
| `status-success`      | `#287A54` | 明确成功                 |
| `status-success-bg`   | `#EAF6EF` | 成功弱背景               |
| `status-attention`    | `#9C5B10` | 等待用户或警告           |
| `status-attention-bg` | `#FFF5E7` | 等待弱背景               |
| `status-danger`       | `#B6424C` | 失败、危险和删除         |
| `status-danger-bg`    | `#FFF0F1` | 失败弱背景               |

组件级规则：

- Primary button 使用 `brand-600` 和白色文字；Pressed 使用 `brand-700`；
- Selected navigation 使用 `brand-100` 背景和 `brand-700` 标识；
- Focus visible 使用 2 px `brand-600` 并保留 2 px offset；
- 普通正文、图标、边框和卡片默认使用中性色，不默认变紫；
- 普通内容不使用紫色描边，App 背景不使用大面积紫色、发光或装饰渐变；
- 主操作色不能同时代表成功、等待或危险；语义状态始终配合文字或图标；
- 正常完成不使用大面积绿色或庆祝动画；
- 状态图标、焦点、文字和控件组合必须通过 WCAG 对比度校验。当前候选的白字/`brand-600` 为 6.34:1，`brand-700`/`brand-100` 为 6.51:1，`status-attention`/浅琥珀背景为 4.97:1。

组件层级依靠排版、间距、背景层次和分隔线建立。圆角只服务输入区、弹层和需要形成边界的交互组；普通消息、活动和设置项不默认卡片化。阴影只用于真实抬升层。

### 16.2 字体

- 标题：macOS 使用 SF Pro Display，Windows 使用 Segoe UI Variable Display，并在不可用时回退系统 UI；不使用通用 serif 制造空态“高级感”；
- 正文：macOS 使用 SF Pro Text，Windows 使用 Segoe UI；中文分别使用 PingFang SC 和 Microsoft YaHei fallback；默认正文不小于 13 px，主要阅读正文目标为 14–15 px；
- Data：SF Mono、Menlo、Consolas 或系统等宽字体；
- Task、按钮、设置、状态和正文统一使用系统无衬线字体；等宽字体只用于命令、路径、稳定标识和数据；
- 不依赖运行时网络字体。

### 16.3 形态与动效

- 间距使用 4 / 8 / 12 / 16 / 24 / 32 px；小控件圆角约 7 px，导航与普通交互组约 9 px，Composer 16 px，Popover / Modal 约 14 px；
- Task 输入、回复与行动状态通过排版和间距形成清晰关系，不用装饰线、节点或卡片伪造底层时序；
- 圆角服务于交互分组，不让每条信息都变成浮动卡片；
- 阴影只用于 Composer、浮层和真正需要抬升的元素；
- 只让当前运行节点旋转，避免全屏多个 spinner；
- Hover / Press 只在约 100–120 ms 内改变颜色或背景，不做位移；Popover / Slash menu 使用约 120–150 ms 淡入和最多 4 px 位移；
- 左栏与 Inspector 的平移或列宽变化约 160–180 ms；不能使用内容状态驱动高频开合；
- capability 到位后的新 Output 只使用约 160 ms 轻微淡入；
- 从 New task 到运行 Task 的布局变化使用一次约 220 ms 的克制过渡：Composer 从中央主视觉落到底部，Task 内容获得空间；不散布无意义入场动画；
- Inspector 不随普通 Run 开始或 terminal 自动改变列宽；显隐只在用户动作、切换 Task 或新的待处理请求边界改变，避免正文高频重排；
- 完成状态不使用庆祝动画；
- 尊重 `prefers-reduced-motion`。

首个正式视觉版本只交付浅色主题。颜色结构必须 token 化，但在深色主题完成完整设计和测试前不暴露半成品主题开关。

## 17. 空状态与异常状态

> Capability：**混合**。错误表达、Host/Core 中断、登录优先、独立 Workspace 和无伪 Resume 属于当前约束；execution rebind 与完整历史恢复按各自目标 capability 显示。

### 17.1 未登录

未登录不是 Workbench 空状态，而是独立登录界面。显示 MetaWork identity、一句直接说明和 `使用 Metask 登录`；不得渲染空 Workspace、空 Task、disabled New task 或空 Inspector。等待浏览器授权、取消、重新打开、目录准备和真实歧义都在同一稳定位置演进。

### 17.2 New task

显示：

- 清晰的行动标题，不使用空泛欢迎语或人格化 Assistant 宣传；
- 一句话说明 MetaWork 将在当前本地 Workspace 中完成工作；
- 作为首屏主视觉的 Composer；
- 当前模型与 Workspace；
- 必要的 trusted Workspace 限制提示。

没有 Workspace 时可以先输入临时草稿，但发送动作明确引导选择并确认 Workspace；Account 此时已经 ready，不再出现登录 prerequisite。

### 17.3 错误原则

错误说明必须包含：

1. 发生了什么；
2. 哪些结果可能不完整；
3. 用户可以采取什么动作；
4. 技术详情入口。

Account 错误必须保留本地 Workspace、Task 和草稿。OAuth 尚未完成时提供取消；已认证后的目录失败保持 `authenticated` 并提供重试；凭据失效直接进入 `signed_out`，由普通登录建立新 identity。错误动作必须与当前四态合同一致，普通异常不能留下无动作 spinner。

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
- 1100 × 720（Inspector 不占固定列宽的边界）；
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
- 首次 signed out 且没有本地历史：Workbench shell 直接提供唯一登录动作；不得制造 saved account、上一次登录或 mismatch 分支；
- OAuth 正常完成、浏览器未回调、重新打开、取消和 hard deadline；
- 历史选择命中、唯一 Key/模型自动推进；
- 多 API、多模型真实选择以及选择期间 reload；OAuth identity 成功后不退回未登录；
- catalog timeout/有限重试、OAuth exchange 失败、持久化确定失败与结果不确定；
- 无 API Key、无模型以及 Host 未提供管理入口时的可理解恢复文案；
- Bridge invoke timeout 后释放 busy、snapshot resync 后恢复 Host 动作；
- ready 后进入 Workbench，左下角显示 identity；重认证、设置、退出与 execution replacement gate 行为正确。

### 19.5 Workspace、模型与设置

- Workspace 是独立 projection：空 Workspace、最近使用、重新授权、移除和跨 Workspace Task signal；
- New task Composer 始终显示当前模型和 Workspace，上下文缺失时提供明确下一步而非静默 disabled；
- New task 首次发送覆盖本地 admission 不满足、`create_rejected`、`create_failed`、Task 已创建后的 `run_rejected` / `run_failed`、Run accepted 与 command timeout；每种结果都保持正确页面和草稿 scope，不伪造指令、Running 或失败定论；
- 当前 API 模型列表、模型切换 pending/error、设置与 Composer 默认值一致；
- 设置页切换默认 API 后加载对应模型，默认只影响新 Task admission，不自动改绑已有 Task；
- 已有 live Task 保留当前 execution binding epoch，默认变化不改写历史或 live Session；detached Task 的 Conversation restore 可按 §6.4 为兼容 credential target 建立 adoption epoch，任意 provider/model 变化仍只有未来的显式 rebind 可以建立新 epoch；
- Host 重启后点击左栏 Task 只浏览已保存时间线，未完成 operation 显示 `Interrupted`；满足 Host 恢复资格时 Composer 显示显式恢复动作，覆盖 required、restoring、failed/retry 和成功后重新发送。不得自动 restore、伪造 Run/Stop、显示假的 rebind，或仅因当前默认配置看似匹配而开放发送；
- API 只在设置中显示脱敏名称、Provider 和尾号；完整 secret 不进入 DOM、snapshot、日志或错误；
- 左下账号入口在窄窗口、长姓名、重认证和 200% text 下仍可用。

### 19.6 内容状态

- 短文本和长文本流；
- 多个连续 Tool Call 保持一个 typed Tool 一张卡，不自动归并；
- Bash 失败和长 stdout/stderr 使用有界预览；没有真实 Inspector projection 时不显示假详情入口；
- Read 大量文件；
- Edit diff；
- one-time permission；
- capability 未验收时 Plan、plan approval、Always allow、Output 与 FileChange 完全不出现；
- 对应 capability 未来验收后，Plan 创建/更新、计划确认、持久规则与 Output 的目标状态按各章节启用；
- 后台 Task 通知；
- Renderer reload 和视图重新同步。

### 19.7 权限规则与失效

- Host 未声明可持久化 capability 时不显示 `Always allow`；
- Workspace identity 改变、移除后重新授权和目录被替换；
- symlink 解析越过授权边界，以及检查/执行间发生目标变化；
- executable resolution、argv、cwd 或 environment policy 变化；
- 项目脚本内容摘要变化；
- tool/MCP identity、version 或 operation 变化；
- 等待期间撤销规则、`Revoke and stop task` 和普通撤销；
- stale、duplicate、expired 和错误 Task/Run/request 响应；
- Renderer reload 后规则命中记录与请求状态从 Host 恢复。

### 19.8 交互与可访问性

- 键盘完整操作；
- focus 不丢失；
- 用户上滚时不强制自动滚动；
- 选择另一个 Task 时定位最新内容，不泄漏或恢复上一 Task 的像素滚动位置；
- reduced motion；
- 状态在无颜色条件下仍可识别；
- 长英文、中文和 pseudo-locale 不溢出；
- `queued / running / waiting_user` 的可见 Stop 只出现在 Composer 发送位置；顶部命令栏不重复出现，`stopping` 阻止重复请求并等待真实 terminal；
- 顶部命令栏 Task overview 按钮可由键盘操作，`打开任务概览 / 关闭任务概览` 与 `aria-expanded` 始终匹配真实面板状态；
- 普通 Run start/terminal 不改变 Inspector 列宽；新的待处理请求只自动打开一次，terminal 后保留 Last run summary，切换 Task 不泄漏旧详情；
- 左栏折叠后完全隐藏且命令栏入口仍可达；Inspector 关闭或覆盖显示后功能不丢失。
- Windows Renderer 窗口按钮在登录页与 Workbench 均可见、键盘可达；最小化、最大化/还原和遵循 `close_policy = hide` 的关闭命中真实窗口，按钮区域不进入 drag candidate；

## 20. 工程目录结构

Workbench 的仓库外层、Renderer、Zig `src/`、依赖方向和测试布局单独维护在 [工程结构与所有权](project-structure.md)。

本文档只定义 UI feature 和产品交互；目录方案不得反向改变 Renderer/Host/AgentCore 的产品边界。

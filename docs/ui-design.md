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

Workbench shell 是应用启动后的稳定根界面；可信根 Snapshot 建立前不得开放 mutation。Account 登录只决定内置 Metask provider 能否取得授权，不得替换或遮住 Workbench；New task 是否可以发送仍只服从 Product Control 的 execution admission。

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

因此当前产品在 Task 内容区显示用户输入、Agent 可见输出、权限决策面、唯一当前状态、紧凑 Tool 摘要和必要的终止结果；Tool input/progress/result 按需在所属 Tool 行下方展开，不展示 Run 用量，context pressure 提醒按需出现在 Composer 附近，历史自动压缩记录不单独占据入口。普通信息不足时，Agent 通过可见回复说明问题并结束当前 Run，用户从 Composer 继续，不进入结构化 Question wait。工具记录只作为所属 Run 的可检查过程证据，不成为 raw event 时间线。当前 PermissionProfile 只定义并开放 `请求批准 | 完全访问`；Plan、plan approval、Outputs、空的 Files changed 概览模块、持久权限管理和 custom UI 均保持隐藏。Renderer 不解析工具参数、stdout 或普通文本来猜测这些状态；Current activity 只来自 Host 对受序列保护的 `run_state` 以及 typed text、Tool、retry、context 和 output control event 的产品投影。当前 Renderer 合同已提供独立 Workspace projection、Task-bound ExecutionConfig facts、正式设置 route、设置与 New task 共享的默认 API/模型选择，以及 New task 的 PermissionProfile 选择；跨重启 rebind 等仍须等对应 capability 落地后才能宣称可用，差距由 [验证规范](validation.md)明确记录。

上述边界同时约束 Agent 对话渲染：工作过程必须在 terminal 前随真实 Snapshot revision 可见，存在 Tool 时在 terminal 后继续提供折叠的历史检查入口；过程与正式回复保持主次层级，用户可以检查 Tool 证据而无需离开阅读上下文。仍不得泄漏 private reasoning、从文本猜测结构化事实或提前开放 gated capability。该信息架构只呈现实际到达的 commentary 与 typed activity，不承诺 Provider 在每个 Tool turn 输出自然语言，也不允许 Renderer 为提高信息密度而生成中间对话、推断模型意图或补造进度。

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
| Task information     | 任务信息        | 执行模型与任务 authority 的只读说明   |
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

> Capability：**当前**。持续可达的 Workbench、独立 Workspace projection、左栏、New task、Settings overlay、Task 内容与统一 Task Panel 已进入当前 shell；未通过 capability gate 的模块与标签仍必须隐藏。

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
- 左栏：默认 320 px；常规桌面可通过分界线在 240–480 px 内调整并保存偏好，键盘聚焦分界线后可用方向键调整；窄窗 overlay 保持固定宽度；
- 左栏品牌区使用紧凑单行，只显示 `MetaWork` 字样，不把品牌区表现成第二层标题栏，也不重复使用首字母图标、产品说明或宣传副标题；
- 横向工作区：`app-window` 继续用 Grid 管理命令栏与工作区两行，并作为可用宽度的唯一 owner；工作区内部使用受父级约束的 Flex，子栏及其内容不得反向撑宽父级或成为自身宽度计算的测量源。左栏占固定的偏好宽度；扣除左栏后的空间默认按中央 Task stage 2 份、Task Panel 1 份分配。中央 Task stage 与 Task Panel 都只设置 360 px 硬下限，不设置固定最大宽度或固定比例范围；最小宽度约束优先于保存比例，保存比例优先于默认 2:1；
- Task Panel：停靠态保存其在剩余工作区中的比例，默认 `1/3`；分界线仅在停靠态出现，拖拽和键盘调整以 16 px 为步进显示实际宽度，再换算为比例保存。其动态可调范围为 360 px 至“剩余工作区减去中央 360 px”，不另设上限。停靠栏开合使用约 160–180 ms 的 `flex-basis` 过渡，拖拽调整直接跟手且不使用过渡；扣除左栏后的空间少于 720 px 时改用右侧非模态 overlay，默认 400 px 且不允许拉伸，overlay 使用不参与工作区布局的 `transform` 过渡。空间恢复后沿用保存比例。入口、显隐和比例属于应用布局，用户可独立开合或通过具体对象入口展开；无 Task、无内容时也允许打开空栏，不触发普通 Run 或审批状态驱动的自动开合；
- 已有 Task 不额外占用独立内容标题区；Task 名称只在顶部命令栏显示；
- 中间正文推荐最大宽度：760 px；
- 表格、diff、日志和文件预览可以使用中间区域的可用宽度；
- Native 主窗口声明 320 × 520 logical px 的系统最小尺寸，保证窗口不能被缩到 Renderer 已定义布局下限之外；960 × 680 仍只是窄窗口回归样本，不是固定设计画布；
- Task Panel 的停靠由扣除桌面左栏后的 720 px 最小工作区决定，而不是单独的 viewport 断点；低于 820 px 时左栏和 Task Panel 互斥，低于 620 px 时 Task Panel 使用全宽 overlay；低于约 560 px 时命令栏隐藏次级文字。

左栏折叠后完全隐藏并把宽度归还横向工作区，不保留 56 px 图标栏，也不用匿名图标映射任意 Task。命令栏左侧始终保留打开/关闭入口，折叠状态与桌面宽度按用户偏好保存；左栏宽度变化时，中央与右栏按同一保存比例同步重分配。右侧栏显隐与对象选择分别管理：常驻开关、关闭、Escape 与窄窗互斥操作控制显隐，打开具体对象可显式展开右栏。切换或删除 Task、切换主页面及目标失效只清空不再适用的内容，保持右栏显隐与比例。显隐默认关闭，在本窗口会话中保持，不建立每 Task 记忆。折叠只改变视图，不改变 Task、审批或运行状态。

### 4.2 窗口模型

首个正式版本采用单主窗口模型：

- 多个 Task 在同一窗口内切换；
- 后台 Task 不因切换而停止；
- 系统通知用于提醒后台 Task 等待用户、完成、失败或中断；
- 多窗口属于后续能力，不进入当前设计范围。

### 4.3 一体化窗口栏

主窗口使用 `hidden_inset_tall`：Renderer 命令栏承担自定义标题栏的产品视觉，不叠加独立的标准系统标题行。React 绘制产品 header，以 SDK 正式标记声明拖拽区域及交互排除，并绘制带固定 `data-metawork-window-control` 语义的窗口按钮；browser-side Bridge 只把窗口按钮转换为受限 Host command。Native SDK/OS 承担 native hit test、拖动循环、系统菜单、resize、close policy 与真实窗口状态；SDK 缺失的原生输入路径只按[已登记兼容能力](architecture.md#35-native-sdk)补齐。React component 不推断平台、不直接调用 transport，也不持有原生窗口 identity、handle 或执行权。

- 命令栏是窗口交互层，不表现为独立横向标题栏：不使用贯穿全窗的底边或异色横带；左侧 Task rail 的背景与竖分隔线必须延伸到窗口顶部，中央命令区与 Task 工作面使用同一 surface；
- macOS 保留系统交通灯；Windows 由 Renderer 绘制最小化、最大化/还原与关闭按钮。Host 只发布 `rendererControls` capability、`maximized` 真值和安全 inset，browser-side Bridge 将它们转换为 document dataset/CSS variables；React 不读取平台名或调用 transport，最大化与还原使用互斥的可访问按钮，由 Host 真值控制显隐；
- 产品 header 默认视觉基线为 52 px；Windows Renderer header 沿用历史实现的 40 px 高度，每个 window control 使用 46 px 命中宽度并贴齐窗口右缘。关闭 hover/focus 使用系统危险红色，其余按钮保持中性色。macOS 交通灯与可拖动 top band 的真实安全区以 Host geometry 为准；
- 命令栏只包含左栏开关、当前 Task 名称、全局搜索、只读任务信息、Task Panel 常驻开关和按需异常/审批定位入口；不在 Task 名称前重复 Workspace，`左栏开关` 只控制能力与 Task 导航，不兼任 Task Panel 开关；
- 主窗口启用 SDK `window_drag_regions`，`WindowTitlebar` 仅在真实 header 声明 `data-native-window-drag`。标题栏内按钮（含 disabled 与 SVG 子节点）、输入、选择框、标签、链接、disclosure、可编辑/可聚焦内容及其他交互子树必须自身或由可命中的外层显式声明 `data-native-window-drag-exclude`；SDK 不自动推断产品控件语义。动态动作、改名表单与菜单沿同一规则。inert 子树的可命中外层仍保留排除标记，避免浏览器跳过 inert 内容后命中可拖动 header。菜单、popover、tooltip、select/combobox、dialog/drawer 及其 backdrop 的实际 portal 根统一显式排除：Windows 原生区域不会因任意 DOM 遮挡自动消失，浮层即使挂在 header 之外也必须声明 no-drag。不维护几何镜像。普通标题文字保持可拖动；业务控件保留点击、编辑和键盘行为，不因原生拖拽取消或移动窗口；
- 窗口 resize/maximize/restore 由 Native SDK/OS 执行，browser-side Bridge 由 SDK 正式 resize event、动作受理后和重新获得焦点时触发同 generation 的 `refresh`。窗口状态只从 `connect/refresh` 响应投影；动作确认不代表原生交互完成。刷新最多一个在途请求并合并后续需求，新动作和原生变化使旧读取失效；卸载后迟到响应不得恢复 UI 或覆盖新文档。不得因 resize、layout 或 command failure 重新 `connect`。React 只由 Host 的 `maximized` 真值选择互斥按钮；
- SDK/OS 独占原生按下、命中、拖动循环、双击时间/距离与系统偏好；Windows 使用 SDK 正式 WebView2 非客户区支持，macOS 使用 SDK/AppKit 原生事件。应用不监听拖拽 pointerdown/mousedown、不选择浏览器点击计数动作、不实现双击计时，不通过 Bridge 发起手势或模拟窗口位移。声明区域按实际呈现位置与缩放参与 SDK 命中，不再由应用额外裁剪到固定 native top-band；React 不注册标题栏 double-click 或 context-menu handler；
- window-chrome bootstrap capability 不依赖 ProductDelivery connection，仅接受同文档的 connect/refresh/disconnect 与 `minimize | toggle_maximize | close` 固定按钮动作；不接受手势、window id 或任意 action。SDK 拖拽独立于这两种连接，登录/连接失败页仍保留系统窗口交互；
- 正常连接、恢复成功和普通操作成功不持续占据命令栏；只有同步失败、命令失败或其他确实需要用户行动的异常才显示状态入口；
- 异常状态按 connection、account、Workspace identity 或 Task identity 分域保存；并行 Task 的结果不得互相覆盖，命令栏只选择当前上下文中优先级最高的一项显示；
- 已有 Task 的标题附近提供键盘可达的“任务信息”纯图标只读入口，所有宽度均保留图标、完整 accessible name、tooltip 和可见焦点，不常驻文字标签；左栏折叠时仍可用，New task 与无 Task 时隐藏。右侧栏开关由应用外壳提供，在主工作界面的各内容页面常驻，使用匹配实际显隐的 accessible name 和 aria-expanded；无 Task 或无内容时仍可操作，不因任务暂无文件而隐藏或禁用。设置仍使用覆盖层，底层开关与工作面共同 inert，不丢失先前显隐选择。窄窗将命令栏审批定位收为有完整 accessible name 的图标按钮，保证两侧栏开关与搜索不会被长标签遮挡；
- 根启动或连接失败界面的应用工具栏只保留产品 identity、语言入口与真实窗口控件；语言不能藏进尚不可进入的设置；
- Renderer 关闭按钮必须进入平台的 user-close 语义并遵循 manifest `close_policy = hide`，后台 Application 与计划任务继续运行；重新打开由 Native SDK 托盘菜单进入 Application 的 `showWindow`/`focusWindow` capability，显式 Quit 才进入应用 shutdown；
- 不使用 `chromeless`；系统 resize frame、Snap Layout、拖动、双击、系统菜单、DPI 与高对比行为只按真实平台验收声明，不由 WebUI 模拟。Renderer 只绘制按钮并提交固定语义意图，不复制这些底层行为；
- 语言、API、模型和诊断进入设置或对应任务上下文，不常驻命令栏；
- 不在命令栏放 ABI、protocol、Host mode 等工程状态。

平台文案、路径、快捷键和文件管理器动作按 OS 切换。

## 5. 左栏：能力与 Task

> Capability：**部分当前、部分目标**。Renderer 合同已提供 MetaWork 顶层与 Workspace/Task 分离的 AgentCore Skill catalog projection；本地 package/inventory、详情与管理 mutation 是本次目标合同。shell 已提供稳定 New task、全局 Task 与项目导航和左下角账号入口；Skill 中心、消费 Host-owned management/Runtime/admission 事实的 MCP 页面与持久定时任务都作为同级全局能力进入该 shell。

### 5.1 Task 列表与路径上下文

登录后的左栏从上到下只承担五类稳定职责：品牌/窗口识别、New task、已接通的全局能力入口、Task 导航、左下角账号入口。搜索由标题栏或命令面板提供，不在窄侧栏重复占据首要位置。

- 左栏保留全局 Task 列表，并按 [Task 列表、项目与排序](#56-task-列表项目与排序) 额外展示用户选择目录的项目导航；不提供全局 Workspace 切换器或目录添加动作。只消费同一 canonical snapshot 中仍被投影的 Workspace 与所属 Task，Workspace 移除后保留的历史 Task 不生成可点击的死入口；
- Task 被选择后使用自身绑定的 Workspace 路径，不提交额外的全局 Workspace 导航动作；不同路径下的后台 Task 都必须持续可见；
- New task 默认选择 Automatic Workspace，工作目录控件直接显示“默认”；此时不提前创建 Workspace 或 Task，首次发送才请求 Host 分配 Automatic Workspace。用户可以在发送前切换到已有 Manual Workspace 或打开原生目录选择器；用户确认目录后即完成授权并只更新草稿上下文，不得追加 trust 确认、自动创建 Task 或发送已有内容。Manual Workspace 直接显示 canonical directory，Automatic Workspace 统一显示“默认”，不得暴露随机目录或内部 kind 术语；
- New task 草稿按 Workspace 隔离。未绑定 Workspace 的临时草稿只在目标 Workspace 没有草稿时迁移；目标已有草稿时保留两边内容并打开目标草稿，不能覆盖或丢弃任一份；
- Workspace projection 的 `kind` 是 Host 事实；一个 Manual Workspace 可以承载多个 Task，Automatic Workspace 精确归属一个 Task；
- Composer 的工作目录控件只选择、添加或重新授权 New task 路径；设置页不提供 Workspace 生命周期管理。设置作为覆盖整个 Workbench 内容区的长期 surface 打开，保留窗口壳层和底层 Workbench 挂载，拥有自己的分区导航与内容滚动，关闭后恢复原工作面；
- 历史 Manual 目录经 Host 恢复检查仍可用时可直接点选，不显示“需要访问权限”或要求重复目录选择器；真实失效目录才显示“目录不可用”并提供重新选择。再次打开历史 Task 只保证可浏览记录，能否继续执行还必须服从 §6.4 的 Conversation 与 execution binding 规则；
- MetaWork 重启后，左栏直接使用 Workbench 恢复的 Task 列表和顺序；点击 Task 打开其已保存时间线，不自动创建新 Task、不重放最后一次输入，也不把恢复的 `interrupted` 显示成仍在运行；
- `taskHistoryPersistenceHealth = degraded` 本身不显示常驻提示；`retainedTaskHistoryCount > 0` 时，左栏 Task 列表以一行静态说明告知有多少已保存 Task 无法在当前版本打开且已原样保留，不提供动作、不阻塞任何操作。`history_read_only` Task 正常出现在列表中，Composer 以 placeholder 说明只能查看，菜单中的重命名、归档与删除不可用。`read_failed / corrupt / write_failed / outcome_unknown` 显示非阻塞保存提示，但不得禁用 Composer、Task 操作、Workspace 选择、权限响应或取消。Host 发布 recovery available 时，提示内提供“使用新的存储继续”，并在就地确认中明确当前文件会保留为恢复副本；Renderer 只提交当前 snapshot revision，不选择路径或操作文件。取消不改变状态，失败保留提示，成功等待 Host snapshot 收口；
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

> Capability：**目标合同**。Renderer 通过 revision 1 strict snapshot 与 transport-discriminated typed command 管理 Workbench-owned Desired Registry；Runtime/catalog availability、credential submission、OAuth operation 和 Admission Authority 是彼此独立的 Host capability/state。任一能力不可用时页面保持可达并只呈现真实可用动作。

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
- Connection approval 后按 auth mode 收敛：None 进入 ready-to-enable；Static 的每个 secret slot 与 OAuth pre-registered client secret 使用普通 password input，显示名称、已设置/缺失状态与保存/取消动作，已保存值不回填。输入清理与提交遵守 [Renderer Bridge 合同](renderer-bridge-contract.md)；超过凭据存储 UTF-8 字节上限时，在本地阻止提交并明确提示上限与修改方式，不截断输入；提交期间禁用重复保存，失败显示既有 mutation 反馈。OAuth 先显示 discovery progress，再由 Host-owned consent 展示 canonical resource、exact issuer、requested scopes、redirect 与 registration plan，用户确认后才打开系统浏览器。缺少 DCR 与 pre-registered client 时回到可操作的 `Existing client required`，不泛化成 unreachable。OAuth operation 全局占用时，其他 OAuth action 显示 busy，目标 server 的替换/删除/授权动作禁用；其他 server 管理和普通 Task 不被冻结。
- 分组顺序固定为 `Needs attention / Available servers / Disabled`，空分组不渲染；状态同时使用细色轨、文字和语义图标。正常产品状态收敛为 `Connecting / Connected / Needs attention / Disabled`。`configurationApply = applying` 显示 Connecting 并冻结冲突动作；`failed` 或 desired 与 Runtime 尚未对齐时显示“配置已保存，重试连接”，调用 `metawork.mcp.applyConfiguration`，不得出现重启要求。desired-disabled 服务始终归入 Disabled。
- 详情依次为连接轨迹、至多一个主要处理动作、Tool permissions、Connection and authentication、默认折叠的 Advanced settings 和危险操作。Tools 显示 discovered、desired allowed 与 available to new tasks 三个事实并提供真实 Checkbox；新发现工具默认关闭。Connection 显示完整 executable/endpoint 与授权状态；秘密值只显示 `Set / Replace / Missing`。`Test connection` 始终是连接详情内的可选诊断，不是正式 apply gate；其 testing/connected/failed 结果只显示在 Connection 区域。正式 Runtime 不可用时，顶部恢复动作只能调用正式 apply 或 refresh，不能用候选测试冒充恢复。`Refresh tools` 只刷新当前正式 Runtime catalog。
- Add/Edit/Enable/Disable/Delete 成功保存后自动 apply；Rename 与 tool-only mutation直接更新对应产品事实。apply 成功才原子安装新 Manifest/Activation/Admission，失败保留已保存 desired 并允许重试。已打开 Task 保持创建时 authority；UI 不暗示即时撤权。Delete、批量放行和恢复非空 tool allowlist 的 Enable 使用 modal confirmation；Disable 与不恢复工具权限的 Enable 直接提交。`runtimeAlignment = unknown` 或 management outcome unknown 时禁用普通编辑并隐藏未经确认的 desired 列表，但恢复文案也不得要求重启。
- Refresh 只刷新当前 Runtime catalog，不应用 pending connection configuration，也不隐式发起 OAuth。refreshing 时禁用会与 catalog/authority 冲突的动作；失败保持 fail-closed new Task access，不恢复旧 catalog selection。OAuth success/refresh 只有同一 consent epoch 的 token revision 可以原子替换 Runtime HTTP auth snapshot；已开始的请求完成后才释放旧 snapshot，既有 Session 的 tool selection 不变。`reauth_required` 禁止新 Task 获得该 server，但不宣称已撤销既有 Session authority。401/403 scope challenge 进入 `Sign in again`，consent 显示原 scopes 与新 challenge scopes 的 union，不自动循环重试失败 tool call。
- Host projection 发布完整非敏感 typed connection：STDIO 的 command/ordered argv/cwd/environment name，Streamable HTTP 的完整 endpoint/header name，以及用户选择的 OAuth registration plan、公开 client id 和 token endpoint auth method。environment/header value、credential locator、client secret、token、code、PKCE、动态注册所得内部材料、raw OAuth document、schema、fingerprint 和 AgentCore handle 仍不从 Host 返回 Renderer；手动填写的值仅按上述表单合同短暂存在。`redacted = true` 时明确说明 Host 移除了敏感文本，对应 `connection = null`；该状态优先于 approval/auth/desired presentation，进入只读恢复面，禁用 Connect、Enable、Edit、Test、Rename 与 tool mutation，只保留 Delete 后重新添加，不以摘要或空表单冒充旧配置。
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
- 页面不再显示“仅在 MetaWork 运行时触发”限制条。窗口关闭时 MetaWork 留在系统后台并继续计划；托盘显式退出直接进入应用 shutdown，不弹出确认，重启后定义与触发游标从 Host store 恢复；
- 已有定义时的搜索使用 `type="search"`；分区是带可访问名称的 region/list；模板行、任务行和 overflow 动作都有明确 button 语义。drawer 打开后焦点进入标题/说明，`Escape` 或关闭动作回到原触发行；运行历史更新不抢焦点。

### 5.6 Task 列表、项目与排序

全局 Task 列表以“最近 / Recent”为标题，保留所有可见任务，每个 Task 在该列表中只出现一次；其上方展示“项目”区域，canonical snapshot 中每个 Manual Workspace 使用自己的 identity、目录名称和所属 Task 形成一个项目。Automatic Workspace 不生成项目，包括用户调整了默认目录上级位置的情形。两处任务入口共享选择、状态、完成提醒和任务操作，不复制 Task 状态或因项目展示改变绑定。

全局列表与每个项目内部共用同一排序：依次按需要处理、正在运行、排队、其他未归档与已归档的优先级排列，同一优先级内按 Task `recentOrder` 倒序；状态优先级不生成标题、分隔或独立栏目。项目之间按 Workspace `recentOrder` 倒序：

```text
Projects
  [Directory name]
    [Task in this directory] [status icon]
Recent
  [Task name]  [status icon]
  [Task name]  [status icon]
  [Task name]
```

- 列表不按状态拆分栏目，不显示 `Needs your attention / Running / Queued / Archived` 等状态标题；
- 只有存在仍被投影的 Manual Workspace 时显示“项目”；目录标题使用文件夹图标与单行名称，完整安全路径放在 hover title 中，redacted 时不显示路径。任务缩进一级，不在每个任务行重复目录说明；同名目录保留 canonical identity，可通过标题的路径区分；
- 项目任务始终展开；空项目保留目录标题和无任务说明。全局归档显示开关同时作用于全局与项目列表；项目只有隐藏的归档任务时说明归档已隐藏，不误称项目没有任务；全局任务计数只计算唯一 Task，不因项目入口重复计数；
- 当前排序优先级只决定行的位置，不在视觉上形成分组；排序规则后续变化不得重新引入状态栏目；
- Task 列表项只显示任务名称与必要状态信号，不在名称下追加 Workspace、`Default / 默认`、模型或其他配置标签；同名 Task 仍保持原名称，由用户按需重命名，不用第二行元数据替代命名；
- 运行中、排队、等待用户、失败和中断使用图标和颜色共同表达；可访问名称通过 `aria-label` 和 tooltip 提供，不在行内保留文字状态标签；
- 后台 Task 产生待处理请求时必须取得最高排序优先级，并继续由行内图标表达；
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

Workbench 左栏底部固定显示紧凑的 Metask identity：已登录时只显示头像或首字母与显示名，不重复展示“Metask 已连接”或成功状态点，也不为已删除的第二行保留空白高度；入口仍保持至少 44 px 命中高度。未登录、检查中或授权中仍使用第二行简短状态说明当前需要。它同时是账户与应用轻量菜单的触发器，不显示完整 API Key，也不承担模型快速选择。

点击后打开最宽 224 px 的轻量菜单，窄窗口下继续受视口宽度约束：

```text
张三

设置
关于
─────────────────────────
退出登录
```

- “关于”是本地产品级动作，位于设置之后、退出登录之前；菜单项不重复展示产品名或版本，也不新增常驻侧栏行、Workbench 一级导航或设置分区。点击后打开紧凑模态窗，只展示 canonical Logo、产品名、Metask 开发者归属和从 `app.zon` 构建注入的版本；只有已有真实、安全 consumer 的官网、隐私、许可或更新能力才显示对应入口，不渲染宣传文案、占位动作或死链接；
- About 不依赖 Account、Models 或登录状态，在 Workbench 的账户与应用菜单中始终可用；菜单与触发器的无障碍名称必须表达“账户与应用”，不能继续声称只包含账号动作；
- 账号菜单中的退出登录使用退出图标和与其他菜单项一致的中性颜色，不在尚未执行的导航层提前使用危险色；点击后在当前 Workbench 上直接打开危险操作确认框，不先导航到设置，最终确认按钮才使用危险样式。确认文案说明本机 Account 凭据会被清除、本地 Task 与历史记录会保留。Account logout 不等待 Product execution replacement 或 Schedule scrub；后续 Product cleanup 失败由 Execution/Schedule recovery surface 表达，不能补写 Account error。账号设置可以保留同一 Host 命令的独立退出入口，但不是账号菜单退出的必经路径；
- 账号菜单只负责身份和导航；Metask API/model目录与用户管理的服务都进入 Models设置，不成为 Account字段；
- 未登录时保留本地 Workbench 历史，并把左栏账号入口切换成登录动作。

## 6. Task 生命周期

> Capability：**混合**。四轴 Run/Task 状态、单 Task 单 in-flight Run 与只读跨重启产品历史属于当前合同；Agent Session/Conversation continuation 和显式 rebind 属于目标能力。

### 6.1 核心规则

- 每个 Task 同时最多一个 active operation；当前 operation 可以是 Run、manual compact 或 Conversation restore，三者不能并发；
- 每个 Task 创建时建立 execution binding epoch，并持有 owned ExecutionConfig。下一轮模型意图与实际 binding、历史 Run 分别呈现；保存意图和同连接 setModel 不推进 epoch。默认配置变化不改写既有 Task，也不禁用其模型选择；实际连接重绑定遵守 Task 执行事务和 epoch 合同；
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
| View sync            | `ready / syncing / failed`                            | 当前连接已确认、最近一次合格读取成功且无故障 |

`draft` 是进入 Workbench 后、尚未创建真实 Task 的 Renderer 临时页面，不进入 Host Task lifecycle。它默认持有 Automatic Workspace intent，也可以切换到 Manual Workspace identity，并可持有不修改 global default 的 runtime-only 同源模型选择；发送前必须同时满足相应 Workspace admission、默认执行配置与所选模型 authority。一次 Run 完成后 `Active operation` 与 `Active Run phase` 回到 `none`，`Last Run outcome` 保留结果。Manual compact 完成后 active operation 同样回到 `none`，其 outcome 进入独立、有界、append-only 的 maintenance history，不改写最近一次 Run outcome。Conversation restore 完成后 active operation 回到 `none`；成功只改变 runtime attachment/continuation，失败只改变派生的 unavailable reason，二者都不新增 Run、消息或 maintenance history。

正常通知滞后不构成 View sync 故障：一次合格快照被当前连接消费后，后续仍有更新需求不撤销 readiness；命令的最终接纳仍由 Host 校验。显式恢复在顶栏既有状态入口轻量显示“正在恢复同步”，普通读取失败自动升级一次重建时不闪中间故障；最终失败在同一入口提供“重试同步”和可折叠技术详情，不在对话正文叠加故障卡或重复横幅。恢复动作可直接使用键盘，窄窗保持可访问名称与安全换行；已收到内容和本地草稿保留。启动时尚无可信视图仍使用根连接失败页面。

Execution binding availability 是下一次 admission 的独立前置事实，不得塞入上述四个状态轴或改写最近一次 Run 结果。Host projection 只发布 `available / rebind_required / unavailable` 及脱敏原因；Renderer 不根据当前默认模型自行判断能否继续。

### 6.3 展示标签与优先级

| 条件                                         | English UI           | 中文 UI      | 主要动作                    |
| -------------------------------------------- | -------------------- | ------------ | --------------------------- |
| draft page                                   | New task             | 新建任务     | 输入并发送                  |
| view sync = failed                           | Workbench is not synced | 工作台尚未同步 | 重试同步，禁用依赖 Host 的操作 |
| waiting_user + permission review = reviewing | Automatic review     | 自动评审中   | 可直接批准、拒绝或停止      |
| waiting_user + no active permission review   | Needs your attention | 需要你处理   | 回答、批准、拒绝或停止      |
| run phase = stopping                         | Stopping             | 正在停止     | 等待真实结果                |
| run phase = running                          | Working              | 正在工作     | 草拟、发送文本插话或停止      |
| run phase = queued                           | Queued               | 排队中       | 草拟或停止            |
| no active Run + outcome = completed          | Completed            | 已完成       | 继续输入、打开结果          |
| no active Run + outcome = cancelled          | Stopped              | 已停止       | 继续输入或重试              |
| no active Run + outcome = failed             | Failed               | 失败         | 修复问题、重试或继续        |
| no active Run + outcome = interrupted        | Interrupted          | 意外中断     | 查看说明并明确继续          |

表格按优先级匹配。`Completed` 等 terminal 标签只描述最近一次执行；归档状态由独立标记表达，不得覆盖需要处理或正在停止的运行状态。

连接失败必须按可恢复边界呈现：只有 bootstrap `connect` 明确返回 Renderer Bridge identity 或 revision 不匹配时，才显示“组件不匹配”并要求关闭后重建或安装；snapshot、revision notification 或 Host signal 的 malformed/unknown payload 仍然 fail closed、禁止 mutation，但显示对应的视图读取失败、技术来源和显式重新连接入口，不能伪装成已经证实的组件版本问题。

启动时收到的数据格式不符合预期，主提示使用“无法加载 MetaWork”等用户能够理解的描述，不把“工作台视图”作为需要用户理解的技术对象。原因说明只陈述已观察到的数据异常；对象路径和有界字段差异收入可折叠技术详情，不在主提示罗列内部字段，也不推断版本错配。该文案不改变既有拒绝与显式恢复边界。

没有 active Run 且 execution binding 为 `rebind_required` 或 `unavailable` 时，左栏仍保留最近一次 Run 的 outcome；Composer 区域另外显示 `需要确认执行配置` 或 `当前无法继续`。不得用 binding 问题把历史结果改标成 Failed，也不得继续显示可发送输入造成错误暗示。

### 6.4 跨重启 Conversation 恢复与 execution rebind

> Capability：**已接通**。Workbench 可以从最新 finalized checkpoint 恢复原 Conversation attachment；这只覆盖正常 Application 重启，不代表独立 AgentCore Worker crash、in-flight Run 或 suspend/resume 已可恢复。显式 execution rebind 仍是未来能力。

当前恢复规则：

1. Host 从 bounded Workbench store 恢复 Workspace/Task、消息、Run/tool/UI 决策、compact 历史、无 secret execution binding 与 checkpoint record；不得把当前默认配置静默写入历史 Task；
2. 没有 live owner 的 non-terminal Run 或 compact 显示为 `Interrupted`，不显示 Running/Stopping，不自动重放输入、工具或 permission；
3. 点击左栏 Task 始终只是导航。满足资格的 detached Task 使用普通 Composer，不显示恢复卡片、恢复按钮、专用 placeholder 或其他 capability continuity 提示；用户发送第一条新消息时，Renderer 才在同一次发送意图内提交现有 restore，并等待 Host snapshot 确认 attachment 后继续提交该条 Run；选择、reload 或 timeout 不会自动触发 restore；
4. restore 只表现为该次普通发送的 preparing/busy 状态，期间禁用发送、compact 和重复提交，不显示 `Restoring conversation / 正在恢复对话`。左栏只更新该 Task 的运行状态图标与排序位置，不能创建恢复分组、伪造 Agent Run 或 Stop 按钮；
5. restore 失败时保留可阅读历史、用户草稿与稳定原因，并显示准确、可执行的失败说明；Host 仍发布 `continuationRecoveryAvailable = true` 时，下一次普通发送重试同一前置流程，不建立专用 `Try again / 重试` 按钮。timeout 只触发 canonical snapshot resync，绝不重放 restore 或 Run；
6. 成功后 Host 原子发布 attachment 与 `continuationAvailable = true`，Renderer 只在这一状态确认后提交一次 Run。`continuationAvailable`、`continuationUnavailableReason` 和 `continuationRecoveryAvailable` 是同一 continuation 模型；不得建立第二个 `recovery.state` 或由 Renderer 猜测资格；
7. checkpoint、Task/Workspace/Execution identity、Agent Runtime 或 checkpoint store 任一恢复事实不满足时显示对应 unavailable 说明，不开放该历史 Conversation 的恢复发送。Workspace 是否因导航语义 `visible=false`、Skill catalog 是否 ready、MCP selection 是否可重建、Permission 是否仍有效、projection capacity 以及 Task persistence health 都不是 Product Task 的全局运行资格；这些可选能力缺失时 Host 可以发布成功但 degraded 的 attachment，普通 Text 立即可用，相关能力按各自现有显式流程恢复。Task store read/corrupt/write/outcome-unknown health 由 Host 发布，Renderer 只提示，不自行清空、修复、迁移或阻塞 mutation；
8. `closed` 不是 Task 产品状态。非归档 Task 只要 Host gate 允许，就应恢复 attachment 并继续；归档只控制日常列表可见性，删除才永久移除记录。

恢复要求 checkpoint record 与 Task execution binding证明 source Task/binding、protocol、Task binding epoch和 terminal anchor精确，当前 execution authority则作为独立 target readiness：protocol相同、Task pinned model仍在当前 Models catalog，且 restore start→commit期间 target generation不变。历史 H与当前 G可以不同；H≠G时 Host必须先以 durable adoption同步推进 Task execution generation、binding epoch与 checkpoint anchor epoch，commit成功后才安装 attachment，旧 Run的 generation/model/usage不改写。checkpoint的 model只用于满足 AgentCore restore expectation，并与其 terminal Run历史 model自洽校验；candidate提交前由 Host以 Task当前 model binding调用 `session_set_model`，不能把 checkpoint旧 model或 Models当前默认 model静默写回 Task。durable Task不保存 account、API Key或 Custom Provider identity，恢复不能从当前 Account/Models projection反推或补写这些字段。该 adoption只连接同一 Conversation的 source与兼容 target，不允许切换 protocol或 Task model；未来通用 rebind仍必须由用户明确发起，重新校验 Workspace和当前 catalog ownership，创建新 binding epoch/Session，并以不可改写的配置边界保留旧 Run、usage与模型归属；失败不得回退到静默默认值。

## 7. 中间区域：Task 内容

> Capability：**混合**。用户输入、Agent 可见输出、permission、typed activity、Tool 摘要与 Run 状态属于当前产品路径；typed Delivery、Outputs、FileChange 与 Plan 仍是未来 capability，当前不得从 Agent 文本或 Tool 记录推断。

中间区域使用同一套 MetaWork AI UI 基础语义：`Conversation` 组织阅读面，`Message` 表达用户与 Assistant 发言，`Activity` 表达当前过程与必要终止状态，`Intervention` 表达真正需要用户介入的决定，`Composer` 控制下一步输入，`Markdown` 与 `CodeBlock` 呈现回复内容。它们是 Renderer 视觉语法，不把 Bridge 或 AgentCore 对象直接变成组件。当前不存在第二套 Task 专用消息、状态、请求或输入表面，也不以 Tool、Reasoning、Question 或 Approval Card 建立平行组件分类。

### 7.1 内容模型

Task 按稳定 Run 顺序显示 `Run exchange`：用户指令及其元信息之后依次是 `Assistant output（含所属 Response metadata）→ Live status / Technical work evidence → Intervention → File Changes → Terminal notice`，不存在的部分不占位。Assistant output 是单一 message，按 Host 保存的 closed commentary group 顺序承载多个 Markdown part，并以相同 part 槽位承载尾部未定性的可回滚 provisional 或已定性的 final/partial；part 只用正文留白区分，不增加卡片、时间戳、Tool 标签或阶段标题。live status 是位于当前输出底部、随唯一 Current activity 原位更新的一行状态；technical work evidence 承载按 Host order 排列的 Tool 摘要并默认折叠。它们属于同一 Run，不是不同说话者，也不构成 raw 事件时间线。Renderer 只做纯 presentation derivation 和会话内 disclosure，不复制 Product 状态机。

### 7.2 Agent 对话渲染机制

Agent 对话不是 CoreEvent 列表、Tool timeline 或逐 chunk DOM append。它是 Product Task 已经定性的 Run projection，由 Bridge 按当前 Task 和历史范围交付后，再派生为稳定的 Run exchange。运输、版本、范围与安全失效只由 [Renderer Bridge 合同](renderer-bridge-contract.md#2-productdelivery-与-snapshot-transport)定义；Renderer 不根据范围读取进度推断执行进度。唯一 owner 链为：

```text
AgentCore typed CoreEvent
  → Product Task：output / activity / tools / terminal facts
  → Renderer Bridge revision 1：范围内的 canonical Run projection
  → deriveRunPresentation(run)：纯 presentation derivation
  → TaskContent：稳定 Run exchange 槽位
  → RunProcess：active status 与可展开的 current/historical technical evidence
```

各层职责不可互换：

- Product Task 独占 output-segment 定性、commentary 边界、provisional rollback、Current activity、Tool lifecycle、terminal outcome/cause 和 credential-safe projection；
- Bridge 运输完整 typed facts，不运输 raw event identity、时间线、private reasoning 或组件状态；
- `deriveRunPresentation()` 只派生 active、response/process visibility、Host-order Tool 列表、唯一 running Tool presentation 和 terminal notice 条件，不保存或推进产品状态；
- `TaskContent` 只按 Task/Run 稳定 identity 组合槽位；输出 part 继续使用稳定 ordinal，插话使用 Host 提交锚点纯派生阅读位置，不把 Snapshot revision 当消息、不从文本或 Tool 内容推断新事实；
- Renderer 本地只拥有 Task+Run disclosure、逐 Tool disclosure、每 Task 阅读位置和 following-latest 等可丢弃 UI 状态；reload 后它们可以重置，不能写回 Product history。

每个 Run exchange 使用以下条件槽位，而不是为每类事件创建节点：

| 槽位              | 出现条件                                                                  | 更新方式                                                           |
| ----------------- | ------------------------------------------------------------------------- | ------------------------------------------------------------------ |
| User instruction  | Run 存在                                                                  | 历史稳定；正文下方始终有复制动作，可用时带弱化提交时间             |
| Assistant output  | 至少一个非空 commentary、provisional、final/partial 或必要 redaction note | 按插话锚点分为连续阅读块；closed part 稳定，尾部原位增长、定性或回滚  |
| Process surface   | Run active，或 terminal Run 存在 Tool                                     | active 时唯一 live status 原位替换；Tool 技术行始终按所属 Run 展开 |
| Intervention      | 当前 Run 存在 pending UI                                                  | 只显示唯一可操作控件，不伪装成 Assistant 文本                      |
| Terminal notice   | partial、非 completed outcome 或完成但无 response                         | 与 partial 合并为唯一准确提示，不重复成功结果                      |
| Response metadata | Run 已 terminal 且存在非空 final/partial response                         | 紧随所属 final/partial 回复正文；纯图标复制入口 + 可用时的弱化完成时间         |

`RunProcess` 同时承担 active Run 的唯一 live status 与 terminal Run 的历史 Tool 入口：

```text
active Run:
  User instruction + optional submitted time + input copy action
  Assistant output interleaved with optional user interjections
  RunProcess = live status header + optional collapsed Tool body
  intervention

terminal Run:
  User instruction + optional submitted time + input copy action
  Assistant output interleaved with optional user interjections
    response copy action + optional finished time inside the final/partial message
  optional File Changes
  optional collapsed RunProcess when Tools exist
  terminal notice
```

active→terminal 时，live activity 与持续外推必须消失；没有 Tool 的 process surface 同步卸载，存在 Tool 时则在最终结果之后保留标题为“执行详情”的默认折叠稳定摘要。Host 最终 `elapsedMs` 非空时在标题右侧弱化显示“本轮用时 {duration}”，不可得时不占位，也不改变入口名称。展开该摘要后，用户可以独立展开具有内联详情的 Tool 行；完整 input/progress/result 在所属行下方挂载，长代码面有界滚动，安全 raw details 继续二次折叠。已有专用 Product 审计面的 Edit 与 Write 不重复挂载原始 input/result。折叠 process surface 不清除逐 Tool disclosure；Renderer reload 后这些本地状态可以重置。存在非空 final/partial response 时，复制元数据紧随所属回复正文，位于同一 Assistant 阅读块内，不被后续插话、文件更改、历史 process surface 或 terminal notice 隔开；复制图标在左，Product 提供完成时间时在其右侧显示弱化的本地相对时间。

#### Output projection 与可见迁移

Renderer 每次只读取当前完整 `RunOutput`，不在本地累积 text chunk：

| Host output 状态                              | Renderer 行为                                                  |
| --------------------------------------------- | -------------------------------------------------------------- |
| open/continued segment 有安全 committed bytes | 作为 commentary 后的惰性交互 Markdown provisional 原位显示     |
| segment 关闭为 commentary                     | 同一尾部 part 原位定性为稳定 commentary                        |
| segment 关闭为 final/partial                  | 同一尾部 part 原位定性为 final/partial response                |
| segment 关闭为 discarded                      | provisional 从下一 Snapshot 消失，不保留撤回占位               |
| closed commentary 已持久化                    | terminal、reload 后仍按原 group 顺序恢复                       |
| response 已定性但 terminal 尚未发布           | response 可以显示，同时 active process surface 保持 finalizing |
| formal terminal 已发布                        | activity 必须为 null；未决 provisional 必须为空                |

Renderer 从 `Run identity + output ordinal` 纯派生每个 part 的 identity；provisional 定性只改变 disposition，不改变所属 Assistant 阅读块、React key 或 part DOM 根。只有 discarded、空内容或整个 Run 卸载才移除对应节点。credential 清理可能使某个 commentary item 为空，但 Renderer 不合并相邻 item，也不改变后续边界。

provisional 与 closed output 复用同一个安全 GFM 渲染根并始终跳过 raw HTML；代码块、列表、引用和表格可随已到达字节渐进形成，未闭合 Markdown 按当前完整前缀做 best-effort 解析，不引入修复器、第二套 parser、逐字动画或分类时交叉淡入。provisional 必须是惰性交互态：链接与文件引用只显示文字，图片只显示 alt text，代码与整段均无复制动作，也不新增正文 live region；唯一 canonical Activity 负责状态播报。final/partial 或 commentary 定性后才开放其对应链接、结构化文件引用和 terminal-only copy policy。

只有非空且仍在增长的 provisional 可以通过 React 调度让旧前缀短暂保留以避免高频 parse 阻塞；分类、discard、Task 切换和 terminal projection 必须立即使用最新 canonical 内容，不能显示 deferred stale text。已闭合 part 在正文与可用引用 alias 集不变时不得因 activity、Tool、elapsed 或无关 Snapshot revision 重新解析；alias 集晚到或失效时必须重新解析并更新可点击状态。第一阶段不维护增量 Markdown AST 或并行兼容 renderer；真实 WebView 的 256 KiB 混合 GFM 验收不通过时，应单独建立增量 parser 评估任务，而不是在运行时静默回退。

#### Activity 与 Tool presentation

非 terminal Run 必须有唯一 canonical activity；terminal Run 必须没有 activity。Renderer 不复制 activity 状态机，只把 Host activity 本地化并做两项有界派生：phase 缺失时只能使用同 phase 的防御性通用标签，`executing_tools` 且恰有一个真实 running Tool 时可以把固定 Tool identifier 映射为“检查工作区”“更新内容”或“运行操作”。多个、零个或未知 Tool 时回退到 canonical activity，不读取参数、结果或历史 Tool 推断 Agent 当前意图。

Tool start/progress/result 只更新同一 Tool record 和 process surface，不在主阅读流追加行。active Run 中展开技术过程用于检查当前证据；terminal 后相同 Tool records 继续通过默认折叠的稳定 process 摘要提供历史检查入口。每条 Tool 主记录固定为单行：左侧依次显示名称及至多一项 Host 安全摘要，右侧固定显示状态、Host elapsed 与可用的 disclosure 箭头；摘要依次取 Bash description、有限 progress 摘录或结构化 fileRefs 的 `displayPath`，空间不足时单行省略，不把不同来源拆成多行。fileRefs 在这里仅作为只读文件名摘要，不提供图标、按钮或预览交互；存在可呈现的 input/progress/result、Bash 字段、截断或脱敏说明时，用户点击对应 Tool 后在该行下方独立展开详情，多个 Tool disclosure 可以同时打开。没有详情正文或说明的 Tool 行保持只读摘要，不提供空 disclosure。

#### Snapshot revision、阅读位置与稀疏输出

ProductDelivery 可以合并短窗口 revision；Renderer 原子接纳当前页面所需的范围和版本，未变化的产品块保持引用与阅读位置。commentary block 稳定追加、provisional 原位变化、activity 原位替换、Tool 行按 Host order 更新，不能把 revision 数、事件次数或历史加载页数显示成进度。用户正在 following latest 时才自动滚动；用户上滚后任何流式更新或历史补载都不得抢回位置，只显示 `Jump to latest`。Task 切换和安全失效清除不再有效的候选，迟到结果不得恢复旧正文。

真实 Provider 没有提交新 commentary 或 provisional 时，主阅读流保持不变，只显示当前 canonical activity 和按需技术证据。Renderer 不重复状态行、不从 Tool 结果生成总结、不展示 thinking 正文，也不通过动画、计时器或伪百分比制造推进感。scripted Provider vertical 证明的是这套机制可以持续交付已存在的事实，不代表真实 Provider 的叙事频率。

#### 本轮耗时

活动状态旁可以弱化显示 Host 采样的“本轮已用时”，包含排队、等待批准和重试；仅表示经过时间，不表示进展或健康。Renderer 从该 Run 投影的本地接收时刻低频外推，切换 Task 不重新起算，reload 后使用新 Host 样本；terminal 后停止外推，存在 Tool 且 Host 最终 `elapsedMs` 非空时，在“执行详情”入口右侧固化显示“本轮用时 {duration}”，耗时不可得时不占位，没有 Tool 时不为耗时单独保留 surface。计时必须位于状态读屏 live region 之外，不触发逐秒播报、自动滚动或逐秒 Snapshot；计时变化不能用来生成叙事、推进状态或判断超时。排队与启动使用不同文案。

### 7.3 用户指令

- 使用浅紫色“任务指令”区块，最大宽度约为正文的 72%，靠右但不使用聊天尾巴、头像或左右双方气泡布局，也不重复显示“你”等归属标签；在窄窗口下可以放宽到约 88%；
- 首条指令建立 Task 目标，后续指令作为明确的补充或重试节点；普通界面不显示 Run ID；
- 附件以文件/目录 chip 展示名称、数量和大小；
- 每条指令正文下方靠右提供纯图标“复制输入”：最新一条始终可见，历史条目在所属 Run hover 或 focus-within 时显示，coarse pointer 设备始终显示；普通文本保持 Host 投影原文，Skill 输入复制为 `/调用名 参数…`，多模态输入复制已投影文本与附件显示名，不读取附件内容、内部 locator 或本地路径，也不从 DOM 反向提取；
- Product 提供 Run 提交时间时，在复制图标左侧使用 12px muted 本地化相对时间，一分钟内使用“刚刚”，完整本地日期时间由统一产品 tooltip 展示并作为 accessible name；时间缺失时不占位，禁止使用完成时间、Snapshot 接收时间、Run ID 或 `elapsedMs` 补造。相对文案与回复完成时间共用每分钟低频更新，不发布 Snapshot、不自动滚动、不改变历史；
- 已发送内容不能静默编辑历史；
- 未来的“编辑并重新运行”必须显式创建新的执行分支或新 Task。

### 7.4 Agent 回复

- 不使用头像和大气泡，使用正文排版；
- 支持 Markdown、表格、代码、引用和链接；
- commentary 作为 Assistant 过程叙事按 Host 提供的有序 group array 渲染为同一 Assistant message 内的独立 Markdown block；Renderer 不自行按换行切组，也不按 chunk 或 Tool 穿插伪造顺序。Host 发布新的 closed commentary group 后，主阅读流随 Snapshot revision 追加一个稳定 block；
- `commentary | provisional | final | partial` 共用安全 Markdown 排版；尚未收到 output-segment 定性的 provisional 不称为草稿，保持惰性交互并在 discard 后随下一 Snapshot 立即消失；流式生成不增加光标、骨架或第二个活动指示；
- 已闭合 commentary 与 final/partial 中的 `http`、`https`、`mailto` 链接保留链接色、下划线、键盘可达性和可复制 `href`，但点击必须同步阻止 WebView 默认导航并交给 Host；请求期间同一链接不重复提交，打开失败在原链接后以紧凑 danger 文案就地提示并允许再次点击，不使用与目标脱节的全局 Toast。非法协议、相对网页地址和 provisional 链接只显示文字；
- 已 terminal 且非空的 `final | partial` response 在所属 Assistant 回复正文下方提供纯图标“复制回复”：最新一条始终可见，历史条目在所属 Run hover 或 focus-within 时显示，coarse pointer 设备始终显示；active、commentary、provisional、Tool 与 terminal notice 不提供整条复制。点击后用同一份原始 Markdown 生成纯文本与安全语义 HTML；真实写入完成前不得显示成功，成功约 1.2 秒切换为勾选，失败约 1.5 秒切换为 warning，重复操作重置反馈周期，动态 accessible name、tooltip 和读屏状态分别使用“复制回复 / 已复制 / 复制失败”。代码块右上角提供独立的纯图标“复制代码”，只复制当前显示的代码正文；两类按钮都具备可见键盘焦点、明确 accessible name、tooltip 和至少 32px 点击区，不把语言名、围栏、行号或 UI 文案带入剪贴板；
- 回复末行在复制图标右侧显示 Product 提供的 Run 完成时间，使用 12px muted 文本和本地化相对表达，一分钟内使用“刚刚”，完整本地日期时间由统一产品 tooltip 展示并作为 accessible name，不使用浏览器原生 `title` 提示；时间始终可见而复制图标仍遵守最新/历史显隐规则。Renderer 每分钟低频更新相对文案，不发布 Snapshot、不自动滚动、不改变历史；时间缺失或超出可信范围时整项隐藏，禁止使用 `Date.now()`、Snapshot 接收时间、Run ID 或 `elapsedMs` 补造；
- 不展示原始 chain-of-thought；`thinking_chunk` 只显示“正在思考”的安全状态，`text_chunk` 开始后显示“正在撰写回复”；Renderer 还必须把 Host 已投影的 Starting、Waiting model、Executing tools、Retrying、Compacting 与 Finishing 显示为本地化 Current activity，并在 Host 提供时显示 retry attempt/max/delay；不同 activity 必须保持可理解的差异，不能把整个 active Run 统一退化成一个不变的“正在工作”；
- output 只表示 Agent 可见输出，不标记为 Delivery、Output artifact 或最终成果；
- 不从回复文本解析活动、计划、文件变化或完成状态；不得为每条内容重复“Agent”标签或品牌头像。

### 7.5 当前状态、请求与结果

- active Run 只显示一个来自 canonical phase/activity 的紧凑 live status，并固定在当前过程底部原位更新；它不为 Tool start/progress/result 追加时间线记录。`executing_tools` 且恰有一个 typed running Tool 时，Renderer 可以依据固定 Tool identifier 映射为“检查工作区”“更新内容”“运行操作”等宽泛但真实的用户文案；不满足条件时回退到 canonical activity，不在主状态中暴露原始 Tool 名称、参数或命令；
- Tool 摘要属于次要 technical work evidence，active Run 内与唯一 live status 共用默认折叠的 process surface；展开内容遵守本节 Tool 证据规则，不带入 usage 或 Run ID。Run terminal 后 live status 消失；没有 Tool 时整个 surface 卸载，存在 Tool 时保留默认折叠的“执行详情”摘要，并在 Host 最终耗时可用时于右侧显示“本轮用时 {duration}”。普通 Tool 可以在所属行下方查看完整 input/result；Edit 与 Write 不显示协议 JSON、不提供 disclosure，当其唯一 `fileRefs.displayPath` 与同 Run typed File Changes 的一个文件分组精确相等时，路径显示为审计链接并打开该 Run Review、展开且聚焦对应文件，否则保持只读摘要。该匹配只建立导航，不生成或补造 File Change。Work 与逐 Tool disclosure choice 仅存于当前 Renderer 会话，不写入 Bridge 或持久化；late terminal observation 不得重新打开 live 状态；
- pending UI 位于当前 Assistant 回复之后、Composer 之前，并提供唯一可操作控件；
- `completed` 且已有 final response 时不追加重复的完成条；空 final response、停止、失败、中断或 dependency failure 只显示准确状态、原因与真实可用的恢复动作；partial response 与 terminal outcome 必须合并为唯一 notice，同时表达“回复未完整生成”和真实终止原因，不能再追加第二条 partial 警告；
- terminal cause 使用最具体的稳定本地化文案：`provider_failure` 显示“模型服务请求失败”，并在同一 notice 中说明本次 Run 未生成可用回复或只生成了可能不完整的部分回复；`tool_failure` 说明工具失败且 Agent 未能恢复，`image_input_unsupported` 明确要求更换支持图片的模型并重新选择图片；不得把三者统一写成“检查模型或网络”，也不得直接展示 provider raw body；
- `provider_failure` 的主区 notice 只表达失败原因、回复影响和匹配的恢复动作，不重复技术诊断边界；若该 Run 已有 Tool 记录，提醒用户失败前已有部分操作完成，应在重试前通过同 Run 保留的折叠工作过程检查其影响；
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
│ 模型：当前模型 ▾                             发送 │
└────────────────────────────────────────────────────┘
  Workspace：metawork ▾
```

模型选择规则：

- New task 默认显示当前 active 模型；Composer 模型按钮和菜单项只显示模型名称，内部仍以来源和模型共同区分候选。菜单仅列出当前已选 Provider 的 ready 模型；已有草稿保留其明确选择的来源，其余从 Host 当前默认配置确定，不能合并其他 Provider 的候选。选择只用于本次 Task，不修改 global default；明确选择与默认相同时也保留该选择。重新打开 New task 时恢复初始默认意图；
- 没有可用 global default 时，已有明确来源仍允许选择该来源当前可用的模型并发送；没有已选 Provider 或该 Provider 没有可用候选时提供进入 `Models` 设置的导航，不回退到其他 Provider。不得显示完整 secret，也不得直接提交默认选择。草稿已选模型因 catalog/authority 变化失效时保留可见选择、禁用发送并要求重选，不能静默显示或执行默认模型；
- Models默认来源、Metask API/protocol/credential authority或 ready Custom Provider模型变化先更新 Models desired selection及对应 revision/source generation，再由 Product Control独立 reconcile active binding generation。两类变化都不热替换已有 live Task；detached历史 Task可在 §6.4的 Conversation restore中采用同 protocol、可承载其 pinned model的当前 credential authority，并通过窄 binding adoption提交新 generation，任意 protocol/model变化仍只能走未来显式 rebind；
- 已有 Task 的 Composer 从 Host modelIntent 显示所选模型，按钮和菜单项只显示模型名称，不随运行状态增加“下一轮使用”等前缀；来源或模型离开可用目录时仍保留模型名称，找不到显示名称时使用保存的模型 id。Provider 保留在设置页与任务信息中：任务信息按 modelIntent 显示“所选 Provider”，来源已移除时保留来源 id，历史来源未知时明确显示未知，不根据模型名或全局默认猜测 Provider；本轮或最近一轮的实际模型与协议直接取自对应 Run 记录，不能用所选模型覆盖执行事实。菜单仅列出 Task modelIntent 所属 Provider 的 ready 模型，不受 global default 的来源变化或忙碌状态约束；当前来源不可用或历史来源未知时保留模型事实，不借用其他 Provider 的目录。Host modelSelectionAvailability 决定目录可用性；modelIntent.state=outcome_unknown 时显示未确认原因并禁用再次选择；已接收消息由 Task 等待权威确认，保留输入并引导既有历史恢复。明确保存失败和过期 revision 刷新 Host 事实，不预测成功、不自动重发，不保留 Renderer 本地模型真源；
- 正在更新默认模型时只禁用相关选择和发送 admission，不冻结导航、历史阅读或其他 Task；
- 模型不可用时说明原因并给出刷新或设置入口，不能留下永久 disabled selector。

Composer 布局与输入规则：

- 模型控件位于输入框内部左下角，发送位于右下角；textarea 与底部工具带共同组成一个完整圆角容器，不得拆成相互竞争的表单块。Workspace 位于容器外下方的轻量 breadcrumb 行，不能做成第二个有边框卡片，也不能放回输入框上方形成第二条上下文栏；
- New task 没有有效模型选择时，Composer 在输入框下方、Workspace 行附近显示单一、可换行的模型准备提示，按 §14.1 区分首次配置、登录、选择、加载与恢复，并提供对应动作；不只依赖发送按钮的禁用样式或 tooltip。已有有效的显式草稿模型选择可沿原准入规则发送，不要求先设置 global default；其他情况等待 Host 确认配置可用。Composer 不提交或修改 global default；非默认草稿选择只随首次 Task create 提交 exact source/catalog generation，创建失败时保留以便重试，创建成功后清除；
- New task 的 Workspace breadcrumb 默认选中“默认”，并可以在 Automatic 与已保存且可用的 Manual Workspace 之间直接切换，也可以打开原生目录选择器添加目录或重新选择失效目录；已有 Task 只显示其绑定 Workspace 事实，不提供虚假的切换；
- 输入框不允许用户拖拽改变大小。它随内容自动增高，达到约 7–8 行或视口高度的 28% 后改为内部滚动；
- Automatic intent 不是 Workspace 缺失；`automaticWorkspaces` 可用时普通 Text 可以直接发送。只有所选 Manual Workspace 缺失或授权失效时发送才保持禁用，并在 breadcrumb 中提供明确恢复动作；Workspace 选择和发送是两个独立动作。

Composer 是唯一 Task 停止入口。空草稿在当前 operation、准备或等待消息存在时显示 44px Stop；有内容时显示发送，并保留独立的同尺寸 Stop。文本、Skill、附件均经同一 Task 发送入口，不以 readiness、Skill Run、compact、restore、停止或收尾阶段禁用有效发送；发送只受内容、连接、真实接收资格与容量约束。顶部命令栏不重复放 Stop。Stop acknowledgement 只表示请求处理，真实 terminal 取 Snapshot；重复停止请求可暂时禁用 Stop，但不能因此阻止新消息。

普通文本与带附件草稿遵守[产品输入限制](requirements.md#53-task)，按 UTF-8 字节预算判断发送能力。输入框不设置会截断粘贴的字符上限；超限时保留全文、禁用按钮与 Enter 发送，并在输入框附近提示如何缩短内容或改用文本文件。超限草稿仍可在本地有界保存预算内恢复。

每次点击或 Enter 将本次提交与当前草稿分离，立即清空本次编辑版本并允许编辑、发送下一条；IME 组合期间不触发发送，Shift+Enter 换行。逐条显示正在提交、等待或明确未执行；只有 Host 事实才能确认接收。未知回执不自动重发，用户可将失败/未确认内容放回编辑器检查后明确发送，不能覆盖已有草稿，失效附件需重新选择。旧响应不能修改较新草稿或抢走其他控件/Task 的焦点。

### 8.1 Slash、Command 与 Skill draft

Slash 是 Composer 的输入手势，不是 CLI 模式。空 draft 的首个非空白字符为 `/` 时，输入框上方打开与 Composer 等宽的候选面；不位于首 token 的 `/`，以及 token 内仍含 `/` 的 URL、路径和代码片段不触发。单段绝对路径与 Slash identifier 在语法上不可区分，若未命中候选则按 unknown Slash 禁止发送，用户需要补充正文语境或改写。候选只有两处真值：

- `Commands` 来自 Renderer 单一 registry，只注册当前产品真实存在且适合从 Composer 发起的动作；
- `Skills` 来自 New task 当前 Workspace catalog，或已有 Task 的 pinned catalog；Renderer 不合并目录、不读取 Skill body，也不按名称跨 revision 猜测替代项。

菜单贴附于 Composer，而不是全局模态命令面板。Command 与 Skill 分组显示，使用确定性的大小写不敏感 prefix/substring 过滤；`ArrowUp / ArrowDown` 移动，`Enter / Tab` 选择，`Escape` 关闭但保留可见文本。菜单打开时 `Enter` 绝不能提交普通 Text；IME composition 期间不打开、过滤或执行。textarea 使用 combobox 语义，候选容器使用 listbox/group/option，并同步 `aria-expanded`、`aria-controls` 与 `aria-activedescendant`。不可用 Command 保留可发现性并显示真实原因。

Command 只是现有动作的键盘入口。选择后由 `App` action controller 消费，不创建 command history，也不把原始 `/command` 送入 Bridge。V1 registry 包含 `/new` 与 `/compact`：`/new` 从已有 Task 打开 New task；`/compact` 在已有 finalized Run、continuation available 且没有 active operation 时触发 typed Task maintenance action。不可用 Command 保留候选并明确显示各自的禁用原因；New task draft 中 `/new` 说明草稿已打开，`/compact` 说明尚无可压缩历史，不能让一个 Command 的 gate 覆盖另一个 Command。`/model`、`/status`、`/goal`、`/resume`、`/continue` 以及其他尚无正式产品 owner/合同的 CLI/TUI identifier 不注册。带尾随参数的 Command 不执行；无法解析的首 token Slash 保持可见但发送禁用，用户必须选择候选、删除 `/` 或改写为普通正文。Command 与 Skill 同名时，裸 `/name` 归 Command，Skill 通过 `/skill:name` 显式选择。

选择 Skill 后，文本 draft 原子变为结构化 draft：左侧能力轨显示可移除的 Skill identity，右侧按 descriptor 顺序显示 positional argument 输入。Renderer 保留 catalog 的 `maxValues`，未命名的可选 positional argument 由用户逐项添加或移除，字段数不得超过该上限和产品的 64 项硬上限；发送前同时校验完整 Skill Run 输入的 64 KiB UTF-8 字节预算。`/review src/main.zig` 的可见尾随文本成为第一个参数，不实现 shell quote/escape parser；每次 Run 至多一个 Skill。Skill 原始 Slash 文本不进入 Bridge 或历史，发送只产生 `{ kind: "skill", skillId, catalogRevision, argumentValues }`。

Skill draft 与 Text draft 一样按 Task/New-task scope 保存在 Renderer session storage；既有 raw Text draft 读取后在下一次写入时单向升级为 tagged storage，暂时超过 Run 提交预算的非空 draft 不得删除已有持久值。失败或未知的已分离提交保留完整内容供显式放回编辑器，不覆盖较新的 tagged draft。catalog revision 或 identity 变化时保留 token 与参数，但显示 stale 说明并禁用发送；刷新是显式动作，成功后仍要求用户从新 catalog 重新选择。已有 Task 的 Workspace current catalog 尚不可用时，同一刷新动作先刷新 Workspace；Workspace ready 后再次执行才刷新 Task binding，不隐式监听、重放或跨 revision 替换。current Workspace 的 `loading / unavailable` 只影响 Skill 候选；Automatic Task 的初始准备 loading 另按 §8.3 阻止首个 Run，文字保持可编辑。

| Task state | Composer behavior |
| --- | --- |
| idle / queued / starting / running / waiting_user | 允许有效发送，Task 决定何时执行；请求回答独立于消息 |
| stopping / compact / restore / 收尾 | 允许有效发送并显示等待；不以执行阶段冻结输入 |
| failed / interrupted | 允许有资格的新意图，旧失败不自动重发 |
| archived / 删除中 / 真实 authority 或容量失效 | 保留草稿，按 Host 接收资格说明不可发送原因 |

输入区中的模式选择只有在语义明确时才出现。审批模式在 New task 输入框左下角作为紧凑下拉菜单出现，紧邻模型选择，只显示当前模式名称；展开列出三种模式名称及各自一句简短说明，不在输入框上方保留独立设置区或铺开说明，不得与模型、执行强度或显示密度混为一谈；已有 Task 只读显示自己采用的模式，不提供会话中切换或 disabled 预告。

Task 决定同步插话或等待下一轮，不使用 `UiBackend.poll()`。Renderer 统一提交消息，不在执行阶段选择路径。连接暂时不可用时草稿保持可编辑且不失焦，恢复连接不自动发送。Host 的 continuing 仅用于内部接续；来源保持真实完成状态，新草稿不混入已有批次，新发送由 Task 顺序处理。根据真实转入关联省略接续目标的重复根输入、时间与复制栏；不按文本相同去重，不显示采纳、接续或转入等技术状态。每条消息使用安全正文、原接收时间与锚点，等待消息转入执行后保持关联，只显示一次。

追加消息与普通用户消息使用相同气泡和复制操作，安全正文靠右显示，不另做状态卡片，不隐藏在默认折叠的技术过程内。内部采纳状态不改变消息外观或位置。Renderer 按 Host 提供的 `afterOutputCount` 将插话放在前 N 个 canonical 输出槽位之后，空的已闭合槽位和脱敏尾部占位仍参与计数，不能先按正文非空过滤再定位。按消息提交顺序对锚点取前缀最大值，再与当前输出槽位数取较小值；同一位置按递增消息 identity 排列，锚点超过实际输出时放在末尾，撤回导致后续锚点下降也不得颠倒用户消息。两个插话边界之间排序后相邻的 Assistant part 连续呈现，不按序号是否连续判断，也不切割同一流式 Markdown。整份临时输出被丢弃并重试时，重试可复用原槽位而显示在插话上方，这是接受的显示差异，不承诺严格的首次出现时间线。采纳锚点保留为内部事实，不产生额外消息、状态说明或重复正文。

命令超时后按 [Bridge 对账合同](renderer-bridge-contract.md)刷新并显示结果未知，不自动重发，不阻塞后续新意图；提交已与草稿分离，旧 connection 的迟到回执不能清除新草稿或抢回焦点。消息采纳不强制滚动或打开右栏；左侧不新增消息槽位图标，既有 completion receipt 与 Schedule 完成确认语义不改变。


### 8.2 文件附件

Composer 工具带在模型控件之前提供一个使用加号图标、带可访问名称与 tooltip 的“添加文件”按钮，与模型控件等高并在工具带内垂直居中，使用系统原生多选文件选择器并接受普通文件；用户也可以把操作系统文件拖入当前包含可编辑 Composer 的窗口，拖入时只在输入框范围显示克制的强调轮廓和“拖放文件以添加”提示。picker、拖放与普通 Composer 的图片粘贴只是文件接收入口，之后必须复用相同的附件 staging、结果和草稿；不提供 WebView file input。处理期间只允许一个添加操作，禁止再次添加和发送，文字仍可编辑；所有来源使用同一种添加操作；处理时按钮提供“取消添加”，取消请求发出后显示“正在取消添加”并禁用重复操作，直到 Host 确认 writer 静止及清理结果。原生 picker 仍由系统取消；窗口 scope 失效时撤销候选 authority，忽略迟到的 picker 结果。整批成功且当前 scope/generation 的草稿同步确认提交后才显示 chip；已移交附件不会被旧操作清理。取消保留已有草稿，typed rejection 在 Composer 就地说明原因且不产生部分 chip；清理失败明确说明残留，取消结果未知立即恢复连接并清除该连接未发送附件，保留文字和重新选择提示。离开当前 Composer scope 或关闭接收界面取消尚未移交草稿的操作；操作 identity 必须避免切换离开再返回后接纳迟到结果，已经 ready 的附件仍按下文规则保留。

图片粘贴只绑定普通 Composer 文本框，不接管 Skill 参数、其他表单或整个窗口。用户通过系统粘贴动作交付的 `image/*` File 按事件顺序作为同一批附件追加，保留已有文字和附件；类型、大小与格式仍以[产品附件准入](requirements.md#53-task)为准，不按 MIME 建立另一套可信分类或格式承诺，不自动转码。没有图片 File 时保留原生文字粘贴、选区替换与撤销；有图片时同步接管默认动作，不插入同次剪贴板附带的 HTML 或文字表示，不解析 HTML 或获取 URL。未命名 File 使用中性显示名；不按名称或内容自动去重，不自动发送。输入框可编辑但附件正忙或当前不能添加时，在现有附件反馈区域明确说明原因，不排队或静默丢弃；禁用输入框不接管粘贴。异步添加完成时合并最新草稿，不能覆盖处理中输入的文字。

ready 附件按选择顺序显示可换行的紧凑 chip，包含经过 Host 校验的 basename、文件类别与格式化大小，并提供逐项移除按钮。图片额外显示已识别格式；其他文件使用通用文件图标。chip 不显示绝对路径、缩略图、hash、上传进度或 provider wire。文件名保持原文且服从普通用户内容方向规则；超长名称截断，完整安全名称通过 title 与可访问名称提供。键盘焦点按选择顺序进入移除按钮，删除后移到相邻 chip 或“添加文件”。窄窗不得因附件列表产生页面横向滚动。

逐项移除在开始时同步更新所属草稿，保留最新文字和其他附件；Host 回包只结算原操作，不能覆盖草稿或将结果写到其他 Task。移除等待期间文字编辑和 Task 切换仍可用，添加、重复移除和发送保持互斥，并以“正在移除文件”区别于添加/取消添加。操作及反馈绑定草稿 scope、连接 generation 和操作 identity，切走再返回也不接纳旧反馈；旧操作收尾不能解除新操作的互斥，焦点不能迁移到其他草稿。release=false 遵守既有幂等语义，不恢复旧 token；无法确认清理结果时明确提示，并复用连接恢复、清除旧连接未发送附件和保留文字/重选提示的规则，不能猜测删除成功或恢复可能已撤销的 token。

Text draft 可以为空，只要附件全部是 ready 图片；非空文字固定先于全部附件提交，chip 顺序就是 input part 顺序。经 Host 按[产品输入限制](requirements.md#53-task)接纳的非图片文件以“文件”展示并可与图片混合发送；草稿只要含非图片文件，去除首尾空白后的用户指令就必须非空，否则发送按钮保持禁用，不额外显示常驻提示。空文件、超限或无法解码的已识别图片在整批 staging 时以 typed reason 拒绝，不发布部分 chip。附件不能与 Skill draft 共存：选择 Skill 时若已有附件必须先由用户明确移除，附件存在时选择 Skill 也必须说明该限制，不能静默丢弃任一草稿。模型 metadata 明确声明不支持相应图片媒体时只显示非阻塞提示；发送能力和最终错误仍以 Host admission 与 AgentCore typed result 为准。

附件 token 与 metadata 只保存在当前 Renderer connection 的内存草稿；Task 切换可以保留，document generation replacement、reload 或 disconnect 后必须清除。Renderer 只允许保存一个不含名称、大小、类型和 token 的 generic marker，使 reload 后能提示“未发送的附件需要重新选择”。文字/Skill 仍按既有 tagged session storage 保存。New task 已创建但 Run 尚未接纳时，附件草稿和文字一起迁移到真实 Task；Run 被 Product 接纳后立即清空 draft chip，timeout 先 resync snapshot且不得自动重放。

图片模型输入可以经过缩放和 PNG 转码，原件仍完整保留；其他文件由 Agent 按需选择工具或 Skill 处理本地原件。内部预览、引用和上下文预算不作为附件类型的另一套文件大小上限展示。

历史用户指令的附件 chip 只显示已保存名称、类型、可选图片格式、大小和顺序，不含文本正文，不可点击、预览、下载或一键重新发送。AgentCore 返回 `image_input_unsupported` 时，该 Run 以准确 terminal notice 收口，Composer 继续可用，但附件已被已接纳 Run 消费，用户若要换模型重试必须重新选择原文件。

### 8.3 New task 首次发送

首次发送区分创建真实 Task、Task 接收消息和实际执行。Renderer 对同一 New task 只发起一次 create；创建期间继续编辑和发送，有界保留明确提交，取得 identity 后依点击顺序交付，不等待上条响应，也不等待 Skill/restore/readiness。准备和推进属于 Task，Renderer 不管理底层执行逻辑。

创建失败或未知逐条显示失败/未确认且不自动重建；切页不改变原提交目标。创建期间停止取消此前尚未交付的提交；创建结果迟到时保留真实 Task，不再交付被取消项。之后的新发送是新意图。连接 generation 失效不跨重连补发。

Host 确认创建后，若用户仍在原 New task，则以 canonical Snapshot 切换真实 Task；保留同一个 Composer、输入、caret、IME 和焦点，约 220ms 动画在减少动效时直接切换。若用户已切页，迟到创建不能强制导航。消息转入执行后保留原接收时间、位置和 operation 关联，普通气泡及复制只出现一次；不显示采纳/转入等底层状态。等待、取消、中断和真实失败有简洁用户说明。内部等待不显示伪造 Running。

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

> Capability：**当前**。审批模式由 MetaWork 拥有，审批 occurrence 与 Session scope choice 由 AgentCore 拥有；自动评审不建立第三个 Core profile 或跨 Session 持久权限规则。

### 10.1 Permission request

审批卡片只能展示 AgentCore 当前 typed request 提供的 choice。`allow_once` 只批准本次请求；只有 request 带有精确 candidate 时才可展示 Session scope choice。Renderer 不得自行扩大 choice、持久化 grant、显示 `Always allow`，或从工具名称和命令文本推断作用域。

审批的 Session 选项必须按 Host candidate scope 呈现：`exact_arguments` 表达相同参数，`file_target` 表达当前 Write/Edit 工具对同一文件的后续修改并显示 Host 发布的目标文件；明确内容可变且不跨工具或文件。允许与拒绝的 Session 选项都遵守同一范围，主操作仍是仅本次。长路径必须换行，不撑破窄窗。目标被敏感过滤隐藏时只保留本次选择，不从参数重建路径。

重复请求说明只能依据可关联到该请求的诊断事实归因。restore 的规则失效总数只能作为“部分会话规则曾失效”的补充信息，并明确与当前请求的关系未知，不得宣称当前规则未能恢复或覆盖具体请求的诊断。

审批卡只在当前权限请求需要人工决定时显示，不仅按 Task 的审批模式判断。自动评审期间不显示审批卡、参数或批准与拒绝按钮，仅在执行状态中以 `aria-live` 说明“自动评审中”；用户仍可停止任务。评审中计入处理中，不计入人工关注数、不按人工待处理置顶，也不显示“需要你处理”的定位提醒；评审无法决定、失败或超时转人工后，立即显示审批卡并恢复人工关注与提醒，人工按钮与键盘决定保持可用。不改变底层 Run 等待审批的事实。不显示伪倒计时、自动重试或“已验证安全”。有效人工决定与自动结果仍由谁先被 Host 接纳谁生效，后来的回答按过期处理。审核器已允许或拒绝的请求不显示审批卡；其记录在所属 Run 中默认折叠，摘要只展示来源、可用的工具名称和本次结果，展开后展示 Host 脱敏理由，不重放参数。

### 10.2 审批模式

New task 的模式菜单只展示三个真实选项：

```text
人工审批
自动审批
直接执行
```

- `人工审批`：常规 Workspace 编辑自动执行，当前策略未覆盖的操作请求用户决定；
- `自动审批`：按任务意图评审本次内置工具请求，不确定或失败时转人工；菜单用一行说明提示模型评审、存疑转人工及额外计费；这不是安全保证，MCP 请求仍需人工；
- `直接执行`：MetaWork 不再为常规工具操作请求批准；AgentCore 核心保护、操作系统权限、服务授权和进程身份仍可拒绝或要求处理。它不是 root、Sandbox 或“信任 Workspace”。

New task 直接显示 Host 发布的默认审批模式，并允许在发送前修改本次选择；首次默认值、选择记忆、授权与恢复边界由[产品需求](requirements.md#55-审批与输入)定义，不叠加第二个确认 modal 或独立委托开关。New task 的审批选择保持紧凑，不常驻展示模式详情、费用说明或风险说明块；这些呈现变化不改变各模式的实际权限、费用和转人工语义。已有交互式 Task 在 Composer 显示同一三档菜单，Task 信息显示当前模式，不受新 Task 默认值影响。Settings 不提供权限入口。

已有 Task 的菜单只消费 Host `availableApprovalModes`，保留当前模式文字；不具备切换 authority 时只读。切换请求受理后显示忙碌状态并禁用重复选择，直到 canonical Snapshot 确认当前模式及 revision；不能乐观切换。跨直接执行边界且已有 Run 时，目标选项明确“先停止当前运行，再切换；不会自动重启运行”。Renderer 不另建 stop-then-switch 编排，也不重发当前输入。

恢复原会话、结果未知与失败各自提供真实状态文字。超时或断连不能呈现成功，结果未确认时提供显式“刷新状态”，只刷新 Snapshot；用户查看最新模式后才可再次选择。菜单使用既有键盘导航、可见 focus 与 Escape/选择后 trigger 焦点恢复，费用及直接执行边界说明保持可读；390px 窄窗控件换行且不得遮挡发送/停止动作。

Renderer 只显示 Host capability projection 声明的模式，不独立审核或更改 authority。Scheduled Task 继续采用其固定非交互 PermissionProfile，不显示自动审批选择；对应映射及授权语义由[产品需求](requirements.md#55-审批与输入)唯一拥有。

## 11. 按需详情与信息归属

> Capability：**当前**。右侧栏是应用三栏布局的辅助容器，Task Panel 是其中承载任务内容的视图；布局开关不属于该视图或任一具体功能，不提供概览根页、日志时间线、任意文件浏览、文件编辑或 Git 操作。

主阅读流拥有叙事、唯一 live status、审批、失败恢复与所属 Work process。默认折叠规则见 §7.2；用户展开 Work process 后，可以在精确 `taskId + runId + toolId` 的 Tool 行下方独立展开详情，详情随 Snapshot 原位更新，不打开或替换右栏内容。不复制整份 Tool 列表，不从 Tool 内容推断 Agent 发言、File Changes 或 Output。Tool 行只承担动作对象、状态与耗时摘要；详情只呈现未在行内表达且具有审计价值的证据，不重复 progress。Host 为内置 Tool 投影稳定的可读参数与结果，Renderer 不解析 provider 私有文本；未知或动态 Tool 才使用安全原始 input/result 兜底。成功的 `Write`/`Edit` 通过文件变更入口审查，成功的 `WebSearch` 与 `KillShell` 不建立空 disclosure；任何 Tool 失败都必须保留可读失败原因或安全原始结果。`Read`、`Glob`、`Grep`、`BashOutput` 与 `WebFetch` 使用各自的语义字段和证据内容。每个代码面最大高度为 `min(360px, 45vh)`，超出后内部滚动；代码面使用由 Tool 框架拥有的中性低对比表面、等宽排版和细边界，不复用 Agent 回复代码块的高对比背景；统一不提供专用复制动作，用户仍可使用平台原生文本选择与复制。该规则不影响 Agent 回复、文件预览或其他内容界面的代码面与复制策略。Host 提供可读 Bash 字段时，详情只呈现 command、exit status、非空 stdout/stderr 与不完整捕获说明，不重复已经解释的原始 input/result。只有部分 Bash 字段无法解释时，未解释的安全原始字段才进入第二层“未解析数据” disclosure；全部无法解释时直接说明并呈现安全原始字段。空 stdout/stderr 不占位；Renderer 仍不得从空输出推断目录为空或任务完成。

信息按事实的生命周期放置：

- Run 的 input/output/cache read/cache creation 统计不进入对话、任务信息或右栏，也不保留空 disclosure、隐藏组件或兼容入口；Host/Bridge 的统计、持久化和数据合同不变。不合并为 Task 用量，也不推算总运行耗时；
- Composer 仅在当前 attached Conversation 有 Host pressure 观测时显示对应 warning/critical 的可读提醒；只有用户打开后才展示最近观测说明和 current/auto-compact/blocking token 数。没有 pressure 时整块隐藏，即使存在 lastAutoCompact 历史也不创建入口；不展示压缩前后 token、dropped/kept、伪百分比、连续实时用量、raw source Run identity 或跨 attachment 历史。Host 清除 pressure 后提醒与已展开详情同步卸载，不由 Renderer 计时或历史推断恢复；
- Task 标题附近的“任务信息”使用独立 info 图标，仅在用户打开后只读展示实际执行模型、固定 permission profile（受 capability gate 控制）与创建时 MCP 三态。模型取当前 Run 的冻结 execution；没有当前 Run 时取最近一轮 Run，并标明“最近一轮模型”；没有 Run 时不展示执行模型，不用 Composer 选择或 global default 伪造执行事实。MCP 不是实时连接状态，不暗示可热附加。不增加通用设置页或第二个概览；
- pendingUi 派生“需要处理”定位入口，不存已读或自动展开记忆；只有原始主区审批提供操作按钮。用户点击定位时，overlay 先关闭再滚动/聚焦原请求；停靠面板保持。新请求自身不触发滚动、焦点移动或面板开合，全宽覆盖时定位入口仍可达。

右栏显隐不属于内容目标。内容是当前 Task 内的对象标签会话：可以同时保留多个精确文件预览，File Changes Review 最多保留一个；未打开对象时呈现通用空态。文件预览只从对话内联引用进入，工作过程不重复文件入口；记录审查保留所属 Run 的入口；不扫描文件系统、不自动读取正文。Review 是按文件首次出现顺序纵向展开的连续差异文档，同一 `displayPath` 的稳定顺序记录汇入一个文件区块；不建立记录列表、单条详情页、返回层级、文件树或旧概览兼容开关。

每个顶层标签代表一个具体对象，不代表“预览/审查”功能模式。文件标签以精确 `taskId + runId + referenceId` 去重；标题和 `displayPath` 只用于呈现，不能推断对象相同。Review 标签在当前 Task 内是 singleton：重开同一 Run 只激活已有标签，打开另一有效 Run 时在原位置原子替换其目标；验证失败不得先清空既有 Review。标签按首次创建顺序保持稳定，重新激活不重排；关闭活动标签后优先选择其右邻，否则选择左邻，用户关闭最后一个标签时同步隐藏右栏并把焦点返回该标签的真实 opener，opener 失效时回到稳定的 Task Panel 开关。对象因 Task 切换或身份失效而被清空时不自动改变右栏显隐。

隐藏右栏只改变布局显隐，保留当前 Task 会话内的标签、已读取内容、活动标签和各标签视图状态；关闭单个标签才释放对应正文并使未完成请求 stale。切换 Task、删除当前 Task、离开可承载 Task 内容的页面或连接身份整体失效时清空全部对象内容，但保留用户选择的右栏显隐与宽度；无 Task 时呈现空态。普通 Run 开始、终态和 Snapshot revision 不关闭仍有效的对象。Review 中单条记录失效只移除该记录及正文；所属 Run 或全部记录失效只关闭 Review 标签，不连带清除文件标签；文件引用失效也只关闭对应文件标签。

身份有效性必须在渲染前判定，不能仅依赖 effect 清理。文件读取与 diff 请求继续使用精确身份和每对象独立的递增 request generation；标签关闭、Review 目标替换、Task 切换与目标失效后，晚到成功或失败都不能覆盖新内容。只挂载活动标签的正文，非活动标签保留会话内资源和视图状态但不得保留隐藏 DOM 或进入辅助技术树；不声称已取消 Host IO。显式刷新重新请求，激活已有成功文件标签不得无故重读。

保留右栏宽度偏好及第 4 节的停靠/覆盖规则。有对象标签时，面板头部提供单行对象标签条、活动对象动作和隐藏按钮；标签关闭与隐藏右栏必须是两个独立动作。未打开对象的空栏不显示通用容器标题条或重复隐藏按钮，仍保留可访问名称，并由命令栏常驻开关控制显隐。每个标签记录最近一次真实 opener；从面板隐藏时焦点返回活动标签 opener，opener 已消失或 disabled 时回到稳定的 Task Panel 开关，从全局开关隐藏则焦点留在该开关。标签使用标准 tablist/tab/tabpanel 语义和手动键盘激活，嵌套 menu/dialog/popover 优先处理 Escape，面板尊重 defaultPrevented。隐藏右栏不改变 Task、审批或运行状态。

Plan、typed Outputs 与尚未开放的能力不渲染空壳或占位符。

## 12. 文件预览、文件变更与结果文件

### 12.1 文件预览

> Capability：**当前**。可预览目标来自 AgentCore `tool_result.file_refs` 或 Agent 验证的 Host 生图保存凭据，并由 Workbench 持久化为结构化文件引用；它是按需读取当前文件内容的只读能力，不是 Files changed 或 Output。

- Host 来源标记的生成图片在所属 Run 的正文下方提供直接预览，最大宽度不超过正文宽度，缩略图保持比例，不裁切；图片本身是键盘可达的预览入口，点击激活现有右侧文件标签；图片下方不重复展示路径或“打开预览”文字栏，完整 accessible name 仍标识目标文件。仅这类可信图片在接近可见区域时读取，其他文件继续按需打开。加载、失败和显式重试原位呈现；引用/Task/连接失效后不显示旧图或接受迟到响应。历史记录缺少来源标记时不猜测，不把普通工具 JSON、文件后缀或 provisional Markdown 转成自动加载图片；
- 主要入口位于所属 Run 的已闭合 commentary 与 final/partial 回复中：普通文字中的完整文件名、行内代码和显式 Markdown 文件链接，只有能匹配本 Run 结构化引用时才呈现为可点击内联入口。保持原文字与正文行高，使用链接色、下划线、完整 accessible name 和可见键盘焦点；点击直接在右栏预览，不要求展开工作过程。provisional 虽按 Markdown 排版但保持惰性交互，不执行引用识别；代码块、图片说明和外部链接不做文件识别，也不把未知文件文本伪装成可打开入口；
- 匹配只使用 Host `displayPath`、其显式相对写法及无歧义文件名，区分大小写，不查询文件系统、不从 Tool 参数拼装 authority。同一路径的重复引用为正文入口选择最后一条有序引用以读取当前内容，不宣称它是该句的历史版本或新文件身份；不同目录的同名文件不得仅按文件名选中，未匹配的本地 Markdown 路径不作为网页导航。引用晚到或失效随 Snapshot 更新可点击状态，不触发自动读取；
- 工作过程不提供 fileRefs 预览入口，只允许在 Tool 单行摘要缺少 description/progress 时显示只读 `displayPath`，也不把引用聚合到回复 footer 或右栏列表；正文内联入口按精确引用身份在 Task Panel 打开或激活对应对象标签，只显示用户已经显式打开的文件，不提供全部引用选择器；
- 文件预览使用 Task Panel 顶部对象标签表达当前路径，活动标签右侧只提供刷新和标签关闭/面板隐藏动作，正文不追加资源副标题、状态标签、常驻说明或信息入口。`.md`、`.markdown`（后缀不区分大小写）默认安全渲染文档，支持标题、列表、表格、引用与代码块，并在正文上方提供更弱层级的“预览 / 源码”切换；切换只使用已读取正文、不重新请求文件。刷新保持当前模式，切换标签后恢复各文件自己的模式和滚动位置，关闭后重开恢复默认模式；非活动视图不保留隐藏正文；
- Markdown 复用安全 Markdown 呈现边界，不执行内嵌 HTML 或脚本；图片只显示替代文字，不请求本地或远程资源；相对资源链接不作为应用导航，只有 HTTP(S) 链接可按主阅读流相同的 Host handoff 与就地失败反馈打开，不接受 `mailto` 或新增资源读取、网络权限。文档主体纵向滚动，宽表格与代码块各自横向滚动；
- 静态 PNG、JPEG 与静态 WebP 文件在同一预览标签中显示 Host 交付的完整原图，实际 WebView 解码完成前保持 loading，完成后按解码尺寸保持比例并使用容器内可用空间，不显示源码模式或原始 Base64。APNG/动画 WebP、单图超限和窗口累计容量不足分别解释原因，不静默缩图；容量不足允许用户关闭现有预览后重试。内联图片离开保留区域释放资源，重新接近时按需读取；
- 普通文本、代码文件及其他已支持的文本格式显示中性等宽源码，保留空白并允许自身横向滚动，不增加模式切换。源码左侧显示从 1 开始的单列行号；行号与正文共用滚动容器，横向滚动时固定在左侧，不进入文本选择、复制内容或辅助技术朗读，只编号当前实际显示的文件前缀且不推断截断后的未读取行数。已识别且处于 Renderer 高亮预算内的代码文件自动渐进增强为主题适配的语法颜色，Markdown 的“源码”模式同样适用；未知格式、超出预算、模块加载失败、grammar 异常或高亮结果校验失败时静默保留完整纯文本，不自动猜测语言、不增加状态、重试、开关或语言选择。HTML、SVG 与 XML 即使显示 markup 语法颜色也始终只渲染惰性源码，不形成真实元素、执行脚本或加载资源，界面不为这一限制增加常驻提示或说明入口。只有具备经验证的独立隔离容器和受控资源读取能力后才能开放页面渲染，不能复用应用主页面执行 HTML 或放宽安全策略作为临时方案。文件预览不做 diff、range 高亮、自动刷新或文件 watcher；
- UI-only `loading` 不进入 Host wire；稳定呈现状态为 `ready | missing | restricted | unsupported | changing | error`，传输的 `busy` 有界重新排队并保持 loading，安全代次重试规则由 [Renderer Bridge 合同](renderer-bridge-contract.md#file-preview-command) 定义。`changing`、`error` 与累计容量不足可以显式重试，其他非 ready 状态只解释原因且正文必须为空；`truncated` 和 `redacted` 以文字说明，不只依赖颜色；
- Renderer 为每个文件标签独立维护 request generation。首次打开和刷新推进该标签 generation；关闭标签、切换 Task、reference 从新 snapshot 消失或该标签后续请求开始后，旧 Promise 即使完成也不得覆盖当前内容。切换到其他标签只卸载当前文件 DOM，不清除仍打开标签的已读取 bytes；重新激活 ready 标签不请求，关闭后显式重开才重新请求；
- File Preview 只陈述“这个 Run 引用了哪个文件，以及它现在可读取的内容”。Renderer 不从 reference kind、Tool 名称、Assistant 文本、Bash 输出或文件后缀推断 create/modify/delete、Output、citation 或 Run 时版本。

### 12.2 Files changed 与 Outputs

> Capability：File Changes **当前**；typed Output **未来**。File Changes 只消费 AgentCore typed `file_changes` observation，不能从 Tool 文本、Bash 输出、Git、文件后缀或 File Preview reference 推断。它是已记录副作用的审查视图，不承诺 Workspace 当前净状态。

- 每个 Run 在 Assistant response 及其复制元数据后、必要 terminal notice 之前显示紧凑的单行“文件更改”入口。至少一条记录时，整行使用一个原生按钮，只显示中性 diff 图标、“文件更改 · 唯一文件数”和“审查更改”动作；不使用卡片、图标底板、过程竖线或第二行状态，也不暴露内部修改记录次数。`incomplete` 在同一行明确提示记录可能不完整；`incomplete` 且零记录时只显示非交互警告，不提供空 Review 动作；其他零记录状态不占位；
- “审查更改”在既有右侧 Task Panel 打开为 singleton 对象标签，不建立独立 route 或占用整个工作区。Review 绑定一个明确 Task + Run，标签使用“审查更改”，活动正文立即进入按文件首次出现顺序排列的连续差异文档；不重复显示类型、标题或常规说明区。Run 级入口打开即请求并展示首个文件的首条 diff；Edit/Write 的已验证路径入口则展开、滚动并聚焦对应文件头，优先请求该文件的首条 diff。同文件后续记录在该文件区块接近可见区域时按稳定 `order` 逐条接入，后续文件纵向衔接，不经过列表页、单条详情页或返回动作。打开时显式展开右栏；切换其他标签保留已读 diff、折叠与滚动状态，关闭 Review 标签才释放这些内容；
- 每个文件使用一个克制文件头区分身份和边界：文件名前以 Git 惯例的 `A/M/D/R` 等宽字母和对应语义色表示聚合后的 created/modified/deleted/moved，不再重复状态文字；partial 是正交的异常事实，只在文件名后显示 warning 图标，并以“更改可能未完整应用”的可访问说明解释。文件头继续显示完整可取得的 `displayPath`、moved 的 `from → to` 与增删摘要，不显示同路径记录序号。文件默认展开，整个文件头是带 `aria-expanded` 的原生按钮，点击、Enter 或 Space 只折叠/展开所属文件的 diff、加载状态和错误说明，文件身份及增删摘要保持可见；折叠状态只属于当前挂载的 Review，不持久化，也不触发尚未开始的按需读取。ready 后可从已经汇入该文件区块的 recorded diff 派生增删行数，但不得据此宣称 Workspace、Git 或 Run 的当前净变化。区块使用分隔线形成连续文档，不包装成可导航卡片；底层多条记录、稳定顺序、独立读取失败与 stale identity 不得因呈现聚合而丢失。停靠、左栏互斥和窄窗全宽 overlay 仅沿用 Task Panel 的统一响应式规则；
- diff 只通过 `metawork.files.diff` 读取 Product 已记录的 credential-safe unified diff。首条立即读取；其余区块仅在进入或接近 Review 可见区域时各自按需读取，不因打开而批量预取。已读取正文只在当前 Task 的 Review 标签内并存，不形成跨 Task、跨关闭或持久化的 Renderer cache。每条请求绑定精确 `taskId + runId + changeId + request generation`；关闭 Review 标签、替换其 Run、切换 Task、目标 Run/记录消失或同记录后续请求开始，都必须使对应旧 Promise stale，不能覆盖其他记录或新 Review；
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

> Capability：**混合**。当前 Renderer 合同已提供持续可达的 Workbench、长期 Settings overlay，以及设置与 New task 共用的 Models-owned默认 API/模型选择；跨重启 execution rebind仍按独立 capability gate验收。

### 14.1 首次启动

首次启动不设置独立登录页面。Renderer 直接挂载 Workbench shell；可信根 Snapshot 到达前全部 mutation 保持关闭，确认根连接失败后使用独立连接恢复表面，只表达连接事实、重试和安全诊断，不显示任何登录文案。

Account 状态在 Workbench 账号入口、Account 设置及新任务输入区中表达，开始弹层只提供统一登录入口：`checking` 显示检查状态，`signed_out` 提供统一登录动作，`authorizing` 显示等待并仅在 `can_cancel` 为真时允许取消，`authenticated` 显示已验证 identity。Account 状态不得自动打开设置、替换 Workbench、隐藏 durable Task，或重新解释 Product Control 发布的 New task admission。OAuth成功后由 Host把 Account授权交给独立 Models continuation恢复或加载目录；历史 intent命中时自动恢复，唯一候选自动采用，真实歧义进入 Models设置。任何 live Task 始终可查看和停止。

新任务的首次模型准备引导使用紧凑的“开始使用 MetaWork”弹层，主动作“登录 Metask”、次动作“配置自己的模型”，并提供“暂时跳过”。次动作与 Providers 设置复用同一运行时能力 gate，能力未开放时隐藏并使用仅登录的说明；弹层不承载 credential 表单，不承诺模型安装或下载。

自动展示须在可信 Snapshot 与正常连接建立后，仅在新任务工作面、Account 已确认 signed_out、没有可用模型或更具体的配置恢复问题时发生。检查、授权、目录加载、执行配置替换、存储恢复、账号错误、已有自定义配置待修复和显式草稿选择失效优先呈现自己的状态。历史、执行中的 Task、设置、搜索、其他模态界面和正在输入的草稿不被首次引导打断。

本机轻量 UI 偏好记住引导已处理，不保存账号、模型或 credential：用户选择任一入口、跳过或关闭后记为已处理；首次确认已有可用模型也视为已处理。记录跨 reload/重启保留，不随退出登录或模型失效重置；存储失败不阻止使用，当前 Renderer 会话仍抑制重复自动展示。关闭按钮、Esc 和遮罩关闭等同跳过。输入区“开始使用”可主动重新打开弹层。

点击登录后关闭开始弹层并调用既有 beginLogin；输入区显示“请在浏览器中完成登录”，取消只在 Host canCancel 为真时提供。点击配置后关闭弹层并打开 Providers 设置，保存服务后通过清晰的 Models 入口添加、测试和选择模型；不复制配置向导、不自动设置默认值、不因后台配置成功强制关闭设置。两条路径均保留原草稿、Workspace 与审批模式，不自动创建 Task 或发送。

跳过后输入框继续可编辑，模型尚未配置时显示“登录或配置模型后即可发送”及“开始使用”；已有模型事实仍保留。Metask 所选模型需要授权时直接提供登录，自己的模型配置入口开放时同时提供“其他方式”重开开始弹层，其他来源已有可用模型不应自动关闭用户主动打开的选择面；已有候选但缺少选择时提供模型设置；目录失败或无模型时提供重试；自定义服务缺少凭据或被禁用时进入 Providers，服务已保存但模型尚未就绪时进入 Models 添加、测试或选择；模型存储异常进入 Models，定时任务存储阻止执行配置更新时说明具体原因，并仅在管理或恢复能力开放时进入定时任务页；本机资源不足如实说明，不提供无效的模型设置恢复承诺。检查、加载与准备状态不提供伪恢复动作；输入区只显示一份主要模型提示，模型恢复后移除，其他发送条件保持独立。按钮和 Enter 保持发送语义，不隐式改为登录或配置。

弹层复用 Foundation Dialog，具备可见标题、描述、焦点限制、关闭及焦点返回；初始焦点落在登录主动作，手动关闭回到原触发位置，自动展示关闭回到 Composer。跳往设置时焦点交给设置页。窄窗正文和动作可换行，不截断阻塞原因。

### 14.2 设置结构

```text
General
└── Language

Account
├── Account information（authenticated identity and balance; sign-in state when unauthenticated）
├── Account usage（daily Token history and recorded cost）
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

设置树不提供权限分区或权限设置项。New task 只显示 Host 声明的审批模式并记住成功创建 Task 时的选择，既有 Task 的会话模式选择与当前值展示见[审批模式](#102-审批模式)。

`Providers` 只有在 management、API Key 写入系统 credential storage、模型测试和已开放 protocol admission 共同可用时才整体进入设置树；它与 `Models` 平级，不是 Models 的下一级。不能只显示不可完成的空壳或“能力不可用”页面。Host 按当次运行时 capability 决定是否开放，不按 Windows/macOS 平台名建立静态 allowlist；目标平台尚未形成完整验收证据时由验证规范保留风险事实，不把已有运行能力永久屏蔽为产品缺失。

Workspace 列表、打开、迁移、清理和重新授权不属于 Settings surface。New task 路径控件负责选择、添加和重新授权 Manual Workspace；Automatic Workspace 只随 owning Task 导航。Renderer 只在当前 draft 内保存 Manual Workspace identity，不维护 `activeWorkspaceId` 或其他全局活动 Workspace 镜像。

`General / 常规` 中提供一行“Automatic Workspace 位置”，它只设置未来随机子目录的直接上级目录，不关闭随机目录、不改名、不迁移也不删除既有 Workspace。主值始终显示 Host 发布的 effective canonical path；system default 只在路径旁显示为“默认”状态标签，不能用“系统默认位置”等抽象文案替代真实路径。辅助文案明确“仅影响新建任务”；动作为“选择文件夹”与仅在非默认或需要显式恢复时出现的“恢复默认”。Choose 只打开 Host 原生 picker，并在 Host 拥有 canonical path 时以当前路径作为初始目录；没有可信路径时不猜测目录。取消后保持页面和焦点；命令完成前禁用该行动作，成功后等待 canonical Snapshot 刷新，不乐观替换路径。

`path_unavailable`、`persistence_unavailable`、`read_failed`、`corrupt`、`write_failed` 和 `outcome_unknown` 都使用该行下方的局部错误文案，只展示 Host 明确发布的 Choose/Reset/Retry 动作。不可用路径仍显示已保存值，不伪装成系统默认；不可信配置则不显示猜测路径。错误不离开 Settings、不触发 New task、不改变底层 draft；原生 picker 关闭后恢复到发起按钮。

`Account`规则：

- 只显示 Metask identity、授权状态、登录/取消、token refresh恢复、账户用量摘要和退出；不得把 API/model catalog、默认模型、Models错误或连接状态显示成 Account字段；
- authenticated时，“账户信息”组显示已认证用户名、Host生成的邮箱脱敏提示与并发额度，不重复显示“Metask 已连接”或成功状态点；邮箱缺失时省略该项。组内放置唯一智能紫主动作“充值”并配外链图标，点击后由Host通过系统浏览器打开固定Metask充值页；按钮可触区域不小于44px，不显示当前 OAuth 合同无法取得的余额。非 authenticated 状态仍显示检查、授权或登录说明及其有效动作。随后在现有设置 group/list语法中增加一个克制的“账户用量”分组，直接显示“Token 使用记录”日历热力图。热力图默认选择范围结束日，以完整日期、总量、输入、输出、缓存创建、缓存读取和已记录费用承担当日明细；组尾显示最近同步时间与唯一刷新动作。必须注明这些数字属于整个 Metask账户，不是 MetaWork单应用统计；金额单位统一为 U；
- 热力图按每日 total Token 使用紫色五级强度呈现，日历语义固定为 `Asia/Shanghai`。宽窗显示最近53个周列，小于620px时显示最近13个周列且不产生水平滚动；每个视图均从周一开始，截至当天，因此当前周尚未发生的日期保持范围外占位。范围外占位与成功响应中的零使用日必须视觉可区分；颜色不能作为唯一信息，图例必须同时给出“少/多”文本和强度格。焦点日下方持续显示完整日期、总量、输入、输出、缓存创建、缓存读取和已记录费用；鼠标悬停、点击以及键盘方向键移动都能选择日期，并有可见focus样式；
- history 按 unavailable/loading/ready/stale显示。已有值刷新失败时继续显示并标注“可能已过期”，不得清空成0；初次不可用只给局部、可操作说明，不把Account伪装成未登录。只有整个history范围成功且通过严格验证时，范围内缺失日期才显示为0；失败不能生成零值热力图。刷新只由用户点击或authenticated/generation建立后的Host自动同步触发；进入设置、Renderer reload、snapshot update和本地timer都不能触发；
- authenticated 后用量分组直接展示 history，不读取或推断旧 `run_mode`。不得显示当前 OAuth 合同无法取得的余额、今日或累计摘要，也不得显示完整email、account id、标准费用、请求数、RPM/TPM、响应时间、API Key数量、订阅额度、模型分布、按模型趋势、最近请求、任意外部管理链接或其他装饰性图表；固定充值页是账户区唯一允许的外部动作，Renderer不得取得或拼接其URL；
- 请求或配置错误、网络失败与刷新结果不确定不得被描述为“凭据过期”“后端撤销”或“已从设备移除”。Account错误可保留authenticated identity；此时账户信息和账号菜单提供既有登录动作。重新登录取消后仍有错误时，入口继续可达。刷新阻断由Host校验，不从错误文字反推权限、不自动重试旧token、不增加保存恢复页面或公开状态；
- 已验证 identity 的 refresh timer 或 wall clock 无法安排时继续显示 `authenticated`，在 Account 设置错误区说明自动刷新未安排并提供唯一 `重试登录刷新`；该动作调用 Host `retryRefresh`，不得由 Renderer timer、reload 或普通 snapshot update 自动重放；hard expiry 后 Metask 新目录/解析由 Host fail closed；
- 重新登录或退出登录不得因 Models、Task、Session、Run、job、worker或 Task-owned credential的运行时引用而被阻止，也不得静默终止或改写这些引用；既有 Task按创建时取得的 ExecutionConfig继续收口；
- 退出登录必须说明 Account设备凭据会清理、Metask模型将暂时不可用于新 Task、自定义模型不受影响且历史保留；不能把它描述成对 live Task的热撤权。

`Models`规则：

- `persistenceHealth = recovery_required` 显示单一显式恢复确认面；文案必须说明 Host 会先尝试恢复合法配置，只有文件缺失或确认损坏时才清空，不得无条件承诺删除 Provider 或模型配置。操作成功后完全以新 snapshot 为准；失败保留恢复面，不由 Renderer 猜测磁盘结果或自动重放；
- 进入该设置 route只渲染 Host已提交的 Models projection，不触发隐藏同步；用户显式点击 `重新同步`时才刷新 Metask provider目录。已提交 intent在同步期间保持可读，`重新同步`只用于失败恢复或页面保持打开期间发生的 Metask外部变更，不能成为打开下拉框或切换默认值的前置步骤；
- 页面以一组连续的 `Provider → 默认模型` 控件显示并修改 global default，并在组头持续显示当前已提交的 `Provider · Model`；Provider 限定 source authority，只有最终选择默认模型时才提交完整 `ModelRef`。Models 是唯一允许提交 global default 的产品页面；
- Models 与对话 Composer 只提供对话模型选择，不设置生图模型选择区域、生成按钮或连接测试。生图模型由 Host 自动解析，Renderer 不渲染图片目录或维护第二份配置。生成可能收费及失败后不自动重试的事实使用既有工具说明和审批详情呈现；结果沿既有工具详情提供真实文件引用或不可用原因，不伪造图片预览、图库或模型已看过图的事实；
- Metask 的 credential authority 由 OAuth 会话隐式提供，Models 页面不显示或选择 API Key；user-managed Provider 的已保存 credential 只在独立 Providers 页面管理，Models 页面也不重复投影凭据步骤；
- Metask protocol 固定为 Anthropic Messages，Renderer 不提供 protocol、base URL 或 credential 编辑入口；
- 切换 Provider 只准备并收窄当前模型候选，不会隐式替换 global default，也不改写 durable Task 历史或正在运行的 Session；
- 默认模型选择与 New task Composer 使用同一 Host-owned selection，不维护两份互相漂移的 Renderer preference；
- 既有 Task 只显示解释历史所需的 protocol、模型与 generation；不显示或保存 Account identity 与 API Key 元数据；
- 跨重启历史 Task 保持只读；设置变化不能使其静默采用当前默认值或伪造 Session；
- `在 Metask 中管理`只有在 Host发布固定安全入口后才显示；当前没有该 capability时不放置链接或假入口；
- Account为 `signed_out`时，Metask provider显示需要登录且不允许刷新/选择；无 secret的已选 intent可以保留，Custom Provider 与其模型仍可独立查看和管理。
- 选择 Custom Provider 后，模型步骤始终显示该 Provider 的全部模型和新增入口，不以“尚无模型”作为唯一可编辑状态；每个模型提供独立测试与带确认的删除动作，ready 模型才可提交为 global default。新增第二个及后续模型不得要求删除或覆盖已有模型；

设置页保留左侧分区导航与右侧内容的双栏布局。桌面双栏直接消费应用左侧导航轨的已保存宽度，使设置内容起点与 Workbench 分界线保持一致；设置页不建立第二份宽度状态或第二个拖动器。它是桌面控制面，不使用营销页式 Hero，也不为视觉饱满度增加无产品语义的卡片、渐变、玻璃材质或装饰性图表。顶部只保留与左侧导航对齐的返回入口，不重复展示全局设置标题和说明；标准窗口下当前分区标题和第一组设置必须在首屏形成紧凑、稳定的阅读起点；窄窗口可把分区导航收成横向行，但不得改变设置 owner 或复制页面状态。

设置视觉与控件遵循以下规则：

- 页面背景、工作面、交互组和浮层使用视觉系统中的 `surface-app` / `surface-work`、分隔线与真实抬升关系建立层级；普通设置行不逐项卡片化，Provider 和模型这种依赖型配置形成连续交互组；
- 每个设置分区页面在内容列顶部使用一个醒目的页面标题；页面标题下用 13–15 px 的小分组标题组织设置项，具体控件再使用自己的字段标签。不得在页面标题、分组标题和字段标签之间重复写“设置”或同义标题；
- 页面标题约 22–26 px，设置主文案 13–15 px，辅助文案不小于 12 px；disabled 状态只改变语义色和对比度，不缩小字号；
- 语言、Provider 和模型统一使用经过键盘、焦点、碰撞和长列表验证的同一 headless Select primitive；正式设置页禁止依赖 WebView 平台主题的原生 `<select>`，也不建立另一套自绘菜单；
- compact 选择器只显示一个短值；Provider 可以使用 detailed 选择器显示名称与来源说明，credential 与 protocol 不伪装成可编辑字段；
- Provider 与默认模型控件在同一个工作面中以带步骤标记和连接线的连续配置链呈现，明确表达 `Provider → source-qualified ModelRef`；不能再附加 Metask 专属配置块、API Key 步骤或第二个同名的默认模型控件。credential 的创建、替换和删除只能进入独立 Providers 页面；
- 模型目录加载、选择和持久化只冻结相关配置组，不得冻结语言、导航、历史阅读或取消仍被 Host 接受的操作；
- 设置页把 Provider 候选准备与 global default mutation表现为一条分阶段的 Models-owned transaction；Provider 只限定 source，最后一步从该 source 的 ready 模型中提交唯一 global default。Metask provider-local 准备和最终 global default提交分别校验对应 catalog/source generation与 expected revision，再 durable提交 Models state；Custom Provider 使用其 provider revision 提交完整 `ModelRef`。Product后续 resolve/scrub/install失败时另行显示 desired/active mismatch与 recovery，不回滚 Models，也不把 Product failure显示成 Account mutation失败。Renderer可在 command acknowledgement前短暂回显用户请求，但收到 snapshot后必须以 Host projection为准；页面重建、失败和成功都不得依赖 Renderer临时状态恢复事务；
- 常规桌面宽度下左侧分区导航切换独立的设置分区页面，右侧一次只渲染当前分区；页面标题和左侧分区导航保持稳定，当前分区内容列可独立滚动。窄窗口改为顶部横向分区导航，但仍不让导航与内容共享滚动层；
- 浮层只在打开时使用克制的透明度与位置过渡；loading 指示只出现在真实运行的配置项，`prefers-reduced-motion` 下移除非必要动画；
- 当前分区导航必须有持续可见的选中态和 `aria-current`，不能只在 hover 时出现；focus ring、菜单选中勾选、状态色和文字共同表达状态。
- 桌面壳注册标准 `primary + ,` 设置快捷键，直接打开正式设置 route；快捷键只负责页面导航，不建立绕过 Account/Bridge gate 的第二命令面。

Account与 Models状态在设置中分别投影：Account按 `checking | signed_out | authorizing | authenticated`显示 identity action，并在authenticated时直接消费Host发布的summary子投影；Models独立按 `needs_authentication | loading | choosing | ready | failed | unavailable`显示provider配置。Account authenticated不能被summary或Models失败伪装成未登录，Account signed_out也不能隐藏Custom Provider。Renderer不从任一公开状态恢复内部operation，也不区分或展示credential persistence子步骤。

Models 设置与 Composer 的候选只来自 Host 按[产品模型范围](requirements.md#52-账号provider模型与执行配置)发布的合格目录，不把失格的历史或 Renderer 请求项补回可选菜单。ready 目录允许保留已失格的 default intent；设置保留其身份并明确提示重新选择，合格候选仍可操作。合法空目录禁用模型选择并提示“没有可用的对话模型”，保留重新同步入口与 Account 登录状态。

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
- Metask provider catalog与当前 custom default同时投影；custom default生效时模型设置仍可查看 Metask 模型，并通过显式“设为新任务默认”提交同一个 global default command。Account只决定 Metask provider当前能否授权，不参与默认来源选择；
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
- `assets/icons/app-icon.svg` 是通用 PNG 与 macOS 应用图标用途母版，使用纯白背景；标志按画布中心缩放至约 88%，使可见主体约占画布宽度 70%。`assets/icons/app-icon.png` 与 `assets/icons/MetaWork.icon` 从该视觉母版派生，不增加非设计渐变、shadow、specular 或 translucency；
- Windows 的 `assets/icons/app-icon.ico` 直接从品牌标志派生，使用透明背景，可见主体约占画布宽度 88%，各尺寸保留透明通道与平滑边缘；开发窗口、任务栏及安装快捷方式使用同一 ICO，不叠加白色底板；
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

> Capability：**混合**。错误表达、Host/Core 中断、持续可达的 Workbench、独立 Workspace 和无伪 Resume 属于当前约束；execution rebind 与完整历史恢复按各自目标 capability 显示。

### 17.1 未登录

未登录是 Account 与 Metask provider 的局部状态，不是应用级页面。Workbench继续显示本地能力与历史，左下角账号入口提供统一登录动作；新任务模型准备引导、等待浏览器授权与取消遵守 [首次启动](#141-首次启动)，复用账号动作。目录准备和真实模型歧义进入 Models职责，不得回退或跳转成账号页面。

### 17.2 New task

显示：

- 清晰的行动标题，不使用空泛欢迎语或人格化 Assistant 宣传；
- 一句话说明 MetaWork 将在当前本地 Workspace 中完成工作；
- 作为首屏主视觉的 Composer；
- 当前模型与 Workspace；
- 当真实能力边界影响本次执行时，显示准确、可操作的 authority 限制提示；不得显示泛化的“信任此工作区”。

没有 Workspace 时可以先输入临时草稿，但发送动作明确引导选择 Workspace；用户在原生目录 picker 中确认即完成 Manual Workspace 授权，不追加“Use this folder”或 trust 弹窗。模型尚未准备时同时遵守 §14.1 的模型提示，不把 Workspace 问题解释为登录问题。

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
- 1100 × 720（验证中央与右栏的 360 px 最小宽度及左栏变化后的停靠边界）；
- 960 × 680（窄窗口回归样本）。

这些尺寸用于稳定复现布局问题，不是产品最小尺寸、固定设计画布或断点来源；断点应由内容拥挤、可达性与平台窗口行为验证得出。

### 19.2 Locale

- `en-US`；
- `zh-CN`；
- pseudo-locale；
- 缺失翻译回退。

### 19.3 Task 状态

- 运行 Run 中的空草稿显示 Stop，文本/Skill/附件草稿显示发送或禁用原因，并保留独立 Stop，两按钮尺寸一致；发送立即清空本次编辑版本，允许继续编辑；Enter 不破坏 IME、换行和 Slash 选择；审批始终保留独立处理面；
- 插话在所有内部状态下都保持普通用户气泡、通用脱敏提示和复制操作，不展示采纳、接续、转入状态或专属动作，技术过程不重复正文；响应丢失沿用既有发送对账反馈；
- 较新草稿、切换 Task、重载及旧连接迟到响应不丢输入、不重发、不抢焦点；桌面和约 390px、深浅主题、键盘、长内容及减少动效均须验收；

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

- cold restore 保持稳定的 Workbench shell，可信 Snapshot 到达前不开放 mutation，也不闪现独立登录页；
- 首次 signed out 且没有可用模型：保持 Workbench，按 §14.1 展示可跳过的开始弹层与输入区恢复提示；不得制造 saved account、上一次登录或 mismatch 分支；
- OAuth 正常完成、浏览器未回调、取消和 hard deadline；
- 历史选择命中、唯一 Key/模型自动推进；
- 多 API、多模型真实选择以及选择期间 reload；OAuth identity 成功后不退回未登录；
- catalog timeout/有限重试、OAuth exchange 失败、持久化确定失败与结果不确定；
- Metask 无可用模型、目录加载失败以及 Host 未提供管理入口时的可理解恢复文案；
- Bridge invoke timeout 后释放 busy、snapshot resync 后恢复 Host 动作；
- ready 后进入 Workbench，左下角显示 identity；重认证、设置和退出只按 Account busy/error scope 收口，Product execution/Schedule recovery 使用独立 scope；Account ready + Execution unavailable 时 recovery action 可见且不会被账号设置 redirect 遮挡。

### 19.5 Workspace、模型与设置

- Workspace 是独立 projection：空 Workspace、最近使用、重新授权、移除和跨 Workspace Task signal；
- Automatic Workspace 位置行覆盖 system default/custom、仅影响新 Task 的说明、Choose 取消和焦点恢复、Reset/Retry 的 Host capability gate，以及全部 typed health；旧 Task 不显示已迁移，Renderer 不提交或乐观镜像物理路径；
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
- 多个连续 Tool Call 保持独立的单行有界顺序摘要，不自动归并或追加主阅读流卡片；
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

- Host 未发布 permission capability 时不显示模式入口；选择、费用与边界说明、评审状态、只读旧会话以及人工响应符合 §10；
- 默认 profile 只影响新 Task；Task effective profile 不可变，Run provenance、same-profile fresh/restore、Task archive/delete 和 Scheduled noninteractive 语义一致；已有 Task 不显示伪切换；
- `full_access` 文案明确保留 AgentCore 核心保护、操作系统权限、服务授权和进程身份边界，不宣称 root、Sandbox 或 Workspace trust；选择动作不再追加第二个确认 modal；
- 权限卡片只显示当前 request 支持的 once/Session choice，不显示跨 Session 持久授权；
- 权限卡每次只有一个智能紫主操作：默认为“允许一次”；仅当 request 提供 `allow_session` 时，在该主操作的分裂展开菜单中显示“本会话允许相同参数”。拒绝是视觉中性但语义清晰的独立操作，`deny_session` 如存在放在其自身展开选项中；不得并列多个紫色主按钮；
- 同一 Task 内出现与已解决 occurrence 相同的 tool binding 和 canonical arguments digest 时，卡片显示简短的“为什么又请求”说明，优先区分上次只允许一次、policy generation/candidate 已变化、Session grant 未恢复或无 Session choice。不显示 digest/rule ID 原值，不声称已证明真实 effect；
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
- 右侧栏常驻开关可由键盘操作，无 Task 时也能独立开合；Task 切换、删除、目标失效不改变布局显隐或保存比例；任务信息纯图标、上下文压力提醒与审批定位入口可由键盘操作，缺少 pressure 时不显示上下文入口；Run 用量和历史 auto compact 不独立展示；
- 右侧只挂载活动对象标签的文件详情或同 Run File Changes Review；标签切换卸载非活动 DOM，关闭标签后聚焦相邻标签，关闭最后一个标签同步隐藏面板并回到该标签的真实 opener，opener 失效时回到稳定 Task Panel 开关。Review 直接挂载连续差异文档并保持明确 Task + Run 身份，不提供列表/详情层级或内部返回；Escape 隐藏右栏并回到真实对话入口；
- 普通 Run start/terminal、新 pendingUi 和 usage revision 不自动开合右栏、不抢焦点；切换 Task、关闭标签或对象失效不泄漏旧详情和已读取 bytes，晚到 Promise 不覆盖新对象；隐藏右栏保留当前 Task 会话，切换 Task 清空会话；
- 左栏折叠后完全隐藏且命令栏入口仍可达；Task Panel 关闭或 overlay 显示后功能不丢失；停靠态始终为中央工作面与 Task Panel 各保留至少 360 px，两者都不设置固定最大宽度；扣除左栏后的空间少于 720 px 时切换 overlay，低于 820 px 与左栏互斥，低于 620 px 使用全宽 overlay。验证样本至少覆盖 1440/左栏 320 的约 746+374、1200/左栏 320 的 520+360、1200/左栏 480 的 360+360、960/左栏关闭的 600+360、960/左栏打开的 overlay，以及超宽窗口右栏仍可继续扩大。
- Windows Renderer 窗口按钮在根启动/连接失败表面与 Workbench 均可见、键盘可达；最小化、最大化/还原和遵循 `close_policy = hide` 的关闭命中真实窗口，按钮区域不进入 drag candidate；

### 19.9 视觉与 Foundation

- `ui-design.md` 是唯一设计规范，品牌资产、token CSS、Foundation 组件与产品样式只作为实现镜像；
- 品牌 primitive 与本文逐字一致，不存在 `brand-*`、组件局部色板或其他平行视觉值；
- Foundation 组件只消费 semantic token；Tailwind bridge 不引入新值，产品 feature 不重建基础控件；
- 智能紫只用于品牌、关键动作、当前选择、焦点和真实活动路径；成功、等待、失败与删除保持独立语义并提供非颜色提示；
- 当前 Light 主题在桌面与约 390 px 窄屏下完成对比度、键盘焦点、长中英文、横向溢出和 reduced-motion 检查；未经同等验收不得显示 Dark/Appearance；
- 标志、应用图标与托盘图标保持同一基础几何和各自用途安全区；平台生成资产不得引入未经设计的渐变、阴影或材质；
- 普通页面不使用大面积紫色渐变、玻璃拟态、装饰性节点、粒子、3D 透视或游戏 HUD。

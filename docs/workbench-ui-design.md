# MetaWork Workbench UI 设计

> 状态：维护登录优先、任务中心和 capability-gated 的成熟产品目标；未通过对应能力验收的界面不得出现
> 设计基线：MetaWork 自有的本地 Agent Workbench；外部产品和参考图只用于提炼交互模式，不构成可复制的布局、品牌或组件规范

## 1. 文档职责

本文档把现有视觉稿补充为可实现、可测试的 Workbench UI 方案，定义：

- 用户可见的信息架构与术语；
- Workspace、Task 和一次执行在界面中的关系；
- 任务时间线、工具活动、审批、权限、结果文件和错误状态；
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

> Task 启动前，Composer 清楚表达 Workspace 与模型；Task 启动后，中间区域沿一条可追溯的“工作轨迹”组织指令、可见活动、决策和交付。

### 2.1 当前 ABI v1 capability profile

当前锁定的 development ABI v1 revision 3 只为以下界面提供可验证数据：

- 文本流、工具开始/进度/结果、Run progress、usage、context warning、auto compact、retry 和 stream done；
- Ask question 与 permission 两类同步用户请求；
- Run 状态、六种终止原因，以及 Session 是否仍可继续。

因此当前产品只显示时间线、工具活动、问题/权限卡片、Current activity 和真实 usage。Plan、plan approval、Outputs、Files changed、持久权限管理和 custom UI 均保持隐藏；它们在本文档中的设计是后续 capability 到位后的产品规范，不是当前实现承诺。Renderer 不解析工具参数、stdout 或普通文本来猜测这些状态。当前 Renderer 合同已提供独立 Workspace projection、Task-bound ExecutionConfig facts、正式设置 route，以及设置与 New task 共享的默认 API/模型选择；跨重启 rebind 等仍须等对应 capability 落地后才能宣称可用，差距由 [验证规范](validation.md)明确记录。

### 2.2 Capability 标记

本文在每个依赖未落地合同的章节就地标记状态，不要求实现者只靠本节的全局免责声明推断：

- **当前**：现有锁定合同可以提供，仍需按验证矩阵确认具体实现；
- **目标**：产品行为已经批准，但必须等标注的 Host、Bridge、persistence 或 AgentCore capability 完整落地后才显示；
- **未来**：只保留设计边界，不进入当前实现范围；
- **混合**：章节同时包含当前与 gated 行为，具体条目必须继续标注。

未达到依赖条件的目标或未来 UI 必须保持隐藏，不能用 Renderer 推断、静态假数据或 disabled 空壳提前占位。

## 3. 用户可见对象与术语

> Capability：**混合**。Task/Run、Account readiness 与当前事件对象已经存在；独立 Workspace、binding epoch history 和 typed Outputs 按各自目标 capability 落地。

### 3.1 对象关系

```text
Account
├── Metask identity
├── API catalog
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
- `Account` 是全局身份与执行能力入口；API 属于账号设置，模型属于默认配置和新 Task 上下文。
- `Workspace` 是独立产品对象，不能只从 Task 路径反推。
- 产品对象就是 `Task / 任务`；每个 live Task 在当前进程中持有一个内部 Agent `Session`，但 Renderer 合同不暴露 Session 身份。
- `Turn` 和 `Run` 通常不直接命名，用当前活动、排队、停止和结果表达。
- 一项 Task 可以包含多次用户补充和多次执行；停止一次执行不会删除 Task。

当前 Renderer 产品合同为 `metawork.renderer-bridge` 固定 revision 1：`connect` 精确协商后才开放产品路径，snapshot 根节点包含无 secret `capabilities`、`account`、`selectedWorkspaceId`、`workspaces` 与 `tasks` 且不维护局部版本；Account 直接发布 `readiness`、唯一 `primaryAction`、脱敏 catalog selection 与 generation，Workspace 独立于 Task 发布，Task 固化 binding epoch 与显示事实。快速开发阶段直接原地 hard cut 合同内容，不提供临时形态兼容层或可选字段退路；任何合同类版本标识变更必须先得到用户显式同意。Agent 内部 Session route identity 不属于 Renderer 产品模型。

### 3.2 规范术语

`en-US` 文案定义产品语义，`zh-CN` 是首个完整本地化版本。

| English source       | 简体中文     | 使用说明                           |
| -------------------- | ------------ | ---------------------------------- |
| Workspace            | 工作区       | 本地目录和任务归属范围             |
| Task                 | 任务         | 用户可持续补充的工作上下文         |
| New task             | 新建任务     | 不使用 New session                 |
| Account & models     | 账号与模型   | API、默认模型、刷新与重新认证      |
| Model                | 模型         | 新 Task 的执行模型，不称模式       |
| Inspector            | 检查器       | 按需活动摘要与详情，不称 Monitor   |
| Current activity     | 当前活动     | Agent 此刻正在进行的可观察动作     |
| Plan                 | 计划         | 只在有真实结构化计划时显示         |
| Outputs              | 结果文件     | 用户关心的最终交付，不称 Artifacts |
| Files changed        | 文件变更     | Agent 实际修改过的文件集合         |
| Needs your attention | 需要你处理   | 审批、问题回答或计划确认           |
| Allow once           | 允许一次     | 仅批准当前请求                     |
| Always allow         | 始终允许     | 创建可撤销的持久权限规则           |
| Stop task            | 停止任务     | 停止当前执行，不删除任务           |
| Stopping             | 正在停止     | 等待真实停止结果                   |
| Interrupted          | 意外中断     | 与明确失败区分                     |
| Show in Finder       | 在访达中显示 | Windows 为 Show in Explorer        |

## 4. 主窗口信息架构

> Capability：**当前**。登录优先 gate、独立 Workspace projection、左栏、New task、设置 route、工作轨迹与按需 Inspector 已进入当前 shell；未通过 capability gate 的 Inspector 模块仍必须隐藏。

### 4.1 总体布局

```text
┌───────────────────────────────────────────────────────────────┐
│ Integrated title/command bar · context · search · OS controls │
├──────────────┬────────────────────────────────┬───────────────┤
│ New task     │ New task Composer              │ Inspector     │
│ Workspaces   │ or Task work trace             │ when useful   │
│ Task groups  │                                │               │
│              ├────────────────────────────────┤               │
│ Account      │ Composer / execution control   │               │
└──────────────┴────────────────────────────────┴───────────────┘
```

默认尺寸：

- 左栏：248 px；
- Inspector：打开时 304 px；审批、活动详情、usage 或真实结果只决定模块是否可用，不触发普通 Run 的自动开合。除新的 `Needs your attention` 可自动打开一次外，显隐由用户控制并在 Run terminal 后保持稳定；
- 中间正文推荐最大宽度：760 px；
- 表格、diff、日志和文件预览可以使用中间区域的可用宽度；
- 960 × 680 仅作为窄窗口回归样本，不定义产品最小窗口；实际下限由内容可达性、Composer 可用性、系统窗口约束和 200% 文本验收共同决定；
- 低于约 1100 px 时 Inspector 使用覆盖层或保持关闭，更窄时允许折叠左栏。

左栏折叠状态按用户偏好保存。Inspector 内容只决定模块和入口是否可用；显隐只由用户动作、Task 切换或新的 `Needs your attention` 单次自动打开改变，并按 Task 保留当前应用会话内状态，不持久化为空面板偏好。折叠只改变视图，不改变 Task、审批或运行状态。

### 4.2 窗口模型

首个正式版本采用单主窗口模型：

- 多个 Task 在同一窗口内切换；
- 后台 Task 不因切换而停止；
- 系统通知用于提醒后台 Task 等待用户、完成、失败或中断；
- 多窗口属于后续能力，不进入当前设计范围。

### 4.3 一体化窗口栏

主窗口使用 `hidden_inset_tall`：Renderer 命令栏同时承担窗口标题栏的视觉角色，不再叠加独立的标准系统标题行。窗口效果仍由 Native Host 执行，不允许 Renderer 直接操作原生窗口身份。

- macOS 为系统交通灯保留左侧安全区；Windows system WebView 无法可靠显露 DWM glyph 时，命令栏提供唯一可见的最小化、最大化/还原与关闭 affordance，Host 在重新校验来源窗口后执行真实 native action；不得同时显示两套窗口按钮；
- 命令栏只包含左栏开关、当前 Task/Workspace 上下文、全局搜索和按需异常入口；`左栏开关` 只控制 Workspace/Task 导航，不兼任 Inspector 开关；
- 命令栏空白背景在越过移动阈值后请求窗口拖拽；按钮、输入、选择框、链接、disclosure 和展开内容必须排除。Renderer 只提交 drag/control 意图；Host 以 App-owned 单一启动窗口 identity 和主线程校验受限 bootstrap chrome capability，使连接失败页仍能移动或关闭窗口，而不依赖 ProductDelivery 已连接。Windows 平台操作必须继续使用同一精确窗口身份，不能猜测当前活动窗口；当前不伪造跨平台双击标题栏语义；
- 正常连接、恢复成功和普通操作成功不持续占据命令栏；只有同步失败、命令失败或其他确实需要用户行动的异常才显示状态入口；
- 异常状态按 connection、account、Workspace identity 或 Task identity 分域保存；并行 Task 的结果不得互相覆盖，命令栏只选择当前上下文中优先级最高的一项显示；
- 每个已有 Task 的内容标题区右侧提供稳定的 Inspector 图标按钮，accessible name 随状态使用 `打开检查器 / 关闭检查器` 并发布 `aria-expanded`；New task、无 Task 或没有任何可检查事实时不显示该按钮；
- 未登录界面的应用工具栏只保留产品 identity 与语言入口；语言不能藏进尚不可进入的设置；
- `chromeless` 仍被禁止；Windows 可见按钮只是 hidden-inset WebView 的控制 affordance，不能据此宣称自绘窗口系统已经覆盖 resize、Snap、系统菜单、DPI 或高对比；
- 语言、API、模型和诊断进入设置或对应任务上下文，不常驻命令栏；
- 不在命令栏放 ABI、Provider、Host mode 等工程状态。

平台文案、路径、快捷键和文件管理器动作按 OS 切换。

## 5. 左栏：Workspace 与 Task

> Capability：**混合**。当前 Renderer 合同已提供独立 Workspace projection，当前 shell 已提供稳定 New task、Workspace/Task 导航、行动优先分组和左下角账号入口；跨 Host Task persistence 仍是目标能力。

### 5.1 Workspace 切换

登录后的左栏从上到下只承担四类稳定职责：品牌/窗口识别、New task、Workspace/Task 导航、左下角账号入口。搜索由标题栏或命令面板提供，不在窄侧栏重复占据首要位置。

当前 Workspace 显示名称和必要时的路径：

```text
Invoices
~/Documents/Invoices
```

点击后打开 Workspace 切换器。左栏主体只列出当前 Workspace 的 Task，不同时展开所有 Workspace。

- `New task` 默认使用当前 Workspace；
- 当前没有 Workspace 时仍先打开空白 New task 页面并允许暂存草稿；发送保持禁用，由 Composer 下方的 Workspace 控件显式选择已有 Workspace 或打开原生目录选择器。选择完成后只更新草稿上下文，不得自动创建 Task 或发送已有内容；
- New task 草稿按 Workspace 隔离。未绑定 Workspace 的临时草稿只在目标 Workspace 没有草稿时迁移；目标已有草稿时保留两边内容并打开目标草稿，不能覆盖或丢弃任一份；
- Workspace 切换器消费 Host 发布的独立 Workspace projection，支持最近使用、打开新目录、重新授权和移除入口；没有 Task 的 Workspace 仍然可见；
- 每个 Workspace 入口汇总 `Running`、`Needs your attention` 和 `Failed/Interrupted` 数量；当前 Workspace 之外的待处理状态不能只依赖系统通知；
- 点击 Workspace 状态徽标切换到该 Workspace，并优先定位对应分组；系统通知点击后直接定位原 Task 和请求；
- 移除 Workspace 不删除历史 Task 或真实文件。入口只在当前 Workspace 可用时出现，并先用就地非模态确认说明“运行中的 Task 会停止、不会删除本地文件和历史记录”；确认打开时聚焦安全的取消动作，`Escape` 取消并把焦点还给触发入口，确认后把焦点移到不会随最后一个 Workspace 消失的稳定区标题。随后 Host 把 Workspace 标记为 `removing`、推进 epoch 并拒绝新 Task/Run，导航持续显示进行中状态；全部收口后才撤销当前 Host authorization 并退出活动导航。失败时 Workspace 保持可用、显示“移除未完成，部分任务可能已经停止”并允许重试，不能静默恢复得像什么都没发生；
- 再次打开历史 Task 只保证可浏览记录；需要访问原目录时重新选择或授权，能否继续执行还必须服从 §6.4 的 Conversation 与 execution binding 规则。

### 5.2 Task 分组与排序

Task 按行动优先级分组，而不是全部按时间混排：

```text
Needs your attention
Running
Queued
Recent
```

- 空分组自动隐藏；
- `Recent` 内部按更新时间排序；
- 运行中、排队、等待用户、失败和中断使用图标、文字和颜色共同表达；
- 后台 Task 产生待处理请求时必须进入 `Needs your attention`；
- 不能只用绿点、灰点区分状态。
- `New task` 是左栏唯一持续高权重的创建动作；Workspace 的添加和管理进入切换器，不与其堆成多个同等级按钮。

### 5.3 创建、命名、归档与删除

- 点击 `New task` 只打开空白任务页；第一次发送后才创建真实 Task，避免空记录；
- 标题根据首条用户指令自动生成，用户可以重命名；
- 归档从日常列表隐藏，但保留记录和引用；
- 删除移除 Task 记录，不自动删除 Workspace 中生成或修改的文件；
- 删除确认必须明确说明文件不会被删除；
- queued、running、waiting_user 或 stopping 的 Task 不能归档或删除；必须先停止或明确取消并等待真实 terminal 结果。

### 5.4 左下角账号入口

`execution_ready` 后，左栏底部固定显示 Metask identity：头像或首字母、显示名和简短连接状态。它是全局账号入口，不显示完整 API Key，也不承担模型快速选择。

点击后打开轻量菜单：

```text
张三
Metask 已连接

账号与模型设置
重新认证          [仅需要时]
退出登录
```

- `reauth_required` 使用文字和图标共同标记，并把 `重新认证` 提升为菜单主动作；
- 退出登录受 Host execution replacement gate 约束，不能只清 Renderer 状态；
- 账号菜单只负责身份和导航，API/模型目录的完整管理进入设置页面；
- 未登录时不渲染这张用户卡，因为未登录界面尚未进入 Workbench shell。

## 6. Task 生命周期

> Capability：**混合**。四轴 Run/Task 状态和单 Task 单 in-flight Run 属于当前合同；Task-bound generation、跨重启历史恢复与显式 rebind 属于目标能力。

### 6.1 核心规则

- 每个 Task 同时最多一次执行；
- 每个 Task 创建时建立第一个 execution binding epoch，固化不含 secret 的 generation、account/profile、Provider/API identity 和模型事实，并让对应 Agent Session 持有 owned ExecutionConfig；默认 API/模型变化不修改当前 epoch；
- 多个 Task 可以后台运行，超过 Host executor 能力时明确排队；
- 切换 Task 不停止执行；
- `Stop task` 只停止当前执行，不删除历史、输入或已有文件；
- 一次执行完成后 Task 回到空闲，可以继续补充要求；
- `Failed` 表示得到明确失败结果；
- `Interrupted` 表示 Host/Core 生命周期被破坏，结果可能不完整；
- 中断后不得自动重放可能有副作用的工具。

### 6.2 状态模型

不得把 Task 生命周期、当前 Run 阶段和最近一次 Run 结果压成一个 enum。Host projection 分别提供以下状态，Renderer 只派生展示标签。

| 状态轴           | 值                                                    | 含义                                            |
| ---------------- | ----------------------------------------------------- | ----------------------------------------------- |
| Task lifecycle   | `active / archived / deleting`                        | Task 记录本身是否参与日常工作                   |
| Active Run phase | `none / queued / running / waiting_user / stopping`   | 唯一 non-terminal Run 是否需要调度、工作或等待  |
| Last Run outcome | `none / completed / cancelled / failed / interrupted` | 最近一次 terminal Run 的结果，不关闭 Task       |
| View sync        | `ready / syncing / failed`                            | Renderer 是否拥有可安全 mutation 的最新投影视图 |

`draft` 是进入 Workbench 后、尚未创建真实 Task 的 Renderer 临时页面，不进入 Host Task lifecycle。它可以在 Workspace 尚未选择时暂存，但发送前必须同时确定 Workspace grant 与默认执行配置。一次执行完成后 `Active Run phase` 回到 `none`，`Last Run outcome` 保留结果。

Execution binding availability 是下一次 admission 的独立前置事实，不得塞入上述四个状态轴或改写最近一次 Run 结果。Host projection 只发布 `available / rebind_required / unavailable` 及脱敏原因；Renderer 不根据当前默认模型自行判断能否继续。

### 6.3 展示标签与优先级

| 条件                                  | English UI           | 中文 UI      | 主要动作                    |
| ------------------------------------- | -------------------- | ------------ | --------------------------- |
| draft page                            | New task             | 新建任务     | 输入并发送                  |
| view sync = failed                    | View unavailable     | 视图暂不可用 | 重试同步，禁止危险 mutation |
| run phase = waiting_user              | Needs your attention | 需要你处理   | 回答、批准、拒绝或停止      |
| run phase = stopping                  | Stopping             | 正在停止     | 等待真实结果                |
| run phase = running                   | Working              | 正在工作     | 草拟下一条指令或停止        |
| run phase = queued                    | Queued               | 排队中       | 撤回或停止                  |
| no active Run + outcome = completed   | Completed            | 已完成       | 继续输入、打开结果          |
| no active Run + outcome = cancelled   | Stopped              | 已停止       | 继续输入或重试              |
| no active Run + outcome = failed      | Failed               | 失败         | 修复问题、重试或继续        |
| no active Run + outcome = interrupted | Interrupted          | 意外中断     | 查看说明并明确继续          |

表格按优先级匹配。`Completed` 等 terminal 标签只描述最近一次执行；归档状态由独立标记表达，不得覆盖需要处理或正在停止的运行状态。

没有 active Run 且 execution binding 为 `rebind_required` 或 `unavailable` 时，左栏仍保留最近一次 Run 的 outcome；Composer 区域另外显示 `需要确认执行配置` 或 `当前无法继续`。不得用 binding 问题把历史结果改标成 Failed，也不得继续显示可发送输入造成错误暗示。

### 6.4 跨重启历史与 execution rebind

> Capability：**目标**。显式 rebind 还依赖 Workbench Task persistence、可验证的 execution binding 恢复，以及已经单独通过验收的 Conversation 恢复或重建能力；当前 baseline 不显示“继续此 Task”。

历史 Task 跨 Host 进程恢复时遵循以下规则：

1. 先恢复可浏览的消息、Run 结果和不含 secret 的 execution binding descriptor；不得把当前默认配置静默写入历史 Task；
2. 只有 Host 证明已恢复的 account/profile、API、model 和 generation 与 Task 当前 binding epoch 精确一致，并且 Conversation 可安全恢复时，binding 才是 `available`；
3. 原 binding epoch 无法精确恢复时，Task 进入 `rebind_required`，Composer 保持只读并显示旧配置与拟采用配置的脱敏差异；当前默认配置是否不同不单独决定 binding availability；
4. 用户点击 `使用当前配置继续` 后，Host 重新校验 Workspace、account/profile、API→model 归属与当前 generation，在没有 non-terminal Run 时原子创建新的 binding epoch 和新的 Agent Session；
5. 时间线记录一条不可改写的 `执行配置已更改` 边界事件，显示旧/新 API、Provider、model 与 generation 事实；旧 Run、usage 和模型归属保持原样；
6. 用户可以取消 rebind 并继续只读浏览，或选择 `从此历史新建任务`。rebind 失败不得回退到静默默认值。

当前 ABI 不提供跨进程 Conversation 恢复，当前 baseline 也不承诺跨 Host Task history。若只读 Task persistence 先行落地，Host/Core 退出后的历史 Task 只能浏览并提供 `从此历史新建任务`；即使原 execution generation 恰好仍可恢复，也不得因此伪造原 Conversation 可以继续。

## 7. 中间区域：工作叙事

> Capability：**混合**。文本、工具活动、问题/permission、Run 状态和真实 usage 属于当前 ABI；Plan、plan approval、typed Outputs 与 FileChange 属于未来 capability，并在对应小节保持隐藏。

### 7.1 内容模型

中间区域是单列、可阅读、可追溯的工作时间线，不采用双方头像聊天布局。内容类型固定为：

1. 用户指令；
2. Agent 回复；
3. 工作活动；
4. 计划变化；
5. 需要用户处理；
6. 结果与文件；
7. 少量系统状态。

### 7.2 用户指令

- 使用全宽或正文宽度内的“任务指令”区块，与工作轨迹对齐；不使用靠右聊天气泡或双方头像布局；
- 首条指令建立 Task 目标，后续指令作为明确的补充或重试节点；普通界面不显示 Run ID；
- 附件以文件/目录 chip 展示名称、数量和大小；
- 已发送内容不能静默编辑历史；
- 未来的“编辑并重新运行”必须显式创建新的执行分支或新 Task。

### 7.3 Agent 回复

- 不使用头像和大气泡，使用正文排版；
- 支持 Markdown、表格、代码、引用和链接；
- 流式生成只显示克制的末尾活动指示；
- 不展示原始 chain-of-thought；
- 只显示用户可验证的活动，如 Scanning files、Comparing totals、Creating workbook；
- 无法确定具体活动时显示 `Working…`，不得编造步骤或百分比。
- Assistant 正文、活动和最终交付共享同一工作轨迹，但通过排版角色区分；不得为每条内容重复“Agent”标签或品牌头像。

### 7.4 工具活动

所有工具调用必须可见，但成功的细碎活动可以归并：

```text
✓ Prepared invoice data                              18s
  Read 24 PDF files
  Extracted invoice fields
  Grouped entries by project

  Show details
```

默认展开规则：

- 运行中：展示当前步骤和真实进度；
- 成功：折叠为摘要；
- 失败：自动展开错误；
- 被拒绝：展示拒绝结果；
- 命中持久权限：展示对应规则；
- 输出过长：展示摘要和查看详情入口。

Read 详情显示真实文件范围；Bash 详情显示实际执行命令、工作目录、有界 stdout/stderr、exit code 和耗时；Edit 详情显示新增、修改、删除和 diff；MCP/连接器主标题使用用户可理解的动作，原始 operation 名称进入技术详情。

“实际执行”不等于把秘密原样塞进 snapshot。Provider credential、Host-held token 和 schema 标记的 secret 字段永远不得进入工具详情；Host 在形成产品 projection 前完成过滤，并对命令与 stdout/stderr 提供明确的 byte 上限和 truncation 标记。任意工具输出可能包含 Host 无法可靠识别的用户数据，因此普通搜索、Task 导出和系统通知默认不索引原始详情；Renderer 不保存另一份未过滤副本。

### 7.5 计划

- 完整计划主要显示在 Inspector；
- 时间线只保留 `Plan created`、`Plan updated` 等关键变化；
- 点击后可以查看当时的计划版本；
- 旧计划不能被新计划静默覆盖；
- 没有结构化计划时不显示虚假的 `2 / 5`。

### 7.6 系统状态

系统状态使用低权重的全宽分隔行，不伪装成 Agent 消息：

```text
──────── Task stopped by you · 14:32 ────────
──────── Task interrupted unexpectedly ──────
```

正常 Renderer reload 和成功同步不进入时间线；只有同步失败或内容可能不完整时才提示。

### 7.7 滚动与密度

- 用户位于底部时自动跟随最新内容；
- 用户向上查看历史时停止自动滚动；
- 出现 `Jump to latest`，不能强制抢回滚动位置；
- 流式更新不能破坏文本选择、输入焦点或当前阅读位置；
- 长 Task 按日期使用轻量分隔；
- 详细工具输入、stdout/stderr 和 diff 使用按需展开；若未来提供 `标准 / 详细` 显示密度，只能改变信息展开程度，不改变 Agent 行为。当前没有足够必要性时不提前增加模式开关。

## 8. Composer 与执行控制

> Capability：**混合**。当前 Run gate、停止、本地草稿、New task 主视觉、默认模型选择和既有 Task execution binding 提示已经由当前 Renderer 合同表达；跨重启恢复与显式 rebind 仍是目标能力。

Composer 固定在中间区域底部，但必须为滚动内容预留空间。

New task 页面以 Composer 为绝对主视觉。输入框附近只放与“这次 Task 如何开始”直接相关的上下文：模型、Workspace、附件（能力真实接通后）和发送。API Key、账号目录刷新、权限默认值、显示密度与诊断不得堆入同一行。

```text
┌────────────────────────────────────────────────────┐
│ 描述你希望 MetaWork 完成什么……                   │
│                                                    │
│ 模型：当前模型 ▾                              发送 │
└────────────────────────────────────────────────────┘
  Workspace：metawork ▾
```

模型选择规则：

- New task 始终显示当前默认模型；点击后只列出当前 API 的 Host-validated 模型目录；
- 弹层顶部可以低权重显示当前 API 的脱敏名称与 Provider，并提供 `账号与模型设置…`；不得显示完整 secret；
- 模型选择更新 Account 默认 execution generation，默认只影响之后创建的 Task，不自动修改已有 Task；历史 Task 只有 §6.4 的显式 rebind 可以采用该默认值；
- 已有 Task 的 Composer 显示当前 binding epoch 的模型事实，历史按 epoch 保留原模型；第一版不提供 live Session 热切换；
- 正在更新默认模型时只禁用相关选择和发送 admission，不冻结导航、历史阅读或其他 Task；
- 模型不可用时说明原因并给出刷新或设置入口，不能留下永久 disabled selector。

Composer 布局与输入规则：

- 模型控件位于输入框内部左下角，发送位于右下角；Workspace 是紧贴输入框下方的独立全宽 rail，不能再放回输入框上方形成第二条上下文栏；
- New task 的 Workspace rail 可以切换已授权 Workspace，也可以打开原生目录选择器添加或重新授权；已有 Task 只显示其绑定 Workspace 事实，不提供虚假的切换；
- 输入框不允许用户拖拽改变大小。它随内容自动增高，达到约 7–8 行或视口高度的 28% 后改为内部滚动；
- Workspace 缺失或授权失效时文本仍可编辑、草稿仍保存，但发送保持禁用并在 rail 中提供明确恢复动作；Workspace 选择和发送是两个独立动作。

| Task state           | Composer behavior                                                         |
| -------------------- | ------------------------------------------------------------------------- |
| draft / idle         | 文本、附件、发送                                                          |
| queued               | 显示排队状态和撤回/停止                                                   |
| running              | 显示当前活动、耗时和停止按钮；允许草拟下一条指令但禁止发送                |
| waiting_user         | 普通输入让位于时间线请求，底部提示 `Respond above to continue` 并保留停止 |
| stopping             | 禁用输入，显示 `Stopping…`                                                |
| failed / interrupted | 恢复输入，提供针对性的重试或继续动作                                      |

表中的 `idle` 仍受 execution binding availability 约束；`rebind_required / unavailable` 时以 §6.4 的只读说明和动作替代发送控件。

输入区中的模式选择只有在语义明确时才出现。`Standard` 不能作为无定义装饰；模型、权限策略、执行强度和显示密度不能混成一个模式。

运行中的输入不会发送给当前 Run，也不使用未验证的 `UiBackend.poll()` 模拟实时 steering。首版 Composer 只保存 Renderer 本地草稿，发送动作保持禁用并显示 `当前任务结束后发送`；当前 Run terminal 后由用户明确发送。不得自动提交、自动启动下一次 Run，或把草稿伪装成已排队状态。`queued` 只表示唯一已提交 Run 正在等待 Host executor，不表示当前 Run 后面还有另一条队列。未来只有在 AgentCore 发布 typed steering capability 后，才设计 `排队补充` 与 `立即打断` 的不同操作。

## 9. 审批、问题与计划确认

> Capability：**混合**。Question 与 tool permission 属于当前 ABI；Plan approval 和其他 typed request 必须等 AgentCore 发布对应 capability。

### 9.1 请求类型

以下请求使用不同语义和组件：

- Tool permission：`Deny / Allow once / Always allow…`；
- Question：选项或文本回答，使用 `Continue`；
- Plan approval：`Request changes / Start work`；
- 应用级危险操作：使用原生确认窗口或应用级 sheet。

普通请求使用时间线内联卡片。左栏和 Inspector 只负责提醒，点击后跳转到原请求，不在多个位置重复生成可操作按钮。

### 9.2 请求状态

请求响应后仍留在时间线中：

- Waiting for your approval；
- Sending your decision；
- Allowed once；
- Allowed by saved permission；
- Denied；
- Expired；
- Cancelled because the task stopped；
- No longer available。

用户点击后立即禁用重复操作，但只有 Host 确认接受后才能显示最终决定。Renderer reload 后必须从 Host 状态恢复，过期请求不能重新变成可操作状态。

危险批准不能由裸 Enter 触发；开放问题可以使用 `Cmd/Ctrl + Enter` 提交。

## 10. 持久权限

> Capability：**未来**。Host-owned 持久权限、strict Workspace security 和对应恢复/撤销合同尚未验收，本章控件当前必须全部隐藏。

### 10.1 基本原则

MetaWork 支持永久权限，但“永久”表示直到用户撤销，并且必须形成范围明确、可审计的 Host-owned 规则。

审批卡片提供：

```text
Deny    Allow once    Always allow…
```

点击 `Always allow…` 后显示实际作用域，不能直接永久放行所有操作。

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

每个 Workspace 提供 `Workspace settings > Permissions`，全局设置也可以按 Workspace 查看全部规则。每条规则显示：

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

## 11. 按需 Inspector

> Capability：**混合**。按需 Inspector shell，以及 Needs your attention、Current activity / Last run、Tools and connections 与真实 usage 已进入当前实现；Plan 与 Outputs 仍是未来项。

Inspector 是当前 Task 的按需结构化摘要与详情面板，不是固定存在的第三栏、第二份聊天记录或日志面板。New task、无 Task 和没有有效模块的普通 idle Task 默认不占用右侧列宽。模块变为可用不等于自动打开面板：普通 Current activity、usage 和工具活动只更新入口或已打开面板，不能在 Run 开始时挤压正文。

用户通过已有 Task 内容标题区右侧的 Inspector 按钮稳定打开或关闭面板；工具卡、diff、结果和 usage 的 `查看详情` 是直接打开并定位具体模块的上下文入口。两类入口控制同一个 Inspector 状态，不建立第二套详情面板。

出现内容时模块优先级为：

1. Needs your attention；
2. Current activity / Last run summary；
3. Plan；
4. Outputs；
5. Tools and connections；
6. Context and usage。

规则：

- 空模块隐藏；
- 需要用户处理始终置顶；
- Current activity 显示此刻可观察动作，不复制完整工具输出；
- Run terminal 后，已经打开的 Inspector 用真实 outcome、状态和 usage 转为 Last run summary；只有 Host 发布 typed Run duration 时才显示总耗时，当前不得从 Renderer 时钟猜测；不得因为 Current activity 消失而清空内容；
- Plan 只消费真实结构化计划；
- Outputs 只显示用户关心的交付结果；
- Tools and connections 只显示本次实际使用的能力；
- Context and usage 显示真实 usage、预算、压缩或警告，不显示伪百分比；
- 用户从工具卡、diff、结果或 usage 主动打开详情后，Inspector 在当前 Task 内保持打开，直到用户主动关闭；切换 Task 时显示目标 Task 自己的会话内状态，返回原 Task 时恢复其状态；Run 进入 terminal 不自动收起，也不回收 304 px 列宽；
- 只有新的 `Needs your attention` 请求可以对当前 Task 自动打开 Inspector 一次，且不能抢走时间线审批卡的键盘焦点；普通运行开始、usage 更新、工具开始或 terminal 都不得自动切换显隐；
- 切换 Task 是允许重新决定布局的显式边界：新 Task 使用自己的会话内显隐状态和内容，绝不能短暂显示前一个 Task 的详情；窄窗口自动打开时使用覆盖层，不触发中栏重排；
- Inspector 折叠不影响通知、审批或 Task 状态；
- 同一可操作审批只在时间线卡片中提供按钮，Inspector 只能提醒并定位，不能复制第二套操作。

当前 ABI v1 下只有 Needs your attention、Current activity、Tools and connections、Context and usage 在有真实数据时可出现。Plan 和 Outputs 不渲染空壳、占位符或“即将推出”模块；不能为了维持三栏布局而常驻 `当前没有打开的任务`。

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

- Workspace 名称；
- Task 标题；
- 用户指令与 Agent 完成消息；
- Output 文件名。

工具原始日志和 stdout/stderr 不进入全局搜索。用户只能在已经打开的工具详情中搜索当前已加载内容；当前不提供 `Detailed/Advanced` 全局搜索模式。

### 13.2 后台通知

只为需要行动或阶段性结果发送系统通知：

- Task 需要用户处理；
- Task 完成；
- Task 失败或中断。

不为每次工具调用和文本增量发送通知。同一待处理请求只通知一次；点击通知打开对应 Task 和请求卡片。

系统通知默认只显示 Task 标题和状态，不包含命令、路径、用户内容、Agent 输出或审批 payload；设置中允许进一步隐藏 Task 标题。锁屏可见内容遵循操作系统通知隐私设置。

## 14. 首次启动与设置

> Capability：**混合**。当前 Renderer 合同已提供登录优先、正式 settings route，以及设置与 New task 共用的 Host-owned 默认 API/模型选择；跨重启 execution rebind 仍按独立 capability gate 验收。

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

首次启动不显示四步进度条，不要求用户点击“加载 API Key”，不出现 C1/C2、Provider target、generation 或 Keychain 等技术术语。后台准备超过正常感知时长时说明正在等待什么，但不伪造百分比。OAuth 已成功而目录准备失败时必须保持已登录 identity，提供 `重试` 或 Host-owned `在 Metask 中管理`，不能退回未登录文案。

冷启动恢复期间使用稳定的品牌与恢复状态，不先渲染一套全部 disabled 的 Workbench。恢复确认 `signed_out` 后显示登录；确认 `execution_ready` 后直接进入 Workbench；确认 `account_only` 后继续目录准备。

### 14.2 设置结构

```text
General
└── Language

Account & models
├── Metask identity and connection status
├── API catalog and default API
├── Default model
├── Refresh / reauthenticate
└── Sign out and clear this device
```

设置是正式的单一页面或应用内 route，不用狭窄 popover 承载目录选择、错误恢复和危险退出。设置属于全局应用上下文，进入后不显示 Workspace/Task 左栏，也不改变离开前的 Workspace/Task 选中状态；统一标题栏和页面内 `返回工作台` 是返回入口。左下角用户菜单只负责打开对应页面和少量直接动作。

设置树只列当前阶段已经完整设计并通过 capability gate 的项目。显示密度不作为设置；`Appearance` 只有在第二套主题完成设计、可访问性和平台验收后才能加入，首个浅色版本不显示空入口。

`Account & models` 规则：

- API 列表显示 Metask 名称、Provider、尾号和可用/需要处理状态；不显示完整 secret；
- 切换默认 API 后加载其模型目录，并明确它只更新默认选择、不自动改绑已有 Task；符合 §6.4 条件的历史 Task 仍需单独确认 rebind；
- 默认模型选择与 New task Composer 使用同一 Host-owned selection，不维护两份互相漂移的 Renderer preference；
- 既有 Task 显示当前 binding epoch 的 API/Provider/模型，旧 epoch 历史不被设置变化或 rebind 改写；
- 跨重启历史 Task 的绑定不可恢复时，设置变化也不能使其静默采用当前默认值；只按 §6.4 提供显式 rebind 或从历史新建 Task；
- `在 Metask 中管理` 只有在 Host 发布固定安全入口后才显示；当前没有该 capability 时不放置链接或假入口；
- 退出登录必须说明 live Task 阻塞、设备凭据清理和历史保留语义。

技能、连接器、定时任务和 IM 频道只有在真实接通并形成清晰产品 owner 后才进入导航；未接通时不放置假入口，也不照搬其他 Agent 产品的信息架构。

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

> Capability：**当前**。本章定义已显示登录、Workbench 与设置界面的视觉验收基线；它不授权显示尚未通过 capability gate 的数据或控件，具体人工证据仍由验证矩阵记录。

### 16.1 视觉方向

MetaWork 采用安静、精确、长时间可读的桌面工具方向。视觉个性来自工作轨迹、信息密度转换和本地执行语义，而不是暖米色加通用衬线、巨大品牌空态、吉祥物、渐变或每块内容一张圆角卡片。外部参考只用于判断主次关系，不能复制品牌字形、导航结构、输入框比例、图标或配色。

初始核心色板如下；状态图标、焦点、文字和控件组合在实现前必须完成 WCAG 对比度校验，必要时调整：

| Token              | Value     | Role                   |
| ------------------ | --------- | ---------------------- |
| `ink-primary`      | `#17212B` | 主文字与标题           |
| `ink-secondary`    | `#52606D` | 次级文字               |
| `surface-app`      | `#F3F5F7` | 应用背景               |
| `surface-work`     | `#FFFFFF` | 中央工作面与浮层       |
| `action-primary`   | `#176C7A` | 主操作、选择与键盘焦点 |
| `status-success`   | `#2C7651` | 明确成功               |
| `status-attention` | `#A85D00` | 等待用户或警告         |
| `status-danger`    | `#B34444` | 失败、危险和删除       |

主操作色不能同时代表运行、成功或选中；成功、等待和危险使用独立语义，并始终配合文字或图标。正常完成不需要大面积绿色庆祝。

组件层级依靠排版、间距、背景层次和分隔线建立。圆角只服务输入区、弹层和需要形成边界的交互组；普通消息、活动和设置项不默认卡片化。阴影只用于真实抬升层。

### 16.2 字体

- 标题：macOS 使用 SF Pro Display，Windows 使用 Segoe UI Variable Display，并在不可用时回退系统 UI；不使用通用 serif 制造空态“高级感”；
- 正文：macOS 使用 SF Pro Text，Windows 使用 Segoe UI；中文分别使用 PingFang SC 和 Microsoft YaHei fallback；默认正文不小于 13 px，主要阅读正文目标为 14–15 px；
- Data：SF Mono、Menlo、Consolas 或系统等宽字体；
- Task、按钮、设置、状态和正文统一使用系统无衬线字体；等宽字体只用于命令、路径、稳定标识和数据；
- 不依赖运行时网络字体。

### 16.3 形态与动效

- 工作轨迹是唯一允许形成强识别度的结构元素：它连接用户指令、Agent 可见活动、决策和交付，但不装饰无真实顺序的内容；
- 圆角服务于交互分组，不让每条信息都变成浮动卡片；
- 阴影只用于 Composer、浮层和真正需要抬升的元素；
- 只让当前运行节点旋转，避免全屏多个 spinner；
- 新 Output 使用轻微淡入和位置过渡；
- 从 New task 到运行 Task 的布局变化使用一次克制过渡：Composer 从中央主视觉落到底部，工作轨迹获得空间；不散布无意义 hover 位移和入场动画；
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
- 3–4 个真实任务示例；
- 当前模型与 Workspace；
- 必要的 trusted Workspace 限制提示。

示例必须与本地工作任务相关，不使用空泛营销分类。没有 Workspace 时可以先输入临时草稿，但发送动作明确引导选择并确认 Workspace；Account 此时已经 ready，不再出现登录 prerequisite。

### 17.3 错误原则

错误说明必须包含：

1. 发生了什么；
2. 哪些结果可能不完整；
3. 用户可以采取什么动作；
4. 技术详情入口。

首次启动 Account 错误必须保留已经完成的 OAuth identity，并提供与失败语义匹配的 `重试`、`重新登录`、`重新打开登录页面`、`取消`、`在 Metask 中管理` 或 `重启应用`。进入 Workbench 后的重认证或目录错误不得清空 Workspace、Task 或草稿。普通异常不能留下无动作 spinner；只有持久化结果不确定等明确 fail-closed 边界可以要求重启。

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
- 首次 signed out：独立登录界面、唯一主动作、键盘可达且不显示 Workspace/Task/Composer；
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
- 当前 API 模型列表、模型切换 pending/error、设置与 Composer 默认值一致；
- 设置页切换默认 API 后加载对应模型，默认只影响新 Task admission，不自动改绑已有 Task；
- 已有 Task 保留当前 execution binding epoch，默认变化不改写历史或 live Session；只有 §6.4 的显式 rebind 可以建立新 epoch；
- Host 重启后历史 Task 先只读恢复；exact-match binding 与 Conversation 均可恢复时才继续，否则显示脱敏差异并要求显式 rebind。当前 baseline 不承诺跨 Host history；若只读 persistence 先行落地则只显示 `从此历史新建任务`；
- API 只在设置中显示脱敏名称、Provider 和尾号；完整 secret 不进入 DOM、snapshot、日志或错误；
- 左下账号入口在窄窗口、长姓名、重认证和 200% text 下仍可用。

### 19.6 内容状态

- 短文本和长文本流；
- 多个成功工具归并；
- Bash 失败和长 stdout/stderr；
- Read 大量文件；
- Edit diff；
- Plan 创建和更新；
- 问题回答、计划确认和 permission；
- Allow once 和 Always allow；
- Output 生成中、完成、失败和缺失；
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
- reduced motion；
- 状态在无颜色条件下仍可识别；
- 长英文、中文和 pseudo-locale 不溢出；
- 已有 Task 的内容标题区 Inspector 按钮可由键盘操作，`打开检查器 / 关闭检查器` 与 `aria-expanded` 始终匹配真实面板状态；
- 普通 Run start/terminal 不改变 Inspector 列宽；新的待处理请求只自动打开一次，terminal 后保留 Last run summary，切换 Task 不泄漏旧详情；
- 左栏折叠、Inspector 关闭或覆盖显示后功能不丢失。

## 20. 工程目录结构

Workbench 的仓库外层、Renderer、Zig `src/`、依赖方向和测试布局单独维护在 [工程结构与所有权](project-structure.md)。

本文档只定义 UI feature 和产品交互；目录方案不得反向改变 Renderer/Host/AgentCore 的产品边界。

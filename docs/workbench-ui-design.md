# MetaWork Workbench UI 设计草案

> 状态：Draft v0.2，供产品与交互评审，不代表当前实现已经具备全部能力  
> 日期：2026-07-17
> 设计基线：设计师提供的 Agent Workbench Windows 视觉稿；macOS 共用内容布局，仅适配原生窗口壳与平台语义

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

MetaWork 是面向本地工作区的桌面 Agent Workbench，不是终端模拟器、聊天应用或完整 IDE。

首次启动也遵循同一命题：用户先选择工作目标并编辑 Task 草稿，账号和执行配置是围绕 Task 自动准备的条件，不形成独立技术配置产品。

界面只需要持续回答四个问题：

1. 当前任务是否仍在工作；
2. 是否正在等待用户决定；
3. 已经完成了什么；
4. 最终产生了什么结果。

技术对象不直接成为产品文案。ABI、Host revision、Run ID、事件连接和原始诊断默认只进入 Advanced Diagnostics。

MetaWork 的视觉记忆点不是装饰性的暖色或衬线字体，而是：

> 中间区域形成可阅读的工作叙事，右侧 Task activity 持续汇总当前活动、计划和结果。

### 2.1 当前 ABI v1 capability profile

当前锁定的 development ABI v1 revision 3 只为以下界面提供可验证数据：

- 文本流、工具开始/进度/结果、Run progress、usage、context warning、auto compact、retry 和 stream done；
- Ask question 与 permission 两类同步用户请求；
- Run 状态、六种终止原因，以及 Session 是否仍可继续。

因此当前产品只显示时间线、工具活动、问题/权限卡片、Current activity 和真实 usage。Plan、plan approval、Outputs、Files changed、持久权限管理和 custom UI 均保持隐藏；它们在本文档中的设计是后续 capability 到位后的产品规范，不是当前实现承诺。Renderer 不解析工具参数、stdout 或普通文本来猜测这些状态。

## 3. 用户可见对象与术语

### 3.1 对象关系

```text
Workspace
└── Task
    ├── User instructions
    ├── Agent responses and work activity
    ├── Current execution
    ├── Decisions and permissions
    └── Outputs
```

- `Workspace` 对用户显示为 `Workspace / 工作区`。
- 产品对象就是 `Task / 任务`；每个 live Task 在当前进程中持有一个内部 Agent `Session`，但 Renderer 合同不暴露 Session 身份。
- `Turn` 和 `Run` 通常不直接命名，用当前活动、排队、停止和结果表达。
- 一项 Task 可以包含多次用户补充和多次执行；停止一次执行不会删除 Task。

Renderer 产品合同固定为 schema v7：snapshot 根节点包含无 secret `account` 与 `tasks`，Account 直接发布 `readiness`、唯一 `primaryAction` 与 `canCancel`；账号命令使用 `metawork.account.*`，Task 命令使用 `metawork.tasks.*`，产品 Task ID 字段使用 `taskId`。该切换不提供旧 schema 兼容别名；Agent 原始事件传输中的 Session route identity 不属于 Renderer 产品模型。

### 3.2 规范术语

`en-US` 文案定义产品语义，`zh-CN` 是首个完整本地化版本。

| English source       | 简体中文     | 使用说明                           |
| -------------------- | ------------ | ---------------------------------- |
| Workspace            | 工作区       | 本地目录和任务归属范围             |
| Task                 | 任务         | 用户可持续补充的工作上下文         |
| New task             | 新建任务     | 不使用 New session                 |
| Task activity        | 任务动态     | 右侧结构化摘要，不称 Monitor       |
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

### 4.1 总体布局

```text
┌──────────────────────────────────────────────────────────────┐
│ Native title bar                                             │
├──────────────┬───────────────────────────────┬───────────────┤
│ Workspace    │ Task timeline                 │ Task activity │
│ Task list    │ Messages / tools / decisions  │ Plan / output │
│              │                               │ Context       │
├──────────────┴───────────────────────────────┴───────────────┤
│                                Composer and execution control │
└──────────────────────────────────────────────────────────────┘
```

默认尺寸：

- 左栏：248 px；
- 右栏：304 px；
- 中间正文推荐最大宽度：760 px；
- 表格、diff、日志和文件预览可以使用中间区域的可用宽度；
- 推荐最小窗口：960 × 680；
- 低于约 1100 px 时优先折叠右栏，更窄时允许折叠左栏。

左右栏折叠状态按用户偏好保存。折叠只改变视图，不改变 Task、审批或运行状态。

### 4.2 窗口模型

首个正式版本采用单主窗口模型：

- 多个 Task 在同一窗口内切换；
- 后台 Task 不因切换而停止；
- 系统通知用于提醒后台 Task 等待用户、完成、失败或中断；
- 多窗口属于后续能力，不进入当前设计范围。

### 4.3 标题栏

Windows 和 macOS 使用同一内容布局，只调整窗口壳：

- macOS 使用系统交通灯并保留左上角安全区域；
- Windows 使用系统或 Native SDK 提供的窗口控制；
- 标题栏包含侧栏切换、搜索、当前 Task 标题和少量全局入口；
- 可点击控件必须排除在窗口拖拽区域之外；
- 不在标题栏放 ABI、Provider、Host mode 等工程状态。

平台文案、路径、快捷键和文件管理器动作按 OS 切换。

## 5. 左栏：Workspace 与 Task

### 5.1 Workspace 切换

左栏顶部显示当前 Workspace：

```text
Invoices
~/Documents/Invoices
```

点击后打开 Workspace 切换器。左栏主体只列出当前 Workspace 的 Task，不同时展开所有 Workspace。

- `New task` 默认使用当前 Workspace；
- 当前没有 Workspace 时先打开原生目录选择器；
- Workspace 切换器支持最近使用、打开新目录和移除入口；
- 每个 Workspace 入口汇总 `Running`、`Needs your attention` 和 `Failed/Interrupted` 数量；当前 Workspace 之外的待处理状态不能只依赖系统通知；
- 点击 Workspace 状态徽标切换到该 Workspace，并优先定位对应分组；系统通知点击后直接定位原 Task 和请求；
- 移除 Workspace 不删除历史 Task 或真实文件，但必须先停止其中所有 non-terminal Run；移除动作撤销未消费 grant，并立即使该 Workspace 的持久权限失效；
- 再次打开历史 Task 时需要重新选择或授权原目录。

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

### 5.3 创建、命名、归档与删除

- 点击 `New task` 只打开空白任务页；第一次发送后才创建真实 Task，避免空记录；
- 标题根据首条用户指令自动生成，用户可以重命名；
- 归档从日常列表隐藏，但保留记录和引用；
- 删除移除 Task 记录，不自动删除 Workspace 中生成或修改的文件；
- 删除确认必须明确说明文件不会被删除；
- queued、running、waiting_user 或 stopping 的 Task 不能归档或删除；必须先停止或明确取消并等待真实 terminal 结果。

## 6. Task 生命周期

### 6.1 核心规则

- 每个 Task 同时最多一次执行；
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

`draft` 是尚未创建真实 Task 的 Renderer 临时页面，不进入 Host Task lifecycle。一次执行完成后 `Active Run phase` 回到 `none`，`Last Run outcome` 保留结果。

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

## 7. 中间区域：工作叙事

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

- 使用浅青色气泡，靠右，最大宽度约 80%；
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

- 完整计划主要显示在右栏；
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
- 提供 `Standard view` 和 `Detailed view`，它们只控制显示密度，不改变 Agent 行为。

## 8. Composer 与执行控制

Composer 固定在中间区域底部，但必须为滚动内容预留空间。

| Task state           | Composer behavior                                                         |
| -------------------- | ------------------------------------------------------------------------- |
| draft / idle         | 文本、附件、发送                                                          |
| queued               | 显示排队状态和撤回/停止                                                   |
| running              | 显示当前活动、耗时和停止按钮；允许草拟下一条指令但禁止发送                |
| waiting_user         | 普通输入让位于时间线请求，底部提示 `Respond above to continue` 并保留停止 |
| stopping             | 禁用输入，显示 `Stopping…`                                                |
| failed / interrupted | 恢复输入，提供针对性的重试或继续动作                                      |

输入区中的模式选择只有在语义明确时才出现。`Standard` 不能作为无定义装饰；模型、权限策略、执行强度和显示密度不能混成一个模式。

运行中的输入不会发送给当前 Run，也不使用未验证的 `UiBackend.poll()` 模拟实时 steering。首版 Composer 只保存 Renderer 本地草稿，发送动作保持禁用并显示 `Send when this run finishes`；当前 Run terminal 后由用户明确发送。不得自动提交、自动启动下一次 Run，或把草稿伪装成已排队状态。`queued` 只表示唯一已提交 Run 正在等待 Host executor，不表示当前 Run 后面还有另一条队列。

## 9. 审批、问题与计划确认

### 9.1 请求类型

以下请求使用不同语义和组件：

- Tool permission：`Deny / Allow once / Always allow…`；
- Question：选项或文本回答，使用 `Continue`；
- Plan approval：`Request changes / Start work`；
- 应用级危险操作：使用原生确认窗口或应用级 sheet。

普通请求使用时间线内联卡片。左栏和右栏只负责提醒，点击后跳转到原请求，不在多个位置重复生成可操作按钮。

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

## 11. 右栏：Task activity

右栏是当前 Task 的结构化摘要，不是第二份聊天记录或日志面板。模块顺序固定为：

1. Needs your attention；
2. Current activity；
3. Plan；
4. Outputs；
5. Tools and connections；
6. Context and usage。

规则：

- 空模块隐藏；
- 需要用户处理始终置顶；
- Current activity 显示此刻可观察动作，不复制完整工具输出；
- Plan 只消费真实结构化计划；
- Outputs 只显示用户关心的交付结果；
- Tools and connections 只显示本次实际使用的能力；
- Context and usage 显示真实 usage、预算、压缩或警告，不显示伪百分比；
- 右栏折叠不影响通知、审批或 Task 状态。

当前 ABI v1 下只有 Needs your attention、Current activity、Tools and connections、Context and usage 在有真实数据时可出现。Plan 和 Outputs 不渲染空壳、占位符或“即将推出”模块。

## 12. 文件变更与结果文件

### 12.1 两类对象

- `Files changed`：Agent 在 Workspace 中新增、修改或删除的全部文件；
- `Outputs`：用户关心的最终交付文件、链接或结构化结果。

右栏默认只列 Outputs，完整 Files changed 进入中间工具活动。不能仅凭“新建文件”自动判断它是 Output；需要 Agent 的结构化标记或用户明确标记。

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

右栏同步更新 Outputs，但不重复整段完成说明。

## 13. 搜索、历史与后台任务

### 13.1 搜索

标题栏提供全局搜索，默认搜索：

- Workspace 名称；
- Task 标题；
- 用户指令与 Agent 完成消息；
- Output 文件名。

工具原始日志和 stdout/stderr 默认不进入普通搜索，可在 Detailed/Advanced 搜索中启用。

### 13.2 后台通知

只为需要行动或阶段性结果发送系统通知：

- Task 需要用户处理；
- Task 完成；
- Task 失败或中断。

不为每次工具调用和文本增量发送通知。同一待处理请求只通知一次；点击通知打开对应 Task 和请求卡片。

系统通知默认只显示 Task 标题和状态，不包含命令、路径、用户内容、Agent 输出或审批 payload；设置中允许进一步隐藏 Task 标题。锁屏可见内容遵循操作系统通知隐私设置。

## 14. 首次启动与设置

### 14.1 首次启动

首次启动流程保持短且可恢复：

1. 按系统语言显示界面；
2. 立即进入 Workbench shell 与 New task；没有 Workspace 时，`选择 Workspace` 是唯一主动作；
3. 用户选择并确认 trusted Workspace 后，Composer 获得该 Workspace 的本地草稿；
4. Workspace 已确定但缺少执行配置时，在任务输入附近显示唯一主动作 `使用 Metask 登录`；
5. 浏览器授权后，Host 后台恢复或加载 Key/模型并形成 ExecutionConfig；
6. 只有真实多选歧义才在原位置请求选择，ready 后直接启用开始任务。

Workspace 选择、草稿和 Account 准备可以并行；没有 ready ExecutionConfig 时不得创建 Task 或发送 Run。Provider credential 只由 Host 读取和持有。Renderer 只显示 `需要登录 / 正在准备 / 需要选择 / 可执行 / 需要处理` 等产品状态，不显示或回传秘密值。

并行不表示多个同等级 CTA：当前缺失 Workspace 时先突出 Workspace；Workspace 已确定后再突出 Account；后台已经进行的另一个条件只显示状态。没有 Key/模型时不显示永久 disabled select，而是说明缺少的对象并提供重试；只有 Host 提供固定管理入口时才显示 `在 Metask 中管理`。

不显示四步 Account 进度条，不要求用户点击“加载 API Key”。等待浏览器期间提供 `重新打开登录页面` 和 `取消登录`；后台准备超过正常感知时长时说明正在等待什么，但不伪造百分比。

### 14.2 设置结构

```text
General
├── Language
├── Appearance
├── Notifications
└── Default detail level

Account
├── Metask identity and connection status
├── Current API Key suffix and model
├── Change execution settings
└── Refresh / reauthenticate / sign out

Workspaces
├── Trusted folders
└── Permissions

Advanced
└── Diagnostics
```

技能、连接器、定时任务和 IM 频道只有在真实接通后才进入导航；未接通时不放置假入口。

## 15. 国际化

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

### 16.1 视觉方向

保留设计稿的暖白侧栏、青绿主操作和深蓝文字，但不能直接引用外部设计稿附带的 Orion 旅游设计系统。正式实现提取为 MetaWork 自己的 token。

初始色板如下，最终实现前必须完成 WCAG 对比度校验，必要时微调色值：

| Token              | Value     | Role               |
| ------------------ | --------- | ------------------ |
| `ink-primary`      | `#1A2F4A` | 主文字与标题       |
| `ink-secondary`    | `#3D5A6E` | 次级文字           |
| `action-teal`      | `#3D7D8A` | 主操作、选择、运行 |
| `action-teal-pale` | `#E8F4F6` | 选中与用户指令背景 |
| `surface-canvas`   | `#FFFFFF` | 中间工作区         |
| `surface-warm`     | `#FAF7F2` | 左栏和轻量分区     |
| `status-success`   | `#278A59` | 明确成功           |
| `status-attention` | `#C77812` | 等待用户或警告     |
| `status-danger`    | `#C64C4C` | 失败、危险和删除   |

青绿不能同时代表运行和成功；成功、等待和危险必须使用独立语义色。

### 16.2 字体

- UI：macOS 使用系统 SF 字体，Windows 使用 Segoe UI；中文分别使用 PingFang SC 和 Microsoft YaHei fallback；
- Data：SF Mono、Menlo、Consolas 或系统等宽字体；
- Display：只在 New task 空状态的大标题中少量使用 `ui-serif`/系统衬线 fallback；
- Task、按钮、监控标题和正文统一使用系统无衬线字体；
- 不依赖运行时网络字体。

### 16.3 形态与动效

- 圆角服务于分组，不让每条信息都变成浮动卡片；
- 阴影只用于 Composer、浮层和真正需要抬升的元素；
- 只让当前运行节点旋转，避免全屏多个 spinner；
- 新 Output 使用轻微淡入和位置过渡；
- 完成状态不使用庆祝动画；
- 尊重 `prefers-reduced-motion`。

首个正式视觉版本只交付浅色主题。颜色结构必须 token 化，但在深色主题完成完整设计和测试前不暴露半成品主题开关。

## 17. 空状态与异常状态

### 17.1 New task

显示：

- 清晰问候或行动标题；
- 一句话说明能做什么；
- Composer；
- 3–4 个真实任务示例；
- 当前 Workspace；
- 必要的 trusted Workspace 限制提示。
- 紧邻 Composer 的 Account readiness；它只显示当前唯一动作或后台状态，不抢占 Task 标题和输入。

示例必须与本地工作任务相关，不使用空泛的营销文案。

### 17.2 错误原则

错误说明必须包含：

1. 发生了什么；
2. 哪些结果可能不完整；
3. 用户可以采取什么动作；
4. 技术详情入口。

Account 错误还必须保留 Workspace 和 New task 草稿，并提供与失败语义匹配的 `重试`、`重新登录`、`重新打开登录页面`、`取消` 或 `重启应用`。普通异常不能留下无动作 spinner；只有持久化结果不确定等明确 fail-closed 边界可以要求重启。

工具失败但 Agent 已恢复时不能把整个 Task 标记为失败。任务级失败才进入左栏 Failed 状态。

### 17.3 当前 baseline 限制

- Renderer reload 只能恢复仍存活 Host 中的视图；
- Host/Core 退出后当前执行显示 Interrupted；
- 不显示伪造的 Resume 或自动重放；
- strict Workspace security 未验证时必须明确限制适用范围；
- async pending、持久化恢复和后台 suspend 只有在真实 capability 存在后才能进入界面。

## 18. 可访问性与键盘

- 所有交互元素具有可见 focus 状态；
- 状态不能只依赖颜色；
- 图标按钮必须提供本地化可访问名称；
- 流式文本不按 token 频率向辅助技术播报，使用节流后的有意义状态；
- 任务完成、失败和待处理请求使用适度的 live region；
- 窄窗口、200% 文本缩放和长英文文案不得导致关键操作不可用；
- 支持 `Cmd/Ctrl + K` 搜索、`Cmd/Ctrl + N` 新建 Task、`Esc` 关闭浮层；
- 危险批准不绑定裸 Enter。

## 19. UI 验收矩阵

### 19.1 视图尺寸

- 1440 × 900；
- 1320 × 812（设计基线）；
- 1100 × 720（右栏折叠边界）；
- 960 × 680（推荐最小窗口）。

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

- 首次 signed out：可选择 Workspace、可编辑草稿、不能启动 Run；
- OAuth 正常完成、浏览器未回调、重新打开、取消和 hard deadline；
- 历史选择命中、唯一 Key/模型自动推进；
- 多 Key、多模型真实选择以及选择期间 reload；
- catalog timeout/有限重试、OAuth exchange 失败、持久化确定失败与结果不确定；
- 无 API Key、无模型以及 Host 未提供管理入口时的可理解恢复文案；
- Bridge invoke timeout 后释放 busy、snapshot resync 后恢复 Host 动作；
- ready 后 Account 降为轻量入口，切换/退出受 execution replacement gate 约束。

### 19.5 内容状态

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

### 19.6 权限规则与失效

- Host 未声明可持久化 capability 时不显示 `Always allow`；
- Workspace identity 改变、移除后重新授权和目录被替换；
- symlink 解析越过授权边界，以及检查/执行间发生目标变化；
- executable resolution、argv、cwd 或 environment policy 变化；
- 项目脚本内容摘要变化；
- tool/MCP identity、version 或 operation 变化；
- 等待期间撤销规则、`Revoke and stop task` 和普通撤销；
- stale、duplicate、expired 和错误 Task/Run/request 响应；
- Renderer reload 后规则命中记录与请求状态从 Host 恢复。

### 19.7 交互与可访问性

- 键盘完整操作；
- focus 不丢失；
- 用户上滚时不强制自动滚动；
- reduced motion；
- 状态在无颜色条件下仍可识别；
- 长英文、中文和 pseudo-locale 不溢出；
- 左右栏折叠后功能不丢失。

## 20. 工程目录结构

Workbench 的仓库外层、Renderer、Zig `src/`、依赖方向、测试布局和渐进迁移单独维护在 [工程目录结构设计草案](project-structure.md)。

本文档只定义 UI feature 和产品交互；目录方案不得反向改变 Renderer/Host/AgentCore 的产品边界。

## 21. 实施顺序建议

本文档不授权立即实现。进入实现阶段后建议按以下顺序：

1. 建立 MetaWork token、三栏响应式骨架和平台标题栏；
2. 完成 New task、Task 列表和 Workspace 切换；
3. 建立状态驱动的 Task timeline 与 Composer；
4. 接入真实文本流和工具活动；
5. 接入同步 UI request；
6. 完成当前 ABI v1 可验证的右栏 Task activity；typed capability 到位后再增加 Output 和文件变更；
7. strict Workspace security 和规则 capability 通过独立验证后，增加持久权限规则及管理入口；
8. 增加国际化、pseudo-locale 和完整 UI 测试；
9. 最后再开放搜索、通知和后续 capability 入口。

任何界面状态都必须由真实 Host/AgentCore 产品投影驱动；不得为了贴合设计稿在 Renderer 内制造第二套协议或猜测 Agent 状态。

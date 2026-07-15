# MetaWork 产品需求

> 状态：v0.2，产品目标保留；当前实现范围收敛为同步 macOS baseline
> 日期：2026-07-15

## 1. 产品定义

MetaWork 是一款桌面端 **Agent Workbench**。它帮助用户在本地工作区中创建和管理 Agent 会话，观察 Agent 推理后的可见工作过程，处理工具审批，并查看最终结果。

MetaWork 的核心不是模拟终端，而是把 Agent 工作表达为结构化的产品界面：消息、工具卡片、审批、任务状态、文件变更、错误和工作产物。

## 2. 产品目标

- 提供清晰、稳定的桌面 Agent 工作入口；
- 支持一个或多个工作区及其会话；
- 以结构化 UI 展示 Agent 文本、工具调用、进度、审批和结果；
- 允许多个会话独立运行和切换；
- 在取消、刷新、关闭和异常后给出明确且可信的状态；
- 为未来的后台任务、持久化恢复、通知和多 Agent 协作保留合理产品边界。

## 3. 非目标

MetaWork 当前不定义为：

- 完整 IDE；
- Terminal Emulator；
- cc-zig CLI 的图形化字符镜像；
- 远程 Agent 托管平台；
- `.native` UI 迁移项目；
- 同时维护 React 和 `.native` 两套 Renderer 的产品。

终端能力未来可以作为一个明确的工具视图存在，但不构成 AgentCore 与 UI 的基础协议。

## 4. 核心对象

### Workspace

代表 Agent 工作所针对的本地目录和权限范围。Workspace 最终应成为文件访问、工具执行和会话归属的安全边界。当前同步 baseline 只在临时或用户明确 trusted 的 Workspace 中验证，不能据此宣称 strict Workspace security 已完成。

### Session

代表一条可持续的 Agent 对话和工作上下文。Session 归属于 Workspace，拥有自己的消息、运行状态和当前进程内的 Conversation。跨进程持久化恢复属于后续能力。

### Turn / Run

Turn 是用户提交的一次交互；Run 是 AgentCore 为该交互进行的一次实际运行。产品必须区分排队、运行、同步等待用户、已完成、已取消、失败和中断等状态。`max_turns`、`tool_loop`、`budget` 等受控停止不得伪装成完成或笼统失败。

未来具备相应 AgentCore capability 后，再加入可恢复 `suspended`、持久化恢复和后台转换状态。

### Tool Call

代表 Agent 发起的一次工具调用，包含工具名、输入、进度、结果、错误和耗时。Tool Call 应通过结构化卡片展示，而不是依赖终端字符解析。

### Approval / UI Request

代表 Agent 继续工作前需要用户作出的选择，包括工具 permission、问题回答、计划审批和自定义结构化交互。当前 ABI v1 baseline 使用同步 request/response；等待期间 Run 仍占用 executor slot，不形成可持久化挂起点。

## 5. 产品功能需求

以下是目标产品需求，不代表当前 ABI v1 baseline 已全部实现。

### 5.1 工作区

- 用户可以选择并打开本地 Workspace；
- Host 校验并保存 Workspace 的规范路径；
- 文件和工具能力最终必须受 Workspace 与显式权限约束；
- UI 能显示当前会话所属 Workspace；
- strict Workspace security 未验证前，产品必须明确限制使用范围，不能制造虚假的安全承诺。

### 5.2 会话

- 用户可以在 Workspace 中创建、切换和关闭 Session；
- 多个 Session 可以同时存在；
- 后台 Session 的运行状态不能因 UI 切换而丢失；
- 每条事件、审批和工具结果必须路由到正确 Session；
- 每个 Session 至多一个 in-flight Run，额外 Run 明确排队或拒绝。

### 5.3 Agent 交互

- 用户可以提交文本输入并启动真实 Agent Run；
- UI 流式显示 assistant 文本；
- UI 展示工具开始、进度、结果、错误和耗时；
- UI 展示 token usage、上下文警告、重试和压缩等可见状态；
- 用户可以取消当前 Run；
- 取消必须等待 AgentCore 给出真实终止结果，不能只在 UI 中停止渲染。

### 5.4 审批与输入

- 工具 permission 默认拒绝，只有明确授权才允许执行；
- 用户可以回答 Agent 问题并批准或拒绝计划；
- 审批和回答必须绑定 Session、Run 和请求标识，拒绝过期或重复响应；
- 同步等待必须支持 deadline、用户取消、Session close 和 Host shutdown 唤醒；
- 同步等待区间发生 Host/Core crash 后，Run 标记 `interrupted`，工具不得自动执行；
- async pending、跨重启恢复和 subagent suspend 只有在 AgentCore 发布明确 capability 后才能进入产品范围。

### 5.5 命令执行

- 普通 shell 命令以非交互子进程执行；
- UI 展示命令、stdout、stderr、exit code、耗时和错误；
- 普通命令不弹出 Terminal 窗口，也不依赖 PTY/ConPTY；
- 当前阶段明确拒绝或限制需要 TTY 的交互式程序。

### 5.6 状态与恢复

- 用户消息、已完成 assistant 消息、工具结果、审批决策和关键 Run 状态应形成可靠状态边界；
- 当前 baseline 的 Renderer reload 只能从仍存活的 Host 恢复视图；
- Host 或 AgentCore 进程退出时，当前同步 Run 标记 `interrupted`，不得伪装完成；
- 崩溃后不得自动重放可能产生副作用的工具；
- 可 checkpoint 的 AgentCore suspend/resume 和跨进程 Conversation 恢复属于后续 capability；
- 成本预算、轮数上限或工具循环熔断后，Session 进入等待用户状态，只有用户明确继续后才创建新 Run。

### 5.7 桌面能力

- 提供窗口与应用生命周期管理；
- 提供受控的文件/目录选择；
- 为通知、更新和系统集成保留明确入口；
- Renderer 只能调用 Host 显式开放的领域命令。

## 6. 非功能需求

### 安全

- Renderer 按不可信调用方处理；
- Host 命令默认拒绝，只开放白名单；
- 校验来源、payload、Workspace、Session 和权限；
- Provider credential 不得进入 Renderer、Bridge、日志、事件或视图 snapshot；
- 文件访问、进程启动和高风险工具最终必须经过能力控制；
- 不向 Renderer 暴露通用任意执行或任意文件接口。

### 可靠性

- 高频事件不能造成无限内存增长；
- 控制事件、工具结果和审批不能静默丢失；
- 单个 Session 的事件不得串入其他 Session；
- Session close 和 Host shutdown 必须等待 Run 与 callback 安全退出；
- 进程模型必须通过故障注入和恢复数据选择。

### 性能

- 文本流应保持可感知的实时性；
- 高频增量允许批量合并，但不得破坏最终内容；
- 大型工具结果应通过有界对象或文件引用展示，避免无限制穿过 WebView Bridge；
- 多会话运行时 UI 应保持响应；
- executor、事件泵和 Bridge 必须同时设置 count、byte 和时间边界。

### 平台

- macOS 是当前 Phase 0A 的优先真实验证平台；
- Windows 是后续 Phase 0B 目标平台，不阻塞 macOS baseline；
- cc-zig Windows 兼容与 Native SDK Windows 可行性分别验证，不能用 macOS 结果替代；
- 对进入验证范围的平台形成可复现的开发构建与可分发包路径。

## 7. 当前交付层级

### 7.1 同步 macOS baseline

当前首先交付：

```text
临时或 trusted Workspace → Session → 用户输入 → 同步 Agent Run
→ 文本流 → built-in Read/Bash/Edit → 同步 permission / UI request
→ 工具结果 → 最终回复 → 取消/关闭 → Renderer reload 视图重建
```

它不包含进程恢复、async suspend/resume、strict Workspace security 或产品 Host tools。

### 7.2 完整 Phase 0A

同步原型通过后，必须完成事件泵数据、生命周期压力测试和同进程/最小 Worker fault-domain spike，才能结束 Phase 0A。

### 7.3 后续产品能力

async pending、持久化恢复、strict Workspace security、正式 Host tools、远程 artifact 发布和 Windows 交付按独立 capability 与阶段推进，不能反向伪装成当前 v1 已具备。

具体验证矩阵见 [Phase 0 验证计划](phase-0-validation.md)。

## 8. 待细化的产品问题

- Workspace 首页、Session 列表和运行中状态的具体信息架构；
- 文件修改、diff 和工作产物的展示方式；
- 后台 Session、通知和任务中心的交互；
- permission 规则的用户级、Workspace 级和 Session 级产品语义；
- Session 删除、归档、导出和搜索；
- 多 Agent、子 Agent 和任务图在 UI 中的呈现；
- TerminalTool 是否进入后续正式产品范围。

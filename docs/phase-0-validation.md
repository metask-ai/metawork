# MetaWork Phase 0 验证计划

> 状态：待执行
> 目标：用最小真实原型验证已选技术栈和关键风险，不在 Phase 0 完成整个产品
> 顺序：Phase 0A 优先完成 macOS 垂直验证；Phase 0B 在其后验证 Windows，不阻塞 0A

## 1. 验证目标

Phase 0 回答以下问题：

1. Native SDK 能否先在 macOS 上稳定承载 React production bundle、双向 Bridge 和桌面生命周期？
2. cc-zig 能否以 `metacodes-core` library 形式完成真实 agent loop？
3. `MetaWorkUiBackend` 能否可靠处理 borrowed 数据、跨线程事件和 WebView 主线程投递？
4. 多 Session 下的事件吞吐、内存和 UI 响应是否可控？
5. 同进程与 Worker 模型的故障域和恢复代价分别是什么？
6. cc-zig 当前可挂起 UI 请求与同步 permission 的恢复语义是否能形成可信产品行为？
7. 每 Session 单 Run、有限 worker 和 allocator 生命周期是否在多 Session 下保持正确？
8. 全部 `StopReason`、Host fatal abort 和当前真实反向控制路径是否能产生可信状态？
9. macOS 基线成立后，Native SDK 与 cc-zig 能否分别在 Windows 上复现构建、运行、Bridge、Shell 和打包能力？

## 2. 最小垂直链路

```text
React 输入
  → Native SDK Bridge
  → Zig Workbench
  → metacodes-core agent_loop
  → cc-zig CoreEvent / UiRequest / RunResult
  → MetaWorkUiBackend 有界事件泵
  → Native SDK Bridge
  → React 结构化渲染
```

模型 Provider SSE 必须止于 cc-zig。React 不接触原始 SSE，也不从终端字符推断 Agent 状态。

## 3. 原型范围

### 必须实现

- 打开一个本地 Workspace；
- 创建和切换 Session；
- 提交一轮真实 Agent 输入；
- 流式显示 `text_chunk`；
- 展示至少一次 `tool_start` / `tool_result`；
- 执行一次非交互 shell 命令并展示 stdout、stderr 和 exit code；
- 处理一次普通工具 permission；
- 处理至少一种可 `.pending` 的 UI 请求并完成 suspend/resume；
- 取消运行并得到真实终态；
- 模拟全部九个 `StopReason` 并得到穷尽、可解释的 Host 状态；
- 同时运行多个 Session；
- Renderer 刷新后恢复保存的 Session 视图；
- 正常关闭 Host 和 AgentCore。

### 不在 Phase 0 实现

- 完整产品视觉系统；
- `.native` Renderer；
- 通用 Desktop Framework 抽象；
- 完整 IDE；
- 默认 PTY/Terminal Emulator；
- 最终数据库和完整迁移体系；
- 生产级自动更新服务；
- 所有多 Agent 和后台任务产品能力。

## 4. 验证矩阵

### 4.1 Native SDK / 平台

以下能力先在 macOS Phase 0A 验证；Phase 0B 再在 Windows 重跑平台相关用例。Windows 失败不阻塞 0A 结论，但阻止项目声明 Windows 或跨平台交付就绪。

- React development server 加载；
- React production assets 加载；
- JavaScript → Zig command；
- Zig → React event；
- 文件/目录选择；
- 窗口创建、关闭和正常退出；
- Bridge 来源与命令白名单；
- Debug 和 Release 构建；
- 可复现的 Windows 分发包；
- 签名和更新路径是否存在明确落地方案。

Native SDK 与 cc-zig Windows 兼容是两条独立验证线，不能用其中一条的成功代替另一条。

### 4.2 cc-zig library

- 以 [AgentCore ABI v1 需求规格](agentcore-abi-v1.md)作为 capability、函数职责和冻结门槛的 source of truth；
- 固定并记录 cc-zig commit；
- 固定精确 Zig toolchain、target、构建模式和 AgentCore API version；
- 由 cc-zig 独立构建和测试版本化 `metacodes-core` library bundle；Phase 0A 允许先写入本地 artifact source，不要求远程发布设施先完成；
- cc-zig 提供不访问实现源码的 artifact-only consumer，证明 bundle 能独立导入、链接和真实调用；
- 本地开发 bundle 使用包含 cc-zig commit 的精确 dev version/build identity；MetaWork 依赖锁同时记录 target、architecture 和 artifact checksum；
- bundle 至少包含 target-specific 静态库、cc-zig-owned public Zig SDK definitions 和 manifest；
- MetaWork 正式应用不使用本地 path dependency、Git source dependency 或源码复制；常规构建期间不访问 cc-zig 实现源码；
- 从 cc-zig 本地构建产物填充 artifact cache，验证 checksum、目标平台选择和重复构建 cache 命中；
- 注入 checksum 不匹配和缺少目标平台 artifact，构建必须明确失败且不回退源码；
- 从 MetaWork 独立消费工程导入 public SDK、链接 AgentCore 库并完成 link/run smoke test；
- 验证 native `pub fn` 不能被误当作 binary export；ABI 不直接暴露 native slice、inferred-tag enum、allocator、error union 或 tagged union；
- ABI facade wire 层使用校验后的固定宽度整数 code、pointer+length、opaque handles、固定布局 structs 和 callback context；bundle SDK 将合法 code 包装为类型化 enum，facade 对内部 `StopReason` 做无 `else` 穷尽映射；
- 进入共享 CI/正规发布前，再验证远程上传、从空 cache 下载以及已填充 cache 的离线重建；该分发设施不阻塞本地 Phase 0A；
- `agent_loop.run()` 真实运行；
- Provider SSE 被 cc-zig 转换为 `CoreEvent`；
- 直接从 bundle SDK 导入 ABI `StopReason`，编译无 `else` 的九变体 switch；同时验证 cc-zig facade 对内部 enum 的穷尽映射；
- 验证 `UiBackend.poll()` 当前是否存在真实生产消费点，不以接口声明或测试桩代替调用链证据；
- 当前基线使用 per-Run `AbortSignal` 完成 stop/cancel；
- 当前基线将生成期 `queue_message` 保存在 Host 有界队列，Run 结束后作为下一 Run 输入；
- 若 Phase 0 选择在 cc-zig 接通 `UiBackend.poll()`，必须单独验证检查点、顺序、所有权和中断优先级后才能启用；
- `UiRequest` / `UiResponse`；
- `RunResult`、error 和 stop reason；
- transcript、`SuspendInfo` 和 `resumeRun`。

同时对照 cc-zig 源码检查 `doc/LIB_API.md` / `doc/CORE_REFERENCE.md`。发现 enum 或签名漂移时记录为依赖缺陷，MetaWork 以固定 commit 的编译器类型为准。

### 4.3 事件泵与所有权

- 每个 borrowed slice 在 `emit()` 返回前深拷贝；
- 工具线程并发调用 `emit()`；
- AgentCore 线程不直接调用 WebView；
- 队列有界且按 Session 公平；
- `text_chunk` 合并后内容逐字节一致；
- `tool_progress` 覆盖旧状态；
- `usage` 累计正确；
- 控制事件在过载下不静默丢失；
- 注入 event copy OOM、控制队列超时和不可恢复 Bridge pipeline failure；
- Host 写入 `fatal_reason` 后触发目标 Run 的 `AbortSignal`，最终状态为 `failed` 而不是 `cancelled`；
- Bridge 失败、Session 关闭和 Host shutdown 不泄漏 owned event；
- 大型工具结果不无限制进入 Bridge。

### 4.4 多 Session

- 至少四个 Session 同时产生文本和工具事件；
- 每个 Session 至多一个 in-flight Run；第二个 Run 明确排队或拒绝；
- Run executor 设置有限并发，超过上限的 Session 排队且 UI 仍可响应；
- event envelope 路由无串台；
- 单 Session 高输出不会饿死其他 Session；
- 取消一个 Session 不影响其他 Session；
- UI 切换不停止后台 Session；
- Session 关闭时清理其队列、请求和运行资源；
- Conversation/session allocator 在多个 Run 间保持有效；run-scoped scratch 释放后不存在 UAF；
- 多个同步 permission 同时等待时只占 worker slot，不阻塞 WebView 主线程，并记录达到 executor 上限后的行为。

### 4.5 UI 请求与恢复

- `ask_question`、`plan_approval` 或 `custom` 返回 `.pending`；
- `agent_loop` 返回 `.suspended` 和 `SuspendInfo`；
- 同一 turn 注入两个 `.pending` 请求：只保留首个挂起点，其他结果为 `ConcurrentSuspendUnsupported`；
- 每个 Run 的 UI 只存在一个 active resumable request；
- subagent 发起可挂起 UI 请求时得到 unsupported/unavailable，父子 Run 均不 hang；
- 保存 transcript + suspend state；
- 重建 Conversation 并 `resumeRun`；
- 过期、重复和错误 Session 的响应被拒绝；
- permission 等待期间模拟 crash 后 Run 变为 `interrupted`；
- crash 后未经新 permission 不执行工具。

### 4.6 Run 生命周期与反向控制

- 穷尽验证 `end_turn`、`max_turns`、`aborted`、`tool_error`、`api_error`、`tool_loop`、`suspended`、`backgrounded`、`budget`；
- `max_turns` / `tool_loop` / `budget` 映射为受控 `stopped` 与 `awaiting_user`，不映射为 completed；
- `aborted` 根据 user cancel、Host shutdown、Host fatal 分别映射为 `cancelled`、`interrupted`、`failed`；
- `backgrounded` 在 clone 与 background spawn 成功前不发布成功状态，失败时前台 Conversation 保留；
- Stop command 绕过普通 FIFO，直接命中正确 Session/Run 的 `AbortSignal`；
- Host Session 输入队列同时设置 count/byte 上限，满载时返回明确错误；
- 当前 Run 结束后，排队消息按确定顺序形成下一 Run 输入；
- 如果启用 `UiBackend.poll()`，追加真实 agent loop 集成测试，而不是只测 backend mock。

### 4.7 Shell 边界

- 普通命令通过隐藏 shell 子进程执行；
- 不启动 Windows Terminal、xterm 或 PTY；
- stdout/stderr/exit code 正确；
- timeout 和 cancel 能终止进程树；
- 超大输出有上限或引用机制；
- TTY-only 程序被拒绝、限制或给出明确错误。

## 5. 故障隔离实验

故障注入必须放在独立测试进程，避免测试 runner 自身被同进程 panic 直接终止。

### 同进程基线

注入 AgentCore/tool fatal crash：

- 记录 Host 是否随进程退出；
- 记录全部 Session 状态损失；
- 记录已持久化状态可以恢复到哪里；
- 将结果明确标记为零进程级隔离基线。

### 单 Worker

注入 Worker fatal crash：

- Host 必须存活；
- 所属 Session 进入明确的 failed/interrupted 状态；
- 不自动重放危险工具；
- 记录 Worker 重启和 Session 恢复时间；
- 记录 Worker 内其他 Session 的影响。

### 决策输出

根据故障影响、恢复时间、资源、吞吐和实现复杂度，选择：

- 同进程正式方案；
- 单 AgentCore Worker；
- 或继续验证每 Session Worker。

Phase 0 不允许仅凭“统一 Zig”或“IPC 麻烦”作出选择。

## 6. Native SDK 退出与降级判据

Native SDK 是已确认选型，但必须可证伪。如果 Phase 0 无法完成以下任一硬能力，应暂停形成更深路径依赖并重新评估桌面框架：

- 稳定加载 React production bundle；
- 可靠完成双向 Bridge 与主线程事件泵；
- 多 Session 高频事件下保持有限内存和可接受 UI 响应；
- 完成文件对话框、窗口生命周期和正常退出；
- 产出可复现 Windows 分发包，并形成明确的签名与更新路径。

重新评估不等于自动切换 Tauri，也不触发 `.native` 迁移。候选方案仍必须满足 React + Zig + cc-zig 的目标边界。

## 7. 完成判据

Phase 0 完成时必须产出：

- Phase 0A：可运行的 macOS 垂直原型；
- Phase 0B：可运行的 Windows 垂直原型和平台差异报告；
- 自动化或可复现的构建与测试命令；
- 事件泵容量、批量窗口和压力数据；
- Run executor 上限、排队策略、allocator 生命周期与同步等待资源数据；
- 九个 `StopReason` 的 Host 映射测试和 cc-zig contract smoke test；
- Phase 0A：cc-zig 产出的可复现本地 `metacodes-core` bundle、精确 build identity、checksum 和 artifact-only consumer 记录；
- Phase 0A：MetaWork 对该 bundle 的 artifact cache、独立 link/run 和端到端消费记录；
- 双方验证过的 library export 语义、build target、bundle layout 和发布规格；
- 进入正规发布时：远程发布、下载校验和离线 cache 记录；
- per-Run AbortSignal、Host fatal side channel、输入队列和 `UiBackend.poll()` 现状报告；
- 同进程与 Worker 故障实验结果；
- permission 与 suspend/resume 恢复记录；
- Native SDK 继续使用或触发重估的明确结论；
- 更新后的 [高层架构](architecture.md)、[AgentCore 集成契约](agentcore-integration.md)与 [AgentCore ABI v1 需求规格](agentcore-abi-v1.md)。

原型“能跑起来”不是完成；关键风险必须有数据、失败语义和可复现验证。

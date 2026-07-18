# MetaWork 架构与目录调整方案

> 状态：正式迁移基线，尚未全部实现
> 日期：2026-07-18
> 适用范围：Zig Native 应用、React Renderer、metacodes AgentCore 集成与自动化构建边界

实施进度：阶段 1、2 与 3 已落地；阶段 4 的 Executor ownership/handoff 纵向切片已落地，RunControl lease、Agent terminal model、schema v5 与 automation build isolation 仍按后续切片推进。

## 1. 目的与决策

本方案收口 MetaWork 当前目录、所有权和生命周期模型。调整的目标不是把文件换个名字，而是让执行、产品状态、传输和 composition 四种责任具有唯一所有者，并让代码依赖与文档描述一致。

本文是目标架构和迁移顺序的规范，不宣称当前代码已经满足目标。在每个阶段落地前，当前代码及对应 source-of-truth 文档仍描述现状；阶段合入时必须同步消除相关冲突。若本文与历史 Gate 报告冲突，历史报告只代表当时实现，不覆盖新的目标决策。

以下决策不再作为开放问题：

- `src/agent/` 是 **MetaWork 自己的 Agent 执行核心**；
- `AgentCore` 专指 metacodes 构建和发布的外部 library bundle；
- 不建立顶层 `agentcore_binding/` 目录；
- Workbench 独占 Task、队列、Executor，以及从 admission 开始就存在的 durable Run record；
- Run record 的 identity 和存储在 admission 时建立，terminal payload 只允许提交一次且提交路径不可失败；
- Agent 只接管已经成功安装 termination control 的真实 Run；
- Bridge 验证和运输数据，不拥有产品真相，也不能直接终止 Run；
- Bridge 的异步 payload 必须 owned，并在 Workbench 产品内存释放前停止 ingress、detach 和 quiesce；
- `app.zig` 是 composition root，不承载 Task、Run 或 Bridge delivery 的业务状态机；
- queued Run 和已进入 Agent 的 Run 使用不同的终止收口路径；
- active termination latch 与 immutable historical result 是两个生命周期，不得混为“重复状态”；
- automation 是否进入产物由 `build.zig` 决定，runtime mode 不能替代 build-graph 隔离。

## 2. 术语

### 2.1 Agent 与 AgentCore

- **Agent**：MetaWork 拥有的执行领域，负责 Runtime、Session、真实 Run、termination、callback 和 event pump；
- **AgentCore**：metacodes 提供的外部 bundle、typed Zig SDK 和 binary ABI；
- MetaWork 的 Agent 内部直接消费 `metacodes_agentcore`，但不复制它的 ABI facade 或发明平行协议。

### 2.2 Task、Session 与 Run

- **Task**：Workbench 拥有的产品对象，保存标题、归档状态、timeline 和 Run 历史；
- **Session**：Agent 内部的执行上下文和 AgentCore Session handle 生命周期；
- **Run**：一次被 Workbench admission 后进入 Agent 的真实执行；
- **queued job**：尚未进入 Agent 的 Workbench 排队记录，不是 Agent Run。

当前不建立可持久化的 `TaskId`/`SessionId` 双身份体系。Task record 持有当前 Agent Session 引用；Agent 只保留路由和 ABI 所需的 opaque identity。只有出现跨进程恢复或独立 Session 持久化需求时，才通过新的设计决策引入双 ID。

### 2.3 Runtime 与 Host

- Native SDK Runtime 使用 `native_runtime`；
- MetaWork Agent Runtime 使用 `agent_runtime`；
- 不使用无修饰的 `runtime` 字段名表达两者之一；
- 禁止含义不明的 `Host` 顶层类型、`src/host/` 目录和 `host` 万能字段；
- `Desktop Host`、`AgentCore host callback` 等已经明确边界的行业术语仍可使用。

## 3. 目标目录

### 3.1 Zig `src/`

```text
src/
├── main.zig
├── app.zig
├── agent.zig
├── agent/
│   ├── runtime.zig
│   ├── session.zig
│   ├── run.zig
│   ├── termination.zig
│   ├── callbacks.zig
│   ├── event_sink.zig
│   └── event_pump.zig
├── workbench.zig
├── workbench/
│   ├── tasks.zig
│   ├── executor.zig
│   ├── projection.zig
│   └── snapshot_writer.zig
├── bridge.zig
└── bridge/
    ├── commands.zig
    ├── handlers.zig
    ├── policy.zig
    ├── delivery.zig
    ├── revision_delivery.zig
    ├── snapshot_delivery.zig
    └── workspace_grant.zig
```

目录树表达目标责任，不要求为了“看起来完整”提前创建空文件。只有当代码已经形成独立不变量和测试边界时才拆文件。

### 3.2 Renderer

```text
frontend/src/
├── app/
├── bridge/
│   ├── client.ts
│   ├── commands.ts
│   ├── contracts.ts
│   ├── decode-contracts.ts
│   ├── connection.ts
│   └── snapshot/
├── workbench/
├── features/
├── components/
├── i18n/
└── styles/
```

`frontend/src/bridge/client.ts` 是访问 `window.zero` 的唯一入口。React component、feature 和 Workbench store 不直接构造 Native command payload。

### 3.3 测试

```text
tests/
├── agent/
├── workbench/
├── bridge/
├── architecture/
└── integration/
    └── lifecycle/
```

现有 `spikes/host-lifecycle` 不能机械改名后整体搬入 `tests/agent/`。它同时覆盖 Agent lifecycle、Workbench Executor、Bridge delivery 和纵向集成，必须按被验证的不变量拆分；在新测试覆盖等价行为前保留原集成套件。

## 4. 模块语义与公开表面

### 4.1 `main.zig`

只负责进程入口：

```zig
const app = @import("metawork_app");

pub fn main(init: @import("std").process.Init) !void {
    return app.run(init);
}
```

`main.zig` 不注册领域 command，不创建 Task，不管理 Agent Session，也不包含大段模块测试。

### 4.2 `app.zig`

负责：

- Native SDK App callbacks、窗口和 platform services；
- 构造 `agent_runtime`、Workbench 和 Bridge；
- 注入 main-loop notification 能力；
- 按规范顺序启动和销毁各组件；
- 选择 build graph 已经编入的 release/development/automation composition。

不负责：

- queued/running 状态转换；
- `RunOutcome` 映射；
- Bridge delivery retry 状态机；
- Task timeline 和 snapshot 内容；
- 直接调用 AgentCore ABI。

### 4.3 `agent.zig` 与 `agent/`

`agent.zig` 只导出 Workbench 和 App 真正需要的最小表面，例如：

- `Runtime`；
- `Session`；
- `RunRequest`；
- `RunControl` / `RunControlLease`；
- `TerminalResult`；
- `Termination`；
- `EventEnvelope` / `OwnedCoreEvent`；
- 明确的 error set。

`agent/` 负责：

- 直接持有 AgentCore Runtime/Session opaque handles；
- 一个 Session 至多一个 active Agent Run；
- 安装 first-writer-wins termination latch；
- 执行同步 AgentCore `session_run`；
- callback identity、deep copy、owner release 和 quiescence；
- 将 SDK-validated CoreEvent 放入 bounded event pump；
- 产出自包含、不可变的 `TerminalResult`；
- 在全部 Session 和 callback 安全退出后销毁 Agent Runtime。

`agent/` 不拥有 Workbench Executor、Task、产品 history、Renderer transport 或 Bridge policy。

### 4.4 `workbench.zig` 与 `workbench/`

Workbench 负责：

- Task 生命周期和产品命令；
- bounded Executor、queue、workers 和 admission；
- queued/starting/running/terminal 产品状态；
- Task close、archive、delete 对 queued/active Run 的协调；
- 将 Agent event 应用到 timeline 和 projection；
- 将 `agent.TerminalResult` 映射并提交为不可变 `RunRecord`；
- pre-execution terminal record；
- bounded snapshot 和 revision。

Workbench 是永久产品历史的唯一所有者。admission 时即创建稳定的 Run record；record 在 non-terminal 阶段允许受锁保护的状态转换，terminal payload 一旦提交便不可变。Session 关闭或销毁后，snapshot 只读取 Workbench record，不得回头查询 Agent Session。

terminal commit 不得临时分配内存或重新按 Task/Run ID 查找可能已经删除的对象。admission 必须预留 record slot 和产品侧固定容量，包括 bounded terminal diagnostic storage；commit 把 Agent result 的 bounded bytes 复制进这块 Workbench-owned storage，随后释放 Agent result。Task delete 在仍有 non-terminal Run 或 worker reference 时只设置 `delete_pending`，不得物理释放 record。

### 4.5 `bridge.zig` 与 `bridge/`

Bridge 负责：

- command identity、payload schema 和 byte limit；
- origin、command 和 builtin policy；
- wire ID、payload 与 schema version 验证；
- command ingress 和 result/event egress；
- generation、ACK/fetch、retention、revision 和 snapshot transport；
- 把 typed transport failure 报告给 Workbench。

Bridge 不保存 Task/Run 真相，不读取 Agent Session，不 import `metacodes_agentcore`，也不直接请求 Agent abort。

所有跨 callback、timer 或异步 delivery 生命周期的数据都必须由 Bridge 自有；同步借用 Workbench snapshot bytes 只能持续到当前调用返回。Bridge shutdown 必须先停止 ingress 和 timer，再 detach Workbench observer 并等待 callback quiescence，之后 Workbench 才能释放产品内存。

## 5. 依赖方向与强制方式

### 5.1 允许的依赖

```text
main
└── app
    ├── agent
    ├── workbench
    │   └── agent
    └── bridge
        └── workbench

agent
└── metacodes_agentcore
```

Native SDK 只由 App 和确实需要 transport/platform 类型的 Bridge 模块消费。Workbench 不依赖 Native SDK；Agent 不依赖 Native SDK、Workbench、Bridge 或 Renderer。

### 5.2 module root 不是自动防火墙

仅创建 `agent.zig`、`workbench.zig`、`bridge.zig` 不会自动禁止相对路径 import。边界通过以下规则共同强制：

1. `build.zig` 注册 `metawork_app`、`metawork_agent`、`metawork_workbench`、`metawork_bridge`；
2. 跨模块只能使用 named import；
3. module root 只导出消费方需要的类型和函数，不得 `pub const projection = projection_impl` 或整包 re-export；
4. `tests/architecture/` 或等价脚本拒绝跨目录相对 import；
5. 只有 `agent/` 和 Agent module root 可以 import `metacodes_agentcore`；
6. Bridge wire DTO 不得返回 AgentCore SDK enum、owner 或 handle。

## 6. Run admission 与原子交接

### 6.1 durable Run record

Workbench 在 admission 时完成所有仍允许失败的产品侧工作：

- 校验 Task、prompt、容量和每 Task 单 non-terminal Run 约束；
- 分配并复制 bounded prompt；
- 取得固定 Run record slot，初始化稳定 identity/generation；
- 预留 terminal scalar fields、timeline/tool 容量和产品侧 diagnostics 上限；
- 创建 worker 可以安全持有的 `RunRef`；
- 只有以上步骤全部成功后才把 record 发布为 `queued`。

Run record 从 `queued` 开始就是 Workbench canonical state。它在 terminal 前是受锁保护的 mutable lifecycle record；terminal payload 是 write-once。不得把“RunRecord 不可变”误读为 queued/running phase 也不能变化。

admission 失败不产生 Run identity，也不留下半初始化 record。admission 成功后，即使 Run 从未进入 Agent，Workbench 也必须为它形成明确 terminal payload。

### 6.2 状态、线性化点与 RunRef

```text
queued     Workbench owns durable record, job and cancellation
   │ worker claims record under Workbench lock/CAS
   ▼
starting   Workbench owns cancel_pending; worker owns a stable RunRef
   │ agent.Session.beginRun() installs Agent termination control
   ▼
running    Agent owns execution termination; Workbench owns product record
   │ agent Run returns immutable TerminalResult
   ▼
terminal   Workbench publishes write-once terminal payload with no allocation
```

`RunRef` 必须在 Task slot 被复用后仍能检测 stale generation，或者通过引用计数阻止 slot 被复用。Task delete、close 或 archive 不得使 worker 手中的 `RunRef` 悬空。

`beginRun()` 成功安装 Agent termination control 是执行所有权的交接点，但跨 Workbench/Agent 两个锁域的取消交接通过以下固定协议完成，而不是依赖“立即”这种没有并发含义的副词：

```zig
const run_ref = workbench.claimQueuedRun(job) orelse return;

const agent_run = session.beginRun(request) catch |err| {
    workbench.commitPreExecutionFailure(run_ref, err); // no allocation, no failure
    return;
};

workbench.lock();
std.debug.assert(run_ref.state() == .starting);
run_ref.publishRunControl(agent_run.control());
run_ref.setState(.running);
const cancel_pending = run_ref.cancelPending();
workbench.unlock();

if (cancel_pending) agent_run.requestTermination(.cancelled);

var result = agent_run.execute();
defer result.deinit();
workbench.commitAgentTerminal(run_ref, &result); // bounded copy, no failure
```

禁止持有 Workbench lock 调用 Agent。锁内只允许状态发布、读取 flag 和复制 thread-safe `RunControl`；`requestTermination()`、`beginRun()` 和 `execute()` 都在锁外调用，避免 lock inversion。

cancel handler 使用同一 Workbench lock：

- 看到 `starting`：只设置 `cancel_pending`；
- 看到 `running`：取得显式 `RunControlLease`，释放 Workbench lock 后请求 termination，最后释放 lease；
- worker 发布 `running` 时在同一临界区读取 `cancel_pending`；
- 因此 cancel 要么被 worker 转发，要么由看到 `running` 的 cancel handler 转发，不存在无人负责的窗口。

重复 termination request 必须幂等。请求与 Run 自然完成的竞态由 Agent first-writer-wins latch/terminalization 和 Workbench write-once terminal payload 共同收口。

`RunControl` 不能指向随 `execute()` 返回而释放的 Run object。它由 Session-lifetime `SessionControlBlock` 和 `run_generation` 组成：natural completion 只把对应 generation 标记为 terminal，不释放 control block；新的 Run 复用 slot 时递增 generation，旧 control 返回 `stale_run`。

Workbench record 在发布 `running` 时持有一个 base control reference。cancel/close/shutdown handler 必须在 Workbench lock 下通过 non-blocking atomic retain 取得 `RunControlLease`，然后释放 Workbench lock，再调用 Agent：

```zig
workbench.lock();
std.debug.assert(run_ref.state() == .running);
const lease = run_ref.tryAcquireControlLease() orelse {
    workbench.unlock();
    return .already_finishing;
};
workbench.unlock();

defer lease.deinit();
_ = lease.requestTermination(.cancelled);
```

`tryAcquireControlLease()` 只允许在 Workbench lock 下确认 record 为 `running` 后调用；`starting` 时 control 未发布不是可接受的空值原因。它只执行不阻塞、不得失败为 allocator error 的 atomic lifetime retain，不得取得 Agent mutex 或执行 Agent 状态转换，因此不违反“持有 Workbench lock 时不调用 Agent 状态机”的锁序规则。在 `running` 前置条件下仍无法取得 lease，只能表示 Agent terminalization 或 Session close 已经禁止新 lease，该路径必须拥有后续 completion；调用方返回幂等的 `already_finishing`，不得伪称 Run 已经 terminal。

terminal publication 可以释放 record 的 base reference，但已经取得的 lease 必须继续保活。Session close 先禁止新 lease，再等待全部 control references 和 callback references 归零，最后才释放 `SessionControlBlock`。禁止在持有 Workbench lock 时等待这些 reference 归零；close 只能在锁外进入 quiescence wait，否则 worker 无法取得 Workbench lock 发布 terminal payload 并释放 record 的 base reference，等待必然死锁。

### 6.3 Agent Run 的 total completion

`beginRun()` 成功后，Agent Run owner 必须恰好调用一次 latch-aware `execute()`。它是唯一公开 completion API：

- Run 处于 `prepared` 且 latch 已有 termination：不进入 AgentCore ABI，直接返回 `TerminalResult`；
- latch 为空：在 Agent lock 下发布 `core_call_in_progress`，随后进入同步 `session_run`；
- Run 已进入 Core 后收到 termination：first-writer-wins 写 latch，并按 ABI 并发合同调用 `session_abort`；
- Run 已 terminal：termination 返回 `already_terminal`；
- generation 不匹配：返回 `stale_run`。

可以存在私有 `finalizeBeforeCoreCall()` helper，但不得暴露第二个 `finishBeforeExecute()` 公共出口。不得在 `beginRun()` 成功后通过普通 error return 丢弃 Run。进程 panic/abort 属于整个同进程 prototype 的 process-fatal failure，不伪造进程内历史；所有可恢复错误必须由 `execute()` 收口进 `TerminalResult`。

只有 `beginRun()` 尚未成功的 job 才由 Workbench 生成 pre-execution terminal payload。成功交接后，Workbench 不得伪造 Agent terminal facts。

### 6.4 no-fail terminal publication

terminal publication 必须构造上不可失败：

- API 接收稳定 `RunRef`，不在 terminal 时重新按 Task/Run ID 查找；
- 不分配、不扩容、不格式化任意长度字符串；
- Agent 返回的 bounded owned diagnostics 复制进 admission 时预留的 Workbench buffer，复制长度有固定上限；
- Workbench 只映射 enum、status code、StopReason 和固定标量；
- terminal payload 使用 compare-and-set 或等价锁内检查只提交一次；
- revision bump 和 waiter notification 不得让 terminal fact 回滚；
- Task 物理删除推迟到 terminal 已提交且 worker/observer references 归零以后。

若 admission 时无法预留所需产品容量，必须在 Run 进入队列前失败。在真实执行已经完成后再报告 OOM，等于制造一个产品历史里不存在的幽灵 Run，不允许。

### 6.5 cancel、close、delete 和 shutdown

| 当前状态 | cancel / Task close 行为 | terminal 来源 | delete 行为 |
| --- | --- | --- | --- |
| `queued` | Workbench 从队列移除 | Workbench pre-execution payload | terminal 后删除或执行 `delete_pending` |
| `starting` | Workbench 设置 `cancel_pending` | begin 失败则 Workbench；成功则 Agent | 设置 `delete_pending`，不得释放 record |
| `running` / `waiting_ui` | 锁内取得 `RunControlLease`，锁外请求 Agent termination | `agent.TerminalResult` | 设置 `delete_pending`，等待 worker/reference 归零 |
| `terminal` | 幂等 no-op 或 stale request error | 已提交 payload | 满足引用条件后物理删除 |

Task close 和 delete 是 Workbench 产品状态转换，不得直接 free Agent Session 或 Run memory。close 先阻止新 admission，再终止 non-terminal Run，最后关闭 Session；delete 在 close 完成后删除产品记录，或记录 `delete_pending` 并在安全点完成。

必须测试 worker claim、cancel、Task close/delete、Workbench shutdown、Agent begin failure、自然完成和重复 terminal commit 的全部交错。

### 6.6 Executor 与关停所有权

- Workbench 创建和销毁 Executor、queue 与 workers；
- Agent 不接收带 `shutdown_fn`/`deinit_fn` 的 Scheduler capability；
- Workbench worker 主动调用 Agent；
- Agent 不能反向 `Scheduler.enqueue()`；
- App 组织关停，但不取得 Executor 或产品 record 所有权。

推荐关停顺序：

1. App/Bridge 停止 command ingress，并取消可能创建新工作的 timer；
2. Workbench 停止 admission；
3. Workbench terminalize queued jobs，并对 starting jobs 设置 termination pending；
4. 对 active Agent Runs 请求 termination，唤醒 UI waits；
5. 等待 Workbench workers 退出，保证所有 Agent `TerminalResult` 已无失败地提交；
6. 关闭 Agent Sessions，等待 AgentCore callback quiescence；
7. Bridge detach Workbench observer，停止并等待所有可能访问 Workbench 的 callback/timer；
8. 销毁 Agent Runtime；
9. 释放 Workbench Executor、Task、Run records 和产品内存；
10. 释放 Bridge-owned delivery buffers，再销毁剩余 App/Native transport resources。

关停必须同时满足两个引用不变量：Agent Runtime 销毁前不存在 worker/callback Session reference；Workbench 产品内存释放前不存在 Bridge callback、timer、worker 或 `RunRef` reference。Bridge 异步 payload 必须 owned，不能靠 teardown 顺序掩盖 borrowed pointer。

## 7. 终止模型与历史结果

### 7.1 active termination latch

`AbortCause` 不是合法名称，因为 callback fatal、ABI failure 和 dependency-contract failure 不一定调用 AgentCore abort。active Agent Run 使用 tagged termination latch：

```zig
pub const TerminationSignal = union(enum) {
    interrupted: ExternalInterruption,
    callback_failure: CallbackFailure,
    event_pump_failure: EventPumpFailure,
    event_consumer_notification_failure: EventConsumerNotificationFailure,
};
```

该 latch 是 first-writer-wins 的可变控制状态，只在 active Run 生命周期内有效。Agent 只知道 bounded event consumer 无法被通知，不知道 Native main loop、Bridge 或 Renderer；App 注入的 notifier 实现可以调用 `notifyMainLoop()`。ABI status failure 和 validated StopReason 可以在同步调用返回时直接进入 terminal result，不必伪装成 abort。

### 7.2 immutable `agent.TerminalResult`

`TerminalResult` 至少保存：

- ABI status 和 raw status code；
- validated StopReason 和 raw reason code；
- termination latch 的最终值；
- `session_disposition_at_completion`，例如 reusable/poisoned/closing；
- 解释终态所需的 owned diagnostics，且受 byte limit 约束。

Workbench admission capacity 与 Agent `max_terminal_diagnostic_bytes` 必须来自同一 composition limit。Agent 在构造 result 时完成 bounded copy/truncation 并记录 truncation flag；因此 Workbench terminal commit 的目标 buffer 必然足够，不能在 commit 时重新决定容量或返回 `DiagnosticTooLarge`。

它不得保存：

- Workbench `RunOutcome`；
- borrowed SDK bytes、callback view、opaque owner 或需要 Session 存活才能读取的数据；
- Renderer/Bridge failure 名称；
- Task title、timeline 或 snapshot 字段。

`session_disposition_at_completion` 是 Run terminal 时刻的不可变结论，不是可持续查询的 Session live state。Workbench 在 commit 时用它更新当前 Task 的可继续状态；历史记录中的值只用于解释当次 Run，后续 close/poison transition 不回写旧结果。

### 7.3 Workbench terminal payload

Workbench 将 Agent terminal facts 映射为产品事实，例如：

- `completed`；
- `stopped`；
- `cancelled`；
- `interrupted`；
- `failed`；
- `dependency_contract_failure`。

Run record 从 admission 开始存在；其中的 terminal payload 在 Run 结束时以 no-fail、write-once 方式发布。发布后不再随 Agent Session snapshot 改写。Workbench 把必要 terminal facts 复制进已经预留的自身存储；这是跨生命周期提交，不是第二份竞争状态，也不把 Agent allocator 生命周期泄漏进产品历史。

queued job 在进入 Agent 前终止时，Workbench 直接填充 pre-execution terminal payload，不得伪造 `agent.TerminalResult`。

## 8. Agent event 合同

Agent event pump 输出：

- route identity；
- run identity；
- SDK-validated、owned 的 CoreEvent；
- 明确的 allocator/deinit 所有权；
- 有界 encoded size 和必要的 sequence metadata。

event 入泵后 ownership 已经转移给 Agent pump。`EventReadyNotifier` 只负责通知 canonical consumer 有数据可取，返回值至少区分 `scheduled`、`already_pending` 和 `unavailable`；notification failure 不得丢弃已经 owned 的 event。Agent 记录的是通用 `event_consumer_notification_failure`，不能把 App 的 `notifyMainLoop()` 实现细节写进 Agent 类型。

notifier 暂时失败时按 bounded retry/deadline 合同处理；只有 canonical Agent→Workbench event consumer 在边界内不可达，才允许 Agent callback 以明确 failure 收口。Renderer/Bridge delivery 不属于这条 canonical notification path。

MetaWork 不建立与 CoreEvent 一一镜像的 `AgentEvent`/`WorkbenchEvent` 协议。`agent.zig` 可以通过 `OwnedCoreEvent` 包装 ownership 和路由，但不重新命名全部 event tags 或复制 payload schema。

Workbench 消费该事件并更新 Task timeline/projection。Bridge 和 Renderer 不接收 raw CoreEvent；它们只消费 Workbench revision 和 snapshot。

unknown CoreEvent 继续遵守 SDK forwards-compatibility 合同：完成 validation 和 owner release，不猜测产品语义，不传给 Renderer。

## 9. Bridge failure 合同

Bridge failure 必须带明确阶段，至少区分：

- ingress validation failure；
- command dispatch failure；
- response delivery failure；
- revision delivery failure；
- snapshot transport/resync failure；
- connection/generation failure。

所有进入异步 delivery、retention、retry timer 或 Native callback 的 payload 必须是 Bridge-owned copy 或显式 ownership transfer。Bridge 不得把 Workbench snapshot slice、Task title、Run diagnostics 等 borrowed view 保存到当前同步调用之外。

处理规则：

- ingress validation failure：拒绝命令，不改变 canonical state；
- command 已提交但 response delivery 失败：不能回滚产品事实，通过 revision/snapshot 恢复；
- revision/snapshot/view-sync failure：保留、重试或 fail-closed Renderer mutation，不终止后台 Run；
- Renderer reload/detach：默认不影响 Run；
- UI interaction 在产品 deadline 内无法完成：Bridge 报告 transport 状态，由 Workbench 决定回答 unavailable 或请求 Agent termination；
- Bridge 永远不直接调用 `agent.requestTermination()` 或等价接口。

Bridge shutdown 分为 `stopIngress`、`detachWorkbench`、`quiesceCallbacks` 和 `deinitOwnedBuffers`。只有前三步完成后 Workbench 才能释放产品内存；owned delivery buffers 可以在随后独立释放。不能把 `Bridge/App transport resources` 混成一个没有引用保证的 teardown 步骤。

因此必须删除 `bridge_pipeline_failure` 这种把 Renderer transport、canonical event notification 和 Agent termination 混为一谈的 cause。App 的 `notifyMainLoop()` 失败按 §8 的 `EventReadyNotifier` 合同进入 generic canonical-consumer notification 路径，不得伪装成 Bridge failure；Renderer delivery failure 则始终由 Workbench 根据操作类型、重试结果和 UI deadline 决定产品影响。

## 10. Task command 与 schema v5

产品公开命令原子迁移到 `metawork.tasks.*`，不保留一半 `sessions.*`、一半 `tasks.*` 的 wire contract：

```text
metawork.tasks.create
metawork.tasks.run
metawork.tasks.cancel
metawork.tasks.respondUi
metawork.tasks.close
metawork.tasks.rename
metawork.tasks.archive
metawork.tasks.delete
```

schema v5 在 Zig serializer、Bridge commands/handlers、Renderer contracts/client、fixtures 和 tests 中一次切换，不提供双写兼容层。

产品语义固定为：

- `tasks.cancel`：终止当前 queued/active Run，Task 保持可继续；
- `tasks.close`：结束 Task，关闭内部 Agent Session，保留 timeline，禁止后续 Run；
- `tasks.archive`：隐藏日常列表，不删除历史；若仍有 non-terminal Run，先按产品规则终止；
- `tasks.delete`：终止 non-terminal Run 后删除产品记录，不删除 Workspace 中的真实文件。

## 11. automation 构建边界

release、development 和 automation 可以共享 App composition 逻辑，但不能共享无条件编译的 fixture command、handler、token 和 worker。

`build.zig` 必须：

1. 读取 `-Dautomation`；
2. 仅在 automation target 中创建并注入 automation module；
3. release module graph 不 import fixture source；
4. product `bridge/commands.zig` 不包含 automation-only command；
5. automation origin、inline source、fixture worker 和 diagnostic token 只存在于 automation artifact。

Renderer 同样需要由 Vite build graph/compile-time constant 裁剪 fixture loader，不能只靠运行时环境变量和“没有调用”。

验收必须扫描 release native binary 和 frontend bundle，确认不存在 automation command、fixture token、automation origin 和 test payload；同时 automation build 仍能通过真实 Native SDK 测试。

## 12. module root 最小公开表面

目标 root 文件不是 barrel dump。以下模式禁止：

```zig
pub const projection = projection_impl;
pub const executor = executor_impl;
pub usingnamespace @import("internal.zig");
```

root 应显式导出稳定消费表面，并让内部模块可以自由重构。测试需要访问内部不变量时，优先把测试放在对应实现文件或为 test build 注入专用入口，不扩大 production API。

## 13. 当前代码与目标差异

| 当前实现 | 目标 |
| --- | --- |
| Workbench 已独占 Executor、queue、workers 与 shutdown；worker 暂调用 transitional `executePreparedRun()` | 进一步收口为 `beginRun()` + 唯一 latch-aware `execute()` |
| `HostCause` 仍混合 interruption、callback 和 contract failure，但已删除 Bridge transport | tagged termination + immutable terminal facts |
| Workbench admission/durable RunRef/no-fail payload 已落地，terminal facts 仍从活 Session snapshot 同步 | Agent `TerminalResult` 直接提交，不回查 Session snapshot |
| Workbench/Bridge 直接 import `metacodes_agentcore` | 只有 Agent 消费 SDK，其他模块通过 Agent/Workbench 公共类型 |
| `sessions.*` 与 `tasks.*` 混用 | schema v5 原子迁移到 `tasks.*` |
| automation handler/token 无条件编入 App source graph | `build.zig` 条件注入 automation module |

## 14. 迁移阶段

每个阶段同时修改代码、测试和受影响的 source-of-truth 文档。禁止先改目录、最后再统一“文档收口”。历史 Gate 报告保留当时术语，不做追溯重写。

### 阶段 1：module boundary 与机械命名

- 建立最小 `agent.zig`、`workbench.zig`、`bridge.zig` 表面；
- `build.zig` 注册 named modules；
- 增加 architecture import tests；
- `agentcore/` → `agent/`，`agentcore.zig` → `agent.zig`；
- `wakeHost()` → `notifyMainLoop()`；
- 变量区分 `native_runtime` 与 `agent_runtime`；
- 本阶段不改变运行行为。

同步更新：`project-structure.md`、`architecture.md`、`agentcore-integration.md`。

### 阶段 2：Workbench durable record foundation

- admission 建立稳定 Run record slot、generation 和 `RunRef`；
- 把仍可能失败的产品分配全部前置到 admission；
- terminal payload 改成无分配、write-once publication；
- Task delete 增加 `delete_pending`/reference quiescence，不允许 worker 指针悬空；
- 暂时仍可从现有 Session snapshot 取得 terminal facts，但写入新 record 的路径必须 no-fail；
- 覆盖 admission OOM、slot exhaustion、stale generation、delete/terminal races。

同步更新：`requirements.md`、`architecture.md`、`agentcore-integration.md`。

### 阶段 3：canonical notification 与 Bridge isolation

- 先把 Agent callback notifier 抽象为 generic `EventReadyNotifier`；在旧 `HostCause` 尚存在期间，notification failure 归入已有 `event_pipeline_failure`，不再冒充 Bridge failure；
- 先删除 App/Bridge 对 `failRun(.bridge_pipeline_failure)` 的全部调用；
- Bridge failure 改为 typed report，由 Workbench policy 决定 command/view/UI 影响；
- 确认 Agent callback 和 App 调用点均不再引用后，从旧 `HostCause` 删除 `bridge_pipeline_failure`，不建立临时 Bridge variant；
- 明确 async delivery payload owned/transfer 规则；
- 实现 `stopIngress`、`detachWorkbench`、`quiesceCallbacks`、`deinitOwnedBuffers`；
- Renderer detach、revision/snapshot failure 不终止后台 Run。

同步更新：`requirements.md`、`architecture.md`、`agentcore-integration.md`、Bridge/Renderer contract 文档。

### 阶段 4：Executor handoff 与 Agent terminal model

- Workbench 完全接管 queue/workers 生命周期；
- 移除 Agent Scheduler ownership 和 `Session.submit()` 反向 enqueue；
- 实现 `RunRef`、queued/starting/running 交接和固定锁协议；
- 禁止持 Workbench lock 调用 Agent；
- 实现 Session-lifetime `SessionControlBlock`、generation-checked `RunControlLease` 和 close quiescence；
- 实现 `beginRun()` 与唯一 latch-aware `execute()` total completion，禁止第二个公共 finish API；
- 拆分 active termination latch、Agent `TerminalResult` 和 Workbench terminal payload；
- 将旧 `event_pipeline_failure` 拆成 callback/event-pump/event-consumer-notification 等 typed failure；
- 删除剩余 `AbortCause`/`HostCause` 混合模型；
- queued cancellation 由 Workbench填充 pre-execution terminal payload；
- Agent terminal result 通过阶段 2 建立的 no-fail commit 路径提交；
- Workbench terminal 后不再依赖 Session snapshot；
- 按 §6.6 冻结跨 Agent/Workbench/Bridge teardown 顺序。

该阶段的 ownership、handoff 和 terminal model 是同一个状态机变更，必须作为一个始终可构建、可测试的纵向提交序列完成；不得保留“新 Executor + 旧 HostCause”或“新 TerminalResult + Agent-owned Scheduler”的批准终态。

同步更新：`requirements.md`、`architecture.md`、`agentcore-integration.md`、`agentcore-abi-v1.md`。

### 阶段 5：CoreEvent 与 SDK dependency boundary

- 只有 Agent import `metacodes_agentcore`；
- Workbench 通过 `agent.OwnedCoreEvent` 消费 canonical event；
- Bridge DTO 不暴露 AgentCore SDK types；
- 完成 `EventReadyNotifier` 的 scheduled/already_pending/unavailable、retry/deadline 和 owned-event tests；
- App 的 `notifyMainLoop()` 实现细节不进入 Agent 类型；
- 增加 owner release、unknown event 和 notification failure tests。

同步更新：`architecture.md`、`agentcore-integration.md`、`agentcore-abi-v1.md`。

### 阶段 6：Task schema v5

- Zig、Renderer、fixtures、tests 原子切换 `tasks.*`；
- 冻结 cancel/close/archive/delete 语义；
- snapshot schema 升级到 v5；
- 不建立 TaskId/SessionId 双写或兼容层。

同步更新：`requirements.md`、`workbench-ui-design.md`、`project-structure.md`。

### 阶段 7：Renderer 与 automation build boundary

- `frontend/src/host/` → `frontend/src/bridge/`；
- 只有 `bridge/client.ts` 访问 `window.zero`；
- Native/Renderer automation fixture 从 release graph 移除；
- 增加 release artifact token scan；
- 保持 automation Native smoke 通过。

同步更新：`project-structure.md`、Gate automation 运行说明；历史报告不改。

### 阶段 8：测试按不变量拆分

- Agent lifecycle/callback/quiescence → `tests/agent/`；
- Executor/admission/shutdown → `tests/workbench/`；
- delivery/generation/ACK/snapshot → `tests/bridge/`；
- 完整纵向竞态 → `tests/integration/lifecycle/`；
- 新套件覆盖等价行为后再删除旧 mixed spike。

## 15. 验收门槛

### 15.1 架构静态检查

- `agent/` 不 import Workbench、Bridge、App 或 Native SDK；
- Workbench/Bridge 不 import `metacodes_agentcore`；
- App 不相对 import 三个领域目录的内部文件；
- module root 不整包 re-export implementation；
- Renderer 只有一个 `window.zero` 访问点；
- release graph 不包含 automation module/token。

### 15.2 必测行为

- admission OOM/容量失败不发布半初始化 Run identity；
- cancel 与 worker claim 竞态；
- cancel 在 `beginRun()` 成功、`running` 发布前后到达时都不会丢失；
- cancel handler 取得 lease 后 Run 自然完成，`requestTermination()` 安全返回而不 UAF；
- Session close 与 control lease acquire/request/release 的全部交错；
- 旧 `run_generation` control 在 slot 复用后返回 `stale_run`；
- Task close 与 `beginRun()` 竞态；
- Task delete 与 worker-held `RunRef`/terminal commit 竞态；
- stale RunRef generation 不得写入复用后的 Task/Run slot；
- Agent `TerminalResult` commit 不分配、不可失败且只发布一次；
- terminal diagnostics 达到上限时在 Agent 侧截断并标记，Workbench commit 不再失败；
- Workbench shutdown 同时存在 queued/running/waiting_ui Run；
- first-writer-wins termination；
- callback fatal、ABI non-OK、invalid RunResult 和 validated StopReason；
- Agent Session 销毁后历史 snapshot 保持完整；
- Bridge response 丢失、Renderer reload 和 snapshot retry exhaustion 不终止后台 Run；
- Bridge shutdown callback/timer quiescence 后才允许 Workbench deinit；
- Bridge async delivery 不保存 Workbench borrowed bytes；
- event consumer notification retry/deadline 不丢失 pump-owned event；
- UI deadline 耗尽由 Workbench 明确决策；
- concurrent close/shutdown 只销毁一次并等待 callback quiescence；
- release/automation 两套 build graph 的能力和 token 隔离。

### 15.3 仓库验证

每个语义阶段至少运行：

```text
npm run format:check
npm run check
npm test
npm run test:phase0a
npm run build:release
```

涉及 macOS Native transport、automation 或 Gate 5/6 行为时，额外运行对应真实应用测试。目录移动但未改变语义时仍必须运行相关 Zig/Renderer contract tests，不能用“只是 rename”跳过 build graph 验证。

## 16. 完成定义

只有同时满足以下条件，调整才算完成：

- 代码目录、named module graph 和文档依赖图一致；
- Workbench 是 queue/Executor/Task/RunRecord 的唯一所有者；
- Agent 是 active Run、termination latch 和 AgentCore handles 的唯一所有者；
- admission 失败不留下 record；admission 成功后始终存在稳定 `RunRef` 和唯一 terminal payload；
- terminal publication 不分配、不可失败且只能成功一次；
- queued termination 与 Agent terminal result 不互相伪造；
- Session 销毁后产品历史仍完整可序列化；
- Bridge failure 不再直接决定 Run 终止；
- Bridge 在 Workbench 释放前完成 ingress stop、detach 和 callback/timer quiescence；
- Agent 类型不包含 Native main-loop、Bridge 或 Renderer failure 名称；
- 只有 Agent 消费 AgentCore SDK；
- schema v5 不混用 `sessions.*`；
- release artifact 不包含 automation-only 能力；
- 拆分后的单元测试和完整纵向生命周期测试全部通过；
- `requirements.md`、`architecture.md`、`project-structure.md`、`agentcore-integration.md` 和 `agentcore-abi-v1.md` 已随相应语义提交同步更新。

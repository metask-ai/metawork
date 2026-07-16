# Phase 0 Gate 4：正式 AgentCore Host 与 bounded test sink 验证报告

> 日期：2026-07-16
> 结果：通过，Gate 5 可以开始
> 平台：macOS arm64

## 1. 实现边界

Gate 4 直接扩展 Gate 2 lifecycle foundation，没有增加 `NativeSdkAdapter`、AgentCore Adapter 或平行协议：

- `src/host/lifecycle.zig` 持有 bundle `sdk.Api`、Runtime/Session handles、bounded executor 和正式 callbacks；
- `src/host/event_sink.zig` 只保存带 Host Session ID/Run ID 的 bundle `ParsedCoreEvent` owner；
- Runtime 的 Host tool table 始终为空；默认 built-in catalog/allowlist 是 Read、Bash、Edit、AskUserQuestion；
- callback 不调用 WebView，Gate 5 前也不进入 Native SDK Bridge；
- 仍只允许临时或用户明确 trusted Workspace，不宣称 strict security。

## 2. Event callback 与 bounded sink

event callback 的固定路径为：

```text
validate Session handle + Run ID
→ validate bytes view and max bytes
→ bundle decodeCoreEvent
→ SDK parse owner deep-copies callback data
→ attach monotonic Host Session ID + Run ID
→ FIFO bounded sink
→ CONTINUE or CALLBACK_FATAL
```

sink 用 ring buffer 保持 FIFO；达到全局 count 上限或单 event bytes 上限时，Host 记录 first-writer `queue_capacity_failure`、释放未入队 parse owner并返回 callback fatal。malformed event 记录 `event_pipeline_failure`。`session_run` 的 non-OK status 随后映射为 failed，不读取 `RunResult`。

当前默认是 256 events、单 event 1 MiB，乘积在 Host 初始化时检查 overflow。这只是 Gate 4 test sink 的显式上限，不是 Gate 5 最终容量：尚无 per-Session quota、公平轮转、control reserve、text merge 或 Bridge batch。

## 3. Status、RunResult 与 StopReason

所有 ABI function status 都先经过 bundle `Status.fromCode`。Run 路径严格执行：

```text
session_run
→ validate Status
→ release diagnostic exactly once
→ non-OK: do not read RunResult
→ OK: validate struct_size and reserved
→ preserve raw stop code
→ StopReason.fromCode
→ exhaustive switch without else
```

unknown status、unknown stop code、invalid result layout、`invalid`、`suspended` 和 `backgrounded` 都形成 `dependency_contract_failure`。`aborted` 再按 first-writer `HostCause` 区分 cancelled、interrupted 或 failed；raw ABI status、abort status 和 stop code仍保留在 Session snapshot。

## 4. 同步 UI

UI callback 使用 bundle `decodeUiRequest`，并在 callback frame 存活期间保存 request owner。Host 复制原始已校验 request 供测试消费者读取，response API 同时校验 Session、Run、request identity 与 response tag：

- stale、duplicate、wrong Run/request 明确拒绝；
- mismatched response 由 bundle request-aware encoder 拒绝；
- response encoder 在 fixed buffer 内执行，默认最大 256 KiB，超限不会先制造无界分配；
- answered buffer 转移给 AgentCore，并由 paired release callback 恰好释放一次；
- 默认 30 秒 deadline 到期返回 unavailable；
- cancel、close 和 shutdown 唤醒 wait；先取得 Session lock 的 response/cancel 形成清晰 linearization point；
- timer future 在 callback 返回前完成或 cancel，不引用已销毁 Session。

等待 UI 仍占用一个 bounded Run executor slot，但 Bridge/main thread 不参与等待。

## 5. Deterministic 与真实 bundle 验证

`spikes/host-lifecycle/` 的 22 个测试覆盖原 Gate 2 lifecycle/race 矩阵，并新增：

- valid/malformed CoreEvent、deep-copy、routing、FIFO 与 sink overflow；
- valid/malformed UI、request copy、stale/duplicate/mismatch、response bytes 上限和 deadline；
- status-before-result、unknown status/stop、invalid layout、suspended/backgrounded；
- RunOutcome 与 HostCause；
- product Host tools 为零、built-in catalog/allowlist；
- OOM、diagnostic release、close/shutdown/callback quiescence。

完整 suite 连续运行 100 次通过。压力过程中曾发现 `waitForState` 把 idle Session 等待 closing 误判为 Run terminal，导致 close thread 悬挂；最终实现只对 queued/running/waiting_ui 使用 Run terminal 的“目标不可达”判定。

artifact-only probe 在同一精确 bundle `0.0.0-dev+ab75314a3dcb` 上额外执行两段真实链路：

1. raw ABI Read/Bash/Edit、UI、abort、lifecycle/release 回归；
2. 正式 Host + Mock Provider 的真实 AskUserQuestion、SDK encoder、typed CoreEvent sink 和 `end_turn → completed`。

probe 有 30 秒进程组 timeout，回归不能退化为 CI hang。

## 6. 可复现命令

```bash
AGENTCORE_BUNDLE_ROOT=/absolute/path/to/agentcore-ab75314 \
  npm run test:phase0a

npm run format:check
npm run check
npm run build:debug
npm run package:macos
```

## 7. 结论与 Gate 5 输入

Gate 4 已证明正式 Host 可以直接消费 typed bundle SDK，并在 bounded test sink 上正确处理真实 callbacks、同步 UI、terminal result 与 lifecycle races。Gate 5 仍需根据 Gate 0 transport 和本 Gate trace 固定 global/per-Session count/bytes、control reserve、fairness、batch、detach/reload retention 与 fatal Bridge pipeline 语义，然后接入真实 Native SDK Bridge。

本结论不表示完整 event pump、Renderer UI、同进程产品原型、fault-domain 决策、strict Workspace security、Host tools、async resume 或 stable ABI policy 已完成。

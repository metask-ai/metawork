# Phase 0 Gate 5：Event pump 与 Native SDK Bridge 验证报告

> 日期：2026-07-16
> 结果：通过，Gate 6 可以开始
> 平台：macOS arm64

## 1. Gate 边界

Gate 5 完成 Event pump、Renderer delivery state machine 和真实 Native SDK transport 验证，但不把 transport fixture 冒充完整 AgentCore 产品链路：

- 正式 AgentCore Host callback 已接入新的有界 Event pump；
- transport-neutral delivery 接受 Host 拥有的、已校验 raw event JSON，不导入或复制 cc-zig schema；
- React 连接、fetch、ack 和 reload generation 使用真实 Native SDK Bridge；
- automation-only fixture 只验证跨线程 wake 和 Native transport，release policy 无法调用；
- 正式 Host 到 delivery 的产品接线、真实 Agent input/UI request 和 structured UI 属于 Gate 6。

这一区分保留了 Gate 顺序：Gate 5 证明组件和 transport 合同，Gate 6 才证明完整同进程垂直链路。

## 2. 真实容量输入

精确锁定的 AgentCore bundle 为 cc-zig `ab75314a3dcb595509862a9b54b3bf3b4d3a44c0`、`0.0.0-dev+ab75314a3dcb`。artifact-only probe 使用真实 built-in Read/Bash/Edit/AskUserQuestion workload：

| fixture | events | total bytes | max single event |
| --- | ---: | ---: | ---: |
| 小型 workload | 38 | 3,809 | 599 bytes |
| 12 KiB Read/Edit workload | 38 | 54,922 | 49,703 bytes |

真实单事件明显超过 Native SDK 的 8 KiB public window-event budget，因此采用有界 object reference 是测量后的决定，不是预先发明通用 blob service。最终容量见 [Gate 5 容量规格](phase-0-gate-5-measurement.md)。

## 3. Event pump

`src/agentcore/event_pump.zig` 替换 Gate 4 的简单 sink，固定提供：

- global 与 per-Session count/bytes；
- global 与 per-Session control reserve；
- 512 KiB 单 event 上限；
- 同 Session 顺序与跨 Session round-robin；
- 100 ms enqueue deadline；
- bundle `CoreEvent` exhaustive classification，无平行事件 schema；
- enqueue 成功才转移 owner，take 成功才转移给 consumer；
- zero Session/Run sentinel、错误容量和 sequence exhaustion 明确失败。

callback 在返回前同时持有 bundle SDK parse owner和 Host raw JSON copy。decode/copy/queue/deadline 失败释放全部 owner、写入 first-writer HostCause 并返回 callback fatal。

## 4. Delivery 与 Bridge

`src/bridge/delivery.zig` 不导入 AgentCore SDK，只维护 MetaWork transport envelope：

- 7 KiB / 16-item batch，最多 4 Sessions、每 Session 4 items；
- 6 KiB 以下 inline，超过后使用 Session/Run-scoped opaque object；
- object、per-Session object、retention count/bytes 和 30 秒 detach TTL 全部有界；
- connection generation 约束 batch、fetch、ack 和 detach；
- Session/Run/sequence/object 的完整 `u64` 域以十进制字符串穿过 JavaScript；
- ack 必须按 Session/Run sequence 顺序，重复 ack 幂等，成功后立即释放 retained owner；
- build 与 commit 分离，只有 `Runtime.emitWindowEvent` 成功后才 commit；send 失败不会把 event 标成已交付；
- cleanupRun/deinit 精确释放 inline/object owner。

React 在安装 listener 后连接，按 generation 串行消费 batch；object 先 fetch 并复核完整 identity，再 ack。旧 generation 事件被忽略，Host 同时拒绝旧 generation ack/fetch。`pagehide` 尝试 detach；即使 unload 通知未送达，新 connect generation 仍使旧 Renderer 失去消费权限。

## 5. Fatal 与生命周期

正式 Host 暴露 `failRun(session_id, run_id, cause)`，用受 Session active-reference 保护的查找避免在全局 registry 锁内执行 cancel/abort。确定性测试证明 callback 返回后的 `bridge_pipeline_failure`：

```text
route Session/Run
→ first-writer HostCause = bridge_pipeline_failure
→ abort active Run
→ ABI abort status preserved
→ final outcome = failed
```

Gate 6 将真实 product delivery error 自动接到该入口；Gate 5 不以两个独立组件的测试冒充已经完成垂直产品接线。

## 6. 测试与真实 macOS 证据

Host lifecycle suite 共 34 个测试，Gate 5 新增覆盖：

- global/per-Session count+bytes、control reserve、身份哨兵；
- 同 Session 顺序、pump 与 batch fairness；
- text bytes lossless；
- inline/object、fetch、ack release、所有 object/retention 配额；
- batch bytes/count、不可能容纳 inline envelope 的配置；
- uncommitted retry、foreign batch、旧 generation；
- detach/reconnect/TTL、cleanupRun/deinit；
- slow consumer、hard deadline、OOM；
- post-callback fatal → abort → failed。

Native app suite 为 6/6，包含完整 `u64` wire ID、严格/有界 payload、release fixture policy。真实 macOS automation 可复现命令：

```bash
npm run test:gate5:macos
```

命令会构建 production Renderer 和 automation Debug binary，启动真实 AppKit/WebView，验证：

```text
worker_wake off_main_thread=true
emit/fetch/ack main_thread=true
generation 1 → reload → generation 2
Session/Run sequence 1,2 → 3,4
dispatch_errors=0
dropped_trace_records=0
main window close → runtime stop → exit 0
```

## 7. Linus 审核修正

严格审核发现并修复：

- ack 原本不释放 retained event；
- batch 原本在 emit 成功前标记 sent；
- Bridge string parse owner 原本可能越过栈 buffer 生命周期；
- `u64` identity 原本使用 JavaScript number；
- `Host.failRun` 原本持有 registry lock 执行 cancel；
- zero sentinel、inline envelope 可容纳性和 foreign batch 原本未防御。

修复后重新执行 deterministic、Native、真实 macOS automation 和完整 Phase 0A 回归；Linus 复审未发现阻止 Gate 5 合入的问题。

## 8. 结论

Gate 5 已完成有界 Event pump、基于实测的大 payload object reference、generation-bound delivery、两阶段 send/commit、真实 Native SDK 跨线程 wake/main-thread Bridge 和 fatal Run 路由。它不声称已经完成真实 Agent input、同步 UI request、structured tool cards 或完整 reload view restore；这些是 Gate 6 的明确输入。

## 9. 上游更新与依赖锁

Gate 5 的全部结果只对应 manifest 已校验的 clean bundle `0.0.0-dev+ab75314a3dcb`，不根据 cc-zig source checkout 的后续移动自动升级。验证收尾时，上游 checkout 已前进到 `09be83ccd231e51836027763adaa2b312e64b775` 并把源码目录改名为 `metacodes/`，但本机没有该 commit 的 clean bundle。

该 checkout 当时的 `agentcore:bundle` 安装清单只包含 library、C header、raw Zig facade 和 ABI types module，不包含锁定 bundle 中供正式 Host 使用的 typed protocol module；raw facade 也没有替代 typed `Status` / `StopReason` validator、`CoreEvent` / `UiRequest` decoder 和 request-aware `UiResponse` encoder。MetaWork 因而不切换 dependency lock、不读取上游源码补合同，也不把 Gate 5 的通过结论外推到 `09be83c`。Gate 6 若要升级，必须先拿到一个精确、clean、checksum 完整且重新满足 Gate 3 typed SDK 门槛的 source-free bundle；否则继续使用已验收的 `ab75314`。

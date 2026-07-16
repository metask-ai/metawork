# Phase 0 Gate 5：Event pump 容量测量与实现规格

> 日期：2026-07-16
> 状态：已实施；这是 Gate 5 容量输入，验证结论见 [Phase 0 Gate 5 验证报告](phase-0-gate-5-report.md)
> 平台：macOS arm64

## 1. 传输事实

锁定的 Native SDK `0.5.1` 提供 `Runtime.emitWindowEvent`，worker 可以通过 platform `wake` 让 app 的 `effects_wake` 在 loop/main thread 排空队列。当前机器可读常量和 Gate 0 实测为：

- window event detail 采用 `8 KiB` Host budget；
- Bridge request、handler result 和 response 上限均为 `1 MiB`；
- event emission 与 Bridge handler 当前都在 macOS loop/main thread；
- AgentCore/tool callback 不得直接调用 `Runtime.emitWindowEvent`。

## 2. AgentCore workload 测量

测量使用精确 bundle `0.0.0-dev+ab75314a3dcb`，覆盖真实 built-in Read、Bash、Edit、AskUserQuestion 和最终文本。probe 对 callback 收到的原始、已由 bundle SDK 校验的 JSON 计数，不用合成事件代替 producer 输出。

| fixture | events | total bytes | max single event |
| --- | ---: | ---: | ---: |
| 小型 Read/Bash/Edit/Ask/final | 38 | 3,809 | 599 bytes |
| 12 KiB Read + Edit/Bash/Ask/final | 38 | 54,922 | 49,703 bytes |

第二组证明真实 `tool_result` 会超过 window event budget。因此 Gate 5 需要 object reference，但不需要通用 blob service：只有单事件不能安全内联时才使用受 Session/Run 约束的 Host object。

## 3. 锁定容量

以下值用于 Gate 5 macOS prototype；它们不是 stable ABI：

| 维度 | 值 |
| --- | ---: |
| max callback event | 512 KiB |
| inline event JSON | 6 KiB |
| window event batch | 16 items / 7 KiB |
| per-pump fairness | 4 Sessions / 每 Session 4 items |
| global retained queue | 512 items / 8 MiB |
| per-Session retained queue | 128 items / 2 MiB |
| global control reserve | 64 items / 2 MiB |
| per-Session control reserve | 16 items / 512 KiB |
| enqueue deadline | 100 ms |
| object store | 64 objects / 4 MiB |
| per-Session object store | 16 objects / 1 MiB |
| max fetched object | 512 KiB |
| detached retention | 256 items / 4 MiB / 30 s |

`7 KiB` batch 给 8 KiB Host budget 留出 Native SDK 包装余量。`512 KiB` object 上限给 1 MiB Bridge response 留出 response envelope 和 JSON escaping 余量；当前 49,703-byte 实测事件无需分片。

## 4. 固定路径

```text
AgentCore callback thread
→ bundle SDK validate + Host copy raw JSON
→ classify from bundle CoreEvent tag
→ bounded per-Session/global retained queue
→ platform wake
→ effects_wake on loop/main thread
→ fair batch
→ inline event or opaque object reference
→ Runtime.emitWindowEvent
→ Renderer fetches oversized object through validated Bridge command
```

object ID 必须不可由 Renderer 解释；fetch 同时校验 connection generation、Session ID、Run ID 和 object ID。Session close、Run terminal、reload generation 失效、TTL 和 Host shutdown 都必须清理对象。

## 5. 过载与重连语义

- data 不能占用 control reserve；control 也受总上限约束；
- 同一 Session/Run 保序，跨 Session round-robin；
- `text_chunk` 不丢字节；实现可合并，也可在预算内逐项发送；
- 容量暂时不足时 callback 最多等待 100 ms，随后 callback fatal；
- callback 返回后的 wake/Bridge pipeline failure 设置 first-writer `bridge_pipeline_failure` 并中止 in-flight Run；
- Renderer detach 不立即失败；30 秒 retention 内新 generation 可获得 snapshot/replay；
- 旧 generation 的 ack、UI response 和 object fetch 全部拒绝；
- 超出 detach retention 才升级为不可恢复 pipeline failure；
- 不把 Renderer reload 描述为 AgentCore 进程恢复。

## 6. Gate 5 验证要求

实现必须用 deterministic tests 覆盖 global/per-Session count+bytes、control reserve、fairness、同 Session 顺序、text 字节一致、batch 边界、object ownership/fetch/TTL、slow Renderer、detach/reload、旧 generation、OOM、deadline、Bridge failure、Run abort 和全部清理路径。最后还要用真实 Native SDK automation 验证 wake → main-thread emit → React ack/fetch/resync。

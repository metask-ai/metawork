# Phase 0 Gate 3：AgentCore typed SDK 验证报告

> 日期：2026-07-16
> 结果：通过，Gate 4 可以开始
> 平台：macOS arm64

## 1. 精确消费产物

本次只读消费以下显式 bundle root：

```text
/Users/zogien/Projects/cc-t2z/cc-zig/zig-out/agentcore-ab75314
```

锁定 identity：

| 项目 | 值 |
| --- | --- |
| bundle version | `0.0.0-dev+ab75314a3dcb` |
| cc-zig commit | `ab75314a3dcb595509862a9b54b3bf3b4d3a44c0` |
| source state | clean |
| ABI | `1` |
| UI request mode | `synchronous` |
| Zig | `0.16.0` |
| target | `aarch64-macos.13.0...15.6-none` |
| optimize | `ReleaseSafe` |
| system links | `libc` |

`spikes/agentcore-contract/bundle.lock.json` 保存完整 manifest。Node validator 要求实际 manifest 与 lock 深度相等，实际 filesystem 只包含规定目录和文件且不含 symlink，并校验静态库、C header、SDK facade、typed protocol module 和 ABI types module 的 SHA-256、平台、toolchain 与唯一 discovery symbol。没有 source fallback。

## 2. cc-zig-owned typed 表面

当前 bundle SDK 提供：

- `Status.fromCode` 与 `StopReason.fromCode`；
- `CoreEvent`、`UiRequest`、`UiResponse` typed union；
- `decodeCoreEvent` 与 `decodeUiRequest`；
- request-aware `encodeUiResponse`；
- `MalformedJson`、`UnknownTag`、`InvalidPayload`、`MismatchedResponse`、`InvalidResponse` 和 `OutOfMemory` 错误；
- `std.json.Parsed` owner，解析后数据不再借用 callback 输入；
- raw API discovery、bytes view 与 ABI function table access。

MetaWork 没有定义平行事件、UI union、code table 或 decoder。正向输入由 bundle SDK typed value 序列化后再解码；JSON 字面量只用于 unknown/malformed/mismatch 负向测试。

## 3. 独立 source-free consumer

`spikes/agentcore-sdk-contract/` 是独立 build graph，只接收经过 lock 校验的绝对 bundle root。它验证：

- discovery、ABI version、required capabilities、缺 capability/函数指针拒绝；
- 所有 SDK `Status` 和 `StopReason`，以及 unknown/max `u32` code 拒绝；
- 对 `StopReason` 的无 `else` 穷尽 switch；
- empty/non-empty bytes view 与 null + positive/max length 拒绝；
- 每个 `CoreEvent` variant 的 typed serialize/decode；
- decoded string 在原 callback buffer 被覆盖并释放后仍有效；
- malformed JSON、unknown tag、缺字段和多 tag 拒绝；
- 每个 `UiRequest` variant 的 typed serialize/decode；
- 四类 matching `UiResponse` encoding、mismatched tag 和 answers count 拒绝；
- decoder/encoder allocator failure 归一化。

Gate 1 的真实 agent-loop probe 也已升级为在 callback 内直接调用 bundle `decodeCoreEvent` / `decodeUiRequest`，并用 `encodeUiResponse` 产生由 paired release callback 释放的回答。因此验收不只依赖 typed value 的 serialize/decode round trip，也验证了真实 AgentCore producer wire 与 shipped SDK codec 一致。

ABI v1 当前只支持 64-bit target，wire length 与 `usize` 同宽，因此不存在可构造的 integer-width overflow；null + positive/max length 仍明确失败。未来若支持窄指针 target，必须新增目标级 overflow corpus，不能用当前结论外推。

## 4. Callback 与所有权结论

锁定 commit 的 public ABI 文档与 bundle header/SDK 共同规定：

- event/request bytes 只借用到同步 callback 返回；
- decoded `std.json.Parsed` 是独立 owner，必须且只能 `deinit` 一次；
- encoded response buffer 由 Host allocator 拥有；AgentCore 对 answered response 调用 paired release callback 恰好一次；
- callbacks 可以请求 abort，但不得 re-enter Run 或 destroy；
- 不同 Session 可以并发调用共享 Host callbacks，Host 必须同步共享状态；
- bundle 未承诺 WebView/main-thread affinity，MetaWork 将 callback 一律视为 AgentCore Run executor 上下文。

因此 Gate 4 callback 必须先 decode，再在 callback 返回前完成需要异步保留的数据复制；不得直接调用 WebView。

## 5. 回归与复现

可复现命令：

```bash
AGENTCORE_BUNDLE_ROOT=/absolute/path/to/agentcore-ab75314 \
  npm run test:agentcore-sdk

AGENTCORE_BUNDLE_ROOT=/absolute/path/to/agentcore-ab75314 \
  npm run test:phase0a
```

`test:phase0a` 还会在同一精确 bundle 上重跑 Gate 1 真实 link/run probe 和 Gate 2 deterministic lifecycle tests。实际结果为 Read/Bash/Edit、同步 UI、abort/lifecycle/release probe 继续通过，证明 typed SDK 增量没有破坏既有 raw ABI 消费。

## 6. 结论与剩余边界

Gate 3 已通过，正式 Host 不再受 typed SDK 缺失阻塞。下一步是 Gate 4：直接把 bundle SDK 接入现有 Host lifecycle foundation 和有界 test sink，落实 status-before-result、typed callback、同步 UI wait 与 pipeline fatal 行为。

本结论不启用 ABI v1 Host tools，不宣称 strict Workspace security、async suspend/resume、跨进程恢复或 stable ABI policy 已完成。

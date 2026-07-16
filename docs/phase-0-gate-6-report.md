# Phase 0 Gate 6：同进程 macOS 同步原型验证报告

> 日期：2026-07-16
> 结果：通过；在 Gate 6 验收边界只能称同进程 macOS 同步原型

Gate 7 随后已通过；进程模型结论见 [Gate 7 报告](phase-0-gate-7-report.md)。本报告保留 Gate 6 当时尚未证明 fault domain 的边界。

## 1. 精确依赖

本次正式 baseline 是 metacodes clean bundle：

| 字段 | 值 |
| --- | --- |
| version | `0.0.0-dev+5fe198cfac4a` |
| source commit | `5fe198cfac4a5cd8230425136086f0463fdc52bd` |
| target | `aarch64-macos.13.0...15.6-none` |
| toolchain | Zig `0.16.0` |
| build | `ReleaseSafe`、`strip=true` |
| binary ABI | revision `1` |
| UI mode | synchronous |
| system link | `libc` |

`spikes/agentcore-contract/bundle.lock.json` 锁定 manifest 和五个文件的 SHA-256。当前 validator 只接受 `source.commit`、`build.abi` 和 `files[]` 组成的现行 experimental manifest，不解析旧字段布局。`npm run agentcore:stage -- /absolute/bundle` 只接受与 lock 完全相等、无额外文件且 discovery symbol 唯一的 artifact，并原子 staged 到被忽略的 `.agentcore/bundle`。正式 build 只读取该固定布局，不读取 `AGENTCORE_BUNDLE_ROOT`，不访问 metacodes source tree，也没有 source fallback。

## 2. 正式 Host 与产品投影

- 根 `build.zig` 直接链接 `libmetacodes_agentcore.a`，并从 bundle 导入 facade、typed protocol 和 ABI types module；
- `src/agentcore/session.zig` 持有 Runtime、Session、callback lifetime、同步 UI wait 和 first-writer-wins `HostCause`，bounded executor 由 `src/workbench/executor.zig` 提供；
- `src/workbench/projection.zig` 将 bundle-validated `CoreEvent` 投影成有界 Session/Run/tool/usage view，不在 Renderer 复制协议；
- `src/main.zig` 暴露 Workspace/Session/Run/UI response 领域命令，Provider credential 只从 Host 环境读取；
- Bridge send、projection 或 retention 失败按 Session/Run 路由为 `bridge_pipeline_failure`，不会让 Core 静默继续；
- Session close 在 bounded Session 数量内离开 WebView 主线程执行，并在 snapshot 中公开 closing/closed/retryable failure。

## 3. 真实 macOS 垂直链路

`npm run test:gate6:macos` 使用真实桌面 binary、React production Renderer、Native SDK Bridge、锁定 AgentCore library 和本地 deterministic Anthropic SSE fixture，完成：

```text
temporary Workspace
→ create Session / submit Run
→ built-in Read / Bash / Edit
→ synchronous permission allow-once
→ AskUserQuestion pending
→ reload Renderer
→ recover same Session/Run/request from live Host
→ answer and resume
→ terminal completed projection
→ async Session close
→ normal app stop
```

验证包含 Read 内容、Bash stdout、Edit 后磁盘内容、最终 assistant bytes、tool terminal state、Run outcome/cause、pending request identity、reload 后继续执行、transport `dispatch_errors=0` / `dropped_trace_records=0` 和正常 Runtime stop。

## 4. Workload matrix 证据

| 维度 | 当前覆盖 |
| --- | --- |
| Sessions/executor | 1 条真实垂直 Run；deterministic 4 Session/4 worker 同时等待 UI；1 worker 下 active+queued+overflow |
| event rate | 真实 AgentCore streaming；Event pump burst/fairness；Workbench 2,048 个 text chunk |
| event bytes | 小事件、真实约 49 KiB tool result object、32 KiB projection 上限与 overflow |
| duration/cancel | provider stream abort、长 Bash abort、queued cancel、active close、shutdown |
| UI waits | answered、deadline、cancel、close、shutdown；全部 executor slot 同时等待时控制路径仍可执行 |
| Renderer | 正常消费、generation detach/reload、pending UI reload restore、过期 retention cleanup |
| failure | malformed wire、OOM、queue deadline、Bridge pipeline fatal、transient destroy retry |

容量仍是 Phase 0 prototype 数据，不是 stable ABI 或长期产品默认值。

## 5. 可复现命令

```bash
npm run agentcore:stage -- /absolute/path/to/metacodes-agentcore-bundle
npm run format:check
npm run check
npm test
AGENTCORE_BUNDLE_ROOT=/absolute/path/to/metacodes-agentcore-bundle npm run test:phase0a
npm run test:gate5:macos
npm run test:gate6:macos
npm run build:debug
npm run build:release
npm run package:macos
```

## 6. 明确未证明

- Renderer reload 只恢复仍存活 Host 的 view，不是 AgentCore 进程恢复；
- 当前只允许临时或用户明确 trusted Workspace，不是 strict Workspace security；
- 当前使用 built-in tools，没有启用 ABI v1 Host tools；
- 没有 async suspend/resume、持久化 Session、remote artifact resolver 或 Windows bundle；
- 同进程 AgentCore crash 会影响 Host。该风险随后由 [Gate 7](phase-0-gate-7-report.md) 的独立进程故障注入确认，并据此选择单 AgentCore Worker 作为后续正式方向。

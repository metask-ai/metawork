# AgentCore ABI v1 revision 2 迁移验证报告

> 日期：2026-07-20
> 结果：通过
> 边界：精确 development bundle 验证，不声明 stable ABI support policy

## 1. 被验证的提交

| 项目                      | 精确值                                           |
| ------------------------- | ------------------------------------------------ |
| MetaWork migration commit | `b36d348cea0e4d39d03e346b40c9458bbba014f2`       |
| post-review hardening     | `78e7bc5832e5a93d59536b136f1dc4ca2b7c0463`       |
| metacodes source commit   | `36637f314c0f1c41bb1a2267ced7ad6a46100003`       |
| bundle version            | `0.0.0-dev+36637f314c0f`                         |
| binary ABI                | version `1`、revision `2`、API table `112` bytes |
| target                    | `aarch64-macos.13.0...15.6-none`                 |
| toolchain                 | Zig `0.16.0`                                     |
| build                     | `ReleaseSafe`、`strip=true`、system link `libc`  |

初始迁移验证从 clean migration commit 开始。后续整体审核发现 UI callback admission 与最终 response extraction 之间仍可能并发发生 Core identity failure；hardening commit 在不增加新 latch、registry 或兼容路径的前提下关闭该线性化缺口，并补充真实 callback quiescence 证据。`agentcore:stage` 从显式绝对 bundle root 校验精确 manifest、文件集合、checksum 和 discovery symbol 后，原子写入被忽略的 `.agentcore/bundle`。正式 build、test 和 package 只消费该 staged bundle，没有读取 metacodes source tree、运行时 receipt 或 source fallback。

## 2. 产物证据

| 产物                                            | SHA-256                                                            |
| ----------------------------------------------- | ------------------------------------------------------------------ |
| staged `manifest.json`                          | `8af8b3fed61a3780b72f9e1aa9f5ec4f6c9be8b773d90b705dc8b6e872454984` |
| staged `libmetacodes_agentcore.a`               | `f285e4974d678a4a0aaa95dbd2f5087dd39404535263d619cb03f43fe3533d6c` |
| release `zig-out/bin/metawork`                  | `2693742c0060505e9fe77085bc4251c71dd41e6fa84429d8e476cd3297c4918c` |
| packaged `metawork.app/Contents/MacOS/metawork` | `2693742c0060505e9fe77085bc4251c71dd41e6fa84429d8e476cd3297c4918c` |

release 与 package 内 executable hash 相同。package verifier 同时确认 arm64 Mach-O executable、应用 metadata 和三个精确 Renderer assets；本地产物是 ad-hoc signed development package，不构成发布签名或 notarization 证明。

## 3. 可复现验证

以下命令在同一 staged bundle 上全部通过：

```bash
npm run agentcore:stage -- /absolute/path/to/aarch64-macos.13.0...15.6-none
npm run format:check
npm run check
npm test
AGENTCORE_BUNDLE_ROOT=/absolute/path/to/aarch64-macos.13.0...15.6-none \
  npm run test:phase0a
npm run test:gate5:macos
npm run test:gate6:macos
npm run build:debug
npm run build:release
npm run package:macos
```

关键结果：

- Renderer runtime `52/52`、architecture `22/22`、bundle contract `13/13`、Native aggregate `40/40`；
- Agent lifecycle suite 包含 `31` 个分组用例；新增的 post-answer identity mismatch 与 callback-outlives-run 用例分别连续运行 `30` 次通过；
- raw probe 明确发现 `ABI 1 revision 2`，真实 event/UI `RunContext` 路径通过；
- Gate 5 通过 worker wake、main-thread emit/fetch/ack、reload generation 和 clean stop；
- Gate 6 通过真实 bundle Read/Bash/Edit、allow-once permission、重复 UI response 拒绝、reload-safe AskUserQuestion、Task metadata lifecycle 和 async close；
- Debug、Release 和 macOS package 均从同一 tracked migration commit 成功生成。

## 4. 迁移边界

本次迁移是旧 ABI revision 的 hard cut：

- manifest、lock、validator、stager、build graph 和 raw probe 只接受 revision 2；
- 正式 Agent 的 Event/UI callback 只接受 SDK-validated `RunContext`，并在同一 Session lock 内验证原始 Session handle、active run ID、Session-lifetime session ID 与 callback ref admission；
- invalid context、错误 handle/run ID、同 Run/跨 Run session ID 漂移和并发首次绑定冲突均 fail closed，并 poison Session；
- UI callback 在 request publication 和最终 response extraction 时重新确认现有 identity/dependency-contract 状态；并发 identity failure 后返回 fatal、释放尚未转移的 response，禁止已经接受的 permission answer 外泄；
- `session_run` 若在 callback 尚未 quiesce 时返回，Host 将其视为 dependency-contract failure，唤醒 UI waiter 并等待 callback ref 归零后才完成 Run；
- 没有旧 API table、旧 callback 签名、并行协议或兼容 fallback。

产品 Runtime 仍不注册 Host tools；strict Workspace security、async resume、跨进程 Conversation 恢复、remote artifact repository 和 Windows bundle 也不在本报告范围内。

## 5. Gate 7 结论保持不变

revision 2 迁移没有改变 fault domain。既有 [Gate 7 报告](phase-0-gate-7-report.md) 的结论继续成立：后续正式方向选择单 AgentCore Worker；当前可运行应用仍是同进程 prototype。Worker transport、supervisor 和真实 AgentCore 资源数据尚未产品化，AgentCore fatal 后也没有 Run 或 Conversation 自动恢复，危险工具不得透明重放。

# AgentCore ABI v1 revision 3 迁移验证报告

> 日期：2026-07-21
> 结果：通过
> 边界：精确 development bundle 验证，不声明 stable ABI support policy

## 1. 被验证的实现与 bundle

| 项目                      | 精确值                                           |
| ------------------------- | ------------------------------------------------ |
| MetaWork hard-cut commit  | `f0e39f43b520ce97b4c390d590d2807019b9c4a3`       |
| metacodes source commit   | `1ec7e4902727ff894c50452d6417fb6fc3d8bb2c`       |
| source state              | `dirty = true`                                   |
| bundle version            | `0.1.0-dev+1ec7e4902727.dirty`                   |
| binary ABI                | version `1`、revision `3`、API table `112` bytes |
| target                    | `aarch64-macos.13.0...15.6-none`                 |
| Rust target               | `aarch64-apple-darwin`                           |
| toolchain                 | Zig `0.16.0`                                     |
| build                     | `ReleaseSafe`、`strip=true`、需要 C runtime      |
| official Zig package path | `.agentcore/bundle/bindings/zig`                 |
| public module/symbol      | `metask_agentcore` / `metask_agentcore_get_api`  |

candidate 直接取自本机 metacodes `zig-out/agentcore/aarch64-macos`。`source.dirty = true` 只说明 provenance；source commit 不能重建同一未提交源码状态。repository lock 的完整 manifest bytes 和全部 payload checksum 精确识别本次 artifact。

candidate acceptance 使用显式绝对 bundle root，完成 exact manifest、filesystem whitelist、checksum、target/toolchain、唯一新 discovery symbol、raw C discover/link/run 和官方 Zig package `Api.discover()`/link/run。随后 stager 只复制 manifest whitelist，复验后安装为 canonical `.agentcore/bundle`。正式 build/test/package 不读取外部 root，也不把 metacodes source tree 纳入 build graph。

## 2. 产物证据

| 产物                                            | SHA-256                                                            |
| ----------------------------------------------- | ------------------------------------------------------------------ |
| repository `bundle.lock.json`                   | `ab4bcebb4c5b545cdfc6cdb05117d51b0ae5ff17c4288b224c9688802b8052bf` |
| staged `manifest.json`                          | `ab4bcebb4c5b545cdfc6cdb05117d51b0ae5ff17c4288b224c9688802b8052bf` |
| staged `libmetask_agentcore.a`                  | `419d895de617c04ccadadec529f58b107c6c7d0a27f6796b5cf79d0938c47792` |
| release `zig-out/bin/metawork`                  | `5c1553f7ce8984edc75c84b50393d37b0708962002bd7da007156ac3681bbfca` |
| packaged `metawork.app/Contents/MacOS/metawork` | `5c1553f7ce8984edc75c84b50393d37b0708962002bd7da007156ac3681bbfca` |

release 与 package 内 executable hash 相同。二者都是 arm64 Mach-O；package executable 的 `LC_BUILD_VERSION` minimum OS 是 macOS 13.0，与 bundle deployment baseline 一致。最终 development app 位于 `zig-out/package/metawork.app`，大小约 6.3 MiB。

package 只包含 executable、metadata、icon、签名计划和三个精确 Renderer assets。扫描确认没有 `.a`、C header、Zig/Rust binding 源码、`.agentcore` staging 内容、旧 AgentCore active token、automation fixture/token 或 Gate 6 fixture credential。

## 3. 可复现验证

以下命令在同一 canonical staged bundle 上按顺序全部通过：

```bash
npm run agentcore:verify-staged
npm run format:check
npm run check
npm test
npm run test:phase0a
npm run build:debug
npm run build:release
npm run test:gate5:macos
npm run test:gate6:macos
npm run package:macos
```

关键结果：

- Renderer runtime `60/60`、architecture `23/23`、bundle contract `17/17`、Native aggregate `105/105`；
- bundle negative corpus 覆盖 exact lock drift、ABI revision、target、dirty identity、revision 2 schema、duplicate/case-colliding/unsafe paths、额外或缺失 payload、symlink、checksum 和新旧 discovery symbol；
- Phase 0A 重跑 staged raw C probe、官方 Zig consumer、typed SDK consumer 和 lifecycle suites；
- Gate 5 通过 worker wake、main-thread emit/fetch/ack、reload generation 和 clean stop；
- Gate 6 通过真实 revision 3 bundle 的 Read/Bash/Edit、permission UI、重复 UI-response 拒绝、reload-safe AskUserQuestion、Task metadata lifecycle 和 async close，并确认 Host credential 到达 AgentCore但不进入 Renderer snapshot；
- Debug、Release、Gate 5/6 和 package 都消费同一 staged manifest identity。

## 4. Hard-cut 边界

- `build.zig.zon` 只从 staged 官方 `bindings/zig` package 获取唯一 `metask_agentcore` module；
- 只有 `src/agent/` 导入 SDK；Account、Workbench、Bridge、Renderer 和 App 不导入；
- 正式 build 不手工创建 AgentCore root/types/protocol modules，不直接 `addObjectFile` archive，也不复制 link inputs；
- 外部 `AGENTCORE_BUNDLE_ROOT` 只属于 candidate probe/stage；正式入口先运行 staged preflight；
- active code/build/规范文档没有 revision 2 parser、路径、symbol、module alias、feature flag 或 fallback；
- 旧 token 只保留在明确的 rejection test、历史验证报告和 hard-cut 验收规则中，不构成可执行兼容路径。

## 5. 仍然成立的限制

本次迁移不改变产品协议、permission 选择、多选问题语义或 fault domain。正式 Runtime 仍不注册 Host tools；strict Workspace security、async suspend/resume、跨进程 Conversation 恢复、remote artifact repository、Windows bundle 和单 AgentCore Worker 均不在本报告范围内。

Gate 7 的结论保持不变：当前可运行应用仍是同进程 prototype，AgentCore fatal 后没有 Run 或 Conversation 自动恢复，危险工具不得透明重放；后续正式方向仍是单 AgentCore Worker。

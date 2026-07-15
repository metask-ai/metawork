# Phase 0 Gate 1：AgentCore artifact-only raw contract probe 报告

> 日期：2026-07-15
> 结果：通过，Gate 2 可以开始
> 平台：macOS arm64

## 1. 消费产物

本次使用显式绝对 bundle root：

```text
/Users/zogien/Projects/cc-t2z/cc-zig/zig-out
```

manifest identity：

| 项目 | 值 |
| --- | --- |
| bundle version | `0.0.0-dev+ab0f851562c3-dirty.66e2d4c61093` |
| cc-zig base commit | `ab0f851562c3cafe926b7e75b0a1b1f4842e2b0b` |
| dirty source digest | `66e2d4c610936e8de9760aeef387f1734dc3c1a484d2f4428adbe069eb418eef` |
| ABI | `1` |
| UI request mode | `synchronous` |
| Zig | `0.16.0` |
| target | `aarch64-macos.13.0...15.6-none` |
| optimize | `ReleaseSafe` |
| system links | `libc` |

cc-zig 当前 checkout 是干净的 `master@192d3c5`，而现存 bundle 是上述更早的 dirty dev identity。probe 精确验证并消费的是 manifest identity，不把它冒充为当前 master 的正式发布包。Gate 2 可以用 deterministic fake 独立推进；未来 Gate 3/4 验收必须要求 cc-zig 提供与当时目标 commit 一致的重新构建 bundle。

## 2. 隔离边界

probe 位于 `spikes/agentcore-contract`，使用自己的 `build.zig` 和精确 `bundle.lock.json`：

- 正式 `src/main.zig`、Native SDK build、test 和 package graph 不引用 probe；
- validator 先要求实际 manifest 与仓库 lock 深度完全一致，再校验 lock 中每个 checksum；因此另一个即使自洽的 bundle 也不能静默替换；
- 只从 bundle root 导入静态库、C header 与两个 cc-zig-owned Zig SDK 文件；
- 不导入 cc-zig 实现源码，不复制 ABI struct、整数 code 或 Agent 事件定义；
- raw JSON 检查与 UI response 字面量只存在于该 contract probe，不得进入正式 Host；
- Runtime 的 `host_tool_count` 保持 `0`，Read/Bash/Edit 使用 built-in catalog。

可复现命令：

```bash
npm ci
npm run test:agentcore-bundle
AGENTCORE_BUNDLE_ROOT=/absolute/path/to/bundle npm run probe:agentcore
```

## 3. Bundle fail-closed 校验

Node validator 和独立 Zig build graph 都校验：

- manifest schema、name、version 与完整 source identity，并与仓库 lock 完全一致；
- dirty bundle 必须带 64 位 source digest；
- Host OS/architecture、resolved target 与 macOS deployment target；
- ABI version、同步 UI mode、Zig toolchain与系统链接输入；
- 静态库、C header、两个 Zig SDK 的精确文件集合和 SHA-256；
- `metacodes_agentcore_get_api` discovery symbol 恰好存在一次；
- API table 的 struct size、ABI、required capabilities 与全部函数指针；
- 请求 ABI 2 必须返回 null。

7 个 validator 负向/正向测试覆盖完整 bundle、repository lock 漂移、checksum mismatch、manifest 文件缺失、target 不支持、dirty digest 缺失以及 discovery symbol 缺失/重复。校验失败不会回退源码。

## 4. 真实调用链

source-free Zig consumer 启动本地 Mock Provider 和临时 Workspace，通过真实同步 agent loop 依次执行：

```text
Read fixture.txt
→ Bash "printf gate1-bash-ok"
→ Edit gate1-before → gate1-after
→ final assistant text
```

验证结果：

- `RunResult.stop_reason = end_turn`，`tool_calls = 3`；
- callback 内每个 CoreEvent 都是合法 JSON，且观察到 Read content、Bash stdout、Edit result 和 final text；
- Edit 后从文件系统读回 `gate1-after`；
- Bash/Edit 的同步 permission request 返回 `allow_once`；
- answered UI response 的 release callback 调用次数与回答次数严格相等；
- unavailable UI 让工具安全失败后仍可由下一模型 turn 正常结束；
- fatal UI 返回 `STATUS_CALLBACK_FAILED` 并 poison Session，后续 Run 返回 `STATUS_INVALID_STATE`；
- event/request bytes 只在 callback 内解析，不跨 callback 保存 borrowed pointer。

## 5. 生命周期与错误矩阵

probe 验证：

- Runtime create/destroy 和 Session create/destroy；
- Runtime 存在 Session 时 destroy 返回 `BUSY`；
- active `sleep 10` Bash Run 期间 Session destroy 返回 `BUSY`；
- active Run 上错误 run ID 的 abort 返回 `STALE_RUN`；
- 正确 run ID 的 abort 返回 OK，Run 最终得到 `STOP_ABORTED`；
- 已结束 Run 的 abort 返回 `TOO_LATE`；
- run ID `0` 和 abort run ID `0` 返回 `INVALID_ARGUMENT`；
- 每个 non-OK diagnostic 都非空，只释放一次，并在 `buffer_release` 后恢复 canonical `{null, 0}`；
- C11 consumer 编译并运行，C header 的 layout assertions 与 discovery table 可用。

## 6. Gate 3 输入：typed SDK 缝隙

当前 bundle Zig SDK 已提供 raw ABI declarations、bytes view validation、API discovery 与 function pointer access，但正式 Host 所需的以下 typed 表面仍缺失：

- ABI function `Status` validator/type；
- `StopReason` validator/type；
- tagged `CoreEvent` decoder；
- `UiRequest` decoder；
- `UiResponse` encoder；
- unknown code/tag、payload mismatch 和 malformed nested fields 的系统化负向 corpus；
- callback 参数 identity、threading 与 ownership 的完整 SDK-level 文档。

因此 Gate 1 通过只证明 raw bundle 可被独立、真实、安全失败地消费，不授权正式 Host 手写这些协议层。Gate 2 只建设可注入 function table 的生命周期与安全基础；正式 AgentCore Host 继续等待 Gate 3。

## 7. 结论

当前 dev bundle 已证明 macOS arm64 的 artifact-only discovery、link、real run、built-in Read/Bash/Edit、同步 UI、abort、生命周期和 release contract 可行。MetaWork 不需要引入 cc-zig 源码，也不需要自建 ABI；后续阻断项是 cc-zig typed SDK 完成和与目标 commit 一致的正式 bundle identity，而不是 C ABI 本身不可用。

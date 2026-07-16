# Phase 0 Gate 7：fault-domain 验证报告

> 结论：通过
> 平台：macOS 13+ / Apple Silicon
> 日期：2026-07-16

## 1. 验证目标

Gate 7 不建设正式 Worker，而是回答一个更窄的问题：AgentCore 或 tool 发生不可恢复的 native fatal 时，MetaWork 是否接受整个 Desktop Host 一起退出，还是把 AgentCore 放到单独故障域。

测试由独立 Node runner 启动一个使用 Zig toolchain 编译的 native C fixture。fixture 的 `SIGABRT` 是 AgentCore/tool panic、abort 的等价进程级 fatal；它不模拟 AgentCore 业务行为，也不链接上游源码或把 spike transport 带入正式 Host。

## 2. 同进程 baseline

baseline 进程在 crash 前持有一个 completed Session snapshot 和一个 active Run，然后执行 `SIGABRT`。runner 验证：

- 进程由 `SIGABRT` 非正常退出；
- active marker 之后没有任何 Host 代码继续执行；
- completed 和 active Session 的进程内状态同时消失；
- 外部观察者最多保留 crash 前最后一次已经发出的 snapshot；
- 外部只能根据“crash 时仍 active”把 Run 解释为 `interrupted`，不能恢复 Conversation；
- native fixture 可以重新启动，但此前的 active Run 必须人工重新发起，危险工具不得自动重放。

fixture 只测到 native 进程重新 ready 的时间；由于当前没有 Conversation checkpoint 或自动 Run 恢复，人工恢复是“用户重启并重新提交”，不存在有限的自动恢复时间。报告不会拿进程启动时间冒充业务恢复时间。

这条路径是**零进程级隔离**。它不能因为 executor 有界、Zig 类型安全或 Renderer 可 reload 而被描述成可恢复。

## 3. 最小 Worker harness

对照组把 Host snapshot 留在 runner，只让 native Worker 接收有界的关联请求。Worker 接受危险工具请求后 `SIGABRT`。runner 验证：

- Host runner 存活；
- 归属 Session 从 `running` 进入 `interrupted`，cause 为 `worker_disconnected`；
- 另一个 completed Session 的 Host UI snapshot 仍可读取；
- 原危险工具一共只 dispatch 一次；重启 Worker 后只发送新的 health request；
- transport 拒绝超过 4096 bytes 的 frame，拒绝后仍可继续处理有效 frame；
- 100 次 request/response 使用并校验 correlation ID；
- Worker 断连使 pending request 失败，不把它伪装成成功或用户取消。

spike transport 是 newline-delimited 的临时测试协议，不是产品 API，也没有 supervisor、自动恢复或通用 RPC abstraction。

## 4. 实测数据

以下是 2026-07-16 一次本机 Debug fixture 运行的数据，只用于比较数量级，不是性能 SLA：

| 项目 | 同进程 baseline | 最小 Worker |
| --- | ---: | ---: |
| fatal 后 Host 存活 | 否 | 是 |
| 进程级隔离 | 无 | Host / Worker |
| native fixture RSS | 1040 KiB | 1040 KiB |
| crash 后 native 进程重启 ready | 1.883 ms | 1.734 ms |
| 有效 transport frame 最大观测值 | 不适用 | 45 bytes |
| frame 上限 | 不适用 | 4096 bytes |
| 100 次关联往返 p50 | 不适用 | 0.023 ms |
| 100 次关联往返 p95 | 不适用 | 0.058 ms |

这些 RSS、启动和往返数字只覆盖最小 native fixture，不代表真实 AgentCore 模型请求的资源或吞吐。故障影响结论来自 OS 进程边界，不依赖该性能样本。

## 5. 进程模型决定

MetaWork 后续正式方向选择**单 AgentCore Worker**，理由是：

1. 同进程 fatal 的 blast radius 是整个 Host、全部进程内 Session 和当前 UI 可用性；
2. 单 Worker 已足以让 Desktop Host 和已有产品 snapshot 在 AgentCore fatal 后继续存活；
3. spike 未给出建设每 Session Worker 的证据；每 Session 进程会增加资源和监管复杂度；
4. 危险操作不能透明重放，因此“Worker 自动重启”与“Run 自动恢复”必须分开；
5. 当前 AgentCore 没有跨进程 Conversation checkpoint，所以 Worker crash 后所有归属该 Worker 的 active Run 都是 `interrupted`。

这个决定只冻结故障域方向，不冻结 IPC layout。正式 Worker transport 必须在后续 Gate 单独定义版本、上限、ownership、backpressure、correlation、断连、shutdown 和 credential 边界，并用真实 AgentCore bundle 重新测量资源与吞吐。

当前可运行应用仍是 Gate 6 的同进程 prototype；在正式 Worker 落地前，不能宣称产品已经具备进程隔离或 crash recovery。

## 6. 可复现命令

```bash
npm run test:gate7:macos
```

该命令用 `zig cc -Wall -Wextra -Werror` 在临时目录编译 fixture，运行 baseline 和 Worker 对照，并在成功或失败后回收子进程和临时文件。

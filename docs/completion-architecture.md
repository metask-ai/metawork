# MetaWork Completion 架构

> 状态：Agent-owned one-shot Completion 的 source of truth；当前消费者为 Model Connection Probe 与首个 Run 自动标题

本文定义 MetaWork 自有的无 Tool、非流式 Completion 边界。它不属于 Metask AgentCore Run/Event 协议，也不建立第二套 AgentLoop；测试归属和持续回归入口见[验证规范](validation.md)。

## 1. 目标

MetaWork 只需要为当前产品提供一个简单的文本 Completion：

```text
Completion.complete(request, cancellation) -> Result | Failure
```

当前消费者只有：

- Model Connection Probe；
- 首个 Run 的自动标题生成。

两者都只消费最终文本，不消费 token delta、thinking delta 或其他流式事件。因此 Completion 使用 Provider 的非流式 JSON 接口，不提供 `Stream`、`next()` 或 SSE。

## 2. Owner 与配置

- `src/agent` 拥有 Completion 请求、结果、错误、协议 codec 和调用语义。
- `src/app` 只实现一次 buffered HTTP/TLS 请求及请求级取消。
- Account 仍是 credential 与 ExecutionConfig owner。
- Completion 使用与对应 Agent Run 相同、已冻结的 ExecutionConfig；不发现、选择或替换模型。
- MetaWork 不修改 `metacodes`，也不要求 AgentCore 提供 Completion。

## 3. Provider 与协议

Provider 表示用户配置的模型服务实例，其身份与配置由 [Account](account-architecture.md#34-model-connection) 拥有；不同服务实例可以使用相同协议，不能通过协议推导服务身份。Agent 不建立额外的 Provider 类别或继承层次。

MetaWork 独立定义 `Protocol`。Session、Completion 和 Provider Probe 同时接收服务实例引用 `provider_id`、明确协议、endpoint、credential 和 model。`provider_id` 是 Host 侧的不透明引用，不是服务商枚举或协议适配器；协议不能由该引用、URL 或模型名推断。Session 与 Completion 持有引用的 owned copy，不依赖调用方配置缓冲区的生命周期；该引用不进入模型请求、Core ABI、Bridge、event、snapshot 或产品历史。

| Protocol | Completion 接口 |
| --- | --- |
| `openai_responses` | 非流式 `POST /v1/responses` |
| `openai_chat_completions` | 非流式 `POST /v1/chat/completions` |
| `anthropic_messages` | 非流式 `POST /v1/messages` |
| `gemini_native` | 非流式 `generateContent` |

协议推荐和选择由 MetaWork 决定，OpenAI 新接入优先采用 Responses；已有连接仍使用其明确配置的协议，不能因默认策略变化而隐式切换。Session 在创建和恢复时将协议映射为 AgentCore 的 provider/protocol ABI 编码；Core provider 只选择执行适配器，不表示用户配置的服务身份，也不能成为 MetaWork 默认策略。Completion 直接按 `Protocol` 选择 codec，不消费 AgentCore enum。

Responses Completion 固定 `stream: false`、`store: false`，仅返回最终文本，不返回或续传 reasoning items，不引入服务端会话状态。

每个 codec 只支持无 Tool 的文本子集：

- 编码 system/messages、model 和认证 header；
- 解码最终文本、usage 和 stop reason；
- tool/function call、未知 terminal reason 或非文本结果 fail closed。

Agent 不建立另一套 Provider registry、动态发现、fallback、通用插件框架或第二套 AgentLoop。

## 4. Transport port

`src/agent` 定义一个窄 port：

```text
perform(http_request, cancellation, response_buffer)
    -> { status, body } | TransportError
```

`src/app/completion_http_transport.zig` 使用 `std.http.Client.fetch` 完成一次请求：

- 响应完整写入有界 caller-owned buffer；
- 请求线程与 cancellation wait 使用 `std.Io.Select` 竞争；
- 返回前取消并等待 losing operation 静止；
- 生产 TLS 使用系统 CA，不接受 Completion 自定义证书配置；
- redirect 不自动跟随。

这沿用仓库现有 buffered fetch/cancel 模式，不维护 socket、Connection 或逐块 read 生命周期。

## 5. Completion 结果

成功结果只包含：

- `text`；
- `usage`；
- `stop_reason`。

失败使用 MetaWork-owned typed union：

- invalid config/request；
- cancelled；
- transport failure；
- Provider HTTP rejection；
- malformed/unsupported response；
- resource limit / out of memory。

Provider 非 2xx 响应按 HTTP status 分类，不把响应正文、credential 或 header 写入错误、日志、event、snapshot 或产品历史。

## 6. 取消与生命周期

- 每次 `complete()` 使用一个独立 Cancellation token。
- watchdog 或 shutdown 可以从另一线程请求取消。
- Application transport 必须让被阻塞的整次 fetch 返回，并在 `perform()` 返回前等待 I/O 静止。
- 调用线程等待 `complete()` 返回并 join watchdog 后，才能销毁 Completion 和冻结的 ExecutionConfig。
- Completion 销毁时 secure-zero 自己持有的 credential copy；编码后的 sensitive header copy在请求结束后 secure-zero。

不存在 Stream owner、abort reason 竞争、exactly-one terminal event 或 Stream-before-Completion teardown 合同。

## 7. AgentCore hard cut

MetaWork 产品代码不调用或 re-export AgentCore Completion API，也不保留运行时 fallback、revision 探测或条件编译。

当前 canonical AgentCore artifact 已经删除全部 AgentCore Completion 类型与 slots。产品 Completion 测试仅使用 MetaWork-owned fake Transport，AgentCore lifecycle fixture 不承担 Completion 行为或兼容路径。

## 8. 验证

最小充分验证包括：

- 不同服务实例共享协议、实例引用深拷贝且不进入 HTTP 请求；
- 显式 protocol 的非流式请求与脱敏 JSON response fixture；
- Session 创建、恢复的 Host 调用路径传递所选协议对应的 Core 适配器和协议码，包括 Responses 不被默认码替换的回归；
- tool/function/未知 stop reason fail closed；
- 非 2xx typed rejection；
- 请求前取消及阻塞请求取消；
- credential/header copy 清零；
- Provider Probe 与自动标题使用同一冻结 ExecutionConfig；
- architecture guard 证明 Completion/Protocol 不导入 AgentCore SDK；
- lifecycle 与 shutdown 验证。

不把真实 Provider 网络或本地测试证书作为普通 CI 依赖。

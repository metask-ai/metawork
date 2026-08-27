# MetaWork Completion 实现

状态：已接受并实现。本文件取代此前的流式 Completion、`metask_model`、Model ABI 和 Runtime Set 方向。

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

- `src/agent` 拥有 Completion 请求、结果、错误、三个 Provider codec 和调用语义。
- `src/app` 只实现一次 buffered HTTP/TLS 请求及请求级取消。
- Account 仍是 credential 与 ExecutionConfig owner。
- Completion 使用与对应 Agent Run 相同、已冻结的 ExecutionConfig；不发现、选择或替换模型。
- MetaWork 不修改 `metacodes`，也不要求 AgentCore 提供 Completion。

## 3. Provider 范围

Provider 是固定 closed union：

- Anthropic Messages：非流式 `POST /v1/messages`；
- OpenAI Chat Completions：非流式 `POST /v1/chat/completions`；
- Gemini Native：非流式 `generateContent`。

每个 codec 只支持无 Tool 的文本子集：

- 编码 system/messages、model 和认证 header；
- 解码最终文本、usage 和 stop reason；
- tool/function call、未知 terminal reason 或非文本结果 fail closed。

不建立 Provider registry、动态发现、fallback、通用插件框架或第二套 AgentLoop。

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

当前 canonical AgentCore artifact 仍是 ABI v1 revision 13，其 SDK 要求测试 `ApiV1` 表包含 Completion slots。`tests/support/lifecycle_fixture.zig` 中这些 slots 始终返回拒绝状态，只满足当前精确表结构，不是产品兼容路径。未来精确 artifact 删除这些 slots 时，fixture 与 bundle lock 原子更新，不保留双 revision。

## 8. 验证

最小充分验证包括：

- 三个 Provider 的非流式请求和脱敏 JSON response fixture；
- tool/function/未知 stop reason fail closed；
- 非 2xx typed rejection；
- 请求前取消及阻塞请求取消；
- credential/header copy 清零；
- Provider Probe 与自动标题使用同一冻结 ExecutionConfig；
- architecture guard 证明 Completion/Provider 不导入 AgentCore SDK；
- lifecycle 与 shutdown 验证。

不把真实 Provider 网络或本地测试证书作为普通 CI 依赖。

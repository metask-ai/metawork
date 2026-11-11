# MetaWork Completion 架构

> 状态：Agent-owned one-shot Completion 的 source of truth

本文定义 MetaWork 自有的无 Tool、非流式 Completion 边界。它不属于 Metask AgentCore Run/Event 协议，也不建立第二套 AgentLoop；测试归属和持续回归入口见[验证规范](validation.md)。

## 1. 目标

MetaWork 只需要为当前产品提供一个简单的文本 Completion：

```text
Completion.complete(request, cancellation) -> Result | Failure
```

当前消费者只有：

- Custom Model Probe；每次 preparation 精确绑定 `ModelRef + provider revision + source generation + catalog generation`，完成时任一 token 过期都只销毁结果，不提交 Models 状态；
- 首个 Run 的自动标题生成；
- 用户选择自动评审后的本次 permission 建议；接纳、授权与历史仍归 Product Task，见 [Product 架构](product-architecture.md#22-workspace-与-task-admission)。

这些消费者都只消费最终文本，不消费 token delta、thinking delta 或其他流式事件。因此 Completion 使用 Provider 的非流式 JSON 接口，不提供 `Stream`、`next()` 或 SSE。

## 2. Owner 与配置

- `src/agent` 拥有 Completion 请求、结果、错误、协议 codec 和调用语义。
- `src/app` 为 Completion 实现单次有界 HTTP/TLS 请求及请求级取消。
- Product Models 合同拥有通用 Protocol/ExecutionConfig；Account 只拥有 Metask credential authority，Models aggregate 独立拥有 Custom Provider credential authority，Completion 不拥有任一服务实例或 credential authority。
- Completion 使用与对应 Agent Run 相同、已冻结的模型执行绑定；不发现、选择或替换模型。
- MetaWork 不修改 `metacodes`，也不要求 AgentCore 提供 Completion。

Agent 的共享输入是 borrowed `ModelTarget { provider_id, protocol, base_url, model }`
与 `ModelBinding { target, credential }`。它只表达执行所需事实，不携带 Product
authority、generation、catalog metadata 或 ownership。Completion、Provider Probe 与
Session 接收同一语义结构，但各自按生命周期决定是否取得 owned copy；公共 binding
本身不分配内存，也没有 `deinit`。

## 3. Provider 与协议

Provider 表示 Product execution source 配置的模型服务实例，其身份、配置与 credential authority 由 [Product Models 与对应 source](product-architecture.md#21-models-aggregate-与-account-handoff)拥有；不同服务实例可以使用相同协议，不能通过协议推导服务身份。Agent 不建立额外的 Provider 类别或继承层次。

Product Models 与 Agent 分别拥有产品已开放的 `Protocol` 和可执行 codec `Protocol`。唯一的 Product-owned outbound adapter 对已开放集合做穷举编译期映射；两侧不共享 enum，不使用字符串转换，也不因 Agent 新增 codec 自动扩大产品能力。Session、Completion 和 Provider Probe 同时接收服务实例引用 `provider_id`、明确协议、endpoint、credential 和 model。`provider_id` 是 Host 侧的不透明引用，不是服务商枚举或协议适配器；协议不能由该引用、URL 或模型名推断。Session 与 Completion 持有引用的 owned copy，不依赖调用方配置缓冲区的生命周期；该引用不进入模型请求、Core ABI、Bridge、event、snapshot 或产品历史。codec 只接收 credential、base URL 与 model；`provider_id` 和已经完成分派的 `protocol` 从类型上不可见。

`provider_id` 作为执行元数据标识 Session 或 Completion 所绑定的服务配置来源；调用方负责提供正确引用，Agent 保留但不分配、解析或重新生成它。身份范围与生命周期由 Product Models source 合同定义，不由潜在的限流、遥测或 credential 分组用途改变。Agent 模型字段的单字段上限与校验由 `model_binding` 唯一拥有，Product Models 可以采用更小的生成范围。Session fresh/restore、model rebind、checkpoint export/restore、Completion 和 Probe 必须复用该规则；credential 是有界 opaque bytes，不做 UTF-8 解释。

endpoint policy 是显式的：Completion 与 Provider Probe 使用
`required_explicit`，必须得到可直接请求的合法 endpoint；Session fresh/restore 使用
`optional_sdk_default`，空 `base_url` 表示由 AgentCore SDK 选择协议默认 endpoint，非空值
仍须通过同一 endpoint 校验。调用方不能用空字符串、URL 或模型名触发协议推断。

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
- 编码调用方给出的非零、有界 `max_output_tokens`；
- 解码最终文本、usage 和 stop reason；
- tool/function call、未知 terminal reason 或非文本结果 fail closed。

输出预算在四种 wire dialect 中使用各自的原生字段：

| Protocol | 输出预算字段 |
| --- | --- |
| `openai_responses` | `max_output_tokens` |
| `openai_chat_completions` | `max_completion_tokens` |
| `anthropic_messages` | `max_tokens` |
| `gemini_native` | `generationConfig.maxOutputTokens` |

Completion 不为某个 codec 私设默认预算；每个消费者显式提供自己的有界预算，不从 Provider 或主 Agent 请求继承预算。

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

Completion 使用有界 buffered fetch。共享 HTTP adapter 还支持带有界缓冲的 GET，以及在请求 worker 内借用成功响应 reader 的 GET。视频下载消费后者，reader 和 header 仅在同步回调内有效。请求返回前须等待读取和回调静止，协议与落盘规则由 [AgentCore 集成契约](agentcore-integration.md#host-tools)定义。

## 5. Completion 结果

成功结果只包含：

- `text`；
- `usage`；
- `stop_reason`。

`max_tokens` 表示生成预算耗尽，此时最终 `text` 可以为空；仅有 thinking 的合法截断响应也须保留该终止原因和 usage，不能误归为格式错误。消费者必须先检查 `stop_reason` 再接纳文本，截断结果不能成为标题、连通性成功或审批决定。声称 `end_turn` 却没有最终文本的响应仍拒绝。

失败使用 MetaWork-owned typed union：

- invalid config/request；
- cancelled；
- transport failure；
- Provider HTTP rejection；
- malformed/unsupported response；
- resource limit / out of memory。

Provider 非 2xx 响应按 HTTP status 分类，不把响应正文、credential 或 header 写入错误、日志、event、snapshot 或产品历史。

Transport 的取消、响应缓冲超限和 host allocation failure 分别投影为
`cancelled`、`resource_limit` 与 `out_of_memory`；只有 DNS、连接、TLS、读写、HTTP
格式和未分类 transport failure 进入 `transport_failed`。`Unexpected` 保留为
`transport_failed.other`，不能吞掉前三类既有语义。

## 6. 取消与生命周期

- 每次 `complete()` 使用一个独立 Cancellation token。
- watchdog 或 shutdown 可以从另一线程请求取消。
- Application transport 必须让被阻塞的整次 fetch 返回，并在 `perform()` 返回前等待 I/O 静止。
- 调用线程等待 `complete()` 返回并 join watchdog 后，才能销毁 Completion 和冻结的模型执行绑定。
- Provider Probe 不产生 credential owned copy；它同步把 borrowed binding 交给 Completion，Completion 在返回前完成自己的复制。
- Completion 在对象生命周期内持有一份 credential copy，销毁时 secure-zero；编码后的 sensitive header copy 在请求结束后 secure-zero。
- Session fresh/restore 只为同步 AgentCore 调用取得一份临时 credential copy，并在调用返回的所有路径 secure-zero；Session 对象不保留 credential。

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
- model binding 单字段边界、两种 endpoint policy，以及所有 Session/Completion/Probe 入口在外部调用前的一致拒绝；
- 四种 codec 精确编码调用方的输出预算，零值与超限在 Transport 前拒绝；
- Transport cancellation、response limit、allocation failure 与 unknown failure 保持各自的 typed 结果；
- Provider Probe、自动标题与 permission 审核器使用各自对应的冻结模型执行绑定；
- architecture guard 证明 Completion/Protocol 不导入 AgentCore SDK；
- lifecycle 与 shutdown 验证。

不把真实 Provider 网络或本地测试证书作为普通 CI 依赖。

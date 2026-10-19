# GenerateImage 阶段 A 实施草案

阶段 A 验证 MetaWork Agent 实现的 `GenerateImage` 能通过当前 canonical AgentCore Host Tool ABI 执行：模型发起工具调用，MetaWork 请求本地图片服务，将图片提交到临时 Workspace，工具返回真实文件路径，AgentCore 消费结果并完成 Run。

本文是实施草案，不是 decision record，也不替代规范合同。当前正式产品禁止注册 Host tools；阶段 A 使用隔离测试装配验证能力，不因此开放桌面产品入口。后续正式启用必须收口 Host Tool 能力合同与 Gate。

## 1 范围和完成条件

使用真实 canonical AgentCore、MetaWork 工具实现、现有 HTTP transport 和临时文件系统。对话 Provider、图片服务、模型绑定和 credential 使用确定性测试数据。

阶段 A 完成必须同时取得两类证据：真实 Core 证明工具暴露、权限和执行链；Agent 测试证明身份校验、资源所有权、并发与退出行为。直接调用 callback 的单元测试不能代替真实 Core 链路。canonical 测试必须经过 MetaWork 的 Agent Runtime、Session 和 callback，而不只是通过 SDK 在测试中另造一套执行器。

本阶段不接 Product 生图模型目录、真实 Metask OAuth、远程生成模型、Skill、Renderer、图片预览或 release 打包；不支持参考图、比例参数和批量生成。图片 fixture 只证明传输与保存正确，不证明通用图片完整解码、远端模型质量或真实 Metask 兼容性。

## 2 现有边界

| 依据 | 阶段 A 的约束 |
| --- | --- |
| [AgentCore 集成契约](../agentcore-integration.md#host-tools) | 当前正式 Runtime 保持 `host_tool_count = 0`；测试装配不能成为产品开放能力的替代路径 |
| [AgentCore ABI 消费合同](../agentcore-abi-v1.md)与当前 target 的 repository lock | 使用唯一 staged SDK 和精确匹配的 binary；缺失或不匹配必须失败 |
| [高层架构](../architecture.md#34-agent-与-agentcore) | 工具定义、callback 和协议适配归 Agent；不反向导入 Product、Bridge 或 Application |
| [Product Models 合同](../product-architecture.md#21-models-aggregate-与-account-handoff)与[Account 合同](../account-architecture.md) | Models 的 Metask provider 拥有固定服务地址与模型执行配置，Account 拥有 OAuth authority；Application 只协调 owned 输入，Agent 消费已明确的执行绑定 |
| [Completion transport](../../src/agent/completion/transport.zig)与[Application HTTP 实现](../../src/app/completion_http_transport.zig) | 复用有界、可取消的 HTTP effect，不新增第二套 TLS、redirect 或取消实现 |
| [验证规范](../validation.md) | fake Core 负责精确故障注入，canonical Core 负责真实互操作，二者的证据范围分别报告 |

Host descriptor 的 context 存活到 Runtime 成功销毁。callback 接收的 `RunContext` 与参数只在调用期间借用，不能保存原始指针。非空 Host result 按 SDK 合同恰好释放一次。

Host 工具允许同一 Session 并发调用。当前权限模式下，Host Tool 不提供 Session 级候选；`approval_required` 每次单独审批，`full_access` 按现有模式执行。工具描述和 Skill 都不能授予权限。

## 3 验证链路

```text
本地对话 Provider fixture
  返回 GenerateImage tool_use
        ↓
canonical AgentCore
  工具目录、权限检查、执行调度
        ↓
MetaWork Agent GenerateImage callback
  Run 身份校验、lease、参数检查、容量预留
        ↓
现有 HTTP transport → 本地图片服务 fixture
  返回固定 PNG 的 b64_json
        ↓
Workspace 输出能力
  创建唯一文件、完整写入、提交
        ↓
callback 返回文件路径
        ↓
Provider fixture 校验 tool_result 并返回最终回答
        ↓
Run 完成，所有调用和资源收敛
```

对话 fixture 必须检查实际模型请求中存在工具定义，并在收到可验证的工具结果后才发送最终回答。图片 fixture 记录请求次数、并发情况和取消行为，并检查 model、prompt、数量和合成 Authorization；测试分别校验请求、工具结果及文件字节，不能只依赖最终回答宣称成功。

fixture 固定返回同一张 PNG；同 prompt 双调用用例证明两次独立服务调用和两个文件，不证明两张图片的画面不同。

## 4 工具和执行输入

工具名固定为 `GenerateImage`。阶段 A 的参数 schema 只有必填字符串 `prompt`，设置 `additionalProperties: false`；执行端独立拒绝空白、错误类型、未知字段、重复键和超限输入。

```json
{"prompt":"生成一张测试图片"}
```

测试装配注入独立于对话模型的图片 binding：本地 fixture target、合成 credential、fixture model。它是图片调用所需的窄输入，不借用带有对话 protocol 的 `ModelBinding` 表达 Images Generation。`GenerateImage` 的模型参数只有 `prompt`；model、endpoint、credential、header、数量、返回格式和输出路径均不进入工具 schema。prompt 中出现的 URL、JSON 或文件路径仍是画面描述，不能作为执行配置解析。每次调用生成一张图片。

### 4.1 接口归属和正式地址

`GenerateImage` 是模型可见的工具，Metask Images Generation 是其执行时消费的服务接口。接口地址由 Host 的 Metask provider 配置策略确定，模型和 Skill 不负责指定。

后续正式接线的唯一目标为：

```text
POST https://app.metask-ai.com/v1/images/generations
```

“Metask 适配”在这里包含两项不同职责：Models-owned Metask provider policy 拥有正式服务地址及模型配置，Agent-owned 图片 client 拥有该接口的请求、响应和错误语义。正式接线时由 Models 的唯一机器定义生成固定 target，再通过既有 owner 协调交付 Agent；不在 Product、Agent 和 Application 各维护一份 URL 常量。

正式 target 不接受 Renderer、工具参数、Skill、prompt、环境变量或用户自填 base URL 覆盖，不从对话 Provider 的 base URL 拼接，也不因 source id 或模型名推断。Agent 使用已交付的明确 target，Application transport 不重新选择、拼接或替换服务地址。该目标也不改走网站的 `/api/studio/images` 会话包装接口。

阶段 A 不新增 Models 生产配置或开放真实调用；以上定义后续正式接线需要保持的归属与目标，正式服务可用性仍需后续验证。

### 4.2 测试地址和其他执行输入

阶段 A 只能在 Agent 的隔离测试初始化边界替换 target。测试装配持有刚启动的 loopback HTTP listener，使用它的实际端口，并保持 `POST /v1/images/generations` 的 method 和 path；测试 target 仅接受该 listener 的明确 loopback 地址。测试服务启动失败、地址不合法或调用失败时直接失败，不回退到正式服务。替换的是目标地址，工具实现、图片 codec、HTTP backend 和 Session 生命周期仍使用同一套代码。

测试地址不通过产品配置、通用 Provider 表单或环境变量注入；测试 HTTP 不扩大正式目标必须使用 HTTPS 的约束。真实 OAuth credential 不得用于本地 fixture，测试初始化只接收合成 credential。

| 执行输入或行为 | Owner 与阶段 A 的边界 |
| --- | --- |
| 工具 prompt | 由模型提供有界画面描述；不能改变其他执行输入 |
| 生图模型 | 正式由 Models 解析独立生图选择，阶段 A 由测试装配固定提供；Agent 不发现模型、不取目录首项、不硬编码正式模型，也不沿用对话模型或其选择 |
| credential | 正式来自 Account authorization lease 的 owned 执行副本，阶段 A 只用合成值；不借用当前对话 Provider 的 API Key，不读取 shell 环境或系统凭据作为 fallback |
| HTTP header | 图片 client 按接口编码 Content-Type 和敏感 Authorization header；模型和响应不能追加或覆盖 header，凭证不进入 URL、正文或工具结果 |
| 输出 authority | 测试装配从当前 Session Workspace 派生并持有输出能力；不由模型、图片响应或另一个 Session 提供根目录 |
| 返回文件路径 | 只由输出能力在成功提交后产生，并相对当前 Session Workspace 解释；不得采纳响应里的 URL、路径或建议文件名作为本地写入位置 |
| 发送次数与 deadline | 由 Agent Runtime 的唯一预算定义拥有；模型、服务响应和 per-Run binding 不能提高限制 |
| 服务错误 | 图片 client 只返回本次调用结果；401/403 不授权 Agent 修改 Account、删除 refresh credential、自动登录或换模型重发 |

模型选择与 credential authority 仍是不同事实：即使生图和对话都使用 Metask，Agent 也只消费 Host 明确交付的生图 binding，不能自行从对话配置复用或推导授权。

Agent 在执行准备时取得所需的有界 owned 输入，确保排队或执行不依赖调用方缓冲区；输出 context 的 owner 必须存活至已接纳调用静止。缺少图片 binding 或输出能力时返回 `unavailable`，不得发送网络请求，也不得阻止普通 Text Run。

预算由 Agent Runtime 的一个定义拥有，不在 per-Run context 复制 limits。运行时必须有参数、响应、解码字节、结果、并发内存、发送次数和单次 deadline 上界；测试采用足以容纳固定 fixture 的小预算，并覆盖每个上界。聚合内存预留覆盖 owned prompt、请求、响应、JSON scratch、解码图片和尚未释放的工具结果，不能只计算原始图片。正式生图的数值在后续真实模型验收时确定。

成功工具结果是有界 UTF-8 JSON，例如：

```json
{
  "status": "saved",
  "path": "generated/images/unique-id.png",
  "media_type": "image/png",
  "size_bytes": 123
}
```

实际路径和大小由文件提交结果产生，不能由模型参数或 fixture 回答伪造。该文本 JSON 不等价于 SDK typed `file_refs`；本阶段不合成 CoreEvent、File Changes 或 Bridge 投影。

## 5 图片请求和文件输出

图片 client 编码最小 Images Generation 请求：`model`、`prompt`、`n = 1`、`response_format = b64_json`。本地服务返回与目标接口一致的最小 `data[].b64_json` envelope。

复用 HTTP transport 仅复用网络 effect：Images Generation 不创建文本 Completion，不调用文本 codec，不共享对话请求、Completion 对象或其他调用的 cancellation token，也不自动继承 Completion 的响应大小预算。图片 client 提供自己的有界 buffer 和独立调用取消状态；HTTP backend 保持不跟随 redirect。服务返回重定向或远程图片 URL 时，本阶段明确拒绝，不向新地址转发 Authorization，也不另行下载。

阶段 A 严格检查状态、响应结构、图片数量、Base64 与 PNG 的基本格式边界；检查深度在 client 测试中明确，不把 signature 检查表述为完整可解码验证。client 不得依赖 fixture 的固定 hash、Base64 或尺寸白名单才能成功，固定字节仅用于测试断言。远程 URL 和其他格式明确拒绝，不重新提交生成请求切换返回格式。fixture 图片保持在当前 Core `Read` 图片上限内；阶段 A 不将图片保存成功解释为模型已查看图片。

输出接口只接收图片字节、取消状态和本次有界输出 authority。测试实现持有明确的临时 Workspace 根，使用 Host 生成的唯一文件名，禁止模型控制路径和覆盖已有文件。阶段 A 采用独占创建目标文件、完整写入并成功关闭后才发布路径的最小实现；提交指工具结果可发布，不承诺其他文件系统观察者看不到写入过程，也不承诺掉电持久性。

独占创建失败时不能打开、截断或删除已有文件。测试命名器必须能强制与已有 sentinel 文件冲突，验证文件内容保持不变；不能依靠随机碰撞概率、存在性预检查或普通 rename 证明不覆盖。阶段 A 不为此引入临时文件 rename 协议。

本次独占创建的文件在写入失败或提交前取消时清理；清理失败保留准确的错误事实，不能伪造“已删除”。提交是单调事实：输出接口必须区分尚未提交和已经提交，文件已提交后即使取消、工具结果编码 OOM 或投递失败，也不重新生成、不按未提交路径清理。相同 prompt 的两次合法调用必须产生不同文件。

测试输出实现验证的是该实现的文件行为，以及 Agent 对输出结果的处理；它不证明未来 Product 输出存储的安全、清理和持久化合同。

输出不调用 Native 图片 codec，不等待主线程，不建立跨线程同步解码会合。一般图片容器校验、尺寸提取和缩略图能力留到真实图片接入时设计，优先复用可靠依赖，不为阶段 A 编写三种格式的完整解析器。

## 6 callback 和退出顺序

Runtime-owned context 将 SDK 验证后的 `RunContext` 路由到正确 Session。先取得能够保证 Session 存活的引用，再按现有同步边界验证 raw handle、稳定 Session identity、active Run 和 callback admission。复用现有 Session callback lease，不维护第二套 Session 生命周期。

callback 在 Session lock 外进行 HTTP 和文件操作；所有 borrowed 数据必须在借用有效期内消费，或先有界复制。每条成功、拒绝、取消和异常路径均释放 lease、容量与 owned buffer。

Run 的停止、Session close 和 Runtime shutdown 必须触发图片调用的取消，并唤醒 transport 等待。`Session.close` 不设置 `cancel_requested`，因此取消不能只挂在 `requestTermination` 或该字段上；接线必须覆盖现有终止和唤醒路径，包括 close/shutdown。`wakeUiLocked` 当前只处理 UI 等待，本身不是已存在的通用 effect 取消设施。

登记活动图片调用与检查终止状态必须处在同一 Session 同步边界：先发生终止的调用不得再发请求，先登记的调用必须被取消通知覆盖。退出时注销调用，并保证取消通知不引用已经释放的 token。持锁只进行短状态变更及非阻塞唤醒，不在锁内执行网络、文件写入或 join。除正常取消外，还要测试“获得 callback lease 后、登记 HTTP 前恰好 close”的丢失唤醒竞态。

现有 HTTP port 支持取消，但没有内置 deadline。图片调用必须组合一个独立 deadline，超时请求同一调用的 cancellation；单次超时不得取消其他图片调用或永久阻止当前 Run。按现有 Completion 消费者的 watchdog 方式组合，不增加另一套 HTTP 实现。请求和 watchdog 都退出后才能释放它们引用的输入和 token；测试进程的外部 timeout 只检测挂起，不能代替内部取消实现。

不能假设 Core abort 会自动中断 MetaWork 自有 HTTP。所有等待必须可被取消，且取消和调用静止后才能销毁 context、binding 与输出能力。返回给 Core 的 owned result 保持独立有效，直到对应 release callback；不能在执行 callback 返回时随局部 arena 或 lease 一并释放。普通工具错误和取消后的下一个 Run 必须能重新取得未取消的调用上下文。

正式 Runtime 的注册和 allowlist 在阶段 A 不变。需要的差异只在 Agent 内部测试初始化边界：在 Runtime create 前传入固定 `GenerateImage` descriptor，并在 Session create 时选入同一工具。仅注册 Runtime descriptor 而不更新测试 Session 的 allowlist，不能完成真实调用。

正式初始化与测试初始化共用 Runtime、Session、路由和 lease 实现，只在固定注册数据及测试 binding 上不同；不能各自维护一套 create/close 逻辑。此入口只能由测试装配使用，不增加产品环境变量、命令或任意 Host Tool 注入接口。原有正式初始化“零 Host tools、原工具集合”的回归必须保持通过。若只能先完成独立 SDK probe，其结果只证明 ABI 可用，尚不满足本阶段的 Agent 接线完成条件。

## 7 并发和失败语义

每次合法工具调用都是一次新的生成意图，包括相同 prompt。不建立参数指纹去重、成功结果缓存、in-flight 去重等待和 Run 级封禁。

完成本地校验及容量预留后，在进入 transport 前原子占用本 Run 的发送额度。并发调用不能超发；进入 transport 后没有可靠未发送证据就不返还额度。结果未知的请求同样计入。没有发送资格的调用归还本地内存预留，但不能改变其他调用的发送计数。发送额度在本 Run 静止后于下一次 Run preparation 重置，不按 prompt、工具返回或单次取消重置。容量预留不得排队等待同一 Run 的另一条工具调用释放。

工具内部不自动重试。`outcome_unknown` 只描述本次调用，提示请求可能已被接纳或计费；它不封禁同一 Run 的后续调用。当前 HTTP adapter 的错误名称不证明发送阶段，特别是不能把 `ConnectFailed` 当成“明确未发送”。

| 情况 | 要求 |
| --- | --- |
| 参数、权限、binding 或容量拒绝 | 图片服务请求数为零 |
| 已进入 transport 后网络失败或超时，且无法证明未被接纳 | 返回本次 `outcome_unknown`，不自动重发 |
| 收到明确 HTTP 或格式错误 | 返回有界、安全的本次工具错误；不回传 credential 或原始错误正文 |
| 收到图片但保存失败 | 返回 `output_failed`，不重新生成 |
| 调用取消 | 收敛 HTTP 与输出，按实际发送及提交阶段描述结果，不承诺服务端未生成 |
| 成功 | 返回真实已提交文件，后续相同 prompt 可以再次生成 |

普通失败通过 SDK `HOST_FAILED` 或 `HOST_REJECTED` 成为 `is_error` 工具结果，允许 Core 按正常工具循环继续。非法 ABI 状态或身份合同错误仍按现有依赖失败规则处理。

## 8 实施步骤

| 步骤 | 交付 | 通过条件 |
| --- | --- | --- |
| A1 固定工具实现与隔离装配 | 工具 schema、callback、图片 client、输出 port；Runtime 注册、Session allowlist 及 loopback target 的固定测试初始化 | 工具不依赖 Product；复用现有 Agent 生命周期；正式初始化的零 Host tools 回归通过；测试失败不访问正式服务 |
| A2 canonical Core 成功链路 | 对话与图片 HTTP fixtures、临时 Workspace、重复运行入口 | 工具真实暴露并执行，文件字节正确，tool_result 被 Provider 消费，Run 完成 |
| A3 权限与并发 | 允许、拒绝、unavailable、同参数双调用、跨 Session、额度测试 | 拒绝不发送、调用不串线、不覆盖、不超发 |
| A4 取消与故障 | 阻塞 HTTP、调用登记竞态、deadline、文件冲突与写入失败、提交后编码失败、close/shutdown、结果释放测试 | 等待有界退出；已提交事实保持；资源恰好释放；不依赖主线程；没有自动重发 |
| A5 标准入口与证据 | 当前平台正式验证入口、依赖与执行证据、范围说明 | canonical bundle 缺失明确失败；fake 与真实 Core 结果分别报告；重复运行结果一致 |

建议以 `src/agent/generate_image.zig` 承载工具定义和 callback，以 `src/agent/image_generation.zig` 承载图片请求与响应语义。仅在具体依赖或生命周期需要时拆分更多文件。

HTTP 直接复用现有 port 和 Application backend。若确需提取共享 HTTP leaf，则一次迁移现有消费者，保留唯一实现，不增加同语义的并行端口。本阶段不扩展文本 Completion 的请求或结果合同。

## 9 验收矩阵

| 失败模式或行为 | 证据层 | 必须观察的结果 |
| --- | --- | --- |
| 工具暴露和真实执行 | canonical Core + 本地 Provider/图片服务 | 请求含精确 schema，callback 执行，工具结果到达模型，Run 正常完成 |
| 正式初始化隔离 | 既有 Agent Runtime 回归 | 产品初始化保持零 Host tools 和原工具集合，不因 fixture 或测试配置变为可调用 |
| 工具参数和配置分离 | schema + Agent 参数测试 | `endpoint`、`model`、`credential`、`header`、`path` 等额外字段被拒绝且零请求；prompt 内的 URL 或 JSON 不改变冻结配置 |
| fixture target 限定 | 测试初始化 + 本地服务记录 | 只使用本次 listener 的 loopback 地址和固定 method/path；错误地址或 fixture 失败直接结束，不触发正式网络请求 |
| 输入与 binding ownership | Agent 故障注入 | preparation 后调用方修改或释放缓冲区，已接纳调用仍使用自己的原始副本 |
| 同 prompt 重复调用 | canonical Core | 两次图片请求、两个不同文件，均为真实成功结果；fixture 字节可以相同 |
| 同 Session 并发与跨 Session 隔离 | canonical Core + Agent 测试 | 输出和结果归属正确，额度预留不超限 |
| 权限拒绝或 callback unavailable | canonical Core | 无图片请求，工具得到准确失败，后续 Run/关闭可收敛 |
| binding 不可用 | Agent + canonical Core | 返回 unavailable，普通文本任务仍可执行 |
| 错误 Run、Session identity、关闭后回调 | Agent 故障注入 | 不访问网络或文件，按现有身份合同失败 |
| 非法 JSON、坏 Base64、超限、HTTP 错误 | 图片 client + canonical Core 代表性错误链路 | 无伪造文件与成功；结果有界、无 secret |
| credential 与图片正文的投影边界 | fixture + 工具结果断言 | 合成 credential 仅进入授权的图片 HTTP header；不进入对话模型请求、工具结果或文件名，图片 Base64 不进入工具结果 |
| 重定向和响应不能改变 effect | 真实 HTTP backend + 输出测试 | 不访问 redirect 目标，不下载响应 URL，不采用响应路径或文件名，不向另一目标转发 Authorization |
| 服务错误不改变 Host authority | Agent 故障注入 | 401/403 只形成工具错误，不读取或修改账号、切换模型或重发；之后仍使用 Host 明确交付的配置 |
| 结果未知后继续调用 | canonical Core + 受控网络故障 | 不自动重试；后续明确的新调用仍可执行，未知请求继续占发送额度 |
| 额度和取消状态跨 Run | Agent lifecycle | 当前 Run 不能超发；静止后的下一 Run 取得新额度和未取消的上下文 |
| 强制文件名冲突 | 测试输出实现 + 文件系统 | 失败或有界换名，原文件字节保持；没有打开、截断或删除原文件 |
| 写入失败、提交前后取消、提交后编码失败 | 输出与 lifecycle 故障注入 | 未提交文件清理或准确报告清理失败；已提交文件保留；不自动重新生成 |
| HTTP 阻塞时停止、close、shutdown | 真实 transport + Agent lifecycle | 请求被取消、等待退出、不依赖主线程或 UI drain |
| callback 登记与 close 竞争 | Agent 故障注入 | 先关闭则不发送，先登记则接到取消；不丢唤醒、不使用已释放 token |
| 单次 HTTP deadline | 真实 transport + Agent lifecycle | 请求收敛、watchdog 退出；其他调用和后续调用不被共同取消 |
| Host result ownership | Agent 故障注入 + canonical Core | 非空结果恰好 release 一次，相关 owner 存活到释放完成 |

测试使用确定性同步信号控制并发和取消位置，不以任意 sleep 推断竞态已经发生。并发测试必须在服务端观察到两个请求同时 in-flight，防止串行实现也通过；身份与错误注入先放在可控 Agent 测试，不要求破坏真实 Core 的合法行为来制造错误。任何成功断言都要包含文件内容和服务请求记录；仅检查最终 Assistant 文本不足以证明工具执行。

## 10 验证入口和下一阶段边界

实现时将 Agent 故障用例接入[现有 lifecycle test graph](../../build.zig)，为 canonical Core 链路增加一个明确入口并接入标准 Native graph，不能只保留一次性 probe。按实际依赖变化运行 architecture guard、正式 Native graph 和当前平台 build；遵循[验证规范](../validation.md)，不机械扩大平台矩阵。

验收证据记录实际 target、canonical bundle/lock identity、源码 revision 与 dirty diff、测试输入 identity、请求次数、落盘结果及退出结果。合成 credential 不授予真实服务权限，真实 credential 不进入 evidence。

阶段 A 完成后，再讨论正式 Host Tool Gate、Models 生图目录与选择、真实 Metask binding、通用图片查看及 Skill 分发。正式工具集合变化可能使旧 checkpoint 的 Session grants 失效，届时必须覆盖 restore degraded report；阶段 A 不修改现有历史或权限恢复政策。

本阶段交付为可复用的 MetaWork Agent 工具实现、确定性 fixtures、可重复运行的 canonical Core 入口及对应生命周期回归，不据此宣称桌面产品已经开放生图。

## 11 关键取舍和理由

| 问题 | 取舍与理由 |
| --- | --- |
| 为什么需要两个本地 HTTP fixture | 对话 fixture 触发真正的 Core 工具循环，图片 fixture 验证 MetaWork 的网络与图片处理；直接调用 callback 或注入“生成完成”都不能证明这条链 |
| 为什么不先做 Skill | 工具必须先能独立执行；本阶段没有需要 Skill 才能验证的执行能力，加入它会扩大 catalog 和分发范围 |
| 为什么保留发送计数而不保留指纹 | 计数约束有成本的调用数量，指纹会把合法的再次生成改成复用旧文件 |
| 为什么测试要使用同一个 Agent Runtime 和 Session | 需要验证的正是路由、lease 和关闭行为；独立 SDK harness 可以证明 ABI，但不能证明 MetaWork 接线 |
| 为什么不先实现原子 rename 发布 | 阶段 A 只需不覆盖已有文件且成功后才返回路径；独占创建和失败清理已经能验证输出 port，产品的多读者发布协议尚不在范围内 |
| 为什么暂不读取图片检查画面 | 固定 fixture 没有生成质量需要判断；保存字节和工具结果已覆盖本阶段目标，视觉检查属于后续模型能力验收 |
| 为什么不复用对话模型 binding | Images Generation 的 endpoint 和请求语义独立，借用对话 protocol 会制造错误配置与无意义映射 |
| 为什么工具不接收 endpoint | 服务地址是 Host 的服务和 credential authority，不属于画面描述；正式地址由 Models 的 Metask policy 唯一定义，测试仅在隔离装配中替换为本地服务 |
| 为什么复用 transport 但不复用 Completion | HTTP/TLS 和取消是共同 effect，图片请求、返回及预算是独立协议语义；共享 effect 不应引入文本模型或 codec 依赖 |
| 为什么取消和 deadline 都要验证 | 用户取消不等于请求有时间上界；deadline 也不能证明 close/shutdown 没有丢失取消通知 |
| 为什么阶段 A 不改正式 Host Tool Gate | 先取得真实 Agent 集成证据，再按产品能力变更收口合同，避免把隔离试验自动变成产品开放 |

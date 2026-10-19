# MetaWork 原生生图阶段 B 方案

> 状态：已获实施授权；B0.1 离线前置核对已完成，继续不收费的实施与验证。正式 Host Tool 与设置入口仍关闭，不调用收费服务。B0.2 的 canonical Core 无 grant checkpoint 恢复缺口阻塞正式集合迁移，不阻塞隔离装配中的 B1/B2 实施，见[验证缺口](../validation.md#generateimage-工具集合迁移的恢复缺口)。本文不是 decision record，也不替代领域真源。

阶段 B 交付一个最小正式链路：用户在 Models 设置中明确选择 Metask 生图模型，普通 Task 的模型通过 `GenerateImage` 发起一次图片生成，结果保存到 owning Workspace，工具返回真实文件引用。对话模型与生图模型独立；对话来源为 Custom Provider 的 Task 也可以消费已配置的 Metask 生图能力。

正式开放必须同时满足三件事：固定工具的权限与恢复合同成立，Models 能解析独立且有效的图片执行配置，生产输出与真实 Metask 链路完成验收。仅把生产 `host_tool_count` 改为 1 不构成交付。

## 1 前提与范围

实施前从当前 Git 与 canonical target lock 重新确认依赖身份。方案依据的 MetaWork 基线为阶段 A 评审修复 `b842899e`；阶段 A 的结果预留、发送额度、取消和 release 语义继续适用。

现有约束以 [AgentCore 集成契约](../agentcore-integration.md#host-tools)、[Models 与 Product 协作](../product-architecture.md#21-models-aggregate-与-account-handoff)、[Account lease](../account-architecture.md#4-authorization-lease-与-metask-provider) 和 [工程依赖边界](../project-structure.md) 为准。阶段 A 的试验范围见[阶段 A 方案](generate-image-phase-a.md)。

| 本阶段交付 | 后续阶段处理 |
| --- | --- |
| 固定 `GenerateImage` Host Tool 的正式注册、fresh/restore allowlist、权限和恢复验证 | 任意 Host Tool registry、用户自定义工具和插件发现 |
| Metask 生图目录、独立的可空模型选择、最小设置界面 | Custom Provider 生图、多生图 Provider、Task 专属生图模型选择 |
| 每次调用只接收 `prompt`，生成一张 PNG 到 Workspace | 参考图、编辑、mask、多图、尺寸与质量参数、视频 |
| 复用既有 OAuth 授权与 HTTP backend，直连 Images Generation | 网站会话包装、独立 API Key、专门 OAuth scope 或账号体系 |
| 正式的 Workspace 输出能力、真实结果与安全错误 | Outputs/图片图库、缩略图、自动展示、生成质量评审 |

工具保存图片不等于对话模型已看过图片。阶段 B 不以自动 `Read`、重编码或缩略图补齐识图；当前 Core `Read` 的图片大小限制必须在后续查看请求中正常报告，不能阻止用户保存较大的合法图片。

## 2 已核实的现状与实施前核对

当前 MetaWork 的 `src/product/models/metask.zig` 在解析后排除了声明支持 `images_generations` 或 `videos` 的模型，留下的成员还要求可选对话 protocol。因此不能从现有对话目录恢复生图候选，也不能给图片配置塞一个虚假的 `anthropic_messages` 或 `openai_chat_completions` protocol。

本地 Metask 源码核对点为 `E:/project/metask-ai` 的 `f1dfbdab162defba25b5d8c57c2648728310a68c`：

- `services/gate-control/internal/gateway/handler.go` 注册 `POST /v1/images/generations`，要求 `model:invoke`；`GET /v1/models` 要求 `read`。
- `services/gate-control/internal/gateway/catalog_caps.go` 把图片路径映射到 `images_generations` 端点声明。
- `services/sglang-proxy/images.go` 消费 Images Generation 请求，在允许的 passthrough 路由执行或交给网关内部 Gemini 转换；桌面端不消费上游协议或路由 identity。
- `apps/web/src/app/api/studio/images/route.ts` 是网站登录会话包装，另有字段限制，并请求 URL 结果；它不是桌面 API。

这些是源码事实，不证明该 revision 已部署到正式站点，也不保证某个模型接受 `b64_json`、返回 PNG 或在本阶段预算内完成。B0 固定接口合同与待验证假设，B5 对正式部署和明确选择的模型取得实际证据；未满足时不打开正式能力，不要求先付费生成才能开始本地实现。

## 3 Owner 与依赖边界

| Owner | 拥有的职责 | 不承担的职责 |
| --- | --- | --- |
| Metask 服务 | OAuth scope 执法、目录声明、模型路由、生成与实际计量 | MetaWork 的工具权限、Workspace 文件归属和重试决定 |
| Account | 身份、token refresh、authorization generation、有效 lease 及清零 | 生图模型目录、选项、图片请求或消费者状态 |
| Models | 单一 Metask 服务地址政策、目录用途分类、生图选择、配置持久化、owned candidate | 查询 Task、调用 AgentCore、生成图片、写 Workspace |
| Product Control | Run admission、冻结 candidate、Workspace 输出 authority、可见历史和 provenance | 猜测模型、服务地址、credential 或 tool wire name |
| Agent | 固定工具/schema、Core callback、图片请求与响应语义、预算、取消和结果所有权 | 导入 Models/Account/Product、决定用户默认模型或持久化选择 |
| Application | catalog 及 Run preparation 的 lease handoff、已有 transport 与文件 effect 装配、worker/资源退出顺序 | 在 worker 选择模型、覆盖 endpoint、形成第二套领域政策 |
| Bridge/Renderer | typed 设置命令、无 secret 的状态与模型列表、既有工具/审批展示 | 接收 OAuth token、提交任意 URL/路径/header、解析工具文本授予权限 |

保持既有依赖方向。Models 只发布自己的纯值合同；Product 的既有 Agent adapter 把图片 candidate 转成 Agent 自己的窄执行输入。Agent 不直接 import Models；Task 不 import Models runtime；Account 不 import Models。HTTP port 保持唯一 `agent_http_transport`，不新建图片专用网络实现或文本 Completion。

## 4 正式 Host Tool Gate

### 4.1 两种资格必须分开

**产品能力 Gate** 决定本版本是否正式提供固定 Host Tool。Gate 关闭时，普通 Runtime 继续保持零 Host tools；隔离测试入口不能授予产品能力。

这里的 Gate 是合同变更与合并/发布的验收条件，不新增一个产品运行时开关、持久 Gate 状态、通用 feature registry 或另一套策略控制系统。

**本次 Run readiness** 决定已开放工具是否具有可用执行输入。正式开放后，Runtime 固定注册一个 `GenerateImage`，fresh 与 restore Session 使用同一固定 allowlist。登录、目录、选择或图片配置变化只改变执行输入，不按这些状态增删工具声明，也不隐式修改 Session grants。

没有图片配置的 Run 仍可完成普通对话。Core 的工具权限判断可能先于 Host execute callback，因此缺配置时也可能先出现当次审批：拒绝按既有拒绝路径收口，允许后执行返回有界 `unavailable`，两者都不发送图片请求。不能承诺缺配置一定没有审批，也不为隐藏这次审批动态改变工具集合。不把生图 readiness 加到 New Task、文本 Run、Conversation recovery 或 Custom Provider 的全局 admission 上。

### 4.2 Gate 通过条件

1. 产品范围、owner、安全、权限及恢复合同已获阶段 B 实施授权并更新对应真源。
2. canonical Core 对固定 Host Tool 的注册、并发、permission namespace、once-only response、释放与生命周期证据齐全。
3. Models、Account handoff、Run 冻结与正式输出能力形成真实闭环；测试 sink 不再承担生产输出。
4. 旧工具集合的 checkpoint 在新集合恢复时，权限失效和 typed degraded report 得到验证；没有静默沿用旧 grant。
5. B0 定义的实际服务合同与 B5 的目标平台验收完成，失败语义和收费风险可观察。
6. 发布注册与界面入口同步接通；尚未完成的 UI 不得先显示可用生图能力。

能力注册的精确数据继续归 Agent；不建立环境变量、Renderer boolean、每 Session 任意工具列表或通用 Host Tool 注入接口。实施分支在最终 Gate 提交前，用固定隔离装配验证同一执行代码；该装配不进入 release。最终注册提交同时收口零 Host tools 的旧断言与正式合同，不保留两套 active 产品路径。

B2/B5 的固定候选注册数据仅由测试装配调用同一私有注册函数；真实 App 验证使用既有隔离 automation identity 和正式 backend。无需为此新增生产 candidate mode、另一层 Runtime factory 或可变注册表。B5 在切换普通 Runtime 为唯一正式集合后，必须重跑最终构建产物的相关验收，候选装配证据不能自动覆盖最后的接线差异。长期保留的本地 fixture 入口仍只接收显式 loopback target，不把阶段 A 的地址验证器放宽成通用生产 override。

### 4.3 权限与成本

沿用 Task 的既有 PermissionProfile 映射。人工/自动评审对应的 `accept_edits` 下，必须用 canonical Core 证明 Host 工具会进入审批，不能推断它具有 built-in Workspace Write 的自动允许资格。`full_access` 按 Core 合同执行；不再追加第三套生图审批系统。

Host tool 不提供 Session-scoped grant candidate。界面、自动评审和恢复都不得伪造 `allow_session`；只回答当次合法选择。拒绝、callback unavailable、noninteractive occurrence 的既有 `permission_required/needs_attention` 路径都必须在图片请求与输出文件创建前收口。自动评审输入需要保留本次调用可能收费的事实，但不能声称已知价格或审核器建议是安全证明。

选择生图模型不是一次生成授权。设置操作不发收费 probe；实际请求的计量与余额由 Metask 执法。工具说明明确每次调用都是新的、可能收费的生成意图，同 prompt 两次仍是两次生成。

### 4.4 checkpoint 与旧权限

工具集合及 schema 的变化由 Core 的官方恢复合同处理，不由 Host 自行编造 fingerprint 或改写 checkpoint。B0 必须取得以下真实证据：

- 旧集合且有既存 Session grant 的 checkpoint，恢复到新增工具的集合：核对 `permission.invalidated_rules`、`health`、issues 与 `describe`，不能只看恢复返回成功。
- 没有 grant 的旧 checkpoint、新集合自身的 checkpoint、再次改变工具 schema 的 checkpoint，各自按真实 report 断言；不预设所有恢复都会 degraded。
- 无效权限不被转成允许，后续 `GenerateImage` 再走当前审批。未知、矛盾或无法验证的 report 按依赖合同失败处理。

保留当前 Product 的恢复政策：**合法 degraded Session 可以恢复 Conversation，不可重建的权限保持失效**。不得仅因新增工具导致 grant 失效就销毁可恢复的历史，也不得为了维持旧授权绕过 degraded。新增图片配置不从 checkpoint、旧 tool_result 或历史 endpoint 恢复。

## 5 Models 生图目录与配置

### 5.1 同一目录请求，分别产生候选

继续只用同一个 OAuth `/v1/models` catalog operation，先完整校验已知字段，再分类：

- 对话目录维持当前资格与 protocol 优先级，生图/视频混合模型仍不混进对话设置和 Composer。
- 生图目录要求 `capabilities.endpoints.images_generations.supported == true`。缺失、null、false 不授予资格；不按名字、`output.image`、旧 alias 或目录顺序推断。
- 同时声明对话与图片端点的成员可以进入生图目录，仍按现有规则排除于对话目录。存在视频声明不等于本阶段会调用视频。
- 图片候选不要求对话 protocol。所有目录共用一次有界解析和 catalog generation，不能分别请求后拼出不一致快照。

现有 `ModelEntry.protocol` 与只保存对话成员的结构必须改为可表达独立用途的内部表示；不复制一份宽松 parser，不为图片新增对话 `Protocol` 值。

catalog 加载状态继续共用，候选数量与可解析性按用途分别判断。尤其要验证“Metask 只有生图模型、对话走 Custom Provider”：对话目录的 `no_models` 不能清掉有效图片目录、阻止图片选择或解析。为此只扩展现有 Models aggregate 的字段和投影，不新建生图 Provider Runtime、独立刷新 worker 或第二套 catalog generation。

### 5.2 选择与持久化

新增独立、可空的 Metask 生图选择；不复用全局对话 default、Provider-local 对话 intent 或 Composer 当前模型。

- 初始为未选择，必须用户明确选择；没有隐式首项、硬编码正式模型或“默认图像模型” fallback。
- 只保存一条带 principal 归属的最近显式生图选择，沿用现有单条 Metask intent 的规模。logout 不清空该记录；当前账号与记录不匹配时显示未配置，不采用其模型。新账号显式选择后替换该条记录；返回旧账号只在记录仍属于自己时恢复。阶段 B 不建立多账号历史配置库。清除操作只清当前账号拥有的选择。
- 选中模型被移除或不再合格：保留不可用 intent，发布原因和当前可选列表，等待用户重选；目录合法为空时不复用旧目录给新 resolve 放行。
- 更改生图选择只推进自己的 selection revision，不改变对话选择、Task 对话 execution generation 或正在运行的图片调用。
- Models 用同一个受控持久化事务保存新增可选字段；读取既有 `models.json` 时缺字段表示未配置，其他字段原样保持。不得借本阶段删除既有数据、重置偏好或更改稳定格式/version identity。若需要迁移或双向降级支持，单独说明并取得相应授权。

typed 选择/清除命令只接受 source-qualified `ModelRef` 和所需 expected selection/catalog revision；Host 核对当前 principal 与目录。Renderer 不提交 endpoint、credential、返回格式、文件路径、请求预算或价格。

### 5.3 图片执行 candidate

Models 发布窄的图片配置值，包括 `ModelRef`、Models-owned 明确 target、catalog generation、图片 selection revision 和线性 owned credential。preparation 内另校验 principal 与 authorization generation；这些授权校验字段不进入 Agent、Renderer 或 durable Run history。图片配置不携带对话 protocol，也不伪装为现有文本 `ExecutionConfig`。

图片选择 revision、catalog generation 与 Account authorization generation 分别表示用户意图、目录快照与授权，不互相替代。不借用会随对话 protocol/default 变化的 source generation 作为图片授权证明，也不额外建立一套图片 execution generation、installation registry 或默认 binding reconcile 状态机。

正式 target 只从 Models 的唯一机器定义构造。Agent 自己的输入只有执行所需字段及 output capability；Product adapter 负责跨 owner 转换和 owned copy，不转发 Account Runtime 或 catalog 指针。

## 6 Account 授权与 Run 冻结

现有 Account → Application → Models catalog handoff 保持。仅靠已缓存目录或 Account 状态通知，不能证明 Run 接纳那一刻 token 尚未到 hard expiry；过期本身也不一定改变已缓存的 generation。阶段 B 显式增加一次 **Run preparation 的即时 lease handoff**，这是需要更新 Account 消费合同的地方。

复用现有 Application Models coordinator 提供一个窄的图片 preparation capability：仅当存在已选且目录合格的图片模型时，在主线程调用 Account 的现有 `authorizationLease()`，把 lease 字段借给 Models 的纯输入方法，配合明确的图片选择/目录 revisions 构造 owned candidate，然后清零临时 lease。没有图片配置的文本 Run 不额外获取 token。Models 不 import Account 类型；coordinator 不选择模型、不触发 refresh，也不新建授权 Runtime、缓存的“已登录”布尔值或授权事件总线。图片 credential 直接来自本次 lease，不从旧 catalog token、对话 API Key、环境或网站 cookie 补齐。

Models 必须核对 lease principal、authorization generation 与已接纳 catalog 的授权归属。刷新换代后旧目录仍在或新目录尚未完成时，本次图片能力 unavailable；不每个 Run 重抓目录，也不以 token 内容相同推断授权等价。Account 的当前 lease 获取失败、过期、clock 失败或主体不匹配都形成图片不可用，不能借旧缓存继续发送。

以 **Run admission** 为图片配置冻结点：

1. Product Control 在主线程取得图片选择快照，通过同一 preparation capability 让 Models 结合当前 lease 解析 candidate。Manual、Scheduled occurrence 和内部 follow-up 都走此入口；没有图片配置则冻结本 Run 的图片不可用事实，不能只有 Bridge 发起的 Run 做授权检查。
2. 捕获 owning Workspace 的既有 authority：owner/binding、epoch、已规范化根的有界副本，或已有的目录 lease。此处只冻结授权输入，不新开目录句柄、不创建目录/文件、不增加持久 file identity。图片配置和输出能力随同 Run 输入在同一 preparation 中冻结，不经过可与 prepare 竞态的可变 Session setter。图片配置/Workspace 资格不可用时冻结 unavailable，文本仍可接纳；Run 本身的接纳失败、排队取消或 stale 时释放全部候选。
3. 同一 Run 的多次调用使用该冻结配置；目录更新、设置切换、refresh 和 logout 不修改其 model/credential/output，也不改写发送额度。
4. Core callback、HTTP、watchdog 和文件操作全部静止后释放 Agent 执行副本；Product 为 canonical 脱敏保留的有界副本要等现有 terminal event drain/清理 barrier 完成后再清零。剩余 Host result 独立拥有已编码字节直到 release，不借用这些副本。下一 Run 重新解析；用户在设置中明确变更的选择届时生效。

图片配置不必与整个对话 Session 同寿命，避免既有 Task 永久持有已退出账号的图片 credential。即便沿用 Session 内存放置，也必须是 per-Run 的冻结 owner，不能保留阶段 A 的长寿命测试 binding 作为正式语义。

保留 Account 现有规则：logout 不等待或取消已交付的消费者 binding；已接纳 Run 可以按原配置收口。logout、换账号或授权失效后，后续 Run 无法取得新的 Metask 图片配置，文本任务与 Custom Provider 不受此额外 gate 影响。恢复后下一 Run 也重新解析当前选择，不从历史 source/model 反查旧 credential。

接纳时 lease 有效不保证排队、长 Run 或人工审批等待结束后 token 仍有效。既有 Run 不为图片调用等待 Account、换 token 或重发；服务端的 401/403 正常形成本次工具失败。配置在 preparation 后才恢复可用时，同一 Run 也不临时升级，留到下一 Run。这里保护的是接纳时授权有效与已交付配置不被热改写，不承诺远程凭据在整个 Run 内持续有效。

非 secret 的本次图片模型和配置 revision 可作为 Run/工具 execution provenance 保存；不写 principal credential、token、Authorization header 或凭据 locator。历史 provenance 不是重新执行 authority。

图片 credential 只交图片 client 与执行所需 HTTP effect，不交对话 Provider 或 Core model binding。已有 Product 的 canonical 投影清理必须覆盖本 Run 持有的对话和图片 credential；工具输入/结果、服务错误与清理诊断都不能成为第二条 secret 通道。

## 7 Metask 正式接口接线

唯一正式目标为：

```text
POST https://app.metask-ai.com/v1/images/generations
Authorization: Bearer <本次 owned OAuth access token>
Content-Type: application/json
```

最小请求仍为 `model`、`prompt`、`n = 1`、`response_format = b64_json`。接口地址由 Models provider policy 唯一定义；Agent 拥有该接口的 wire codec、错误分类和调用控制；Application backend 只执行已交付的 URL。

Agent 可验证 target 的 HTTPS、安全 URL 结构和输入边界，但不另存一份正式 URL 常量或按 source id 推断 target。Renderer、Skill、prompt、环境变量和 Custom Provider base URL 均不能覆盖正式目标；prompt 中的 URL/JSON 仍只是画面描述。

不访问 `/api/studio/images`，不解析网站 cookie，不直接访问 Gemini/其他上游，不转发服务返回的文件名、路径或 header。拒绝 redirect 和 URL-only 输出，不向另一个目标转发 credential，也不为了改为另一返回格式重新生成。

401/403 只形成本次有界工具错误，不能调用 Account mutation、删除 credential、切换账号/模型或自行 refresh/retry。明确拒绝与结果未知分别报告，但 HTTP status 本身不构成“肯定没有收费”的证据。诊断仅保留已批准的安全错误码/有界 request reference，不把响应正文或服务端回显复制到日志、对话或 Snapshot。

## 8 实际图片与资源预算

阶段 B 首版仍接受一张 **内联 Base64 PNG**；这是客户端输出范围，不能由目录端点支持推导为所有模型均保证返回该格式。B0 明确请求/响应合同，B5 确认正式部署下明确选择的模型可用。其他模型返回 URL、JPEG/WebP 或不合格 payload 时准确报告不支持，不冒充 PNG、不下载或自动换参数再收费。设置中的目录资格不能被标为“PNG 已验证”；若服务合同根本不能支持本次发布范围的 PNG 输出，应在 B5 停止开放并收窄范围或评审格式扩展，不用一次成功或按模型名硬编码的白名单掩盖差异。

建议生产初值如下；B0 根据服务合同核对，B2 在 Agent 的唯一 limits 定义落实，B5 用真实响应验证是否足够，不接受模型或设置提高：

| 项目 | 建议边界 |
| --- | --- |
| prompt | 16 KiB UTF-8，保持严格参数校验 |
| 单图原始字节 | 10 MiB |
| HTTP JSON 响应 | 16 MiB，包含 Base64 和 envelope |
| 尺寸/像素基本格式边界 | 沿用当前 PNG 结构、CRC 与像素上限；不声称完成解压验证 |
| 单次调用 deadline | Host execute callback 登记后 180 秒，独立 monotonic deadline；不计入此前的人工审批等待 |
| 每 Run 发送额度 | 4 次，不做指纹去重或未知结果重试 |
| Runtime 图片 owned buffer 预算 | 256 MiB，包含解析 scratch、原图、请求与预分配结果，不等于整个进程 RSS 上限 |
| 单 Session 并发调用槽 | 保持 4；固定最大 working reservation 和全局预算实际限制同时接纳量，不增加等待队列 |

响应 16 MiB 的最坏解析 scratch 与解码内存必须计入现有预算公式；不能只提高 HTTP buffer。按当前公式，单调用约 90 MiB，两条最大预留可并存，第三条即时容量拒绝。生产 profile 与测试缩小 limits 使用同一校验，不保留只适合 tiny fixture 的隐含上限。

这些是客户端上限，不是服务端保证。继续使用现有原子预算和固定槽位，不增加 buffer pool、动态调参、等待队列或落盘缓存来提高并发。

沿用阶段 A 评审修复：发送前一次取得 working/result reservation 并分配 owned result；合法最大 Receipt 必须编码得下。提交后不再申请结果容量或堆分配；无法在发送前分配时返回静态 `capacity`。防御性编码失败仍返回有分类的 `outcome_unknown`，release 识别静态存储，不能 free 常量或返回空 `HostToolFailed`。

## 9 正式 Workspace 输出

生产输出由 Product 的 Workspace 文件能力拥有，Application 装配正常文件 effect；Agent 只消费窄 output port。不得把测试 sink 或 Native 主线程图片 codec 直接作为生产输出。

固定输出目录建议为 Workspace 下 `generated-images/`，文件名由 Host 产生，形如 `image-<随机唯一值>.png`；模型和服务响应均不参与选根或命名。receipt 返回真实的 Workspace-relative path、MIME 和字节数。

沿用阶段 A 的单次 `commit(bytes, cancellation)` 输出能力：成功取得并校验图片后，在 callback worker 上按冻结的 Workspace authority 打开/验证根，打开/创建固定子目录、独占创建文件、完整写入并关闭，最后返回 committed receipt。已有目录 lease 可直接使用。文件名、receipt 和所有可能分配失败的本地 metadata 在写入前准备完成，关闭后不追加可失败的步骤。当前 `std.Io.File.close` 不返回错误；写入、必要的同步与归属校验等可失败步骤须放在提交前，不能承诺观察到该 API 不提供的 close 错误。提交不承诺崩溃持久性，不为此引入新的持久化事务。

不在 HTTP 前创建空图片，不引入对外 `prepare/commit/abort` 文件事务、试写协议、文件名预留表或长期 pending output。提前占位也不能保证数分钟后磁盘、配额和写入仍成功，却会增加空文件、取消和崩溃状态。Run preparation 能拒绝已知的 Workspace 资格不可用；它不是文件系统可写性或未来写入成功的承诺。实际目录打开及写入都在 worker，落盘失败可能发生在收费之后，必须准确报告并禁止自动重试。

输出能力只含有界目录 authority 与 I/O 所需 owner，不含可变 Task/Run 指针；期限覆盖全部 callback、文件操作及清理。权限拒绝与 callback unavailable 不调用输出，因此不创建目录或文件。合法输出发生命名冲突时，只能在同一次落盘中有界换一个 Host 名称，不得重发生成请求。

目录打开逐级拒绝 symlink/reparse 跳转，目标文件用独占创建，不能打开或截断已存在文件；不使用普通 rename 证明不覆盖，也不等待 Native loop 图片解码。Windows 的 no-follow 可以成功打开 reparse 对象自身，须检查打开句柄的类型，再执行子目录操作；`resolve_beneath` 在不支持的平台可能被忽略，不单独作为 confinement 证明。用于确认文件身份的创建句柄须具备平台查询 metadata 所需的访问权。复用现有受支持的文件 API，在 Windows 与 macOS 分别验证；缺少所需语义时明确 capability gap，不能以字符串前缀或先检查再创建替代。这里不扩展为对所有持有 Workspace 写权限的并发者提供完整 TOCTOU/原子隔离保证；receipt 表示提交时的文件事实，用户和其他工具之后仍可修改它。

文件提交是单调事实。提交后取消、Core 中止、结果投递失败或历史保存失败都保留已生成文件，不自动再生成。未提交失败只清理本次确实创建且仍可确认归属的文件；发现名称/文件已被替换、移动或无法确认归属时保留现场，不按旧路径删除别人的文件。清理不完整是有界工具错误事实，不能报告已删除；本阶段不新建持久 cleanup debt 服务或后台扫描/自动删除循环。直接写入不承诺其他观察者看不到写入过程，也不承诺崩溃/掉电持久性；崩溃残留不在重启时按文件名前缀擅自删除。

现有单次输出调用应返回能区分 committed receipt、普通失败和清理不完整的有界结果；需要时仅附带本次 Host 生成的相对名称与固定错误码。不要把这些事实压成一个无法区分的 `anyerror`，也不存入并发共享的 `last_error`；这是本次调用的返回值，不是新的恢复系统。结果编码上限同时覆盖成功与失败 metadata。

文件操作必须使用可取消的现有 I/O 并在返回前静止；不在主线程执行阻塞写入。网络取消的阶段 A 证据不能替代文件写入/清理期间的 stop、close、shutdown 测试；平台不支持中断的系统 I/O 不能被表述为已有的严格关闭时限，也不能通过释放仍在使用的目录/文件 owner 掩盖等待。

手动 Workspace 中的生成文件属于用户工作文件，删除 Task 不删除它们。Automatic Workspace 的移除只按既有 Workspace owner 合同执行。文件内容不进入 Task SQL history 或附件原件 store；history 只保存本次工具结果和批准的 metadata。

该写入不会天然产生 Core `File Changes`，因此不合成 CoreEvent、diff、typed file_refs 或“模型已看过图”的事实。本阶段沿用既有工具结果详情展示真实路径；图片卡片、Outputs 和预览扩展另行设计。

## 10 失败、取消与重试

- `unavailable / invalid_arguments / capacity` 及发送前 `cancelled`：不发生成请求；Run preparation 发现目录 authority 不可用也属于未发送。
- 发送后的 transport/超时/取消：`outcome_unknown`，保守计入发送额度，不能声称服务端未生成或未收费。
- 2xx 后无效响应、超限、非支持格式或写入失败：准确报告未得到 committed 文件，并提示生成可能已完成或收费；不把这类失败解释为可安全自动重试。
- 输出已提交：返回 `saved`；该事实优先于随后出现的取消。仅在无法交付完整结果的防御性异常下报告 unknown，并保留文件。

工具说明应把“禁止盲目重试”的提示覆盖所有已经发送、但未能交付 saved receipt 的结果，而不只覆盖某一个错误名。用户或模型后续明确的新调用仍是新意图，不能用 Run 级封禁、成功缓存或指纹去重代替成本说明。

stop、close、shutdown 继续经过同一终止 latch 取消已登记调用。登记、终止检查与注销处在同一 Session lock；HTTP、文件操作和 join 在锁外。单次 deadline 不取消同 Run 的其他调用；返回前等待 HTTP/watchdog 静止，所有 owned 配置与输出随后按真实引用释放。

## 11 最小设置与产品呈现

Models 设置新增独立“生图模型”区域，只列当前 Metask 图片候选，支持明确选择和清除。展示未登录、目录加载/失败、未选择、可用和已选模型不可用；设置页解释生成可能收费、配置对下一 Run 生效、首版输出 PNG。它不展示推测价格、未取得的余额或内部 generation。

不在对话 Composer 的模型列表混入生图模型，不增加生图模式按钮、Skill 入口或 prompt 参数编辑器。没有图片配置时文本输入、发送与历史浏览仍正常。

Bridge 增加专用设置 command 与 secret-free projection，Host 独立验证 revisions 和模型资格。使用既有 Models 状态，不新建 Renderer authority cache。增加的 command 必须同步 `app.zon` allowlist、跨语言 fixture、strict decoder 与测试；不顺带 bump 产品版本或 Bridge revision，若稳定合同确需版本变化则单独申请相应授权。

UI 实施遵循现有设计系统、双语、键盘、深浅主题、窄屏与现有 Task 审批流程。设置选择不触发付费验证，不以配置成功宣称远程服务已经调用成功。

## 12 实施 DAG 与提交边界

| 子任务 | 依赖 | 完成条件与提交边界 |
| --- | --- | --- |
| B0 合同与 canonical 行为核对 | 阶段 A 评审修复 | 固定 API/授权/目录/返回格式合同及正式部署待验证项；取得工具集合变化/Host permission 的真实 Core 证据，核对文件 API 与 Run 即时 lease handoff 合同；不要求收费请求。先提交必要 probe/fixture 与合同收敛，不开放产品 |
| B0.1 合同与离线前置核对 | 阶段 A 评审修复 | 已取得固定工具、权限、文件 API 与 lease 的离线证据；未知正式部署事实保留给 B5；不把已复现的上游恢复缺口当成通过 |
| B0.2 旧工具集合恢复缺口关闭 | B0.1 | 等待上游交付符合官方恢复合同的 canonical artifact，再验证旧无 grant checkpoint；当前不修改 AgentCore 生产者，不放宽消费者校验 |
| B1 Models 生图能力 | B0.1 | 一次 catalog 分出用途、独立可空选择、持久化兼容、精确解析 owned 图片 candidate；对话选择与账号隔离回归通过后提交 |
| B2 Agent 与正式输出 | B0.1 | 独立正式 target 输入、生产预算、owned 目录与单次 commit、无主线程等待、结果单调性；测试替身替换为真实产品输出适配的证据通过后提交 |
| B3 Run 接线与恢复 | B1、B2 | 所有 Run 的即时 lease handoff、冻结/清零/失效、logout/refresh/过期、权限/noninteractive、checkpoint degraded 和并发闭合后提交 |
| B4 Models 设置与 Bridge | B1 | 最小选择区域、typed command/view、allowlist；可独立验证设置组件，发布呈现仍等 B5。受影响 Renderer/Bridge 验证通过后提交，无须等待 B3 才开始实现 |
| B5 正式能力验收与启用 | B0–B4 | 核对正式部署，以明确付费额度验证真实服务/模型；正式集合切换后重新验收最终 App 构建产物、Core、UI 与平台，全部通过才完成发布 Gate |

每个子任务完成后检查其是否可独立验证并及时提交，记录实际 revision 与验证。不能用“最终启用时再补”留下跨 owner 半条 active 链路；保留隔离测试入口只为持续验证明确的 fixture target，不保留旧正式实现。

B0 是 B0.1/B0.2 的父任务。Models、图片 client、生产输出和 Run 接线可在固定隔离装配中继续实施；旧工具集合迁移的证据仍由 B0.2 提供，B0 未完成时 B5 不得通过。这里修正的是实现任务的依赖，不改变正式 Host Tool Gate、SDK 校验、恢复政策或任何 machine guard。

B0 的源码与无收费 fixture 核对可先做；真实付费调用只在用户明确提供可用测试身份、模型和有界生成次数后执行。当前实施授权不包含使用本机已有凭据调用收费服务。

### B0 无收费核对结果

本轮在 Windows x86_64 上使用当前 target lock 验证；生产注册、持久化和设置入口未改变。

| 前提 | 结论 |
| --- | --- |
| Metask 接口归属 | 已复核本地服务源码 revision `f1dfbdab162defba25b5d8c57c2648728310a68c`：目录使用 `read`，图片使用 `model:invoke`，复用既有 scope；地址政策归 Models、请求 codec 归 Agent。源码不证明正式部署，也不保证目录内所有模型返回 PNG；实际模型验收仍属于 B5 |
| Host 权限 | canonical Core 证明 `accept_edits` 下同 prompt 两次调用需要两次 `allow_once`，`allow_session` 非法；请求、PNG 文件与 receipt 同时核对 |
| 工具集合与 schema 恢复 | 旧集合有 Write grant → 新集合：合法 degraded，旧 grant 失效，Write 和 Host 分别审批；新集合不变及只改变 GenerateImage schema：Write grant 保留，Host 仍审批。report/issue/describe 均由官方 SDK 校验；无 grant 的旧 checkpoint 存在[上游矛盾 report](../validation.md#generateimage-工具集合迁移的恢复缺口)，**B0 尚未完成** |
| 即时 lease | Account 的现有能力在不变更 authenticated 状态或 generation、且没有通知的情况下，仍会拒绝 hard expiry 与时钟不可用的新 lease；已有 owned copy 保持独立寿命。App → Models 的一次 Run preparation handoff 按 §6 实施，不消费 catalog 缓存 token |
| 文件 API | Windows 实测 exclusive 创建不覆盖，no-follow + 句柄类型可识别 junction，打开文件的 identity 可区分名称被替换。只是 B2 的 API 前提，不是生产 sink 验收；macOS 与真实文件取消/清理仍待后续验证 |

B0 的离线探针已独立提交；无 grant checkpoint 的合法恢复证据必须由 canonical 依赖修复后补齐。不得把“测试准确断言了拒绝”当成 B0 通过。B1/B2 的实施只依赖已完成的 B0.1，正式集合切换及发布继续受 B0.2 和 B5 约束。

## 13 验收矩阵

| 边界 | 必须观察到的证据 |
| --- | --- |
| 正式注册 | 普通 Runtime 只注册固定 GenerateImage，fresh/restore 集合一致；缺配置不增删声明；未知工具不可执行 |
| Models 解析 | 对话/生图/混合/视频/空目录及非法字段；只按明确 endpoint 分类；仅有图片模型不被对话 no_models 挡住；无第二目录 worker/generation |
| 设置事务 | stale revision、跨账号、选择/清除/移除/重启恢复、写失败/结果未知；不改变对话 default，不丢既有配置 |
| 来源独立 | Custom 对话 + Metask 图片、无图片配置的正常文本、未登录/过期的新图片 resolve 拒绝 |
| 配置所有权 | 即时 lease 与目录 principal/generation 匹配；到 hard expiry 但通知尚未发生、refresh 后目录未完成、Scheduled/follow-up 也重新验证；冻结后切换/logout/等待过期不热更新；执行及 terminal drain 各自清零 |
| 权限 | accept_edits、full_access、自动评审、deny/unavailable、无 Session candidate、Scheduled noninteractive；拒绝时零请求且零新输出 |
| restore | 旧集合有/无 grants、新集合、schema 变化；核对 typed report/describe，合法 degraded 保留 Conversation、旧权限失效且后续重新审批 |
| 正式请求 | fixture 记录 method/path/独立 model/prompt/n/b64 格式/header；正式 smoke 证明 OAuth scope、部署目标、真实结果和服务请求 reference |
| 费用与失败 | 一次调用一次请求，同 prompt 两次两个文件；unknown/401/403/429/5xx/超限/不支持格式不自动重试、切模型或变更 Account |
| 文件 authority | Manual/Automatic、不同 Task/Session、冲突、symlink/reparse、目录权限、write/同步/cleanup 故障及 close 前后的取消；HTTP 前无占位图片，替换文件不被误删；请求记录与文件字节/receipt 同时验证 |
| 结果可靠性 | 最长合法路径/JSON 转义、最小内存预算并发、发送前 OOM、提交后禁用分配、Core release、提交与取消/投递失败；没有无 detail 的误导失败 |
| 取消与预算 | 大于 A fixture 的量级、超时、同时在途、HTTP/文件写入/清理期间 stop/close/shutdown、登记竞态；I/O/watchdog 静止，下 Run 重置，不依赖 UI drain |
| 产品呈现 | 设置选择、不可用提示、已有审批/工具详情、两种语言/主题/窄屏/键盘；不泄漏 credential/Base64，不伪造 File Changes 或看图事实 |

B1–B4 按失败模式运行最小充分 owner/跨 owner 测试。新能力涉及共享装配、工具集合和持久化时运行 architecture guard、正式 Native graph、受影响 Renderer/Bridge suite、当前平台 build 与 packaged vertical。Windows/macOS 的路径与 lifecycle 具有独立失败模式，分别验收；一个平台通过不升级另一个平台的能力状态。

本地 fixture、fake Core、真实 Core、真实 Metask、真实平台分别报告证据范围。source/target lock、源码 revision/diff、输入 identity、请求数、实际文件与退出结果应可定位；缺少 canonical bundle 明确失败。真实服务的权限、格式、计量事实与平台专项保留长期证据，普通可重复测试不另建静态覆盖清单。

## 14 真源更新与仍需确认的事项

实施时按实际合同分别更新，本文不先改变它们：

- `docs/requirements.md`：图片能力、独立设置、文本不被图片 readiness 阻塞、输出与收费语义。
- `docs/product-architecture.md`：Models 用途/选择、owned candidate、Run 冻结与输出 owner；沿用合法 degraded recovery。
- `docs/account-architecture.md`：明确 lease 从仅 catalog 消费扩展到一次 Run 图片 preparation 的 handoff；Account 不拥有图片领域逻辑，已交付 Run 不热撤权。
- `docs/agentcore-integration.md`：固定正式 Host Tool、fresh/restore allowlist、permission 与 callback 输入生命周期。
- `docs/renderer-bridge-contract.md`、`docs/ui-design.md`：最小设置 command/view 和可观察行为；`app.zon` 只登记真实新增 command。
- `docs/validation.md`：正式接线与平台/外部服务证据，替换“只覆盖测试 sink”的相应能力结论。
- Completion、架构/目录或 ABI 文档仅在其合同实际改变时更新；复用原有 transport、同一 owner 内新文件不构成机械同步理由。

进入 B1 前由 B0 收口：API 的 OAuth/b64/PNG 合同、Run 即时 lease handoff 的 owner 边界、canonical 工具集合变化的实际 report、平台文件 API 的可用语义。正式部署、具体模型的 PNG/大小/deadline 与最终产物行为留到 B5 的真实验收；不能用“一个模型曾成功”推导目录内所有模型的格式保证。

如果这些前提不成立，应停在对应能力边界，提出必要的最小合同调整。不得改用网站接口、伪装模型、下载未知 URL、扩大 OAuth scope、取消安全文件校验或忽略 restore report 来交付表面成功。

## 15 复盘后的设计取舍

| 自问 | 保留或删减的理由 |
| --- | --- |
| 为什么 Gate 不做成运行时开关 | 本阶段只批准一个固定工具。增加持久开关和候选产品模式，会引入额外工具集合、恢复组合与验证职责；合并/发布验收和固定测试装配已足够 |
| 为什么有 catalog lease 还要在 Run preparation 检查 | Account 的 `authorizationLease()` 会即时检查 hard expiry 和 principal，而缓存目录或通知不是该时刻的证明；一次窄 handoff 补齐缺口，不需要新的授权服务 |
| 为什么生图选择独立，却不建另一套 execution registry | 用户意图确实与对话不同，但 per-Run owned candidate 已覆盖执行与清理；新增 registry/generation/reconcile 没有独立职责 |
| 为什么不为每个账号维护图片配置历史 | 当前 Metask intent 是单条 principal 绑定记录；单条生图记录已满足不串账号，跨账号历史 profile 不属于阶段 B |
| 为什么不在收费前创建占位文件 | 占位只能验证当时的一次创建，不能保证未来写入；它制造额外空文件与回收状态，仍无法消除生成后落盘失败。单次 commit 和准确错误语义更直接 |
| 为什么 logout 不取消已接纳 Run | 这是现有 owned binding 的合同；新 lease 接纳检查与已交付执行收口是两条边界，不能用新增工具偷偷实现热撤权 |
| 为什么不能只在 worker 结束时清空全部图片 secret | 尚未 drain 的 canonical 事件仍需脱敏；执行副本与投影清理副本各自按真实静止点释放，不能提前清空也不能让 Session 永久持有 |
| 为什么 B0 不要求付费，B4 不依赖 B3 | 本地合同实现不依赖一次真实生成，设置域也不依赖 Run 接线完成；实际部署/模型和最终产物留在 B5 验收，消除不必要的实施串行 |

保留的复杂度只对应可观察失败：独立选择避免串模型，即时 lease 防止新 Run 使用失效授权，固定工具集合稳定恢复，owned 输出与结果预留保护文件事实。其余通用注册、缓存、事务和回收系统均不在本阶段引入。

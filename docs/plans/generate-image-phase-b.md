# MetaWork 原生生图阶段 B 方案

> 状态：待评审的实施方案。阶段 A 及评审修复已完成；本次只整理阶段 B，不开放正式 Host Tool、不调用收费服务，不修改规范、持久格式或现有 Gate。本文不是 decision record，也不替代领域真源。

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

这些是源码事实，不证明该 revision 已部署到正式站点，也不保证某个模型接受 `b64_json`、返回 PNG 或在本阶段预算内完成。B0 必须固定部署合同和至少一个可验收模型；未满足时不打开正式能力。

## 3 Owner 与依赖边界

| Owner | 拥有的职责 | 不承担的职责 |
| --- | --- | --- |
| Metask 服务 | OAuth scope 执法、目录声明、模型路由、生成与实际计量 | MetaWork 的工具权限、Workspace 文件归属和重试决定 |
| Account | 身份、token refresh、authorization generation、有效 lease 及清零 | 生图模型目录、选项、图片请求或消费者状态 |
| Models | 单一 Metask 服务地址政策、目录用途分类、生图选择、配置持久化、owned candidate | 查询 Task、调用 AgentCore、生成图片、写 Workspace |
| Product Control | Run admission、冻结 candidate、Workspace 输出 authority、可见历史和 provenance | 猜测模型、服务地址、credential 或 tool wire name |
| Agent | 固定工具/schema、Core callback、图片请求与响应语义、预算、取消和结果所有权 | 导入 Models/Account/Product、决定用户默认模型或持久化选择 |
| Application | lease handoff、已有 transport 与文件 effect 装配、worker/资源退出顺序 | 在 worker 选择模型、覆盖 endpoint、形成第二套领域政策 |
| Bridge/Renderer | typed 设置命令、无 secret 的状态与模型列表、既有工具/审批展示 | 接收 OAuth token、提交任意 URL/路径/header、解析工具文本授予权限 |

保持既有依赖方向。Models 只发布自己的纯值合同；Product 的既有 Agent adapter 把图片 candidate 转成 Agent 自己的窄执行输入。Agent 不直接 import Models；Task 不 import Models runtime；Account 不 import Models。HTTP port 保持唯一 `agent_http_transport`，不新建图片专用网络实现或文本 Completion。

## 4 正式 Host Tool Gate

### 4.1 两种资格必须分开

**产品能力 Gate** 决定本版本是否正式提供固定 Host Tool。Gate 关闭时，普通 Runtime 继续保持零 Host tools；隔离测试入口不能授予产品能力。

**本次 Run readiness** 决定已开放工具是否具有可用执行输入。正式开放后，Runtime 固定注册一个 `GenerateImage`，fresh 与 restore Session 使用同一固定 allowlist。登录、目录、选择或图片配置变化只改变执行输入，不按这些状态增删工具声明，也不隐式修改 Session grants。

没有图片配置的 Run 仍可完成普通对话；模型调用图片工具时得到有界 `unavailable`，且不发送图片请求。不把生图 readiness 加到 New Task、文本 Run、Conversation recovery 或 Custom Provider 的全局 admission 上。

### 4.2 Gate 通过条件

1. 产品范围、owner、安全、权限及恢复合同已获阶段 B 实施授权并更新对应真源。
2. canonical Core 对固定 Host Tool 的注册、并发、permission namespace、once-only response、释放与生命周期证据齐全。
3. Models、Account handoff、Run 冻结与正式输出能力形成真实闭环；测试 sink 不再承担生产输出。
4. 旧工具集合的 checkpoint 在新集合恢复时，权限失效和 typed degraded report 得到验证；没有静默沿用旧 grant。
5. B0 定义的实际服务合同与 B5 的目标平台验收完成，失败语义和收费风险可观察。
6. 发布注册与界面入口同步接通；尚未完成的 UI 不得先显示可用生图能力。

能力注册的精确数据继续归 Agent；不建立环境变量、Renderer boolean、每 Session 任意工具列表或通用 Host Tool 注入接口。实施分支在最终 Gate 提交前，用固定隔离装配验证同一执行代码；该装配不进入 release。最终注册提交同时收口零 Host tools 的旧断言与正式合同，不保留两套 active 产品路径。

B2/B5 如需验证正式 target，只允许隔离 automation identity 的固定 GenerateImage 候选装配，调用同一注册函数和正式 backend。它不接受任意 Host Tool，也不能从 release 或环境变量到达；B5 通过后删除这项阶段条件，让普通 Runtime 走唯一正式配置。长期保留的本地 fixture 入口仍只接收显式 loopback target，不把阶段 A 的地址验证器放宽成通用生产 override。

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

### 5.2 选择与持久化

新增独立、可空的 Metask 生图选择；不复用全局对话 default、Provider-local 对话 intent 或 Composer 当前模型。

- 初始为未选择，必须用户明确选择；没有隐式首项、硬编码正式模型或“默认图像模型” fallback。
- 选择按现有 Metask principal 归属规则隔离。同一账号回来可恢复自己的 intent，换账号不继承另一个账号的选择。
- 选中模型被移除或不再合格：保留不可用 intent，发布原因和当前可选列表，等待用户重选；目录合法为空时不复用旧目录给新 resolve 放行。
- 更改生图选择只推进自己的 selection revision，不改变对话选择、Task 对话 execution generation 或正在运行的图片调用。
- Models 用同一个受控持久化事务保存新增可选字段；读取既有 `models.json` 时缺字段表示未配置，其他字段原样保持。不得借本阶段删除既有数据、重置偏好或更改稳定格式/version identity。若需要迁移或双向降级支持，单独说明并取得相应授权。

typed 选择/清除命令只接受 source-qualified `ModelRef` 和所需 expected selection/catalog revision；Host 核对当前 principal 与目录。Renderer 不提交 endpoint、credential、返回格式、文件路径、请求预算或价格。

### 5.3 图片执行 candidate

Models 发布窄的图片配置值，概念上包括：模型 identity、Models-owned 明确 target、source/catalog/图片 selection revision 和线性 owned credential。它不携带对话 protocol，也不伪装为现有文本 `ExecutionConfig`。

正式 target 只从 Models 的唯一机器定义构造。Agent 自己的输入只有执行所需字段及 output capability；Product adapter 负责跨 owner 转换和 owned copy，不转发 Account Runtime 或 catalog 指针。

## 6 Account 授权与 Run 冻结

沿用 Account → Application → Models catalog 的 lease handoff。Account 仍只拥有身份、generation、token 与有效期；图片 client 不读取系统凭据、环境变量、对话 API Key 或网站 cookie。

Models 只在当前授权资格、principal 与来源 generation 有效时解析新的图片 candidate。B0 要验证 hard expiry 与授权失效时新的图片 resolve 已关闭；若现有 Application/Models 收敛存在空窗，应在该 owner 边界修正，不能让 Agent 查询 Account 或在同步 tool callback 中触发登录/刷新。

以 **Run admission** 为图片配置冻结点：

1. Product Control 在主线程读取当前图片选择及 readiness，按精确 revisions 解析 candidate；没有图片配置则冻结本 Run 的图片不可用事实。
2. 准备 owning Workspace 的窄输出 authority，并有界转成 Agent-owned Run 输入。图片配置和输出 authority 随同 Run 输入在同一 preparation 中冻结，不经过可与 prepare 竞态的可变 Session setter。图片配置/输出资格不可用时冻结 unavailable，文本仍可接纳；Run 本身的接纳失败或 stale 时释放全部候选。
3. 同一 Run 的多次调用使用该冻结配置；目录更新、设置切换、refresh 和 logout 不修改其 model/credential/output，也不改写发送额度。
4. Run 静止后，清零图片 credential 并释放输出 authority。下一 Run 重新解析；用户在设置中明确变更的选择届时生效。

图片配置不必与整个对话 Session 同寿命，避免既有 Task 永久持有已退出账号的图片 credential。即便沿用 Session 内存放置，也必须是 per-Run 的冻结 owner，不能保留阶段 A 的长寿命测试 binding 作为正式语义。

保留 Account 现有规则：logout 不等待或取消已交付的消费者 binding；已接纳 Run 可以按原配置收口。logout、换账号或授权失效后，后续 Run 无法取得新的 Metask 图片配置，文本任务与 Custom Provider 不受此额外 gate 影响。恢复后下一 Run 也重新解析当前选择，不从历史 source/model 反查旧 credential。

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

阶段 B 首版仍接受一张 **内联 Base64 PNG**；这是客户端输出范围，不能由目录端点支持推导为所有模型均保证返回该格式。B0 要确认至少一个明确选择的模型在该请求下可用。其他模型返回 URL、JPEG/WebP 或不合格 payload 时准确报告不支持，不冒充 PNG、不下载或自动换参数再收费。扩大格式需要可靠依赖和独立验收，不复制完整图片解码器。

建议生产初值如下；B0 根据服务合同核对，B2 在 Agent 的唯一 limits 定义落实，不接受模型或设置提高：

| 项目 | 建议边界 |
| --- | --- |
| prompt | 16 KiB UTF-8，保持严格参数校验 |
| 单图原始字节 | 10 MiB |
| HTTP JSON 响应 | 16 MiB，包含 Base64 和 envelope |
| 尺寸/像素基本格式边界 | 沿用当前 PNG 结构、CRC 与像素上限；不声称完成解压验证 |
| 单次调用 deadline | 180 秒，独立 monotonic deadline |
| 每 Run 发送额度 | 4 次，不做指纹去重或未知结果重试 |
| Runtime 图片 owned buffer 预算 | 256 MiB，包含解析 scratch、原图、请求与预分配结果，不等于整个进程 RSS 上限 |
| 单 Session 并发调用槽 | 保持 4；固定最大 working reservation 和全局预算实际限制同时接纳量，不增加等待队列 |

响应 16 MiB 的最坏解析 scratch 与解码内存必须计入现有预算公式；不能只提高 HTTP buffer。按当前公式，单调用约 90 MiB，两条最大预留可并存，第三条即时容量拒绝。生产 profile 与测试缩小 limits 使用同一校验，不保留只适合 tiny fixture 的隐含上限。

沿用阶段 A 评审修复：发送前一次取得 working/result reservation 并分配 owned result；合法最大 Receipt 必须编码得下。提交后不再申请结果容量或堆分配；无法在发送前分配时返回静态 `capacity`。防御性编码失败仍返回有分类的 `outcome_unknown`，release 识别静态存储，不能 free 常量或返回空 `HostToolFailed`。

## 9 正式 Workspace 输出

生产输出由 Product 的 Workspace 文件能力拥有，Application 装配正常文件 effect；Agent 只消费窄 output port。不得把测试 sink 或 Native 主线程图片 codec 直接作为生产输出。

固定输出目录建议为 Workspace 下 `generated-images/`，文件名由 Host 产生，形如 `image-<随机唯一值>.png`；模型和服务响应均不参与选根或命名。receipt 返回真实的 Workspace-relative path、MIME 和字节数。

为在收费前发现本地输出故障，把输出拆成具体的两步能力，而非通用事务框架：

1. **prepare**：Core 允许工具调用后，在 callback worker 上验证目录 authority，拒绝 symlink/reparse 跳转或不支持的安全打开方式；独占创建本次目标文件并返回线性 pending output。冲突只可有界换一个 Host 名称；不能打开、截断或删除 sentinel。此时尚未发送 HTTP。
2. **commit/abort**：成功取得并校验图片后完整写入、关闭，再返回 committed receipt；失败或提交前取消只关闭、清理自己新建的文件。pending output 必须恰好 commit 或 abort 一次。

准备 output 与预分配结果失败都发生在图片请求前。输出能力只含有界 Workspace/root authority 和文件 owner，不含可变 Task/Run 指针；借用期限覆盖所有并发 callback、HTTP、watchdog 和清理。权限拒绝与 callback unavailable 不进入 output prepare，因此不创建目录或文件。

不使用普通 rename 证明不覆盖，不等待 Native loop 图片解码。目录验证应使用现有受支持的安全文件 API，并在 Windows 与 macOS 分别验证；如果所需语义缺失则明确 capability gap，不以字符串前缀或先检查再创建替代。

文件提交是单调事实。提交后取消、Core 中止、结果投递失败或历史保存失败都保留已生成文件，不自动再生成。未提交清理失败必须保留可诊断的真实 debt/结果，不能报告已删除。直接写入不承诺其他文件观察者看不到写入过程，也不承诺崩溃/掉电持久性；崩溃残留不在重启时按文件名前缀擅自删除。

手动 Workspace 中的生成文件属于用户工作文件，删除 Task 不删除它们。Automatic Workspace 的移除只按既有 Workspace owner 合同执行。文件内容不进入 Task SQL history 或附件原件 store；history 只保存本次工具结果和批准的 metadata。

该写入不会天然产生 Core `File Changes`，因此不合成 CoreEvent、diff、typed file_refs 或“模型已看过图”的事实。本阶段沿用既有工具结果详情展示真实路径；图片卡片、Outputs 和预览扩展另行设计。

## 10 失败、取消与重试

- `unavailable / invalid_arguments / capacity` 及发送前 `cancelled`：不发生成请求；本地输出准备失败也应明确属于未发送。
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
| B0 合同与 canonical 行为核对 | 阶段 A 评审修复 | 固定服务部署/授权/目录/返回格式/时限合同；取得工具集合变化及 Host permission 的真实 Core 证据；整理精确规范修改清单。先提交 probe/fixture 和合同收敛，不开放产品 |
| B1 Models 生图能力 | B0 | 一次 catalog 分出用途、独立可空选择、持久化兼容、精确解析 owned 图片 candidate；对话选择与账号隔离回归通过后提交 |
| B2 Agent 与正式输出 | B0 | 独立正式 target 输入、生产预算、output prepare/commit/abort、无主线程等待、结果单调性；测试替身替换为真实产品输出适配的证据通过后提交 |
| B3 Run 接线与恢复 | B1、B2 | Run 冻结/清零/失效、logout 与下一 Run、权限/自动评审/noninteractive、checkpoint degraded 行为和并发均闭合后提交 |
| B4 Models 设置与 Bridge | B1、B3 | 最小选择区域、typed command/view、allowlist 与现有 Gate 呈现一致，受影响 Renderer/Bridge 验证通过后提交 |
| B5 正式能力验收与启用 | B0–B4 | 真实 App composition、canonical Core、实际服务与平台证据通过；最后一个正式注册与发布入口提交，关闭阶段 Gate |

每个子任务完成后检查其是否可独立验证并及时提交，记录实际 revision 与验证。不能用“最终启用时再补”留下跨 owner 半条 active 链路；保留隔离测试入口只为持续验证明确的 fixture target，不保留旧正式实现。

B0 的源码与无收费 fixture 核对可先做；真实付费调用只在用户明确提供可用测试身份、模型和有界生成次数后执行。此方案整理不授权使用本机已有凭据调用收费服务。

## 13 验收矩阵

| 边界 | 必须观察到的证据 |
| --- | --- |
| 正式注册 | 普通 Runtime 只注册固定 GenerateImage，fresh/restore 集合一致；缺配置不增删声明；未知工具不可执行 |
| Models 解析 | 对话/生图/混合/视频/空目录及非法字段；只按明确 endpoint 分类，旧对话列表与 protocol 优先级不回归 |
| 设置事务 | stale revision、跨账号、选择/清除/移除/重启恢复、写失败/结果未知；不改变对话 default，不丢既有配置 |
| 来源独立 | Custom 对话 + Metask 图片、无图片配置的正常文本、未登录/过期的新图片 resolve 拒绝 |
| 配置所有权 | preparation 后修改/释放调用方 buffer；中途设置切换、catalog 更新、logout 不改已接纳 Run；下一 Run 取得新配置或 unavailable |
| 权限 | accept_edits、full_access、自动评审、deny/unavailable、无 Session candidate、Scheduled noninteractive；拒绝时零请求且零新输出 |
| restore | 旧集合有/无 grants、新集合、schema 变化；核对 typed report/describe，合法 degraded 保留 Conversation、旧权限失效且后续重新审批 |
| 正式请求 | fixture 记录 method/path/独立 model/prompt/n/b64 格式/header；正式 smoke 证明 OAuth scope、部署目标、真实结果和服务请求 reference |
| 费用与失败 | 一次调用一次请求，同 prompt 两次两个文件；unknown/401/403/429/5xx/超限/不支持格式不自动重试、切模型或变更 Account |
| 文件 authority | Manual/Automatic、不同 Task/Session、强制命名冲突、symlink/reparse、目录权限、prepare/write/close/cleanup 故障；请求记录与文件原始字节、receipt 同时验证 |
| 结果可靠性 | 最长合法路径/JSON 转义、最小内存预算并发、发送前 OOM、提交后禁用分配、Core release、提交与取消/投递失败；没有无 detail 的误导失败 |
| 取消与预算 | 大于 A fixture 的真实量级、超时、同时在途、stop/close/shutdown、登记竞态；HTTP/watchdog 静止、下 Run 重置，不依赖 UI drain |
| 产品呈现 | 设置选择、不可用提示、已有审批/工具详情、两种语言/主题/窄屏/键盘；不泄漏 credential/Base64，不伪造 File Changes 或看图事实 |

B1–B4 按失败模式运行最小充分 owner/跨 owner 测试。新能力涉及共享装配、工具集合和持久化时运行 architecture guard、正式 Native graph、受影响 Renderer/Bridge suite、当前平台 build 与 packaged vertical。Windows/macOS 的路径与 lifecycle 具有独立失败模式，分别验收；一个平台通过不升级另一个平台的能力状态。

本地 fixture、fake Core、真实 Core、真实 Metask、真实平台分别报告证据范围。source/target lock、源码 revision/diff、输入 identity、请求数、实际文件与退出结果应可定位；缺少 canonical bundle 明确失败。真实服务的权限、格式、计量事实与平台专项保留长期证据，普通可重复测试不另建静态覆盖清单。

## 14 真源更新与仍需确认的事项

实施时按实际合同分别更新，本文不先改变它们：

- `docs/requirements.md`：图片能力、独立设置、文本不被图片 readiness 阻塞、输出与收费语义。
- `docs/product-architecture.md`：Models 用途/选择、owned candidate、Run 冻结与输出 owner；沿用合法 degraded recovery。
- `docs/agentcore-integration.md`：固定正式 Host Tool、fresh/restore allowlist、permission 与 callback 输入生命周期。
- `docs/renderer-bridge-contract.md`、`docs/ui-design.md`：最小设置 command/view 和可观察行为；`app.zon` 只登记真实新增 command。
- `docs/validation.md`：正式接线与平台/外部服务证据，替换“只覆盖测试 sink”的相应能力结论。
- Account、Completion、架构/目录或 ABI 文档仅在其合同实际改变时更新；复用原有 lease/transport、同一 owner 内新文件不构成机械同步理由。

进入 B1 前必须由 B0 收口：正式部署是否接受当前 OAuth 和 b64 请求；至少一个明确模型是否满足 PNG/大小/deadline；硬过期时新 resolve 的授权收敛是否可靠；canonical 工具集合变化的实际 report；平台安全文件打开语义是否齐全。

如果这些前提不成立，应停在对应能力边界，提出必要的最小合同调整。不得改用网站接口、伪装模型、下载未知 URL、扩大 OAuth scope、取消安全文件校验或忽略 restore report 来交付表面成功。

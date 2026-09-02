# MetaWork Account 架构

> 状态：Account Product owner、其消费的 Metask 合同与持久化边界的 source of truth。
>
> 本文定义 Account 语义收敛后的目标合同；实现必须以一次性 hard cut 收口，不得保留旧 execution/replacement 路径、兼容字段或隐式提交判断。

## 1. 文档职责

本文定义 `src/product/account.zig` 与 `src/product/account/` 的内部职责、领域状态、事务、effect、持久化提交、恢复、并发和生命周期，同时锁定 MetaWork 实际消费的 Metask OAuth、HTTP catalog 及 Account persistence 合同。Account 产出的 `Protocol`、`ExecutionTarget` 与 `ExecutionConfig` 使用 Product Execution 发布的纯合同；其通用语义和 Model Connection owner 由 [Product 架构](product-architecture.md)定义。以下事实由其他规范独占：

- 产品可见行为、默认模型与 Task 的关系见[产品需求](requirements.md)；
- Account 与 Application、Workbench、Bridge、Agent 的跨 owner 协作见[Product 架构](product-architecture.md)；
- Renderer 展示和交互见[UI 设计规范](ui-design.md)；
- wire command、Snapshot 与 transport 见[Renderer Bridge 合同](renderer-bridge-contract.md)；
- 测试层、验证入口和平台证据见[验证规范](validation.md)。

本文不复制上述外部合同。同一事实发生变化时，先修改拥有该事实的规范，再检查本文的不变量和实现是否仍成立。

## 2. Owner 与模块边界

Account 是独立 Product owner，拥有：

- OAuth/refresh token 生命周期和当前已验证 Metask identity；
- Metask private catalog attempt、secret-free committed/candidate catalog 与默认 API/model selection；
- Metask credential/source generation、默认选择 preference 及其 commit/recovery；
- 在自身事实完整时构造一次性的 credential-bearing Metask source candidate；
- Account command/completion 合法性、attempt identity、deadline/cancel 语义、effect queue 和 mailbox；
- 唯一 canonical、无 secret 的 `AccountView` 与 `AccountFact`。

Account 不拥有：

- Native SDK、窗口、WebView、socket listener、平台 timer 实现或文件系统具体实现；这些由 Application 通过 `ports.zig` 注入窄 capability；
- Product 默认来源、active `ExecutionConfig`、Product execution generation、replacement、Schedule scrub、Workspace、Task、Run、Session admission 或历史；
- user-managed Model Connection registry、credential vault、connection generation、测试状态、默认 binding 和 persistence health；这些属于 Product Control 持有的 Execution aggregate；
- AgentCore Runtime、Session、Conversation、provider transport 和协议解析；
- Bridge transport、Renderer 临时状态或 UI continuation policy。

依赖方向固定为：

```text
contract.zig                 Account 脱敏合同；消费 Product Execution 纯合同
catalog/credential/*         Account-owned Metask 领域值与持久化策略
state.zig                    纯事务状态与 transition decision
runtime.zig                  aggregate、effect admission、completion 与 commit
ports.zig                    Account 所需的窄平台 capability

Application adapter → Account ports
Application coordinator → Account Runtime + Workbench public API
Workbench / Bridge → Account contract
Product Execution contract → Account catalog adapter
```

`runtime.zig` 可以组合 Account 子模块，但不得成为 Application facade；`state.zig` 不调用平台、Workbench、Bridge 或 AgentCore。

## 3. 核心领域事实

### 3.1 Committed identity

只有通过当前 token 严格验证的 `/me` identity 才能进入 committed state。saved identity、Renderer identity、旧进程 projection 和 preference owner 都不能建立 authenticated identity。

显式登录替换、refresh 和 logout 是 identity transaction。新 token rotation 一旦 durable 提交，后续失败不得恢复已作废 token；新 identity 未验证前不得覆盖 committed identity。

### 3.2 Committed Metask preference 与 source authority

已提交 Metask 默认值由以下事实组成：

```text
api_key_id
default_model
metask_source_generation
```

`metask_source_generation` 是 account、API Key、credential、protocol 与 endpoint authority 的非零不透明 identity，只用于相等比较。它不表达顺序，也不因同一 source 下的默认模型变化而改变。它不是 Product execution generation，不进入 Renderer `AccountView`，也不能直接写入 Task binding。

默认模型是 Account preference，只影响之后创建的 Task。Task 当前模型及历史 Run 模型归 Workbench；Account 不改写既有 Task。

### 3.3 Catalog slots

Account 同时最多拥有两个 secret-free `PublicCatalog` slot：

- `committed`：当前可发布、可用于 admission 校验的目录；
- `candidate`：绑定唯一 catalog attempt、尚未提交的目录。

含完整 API Key secret 的 `CatalogSession` 只属于当前 private catalog attempt，不进入 `AccountView`，也不等同于任一 public slot。

`committed` 与 `candidate` 必须由 Account aggregate 共同拥有。每个 `PublicCatalog` slot 同时拥有自己的 `model_catalog_api_key_id`；copy、promotion、restore、clear 与 projection 必须原子维护该 owner，禁止从 transaction phase 或 selected state 重新推导。effect driver 只执行 I/O，不拥有 committed 产品目录。candidate 必须携带 attempt identity；陈旧 completion 不能覆盖、提升或清除另一个 attempt 的 slot。

### 3.4 Product Execution boundary

Account 只把已验证的 Metask API Key、catalog selection 和外部 `group.platform` 解析为 Product Execution 合同中的线性 `OwnedSourceCandidate`：显式 protocol、固定 endpoint、model、credential、Account source generation 与 `metask:<api-key-id>` 服务实例引用。candidate 不含 Product execution generation。Account 不定义通用 protocol enum，不发布 Model Connection command/view，不保存 Model Connection registry，也不拥有其 credential capability。

默认 execution source 的选择、Model Connection 生命周期、两种 source 的 replacement 和服务实例引用通用语义由 [Product 架构 §2.1](product-architecture.md)独占。Account 不定义、保存或发布厂商类别，也不存在 `ProviderKind`、协议反推或双重校验路径。

### 3.5 MetaWork 消费的 Metask 合同

MetaWork 是 Metask Account API 的消费方，不拥有或修改 Metask 服务端实现。正式客户端只接受以下固定 OAuth public-client 合同：

| 项目      | 固定值                                                 |
| --------- | ------------------------------------------------------ |
| Flow      | OAuth 2.0 Authorization Code + PKCE S256               |
| Authority | `https://napi.metask-ai.com`                           |
| Authorize | `https://napi.metask-ai.com/oauth/authorize`           |
| Token     | `https://napi.metask-ai.com/oauth/token`               |
| Revoke    | `https://napi.metask-ai.com/oauth/revoke`              |
| Client ID | `metawork-app`，无 `client_secret`                     |
| Scope     | `metawork:use`                                         |
| Redirect  | `http://127.0.0.1:{dynamic_port}/auth/callback`        |
| Identity  | bearer `GET https://napi.metask-ai.com/api/v1/auth/me` |

Account 只生成 CSPRNG `state` 与 PKCE verifier，只接受 S256 challenge。callback 只绑定 IPv4 loopback 动态端口，不依赖 `localhost` DNS、不绑定 wildcard，只接受一次精确路径的 `GET`，严格解析 query、拒绝重复或 unknown 参数，并以 constant-time 比较 `state`。token response 必须有界解码并包含非空 `access_token`、每次必需的新 `refresh_token`、Bearer `token_type`、正整数 `expires_in`、精确 scope 与非空 `account_id`；服务端可以增加未消费 metadata。refresh token 每次成功刷新都轮换，rotation durable commit 后不得恢复旧 token。

只有 `/me` 返回 `code = 0`、数值 `data.id` 的十进制文本精确匹配 token `account_id`，且 `data.username` 是非空有界 UTF-8 时，Account 才能提交 authenticated identity。明确的 `401/403` 删除无效 refresh token并进入 `signed_out`；网络、deadline、`429` 或 `5xx` 保留当前 refresh token并发布重试入口，不得回退到 saved identity。

Metask catalog 使用以下固定路径：

- OAuth Bearer `GET https://napi.metask-ai.com/api/v1/keys?page=1&page_size=100`；只接受完整单页结果，item 必须具有稳定 id、name、secret、status、group identity 和完整 group，且 item/group 均为 `active`；
- 选中 API Key 后以该 Key 作为 Bearer 请求 `GET https://napi.metask-ai.com/v1/models`；拒绝缺失或非法消费字段、重复 model id、`has_more = true`、超限字段与超限集合；
- 两条路径都不发送 Profile header，不读取或持久化 `profile_id`，也不接受 Renderer、环境变量或任意 URL 覆盖；
- decoder 允许服务端增加未消费 metadata，但所有已消费字段、分页、集合和字节上限必须严格验证。

API Key catalog success 必须为 `code = 0`、`message = "success"` 和完整分页对象；model catalog success 必须为有界 list root 与 `data[]`。Account 在当前会话中以 token `account_id + API Key id` 证明 catalog 和 execution credential 归属，自动 refresh 与冷启动不得静默切换账号。

Account 从 `/v1/models` 消费每个模型的 `max_input_tokens`、`max_tokens`（输出上限）与 `capabilities`，并随同一 API Key 的 catalog slot 发布无 secret 的 typed metadata。token 上限只接受 `u64` 范围内的 JSON 整数；缺失、null 或零表示未知，不推导总 context window。能力声明消费 `image_input`、`pdf_input`、`batch`、`citations`、`code_execution`、`structured_outputs` 的 `supported`，以及 `thinking.supported` 和 `thinking.types.{adaptive,enabled}.supported`、`effort.supported` 和 `effort.{low,medium,high,max}.supported`、`context_management.supported` 和 `context_management.{clear_thinking_20251015,clear_tool_uses_20250919,compact_20260112}.supported`。声明值只接受 boolean 或 null；缺失或 null 保持未知，不能转换成 false，已消费字段类型错误拒绝本次目录替换。

这些值是服务端声明，不等同于已验证的运行能力、MetaWork 功能开放 gate 或 AgentCore 的执行预算；`structured_outputs` 不表示图像、音频等输出模态。元数据跟随 candidate/committed 目录原子替换，不按 model id 跨 API Key 复用，不新增持久化；最小恢复目录在刷新前保持未知。`owned_by`、`anthropic_family_tier`、日期以及 root 额度字段不用于推断模型厂商或能力。手工 Model Connection 的 model discovery 范围不因此改变。公开 wire shape 由 [Renderer Bridge 合同](renderer-bridge-contract.md) 定义。

Metask managed `ExecutionTarget` 只从选中 API Key 的精确 `group.platform` 形成，不根据模型名、显示名或列表顺序推断：

| `group.platform` | Protocol                  | Fixed target URL                                 |
| ---------------- | ------------------------- | ------------------------------------------------ |
| `anthropic`      | `anthropic_messages`      | `https://napi.metask-ai.com/v1/messages`         |
| `openai`         | `openai_chat_completions` | `https://napi.metask-ai.com/v1/chat/completions` |
| `gemini`         | `gemini_native`           | `https://generativelanguage.googleapis.com`      |

其他 platform fail closed。OAuth token、PKCE verifier、authorization code、完整 authorize URL、API credential 和 Authorization header 不得进入 Renderer、Bridge、日志、Snapshot 或产品历史。

Gemini fixed target 是 AgentCore Gemini Native client 使用的服务基址；AgentCore 负责追加 model 与 `streamGenerateContent` operation path、认证 header 和请求格式，Account 不实现 provider transport。

## 4. 事务状态模型

Account 只允许一个前台 mutation transaction。实现必须使用封闭的 sum type 表达事务，不得用多个互相独立的 enum、nullable attempt、pending 字段和布尔位构造隐式笛卡尔积。概念模型为：

```text
Transaction =
  none
  | login(LoginTransaction)
  | token_refresh(RefreshTransaction)
  | catalog(CatalogTransaction)
  | default_model(DefaultModelTransaction)
  | source_resolution(SourceResolutionTransaction)
  | logout(LogoutTransaction)
```

每个非 `none` transaction 自包含：

- 非零 attempt identity；
- 当前阶段和该阶段唯一合法的 pending facts；
- 是否存在 worker/effect、是否仍允许取消；
- 成功、明确失败、取消、deadline 和 outcome unknown 的 terminal 规则。

Zig 实现必须把 transaction kind 与阶段表达为一个封闭 tagged union；catalog/default-model variant 直接携带 attempt identity 与 bounded pending facts，`reloading_models` 是独立 variant。transaction 写入必须直接构造具体 variant 或调用 variant-specific constructor；`OperationKind`/`AttemptKind` 只能作为派生 projection，禁止以二元组重新拼装 union。committed preference authority 可以表达 `none | ready | recovery`，但 recovery 只冻结新的 preference/default mutation；token refresh、纯 catalog refresh 与 logout 仍可 terminal 收口，recovery catalog refresh 不得自动选择、写 preference 或产生 candidate。

Catalog transaction 使用封闭阶段：

```text
loading_keys
choosing_key
loading_models
reloading_models
choosing_model
preparing_execution
```

“用户在模型加载期间重新选择 API”必须进入 `reloading_models`，不能用旁路布尔位附着在另一个阶段。是否存在 committed execution 由 committed default 是否存在直接表达；不能再用独立 `preparing | ready | reconfiguring` 状态与 transaction stage 重复编码。

公开的 `AccountState`、`CatalogState`、`canCancel` 与 Metask catalog 都是 committed aggregate 与 transaction 的派生 projection，不是内部状态机的第二份真相。`catalog_generation` 只用于 Renderer selection optimistic concurrency；任何使 selection 输入失效的 account、catalog owner 或 catalog contents 变化都必须提升它。Account source generation 只进入 secret-free authority fact 与 source candidate。新 Task admission、默认/active execution 与 replacement 状态由 Product Control 的 Execution projection 派生，Account 不发布也不缓存这些决定。

## 5. Prepare、effect 与 commit

所有 command 和 completion 都先产生不可变的 `PreparedAccountChange`，概念上包含：

```text
next aggregate state
canonical AccountFact
optional effect
CatalogIntent
PreferenceIntent
optional Account source authority fact
optional owned source candidate
```

显式 intent 为封闭类型：

```text
CatalogIntent =
  committed
  | candidate
  | promote_candidate
  | discard_candidate
  | clear_all

PreferenceIntent = unchanged | commit_pending | clear
```

精确 symbol 可以随实现调整，但以下约束不可改变：

- State/Account aggregate 是 intent 的唯一决策者；
- Runtime 不从 `AccountFactKind`、公开 `CatalogState`、operation 名称或 effect tag 反推 catalog commit；
- Coordinator 不从 Renderer command 名称或 Account effect tag 反推 Product replacement；
- `AccountFactKind` 只描述已观察事实，不控制 slot、persistence 或 execution 提交；
- preference shadow 只按显式 `PreferenceIntent` 提交或清除，不得从 fact kind、effect tag 或 pending 值存在性推断；
- `CatalogIntent.candidate` 保留当前 attempt 的私有 catalog session；`promote_candidate`、`discard_candidate` 和 `clear_all` 都是 terminal intent，Runtime 必须在已接纳的 terminal effect 完成 dispatch、cancel/join 达到 quiescence 后销毁其中的 API Key secret，并在本次 Account commit handoff 返回前完成；
- prepared transition 被拒绝或 effect admission 失败时不得修改 committed aggregate；
- completion 产生的下一 effect admission 失败时，先提交已经观察到的外部结果，再从该 committed phase 产生唯一 terminal failure。

主线程跨 owner 顺序由 [Product 架构](product-architecture.md#21-execution-aggregate-与-account-handoff)定义。Account 内部 terminal commit 必须一次应用 state、catalog intent 和 preference shadow；本地构造的 credential-bearing candidate 在 preference durable commit 与 Account terminal commit 成功后，通过 no-fail sink 线性转移给 Product。Coordinator 不得读取、复制或持有具体配置，Product 的 scrub/install 结果也不得回写 Account。

## 6. 关键事务

### 6.1 登录与 identity replacement

登录、token rotation、`/me` identity 和后续 catalog bootstrap 是连续的用户路径，但不是一个可整体回滚的事务：

1. OAuth code exchange 得到 token rotation；
2. refresh token durable commit；
3. 使用当前 token 验证 `/me`；
4. 原子提交 identity；
5. 以独立 catalog transaction 恢复或请求 Metask preference，并在完整时构造 source candidate。

第 2 步成功后不能回滚旧 token。第 4 步成功但 catalog 失败时保持 authenticated identity，并发布可恢复 catalog failure。显式替换 identity 时，旧 credential execution 不得与新 identity 混用。

### 6.2 Catalog refresh

普通 refresh 从新的 private `CatalogSession` 构造 candidate public catalog。若 committed API/model 仍有效，则以 `promote_candidate` 提交新目录，不写 preference、不改变 source generation，也不决定 Product 是否替换 execution。

若 committed API 或模型已离开目录，transaction 停在对应选择阶段；不得自动切换到另一 credential authority。取消或明确失败使用 `discard_candidate` 返回 committed default。

### 6.3 API Key 或 credential authority 变化

credential-bearing Account preference mutation 是完整 Account transaction；本节明确取消旧合同中 Product scrub 对 Account preference commit 的前置 admission：

```text
load/validate candidate catalog
→ select API and model
→ construct complete owned source candidate without persistence
→ generate new Metask source generation
→ durable preference commit
→ exact reread when outcome is unknown
→ atomically promote Account state, catalog intent and preference shadow
→ publish secret-free authority fact
→ no-fail transfer candidate ownership to Product
```

Account candidate construction 与 preference persistence 是两个独立阶段；构造 worker 不得写 preference。candidate 构造、catalog membership 和 Account persistence 任一明确失败都由 Account secure-zero candidate 并保留旧 committed preference；persistence outcome unknown 按 §7 精确重新观察持久化真相。Account terminal commit 之后的 Product sink 必须 no-fail 接管 candidate；Schedule scrub、Product generation 分配、安装、pending/recovery 与 Task admission 全由 Product 决定，任何失败都不回滚 preference 或补写 Account error。

Bridge 不发布由 Account 拥有的默认来源切换 command。Product-owned “使用 Metask” command 可以请求一个非 Bridge 的 Account source-resolution operation；它只能按当前 committed API、model 与 source generation 重建 candidate，不能选择新 tuple、生成新 generation、调用 preference writer或读取 Product state。Product 决定 candidate 是安装、暂存还是销毁。

### 6.4 同一 API Key 下修改默认模型

默认模型变化是独立 preference transaction，不是 catalog transaction，也不是 credential execution replacement：

1. 使用 committed catalog 和 expected catalog generation 校验目标模型；
2. transaction 保存 pending model，committed selection 不变；
3. 原子写入同一 owner、API Key 和 source generation，仅替换 `model_id`；
4. 写入成功后提交默认模型；
5. 明确失败丢弃 pending model；
6. outcome unknown 重新读取 preference 后决定提交、回滚或进入 recovery。

该 transaction 不提升或清空 candidate catalog，不决定 Product replacement，也不替换 credential。Account 提交后发布新的 authority fact 与同 source candidate；Product 根据 desired/active binding 独立决定新 Task admission。既有 Task、Run、历史阅读和导航不受影响。重复选择当前模型是幂等 no-op。

## 7. Persistence 与恢复

Account persistence 服从[高层架构的持久化权威与故障语义](architecture.md#37-持久化权威与故障语义)。当前实现使用无版本 hard cut，不读取、迁移或兼容旧 manifest、slot、`account.json` 或旧 credential family；无法识别的既有数据不进入当前 Account state，也不被描述为已经迁移，具体清理由本节既有冷启动规则决定：

- secure credential service identity 为产品 Bundle ID 加 `.account`，automation 构建在编译期使用 `.automation.account`；Metask refresh token 的固定 account name 是 `metask-refresh-token`；
- 数据目录中的 `preferences.json` 精确保存 `selection_owner_account_id`、`api_key_id`、`model_id` 和非零 `metask_source_generation`；它不保存 display name、access token、API credential、protocol、base URL 或完整 `ExecutionConfig`；包含旧 `execution_generation` 的文件无条件失效并按冷启动规则清除，不迁移、不备份、不 alias decode；
- production 与 automation 的数据根和 Account credential service 在编译期隔离；任何一侧不得读取另一侧的 preference 或 credential；
- preference 写入使用同目录临时文件、文件 sync、原子 rename 和提交确认；不存在双写、运行时 fallback 或隐式迁移。

refresh rotation 与 preference 是独立 commit。refresh response 成功后必须先替换 secure refresh token；后续 identity、catalog 或 preference 失败不得恢复已作废的旧 token。logout 固定先删除 refresh token，再删除无 secret preference；本地退出不依赖 remote revoke 成功，refresh token 已删除后即使 preference 删除失败也不能继续使用旧 identity。

冷启动只依赖 refresh token：不存在 token 时直接进入 `signed_out`；存在时先 refresh 并提交 rotation，再以 `/me` 建立当前 identity，最后决定 preference 是否可复用。preference 缺失、损坏、owner 不同或 catalog membership 失效只清空默认选择，不影响已验证 identity，也不能制造 account mismatch。Model Connection 的独立恢复不参与 Account identity 判定。

Account persistence effect 区分以下结果：

- `committed`：磁盘真相已确认，可以提交内存；
- `definite_failure`：磁盘未提交，保留旧 committed state；
- `outcome_unknown`：不得假设成功或失败，必须重新读取持久化真相。

默认模型写入 outcome unknown 后：

- 读取到完整新 preference：提交 pending model；
- 读取到完整旧 preference：回滚 pending model；
- 缺失、损坏、owner/API/generation 不匹配或第三种值：进入 preference recovery，禁止新的 preference/default mutation；token refresh、纯 catalog refresh 与 logout 仍可执行。Account 不决定新 Task admission，也不停止既有 Task。

credential-bearing preference 的重读同样只有三个结果：完整 candidate tuple（owner、API、model、source generation 全部一致）允许 Account terminal commit；完整旧 tuple 明确 abort 并保留旧 preference；缺失、损坏或第三种 tuple 必须 abort、secure-zero candidate 并进入 recovery。不得自动重放非幂等 persistence；任何路径都只能产生一个 terminal Account revision。

`saved_preference` 只能是已观察持久化真相的 Account-owned shadow，不能与 committed selection 分别更新。恢复成功、提交成功和明确清除必须由 prepared transition 的显式 `PreferenceIntent` 在同一个 Account commit 中同步两者；进入 preference recovery 时必须清除不再受磁盘观察证明的旧 shadow，后续同 owner 登录不得复用该值。

## 8. Projection 与安全

`AccountView` 是 Account aggregate 一次生成的 canonical projection。State transition 只提供无 catalog 的内部 base view；只有 Runtime 可以结合显式 `CatalogIntent`/当前 slot 生成公开 `AccountFact`，并在返回 prepared 或 committed view 前强制执行 `validateView()`。禁止公开 State 半成品，也禁止根据公开 fact 反推 slot 后再补齐。

每个 prepared 和 committed view 都必须满足 `contract.validateView()`：

- ready selection 在对应 public catalog 中精确出现一次；
- model catalog owner 与 API selection 一致；
- candidate 字段只来自当前 transaction；
- catalog slot owner 与 `catalog_generation` 自洽；
- signed-out/checking/authorizing projection 不泄漏 identity、catalog 或 selection；
- projection 永不包含 token、API Key secret、credential、PKCE、authorization code、header 或 locator。

Renderer acknowledgement 不是 committed fact。Renderer reload、Bridge disconnect 或本地 timeout 不取消 Host transaction；恢复后只消费最新 canonical snapshot。

## 9. 并发、取消与 shutdown

- 每个 Account attempt 有唯一 identity、Host deadline 和最多一个 terminal completion；
- worker 只通过有界 mailbox 交付 owned completion，不调用 Workbench、Bridge 或 WebView；
- stale completion 必须销毁其 secret/owned payload，不能改变 transaction 或 catalog slots；
- credential 与 open-browser effect 只经 Application 注入的 Native SDK 主线程 capability 执行；网络、OAuth loopback wait、deadline 与 cancellation 在有界 Account worker 和 Application byte-transport port 上收口；
- 取消只在 transaction 明确允许的阶段进入；credential/preference persistence 一旦可能提交即跨过取消边界；
- mailbox collision、notification failure和 malformed completion 必须收口为当前 attempt 的明确失败，不能永久 wedged；
- `metask_platform_unsupported` 只表示已验证 catalog 中的 Metask platform 无法映射到受支持协议；无法进一步归类但必须终止当前 Account attempt 的 Account-owned mailbox、平台 capability 或 effect 失败使用 `account_operation_failed`。Account error space 不包含 Task/Session/Execution 占用语义；
- shutdown 先停止新 command、取消 timer、cancel/join attempt、消费或销毁 mailbox、清空 private secret，再清 committed/candidate catalog 和 Runtime-owned credential，最后断开 ports；
- Account `deinit` 不执行仍依赖平台 capability 的 effect。

## 10. 必须保持的回归不变量

Account inline tests 覆盖纯 transaction transition、intent、projection、codec 和 ownership；Application coordinator tests 只覆盖必须跨 Account 与 Workbench 才能观察的 gate/transfer；Renderer tests只覆盖公开交互。至少长期保护：

- 登录后自动完成首个可用默认配置；
- GLM 默认 → GPT API → 自动模型 → 同 API 下选择另一 GPT 模型不 crash；
- 模型 preference 成功、明确失败、outcome unknown 三类结果；
- preference recovery 清除旧 shadow，避免同 owner 重新登录恢复出未经磁盘证明的默认值；
- 纯模型变化不改变 source generation，重启后恢复新模型；
- Metask account、API Key、credential、protocol 或 endpoint authority 变化生成新 source generation，并只在完整 Account 成功后发布；
- catalog refresh、取消、park/reload 和 stale completion 的 slot 行为；
- candidate model-load failure park 后再次 reload/fail 仍发布合法 view，catalog owner 不从 transaction 推导；
- preference recovery 中 token refresh、纯 catalog refresh 与 logout 可 terminal 收口，refresh 不自动写 preference 或产生 candidate；
- identity replacement、effect admission failure、deadline 和 shutdown 在所有终止路径平衡 gate、attempt、secret 和 catalog；
- catalog promote/discard/clear terminal handoff 在 effect quiescence 后清除私有 secret session，catalog cancel 同步丢弃 candidate slot 与 attempt identity；
- 每个 prepared/committed `AccountView` 都通过 runtime decode 等价的合同校验。

实现收口基线：`Transaction` 是唯一可写事务状态；Runtime 直接拥有 committed/candidate public catalog 与 candidate attempt identity；每个 public slot 自己拥有 model catalog owner；默认模型使用独立 durable preference transaction；Account prepared output 不含 Product execution/replacement intent。`fact.kind` catalog completion、effect-driver committed catalog、ready 模型直接 mutation、command/effect gate 推断、`candidateCatalogActive`、组合 operation/attempt 写入 API和 Product failure → Account error 路径均不得以兼容或 fallback 名义存在。

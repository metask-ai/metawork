# MetaWork Account 内部架构

> 状态：Account Product owner 的内部架构 source of truth。
>
> 当前实现已按本文完成 Account transaction kernel 硬切；后续变更必须继续满足本文不变量，不得恢复历史组合状态或隐式提交判断。

## 1. 文档职责

本文定义 `src/product/account.zig` 与 `src/product/account/` 的内部职责、领域状态、事务、effect、持久化提交、恢复、并发和生命周期。以下事实由其他规范独占：

- 产品可见行为、默认模型与 Task 的关系见[产品需求](requirements.md)；
- Account 与 Application、Workbench、Bridge、Agent 的跨 owner 协作见[Product 内部架构](product-architecture.md)；
- Metask OAuth、HTTP catalog、Provider、ExecutionTarget、`preferences.json` 字段和平台持久化合同见[Metask Account API 合同](metask-account-contract.md)；
- Renderer 展示和交互见[Workbench UI 设计](workbench-ui-design.md)；
- wire command、Snapshot 与 transport 见[Renderer Bridge 合同](renderer-bridge-contract.md)；
- 测试层、验证入口和平台证据见[验证规范](validation.md)。

本文不复制上述外部合同。同一事实发生变化时，先修改拥有该事实的规范，再检查本文的不变量和实现是否仍成立。

## 2. Owner 与模块边界

Account 是独立 Product owner，拥有：

- OAuth/refresh token 生命周期和当前已验证 Metask identity；
- Metask private catalog attempt、secret-free committed/candidate catalog 与默认 API/model selection；
- Metask credential execution generation、默认选择 preference 及其 commit/recovery；
- user-managed Model Connection registry、credential locator、connection generation 和 persistence health；
- Account command/completion 合法性、attempt identity、deadline/cancel 语义、effect queue 和 mailbox；
- 唯一 canonical、无 secret 的 `AccountView` 与 `AccountFact`。

Account 不拥有：

- Native SDK、窗口、WebView、socket listener、平台 timer 实现或文件系统具体实现；这些由 Application 通过 `ports.zig` 注入窄 capability；
- Workbench 默认 ExecutionConfig、replacement gate、Workspace、Task、Run、Session admission 或历史；
- AgentCore Runtime、Session、Conversation、provider transport 和协议解析；
- Bridge transport、Renderer 临时状态或 UI continuation policy。

依赖方向固定为：

```text
contract.zig                 纯产品合同，无平台和 runtime 依赖
catalog/credential/model_*   Account-owned 领域值与持久化策略
state.zig                    纯事务状态与 transition decision
runtime.zig                  aggregate、effect admission、completion 与 commit
ports.zig                    Account 所需的窄平台 capability

Application adapter → Account ports
Application coordinator → Account Runtime + Workbench public API
Workbench / Bridge → Account contract
```

`runtime.zig` 可以组合 Account 子模块，但不得成为 Application facade；`state.zig` 不调用平台、Workbench、Bridge 或 AgentCore。

## 3. 核心领域事实

### 3.1 Committed identity

只有通过当前 token 严格验证的 `/me` identity 才能进入 committed state。saved identity、Renderer identity、旧进程 projection 和 preference owner 都不能建立 authenticated identity。

显式登录替换、refresh 和 logout 是 identity transaction。新 token rotation 一旦 durable 提交，后续失败不得恢复已作废 token；新 identity 未验证前不得覆盖 committed identity。

### 3.2 Committed Metask default

已提交 Metask 默认值由以下事实组成：

```text
api_key_id
default_model
credential_execution_generation
```

`credential_execution_generation` 是 provider、base URL 和 credential authority 的非零不透明 identity，只用于相等比较。它不表达顺序，也不因同一 API Key 下的默认模型变化而改变。

默认模型是 Account preference，只影响之后创建的 Task。Task 当前模型及历史 Run 模型归 Workbench；Account 不改写既有 Task。

### 3.3 Catalog slots

Account 同时最多拥有两个 secret-free `PublicCatalog` slot：

- `committed`：当前可发布、可用于 admission 校验的目录；
- `candidate`：绑定唯一 catalog attempt、尚未提交的目录。

含完整 API Key secret 的 `CatalogSession` 只属于当前 private catalog attempt，不进入 `AccountView`，也不等同于任一 public slot。

`committed` 与 `candidate` 必须由 Account aggregate 共同拥有。effect driver 只执行 I/O，不拥有 committed 产品目录。candidate 必须携带 attempt identity；陈旧 completion 不能覆盖、提升或清除另一个 attempt 的 slot。

### 3.4 Model Connection

Model Connection registry 与 Metask identity/catalog 独立，继续使用自己的 committed candidate、credential vault 和 persistence health。连接 CRUD、测试状态和 credential cleanup 由 Account 拥有；默认 execution source 在 Metask 与 Model Connection 之间切换时，必须使用同一条显式 execution replacement 协议。

## 4. 事务状态模型

Account 只允许一个前台 mutation transaction。实现必须使用封闭的 sum type 表达事务，不得用多个互相独立的 enum、nullable attempt、pending 字段和布尔位构造隐式笛卡尔积。概念模型为：

```text
Transaction =
  none
  | login(LoginTransaction)
  | token_refresh(RefreshTransaction)
  | catalog(CatalogTransaction)
  | default_model(DefaultModelTransaction)
  | execution_source(ExecutionSourceTransaction)
  | logout(LogoutTransaction)
```

每个非 `none` transaction 自包含：

- 非零 attempt identity；
- 当前阶段和该阶段唯一合法的 pending facts；
- 是否存在 worker/effect、是否仍允许取消；
- 成功、明确失败、取消、deadline 和 outcome unknown 的 terminal 规则。

当前 Zig 实现将 transaction kind 与阶段扁平为一个封闭 tagged union；catalog/default-model variant 直接携带 attempt identity 与 bounded pending facts，`reloading_models` 是独立 variant。`OperationKind`/`AttemptKind` 只是在纯 projection helper 中返回的派生标签，不是可独立写入的状态。committed execution authority 只表达 `none | ready | recovery`；准备或替换阶段只由 transaction variant 表达。

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

公开的 `AccountState`、`CatalogState`、`canCancel` 和 `canCreateTask` 都是 committed aggregate 与 transaction 的派生 projection，不是内部状态机的第二份真相。

## 5. Prepare、effect 与 commit

所有 command 和 completion 都先产生不可变的 `PreparedAccountChange`，概念上包含：

```text
next aggregate state
canonical AccountFact
optional effect
CatalogIntent
ExecutionIntent
ReplacementIntent
```

显式 intent 为封闭类型：

```text
CatalogIntent =
  committed
  | candidate
  | promote_candidate
  | discard_candidate
  | clear_all

ExecutionIntent = unchanged | install | clear

ReplacementIntent =
  none
  | begin_default
  | begin_identity
  | finish
```

精确 symbol 可以随实现调整，但以下约束不可改变：

- State/Account aggregate 是 intent 的唯一决策者；
- Runtime 不从 `AccountFactKind`、公开 `CatalogState`、operation 名称或 effect tag 反推 catalog commit；
- Coordinator 不从 Renderer command 名称或 Account effect tag 反推 Workbench replacement；
- `AccountFactKind` 只描述已观察事实，不控制 slot、persistence 或 execution 提交；
- prepared transition 被拒绝或 effect admission 失败时不得修改 committed aggregate；
- completion 产生的下一 effect admission 失败时，先提交已经观察到的外部结果，再从该 committed phase 产生唯一 terminal failure。

主线程跨 owner 顺序由 [Product 内部架构](product-architecture.md#21-account-与-executionconfig)定义。Account 内部 commit 必须一次应用 state、catalog intent 和 preference shadow；owned execution payload 由 Coordinator 按 `ExecutionIntent` 精确转移一次，并在 Account commit 前安装或销毁。不得发布只有 state 或只有 catalog 已更新的中间事实。

## 6. 关键事务

### 6.1 登录与 identity replacement

登录、token rotation、`/me` identity 和后续 catalog bootstrap 是连续的用户路径，但不是一个可整体回滚的事务：

1. OAuth code exchange 得到 token rotation；
2. refresh token durable commit；
3. 使用当前 token 验证 `/me`；
4. 原子提交 identity；
5. 以独立 catalog transaction 准备默认执行配置。

第 2 步成功后不能回滚旧 token。第 4 步成功但 catalog 失败时保持 authenticated identity，并发布可恢复 catalog failure。显式替换 identity 时，旧 credential execution 不得与新 identity 混用。

### 6.2 Catalog refresh

普通 refresh 从新的 private `CatalogSession` 构造 candidate public catalog。若 committed API/model 仍有效，则以 `promote_candidate` 提交新目录，不写 preference、不改变 credential generation、不替换 Workbench execution。

若 committed API 或模型已离开目录，transaction 停在对应选择阶段；不得自动切换到另一 credential authority。取消或明确失败使用 `discard_candidate` 返回 committed default。

### 6.3 API Key、provider 或 credential 变化

credential-bearing default replacement 是完整 transaction：

```text
load/validate candidate catalog
→ select API and model
→ prepare typed ExecutionTarget and credential
→ generate new credential execution generation
→ durable preference commit
→ Workbench install
→ promote candidate catalog
```

只有 ownership、catalog membership、persistence 和 Workbench install 全部成功后才能提交新默认值。任何明确失败都保留旧 committed default；persistence outcome unknown 按 §7 fail closed 并重新观察持久化真相。

### 6.4 同一 API Key 下修改默认模型

默认模型变化是独立 preference transaction，不是 catalog transaction，也不是 credential execution replacement：

1. 使用 committed catalog 和 expected generation 校验目标模型；
2. transaction 保存 pending model，committed selection 不变；
3. 原子写入同一 owner、API Key 和 credential generation，仅替换 `model_id`；
4. 写入成功后提交默认模型；
5. 明确失败丢弃 pending model；
6. outcome unknown 重新读取 preference 后决定提交、回滚或进入 recovery。

该 transaction 不提升或清空 candidate catalog，不打开 Workbench default-execution replacement，不替换 credential。提交期间暂停新 Task admission，既有 Task、Run、历史阅读和导航不受影响。重复选择当前模型是幂等 no-op。

### 6.5 Execution source 切换

Metask 与 ready Model Connection 之间切换必须产生显式 `ExecutionIntent.install` 和 `ReplacementIntent.begin_default`。新 source 成功安装前保留旧 source；失败不得清除当前可用默认 execution。Connection CRUD/test 不隐式改变默认 source。

## 7. Persistence 与恢复

平台存储格式、字段、原子 rename 和 credential 顺序以 [Metask Account API 合同](metask-account-contract.md)为准。Account 内部区分以下结果：

- `committed`：磁盘真相已确认，可以提交内存；
- `definite_failure`：磁盘未提交，保留旧 committed state；
- `outcome_unknown`：不得假设成功或失败，必须重新读取持久化真相。

默认模型写入 outcome unknown 后：

- 读取到完整新 preference：提交 pending model；
- 读取到完整旧 preference：回滚 pending model；
- 缺失、损坏、owner/API/generation 不匹配或第三种值：进入 preference recovery，禁止新的默认 mutation 和新 Task admission，但不销毁仍受当前进程证明的 credential，也不停止既有 Task。

credential-bearing execution persistence outcome unknown 风险更高：在重新观察并精确证明唯一 generation 前，不得发布或安装 candidate execution。不得自动重放非幂等 persistence。

`saved_preference` 只能是已观察持久化真相的 Account-owned shadow，不能与 committed selection 分别更新。恢复成功、提交成功和明确清除必须在同一个 Account commit 中同步两者。

## 8. Projection 与安全

`AccountView` 是 Account aggregate 一次生成的 canonical projection。State transition 只提供无 catalog 的内部 base view；只有 Runtime 可以结合显式 `CatalogIntent`/当前 slot 生成公开 `AccountFact`，并在返回 prepared 或 committed view 前强制执行 `validateView()`。禁止公开 State 半成品，也禁止根据公开 fact 反推 slot 后再补齐。

每个 prepared 和 committed view 都必须满足 `contract.validateView()`：

- ready selection 在对应 public catalog 中精确出现一次；
- model catalog owner 与 API selection 一致；
- candidate 字段只来自当前 transaction；
- generation、execution source 和 `canCreateTask` 自洽；
- signed-out/checking/authorizing projection 不泄漏 identity、catalog、selection 或 generation；
- projection 永不包含 token、API Key secret、credential、PKCE、authorization code、header 或 locator。

Renderer acknowledgement 不是 committed fact。Renderer reload、Bridge disconnect 或本地 timeout 不取消 Host transaction；恢复后只消费最新 canonical snapshot。

## 9. 并发、取消与 shutdown

- 每个 Account attempt 有唯一 identity、Host deadline 和最多一个 terminal completion；
- worker 只通过有界 mailbox 交付 owned completion，不调用 Workbench、Bridge 或 WebView；
- stale completion 必须销毁其 secret/owned payload，不能改变 transaction 或 catalog slots；
- 取消只在 transaction 明确允许的阶段进入；credential/preference persistence 一旦可能提交即跨过取消边界；
- mailbox collision、notification failure和 malformed completion 必须收口为当前 attempt 的明确失败，不能永久 wedged；
- shutdown 先停止新 command、取消 timer、cancel/join attempt、消费或销毁 mailbox、清空 private secret，再清 committed/candidate catalog 和 Runtime-owned credential，最后断开 ports；
- Account `deinit` 不执行仍依赖平台 capability 的 effect。

## 10. 必须保持的回归不变量

Account inline tests 覆盖纯 transaction transition、intent、projection、codec 和 ownership；Application coordinator tests 只覆盖必须跨 Account 与 Workbench 才能观察的 gate/transfer；Renderer tests只覆盖公开交互。至少长期保护：

- 登录后自动完成首个可用默认配置；
- GLM 默认 → GPT API → 自动模型 → 同 API 下选择另一 GPT 模型不 crash；
- 模型 preference 成功、明确失败、outcome unknown 三类结果；
- 纯模型变化不改变 credential generation、不安装 Workbench execution，重启后恢复新模型；
- API/provider/credential 变化生成新 generation，并只在完整成功后提升 candidate；
- catalog refresh、取消、park/reload 和 stale completion 的 slot 行为；
- identity replacement、effect admission failure、deadline 和 shutdown 在所有终止路径平衡 gate、attempt、secret 和 catalog；
- 每个 prepared/committed `AccountView` 都通过 runtime decode 等价的合同校验。

实现收口基线：`Transaction` 是唯一可写事务状态；Runtime 直接拥有 committed/candidate public catalog 与 candidate attempt identity；默认模型使用独立 durable preference transaction；Coordinator 只消费显式 execution/replacement intent。`fact.kind` catalog completion、effect-driver committed catalog、ready 模型直接 mutation、command/effect gate 推断、`candidateCatalogActive` 和组合 operation/attempt 字段均已删除，后续不得以兼容或 fallback 名义恢复。

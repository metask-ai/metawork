# MetaWork Models 模块设计提案

> 状态：已于 2026-09-02 获用户批准实施，非规范性真源；阶段 A 已于 `ccf1707` 完成并通过评审，A-close、阶段 R 与 B–E 按本文 Gate 推进
>
> 目的：为 Account 与模型体系解耦、用户自定义模型和消费方隔离提供可实施方案
>
> 后续：每个阶段开始前必须先同步该阶段列出的规范真源；本文记录实施决策和顺序，不替代这些合同

## 1. 结论

MetaWork 应在 Product Control 下建立独立的 `Models` aggregate，统一拥有 Provider、模型来源、连接、模型目录、默认选择、配置解析和模型连接凭据。现有 `Execution` aggregate 中属于模型控制面的职责应一次性迁入 `Models`，迁移完成后删除旧路径。

Account 只负责公司账号身份与授权，不再拥有 API Key/模型目录、默认 API、默认模型、模型 preference 或模型运行配置。Metask 对 `Models` 而言只是一个内置、推荐、使用 Account 授权的 Provider。

`Models` 是模型配置和绑定的供应方，不是执行引擎。它向运行消费者提供 owned、冻结的模型绑定，向 Schedule 等延迟消费者只提供无 secret 的模型引用和来源权威事实；它不接收消费者身份，不创建或修改消费者状态，也不干预绑定交付后的消费行为。

Models durable desired intent 与 Product Control 当前 installed binding 是两个事实。Models mutation 先按自身合同提交；Product Control 随后完成 credential scrub、resolve 和 active installation。两者不一致时关闭新的 Task/Schedule admission并发布精确 recovery，不回滚 Models 用户意图，也不改写已经取得 owned binding 的消费者。

目标依赖关系为：

```text
Account ──窄授权能力──→ Models::Metask Provider
用户配置 ────────────→ Models::Custom Provider
                              │
                              ├── catalog / default selection
                              └── OwnedModelBinding
                                          ↓
                              Product Control coordination
                               ┌──────────┼──────────────┐
                               ↓          ↓              ↓
                             Task      Completion      Schedule
                               │          │              │
                               └──────→ Agent       occurrence → Task
```

阶段 A 只完成 owner 命名和 module graph hard rename，没有改变现有产品语义。用户管理连接的完整可用性也不受“Native SDK 缺少 secure input”阻塞：Windows 已有并验证了基础 secure-input seam，当前缺口是 Model Connection host wiring、capability exposure、Renderer 硬门和真实 signed-out vertical；macOS 仍缺真实平台 Gate。该缺口作为独立的阶段 R 在 B–E 前闭合，不能再归类为外部 SDK 依赖，也不能用 Windows 证据替代 macOS 验收。

## 2. 设计目标

本方案必须同时满足：

1. Account 与 Models 具有独立的状态、事务、持久化、错误和恢复；Models 仍是 Product Control 持有的 aggregate，不因此成为第三个顶层 Product owner。
2. 在 secure-capture 平台 Gate 已通过的平台上，用户不登录 Metask，只要自定义模型来源可用，就能创建并运行 Task；当前交付范围由阶段 R 的真实 Windows vertical 证明，macOS 在自身 Gate 通过前保持 capability false。
3. Metask 登录成功不自动选择、替换或启用任何模型。
4. Account logout 不删除自定义 Provider，不改写已有 Task，也不清除非 secret 的 Models 用户意图。
5. Provider、Protocol、Connection、Model 和 Consumer 是不同概念，不互相推断或合并。
6. Models 不导入或操纵 Task、Schedule、Completion、Agent、Bridge、Renderer 或 Account Runtime。
7. 模型配置变化只影响后续解析；已交付给消费者的 owned binding 不被热替换。
8. credential 不进入 Renderer、Bridge、日志、event、snapshot 或持久历史。
9. 现有实现通过单一路径完成 hard cut，不保留并行的 Execution/Models 控制面。
10. 自定义模型能力从最小端到端版本开始：显式协议、endpoint、credential 和至少一个 model id；其后再扩展多模型及能力元数据编辑。
11. Product Control 保留一份进程内当前 default binding authority，直到另一个已批准方案完整替代 recovery equality、replacement/redaction 和冷启动重建；Models 不因此获得 Task/Schedule authority。
12. `source_generation` 与现有 Product binding generation 是两个事实，不能改名代替、复制数值或共用持久化字段。
13. Metask Provider 内部最后选择与全局 new Task default 是两个 Models-owned intent；custom 为全局默认时仍可配置、保留并显式恢复 Metask selection。
14. Models 的 durable desired mutation 不以 Task、Run、Schedule 或 Session 状态为提交前置条件；跨 aggregate activation 失败只形成 Product Control desired/active mismatch。

## 3. 非目标

本次不负责：

- Agent loop、Session、Conversation、Run 或工具调用；
- Provider HTTP/SSE codec 与 AgentCore ABI；
- 本地模型下载、安装、进程托管和资源调度；
- 根据模型名称、endpoint 或 Provider 品牌推断协议与能力；
- 动态 Provider 插件框架；
- 已有 Task 的隐式 rebind；
- Provider 配置变化后的自动重试、fallback 或消费者广播；
- 为旧内部模块名保留 facade、alias 或双写；
- 在本方案中删除 Product Control 当前 binding authority，或迁移 Task/Run 的 `execution_generation` 历史格式；
- 以 Models 重构顺带开放 Model Connection Task 的已有 Task 模型切换；
- 用 Windows secure-input 证据宣称 macOS capability 已通过。

如果未来支持本地模型进程，应建立独立的 `LocalModelRuntime` 能力，并通过与其他来源相同的 Models source/binding 合同接入；不能把进程管理塞入 Models 配置域。

## 4. 术语与身份

### 4.1 ProviderDescriptor

`ProviderDescriptor` 描述产品认识的模型服务接入方式，而不是运行时连接实例。

```text
ProviderDescriptor
├── provider_key
├── display_name
├── origin: builtin | custom
├── recommendation: recommended | standard
├── authentication: account | api_key
├── endpoint_policy: managed | user_configured
└── catalog_policy: remote | manual
```

Metask descriptor 是产品内置静态事实：

```text
provider_key = metask
origin = builtin
recommendation = recommended
authentication = account
endpoint_policy = managed
catalog_policy = remote
```

`recommended` 只影响用户引导和排序，不给予绕过验证、持久化、连接测试、安全或恢复 Gate 的特权，也不构成默认选择。

`ProviderDescriptor` 是产品定义的封闭接入目录，不是动态插件注册表。第一阶段只有内置 `metask` descriptor 和产品提供的通用 `custom` descriptor；用户创建的是 `ModelSource`/Connection，而不是可以注入代码或协议行为的新 Provider 类型。

### 4.2 ModelSource

`ModelSource` 是一个可配置或可解析的模型服务实例。Metask 的某个 API access 与用户创建的 Model Connection 都属于 source。

```text
ModelSource
├── source_id
├── provider_key
├── protocol
├── endpoint
├── external credential authority object
├── source_generation
└── availability
```

`source_id` 是 Models 域内稳定、不透明、非 secret 的身份。它不是 Provider 类型，不进入模型请求，也不能替代 generation。相同 endpoint 或 credential 的不同连接仍拥有不同 source identity。

`ModelConnection` 是 custom `ModelSource` 的用户管理形态，不是第二套运行身份。首版固定一条 Connection 对应一个 source，`connection_id == source_id`；Metask source 没有伪造的 Connection 对象。只有未来出现“一条用户配置产生多个独立 authority source”的真实需求时，才可以引入不同 identity 和显式映射。

### 4.3 ModelDefinition

`ModelDefinition` 表示某个 source 下的一项模型：

```text
ModelDefinition
├── model_id
├── display_name
├── capabilities
├── max_input_tokens
├── max_output_tokens
└── metadata_provenance
```

模型身份由 `source_id + model_id` 共同确定。相同 `model_id` 出现在不同 source 时不是同一个模型；display name 永远不是身份。

Metask 模型定义来自服务端目录且只读。自定义模型定义由用户提交并持久化。缺失能力保持 `unknown`；用户声明、服务端声明和运行验证必须保留 provenance，不能将声明伪装成已验证能力。

### 4.4 ModelRef

```zig
pub const ModelRef = struct {
    source_id: []const u8,
    model_id: []const u8,
};
```

所有默认选择、解析和测试都使用 `ModelRef`，不接受脱离 source 的裸 model id。

### 4.5 Protocol

Protocol 是请求/响应 wire dialect，不是 Provider 分类：

```text
openai_responses
openai_chat_completions
anthropic_messages
gemini_native
```

Provider、URL 和模型名称都不能隐式决定 Protocol。Metask managed source 从服务端精确字段映射协议；自定义 source 由用户显式选择并经过 endpoint 结构校验。

## 5. Owner 边界

### 5.1 Account

Account 独占：

- OAuth 登录、取消、refresh 和 logout；
- `/me` identity；
- access/refresh token；
- Account 授权状态与 generation；
- Account credential 的安全生命周期；
- 向 Application 暴露窄、可撤销的 Metask 授权能力。

Account 不拥有：

- Provider 或 ModelSource；
- API Key/模型目录的产品状态；
- 默认 API、默认 source 或默认模型；
- 模型 preference；
- Protocol、模型 endpoint 或模型能力元数据；
- `OwnedModelBinding`；
- Model Connection credential vault；
- Task admission 或模型可运行判断。

### 5.2 Models

Models 独占：

- Provider descriptor catalog；
- Metask Provider adapter；
- Metask API/model catalog transaction；
- ModelSource 与 ModelDefinition；
- 自定义 Model Connection registry；
- 自定义模型 CRUD；
- 自定义连接的 credential locator、tombstone 和恢复；
- Metask source 的运行时模型 credential owner；
- source readiness 与精确模型 probe 状态；
- Metask Provider-local selection intent 与其 revision；
- 全局默认 `ModelRef` 与 selection revision；
- connection revision 与 source/catalog/selection generation；
- `OwnedModelBinding` 的构造和线性转移；
- Models 自己的 persistence health、operation 和 recovery。

### 5.3 Product Control

Product Control 持有 Models aggregate，并只负责跨 aggregate 用例：

- Task 创建时取得 default binding，再提交给 Task；
- Task 显式模型切换时，从 Models 取得 candidate，再由 Task 自己提交；
- Schedule occurrence 先校验 durable Models selection/source authority，再取得创建 Task 所需的当前 binding；
- 持有进程内 `DefaultBindingState`，保存当前 installed binding、Product binding generation、replacement/redaction 状态和 recovery equality authority；
- 根据 Models default resolvability、desired/active alignment、Schedule persistence 和 Workspace authority 组合新 Task admission；Product Control 不旁路 Models 读取 Account authorization；
- canonical snapshot 的组合与 secret scrub；
- shutdown 顺序和 owned transfer 的完成。

Product Control 不复制 Models policy，不根据 snapshot、display name、URL 或 consumer 状态推断模型配置。

`DefaultBindingState` 是现有 `execution_state.State` / `ActiveExecution` 的目标语义，不是新的持久化 aggregate。它必须保持进程内，并在冷启动时从 Models durable default、当前 source authority 和 credential capability 重新解析安装；`activeGeneration = 0` 表示本进程尚未安装可用 binding。它继续拥有：

- `BindingAvailability = unavailable | ready | replacing`；
- 当前 owned credential、`ModelRef`、source generation、selection revision、protocol、endpoint 和 Product binding generation；
- `beginIdentityReplacement` / `beginDefaultReplacement` 所表达的串行化，但实现命名应收敛为 source-authority replacement 与 default-selection replacement；
- Task/Run restore 与 binding adoption 所需的 Product binding generation equality；
- durable credential scrub 的 prepare/commit ordering。

它不保存 Models registry 的第二份真相，也不把 `taskCreationAvailable` 交给 Models。`taskCreationAvailable` 是 Product Control 对 Models desired 与 installed binding 是否对齐、Workspace、Schedule persistence、replacement 和 shutdown 的组合判定，目标 wire 中改名为 `newTaskAdmission.available`；Models 只发布 default 是否可解析及其自身失败原因。

默认选择或默认 source authority 变化时，Product Control 不阻止 Models durable commit。它以最新 `selection_revision + source_generation` 开始或取代 reconcile，先关闭所有会取得新 binding 的 admission（new Task、Schedule occurrence、detached Task restore/adoption 和显式 rebind），再完成旧 credential 的 durable scrub、解析新 binding 并 no-fail 安装。scrub/resolve/install 失败时保留旧 active credential 的唯一 owned copy 直至安全释放，发布 desired/active mismatch，不回滚 Models、不让旧 active 继续签发 binding，也不触碰已经持有 binding 的消费者。

### 5.4 Application

Application 只组装平台 capability 和跨 owner effect：

- 把 Account committed authorization 转换成 Models 可消费的窄授权输入；
- 为 Models 注入 credential vault、persistence 和网络 transport；
- 执行 Models prepare 的 probe job，并把 typed completion 交还 Models；
- 执行 Models prepare 的 catalog refresh job，并把 typed completion 交还 Models；
- 为 Model Connection create/credential replacement 组装独立 secure-capture host，拥有 bounded plaintext buffer 并在所有 terminal path secure-zero；
- 安排主线程 wake、drain 和 shutdown 顺序。

Application 不读取 Models/Account view 后形成默认选择、source readiness、Task admission 或 probe 成功策略。

### 5.5 消费者

Task、Schedule 和 Completion 只依赖 Models 的纯合同。运行消费者在接收 owned binding 后独占自己的副本和生命周期：

- Task 拥有 attachment、当前模型、binding epoch、Run 和历史；
- Schedule 只保存无 secret 的 `ModelRef + source_generation + selection_revision + protocol`，并拥有定义、触发、occurrence 和对应历史；到期时由 Product Control 校验 Models desired/active authority、解析 binding并创建真实 Task；
- Completion 拥有一次调用、取消和结果；
- Agent 拥有 Session、Run、codec、transport 和 AgentCore 集成。

Models 不保存 consumer identity，不观察 consumer lifecycle，也不回调改写 consumer。

## 6. Account 与 Metask Provider 集成

解耦不表示没有交互，而是交互必须通过窄 capability，且双方 authority 与故障独立。

建议由 Application 组装 Account 与 `Models::MetaskProvider`：

```text
Account committed authorization
→ Application obtains bounded Account-owned authorization transfer/capability
→ Models Metask adapter performs bounded API/model discovery
→ Models commits secret-free catalog and source state
→ Account state不等待、不读取 Models 结果
```

Models 不导入 Account Runtime。Account 也不导入 Models contract。跨 owner value 应限制为授权 availability、opaque principal reference、authorization generation 和有界 authorization lease/capability；其中任何 secret 都不得进入领域 view、持久化或长期 Models state。

Account OAuth token 只用于访问公司账号服务，是 Account credential；Models 最多在一次有界 Provider operation 中消费由 Application 转移的 authorization lease，不能保存或转交该 token。通过这次授权发现的模型 API credential 是另一类 secret：它由 Models 对应的 Metask ModelSource 在运行时拥有，用于构造 binding，不成为 Account preference、Account view 或 durable Models credential。

自定义连接的 secret 与此不同：它由用户通过 Host secure capture 写入 Models credential vault，Models store 只保存 locator。两类 credential 不共用 locator、generation 或清理事务。

### 6.1 登录

登录成功只产生 Account authorization。Models 可以随后刷新 Metask source并恢复同一 principal 的 Provider-local selection intent，但不得自动：

- 选择 Metask 为默认 Provider；
- 覆盖当前自定义默认模型；
- 创建 Task；
- 改写已有 Task；
- 将目录加载失败回写为 Account 登录失败。

### 6.2 Logout

Account logout 后：

- Account 清除自己的 token；
- Models 立即使 `provider=metask` 的可用模型目录失效，撤销新的 Metask resolve capability并清零未转移的 Metask credential；
- Models 保留非 secret 的 Metask Provider-local selection intent 和全局默认选择意图，并把对应 source 标记为 `needs_authentication`；
- 自定义 source 和其默认选择不受影响；
- 已交付给 Task/Completion 的 owned binding 不被 Models 主动撤回；
- 若未来需要强制安全撤权，必须建立独立显式 revocation 合同，不能借普通 logout 或配置编辑暗中改写消费者。

### 6.3 换账号

Metask source 必须绑定 opaque principal reference。新账号不能复用旧账号的 source credential 或 catalog。旧选择意图可以保留为 unavailable，但只有同一 principal 的新授权和新鲜 catalog 能恢复运行资格；不得根据显示名、API Key 尾号或 model id 猜测等价性。

Account `authorization_generation` 不能直接复制成 `source_generation`。OAuth token rotation 只改变管理授权，不改变模型 source authority。

Metask `source_generation` 标识外部 API access 对象的 authority，而不是 secret bytes 的版本。首版同一 `opaque principal reference + API Key object id + protocol + managed endpoint` 证明同一 authority；服务端在同一对象上轮换 secret bytes 不提升 source generation。若未来产品必须区分“同一对象 id 下 authority 被替换”，Metask 合同必须先提供稳定、非 secret 的 authority revision；不得持久化 secret hash、suffix、`updated_at` 或其他猜测值充当证明。principal、API Key object、protocol、endpoint 或受合同保护的 authority revision 变化时必须生成新的非零 `source_generation`。

## 7. Models 对外合同

### 7.1 OwnedModelBinding

```zig
pub const OwnedModelBinding = struct {
    allocator: std.mem.Allocator,
    source_id: []u8,
    protocol: Protocol,
    endpoint: []u8,
    model_id: []u8,
    credential: SecretBuffer,
    source_generation: u64,
    capabilities: ModelCapabilities,
};
```

它必须满足：

- 所有 buffer 由 binding 自有；
- credential 在所有失败、取消和释放路径 secure-zero；
- `take()` 线性转移，不能复制 secret owner；
- 不包含 Account identity、Provider display metadata 或 consumer identity；
- 不进入 Renderer、Bridge、snapshot 或持久历史；
- Agent adapter 只在消费边界把 Models Protocol 穷举映射为 Agent Protocol。

### 7.2 Public API

建议最小公共表面：

```zig
pub fn view(self: *Runtime) ModelsView;
pub fn submit(self: *Runtime, command: Command) CommandResult;
pub fn resolveDefault(
    self: *Runtime,
    expected_selection_revision: u64,
) ResolveResult;
pub fn resolve(
    self: *Runtime,
    model: ModelRef,
    expected_source_generation: u64,
    expected_catalog_generation: u64,
) ResolveResult;
pub fn prepareCatalogRefresh(
    self: *Runtime,
    source: SourceSelection,
) CatalogRefreshPreparation;
pub fn completeCatalogRefresh(
    self: *Runtime,
    completion: CatalogRefreshCompletion,
) void;
pub fn prepareProbe(self: *Runtime, model: ModelRef) ProbePreparation;
pub fn completeProbe(self: *Runtime, completion: ProbeCompletion) void;
```

公共 API 和 ports 中禁止出现：

```text
TaskId / RunId / ScheduleId / WorkspaceId
Session / Conversation
Task admission / Task persistence
Run cancellation / retry / history
automatic title / Composer / UI route
```

### 7.3 Probe

Models 拥有 probe 的产品事务和状态，但不实现 Provider 请求。Application 注入窄 `ModelProbePort`，由 Agent-owned one-shot Completion 执行一次精确 `OwnedModelBinding` 测试。

Probe 成功只证明该 source generation 下的精确 model binding 完成了规定请求；它不证明：

- 同 connection 下所有模型可用；
- 所有声明能力可用；
- Task admission 必然成功；
- Provider 永久健康。

### 7.4 Catalog refresh

Models 拥有 catalog refresh 的 admission、attempt identity、stale completion、catalog commit 和 source error；Application 拥有网络 worker、线程、transport、bounded mailbox、wake、cancel 和 shutdown join。Models 不创建线程，也不直接持有 Application transport。

固定异步合同为：

```text
Models.prepareCatalogRefresh(source, expected generation)
→ immutable preparation + owned bounded request
→ Application starts at most one admitted worker for that source
→ worker returns owned bounded completion through mailbox
→ Application main-thread drain calls Models.completeCatalogRefresh
→ Models validates attempt/source/authorization generation and commits or destroys completion
```

shutdown 必须先停止新 admission，再 cancel/join catalog 与 probe worker，最后释放 Models Runtime。stale、cancelled、oversized 或 owner 已替换的 completion 必须销毁 owned payload；不得更新 catalog、default selection 或 Account state。阶段 B 不引入 Models 自持线程，因此 `src/product/models/` 不新增 thread/shutdown leaf。

### 7.5 Credential mutation port

Generic `submit(Command)` 永远不携带 secret，也不能通过 command union 间接借用 Renderer buffer。创建连接和替换 credential 使用独立 Application-owned host sequence：

```text
Bridge decodes bounded non-secret connection metadata
→ Application ModelConnectionHost captures secret into bounded native buffer
→ Application calls Models credential-mutation capability
→ Models performs vault tombstone / credential effect / registry commit
→ typed terminal outcome returns to Bridge
→ Application secure-zeroes capture buffer on submit, cancel, failure and shutdown
```

Models capability 可以接收调用期借用的 secret，但不得保存调用方 buffer；它只把 secret 写入 injected credential vault，并按自身事务保存 locator。Bridge、Renderer、generic command、snapshot、event 和日志都看不到 secret 或 locator。secure capture 不可用时必须返回 typed `capture_unavailable`，不得回退到 WebView password input、环境变量或普通文本 payload。

### 7.6 非干预合同

Models 对消费者的影响止于“是否为当前请求签发一个 binding”：

- Models 可以依据自己的 source、catalog、credential 和 revision 事实接受或拒绝一次 resolve；
- resolve 成功后，binding 与 Models registry、vault buffer 和 Runtime 生命周期解耦；
- default/source/model 的编辑、删除和故障只影响未来 resolve；
- Models 不等待 consumer 释放，不持有 consumer callback，不发送 rebind/cancel/retry 指令；
- consumer 不在每次 Run 前回查默认选择；它只使用自己已经提交的 binding；
- 配置删除后外部服务是否仍接受旧 credential 是服务端事实，不授权 Models 篡改本地 consumer 历史或伪造取消；
- default selection 的提交不得以 Task、Schedule、Session 或 Run 状态为前置条件。

创建或显式 rebind consumer 时，Product Control 必须分别取得 Models binding candidate 和 consumer admission，再把 ownership 转移给 consumer；Models 自身不得获得跨 aggregate commit 权限。Models 配置 mutation 与 consumer mutation 不组成原子事务：配置只提交 desired intent，Product Control 的 active reconcile 和新 consumer admission是后续独立边界。

## 8. 状态与 generation

现有 `execution_generation` 不能直接改名成 `source_generation`。前者由 Product Control 为当前 installed binding authority 分配，后者由 Models 表达某个 source 的可解析权威；二者都只做相等比较、不表达顺序，但 owner、生命周期和消费者不同。

| 字段 | Owner | 变化条件 | 不因何变化 |
| --- | --- | --- | --- |
| `authorization_generation` | Account | principal/token authority replacement | 模型选择、目录刷新 |
| `connection_revision` | Models | custom Connection 的 display/config/model/credential intent 任一成功 mutation | probe completion、consumer 状态 |
| `source_generation` | Models | protocol、endpoint、source principal、外部 authority object/revision 或用户显式替换 custom credential | 同一 Metask authority object 的 provider-managed secret/OAuth token rotation、同 source 下选择其他模型 |
| `catalog_generation` | Models | source 模型集合或公开元数据替换；remote catalog 每次新鲜观察产生新 identity | 默认选择变化 |
| `metask_selection_revision` | Models | Metask Provider-local source/model intent 变化或被清除 | custom/global default 变化、目录只刷新 |
| `selection_revision` | Models | 全局默认 `ModelRef` 变化、被清除或显式 store recovery | 无关 source/catalog 变化、幂等重复选择 |
| `binding_generation` | Product Control | 本进程首次安装或安装与既有 binding authority 不等价的新 source authority；必须为非零 opaque equality token | 同一进程、同一 source authority 下只切换默认模型 |
| Task `binding_epoch` | Task | Task 自己显式采用新的 binding attachment | 全局默认变化、同 epoch 的下一轮模型选择 |

内部目标名使用 `binding_generation`。Task/Run 现有稳定 wire/persistence 字段继续叫 `execution_generation`，Bridge 当前 installed fact 继续叫 `activeGeneration`；Schedule schema 1 的同名字段仅保留到阶段 E 的已批准 schema 2 hard cut，目标 Schedule definition 不再保存 Product generation。禁止把 `source_generation` 写入任何旧字段假装兼容。

`connection_revision` 是 custom Connection mutation 的 CAS，不是执行 authority；修改 display name 必须推进它但不推进 `source_generation`。模型集合/metadata mutation 同时推进 `connection_revision + catalog_generation`；endpoint/protocol/credential authority mutation 同时推进 `connection_revision + source_generation` 并使新 generation 重新经过 readiness/probe。不得用一个旧 `connection_generation` 继续混装这三种语义。

`selection_revision` 是持久化的非零 opaque equality token，不表达顺序。每次实际默认选择变化都生成新值，因此 A → B → A 后不能复用第一次 A 的 revision；Models store 显式恢复或重建时也必须生成新值，不能从 0 重新计数。`catalog_generation` 不进入 Schedule durability；普通 fresh catalog observation 不应使所有计划失效。

`OwnedModelBinding` 携带 `ModelRef + source_generation + protocol + endpoint + credential`。Product Control 安装时把它包装为当前 `DefaultBindingState`，分配或在同进程复用 `binding_generation`。Task 接收自己的 owned runtime copy，并继续以 `protocol + model_id + execution_generation + binding_epoch` 解释历史；Models 不保存或比较 Task `binding_epoch`。

冷启动顺序固定为：恢复 Models durable intent 和自定义 registry → 恢复 Account authorization → Models 建立可解析 source → Product Control resolve 并安装 `DefaultBindingState` → 才开放相关 binding admission。Schedule store 可以先恢复，但 timer/reconcile 必须等待这条 bootstrap 到达 ready 或明确的 unavailable/recovery terminal fact，不能把瞬时 `loading` 记成永久 needs-attention。Product `binding_generation` 不写入 Models store；Metask 与 custom 都可以在新进程安装时取得新的 binding generation。历史 Task 的 generation 不相等时只能走现有 exact recovery/adoption 合同，不能把 `source_generation` 复制过去或猜测相等。Schedule 不再依赖该进程内值。

`recoveryAuthorityExact` 和 `validExecutionGeneration` 在 B–E 中保留，由 `DefaultBindingState` 实现。删除该 state 的任何未来方案必须同时给出冷启动比较对象、Task/Run/Schedule 持久化迁移和 restore/adoption 证明；不能作为 Models 内部重构顺带完成。

## 9. 配置命令

建议 Models 命令集合：

```text
refresh_provider_catalog
configure_metask_selection
select_default
create_connection_metadata
update_connection_metadata
remove_connection
probe_model
add_custom_model
replace_custom_model
remove_custom_model
recover_registry
```

以下不是 generic command，必须走 §7.5 的独立 credential mutation port：

```text
create_connection_with_captured_credential
replace_connection_credential
```

所有 mutation 使用与其事实对应的 CAS，不能笼统写成 expected generation：

- custom Connection metadata/authority mutation 使用 `expected_connection_revision`；
- custom model membership/metadata mutation 同时使用 `expected_connection_revision + expected_catalog_generation`；
- `configure_metask_selection` 使用完整 Metask `ModelRef + expected_metask_selection_revision + expected_catalog_generation`；
- `select_default` 使用完整 `ModelRef + expected_selection_revision + expected_source_generation + expected_catalog_generation`；
- probe/credential completion 绑定 attempt identity 和开始时的 exact connection/source generation。

`configure_metask_selection` 与 `select_default` 是两个命令。前者更新 Provider-local Metask source/model intent；custom 是当前全局默认时，它不能暗中切换全局默认。Metask 已是全局默认时，配置新 Metask selection 必须在同一 Models transaction 中同步更新全局 `ModelRef` 并推进两个 revision。`select_default` 只负责全局 new Task default，可以显式选择当前 Metask intent 或任一 ready custom `ModelRef`。

Connection 与 Model 是不同对象：

- 一个 Connection 可以包含多个模型；
- Connection mutation 使用与 `source_id` 相同的稳定 `connection_id`，不通过模型 display name 定位；
- 移除默认模型必须原子清除或替换默认 selection；
- 移除 source 禁止未来 resolve，但不进入消费者修改既有 binding；
- 自定义模型能力缺失保持 unknown；
- 普通编辑不自动 probe，probe 也不自动设为默认。

第一阶段可以只开放创建 Connection 时提交一个模型，但内部持久化和身份从一开始必须支持非空有界模型集合，避免把 Connection 与 Model 永久合并。

`refresh_provider_catalog` 严格对应 §7.4 的 prepare/complete 异步合同，不允许 `submit()` 同步执行网络。`probe_model` 同理只创建 probe preparation；Completion/Agent transport 不是 Models command handler。

## 10. 持久化与恢复

### 10.1 Canonical store

长期使用单一原子 `models.json`。这不是为了目录命名，而是因为 custom registry、Metask Provider-local intent、全局 default intent 与各自 revision 必须由同一 Models owner 原子提交，不能分散到 Account preference 和 connection store。目标 schema 拥有：

- custom Connection public configuration；
- custom ModelDefinition；
- Metask Provider-local `ModelRef` intent 与 `metask_selection_revision`；
- 全局默认 `ModelRef` 与 `selection_revision`；
- custom connection revision/source generation，以及最后一次已提交 Metask authority 的 source generation；remote catalog generation 不持久化；
- credential locator 和 deletion tombstone；
- persistence/recovery marker。

不持久化：

- Account OAuth token；
- API/model credential bytes；
- remote catalog cache，除非未来单独建立离线合同；
- `OwnedModelBinding`；
- Task、Run、Schedule 或 Completion identity；
- probe response/body；
- Consumer history。

Product `binding_generation` / 旧 `default_execution_generation` 不进入目标 schema。它们属于 Product Control 进程内 installed fact；Task/Run 持久历史继续保存自己已有的 `execution_generation`，但 Models store 不保存其当前比较值。

Credential 继续位于系统安全存储，Models store 只保存 locator。创建、替换和删除沿用 tombstone-first、credential effect、registry commit、cleanup 的可恢复顺序。Model Connection metadata、custom model 集合和指向它们的 default selection 必须在同一个 registry candidate 中原子提交。

上句只适用于用户自定义连接。Metask 模型 API credential 不写入 Models store 或长期 vault；它在登录后的新鲜 provider/catalog transaction 中取得，随 Models runtime source 持有，并在 authorization loss、source replacement、logout 和 shutdown 时 secure-zero。Metask Provider-local intent 只保存 opaque principal reference、source reference、model id 和对应 revision；全局 default 另存指向该 `ModelRef` 的 selection。两者都不保存 OAuth token、Account display identity 或 remote catalog。

### 10.2 Store 分类处置

三个既有 store 分别决定语义，但前两个必须在阶段 B 由一个 bootstrap migration 共同构造 `models.json`；禁止先让 Models 在 B–D 继续写两个 legacy store，再到 E 拼接第二次真相：

| Store | 处置 | 理由 |
| --- | --- | --- |
| Account `preferences.json` | 阶段 B 一次性严格迁移，成功前保留原文件 | 已发布登录用户可能存在真实 Metask API/model 意图 |
| Models `model-connections.json` | 阶段 B 一次性严格迁移，成功前保留原文件 | 阶段 R 在 B 前开放真实创建路径，届时该文件可能已有真实 custom connection/credential intent，历史版本证据不再足以支持 hard cut |
| Schedule store schema 1 | 迁移为 schema 2，不能 hard cut | 已发布 Scheduled Task 可能包含真实定义与 occurrence 历史 |

Application bootstrap 只提供受限文件 effect；Models 拥有迁移判断。固定顺序为：

1. 仅当 `models.json` 不存在时，分别严格读取当前 `preferences.json` 与 `model-connections.json`，把每个输入独立分类为 `absent | valid | recovery_required`。一个 legacy sector 损坏不能清空或阻止另一个已验证 sector；损坏 bytes 只作为非 active recovery evidence 保留；
2. 从 valid preference 构造 Metask Provider-local intent；从 valid connection registry 精确迁移 custom connection/model、credential locator/tombstone、readiness 和 custom default；custom `connection_id` 原样成为 `source_id`。invalid sector 不产生空数据或猜测值，只在目标 store 记录 typed、sector-specific migration marker；
3. global default 只在旧事实可证明时迁移：valid custom registry 有 default 则使用它；valid custom registry 明确无 default 且 preference valid 时使用 Metask intent；两份输入都 valid/absent 且均无 default 时才提交空 default。若损坏输入可能包含决定全局 default 的事实，则提交 `default_migration_required`，关闭 default admission，不能拿另一个 sector 猜测；
4. 结构完整的 Metask preference 即使当前 signed-out 也作为 unavailable intent 保留；只有当前 principal authorization 和 fresh catalog 验证后才能标为 resolvable；
5. 旧 `connection_generation` 只作为迁移输入，不复制成 `source_generation`。Models 为精确迁移的 authority 生成新 `source_generation`，并把旧 generation 映射为初始 `connection_revision`；旧 ready/test proof 只有在完整 endpoint/protocol/model/credential locator 精确迁移时才能绑定到新 source generation，否则进入 `needs_test`；
6. 旧 `default_execution_generation` 不迁移。目标 store 为已知的 Metask/global selection 生成新的非零 opaque revision；未知 default 保留 recovery marker而不伪造 revision；
7. Models 原子提交完整 `models.json`（包括已验证 sector 和必要 recovery marker）成功后才取得 canonical authority；在此之前 Account 与旧 Models 路径继续是唯一旧 authority，不能提交半迁移内存 state；
8. outcome unknown 时只严格重读 `models.json`：完整 candidate 表示已提交，文件缺失表示未提交，损坏或第三种值进入 Models persistence recovery；不得回退成运行时拼接两份 legacy store；
9. 新 store 确认后停止所有 legacy writer。已消费的 valid 文件原子改名为 recovery copy；`recovery_required` 文件作为 marker 绑定的唯一 evidence 保留，只有显式 Models recovery transaction 可以重读。cleanup 明确失败不撤销新 canonical authority，但发布可重试 cleanup fact；普通启动/resolve 不读取 recovery copy；
10. sector recovery 成功时从当前 canonical `models.json` 构造完整 candidate 原子合并，必要时生成新的 selection revision并重新进行 Product reconcile；不得覆盖另一 sector 已提交的新 mutation；
11. Account 未登录时不能宣称 Metask source ready；owner/principal 不匹配、catalog membership 未确认时保留 unavailable intent，待同 principal authorization 后严格验证，不从 model id、显示名或当前 default 猜测；
12. OAuth token、Account refresh state、remote catalog、API credential bytes 和 Product binding generation 不迁移。

### 10.3 Schedule schema 1 → 2

现有 Schedule schema 1 持久化 `execution_generation + execution_protocol + execution_model`，没有 `source_id`。schema 2 的可执行定义改为保存：

```text
model_ref { source_id, model_id }
source_generation
selection_revision
protocol
```

迁移不得从 model id、protocol、当前 default 或 Account catalog 猜测 source。schema 1 definition 必须转换为 schema 2 的 `binding_migration_required` 非执行状态：保留 title、input、recurrence、permission profile、旧 generation/protocol/model 显示事实和 occurrence 历史，但 `enabled = false`、不得 launch，UI 要求用户从当前 Models projection 显式重新绑定。用户提交新的完整 `ModelRef` 后才形成可执行 definition；旧 occurrence 历史不改写。

schema 2 的 `ModelRef` 只消除裸 model id 歧义，不开放 Schedule 独立选择任意非默认 source。每次 occurrence 固定按以下顺序校验：

1. definition 的 `ModelRef + selection_revision` 与 Models 当前全局 default 精确一致；这使 A → B → A 仍被识别为默认配置发生过变化；
2. definition 的 `source_generation + protocol` 与当前 source authority 精确一致，current catalog 仍包含该 model；普通 catalog refresh 不因 generation 自身变化使计划失效；
3. Product Control `DefaultBindingState` 为 ready、未 replacing，且 installed `ModelRef + source_generation + protocol + selection_revision` 与同一 Models desired authority 精确一致；desired/active mismatch 不得用旧 active launch；
4. Product Control 使用读取到的 current catalog generation 向 Models resolve 同一 `ModelRef`。成功后才为新 Task 分配/复制当前 Product `binding_generation`；该进程内 generation 不写回 Schedule definition。

任一步失败都进入现有 `execution_changed`/needs-attention 路径，不静默改绑。相同 Metask authority 的冷启动可以安装新的 Product binding generation而不使 Schedule 失效；default selection、source authority、protocol 或 store incarnation 改变则必须重新确认。

迁移必须整库严格 decode、构造 schema 2 candidate、同目录 temp + sync + atomic rename。decode/read 失败保留原文件并进入 `corrupt/read_failed`。明确写失败，或 outcome unknown 后重读确认 canonical 仍精确等于原 schema 1 bytes，均保持原文件、本次不提交迁移内存并发布 `migration_failed`；该状态不开放 hard-reset recovery，只允许重启后重新尝试。重读精确等于 schema 2 candidate 时接纳迁移；既不等于完整旧 canonical 也不等于完整新 candidate 时发布 `outcome_unknown` 并进入 Schedule recovery。运行时不存在 schema 1 launch fallback。

### 10.4 Task、Run 与 checkpoint

Task `BindingWire.execution_generation`、Run `execution_generation`、checkpoint/binding adoption 和对应历史格式本轮保持不变，也不增加 `source_id`、Account identity 或 Model Connection identity。恢复先和 Product Control `DefaultBindingState.binding_generation` 做现有精确判断；不相等时继续走已经存在的 protocol/model/authority adoption 合同，不能因为 Models store 不再持久化当前 Product generation 而伪造相等或回退到默认模型。

因此，本轮不迁移 Task/Run persistence，也不把 `source_generation` 写入 `execution_generation`。若未来希望历史直接保存 `ModelRef`，必须单独取得持久化格式批准，并同时处理 credential/source identity 隐私、旧 Task migration、checkpoint compatibility 和 Renderer contract。

## 11. Renderer Bridge 与 UI

### 11.1 Snapshot

Account projection 收紧为：

```text
account {
  state
  identity
  operation
  canCancel
  error
}
```

新增 Models projection：

```text
models {
  availability
  persistenceHealth
  providers[]
  sources[]
  metaskSelection
  metaskSelectionRevision
  defaultSelection
  selectionRevision
  operation
  error
}
```

Models projection 不包含 credential、完整 endpoint secret、Account token、Task binding 或 Consumer identity。

现有 `execution` root 不直接改名成 `models`，因为两者 owner 不同。阶段 B 先新增 Models-owned `models` 并从 `account` 移除模型字段；阶段 C 再把 Product Control-owned `execution` hard cut 为 `newTaskAdmission`：

```text
models { ... }                 // Models-owned provider/source/catalog/default intent
newTaskAdmission {
  available
  reason
  activeModelRef
  activeGeneration
  activeSelectionRevision
  state: unavailable | ready | replacing
}                              // Product Control-owned installed fact
```

`newTaskAdmission` 是 Product Control 的组合 projection，不是 Models view。它取代当前 `execution.state/taskCreationAvailable/active*` 的语义；不得把 Workspace、Schedule、shutdown 或 replacement failure 塞进 Models source state。Task/Run 历史继续使用既有 `executionGeneration` wire name。

### 11.2 Commands

建议 wire command：

```text
metawork.models.refreshCatalog
metawork.models.configureMetaskSelection
metawork.models.selectDefault
metawork.models.connections.create
metawork.models.connections.update
metawork.models.connections.replaceCredential
metawork.models.connections.remove
metawork.models.connections.test
metawork.models.customModels.add
metawork.models.customModels.replace
metawork.models.customModels.remove
metawork.tasks.selectModel
```

完整迁移表按 owner 变更所在阶段原地 hard cut，不能把所有 wire 延迟到 E：

| 当前 command | 目标 | 阶段 |
| --- | --- | --- |
| `metawork.account.refreshCatalog` | `metawork.models.refreshCatalog` | B |
| `metawork.account.selectApiKey` | 删除持久选择语义；选择 source 只发起 `metawork.models.refreshCatalog`，不改变 Provider-local/global intent | B |
| `metawork.account.selectModel` | `metawork.models.configureMetaskSelection`，接受完整 Metask `ModelRef` | B |
| `metawork.modelSources.selectMetaskDefault` | `metawork.models.selectDefault` | B |
| `metawork.modelConnections.create` | `metawork.models.connections.create`，credential 走独立 Host capture | D |
| `metawork.modelConnections.update` | `metawork.models.connections.update` | D |
| `metawork.modelConnections.remove` | `metawork.models.connections.remove` | D |
| `metawork.modelConnections.test` | `metawork.models.connections.test` | D |
| `metawork.modelConnections.selectDefault` | `metawork.models.selectDefault` | B |
| `metawork.tasks.selectModel` | 保留名称，hard cut payload | C |

`metawork.models.configureMetaskSelection` 接受完整 Metask `ModelRef + expectedMetaskSelectionRevision + expectedCatalogGeneration`；Metask 是当前 global default 时，Host/Models 在同一 transaction 中同步推进 global selection。`metawork.models.selectDefault` 接受完整 `ModelRef + expectedSelectionRevision + expectedSourceGeneration + expectedCatalogGeneration`。Host 必须从 Models current projection 重新校验，不接受裸 model id、display name 或 Renderer 拼装 endpoint。

`metawork.tasks.selectModel` 的目标 payload 为：

```text
taskId
expectedModel
expectedExecutionGeneration
targetModelRef { sourceId, modelId }
expectedSourceGeneration
expectedCatalogGeneration
```

阶段 C 仍只允许当前已开放的 Metask exact-authority 模型切换：target source 必须等于当前 installed Metask source，Task protocol/execution generation 必须匹配，candidate 必须属于同 source current catalog。Model Connection Task 和跨 source 切换继续 typed reject，不因 payload source-qualified 而开放；开放它们需要独立产品能力、connection CAS、Task binding epoch 和持久化设计。

每个阶段的 Bridge hard cut 都必须在同一提交同步 `app.zon`、Zig command catalog/decoder/dispatcher、TypeScript command catalog/runtime decoder、snapshot fixture、行为测试和本地化文案。不得让已失去 owner 的字段/命令存活到 E，也不得保留旧命令 alias。

### 11.3 UI

设置页分为两个明确区域：

- Account：登录、身份、刷新授权、退出；
- Models：推荐 Provider、自定义连接、模型目录、默认模型、测试和恢复。

用户未登录时，Metask Provider 显示 `需要登录`，但 Models 页面、自定义连接和 New Task 的自定义模型路径保持可用。Account 菜单不得承载模型选择。

Models UI 必须分别呈现“Metask 配置”和“新 Task 默认模型”。custom 为默认时，用户仍可浏览、刷新和修改 Metask Provider-local selection；该操作不暗中切换全局 default。切换回 Metask 是显式 global-default 操作，使用当前已验证的 Metask selection。

Connection 编辑、删除和 credential replacement 不查询或阻止已有 Task/Run/Session。若被修改 source 是当前 global default，Models 先提交 desired intent，Product Control 按 §5.3 关闭新 admission并 reconcile；已有消费者继续使用自己的 binding。该行为会替换现行“execution in use 时禁止删除/编辑”的 UI 合同，必须在阶段 B/D 对应真源中明确 hard cut。

## 12. 模块结构与依赖 Gate

建议最小结构：

```text
src/product/models.zig
src/product/models/
├── contract.zig
├── state.zig
├── runtime.zig
├── connections.zig
├── ports.zig
└── providers/
    └── metask.zig
```

只有当 persistence 或 catalog 已形成独立 owner/测试收益时，再拆出对应 leaf；不为了目标目录树预建空层。

`src/product/models.zig` 是 canonical aggregate root，不是旧 `execution` 名称的 forwarding facade。它只导出 Product Control 构造和持有 aggregate 所需的 `Runtime`、`StartError` 等 aggregate API，不转发完整 contract/ports barrel。允许的精确消费路线是：

- Product Control runtime 通过 `metawork_product_models` 取得 aggregate Runtime，同时可直接导入纯 `metawork_product_models_contract` 和窄 `product_models_ports`；
- Application coordinator/binding 直接导入 contract/ports，不获得 Models policy；
- Task/Schedule 只导入纯 contract；
- 其他消费者不得以 root 绕过 leaf 边界。

因此“Product Control 走 aggregate root”只描述 Runtime ownership，不表示同一文件不能使用纯 value contract 或 injected port。root、contract、ports 是三个不同层，不是三条等价 active path。

依赖规则：

```text
product/models/**
  may import: std, models contract/leaf, injected ports, shared bounded utilities
  must not import: product/task, product/schedule, product/control runtime,
                   agent, bridge, renderer, app, account runtime

product/task and product/schedule
  may import: models contract
  must not import: models runtime, account contract/runtime

agent
  must not import: models runtime or Product Control
```

`build.zig` 的具名 module graph 是依赖方向真相，architecture guard 必须读取/断言具名 module import edge，而不是扫描源码字符串并维护例外列表。至少固定以下 edge 规则：

```text
product_models_runtime -> models_contract, models_ports, owned Models leaves
product_control_runtime -> models root, models_contract, models_ports
application adapters -> models_contract, models_ports
product_task/product_schedule -> models_contract only
product_models_* -X-> product_task, product_schedule, product_control,
                      account runtime, agent, bridge, app
account_* -X-> models runtime/ports; 阶段 B 后也不再导入 models contract
agent_* -X-> models/product
```

guard 必须通过删除或添加一条临时非法 module edge 证明会失败；文字匹配只可补充检查旧路径/identifier 残留，不能承担 owner 方向 Gate。

## 13. 当前实现迁移映射

| 当前路径/职责 | 目标 |
| --- | --- |
| `src/product/execution/contract.zig` | `src/product/models/contract.zig` |
| `src/product/execution/runtime.zig` | `src/product/models/runtime.zig` |
| `src/product/execution/model_connections.zig` | `src/product/models/connections.zig` |
| `src/product/execution/ports.zig` | `src/product/models/ports.zig` |
| Account API/model catalog | `src/product/models/providers/metask.zig` |
| Account API/model preference | Models Metask Provider-local selection；Metask 是 global default 时同 transaction 更新 global selection |
| Account source candidate | Models-owned source resolution |
| `src/app/execution_coordinator.zig` | `src/app/models_coordinator.zig` |
| `src/product/control/execution_state.zig` | 保留职责并收敛为 Product Control `DefaultBindingState`；不迁入 Models，不在 B–E 删除 |
| `Availability` / `taskCreationAvailable` | 分别成为 Product Control `BindingAvailability` / `newTaskAdmission.available`，不属于 Models contract |
| `beginIdentityReplacement` / `beginDefaultReplacement` | 保留 Product Control 串行化职责，按 source-authority/default-selection 语义改名 |
| `OwnedTaskExecution` | Task-owned `OwnedModelBinding` wrapper/owner |
| Models registry `connection_generation` | `connection_revision + source_generation + catalog_generation`，按变化原因分别推进 |
| Models registry `default_execution_generation` | 不迁移；Product Control 在进程内分配 `binding_generation` |
| Product Control `selectTaskModel` 的 catalog 校验 | Models resolve + Product Control transfer + Task commit |
| `execution` snapshot root | 拆为 Models-owned `models` 与 Product Control-owned `newTaskAdmission` |
| `installAutomationExecution` 的伪造 Account fact | automation-only Models source/binding fixture，走同一 Models resolve/install path |
| `executionManagement()` | `modelsManagement()` |

迁移完成后删除旧 `src/product/execution/`、旧 module imports、Account 模型 transaction、旧 Bridge 命令和 Renderer 分支。Git 历史负责恢复，不建立 active archive。

Automation 路径必须在阶段 B 同步完成：`-Dautomation=true` 构建可以由 Application 注入 compile-time gated 的 automation Models source candidate，但不得构造 Account identity、catalog fact 或 Metask preference。该 source 通过与生产 source 相同的 Models validation、Product Control install 和 owned binding transfer；生产构建不导出 automation command/port，release Bridge allowlist 不增加 fixture 入口。

## 14. 实施顺序

### 阶段 A：合同与 module graph hard rename（已完成）

`ccf1707` 已建立 Models 纯合同与 root module、迁移 Execution contract/runtime/connections/ports、更新消费者 import、删除旧目录并加强 Task/Schedule import guard。它不改变产品行为、wire 或持久化语义。

#### A-close：非语义收口

1. `executionManagement()` 改为 `modelsManagement()`。
2. Models root 只保留 aggregate API，删除未使用的 contract/ports re-export。
3. 明确 Product Control 允许 root + contract + ports 三层精确 import。
4. 独立修复或精确归类 Windows Task persistence quarantine 测试的 file flag 崩溃，使 B 开始前相关正式 test graph 有可信 baseline。

同步真源：只有 module root/依赖文字变化时更新[工程结构与所有权](../project-structure.md)；测试归属或长期缺口变化时更新[验证规范](../validation.md)。不因纯命名修复机械更新其他规范。

### 阶段 R：Model Connection readiness slice

1. 删除 `app.zig` 与 Dispatcher 中“Native SDK 没有 secure input”的过期注释。
2. 按 §7.5 建立 Application-owned `ModelConnectionHost`，连接现有 native secure input 与 Models coordinator credential mutation capability。
3. Windows 只在 management、secure capture、connection test 三项均真实可用时发布完整 capability；任一缺失整体隐藏设置入口。
4. 移除 Renderer `MODEL_CONNECTION_SETTINGS_ENABLED = false` 硬门，继续由 Host capability fail closed。
5. 覆盖 create → credential vault → test → select default → signed-out Task create/run → shutdown zeroization 的真实 Windows desktop vertical。
6. 补齐 Windows UIA password 语义和长时间输入人工证据，不把已有基础 secure-input 证据夸大为完整交互验收。
7. macOS 保持 capability false，直到 compile、modal reentrancy、VoiceOver 明文检查和 shutdown Gate 全部通过；不得借 Windows vertical 开放。
8. 阶段 R 创建的真实 Connection 继续写当前 `model-connections.json`；它从此被视为可能包含真实用户数据，并成为阶段 B 严格迁移输入，禁止再依据历史发布版本执行 hard cut。

阶段出口：Windows 上 signed-out custom source 可真实创建并运行 Task；失败不影响 Account，secret 不进入 Bridge/Renderer。macOS 明确保持未开放，不伪报跨平台完成。

同步真源：[产品需求](../requirements.md)、[UI 设计规范](../ui-design.md)、[高层架构](../architecture.md)、[Product 架构](../product-architecture.md)、[Renderer Bridge 合同](../renderer-bridge-contract.md)、[工程结构与所有权](../project-structure.md)、[验证规范](../validation.md)。Account 合同不变，不机械修改[Account 架构](../account-architecture.md)。

### 阶段 B：Metask 模型职责迁移

1. 用户已随整套方案批准 `preferences.json + model-connections.json → models.json` 严格一次性迁移；不再请求基于旧历史的 connection hard cut，也不建立临时双写。
2. 建立 Models-owned Metask provider/source state、Metask Provider-local selection、global default selection、connection/source/catalog revision 和 provider catalog transaction。实现期间的新代码不得同时取得 production authority；已提交 checkpoint 始终只有旧路径或新路径之一可运行。
3. 按 §10.2 在一次 bootstrap transaction 中读取两份 legacy store、构造并提交 canonical `models.json`，同时移除 `default_execution_generation` 的 Models persistence。阶段出口前停止 legacy writer；不存在 B–D 继续写旧格式的过渡期。
4. 实现 §7.4 prepare/complete catalog worker 合同，由 Application 拥有线程、transport、mailbox、cancel/join。
5. 把 Account coordinator source candidate handoff 替换为窄 authorization capability；Models 不导入 Account Runtime，Account 最终不再导入 Models contract。
6. 从 Account contract/view/state/runtime 移除 API/model catalog、selection、preference 与 source candidate；只保留 OAuth identity/authorization。Metask authority 按 §6.3 的外部对象 identity 重建，不把 token/secret rotation 冒充 source replacement。
7. 在同一阶段 hard cut `account`/`models` snapshot、Metask Provider-local/global-default commands、allowlist、Renderer 设置区域和 fixture；不得由 Product Control 把 Models 字段伪装回旧 Account projection，也不得丢失 custom-default 下的 Metask intent。
8. 将 Models desired commit 与 Product Control active reconcile 分开：Models commit 不等待消费者；Product Control 对 mismatch 关闭新 admission、完成 scrub/resolve/install，失败不回滚 Models。同阶段删除 Connection edit/delete 的 consumer identity 查询和 `execution_in_use` Gate。
9. 同步 automation：删除伪造 Account fact，改为 automation-only Models source，并经过同一 resolve/install path。
10. Product Control `DefaultBindingState` 继续负责 installed binding、replacement/redaction、Task/Run recovery equality 和 Task admission；验证 Account ready 与 Models unavailable、Models desired 与 active mismatch 都是合法可恢复状态。

阶段出口：Metask 登录和目录通过唯一 Models provider path 工作；Account 不含模型职责；`models.json` 是唯一 Models durable authority；Provider-local/global selection 均被保留；custom readiness vertical 继续通过；automation 不伪造 Account。

同步真源：[产品需求](../requirements.md)、[UI 设计规范](../ui-design.md)、[高层架构](../architecture.md)、[Product 架构](../product-architecture.md)、[Account 架构](../account-architecture.md)、[Renderer Bridge 合同](../renderer-bridge-contract.md)、[工程结构与所有权](../project-structure.md)、[验证规范](../validation.md)。

### 阶段 C：消费者中立解析

1. Product Control 通过 Models `resolveDefault` 取得 `OwnedModelBinding`，再包装为 Product binding candidate 并提交 Task。
2. Task 模型切换使用 source-qualified target `ModelRef`，但保持 Metask-only exact-authority capability；不开放 custom/cross-source rebind。
3. Completion 只消费 owned binding；Models 不导入 Completion/Agent。
4. 将 `Availability`、`taskCreationAvailable` 和 replacement transaction 从 Models contract 中剥离到 Product Control `DefaultBindingState/newTaskAdmission`，并在同一阶段 hard cut snapshot 与 `tasks.selectModel` payload。
5. Schedule 在 E 前继续使用现有固定 protocol/model/execution-generation definition 和 admission，不获得 Models runtime import；其 source-qualified persistence 与 per-occurrence resolve 和 schema migration 一起原子切换，避免不可恢复的中间格式。Product binding generation 不再由 Models store 持久化，Task/Run 继续走现有 recovery/adoption。
6. 将 architecture Gate 改为 build module edge guard，并用非法 edge mutation 证明 fail closed。

阶段出口：Task、Schedule、Completion 只消费 Models 纯合同；Models 无 consumer-specific API；现有 Task/Run restore equality 仍由 Product Control 提供；Schedule 仍走唯一旧持久化语义且未产生第二 active format。

同步真源：[产品需求](../requirements.md)、[UI 设计规范](../ui-design.md)、[Product 架构](../product-architecture.md)、[Account 架构](../account-architecture.md)中仅删除残留交叉职责、[Renderer Bridge 合同](../renderer-bridge-contract.md)、[工程结构与所有权](../project-structure.md)、[验证规范](../validation.md)。高层 owner/故障域不变时不修改[高层架构](../architecture.md)。

### 阶段 D：自定义模型完整语义

1. Connection 使用有界非空模型集合。
2. 增加自定义模型 add/replace/remove transaction，所有 identity 使用 `source_id + model_id`。
3. 增加 capability/token metadata 与 provenance；unknown 不伪装 false/verified。
4. Probe 绑定精确 source generation + model id，stale completion 不提交。
5. 默认选择统一使用完整 `ModelRef`；普通 metadata 编辑不自动 probe/设默认。
6. 在同一阶段 hard cut 现有 `modelConnections.*` 为 §11.2 的 `models.connections.*`，同步 allowlist、Host、Renderer 和 fixture。
7. 将旧 connection command payload 的 `expectedConnectionGeneration` hard cut 为与 mutation 对应的 connection/source/catalog revision；底层 split 已在 B 的 canonical store 建立，D 不再保留混合字段。

阶段出口：第一版单模型表单仍可用，底层和 wire 能完整表达有界多模型集合；custom readiness vertical 不回退。

同步真源：[产品需求](../requirements.md)、[UI 设计规范](../ui-design.md)、[Product 架构](../product-architecture.md)、[Renderer Bridge 合同](../renderer-bridge-contract.md)、[Completion 架构](../completion-architecture.md)、[工程结构与所有权](../project-structure.md)、[验证规范](../validation.md)。Account 无变化。

### 阶段 E：Schedule 持久化、source authority 与最终收口

1. 用户已随整套方案明确批准 Schedule schema 1 → 2 迁移；Models canonical store 已在 B 完成，不在本阶段重新打开 legacy store。
2. 原子切换 Schedule definition 为 `ModelRef + source_generation + selection_revision + protocol` 和 per-occurrence Product Control resolve，同时执行 schema 1 → 2 migration-required 转换；Task/Run persistence 不迁移。
3. 每次 occurrence 同时校验 Models desired、source authority 与 Product Control active readiness；新 Task 才取得当前 Product binding generation，Schedule 不保存或比较该值。
4. 同步 Schedule rebind/migration 所需的 revision 1 wire、Host/Renderer DTO/decoder、fixture、UI 和本地化；复核 B–D 已删除的 Account/旧 Models command 不得重新出现。
5. 验证 migration definite failure/outcome unknown、旧文件保留、Schedule 显式 rebind、Metask cold-start、A → B → A 和 desired/active mismatch。

阶段出口：新旧格式不存在并行 active path；全部规范和机器 allowlist 一致；B–E 全量回归与真实生命周期通过。

同步真源：[产品需求](../requirements.md)、[UI 设计规范](../ui-design.md)、[Product 架构](../product-architecture.md)、[Renderer Bridge 合同](../renderer-bridge-contract.md)、[工程结构与所有权](../project-structure.md)、[验证规范](../validation.md)，以及 release allowlist 机器真源 `app.zon`。Account owner 和顶层故障域未变化时不机械修改 [Account 架构](../account-architecture.md)或[高层架构](../architecture.md)。

每个阶段必须以可构建、可运行的单一产品路径结束；不得以“后续阶段会接上”为理由提交不可工作的中间架构。阶段 R 未通过前不启动 B；B 在 owner 改变时同时建立 canonical Models store，C–D 不再接触 legacy Models/Account preference；Schedule 新格式仍只在 E 原子切换。受影响 wire 必须在 owner/语义改变的同一阶段 hard cut，不能保留到 E 的兼容投影。

## 15. 验证计划

### 15.1 架构 Gate

- 从 `build.zig` 具名 module graph 断言 §12 的允许/禁止 edge，不以源码文字扫描代替；
- Models runtime/root 不导入任何消费者、Account Runtime、Agent、Bridge 或 Application；
- Task/Schedule 只导入 Models contract；
- Account 在阶段 B 完成后不导入 Models root/runtime/ports/contract；
- Agent 不导入 Models/Product；
- 临时加入 `product_models_runtime -> product_task`、`product_schedule -> product_models_runtime` 等非法 edge 时 guard 必须失败，恢复后通过；
- 文字扫描只补充验证旧 Execution module/import/command/snapshot identifier 无残留，以及 Models contract 不出现 consumer identity；
- Provider、Protocol 和 source identity 不存在字符串推断路径。

### 15.2 状态与事务

- default selection CAS、stale revision 和幂等选择；
- Metask Provider-local selection 与 global default 分离；custom default 下修改 Metask selection 不改变 global default；
- connection revision、source/catalog/selection generation 分离；display-only mutation 不改变 source generation；
- source generation 与 Product binding generation 不复制、不混用；
- 相同 Metask authority object 冷启动复用 source generation，secret/OAuth token rotation 不冒充 source replacement；principal/API object/protocol/endpoint 变化必须替换 generation；
- Connection 与多 ModelDefinition 的原子 mutation；
- credential tombstone、明确失败和 outcome unknown 恢复；
- stale catalog/probe completion 不能覆盖新 generation；
- logout、换账号和 source replacement 的 secret 清零；
- default 删除不修改 consumer-owned binding；
- catalog/probe worker 在 stale、cancel 和 shutdown 后 join，并销毁 owned completion；
- `DefaultBindingState` 冷启动重建后仍为 recovery equality 的唯一当前比较方。
- Models desired commit 不等待 consumer；desired/active mismatch 关闭新 admission，reconcile 失败不回滚 Models 或修改 existing consumer；
- Product Control 的模型 admission 只消费 Models resolvability/alignment，不旁路读取 Account catalog、selection 或 authorization 推断 Metask readiness；

### 15.3 解耦 vertical

必须覆盖：

```text
Account signed_out
+ Custom source ready
+ Custom model selected
→ Task create/run succeeds
```

```text
Account authenticated
+ Metask catalog unavailable
→ Account remains ready
→ Custom source remains usable
```

```text
Metask is default
+ Account logout
→ Models preserves non-secret intent as needs_authentication
→ new Metask resolve is rejected
→ existing Task continues with its owned binding
```

```text
Models default changes
→ existing Task/Run/Session/Schedule history is unchanged
```

```text
Custom is global default
+ Metask Provider-local selection changes
→ global default and active custom binding are unchanged
→ explicit select-default is still required to switch to Metask
```

```text
Models desired default/source changes
+ Product Control scrub or resolve fails
→ Models durable intent remains committed
→ old active is not used for new Task/Schedule/restore/rebind
→ existing consumers keep their owned binding
```

```text
Custom source mutation fails
→ Account state and Metask authorization are unchanged
```

阶段 R 的第一条 vertical 必须使用真实 Windows desktop、native secure capture、系统 credential vault 和真实 provider probe/run；直接调用 `createWithCapturedCredential`、automation fixture 或预写 registry 只能作为单元测试，不能关闭 readiness Gate。macOS 保持独立证据项。

### 15.4 Bridge 与 Renderer

- Host serializer 与 TypeScript decoder 跨语言 fixture；
- command allowlist 精确一致；
- malformed Provider/source/model payload fail closed；
- signed-out UI 仍可管理并选择自定义模型；
- Account 区域不再显示模型配置；
- snapshot 和 UI 不包含 secret 或 consumer-internal identity；
- `metawork.tasks.selectModel` 对 custom/cross-source target 保持 typed reject；
- old command 全部从 `app.zon`、Host、TypeScript 和 fixture 同时消失。

### 15.5 持久化与恢复

- `preferences.json` 迁移覆盖成功、明确失败、outcome unknown、未登录、owner 不同、catalog stale 和第三种磁盘值；
- 阶段 R 创建非空 `model-connections.json` 后，阶段 B 与 `preferences.json` 一起严格迁移为单一 `models.json`；单 sector 损坏只产生对应 recovery marker，不清空已验证 sector；global default 无法证明时保持 `default_migration_required`；
- migration commit 明确失败或 outcome unknown 不安装半写内存 state；sector recovery 必须从最新 canonical candidate 合并，不能覆盖迁移后已提交的另一 sector mutation；
- custom default 与 Metask Provider-local preference 同时存在时，两者都迁移且保持各自语义；旧 `default_execution_generation` 不进入新 store；
- Schedule schema 1 全量转换为不可执行 `binding_migration_required`，不得推断 source，不得 launch；显式 rebind 后保存 `ModelRef + source_generation + selection_revision + protocol` 才恢复；
- Metask default + 已启用 Schedule 在相同 authority 冷启动后正常 launch；Product binding generation 可以变化；
- Schedule restore 早于 Account/Models bootstrap 时不因 transient loading 进入 needs-attention；只有明确 unavailable/recovery terminal fact 才按产品规则停止；
- global default A → B → A 后旧 Schedule 因 selection revision 不同进入 needs-attention；source/protocol 变化和 desired/active mismatch 同样不得 launch；
- Task/Run/checkpoint fixture 证明 `execution_generation` shape 与 exact/adoption restore 合同未改变；
- cold start、logout、source replacement、registry recovery 和 shutdown 全路径验证 secret 清零。

### 15.6 标准检查

- 受影响 Zig module tests；
- Product Control、Account、Task、Schedule、Completion tests；
- 正式 Native test graph；
- Renderer typecheck 与受影响 suite；
- Bridge fixture/contract tests；
- architecture/import guards；
- `git diff --check`、Markdown 链接与残留引用检查。

已知 Windows Task persistence quarantine test 崩溃是 B 前必须收口的 baseline 项。Phase A 未修改该 leaf 只能证明它与 `ccf1707` 无关，不能仅凭 stdlib `unreachable` 就宣称根因已经证明；应针对测试直接 `openFile` 后缺少现有 Windows file flag 适配建立最小回归，再决定是测试修复还是 Zig 上游缺陷。

## 16. 需要明确批准的决策

| # | 决策 | 结论 | 状态 |
| --- | --- | --- | --- |
| 1 | aggregate 和目录采用 `Models` / `src/product/models/` | 接受，阶段 A 已完成 | 已批准 |
| 2a | 产品是否继续需要当前 binding equality token | 需要；由 Product Control `DefaultBindingState` 进程内拥有，不要求单调，也不写入 Models store | 已选择 |
| 2b | 外部 `executionGeneration` 是否改名为 `sourceGeneration` | 不改；两者是不同 owner 的不同事实 | 已选择 |
| 3a | Account `preferences.json` | 阶段 B 与 connection registry 一次性严格迁移，成功前保留旧文件 | 已批准 |
| 3b | `model-connections.json` | 阶段 R 后可能包含真实用户数据，必须在 B 严格迁移，撤销旧 hard-cut 推荐 | 已批准 |
| 3c | Schedule schema 1 | 迁移 schema 2；无 source 的旧 definition 进入 `binding_migration_required`，禁止猜测 | 已批准 |
| 4 | logout 后的 Metask intent | Models 保留非 secret intent，但新 resolve 需要新鲜 Account authorization；custom 不受影响 | 已选择 |
| 5 | Bridge revision | 按现行合同保持 revision 1 原地 hard cut；首次 wire 变更前核实没有外部 Renderer consumer | 已选择，B 前复核事实 |
| 6 | 自定义模型首版 | UI 单模型表单，底层有界非空集合 | 已选择 |
| 7 | installed binding authority | B–E 保留进程内 `DefaultBindingState`；未来删除另立方案 | 已选择 |
| 8 | Model Connection Task 模型切换 | 本轮不开放；只保留 Metask exact-authority 路径 | 已选择 |
| 9 | secure capture 平台开放 | Windows 先完成阶段 R；macOS 按独立真实平台 Gate 开放 | 已选择 |
| 10 | Metask source authority | authority 取 principal + API Key object + protocol + endpoint；普通 secret/token rotation 不改变 source generation，未来更细区分必须先有服务端非 secret revision | 已批准 |
| 11 | Metask selection 与 global default | 作为两个 Models-owned intent 保存；custom default 下修改 Metask selection 不切换 global default | 已批准 |
| 12 | Models desired 与 Product active | Models 先独立 durable commit；Product Control reconcile 失败关闭新 admission但不回滚意图或修改 existing consumer | 已批准 |
| 13 | Schedule schema 2 binding | 保存 `ModelRef + source_generation + selection_revision + protocol`，不保存 Product binding generation | 已批准 |
| 14 | custom Connection identity/CAS | `connection_id == source_id`；另设 connection revision，不用 source generation 承担通用 mutation CAS | 已批准 |

用户已于 2026-09-02 通过“使用 Goal 进行方案实施”的指令批准本表全部实施决策。阶段 B 仍依赖阶段 R 和已选择的 1、2、4–14；首次 wire hard cut 前仍须复核决策 5 的事实前提。阶段 E 仍依赖阶段 D 完成及其迁移 Gate，不因批准而跳过验证。

## 17. 完成定义

完成分两层，避免把 Account/Models owner 收口绑在后续能力扩展上。

`Models Core` 在阶段 B–C 后满足：

- Account 代码、合同、Snapshot、持久化和 UI 中不存在模型配置职责；
- `models.json` 是 Provider/source、Metask Provider-local selection、global default 和 custom registry 的唯一 durable 真相；
- Models desired 与 Product active 有明确 mismatch/reconcile 语义，Models mutation 不查询 consumer；
- Metask 与自定义来源经过同一 Models resolve/owned-binding 合同；
- 旧 Execution aggregate/module active path 和旧 Account 模型路径全部删除；Product Control `DefaultBindingState` 只是 installed/admission authority，不形成第二 Models 控制面；
- Windows signed-out custom vertical 保持通过，macOS 未通过时明确保持 capability false；
- Task/Run `execution_generation` shape 与 recovery/adoption 合同未改变。

完整 B–E 方案还必须满足：

- custom Connection/model CRUD 使用 `source_id + model_id` 和分离的 revision/generation；
- Schedule schema 2 不依赖进程内 Product binding generation，并通过 cold-start 与 default ABA 验证；
- Models 不依赖或修改任何消费方；
- consumer 拥有并独立释放已转移 binding；
- credential 全生命周期验证通过；
- Schedule migration、Bridge hard cut、Renderer 和规范真源同步完成；
- automation 使用 Models fixture source，不伪造 Account fact；
- catalog/probe workers 的 cancel、stale completion 和 shutdown join 已验证；
- module import 方向由具名 graph guard fail closed；
- 所有相关 tests、build、guards 和 vertical 均通过。

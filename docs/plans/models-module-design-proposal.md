# MetaWork Models 模块设计提案

> 状态：设计提案（本轮定稿），非规范性真源，尚未批准实施
>
> 目的：为 Account 与模型体系解耦、用户自定义模型和消费方隔离提供可实施方案
>
> 后续：方案获批后，必须分别更新受影响的产品、架构、Account、Bridge、UI、Completion、工程结构与验证真源；本文不替代这些合同

## 1. 结论

MetaWork 应在 Product Control 下建立独立的 `Models` aggregate，统一拥有 Provider、模型来源、连接、模型目录、默认选择、配置解析和模型连接凭据。现有 `Execution` aggregate 中属于模型控制面的职责应一次性迁入 `Models`，迁移完成后删除旧路径。

Account 只负责公司账号身份与授权，不再拥有 API Key/模型目录、默认 API、默认模型、模型 preference 或模型运行配置。Metask 对 `Models` 而言只是一个内置、推荐、使用 Account 授权的 Provider。

`Models` 是模型配置和绑定的供应方，不是执行引擎。它向运行消费者提供 owned、冻结的模型绑定，向 Schedule 等延迟消费者只提供无 secret 的 `ModelRef`/描述事实；它不接收消费者身份，不创建或修改消费者状态，也不干预绑定交付后的消费行为。

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

## 2. 设计目标

本方案必须同时满足：

1. Account 与模型体系具有独立生命周期、持久化、错误和恢复状态。
2. 用户不登录 Metask，只要自定义模型来源可用，就能创建并运行 Task。
3. Metask 登录成功不自动选择、替换或启用任何模型。
4. Account logout 不删除自定义 Provider，不改写已有 Task，也不清除非 secret 的 Models 用户意图。
5. Provider、Protocol、Connection、Model 和 Consumer 是不同概念，不互相推断或合并。
6. Models 不导入或操纵 Task、Schedule、Completion、Agent、Bridge、Renderer 或 Account Runtime。
7. 模型配置变化只影响后续解析；已交付给消费者的 owned binding 不被热替换。
8. credential 不进入 Renderer、Bridge、日志、event、snapshot 或持久历史。
9. 现有实现通过单一路径完成 hard cut，不保留并行的 Execution/Models 控制面。
10. 自定义模型能力从最小端到端版本开始：显式协议、endpoint、credential 和至少一个 model id；其后再扩展多模型及能力元数据编辑。

## 3. 非目标

本次不负责：

- Agent loop、Session、Conversation、Run 或工具调用；
- Provider HTTP/SSE codec 与 AgentCore ABI；
- 本地模型下载、安装、进程托管和资源调度；
- 根据模型名称、endpoint 或 Provider 品牌推断协议与能力；
- 动态 Provider 插件框架；
- 已有 Task 的隐式 rebind；
- Provider 配置变化后的自动重试、fallback 或消费者广播；
- 为旧内部模块名保留 facade、alias 或双写。

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
├── credential authority
├── source_generation
└── availability
```

`source_id` 是 Models 域内稳定、不透明、非 secret 的身份。它不是 Provider 类型，不进入模型请求，也不能替代 generation。相同 endpoint 或 credential 的不同连接仍拥有不同 source identity。

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
- 默认 `ModelRef` 与 selection revision；
- source/catalog/selection generation；
- `OwnedModelBinding` 的构造和线性转移；
- Models 自己的 persistence health、operation 和 recovery。

### 5.3 Product Control

Product Control 持有 Models aggregate，并只负责跨 aggregate 用例：

- Task 创建时取得 default binding，再提交给 Task；
- Task 显式模型切换时，从 Models 取得 candidate，再由 Task 自己提交；
- Schedule occurrence 创建 Task 时取得所需 binding；
- canonical snapshot 的组合与 secret scrub；
- shutdown 顺序和 owned transfer 的完成。

Product Control 不复制 Models policy，不根据 snapshot、display name、URL 或 consumer 状态推断模型配置。

### 5.4 Application

Application 只组装平台 capability 和跨 owner effect：

- 把 Account committed authorization 转换成 Models 可消费的窄授权输入；
- 为 Models 注入 credential vault、persistence 和网络 transport；
- 执行 Models prepare 的 probe job，并把 typed completion 交还 Models；
- 安排主线程 wake、drain 和 shutdown 顺序。

Application 不读取 Models/Account view 后形成默认选择、source readiness、Task admission 或 probe 成功策略。

### 5.5 消费者

Task、Schedule 和 Completion 只依赖 Models 的纯合同。运行消费者在接收 owned binding 后独占自己的副本和生命周期：

- Task 拥有 attachment、当前模型、binding epoch、Run 和历史；
- Schedule 只保存无 secret 的 `ModelRef`/模型描述事实，并拥有定义、触发、occurrence 和对应历史；到期时由 Product Control 解析 binding并创建真实 Task；
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

登录成功只产生 Account authorization。Models 可以随后刷新 Metask source，但不得自动：

- 选择 Metask 为默认 Provider；
- 覆盖当前自定义默认模型；
- 创建 Task；
- 改写已有 Task；
- 将目录加载失败回写为 Account 登录失败。

### 6.2 Logout

Account logout 后：

- Account 清除自己的 token；
- Models 撤销新的 Metask resolve capability并清零未转移的 Metask credential；
- Models 保留非 secret 的默认选择意图，并把对应 source 标记为 `needs_authentication`；
- 自定义 source 和其默认选择不受影响；
- 已交付给 Task/Completion 的 owned binding 不被 Models 主动撤回；
- 若未来需要强制安全撤权，必须建立独立显式 revocation 合同，不能借普通 logout 或配置编辑暗中改写消费者。

### 6.3 换账号

Metask source 必须绑定 opaque principal reference。新账号不能复用旧账号的 source credential 或 catalog。旧选择意图可以保留为 unavailable，但只有同一 principal 的新授权和新鲜 catalog 能恢复运行资格；不得根据显示名、API Key 尾号或 model id 猜测等价性。

Account `authorization_generation` 不能直接复制成 `source_generation`。OAuth token rotation 只改变管理授权；只有模型 API credential、source principal、protocol 或 endpoint 的可执行权威发生变化时，Models 才生成新的 `source_generation`。

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

### 7.4 非干预合同

Models 对消费者的影响止于“是否为当前请求签发一个 binding”：

- Models 可以依据自己的 source、catalog、credential 和 revision 事实接受或拒绝一次 resolve；
- resolve 成功后，binding 与 Models registry、vault buffer 和 Runtime 生命周期解耦；
- default/source/model 的编辑、删除和故障只影响未来 resolve；
- Models 不等待 consumer 释放，不持有 consumer callback，不发送 rebind/cancel/retry 指令；
- consumer 不在每次 Run 前回查默认选择；它只使用自己已经提交的 binding；
- 配置删除后外部服务是否仍接受旧 credential 是服务端事实，不授权 Models 篡改本地 consumer 历史或伪造取消；
- default selection 的提交不得以 Task、Schedule、Session 或 Run 状态为前置条件。

如果某个用例需要同时改变 Models 和 consumer，Product Control 必须分别取得 Models candidate 和 consumer admission，并把 ownership 转移给 consumer；Models 自身不得获得跨 aggregate commit 权限。

## 8. 状态与 generation

不同事实使用不同 revision，不再由 `execution_generation` 混合表达：

| 字段 | 变化条件 | 不因何变化 |
| --- | --- | --- |
| `authorization_generation` | Account principal/token authority replacement | 模型选择、目录刷新 |
| `source_generation` | protocol、endpoint、credential authority 或 source principal 改变 | 同 source 下选择其他模型 |
| `catalog_generation` | source 的模型集合或公开元数据替换；remote catalog 每次新鲜观察产生新 identity | 默认选择变化 |
| `selection_revision` | 默认 `ModelRef` 变化或被清除 | 无关 source/catalog 变化 |
| Task `binding_epoch` | Task 自己明确提交新的 source attachment | 全局默认变化 |

消费者历史使用 `protocol + model_id + source_generation + binding_epoch` 解释运行事实。`source_generation` 不需要表示全局顺序，只用于精确相等判断。

默认模型变化只更新 `selection_revision`。若新默认模型仍在同 source 下，`source_generation` 不变；若 source credential、endpoint 或 protocol 改变，则生成新的 `source_generation`。

## 9. 配置命令

建议 Models 命令集合：

```text
refresh_provider_catalog
select_default
create_connection
replace_connection
remove_connection
probe_model
add_custom_model
replace_custom_model
remove_custom_model
recover_registry
```

所有 mutation 使用 expected revision/generation 做 CAS。`select_default` 接受完整 `ModelRef`，统一替代 Account 模型选择、Model Connection 默认选择和“切换回 Metask”三条特殊路径。

Connection 与 Model 是不同对象：

- 一个 Connection 可以包含多个模型；
- Connection mutation 不通过模型 display name 定位；
- 移除默认模型必须原子清除或替换默认 selection；
- 移除 source 禁止未来 resolve，但不进入消费者修改既有 binding；
- 自定义模型能力缺失保持 unknown；
- 普通编辑不自动 probe，probe 也不自动设为默认。

第一阶段可以只开放创建 Connection 时提交一个模型，但内部持久化和身份从一开始必须支持非空有界模型集合，避免把 Connection 与 Model 永久合并。

## 10. 持久化与恢复

### 10.1 Canonical store

长期使用单一原子 `models.json`，拥有：

- custom Provider/Connection public configuration；
- custom ModelDefinition；
- 默认 `ModelRef`；
- durable source generation 与 selection revision；remote catalog generation 不持久化；
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

Credential 继续位于系统安全存储，Models store 只保存 locator。创建、替换和删除沿用 tombstone-first、credential effect、registry commit、cleanup 的可恢复顺序。

上句只适用于用户自定义连接。Metask 模型 API credential 不写入 `models.json` 或长期 vault；它在登录后的新鲜 provider/catalog transaction 中取得，随 Models runtime source 持有，并在 authorization loss、source replacement、logout 和 shutdown 时 secure-zero。非 secret 的 Metask `ModelRef` 用户意图可以独立持久化。

### 10.2 现有数据迁移

当前 `preferences.json` 保存 Account-owned API/model preference，`model-connections.json` 保存用户连接和默认 binding。两者属于已有持久化格式，不能未经明确批准直接破坏。

推荐一次性迁移：

1. 仅在 `models.json` 不存在时读取两个旧 store；
2. 严格验证旧数据，不接受旧 shape alias 或宽松字段；
3. 构造完整的新 registry candidate；
4. 原子提交 `models.json`；
5. 新文件提交成功后，以 `models.json` 为唯一真相；
6. 后续清理旧文件，但不再双写；
7. 中途 crash 时，下次启动按“新文件存在即为 canonical”继续 cleanup；
8. 任一旧 store 不确定或损坏时 fail closed，不覆盖原文件，也不伪造迁移成功。

迁移必须精确保留 custom connection identity、protocol、normalized endpoint、模型集合、selected model、credential locator、connection generation、默认选择和 credential-deletion tombstone。Account 旧 preference 中的 owner/API/model 只迁为 Metask provider-scoped 的非 secret selection intent；OAuth token、Account refresh state 和 remote catalog 不迁移。迁移 reader 只在新 store 不存在时运行，不参与正常恢复，也不能在新 store 失败后回退到旧 store。

如果产品尚未发布且确认不存在需要保留的用户数据，也可以经用户明确批准选择 hard cut。实现前必须在“一次性迁移”与“清除旧模型配置”之间作出明确决定。

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
  defaultSelection
  selectionRevision
  operation
  error
}
```

Models projection 不包含 credential、完整 endpoint secret、Account token、Task binding 或 Consumer identity。

### 11.2 Commands

建议 wire command：

```text
metawork.models.refreshCatalog
metawork.models.selectDefault
metawork.models.connections.create
metawork.models.connections.replace
metawork.models.connections.remove
metawork.models.connections.test
metawork.models.customModels.add
metawork.models.customModels.replace
metawork.models.customModels.remove
```

删除：

```text
metawork.account.refreshCatalog
metawork.account.selectApiKey
metawork.account.selectModel
metawork.modelSources.selectMetaskDefault
metawork.modelConnections.selectDefault
```

Bridge hard cut 必须同步 `app.zon`、Zig command catalog/decoder/dispatcher、TypeScript command catalog/runtime decoder、snapshot fixture、行为测试和本地化文案。不得保留旧命令 alias。

### 11.3 UI

设置页分为两个明确区域：

- Account：登录、身份、刷新授权、退出；
- Models：推荐 Provider、自定义连接、模型目录、默认模型、测试和恢复。

用户未登录时，Metask Provider 显示 `需要登录`，但 Models 页面、自定义连接和 New Task 的自定义模型路径保持可用。Account 菜单不得承载模型选择。

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

`build.zig` 的具名 module graph 和 architecture guard 必须共同强制这些方向，不能只依赖注释或评审习惯。

## 13. 当前实现迁移映射

| 当前路径/职责 | 目标 |
| --- | --- |
| `src/product/execution/contract.zig` | `src/product/models/contract.zig` |
| `src/product/execution/runtime.zig` | `src/product/models/runtime.zig` |
| `src/product/execution/model_connections.zig` | `src/product/models/connections.zig` |
| `src/product/execution/ports.zig` | `src/product/models/ports.zig` |
| Account API/model catalog | `src/product/models/providers/metask.zig` |
| Account API/model preference | Models default selection |
| Account source candidate | Models-owned source resolution |
| `src/app/execution_coordinator.zig` | `src/app/models_coordinator.zig` |
| `OwnedTaskExecution` | Task-owned `OwnedModelBinding` wrapper/owner |
| Product Control `selectTaskModel` 的 catalog 校验 | Models resolve + Product Control transfer + Task commit |
| `execution` snapshot root | `models` snapshot root |

迁移完成后删除旧 `src/product/execution/`、旧 module imports、Account 模型 transaction、旧 Bridge 命令和 Renderer 分支。Git 历史负责恢复，不建立 active archive。

## 14. 实施顺序

### 阶段 A：合同与 module graph hard rename

1. 建立 Models 纯合同与 root module。
2. 将 Execution contract/runtime/connections/ports 原位迁移并更新 build graph。
3. 更新所有消费者 import。
4. 删除旧 Execution module，不保留 forwarding facade。
5. 保持现有行为可构建、可测试，为后续语义迁移建立唯一入口。

### 阶段 B：Metask 模型职责迁移

1. 从 Account contract/view/state/runtime 移除模型 catalog、API/model selection 和 preference。
2. 将 Metask model client/catalog transaction 移入 Models provider adapter。
3. 将 Account coordinator 的 source candidate handoff 替换为窄 authorization coordination。
4. Models 独立发布 provider/source/catalog/default 状态。
5. 验证 Account ready 与 Models unavailable 可以同时合法存在。

### 阶段 C：消费者中立解析

1. Product Control 通过 Models `resolveDefault` 创建 Task candidate。
2. Task 模型切换改为 Models resolve candidate → Task commit。
3. Completion 只消费 owned binding；Schedule 只消费无 secret 的 `ModelRef`/描述事实，occurrence 由 Product Control 解析后创建 Task。
4. Models API 和状态中删除全部 consumer-specific 概念。
5. 新增 build/import guard。

### 阶段 D：自定义模型完整语义

1. Connection 使用有界非空模型集合。
2. 增加自定义模型 add/replace/remove transaction。
3. 增加 capability/token metadata 与 provenance。
4. Probe 绑定精确 source generation + model id。
5. 默认选择统一使用 `ModelRef`。

### 阶段 E：持久化与 Bridge/UI hard cut

1. 实现已批准的数据迁移策略。
2. 切换 canonical `models.json`。
3. 同步 Snapshot、commands、allowlist、decoder、fixtures 和 UI。
4. 删除旧 store active path、命令和 Account 模型页面。
5. 完成全量回归和真实生命周期验证。

每个阶段必须以可构建、可运行的单一产品路径结束；不得以“后续阶段会接上”为理由提交不可工作的中间架构。

## 15. 验证计划

### 15.1 架构 Gate

- Models module graph 不导入任何消费者或 Account Runtime；
- Task/Schedule 只导入 Models contract；
- Agent 不导入 Models/Product；
- Account contract/view 不出现模型 Provider、ModelSource、模型 protocol/endpoint、模型 catalog 或模型选择；Account 自己的 OAuth/HTTP 合同不受该文字匹配规则限制；
- Models contract 不出现 Task/Run/Schedule/Session/Conversation identity；
- 旧 Execution module/import/command/snapshot root 无残留；
- Provider、Protocol 和 source identity 不存在字符串推断路径。

### 15.2 状态与事务

- default selection CAS、stale revision 和幂等选择；
- source/catalog/selection generation 分离；
- Connection 与多 ModelDefinition 的原子 mutation；
- credential tombstone、明确失败和 outcome unknown 恢复；
- stale catalog/probe completion 不能覆盖新 generation；
- logout、换账号和 source replacement 的 secret 清零；
- default 删除不修改 consumer-owned binding。

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
Custom source mutation fails
→ Account state and Metask authorization are unchanged
```

### 15.4 Bridge 与 Renderer

- Host serializer 与 TypeScript decoder 跨语言 fixture；
- command allowlist 精确一致；
- malformed Provider/source/model payload fail closed；
- signed-out UI 仍可管理并选择自定义模型；
- Account 区域不再显示模型配置；
- snapshot 和 UI 不包含 secret 或 consumer-internal identity。

### 15.5 标准检查

- 受影响 Zig module tests；
- Product Control、Account、Task、Schedule、Completion tests；
- 正式 Native test graph；
- Renderer typecheck 与受影响 suite；
- Bridge fixture/contract tests；
- architecture/import guards；
- `git diff --check`、Markdown 链接与残留引用检查。

## 16. 需要明确批准的决策

实施前必须确认：

1. aggregate 和代码目录采用 `Models` / `src/product/models/`；
2. 是否将现有外部 `executionGeneration` 语义和 wire 名称迁为 `sourceGeneration`；
3. 旧 `preferences.json` 与 `model-connections.json` 采用一次性迁移还是明确 hard cut；
4. Account logout 后保留 Metask 非 secret selection intent，但禁止新的 Metask resolve；
5. Bridge revision 1 内原地 hard cut 命令和 snapshot，还是经明确批准调整合同版本；
6. 自定义模型第一阶段只开放单模型表单，但底层从第一天使用有界模型集合。

本提案推荐：1 接受；2 迁移；3 一次性迁移；4 接受；5 保持 revision 1 原地 hard cut；6 接受。

## 17. 完成定义

只有同时满足以下条件，Models 重构才算完成：

- Account 代码、合同、Snapshot、持久化和 UI 中不存在模型配置职责；
- Models 是 Provider/source/model/default selection 的唯一产品真相；
- Metask 与自定义来源经过同一 Models selection/resolve 合同；
- signed-out + custom source 可以真实创建并运行 Task；
- Models 不依赖或修改任何消费方；
- consumer 拥有并独立释放已转移 binding；
- 旧 Execution active path 和旧 Account 模型路径全部删除；
- credential 全生命周期验证通过；
- 数据迁移、Bridge hard cut、Renderer 和规范真源同步完成；
- 所有相关 tests、build、guards 和 vertical 均通过。

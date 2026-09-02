# Account 语义收敛 Hard-Cut 实施方案

> 状态：待实施方案，非规范真源。
>
> 本文用于约束一次性实施顺序、删除范围和验收证据，不替代
> `docs/account-architecture.md`、`docs/product-architecture.md`、
> `docs/renderer-bridge-contract.md`、`docs/requirements.md` 或
> `docs/ui-design.md`。实施造成的长期合同变化必须直接写入对应真源；
> 完成后本文可以删除，Git 历史负责保留过程。

## 1. 结论

Account 收敛为 MetaWork 的 Metask 账号与模型信息 owner：

- 拥有 OAuth、token、identity、Account persistence 与认证恢复；
- 拥有 Metask API Key/model catalog、catalog transaction 与 Metask preference；
- 可以在自身事实完整时构造一次性的 Metask source candidate；
- 拥有 Metask credential/source generation，但它只标识 Account source authority；
- 不拥有 Product 默认来源、Product execution generation、安装/replacement、Schedule scrub、
  Task admission 或下游失败。

跨 owner 依赖固定为单向：

```text
Account committed fact + optional owned Metask source candidate
                              |
                              v
                        Product Control
                              |
                              +-- Product execution generation
                              +-- Schedule credential scrub
                              +-- active/default binding
                              +-- Task admission and recovery
```

Product 可以拒绝、暂存或销毁 candidate，但不得因此补写 Account failure、回滚
Account preference 或伪造 Account identity/catalog 状态。

更精确地说，Account terminal commit 之后的 Product sink 必须 no-fail 接管 candidate
ownership；“拒绝”只能表示 Product 将其安全销毁或转为 Product-owned pending/error fact，
不能作为返回 Account 的 fallible result。

本次原地 hard cut：不迁移、不兼容、不双写旧 Account preference、旧 Bridge
payload 或旧 Schedule store；不保留仅用于兼容旧实现的 error、intent、command、
fixture 和分支。

## 2. 复盘、合同反转与已知缺陷收口

### 2.1 保留的判断

- 当前单一 `metaskExecutionGeneration/execution_generation` 同时承担了 Account credential
  source identity 与 Product execution identity，必须拆成两个 owner 的 generation；不能简单
  删除所有 generation。
- Account preference 的 durable commit 不应依赖 Product/Schedule prepare 成功。
- Schedule 或 Product failure 必须留在 Product projection，不能转译为
  `dependency_contract_invalid`。
- Product 必须能够在 Schedule reset 后于同一进程继续安装，不要求重新登录或刷新
  Account。
- Account、Model Connection 和 Product recovery 必须使用独立 UI busy/error scope。

### 2.2 合同反转：candidate 在 Account commit 前构造，Product effect 在 commit 后执行

本节明确反转当前 `docs/account-architecture.md` §6.3 与
`docs/product-architecture.md` §2.1 已生效的写入顺序。现行合同把 Product durable
Schedule scrub 放在 Account preference commit 之前；新合同取消 Product 对 Account
preference admission 的控制，实施时必须直接改写两份真源，不能把本节当作实现细节。

不能先提交 preference、再尝试构造 candidate。否则 secret 缺失、Metask platform
非法或本地资源不足时，Account 会提交一个自身无法解析的选择。

正确顺序是：

```text
Account validate catalog membership
-> Account locally construct complete source candidate
-> durable preference commit
-> Account aggregate/catalog/preference terminal commit
-> publish Account fact
-> transfer candidate to Product
-> Product performs scrub/install or records Product-owned failure
```

candidate 构造只依赖 Account 自身持有的 identity、catalog session、selection 和 secret，
因此可以作为 Account mutation 的本地前置条件；Schedule scrub、Product execution
generation 与安装
必须位于 Account commit 之后。

安全不变量随 owner 边界改写为：无 secret 的 Account preference 可以先 durable commit；新
credential 在 Schedule scrub 成功前不得安装或用于新 Task，待退役 credential 在 Product
确认 scrub/clear 前不得释放。scrub 失败不会回滚 Account preference，而是形成
Product-owned desired/active mismatch 与 recovery。

### 2.3 修正二：pending candidate 是有界 Product owner，不是无限重试缓存

为了支持同进程 Schedule recovery，Product 可以持有最多一个 pending Metask candidate，
但它必须绑定精确 authority token：

```text
account_id
api_key_id
model_id
source_generation
```

以下任一事实变化都必须立即 secure-zero pending candidate：

- Account identity、selected API、selected model 或 catalog authority 改变；
- Product 默认来源改为 Model Connection；
- 新 candidate 取代旧 candidate；
- logout、shutdown 或 authority validation 失败。

Schedule recovery 只能重试仍与当前 Account authority 精确匹配的 pending candidate，
不能重新播放原 Account command。

`catalog_generation` 只用于 Renderer selection 的 optimistic concurrency。普通 catalog refresh
可能提升它，但只要 committed source authority 未变，就不应使 Product pending candidate
失效。candidate lifetime 因此绑定 Account-owned `source_generation`，不能绑定 UI catalog
generation。

任何 committed Account credential/source authority（account、API Key、credential、protocol
或 endpoint）变化都必须产生新的非零 `source_generation`；同一 source 下的 model-only
preference 可以保持该 generation。任何可能使 Renderer selection 输入失效的 account、catalog
owner 或 catalog contents 变化都必须提升 `catalog_generation`，不能依赖“authority 变化通常会
顺便刷新目录”的隐式调用顺序。

### 2.4 修正三：不在本任务内重写整个 Execution aggregate

当前 Execution 命名和职责仍有进一步简化空间，但本任务只切断 Account 的反向依赖。
以下内容保持：

- 通用 `Protocol`、target 与 Task-owned `ExecutionConfig` 合同；
- Model Connection registry、测试与 credential vault；
- Task/Run/Session 的 generation provenance；
- Product Control 对跨 aggregate admission 和 canonical snapshot 的 ownership。

只把完整 Account projection 从 `execution_state` 中移出，并把 Product 对 Account 的消费
收窄为 display projection、Metask authority 与 optional source candidate。

### 2.5 已知 Account kernel 缺陷不得随 hard cut 搬运

本次会重写缺陷所在的 `state.zig`、`runtime.zig` 与 `catalog.zig`，因此同时收口三项已知
问题：

- `PublicCatalog` 自己拥有并发布 `model_catalog_api_key_id`；`AccountView` 不再根据当前
  transaction phase 推导 catalog owner，committed/candidate slot 各自只有一个真相源；
- preference outcome unknown 只冻结新的 preference/default mutation，不冻结 token refresh、
  catalog refresh 或 logout；recovery 中的 catalog refresh 只能更新目录，必须抑制自动选择、
  preference repair 与 candidate transfer，不得保留当前 `recovery => operation == none` 的死状态；
- transaction 写入直接构造 tagged-union variant 或使用 variant-specific constructor，删除把
  `OperationKind + AttemptKind` 二元组重新拼回 union 的 `setTransaction` API。

这些是 Account 自身 correctness 与单一 owner 问题，不属于相邻重构，也不能因为旧测试将在
Phase G 删除而失去回归覆盖。

## 3. 目标 ownership

| 事实或行为                                       | 唯一 owner                       |
| ------------------------------------------------ | -------------------------------- |
| OAuth、refresh token、identity、login/logout     | Account                          |
| Metask API Key/model catalog                     | Account                          |
| `{account_id, api_key_id, model_id}` preference  | Account                          |
| Metask credential/source generation              | Account                          |
| Metask source candidate 构造                     | Account                          |
| 全局默认来源 `metask` / `model_connection`       | Product Control                  |
| active config、execution generation、replacement | Product Control                  |
| Schedule credential scrub/reset/retry            | Schedule + Product Control       |
| 新 Task admission 与 blocked reason              | Product Control                  |
| 已有 Task/Session/Run config 与生命周期          | Product Task / Agent             |
| Account、Execution、Schedule 的展示与交互状态    | Renderer 分别消费各自 projection |

Application coordinator 只负责编排主线程顺序与线性所有权转移，不持有领域状态，不决定
默认来源、admission、错误归属或 recovery policy。

Account terminal commit 与 Product 对应的 display/authority/candidate observation 必须在同一主线
turn 内进入一个 canonical Product revision。Renderer 不能观察到新 Account preference 已发布、
但 Product 仍假装没有观察过该 authority 的中间 snapshot。

## 4. Hard-cut 后的合同

### 4.1 Account projection

`AccountView` 保留：

- `state`、`catalogState`、`canCancel`；
- `accountId`、`displayName`；
- 脱敏 API Key/model catalog 与 metadata；
- committed/candidate API/model selection；
- `catalogGeneration`；
- Account-owned `errorCode` 与 `safeDiagnostic`。

每个 committed/candidate `PublicCatalog` slot 同时保存自己的
`model_catalog_api_key_id`。`replaceFromSession`、slot copy/promotion、restored selection 和
`clear` 必须原子维护该 owner；`decorate` 只发布 slot 自己的 owner，不读取 transaction phase
补算。

删除：

- `metaskExecutionGeneration`；
- active/default execution、replacement 或 Task admission 的任何派生字段。

Account 另外产生一个 secret-free committed authority fact，至少包含：

```text
account_id
api_key_id
model_id
protocol
source_generation
```

该 authority 只在 committed preference 完整且仍属于 committed catalog 时存在；catalog
加载中的 candidate view、错误码和 UI operation 不得隐式改变它。

### 4.2 Account command

保留：

- `begin_login`
- `cancel_operation`
- `refresh_catalog`
- `select_api_key`
- `select_model`
- `logout`

选择 payload 只携带 `selection_id + expected_catalog_generation`。

删除 Account-owned `activate_metask`。切换全局默认来源是 Product command；建议使用明确的
Product wire identifier，例如 `metawork.modelSources.selectMetaskDefault`。最终 identifier
必须在实现时由 `app.zon`、Bridge 合同和两端 command catalog 一次性锁定，不保留旧命令。

Product-owned “使用 Metask” command 可以触发一个非 Bridge 的 Account source-resolution
operation；该 operation 只按当前 committed preference 重新解析 candidate，不修改
preference，也不取得 Product state。

### 4.3 Account error

删除确属 Product/Task 的语义：

- `execution_in_use`
- `session_in_use`

同时 hard cut 三个命名或边界不准确的通用码，但不是删除失败通道：

- `execution_target_invalid` 改为 Account-owned `metask_platform_unsupported`，只表示 Metask
  API Key 的 platform 不受客户端支持；它与可重试的畸形响应
  `metask_protocol_invalid` 分离；
- 无独立生产语义的 `execution_config_invalid` 删除；外部 Metask 数据错误、unsupported
  platform 和内部 builder 不变量必须分别归类，不能继续共用 execution 兜底；
- `dependency_contract_invalid` 的旧名字和跨 owner 用法删除。Account mailbox collision、
  malformed/empty completion、无法进一步分类但可安全终止当前 attempt 的 Account-owned
  platform/effect 失败，统一进入新的 `account_operation_failed` terminal fallback；Product、
  Schedule 或 coordinator 不得生产这个码。

已知 credential store、OAuth、network、catalog 与资源错误继续使用精确 typed code；fallback
不能抢先吞掉可判定错误。assertion/panic 只用于 prepared transition、tagged union 或线性
ownership 本身结构非法，不用于 mailbox collision、时钟/随机源失败、平台 effect 失败或未知
credential backend 错误。所有旧 `dependency_contract_invalid` 生产点必须逐个审计后删除，
不能机械全量替换成新 fallback。

### 4.4 Account preference persistence

Account preference 保留 Account-owned source identity，但 hard cut 字段和语义。当前唯一
格式严格为：

```json
{
  "selection_owner_account_id": "account-1",
  "api_key_id": "key-1",
  "model_id": "model-1",
  "metask_source_generation": 1
}
```

`metask_source_generation` 是非零 opaque identity，只用于 Account source authority 相等比较：
API Key/credential authority 改变时生成新值，同一 source 下只修改 model 时保持不变。它
不是 Product execution generation，不进入 Renderer Account projection，也不能直接写入 Task
binding。

decoder 保持 unknown-field rejection；包含旧 `execution_generation` 的文件直接判为 invalid
并按 Account 冷启动规则清除，不迁移、不读取旧值、不写备份。

这是有意的格式 hard cut，而不是兼容性疏漏：所有当前 `preferences.json` 都会失效，用户在
下次认证目录恢复后需要重新选择 API Key/model。当前处于开发阶段，接受这项一次性代价，
以消除 persisted source identity 继续携带 Product execution 命名造成的双重语义；不得为避免
重选而保留旧 key、alias decoder 或迁移分支。

preference outcome unknown 只影响 Account 对 preference disk truth 的判定和后续 preference
mutation。Product 只消费 terminal committed authority fact，不能从 Account error 或磁盘诊断
猜测新的 desired binding。

### 4.5 Source candidate

在通用 execution contract 中增加不含 Product generation 的线性 owned candidate：

```text
source = metask
service_reference = metask:<api-key-id>
protocol
endpoint/base_url
model
source_generation
owned credential
Account authority token
```

Account 负责证明 candidate 与当前 identity/catalog/preference/source generation 一致；Product
接管后重新校验 authority token，独立分配或保留 Product execution generation，并拥有所有
secure-zero 路径。两种 generation 不能依赖数值相等。

Product sink 使用已经分配完成的 owned candidate和预留 projection capacity，必须完成 no-fail
ownership take。Schedule I/O、scrub 或 install preparation 的失败在接管后形成 Product fact，
不能使 sink 返回 Account error。

## 5. 关键事务

### 5.1 首次登录或 API Key 改变

```text
Account load/validate catalog
-> construct candidate
-> commit four-field source preference
-> commit Account fact and authority
-> Product consumes candidate
-> Product assigns a new execution generation
-> Schedule scrub
-> install, or retain one exact pending candidate and publish Product failure
```

Product failure后 Account 仍为 authenticated/catalog ready/preference committed。若当前全局
默认确实是 Metask，desired/active mismatch 必须关闭新 Task admission；已有 Task 不受影响。

Schedule 中既有 credential 文本的 durable residue 始终由 Schedule + Product Control
负责。scrub 失败时 Product 不安装新 candidate，并继续有界持有新 candidate；存在待替换的
旧 active Metask config 时，Product 也必须保留其 credential owner，直到 old/new credential
所需 scrub/clear 已明确提交。Account 不接收该失败，也不恢复旧 preference。

pending candidate 不持久化。若进程在 mismatch 期间退出，冷启动在 Account 完成
token/identity/catalog/preference 恢复后重新解析 committed preference，产生新的 exact
candidate；Product 重新执行 Schedule scrub。Schedule store 仍不可信时继续发布
`schedule_persistence_unavailable` 并禁止相关新 Task，用户 hard reset canonical store 后再由
Product 安装。不得通过自动重放原 Account mutation、回滚 preference 或跳过 scrub 收口。

### 5.2 同一 API Key 修改模型

Account 提交新的 model preference，保持 Account source generation，并可输出同 source
candidate。Product 比较精确 source identity/credential authority：

- source generation 未变且 authority 可证明：保留 Product execution generation，只更新未来
  Task 的默认 model；
- source generation 改变或无法证明：按 credential replacement 生成新 Product execution
  generation；
- Product 更新失败：保留旧 active config，但关闭依赖新 desired binding 的 admission，并发布
  Product error。

Account 不判断当前默认来源；若全局默认是 Model Connection，Product 丢弃 Metask candidate，
Account preference 仍正常提交。

### 5.3 Catalog refresh

committed preference 仍属于新 catalog 时，只替换 Account catalog/authority projection，不触发
默认 execution replacement。transient loading/error 不得仅因 UI `catalogState` 变化撤销已经
提交的 Metask authority。

preference 失效时 Account 清除或重新选择自己的 preference；Product 收到 terminal authority
变化后独立处理 active/default binding。

### 5.4 显式切换回 Metask

Product 先建立一次 source-selection operation，再请求 Account 按 committed preference 解析
candidate。Account resolution 失败属于 Account 的 Metask/auth/catalog事实；Product 同时发布
自己的 source unavailable，不把 Product error写回 Account。

只有 candidate、Schedule scrub 和 durable custom-default clear 全部成功后，Product 才切换
全局默认来源。失败继续保留当前 Model Connection default。

### 5.5 Logout

Account 先按自身合同删除 refresh token、preference 并提交 `signed_out`。Product 随后观察
authority 消失：

- 立即拒绝新的 Metask admission；
- secure-zero pending candidate；
- 对 Product-owned active Metask config 执行自己的 scrub/clear；
- scrub 失败时由 Product 安全持有待释放 credential 并发布 Product recovery，不回滚 logout。

已有 Task 持有自己的 config，继续按 Task 生命周期收口。

### 5.6 Schedule store 不可用与 hard reset

Schedule store 不可信时 Product 不安装 candidate，并持有至多一个 exact pending candidate。
Renderer 必须始终能够访问 Schedule reset，不得被 Account onboarding/settings redirect 遮挡。

reset 只针对已解析的 canonical Scheduled Task store：用当前格式的 Product-owned empty/current
candidate 原子替换旧文件，不迁移、不 quarantine、不保留旧格式副本。reset committed 后，
Product 在同一进程重新校验 pending authority 并继续 scrub/install；失败保持 typed Product
状态，不重放 Account command。

## 6. 代码实施顺序

### Phase A：先锁定真源与纯合同

1. 更新 Account、Product、Renderer Bridge、产品需求和 UI 真源，明确区分 Account source
   generation 与 Product execution generation。
2. 在 execution 纯合同中加入不含 Product execution generation 的 source candidate。
3. hard cut Account view、command、error 和 preference wire。
4. 同步 Zig/TypeScript DTO、decoder、fixture 与 command allowlist，不加 optional fallback。

### Phase B：收敛 Account kernel

主要文件：

- `src/product/account/contract.zig`
- `src/product/account/state.zig`
- `src/product/account/runtime.zig`
- `src/product/account/catalog.zig`
- `src/product/account/credential_store.zig`

动作：

1. 将 committed/pending `execution_generation` hard cut 为 Account-owned
   `metask_source_generation`，并从 Renderer projection/command 中移除。
2. 删除 `ExecutionIntent`、`ReplacementIntent` 和 Product execution persistence recovery 分支；
   将 Account source preference outcome-unknown 改为 capability-specific recovery：只禁止新的
   preference/default mutation，允许 token refresh、catalog refresh 与 logout；recovery 中的
   catalog refresh 不得自动选择、写 preference 或产生 candidate。
3. 保留 CatalogIntent 与四字段 source PreferenceIntent。
4. 将 prepared output 收敛为 Account fact、catalog/preference intent、effect 和 optional source
   candidate。
5. 在 Account commit 前完成本地 candidate 构造；所有拒绝路径 secure-zero。
6. 让 committed/candidate `PublicCatalog` slot 各自拥有
   `model_catalog_api_key_id`，slot copy/promotion/clear/decorate 不再从 transaction state 推导。
7. 删除二元组式 `setTransaction`，只允许直接构造 tagged-union variant 或调用
   variant-specific constructor；`OperationKind`/`AttemptKind` 只作为只读 projection。
8. 逐个重新归类 `dependency_contract_invalid` 生产点：精确 typed error 优先，其余
   Account-owned 可终止失败进入 `account_operation_failed`，Product/coordinator 路径直接删除。
9. 重写 Account inline tests，只验证 Account 自身事务、catalog slot owner、recovery 能力门与
   source candidate ownership。

### Phase C：切断 Coordinator 反向控制

主要文件：

- `src/app/account_coordinator.zig`
- `src/product/control/ports.zig`
- `src/app.zig`

动作：

1. 删除 `AccountExecutionHandoff` 及 begin/prepare/finalize/abort replacement callbacks。
2. 提供窄的 no-fail Account commit sink：一次接收 secret-free fact 与 optional owned
   candidate，并负责唯一 Product revision。
3. Coordinator 固定先 Account commit，再线性转移 candidate；转移后没有 fallible callback。
4. Product install/pending/discard 结果不进入 Account state machine。
5. 删除 recursive `prepareActiveAttemptFailure(.dependency_contract_invalid)` 路径。

### Phase D：Product 独立 reconciliation

主要文件：

- `src/product/control/execution_state.zig`
- `src/product/control/runtime.zig`
- Schedule persistence/recovery implementation

动作：

1. 将完整 Account projection 从 `execution_state` 移至 Product snapshot composition。
2. Execution state 只保存 active config、Product execution generation、default binding、Metask
   source binding 和
   optional pending candidate。
3. Product Control 组合 Account authority、active binding 与 Task binding完成 admission/model
   selection/recovery校验。
4. Schedule failure只更新 Execution/Schedule projection。
5. Schedule hard reset committed 后自动消费 exact pending candidate。
6. candidate replacement、custom-default selection、logout 和 shutdown 全路径 secure-zero。

### Phase E：Bridge 与 Renderer

主要范围：

- `app.zon`
- `src/bridge/`
- `frontend/src/bridge/`
- `frontend/src/app/App.tsx`
- Account/settings/scheduled-task presentation tests

动作：

1. 删除 Account execution generation wire 和旧 activation command。
2. 新增 Product-owned Metask default-source command。
3. Task/Schedule 自己的 `expectedExecutionGeneration` 保持不变。
4. 拆分 Account mutation busy 与 Model Connection/Product source busy。
5. Account surface policy 不遮挡 Product recovery；Execution error必须由 Product surface呈现。
6. existing Task model policy 使用 Product active generation + Account catalog authority，不读取
   已删除字段。

### Phase F：删除 Account 私有实现的外部消费者

`src/app/mcp_oauth.zig` 和 loopback transport 不再导入 Account 私有 OAuth/loopback policy。
只抽取确有两个消费者的中性 PKCE/secret/byte-pump mechanics，以及严格 callback query
解析、duplicate/unknown parameter rejection 和 constant-time state compare 等信任边界 leaf；
Metask 与 MCP 各自拥有 callback path、redirect URL、issuer/resource acceptance、limit value 和
error mapping。共享 loopback mechanics 可以接受调用方提供的 invalid-request budget，但不拥有
任一业务的 budget policy。architecture guard 明确禁止 MCP 导入 Account 私有 leaf。

### Phase G：删除旧路径

删除所有仅服务旧设计的：

- 使用旧 `execution_generation` 语义/字段的 preference codec/fixture；
- Account execution/replacement intent 与测试；
- Product failure -> Account error mapping；
- `metawork.account.activateMetask` allowlist、handler、client 和文案；
- `execution_in_use`、`session_in_use`、`dependency_contract_invalid`、
  `execution_target_invalid` 等旧 Account wire分支；
- Schedule quarantine/旧格式保留文案和测试；
- 证明旧耦合行为的 coordinator/lifecycle fixtures。

不得保留 deprecated alias、双命令、双字段 decoder 或临时兼容 facade。

## 7. 验收不变量

### 7.1 Owner 与状态

- Account command 只因 Account-owned validation/effect/persistence 失败。
- Product/Schedule failure 永不改变 Account identity、catalog、preference 或 Account error。
- committed/candidate catalog slot 的 `model_catalog_api_key_id` 只由该 `PublicCatalog` slot
  拥有；任何 park/reload/failure projection 都不得从 transaction phase 补算 owner。
- preference outcome unknown 只阻止新的 preference/default mutation；token refresh、catalog
  refresh 与 logout 均可开始并 terminal 收口，refresh timer 不得永久 rearm 同一拒绝；catalog
  refresh 在 recovery 中不自动选择、不写 preference、不产生 candidate。
- committed credential/source authority 的 account、API Key、credential、protocol 或 endpoint
  变化都提升 `metask_source_generation`；model-only preference 可以保持它。任何使 selection
  input 失效的 account/catalog owner/catalog contents 变化都提升 `catalog_generation`，Product
  candidate 不依赖两个 generation 数值相等。
- transaction variant 不能由可自由组合的 `OperationKind + AttemptKind` 写入；两者只能从
  tagged transaction 派生。
- Account terminal commit 后 candidate ownership 必须恰好一次转移或清零；Product sink 不返回
  fallible rejection。
- Account busy 不禁用 Model Connection；Model Connection busy 不伪造 Account operation。
- custom default active 时，Account refresh/selection/logout 不热替换或暂停它。
- existing Task/Session/Run 不因 Account mutation、logout 或 Product pending candidate 停止。

### 7.2 原始故障纵向

给定旧/损坏 Schedule store、无 Task、有效 refresh token和有效 Account preference：

1. Account 恢复为 authenticated；
2. catalog 与 preference 对用户可见且无 Account error；
3. Product 发布 `schedule_persistence_unavailable` 和 recovery action；
4. UI 不自动跳转并遮挡 recovery；
5. reset 删除旧 canonical，写入当前空 store；
6. Product 同进程安装仍匹配的 pending candidate；
7. Task admission 恢复 ready，无需重登、Account refresh 或进程重启。

### 7.3 Persistence hard cut

- 四字段 `metask_source_generation` preference round-trip；
- unknown field、旧 `execution_generation`、零 source generation、缺字段和非法 UTF-8全部拒绝；
- 所有含旧 `execution_generation` 的当前 preference 被有意清除，用户重新选择；不产生
  backup/migration/alias decode；
- Schedule reset不产生 quarantine artifact；
- outcome unknown 不自动重放原 mutation。

### 7.4 Secret lifetime

- source candidate 不进入 AccountView、Snapshot、Bridge、日志、history 或 checkpoint；
- Account reject、preference failure、Product stale/reject、custom default、logout、reset failure、
  replacement 和 shutdown 均有唯一 secure-zero owner；
- Product 最多持有一个 pending Metask candidate；
- pending candidate 的 authority token 每次 retry 前重新校验。

### 7.5 Structural guard

- Account 不导入 Product Control Runtime、Task、Schedule、Bridge 或 Application；
- Account public error/intent 不含 Product/Task术语；
- `execution_state` 不保存完整 AccountView；
- MCP 不导入 Account OAuth/loopback 私有实现；
- Bridge 两端和 `app.zon` command catalog 精确一致。

## 8. 验证矩阵

按最小充分层逐步执行：

1. Account Zig inline tests：state、runtime、catalog、preference codec、secret ownership；至少覆盖
   candidate model-load failure park 后再次 reload/fail 仍能生成合法 view，以及 preference
   outcome unknown 后 token refresh、catalog refresh、logout 各自可 terminal 收口；recovery
   catalog refresh 断言 preference writer 未调用且无 candidate。
2. Product Control Zig tests：generation、binding、pending candidate、custom default、logout、
   Schedule failure/reset/retry。
3. Application coordinator tests：commit 顺序、无反向错误、candidate linear transfer。
4. Bridge Zig + TypeScript contract fixture：字段删除、命令 hard cut、strict decode。
5. Renderer typecheck 与 Account/settings/Schedule/bridge client Node suites。
6. architecture boundaries guard：import、owner、allowlist 和旧 symbol absence。
7. Product lifecycle：原始冷启动故障、同进程 reset、existing Task Run during Account mutation。
8. 正式 Native test graph 与 `npm test`；若命中已登记的 Windows file recovery crash，单独报告
   已通过的相关精确用例和既有平台缺口，不把 crash 伪报为本变更成功。
9. `git diff --check`、格式检查和旧 symbol 全仓扫描。

## 9. 实施风险与控制

| 风险                                                           | 控制                                                                                                                                                        |
| -------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Account commit 后 Product 安装失败形成 desired/active mismatch | Product 显式保存 desired Metask authority，关闭相关新 Task admission并发布 typed reason；不回滚 Account                                                     |
| pending candidate 变 stale                                     | 绑定 `account + API + model + source generation`；每次 retry 校验；任一 authority 变化立即清零                                                              |
| catalog refresh误清 pending candidate                          | candidate 不绑定 UI catalog generation；只按 committed source authority 判断                                                                                |
| model-only change错误提升 generation                           | Account source generation保持不变；Product generation 只按 source/credential authority提升                                                                  |
| logout 时 Product scrub失败                                    | Account logout照常完成；Product 保留有界待释放 credential、拒绝新 admission并提供恢复                                                                       |
| preference outcome unknown污染 Product                         | Product 只消费 terminal committed authority，不读取 Account diagnostic猜测 desired state                                                                    |
| UI 又把 Account当全局 gate                                     | Account、source/admission、Schedule recovery使用独立 projection和 busy scope；加入无 Task 回归                                                              |
| 抽取 OAuth helper 形成新通用 facade                            | 共享 leaf 只包含 PKCE/secret/byte pump 与严格 callback/state trust-boundary mechanics；path、issuer/resource、limit value 和 error policy 仍分属 Metask/MCP |

## 10. 明确非目标

- 不重命名或重写全部 Execution/Task/Session 类型；
- 不修改 Task-owned `ExecutionConfig` 和历史 generation provenance；
- 不改变 Model Connection registry 的持久化格式或 credential vault；
- 不给旧 Renderer、旧 preference 或旧 Schedule 格式提供迁移；
- 不建立通用事务框架、event bus、provider facade 或兼容 adapter；
- 不处理与本故障无关的 Task history recovery策略。

## 11. 完成条件

只有同时满足以下条件，Account 语义收敛才算完成：

- Account 合同、状态机、持久化和错误中不存在 Product execution/replacement语义；
- Product/Schedule failure不能沿任何路径写回 Account；
- 原始 Schedule 故障可以在 Account ready 状态下从 UI reset，并在同进程恢复 Task admission；
- 旧字段、旧 command、旧错误、旧 intent和兼容路径已从代码、测试、fixture、allowlist与文案删除；
- 相关真源已更新，验证矩阵通过或精确登记既有平台阻塞；
- 工作树中不存在未解释的新增 owner、双重真相或 secret lifetime缺口。

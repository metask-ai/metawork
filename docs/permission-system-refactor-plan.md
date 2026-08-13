# MetaWork 会话权限系统重构方案

> 状态：设计方案（待实现）
> 范围：Agent Session、Workbench 权限投影、Renderer Bridge、AgentCore permission ABI
> 目标：完整利用 AgentCore 已开放的 Session permission 能力，消除同一会话内的重复授权，同时避免在 ABI 之外自行发明持久策略和撤销语义。

## 1. 设计结论

本次重构采用最小可实施的垂直切片：

1. Agent 继续拥有 AgentCore Runtime、Session、callback 和 ABI response 编码。
2. AgentCore 拥有 Session grant 的匹配、执行和 provenance。
3. Workbench 只拥有产品侧的权限 occurrence、用户选择、审计摘要和 UI 状态。
4. Bridge 只负责 Renderer transport、command ingress 和产品级身份校验。
5. Renderer 根据当前请求的 `responses[]` 渲染按钮，不固定展示四种选择。
6. 当前不实现 Host 持久 permission rules、即时撤销或自定义规则 compiler。

不新增独立的“大权限控制平面”，也不在 Workbench 镜像一份 AgentCore Session grant 状态。

## 2. 依据与边界

实施以以下 canonical source of truth 和实际 bundle 为准：

- [AgentCore ABI v1](agentcore-abi-v1.md)
- [AgentCore integration](agentcore-integration.md)
- [Workbench product architecture](product-architecture.md)
- [Renderer Bridge contract](renderer-bridge-contract.md)
- [Product requirements](requirements.md)
- canonical `.agentcore/bundle/bindings/zig/src/protocol.zig`、`types.zig` 和 `include/metask/agentcore.h`

当前 revision 8 的事实包括：

- Permission request 携带 request/session/run/tool identity、canonical arguments digest、`policy_generation`、`responses[]` 和可选 candidate。
- candidate scope 当前只有 `exact_arguments`。
- response 必须属于 request 的 `responses[]`；Session choice 必须带与 candidate 完全一致的 `rule_id`。
- provenance 的 `policy_generation` 是必有字段，`source` 是 AgentCore 的 `PermissionDecisionSource`。
- RestoreReport 提供 permission `restored_rules` 和 `invalidated_rules` 统计。
- `SessionHostConfigV1` 没有 Host 可设置的 policy generation 字段。

MetaWork 不复制 ABI 类型、schema、parser、compiler 或 AgentCore 内部 rule state。

## 3. Owner 模型

```text
AgentCore callback
        ↓
Agent Session
  - SDK decode
  - UTF-8 / identity 校验
  - pending request 生命周期
  - response 编码与提交
        ↓ typed product observation
Workbench
  - 产品 occurrence
  - 用户选择
  - 审计摘要
        ↓ transport command/event
Renderer Bridge
        ↓
Renderer
```

### 3.1 Agent

Agent 是 AgentCore 协议 owner，负责：

- 在 callback 内完成 SDK typed decode、UTF-8、布局、Session/Run identity 校验和深拷贝；
- 持有 canonical pending `UiRequest` 及其生命周期；
- 暴露 choice-only 的 `respondPermission(run_id, request_id, choice)`；
- 从 pending request 回填 request ID、`policy_generation` 和 candidate `rule_id`；
- 通过 SDK encoder 校验并提交 `UiResponse`；
- 消费并转发 `permission_provenance` 和 RestoreReport。

Agent 不调用 WebView，也不直接拥有 Renderer 产品状态。

### 3.2 Workbench

Workbench 负责：

- 把 Agent 的 typed permission observation 转成产品 occurrence；
- 根据 `responses[]` 和 candidate 是否存在计算 `available_choices`；
- 校验 Task/Run/Session 产品身份和 occurrence 生命周期；
- 记录用户选择和脱敏 provenance 摘要；
- 处理过期、取消、Session close 和恢复健康状态。

Workbench 不保存 AgentCore grant 的镜像，不生成 `rule_id`、`policy_generation` 或任意 ABI response JSON。

### 3.3 Renderer Bridge

Bridge 只负责：

- 接收 Renderer 的白名单化 permission choice command；
- 校验 origin、command、Task/Run/Session 路由身份；
- 将 choice 交给真实 Workbench/Agent 路径；
- 将 Workbench projection 推送给 Renderer。

Bridge 不解码 AgentCore callback，不持有 SDK handle，也不直接调用 AgentCore Session。

## 4. 最小状态模型

Agent Session 持有唯一的 canonical pending request：

```text
request_id
session_id
run_id
tool identity
canonical arguments digest
policy_generation
responses[]
candidate?
```

Workbench 只保存面向产品的 occurrence projection：

```text
task_id
run_id
request_id
tool display name
arguments display summary
available_choices
status: pending | answered | expired | invalidated
user_choice?
callback_outcome?
```

权限投影不包含 Host 侧的 generation pin：`policy_generation` 是 AgentCore 在 request/description 中产生的事实，Workbench 只能记录实际收到的值，不能在 Session 创建时绑定一个 Host 不可设置的 generation。

## 5. Permission UI 语义

| UI 选择 | AgentCore response | 作用域 | UI 文案含义 |
| --- | --- | --- | --- |
| 允许一次 | `allow_once` | 当前 request | 只允许这次调用 |
| 本会话允许 | `allow_session` | 当前 Session + candidate | 本会话内允许相同参数的调用 |
| 拒绝一次 | `deny_once` | 当前 request | 只拒绝这次调用 |
| 本会话拒绝 | `deny_session` | 当前 Session + candidate | 本会话内拒绝相同参数的调用 |

`allow_session` / `deny_session` 只有在 request 带 candidate 且 `responses[]` 包含对应 choice 时可用。revision 8 的 candidate scope 恒为 `exact_arguments`；未知 scope 按 SDK 规则 fail closed。

Renderer 不接收或提交：

- candidate `rule_id`；
- `policy_generation`；
- 原始 AgentCore response JSON；
- 可扩大权限范围的规则字符串。

这些字段由 Agent 从 canonical pending request 中回填，避免 Renderer 伪造 Session 授权。

## 6. 请求与响应流程

1. AgentCore 在同步 callback 中发出 `UiRequest(permission)`。
2. Agent Session 使用官方 SDK 解码，完成 UTF-8、布局、Session/Run identity 校验，并深拷贝需要跨 callback 保存的内容。
3. Agent 将 typed request 交给 Workbench，Workbench 创建一个产品 permission occurrence。
4. Workbench 根据 `responses[]` 和 candidate 是否存在生成 `available_choices`，只把脱敏 projection 发给 Renderer。
5. Renderer 返回一个白名单 choice 字符串。
6. Bridge 校验 origin、command 和产品路由身份后进入 Workbench。
7. Workbench 校验 occurrence 仍 pending、Task/Run/Session 仍匹配，并调用 Agent 的 choice-only response 入口。
8. Agent 从 pending request 回填 request ID、`policy_generation` 和 candidate rule ID，并调用 SDK encoder。
9. SDK 校验 choice 属于 `responses[]`、generation 匹配、Session choice 的 rule ID 匹配后，AgentCore 接收 response。
10. 后续工具决策产生 `permission_provenance`，Agent 解码并交给 Workbench 形成 live projection 和审计摘要。

### 6.1 错误处理

- choice 不在 `responses[]`：fail closed，Renderer 不应产生该按钮，Agent/SDK 仍做最终拒绝。
- Session choice 缺少 candidate 或 rule ID 不匹配：拒绝 response。
- generation 不匹配、request identity 不匹配、错误 Session/Run：拒绝并按 AgentCore 合同处理，必要时 poison Session。
- Renderer 重复提交：第一次有效 response 线性化，后续返回 stale/duplicate，不二次执行。
- deadline、cancel、close、shutdown：唤醒同步 UI wait，不能静默丢弃 control event。
- malformed/unknown ABI observation：由 Agent 按 canonical 合同 fail closed，不由 Bridge 或 Renderer 猜测。

## 7. Session grant 与重复授权

MetaWork 不维护“已允许工具”缓存。用户选择 `allow_session` / `deny_session` 后，Agent 将 choice 和 candidate 交给 AgentCore，由 AgentCore 保存和匹配 Session grant。

成功标准是：

- 同一 AgentCore Session；
- 同一 candidate（revision 8 即相同 exact arguments 范围）；
- 后续调用由 AgentCore 直接决策；
- 不再发起重复 UI request。

Session 关闭后，Workbench 不向新 Session 注入旧 grant。是否在 restore 后保留内部规则由 AgentCore checkpoint/restore 合同决定，Workbench 不自行推断。

## 8. Permission mode

沿用 `SessionHostConfigV1.permission_mode_code`，不创建新的 Workbench mode 状态：

- 当前正式使用 `default`；
- `accept_edits`、`auto` 只有在 AgentCore 提供确切行为语义/安全边界，并完成对应 capability gate 和安全验收后接入；
- `dont_ask`、`full_access` 当前保持隐藏。

当前 bundle 只声明五个 `permission_mode_code` 常量，没有定义各 mode 的自动放行范围、工具适用性、与 `shell_policy`/Workspace 边界的关系或 provenance 语义。因此高级 mode 的阻塞点不仅是产品安全 gate，也包括 AgentCore 的正式语义合同。

mode 变化不通过 Renderer 直接修改活动 Session；如 AgentCore 没有明确的安全更新入口，则使用新 Session。

## 9. Provenance 与审计

分离两类语义，但复用现有 Workbench occurrence/history 路径，不新增独立审计服务。

### User decision

记录：

- Task/Run/Session/request identity；
- 用户选择和时间；
- candidate 脱敏摘要；
- response callback outcome。

### AgentCore provenance

记录 AgentCore 返回的 typed fields：

- decision；
- `source`（仅使用 AgentCore `PermissionDecisionSource`）；
- `matched_rule_id`；
- `policy_generation`；
- `used_session_rule`；
- callback outcome。

Host 侧若要记录来源，使用 `policy_origin`，不得与 AgentCore `source` 同名。

持久边界保持有界：live projection 可保留完整 typed provenance；Workbench 将 provenance 摘要挂到既有 permission occurrence，再由既有有界 Task history 保存；snapshot 只发布该脱敏摘要和 RestoreReport 统计，不保存 credential、完整原始参数或可重放 response。RestoreReport 只作为当前运行的健康投影，不写入 checkpoint，也不作为下一次 grant 的输入。

## 10. Restore 与恢复边界

MetaWork 不对 opaque checkpoint 的权限内容做反向断言。

恢复时：

1. Agent 调用 canonical restore adapter；
2. Agent 校验 RestoreReport、SessionDescription 和持久 expectation；
3. Workbench 消费 `permission.restored_rules` 与 `permission.invalidated_rules`；
4. 恢复结果进入已有 checkpoint/Session health projection；
5. 不重放旧 permission response；
6. 不重放未完成或结果不确定的工具调用；
7. identity、authority 或 report 不一致时，沿现有 detached/recovery-required 路径 fail closed。

“AgentCore 是否恢复了 Session grant”和“MetaWork 是否重放了授权操作”是两个独立问题，不能混写成一个结论。

## 11. 撤销与持久权限的延后范围

当前不实现 live permission rule revoke。可靠硬撤销仍是：

```text
停止新请求 admission
→ 停止或取消 Run
→ 关闭 Agent Session
→ 丢弃旧 attachment
→ 按需创建新 Session
```

Host 持久 permission rules 也暂不实现，因为当前 bundle 没有可供 MetaWork 使用的正式 rule compiler/schema。`permission_rules` 保持现有产品配置，不生成 `Tool(specifier)` 字符串。

只有在 AgentCore 明确提供以下能力后，才开启后续阶段：

- typed rule schema/compiler；
- rule replacement 的并发和撤销保证；
- generation 的 Host/AgentCore 关联合同；
- restore 后 rule validity 的明确语义。

## 12. 分阶段实施

### Phase 1：协议与 owner 对齐

- Agent 保持 UiRequest decode、identity 校验和 response encode；
- Bridge 支持四种 choice；
- Workbench projection 增加 `available_choices`；
- 删除 `allow_always` / `deny_tool_session` 的产品命名；
- 增加 `responses[]`、candidate 缺失、错误 choice 和重复 response 测试。

### Phase 2：Session grant 垂直切片

- 接通 `allow_session` / `deny_session`；
- 验证同一 Session、同一 exact candidate 的后续调用不再重复询问；
- 验证新 Session 不使用 Workbench 本地 grant 缓存。

### Phase 3：Provenance 与 Restore

- 接入 typed provenance；
- 对账 RestoreReport 的 restored/invalidated permission 统计；
- 建立 live projection 与 durable history 的有界字段集合。摘要挂在既有 permission occurrence 上，不新增独立 history 记录；Task history 的最小权限摘要至少包含 `task_id`（由所属 Task identity 提供）、`run_id`、`request_id`、tool identity、`decision`、`source`、`policy_generation`、`used_session_rule` 和 `callback_outcome`；
- 覆盖 Session close、restore mismatch 和 callback failure。

### Phase 4：未来能力门槛

- Host 持久 permission rules；
- canonical rule compiler；
- 即时撤销；
- 高权限 permission mode；
- 跨 Session 的产品权限策略。

## 13. 验收标准

### 体验

- 同一 Session、同一 exact candidate 的后续调用不再重复询问；
- UI 只显示当前 request `responses[]` 中的 choice；
- Session choice 的文案明确表达“相同参数”，不扩大为“整个工具”。

### 正确性

- 四种 choice 在 ABI 允许时能完成 typed 往返；不可用 choice 不会出现在 UI；
- Agent 自动回填 request identity、generation 和 rule ID；Renderer 无法伪造这些字段；
- 重复 response、stale response、candidate mismatch、generation mismatch 均 fail closed；
- provenance 的 decision/source/generation/used_session_rule 可与 occurrence 关联。

### 恢复

- RestoreReport 的 restored/invalidated permission 统计可被 Workbench 消费并对账；
- 不重放旧 permission response、未完成工具调用或不确定 mutation；
- restore identity/authority/report 不一致时进入既有恢复失败路径。

### 安全

- credential 不进入 Renderer、Bridge payload、snapshot、history 或日志；
- MetaWork 不解析或生成 AgentCore 规则字符串；
- 未通过 capability gate 的 mode、持久规则和即时撤销不可调用。

## 14. 待 AgentCore 明确的后续 ABI 条件

以下不是当前 Session permission 垂直切片的阻塞项，而是未来持久策略或高级 mode 阶段的前置条件：

1. Host rule 的正式 typed schema/compiler；
2. `session_update_permission_rules` 是否撤销既有 grant 的保证；
3. Host policy 与 AgentCore policy generation 的关联方式；
4. restore 后 permission rule 的有效性和失效条件；
5. 规则替换、Session close 与并发 tool call 的线性化语义。
6. 五个 `permission_mode_code` 的确切语义、自动放行范围、适用工具和安全边界，以及对应 provenance 语义。

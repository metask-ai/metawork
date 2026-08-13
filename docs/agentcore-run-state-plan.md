# AgentCore 执行状态最小收敛方案

> 状态：已实施（`0ed6bce`、`51e0fcc`）；§2 为实施前基线快照。

## 1. 目标与边界

以 Windows x86_64 GNU AgentCore ABI v1 revision 8 hard cut 为唯一基线，先确认 `CoreEvent.run_state` 是否能被 MetaWork 安全、稳定地观察，再决定是否扩展产品状态展示。

本阶段只处理：

- AgentCore `run_state` 的真实事件证据；
- Host Run identity 与 AgentCore `run_id` 的关联；
- `transition_seq` 首值和递增语义；
- Workbench 中会覆盖或终止 Run 的最小错误路径；
- runtime-only 的观测字段。

本阶段不处理：

- Renderer 或 Bridge 合同扩展；
- `run_state` 持久化；
- 工具级状态 UI；
- 完整 status 优先级体系；
- 自定义 Host tools、plan approval、custom UI、Output 或 FileChange；
- macOS AgentCore 交付面；
- AgentCore Worker、进程隔离或 crash recovery。

产品 `RunPhase`、Run result、abort、poison 和生命周期仍由 Host/Workbench 独占。`run_state` 不是 terminal authority。

## 2. 当前已知事实

- `applyEvent` 当前会把 AgentCore phase 写入 `run.active_phase`；
- `syncLifecycle()` 会根据 Host 自己的 cancel、pending UI 和 handoff 事实重算 `active_phase`；
- `writeSnapshot()` 会先调用 `syncLifecycle()`，因此 AgentCore phase 不能成为稳定的产品 `RunPhase`；
- `agent_transition_seq` 当前以 `0` 表示未观测，可能丢弃 AgentCore 从 0 开始的首个事件；
- 当前 `run_state` 观测错误可能走 projection failure 和 `consumer_rejected`，其终止 Run 的影响范围过大；
- 真实 bundle 中 `run_state.run_id` 与 Host Run identity 是否属于同一命名空间尚未有证据。

## 3. 最小实施切片

### 步骤一：隔离 probe，先取证

新增 Windows staged bundle 专用 probe。probe 不复用会终止产品 Run 的 Workbench projection failure 路径，只记录原始 typed observation 和最终 outcome。

每次 Run 至少记录：

- Host Run identity；
- `run_state.run_id`；
- 首个 `transition_seq`；
- 完整的后续 sequence；
- phase、turn、tool call 总数和 in-flight 数；
- 最终 Run outcome。

probe 必须回答：

1. `run_state.run_id` 是否与 Host Run identity 可直接关联；
2. 首个序号是 `0`、`1` 还是其他值；
3. 后续序号是否严格递增；
4. 是否出现重复、倒退或跨 Run 事件；
5. revision 8 bundle 是否稳定发送 `run_state`。

如果没有稳定事件，或 identity 无法关联，结论为 `unsupported`，停止后续产品扩展。

### 步骤二：做三项最小生产修正

只有步骤一取得证据后，才修改正式路径：

1. 删除 AgentCore phase 对 `run.active_phase` 的写入。AgentCore phase 只更新 runtime-only observation 字段和受控 status 文案，不参与 Host `RunPhase` 计算。
2. 将 last transition 由“初值为 0”改为 nullable 或等价的 `has_observation` 状态；首个合法序号无论是 0 还是 1 都必须被接受，之后才要求严格递增。
3. 将 typed `run_state` observation failure 与产品事实消费失败分开：跨 Run、非法字段和超限数组只丢弃该 observation，并设置一个 bounded runtime-only degraded 标记；不得调用 `requestRunTermination(.consumer_rejected)` 终止用户 Run。无法安全识别为 typed `run_state` 的 malformed wire/UTF-8 事件、`run_id == 0` 或 callback 文本校验失败仍按 event-pump 既有 invalid-event 合同 fail closed，因为不能凭原始字节安全确认事件类型。`consumer_rejected` 继续用于 tool result、usage、terminal 等产品事实无法安全消费的情况。

步骤二不新增 persistence 字段，不改变产品 `RunPhase`，不扩展 Renderer 合同。

步骤二完成后必须同步更新 [AgentCore ABI v1 消费合同](agentcore-abi-v1.md)：修正 `run_state` 的投影边界，明确它只更新 runtime-only observation/status，不进入产品 `RunPhase`，并记录 observation failure 的 drop + degraded 语义。

### 步骤三：补最小回归测试

只覆盖会影响本切片正确性的测试：

- 首个 `transition_seq` 为 0；
- 首个 `transition_seq` 为 1；
- 正常递增；
- 重复和倒退 transition 被忽略；
- 跨 Run observation 被 drop + degraded，Run 不被终止；
- callback 边界的 malformed wire/UTF-8 event 按 event-pump 既有 invalid-event 合同 fail closed；它不属于 projection drop 范围，本切片不重复测试；
- typed observation 的 in-flight 数量越界当前没有可构造的超大数组输入，本切片不单独覆盖；正式 projection 语义仍保持 drop + degraded；
- AgentCore phase 不覆盖 Host-owned `RunPhase`；
- `applyEvent` 不再写入 `run.active_phase`；
- terminal result 仍覆盖任何 live observation；

不在本切片加入完整 terminal race 矩阵、工具名称 UI、Bridge fixture 或 i18n catalog 变更。

### 步骤四：最小验收

```text
node scripts/verify-staged-agentcore-bundle.mjs
node scripts/run-agentcore-probe.mjs --staged
node scripts/run-agentcore-run-state-probe.mjs --staged  # 新增 probe
npm run check
npm test
git diff --check
```

验收结论：

- `supported`：identity、首序号、递增规则和最小投影语义均有真实证据；
- `unsupported`：事件不存在或 identity 无法关联，停止后续 UI/Bridge 设计；
- `blocked`：AgentCore 事件可见但语义不完整，只保留内部 observation，不扩展产品展示。

步骤四完成后必须同步更新 [验证规范](validation.md)：记录 `run-agentcore-run-state-probe.mjs` 的正式证据入口、实际 identity/序号结果，以及 `supported`、`unsupported` 或 `blocked` 的能力结论。

## 4. 后续扩展门槛

只有最小切片达到 `supported` 后，才单独评估：

- status 文案归并；
- stable phase/message identifier；
- Renderer i18n 投影；
- Bridge 合同变更；
- 更完整的 terminal race、cancel、permission、shutdown 回归矩阵。

这些不是当前切片的隐含工作，也不应在 AgentCore 真实能力未证实前提前实现。

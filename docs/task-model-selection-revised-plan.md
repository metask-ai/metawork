# Task 模型选择与登录后可用流程：收敛方案

> 状态：按评审意见重新收敛，已在 `feat/task-model-selection` 实现并完成验证
>
> 本文同时作为产品/架构方案与本次实现的验收基线；评审意见用于暴露风险，最终设计结论以本文和实际验证证据为准。

## 1. 目标

解决两条用户路径：

1. 用户登录后不进入设置页，也能直接新建 Task 并发送消息；
2. 用户进入已有 Task 后，可以在对话 Composer 中选择后续使用的模型，且不丢失上下文。

## 2. 核心判断

本期只做一个最小、可验证的闭环：

- Account 默认模型只负责新 Task；
- 已有 Task 拥有自己的 pinned model；
- 模型切换复用同一 AgentCore Session，从下一次 Run 生效；
- credential generation 继续保护 Provider、Base URL 和 credential，不因模型切换而改变；
- 不递增现有 `binding.epoch`，不新增第二套持久化 epoch，不复制每个 Task 的模型目录，不持久化短生命周期 pending 状态。

## 3. ExecutionConfig 的正确拆分

这里拆的是产品所有权和版本语义，不是强行修改 AgentCore create ABI 的参数形状。

AgentCore 创建 Session 仍然需要完整的 provider/model/base URL/credential 输入；但 MetaWork 内部应把它理解为两个事实：

| 事实 | Owner | 版本语义 |
| --- | --- | --- |
| Provider、Base URL、credential | Account / Workbench runtime | 由 `execution_generation` 版本化并 pin 到 Task |
| 默认模型 | Account | 只影响新 Task，不 bump `execution_generation` |
| 当前 Task 模型 | Workbench Task | 保存在现有 binding 中；模型变化不递增 `binding_epoch` |

因此，Account 可以继续在创建输入中携带默认模型，但“默认模型变化是否产生新的 credential generation”必须从实现中解耦。

已有 Task 的 credential admission 必须比较：

```text
input.execution_generation == task.binding.execution_generation
input.provider            == task.binding.provider
```

模型不再参与 credential generation 的等值比较；Task model binding 由 Session 和 Task 自己的 Run admission 负责。credential generation/provider 不一致时必须 fail closed，禁止旧 Task 静默使用新凭证。新 Task 从 Account `selected_model` 取得默认值，但 Account 只更新该默认值，不创建新的 credential execution generation。

## 4. 复用现有 Task binding，但不把模型变化塞进现有 epoch

当前 Task 已有：

- `binding.epoch`；
- `binding.execution_generation`；
- `binding.provider`；
- `binding.model`。

本期复用这组结构，但保留现有 epoch 的原语义：

- `binding.epoch` 继续表示现有 credential/session/checkpoint binding；模型切换不修改它；
- 不新增 `model_binding_epoch`；
- 模型选择命令使用现有 Workbench snapshot revision 或 expected model 做 CAS，不用 `binding.epoch` 表达模型变化；
- Run 必须拥有自己的 `execution_generation`、Provider 和 model 字符串；
- 持久化校验保留 Run 与 Task 的 credential generation/provider 约束，移除“Run model 必须等于 Task 当前 model”的错误约束；
- `restoreRun` 使用 `wire.execution_model` 深拷贝构造 `RunRecord.execution_model`，不能继续借用 Task 的 model buffer；
- Run 快照和详情从 Run 自己的 model 字段读取。

这样模型切换不会作废已有 Checkpoint 或 Renderer 手里的 binding epoch，历史 Run 在模型切换和重启后仍显示真实模型。

## 5. 模型目录策略

Task 不复制完整 `modelCatalog`，也不把目录变成 Task owner。

- Renderer 提交模型选择时携带 Account 当前 `catalog_generation` 作为 expected value；
- Host 重新校验 generation 和 model membership；
- Task 只持久化 pinned model（已有 `binding.model`）；
- 当前 Account 目录找不到 pinned model 时，显示原模型和“已不在当前账户目录”，选择器禁用，不静默替换。

目录 generation 是选择命令的并发校验事实，首期不再额外持久化到 Task。若后续需要审计“选择发生时的目录版本”，再单独增加字段，不为当前运行链路预先扩展 schema。

## 6. 模型切换流程

### 6.1 Task 空闲

1. Renderer 提交 `task.selectModel` 意图，携带 Task id、现有 snapshot/CAS revision、Account `catalog_generation` 和模型 identifier；
2. Workbench 校验 Task 可继续、Session idle、Account generation/catalog membership 和 Provider 边界；
3. 调用 AgentCore `session_set_model`；
4. 成功后更新 Task model；不修改现有 `binding.epoch`；
5. 发布新的 Task snapshot；
6. 下一次 Run 使用新模型。

已知失败保留旧 binding。若 AgentCore 已成功但持久化结果不确定，则关闭该 Task 的后续 admission，销毁当前 Session，并按持久化旧 binding 进入可重试恢复；不把不一致状态继续暴露给 Renderer。

### 6.2 Task 正在运行

运行中不调用 AgentCore model mutation。选择器仍可操作，但只在 Workbench runtime 中保留最后一个 `pending_model`：

- 当前 Run 不变；
- 当前 Run terminal 后应用 pending；
- 应用成功后才更新 Task durable binding；
- 应用失败则保留旧模型并发布 typed error；
- 应用重启时不恢复 pending，因为当前产品也不恢复 in-flight Run，Renderer 重新显示 durable 当前模型。

这避免为一个短生命周期 UI 状态增加持久化 journal、schema migration 和恢复协议。

## 7. Restore 语义

### 7.1 expectation

`SessionRestoreConfigV1` 不携带 model，因此 model 不应成为 restore 前的相等证明。正确义务是：Host 在 candidate 提交前把 candidate 设置成 Task 当前 model binding。

Restore 前仍需证明 credential/session 绑定有效：

- credential generation 与 Task binding 一致；
- Provider 与 Task binding 一致；
- Checkpoint 的 Task id、binding epoch、terminal anchor 和历史 Run/Compact 关系自洽。

`docs/agentcore-abi-v1.md` 中“持久化 model 必须与当前 ExecutionConfig 精确一致”的 restore 前置规则必须改写为：

> Restore 不要求持久化 model 与任何当前 model 相等。Host 必须在 candidate 提交前调用 `session_set_model`，把 candidate 设置为 Task 当前 model binding；调用失败即销毁 candidate，并以可重试失败收口。

`recoveryExecutionExact` 不再比较 `task.durable.execution_model` 与全局 `self.execution.model()`；它只校验 Task 的 credential/provider binding 和当前模型目录可用性，模型切换由 candidate restore 的 `session_set_model` 收口。

### 7.2 Checkpoint

Checkpoint/Run 中的 model 是历史事实，只用于校验该 Checkpoint 与其 terminal Run 的 model 自洽。`checkpoint_record.validateBinding` 不能再接收 Task 当前 model 作为相等条件；启动加载和运行期 projection 都不得把历史 checkpoint model 与 Task 当前 model 做跨对象等值比较。Restore 不自动采用 checkpoint 的旧 model，也不把 Task 当前 model 改回历史值；candidate 以 Task 当前 model 继续。

### 7.3 失败边界

restore 是 candidate 全成或全败：

- `session_set_model` 失败：销毁 candidate，restore 返回可重试失败；
- Task binding、当前 Session 和持久化状态保持不变；
- 不确定的 AgentCore 或 persistence outcome 必须 fail closed。

实现前已用隔离 probe 取证 `session_set_model` 的 idle/non-idle 行为与 restore candidate 调用窗口；实现将 candidate 的 set-model 失败收口为候选销毁和可重试 restore 失败，清理失败则 fail closed。

## 8. UI 交互

- New Task Composer 显示 Account 默认模型；
- Existing Task Composer 始终显示 Task 当前模型；
- 切换后显示“下一轮使用：模型 X”；
- 运行中切换显示“当前生成完成后生效”；
- Run 详情展示该 Run 实际使用的模型；
- 设置页明确“默认模型仅影响新建 Task”；
- pinned model 不在当前目录时显示原值和恢复动作，并禁用选择器。

## 9. 实施切片

### Slice A：登录后直接可用

只处理 Account bootstrap：登录成功后自动完成默认 API/model catalog continuation，目录 ready 后允许新 Task admission。

验收：登录 → 新建 Task → 直接发送成功，无需进入设置页。

### Slice B：已有 Task 模型切换

一次完整收口：

1. 先完成 AgentCore `session_set_model` 隔离 probe；
2. 修正 Account 默认模型与 credential generation 的版本语义；
3. 复用现有 Task binding 和 `binding.epoch`；
4. 修正 Run model 历史校验与 restore expectation；
5. 接通 idle switch、runtime pending 和 candidate restore；
6. 更新 Renderer Composer、snapshot 和 Run 详情；
7. 运行 Bridge、Workbench、persistence、restore、并发和 Renderer 回归测试。

首期不新增 pending 持久化字段，因此不需要为 pending 引入 schema hard cut；若未来确实要求跨重启恢复未完成模型切换，再单独设计 durable intent。

## 10. 必须同步的 source of truth

实现 Slice B 时同步检查并更新：

- `docs/requirements.md`：默认模型、Task binding、历史 Run；
- `docs/product-architecture.md`：Account/Workbench/Agent owner、事务和恢复；
- `docs/renderer-bridge-contract.md`：模型选择 command、snapshot 和错误；
- `docs/workbench-ui-design.md`：Composer、pending 和不可用状态；
- `docs/agentcore-integration.md`：Session mutation 与 idle gate；
- `docs/agentcore-abi-v1.md`：restore expectation 语义；
- `src/workbench/checkpoint_record.zig`：Checkpoint 历史 binding/model 自洽校验；
- `docs/validation.md`：probe、restore 和回归证据。

## 11. 验收矩阵

| 场景 | 预期 |
| --- | --- |
| 登录后首次使用 | 不进设置页即可发送 |
| 修改 Account 默认模型 | 只影响新 Task |
| 已有 Task 空闲切换 | 下一次 Run 使用新模型，Conversation 不变 |
| 当前 Run 中切换 | 记录 runtime pending，当前 Run 不变 |
| 重启时存在 pending | 丢弃 pending，恢复 durable 当前模型，不恢复 in-flight Run |
| 修改 API Key/base URL | bump credential generation，旧 Task 不静默换凭证 |
| 模型不在当前目录 | 显示 pinned 模型并禁用切换 |
| 历史 Run 展示 | 永远显示该 Run 实际模型 |
| 切换模型后重启 | Task store 不因旧 Checkpoint model 失配而 corrupt |
| restore 后模型不同 | 使用 Task 当前 binding，不回滚 checkpoint 模型 |
| restore set-model 失败 | candidate 销毁，Task binding 不变，可重试 |

## 12. 明确不做

- 不把已有 Task 选择器直接接到全局 `account.selectModel`；
- 不通过新建 Session 规避模型切换；
- 不删除 credential generation 校验；
- 不让 Task 复制完整模型目录；
- 不持久化首期 `pending_model`；
- 不递增或复用现有 `binding.epoch` 表达模型变化；
- 不静默采用 Account 当前模型或 checkpoint 历史模型；
- 不支持跨 Provider 迁移和 per-Run model override。

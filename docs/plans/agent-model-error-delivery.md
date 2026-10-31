# Agent 模型错误处理与交付方案

日期：2026-10-31。状态：Agent 阶段已收口，当轮专项通过及完整 Native 未通过记录保留；Product 阶段方案已评审通过（APPROVE，Blocking findings: none），尚未实施。

当前实施入口为[第 10 节](#10-product-模型错误交付与旧文件退役最终方案)，覆盖 Product、Bridge、Renderer、SQLite 历史和旧文件退出运行路径。第 1–9 节保留上一阶段的方案与实施结果，其中“本轮”“当前”等表述均以 Agent 阶段为时间和范围边界；后续 Native 修复状态见第 10.11 节。方案评审通过不代表实现或验收已完成，本次整理只修改方案。

本轮在现有 `TerminalResult` 上补齐结构化模型错误，完成 Agent 内部的捕获、校验、终态对账和所有权交付。上层通过 Agent 公共结果取得模型错误、实际执行终态与 Session 可用性，再由各自 owner 制定业务处理。

本文件是实施方案，不是 decision record，也不替代现行规范。实施时同步修改对应合同；依赖身份由各 target 的 canonical lock 唯一拥有。

## 1 目标与范围

完成 Text、多模态和 Skill Run 的同一条生产链路：

```text
Core callback
→ 校验并捕获有界模型错误
→ Core 返回及相关调用静止
→ 对账 ABI status、合法 StopReason 与错误观察
→ 收口最终 failure 和 Session disposition
→ 通过 TerminalResult 交付
```

本轮交付须同时具备错误事实、确定的失败规则、完整生命周期和可重现验证，不能以字段声明或透传作为完成标准。

Agent 继续负责协议消费、执行事实与 Session 生命周期；Product 继续拥有产品终态映射及业务恢复决策。本轮不实现账号刷新、Models 可用性变更、Run 自动重放、用户通知、Bridge 字段或错误持久化。manual compact、独立 Completion、Provider Probe 和生图保留各自现有合同。

## 2 实施依据

规范依据为 [AgentCore ABI 消费合同](../agentcore-abi-v1.md)、[AgentCore 集成契约](../agentcore-integration.md)、[Product 架构](../product-architecture.md)、[Completion 架构](../completion-architecture.md)、[工程结构](../project-structure.md)和[验证规范](../validation.md)。现行 ABI 消费合同要求释放 `model_error`，实施时须同步替换该条款。

按 canonical lock 的 `source.commit` 核对上游 `doc/AGENTCORE_BINARY_ABI.md` 的 `Model failure detail` 章节，并与当前 bundle SDK 对照，接受以下前提：

| 上游保证 | 对 Agent 实现的约束 |
| --- | --- |
| 合法 `STATUS_OK + STOP_API_ERROR` 恰好发送一条 `model_error`，先于 terminal `run_state` | 验证归属、唯一性、顺序与终态一致性 |
| 重试恢复后的失败不保留最终错误；budget outcome 优先及 aborted 分支不发送它 | 以合法最终结果对账，不把历史失败或重试提示当作终态 |
| `on_event` 按 Session 串行，同步 Run 返回是 callback 静止边界 | 复用现有 mutex、callback lease 和静止检查 |
| HTTP 200 可以发生流内错误；`output_limit` 不一定对应失败的 HTTP 请求 | 不通过 HTTP 状态反推详情是否合法 |
| 文本有界并经上游脱敏，但 SDK 未导出字段容量常量，也不校验全部长度上限 | Agent 定义接受容量，并由 canonical 长字段场景验证生产边界 |

`category` 是技术分类，未知 `code/type` 原样保留。`retry` 只描述再次发送同一请求可能是否有效；`attempts` 是最终失败请求的实际尝试次数，不是整个 Run 的请求总数，也不证明全部重试已耗尽。

上游合同以锁定 commit 为准，不以相邻源码仓库 HEAD 或候选 bundle 作为当前接受依据。

## 3 数据结构与消费语义

### 3.1 扩展现有结果

在 `TerminalResult` 增加：

```zig
model_error: ?ModelError = null,
```

`ModelError` 保留 `run_id`、`category`、`code`、`type`、`message`、`http_status`、`request_id`、`retry`、`retry_after_ms`、`attempts` 和 `truncated`。`run_id` 表达 Agent 执行归属，不成为 Product Task identity 或新增路由。

category 和 retry 沿用 Agent 现有 SDK enum 导出方式。调用方通过 Agent 公共入口消费，不直接导入 SDK，不新增 Provider 分类 enum 或产品动作 enum。

现有字段保持各自职责：

| 字段 | 含义 |
| --- | --- |
| `abi_status` 与 raw status | Core 调用结果及 operation 对应的可读边界 |
| `failure` | 既有 ABI 失败或 dependency contract failure |
| `stop_reason` | 仅从合法结果读取的 Run 停止原因 |
| `termination_signal` | 既有 first-writer-wins 控制信号，不等于最终结果 |
| `session_disposition_at_completion` | 完成时 Session 健康状态，不是实时查询 |
| `model_error` | 已校验的本次 Run 模型错误观察，按第 4 节决定是否交付及是否解释终态 |
| `diagnostic`、`first_callback_rejection` | 既有有界技术诊断与固定格式拒绝事实 |

`failure == null` 不等于运行成功。合法模型失败可以是 `failure == null + abi_status == .ok + stop_reason == .api_error`。这些字段承担不同职责，本轮不将它们压成一个错误码，也不增加另一层终态分类。

### 3.2 有界值与 view

新增 `src/agent/session/model_error.zig`，集中实现固定容量错误值、SDK 到 owned 值的构造、只读 view 和纯值测试。该 leaf 不持有 Session、Runtime、Product 或平台 effect，具体收益是隔离容量与按值所有权的验证。

容量只在该模块定义：message 1024 bytes，code、type、request ID 各 128 bytes。注释指向上游合同，具体依赖版本仍由 lock 拥有。实现与测试复用这份容量，不增加配置或自动扩容。

固定容量值不保留 SDK parse arena，也不为捕获各文本字段引入新的分配失败点。既有 SDK JSON 解码仍可能分配，沿现有失败路径处理。构造须完整成功后才安装到捕获槽，不发布半成品。

`ModelError` 是自包含值，可以按值复制；内部不保存指向自身数组的 slice。`view()` 返回借用所属值的只读结构，原值移动、修改或释放后旧 view 失效。消费时取得稳定结果中的引用：

```zig
if (terminal.model_error) |*detail| {
    const observation = detail.view();
    // 在 terminal 移动或释放前消费，或复制所需字段。
}
```

`TerminalResult` 仍包含 owned diagnostic，保持单一所有者、恰好一次 `deinit` 的约束。错误值可复制不代表整个结果可任意复制；转移结果后原 owner 不得再次释放。不新增独立的模型错误释放接口。

### 3.3 字段接受与安全边界

- 复用 SDK decode、现有 UTF-8 和事件字节预算校验；保留可空字段的 null 与非 null 文本区别。
- 已识别详情超出接受容量时，按 dependency contract failure 收口，不由 Host 二次静默截断；上游在容量内提供的 `truncated` 原样保留。
- 不根据 category 反推 HTTP 状态，不根据自由文本生成业务结论。
- 模型错误与 diagnostic 分别表示，不把结构化字段序列化进诊断缓冲区。
- 错误只在 Host 执行结果内交付，不写入日志、产品 event pump、Snapshot、Bridge 或历史。

上游脱敏不证明任意自由文本均可发布。未来展示或持久化须由对应 owner 定义字段并复用 Host credential 清洗；本轮不建立旁路脱敏器。

## 4 捕获与终态对账

### 4.1 接收状态与顺序

每个 Run 仅增加一个可空捕获槽和一个 `terminal_run_state_seen` 标记，均由现有 Session mutex 保护。槽非空同时表示已收到详情，不增加第二份计数或终态副本。

terminal 精确为 `completed | failed | aborted | poisoned`。`finalizing` 只关闭输入窗口，不设置 terminal 标记。顺序在 callback 接收边界判断，不查询 Product phase 或 event pump 消费进度，也不重做完整 RunState projector。

callback 按以下顺序处理：

1. 沿现有机制取得 lease，验证 RunContext、handle、Session identity 和 active Run。
2. 按现有字节预算、SDK decode 和 UTF-8 入口解码。
3. 对合法 `run_state` 继续处理输入窗口，在真正 terminal 到达时设置标记。
4. 对 `model_error` 检查 payload Run ID、槽为空、尚未 terminal、容量及官方字段约束。
5. 完整构造并在锁内安装 owned 值，释放 SDK parse owner，返回 continue；该事件不 enqueue，也不额外唤醒产品事件消费。
6. 重复、错 Run、terminal 后到达或已识别详情超长时，记录固定格式拒绝事实，沿既有 dependency contract/fatal 路径关闭后续准入；close 竞争遵守原生命周期。

SDK 解码或 UTF-8 失败继续使用现有 invalid-event callback 路径，不统一改写其他 malformed event 的分类。`finalizing → model_error → failed` 必须通过，`failed → model_error` 必须拒绝。`retry_notice` 保持现有 activity 路径。

### 4.2 对账与状态收口

在 `executeBegunRun` 中，完成现有 callback、输入提交和 abort 静止检查，按 operation 可读边界校验 status 与结果，再对模型错误与合法 StopReason 做一致性检查。

新增对账必须早于以下动作：最终 dependency failure 收口、`input_counts` 发布、`run_done` 置位、Session 回到 idle、结果转移。这样新增违约进入同一次 failure/disposition 计算，避免返回合同失败而实际 Session 仍可准入。

先确定最终 failure，再按下节选择交付值并清空槽。`takeTerminalResultLocked` 只转移，不追加会改变 Session 健康的新校验。非 OK 返回不读取未定义的 StopReason；新增详情不提前发布产品终态，也不绕过 Product event drain barrier。

### 4.3 交付规则

以下规则按表中优先级执行：

| 最终事实 | 必须产生的结果 |
| --- | --- |
| 任意来源的 `failure == .dependency_contract` | `model_error = null`，包括 identity、callback 未静止、输入计数及新增错误校验违约 |
| 合法 `OK + API_ERROR`，恰好捕获一条合法详情 | 必须交付详情；Session disposition 沿既有执行与生命周期规则计算 |
| 合法 `OK + API_ERROR`，没有详情 | 新增 dependency contract failure，关闭后续准入，详情为 null |
| 合法 OK 结果为其他 StopReason，却捕获了详情 | 新增 dependency contract failure，关闭后续准入，详情为 null |
| 已捕获合法详情，随后发生普通 callback 或非合同违约的 ABI 失败 | 必须交付详情作为补充观察，实际终态由既有失败规则决定 |
| 未捕获详情，结果也不要求详情 | `model_error = null`，不生成 Host 猜测值 |

普通 event pump 拒绝导致 `CALLBACK_FAILED + .abi_status` 时，合法详情必须保留；后续若又发现合同违约，第一行优先。只有合法 `OK + API_ERROR` 才能将详情作为该模型失败终态的解释。

在既有 `CallbackRejection` 固定 enum 中补足必要的缺失、重复、顺序、容量或终态不匹配原因。拒绝事实只包含固定类型、identity、计数和边界，不拼接模型错误正文或增加诊断 owner。

## 5 生命周期与上层边界

### 5.1 所有权转移

| 阶段 | 所有权与清理 |
| --- | --- |
| Session 新建、Run 准备 | 槽为空、terminal 标记为 false；准备失败不遗留新增状态 |
| callback | SDK 数据仅在 callback 内存活；Session 在锁内保存完整 owned 值 |
| 完成对账 | 按第 4 节转移或丢弃错误值，清空 Session 槽 |
| 下一轮 Run | 独立初始化状态，不修改前轮已返回结果 |
| 准备取消、执行前中断 | 详情为 null，沿现有 finish 路径清理 |
| close、shutdown、callback 失败 | 等待现有 lease 与 effect 静止，按同一收口规则处理 |
| 调用方结束消费 | 恰好一次释放结果；旧 view 失效，固定错误值无独立 allocator owner |

旧结果不得借用 SDK、Session 或 Runtime 存储。测试覆盖前轮结果跨下一轮存活、Session 关闭释放后仍可读取，以及最终唯一释放。新增状态不进入 checkpoint，不解析 Core Conversation，不建立跨 Run 的“最近错误”缓存。

### 5.2 上层消费限制

上层未来结合精确来源、授权或 source generation、生命周期制定动作。Agent 合同明确：

- `retryable` 不证明整轮 Run 重放安全，不授权重复工具 effect。
- 鉴权错误不单独证明 Account 失效，也不授权 Agent 刷新、退出或替换凭据。
- 支付类别或业务 code 不直接改写 Account 余额或 Models authority。
- 模型服务权限与工具 Permission 是独立合同。
- 详情不改变已发生的 effect、已提交输入和输出，不替代 Session disposition。

调用方本轮可不消费新增字段，正常产品投影保持原状；新增校验发现的真实违约仍须明确失败。

## 6 文件修改清单

| 文件 | 修改内容 |
| --- | --- |
| 新增 `src/agent/session/model_error.zig` | 有界值、唯一容量、SDK 构造、view 和纯值测试 |
| [session/control.zig](../../src/agent/session/control.zig) | 结果字段、消费语义和必要的固定拒绝原因 |
| [session.zig](../../src/agent/session.zig) | 类型导出、捕获槽、terminal 标记、callback、对账与全部清理路径 |
| [agent.zig](../../src/agent.zig) | 导出公共错误类型 |
| [Agent lifecycle 测试](../../tests/agent/lifecycle_test.zig) | 顺序、结果矩阵、静止、跨轮和释放 |
| [共享 fixture](../../tests/support/lifecycle_fixture.zig) | 合法 API error 事件及受控违约、竞争输入 |
| [Host probe](../../scripts/probes/agent-multimodal-test.zig) | terminal 详情、Session 复用和事件不入泵断言 |
| [Provider 驱动](../../scripts/run-agentcore-provider-test.mjs) | 具名长字段场景 |
| [ABI 消费合同](../agentcore-abi-v1.md) | 替换丢弃详情的规则，链接集成契约 |
| [集成契约](../agentcore-integration.md) | 完整定义结果、校验、优先级、所有权与消费限制 |

`wire.zig` 仅在局部校验确需复用时调整，继续使用官方 JSON decoder。新 leaf 使用相对 import，不新增 owner 或 module root。测试发现缺少引用时才补最小接线。

Product、Account、Models、Bridge、Renderer、SQL/migration、bundle lock、依赖 artifact 和 `AGENTS.md` 不在修改范围。共享 fixture 的修正服务于本次 Agent 消费合同，不放松既有 guard。

## 7 验证设计

### 7.1 纯值与生命周期

纯值测试覆盖字段复制、未知 code/type、可空值、UTF-8 和多字节边界、各字段到达或超过容量、上游 truncated、构造失败不安装半成品、SDK 数据释放后的独立性。值复制或移动后重新取得 view，不使用原对象的旧 view。

lifecycle 测试通过生产 Agent callback 执行，按下表观察失败模式：

| 场景 | 必须验证 |
| --- | --- |
| Text、多模态、Skill | 每类至少一例合法 API error，复用详情、终态与健康断言 |
| 合法 `finalizing → model_error → failed` | 成功交付，finalizing 未提前关闭捕获 |
| 重复、错 Run、terminal 后详情、超长字段 | fatal、dependency failure、详情为空、后续准入关闭 |
| API error 缺失详情、其他 OK StopReason 携带详情 | dependency failure，且实际 Session 健康与返回结果一致 |
| 详情后普通 event pump 拒绝 | 保留 `.abi_status`、既有终止信号和非空详情 |
| 详情后 identity、输入计数或 callback 静止违约 | dependency failure 优先，详情必须清空 |
| 非 OK 返回携带不可信结果区 | 不用其中 StopReason 对账 |
| 成功、准备取消、执行前中断 | 详情为 null，无跨轮残留 |
| 关闭与终态竞争、结果转移和释放 | 现有同步边界成立，结果独立存活且恰好释放一次 |
| SDK parse/allocation 失败、原始事件超限 | 既有失败分类保持，无部分捕获或泄漏 |

缺失详情和终态矛盾用例同时断言 failure、返回 disposition、实际 Session 状态和后续准入拒绝，避免只改返回值。各结果路径断言详情应保留或应为空。

正常凭据拒绝 fixture 必须发送合法详情；缺失事件作为明确命名的违约反例。新增竞争测试复用现有 callback、condition 或 barrier，明确捕获、取消、返回和释放的先后，不依赖固定 sleep，也不增加调度框架。

### 7.2 canonical Core 与容量接受

沿现有 `--staged --host` 入口保留 Responses、Chat Completions、Anthropic Messages、Gemini Native 的生产接线验证。各协议受控拒绝断言 terminal 详情、事件不入泵，以及后续显式 Run 成功。

长字段场景固定为 Chat Completions 的 HTTP 401：

| 输入来源 | 输入与断言 |
| --- | --- |
| `error.message` | 超过 message 容量，断言对应前缀与长度 |
| `error.code` | 超过 code 容量，独立于 type，避免回退取值 |
| `error.type` | 超过 type 容量，使用不同前缀 |
| `x-request-id` 响应 header | 超过 request ID 容量，单独核对来源与内容 |

四个值使用无 secret、可预测的不同前缀；完整响应必须在客户端原有 body 读取预算内。场景由明确请求内容或具名阶段选择，使用独立受测 Session 和请求断言，避免误落入现有按请求计数选择 401/200 的分支；不重构整个驱动。

四字段分别断言预期前缀和长度、均在 Agent 容量内，整体 `truncated = true`，且 Host 成功交付。不能只断言全局 truncated 或一个字段。未来 Core 输出超过接受容量时，该用例必须失败，再显式评估合同与容量。

该场景证明所测输入、协议和锁定 artifact 的边界，不证明未来所有协议分类或脱敏模式。其他组合放在纯值/lifecycle 层；只有存在独立 Agent 消费失败模式时才追加 canonical 场景。所有 Provider 场景使用 loopback、合成凭据和临时目录。

### 7.3 测试发现与执行入口

`test-agent-lifecycle` 验证 Session/fixture 行为；不能因 leaf 被生产导入就认定其中纯值测试已运行。核对现有 `metawork-agent-session` module test root，必要时加最小引用，并从输出确认新增用例实际执行。

实现阶段按当前机器 canonical target 执行：

```text
node scripts/verify-staged-agentcore-bundle.mjs
zig build test-agent-lifecycle
zig build test-lifecycle
node scripts/run-agentcore-provider-test.mjs --staged --host
node --test scripts/architecture-boundaries.test.mjs
node node_modules/@native-sdk/cli/bin/native.js test . --yes -Dtarget=<verified-target>
git diff --check
```

Native 入口对应 `scripts/build.mjs` 的 `nativeCli`，参数沿用 `scripts/run-tests.mjs` 的 `runNativeTests`。先定向定位，再完成 Agent root、完整 lifecycle、canonical probe、owner guard 与正式 Native graph。只有独立平台失败模式才扩展平台矩阵；bundle、工具链或 required evidence 缺失须明确报告失败。

## 8 实施顺序与验收

按依赖顺序完成一个完整改动：

1. 实现有界值、公共字段与纯值测试。
2. 接入捕获和真正 terminal 标记，补边界及顺序反例。
3. 完成终态对账、交付优先级、状态与所有权收口，同步正常 fixture 和 lifecycle 测试。
4. 扩展 canonical Host probe 与具名长字段场景。
5. 同步两份领域真源，完成第 7 节验证并核对范围。

原定完整验收标准（当前 Native 项未满足，实施收口决定见第 9 节）：

- 三种输入经同一生产路径交付详情；所有权、身份、顺序、容量及终态规则均有确定测试。
- 新增违约在 Session 状态最终收口前生效；普通失败必留详情，合同失败必清详情。
- 旧结果独立存活，无跨轮残留、资源泄漏或重复释放。
- 四协议接线、长字段接受、测试发现、owner guard 和当前平台正式 Native graph 均通过。
- 上层消费语义明确，产品恢复、投影、持久化与依赖输入保持本轮范围。

## 9 本轮实施结果

实施分支为 `feat/agent-model-error-delivery`，TinyKG 根任务为 10748。方案基线、有界值、生产接入及 canonical 验证子任务均已完成并分别评估、提交。用户在查看下述结果后明确选择“收口本次 Agent 实施，保留完整 Native 未通过记录”；最终验证子任务 10753 与根任务据此完成本次范围的收口，不表示完整 Native 验收通过或解除其失败。

2026-10-31 本机 Windows x86_64 验证结果：

| 验证 | 结果 |
| --- | --- |
| canonical stage verifier | 通过，依赖和 lock 未修改 |
| 有界值测试与正式 Agent Session root 测试发现 | 五项新增纯值测试通过，并已确认被正式 root 发现执行 |
| 完整 Agent lifecycle root | 132/132 通过 |
| 完整 lifecycle graph | 306/306 通过 |
| architecture guard | 33/33 通过；按现有 guard 修正 leaf 的命名聚合引用，未修改 guard |
| canonical Host probe | 四协议详情交付、后续显式 Run、Chat Completions 四长字段接受均通过 |
| canonical SDK probe | 四协议通过，原有 SDK 模式保持可用 |
| 格式、文档链接与 diff 检查 | 通过 |
| 完整 Native graph | 未通过；出现 test runner 无响应、Skill archive 用例崩溃，Office pipeline 停滞后仅停止了已核实归属的本轮测试子进程 |

已用任务开始前精确提交 `857e5339` 的临时 detached worktree，在同一工具链和 canonical 依赖上重新执行 `zig build test-product-skill-runtime --summary all`。基线同样为 30/31 通过、1 crashed，停在 `managed imports bind source grants and publish effective bytes through export and reimport` 的 archive preview。当前产物与基线均在 Windows Zig ZIP 读取路径触发 `.PENDING => unreachable`；此前的 `FileTransactionFailed` error-return context 不能据此解释为该 panic 的根因。该 Skill 失败不是本轮 Agent 修改引入。其余 runner 超时与 Office 停滞尚未归因，不能由这项对照一并认定为同因或已解决。

本轮保留失败，不跳过测试、不调整 verifier、不修改 Product/Skill 或 SDK。基线 checkout 和依赖 junction 已清理，原依赖保持完整。完整 Native 通过仍是第 8 节未满足的验收条件，既有失败的修复未纳入本次实施。

本地缓存日志保留于 `.zig-cache/agent-model-error-{final-agent,final-lifecycle,architecture,p3-host,p3-sdk,final-native,baseline-skill}.log`。这些是本轮复核线索，不替代可重现测试或长期验证账本。

## 10 Product 模型错误交付与旧文件退役最终方案

### 10.1 目标与范围

让 Agent 已交付的模型错误成为用户可见、可在重启后查看的 Run 事实，并由 Product 提供符合来源和当前操作资格的恢复入口。同时结束旧 `.store` 的运行时参与，将兼容范围压缩为一次性导入；旧文件原样保留，删除以后另行决定。

当前正式 Task 历史已经接入 SQLite：Application 的 [history store](../../src/app/history_store.zig) 创建和管理 `workbench-history.sqlite`，[Product Control persistence](../../src/product/control/persistence/schema.zig) 拥有 schema、codec 和 repository。模型错误持久化直接接入现有 Run 终态保存边界，不等待另一次 SQLite 落地。

本阶段包括 Run 内存记录、安全清洗、终态投影、typed Bridge、Renderer 提示与操作入口、SQLite 保存和恢复，以及旧 `.store` 在迁移后的停止读取、清洗和写回。不删除或自动隔离旧文件，不建设删除资格证明。不新增自动重放、自动退出账号、余额推断、Models authority 修改、协议切换或第二条模型错误通道。manual compact、独立 Completion、Provider Probe 和生图仍保持各自合同。

### 10.2 Owner 与数据链路

```text
Agent TerminalResult.model_error
→ Product 按值接收并通过 Host credential 清洗
→ 随同 Run 终态发布和 event drain 收口
├→ Product 安全投影 → typed Bridge → Renderer
└→ 现有 Run durable boundary → SQLite → 冷启动恢复

Product 根据错误事实、精确来源和当前资格生成恢复入口
→ 用户显式操作 → 既有 Account / Models / Task 流程重新校验
```

Agent 保持既有校验和执行生命周期。Product Task 保存观察、决定终态含义和展示；Product Control 负责跨对象恢复动作及历史事务；Account 与 Models 分别保有自身授权、凭据和可用性 authority。Application 执行文件和数据库 effect；Renderer 不导入 SDK、不分类自由文本、不自行决定恢复资格。

### 10.3 Run 记录与终态语义

Run 为可空模型错误预留固定容量，按值复制 Agent 公共 `ModelError`，复用其字段和容量定义，不复制 SDK arena、Session 存储或借用 view，也不另建可扩容错误正文。Host 清洗所需的固定缓冲和结果构造保持同样的容量边界。

记录保留 category、code、type、message、HTTP status、request ID、retry、retry-after、attempts、上游 truncated 及 Agent Run identity，并额外表达 Host 清洗与 Host 截断事实。模型错误的 Agent Run identity 只是执行来源，不成为 Task 路由，不假设与 Product Run ID 数值相等。恢复入口使用既有的无 secret 来源事实；确需补充时只冻结最小来源身份，不保存 credential locator、凭据或第二份 ExecutionConfig。

接收与现有 terminal payload 在同一发布边界完成，早于结果 `deinit`；维持 write-once publication、callback 静止、event drain 和关闭顺序。主线程后续 credential 清洗仍遵守现有同步和投影失效规则，不修改 worker 正在使用的 owned 历史候选。

既有 `classifyAgentTerminal` 与 Product event drain 的优先级保持不变：

| 执行事实 | Product 含义 |
| --- | --- |
| 合法 `OK + API_ERROR`，最终 Product cause 为 `provider_failure` | 使用详情细化模型错误文案和恢复建议 |
| 普通 ABI/callback 失败附带合法详情，或 Product 后续发现 event pipeline failure | 保留详情作为补充观察；主提示仍解释真正的最终 cause |
| Agent dependency contract failure | Agent 不交付详情；Product 不补造模型错误 |
| Product 最终形成 dependency contract failure | 已合法接收的详情仅作为补充观察；不解释、覆盖或降低该终态 |
| 成功、取消、执行前拒绝或旧历史没有详情 | 保持 null，不从 diagnostic、日志、HTTP status 或历史最近错误重建 |

不把所有 category 扩成新的 `RunCause`。`provider_failure` 继续表达稳定终态原因，详情提供更具体的模型失败事实。

### 10.4 Host 清洗与发布边界

所有外部文本字段，包括 `message`、`code`、`type`、`request_id`，均使用现有 Host credential sanitizer。category、retry、计数与其他结构字段维持 typed 语义，不能因字节巧合按自由文本替换。

清洗覆盖三处：终态接收时形成 Run-owned 安全副本；凭据首次获知、替换或释放前清洗已有内存与 durable candidate；投影交付前按现有 live credential 和安全代次再次检查。新增 SQL 字段、只读/保留 payload 和待确认候选都必须纳入现有历史安全协议，不能通过 JSON 嵌套绕过字段分类，也不能改变未知事务的确认依据。

清洗始终有界且保持合法 UTF-8。替换文本超过目标容量时按 UTF-8 边界截断并记录 Host 截断；正文被完全清除时展示固定本地化占位，不回退原文。上游 `truncated`、Host redacted 和 Host truncated 分开保存和发布。清洗失败不得退回未经清洗的内容，也不得把已经完成的执行改成另一个 outcome；按既有安全发布和 history health 规则处理。

不将模型错误正文拼进 diagnostic、日志、event pump 或产品 activity。既有 `diagnosticDisposition` 继续只描述独立 diagnostic 的 absent/withheld 状态；它不能暗示结构化模型错误也被隐藏。Renderer 中两者分别表达，避免一边展示安全详情、一边声称所有附加信息都不可见。

### 10.5 投影与 Bridge

在现有 Run terminal 增加必填、可空的 `modelError`，非 terminal Run 不发布终态详情。类型完整表达安全字段、上游截断和 Host 清洗事实；所有 u64/identity 按既有 canonical decimal wire integer 规则编码。自由文本保持 null 与非 null 的区别，Host 固定占位由明确清洗状态驱动。

Host serializer、跨语言 fixture、TypeScript 类型、严格 decoder 和历史 Run 投影同时更新。Renderer 只消费 Product 发布的分类和恢复资格；不从 code、type、message 或 HTTP status 再推导业务结论。依照当前 Bridge revision 的开发期 hard cut 合同更新，不接受平行旧 shape 或静默 fallback；旧历史缺字段由 Host 历史迁移归一为 null。

模型错误内容归属发生错误的精确 Run，model、protocol、来源均取该 Run 的事实，不能使用当前默认模型或 Task 新 binding。历史上的错误事实不直接授予今天的操作资格；恢复入口在读取、点击和实际 effect 前按现有 Product 路径重新校验。

### 10.6 用户提示与恢复动作

沿用现有 terminal notice 和默认折叠的运行详情。主区用本地化分类解释失败、无回复或部分回复的影响，以及可采取的动作；详情显示 Host 清洗后的服务端 message、code/type、HTTP status、request ID、请求尝试次数、retry 建议、retry-after 和清洗/截断事实。字段为空时不伪造内容，外部文本按普通文本渲染，不解释 HTML、命令或服务端提供的操作链接。

有工具记录时保留“已有操作可能完成，重试前检查执行详情”的提醒。补充观察不得把 event pipeline、权限或 dependency failure 的主提示改成模型服务失败。窄窗、长文本换行、键盘 disclosure、展开/折叠和浅深主题沿用现有组件和 UI 合同，不增加第二套错误面板。

| 官方 category | 主提示与 Product 恢复方向 |
| --- | --- |
| `authentication` | 提示服务端拒绝了请求凭据；Metask 来源提供符合当前 Account 状态的登录/账号入口，Custom Provider 提供对应凭据设置入口 |
| `permission` | 提示模型服务权限不足，提供来源设置或可用的模型选择入口；不进入工具 Permission 流程 |
| `payment_required` | 提示服务端要求处理支付状态；仅使用 Product 已有且可信的 Metask 充值或服务商管理入口，无可用入口时给出来源对应的处理建议 |
| `not_found`、`invalid_request` | 提示模型或请求被服务端拒绝，提供适用的模型/来源设置及修改指令建议，不断言一定是本地配置错误 |
| `context_window` | 提示上下文超限；仅在当前 Task 允许时提供既有 compact 或模型选择入口 |
| `output_limit` | 提示输出达到限制并说明部分内容；建议调整任务或显式继续，不宣称原 Run 已完成 |
| `rate_limited`、`overloaded`、`server_error`、`timeout`、`connection`、`stream_interrupted` | 按具体分类提示等待或连接/流中断；结合 retry 和 retry-after 给出请求层建议，提供合格的“准备重试”入口 |
| `unknown` | 保留通用模型失败提示和安全详情，不靠未知 code 或 message 匹配业务动作 |

分类只描述模型请求事实。`authentication` 不证明 Account 失效；`payment_required` 不证明余额不足；任何 category/code 均不直接更新 Account、余额、Models readiness 或 admission。重新登录、充值、设置和模型选择都是用户显式入口，继续走各自 owner 的现有事务与校验；本阶段不为错误处理新建支付系统或自动恢复编排。

“准备重试”沿用现有安全交互：仅在当前 Task 真实可继续、所需输入可用且草稿不会被覆盖时，将可恢复指令填回 Composer，由用户确认后发送；不立即提交新 Run，不静默重放原 Run、工具、追加输入或附件。无法重建的输入须明确要求重新选择，不伪造已恢复。`retryable` 不单独授权或启用该动作，`not_retryable` 也不禁止用户修改配置或指令后显式重试。attempts 不表述为整个 Run 的重试总数或已耗尽所有重试。

### 10.7 SQLite 历史保存与恢复

模型错误随现有 Run 终态、完整安全回答和 Task 状态在同一次历史事务中保存，沿用 best-effort health、dirty 补写和 unknown witness 规则。保存失败不回滚执行终态，不重新运行 Agent，不提前释放仍被引用的凭据或资源。

为 `runs` 追加一个 nullable typed JSON 附属值，承载完整安全观察及 Host 清洗事实；它随 Run 整体读写，不新增错误表、通用事件日志或独立提交。按当前 Product wire codec 精确编码，u64 不经浮点，字段容量和 UTF-8 受 Product 校验。现有 diagnostic 的保存与安全语义保持独立。

0.2.8 发布提交 `670e235d` 已包含 SQLite 历史，`0001_task_history.sql` 是必须保留的已发布身份。通过追加有序迁移引入模型错误字段，禁止原地改写 0001；不为暂不删除的旧文件增加源指纹、完整性证明或清理状态字段。旧 SQL Run 和 framed 导入记录缺少模型错误时初始化为 null；不尝试从旧 diagnostic 解析。SQL loader、candidate 校验、恢复、只读/保留记录及 credential 清洗共同覆盖新字段。

已安装的 0.2.8 与 dev 构建共享数据目录。升级 schema 后，0.2.8 遇到 `VersionUnknown` 必须保持禁写，不回退 `.store` 或替换新库；下一个发布版本包含新 schema 支持前，0.2.8 不能用该目录读取升级后的历史。这是版本接受边界，不以改写 0001、双写或旧文件 fallback 规避。

重启后能显示已保存的错误详情和原始执行事实；恢复动作根据当前资格重新计算，不持久化按钮 enabled 状态、Account 授权证明、充值结果或自动重试意图。

### 10.8 旧 store 的一次性导入和退役

退役指退出产品运行路径：`workbench-history.store` 只在尚无正式 SQLite、且允许首次迁移时读取；成功转换并确认 SQLite 接管后，后续启动和所有日常操作直接使用 SQLite。旧 `.store` 原样留在原位，本阶段不删除、不自动改名隔离、不做覆盖比较，也不建立删除证明或清理重试系统。

| 启动状态 | 行为 |
| --- | --- |
| 正式 SQLite 不存在，旧 `.store` 存在，且没有要求先恢复的 SQL 证据 | 读取旧来源，在私有临时库转换、校验和发布；确认 SQLite 接管后只使用 SQL，旧文件原样保留 |
| 正式 SQLite 已存在，包括 0.2.8 已导入的库 | 只加载 SQLite，不读取、计算指纹、解码、清洗、写回或合并 `.store`；旧文件原样保留 |
| 两者都不存在，且没有迁移/恢复证据 | 通过既有流程初始化空 SQLite |
| 转换失败、发布/提交结果未知，或 SQLite 损坏、不可读、版本不受支持 | 保留旧文件及相关恢复证据，明确失败或进入既有恢复流程，不回退 `.store` |

首次转换严格按以下顺序进行：

1. 持有既有 history 互斥与目录 authority，读取稳定的旧来源，保持 `.store` 原样。
2. 将可接受事实、只读/保留记录及身份高水位导入私有临时 SQLite；复用现有恢复和降级规则，不因减少兼容路径而放弃合法记录。
3. 通过完整 loader 和业务恢复校验，完成 checkpoint/同步并关闭临时连接。
4. 发布到正式路径，确认发布持久化，重开校验历史与提交依据；文件存在、COMMIT 返回或 SELECT 成功均不能单独代替这一步。
5. SQLite 确认接管后交付正式能力；后续读取、保存和 credential 清洗均只针对 SQL 及当前 Product-owned 内存和候选，不再访问旧来源。

“读一次”指成功迁移后不再消费旧来源。转换尚未发布就失败时，可以按既有流程重试读取；发布后发生 unknown 时先按既有提交依据重新观察和确认 SQL，不重新导入或覆盖。未发布的普通临时导入仍可按既有规则清理后重做；缺正式库但存在 WAL、SHM 或 quarantine 不等于首次启动，不允许据此重新导入或初始化。

`decodeRecovering` 跳过损坏 frame 或业务恢复出现 degraded 时，保持现有降级观察，不能宣称所有源数据已经完整迁移。可恢复事实按现有规则进入 SQLite，原件保持不变以便后续找回；不为判断旧文件能否删除新增完整性追踪。如果旧版本在迁移后继续向 `.store` 写入，新版本仍只使用 SQLite，不自动合并；旧版本写入的原件继续保留。

在新增 persistence wire 字段前移除 `sanitizeLegacy`、`legacy_pending` 及只服务旧文件清洗的凭据保留和测试分支。现有清洗路径会解码旧文件后以当前 wire 重新编码写回，新增字段可能使只接受旧 shape 的发布版拒收；因此必须先闭合“不再写回旧文件”，再扩展历史字段。

SQL、当前内存、只读/保留 SQL payload 和待确认候选仍须遵守完整 credential 清洗合同；原样保留的旧文件不再属于应用自动维护范围，也不承诺其已被清洗或清除，不为维护该静态副本继续保留 credential lease。该取舍及未来删除边界见第 10.12 节。

保留一次性 framed reader、导入验证、SQL codec 仍依赖的数据类型和必要的进程锁；不因为它们曾由 `FileStore` 提供就机械删除，也不保留无职责的旧 canonical writer。必要的目录或锁管理不等于读取旧历史内容。现有显式恢复继续按其授权边界保全证据，本阶段不增加自动删除或隔离旧来源的动作。

以后若决定删除旧文件，再单独定义完整迁移、来源变化及旧版本新增数据的证明和保全规则；SQLite 可加载不证明磁盘上的 `.store` 已完整进入 SQL。本阶段不提前实施这套删除机制。

### 10.9 文件与合同范围

| 范围 | 实施责任 |
| --- | --- |
| `src/product/task/{state,policy,execution,view}.zig` 及相关 runtime | Run-owned 安全观察、终态优先级、投影和恢复资格 |
| `src/product/task/persistence.zig`、`history_security.zig` | typed 历史字段、旧记录默认值和统一安全字段分类 |
| `src/product/control/persistence/` | 模型错误的新迁移、SQL codec、repository 及同事务保存/恢复 |
| `src/app/history_store.zig` 及必要的 stores 接线 | 一次性导入后只使用 SQLite，保留旧文件，移除旧文件清洗职责 |
| Host Bridge serializer、共享 fixture、Renderer contracts/decoder | 严格 `modelError` 字段与无 secret 的恢复资格合同 |
| Task notice、`RunDiagnostics`、恢复动作处理和中英文文案 | 分类、清洗后详情、来源匹配的显式动作和草稿保护 |
| 相关 Product、Application、Bridge、Renderer 测试 | 观察实际生命周期、安全发布、历史和迁移失败模式 |

实施时按 owner 同步真源：产品行为进入 [requirements](../requirements.md)，呈现进入 [ui-design](../ui-design.md)，Product 终态、历史与旧来源退役进入 [product-architecture](../product-architecture.md)，wire 进入 [renderer-bridge-contract](../renderer-bridge-contract.md)。[AgentCore 集成契约](../agentcore-integration.md)中“当前不发布/不入历史”的阶段限制需更新为 Product-owned 清洗后消费，Agent 捕获和校验不变量保持不变。[Storage 架构](../storage-architecture.md)只纠正已过时的“Application 与 Product 尚未接入”状态及相关依赖描述，不承载业务字段；[验证规范](../validation.md)登记实际新增验证责任和证据。

原 SQLite 接入方案中持续清洗旧来源的描述在实施时同步指向本节确定的运行路径退役规则：保留旧文件，但成功迁移后不再消费或维护它。第 1–9 节作为上一阶段记录保留，不把旧阶段范围误当成本阶段限制。不修改 AgentCore artifact/lock、`AGENTS.md`、machine guard 或无关业务 store。

### 10.10 实施顺序

| 顺序 | 工作包 | 完成条件 |
| --- | --- | --- |
| 1 | 收口旧来源维护 | 保留首次导入；已有 SQLite 后不读取、清洗或写回 `.store`；重启与凭据变更测试证明旧字节不变，SQL 安全维护正常 |
| 2 | 接入 Run-owned 模型错误 | 固定容量按值接收，结果释放后独立存活；Host 清洗有界；主终态与补充观察优先级正确 |
| 3 | 接入 SQLite 历史 | 只追加迁移，字段与 Run 同事务；旧记录为 null；恢复、dirty/unknown 和 credential 再清洗闭合 |
| 4 | 接入投影和用户交互 | Host、Bridge fixture、严格 decoder、Renderer 同步更新；安全详情可见；恢复入口按当前资格校验，准备重试只填入 Composer |
| 5 | 验收完整产品链路 | 通过相关 roots、正式 Native graph 和当前平台真实接线验证；实际覆盖保存后重开、显式恢复动作及旧文件不变 |

步骤 1 是扩展 persistence wire 的前置条件。各工作包在改变外部合同时同步更新第 10.9 节对应真源与测试，不把合同和安全接线留到最后。步骤 5 统一复核差异和验证结果，不补做已经错过的安全前置条件。

每一步保持已有执行和历史路径可工作；不以尚未完成的异步框架、平行历史格式或临时兼容层替换生产链路。

### 10.11 验证与验收

| 失败模式 | 最小充分观察 |
| --- | --- |
| 详情丢失、借用已释放数据或覆盖真正终态 | Product 终态/lifecycle：Agent 结果 deinit、下一轮、Session 关闭后仍可读；三种 Run 输入共用生产链路；补充观察不覆盖 ABI、pipeline 或 dependency failure |
| credential 泄漏 | message/code/type/request ID 的精确 secret、重叠 secret、UTF-8、替换扩容、全字段清除；首次获知、替换、释放及晚到清洗；Snapshot、SQLite、只读/保留记录和 pending candidate 均无未经清洗内容，日志无模型错误正文 |
| 历史丢失、迁移破坏或重放 | 真实 Storage：从当前 schema 升级、null/完整字段往返、正常关闭/强杀恢复、失败与 unknown、dirty 补写；新字段与 Run 同事务；旧迁移 checksum 不变，恢复不执行动作 |
| wire 或显示误导 | 跨语言 fixture、严格 decoder、Renderer typecheck 和 Task suite：缺字段/非法值拒绝；主次失败优先级、部分回复、空字段、长文本、Host 与上游截断、诊断 absent/withheld 独立表达 |
| 非法恢复或重复 effect | 真实 Product 入口：Metask/Custom 来源隔离、历史来源变化、登录/支付不改变其他 authority、stale 点击拒绝；草稿不覆盖、附件不补造；准备重试不发送请求、不执行工具 |
| 旧文件继续参与运行或被改变 | Application 隔离目录测试：首次迁移成功、重启和凭据变更后旧字节保持不变；已有 SQLite 时让 `.store` 不可读或损坏仍不影响 SQL 加载与保存；旧版本改写 `.store` 后新版本不读取、不合并、不覆盖；无清洗、指纹计算或删除调用 |
| 一次性导入丢失事实或重复执行 | 导入失败/unknown 及发布中断保留原件；未发布时可按当前来源重试；已发布时确认 SQL 不重导入；CRC/header 损坏的 degraded 不伪装完整导入，合法记录及保留 frame 继续按现有规则恢复；无额外删除证明迁移 |
| 已发布版本接受边界破坏 | 以 0.2.8 接受规则验证升级库返回 `VersionUnknown`，普通保存、退出补写及显式恢复均不能覆盖、降级或回退 `.store`；新版本重开保留完整历史 |
| 迁移源被错误重建或恢复证据被删除 | 无正式 DB 但有 WAL/SHM/quarantine 时拒绝首次初始化；未知版本与损坏 DB 不回退且保留 `.store`；既有锁有效，不新增旧来源删除、隔离或证据清理动作 |

按 [验证规范](../validation.md)运行受影响 Product/Application roots、`test-product-history-schema`、`test-lifecycle`、Bridge/Renderer suites、architecture guard 和正式 Native graph。涉及实际 AgentCore 调用时先通过 canonical staged verifier；当前平台真实 Product 路径须证明模型错误经过 Host 清洗进入提示，并经 SQLite 重开后仍可见，恢复入口由用户显式触发。只有存在独立平台失败模式才扩展平台矩阵。

第 9 节记录的 Native Skill 归档崩溃与 Office fixture 失败已在后续修复中验证收口；runner 间歇性停滞的根因仍未定位，属于已知未闭合问题，必须与本阶段结果分别报告。单次完整 Native 通过不证明 runner 问题已消失；不跳过、不弱化 guard，也不因专项通过声称完整 Native 通过。本次仅整理方案，检查文档链接、锚点与 `git diff --check`，不执行 runtime 测试。

最终验收以用户可观察闭环为准：错误不再随 Agent 结果释放而丢失；用户能看到具体分类与安全详情；重启后可查看已保存事实；恢复入口不扩大授权、不自动重放；一次性导入并确认 SQLite 接管后，后续只读写 SQLite，旧 `.store` 原样保留且不再读取、清洗或写回，删除以后单独决定。

### 10.12 复盘结论与已接受风险

用户提供的最新评审结论为 APPROVE，Blocking findings: none。该结论覆盖本节方案，实施后仍须逐项取得第 10.11 节的验证证据。

| 复盘结论 | 对实施的约束 |
| --- | --- |
| Agent 交出完整错误后，必须继续闭合产品消费 | 验收观察用户提示与冷历史；仅有类型、复制或透传不算用户价值完成 |
| SQLite 已经随 0.2.8 发布 | 从当前生产接线出发，只追加迁移；过时的阶段文档不作为改写 0001 的依据 |
| 旧格式退役指停止运行时消费 | 成功迁移后只使用 SQLite，旧文件原样保留；删除、指纹证明和覆盖比较不进入本阶段 |
| 清洗后写回旧格式会扩大兼容风险 | 先移除旧文件写回，再扩展 persistence wire；SQL 和当前内存的安全维护继续完整生效 |
| 错误分类与业务 authority 分属不同 owner | 具体文案不改变终态优先级；登录、充值、设置和准备重试均经既有 owner 的显式动作 |

已接受的剩余风险如下，实施中不得将其描述为已经消除：

- 原样保留的 `.store` 可能含有日后才被 MetaWork 识别为 credential 的明文；SQLite 和当前内存会按现有合同清洗，旧副本保持原样。彻底清除旧副本由未来独立删除方案处理，本阶段不补回清洗写入。
- 新 schema 与已安装 0.2.8 共用数据目录时，旧版可能因 `VersionUnknown` 无法读取历史；其禁写和不回退边界必须保持，不宣称旧版可继续消费新库。
- degraded 导入和迁移后旧版本新增的 `.store` 记录可能不在当前 SQLite 视图中；原件保留以供后续找回，不宣称全部迁移或自动合并。

runner 间歇性停滞是独立的未闭合验证问题，状态沿第 10.11 节报告；不将方案 APPROVE、专项通过或单次 Native 通过当作其根因已解决。

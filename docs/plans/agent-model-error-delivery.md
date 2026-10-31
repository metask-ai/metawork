# Agent 模型错误处理与交付方案

日期：2026-10-31。状态：本次 Agent 实施已按用户确认收口；专项验证通过，完整 Native 未通过记录保留。

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

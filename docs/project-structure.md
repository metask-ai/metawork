# MetaWork 工程结构与所有权

> 状态：描述 active tree 的当前结构与可执行边界；不维护目标目录草案或迁移计划

## 1. 文档职责

本文只回答三个问题：代码现在放在哪里、每个目录拥有什么、依赖可以朝哪个方向流动。

- 产品行为以 [产品需求](requirements.md) 为准；
- 系统职责与安全边界以 [高层架构](architecture.md) 为准；
- AgentCore 生命周期以 [AgentCore 集成契约](agentcore-integration.md) 为准；
- UI 行为以 [Workbench UI 设计](workbench-ui-design.md) 为准；
- 验证状态与入口以 [验证规范](validation.md) 为准。

本文不预测尚不存在的文件，不为未来 capability 预建空目录，也不记录已经完成的迁移步骤。结构变化只有在真实职责或不变量形成后才进入本文。

## 2. 当前仓库地图

```text
metawork/
├── docs/                  # 当前规范、验证账本与保留的 artifact migration 证据
├── frontend/
│   └── src/
│       ├── app/           # React composition 与窗口级状态
│       ├── bridge/        # Renderer Bridge client、runtime decoder 与 snapshot transport
│       ├── workbench/     # canonical snapshot store、selector 与纯派生状态
│       ├── features/      # 用户可见 feature
│       ├── components/ui/ # 无业务语义的 UI primitive
│       ├── i18n/          # message catalog、formatter 与 locale runtime
│       └── platform/      # Renderer-only 本地偏好等平台能力
├── src/
│   ├── main.zig           # 进程入口
│   ├── app.zig            # Native composition root
│   ├── account.zig        # Account module entrypoint
│   ├── account/           # OAuth、catalog、credential 与 Account 状态机
│   ├── bridge.zig         # Renderer Bridge module entrypoint
│   ├── bridge/            # command policy、Dispatcher 与 ProductDelivery
│   ├── workbench.zig      # Workbench module entrypoint
│   ├── workbench/         # 产品 projection 与 bounded executor
│   ├── agent.zig          # Agent execution module entrypoint
│   ├── agent/             # Session、event pump 与 callback ownership
│   ├── automation.zig     # compile-time automation selection
│   └── automation/        # enabled/disabled authority capability
├── tests/
│   ├── agent/             # Agent lifecycle invariants
│   ├── workbench/         # Workbench executor/lifecycle invariants
│   ├── integration/       # 跨 owner 竞态
│   └── support/           # deterministic fake 与共享 fixture
├── scripts/               # Node 回归、真实应用编排与 artifact 工具
├── build_support/         # 正式 AgentCore bundle verifier 与 target locks
├── build.zig              # Zig/Native SDK module graph
├── app.zon                # Native window、origin 与 command allowlist
└── package.json           # 工程命令入口
```

`build_support/` 是正式 build graph 的一部分，不是归档目录。一次性 candidate consumer 在临时目录生成；实验 harness、阶段报告和仅为旧验证服务的 fixture 不进入 active tree。

## 3. 顶层所有权

| Owner     | 唯一职责                                                                                                   | 不拥有                                                 |
| --------- | ---------------------------------------------------------------------------------------------------------- | ------------------------------------------------------ |
| App       | Native SDK composition、主线程平台动作、owner 生命周期顺序                                                 | 产品状态、Agent 调度策略、第二套 Bridge transport      |
| Account   | OAuth/catalog 状态、credential、脱敏 Account view、ExecutionConfig transfer                                | Workbench Task、Renderer 状态、AgentCore Runtime       |
| Workbench | Workspace/Task/Run 产品状态、Executor、admission、terminal product record、snapshot projection             | AgentCore raw protocol、Native WebView、Account secret |
| Agent     | AgentCore Runtime/Session/Conversation、callback、event pump、Run terminal facts                           | 产品队列、Task 历史、Bridge transport                  |
| Bridge    | command authority、payload decode、Workspace grant、ProductDelivery connection/revision/snapshot transport | 产品策略真相、AgentCore handle、Account runtime        |
| Renderer  | snapshot 消费、用户交互、纯 UI 状态与本地草稿                                                              | 安全决策、secret、AgentCore raw event、产品状态机      |

`account/contract.zig` 是 Account owner 发布的纯合同，不是第六个产品 owner。`automation/` 只提供受控账号、origin 和临时 Workspace authority，不注册额外协议，也不拥有产品 transport state。

## 4. Renderer 结构

### `app/`

`App.tsx` 是唯一 React composition entry。它组装 feature、选择当前 Workspace/Task，并协调 bootstrap、view-sync 和窗口级错误状态。只有形成可独立测试的不变量时才提取 controller 或 hook；不得只为缩短文件制造 callback 转发层。

### `bridge/`

- `commands.ts` 定义 Renderer 使用的完整命令目录与 Bridge identity/revision；
- `client.ts` 是唯一 `window.zero` command/event 适配入口；
- `decode-contracts.ts` 对所有 Host payload 做 runtime decode；
- `connection.ts` 协调 contract bootstrap、generation、重连与 snapshot refresh；
- `snapshot/` 负责 bounded descriptor、分块读取和 retry，不拥有产品状态；
- `__fixtures__/workbench-snapshot.fixture` 是 Zig serializer 与 TypeScript decoder 共用的 canonical bytes。

Renderer Bridge `metawork.renderer-bridge` revision 1 覆盖完整 command、event 和 snapshot surface；snapshot 不维护局部 schema version。React component 不得直接访问 `window.zero`、拼 wire payload 或解析 AgentCore raw JSON。

### `workbench/` 与 `features/`

`workbench/` 只保存 canonical Host snapshot、selector 和无副作用派生状态。Workspace/Task 生命周期仍由 Host 决定；Renderer 只持有选择、折叠、输入草稿等纯 UI 状态。

`features/` 按用户可见能力分区。feature 通过 `workbench/` selector 消费产品状态，不读取其他 feature 的内部文件。带业务语义的 Timeline、Approval、Composer、Workspace navigation、Search 和 Task activity 保留在各自 feature；真正无业务语义的 primitive 才进入 `components/ui/`。

## 5. Zig 结构

### `app.zig` 与 module entrypoint

`main.zig` 只调用 `metawork_app`。`app.zig` 注入 Native platform capability 并按顺序组织 Account、Workbench、Agent、Bridge 与 automation 生命周期，不复制这些 owner 的状态。

`account.zig`、`bridge.zig`、`workbench.zig` 和 `agent.zig` 是小型公开入口，只显式暴露实际消费者需要的类型、函数或窄 namespace。内部文件不通过 `usingnamespace` 或无边界 barrel 重新泄漏。

### `account/`

- `state.zig` 拥有 Account 状态机、attempt/generation 与 prepare/admit/commit；
- `oauth.zig`、`loopback.zig`、`login_attempt.zig` 和 `network_attempt.zig` 拥有登录网络链路；
- `metask_client.zig` 与 `catalog.zig` 消费锁定的 Metask production contract；
- `credential_store.zig` 拥有持久化 revision、Keychain namespace、双 family slot 与 manifest 原子提交；
- `platform.zig` 只适配 Account 所需的 Native 主线程能力，不形成通用 Desktop Interface；
- `credentials.zig` 管理 execution credential ownership/rotation。

Account 与 Workbench 是同级 owner，只通过纯 `account/contract.zig` 和 App 主线程提交链协作。Bridge 只消费脱敏 view/command contract，不导入 Account runtime。

### `bridge/`

- `dispatcher.zig` 统一拥有 handler registry、callback ingress、authority、payload decode、Workspace grant 与 `*Workbench` command 边界；
- `commands.zig` 定义完整 Bridge identity/revision 和 command catalog；
- `policy.zig` 定义 release/development origin、command 与 builtin policy；
- `handlers.zig` 只定义 bounded wire DTO 和解析；
- `product_delivery.zig` 是 connection generation、revision retry/timer、snapshot identity 和 owned transport storage 的唯一 owner；
- `revision_delivery.zig` 与 `snapshot_delivery.zig` 是 `ProductDelivery` 内部状态，不形成第二个公开 transport；
- `callback_gate.zig` 管理同步 Native callback ingress stop/quiescence；
- `workspace_grant.zig` 管理绑定 window/source 的一次性 Renderer capability，不是持久 Workspace registry。

Bridge handler 不能绕过 Workbench 操作 AgentCore handle。automation 只能驱动和观察真实 `ProductDelivery`，不得注册测试专用 handler 或平行 event/ACK/object 协议。

### `workbench/` 与 `agent/`

`workbench/projection.zig` 当前拥有 Workspace/Task/Run 产品状态、stable Run record、`RunRef`、write-once terminal publication 和 bounded snapshot writer。`workbench/executor.zig` 独占队列、workers、admission 和 shutdown。只有这些职责形成可独立测试的不变量时才拆文件；本文不预先指定未来文件名。

`agent/session.zig` 当前拥有 AgentCore Runtime/Session、Conversation、Run、callback quiescence、UI wait、cancel/close/shutdown 和 immutable `TerminalResult`。`event_sink.zig` 与 `event_pump.zig` 管理 borrowed event 深拷贝、容量和通知。Agent 不接收 Scheduler capability，也不反向 enqueue Workbench。

依赖方向固定为：

```text
main -> app
app  -> account, workbench, agent, bridge, automation, Native SDK
bridge -> workbench, account contract, Native SDK
workbench -> agent, account contract
agent -> Metask AgentCore bundle SDK
account -> account contract, Native SDK platform capability
```

禁止 `agent -> workbench/bridge/app`、`workbench -> bridge`、`bridge -> Account runtime` 和任何产品模块反向依赖 Renderer。

## 6. 测试与构建资产

- 正式 Zig test graph 由 `build.zig` 注册，产品 module 与其测试使用相同依赖边界；
- `tests/agent/` 验证 Session/callback/quiescence，`tests/workbench/` 验证 Executor/admission/shutdown，`tests/integration/` 只保留跨边界竞态；
- `tests/support/` 的 fake 和 fixture 不得升级为产品 owner；
- `scripts/` 可以编排真实应用、Renderer runtime 和 artifact 校验，但不能建立测试专用产品协议；
- `build_support/agentcore_bundle.zig` 与 target lock 是正式信任边界；candidate probe 只使用临时 source-free SDK consumer；
- `app.zon`、Zig commands 和 TypeScript commands 的完整目录必须由集合等式测试保持一致；
- release artifact 必须继续证明 automation credential、origin 和证据 token 被裁掉。

## 7. 结构变更规则

- 先证明新的 owner 或不变量，再拆文件；不为目标树、行数或命名整齐创建空模块；
- 类型跟随拥有其不变量的模块，不建立 `models`、`common`、`helpers`、`services` 或 `managers` 垃圾桶；
- 同一事实只在一个 source of truth 定义，目录文档不复制完整产品或生命周期论证；
- 删除 owner 时同步删除 build graph、allowlist、测试入口和文档引用，不把废弃实现移动到归档目录；
- 目录调整必须保持 Bridge contract、lifecycle、event pump、snapshot、release isolation 和真实 vertical path 的对应验证；
- 不增加 Native SDK adapter、AgentCore facade、平行 Renderer、平行协议或 source dependency fallback。

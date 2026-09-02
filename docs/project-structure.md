# MetaWork 工程结构与所有权

> 所有者：本文定义稳定的 owner/module root、目录 owner、跨 owner 封装边界与允许的依赖方向；仓库文件树和精确 build graph 由文件系统与构建清单机器定义。

## 1. 文档职责

本文只回答三个问题：一个稳定 owner/module root 属于谁、跨 owner 发布什么边界、依赖允许朝哪个方向流动。

本文不维护逐文件目录树、当前实现清单、产品行为、协议字段、测试命令、平台证据、迁移过程或未来目标结构。实际存在的文件以仓库为准，Zig module/import graph 以 [`build.zig`](../build.zig) 为准，工程命令以 [`package.json`](../package.json) 为准。领域语义、验证责任与平台分发规则按 [`AGENTS.md`](../AGENTS.md) 路由到对应真源。

同一 owner 内新增、删除、改名或拆分内部文件，不需要修改本文。只有稳定 owner/module root、目录 owner、跨 owner 封装边界或允许的依赖方向发生变化时，才更新本文。

## 2. 稳定源码根

### Native 与 Zig

| 稳定根 | Owner | 边界 |
| --- | --- | --- |
| `src/main.zig` | Process entry | 只进入 Application composition root |
| `src/app.zig`、`src/app/` | Application | Native SDK composition、平台 capability、资源生命周期和跨 owner 编排 |
| `src/product/account.zig`、`src/product/account/` | Account | Account public module 与内部 aggregate |
| `src/product/control.zig`、`src/product/control/` | Product Control | Product composition、shared execution 与跨 aggregate 编排 |
| `src/product/models.zig`、`src/product/models/` | Product Control 持有的 Models aggregate | Product 通用 Protocol/ModelRef/ExecutionConfig 纯合同、Metask provider/catalog、Provider-local/global selection、Model Connection及其有界 custom model definition registry、metadata provenance、per-model readiness、credential port、持久化与恢复；aggregate root只发布runtime API，不形成新的顶层owner |
| `src/product/agent_protocol_adapter.zig` | Product Control 的 Agent outbound boundary | Product 已开放 Protocol 到 Agent codec Protocol 的唯一穷举映射；无状态且不形成共享 enum 或新 owner |
| `src/product/{mcp,schedule,skill,task,workspace}.zig` 及同名目录 | Product Control 持有的 aggregate | 各自发布窄 public module，不形成新的顶层 owner |
| `src/agent.zig`、`src/agent/` | Agent | AgentCore integration、Runtime、Session、Completion 与 callback/event boundary |
| `src/bridge.zig`、`src/bridge/` | Bridge | Renderer command authority、wire decode 与 ProductDelivery transport |
| `src/storage.zig`、`src/storage/` | Storage | backend-independent SQL contract、backend 与 conformance |
| `src/automation.zig`、`src/automation/` | Automation capability | compile-time authority selection，不形成产品 owner |
| `src/oauth/` | OAuth shared leaf | 只提供 PKCE、secret lifetime、严格 callback 解析与 loopback byte-pump 合同；不拥有 callback path、issuer/resource 接受、limit policy、响应文案或领域错误映射 |
| `src/native_sdk_compat/` | Application | 已登记 Native SDK 缺口的窄 compatibility seam，不形成通用平台层 |
| `src/product_identity.zig` | `app.zon`-derived shared leaf | 把 build-time artifact identity 投影给 Application 及 Models/Account/MCP credential boundary，不形成领域 owner |

`src/product/models.zig` 是 Product Control 构造并持有 Models aggregate 的 runtime root，只发布 `Runtime`、启动错误等 aggregate API；Product Control 可按需要同时精确导入该 root、`src/product/models/contract.zig` 的纯模型合同和 `src/product/models/ports.zig` 的窄 effect port。Application adapter消费 Models contract/port与 Metask provider transport leaf，Task与 Schedule只消费 contract，三条路线不经 root转发。`src/product/account/contract.zig`只发布 Account identity/authorization合同；Account root及内部 module不得导入任何 Models module。`src/product/agent_protocol_adapter.zig`只拥有 Product到 Agent的穷举协议映射，不能承载模型执行配置、推断或通用转换。它们都不是新的顶层产品 owner。`src/product/`只是 Account、Product Control及其 aggregate的目录归属，不发布统一 Product facade。

每个 `*.zig` module root 只显式发布消费者需要的类型、函数或窄 namespace。内部文件不得通过无边界 `usingnamespace`、barrel 或 forwarding facade 重新暴露；build graph 中为隔离测试或依赖形成的 leaf module 不因此取得新的 owner 身份。

### Renderer

| 稳定根 | Owner | 边界 |
| --- | --- | --- |
| `frontend/src/app/` | Renderer composition | React composition、窗口级协调与产品 action wiring |
| `frontend/src/bridge/` | Renderer Bridge client | `window.zero` 的唯一 browser-side adapter、runtime decode 与 connection/snapshot transport |
| `frontend/src/workbench/` | Renderer projection | canonical Host snapshot、selector 与无副作用派生状态 |
| `frontend/src/features/` | 用户可见 feature | 按产品能力分区的交互与呈现，不拥有 Host 领域状态 |
| `frontend/src/components/ui/` | Foundation UI | 无产品语义的基础交互 primitive |
| `frontend/src/components/ai/` | AI presentation | 复用 Foundation UI 的对话呈现 primitive，不拥有 Task、Run 或 AgentCore 语义 |
| `frontend/src/i18n/` | Renderer localization | message catalog、formatter 与 locale runtime |
| `frontend/src/platform/` | Renderer-local capability | browser-side 本地偏好，不拥有原生平台能力 |

React component 不得直接访问 `window.zero`、拼装 Bridge wire payload、解析 AgentCore raw data 或拥有 Host lifecycle。feature 可以消费 `workbench/` selector、`bridge/` typed surface 与共享 component，不得导入其他 feature 的内部文件。`components/ai/` 可以向下依赖 Foundation UI 和共享 Renderer 工具，不得反向导入 `features/`、`workbench/`、`bridge/` 或 `app/`。

### 支撑根

| 稳定根 | Owner / purpose |
| --- | --- |
| `tests/agent/`、`tests/product/` | 对应 owner 的 external Zig test root |
| `tests/integration/` | 无法归属单一 owner 的跨边界失败模式 |
| `tests/support/` | test-only fake 与 fixture，不形成产品 owner |
| `tests/fixtures/` | 由测试或 probe 启动的外部进程与协议 fixture，不形成产品 owner |
| `scripts/` | 工程编排、回归和 artifact 工具，不形成产品协议 |
| `build_support/` | 正式 build graph helper、AgentCore verifier 与 target lock |
| `packaging/` | 平台分发输入；具体合同归平台分发文档 |
| `assets/` | 品牌与平台用途源资产；语义归 UI 与平台分发文档 |

生成目录、缓存、stage、candidate consumer 和临时 probe 不是源码 root，也不得成为依赖真源。canonical `.agentcore/bundles/<target-id>` 是已验证的外部依赖 stage；正式产品只有 Agent module 可以消费其中的官方 SDK。

## 3. Native 依赖方向

正式顶层依赖方向为：

```text
main -> application
application -> account, models capabilities, product control, agent, bridge, automation, Native SDK
application -> native_sdk_compat
application -> product identity
application, account -> OAuth shared mechanics and loopback contract
bridge -> product control, account contract, Native SDK transport contract
product control -> agent through product agent protocol adapter, account contract, models root/contract/ports
account -> account contract, OAuth mechanics/loopback contract
task, schedule -> models contract
models, account credential boundary -> product identity through Application adapters
agent -> Metask AgentCore bundle SDK
automation -> bridge policy, account contract, Native SDK policy types
storage backend -> SQLite amalgamation
```

Application 只做 composition、capability 注入、资源生命周期和跨 owner 调用顺序，不读取领域内部状态形成 policy。`app/`、`product/`、`agent/` 与 `bridge/` 的下层 owner 都不得反向导入 Application 实现。

Product Control 可以消费 Agent、Account 与 Models 的纯合同，并可构造 Models aggregate，但不得导入 AgentCore SDK、Account Runtime、Bridge 或 Renderer。Models contract/registry/runtime/provider 不得反向导入 Account 或消费方；Account root/contract/state/runtime不得导入 Models root/contract/runtime/ports/provider。Application可以同时组合两者并把一次 Account authorization lease交给 Metask catalog worker，但不得因此建立领域反向边。Task与 Schedule不得通过 Account取得模型执行类型，也不得导入 Models runtime/root/ports。Bridge可以消费 Product Control public surface、Models command/view、Account脱敏合同与 Native SDK transport contract，但不得持有 Account Runtime、AgentCore handle、`PlatformServices`、OS handle或具体平台实现。Agent不得导入 Product Control、Models、Bridge、Application或 Renderer。`product_identity.zig`只消费 `app.zon` manifest与 build-time artifact option；Application的 Models/Account/MCP credential adapter可以读取其派生 identity，但它不得反向依赖领域模块。Storage contract不依赖 Product、Application、Native SDK或 SQLite C类型；只有 concrete backend可以依赖 SQLite。

OAuth shared leaf 不发布统一 OAuth flow 或业务 policy。Account 与 Application MCP OAuth 可以消费其 mechanics/loopback contract，但必须各自拥有 callback path、redirect/issuer/resource 接受规则、大小和 invalid-request budget、用户响应与错误映射；MCP 不得导入 Account 私有 OAuth 或 loopback policy。

`src/native_sdk_compat/` 中每项 seam 必须由 Application 显式组装，只暴露对应缺口所需的窄 capability。它不得成为 Native SDK adapter、Desktop Interface、通用 facade 或下层 owner 的反向依赖入口；SDK 提供等价正式能力并完成验收后，应删除对应 seam、allowlist 和专用验证。

精确 module imports 由 `build.zig` 强制，本文不复制内部 leaf graph。跨 owner import 必须符合上述方向，并只消费发布者显式暴露且由 build graph 具名注入的 root、contract、port 或窄 leaf；具名 leaf 不因此取得新的 owner 身份。

## 4. 文件放置与封装规则

- 类型和状态跟随拥有其不变量与生命周期的 owner；effect interface 由需要该 effect 的 owner 定义，由 Application 绑定具体平台实现。
- 只有形成独立 owner、公开边界或可单独测试的不变量时才拆 module；不为行数、命名整齐或未来 capability 创建空层。
- 不建立无 owner 的 `models`、`common`、`helpers`、`services` 或 `managers` 聚合目录；真正跨 owner 的纯合同必须有明确发布者和消费者。
- feature、aggregate 和 compatibility seam 不得借目录位置升级为新的顶层 owner，也不得建立平行协议或统一 facade。
- 测试优先与实现共置；external test 进入对应 owner root，只有跨 owner 失败模式进入 `tests/integration/`。测试目录不能反向决定产品 owner。
- 删除 owner 或 public root 时，同步删除 build graph、allowlist、测试入口和规范引用；不把失去职责的实现移动到 active archive。
- 目录搬迁不得顺带改变领域合同。若同时改变 owner、public surface 或依赖方向，必须按对应真源与验证 Gate 一并收口。

## 5. 文档更新 Gate

以下变化需要更新本文：

- 新增、删除或重命名稳定 owner/module root；
- 目录转移到不同 owner；
- public module 的封装责任发生变化；
- 顶层允许或禁止的依赖方向发生变化；
- 新增或删除正式 compatibility seam 根。

以下变化不需要更新本文：同一 owner 内的文件增删改名、内部 helper 或 leaf module 调整、测试文件变化、build command 变化、artifact refresh、实现进度和 capability 状态变化。它们分别由代码、构建清单、测试或对应领域真源承担。

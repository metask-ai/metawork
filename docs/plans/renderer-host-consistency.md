# Renderer 与 Host 一致性调整方案

Renderer 发产品命令，Host 返回结果并发布状态，Renderer 据此更新界面。沿用 Native SDK、既有 Bridge 和 Snapshot，减少运行产物错配与重复定义，不重建通信框架。

本文是实施计划，不是 decision record。用户已授权通过 goal 实施，并在范围复核后明确选择：**保留必要修复与 SnapshotDescriptor/TaskApprovalResult 小对象试点，撤回大块迁移。** 本文按这次选择收敛；整个 Snapshot 的结构派生不再属于本轮完成条件。

## 1 问题与证据边界

同一结构原由 Host JSON 输出、Renderer 类型和结构 decoder 分别手写。开发时 Renderer 可随 Vite 更新，Host 则继续运行启动时构建的程序，存在源码表达与运行产物两类漂移风险。

本机已实际复现混装：共享输出里的 Host 已发布 queued input 字段，但其 index.html 引用的旧 Renderer 尚不接受这两个字段。使用现存产物，通过官方 SDK 临时打包、签名并启动，实际窗口在 `$.tasks[0]` 拒绝字段集合；标准 `npm run build:debug` 成套重建后，同样历史任务恢复加载。未修改用户历史数据来使样本通过。

原截图的 Renderer 已要求 queued input 字段，差异方向不同，不能声称原截图也缺少这两个字段。当时没有实际字段差异与运行来源，原截图的逐字段根因仍未确定。本轮不增加原始 payload 留存或诊断服务，也不等待用户复现才处理已确认的问题。

另有两处实际源码不一致，各有修复前失败的独立回归：

- Compact 的 `interrupted` 已存在于 Host 和 Renderer 类型，手写 decoder 值目录却遗漏；恢复历史时会拒绝该状态。
- 附件 store 或图片能力不可用时，Host 发布 `enabled=false`，却仍发布图片格式列表；Renderer 按既有规则拒绝这种组合。

历史上还存在 Host Snapshot 容量提高后 Renderer 上限未同步的遗漏。这说明人工同步点确有风险，不证明历次报错来自同一原因。

## 2 本轮保留的实现

### 准确且有界的诊断

报告对象路径、缺少的已知字段及额外字段数量，替换整段预期字段清单。字段名称条数与总长度有界，不输出任意输入 key、字段值、原始 JSON 或未知 enum 原文，不自动推断版本错配。

启动主提示使用“无法加载 MetaWork”等用户可以理解的描述；字段差异收入技术详情。保持既有快照拒绝、显式重连与整页阻断政策，不猜默认值、不吞未知字段、不重放命令。

### 成套构建与固定资源

默认 `npm run dev` 验证 canonical bundle 与当前平台前置条件，构建静态 Renderer、构建 Debug Host 并部署资源，验证最终位置的 macOS 稳定签名，再启动新 primary。默认入口不启动独立 Vite 热更新；开发循环改为退出后重新构建。

Renderer 输出、Native install prefix 和部署资源从一开始就使用本次独立目录，不先写共享输出再复制。沿用 executable 相对资源布局与官方 SDK，不新增打包器、artifact registry、全仓指纹、常驻 watcher 或原子源码快照机制。运行目录在进程存活期间保持不变，后续构建使用另一目录。

启动环境排除前端 URL/HMR 覆盖，Office、archive、Skill 开发配置与 credential namespace 沿用原规则。构建、部署、依赖或签名缺失时明确失败，不能启动旧产物。

沿用 Application 单实例 owner，开发启动必须取得新 primary；已有同身份实例时明确失败，不把激活旧窗口算作新构建成功。普通产品重复打开行为保持不变，不删除锁或停止其他实例。脚本只管理自己的子进程，正常退出后清理自有目录；异常退出无法证明全部后代停止时保留资源，不新增清理服务。

### 两处缺陷的最小修复

Compact 的 Renderer type 与 decoder 共享一个值目录，包含既有 `interrupted`，不迁移整块 Compact。Host 按附件是否可用发布完整格式列表或空数组，保留 Renderer 原有组合校验，不迁移整块 Capabilities。

### 两个小对象的结构试点

仅将 `SnapshotDescriptor` 与 `TaskApprovalResult` 的字段、基础类型、nullable、enum 和明确整数编码交给发布 owner 的纯 Zig wire 类型。实际 Host serializer 消费同一定义，构建期派生 Renderer 类型与基础结构 decoder；共享运输限制由 Bridge 定义并派生到 Renderer。

Product 不反向依赖 Bridge、Renderer 或 Native SDK。生成器只消费纯合同，不加载 Product Runtime 或 AgentCore Session。只保留试点使用的编码支持，不建立独立 schema 语言、运行时服务、插件或文本/数组投影框架。不支持的编码在构建时明确失败。

`dev/build` 更新生成结果，`check/test` 确定性拒绝过期结果；生成文件随源码提交，不能手写维护。业务关联和审批结果的成功/失败语义仍由原校验执行。实际两端与独立拒绝用例共同验证，不能只证明生成器自洽。

## 3 已撤回与不再扩展的范围

Account、Models、RunOutput、权限历史、FileChanges、Binding、ConversationContext、Capabilities、Automatic Workspace root 和 NewTaskAdmission 等大块结构迁移已撤回；相应手写投影与解码路径恢复。与这些迁移绑定且已无独立职责的生成注册、纯类型、文本/数组适配、枚举搬迁和新增 fixture 一并删除，没有保留平行 active path。

原有脱敏、容量预算、文本回调、借用生命周期与业务校验保持原路径。独立的 Compact 与附件缺陷回归保留。实施期间对定时任务键盘测试的额外时序修改已撤回。Skill 仅做过阅读，未实施迁移。

其余 Snapshot 对象仍有手写同步点；本轮不能宣称全部消除。命令/事件整体生成、审批 UI 布局、Run 业务、恢复政策、全屏阻断与持久化迁移均不属于本轮。

## 4 验收与完成条件

按[验证规范](../validation.md#标准入口)执行：

1. Renderer typecheck、生成新鲜度与受影响 suite 通过。两个试点的必填、额外字段拒绝、nullable、enum 和精确整数编码保持成立。
2. 正式 Native test graph 通过；实际 Host serializer 与 Renderer decoder 通过跨语言 fixture 对照，独立的 Compact 和附件回归有效。
3. 成套开发入口的目录隔离、环境清理、构建失败不启动旧产物、primary 判定、退出与资源清理有对应证据。
4. macOS 当前代码的成套产物完成真实窗口验收：新任务页、既有任务与历史内容可以加载，最终位置签名有效，正常 Quit 后清理自有目录。只看到构建成功或连接受理不算加载通过。
5. 检查迁移残留、生成注册、导入、文档链接和格式；不保留已经失去职责的迁移材料，也不丢弃仍承担缺陷回归职责的样本。

本轮按用户要求不验收 Windows；这不改变产品的平台支持合同。canonical bundle 或签名缺失必须明确失败，不得降级。原截图缺少当时的实际字段差异与运行来源，保留这一证据限制，不将推断冒充根因结论。

## 5 合同与状态

Bridge revision 1、command allowlist、Native SDK upstream-only 政策、权限语义、持久化格式、产品 identity 与 `AGENTS.md` 保持不变。长期合同只在[Renderer Bridge 合同](../renderer-bridge-contract.md)、[验证规范](../validation.md)、[macOS 分发](../macos-distribution.md#开发入口)与[UI 设计规范](../ui-design.md)中定义；本计划不成为第二份规范。

2026-10-15，基线 `e03a4cfbb941bf29537b589c92cfec9c942fb4cd` 上的本次工作树已完成上述收敛。撤回后重新执行 `npm test`、`npm run check`、`npm run format:check` 和定向合同测试，均通过；`npm test` 同时完成 Node 与正式 Native graph。另实际改动生成文件，确认新鲜度检查明确拒绝，恢复原内容后再次通过。迁移残留搜索、计划链接及 `git diff --check` 通过。

同日用当前代码、canonical staged AgentCore 与既有 Apple Development identity 构建并签名 macOS 成套产物，经官方 SDK 临时打包，在 `run-wGG0qV` 验收窗口确认新任务页、既有任务列表与对话历史正常加载；通过系统 Quit 正常退出后，进程返回成功，自有运行目录已删除。该窗口存活期间另执行标准 `npm run dev`，本次独立产物完成构建与签名后明确返回 `DevelopmentInstanceAlreadyRunning`，没有激活旧窗口或将其计为成功；该次异常输出按既有保留政策处理。账户凭据、默认配置与任务内容未作修改。

未迁移 Snapshot 对象仍由既有手写结构和测试维护，不宣称全面派生；原截图的精确逐字段根因仍受第 1 节证据边界限制。

2026-10-16 复盘发现开发取消逻辑在自有子进程忽略 SIGTERM 时会无限等待。独立回归在修复前因取消未完成而失败；加入有限宽限期后的自有进程组终止兜底后通过，原取消/失败时保留资源与正常退出清理的回归也通过。完整 Node 回归与格式检查已通过，原有平台跳过保留。

标准 `npm run dev` 的成功启动、Bridge smoke ACK、退出及目录清理已另行验证；此前临时打包产物的界面验收不能完整代替标准入口的页面观察。桌面工具无法绑定标准入口启动的裸可执行文件，故该路径的新任务页与历史内容的直接界面确认仍待补齐，不再把这一点标作已完成。

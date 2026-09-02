# MetaWork 验证规范

> 状态：持续维护；本文拥有测试归属、标准验证入口、平台证据状态、长期证据和未闭合验证缺口

本文是验证控制面，不是产品、架构或实现清单。它只回答四个问题：依据哪份规范验证什么、由哪个测试层负责、证据达到什么状态、还缺什么。产品行为以[产品需求](requirements.md)为准，UI 交互与呈现以[UI 设计规范](ui-design.md)为准，系统边界以[高层架构](architecture.md)和[Product 架构](product-architecture.md)为准；各项 wire、ABI、Storage 和平台分发合同由对应真源定义。

测试文件名、实现路径、逐项断言、当前数量和机器可判定 artifact identity 由 test graph、源码、manifest、lock 与 verifier 负责，不在本文建立第二份目录。只有测试层或归属规则、标准入口、证据状态、长期证据或未闭合验证缺口变化时才更新本文。

## 状态与证据纪律

| 状态 | 含义 |
| --- | --- |
| 已验证 | 在精确 revision、平台和 artifact 上有可定位执行证据；不自动证明后续 revision |
| 自动化已覆盖 | 当前 test graph 有绑定到该不变量的确定性测试；不等同于真实平台或外部服务验收 |
| 人工验收待完成 | 实现或自动化可能存在，但真实窗口、平台、可访问性或产品判断尚无完整证据 |
| 尚未实现 | 只有需求或架构边界，不得从当前 baseline 推导为可用能力 |

状态必须绑定证据，不能仅凭代码存在、关键词扫描或历史对话升级。一次执行的证据至少绑定日期、MetaWork revision、目标平台、被测 artifact 或外部依赖、执行入口和结果；缺少任一关键维度时，只能作为线索，不能关闭 Gate。

普通确定性测试由当前 test graph 重现，不进入长期证据账本。只有无法由普通自动化稳定重现的外部服务事实、真实平台行为、签名或分发 artifact 验收，以及影响长期架构选择的一次性实验，才保留独立证据。历史证据可以由精确 Git object 保存，但不得覆盖 active source of truth，也不得证明后续代码或替换后的 artifact 仍然通过。

## 测试归属

测试按失败模式和 owner 归属，不按文件类型或调用路径堆叠。新增或修改测试前，必须能说明它保护哪份真源中的哪条可观察不变量、失败时唯一指向什么问题，以及哪个测试层能以最小充分成本观察该问题。只有失败必须跨越两个以上 owner 才能出现时，才进入 integration 层。

| 层级 | 唯一职责 |
| --- | --- |
| Zig inline test | 单模块纯状态转换、codec、容量与资源所有权不变量 |
| Storage conformance | backend-independent SQL contract 与 concrete backend 的事务、profile、limits、lifecycle、故障分类及 child-process WAL/crash recovery |
| `tests/agent/` | Agent Runtime、Session、callback、ABI 消费、生命周期与并发 |
| `tests/product/` | Product aggregate、事务、持久化、恢复与产品并发 |
| `tests/integration/` | 必须跨两个以上 owner 才能出现的组合失败 |
| Renderer / Node | 通过函数、DOM、SSR 或跨语言 fixture 观察的 Renderer、Bridge client 与工程脚本行为 |
| architecture guard | owner 依赖方向、禁止依赖、module graph、稳定 allowlist、catalog 一致性和 test graph 接线 |
| probe / platform acceptance | candidate artifact、外部依赖事实、真实窗口、系统服务、签名和平台生命周期 |

一个测试可以用多条断言证明同一个失败模式，但不能把独立失败模式塞进同一场景。同一合同可以在不同观察边界保留测试，例如纯状态转换与线程 quiescence；若 owner、失败模式和观察边界都相同，只保留一个权威失败点。删除疑似重复的并发或 lifecycle 测试前，应临时破坏对应不变量并确认保留侧会失败。

源码扫描、文件存在性和关键词 guard 只能证明结构边界，不能替代产品行为、响应式布局、运行时顺序、真实平台或 shutdown 验收；architecture guard 也不得用测试数量代表覆盖充分性。一次性 probe 只在答案仍会改变 active contract、实现决策或验证 Gate 时保留；结论进入合同、持续回归或长期证据后，或者 active contract 已对所有可能结果安全且该问题不再控制任何决策时，应从 active tree 删除不再承担职责的资产。

## 标准入口

平台无关的仓库验证入口是：

```bash
npm ci
npm run format:check
npm run check
npm test
```

`npm test` 必须校验 canonical staged AgentCore bundle、执行 Renderer typecheck，并运行自动发现的 Node tests 与正式 Native test graph。Node 和 Native 阶段都必须得到结果；一侧失败不得遮蔽另一侧。bundle 缺失或不匹配时必须明确失败，不能跳过 AgentCore 用例后报告成功。

candidate probe、真实桌面验收、签名、公证和发布验证不属于 `npm test`，也不得被其结果替代。定向入口只缩短开发反馈；提交前仍运行能覆盖受影响失败模式的完整关联 root。

| 范围 | 标准入口 | 说明 |
| --- | --- | --- |
| 单个 Node / Renderer suite | `node --test scripts/<suite>.test.mjs` | 只用于单一失败模式 |
| Agent / Product lifecycle | `node scripts/run-lifecycle-tests.mjs` | Session、Product、恢复、并发和 shutdown |
| 单个 Native owner | `zig build <registered-test-step>` | 精确 step 由 `build.zig` 注册 |
| Storage 基础层 | `zig build test-storage` | SQL conformance、SQLite backend 与 child-process WAL recovery；优化级别与平台要求见 [Storage 基础层验证](#storage-基础层验证) |
| AgentCore staged candidate | `node scripts/verify-staged-agentcore-bundle.mjs` 后运行相关 `run-agentcore-*-probe.mjs` | verifier 证明接受条件，probe 证明候选行为；二者不能互换 |
| Agent Session 多模态输入 | `node scripts/run-agentcore-provider-test.mjs --staged --host` | 真实 Host 消费 canonical bundle，验证 provider 图片/PDF 块、连续历史、typed 拒绝与 opaque checkpoint 恢复；当前 fixture 中 Anthropic 接受 PDF，Responses、OpenAI Chat 与 Gemini 明确返回 `document_input_unsupported`；不等于远端模型视觉或文档理解质量验收 |
| Windows development baseline | `node scripts/run-windows-bringup.mjs` | Windows 真实 vertical 与关联回归的组合入口 |
| Windows Model Connection readiness | `node scripts/test-model-connection-readiness-windows.mjs` | 使用隔离 automation identity，但不注入 Account/Models fixture；通过真实原生 secure capture、Windows Credential Manager、本地 HTTP Provider、signed-out Task create/run 与 clean shutdown 验证完整 capability gate；执行时会短暂显示并自动提交一个原生凭据输入窗 |
| macOS desktop vertical | `node scripts/test-agentcore-vertical-macos.mjs [aarch64-macos\|x86_64-macos]` | 无参数绑定当前 Host target；显式参数在 Rosetta 可用时分别证明所选 artifact，不替代 Intel 真机专项验收 |
| macOS 分发 | `npm run package:macos` | 具体签名、公证和 artifact Gate 见 [macOS 分发](macos-distribution.md) |
| Windows 分发 | `npm run package:windows` | 具体安装器、签名和 artifact Gate 见 [Windows 分发](windows-distribution.md) |

## 变更验证 Gate

选择能观察真实失败模式的最小充分验证层；文件位置不能反向决定 owner，也不因脚本名、lock 路径或构建文件变化机械扩大平台矩阵。

| 变更类型 | 最小充分证据 |
| --- | --- |
| 纯文档删除或改写 | 链接、锚点、残留引用和 `git diff --check` |
| Renderer 内部行为 | typecheck 与受影响的 Renderer suite |
| Bridge wire 或跨语言合同 | Renderer/Host 两侧 fixture、合同测试与相关类型检查 |
| 单一 Zig owner 内部实现 | 对应 test root；共享 owner 或 module graph 变化追加正式 Native graph |
| owner、依赖方向、allowlist 或 test graph | architecture guard 与能命中该违规的正式 test root |
| Account / Models owner 边界 | architecture guard 证明 Account 与 Models 不互相 import；Models/Account 各自的 Native test root，并以组合测试证明 Account 授权丢失只使 Metask provider 对新 catalog/resolve 进入 `needs_authentication`，不影响 custom source 或既有 Task/Run binding |
| AgentCore ABI 接受政策或 candidate artifact | staged verifier、相关 probe；行为或 artifact 变化时追加受影响目标平台 vertical |
| lifecycle、异步队列、真实 ProductDelivery 或平台能力 | 对应 lifecycle/vertical；存在独立平台失败模式时分别取证 |
| 签名、公证、安装器或分发合同 | 对应平台分发入口及合同要求的真实 artifact 验收 |

AgentCore runtime assets 的验证必须覆盖 manifest declaration、执行文件和许可证缺失/篡改、构建和 runtime package 部署，以及不依赖开发机外部 rg 的真实 Glob/Grep。source-free probe 显式绑定候选 bundle 自带的 rg；桌面 vertical 验证 Host 同目录部署，不能让环境中的 rg 掩盖漏包。

Model Connection的最小充分证据必须覆盖：有界非空custom model集合的add/replace/remove及最后成员拒绝；source-qualified identity与connection/source/catalog revision漂移；probe开始后metadata/catalog变化使completion stale；成功proof后的失败重测不撤销同一source generation readiness；authority变化清除全部旧proof；canonical store恢复metadata/provenance/per-model readiness；Renderer revision 1严格拒绝旧混合generation payload。首版UI继续只验证单模型创建表单，不以未开放的多模型编辑界面替代底层与wire验证。

Schedule 模型绑定与 schema migration 的最小充分证据必须覆盖：schema 2 对 `ModelRef + source_generation + selection_revision + protocol` 的严格 round trip 与旧 wire 拒绝；schema 1 全量保留定义/occurrence 事实但转换为 disabled `binding_migration_required`，显式保存后才形成可执行绑定；迁移 commit 的 committed、明确失败、outcome unknown 后观察 old/new/第三态；`migration_failed` 保留原 canonical 且不开放 hard reset；default A→B→A 被 selection revision 拒绝；同一 Metask source authority 冷启动即使 Product generation 改变仍可触发；Metask authorization 丢失停止新的 resolve/occurrence而 custom source和既有 Task/Run binding不受影响。Bridge/Renderer fixture必须同时固定 bound/migration 两种判别 shape以及 create/update 的 source-qualified payload。

artifact refresh、checksum 或 lock 更新本身不要求修改本文。精确 target identity 以 `build_support/agentcore-bundle.*.lock.json` 为准，ABI 接受语义以 [AgentCore ABI v1 合同](agentcore-abi-v1.md)为准；verifier 必须报告它实际读取的 identity，文档和脚本不得硬编码一份“当前值”。替换 artifact 后，旧 artifact 的行为证据、checkpoint 样本和平台通过结论不自动继承；必须对新 artifact 重新运行相关 verifier、probe 或 platform vertical。

PermissionProfile 的最小充分证据必须跨越实际 owner：candidate probe 固定所采用 `PermissionMode + ShellPolicy` 的代表性 tool/effect 行为；Agent tests 固定配置编码、typed request/provenance、same-profile fresh/restore 与 noninteractive stop fact；Product lifecycle 固定默认值只影响新 Task、Task/Run provenance、archive/delete，以及 Scheduled occurrence 由生产 event consumer 自动 abort 后形成 `permission_required → needs_attention`；Renderer/Bridge tests 固定 capability gate、只读 effective profile、单次选择动作和合法历史 snapshot。Schedule definition update 只影响后续 occurrence，不能改写历史 Task profile 或使 Renderer 拒绝合法 snapshot。`standard` 在 typed risk/effect 和执行前 commit boundary 未经独立 fixture 证明前必须保持隐藏。

File Changes 的最小充分证据必须跨越实际 owner：Agent lifecycle 固定 oversized/capacity degradation 只命中 classifier-confirmed `file_changes` 并发布 monotonic loss fact；Product lifecycle 固定协议矩阵、stable order/dedup、depth、容量、redaction、artifact identity、恢复/orphan/delete/shutdown；Bridge/Renderer 固定严格 DTO、capability gate、异步 stale response 和响应式审查视图；真实 AgentCore desktop vertical 必须由 canonical bundle 的 Edit/Write 产生 typed observation，并通过 `metawork.files.diff` 读回已记录 diff。静态 fixture、Tool 文本、Workspace 扫描或 Git diff 不能替代该纵向证据。

## Storage 基础层验证

[Storage 架构](storage-architecture.md)拥有 SQL、权限、migration、事务结果和 lifecycle 合同；本节统一拥有其验证责任、入口与平台证据边界，不复制实现清单或测试数量。

基础层验收必须覆盖以下失败模式，具体用例由当前 test graph 拥有：

- backend-neutral fake conformance 与 memory SQLite integration，覆盖输入校验、借用 row 和 terminal failure 前的 provisional delivery；
- 文件 reopen、WAL/FULL、profile 与 limits；设置未生效必须 fail closed；
- transaction/savepoint、DDL、PRAGMA 和 metadata 越权，包括关联 schema 对象及持久化 trigger/view 的间接访问；
- expected-changes conflict、完整 batch rollback、引擎自动回滚、真实写入取消和 COMMIT 阶段 constraint；同时验证已知事务结果与连接可用性，不以 poison 代替结果分类；
- migration prefix/checksum、unknown version、非法 metadata、schema 与 identity 原子回滚，以及提交前持久化身份序列的后置条件；
- busy、constraint、cancel、resource、corrupt 和 outcome-unknown 分类；故障注入不能替代能稳定触发的真实引擎失败；
- blocking no-spin concurrency、排队 caller、callback 重入拒绝、并发 shutdown 与 interrupt 收敛，以及 destroy 前 caller quiescence；
- child-process crash 后 reopen/hot-WAL recovery；
- architecture guard 证明 Storage 没有进入 Application/Product graph。

专用入口分别运行默认 Debug、`-Doptimize=ReleaseSafe` 与 `-Doptimize=ReleaseFast`。正式 Native graph 和 `test-storage` 必须复用同一 Storage runner 与 crash fixture；fixture 缺失必须失败，不得静默跳过。共享 owner 或 module graph 变化仍须运行正式 Native graph，专用入口不替代仓库级依赖验证。

基础层交付要求 Windows 原生文件数据库 suite，以及 macOS arm64/x86_64 的 Storage test root 与 crash fixture 在上述优化级别的编译验证。macOS 原生文件数据库、并发、取消和 crash recovery 运行证据尚未完成，是非阻塞的后续平台验证，不阻塞本次基础层交付；交叉编译不得表述为原生运行已验证，也不得借此关闭其他 macOS 产品或分发 Gate。

child-process 非正常退出证明进程终止后的 WAL 恢复，不是机器断电或磁盘故障实验。基础层结果也不证明 Application/Product 已接入、现有数据已迁移或产品恢复已验收。普通可重现结果绑定执行时的 revision，不在长期证据账本重复登记。

## Native SDK 兼容能力证据

[高层架构](architecture.md#35-native-sdk)拥有兼容 capability 的 identity、允许边界和删除条件；[工程结构与所有权](project-structure.md)映射其 module root 与依赖方向。本文只登记平台证据和未闭合验收，不复制实现路径、低层 symbol 或 allowlist。

| capability | Windows 状态 | macOS 状态 | 证据定位 | 未闭合验证 |
| --- | --- | --- | --- | --- |
| `system_webview_drag_region` | 已验证：普通拖动和最大化拖动恢复；人工验收待完成：edge snap、双击标题栏、系统菜单、touch/pen | 人工验收待完成：真实窗口行为 | `E-WIN-COMPAT-20260820` | 两平台分别取得 Native SDK 正式能力的等价行为证据 |
| `system_webview_maximize_restore` / `maximized_state` / `user_close` | 已验证：controls、maximize/restore、hide/reopen 与 clean shutdown | 不适用于已登记兼容 seam | `E-WIN-COMPAT-20260820` | Native SDK 正式能力在 Windows 通过等价验收 |
| `secure_input` | 已验证：Unicode、确认/取消、真实 Run、clean shutdown，以及 UIA password、ValuePattern 不可读与 2.5 秒 modal responsiveness；阶段 R 由用户暂时放行 | 人工验收待完成：编译、modal、VoiceOver 明文检查和 shutdown | `E-WIN-COMPAT-20260820`、`E-WIN-MODEL-CONNECTION-PROVISIONAL-20260902` | Windows signed-out create→probe→select→run 的一次完整可见重跑仍延后；macOS 全部真实平台 Gate |
| `app_single_instance` | 已验证：多进程仲裁、activation 转交、restart 与 crash 后 lease 恢复；人工验收待完成：交互失败与安装升级 | 已验证（历史）：交叉语义编译；人工验收待完成：socket 权限、peer identity、并发转交、提示、shutdown 和 crash recovery | `E-WIN-SINGLE-20260828`、`E-MACOS-SINGLE-COMPILE-20260828` | 两平台分别取得完整实例仲裁与 activation 验收 |
| `macos_icon_composer_package` | 不适用 | 自动化已覆盖：源结构与编译输入输出；已验证：历史本机 `actool` compile；人工验收待完成：签名、公证和视觉 | `E-MACOS-ICON-20260825` | Developer ID、DMG、公证、macOS 26 明暗视觉和旧系统 fallback |

以下不是可长期豁免的 capability：Application adapter 中仍存在 Runtime 已覆盖能力的直接低层调用，main-loop `wake` 也尚未完成 SDK 缺口确认与独立 seam 登记。它们在架构收口、结构 guard 和对应线程、行为、shutdown 证据全部完成前，仓库级兼容 Gate 保持打开。单项兼容能力通过不能证明全仓低层能力路径合规。

## 平台与 artifact 状态

各平台结果互不替代；跨平台确定性回归通过只证明共享逻辑。artifact kind、产品 identity 与 target lock 是机器真源，macOS/Windows 的构建、签名和分发流程分别由平台分发文档拥有。

| 目标 | 状态 | 未闭合证据 |
| --- | --- | --- |
| macOS arm64 | 已验证（`E-MACOS-ARM64-PACKAGE-20260901`）：revision `93075d3` 的 desktop vertical 与 Developer ID signed/notarized DMG；历史真实 Metask Account 证据见 `E-METASK-20260720-0810` | DMG 拖拽安装与首次启动、Keychain 跨重建授权、兼容能力、可访问性和真实 UI 交互仍须分别取证 |
| macOS x86_64 | 自动化已覆盖：target-specific artifact 接受由 lock 与 verifier 控制；人工验收待完成：真实 desktop | 真实 desktop vertical |
| Windows x86_64 GNU | 已验证（历史，`E-WIN-COMPAT-20260820`、`E-WIN-SINGLE-20260828`、`E-WIN-X64-PACKAGE`）：development capability 与 signed installer 隔离安装/卸载 | 受影响 revision/artifact 的 development vertical，以及交互式安装、开始菜单、驻留升级与 Windows 10/11 矩阵 |
| Windows arm64 GNU | 已验证（历史，`E-WIN-ARM64-PACKAGE`）：Native Release、安装包生成和签名；人工验收待完成：真实运行 | 真实 AgentCore vertical、安装启动与平台行为 |
| Linux | 尚未实现 | 构建、运行、分发和平台验收均未开始 |

macOS 的 AgentCore artifact、Native vertical、Keychain、secure input、window chrome、WebView 可访问性与分发 artifact 是独立证据项。Windows development baseline 不证明安装、更新、完整安全矩阵或其他平台；程序化 resize 不证明真实 pointer resize、系统 snap 或焦点行为。签名成功只证明被测二进制和签名 policy，不证明安装启动、交互、更新、回滚或迁移。

## 长期证据账本

| ID | 证据 | 规范真源 | 定位 | 结论与有效范围 |
| --- | --- | --- | --- | --- |
| `E-METASK-20260720-0810` | Metask Account 与真实 AgentCore Run | [产品需求](requirements.md)、[Account 架构](account-architecture.md) | `git show dbaaf81b0217d4016944960ee8621e9a23274f05:docs/phase-0-validation.md` 中 2026-07-20 记录；`git show 458daf7e737d3206ab9026bd6c31d4617fbc2911:docs/validation.md` 中 2026-08-10 复核 | 前者证明当时打包 `.app` 的 OAuth、catalog、execution persistence 与两个真实模型 Run；后者证明 production `/me` 与无 Profile-ID catalog 路径。均不证明后续 UI、平台或代码仍通过 |
| `E-FAULT-DOMAIN` | fault-domain 方向 | [高层架构](architecture.md) | `git show dbaaf81b0217d4016944960ee8621e9a23274f05:docs/phase-0-gate-7-report.md` | 独立 crash 对照证明同进程没有进程级隔离，并支持选择单 AgentCore Worker；不证明 Worker 已实现 |
| `E-WIN-COMPAT-20260820` | Windows window chrome 与 secure input | [高层架构](architecture.md)、[UI 设计规范](ui-design.md) | `git show 77e2f99d5672bf31a55d512aa2a7a431fd1779ab:docs/validation.md` | 2026-08-20 记录证明当时 Windows drag、controls、secure input、真实 Run 与 clean shutdown 的已列子集；不证明未列交互或后续 revision |
| `E-WIN-MODEL-CONNECTION-PROVISIONAL-20260902` | Windows Model Connection 阶段 R 暂时放行 | [产品需求](requirements.md)、[Product 架构](product-architecture.md)、[UI 设计规范](ui-design.md) | 2026-09-02；MetaWork revision `52f54e3`；`npm run check`、`npm run format:check`、相关 Node/Renderer Gate、`zig build test --summary all '-Dtarget=x86_64-windows.win10...win11_dt-gnu' -j1`、`npm run build:release`；用户明确指示“先当做通过” | revision `52f54e3` 的 Application-owned capture、完整 capability gate、Renderer 解门、secret zeroize、Windows UIA password provider、readiness harness 与发布产物 automation 隔离已通过确定性检查；一次真实弹窗尝试已观察 UIA password、ValuePattern 不可读和 2.5 秒响应性，但旧 probe 在提交按钮不支持 `InvokePattern` 时终止，未完成 signed-out create→probe→select→run。用户明确允许 Phase R 先行放行；本记录不把延后的完整可见 vertical 表述为已执行，也不证明 macOS readiness |
| `E-WIN-SINGLE-20260828` | Windows single-instance process vertical | [高层架构](architecture.md) | `git show df8a9b2e798f5242491ace37400b09e495ae32d2:docs/validation.md`；`git show a858fcf96fa114cff56ab212b2c4fcc3ed66af87:docs/validation.md` | 2026-08-28 的真实多进程竞争、activation、restart、shutdown 与 crash recovery 子集；不证明交互失败、安装升级或后续 revision |
| `E-MACOS-SINGLE-COMPILE-20260828` | macOS single-instance 交叉语义编译 | [高层架构](architecture.md) | `git show 331e77c101ed0e0ea7aba4b3399dcd76ebd10fca:docs/validation.md` | 2026-08-28 的 aarch64 macOS 交叉语义编译；不证明真实 socket、peer identity、activation、shutdown 或 crash recovery |
| `E-MACOS-ICON-20260825` | macOS Icon Composer compile | [macOS 分发](macos-distribution.md) | `git show 7767629ee2fe8aaa4c85ac89afa1c6fa1887cdc5:docs/validation.md` | 2026-08-25 的本机 `actool` compile 证明当时工具链和输入能生成预期 icon resources；不证明后续输入、签名、公证或真实 UI 视觉 |
| `E-MACOS-ARM64-PACKAGE-20260901` | macOS arm64 desktop vertical 与 notarized package | [产品需求](requirements.md)、[Product 架构](product-architecture.md)、[macOS 分发](macos-distribution.md) | 2026-09-01；MetaWork revision `93075d3736c28b6b8d37cab9778f0a49f9a7b733`；`node scripts/test-agentcore-vertical-macos.mjs`；`npm run package:macos -- arm64`；Apple notarization `11559e7a-92f0-4f7b-bbdf-e677db775359`；`metawork-0.1.5-macos-arm64.dmg` SHA-256 `e735080b52d0892d8b7386a8b80c2079d2427116d3e1ba46351abbe06f187506` | 精确 revision 的 isolated local-provider desktop vertical 通过 Skill/Text/compact checkpoint、ProductDelivery、工具、permission、恢复和 clean shutdown；同一 revision 的 arm64 artifact 通过 Developer ID 签名、公证、staple/validate、Gatekeeper、DMG 结构与 hash Gate。它不证明真实 Metask 服务或用户 Keychain、拖拽安装后首次启动、可访问性/视觉、x86_64 或后续构建 |
| `E-WIN-X64-PACKAGE` | Windows x64 signed installer | [Windows 分发](windows-distribution.md) | `git show 48ba6c76522731cdbff5d11fe320f6dabb54faaa:docs/validation.md` | 当时的 signed x64 installer 完成隔离目录 silent install/uninstall 与 Authenticode 验证；不证明后续 artifact 或交互式安装 |
| `E-WIN-ARM64-PACKAGE` | Windows ARM64 signed package | [Windows 分发](windows-distribution.md) | `git show 776e2c25d9bd4f6ec6ad89cf70d91fe8ba73e378:docs/validation.md`；2026-08-28 installer SHA-256 `830d524cb35000a342687658b5aaf561d003f6149a26775747aae8c810a732a5` | 当时的 ARM64 主程序与 installer 通过签名、时间戳和 PE identity 验证；不证明 ARM64 安装、启动或 AgentCore vertical |

## 未闭合验证缺口

本节只防止错误能力声明。行为、边界和产品开放条件仍由所列真源定义；测试清单和逐项断言不在这里维护。

| 能力 | 状态 | 关闭所需证据 | 真源 |
| --- | --- | --- | --- |
| AgentCore 独立 Worker、crash、async pending、suspend/resume、跨进程 in-flight recovery | 尚未实现 | Worker fault-domain 与恢复 lifecycle/vertical | [高层架构](architecture.md)、[产品需求](requirements.md) |
| strict Workspace security、正式 Host tools、持久权限 | 尚未完成安全验收 | authority、process tree、filesystem、network 与跨平台安全证据 | [产品需求](requirements.md) |
| PermissionProfile `standard` 与其他平台 artifact 行为 | 两档产品切片已开放，macOS arm64/x86_64 exact artifact probe 已通过；`standard` 隐藏，Windows target 尚缺同等 probe | typed risk/effect、执行前 commit boundary，以及 Windows 各 target exact artifact probe | [产品需求](requirements.md)、[AgentCore 集成契约](agentcore-integration.md) |
| File Preview 真实桌面体验 | 核心 wire、owner、bounded read 与 redaction 已自动化覆盖；人工验收待完成 | Windows/macOS Drawer 视觉、键盘、焦点和窄窗验收 | [产品需求](requirements.md)、[UI 设计规范](ui-design.md) |
| File Changes 真实桌面体验 | typed owner、持久化/恢复、Bridge/Renderer 和 canonical AgentCore desktop vertical 已自动化覆盖；人工验收待完成 | Windows/macOS Drawer 视觉、键盘、焦点、屏幕阅读器和窄窗验收 | [产品需求](requirements.md)、[UI 设计规范](ui-design.md) |
| typed Output、plan/approval、custom UI | 尚未形成可开放产品能力 | 对应合同、owner、持久化、恢复、投影和 UI Gate | [产品需求](requirements.md)、[UI 设计规范](ui-design.md) |
| Skill catalog 历史内容固定 | 外部合同证据不足 | body/resources lease 的独立合同或可复现实验 | [AgentCore 集成契约](agentcore-integration.md) |
| execution rebind | 仅进程内 binding/model switch 有自动化 | 跨重启 epoch/history、竞态和恢复证据 | [产品需求](requirements.md)、[Product 架构](product-architecture.md) |
| Product 持久化格式演进与恢复策略 | 当前各 owner 的格式识别、迁移和恢复能力尚未形成统一、已实现的产品策略；Windows Task quarantine 文件测试已补齐 Threaded I/O file flag 并进入正式 test graph | 另行完成 owner-specific 决策、实现与对应原生文件验证后，再更新相关领域真源 | [高层架构](architecture.md)、[Product 架构](product-architecture.md)、[Account 架构](account-architecture.md) |
| MCP 图片作为模型视觉输入 | 当前 canonical bundle 的 Streamable HTTP → Anthropic 验证仅保留序列化 tool-result 文本，不能认定模型收到图片块 | 上游支持后，验证标准 MCP image content 成为 provider 图片块，且连续历史与 checkpoint 保持；不得用 Base64 文本存在代替视觉证据 | [AgentCore 集成契约](agentcore-integration.md#agent-session-多模态输入) |
| MCP 真实外部环境 | 确定性 owner/事务回归不等于平台验收 | 第三方 server、credential、network、secure capture、browser/callback 与 issuer 的跨平台证据 | [产品需求](requirements.md) |
| Scheduled Task 的 Host 外执行 | 尚未实现 | 系统关机、用户显式退出、登录前服务或远端调度的能力合同与 lifecycle 证据 | [产品需求](requirements.md)、[Product 架构](product-architecture.md) |
| Windows 完整分发矩阵与更新、Linux | 部分平台证据或尚未开始 | 交互安装、启动、升级、Windows 10/11、更新策略，以及 Linux build/run/distribution | [产品需求](requirements.md)、[Windows 分发](windows-distribution.md) |

## 维护规则

- 同一事实只在一份 source of truth 定义；本文链接规范，不复制产品、架构、ABI 或分发合同。
- 普通可重现测试不进入长期证据账本；提交是否通过由该 revision 的真实执行结果负责。
- 只有具备长期审计价值的稳定 artifact、平台或外部服务事实保留独立证据；阶段叙事在结论进入合同、测试或账本后删除。
- 长期证据 ID 是稳定引用；既有 ID 的证据对象、结论与有效范围不得改写为另一项验收，新证据使用新 ID 追加。
- 新增普通测试、测试改名、测试文件移动、artifact rebuild、checksum 或 lock refresh 不要求更新本文；只有测试层或归属规则、标准入口、证据结论或未闭合缺口变化时才更新。
- `rg`、格式检查、文件存在性和源码关键词检查只属于卫生或结构验证，不能替代合同、运行时和平台行为测试。

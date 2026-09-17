# Window controls 调整方案

状态：经三轮自审修订的方案，2026-09-17。复盘范围为职责与平台范围、生命周期与错误顺序、验证可执行性。当前只完成方案制定和源码核对，未开始实现或产生新的运行时验证证据。本文件是实施计划，不是产品真源或 decision record；稳定合同仍由既有领域文档拥有。

核对基线：MetaWork `d2c001a7870fcf8ffca2471ccdc49a755efdab70`，Native SDK `0.10.1`。实施前重新检查工作树与相关代码变化。

## 1. 目标与范围

借鉴 Tauri 的窗口身份解析、操作决策与平台执行分工，使现有 Windows 标题栏按钮和双击经过一致的生命周期检查；原生兼容模块只补 Windows 上 SDK 尚未提供的能力。

完成后应满足：

- 标题栏动作只作用于当前仍打开、未被 SDK 隐藏的主窗口。已经隐藏后到达的最大化请求不能重新显示窗口。
- SDK 主窗口不存在、已关闭或 Windows binding 未建立时明确失败，不以 `maximized = false` 表示这些不可用状态。
- 最大化按钮与标题栏双击经过同一个 Application 决策入口。
- 标题栏关闭继续进入 SDK 的 `close_policy = hide`；托盘显式 Quit 继续经过现有退出流程。
- SDK 拥有窗口存活、隐藏及销毁；OS 提供最大化事实。MetaWork 不增加窗口状态缓存、窗口运行时或关闭状态机。

范围严格限定为 Windows `window_controls` 及其必要的 Windows 调用分支。保留已完成的 drag 事件路径、Host 双击状态机、top-band 授权和 resize 输入层；Windows 调用接线只做错误传播、执行前检查和公共最大化入口所必需的调整。

macOS 原本不需要这项窗口控制兼容，不参与本次改造：不修改其平台实现、原生交通灯、SDK drag 调用链、调用参数或执行前提，也不新增兼容原语。共享文件可以改，但新逻辑必须限定在 Windows 分支；不得为了统一接口而要求 macOS 配合改签名、补空实现或承担新的 Runtime/可见性/binding 检查。其他平台原有 disabled-controls 表达保持不动。不为本任务增设 macOS 实施子任务或实机验收要求。

不改变 Bridge revision、wire command、payload、动作 ACK 或 UI 按钮布局。继续使用官方 SDK，不修改 `node_modules`、SDK 私有 context 或外部依赖源码。

## 2. 对 Tauri 的借鉴及适用边界

核对的上游源码固定为：

- Tauri `990f77eb2f16b431dd5fd8b1059e6112647cca7a`：[窗口命令](https://github.com/tauri-apps/tauri/blob/990f77eb2f16b431dd5fd8b1059e6112647cca7a/crates/tauri/src/window/plugin.rs)、[运行时派发和关闭请求](https://github.com/tauri-apps/tauri/blob/990f77eb2f16b431dd5fd8b1059e6112647cca7a/crates/tauri-runtime-wry/src/lib.rs)。toggle 在命令层读取状态并选择动作；运行时按窗口身份执行；close 与 destroy 分路。
- Tao `27fe28c73ace307eb0b1d1abf457508410f1340e`：[Windows 窗口入口](https://github.com/tauri-apps/tao/blob/27fe28c73ace307eb0b1d1abf457508410f1340e/src/platform_impl/windows/window.rs)、[状态应用](https://github.com/tauri-apps/tao/blob/27fe28c73ace307eb0b1d1abf457508410f1340e/src/platform_impl/windows/window_state.rs)、[原生事件](https://github.com/tauri-apps/tao/blob/27fe28c73ace307eb0b1d1abf457508410f1340e/src/platform_impl/windows/event_loop.rs)。平台接受确定的最大化目标，处理显示状态与操作顺序，并从原生消息更新其自有状态。

以上是两仓库分别核对的源码，不宣称是本地运行过的一组 Tauri/Tao 依赖组合，也不构成 MetaWork 平台验证。

MetaWork 采用其中的职责划分，继续由 Native SDK 拥有窗口。Tao 的 WindowState、线程执行器、样式管理和 WM_SIZE 缓存属于它自身的窗口运行时，不能复制到 MetaWork 形成第二个 owner。

当前主窗口可缩放、可最大化；Tauri 内部标题栏命令的 resizable/maximizable 检查说明这些是执行前提，但本次不新增动态窗口能力配置、猜测的 capability 字段或通用查询协议。若基线检查发现主窗口声明已改变，先收口真实要求与按钮行为，再实施。

## 3. 事实来源和生命周期

| 事实 | 唯一来源 | 本次用途 |
| --- | --- | --- |
| 主窗口 id、平台 Runtime 是否可用 | 现有 Application composition | 确定调用对象与运行阶段 |
| `open`、`hidden` | SDK `Runtime.listWindows()` 返回的 `WindowInfo` | 每次执行前检查，不缓存 |
| 最大化事实 | 已绑定主窗口的 `IsZoomed` | toggle 决策、只读 UI 投影 |
| 原生窗口 identity | 既有 startup binding | 只借用，不销毁、不重新寻找窗口 |
| Renderer 文档会话 | 既有 Bridge generation | 拒绝失效文档请求 |

`listWindows()` 使用 `native_sdk.platform.max_windows` 对应的有界栈缓冲，按 id 查找；不假设主窗口一定是数组第一个，也不使用会截断结果的单元素缓冲。

SDK 的 `WindowState` 类型虽然有 `maximized` 字段，当前 Windows 路径与公开 `WindowInfo` 不提供可据此消费的最大化查询。不能仅凭字段存在就替换 OS 查询。

当前 SDK 的 Windows event handler 直接进入 Runtime 派发，`window_frame_changed` 更新窗口信息；这给使用 `listWindows()` 的检查提供了源码依据，但不单独证明所有原生重入和 Bridge 到达顺序。阶段 A 核对这一链路并以 SDK 公共事件派发/窗口列表的 Native fixture 验证字段更新；B 出口的最小产品 probe 和 C 的完整矩阵再验证真实动作入口。若实测不能作为可靠执行前提，停止推进该检查设计并复审，不能另建镜像状态或假定它同步。

阶段 A 不以普通 SDK automation snapshot 观察 `open/hidden`：当前 `automation.snapshot.Window` 只有 id、title、bounds、focused，没有这两个字段。SDK 原生 fixture、改造后由窗口表产生的具体拒绝错误、OS 可见性与 DOM 投影分别承担对应证据，不能互相冒充。不为补观测而增加生产 Bridge 查询或测试后门。

启动仍在成功捕获、绑定窗口后才开放既有 Bridge 入口。退出继续使用现有 ingress/Runtime 清理顺序；Windows 新增状态查询和窗口 effect 检查 Runtime 窗口存活，reset/disconnect 的清理例外见下文。隐藏与页面 reload 不清除窗口 binding，Application teardown 才释放借用。

这不消除 startup 捕获依赖，也不提供一个跨窗口重建、HWND 复用仍有效的 lease。当前单主窗口不在同一会话销毁后重建；新增该能力须重新定义 binding 合同。不得用重复捕获、窗口标题/焦点搜索或额外 subclass 掩盖限制。

## 4. 具体实现

### 4.1 Application 承担执行前检查与动作选择

在现有 `src/app/window.zig` 内建立两个局部 helper，不新增控制器或 service 层：

- `requireLiveMainWindow(runtime, window_id)`：验证主窗口身份，读取 SDK 窗口表，要求记录存在且 `open = true`。
- `requireUnhiddenMainWindow(runtime, window_id)`：在上一检查基础上要求 `hidden = false`，不把它当作前台、未遮挡或未最小化的证明。两个 helper 共用一次有界查询，不重复遍历或跨调用缓存。

再提供唯一的 Application `toggleMainWindowMaximized`：检查当前窗口可接受标题栏动作，读取 `isMaximized()`，调用 `setMaximized(!current)`。读取和执行之间没有 await、排队或跨线程跳转；`ShowWindow` 本身可能同步派发消息，不把整个函数宣称为不可重入事务。

按钮和双击结果都调用此入口；双击结果从原生手势处理返回后再次检查当前窗口事实，不沿用进入手势处理前的状态。

现有 `src/app/platform.zig` 仅在 Windows connect/refresh/pointer 所需分支使用其已持有的 Runtime；不扩展 Bridge Platform 的对外函数签名，也不让兼容模块导入 Application。新增 Runtime 解析不能在共用 Adapter 入口无条件提前失败：它必须留在确实需要它的 Windows 分支内，macOS 继续按原有调用及参数进入现有实现。不为统一平台签名新增通用 context、facade 或空适配层。

Windows connect 的新增可失败步骤放在 attachment 之前：先完成窗口检查与 controls 查询，再调用既有 `drag_region.connect()` 并组装 environment；避免 controls 查询失败却已经建立本次 drag attachment。若后续实现确需在 attachment 后新增失败点，必须撤销本次 attachment。connect 失败仍遵守既有 generation 失效语义，不恢复旧 generation；refresh 失败不新建 generation、不断开现有 session。

### 4.2 按操作区分检查条件

以下新增条件仅约束 Windows；Bridge 现有的身份/线程/会话规则保持原适用范围。

| 操作 | 要求 | 不满足时 |
| --- | --- | --- |
| connect / refresh | 会话规则、Runtime 可用、主窗口仍 open；允许 hidden | 返回错误，不生成虚假窗口事实 |
| 最小化按钮 | 主窗口 open 且未 hidden | 拒绝动作；通过时仍调用 SDK `minimizeWindow()` |
| 最大化按钮、双击产生的 toggle | 主窗口 open 且未 hidden；Windows binding 可查询 | 拒绝动作，不调用 `ShowWindow` |
| 标题栏关闭按钮 | 主窗口 open 且未 hidden；binding 可用 | 拒绝动作，不重复投递关闭请求 |
| pointer down | 已通过当前文档身份/会话校验，再于原生手势执行前检查主窗口可接受标题栏动作；原有原生授权继续执行 | 本次有效会话的按下被窗口前提拒绝时清序列并返回错误；不调用原生手势或最大化 effect |
| pointer reset / disconnect | 保留既有身份、会话和清理约束；不新增 open/hidden 检查 | 始终允许有效清理路径重置序列，不触发窗口 effect |
| 托盘 Open / 显式 Quit | 各自现有 Application 流程 | 不套用“未隐藏”检查，避免隐藏后无法重开或退出 |

不要求窗口 focused，避免破坏失焦窗口的首次点击。最小化不会被当成 SDK hidden；本次不新建 minimized 镜像，也不扩大为通用“后台窗口禁止操作”政策。

错误与清理的顺序必须闭合：旧 generation、错误 window id、非法 payload 或非主线程请求仍由 Bridge 提前拒绝，不能清掉当前合法会话的序列。有效会话 down 的 Runtime 缺失、SDK 窗口不可用或 binding 错误则都落入同一个序列清理范围；不得在 Adapter 的 Runtime unwrap 处提前返回、绕过清理。reset/disconnect 不增加 Runtime unwrap，不被隐藏状态挡住，也不重新捕获窗口。

### 4.3 Windows 兼容只提供明确原语

Windows 内部接口调整为，其他平台不需要实现这些新增原语：

```zig
isMaximized() !bool
setMaximized(maximized: bool) !void
requestUserClose() !void
```

- `isMaximized`：未绑定时返回 `WindowUnavailable`；已绑定且通过调用者的 SDK 存活检查后读取 `IsZoomed`。
- `setMaximized`：只把确定目标映射到 `SW_MAXIMIZE` / `SW_RESTORE`，不再自己执行 toggle 决策。
- `requestUserClose`：继续用 `PostMessageW(WM_CLOSE)`，保留投递失败错误。名称明确请求性质。
- Windows 的 `state()` / environment 组装传播查询错误；非 Windows 的既有 disabled-controls 分支保持原实现，不跟随 Windows 增加接口、错误或 binding 前提。
- 只删除 Windows 新路径替换后确实失去职责的旧入口；空 `prepareStartup()` 转发、共享字段等清理若需要连带修改非 Windows 实现，则不纳入本次任务。

OS API 仍限于当前 `IsZoomed`、`ShowWindow`、`PostMessageW`，本方案不需要放宽 extern allowlist。`ShowWindow` 返回旧可见状态，不能把返回零当作执行失败；动作 ACK 也不伪装成最终状态确认。参考 [Microsoft ShowWindow 合同](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-showwindow)。

`isMaximized() !bool` 的错误来自窗口/binding 前提；`IsZoomed` 自身没有独立的失败结果，本方案也不把它当作 HWND 有效性验证器。测试不得虚构“IsZoomed 查询失败”的返回码；SDK 存活与 startup identity 是这里的明确前提，不能由一个 `!bool` 签名宣称获得了完整的原生句柄复核。参考 [Microsoft IsZoomed 合同](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-iszoomed)。

### 4.4 关闭与事件顺序

关闭按钮与 Alt+F4 继续汇合到 SDK 的 `WM_CLOSE` 处理，由 SDK 执行 manifest 关闭策略、托盘可用性检查以及最终隐藏/销毁。Application 不复制这些判断，不改为直接 `hideWindow()` 或 `closeWindow()`。

`{ generation, handled: true }` 对 close 只表示请求成功投递。窗口隐藏/销毁结果仍来自后续真实处理；Renderer 不把 ACK 写成隐藏或关闭状态。

以主线程实际受理/执行次序为准：关闭请求尚在 OS 队列时，窗口仍 open 且未 hidden 的后续动作可能被受理；本方案不承诺“点击关闭瞬间冻结所有命令”。SDK 已完成隐藏后，后续标题栏动作必须拒绝。若测试发现这种顺序导致明确产品问题，保留反例并重新评审，不先加 `closing` 锁或重试队列。

该保证针对命令进入 Application 检查时的事实，不撤销已经受理或投递的 OS 动作。WebView 渲染进程与 UI 线程间不存在由墙钟时间推导的总顺序；不能仅凭 JS 发出顺序、ACK 返回顺序或固定延迟断言原生处理顺序。

### 4.5 只读投影与 Renderer

保留 connect/refresh 的状态响应、control/pointer 的动作 ACK，以及既有 single-flight refresh、epoch 失效、resize/focus/动作后刷新和 dispose 清理。

Renderer 不根据发出的动作乐观翻转最大化状态，不自动重试被拒绝的动作。查询失败不能变成 `false`。沿用当前“保留最后已确认状态，后续事件可再刷新”的恢复行为；不因本任务另增通用状态错误 UI。

Windows 新旧内部路径一次性替换，不为 Windows 保留旧 `toggleMaximize` 平台入口作为别名；不借此整理非 Windows 分支。

## 5. 文件与合同范围

| 文件 | 计划职责 |
| --- | --- |
| `src/app/window.zig` | Windows 的 SDK 当前事实检查、唯一 toggle 入口、动作条件与清理分路 |
| `src/app/platform.zig` | 必要的 Windows Runtime 接线，macOS 调用及参数不变 |
| `src/native_sdk_compat/system_webview_window_controls.zig` | Windows 能力派发与查询错误传播，非 Windows 分支不动 |
| `src/native_sdk_compat/system_webview_window_controls/windows.zig` | 明确原生 set/query/request 操作，移除被替换的 Windows 旧入口 |
| 对应 Native tests、既有 Bridge tests | Windows 执行条件、错误、清理顺序、connect 失败的 attachment 边界及调用接线 |
| `scripts/test-window-chrome-windows.mjs`、`scripts/probe-windows-window-chrome.ps1` | 真实状态组合与原生关闭/重开验证 |
| `scripts/window-chrome.test.mjs` | 只有新增失败路径影响现有前端行为时追加断言 |
| `docs/renderer-bridge-contract.md` | 实施时定义标题栏动作受理条件与清理/只读例外，保留 wire 和 ACK 语义 |
| `docs/validation.md` | 验证完成后登记精确 artifact/revision 证据与未覆盖范围 |

`app.zon` command allowlist 无预期变化；architecture owner 和能力登记无预期变化；UI 布局、startup 捕获机制、drag/resize 算法无预期变化。机器 guard 如因本次删除内部符号需要调整，只收口对应断言，不扩大允许边界、不跳过失败。

## 6. 验证设计

### 6.1 最小 Native 与 Bridge 验证

按失败模式选测试层：SDK 公共 Runtime/事件 fixture 检查窗口列表更新与有界查找；Application/Bridge fixture 检查身份、分支、清理和调用顺序；Windows 产品 probe 检查真实原生 effect。局部纯 helper 测试不能代替对真实调用接线的检查。既有 port 的 fake 可计数；直接 Win32 extern 没有计数接口时用本任务拥有的测试窗口状态作断言，不为了“调用次数为零”新增生产态通用 dispatch facade。

- Runtime 不可用、id 不匹配、记录缺失、`open = false`：返回明确错误，无原生 effect；查找测试包含主窗口不在首项，不能用单元素输出掩盖截断。
- `hidden = true`：查询允许；minimize/toggle/request-close 均无原生 effect；Open/Quit 路由仍可用。
- Windows 未绑定：查询明确失败。
- 按钮与双击调用同一 toggle 路径；有效会话 down 的 Runtime/binding/存活失败均清序列；hidden 或 Runtime 不可用时有效清理路径仍可 reset/disconnect。
- 旧 generation、错误 window id、非主线程、非法 action：继续由现有 Bridge 拒绝，且不清除当前合法会话序列。
- SDK/Windows binding 前提失败不触发 set；close 投递失败不伪装成功，不自动重试；不伪造 IsZoomed 的错误通道。
- connect 的 controls 查询失败不会建立本次 drag attachment；refresh 查询失败保持 session/generation，下次成功 refresh 可恢复。
- 检查 diff，确认 macOS 实现与调用路径、非 Windows disabled-controls 分支未被改造。共享文件修改接受既有相关检查，不另建 macOS 兼容测试或以新增 macOS 实机验收扩大任务。
- 已投递 close 的 ACK 不是最终状态，control 不再投影最大化事实；迟到 refresh 和卸载后的响应仍被隔离。

如故障注入需要本地测试窗口或 fake platform，限定在 test root 中；不新增测试专用 Bridge 命令或绕过产品入口。

### 6.2 Windows 真实验证矩阵

| 场景 | 观察与通过条件 |
| --- | --- |
| 按钮最大化/还原、标题栏双击 | OS 窗口状态与 Renderer 图标一致，既有双击规则保持 |
| 最大化 → 最小化 → 从任务栏恢复 | 保持系统恢复语义，恢复后按钮事实正确；不能用 probe 的 `SW_RESTORE` 代替真实恢复动作 |
| 普通及最大化 → 点击关闭 → 托盘 Open | 原 HWND 仍存活，Host 后台继续，重开后的窗口状态/图标正确 |
| Alt+F4 与关闭按钮 | 都经过同一 SDK 关闭策略，行为一致 |
| 确认已 hidden 后发送标题栏动作 | 通过既有产品 Bridge 验证拒绝；OS 窗口仍 hidden，无意外重新显示 |
| close 后紧邻 toggle、toggle 后紧邻 close | 按实际处理顺序记录结果；无销毁后原生操作、无 SDK 已 hidden 后重新显示 |
| SDK 已关闭 / teardown 后的请求 | 最小 Native/Bridge 测试验证无 effect；实机退出正常，无为了测试保留僵尸窗口的生产路径 |
| hidden 时刷新、重开、页面 reload | 不产生假 maximized 状态；controls 恢复，旧文档响应不污染新文档 |
| 拒绝手势与 reset、原生 resize 中断 | 双击序列不跨越被拒绝的按下；现有 drag/resize 验收保持 |

真实鼠标/键盘用于验收交互；无法从隐藏窗口产生的动作通过现有产品 Bridge 直接检验其受理条件，两种证据分别记录。不会把直接调用 Bridge 或程序化窗口操作写成真实鼠标证据。

probe 必须满足以下可执行约束：

- generation 从当前页面真实请求的被动 transport 观测获得，沿用现有 `window-chrome-input.mjs` 的机制；不能额外调用 connect 来取得 generation，否则会撤销页面原有会话。专门验证 connect 失败/reload 的用例须隔离，并在结束后重新等待真实页面握手。
- hidden 后直接调用原有 control 命令时，先确认 native 窗口确实 hidden，再断言来自窗口表检查的明确拒绝，最后复核窗口仍 hidden。拒绝后还要托盘重开并验证真实按钮可用，不能只证明后续所有动作都坏了。
- OS 状态观察使用现有 probe 的原生检查；投影观察使用当前环境响应、`data-metawork-window-maximized` 及实际 maximize/restore 图标可见性。普通 automation snapshot 不充当 SDK `open/hidden` 证据。
- 正常 UI 检查等待有界的状态条件：OS 状态、按钮重新可用、DOM 投影收敛；固定 sleep 只能用于建立特定输入间隔，不能成为状态同步成功依据。隐藏/最小化可能节流 WebView，重开后必须等待控件可操作再发下一次点击。
- 任务栏恢复使用真实键鼠触发；托盘 automation 调用标明是既有 SDK 托盘入口测试，不冒称真实鼠标点击系统托盘。不能用直接 `ShowWindow` 验收上述恢复入口。
- 有 barrier 的 hide→命令用于证明拒绝条件；无 barrier 的 close/toggle 交错只记录其实际结果与不变量，允许平台调度差异，不预设唯一 ACK 顺序。
- 观察 wrapper、临时页面节点、系统输入设置均在 finally 恢复；每组用例建立自己的窗口前置状态，不依赖前一组未结束的动作。

托盘不可用时的 SDK 关闭分支仍由 SDK 拥有。本次核对其调用路径未被绕过；若没有真实验证该异常分支，不宣称它已通过新实机验收。

记录 OS、DPI、SDK、WebView2、源码 revision、artifact hash、命令和逐项结果；测试未提交改动的 artifact 时另记录 diff/dirty 状态，不能仅标 HEAD。旧 `E-WIN-CHROME-EVENTS-20260916` 只作历史基线，不算新实现通过。Windows 11、混合 DPI 等未运行范围明确保留。macOS 不属于此次 Windows 兼容改造的验收范围，其既有证据不因本任务重写。

阶段 A 发现的既有组合行为缺陷须与本次新增拒绝和回归分开记录；不自动把它们扩展成 SDK 修复任务，也不能降低 C 的承诺来掩盖退化。新增检查的事实前提不成立、旧承诺退化或 probe 无法观察关键结果时，该阶段不算完成。

### 6.3 仓库检查

- 先运行对应 Native/Bridge/Renderer focused tests 和 architecture guard。
- 再运行 `npm run check`、`npm test`，保证 Node 与正式 Native test graph 都有结果；缺少 canonical staged bundle 必须失败。
- 运行完整 `node scripts/test-window-chrome-windows.mjs`，包括本次扩充场景及已有 drag/resize/paint/reload 回归。
- 检查改动文件格式、链接、旧路径残留和 `git diff --check`。
- 既有默认并发 Native 测试停滞需要如实报告；单独或串行通过不能宣称修复并发问题，不把相邻问题混入本任务。

## 7. 实施 DAG 与提交边界

依赖：A → B → C → D。当前仅完成方案制定，以下实现任务尚未执行。

| 阶段 | 产物与完成条件 | 提交判断 |
| --- | --- | --- |
| A：基线与事实时序 | 在未改动作语义上核对 SDK 同步事件链，以公共 Runtime fixture 检查字段更新，运行原有真实交互基线；确认观察手段与各层能证明的事实。区分已有通过、预期拒绝缺失和实际失败 | 仅提交可独立运行且不把预期失败伪装通过的 fixture/probe/基线记录；否则与 B 合并提交；不提交会混入默认 suite 的预期失败测试 |
| B：原子实现 | 一次性替换 Windows 的 Application 检查、唯一 toggle、平台原语、错误传播、reset 清理和 connect 失败顺序，并补充对应测试；macOS 不参与改造。必要的 Bridge 合同说明仅约束 Windows。focused tests/guard/build 及最小真实 hidden→拒绝→重开 probe 通过 | 提交完整 vertical，不先提交只有函数改名、编译失败或双路径的中间态 |
| C：真实交互验收 | 扩充矩阵通过；OS/SDK/UI 三方状态一致；有完整环境与 artifact 记录。若失败，在本阶段修复实现、关联 B 的证据并重验 | 提交真实回归和必要修复；实现变化后不得沿用旧 artifact 证据 |
| D：正式检查与收口 | 正式检查、相关套件、完整 Windows probe、源代码复盘、长期证据与 TinyKG 收口；限制准确报告 | 及时提交剩余验证/合同变更；不声称未执行的平台已通过 |

每个 DAG 子任务完成后评估及时提交；能形成完整、可验证的改动就提交，否则记录具体暂缓原因。C/D 发现 B 的问题时，在当前阶段完成修复和受影响重验并关联先前证据，不把已完成的 TinyKG task 强行改回 open，也不增加依赖环。制定方案阶段不创建实现分支、不运行新的 goal、不提交生产代码；开始实施时再使用 `feat/` 分支并重新核验基线。

## 8. 方案复盘

- 为什么不直接移植 Tao：它拥有窗口，MetaWork 已由 SDK 拥有窗口；复制其状态表和消息循环会产生第二 owner。
- 为什么不统一改造 macOS：本次补的是 Windows SDK 能力缺口，macOS 没有这项兼容需求；接口整齐不能成为修改其既有路径的理由。
- 为什么使用 SDK 窗口表：原生句柄非空不等于当前产品窗口仍存活；SDK 已提供这项事实，不能在兼容层再维护一份。
- 为什么不只加 visible 检查：隐藏不等于销毁，查询和清理仍有职责；统一挡住它们会破坏重开与双击中断。
- 为什么把 toggle 上移：只有与执行条件、按钮/双击共享路径一起完成才有收益；单纯拆函数不构成改造目标。
- 为什么保留 `WM_CLOSE`：当前公开 SDK 缺少 request-close，它是汇合既有策略的窄入口；直接 hide 会绕过该策略。
- 为什么不增加 closing 状态：现有动作是请求语义，按实际执行次序处理；先验证交错结果，不能把待验证风险转换成第二状态机。
- 为什么不更换 `IsZoomed`：现有用途是查询最大化事实；没有证据表明换为 GetWindowPlacement 能解决本任务问题，不增加系统 API 范围。
- 为什么还保留 startup binding：SDK 没有公开对应 HWND 入口；本方案改善操作前提，不宣称消除该已知兼容依赖。

接受条件是生命周期、动作语义与回归证据得到实质收紧；代码分层外观或与 Tauri 的名称相似不能单独作为成功标准。

## 9. 三轮自审结果

三轮均以当前代码、SDK 源码及测试入口复核，不把计划中的测试记为已执行。修订后的主方向保持不变。

| 轮次 | 追问 | 原草案不足 | 已收紧的边界 |
| --- | --- | --- | --- |
| 1：职责和最小范围 | 为什么 Windows 控制改造要让 macOS 配合修改？ | 仅承诺行为不变仍可能引入跨平台签名与空适配改动 | 按用户明确边界，只改 Windows 实现及必要调用分支；macOS 的实现、调用、参数和前提不动，不设新增实施或验收任务 |
| 1：事实与承诺 | 为什么改成 `!bool` 就能叫“查询失败”？ | 容易把前提失败与 IsZoomed 不存在的错误通道混淆 | 明确只报告 SDK/binding 前提失败；不宣称独立 HWND 复核 |
| 2：失败顺序 | 为什么 Runtime 不可用时序列一定能清除？ | Adapter 提前 return 可绕开 Application 清理 | 有效 down 的全部新失败位于清理范围；无效文档不得清合法序列 |
| 2：失败顺序 | 为什么 connect 后新增查询失败不会留下 attachment？ | 原 controls state 不失败，新错误传播会改变副作用顺序 | 查询在 attachment 前，必要时回滚本次 attachment；refresh 不撤销 session |
| 2：异步请求 | 为什么关闭 ACK 能当原生顺序屏障？ | 关闭投递、窗口事件与 Renderer 回调不是同一完成点 | 以执行入口事实判断；受理后的 OS 请求不被假定可撤销；不增加 closing 状态 |
| 3：测试真实性 | 为什么为测试再 connect 不会影响页面？ | connect 会递增 generation 并撤销现有会话 | 被动观察真实 generation，特殊握手用例隔离并恢复 |
| 3：观测能力 | 为什么 SDK snapshot 能证明 hidden/open？ | 当前 automation Window 根本没有这两字段 | 明确 Native fixture、具体拒绝、OS 与 DOM 各自的证据责任 |
| 3：验收收敛 | 为什么 sleep 后没变化就算同步正确？ | WebView 隐藏/最小化节流会把时序问题藏进固定等待 | 有界条件等待、拒绝后重开正向检查、用例清理、dirty artifact 身份和阶段失败条件 |

仍需实施阶段验证的是 SDK 在目标运行时的入口事实、真实输入和关闭交错；这些已成为明确出口条件。本轮没有发现需要新增窗口 owner、OS API、Bridge 命令或关闭状态机的证据。

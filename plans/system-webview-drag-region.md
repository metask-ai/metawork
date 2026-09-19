# System WebView 拖动区域最终建议方案

日期：2026-09-19。分支：`feat/native-drag-region`。任务根：TinyKG `3145`。

状态：用户在最终方案交付后明确要求使用 goal 实施，F1–F9（含 F2 的 Windows 行为迁移）已获实施授权。实现与验证进行中，未通过的验收不因授权而视为完成。

**选定路线：参考 Tauri 最新稳定版的窗口手势机制，在现有标题栏和 Bridge 上作最小适配。Windows 采用浏览器点击计数，不再维护 Host 首击历史；macOS 保留 SDK/AppKit。**不再以 CSS 原生区域能力作为本次前置，不再推进透明输入子窗口、区域镜像、业务 ACK 或额外拖动带。

当前方案只有 F1–F9。文末第 12–15 节因原型证据追溯责任保留为历史，历史“下一步”、批准边界和章节编号不构成当前实施指令；其原始上下文见 Git `3e725c69`。

## F1. 固定参考基线，限定最小偏离

本次核对的最新稳定版为 [Tauri 2.11.5](https://github.com/tauri-apps/tauri/releases/tag/tauri-v2.11.5)，commit `7cd71369c00978a3783b6ae3e9972358abbe4ae6`。以该 revision 的 [drag.js](https://github.com/tauri-apps/tauri/blob/7cd71369c00978a3783b6ae3e9972358abbe4ae6/crates/tauri/src/window/scripts/drag.js)、[window plugin](https://github.com/tauri-apps/tauri/blob/7cd71369c00978a3783b6ae3e9972358abbe4ae6/crates/tauri/src/window/plugin.rs) 和 [Cargo.lock](https://github.com/tauri-apps/tauri/blob/7cd71369c00978a3783b6ae3e9972358abbe4ae6/Cargo.lock) 为基线，依赖对应 Tao 0.35.0、Wry 0.55.0。实施期间不自动漂移到 dev、alpha、教程片段或另一个版本；复制或改编源码时保留适用许可与来源。

稳定版内置脚本在 document 冒泡监听 mousedown，仅在目标合格且 detail 为 1/2 时执行，Windows 的第二击请求 internal_toggle_maximize；其他计数不执行。Tao 将拖动交给 Windows caption move loop。这是一条现成机制，不要求应用建立原生区域镜像。

本项目的有意适配只有：

- 监听收窄到实际标题栏 DOM 节点；React 只登记节点，不读取平台、连接 DTO 或调用 transport。
- 保留项目已有的完整控件/inert/no-drag 排除，以及启动窗口、generation、原生 top-band 与实时指针授权。
- Windows 复用已有原生拖动与 window-controls owner，不移植另一套宿主；macOS 保留当前 SDK/AppKit 手势和系统偏好，不叠加 Tauri JS 双击执行。
- 按实际挂载/卸载管理监听，按既有 Bridge 合同处理失败和迟到响应。

[Wry 0.55.0 的 CSS 原生区域设置](https://github.com/tauri-apps/wry/blob/wry-v0.55.0/src/webview2/mod.rs)仍是未来能力替换参考。Native SDK 0.10.1 对启动 System WebView 的公开入口缺口不妨碍本次 JS 意图路线；不修改 SDK、私有对象或 upstream-only 政策。

## F2. 明确行为迁移，不再承诺旧状态机等价

采用 Tauri 的 Windows 点击语义，替换旧 Host 配对语义；用户在最终方案明确列出以下差异后批准实施。这是行为迁移，不是旧状态机的等价重构。

对当前合格标题栏按下，Windows 只做以下映射：

| 条件 | 请求 |
| --- | --- |
| 可信主键 mousedown，detail === 1 | start_drag |
| 同上，detail === 2 | toggle_maximize |
| detail 为其他值、目标被排除或 capability 未就绪 | 不发手势命令 |
| 普通业务按下、失焦、原生边缘按下 | 不发送或维护双击 reset |

Host 仍可因当前窗口/指针/生命周期不合格拒绝请求。浏览器计数不是执行授权；动作被拒绝不排队、不重放，也不另行修补后续点击计数。

这意味着：

- 正常双击继续最大化/还原，拖动继续交给 OS。
- 不再保证“中间发生任何业务按下、失焦、原生边缘输入、失败或窗口矩形变化，都由应用强制中断双击”。
- 给定标题 1 → 相邻控件 2 → 标题 3，最后一击无窗口动作；给定标题 1 → 控件 1 → 标题 2，最后一击可以请求最大化。
- 给定标题 1 → 失焦 → 标题 2，最后一击可以请求最大化。仓库已有真实 [失焦计数证据](../docs/validation.md)，不是尚未发现的理论情形。
- 连续 detail 为 3/4 时不发新手势；窗口移动后浏览器若重新从 1 计数，则按新事件处理。
- 时间、距离及计数重置由目标 WebView 的浏览器机制决定。记录系统设置与正负边界，不再复制旧 Host 闭区间，也不承诺与原型 native child 的每个边界像素相同。

业务隔离的保证是“业务事件自身零窗口手势命令、不被窗口 handler 取消或修改焦点”，不是承诺浏览器将任何业务事件视为独立于下一次标题事件的计数序列。

标题栏高度、按钮位置、内容空间、弹层覆盖、复制/编辑/选区、系统关闭隐藏/托盘/显式退出不改变。macOS 不采用上述 Windows 行为迁移，维持 SDK/AppKit 与用户双击偏好。

实施须同步本节涉及的合同及验证预期，不改变无关 Gate。本方案不再留下多条待选技术路线，也不把已接受的行为差异转换为再次开发自制状态机的理由。

## F3. 局部 DOM 入口与真实界面接入

AppShell/AccountGate 将 browser-side Bridge 的稳定窄绑定函数作为 DOM ref 注入 `WindowTitlebar`，后者只转交给真实 header，保持 Foundation UI 不导入 Bridge 的依赖边界；Bridge 拥有事件、会话和响应状态，挂载取得清理函数。当前 React 19 支持 ref cleanup。不得在 `main.tsx` 的 React 渲染之前只 querySelector 一次，不引入 MutationObserver、全页扫描或通用区域注册系统。

- 监听绑定在真实 header：Windows 处理局部 mousedown；macOS 保持局部 pointerdown，以保留当前 SDK 输入时机。由 Host capability 决定哪一个入口生效，同一事件不会走两条动作路径。
- 标题栏明确采用深层拖动语义，覆盖非交互标题文字及空白；不能直接套用 Tauri bare marker 的“只命中元素自身”语义而让当前标题 span 失去拖动。
- 依据原生 composedPath，确认包含本次绑定 header，并检查完整交互排除。保留当前 button/SVG、input、链接、disclosure、可编辑/可聚焦内容、inert 和显式 no-drag 保护；采纳 Tauri 的交互排除模式，不复制其允许交互元素主动标记为 drag 的覆盖特例。
- Windows 只有在 capability 就绪、目标合格且有动作时，按参考入口取消选字默认行为并停止该次拖动事件传播，立即发请求。无动作分支不取消事件；macOS 不额外改变当前 pointerdown 默认处理。
- 使用原生局部监听，不以 React 逻辑树的冒泡替代 DOM 命中。原生传播被显式停止时尊重其结果，不回退到 document capture 追捕事件。
- 窗口按钮的 click 处理也绑定在标题栏内，保持现有键盘激活、执行中禁用和恢复逻辑；普通业务按钮不进入窗口手势分支。
- AccountGate 与 Workbench 的标题栏各自随挂载绑定、随卸载解除；动态 actions 由当次 DOM 命中自然排除。保留设置覆盖时已有的可命中 no-drag 外层，避免 inert 跳过子树后误命中 header。
- modal、菜单与 portal 按实际 DOM 路径处理；路径不经过该 header 时不触发其原生监听。业务布局照常提交，不需要 IPC ACK。缩放、窄窗和语言变化不发布几何镜像，也不改变 CSS 布局。有效拖动范围始终是 DOM 候选与 Host 原生 top-band 的交集；不承诺缩放后的整个视觉 header 都取得原生执行权，也不扩大 top-band 来掩盖越界。
- StrictMode 重挂、节点更换及重复清理不得重复注册或解除新节点的监听。文档 dispose 解除当前全部局部绑定；旧连接/响应不能重新绑定节点。

## F4. 最小 Bridge 合同

保留 connect / refresh / control / disconnect。以 `metawork.host.windowChrome.gesture` 原位替换旧 pointer command，不新增通用 OS action 协议，也不保留旧 phase 的兼容解析。

gesture payload 固定为 `{ generation, action: "start_drag" | "toggle_maximize", x, y }`；坐标必须有界且有限。成功沿用 `{ generation, handled: true }`，含义仍是受理，不保证原生交互已完成。不传 HWND、window id、点击时间、计数、continuity hint 或 token。

connect/refresh 用闭合 `gestureMode: "browser_mouse" | "native_press" | "disabled"` 替换 livePointerDrag：

- browser_mouse：Windows，Bridge 按 F2 从 mousedown 选动作。
- native_press：macOS，合格 primary pointerdown 只请求 start_drag；SDK/AppKit 自行处理这次按下的原生含义。Host 拒绝此模式下 Renderer 请求 toggle_maximize。
- disabled：不发送手势；不猜平台或换用另一路径。

模式只是当前已支持能力的判别，React 不消费它，不建立可配置策略框架。未就绪事件直接忽略，不在 connect/refresh 完成后回放。

保留 origin、精确启动窗口、generation、严格字段和主线程检查。新请求仍使用唯一现有 transport；删除旧 pointer catalog/type/decoder/fixture，旧 command 和额外字段必须被拒绝。更新唯一 app.zon catalog 及其派生物，不以泛化 allowlist 或跳过 guard 完成迁移。

## F5. Native owner 与失败处理

Windows 在现有 drag seam 内把“当前按下授权”从“首击配对”中分离，删除后者。两种 gesture 都先验证 document attached、当前主窗口可用/未隐藏、逻辑主鼠标键按下、实际 OS 光标、已绑定 root、native hit 和 DPI top-band；Renderer 坐标不授予执行权。

- start_drag：复用现有 ReleaseCapture 与正确封装坐标的 WM_NCLBUTTONDOWN/HTCAPTION 路径，不复制 Tao 的内部线程/消息包装。
- toggle_maximize：通过同一手势授权后，由 Application 调用已有 window-controls owner。复用执行原语，不直接转发到没有手势授权的按钮 control 分发入口，不增加双击缓存。
- macOS：保留现有坐标 top-band 检查与正式 startWindowDrag；不同时发送 JS toggle，不改变交通灯与用户系统偏好。
- resize：保留原生边缘命中、系统缩放、绘制和生命周期，只删除专为旧首击缓存存在的 reset 回调。无 drag child，不新增 Z 序/区域裁剪协调。

保留窗口状态读取和生命周期校验；只移除专用于配对的 Press、tick、距离、window_rect 比较与 reset。不能按符号名批量删除其他 owner 仍使用的窗口矩形、focus refresh、隐藏/销毁或资源清理。

窗口手势立即提交，不等待状态读取，不设全局 gesture in-flight 锁，不将后续手势排队。失败或结果未知时不重试 toggle/start_drag、不 reconnect、不恢复旧引擎；复用既有 refresh、响应 epoch 和 generation 失效规则。动作 ACK 不当成移动/最大化完成，最终状态由 Host 事实确认。会话/刷新状态不是双击历史，不因“删除状态机”一并删除。

## F6. 删除边界与规范同步

生产替换必须在同一完整变更中收口：

- 全局 document.pointerdown，以及本次局部化后失去职责的 document.click。
- 业务 pointer.reset、blur reset、原生边缘 reset、first_press、配对时间/距离/窗口矩形状态、旧 pointer wire/DTO。
- 不再使用的回调、常量和仅验证旧内部协议的断言；不保留静默 fallback、两个 active 手势引擎或生产开关。

保留已证实的旧失败作为历史证据。原型源码/脚本暂仍有证据复现责任，本次不扩大使用；新路径验收后检查哪些纯原型文件已无合同/证据职责再删除，保留被正式验证入口复用的输入驱动。历史只靠 Git 与现有证据追溯，不另建 active archive。

实施时只同步真正变化的真源：

| 真源 | 本次责任 |
| --- | --- |
| Renderer Bridge 合同 | gesture wire、mode、局部入口与授权、响应/清理语义 |
| UI 设计规范 | F2 的 Windows 行为变化；布局与业务隔离不变 |
| 高层架构 | drag owner 不再持有首击历史；SDK 缺口和原位删除条件 |
| validation | 新行为判据、原生授权及实机证据边界，旧证据保持原意 |
| app.zon / 生成输入 | 精确 command catalog；不放宽来源或任意 action 权限 |

不修改 AGENTS.md、SDK 依赖政策或无关规范。规范中旧“证据不足保留 Host 状态机”的约束在迁移获准前有效；推荐稿和合成测试不能解除它。迁移获准后，按 F2 明确更换行为合同，而不是遇到测试失败才改预期。

## F7. 实施 DAG 与提交边界

不继续“原生子窗口原型 → 新区域协议 → 正式替换”的旧路径。恢复实施时，将未完成 DAG 的职责对齐为以下顺序；旧 A failed、A2 的有限 completed 结论保持，不能用于证明新路线。

1. **行为与接口基线。**接受 F2 后同步实施范围，固定稳定版来源和预期表；补齐局部绑定、双击分支、权限/fixture 的回归用例。源码逻辑对照可纯本地执行，但不冒充真实点击计数。
2. **完整单路径替换。**在开发分支同时接入标题栏生命周期、typed gesture、Windows 原语与 macOS 适配，删除旧监听/首击/reset；运行类型、Renderer、Bridge、Native 定向验证和 guard。不先合入“只删除入口但没有替代”的断档提交。
3. **真实产品验收与清理。**通过正式产品路径运行 F8，绑定当前 artifact；收口失去职责的原型材料与验证记录，检查没有旧路径残留。

已启动 goal。TinyKG decision 3186 将稳定任务 ID 对齐为 B1 行为/接口基线、B2 局部 DOM/模式/生命周期回归、C 完整链路替换和自动验证、D 真实产品证据及清理；旧原型下一步不再适用，旧实验完成不证明新路径。

每个 DAG 子任务完成都评估是否提交，但任务数量不等于提交数量。以独立可审阅、可构建、可验证为边界：完整替换及其合同/回归应成一个一致单元；真实输入验证扩展和有独立价值的清理可另提交。不要逐个补丁产生检查点，也不要把全部实现、验证工具和无关文档压成一个大提交。已有四条提交不在本轮再次重写；本次计划先保留工作树修改，不单独制造提交。

## F8. 验收与停止条件

### 自动化

- 稳定版原脚本分支对照：普通双击、给定 1/2/3/4、1/1/2、失焦 1/2，确认采用的 Windows 分支；JS 只供应序列，不能证明浏览器会产生该序列。
- 局部绑定：首次渲染、AccountGate/Workbench 切换、StrictMode、节点替换/卸载、迟到 connect、dispose 后事件；每次有效输入最多一个命令。
- 目标排除：button/SVG、disabled、inert/no-drag 外层、可编辑/可聚焦内容、disclosure、portal、控件取消 pointerdown/传播；普通内容不被全页窗口 handler 观察或发送手势。
- Bridge/Host：新旧 command 与字段的严格接受/拒绝，旧 generation、错误窗口、无当前主键、错误 native hit、top-band 越界、隐藏/销毁/断连、迟到响应；两种 Windows gesture 都测试授权。
- macOS mode 分支与 SDK 调用次数，禁止双重 toggle；Windows 不触发 macOS 路径。

按验证规范运行 frontend typecheck、受影响 Renderer suite、跨语言 fixture/Bridge tests、window-chrome Zig root、architecture guard；共享 Native graph 真正受影响时运行正式 graph。缺 canonical AgentCore bundle 明确失败，不跳过后报通过。

### 真实 System WebView 产品路径

先测最可能否决接入的真实界面：AccountGate/Workbench、动态 actions、菜单/modal/portal、设置 inert 外层、窄窗、缩放与 DPI。记录当次 native composedPath、mousedown.detail、Bridge 意图和原生执行结果；这些只由验证探针记录，不能进入生产手势历史。

再覆盖普通/最大化拖动恢复、默认及非默认双击时间、正负距离边界、三/四击、内容/相邻 normal/disabled/取消 pointerdown/stopPropagation 控件插入、失焦、原生边缘按下但不改变尺寸。期望按 F2 和实际浏览器计数计算，不再要求 down/reset/down，也不把所有插入场景一律判为“必须不 toggle”。业务事件自身零手势命令及当前手势的原生授权始终是硬要求。

验证复制/编辑/选区及按钮操作不受窗口 handler 取消；保留既有剪贴板检查，不把其他复制问题归因于窗口链路。验证正常绘制、上沿/上角 resize、关闭隐藏、Alt+F4、托盘重开、reload 和 clean shutdown。不重跑已经退出路线的透明 child 绘制/资源矩阵。

不必另搭一个 Tauri 应用作为前置；固定源码对照只证明动作选择，正式产品的真实输入证明实际执行。若出现与参考机制不一致且不能解释的失败，停止合入并形成最小反例，不临时改算法/加计数状态/删断言，也不自动改换路线。

每份实机证据绑定 revision/diff、binary hash、OS、Native SDK 和 WebView 版本。macOS 独立验证当前 SDK 输入时机及双击偏好；Windows 10/11、混合 DPI、负屏幕坐标分别记录覆盖。touch/pen、系统菜单、snap 等未闭合能力不借鼠标通过宣称完成。缺失必需平台证据时如实保留未完成项，不将方案定稿标为实施完成。

## F9. 三轮复盘结论与当前证据

| 复盘问题 | 收口结果 |
| --- | --- |
| 第一轮：是否仍用旧 Host 规则筛掉 Tauri，再另造机制？ | F1 固定稳定版和对应依赖，F2 明确采纳点击语义及差异，不再声称旧中断逐项等价 |
| 第二轮：局部化会不会漏挂、吞控件或迫使布局协调？ | F3 绑定真实节点生命周期，沿实际 DOM 路径排除，保留 inert 外层；没有原生区域副本或业务 ACK |
| 第三轮：是否借“最小适配”引入新引擎或丢授权？ | F4/F5 的 mode 只分已有平台能力；两种 Windows 动作共享授权；无首击缓存、重试、双重 macOS 执行或生产 fallback |

已有稳定版原脚本的 6 组内存 JSDOM 逻辑检查确认：正常 1/2 请求 drag/toggle；控件插入 1/2/3 只请求首击 drag；控件重锚 1/1/2 与失焦 1/2 均请求 drag/toggle；固定 1/2/3/4 只有前两次动作；bare marker 的后代不拖动。这不是实机 Tauri 应用或新 MetaWork 路径验收。首次 Node 直接下载因网络超时未执行检查，改用只读下载后通过；不把失败尝试计为通过。

三轮复盘没有证明“所有环境无风险”，而是将方案收敛为一条有明确行为、调用链、失败语义和验收边界的路线。定稿时生产尚未改动；后续实施授权见首页，验收仍需新路径自己的证据。

## 历史原型与纠偏记录

以下第 12–15 节保持历史原意。旧章节引用对应 Git `3e725c69` 中的旧方案，当前执行建议以 F1–F9 为准。

## 12. A 阶段已批准的精确边界

2026-09-19 用户在明确以下边界后回复“那继续吧”，批准 A 原型及其必要的 capability / exact-symbol 更新。只登记实际使用的符号，不放宽其他 Gate。生产路径仍保持原状；本节不构成 A 验证通过、实际 UI 边界闭合或生产替换批准。

| 范围                    | A 原型所需变化                                                                                                                         | 保持的限制                                                                                             |
| ----------------------- | -------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| Windows drag capability | 在现有 drag owner 中验证一个同 UI 线程、初始隐藏的输入子窗口；只接受原型拥有的固定正向片区，经原生 top band 与 resize 占用区裁剪       | 不接收生产 DOM 区域、不新增区域 wire；不递归 subclass WebView、不访问 SDK 私有对象、不改变生产手势分发 |
| 输入资源创建与清理      | `CreateWindowExW`、`RegisterClassExW`、`GetModuleHandleW`、`DefWindowProcW`、`DestroyWindow`、`GetWindowLongPtrW`、`SetWindowLongPtrW` | userdata 仅属于自己创建的 child，不读取 SDK 窗口 userdata                                              |
| 线程、显示与几何        | `GetCurrentThreadId`、`GetWindowThreadProcessId`、`GetClientRect`、`IsIconic`、`IsWindowEnabled`、`IsWindowVisible`、`IsZoomed`        | 只检查已绑定 root 和自有 child，不查找任意窗口、不建立第二份 SDK 窗口状态                              |
| 同线程生命周期与层级    | `SetWindowSubclass`、`RemoveWindowSubclass`、`DefSubclassProc`、`RegisterWindowMessageW`、`GetWindow`、`SetWindowPos`                  | root 回调只维护输入资源及观测 move loop；drag 不自行置顶、不将根窗 hit-test 作为 WebView 输入替代路径  |
| 实际形状与诊断          | `SetWindowRgn`、GDI `CreateRectRgn`/`DeleteObject`；`GetCapture`                                                                       | A 只需裁剪后的单个矩形及空区域，不预增任意形状能力；capture 只读观测，不恢复应用层手势缓存             |
| resize 与 Application   | resize 暴露其已经计算的有效占用事实；Application 组合更新顺序和相对层级                                                                | 两 seam 不相互 import；不复制 OS 边框计算；原有生产 resize 行为与 reset 回调暂不删除                   |
| guard 与验证            | 仅对实际使用的精确符号、所属库和 owner 增补断言；原型入口单独列出，标准构建不激活它                                                    | 既有私有 context、错误 owner、未登记符号与单一路径约束保持；不得通过把代码挪到 probe 文件避开检查      |

以上列出相对现有 drag allowlist 的 24 个新增符号上界；落地只登记实际使用项，额外需求另行说明，不以这份上界放开通用 Win32。A 固定区域原型若通过，仍不批准动态 DOM 镜像或任何产品交互范围调整。

## 13. A 原型实施与有限证据（2026-09-19）

本节及第 14 节按实验顺序保留历史结果和当时的下一步，不是当前执行清单。最终固定原型结论见 14.6，当前产品接入状态见第 15 节。

A 的首次候选已被 §14 的反例否决，TinyKG `3146` 以 `failed` 关闭，B1/B2/C/D 不解锁。以下记录首次基础验证的有限范围。生产 `State` 与 Renderer 输入路径未替换；新增入口只在显式 `-Dwindow-chrome-probe=true` 构建中运行。原型复用启动 binding、resize 的实际占用事实和 Application window-controls，不含首击缓存或 Renderer 窗口手势命令。

当前实现已验证的范围：

- Architecture suite `27/27`，Window Chrome Zig tests `30/30`；包括固定矩形裁剪、无效 binding、重复 attach/detach、child-first/root-first 和创建过程中销毁宿主。最后一个重入用例没有复现安装误报，因此不把此前的审查疑问写成已发现的缺陷。
- 标准产品 Debug 构建与隔离原型 Debug 构建均成功。标准入口仍为 `src/main.zig`；原型不属于生产 fallback。
- 用户在 Windows `10.0.19045`、WebView2 `153.0.4234.32`、SDK `0.10.1` 上人工双击两次并拖动，回复“好了，没发现异常”。该原型二进制 SHA-256 为 `F178E9498EAC0981C1DA0EB023462422AB49F0F27B500EB3710A7E3BFE33E178`。原生日志分别记录 `WM_NCLBUTTONDOWN → WM_NCLBUTTONDBLCLK`（间隔 156 ms、172 ms），各一次 maximize/restore；普通拖动有 `WM_ENTERSIZEMOVE/WM_EXITSIZEMOVE`，窗口矩形从 `104,104,1298,871` 变为 `221,142,1415,909`。

**上述人工记录只证明该二进制的基础交互。**首次构建未冻结完整源码 diff；不能以该记录证明当前工作树整体，更不能扩张为双击中断、paint 或实际 UI 一致性验收。原始日志保留在本地 `zig-out/drag-probe/evidence/manual-fe0c1543e6ed4b6486877b68a13c135f/stderr.log`。Computer Use 的截图失败（`SetIsBorderRequired: 0x80004002`）及其后的坐标失败没有产生测试鼠标输入；后续 Esc 停止工具也不是原型失败证据。

后续可重复入口为 `node scripts/run-window-drag-probe.mjs`。它使用已验证的 canonical bundle、独立的每次运行 artifact/profile，构建前后核对源码 identity，保存 patch、未跟踪文件 hash、二进制 hash、OS/SDK、实际 WebView2 版本和原生日志；不注入桌面输入，也不把进程正常退出判为验收通过。`--build-only` 只构建取证、不启动窗口，已运行成功。启动后用 `Ctrl+Shift+Q` 正常退出；15 分钟 watchdog 仅用于原型进程收尾，不参与手势判断。

下一步仍是 §8 的精确真实输入矩阵，尤其是阈值内的相邻控件、disabled、stopPropagation、取消 pointerdown、失焦和原生边缘插入。还需证明 resize/drag/控件的实际像素归属、最大化拖动恢复、静止更新/动画/遮挡恢复的绘制，以及失效与实际撤除。没有这些证据，不删除生产旧路径，不将基础交互通过包装为 A 完成。

## 14. A 首次候选否决与后续复盘

用户随后明确批准改用仓库 Win32 输入脚本，只驱动独立原型，不再使用 Computer Use。带完整构建输入 identity 的实验位于本地 `zig-out/drag-probe/evidence/manual-onPLuD/`：revision `64fbb82647c74af22689eaea1f7df85af3199d70`，diff SHA-256 `2d2cc9267065b306fff48bba0ce5f9b0a8f7ac10cf7057688ee193ce859fc7f4`，binary SHA-256 `9979abf33b7a3cdde235dd07a89275854cb4d43c8a71aab8edc815eb70a5e04c`；OS `10.0.19045`、WebView2 `153.0.4234.32`、SDK `0.10.1`。`identity.json`、`source.patch`、版本文件和原始日志保留在那里。

`probe-windows-window-chrome.ps1 -Mode input-case -InputCase pair -PointX 300 -PointY 20` 通过；同一 PID 的 `blur-reset` 连续失败两次。系统时间阈值 500 ms、距离范围 4×4 px、DPI 96。日志摘录如下，两次第二击均错误触发最大化，脚本返回非零：

| 尝试 | 首击 A1 tick | 原生失焦 tick | 原生回焦 tick | 第二击 A3 tick | 两击间隔 |
| ---- | ------------ | ------------- | ------------- | -------------- | -------- |
| 1    | 820451687    | 820451937     | 820452015     | 820452109      | 422 ms   |
| 2    | 820506859    | 820506984     | 820507062     | 820507156      | 297 ms   |

两个序列都在同一点，配对前窗口矩形为 `100,100,1000,720`。SDK `deactivate/activate` 日志与原生 `WM_ACTIVATE` 互证。脚本 finally 核验恢复原始双击时间；最后通过原型退出快捷键取得 `child-destroy → detached → window_closed → stop`，进程 exit code 为 0。正常退出不改变失败判定。

**结论：保留同一个输入 child、直接依赖 OS 双击消息，不能满足既定失焦中断语义。**这否定的是当前候选，不是证明所有原生方案都不可行，也不是批准取消失焦中断。按关键失败退出条件停止该候选，TinyKG 验证 `3157` 关闭 A `3146` 为 failed；后续复盘任务为 `3158`。

下一步先区分“只缺原生激活边界”与“WebView 跨 HWND 点击本身也未中断”：使用同一固定原型做有界诊断。若确实只有激活边界缺失，才评估将输入资源有效期约束到原生激活边界的替代候选；它必须不吞回焦首击，保持后续完整双击/拖动并重跑整个 A 矩阵。不得用一个忽略下一次双击的布尔补丁、重建手势缓存或放宽用例掩盖问题。任何新候选没有完整证据前，B1 仍不解锁。

### 14.1 跨 HWND 插入诊断与下一项有界实验

后续诊断 artifact `manual-MZZJ8x` 仍为上述 binary `9979abf3…`，基于 checkpoint `0f327dc8f32df676a18b58ee8caa95969142b80a`。在 DPI 96、500 ms、4×4 px 阈值下，标题点 `(467,120)` 与相邻控件点 `(468,120)` 跨越真实 child 边界，仅隔一个物理像素。控件命中为另一进程的 `Chrome_RenderWidgetHostHWND`。最终脚本同时核对两次标题命中、控件命中、时间阈值和窗口矩形不变；早先窗口发生位移的一轮作废，不以“未 toggle”计为通过。

正常控件两轮原生消息为 A1/A1，间隔 188、218 ms。disabled、取消 pointerdown、stopPropagation 三轮分别为 A1/A1，间隔 203、218、203 ms，均无 toggle；对应控件日志均为 trusted 输入。disabled 只有 pointerdown；取消 pointerdown 时有 pointerdown/click 而无 mousedown；传播阻断时三种事件仍在控件本地记录。CDP 只设置 fixture 模式，不作为受测输入。原生日志允许夹有人工操作，结论只对应上述已校准序列，不把整个进程的其它输入视为脚本证据。此结论不覆盖整个 §8，也不证明所有 WebView/OS 版本。

下一项实验只改隔离原型：在 `WM_ACTIVATE/WA_INACTIVE` 同线程撤销旧 drag child 并创建新的隐藏 child，再按现有 resize 事实恢复固定命中；回焦事件不替换 child，避免在 click-to-activate 路径撤走正在命中的对象。根窗口、SDK 生命周期、Renderer 和生产 State 不变，不引入点击历史、吞下一击布尔或全局记录器。代价是失焦时产生原生资源创建/销毁；这不是已有成熟方案的等价复刻，只有实测能判断是否值得继续。

`DestroyWindow` 的公开合同没有承诺清除双击配对；此实验检验新的 HWND 身份是否形成可靠边界，不能用生命周期单测替代真实输入结论。最先重跑原失焦反例，再验证回焦首击拖动与随后完整双击；任一失败即停止此变体。即使局部通过，也须重跑 A 完整矩阵与资源/绘制验证，不能解锁 B1。

### 14.2 激活边界变体的结果：局部通过，等价验收失败

本地 `manual-AsNxfT` 绑定 revision `0f327dc8f32df676a18b58ee8caa95969142b80a`、构建 diff SHA-256 `a8c93c1c829b789af254a1249d7d705961f6d5f0516e84fdfdf8074392a67910`、binary SHA-256 `11451b7ad4dc9686ce20f38150e1b8794c1834200d45118331f9667bdfe4b1f6`；OS/SDK/WebView2 与 §14 相同。原生实现构建后未改。运行期间补充的 PS 探针另绑定 SHA-256 `3dff7577ba2567a1f0c8411b66fc6a1e7ebcf8e72188ed1345a49fa006bad856`，不冒充已包含在构建前冻结的 diff 中。

- 原 `blur-reset` 通过：标题首击 tick `821618968`，失焦时 old child `0x350e6c` 被销毁并换成 `0x360e6c`，返回按下 tick `821619328` 为 A1，无 toggle。
- `probe-blur-repair` 通过：旧首击 `821695203`，新 child 上首击 `821695515` 仍为 A1，下一击 `821695671` 为 A3 并最大化。不是以吞下一次双击实现中断。
- `probe-blur-drag` 通过：另一原生窗口保持前台，返回首击 `821697796` 同时激活并进入 move loop，窗口从 `100,100,1000,720` 精确移动到 `180,148,1080,768`。没有程序化预激活或额外点击。
- `edge-reset` 通过：标题 `(408,108)`、上沿 resize `(408,107)`、标题 `(408,108)`；两条 A1 相隔 203 ms，期间真实 resize-press/move-loop，窗口矩形不变且无 toggle。
- 同点 `pair` 和 `timeout` 通过。32/32 Window Chrome Zig tests、27/27 architecture tests 和隔离构建通过；生命周期单测包含 20 次失焦资源替换及创建期间 root 销毁回滚。

**继续运行未修改预期的 `distance-inside` 时失败两次，因此停止该变体的验收。**本机系统距离矩形为 4×4 px。旧 Host 对 `abs(dx) <= width/2` 接受，即向右偏移 2 px 时应 toggle；新原生候选两次都收到 A1/A1 而非 A1/A3：

| 尝试 | 首击 tick / 坐标 | 第二击 tick / 坐标 | 间隔 | 实际结果 |
| ---- | ---------------- | ------------------ | ---- | -------- |
| 1 | `821761843` / `(408,120)` | `821762000` / `(410,120)` | 157 ms | 无 toggle，脚本失败 |
| 2 | `821826015` / `(408,120)` | `821826171` / `(410,120)` | 156 ms | 无 toggle，脚本失败 |

四次按下均到达同一 native child，窗口矩形稳定为 `100,100,1000,720`，没有中间失焦。这里证明的是旧 Host 与原生候选的距离边界不等价，不宣称 Windows 自己的双击实现有 bug，也不把该差异归因于失焦资源替换。原型通过快捷键 clean shutdown，exit 0；上一轮 `manual-MZZJ8x` 因退出时前台条件不足未发送快捷键，最终由已有 watchdog 正常退出，同样 exit 0。

当前复盘结论：跨 HWND 插入并非已测场景中的主要缺口，激活资源边界可以闭合已测失焦反例，但原生双击不能直接视为旧 Host 判定的精确等价物。后续不能靠恢复点击缓存或偷偷修改距离断言收口。须先明确对这项具体行为差异的处置；在既定等价要求下，该变体尚不可实施到生产。A/B1 继续未闭合，未执行的非默认时间、其它输入/绘制/资源/平台矩阵保持未验证。

### 14.3 标准 Windows 标题栏对照：旧 Host 的右边界多包含一列像素

为区分输入 child 缺陷与旧 Host 自定义判定差异，在同一 Windows 10 / DPI 96 桌面用独立标准 WinForms caption 作基准。该 Form 的 override 只记录收到的 A1/A3、`GetMessageTime` 和屏幕坐标，然后原样调用 base WndProc；不自制分类、不改命中、不转发输入到产品。每一击前确认真实 `HTCAPTION` 与前台归属；每组确认两次消息、间隔小于 500 ms，同点组另确认正常最大化。

命令为 `powershell.exe -NoProfile -File scripts/probe-windows-window-chrome.ps1 -ProcessId 12744 -Mode input-case -InputCase native-distance-reference`。脚本 SHA-256 `b16f6724f8bbc9dc368a613865bdfd4e2c165aa9a5a6554c997409ca25e4b010`；基础 revision `2495af5a5477ce3787d00334381ba99d01ff3936`。下表转录自该次命令的完整 stdout（执行输出 `9a73c8`），不是原型二进制的 A 验收。两击 y 均为 238，首击 x 均为 460，`wParam` 均为 `HTCAPTION=2`：

| 第二击 dx | 两击 tick | 间隔 | OS 消息 | 最大化 |
| --------- | --------- | ---- | ------- | ------ |
| 0 | `822135796 → 822135953` | 157 ms | A1/A3 | 是 |
| +1 | `822136750 → 822136906` | 156 ms | A1/A3 | 是 |
| +2 | `822137703 → 822137859` | 156 ms | A1/A1 | 否 |
| -2 | `822138640 → 822138812` | 172 ms | A1/A3 | 是 |
| -3 | `822139609 → 822139781` | 172 ms | A1/A1 | 否 |
| +3 | `822140546 → 822140718` | 172 ms | A1/A1 | 否 |

`GetSystemMetrics` 明确给出的是双击矩形的宽/高，`PtInRect` 的公开矩形语义包含左/上边界、不包含右/下边界。上述水平方向实测与此一致；这里只是结合文档作解释，不声称已取得 Windows 双击内部实现或验证了垂直方向。旧 Host 的 `abs(dx)*2 <= width` 在 width=4 时接受五列像素 `[-2,-1,0,1,2]`，与本机原生 `[-2,-1,0,1]` 不同。因此 §14.2 的 +2 结果与标准 caption 一致，不能作为 child 输入丢失的证据。

第一轮输出因为 JSON 默认深度不足未保留 samples，未计为完整证据；修正序列化后得到上表。后续为保存独立 JSON 文件而增加输出功能的尝试被前台归属检查中止，没有产生证据文件，也没有重试绕过检查；未验证的文件输出功能已撤回。标准 Form 均已 dispose，关联原型 `manual-dMsP2q` 通过快捷键正常退出，exit 0。其 artifact 仍为 §14.2 的 `11451b7a…`，只负责隔离会话，不代表该二进制拥有标准 caption 对照结果。

建议：后续候选采用 Windows 原生距离边界，并增加正/负方向的内点、边界和外点验证，不为旧自定义闭区间重建点击缓存。由于现行 validation 要求既定行为等价，已单独请求这项具体边界变更的确认；尚未据此修改生产判定、既有失败预期或规范真源，B1 仍未解锁。原生判定取舍不能顺带放宽失焦、中断、绘制或其它 Gate。

依据：[GetSystemMetrics](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getsystemmetrics)、[PtInRect](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-ptinrect)。

### 14.4 用户批准原生距离边界，恢复 A2 验证

2026-09-19 用户在上述差异说明后明确回复“可以的”，批准采用 Windows 原生距离边界并同步对应合同和测试（TinyKG decision `3165`）。这解除的是距离预期阻断，不是认可整个候选已通过，也不放宽其它 Gate。唯一规范更新落在 validation 的 Windows 双击替代验收责任；Bridge wire 与生产 State 尚未替换，不在本阶段宣称新协议生效。

A2 任务为 `3166`，真实输入子任务 `3167`，绘制/组合/资源子任务 `3168`。它们通过后才重新安排 B1 依赖；旧 A `3146` 及 §14.2 的历史失败不改写成成功。原型使用新增四方向边界矩阵，不再以旧 `distance-inside` 的闭区间预期判定原生候选；该旧测试仍覆盖尚未迁移的生产路径，C 时随旧实现一并收口，不能长期维持两套生产语义。

### 14.5 A2 输入矩阵通过，绘制/资源尚待验收

`node scripts/run-window-drag-probe.mjs --input-matrix` 完整通过 20 个具名用例并正常退出。证据为本地 `zig-out/drag-probe/evidence/manual-yWps7O`：revision `ac7a5c74fbb85e704e1587824f508a94ead5617e`，diff SHA-256 `db06bd5cd58dc2274b661a0c9df23c7eb2a7418104a6761865730353428a74d1`，新增矩阵脚本 SHA-256 `131861b597f846dd5b1a829ea2447fc0e41ab3041b42bccdb393ce3921c79d53`，binary SHA-256 `11451b7ad4dc9686ce20f38150e1b8794c1834200d45118331f9667bdfe4b1f6`。OS `10.0.19045`、SDK `0.10.1`、WebView2 `153.0.4234.32`、DPI 96。identity、源码 patch、逐例 `input-matrix.json`、原生日志和退出结果均保存；之后仅格式化 JS 及补充说明，没有改受测 native 实现。

距离矩阵覆盖 x/y 各 `-3,-2,-1,+1,+2,+3` 共 12 个点；两轴均为 `-2,-1,+1` 配成双击，`-3,+2,+3` 不配对。其它用例覆盖同点双击、超时、900 ms 下双击/超时、三四击、内容/控件/相邻 normal/disabled/取消 pointerdown/stopPropagation 插入、相邻原生边缘插入、失焦、失焦后重新双击、回焦首击拖动、普通拖动、最大化拖动恢复以及控件/内容不拖动。每例同时核对实际 A1/A3 数量和 toggle 次数；距离点还核对实际间隔，相邻控件记录 trusted DOM 输入，拖动核对进入/退出 move loop。系统双击时间在每例 finally 恢复并读回核验。进程 exit 0 不单独充当通过证据。

新增入口复用既有隔离 WebView 调试连接，HTML fixture 用精确 title/data URL 选择；CDP 只准备局部控件模式，不合成受测输入。原先产品 origin 的默认连接规则不变。Architecture 与现有 Window Chrome Node suite 共 `37/37` 通过，脚本语法、格式和 diff 检查通过。这里完成的是输入子任务 `3167`，不是 A2 总体验收；屏幕静止更新/动画/遮挡、资源稳定、生命周期和原生层组合仍由 `3168` 验证，B1 不提前解锁。

### 14.6 A2 绘制与资源闭合：修复原生显示完成边界

绘制矩阵先通过五色静止更新/遮挡恢复、九次真实上沿和上角 resize、实际层级命中及连续动画。资源测试的辅助 Form 在第二次程序化激活时被 OS 拒绝（`manual-sLDKIH` 的 `SetForegroundWindow=false`），因此未计作资源通过；补消息泵并不能消除该限制。随后以用户已授权的真实鼠标输入在两个测试拥有的窗口之间切换，每次先核对真实命中；辅助 Form 改为无边框，避免硬编码点落到非客户区。没有取消前台或所有权断言，也没有增加强制前台权限调用。前置检查失败的 `manual-HcQQso` / `manual-sLDKIH` / `manual-3s9Mlb` 日志保留，不计作完整验收。

`manual-yiwK5M` 在完成 35 次实际失焦/回焦后，发现 **隐藏再显示未恢复 drag child**，因此该轮仍失败。该轮绑定 revision `28d4726024b19dd7b49173dcd3c9b711651e277a`、diff `16d6d32e44ef51de5df232fba7e1dc06ea6426e1950296ff230259fa91d5e441`、旧 binary `11451b7a…`。新增 Native 回归使用真实 `SetWindowPos` show/hide、不改变尺寸、不手工 refresh：旧实现在显示断言失败。原因是 `WM_SHOWWINDOW` 时根窗的可见状态仍可能尚未提交；只在该回调中重新计算不足以恢复输入。修复只在原型 owner 的 `WM_WINDOWPOSCHANGED` 的 SHOW/HIDE flags 上，按已完成的实际状态重新计算；没有加定时器、输入缓存、SDK API 或全页监听。回归同时约束隐藏时必须撤销输入，最终 `33/33` Window Chrome Zig tests 与 `37/37` Node tests 通过。[原生显示通知](https://learn.microsoft.com/en-us/windows/win32/winmsg/wm-showwindow)、[位置变更完成通知](https://learn.microsoft.com/en-us/windows/win32/winmsg/wm-windowposchanged)。

修复后的两个完整入口均 exit 0，代码在两次构建/运行间没有变化：

| 入口 | 本地证据目录 | 结果 |
| ---- | ------------ | ---- |
| `node scripts/run-window-drag-probe.mjs --surface-matrix` | `zig-out/drag-probe/evidence/manual-pVmaA1` | 16 步全部通过 |
| `node scripts/run-window-drag-probe.mjs --input-matrix` | `zig-out/drag-probe/evidence/manual-TY3gOT` | §14.5 的 20 个具名用例全部复验通过 |

两份 identity 均绑定 revision `28d4726024b19dd7b49173dcd3c9b711651e277a`、diff SHA-256 `73272ea9943039f6edbe64bfe833af20bb6dd7056e88e6fbac49b485f8efc200`、新增 surface 脚本 SHA-256 `bf17cba30d7f5f25b0688757925f6b24ea3217b116021a7b5d7b525df6d4fe4b`、binary SHA-256 `eff851d28fe78c3f459e1470839b5321ac1fa56486d44d0fbd7fd5170fca9f9e`。环境为 Windows `10.0.19045`、x64、SDK `0.10.1`、WebView2 `153.0.4234.32`、DPI 96。各目录保留 source patch、identity、逐例 JSON、原生日志、截图（surface）及退出结果；本节是事后证据摘要，不冒充已包含在受测 diff 中。

surface 结果包括：五种颜色均在任何 resize/遮挡修复之前通过实屏像素采样，随后变宽、覆盖和恢复也通过；10 帧动画有 10 种不同图案，drag 下方 120 px 与同帧未覆盖参照区逐像素一致；九次真实 resize 的 USER `29→29`、GDI `13→13`。35 次真实点击激活循环逐次确认旧 child 销毁且只有一个新 child，预热后的 USER 首尾 `32→32`、范围 `32..33`，GDI 首尾 `13→13`、范围 `13..15`。隐藏、最小化及恢复通过，随后实际 resize/drag/WebView 命中顺序再次通过；清理日志包含 child destroy、detach、window closed 和 stop。像素证明不使用 CDP 截图，CDP 只准备受测页面内容。

结论：`3168` 完成，结合新二进制的输入复验和已有创建回滚/两种销毁顺序测试，A2 `3166` 满足固定原型的阶段条件，可以把 B1 的依赖从已失败的旧 A 改为 A2；旧失败记录不变。该实现和验证可独立审阅，按用户要求及时提交。它不证明真实产品布局、动态覆盖层、SDK close/hide/托盘/reload 全链路、混合 DPI、Win11、touch/pen、系统菜单/Snap 或 macOS；这些仍须按 B1/B2/D 明确验证，不能直接进入 C。生产 `document.pointerdown`、first_press/reset 和 wire 均未移除，产品区域范围和浏览器缩放行为没有改变。

## 15. B1 实际界面审计与方案纠偏

实际 UI 审计基线为 `48d9f9840adb0fe464edaa2cabda10d78f99dd30`。A2 已通过；B1 `3147` 仍未完成，B2 与生产替换未开始。原文提出的额外拖动带在用户指出方案偏离后撤回；本节保留有效的静态审计，替换其实施与等待批准的指令。

### 15.1 固定测试矩形不能原样移植

| 实际页面/状态 | 当前唯一事实与风险 | 对设计的约束 |
| --- | --- | --- |
| AccountGate | `AccountGate.tsx` 的同一 header 有品牌、语言菜单和窗口按钮，使用 space-between；窗口按钮总宽 138 CSS px | 在 320 CSS px 视口下，右侧按钮占据 `[182,320)`；测试片区 `[200,360)` 即使裁到视口仍会覆盖按钮，不是可用空白 |
| Workbench | `AppShell.tsx` 同一 header 有左栏开关、搜索、条件 contextContent/headerActions、Task Panel 开关及异常入口；grid 列宽依赖左栏宽度与内容 | 不能按某次截图扣几个固定按钮矩形；变化由正常 React 提交拥有 |
| 设置/其它覆盖层 | header 的业务部分可 inert；`Dialog.Backdrop` 是 fixed inset-0，Popover/SelectionMenu 使用 portal | 弹层可在原生输入片区之上绘制；DOM z-index 不能把点击放到原生 HWND 之前 |
| 字体、语言与浏览器缩放 | 当前控件大小、文字截断和菜单布局均由 WebView 计算 | CSS 空白不是原生保留区；固定缩放也不解决动态覆盖层。纯 vw/vh 镜像还需面对 native resize 与 WebView 布局/呈现不同时提交的问题 |

证据入口：[AccountGate](../frontend/src/features/account/AccountGate.tsx)、[AppShell](../frontend/src/app/AppShell.tsx)、[共享 Dialog](../frontend/src/components/ui/dialog.tsx)、[共享 Popover](../frontend/src/components/ui/popover.tsx)、[当前窗口栏合同](../docs/ui-design.md#43-一体化窗口栏)。该结论来自实现和布局规则，不宣称本轮运行了真实产品界面的输入测试。

工程结论：在 WebView 内仅声明一块不放按钮的区域，仍然没有解决全视口覆盖层和两套布局事实；不能把 A2 的固定输入成功当作这种布局已安全。不重新提出被排除的全局记录器，也不把 business ACK 屏障换个名字恢复。

### 15.2 官方能力复核及其边界

2026-09-19 查询[官方发布列表](https://github.com/vercel-labs/native/releases)，最新仍为 `v0.10.1`，没有已经发布的新版本可用于消除 §2.2 的能力缺口。没有拉取未发布源码或改依赖。

当前固定包存在另一个公开机制：`Runtime.updateView(window_id, "main", .{ .frame = ... })`，公开导出在 `src/runtime/core.zig:703`；`window_view_runtime.zig` 的 main 分支同步维护 SDK Runtime 的 main frame，再交给平台。Windows `native_sdk_windows_load_window_webview` 为启动 main WebView 建立独立 STATIC child；`set_webview_frame` 路径会调整该 child 及 controller bounds。这个 API 调整的是整个视口边界，不提供 DOM 拖动区域语义，不能补齐 2.2 的缺口。

这是源码确认的 public capability，不是实机通过证据，本任务不再推进该 frame 改造。不能绕过 Runtime 直调 `PlatformServices`、读 SDK context 或自行挪动 SDK child，也不能从 Runtime 记录反推实际 HWND 已成功移动。主 WebView 的 zoom setter 在 Windows 平台明确返回 `UnsupportedMainWebViewZoom`；这一事实不构成关闭缩放的理由或授权。

### 15.3 撤回额外拖动带及等待批准的前提

原候选在窗口顶部增加 32 DIP 原生带，并将整个 WebView 下移；100% 缩放、DPI 96 下顶部占用由约 40 增至约 72，窗口按钮下移，内容空间减少，网页弹层也不能覆盖该带。32 DIP 是为候选自行选取的尺寸，不是系统要求，更不是移除全局监听的必要条件。

它把未解决的原生区域/网页布局一致性问题转化为产品布局变更。即使物理分区能够成立，也不能由此证明这种产品代价合理。用户要求的是现有窗口能力的机制改造；执行方未足够早地审查实际 UI，不能把后期发现的实现代价转成反复等待产品让步。

该候选现已撤回，不再实施或请求批准。撤回不改变 A2 的有限实验结果，也不表示已有其他可用替代。旧详细提案由 Git 历史保留，不保留待执行的原型步骤或把标准标题栏换成新的默认选项。

### 15.4 当前停止点与恢复条件

当前事实是：固定原型 A2 已通过；真实 UI 的完整输入路径未成立；2.2 的浏览器原生区域 public capability 缺口仍在；生产全局监听及首击/reset 路径未移除。不能把缺口归结为“用户未批准额外拖动带”，也不宣称已证明所有实现都不可能。

本轮完成计划与 TinyKG 的纠偏及验证后停止，不创建重复等待任务或自动监控。B1 保持未完成，B2/C/D 不解锁。历史验证节点中的等待批准只代表当时状态，恢复任务时以本次纠偏记录为准。

恢复实现必须先有可核查的新事实，而不是原样重复搜索、鼠标测试或选项提问：

1. **存在符合当前边界的完整调用链。**例如官方发布的 SDK 经公开入口支持启动 System WebView 原生区域，或在已有许可内找到另一条明确的公开调用路径；需指出具体 API、可用对象、初始化时机、目标平台及失败语义。不得从头文件、GPU-only 接口或视口 frame API 推导能力已经可用，不把 SDK patch/PR 或等待发布当成本次交付。
2. **先说明产品接入，再开始原型。**在不改变第 1 节界面的前提下，具体解释 AccountGate/工作台、动态操作、modal/menu/portal、最窄窗口和缩放的布局与命中如何一致，以及双击中断、窗口动作、resize 和生命周期由谁负责。仅有固定原生区域或局部 `detail` 判定不满足条件。
3. **以实际机制安排最小验证。**先覆盖会否决该接入路径的真实 UI 场景，再补必要的输入/绘制/平台矩阵；旧 A2 证据只支持未变且确实适用的部分。未闭合前不确定新 wire，不替换生产；没有新事实就保留缺口说明，不要求用户再次作同一决定。

本次只改普通计划与任务控制记录；现有 UI、Bridge、architecture 合同和 Gate 不变。原型源码、测试及证据仍有追溯职责，暂不删除或扩大它们；生产改造完成条件亦不因本次文档提交而缩减。

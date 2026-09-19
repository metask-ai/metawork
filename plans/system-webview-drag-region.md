# System WebView 拖动区域最终建议方案

日期：2026-09-19。分支：`feat/native-drag-region`。任务根：TinyKG `3145`。

状态：用户已批准 F1–F9（含 F2）并使用 goal 实施。B1/B2/C 已完成，完整实现提交为 `47d407b2`；D 的 Windows 完整窗口入口已复验通过，任务栏驱动修复提交为 `a2193b14`。真实普通回复复制、粘贴、键盘选区与清空的事件隔离也已通过；完整 Native/AgentCore graph 与大文本剪贴板检查仍未通过，D 未关闭。用户明确允许保留 macOS 本次接线未实机验证项；macOS 仍调用 SDK/AppKit，不需要新增原生兼容。未通过的验收不因授权而视为完成。

**选定路线：参考 Tauri 最新稳定版的窗口手势机制，在现有标题栏和 Bridge 上作最小适配。Windows 采用浏览器点击计数，不再维护 Host 首击历史；macOS 保留 SDK/AppKit。**不再以 CSS 原生区域能力作为本次前置，不再推进透明输入子窗口、区域镜像、业务 ACK 或额外拖动带。

当前方案只有 F1–F9。已退出的原生输入子窗口原型及阶段记录由 Git 历史保留，不再作为当前构建、验证入口或实施指令；复现基线见文末。

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

保留已证实的旧失败作为历史证据。按用户清理要求，删除已退出路线的原型源码、专用构建入口和脚本，以及共享驱动中的原型专用分支；同步移除其二级能力许可和专用符号 allowlist。正式产品使用的输入、绘制和生命周期验证保留。旧原型复现使用文末 Git 基线，不要求当前工作树保留原型，不另建 active archive。

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

### 实施与验收记录

B1/B2 的提交评估结论为暂缓，避免形成半套 wire；C 完整链路、合同和必要回归一起提交 `47d407b2`。生产代码不再存在全局 document pointerdown/click、首击缓存或 reset 协议；旧 command 只在明确拒绝的负例中保留。原型已退出当前工作树，历史复现转由 Git 基线承担；正式验证入口复用的驱动继续保留。

D 的当前通过范围、精确 artifact 与失败边界统一记录在 [验证规范](../docs/validation.md#e-win-chrome-gestures-20260919)，不将局部 UI 检查通过写成完整 AgentCore vertical 成功。真实 UI 探针的首轮错误包括选择了隐藏的 maximize 按钮、试图序列化 DOM 节点，以及错误要求已关闭菜单从 DOM 卸载；按当前真实组件修正后 AccountGate 通过，未为此修改产品。一次 Ctrl+, 探针未打开设置，原因未定；最终设置验证使用实际账号菜单，不能借此宣称快捷键通过。Workbench 探针通过后完整 Run 在 snapshot chunk 超时，不带探针对照失败于呈现时序断言，均保留失败。

提交评估：D 的实际 UI 验证扩展与证据有独立审阅价值，应独立提交，不为每次探针调整创建提交。完整 Native graph 的既有 history schema Gate 不属于本次窗口改造，不修改或绕过。macOS 的 SDK 能力并无新增缺口；仅记录共用 Bridge/局部入口改动后的实机接线回归未验证。

后续复验已将 110% 浏览器缩放纳入 AccountGate 9 项实际 UI 检查并通过，恢复原缩放成功。两次任务栏恢复超时后，只读诊断重现驱动错误选中 `metawork-site` 的前缀冲突；收紧选择并补回归后，独立 controls 和完整窗口入口均通过，产品二进制未变。详见 [任务栏诊断证据](../docs/validation.md#e-win-chrome-taskbar-20260919)。该修复、回归和证据形成一个可独立审阅的提交，不改既定产品方案。

D 的普通回复复制/编辑/键盘选区隔离已有[独立证据](../docs/validation.md#e-win-chrome-conversation-20260919)。既有大文本复制探针的 PowerShell 自动变量冲突已修正并补回归，但复验在更早的快照读取失败，不能声称大文本或完整 vertical 通过。该事件隔离探针与有因果证据的驱动修复作为一个验证交付评估提交，不为失败重跑单独提交，也不修改产品机制。

D 与 goal 仍不标完成：保留原有剪贴板完整性及 AgentCore 断言，不以重复运行至偶然通过替代快照读取失败诊断；history schema 字段 Gate 与本次实现无关，未经明确授权不修改。macOS 接线实机是用户已允许保留的未验证项，不作为新增兼容开发或再选方案的理由。

## 历史原型复现基线

已退出的 native input-child 原型、专用构建入口、输入/绘制/资源脚本和旧阶段记录可从 Git 提交 `14d75ebb984aa5d728c111a78a508709e661ef26` 恢复；应在独立 checkout 中复现，不恢复为生产 fallback。最初方案及纠偏上下文见 `3e725c69`。

删除旧原型不撤销历史失败，也不将有限原型结果升级为当前产品能力证明。[验证规范](../docs/validation.md) 中的历史证据仍保持各自的 revision、适用范围和结论；当前路线以 F8 和新产品证据验收。

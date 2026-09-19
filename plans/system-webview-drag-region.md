# System WebView 拖动区域原位改造方案

状态：方案纠偏与有限证据记录，尚无已证明可接入现有产品的替代机制。2026-09-19 用户在指出方案偏离后，授权先修正计划与 TinyKG；撤回额外 32 DIP 拖动带，不再等待批准该候选。原改造目标未完成，生产替换不继续推进。本文不是规范性架构 decision record，不自动改变当前生效合同。

日期：2026-09-19。

分支为 `feat/native-drag-region`，TinyKG 任务根为 `3145`。旧 A `3146` 的失败与后续 A2 `3166` 的固定原型通过均保留原义；B1 `3147` 的实际 UI 接入未闭合，B2/C/D `3148`–`3150` 未完成。当前停止点是缺少满足现有界面和输入边界的完整机制，不是缺少用户对 32 DIP 的批准。第 12–14 节是历史授权与实验记录，其中的“下一步”不构成当前执行指令；当前恢复入口见 5.4、7 和 15.4。

## 1. 目标与范围

在现有 `system_webview_drag_region` owner 内完成改造：保留现有一体化标题栏、Windows 拖动与双击最大化/还原，彻底移除全局 `document.pointerdown`，不把全局点击记账改挂到 `window` 或其他事件。标题栏高度、窗口按钮位置、业务内容空间及弹层覆盖/点击行为保持[现有 UI 合同](../docs/ui-design.md#43-一体化窗口栏)，不为适配原生子窗口另加拖动带、整体下移 WebView 或关闭浏览器缩放。

工程动机是减少应用层自行拼接窗口手势历史，而不是把 `document.pointerdown` 这个 API 本身判为错误。当前 `frontend/src/bridge/window-chrome.ts:149` 会把每次符合条件的业务按下转换为 reset，Host 的 `first_press` 又依赖它与失焦、原生边缘等来源共同中断。集中式被动记录器可以减少 IPC，且不要求业务组件接线或等待；但它仍让窗口逻辑依赖全页输入与 Renderer/Host 两侧的连续性状态。本次选择重新审视这一职责分配，而不只优化现有模型的通信次数。

双击识别仍需要输入序列信息。目标是让合适的 OS/WebView 输入机制承担这项职责，不是宣称任何观察都应消失。该取舍同时符合用户此前对“即使不发 IPC、只在本地记录，也完全移除 document.pointerdown”的明确决定。本文件不据此禁止无关组件的正常事件委托，也不把捕获监听等同于阻止业务点击或导致复制故障。

- 普通复制、输入、选区和业务按钮不参与窗口手势协议。
- 页面状态提交、AccountGate 切换和弹层打开不得等待窗口拖动能力的 IPC；移除全局点击耦合后，不得引入全局布局事务耦合。
- 不更换 Native SDK 或桌面宿主，不 patch/fork/vendor SDK，不访问私有 WebView 对象。
- 不引入手势 token、lease、点击编号或自制双击定时器。
- 保留主窗口身份、Application/Bridge authority、关闭隐藏、托盘、显式退出和窗口状态持久化。
- `system_webview_resize` 仍只拥有原生缩放输入；不合并成通用窗口 facade。
- macOS 保留 AppKit 路径，只收窄 Renderer 入口；不照搬 Windows 输入子窗口。

不把“业务点击零手势命令”夸大为“所有业务操作绝不引起任何窗口 IPC”。但是否需要区域发布协议尚未成立，不能先定协议，再要求各业务 owner 配合。

## 2. 已知事实与设计判断

### 2.1 当前能力与参考边界

现有 Windows drag seam 已经通过 `ReleaseCapture` 和 `WM_NCLBUTTONDOWN/HTCAPTION` 调用系统拖动循环。缺口不是没有原生拖动执行能力，而是 `first_press` 依赖全页面 `reset` 才能维护双击连续性。

现有 resize seam 已具备局部输入子窗口、原生命中、启动 binding、DPI/窗口状态更新和销毁清理。它为生命周期实现提供依据，但其窄边缘绘制证据不证明整块标题栏输入区域可用。

Tauri/Tao 的 JS 意图路径与 Wry 的 WebView2 CSS 区域路径是不同机制。前者在 DOM 事件路径确认拖动目标后才调用窗口动作；当前上游脚本仍使用 document 级 mousedown，不能原样满足本任务的输入边界。后者启用浏览器原生区域支持，具体能力见 2.2。自建透明输入子窗口不是这两条路径的同款实现，不能借用其成熟度结论。

### 2.2 Windows 浏览器原生区域：具体 SDK 缺口与替换条件

WebView2 的具体能力是 `ICoreWebView2Settings9::put_IsNonClientRegionSupportEnabled(TRUE)`，Wry 的 Rust binding 对应调用名为 `SetIsNonClientRegionSupportEnabled(true)`。启用后由 CSS `app-region: drag` / `app-region: no-drag` 声明区域；官方文档描述了拖动、右键系统菜单、双击最大化/还原。该设置默认关闭，变更在下一次导航后生效，不能视为可即时切换的布局屏障。[官方 API](https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/win32/icorewebview2settings9?view=webview2-1.0.3537.50)

这条路径的职责优势是浏览器同时拥有 DOM 布局和区域输入语义，MetaWork 不必额外镜像可拖动空白或记录全页点击；不宣称它完全没有边界条件或无需平台验收。

当前固定 Native SDK 0.10.1 的已公开 `set_window_drag_regions` 只覆盖 GPU surface，启动 System WebView 不在覆盖范围；本次对其公开 platform/runtime surface 与 Windows 适配路径的检查没有找到可用于启动 System WebView 的上述设置入口。依赖携带 WebView2 接口声明不等于 MetaWork 已取得可调用的 public capability。能力缺口继续登记在[高层架构 §3.5](../docs/architecture.md#35-native-sdk)，不访问 SDK 私有 context 或 COM 对象，不修改 SDK，也不把等待上游作为本次交付路径。

这里记录的是 Windows 上游等价能力的具体候选。未来官方固定版本若以任何合适的 public API 提供 System WebView 等价区域能力，且通过本文件的平台矩阵，应原位替换并删除失去职责的 Windows seam、wire 和验证分支。删除条件不限定 SDK 必须暴露这个 COM setter，不把 Windows API 当作 macOS 的替换条件。本轮不改写规范中的等价能力删除条件。

### 2.3 两条不同的 Renderer 路线，分别评估

**仅靠 detail 的路线。**局部 mousedown 加 `detail === 2`，同时保留原 Host 首击缓存，不能仅凭这个数值证明双方指向同一次首击。此前 `[1,1,2]` 是浏览器计数重锚的源码模型反例；失焦还有仓库真实证据。它只否定 detail 单独充当连续性证明，不能用来否定下面的记录器。

**全局被动记录器路线。**为准确比较，按下列候选语义分析；不是批准新增协议或监听：

1. document 的 pointerdown capture 记录可信 primary 主键按下。判定必须使用完整的 candidate 与交互排除规则；按钮即使位于标记 header 内，也必须判为非拖动目标。此类按下只令本地 `interrupted = true`，不发窗口命令、不取消事件、不改变焦点或 DOM。
2. 标题按下的 mousedown capture 读取 `detail`，由有效标题动作入口在本次事件内将 `continue = !interrupted && detail === 2` 随 down 同步提交，然后将本地 interrupted 清为 false。单纯观察不消费记录；消费不等待 ACK，也不能让迟到完成回调修改下一次序列。本地初始/新文档状态视为 interrupted，具体动作失败分支仍须验证。
3. Host 在 continue 为 false 时无条件清除旧首击，再处理当前有效按下；为 true 时仍需现有原生资格、首击存在、时间、距离和窗口矩形全部检查。保留失焦、原生边缘、断连与授权失败清理。

两个 capture 观察步骤本身不发 IPC；只有有效标题动作入口发送 down。pointerdown 用于观察、mousedown 用于读取计数不能混用：仓库探针断言 pointerdown.detail 为 0；`ResizableSeparator.tsx:60` 取消 pointerdown，可抑制兼容 mousedown。因此只监听 mousedown 会漏记此类业务按下。[Pointer Events 规范](https://www.w3.org/TR/pointerevents3/#mapping-for-devices-that-support-hover)

以下是给定输入的条件推演，不是实际浏览器计数采样或平台验收。前提是完整资格判定、事件确实到达 capture、请求有序送达及 Host 原生检查正常：

| 场景                                         | 记录器/Host 对末次标题按下的处理                          | 模型结论                              |
| -------------------------------------------- | --------------------------------------------------------- | ------------------------------------- |
| 标题 A → 内容 B → 标题 C                     | B 置 interrupted，C 不续接                                | 不误 toggle                           |
| 标题 A → 相邻控件 B → 标题 C，给定 `[1,2,3]` | B 置 interrupted；C 的 detail 也非 2                      | 不误 toggle                           |
| 计数重锚，给定 `[1,1,2]`                     | B 置 interrupted，C 即使 detail 为 2 也不续接             | 此反例不能否定记录器                  |
| 同位置 disabled 控件插入                     | 若真实按下到达 capture 且被完整规则排除，则置 interrupted | 条件下不误 toggle；事件路径需实机证明 |
| 业务祖先 stopPropagation                     | document capture 先于下层业务处理器观察 B                 | 不因下层冒泡阻断而漏记                |
| 相邻业务控件取消 pointerdown，无 mousedown   | pointerdown capture 已记录 B                              | 不依赖 B 的 mousedown                 |
| 失焦或原生边缘按下，末次 detail 仍为 2       | 保留的 Host reset 已清首击                                | 即使 continue 为 true 也不能 toggle   |
| 正常两次标题按下                             | 第二击可续接，仍过 Host 全部检查                          | 保留正常双击                          |

现有资料没有用上述反例证明记录器不可靠；也没有证明它是唯一候选或已通过全部验收。它可以集中在 Bridge 内，不要求业务 owner 接线，不能与已撤回的业务布局屏障混为一谈。普通下层 stopPropagation 也不是拒绝 document capture 的理由。

本次不选记录器，依据是第 1 节的职责取舍与已明确的输入边界：它优化了 IPC，却保留全页输入记账及跨层连续性状态。技术可行性判断和本次是否选择必须分开。若未来重新选择它，需要明确改变设计决定，并修改 Bridge down 的字段、非拖动点击的中断语义及跨语言 fixture；只能说“Host 不镜像区域”原则可保留，不能说现有 Bridge 第 18/22 行整体不变。

### 2.4 当前取舍，不声称已穷尽所有实现

| 路径                       | 当前结论                                                                   |
| -------------------------- | -------------------------------------------------------------------------- |
| 现有 pointer down/reset    | 替换验证完成前保留的安全基线；确实仍有每次业务按下一次 reset，不算完成改造 |
| 浏览器原生区域             | 职责参考与未来上游替换候选；当前 SDK 公开入口缺失，不能假设可直接接入      |
| 原生输入子窗口             | A2 已证明固定原型的有限输入/绘制事实；真实 UI 接入未成立，退出默认实施路线 |
| 固定专用拖动片区           | 额外 32 DIP 拖动带及整体下移 WebView 的候选已撤回；不等待其批准或继续原型 |
| 被动 capture 记录器        | 已完成上述条件评估，本次不采用；不再用 detail 单用反例否定它               |
| 动态区域镜像加业务提交屏障 | 已撤回；不得要求 AccountGate、actions 或弹层 owner 等窗口 IPC              |

这些是已讨论路径的处置，不是已穷尽所有实现的证明。原型可行性不等于产品适配成立；不能为维护已投入的实现路线而反复要求用户改变产品。当前按第 1 节边界收敛方案，不重新要求选择全局记录器、额外拖动带或 SDK 改造。

## 3. 目标职责

| Owner                               | 职责                                                                                                       | 不承担的职责                                 |
| ----------------------------------- | ---------------------------------------------------------------------------------------------------------- | -------------------------------------------- |
| `WindowTitlebar` 与标题栏布局 owner | 声明自身的拖动意图和交互边界；不取得其他业务 owner 的提交权                                                | HWND、直接 transport、双击计时、阻塞页面提交 |
| browser-side window chrome Bridge   | 局部入口生命周期、严格响应校验；具体输入机制须经第 5 节的可行性判断                                        | 全页事件观察、全页交互元素扫描、猜测窗口真值 |
| Dispatcher                          | 来源、启动窗口、generation、payload 与主线程校验                                                           | 原生资源、双击状态                           |
| Application window owner            | 组合 binding、drag/resize/controls 生命周期；具体调用链随已证明的输入机制确定，不预设必须有两个输入层      | 重建 SDK 窗口生命周期、直接散布 Win32 effect |
| Windows drag seam                   | 替换前维持既有职责；替换后仅承担 SDK 未覆盖且已获准的窄能力，不预设保留 drag 子窗口                       | 任意窗口操作、业务布局事务                   |
| Windows resize seam                 | 顶边/顶角输入、系统缩放；拥有当前有效原生 resize 占用区并提供窄的只读事实                                  | 业务控件命中、标题栏布局、直接 import drag   |

已确定的方向是输入资格与窗口动作分离；布局如何与命中保持一致尚未解决，因此不再把“区域发布 → 原生命中”写成既定链路。

## 4. Windows 原生输入层候选

以下保留已验证固定原型的机制与资源约束，不是当前默认实施路线或新一轮实验指令。A2 结果见 14.6；第 5 节的布局一致性问题不能靠这里的 Win32 原语自动解决，固定区域原型通过不能授权动态区域实现。

候选的潜在收益是把标题栏按下纳入 OS 的非客户区输入，使应用不再用 DOM 业务点击拼接双击历史。需要证明的具体链路是“drag 子窗口首击 → 主窗口 move loop → WebView2/原生边缘插入 → drag 子窗口再次按下”。不能预先宣称任意跨 HWND 点击都会替本实现正确重置 OS 序列；capture、消息转发及最大化后的窗口变化都属于该证明。

1. 复用现有启动窗口 binding，在当前 UI 线程建立 drag-owned 输入子窗口。初始隐藏且无命中区域；不建立第二个顶层窗口或 WebView。
2. 只覆盖显式登记的拖动片区。候选实现使用有界矩形集合与窗口 region 裁剪；空集合必须清空/禁用命中，不能把空 region 误作恢复整个矩形窗口。
3. 片区内的命中为 `HTCAPTION`；片区外由真正的窗口形状排除，不能仅依赖跨线程 `HTTRANSPARENT` 穿透。
4. 原生 `WM_NCLBUTTONDOWN` 进入现有系统拖动路径；`WM_NCLBUTTONDBLCLK` 经窄回调进入 Application 的最大化/还原入口。不得同时转发双击消息和调用 toggle，避免执行两次。
5. 最大化窗口仍需要标题栏拖动恢复，不能照搬 resize 的“最大化时隐藏输入层”条件。隐藏、最小化、禁用、文档断开等状态分别定义并验证。
6. 右键系统菜单通过主窗口原生路径处理，不新增自绘菜单。它属于拟验证行为，不因识别了 `HTCAPTION` 就宣称自动通过。
7. drag/resize 的裁剪与 Z 序按 4.1 的单一责任划分实现，不能留给两个子窗口各自抢占最高层。
8. 使用现有输入层的绘制策略作为候选，不增加整窗截图、重绘镜像或透明度补丁。静止 DOM 更新、动画、遮挡恢复与调整尺寸都必须验证。

原生输入并不自动证明所有中断语义成立。首击进入主窗口 move loop 后的第二击、失焦与原生边缘插入，都属于 A 阶段否决项。

### 4.1 原生裁剪、层级与更新归属

- **resize seam 拥有排除事实。**使用当前窗口、DPI、可缩放/最大化/最小化/启用状态计算实际有效 resize 占用区；沿用现有原生边框指标，不能写死约 8 px。通过 Application 注入的窄接口提供同一份事实，不在 drag 或 Renderer 复制计算。resize 未启用时排除集合为空。
- **drag seam 执行裁剪。**先将候选拖动区域可靠映射到原生客户区物理坐标，再限制到 native top band 并扣除有效 resize 区域；以裁剪后的真实窗口 region 安装。Renderer 不接收 HWND、不估计 OS 边框，也不承担这项排除。坐标映射未证明时不启用候选。
- **Application 拥有组合顺序。**输入层的实际原生操作仍封装在对应 seam，Application 以明确调用/窄回调协调；不合并成通用 facade，也不让两个 seam 相互 import。
- **Z 序固定为 resize 在 drag 之上、drag 在 WebView 内容之上。**drag 创建时保持隐藏，首次激活前由原生 seam 将其排在 resize 子窗口之后；drag 不使用 `HWND_TOP` 自行置顶。resize 保留其置顶职责，Application 协调 drag 的相对位置；不能把“创建一次排对了”当作永久成立。
- **更新入口覆盖安装、SIZE、SHOWWINDOW、DPICHANGED、窗口启用/样式变化和 PARENTNOTIFY 引起的子窗口顺序变化。**在同一 UI 线程的受控更新中先撤销可能失效的 drag 命中，resize 更新并提供当前排除事实，再由 drag 裁剪、定位；仅在映射和候选片区的有效性仍成立时重新激活。不能因为原生尺寸更新完成就复用过期 DOM 区域。
- **失败先保持不可命中并清理。**不能确认裁剪、相对层级或激活前提时，不启用 drag 子窗口；只读查询或定位失败不触发另一层的置顶重试循环。具体撤除失败按 5.5 处理。

原型须观察有效 resize 像素不会触发拖动、drag 像素不会被 WebView 抢走、其余控件像素正常交给 WebView；同时覆盖 child 创建/重排与最大化时 resize 隐藏而 drag 仍需可用。这里解决的是原生层之间的归属，不解决 5.1 的动态 DOM 一致性问题。

## 5. 已撤回设计与尚待证明的机制

### 5.1 第一轮：为什么需要业务布局等窗口 ACK？

上一版用 `suspend → ACK → 提交 DOM → publish` 防止原生区域落后于页面。这说明候选设计建立了两份命中事实，却没有共同的提交边界。

可达反例：旧拖动区域 R 已安装；AccountGate 切换或标题栏 action 更新使 R 被控件占用。若 React 正常提交，Host 处理撤销之前，旧输入层仍能截获控件点击；若等待撤销 ACK，则页面状态提交依赖窗口 IPC。ACK 未到时，“保留旧视图、允许取消”不能正确呈现已经发生的 Product 状态变化。

代码依据：`frontend/src/app/App.tsx:763` 从 snapshot 推导 AccountGate，`:2667` 和 `:2691` 在 root render 直接分支；`AppShell.tsx:370`、`:384` 动态提交上下文和 actions，`frontend/src/index.css:3415` 使用内容相关的 grid 列宽。`frontend/src/components/ui/SelectionMenu.tsx:52` 的未受控打开状态与 `frontend/src/components/ui/Dialog.tsx:21` 的全视口 backdrop 也不是标题栏协调器拥有的布局事务。这里不推断 AccountGate 延迟等同于数据泄漏；已确认的问题是错误的呈现依赖和故障耦合。

原布局屏障设计的 P1 已通过撤回该路线收口，不再是当前草案要求执行的动作；动态区域如何安全承载实际 UI 仍未解决。不能用事后 observer、更多版本号、业务层等待队列或“之后加测试”修复这个所有权问题，也不能把状态记录获准当作生产机制获准。

### 5.2 第二轮：为什么发布失败就能断言原生区域已禁用？

上一版把 Host 安装结果与 Renderer 收到响应混为一个原子动作。实际调用顺序是平台 effect 先执行、再编码/运输响应（`src/bridge/dispatcher.zig:676`）。当前固定 SDK 的 invoke 在 post 成功后等待 complete 才结束 pending，没有内建等待期限；Windows 响应通过 `ExecuteScript` 单独送达，并没有向调用方提供跨层回滚保证。

可达故障序列：Host 安装成功 → 响应执行失败或未送达 → Renderer 未获确认。此时本地错误/超时不能证明区域已经撤销。版本号可以拒绝后续陈旧发布，却不能撤销一次已生效的安装；取消等待也不等于取消 Host effect。

上一版失败语义的 P2 已通过撤回错误保证收口。未来若确需持久原生区域，必须分别处理“确认未应用”“确认已应用”“结果未知”，并给出 Host 侧可观察的撤销完成条件；不能把 unknown 当 disabled，也不能以冻结业务 UI 等待撤销来重新引入 5.1。当前没有宣称已实现这样的替代机制，此结论不要求改造通用 RPC 或修改 SDK。

### 5.3 第三轮：为什么借用 resize 子窗口就足以证明标题栏可用？

不能。resize 的区域由原生窗口边缘决定，动态标题栏的可拖动空白由 DOM 布局、控件和遮罩共同决定；两者不是相同的一致性问题。`WS_EX_TRANSPARENT` 只提供受限制的绘制顺序语义，不保证任意 WebView 绘制和输入穿透。原生双击消息还受鼠标 capture 影响，转发首击进入主窗口 move loop 后的实际序列必须验证。

这不是已经复现的原生输入层缺陷，不额外列为 P1。当时修订的是证据等级：第 4 节只能作为候选，不能称为“成熟方案的具体实现”；现已退出默认实施路线。固定区域的绘制/输入证明与动态页面的一致性证明是两项独立义务，前者不能替代后者。

### 5.4 现在允许推进什么

本轮只修正计划与任务记录，不修改生产、SDK、UI 或 Gate，不启动新原型，不以继续追加固定区域测试替代真实 UI 的设计证明。

- 保留第 1 节的既有界面与输入边界。执行方须先回答“谁同时拥有可见布局和命中”，并把 AccountGate、工作台动态操作与覆盖层放进同一完整方案，不再以固定空白矩形或未来补充的业务协调协议代替。
- Wry 的浏览器原生区域是更贴近该职责目标的参考，但它依赖实际可调用的 SDK 能力。2.2 的公开入口缺口仍在，不能把原生 WebView2 支持、依赖头文件或 main view frame API 当作已经接通。
- 自建原生输入子窗口退出默认生产路线。已做实验保留为有限证据；没有新增、可检验的机制假设时不重跑同类实验。额外拖动带已撤回，不能继续以其批准为前置，也不自动改选全局记录器、标准标题栏或 SDK patch。
- 尚无满足全部目标的可实施替代，生产保持现状，明确“全局监听移除尚未交付”。这不是证明所有路线都不可能，也不是把等待上游当成交付承诺。恢复实现所需的新事实与证据见 15.4；没有新事实时不循环复查相同源码或重复询问用户。

后续若有新的完整机制，先确认公开调用链、布局/命中所有权、手势中断与失败清理，再安排与它直接相关的最小验证。涉及坐标映射、旧响应或区域资源的断言只适用于确有这些机制的路线，不把原型的子窗口、区域协议或测试形态固化成所有实现的要求。

### 5.5 与具体区域协议无关的清理约束

- 资源安装失败须回滚；运行更新失败须撤除失效输入层并报告。不能只设置一个本地 disabled 标志，就声称实体 HWND 不再截获输入；撤除失败属于未处理完的能力故障。
- disconnect、新 document、root 销毁及 Application cleanup 均须撤销对应输入资源与回调；旧响应不得激活新文档，无需因每次布局变化重新 connect。
- 成功交给 `SetWindowRgn` 的 region 资源由系统拥有；失败分支负责释放尚未转移的资源。输入子窗口与主窗口两种销毁顺序均验证。

## 6. macOS 与删除清单

macOS 保留现有 SDK/AppKit 原语及其双击偏好。browser-side Bridge 在真实标题栏/拖动片区按生命周期注册局部入口，不再使用 document 级 pointerdown；输入资格、交互排除与卸载清理仍由 Bridge 负责，React 不直接调用 transport。

只有 Windows 输入机制确认成立后，才确定共享 `pointer` 命令的删除/收窄及 macOS 局部 `startDrag` 的 wire 变化。平台差异通过 Host capability 表达，不由 React 推断平台，不保留旧协议兼容分支。不能先把 Windows 入口删掉再寻找可用替代。

Windows 路线通过后删除：`first_press`、自制时间/距离配对、逐次 down/reset、业务点击 reset、专为首击缓存存在的 blur/resize reset 回调及相应 DTO。保留独立的 focus refresh、资源清理与窗口状态检查，不能把所有 blur/focus/lifecycle 处理一起删掉。

## 7. 实施阶段与通过条件

以下保留原 DAG 的阶段责任，并标明纠偏后的状态；不是继续原生子窗口路线的执行授权。每个 DAG 子任务完成后，必须同时评估提交：验证充分且形成独立可交付改动时及时提交；否则在该任务的验证记录中说明暂缓原因。计划纠偏可以独立提交，但不因此关闭 B1 或总任务。

原型同样受现有 capability 边界、exact-symbol allowlist 和验证 Gate 约束。若 A/B 原型需要扩大已登记的原生输入边界或新增受控符号，应先列出精确差异并取得相应批准，再实现原型；不能等到 C 再补批准，也不能用“隔离测试产物”绕过 guard。本轮不作这些修改。

| 阶段                       | 交付与责任                                                                                                                                           | 完成/停止条件                                                                                             |
| -------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| 0：方案纠偏                | 撤回额外拖动带与等待批准的前提，区分原型证据、真实 UI 缺口和恢复条件                                                                                 | 本轮文档与任务记录的交付；不宣称已解决替代机制或关闭原目标                                                  |
| A/A2：原生事实原型         | 旧 A `3146` 失败；后续 A2 `3166` 的固定区域输入、绘制及资源验证通过，见 14.6                                                                        | 结论仅限受测原型和环境；停止无新假设的追加实验，不直接推导生产适配成立                                    |
| B1：实际 UI 的命中边界设计 | `3147` 未完成；保持现有界面，说明公开调用链及各时刻布局/命中的共同所有权                                                                           | 不用业务 ACK 屏障或事后追赶，不新增拖动带/下移 WebView/关闭缩放；完整机制未成立则不进入 B2                 |
| B2：真实 UI 原型           | 按经确认的边界覆盖页面切换、动态 actions、菜单、遮罩、DPI、故障和生命周期                                                                            | 不冻结业务提交；无旧区域吃点击；失败有可观察的实际清理；通过方可确定最小 wire 与正式实现方案              |
| C：正式替换                | 同步获准的合同，接入 Windows/macOS，删除失去职责的全局监听、首击/reset 路径、DTO 与回调                                                              | 单一 active path；普通业务点击零窗口手势命令；类型、fixture、测试和 guard 一致                            |
| D：平台验收                | 当前实现的真实输入/绘制/生命周期证据与未验证范围                                                                                                     | 满足现有正式矩阵；不以旧 artifact、模型推演或合成 DOM 事件代替                                            |

A 的最小输入证据逐例记录：实际输入时序、收到消息的 HWND/线程、native hit、capture、move loop 前后状态、最大化前后矩形与最终动作。不得为了让原型通过偷偷保留全局记录器、JS reset 或另一条拖动路径；双击、插入中断和绘制任一失败都记录为当前候选失败，而不是改写预期。

B1 的交付必须具体到两个实际页面与覆盖层，不能只写“固定一个空白区”。先在保留现有标题栏、按钮和弹层行为的条件下解释最窄窗口、语言/字体、页面切换、浏览器缩放及 DPI 的完整输入路径。若该路径尚不存在，就如实报告缺口；不能通过提出产品让步把已投入的原型包装成可交付方案。

暂缓替换并保留现状是证据不足时可接受的安全处置：维持目前的 Host 状态机及 down/reset 路径，明确每次业务按下仍会发送 reset，明确“全局监听移除尚未交付”。它不构成新版本中的并行 fallback，也不以本次文档通过为由宣称任务完成。原型材料按验证职责收口，不留下平行生产实现或 active archive。

## 8. 验证矩阵

- 原生手势：默认/非默认双击时间、距离内外、首击 move loop 后第二击、三/四击、普通拖动、最大化拖动恢复。
- 中断：标题栏→内容→标题栏；标题栏→相邻控件→标题栏；同位置 disabled/传播阻断；相邻业务控件取消 pointerdown；此前模型反例的位置序列；失焦；边缘只按下但不改变尺寸。相邻距离以本机原生双击阈值校准，不只写一个未经校验的 CSS ±2px。
- 原生候选看真实 HWND/线程、非客户区消息、capture 和窗口状态，不要求标题栏仍产生 DOM `mousedown.detail=[1,2,3]`，也不把 B 没有 mousedown 当成 B 没发生。
- 业务隔离：复制、输入、选择文本、链接、菜单、inert、portal、控件 SVG。复制保持既有剪贴板断言，不把未证实的复制故障归因于本次窗口链路。
- 一致性：正常页面/弹层提交不等待 chrome ACK；已应用但响应未送达、慢/迟到 ACK、原生 resize、尺寸 A→B→A、DPI 变化、旧 generation、新 document、重复卸载、取消等待不冒充撤销。具体协议断言须随选定机制确定，不假设 suspend/publish 已获批准。
- 绘制：首次显示、静止更新、连续动画、明暗主题、遮挡恢复、反复 resize；不能用“拖动窗口后恢复正常”当作通过。
- 原生层组合：边缘/拖动片区/HTML 控件的交界、resize 启停、DPI/样式变化、WebView child 创建及重排；验证实际裁剪和 Z 序，不仅检查计算出的矩形。
- 生命周期：普通/最大化关闭隐藏、Alt+F4、最小化/任务栏恢复、托盘重开、reload、clean shutdown、资源计数和两种销毁顺序。
- Windows 10/11、混合 DPI、负坐标、touch/pen、系统菜单与 snap 分别记录。未覆盖的能力保持明确未验证，不借鼠标通过推断触摸/笔或 Win11 Snap hover。
- macOS 对局部入口、双击偏好、交通灯、首次拖动和卸载做独立实机验证；Windows 结果不代替。

正式检查按现有标准入口执行：Renderer typecheck 与受影响 suite、Bridge 跨语言 fixture/Zig tests、`zig build test-window-chrome -Dtarget=x86_64-windows-gnu`、对应架构 guard 和真实 `node scripts/test-window-chrome-windows.mjs`。共享 native module graph 如受影响，再执行正式 Native graph。缺少 canonical staged bundle 明确失败，不跳过后宣称通过。

每份平台证据绑定源码 revision/diff、二进制 hash、OS、Native SDK、WebView2 版本和实际运行命令。旧证据保留其历史含义，不改写成新实现已通过。

## 9. 预计变更位置与合同审批

实现集中于 `frontend/src/bridge/window-chrome.ts`、`WindowTitlebar.tsx`、AppShell/AccountGate 的标题栏布局入口、Bridge 类型/dispatcher/fixture、`src/app/window.zig` 与现有 drag 平台文件。resize 仅调整明确的命中优先级/清理协作和已失去职责的 reset 回调，不扩展其 owner。

最终机制如果改变“Host 不镜像区域”、逐次 pointer 协议或标题栏交互范围，C 阶段之前须评审批准实际涉及的 Bridge/UI/architecture 合同变化；原型若更早触及这些边界，批准也须先于原型。当前不预先批准区域镜像。需求文档仅在用户可观察行为或范围实际变化时更新；validation 更新验证责任与新增证据。`app.zon` command catalog 和 exact-symbol allowlist 只随批准后的具体实现收口，不删除或泛化 guard 规避失败。不修改 AGENTS.md 或 upstream-only 政策。

在 B1、B2 及实际机制所需的原生验证通过，并取得正式替换所需的合同批准前，本文件不能作为直接删除生产首击状态机的依据。旧 A 的失败不改写成成功，A2 的通过也不预先满足不同机制的验证责任。方案完善交付的是可核对的取舍、责任与恢复条件，不代表已有可用替代。

## 10. 参考依据

- [Tauri 拖动脚本](https://github.com/tauri-apps/tauri/blob/dev/crates/tauri/src/window/scripts/drag.js)与 [Wry WebView2 设置](https://github.com/tauri-apps/wry/blob/dev/src/webview2/mod.rs)：分别验证 DOM 意图与浏览器原生区域路径，不混为一套实现。
- [Tao Windows 原生拖动入口](https://github.com/tauri-apps/tao/blob/dev/src/platform_impl/windows/window.rs)：用于理解原生动作路径；实施时固定所参考 revision，不复制可变 upstream 源码作为依赖。
- [WebView2 ICoreWebView2Settings9](https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/win32/icorewebview2settings9?view=webview2-1.0.3537.50)：浏览器原生 app-region 能力及设置生效时机。
- [Pointer Events 鼠标兼容映射](https://www.w3.org/TR/pointerevents3/#mapping-for-devices-that-support-hover)：取消 pointerdown 对 mousedown 的影响；具体 WebView 行为仍须实测。
- [Win32 WM_NCLBUTTONDBLCLK](https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-nclbuttondblclk)：系统非客户区双击消息与 capture 条件。
- [Win32 SetWindowRgn](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwindowrgn)：窗口 region 与资源 ownership。
- [Win32 SetWindowPos](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwindowpos)：相对 Z 序、显示/隐藏与不激活语义。
- [Win32 Extended Window Styles](https://learn.microsoft.com/en-us/windows/win32/winmsg/extended-window-styles)：绘制透明性不等于任意情况下的输入穿透。
- 仓库历史 `f6c1517f`、`62bdb9ba`、`f30d7e5e`、`494fc590`、`c952bfb5`，以及 validation 中的 `E-WIN-CHROME-EVENTS-20260916`、`E-WIN-TOP-RESIZE-20260916`；历史实现只作为失败模式和验证责任线索，不恢复旧的整页扫描或递归 child subclass。
- 本次失败路径核对使用固定依赖 `node_modules/@native-sdk/cli/src/platform/windows/webview2_host.cpp:5051`、`:5062`、`:6463`；只读审计，没有修改依赖。这证明响应不是安装 effect 的事务回滚屏障，不声称本轮实际复现了响应丢失。
- SDK 缺口核对：同一固定依赖的 `src/platform/types.zig:3193` 定义公开 drag-region 原语，`src/platform/windows/webview2_host.cpp:6684` 的目标必须是 GPU surface；WebView2 接口声明位于依赖的第三方头文件，不能据此推导 MetaWork 有权取得 SDK 私有 WebView 对象。

## 11. 前次评审问题的处理状态

- 记录器路线未单独评估、拒绝理由含混：文档问题已解决。2.3 分离 detail 单用与被动记录器，逐案说明模型、前提和真实取舍；不声称记录器已被反例否定或已通过实机验收。
- “不挂全局记录器”缺少依据：文档问题已解决。第 1 节写明应用层输入历史依赖的工程动机及用户决定，区分集中式观察与业务 owner 被迫配合；不是通用 API 禁令。
- drag/resize 裁剪与 Z 序归属：责任见 4.1，固定原型证据见 14.6；不把该证据扩展为动态标题栏可用。
- SDK 缺口只写“未找到”：方案层已解决，见 2.2；明确 API/CSS 能力及生效时机，保留基于等价能力的删除条件，不修改 upstream-only 政策。
- 复制故障归因：已纠正。旧监听会让复制按下参与 reset IPC，但未证明它导致复制失败；复制功能回归与监听副作用的因果验证分开。
- document 冒泡被祖先 stopPropagation 截断：不能用于否定 capture 记录器，已在 2.3 澄清；后续 macOS 局部注册仍须验证真实传播与卸载。
- 两次有序 invoke 的所谓“重排间隙”：不再作为改造理由。5.2 讨论的是 effect 已执行而响应未确认，与请求重排不是同一个问题。
- 布局屏障与“发布失败即 disabled”：旧设计问题已通过撤回收口；布局一致性和实际清理的生产证明仍待候选给出，见第 5 节。
- 当前结论：记录器评估和 A2 固定原型已有各自结论，但实际 UI 接入与平台验收未完成。本文不批准生产替换；不再将原生子窗口或额外拖动带列为默认路线，按 15.4 的新事实条件恢复，不围绕同一偏好循环评审。

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

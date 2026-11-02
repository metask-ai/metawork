# Changelog

本文记录 MetaWork 各版本显著的开发、架构、依赖与验证变更，不作为面向用户的发布说明。

格式遵循 [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)，版本号遵循 [Semantic Versioning](https://semver.org/spec/v2.0.0.html)，真源是 `app.zon`。当前能力边界与验证状态以 [docs/validation.md](docs/validation.md) 为准。

## [Unreleased]

## [0.2.9] - 2026-11-01

### Added

- Task Panel 新增按需展开的工作区文件树，支持分层浏览、键盘导航、刷新及文本和图片预览。
- Models 设置支持添加、编辑、测试和删除用户模型；任务输入区统一列出已就绪模型，并显示本地厂商品牌图标。
- Skill 中心支持从 `.skill`、`.zip` 或目录导入，以及导出、重新导入和卸载受管 Skill。
- Run 新增模型等待、思考、输出、工具调用和收尾等活动状态；脱敏后的模型错误随历史保存，并提供对应恢复提示。

### Changed

- 调整会话阅读区、消息、Composer 和历史导航的排版与操作层级。
- Skill 在后续交互 Run 前自动采用最新目录；Office Skills 合并共享资源，并补充 XLSX 验证、PPTX 收尾检查及 Windows 归档导入修复。
- Metask credential 支持续期而无需重建 Session；AgentCore 升级至 `0.13.0-dev+723af0baee8d` / ABI revision 26，并刷新全平台 bundles。

### Fixed

- 修复 HTTP、图片生成、MCP、OAuth 和主循环唤醒在并发取消时可能遗留等待或形成死锁的问题。
- 修复 Manual Workspace 无法安全移除、项目与 Task 右键菜单行为不一致，以及用量热力图月份标签错误的问题。
- 修复审批上下文丢失或超出容量，以及模型失败后文件观察状态未正确收口的问题。

## [0.2.8] - 2026-10-28

### Added

- 设置新增“已归档任务”，支持搜索、查看只读历史、恢复和删除；归档成功后提供撤销与查看入口。Task 现在无需先归档即可直接删除，活动中的 Task 可以一次确认停止并删除，Workspace 中的真实文件保持不变。
- 分发构建新增正式版本检查：后台和手动检查官方 manifest，在左下角提示新版本，并通过“关于 MetaWork”按当前平台与架构把下载交给系统浏览器；不自动下载、安装、重启或切换目标。

### Changed

- Product 历史改用类型化 SQLite schema、原子事务和有界分批读写，保留旧历史恢复，并提高大型 Task、Run 集合和积压提交的容量；credential 清洗与持久确认纳入同一恢复边界。
- 全局搜索改为 Host 端有界分页查询，覆盖 Task、用户指令、完成消息和 Output 文件名；使用固定 Unicode 大小写折叠，并在历史变化或安全失效时使旧游标失效。
- Task 重命名改用独立对话框，不再占用标题栏进行内联编辑；提交失败或结果未确认时在原对话框内保留草稿和反馈。
- 审批卡片改为直接展示可读的动作、目标、完整脱敏内容和真实转人工原因；自动评审使用当前请求及已确认采纳的近期用户上下文，并受有界执行与取消预算约束。
- Run 执行资源与已恢复历史分离，空闲 Session 可以在容量压力下回收；容量暂时不足时发布明确状态，并只在用户显式操作后重试。
- AgentCore 升级至 `0.11.0-dev+e75ad43c4557` / ABI revision 24，并刷新 Windows 与 macOS 的 x86_64/ARM64 bundles。
- Metask 模型目录、执行与 OAuth 端点迁移至 `www.metask-ai.com`。

### Fixed

- 修复定时任务在执行配置变化或使用 Custom Provider 时可能错误触发、丢失待处理执行或被重叠状态持续阻塞的问题；通知和管理动作现在始终指向真实 Task，并明确呈现恢复结果。
- 修复 MCP 主动刷新造成短暂准入中断的问题；刷新改用独立控制容量和有界恢复，不再受等待审批的 Run 阻塞，也不再用配置应用失败覆盖单个服务的健康状态。
- 修复 Office 资源校验错误依赖生成器版本，避免生成器升级使内容未变化的已发布资源失效。
- 修复文件预览标签尚在等待聚焦时关闭 Task Panel，迟到的聚焦回调可能把焦点移到无关控件的问题。

## [0.2.7] - 2026-10-24

### Added

- 内置 DOCX、PPTX 与 XLSX Office Skills，并为 Windows 与 macOS 的 x86_64/ARM64 目标锁定私有 Python、Node 和文档库输入；依赖经现有 Shell 与权限链按需准备到应用私有目录，不依赖或改写系统解释器。各目标的真实桌面与正式分发证据仍以验证规范记录的边界为准。
- Run 的可信文件交付记录新增“检查文件”“定位文件”“另存为”和“继续修改”操作；每次操作都重新核验当前 Workspace 授权与实际文件字节，另存通过系统对话框原子发布，目标路径不会进入 Renderer。
- 新增模型首次设置与不可用状态的引导界面，根据实际 Account、Provider、模型目录和持久化状态提供登录、配置、重试或恢复入口。
- Task 会话为用户消息、Agent 输出和生成图片新增持久化呈现锚点，分页、恢复和增量刷新保持稳定阅读顺序。

### Changed

- 消息信息栏统一使用实际模型元数据，不再由不同消息类型各自拼接模型说明。
- 更新 MetaWork 标志、字标、应用图标与托盘图标，并为 Windows 主包增加体积和资源预算检查。
- Native SDK 升级至 `@zogien/native-sdk 0.11.0-fork.4`，窗口顶部缩放改由 SDK 原生能力承担。

### Fixed

- 修复 Metask 凭据续期时未保留等待消息，以及模型目录变化后 credential authority 未随新授权推进的问题；既有 Task 已持有的执行 binding 不被追溯替换。
- 修复 Windows 升级时托盘驻留 Host 未退出便替换运行文件的问题。
- 修复复制操作和时间戳作用到错误消息，以及旧历史图片与末尾用户输入顺序不稳定的问题。

## [0.2.6] - 2026-10-21

### Added

- Task 现在可以持续接收有效的文本、Skill 和已完成 staging 的附件消息，不再因当前 Run 的启动、停止或收尾阶段拒绝普通发送；消息按 Task 顺序等待，只有普通文本可以作为当前 Run 的插话，Skill 和附件留待后续 Run。Stop 只取消当时已有的等待消息和当前 operation，之后提交的新消息继续保留。
- Agent Runtime 新增固定的 `GenerateImage` Host Tool 桌面执行链：每个 Run 从当前 Metask 授权解析图片模型，按权限、并发、容量和取消边界生成一张 PNG、JPEG 或静态 WebP，并保存到所属 Workspace；失败或结果不确定时禁止自动重试。该能力仍处于内部测试阶段，图片模型设置尚未向用户开放，正式服务与发布验收尚未闭合。
- Host 生成图片可以在所属 Run 中内联显示并打开完整预览；文件预览新增静态 PNG、JPEG 和 WebP 原图读取，通过有界临时授权和分块传输交付，不把原图复制到 Snapshot、产品历史或额外磁盘缓存。

### Changed

- Renderer 产品数据面改为按消费范围读取版本化视图，并按页补充 Task 历史；缓存复用、权限失效和范围替换由 Host 明确控制，不再要求先运输全部 Task 正文，同时保留阅读位置和已打开面板状态。
- 插话统一呈现为普通用户消息，不再显示采纳、接续或转入等内部状态；等待消息转入执行后仍只显示一次。
- AgentCore 升级至 `0.11.0-dev+9c2f68671198` / ABI revision 24，并刷新 Windows 与 macOS 的 x86_64/ARM64 bundles。

### Fixed

- 修复审批恢复在历史写入完成后未继续收口，以及长回复可能撑出中央阅读列的问题。
- 修复图片生成的 JPEG/WebP 结果、模型图片能力传递、费用事实、取消与清理竞态，并确保拒绝或结果不确定时不会隐式重试。
- 修复分区视图刷新时历史连续性、阅读锚点、已提交命令对账、Account 图片凭据识别和安全撤权不稳定的问题。
- 修复单实例启动期间激活请求过早接纳或唤醒丢失，以及图片预览失效后的重试、拒绝原因保留和 shutdown 资源收口问题。

## [0.2.5] - 2026-10-18

### Added

- 既有 Task 现在可以在保留 Task、Conversation 与历史身份的前提下切换其已选 Provider 内的模型；模型选择独立于实际 Session 和历史 Run 持久化，并在后续 Run 前应用。
- Run 进行期间可以直接提交文本插话；消息以普通用户气泡保留在提交时对应的输出位置，并显示等待采纳、已采纳、本轮未采纳或结果未知状态。
- Run 正常完成并收尾后，已确认未采纳的输入会按提交顺序合并进入一个真实的后续 Run；消息只显示一次，并可从来源定位后续 Run。停止、失败、中断、结果未知、取消或重启不会触发接续，转入也不代表后续 Run 执行成功。Skill Run、Skill 草稿和附件草稿不支持插话。该机制取代 0.2.4 的下一轮排队输入。

### Changed

- 模型选择器按 Task 已选 Provider 限定候选项；Task 信息与历史 Run 分别显示目标模型和实际执行模型，并简化选择器标签和提示。
- Task 模型重绑定与分离状态恢复使用已提交的模型来源，并按原有能力与当前授权的交集恢复 MCP、Skill 和权限；失效能力安全收缩，不回退到全局默认配置。
- Agent 日期与时区上下文改由 AgentCore 生成，Host 不再维护平行的时间上下文实现。
- AgentCore 升级至 `0.11.0-dev+68ac95c2d42b` / ABI revision 24，并刷新 Windows 与 macOS 的 x86_64/ARM64 bundles；Windows 正式目标由 GNU 切换为 MSVC。
- Native SDK 升级至 `@zogien/native-sdk 0.11.0-fork.3`，Windows 最小化、最大化、还原和关闭操作改由 SDK 原生窗口控制 API 承担。

### Fixed

- 修复审批 checkpoint 错误依赖 Task 当前模型，以及模型切换和分离状态 Task 恢复中的模型意图映射问题。
- 修复插话在历史投影中丢失身份标识、接续后的用户消息重复显示，以及接续取消范围和失败提示不准确的问题。
- 修复传输恢复期间本地草稿无法继续编辑，以及活跃 Run 下 Skill 草稿的不可用原因提示不准确的问题。

## [0.2.4] - 2026-10-17

### Added

- Run 进行期间可以排队一条文本或 Skill 输入；绑定 Run 正常完成并收尾后自动按普通准入启动下一次 Run，支持查看、编辑和撤回；非正常结局或准入失败时保留为待处理，应用重启后不恢复。
- Composer 支持直接粘贴剪贴板图片，并复用现有附件接收、校验、取消与草稿生命周期；不主动读取系统剪贴板，不插入同次粘贴的 HTML 或文字表示，也不自动发送。

### Changed

- New task 可以直接选择已有且仍获授权的 Manual Workspace；系统选择器只用于新增或重新授权目录，Automatic Workspace 统一显示为“默认”。
- 审批模式界面文案调整为“自动审批 / 直接执行”并压缩选择器说明；权限、额外用量与存疑转人工语义不变。
- Agent 时间上下文只传递本轮日历日期与时区信息，不再包含具体钟点。
- Renderer Bridge 的两类共享 wire 结构改由 Host 类型生成；开发启动与构建改用隔离、成对产物，避免跨语言合同漂移和旧产物混用。
- Native SDK 切换至维护版 `@zogien/native-sdk 0.11.0-fork.2`；System WebView 标题栏拖动改用 SDK 原生声明区域，移除应用自有手势与拖动兼容路径。
- Windows 与 macOS 的 x86_64/ARM64 AgentCore bundles 统一刷新至 `0.6.0-dev+4e826cef9799` / ABI revision 19。

### Fixed

- 修复提交输入时可能丢失 Composer 焦点或草稿的问题。
- 修复已保存 Manual Workspace 恢复后仍重复要求目录选择，以及 Renderer/Host Snapshot 对 Compact 阶段、附件可用性和合同差异的处理不一致。

## [0.2.3] - 2026-10-14

### Added

- 既有 Task 现在可以在同一 Session 中切换“人工审批 / 自动评审 / 完全访问”，保留 Task、Conversation 与历史身份，并以持久化的 approval revision 防止陈旧或重复提交；旧的“以完全访问继续”successor Task 流程已移除。
- 附件新增 DOCX、XLSX、PPTX 与 ZIP 原件支持；内置本地 Office Skills 和有界归档资源，通过既有 Skill/Bash 路径完成读取、编辑、校验与解包，不引入通用文档输入协议。
- 含未知字段但仍可校验的已保存 Task 现在以只读状态打开；当前版本完全无法读取的记录继续原样保留，并在左栏说明未打开的 Task 数量。

### Changed

- AgentCore 升级至 `0.6.0-dev+c4b0af79fe20` / ABI revision 19，并刷新 Windows 与 macOS 的 x86_64/ARM64 bundles。
- Metask 模型目录以声明的 endpoint protocol 作为准入真源，完整保留输入模态与根级 token limits；不可用的既有模型 intent 保持可见，并提供当前合格替代项。
- Composer 附件统一为异步批次接收协议，系统选择器与拖放共享预留、传输、取消和草稿移除生命周期。
- 托盘退出不再显示额外确认，仍按既有 shutdown 流程安全收口。

### Fixed

- 修复 Workbench snapshot 刷新可能无界等待或接纳旧 generation、同步恢复动作未稳定保留在命令栏，以及启动失败与已提交结果显示不准确的问题。
- 修复附件不完整读取、Windows positional I/O、跨草稿移除、批次取消和关闭竞态，确保未完整传输的文件不会发布、Task 原件不会被迟到操作误删。

## [0.2.2] - 2026-10-10

### Added

- Agent Session 新增固定的 MetaWork 产品身份；每次普通文本或多模态 Run 都注入重新采样的系统时间、UTC offset 与平台时区 identity，不改写用户输入或产品历史。
- 左栏新增 Manual Workspace 项目导航，在保留全局 Task 列表的同时按项目展示同一批 Task。

### Changed

- 升级至 AgentCore ABI revision 18，并将 Windows 与 macOS 的 x86_64/ARM64 bundles 刷新至 revision `eeff8dc69607`，接入 Session prompt profile、per-Run context blocks 与新版 typed input 合同。
- Composer 输入框随内容扩展且不再截断草稿；超限草稿保持可编辑并禁止发送。单个受支持附件上限提高至 100 MB，Run 接纳后的原件由 Task 持有，可跨重启与 Conversation 恢复继续读取，并随 Task 删除。
- Metask OAuth scope 对齐已部署的 `read model:invoke` 合同；scope 按集合校验，callback 接受不改变身份与 issuer policy 的扩展参数。

### Fixed

- 修复 refresh token 轮换在发送前失败、结果不确定、重启与 Host shutdown 下的恢复：仅在可证明请求未发送时重试，无法证明安全时跨重启保持阻断，并保留可达的登录入口。
- 修复 Task 删除在 Session 真正关闭前完成、Conversation coverage 在取消或 worker failure 的 terminal barrier 处错误纳入，以及 Run 时间采样未及时响应中断的问题。

## [0.2.1] - 2026-10-08

### Added

- 新增“人工审批 / 自动评审 / 完全访问”三档 Task 审批模式；自动评审对当前内置工具请求给出一次性建议，失败、超时、证据不足或参数不透明时回到人工处理，并随 Task 和默认设置跨重启恢复。
- 新增权限请求诊断与审批来源记录；Manual Workspace 可在当前 Run 终止后创建独立的“以完全访问继续”Task，不继承 Conversation、待处理请求或 Session grant。

### Changed

- 新安装默认使用自动评审；审批卡仅在仍需人工决定时显示，自动处理结果保留为可追溯记录，并完善窄窗口与键盘操作。
- Metask OAuth callback 改为每次登录绑定由 OS 分配的 loopback 动态端口，并在授权与 code exchange 中使用同一个 redirect URI。

### Fixed

- 修复 macOS x64 应用签名可能破坏主程序内容的问题，并新增 deployment target、Mach-O section 与最终 DMG 内应用的一致性验证。

## [0.2.0] - 2026-09-26

### Added

- Metask OAuth 授权现在直接用于模型目录和模型调用；token 只通过绑定 authorization generation 的有界 lease 传递，并作为 transient execution credential 使用，不进入持久化或投影。
- Account 设置新增最近 53 周的每日 Token 使用与已记录费用热力图，支持日期明细、显式刷新和 stale 数据保留；充值动作由 Host 打开固定 Metask 页面。

### Changed

- Metask OAuth authority、token 与 Userinfo 合同切换到 `app.metask-ai.com`、client `metawork` 和 `openid profile email` scope；登录 identity 改由严格校验的 Userinfo 建立。
- 账户用量改用同一 OAuth gateway token 请求 `app.metask-ai.com/v1/usage/stats`；不再调用 `napi.metask-ai.com` 的旧 `/api/v1/auth/me` 与 `/api/v1/usage/dashboard/*`，也不展示当前合同无法取得的余额、今日或累计摘要。
- Metask 模型调用固定使用 Anthropic Messages `/v1/messages`，模型目录与调用 credential 均来自当前 OAuth 授权。
- 移除 Metask API Key 选择及对应 Bridge command；Models 设置统一为 `Provider → 默认模型` 流程，Custom Provider credential 继续由独立 Providers 设置管理。
- 刷新 macOS 与 Windows 的 x64/ARM64 AgentCore bundles 至 revision `95980e10aadd`。
- macOS 图标打包在既有 Xcode 26.6 基线外，新增对精确 Xcode 27.0 `actool` 的支持。

### Fixed

- 修复 OAuth 回调端口与 Metask 已注册 redirect 不一致的问题，固定使用 `http://localhost:13090/auth/metask/callback`。

## [0.1.12] - 2026-09-21

### Added

- 新增安全外部链接打开机制：Agent 回复中的 HTTP(S)/mailto 及 Markdown 文件预览中的 HTTP(S) 链接由 Host 交给系统处理，并在原位置反馈失败。
- 新增终态 Run 耗时持久化；当 Run 包含 Tool 时，在“执行详情”中显示最终耗时。
- 建立 Product 历史的 SQL schema 与有序迁移验证基线；生产持久化仍沿用既有 framed history。

### Changed

- 移除应用级 Account Gate：无论登录状态均进入 Workbench；未登录时保留本地历史，账号状态仅在账号入口与设置中呈现。
- Tool 详情改为展示 Host 为内置 Tool 投影的语义化证据，Edit/Write 路径可直达同一 Run 的文件更改审查。
- System WebView 标题栏手势收口到实际标题栏节点的浏览器事件，Host 仍按原生窗口事实复核授权。
- 优化侧栏开合动画、Task Panel 空态，以及关闭最后一个对象标签后的显隐与焦点恢复。

### Fixed

- 修复 Metask 资料字段不完整时错误阻断登录；用户名、邮箱、手机号和并发额度改为非阻断的可选投影，并新增脱敏手机号提示。
- 修复中断尾部或 `poisoned` Session 导致既有 Task 无法安全继续的问题；持久化 Conversation coverage，并保留未纳入恢复上下文的历史。

## [0.1.11] - 2026-09-18

### Added

- 新增 Automatic Workspace 根目录设置，支持选择、恢复默认和重试；仅影响后续新建 Task，不迁移既有 Workspace。
- Task Panel 新增对象标签会话，可并行保留多个文件预览和一个 File Changes Review，以及各自的加载结果、模式与滚动位置。
- 新增已发送用户输入的复制操作和 Product 记录的提交时间显示。
- Windows 标题栏支持原生双击最大化与还原。

### Changed

- Workbench 改用比例列布局，优化侧栏密度并压缩账号菜单。
- 收口 System WebView 标题栏手势路由：Renderer 仅声明 DOM 候选，Host 依据原生窗口事实授权。
- 明确 Native SDK upstream-only 策略：仅消费官方固定版本与 public API，未覆盖能力按已登记 capability gap 管理。

### Fixed

- 修复 Windows System WebView 顶边无法原生缩放及相关绘制、输入生命周期问题。
- 修复 Task Panel 隐藏或切换时对象会话丢失、Review 替换后状态残留及意外宽度上限。
- 修复纯文本复制缺少显式 `text/plain` MIME 写入路径的问题。
- 修复 Windows 应用图标白底，改用透明 ICO 资源。

## [0.1.10] - 2026-09-15

### Added

- 新增 Metask Account 用量摘要，展示 U 余额、当日与累计 Token/费用、按上海自然周排列的每日用量热力图，以及脱敏邮箱、并发额度、手动刷新和充值入口。
- 新增 Agent 回复与代码块复制；支持多格式剪贴板时一次写入原始 Markdown 和安全 HTML，明确不支持时回退为完整 Markdown；回复末行同时显示 Product 记录的完成时间。
- 文件预览新增行号和有界语法高亮；未知格式、超限或高亮失败时保持完整纯文本。

### Changed

- 流式 provisional output 从首批安全字节开始按 Markdown 呈现，并在后续定性和运行状态更新时保持同一 Assistant 内容块。
- 移除独立 Permission 设置；New Task 中成功创建时所选的 PermissionProfile 直接成为后续默认值，既有 Task 仍保持创建时的只读策略。
- MCP static/client secret 改由 Renderer password 表单经专用 typed Bridge command 交给 Host 安全存储，删除原生 secure-input 兼容层。
- Tool 详情改为在所属过程行内展开，并进一步收紧 Task 列表密度与终态呈现。
- 刷新 Windows AgentCore bundles。

### Fixed

- 修复 Conversation 恢复后提交仍使用旧 binding epoch，导致后续指令被错误拒绝的问题。
- 修复 Skill 文件事务恢复、损坏 store 原子重建，以及 Workspace identity 复用可能造成的策略错配。
- 修复 Windows runtime stage 和安装包缺少 canonical 托盘图标的问题。

## [0.1.9] - 2026-09-13

### Added

- Skill 中心新增 Claude 与 Codex 兼容来源开关，可分别启用对应的个人目录和全部已授权 Manual Workspace 固定目录，并支持持久化选择与异常恢复。
- 新增 Run 已用时和有界的可读 Tool 证据，在不推断进度或模型意图的前提下展示当前执行事实。
- 新增 Task 完成回执，仅在最新一次成功完成尚未被用户实际看到时显示未读提醒；确认状态随既有 Task 持久化边界保存。
- 新增“关于 MetaWork”对话框，展示产品身份、Metask 开发者归属和构建版本。

### Changed

- File Changes Review 改为按文件聚合的连续差异文档，支持文件级折叠与渐进式按需读取，同时保留底层记录顺序。
- 统一 PermissionProfile 的界面表达，明确“请求批准”和“完全访问”的边界、默认值、单 Task 覆盖与既有 Task 只读语义，并移除重复确认。
- 简化 Task 列表状态和文件预览界面，移除重复的元数据标签与冗余框架。

### Fixed

- 修复 macOS 安装包未完整部署 AgentCore runtime assets 的问题。
- 修复同步失败与停止请求反馈不准确的问题。
- 修复 recorded diff 行号和语义样式丢失的问题。
- 修复 Automatic Workspace 错误携带 Skill catalog，以及个人兼容 Skill 来源查询缺失的问题。

## [0.1.8] - 2026-09-10

### Added

- 新增 Composer 文件附件，支持通过系统选择器添加 PNG、JPEG、WebP 与 UTF-8 文本，并在 Windows 支持文件拖放；附件以有界、原子的 staging 流程接入 Run。
- 新增 New Task 模型选择，可在当前 execution source 与 catalog authority 内为单个 Task 覆盖默认模型。
- 新增 Run 失败诊断，在所属 Run 内呈现稳定终态原因，并明确附加诊断是否因安全边界未投影。

### Changed

- 简化 Task 详情：移除低价值 overview，将只读任务信息内联到会话，并由右侧面板按需承载 Tool detail 与文件预览；Markdown 预览支持切换源码。
- AgentCore hard cut 到 ABI v1 revision 15，不再接受 PDF/document part；图片仍使用媒体 part，UTF-8 文本附件编码为受限的普通文本 part。

### Fixed

- 修复会话文件引用无法打开预览，以及侧栏布局与 Task 内容耦合的问题。
- 补齐附件大小限制展示，并移除重复的文本附件提示。
- 修复下拉选择器被浮层遮挡，以及生产 CSS 构建守卫仍要求已废弃响应式断点的问题。

## [0.1.7] - 2026-09-05

### Added

- 新增 DeepSeek、Kimi、MiniMax 与智谱 GLM 内置 Provider 配方，提供引导式配置、已复核 endpoint 和可选 Base URL override。
- 将 Task overview、Tool detail、File Preview 与 File Changes 统一到可调整宽度的右侧 Task Panel。

### Changed

- 统一 Agent 模型 execution binding 与校验边界。
- Scheduled Task store hard cut 为唯一 schema 1，完整持久化 source-qualified model binding；旧 shape、未知版本和损坏数据 fail closed，仅允许用户显式恢复。
- 收口 Custom Provider 设置流程，在设置页优先呈现官方 Provider 引导，并统一表单交互与视觉层级。

### Fixed

- 修复模型绑定收口后 Completion 请求资源所有权语义被改变的问题。
- 修复 Models canonical store 恢复、未知提交验证、credential tombstone 清理及借用生命周期问题。
- 修复 MCP refresh/OAuth 无关阻塞 Text Task admission，以及运行时鉴权失败未被保留的问题。
- 修复 MCP mutation、token rotation ownership 与 auth scope 校验未完整 fail closed 的问题。
- 修复 Product Skill prepared backup 恢复与不确定写入冻结问题。
- 修复 Account credential invalidation 越过对应 active request 边界的问题。
- 修复 Scheduled Task persistence、reconciliation 和恢复 artifact 收口不一致的问题。
- 修复 Task Panel resize transaction 丢失，以及 Provider 表单重复 focus ring 等界面问题。

## [0.1.6] - 2026-09-04

### Added

- 新增由 Product Models 管理的 Custom Provider、用户自定义模型与全局默认选择；支持直接录入 API Key 和独立模型测试，无需 Metask 登录，并完成 Windows/macOS connection readiness 验证。
- 新增 PNG、JPEG、WebP 与 PDF 多模态输入，贯通原生文件选择、Host staging、Run admission、Agent 输入和脱敏历史。
- 新增 typed File Changes，提供有界持久化、artifact reconciliation、路径重新校验和按 Run 查看变更的抽屉。
- 新增 Task Permission Profile 首个切片，支持 `approval_required` 与 `full_access`；Scheduled Task 固定非交互执行策略并持久化 source-qualified model binding。
- 新增 backend-neutral SQL contract 与直接 SQLite backend，覆盖 migration、transaction、lifecycle 和 crash recovery；尚未接入正式 Product persistence。

### Changed

- AgentCore hard cut 到 ABI v1 revision 16；Host 使用显式模型协议，并接入 OpenAI Responses、图片与 PDF input part。
- Native SDK 升级至 `0.10.1`。
- 将模型与执行 authority 从 Account 解耦，由 Product Models 独占 Provider、catalog、selection 和 execution source；删除 `ModelConnection` 与 `ProviderKind` 旧模型。
- 重组 Settings 为独立导航页面，分离 Provider 配置、模型管理、默认模型与 Account 登录状态。
- 收紧 Product Task 的 worker lease、durability preparation、checkpoint outcome 与 lifecycle transaction 边界。

### Fixed

- 修复 Account OAuth callback、token refresh、cold restore 与 Bridge validation 的生命周期缺口。
- 修复模型默认值与 canonical store 恢复，以及 Provider registry 变更时在途模型测试未正确收口的问题。
- 修复 Task 持久化失败后的可用性、未知 checkpoint outcome、late credential 清洗与 recovery artifact 回收。
- 修复 File Changes diff 重读、terminal persistence 与 execution source replacement 的原子性问题。
- 修复 Scheduled Task 未可靠清除 credential、缺少 Task persistence 时仍可能进入 admission，以及 permission-required 后台停止未完整收口的问题。
- 移除选择 Manual Workspace 后重复出现的 trust 确认。

## [0.1.5] - 2026-08-29

### Added

- 新增 Windows ARM64 签名打包流程；x64 与 ARM64 分别生成版本化安装器，并遵循相同的 Authenticode 验证规则。
- 新增原生单实例协调与受控启动转交，并补充进程级生命周期验证。
- 新增异步文件预览抽屉；Host 在读取前重新校验 Task、Run 与文件引用，并限制读取范围和响应大小。
- 新增 Agent 对话过程呈现，区分过程说明与最终回复，并展示统一的 Run 执行状态。

### Changed

- AgentCore 升级至 ABI v1 revision 14，并锁定 macOS arm64/x64、Windows x64/ARM64 四个目标的独立 bundle。
- Completion 脱离 AgentCore Runtime，改由 Agent 提供独立、一次性的非流式调用能力。
- 将原 Workbench composition owner 收口为 Product Control，并将 Workspace 与 Schedule 状态分别归入各自 Runtime。
- 收紧 Account execution authority，避免 Product Control 持有或推导不属于自身的执行配置事实。

### Fixed

- 修复 Task 终态事件尚未排空时提前发布结果，以及活跃 Run 阶段被错误视为终态的问题。
- 修复 Task 模型选择未精确绑定 Metask execution authority 的问题。
- 修复 Scheduled Task 将 execution credential 遗留在持久状态中的问题。
- 修复单实例 endpoint 安全、启动转交重试和失败结果不确定的问题。

## [0.1.4] - 2026-08-26

### Added

- 新增 macOS x64 发布目标；macOS 打包默认同时生成 arm64 与 x64 DMG，并保留已有架构产物。
- MCP server 启用状态进入产品投影，启动不再等待 server activation，并简化配置与恢复流程。

### Changed

- 将 Product Task、MCP 与 Skill 收口为各自的 live aggregate，关闭跨 owner 的内部状态与生命周期入口，并隔离 executor job 和 catalog refresh worker。
- AgentCore bundle 改为按目标平台选择 canonical bundle，开发与发布流程使用同一 target-specific 规则。

### Fixed

- 修复 Conversation 恢复错误绑定历史 execution generation 的问题；兼容当前 provider/model authority 时持久化推进 Task binding，并在首次发送前透明恢复。
- 修复 Task Session 所有权竞态与 recovery authority 失效处理。
- 修复 Skill 无效重调度，以及 MCP applying 状态和 mutation locking。
- 修复 Windows 主程序图标嵌入，以及 macOS flat icon 打包与 staged icon cache 刷新。

## [0.1.3] - 2026-08-24

### Added

- 新增 Agent Completion capability；Workbench 在首个 Run admission 时显示 provisional title，并在 Run 收口后通过独立 Completion 生成不超过 32 个 Unicode 字符的 Task 标题。

### Changed

- 统一 Agent provider identity，并将 Account provider probe 迁移到 Completion capability。
- 定义 Account transaction architecture，收口 transaction kernel 状态模型，并 hard cut model preference transaction 路径。

### Fixed

- 修复 MCP catalog freshness 生命周期，覆盖 refresh operation 串行化、deadline 保留、Workbench pending request 和 Conversation restore。
- 修复 Account identity 切换或退出被 live Task 阻止的问题；既有 Task 继续使用已取得的 ExecutionConfig 收口，不被中止或改写。
- 修复账号菜单退出必须先打开设置页，以及 signed-out identity 与菜单状态不清晰的问题。
- 修复 Account terminal transaction 在 preference recovery 与 catalog terminal handoff 后遗留 shadow、candidate 或 secret session 的问题。

## [0.1.2] - 2026-08-22

### Added

- 启用并重设计 MCP 管理页，覆盖 server 配置、授权、测试、启停、工具 allowlist 与恢复交互。
- 新增 Workbench-owned 持久化分层 Skill 启用策略，支持用户默认值、项目 override，并端到端接入 Workspace 与 Run admission。
- 新增 SDK-independent SQL foundation contract、直连 SQLite backend 及对应 migration、transaction 和 conformance tests。
- 建立统一的应用与托盘图标资产管线。
- 新增签名的 Windows x64 安装包，以及带 Applications 拖拽布局、签名和公证的 macOS DMG 发布流程。

### Changed

- AgentCore hard cut 到 ABI v1 revision 9 skill policy contract；Skill authority 改为不可变、事务化的 Run 输入，并停止注册 `AskUserQuestion`。
- MCP 配置现在可在不重启应用的情况下应用；管理页统一布局，并 hard cut 到当前 AgentCore HTTP response contract。
- Renderer conversation surfaces 迁移到统一 AI UI primitives，收口重复的消息、活动状态和交互实现。
- Account hard move 到 `src/product/account/`；Application 通过 Account-owned ports 绑定 HTTP、OAuth loopback、credential persistence 和其他平台 effect。
- 收紧 Agent 与 Application 的 MCP transport boundary，减少跨 owner 的具体 transport 依赖。
- 更新 Windows/macOS AgentCore staged artifacts，纳入 Conversation restore、Skill policy 与 MCP 修复。
- 重新明确验证 owner、失败模式与最小充分测试层，并将 lifecycle roots 和真实架构边界接入默认测试守卫。
- 隔离 automation runner identity，并更新 vertical fixtures 以匹配当前产品合同。

### Fixed

- 修复 Skill 管理与 Run admission 共享可变 policy context，以及 enablement 持久化失败后的状态一致性问题。
- 修复 MCP stdio executable `PATH`、stderr EOF teardown 和 SSE 空事件处理问题。
- 修复 MCP 恢复交互与管理页重构后的残留状态、组件和样式路径。
- 修复关闭 Task 后的删除协调流程，以及不适用的降级历史提示仍被显示的问题。
- 明确定义并修复 Storage receiver callback 的 reentrancy 行为。
- 修复 macOS package 缺少托盘图标资源及 Settings sidebar 样式不一致的问题。

## [0.1.1] - 2026-08-18

### Added

- 新增 Account-owned 用户模型连接运行时、持久化 registry、Bridge command/projection，以及 Metask managed 与 user-managed execution source 的显式切换事务。
- 接入 OpenAI Chat Completions 与 Gemini Native typed provider contract、AgentCore provider probe 和合同测试；Anthropic Messages 在原生 `x-api-key` 合同可用前保持 capability gate 关闭。
- 新增 Windows/macOS `native_sdk_compat/secure_input` 窄 capability seam，并将 MCP secret capture 接入 Host-owned 安全输入路径。
- 新增 `TaskContent`、`TaskOverview` Run activity 投影与可拖拽工作台侧栏；补齐对应 Renderer contract、decode、i18n 和交互测试。

### Changed

- 将 Agent Session 拆分为 `control`、`binding`、`runtime`、`wire` 叶模块，并把 MCP 实现收口到 `src/agent/mcp/`；同步强化 owner-boundary 与 inline coverage guard。
- Renderer hard cut 从 `AgentWorkSurface`/本地 conversation projection 切换到 Host 投影驱动的 `TaskContent`，删除失去职责的旧 AI 组件和样式路径。
- Workbench Run projection 区分 thinking、responding 与 tool activity，并统一 Task 消息排版和活动状态呈现。
- Workspace Edit permission 默认决策调整为 accept。
- Native SDK 升级到 `0.9.2`，并更新 Windows/macOS AgentCore staged bundle、lock 与 ABI 验证基线。

### Fixed

- 修复 Agent Runtime MCP selection update 未向外暴露的问题。
- 修复 UI request 在用户响应前提前离开 pending 状态，以及 Renderer 未在对应阅读位置渲染 pending request 的问题。
- 修复活跃 Run 进度未同步到 Task 内容区和详情投影的问题。
- 修复 Account 菜单设置入口未打开设置根页面的问题。

## [0.1.0] - 2026-08-16

### Added

- 桌面 Agent Workbench 首个发布版本：Windows x86_64（development baseline）与 macOS arm64（本地签名打包）。
- Metask Account：OAuth 登录、API Key 与模型目录、默认 API/模型切换与持久化；默认配置变更不影响已有 Task。
- Task 工作台：Task 创建、重命名、归档、关闭与删除；自动标题回退；任务状态通知；每个 Task 独立绑定模型。
- Agent 执行：基于 Metask AgentCore（ABI v1 revision 8）的 typed Text/Skill Run；内置 Read/Bash/Edit 工具；question/permission 用户决策；Run 取消；结构化 run 状态投影。
- 会话管理：手动 `/compact` 压缩；checkpoint 持久化，应用重启后从最近 finalized checkpoint 显式恢复 Conversation。
- Workspace：Manual Workspace 授权与复用；Automatic Workspace 按 Task 独立分配目录。
- 技能管理：本地 Skill 导入（包/目录）、导出、重新导入与卸载，支持个人与项目两种作用域。
- 定时任务：本地进程内 cron 调度；窗口关闭后继续运行；下次启动执行单次 missed-run reconciliation。
- 界面：中英双语；统一的 Metask 设计语言字号阶梯与组件体系。

[unreleased]: https://github.com/metask-ai/metawork/compare/v0.2.9...HEAD
[0.2.9]: https://github.com/metask-ai/metawork/compare/v0.2.8...v0.2.9
[0.2.8]: https://github.com/metask-ai/metawork/compare/v0.2.7...v0.2.8
[0.2.7]: https://github.com/metask-ai/metawork/compare/v0.2.6...v0.2.7
[0.2.6]: https://github.com/metask-ai/metawork/compare/v0.2.5...v0.2.6
[0.2.5]: https://github.com/metask-ai/metawork/compare/v0.2.4...v0.2.5
[0.2.4]: https://github.com/metask-ai/metawork/compare/v0.2.3...v0.2.4
[0.2.3]: https://github.com/metask-ai/metawork/compare/v0.2.2...v0.2.3
[0.2.2]: https://github.com/metask-ai/metawork/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/metask-ai/metawork/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/metask-ai/metawork/compare/v0.1.12...v0.2.0
[0.1.12]: https://github.com/metask-ai/metawork/compare/v0.1.11...v0.1.12
[0.1.11]: https://github.com/metask-ai/metawork/compare/v0.1.10...v0.1.11
[0.1.10]: https://github.com/metask-ai/metawork/compare/v0.1.9...v0.1.10
[0.1.9]: https://github.com/metask-ai/metawork/compare/v0.1.8...v0.1.9
[0.1.8]: https://github.com/metask-ai/metawork/compare/v0.1.7...v0.1.8
[0.1.7]: https://github.com/metask-ai/metawork/compare/v0.1.6...v0.1.7
[0.1.6]: https://github.com/metask-ai/metawork/compare/v0.1.5...v0.1.6
[0.1.5]: https://github.com/metask-ai/metawork/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/metask-ai/metawork/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/metask-ai/metawork/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/metask-ai/metawork/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/metask-ai/metawork/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/metask-ai/metawork/releases/tag/v0.1.0

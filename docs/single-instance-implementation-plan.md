# MetaWork 单实例运行实施方案

状态：复盘修订后的最终方案（待实施）

适用平台：Windows、macOS

## 1. 目标

MetaWork 默认采用单实例运行。同一实例域内重复启动时，新进程将经校验的启动请求转交给现有实例；现有实例唤醒并显示主窗口，同时请求系统将其聚焦。转交成功后，新进程立即退出。

开发版、自动化测试版与正式版使用不同的实例标识、数据目录和凭据命名空间，彼此不冲突，但各自保持单实例。

本方案必须同时保证：

- 重复启动回到已运行的 MetaWork，而不是创建第二个 Host；
- Secondary 在任何业务 Store、Account、Product、Bridge 或 Native Runtime 初始化之前退出；
- 同一份业务数据在任意时刻最多由一个 Host 写入；
- 窗口显示和聚焦继续通过 Native SDK Runtime 执行；
- 不修改 Native SDK，不在 Renderer 或 Product owner 中实现系统行为。

## 2. 实例 ownership 与 artifact identity

单实例 ownership 不是 Metask 账号、登录身份或业务用户身份。必须区分两个概念：

```text
instance ownership scope = current OS user + canonical data root
artifact identity = development | release | automation 对应的稳定应用身份
```

其中：

- canonical data root 是通过系统目录句柄解析后的真实数据目录；
- instance ownership scope 决定 lease 和 IPC endpoint，是防止双写的最终正确性边界；
- artifact identity 决定 Native SDK、数据目录、credential 和日志等预期 namespace，并在 IPC 握手中校验；
- artifact identity 不参与 lease ownership，也不参与 endpoint 寻址。

由此得到以下行为：

- 同一系统用户、同一 canonical data root：无论 artifact 配置为何，都只能有一个 Host；
- development、release、automation 必须通过构建 guard 映射到不同数据目录，因此正常情况下可以同时运行；
- 如果两个 artifact 被错误配置到同一数据目录，它们会竞争同一个 lease，Secondary 可以连接到同一个 endpoint，并因 artifact identity 不匹配得到 `incompatible`；
- 不同系统用户由各自的数据目录、endpoint namespace 和 IPC 权限隔离；
- automation 可以通过不同临时数据目录并行，但同一个测试沙箱内仍保持单实例。

## 3. 架构边界

### 3.1 Application owner

新增 `src/app/single_instance.zig`，由 Application 拥有单实例产品语义和生命周期编排，负责：

- 构造、解析并校验启动请求；
- 管理 Runtime ready 前的有界请求队列；
- 接收第二实例激活请求；
- 通知 Native SDK 主线程事件循环；
- 在主线程调用现有 `app/window.zig` 窗口能力；
- 管理 `starting`、`ready` 和 `stopping` 状态。

该模块不拥有 Product、Account、Task 或 Renderer 状态，不解释业务数据，也不成为新的产品 owner。

### 3.2 Native SDK compatibility seam

新增：

```text
src/native_sdk_compat/app_single_instance.zig
src/native_sdk_compat/app_single_instance/windows.zig
src/native_sdk_compat/app_single_instance/macos.zig
```

该 seam 只补齐 Native SDK 当前缺失的应用实例协调能力，负责：

- 获取和持有 data-root 独占 lease；
- 建立当前用户范围的本机 IPC；
- 收发有界协议帧；
- 校验本机 peer 身份；
- 在交互式 Secondary 无法完成转交时显示固定、枚举化的启动失败提示；
- 停止 listener 并释放平台资源。

该 seam 不得：

- 打开任何业务 Store；
- 持有 Product、Account、Bridge 或 Renderer 状态；
- 显示、恢复或聚焦 MetaWork 主窗口；
- 接受任意标题、正文或按钮配置来形成通用系统对话框；
- 持有可传播到其他 owner 的系统 handle；
- 演变成通用 Desktop Interface、进程管理框架或第二套窗口 owner。

窗口显示和聚焦继续使用 `src/app/window.zig` 现有实现：

```zig
runtime.showWindow(main_window_id)
runtime.focusWindow(main_window_id)
```

Native SDK 未来提供并通过目标平台验收的正式单实例 API 后，原位替换并删除该 compat seam、平台子文件、allowlist 和专用验证，不保留双实现。

## 4. 构建身份、现有 namespace 归属与迁移

构建系统引入显式 artifact kind：

```text
development
release
automation
```

不能使用 Debug、ReleaseSafe 等优化等级推断身份，因为优化等级不等于产品身份。

artifact kind 必须由构建入口显式选择，不能由优化等级或“是否打包”间接推断。当前仓库的 `app.zon` identity 是 development 产品身份；签名安装包和 DMG 仍使用该 development channel，不会因为采用 ReleaseFast、Developer ID 或 Authenticode 就自动成为独立 release channel。

现有和目标 namespace 归属固定为：

| Artifact kind | Runner identity                       | 数据目录                                  | Account credential service  | MCP credential service   | 既有状态归属                                 |
| ------------- | ------------------------------------- | ----------------------------------------- | --------------------------- | ------------------------ | -------------------------------------------- |
| `development` | 当前 `app.zon` identity               | Windows `MetaWork`；macOS `MetaWork Dev`  | 当前 `<base>.account`       | 当前 `<base>.mcp`        | 继承全部现有非 automation 状态               |
| `automation`  | `<base>.automation`                   | `MetaWork Automation` 或 harness 临时目录 | `<base>.automation.account` | `<base>.automation.mcp`  | 不读取或迁移 development 状态                |
| `release`     | 经发布决策明确登记的 release identity | 经发布决策明确登记的 release 数据目录     | 由 release identity 派生    | 由 release identity 派生 | 新 channel；不得从 `.dev` 名称猜测或静默导入 |

因此：

- `npm run dev`、普通 build 以及当前使用 `.dev` identity 的 package 入口仍属于 `development`；
- automation harness 显式选择 `automation`；
- `release` 只有在正式 identity、数据目录、Account service 和 MCP service 全部登记且两两隔离后才允许构建；配置不完整必须在 build/package 阶段 fail closed；
- 当前 development 数据和 credential namespace 保持不变，不发生静默“数据丢失”；
- automation 的 MCP credential 当前尚未隔离，实施时必须原地修正为 `.automation.mcp`，不得迁移或读取 development secret；
- 未来若决定把 development 状态导入 release，必须作为独立、显式、可回滚且不复制 secret 的迁移项目处理，不属于单实例实现。

每种已启用 artifact 必须分别拥有：

- Native SDK runner identity；
- 产品数据目录；
- Account credential service；
- 通过独立数据目录得到的单实例 endpoint namespace。

architecture/build guard 必须证明任意两个已启用 artifact 的 runner identity、默认 canonical data root、Account credential service 和 MCP credential service 两两不同。`app.zon` 声明的 development Bundle ID 不在本次工作中重命名；release Bundle ID 会影响安装、签名、凭据和已有数据，必须由独立发布决策明确提供，不能由代码删除 `.dev` 后缀进行猜测。

development/release artifact 不提供 `--multi-instance`、环境变量或隐藏配置来绕过单实例。自动化并行通过隔离数据目录实现，而不是关闭单实例保护。

## 5. 启动时序

单实例仲裁必须发生在所有业务持久化和 Runtime 初始化之前。

实施后的启动顺序为：

1. 解析 artifact kind 和启动环境；
2. 解析并创建目标数据目录；
3. 通过系统目录句柄取得 canonical data root；
4. 解析并限制 argv 和 working directory；
5. 尝试取得 data-root 独占 lease；
6. 取得成功时，立即建立 IPC listener，成为 Primary；
7. 取得失败时，连接 Primary、转交启动请求并等待 ACK；
8. 收到 `accepted` 后，Secondary 立即退出；
9. 只有 Primary 才继续解析 frontend assets，初始化 Stores、Account、Product、Bridge 和 Native Runtime；
10. Native Runtime ready 后处理启动阶段积压的激活请求；
11. 运行期间的新请求通过现有 `PlatformServices.wake()` 唤醒主线程；
12. `App.event(.effects_wake)` 在主线程排空请求，并调用 `showMainWindow()`。

listener 线程只能验证、入队和请求 wake，不能跨线程调用 Native SDK Runtime 或 WebView。

Primary 必须先取得 lease，再建立 IPC，之后才能初始化业务。若 IPC listener 建立失败，Primary 必须释放 lease 并中止启动，不能降级成没有单实例保护的运行模式。

## 6. 启动请求协议

定义内部协议 `metawork.app-activation/1`。该协议属于 Application 内部进程协调，不修改 Renderer Bridge revision。

endpoint 必须跨 artifact 配置错误和协议升级保持稳定：

```text
endpoint key = current OS user identity digest + canonical data root digest
```

artifact identity 和 protocol revision 只能进入握手帧，不能进入 pipe/socket 名称。这样旧版本、新版本或错误 artifact 指向同一数据目录时仍能连接到 lease owner，并得到准确的 `incompatible`，而不是被误诊为 endpoint 未就绪或超时。

请求至少包含：

- protocol magic 和 revision；
- artifact/Application ID digest；
- canonical data root digest；
- argv；
- working directory。

建议固定以下上限，并由 codec 和测试共同约束：

- 参数数量不超过 64；
- 单参数不超过 4 KiB；
- argv 总大小不超过 32 KiB；
- working directory 不超过 4 KiB；
- 总协议帧不超过 64 KiB。

当前产品行为只有“激活并显示主窗口”。参数可以被转交，但只有 Application 明确支持并再次校验的参数才能产生行为。未知参数不能获得文件、Workspace、Product 或系统 capability。

响应固定为：

- `accepted`：请求已经进入 Primary 的有界队列；
- `stopping`：Primary 已停止接收新请求；
- `incompatible`：identity 或协议 revision 不兼容；
- `rejected`：请求非法、超限或队列无法接收。

只有成功入队后才能返回 `accepted`。纯激活请求可以合并，避免大量重复启动占满队列；携带未来受支持参数的请求不得在未处理时静默丢弃。

协议内容不得包含 credential，不记录完整敏感参数；诊断只记录结果类别、revision 和经过处理的 identity 摘要。

## 7. Windows 实现

- 在 canonical data root 中使用锁文件，以独占文件句柄作为 lease；
- 文件是否残留不代表实例存活，只有系统持有的独占句柄代表 ownership；
- 使用仅允许当前 Windows 用户访问的 Named Pipe；
- pipe 名称只由当前 Windows 用户 SID 摘要和 canonical data root digest 派生；
- Secondary 连接后通过系统 API 取得 Primary PID，不信任请求或响应中的裸 PID；
- Secondary 在系统策略允许时调用 `AllowSetForegroundWindow(primary_pid)`，把本次前台激活资格交给 Primary；
- Primary 收到请求后在主线程调用 Native SDK `showWindow` 和 `focusWindow`。

Native SDK Runtime 负责恢复最小化或托盘隐藏的窗口并请求焦点。系统可能基于前台切换策略拒绝绝对聚焦，因此产品合同是“请求系统聚焦”，而不是绕过系统策略强制抢焦点。

## 8. macOS 实现

- 在 canonical data root 中使用锁文件和 `flock` lease；
- 使用 Unix-domain socket 传递启动请求；
- socket 放在仅当前用户可访问的目录中，endpoint 名只使用当前 UID 和数据目录摘要，避免 Unix socket 路径长度限制；
- 校验 peer effective UID，拒绝其他用户连接；
- Finder 和 Dock 的普通 reopen 继续使用 Native SDK/AppKit 已有生命周期；
- 直接执行二进制或 `open -n` 产生的第二进程通过 Unix-domain socket 转交请求。

崩溃后可能残留 socket 文件。只有成功取得 data-root lease 的新 Primary 才有权清理并重建该 socket，Secondary 不得依据文件存在与否自行删除。

## 9. 明确不采用的机制

- 不使用 loopback TCP，避免端口、代理、防火墙和网络认证问题；
- 不使用 PID 文件判断进程存活；
- 不主动杀死旧进程；
- 不在 Renderer 中模拟单实例或窗口聚焦；
- 不让 Product、Account 或 Bridge 持有 OS lock、pipe、socket 或窗口 handle；
- 不修改或复制 Native SDK；
- 不因为 SDK 当前缺少能力而建立通用原生平台抽象层；
- 不把固定的单实例启动失败提示扩展成 Renderer、Product 或其他 Application 用例可调用的任意对话框能力。

## 10. 竞态和失败策略

### 10.1 Primary 尚未完成启动

Primary 取得 lease 后立即建立 listener。Secondary 发现 lease 已占用但 endpoint 尚未 ready 时进行有界重试。请求可以在 Runtime ready 前入队，Runtime ready 后统一处理。

### 10.2 Primary 正在退出

Application 首先停止单实例 ingress，listener 对新请求返回 `stopping`。Secondary 可以有界等待 lease 释放，随后重新竞争并成为新的 Primary；等待超时则 fail closed。

### 10.3 Primary 无响应或协议不兼容

Secondary 不得绕过 lease 启动第二个完整 Host。诊断必须区分 endpoint 未就绪、超时、协议不兼容、身份不匹配和请求被拒绝。

交互式 development/release Secondary 在退出前显示固定提示：

- 协议或 artifact 不兼容：提示用户先退出正在运行的 MetaWork，再启动当前版本；
- Primary 无响应：提示 MetaWork 已运行但无法激活，用户应返回现有窗口或退出后重试。

提示内容由失败枚举映射，不能携带 argv、路径、credential、底层错误或任意调用方文本。automation 不弹出系统对话框，只产生有界诊断并以非零状态退出。所有场景都同时记录安全的启动诊断。

### 10.4 Primary 崩溃

操作系统自动释放锁句柄或 `flock`。新的启动进程取得 lease 后成为 Primary，并清理由同一实例域遗留的 IPC endpoint。禁止通过 PID 猜测或超时直接宣告旧实例死亡。

### 10.5 并发重复启动

多个 Secondary 可以并发连接，但请求队列必须有界。纯窗口激活请求进行合并，最终至少触发一次显示和聚焦请求。未成功入队的请求必须得到 `rejected`，不能返回伪成功。

## 11. Shutdown 顺序

退出顺序必须为：

1. 将单实例状态切换为 `stopping`；
2. 停止接收新请求；
3. listener 返回 `stopping`、退出并 join；
4. 停止 Bridge ingress；
5. 停止 Product、Agent 和 Account；
6. 关闭全部业务 Store；
7. 最后释放 data-root lease 和 IPC 资源。

lease 必须覆盖整个业务持久化生命周期。提前释放 lease 会允许新 Primary 在旧 Host 尚未关闭 Store 时进入，从而破坏单写保证。

## 12. 代码变更范围

预计涉及：

```text
src/app.zig
src/app/single_instance.zig
src/app/platform.zig
src/app/window.zig
src/app/paths.zig
src/product_identity.zig
src/product/account/credential_store.zig
src/app/mcp_platform.zig
src/native_sdk_compat/app_single_instance.zig
src/native_sdk_compat/app_single_instance/windows.zig
src/native_sdk_compat/app_single_instance/macos.zig
build.zig
scripts/build.mjs
scripts/package-windows.mjs
scripts/package-macos.mjs
scripts/package-metadata.mjs
相关 automation harness 与 architecture guards
```

`src/app.zig` 只保留组合、顶层启动顺序和 Native SDK App vtable；协议、队列、平台锁和 IPC 实现不能堆入 composition root。

不需要修改：

- Native SDK 外部依赖；
- Renderer Bridge command、event、Snapshot 或 revision；
- Product owner 的事务和并发合同；
- Account 外部合同；
- AgentCore ABI 或运行协议。

## 13. 首次引入与升级边界

单实例协议无法让已经运行、且尚未实现本协议的旧 MetaWork 进程补持新 lease。首次发布单实例能力时必须显式处理这个 rollout 边界：

- Windows 安装或覆盖升级必须检测正在运行的已安装 MetaWork，并要求用户完成正常退出后再替换文件；不得强杀可能仍有 Task 或 Scheduled Task 的旧 Host；
- macOS 当前没有自动更新协议，替换 `.app` 前必须退出旧应用；分发文档和验收必须明确这一前置条件；
- 不支持在旧 Host 仍运行时，通过直接执行新二进制、`open -n` 或复制另一份应用完成跨代 handoff；该场景不能声称具备单实例或单写保证；
- 第一版单实例应用正常退出并重新启动后，后续兼容版本都通过稳定 endpoint 和握手处理重复启动及版本冲突。

现有 Product Store writer lock 继续作为各 Store 自己的持久化保护，但不能替代 Application data-root lease，也不能被用来猜测旧 Host 状态。安装器、DMG 和未来 updater 的升级协议不由本方案发明；本方案只要求首次部署不能在旧 Host 运行时切换到新二进制。

## 14. 文档同步

实施时必须同步更新：

- `docs/requirements.md`：定义用户可观察的单实例语义；
- `docs/architecture.md`：登记 Application owner、compat seam、线程与生命周期边界；
- `docs/project-structure.md`：登记新增模块、依赖方向和 artifact identity；
- `docs/validation.md`：登记精确 allowlist、平台验收矩阵和 seam 删除条件；
- `docs/windows-distribution.md`：登记首次升级前退出旧 Host 的安装门槛；
- `docs/macos-local-development.md`：登记 development namespace 归属和替换应用前的退出要求。

本文是实施方案，不替代上述 source of truth。实现落地时，稳定产品和架构语义必须进入对应规范，避免本文成为第二份长期合同。

## 15. 验证矩阵

### 15.1 平台无关测试

- 协议 encode/decode、revision 和长度边界；
- argv、working directory 和 identity 校验；
- 有界队列和激活请求合并；
- `accepted` 只在成功入队后返回；
- `starting`、`ready`、`stopping` 状态转换；
- endpoint key 不包含 artifact identity 或 protocol revision；
- development、automation 以及未来启用的 release identity/data/Account/MCP namespace 两两不同；
- development 精确保留现有数据和 credential namespace，automation MCP 精确使用 `.automation.mcp`；
- listener 线程只入队和 wake，窗口调用只发生在主线程；
- 固定启动失败提示只接受枚举，不接受任意文本；automation 不产生系统对话框；
- architecture guard 精确限制 compat 文件、导入方向和系统 API symbol。

### 15.2 跨进程测试

- 同一数据目录并发启动 20 个进程，最终只有一个 Primary；
- Secondary 在业务 Store 初始化前退出；
- Primary 冷启动期间收到请求，Runtime ready 后正确处理；
- shutdown 期间重复启动；
- Primary crash 后重新启动，无 stale-lock 阻塞；
- endpoint 未就绪、无响应、协议不兼容和非法请求均 fail closed；
- 不同协议 revision 和错误 artifact identity 能连接到稳定 endpoint 并收到 `incompatible`；
- release profile 启用后，development、release、automation 可以同时运行，但各自单实例；
- 不同 automation 临时数据目录可以并行；
- 同一 automation 临时数据目录仍只有一个 Primary。

### 15.3 Windows 真实验收

- 主窗口可见时重复启动；
- 主窗口最小化时重复启动；
- 主窗口关闭到托盘时重复启动；
- Named Pipe 当前用户权限；
- 交互式不兼容/无响应提示与 automation 无提示行为；
- 前台授权传递以及 `showWindow`、`focusWindow` 请求；
- 首次升级时运行中的旧 Host 阻止安装替换；
- clean shutdown 和强制终止后的 lease 恢复。

### 15.4 macOS 真实验收

- Finder 双击和 Dock reopen；
- 主窗口隐藏后 reopen；
- 直接执行二进制产生的第二进程；
- `open -n` 启动；
- Unix-domain socket 权限和 peer UID；
- 交互式不兼容/无响应提示与 automation 无提示行为；
- 替换旧 `.app` 前退出旧 Host 的发布验收；
- clean shutdown、强制终止和残留 socket 恢复。

## 16. 完成标准

只有同时满足以下条件，单实例能力才能视为完成：

- 用户重复启动时回到原有 MetaWork 窗口；
- 同一实例域内始终只有一个持有业务数据写权限的 Host；
- Secondary 不初始化任何业务 owner 或 Store；
- 开发、自动化测试和正式 artifact 完全隔离；
- 现有 development namespace 继续可见，automation 不读取 development Account 或 MCP credential；
- endpoint 对 artifact/revision 稳定，版本或身份不兼容得到准确响应；
- 交互式异常不会静默退出，automation 不弹出阻塞对话框；
- 首次部署路径要求旧版 Host 先退出，并且不声称支持旧版与新版跨代并存；
- Windows 与 macOS 的真实启动路径通过验收；
- 所有异常路径 fail closed，不存在绕过 lease 的 fallback；
- Native SDK 未被修改，所有低层系统 API 都被限制在登记的 compat seam；
- requirements、architecture、project structure、validation 与实现一致；
- seam 具有明确的上游替换和删除条件。

# MetaWork macOS 分发

> 状态：macOS 本地签名、Developer ID、DMG、公证和发布验证的 source of truth

本文定义 macOS 平台使用的两套签名身份。Apple Development 只保证本机构建在重新签名后仍有稳定 `TeamIdentifier`，从而维持 Account Keychain 身份；它不是分发身份。`npm run package:macos` 使用独立的 `Developer ID Application` identity，按显式架构选择生成经过签名、公证和验证的 DMG。

开发和打包签名彼此独立：跨平台 `scripts/dev.mjs` 独占 Apple Development 本地签名策略，setup 只复用该 owner；`scripts/package-macos.mjs` 只拥有 Developer ID、DMG、公证和发布验证。正式分发不能在 identity 缺失或歧义时回退到开发证书、自签名或 ad-hoc 签名。

两条流程都直接读取 `app.zon` 中现有的 Bundle ID 与 executable name；当前分别是 `com.metask.metawork.dev` 和 `metawork`。`app.zon` 是跨平台产品 identity 与 release version 的唯一真源，Application 通过 `src/product_identity.zig` 消费同一个 Native SDK manifest module。Account 在所有平台使用同一 persistence 合同：`com.metask.metawork.dev.account` secure service 只保存 refresh token；模型选择由 Models 的 `models.json` 独立持久化。旧开发命名空间与 retired Models 文件都不迁移、不 fallback。

## 本地签名（非分发）

MetaWork 的真实 Account 开发流程使用 Apple 签发、带稳定 `TeamIdentifier` 的 `Apple Development` Code Signing identity。它只解决同一台开发机上重新构建后的 macOS Keychain 身份稳定性，不用于向测试人员或用户分发应用。

自签名证书不是可接受的替代品。真实复验证明，即使自签名证书和 designated requirement 保持不变，签名报告仍是 `TeamIdentifier=not set`；Keychain partition 会继续绑定随构建变化的 CDHash，用户选择“始终允许”后，下一次构建仍可能再次弹出授权框。

### 一次性平台准备

免费 Apple Account 可以通过兼容当前 macOS 的 Xcode 创建 Personal Team 开发证书：

1. 打开 Xcode → Settings → Accounts；
2. 登录 Apple Account；
3. 选择 Personal Team，打开 Manage Certificates；
4. 新增 `Apple Development` certificate。

付费 Apple Developer Program 账号也可以通过开发者网站创建证书并将证书与对应 private key 导入登录钥匙串。无论采用哪种方式，MetaWork 都不会生成、撤销或删除 Apple Development identity。

确认登录钥匙串中存在有效 identity：

```bash
security find-identity -v -p codesigning ~/Library/Keychains/login.keychain-db
```

如果 Xcode 已创建证书与 private key，但上面的命令仍没有列出 Apple Development identity，通常是 WWDR G3 中间证书缺失。setup 会优先跟随 `xcode-select -p` 当前选择的 Xcode，并以标准位置 `/Applications/Xcode.app` 作为 fallback，导入 Xcode 自带的 Apple 官方 G3 中间证书；它不会设置自定义 trust。两个位置都不可用时，先从 [Apple PKI](https://www.apple.com/certificateauthority/)手动安装 `Worldwide Developer Relations - G3`。

### 项目一次性选择

执行：

```bash
node scripts/setup-macos-local-signing.mjs setup
```

如果存在多个 Apple Development identity，命令会 fail closed。将 `security find-identity` 输出中的 40 位 fingerprint 显式传入：

```bash
node scripts/setup-macos-local-signing.mjs setup 0123456789ABCDEF0123456789ABCDEF01234567
```

setup 只做以下操作：

- 选择一个精确 fingerprint；
- 签名并验证安全临时探针；
- 从探针的 `codesign` 报告读取真实 `TeamIdentifier`，绝不从证书显示名称末尾的括号推断；
- 把 fingerprint、证书名称和 Team ID 写入被 Git 忽略且权限为 `0600` 的 `.metawork-local-signing.json`。

临时探针位于权限受限的系统临时目录，成功、失败或收到终止信号都会清理。macOS 如果询问 `/usr/bin/codesign` 使用 private key，完成一次授权即可。

清除项目的本机选择使用：

```bash
node scripts/setup-macos-local-signing.mjs clear
```

该命令不会修改或删除钥匙串中的 Apple Development identity。

### 开发入口

```bash
npm run dev
```

macOS `dev` 读取 `app.zon` 的现有 identifier，确认本机已选择的 identity 仍然有效；Renderer 静态资源和 Debug Host 从构建输出开始使用本次独立目录，再对最终运行位置的 executable 写入 canonical designated requirement。验证阶段必须精确读回该 requirement，并由系统 requirement engine 独立复核 identifier、Apple anchor、Team 与所选 Apple Development certificate。开发入口直接启动这组成套产物，不启动 Vite，也不继承前端 URL/HMR 覆盖；进程存活期间资源不被后续构建覆盖。默认开发循环是正常退出后重新构建启动。

开发启动要求取得新 primary；已有同身份实例占用时明确失败，不把激活旧窗口算作新构建成功。普通产品重复打开的单实例激活语义保持不变。开发脚本只管理自己的子进程，正常退出后清理本次目录；异常退出不能证明全部后代已停止时保留目录，不能仅凭原进程组消失就删除资源。构建、部署或签名失败不能回退上次产物。Office、archive、Skill 开发配置和 credential namespace 保持原 owner 的既有规则。

取消开发启动时先请求自有子进程退出；宽限期后仍存活时，仅终止其自有进程组并等待关闭，不能无限等待不响应退出信号的进程。该兜底不改变异常输出目录的保留规则，也不能用于停止其他实例。

## 凭据准备

先在 Xcode 的 Team `Manage Certificates` 中创建 `Developer ID Application`，并确认登录钥匙串同时持有证书和 private key：

```bash
security find-identity -v -p codesigning ~/Library/Keychains/login.keychain-db
```

为同一 Team 的 Apple ID 生成 app-specific password，并以安全交互提示一次性写入本机钥匙串；不得把 password 放在命令参数、环境文件或仓库中：

```bash
xcrun notarytool store-credentials "metawork-notary" \
  --apple-id "<Apple ID>" \
  --team-id "<Team ID>" \
  --validate
```

不提供 `--password` 时 `notarytool` 才会使用安全提示。

## 正式 DMG

profile 验证成功后执行：

```bash
node scripts/stage-agentcore-bundle.mjs /absolute/path/to/aarch64-macos-bundle
node scripts/stage-agentcore-bundle.mjs /absolute/path/to/x86_64-macos-bundle
npm run package:macos
```

stage 入口按 manifest target 将两份 bundle 分别安装到 `.agentcore/bundles/aarch64-macos` 与 `.agentcore/bundles/x86_64-macos`；后一次 stage 不覆盖前一 target。构建从 resolved target 对应 bundle 直接消费其官方 `bindings/zig` package。AgentCore 发布物为压缩包时，先将其完整解压到仓库外的绝对目录，再把该目录交给 stage 入口。

不带参数的 `package:macos` 等价于 `all`，按 arm64、x64 的固定顺序分别完成完整签名与公证，并输出两个 DMG。只构建一个架构时显式执行：

```bash
npm run package:macos -- arm64
npm run package:macos -- x64
npm run package:macos -- all
```

`arm64`、`x64` 与 `all` 是唯一有效选择；缺少所选 target 的 canonical bundle 时在访问签名 identity 前明确失败。发布架构不由最后一次 stage、Host 默认架构或环境变量决定。

DMG 是拖放式分发，不提供能代替用户退出旧 Host 的安装器事务。第一次部署具备单实例能力的版本时，测试者或用户必须先显式退出仍在运行的旧 MetaWork，再替换 `/Applications` 中的 `.app`；旧 Host 尚未持有数据目录 lease，也不理解新的启动转交协议，因此这一代际边界不具备并行运行或双写保护。完成首次切换后，同一 artifact 与数据目录的兼容版本由应用自身执行单实例转交。

打包入口先要求当前 `xcode-select` 提供 allowlist 内的 Xcode `actool`，把 `assets/icons/MetaWork.icon` 编译为临时 `Assets.car` 与 fallback ICNS；普通开发、check、test 和 build 不调用该工具。随后从 `security find-identity` 精确筛选唯一 Developer ID Application identity，再从所选证书的 subject `OU` 读取 Team ID 并复核 SHA-1 fingerprint。它构建 ReleaseFast、调用 Native SDK 生成未签名 `.app`，以打包期 Native SDK compatibility seam 原位替换 SDK 临时图标、合并 Icon Composer metadata、stage 其余完整原生资源，再以 `--options runtime --timestamp` 执行唯一一次应用签名。验证必须覆盖 Bundle ID、产品版本、Renderer、Icon Composer resource digest、托盘资源、Developer ID leaf authority、Team ID、Apple anchor、hardened runtime 和可信时间戳。`Assets.car` 与 fallback ICNS 都是发布时生成并在结束后清理的 artifact，不提交到仓库；工具版本变化必须先复核输出与真实系统视觉，再扩展 allowlist。

签名验证通过后，入口把 `.app` 与指向 `/Applications` 的精确符号链接放入临时 staging root，使用系统 `hdiutil` 生成可写磁盘映像，并在当前 macOS 图形用户会话中通过 Finder 写入固定图标视图：`MetaWork.app` 位于左侧、`Applications` 位于右侧，使用固定窗口和图标尺寸并隐藏工具栏与状态栏。布局写入 `.DS_Store` 后，入口卸载临时映像并转换成最终 UDZO，再以同一 Developer ID Application identity 和可信时间戳签名 DMG。入口按显式 package selection 生成 `zig-out/package/metawork-<version>-macos-arm64.dmg`、`zig-out/package/metawork-<version>-macos-x64.dmg` 或两者，并在应用签名前确认主程序恰好为对应单一 Mach-O 架构；当前不生成 Universal 包。每份最终 DMG 都直接通过钥匙串 `metawork-notary` profile 提交 `notarytool`，并等待最多 2 小时。只有 typed terminal status 精确为 `Accepted` 才继续 staple/validate DMG、执行 Gatekeeper assessment、`hdiutil verify`，并只读挂载检查根目录恰好包含布局 `.DS_Store`、`MetaWork.app` 和精确 `/Applications` 符号链接，同时复核内含应用的 Developer ID 签名。全部通过后输出 SHA-256。

应用签名前，打包入口必须从主程序的 macOS deployment target 派生 `Info.plist` 的 `LSMinimumSystemVersion`，不得沿用 Native SDK packager 的独立默认值或另建手工版本常量。签名后的应用与最终 DMG 内的应用均必须复核这份声明与主程序一致。

应用签名后必须复核主程序所有 file-backed section 的地址、文件偏移、长度和内容与构建输出一致，并拒绝 load command 与 section 重叠的 Mach-O。签名验证或公证通过不能替代这项 executable integrity 检查；失败时不得继续生成或提交 DMG。最终 DMG 只读挂载时必须对内含主程序重复同一检查，只有它与原始构建输出一致才能报告发布验证成功。

入口先验证全部所选 canonical bundles，每轮构建替换当前 `.app`，并由 `hdiutil convert -ov` 写入对应最终 DMG。本流程不创建 preview 或 ZIP。`all` 中任一架构失败即使整个命令失败，已经完成签名、公证和验证的前序架构 DMG 仍是独立有效产物。等待超时不会取消 Apple 已接收的 submission，必须以原 submission ID 继续查询，不能盲目重传同一构建。

现有 development Bundle ID `com.metask.metawork.dev` 及其数据和 credential namespace 保持不变；DMG 是只读拖拽分发容器，不是带安装逻辑的 PKG，不执行自动替换或安装。打包入口显式开启 `automatic-update-check`；应用内版本提醒与浏览器下载遵循[Product 架构](product-architecture.md#28-版本提醒与下载交接)，不构成 DMG 安装事务。`.dev` identity 仍是当前产品 Bundle ID，不因产物改为 DMG 而自动升级成独立 production channel。

普通 `check`、`test`、Debug/Release build、Windows baseline 和 automation 不依赖 Apple Development、Developer ID 或 notary credential，也不访问真实 Keychain。

## Office Skill 与私有依赖

Office 能力由[产品需求](requirements.md#53-task)拥有，跨平台准备、执行和故障恢复只由 [Product Skill 合同](product-architecture.md#内置-office-skill)定义。主包携带压缩 Skill、固定入口与锁定输入，不携带 Python、Node 或文档库；Application 资源发布仍属于自有数据根，macOS 排他发布只经[已登记窄 seam](architecture.md#35-native-sdk)。

macOS 的固定 Python 来源为 Astral `python-build-standalone` 的标准 GIL `install_only` 发行包，Node 来源为官方 Darwin archive；arm64 与 x64 分别锁定输入和原生 wheel，不查询 latest、不安装 uv、不消费系统解释器或 Homebrew fallback。固定发行摘要在解包和执行前完整核验；发行归档接受检查须覆盖相对链接、执行位、可搬移性及系统基线，系统 tar 可保留受信任固定发行所需内部链接。这不降低用户附件的有界归档规则。解释器、原生扩展和其动态依赖的最低系统不能高于应用从 canonical Core 派生的基线。

固定 Shell 入口只使用基线系统已有的绝对工具路径；缺少工具明确失败，不静默切换来源或能力。包管理器保留既有用户网络配置，私有安装目标、哈希和禁用安装脚本等参数固定，不修改全局 PATH、用户配置或系统安装位置。Apple Development 的开发执行不能替代 Developer ID 应用/DMG 的运行验收；正式产物须实际验证私有解释器和 wheel 扩展可执行，不删除 quarantine、关闭校验或临时重签第三方 artifact 取得通过。两个架构、最低系统、当前系统与正式分发证据分别记录于[验证规范](validation.md#office-skill-与私有环境验证)；尚缺证据的目标不得报告正式分发通过。

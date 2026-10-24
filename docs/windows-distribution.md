# MetaWork Windows 分发

> 状态：Windows 主包、Office 资源与私有依赖、Authenticode 与发布验证的 source of truth

`npm run package:windows` 是 Windows 安装 artifact 的正式工程入口，默认选择 x64；`npm run package:windows -- arm64` 选择 ARM64。每次调用只输出所选架构的一个版本化安装器：

Windows development baseline 与平台证据见[验证规范](validation.md)；本文不定义 development bringup。

```text
zig-out/package/metawork-<version>-windows-x64.exe
zig-out/package/metawork-<version>-windows-arm64.exe
```

安装器按当前用户安装到 `%LOCALAPPDATA%\Programs\MetaWork`，不请求管理员权限；它注册开始菜单入口和卸载程序，并提供默认不勾选的桌面快捷方式。安装后运行的是 Native SDK package 中的完整目录，不能把其中的 `metawork.exe` 单独取出分发。

## 工具与执行

先满足仓库普通 Windows build 的全部前置条件，并安装 Inno Setup 6.7.3 或兼容的 7.x 版本：

```powershell
winget install --id JRSoftware.InnoSetup.7 -e -s winget -i
npm run package:windows
npm run package:windows -- arm64
```

Inno 编译器按显式环境变量、标准安装目录、`PATH` 和 Windows 卸载注册表顺序发现，因此支持安装到其他磁盘；仍无法定位时，可将 `METAWORK_INNO_SETUP_COMPILER` 指向绝对 `ISCC.exe` 路径。正在运行的普通 `zig-out/bin/metawork.exe` 不会阻塞 package build。

Inno Setup 只负责把 Native SDK runtime stage 安装和卸载为一个 Windows 应用，不成为应用 runtime owner，也不替代 Native SDK package。

安装器必须在替换 runtime stage 前处理仍在运行的已安装 MetaWork。`packaging/windows/metawork.iss` 固定启用 `CloseApplications=yes`，并以 `RestartApplications=no` 禁止安装完成后擅自恢复 Host；用户取消关闭时安装不得继续覆盖正在使用的文件。第一次部署具备单实例能力的版本时，旧 Host 尚未持有数据目录 lease，也不理解新的启动转交协议，因此“先退出旧 Host，再替换应用”本身就是 rollout 的正确性边界，不能依赖新版本在启动后补救跨代双写。

## 固定流程

同一个 `package:windows` 入口按以下顺序执行：

1. 在开始构建前解析参数并检查 Inno；signed mode 还必须先发现 Windows SDK SignTool、校验证书 thumbprint 和时间戳 URL，缺失时立即失败。
2. 构建 Renderer，再以所选 x64 或 ARM64 target 和隔离 prefix 生成 Windows `ReleaseFast` 主程序并检查 release automation isolation。
3. 调用 Native SDK 生成完整 runtime stage，验证版本、App ID、GUI subsystem、主程序与 WebView2 loader 的精确 PE machine、Renderer assets、应用图标与 canonical Windows 托盘图标；从已验证的 canonical AgentCore bundle 部署 rg 和许可证到 Host 同目录，并在编译安装器前再次核验 checksum。runtime asset 接受与解析边界由 [AgentCore ABI v1 合同](agentcore-abi-v1.md)定义。
4. signed mode 签署 MetaWork 主程序并立即验证，同时验证 WebView2 loader 的微软原厂签名；unsigned mode 完整跳过签名身份读取。
5. Inno Setup 将 runtime stage 编译为单 EXE；signed mode 由同一个 SignTool definition 签署卸载器模板和最终安装器。
6. signed mode 验证最终安装器；随后统一检查安装器 PE identity、精确文件名与非空内容，并输出最终文件 SHA-256。

编译安装器前，runtime stage 必须通过主包资源检查，不混入展开的 Office 资源树、Python、Node 或文档库。完整 Skill/helper/必要 XSD 以压缩内嵌资源随主包发布，解包前接受固定摘要、大小及路径检查；不以压缩规避内容边界。发布失败不阻止应用启动。最终安装器仍必须通过 [`build_support/main-package-size.json`](../build_support/main-package-size.json) 定义的真实安装包预算，不以单个 executable 或资源压缩量代替。

## 签名边界

普通 x64 或 ARM64 package 调用生成不读取签名身份的本地未签名安装器。正式签名构建必须显式要求 signing，并通过环境传入当前证书的精确 SHA-1 thumbprint；两个架构共用同一套 Authenticode、WebView2 原厂签名验证和 Inno SignTool 流程：

```powershell
$env:METAWORK_WINDOWS_SIGNING_CERTIFICATE_SHA1 = "<40 位证书指纹>"
npm run package:windows -- --signing required
npm run package:windows -- arm64 --signing required
```

签名入口只发现当前 Windows SDK 中版本最高的 x64 `signtool.exe`，不搜索 `PATH`，也不读取供应商附带的旧工具目录。非标准 SDK 位置可通过 `METAWORK_WINDOWS_SIGNTOOL` 显式指定绝对路径；RFC 3161 服务默认使用 `http://time.certum.pl`，需要切换供应商时通过 `METAWORK_WINDOWS_TIMESTAMP_URL` 显式替换。证书 thumbprint 和工具路径不是私钥；PIN、token、PFX 密码及云签名 credential 不得进入仓库、命令参数、日志或持久配置。

signed path 使用 `/sha1` 在默认的当前用户个人证书库中精确选择由 SimplySign CSP 暴露的证书，固定 `/fd SHA256 /tr <URL> /td SHA256`。Native runtime stage 完成结构校验后只签署 MetaWork-owned `metawork.exe`，不覆盖 Microsoft 已签名的 `WebView2Loader.dll`；后者保留原厂签名并通过相同 Authenticode policy 验证。上游 rg 保留 bundle 原始 bytes，由 manifest checksum 验证，不作为 MetaWork-owned 二进制重签。Inno Setup 使用同一 SignTool definition 生成签名卸载器并签署最终安装器。每个 MetaWork-owned 可执行文件签名后都必须运行 `signtool verify /pa /all /v`；任何签名、时间戳或验证失败都会终止 package，不允许退回未签名 artifact。最终 SHA-256 只在所有签名和验证完成后输出。

该入口只调用现有 Windows certificate provider，不安装、升级、登录或修改 SimplySign，不导入导出证书，也不改变 CSP/KSP、证书库或 PIN 设置。是否弹出 SimplySign 授权由现有 provider 和证书策略决定。

安装器生成不等于自动更新能力；更新协议、channel、回滚和旧版本迁移不在当前入口范围内。

工具能力参考 [Inno Setup 官方说明](https://jrsoftware.org/isinfo.php)、[ISCC 命令行](https://jrsoftware.org/ishelp/topic_compilercmdline.htm)和 [Microsoft SignTool](https://learn.microsoft.com/en-us/windows/win32/seccrypto/signtool)。

## Office Skill 与私有依赖

Office 能力与用户授权由[产品需求](requirements.md#53-task)拥有，准备与执行生命周期由 [Product Skill 合同](product-architecture.md#内置-office-skill)拥有。主包仅携带完整 Skill、固定准备/调用脚本及锁定输入，不携带解释器或第三方文档库，不运行组件 producer 或系统安装器。

Windows x64 的既有发行、库锁和环境身份保持；Windows ARM64 采用独立的官方 `pythonarm64` NuGet 与 Node Windows ARM64 ZIP 输入，不能借 x64 仿真或 wheel 代替原生接受。两目标均保持 Python/Node 独立准备。所有发行包在解包或执行前必须完整匹配主包输入的摘要。Python requirements 按目标固定全部直接/传递依赖和 wheel 哈希，拒绝源码编译；Node 使用独立最小 package-lock 的完整性身份并禁用安装脚本。具体版本、来源、摘要和依赖集合由唯一机器输入拥有，不在本文镜像。各目标运行及安装产物验收独立记录于[验证规范](validation.md#office-skill-与私有环境验证)，输入存在不表示 ARM64 已通过执行验收。

引导不得依赖尚未下载的解释器；使用公司策略允许且经过真实 AgentCore Shell 验证的既有系统能力，不绕过企业策略、不预建多套静默 fallback。已知发行包完整摘要通过后可使用成熟解包工具；这不降低用户附件 ZIP helper 的有界安全规则。镜像/代理/证书兼容必须实际验证，既有直接 URL 不被当作自动支持镜像，不输出认证配置或凭据。准备及调用不修改全局 PATH、文件关联或用户包管理器配置，不提权；每个环境由独立临时目录验证后原子发布，不能覆盖或修改正在使用的目录。

# MetaWork Windows 分发

> 状态：Windows 主包、Office 组件 producer、Authenticode 与发布验证的 source of truth

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

编译安装器前，runtime stage 必须通过主包资源检查，不得混入 Office Skill、Python、Node 或 Office 引擎等独立组件资源。最终安装器完成签名及身份检查后，还必须通过对应 target 的主包体积检查；超限或缺少有效基线均使 package 失败。基线安装器身份、摘要、实际字节和允许增量由 [`build_support/main-package-size.json`](../build_support/main-package-size.json) 唯一拥有，检查完整安装器，不以单个 executable 或源码目录大小代替。Office 组件与主包分别计量，不得通过把重依赖放进低压缩率或高压缩率资源来规避主包边界。

交互式安装验收还必须覆盖两条路径：拒绝关闭正在运行的旧 Host 时安装取消且旧 Host 保持运行；允许关闭时旧 Host 完全退出后才安装新文件，安装完成后不自动重启应用。

任一步失败都不会报告 package 成功，也不会从 signed mode 静默降级为 unsigned mode。

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

## 独立 Office 运行时构建

Office 重依赖由独立组件 producer 构建，不进入主程序 runtime stage。目前 producer 只接受 Windows x64 构建主机和 x64 组件；其可构建不表示应用已开放组件安装，也不表示 ARM64 或干净机器通过验收。

```powershell
node scripts/build-office-component.mjs --python <absolute-builder-python> --output <new-absolute-output.tar.gz>
```

构建解释器只属于 producer，不成为交付物对系统 Python 的依赖。唯一供应商输入为 [`office-runtime.windows-x64.sources.json`](../build_support/office-runtime.windows-x64.sources.json)，固定引擎、所带 Python、Node 和私有中文字体的来源与摘要；Python wheel 身份由 [`office-python.windows-x64.lock.json`](../build_support/office-python.windows-x64.lock.json) 固定并绑定现有依赖输入，JavaScript 创作库从现有 `package-lock.json` 取得完整闭包，以独立的 lock 和禁用安装脚本的 `npm ci` 构建。producer 不复制整个开发依赖树，不安装全局 Office 或注册全局字体。

供应商输入必须通过摘要与适用的 Authenticode 校验；MSI 只行政提取到新的 staging 目录，保留许可证和运行所需的 app-local Microsoft 库。组件入口拥有解释器和引擎进程树，组件内的私有字体由引擎加载。默认要求签署 MetaWork 自有入口并立即验证；显式 `--signing none` 仅产生开发组件，不能作为正式分发通过证据。签名身份与工具继续遵守上文的[签名边界](#签名边界)。

组件归档为 `tar.gz`，tar 使用 USTAR；当前 Windows producer 不生成链接或特殊成员，不包含字节码缓存、PDB 或安装器副本。归档根的 `office-runtime.json` 使用 schema 1，固定 `target`，以 `files` 列出相对 `path`、实际 `bytes` 和 `sha256`；`payloadBytes` 是清单自身之外所列文件的总字节。归档旁的机器结果记录完整压缩摘要、压缩量和含清单的实际展开量。构建完成前必须重新流式读取完整归档，检查实际成员与清单一致及 gzip CRC，不能只核对构建目录。容量与成员预算由 producer 检查拥有；安装器的受限解包验收仍需独立完成。

这些 producer 来源不授予客户端任意下载 authority。正式客户端须由主包固定其接受的组件发布身份、来源和完整归档摘要；组件内引擎或解释器安全更新因此需要同步发布主包信任信息。主包升级不自动下载用户尚未启用的 Office 组件。完整 Skill 工作流、安装事务、签名后位置与干净机器验收通过前，不得将开发归档登记为可安装的正式组件。

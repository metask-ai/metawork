# Windows 安装包

`npm run package:windows` 是 Windows 安装 artifact 的正式工程入口。它输出一个版本化安装器：

```text
zig-out/package/metawork-<version>-windows-x64-setup.exe
```

安装器按当前用户安装到 `%LOCALAPPDATA%\Programs\MetaWork`，不请求管理员权限；它注册开始菜单入口和卸载程序，并提供默认不勾选的桌面快捷方式。安装后运行的是 Native SDK package 中的完整目录，不能把其中的 `metawork.exe` 单独取出分发。

## 工具与执行

先满足仓库普通 Windows build 的全部前置条件，并安装 Inno Setup 6.7.3 或兼容的 7.x 版本：

```powershell
winget install --id JRSoftware.InnoSetup.7 -e -s winget -i
npm run package:windows
```

脚本依次执行隔离 prefix 的 Release build、Native SDK Windows package、runtime stage 校验和 Inno Setup 编译；正在运行的普通 `zig-out/bin/metawork.exe` 不会阻塞 package build。runtime gate 要求版本、App ID、x64 GUI subsystem、WebView2 loader、Renderer assets 与应用图标全部匹配；最终 gate 要求精确命名的单一非空 PE 安装器并输出 SHA-256。编译器按显式环境变量、标准安装目录、`PATH` 和 Windows 卸载注册表顺序发现，因此支持安装到其他磁盘；仍无法定位时，可将 `METAWORK_INNO_SETUP_COMPILER` 指向绝对 `ISCC.exe` 路径。

Inno Setup 只负责把 Native SDK runtime stage 安装和卸载为一个 Windows 应用，不成为应用 runtime owner，也不替代 Native SDK package。

## 签名边界

当前入口生成未签名安装器，因此只证明单 EXE 的构建与结构，不证明可信外部分发。正式对外发布还必须用公司 Authenticode 证书签署应用二进制、运行时 DLL、安装器和卸载器，使用 SHA-256 与 RFC 3161 时间戳，并对最终 artifact 执行 Windows Authenticode policy 验证。证书、私钥、时间戳服务和签名选择尚未配置前，普通 build 与 `package:windows` 不读取或猜测凭据，也不得宣称通过该 Gate。

安装器生成不等于自动更新能力；更新协议、channel、回滚和旧版本迁移不在当前入口范围内。

工具能力参考 [Inno Setup 官方说明](https://jrsoftware.org/isinfo.php)、[ISCC 命令行](https://jrsoftware.org/ishelp/topic_compilercmdline.htm)和 [Microsoft SignTool](https://learn.microsoft.com/en-us/windows/win32/seccrypto/signtool)。

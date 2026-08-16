# MetaWork macOS 开发与内部测试签名

MetaWork 的真实 Account 开发流程使用 Apple 签发、带稳定 `TeamIdentifier` 的 `Apple Development` Code Signing identity。它只解决同一台开发机上重新构建后的 macOS Keychain 身份稳定性，不是 `Developer ID`，也不用于向测试人员或用户分发应用。

内部跨机器测试包使用 Apple 签发的 `Developer ID Application` identity。开发和打包签名彼此独立：`npm run dev` 只接受项目显式选择的 Apple Development identity；`npm run package:macos` 只接受登录钥匙串中唯一有效的 Developer ID Application identity，不能在缺失或歧义时回退到开发证书、自签名或 ad-hoc 签名。

签名流程直接读取 `app.zon` 中现有的 Bundle ID 与 executable name；当前分别是 `com.metask.metawork.dev` 和 `metawork`。`app.zon` 是跨平台 development 产品 Bundle ID 唯一真源，Application 通过 `src/product_identity.zig` 消费同一个 Native SDK manifest module。Account 在所有平台使用同一 persistence 合同：`com.metask.metawork.dev.account` secure service 只保存 refresh token，`preferences.json` 只保存无 secret 的当前选择；旧开发命名空间不迁移、不 fallback。

自签名证书不是可接受的替代品。真实复验证明，即使自签名证书和 designated requirement 保持不变，签名报告仍是 `TeamIdentifier=not set`；Keychain partition 会继续绑定随构建变化的 CDHash，用户选择“始终允许”后，下一次构建仍可能再次弹出授权框。

## 一次性平台准备

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

## 项目一次性选择

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

## 开发入口

```bash
npm run dev
```

macOS `dev` 会读取 `app.zon` 的现有 identifier，确认本机已选择的 identity 仍然有效，再构建并为 Debug executable 写入 canonical designated requirement；验证阶段必须精确读回该 requirement，并由系统 requirement engine 独立复核 identifier、Apple anchor、Team 与所选 Apple Development certificate，最后启动 Native SDK development shell。

## 内部测试包

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

不提供 `--password` 时 `notarytool` 才会使用安全提示。profile 验证成功后执行：

```bash
npm run package:macos
```

打包流程从 `security find-identity` 精确筛选唯一 Developer ID Application identity，再从所选证书的 subject `OU` 读取 Team ID 并复核 SHA-1 fingerprint。它构建 ReleaseFast、调用 Native SDK 生成 `.app`，最后以 `--options runtime --timestamp` 重签外层 bundle。验证必须覆盖 Bundle ID、产品版本、Renderer 资源、Developer ID leaf authority、Team ID、Apple anchor、hardened runtime 和可信时间戳。

签名验证通过后，入口使用 `ditto --sequesterRsrc --keepParent` 创建临时提交 ZIP，只从钥匙串 `metawork-notary` profile 认证 `notarytool`，并等待最多 2 小时。只有 typed terminal status 精确为 `Accepted` 才继续 staple/validate 原 `.app` 和 Gatekeeper assessment；之后重新生成 `zig-out/package/MetaWork-<version>-macos-arm64.zip`、检查 ZIP 完整性并输出 SHA-256。入口启动时先删除精确命名的旧分发 ZIP，临时 notary ZIP 在成功后删除，所以失败时不会留下可误发的旧最终产物。等待超时不会取消 Apple 已接收的 submission；必须以原 submission ID 继续查询，不能盲目重传同一构建。

现有 development Bundle ID `com.metask.metawork.dev` 及其数据和 credential namespace 保持不变；该入口不生成安装器或更新器，也不将 `.dev` identity 宣称为正式 production channel。

普通 `check`、`test`、Debug/Release build、Windows baseline 和 automation 不依赖个人证书或 notary credential，也不访问真实 Keychain。

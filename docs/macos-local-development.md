# MetaWork macOS 本地开发签名

MetaWork 的真实 Account 开发流程使用 Apple 签发、带稳定 `TeamIdentifier` 的 `Apple Development` Code Signing identity。它只解决同一台开发机上重新构建后的 macOS Keychain 身份稳定性，不是 `Developer ID`，也不用于向测试人员或用户分发应用。

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
npm run setup:macos-signing
```

如果存在多个 Apple Development identity，命令会 fail closed。将 `security find-identity` 输出中的 40 位 fingerprint 显式传入：

```bash
npm run setup:macos-signing -- 0123456789ABCDEF0123456789ABCDEF01234567
```

setup 只做以下操作：

- 选择一个精确 fingerprint；
- 签名并验证安全临时探针；
- 从探针的 `codesign` 报告读取真实 `TeamIdentifier`，绝不从证书显示名称末尾的括号推断；
- 把 fingerprint、证书名称和 Team ID 写入被 Git 忽略且权限为 `0600` 的 `.metawork-local-signing.json`。

临时探针位于权限受限的系统临时目录，成功、失败或收到终止信号都会清理。macOS 如果询问 `/usr/bin/codesign` 使用 private key，完成一次授权即可。

清除项目的本机选择使用：

```bash
npm run setup:macos-signing:clear
```

该命令不会修改或删除钥匙串中的 Apple Development identity。

## 开发入口

```bash
npm run dev
npm run package:macos
```

macOS `dev` 会读取 `app.zon` 的现有 identifier，确认本机已选择的 identity 仍然有效，再构建并为 Debug executable 写入 canonical designated requirement；验证阶段必须精确读回该 requirement，并由系统 requirement engine 独立复核 identifier、Apple anchor、Team 与所选 Apple Development certificate，最后启动 Native SDK development shell。`package:macos` 使用同一 identity，为 Native SDK 生成的本地 `.app` 外层签入并验证同一 canonical requirement。

普通 `check`、`test`、Debug/Release build、Windows baseline 和 automation 不依赖个人证书，也不访问真实 Keychain。

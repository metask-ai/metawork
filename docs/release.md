# MetaWork 发布流程

## 从版本提交到正式产物

1. 更新 `app.zon` 中的产品版本及各包的版本镜像，在 `CHANGELOG.md` 写入该版本的发布说明。通过 PR 将 `chore: release` 提交合入 `main`。
2. 在合入的确切提交上推送 `v<major>.<minor>.<patch>` 标签。[Release workflow](../.github/workflows/release.yml) 核对标签属于 `main` 的历史、版本与 `app.zon` 一致，并从 CHANGELOG 对应版本段创建或更新 Release 草稿。
3. 草稿作业通过后，CI 从该标签为 Windows 和 macOS 的 x64、ARM64 分别运行打包脚本。Windows 验证未签名安装器，macOS 验证未签名的 `.app`。正式分发使用**同一标签的提交**和对应 target 的锁定 AgentCore bundle，在持有签名身份的机器上按[Windows 分发](windows-distribution.md)生成并验证签名安装器，按[macOS 分发](macos-distribution.md)签名、公证并验证 DMG。
4. 将四个正式产物上传到下载主机，逐一核对下载地址、平台和架构。产物就绪后，在同一次发布操作中公开 GitHub Release 并更新下面的客户端清单。GitHub Release 只刊载版本说明，安装包由下载主机分发。已发布版本的修正使用新的 patch 版本和标签。

## 更新 manifest

客户端从 [Update owner](../src/product/update.zig) 指定的 `https://metawork.metask-ai.com/manifest.json` 检查更新。生产清单在仓库外，由发布者通过 CloudBase 静态托管控制台或 `tcb` CLI 覆盖同一路径。推送标签只启动发布 workflow，清单需要单独上传。

清单的 `version` 与发布版本一致。为每个操作系统和架构填写相应产物的完整 HTTPS 地址，同时更新目录、文件名和查询参数。`release` 取版本号，`rev` 取上传日期（`yyyymmdd`）。下面是 0.2.13 的已发布格式示例。

```json
{
  "version": "0.2.13",
  "downloads": {
    "macos": {
      "arm64": "https://downloads.metask-ai.com/metawork/v0.2.13/metawork-0.2.13-macos-arm64.dmg?release=0.2.13&rev=20261116",
      "x64": "https://downloads.metask-ai.com/metawork/v0.2.13/metawork-0.2.13-macos-x64.dmg?release=0.2.13&rev=20261116"
    },
    "windows": {
      "x64": "https://downloads.metask-ai.com/metawork/v0.2.13/metawork-0.2.13-windows-x64.exe?release=0.2.13&rev=20261116",
      "arm64": "https://downloads.metask-ai.com/metawork/v0.2.13/metawork-0.2.13-windows-arm64.exe?release=0.2.13&rev=20261116"
    }
  }
}
```

产物目录为 `https://downloads.metask-ai.com/metawork/v<version>/`。客户端校验清单及官方目标地址的规则见 [Product 更新合同](product-architecture.md#28-版本提醒与下载交接)。上传后从客户端使用的公开地址读回清单，核对版本和四个下载地址。遇到缓存的旧清单时，按响应的 `Cache-Control` 等待后再核对；已记录的托管配置为 `public, max-age=300, s-maxage=600`。

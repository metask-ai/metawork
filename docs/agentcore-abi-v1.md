# MetaWork AgentCore ABI v1 合同

Metask AgentCore 是外部依赖，官方 bundle 的 header、typed SDK 和 manifest 定义其 API、ABI layout 与 ownership。本文只定义 MetaWork 的获取、锁定和接受规则；运行时集成见 [AgentCore 集成契约](agentcore-integration.md)，验证入口与平台证据见[验证规范](validation.md)。

## 1. 范围与机器真源

MetaWork 通过官方 `bindings/zig` package 静态链接 AgentCore ABI v1。各平台的完整 artifact identity 由 target lock 固定，精确 revision、table layout、toolchain、link inputs 和 payload checksum 由 lock、官方 SDK 与 verifier 校验：

- [Windows x86_64 MSVC lock](../build_support/agentcore-bundle.windows-x86_64.lock.json)
- [Windows arm64 MSVC lock](../build_support/agentcore-bundle.windows-aarch64.lock.json)
- [macOS arm64 lock](../build_support/agentcore-bundle.macos-aarch64.lock.json)
- [macOS x86_64 lock](../build_support/agentcore-bundle.macos-x86_64.lock.json)

Host、SDK 和 bundle 必须使用相同 architecture、OS 与 ABI；Windows 使用 MSVC 及对应的 Visual C++/Windows SDK 工具链。各 target 独立锁定和验收，不复用其他 target 的产物或通过结论。

### 1.1 官方发布来源与手动更新

正式发布清单位于 `https://downloads.metask-ai.com/agentcore/v<version>/manifest.json`。更新由用户明确发起并确定版本；开发环境准备沿用当前 lock。正式版本采用不带预发布或 build metadata 的 SemVer `major.minor.patch`，源码身份由独立的 `source.commit` 固定。

按清单 `targets` 条目的 `custom.target` 选择平台，文件路径相对该版本目录解析，压缩包必须匹配 `length` 与 `hashes.sha256`。解压后的 bundle manifest 必须与发布清单的版本、source commit、target 和 ABI 声明一致；下载清单不替代包内 manifest、repository lock 或 verifier。

升级在同一变更中收口所需 target 的 lock、必要的集成适配与[恢复验收](#3-调用与恢复验收)。ABI revision、required surface、symbol 或稳定外部格式的变化仍须用户显式批准。回退须整体回退 MetaWork 变更与对应产物，运行时不保留旧 ABI 分流或 fallback。

## 2. 安装与构建

`stage-agentcore-bundle.mjs` 是进入 `.agentcore/bundles/<target-id>` 的唯一入口；candidate 只用于 probe 和 stage。stager 校验 lock 并只复制 manifest whitelist；复制或 rename 失败须保留或恢复原 canonical bundle，中断残留由再次 stage 恢复，不承诺跨进程 crash transaction 或并发 build/stage。

正式 dev/check/test/build/package 先执行 staged preflight，Zig build 再校验实际输入；只消费 resolved target 的 staged bundle。manifest bytes 必须与 target lock 精确一致，schema、target、toolchain、build/link、ABI、required surface、唯一 discovery symbol、payload whitelist 与 checksum 必须通过现有验证。缺包、dirty source、未知 target、额外文件、symlink 或任一不匹配均明确失败，不以源码、archive 直链、`latest`、可变版本或其他 target 替代。

SDK 是 ABI types、typed protocol、decoder 和 module/link graph 的唯一来源，MetaWork 不复制或 patch 上游实现。发布包里的共享库作为锁定 payload 校验，不建立动态加载路径。开发构建和正式包均须部署 manifest 声明的 ripgrep 与许可证；resolver 仍归 AgentCore，Host 不改写全局环境或声称已强制锁定实际执行路径。真实 Glob/Grep 验收须不依赖外部 rg。

## 3. 调用与恢复验收

Agent 按官方 SDK 的 borrowed/owned memory、callback、status/result 和 release 合同消费依赖。Host 侧身份、并发与失败收口约束由[集成契约](agentcore-integration.md)定义；operation disposition 与产品终态映射以 [RunResult 与 StopReason](agentcore-integration.md#10-runresult-与-stopreason)为准。

升级必须保留既有产品历史与 checkpoint。使用上一版 Core 导出的非空原始 checkpoint，交给新版官方 restore，核对 Session identity、运行及 checkpoint 元数据，再实际执行一轮证明旧 Conversation 被消费。不能以空 Session 恢复替代；失败时保留原始 bytes 并明确报错，不解析、改写 checkpoint 或静默创建空 Conversation。

接受产物须验证官方 SDK 的 discovery/link/run、required table/entry/layout/reserved fields、callback identity 与 ownership，以及 operation-specific status/result 的拒绝路径；probe 前后产物内容保持不变。具体用例、命令和平台矩阵由[验证规范](validation.md)维护；没有对应 exact artifact 或跳过真实 AgentCore 调用不能报告通过。

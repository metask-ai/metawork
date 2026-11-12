# MetaWork

MetaWork 是一款面向本地工作区的桌面 Agent 应用。用户可以围绕 Workspace 和 Task 配置执行环境、运行 Agent、观察工具活动、处理必要决策并保留结果；产品不把终端模拟器或 IDE 作为主要交互模型。

## 当前状态

当前版本已经形成可运行的同进程桌面基线，覆盖 Account 登录与执行准备、Workspace/Task、Text/Skill Run、同步 permission、取消、Renderer reload、产品历史和正常重启后的 Conversation attachment 恢复。

当前仍是同进程 prototype，不宣称具备 AgentCore 进程隔离、crash recovery、跨进程 in-flight Run 恢复、strict Workspace security 或自动更新。精确产品范围见[产品需求](docs/requirements.md)，系统边界见[高层架构](docs/architecture.md)，平台证据和未验证能力见[验证规范](docs/validation.md)。

## 参与贡献

遇到使用问题或有功能建议，欢迎通过 GitHub Issues 反馈。具体说明见[贡献指南](CONTRIBUTING.md)。

## 快速开始

需要 Node.js 24+、Zig 0.16.0，以及按下文 [AgentCore bundle](#agentcore-bundle) 准备的对应平台依赖包。

桌面框架使用 [zogien/native](https://github.com/zogien/native) 发布的 [`@zogien/native-sdk`](https://www.npmjs.com/package/@zogien/native-sdk)，由依赖清单和 lockfile 固定版本。`npm ci` 同时安装 SDK，并通过其安装脚本下载、校验 SDK 固定的 ScriptC 工具链，无需另行全局安装 ScriptC；首次准备工具链需要访问 npm registry 和 GitHub Releases。依赖来源与接受规则见[高层架构](docs/architecture.md#35-native-sdk)。

### macOS

以下以 Apple Silicon 为例；Intel Mac 使用对应的 x86_64 macOS bundle。首次在当前 checkout 开发前需要选择 Apple Development identity：

```bash
npm ci
node scripts/setup-macos-local-signing.mjs setup
node scripts/stage-agentcore-bundle.mjs /absolute/path/to/aarch64-macos-bundle
npm run dev
```

本地签名、Developer ID、DMG 和公证要求见 [macOS 分发](docs/macos-distribution.md)。

### Windows

```powershell
npm ci
node scripts/stage-agentcore-bundle.mjs C:\absolute\path\to\x86_64-windows.win10...win11_dt-msvc
npm run dev
```

安装器与 Authenticode 要求见 [Windows 分发](docs/windows-distribution.md)。

### 本地开发 Office Skills

主包提供完整 Word、Excel 和 PowerPoint Skills。私有 Python、Node 与文档库由 Agent 按任务需要说明预计下载量并取得同意后，通过固定入口准备；普通启动不下载，也不修改全局解释器或 Task 长期环境。macOS 首次准备 Node 前需先准备固定私有 Python；Windows 两套环境独立准备。

```bash
npm run office:check
npm run dev
```

发行输入按 Windows x64/ARM64 与 macOS arm64/x64 锁定，具体原生验证及分发验收范围见 [Office 验证记录](docs/validation.md#office-skill-与私有环境验证)。版本、身份、准备和故障恢复合同见 [Product Skill](docs/product-architecture.md#内置-office-skill)。损坏目录不会自动修复或删除；按固定入口输出的精确路径指引确认所有使用者停止后，再由用户明确决定单目录恢复。当前能力限于读取、新建、针对性修改与结构检查，不提供重算、渲染或 PDF 导出。

创建普通 Task 后直接添加 Office 文件并输入处理要求，由 Agent 在普通 Run 中选择 `docx`、`xlsx` 或 `pptx`。首次发送会等待 Automatic Task 的初始 Skill 准备；也可在 Manual Workspace 中使用 Skill 选择器显式调用。附件保留本地原件，只向模型提供文件引用。ZIP 附件通过既有 Bash 调用归档 helper 查看目录并按需解压；本地开发启动自动提供 helper 位置和依赖说明，由 Agent 查找可用的 Python 并依据工具结果反馈失败，无需先配置解释器。需要固定开发解释器时，可选执行 `npm run archive:setup -- --python /absolute/path/to/python3.9-or-newer`，再通过 `npm run archive:check` 验证；它只需要 Python 标准库，无需安装 Office 依赖。安装包的归档资源交付尚未完成，解释器发现与调用合同见 [Product 附件合同](docs/product-architecture.md#26-文件-attachment-staging)，来源 authority 见 [Product 架构](docs/product-architecture.md#24-skill-authority-与本地资产)，验证边界见 [验证规范](docs/validation.md#标准入口)。

## 工程入口

`package.json` 提供以下正式入口：

```bash
npm run dev
npm run check
npm test
npm run format
npm run format:check
npm run build:debug
npm run build:release
npm run package:macos
npm run package:windows
```

平台打包入口只在对应平台运行。一次性准备、平台验收 harness 和 probe 直接使用 `node scripts/<name>.mjs`；验证范围和命令选择见[验证规范](docs/validation.md)。

`npm run dev` 首次构建并启动 Host 后，React、TypeScript 和 CSS 界面修改会通过 Vite 热更新。修改 Zig、Bridge 合同或构建配置后需退出应用并重新运行；开发入口的验证与清理规则见[标准入口](docs/validation.md#标准入口)。

## AgentCore bundle

按[官方发布来源与手动更新流程](docs/agentcore-abi-v1.md#11-官方发布来源与手动更新)下载、校验并解压与当前 target lock 匹配的包，将包含包内 `manifest.json` 的 bundle 根目录传给上述 `stage-agentcore-bundle.mjs` 命令。

需要验证尚未 stage 的 candidate 时运行：

```bash
AGENTCORE_BUNDLE_ROOT=/absolute/path/to/bundle node scripts/run-agentcore-restore-probe.mjs
```

产品集成规则见 [AgentCore 集成契约](docs/agentcore-integration.md)。

## 文档入口

### 产品与界面

- [产品需求](docs/requirements.md)：产品对象、行为与范围
- [UI 设计规范](docs/ui-design.md)：信息架构、交互、视觉与 capability gate

### 系统与 owner

- [高层架构](docs/architecture.md)：技术选型、系统职责与安全边界
- [Product 架构](docs/product-architecture.md)：Product owner、事务、并发与恢复
- [Account 架构](docs/account-architecture.md)：Account 状态、事务、Metask 合同与持久化
- [工程结构与所有权](docs/project-structure.md)：稳定 module root、目录 owner 与依赖方向
- [Completion 架构](docs/completion-architecture.md)：Agent-owned 无 Tool Completion
- [Storage 架构](docs/storage-architecture.md)：SQL contract、backend、limits 与 lifecycle

### 集成与验证

- [Renderer Bridge 合同](docs/renderer-bridge-contract.md)：command、event、Snapshot 与 transport
- [AgentCore 集成契约](docs/agentcore-integration.md)：Session、工具、Skill、Permission 与生命周期
- [AgentCore ABI v1 合同](docs/agentcore-abi-v1.md)：bundle 接受、ABI surface 与 Host 安全消费
- [验证规范](docs/validation.md)：测试归属、持续回归、平台证据与能力缺口

### 平台与执行规则

- [macOS 分发](docs/macos-distribution.md)：本地签名、Developer ID、DMG 与公证
- [Windows 分发](docs/windows-distribution.md)：Inno Setup、Authenticode 与安装验证
- [Agent 工作约束](AGENTS.md)：仓库内执行规则和不可绕过的 Gate

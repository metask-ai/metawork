# MetaWork

MetaWork 是一款面向本地工作区的桌面 Agent Workbench。用户可以围绕 Workspace 和 Task 配置执行环境、运行 Agent、观察工具活动、处理必要决策并保留结果；产品不把终端模拟器或 IDE 作为主要交互模型。

## 当前状态

当前版本已经形成可运行的同进程桌面基线，覆盖 Account 登录与执行准备、Workspace/Task、Text/Skill Run、同步 permission、取消、Renderer reload、产品历史和正常重启后的 Conversation attachment 恢复。正式构建只消费已安装到 `.agentcore/bundles/<target-id>` 的 target-specific Metask AgentCore bundle。

当前仍是同进程 prototype，不宣称具备 AgentCore 进程隔离、crash recovery、跨进程 in-flight Run 恢复、strict Workspace security 或自动更新。精确产品范围见[产品需求](docs/requirements.md)，系统边界见[高层架构](docs/architecture.md)，平台证据和未验证能力见[验证规范](docs/validation.md)。

## 快速开始

需要 Node.js 24+、Zig 0.16.0，以及与仓库 lock 精确匹配的 target-specific AgentCore bundle。

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
node scripts/stage-agentcore-bundle.mjs C:\absolute\path\to\x86_64-windows.win10...win11_dt-gnu
npm run dev
```

安装器与 Authenticode 要求见 [Windows 分发](docs/windows-distribution.md)。

### 本地开发 Office Skills

`npm run dev` 自动加载仓库中的 Word、Excel 和 PowerPoint Skills。处理文件前，准备 Python 3.12、LibreOffice 和 Poppler，并显式选择其可执行文件：

```bash
npm run office:setup -- --python /absolute/path/to/python3.12 --soffice /absolute/path/to/soffice --pdftoppm /absolute/path/to/pdftoppm
npm run office:check
npm run dev
```

setup 将 Python 依赖安装在当前 checkout 的 `.zig-cache` 内；Node 依赖由 `npm ci` 安装。需要 Pandoc 提取 Word 内容时另加 `--pandoc /absolute/path/to/pandoc`；未安装时可用解包 XML 的读取流程。

在项目目录的 Manual Workspace 中创建 Task，通过 Skill 选择器调用 `docx`、`xlsx` 或 `pptx`，处理该 Workspace 内的文件。此入口尚未放开 Office/ZIP 附件上传、Automatic Workspace Skill 或安装包内置运行环境。来源 authority 见 [Product 架构](docs/product-architecture.md#24-skill-authority-与本地资产)，验证边界见 [验证规范](docs/validation.md#标准入口)。

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

## AgentCore bundle

`stage-agentcore-bundle.mjs` 是 candidate bundle 进入仓库 canonical target store 的唯一入口。正式 build、test 和 package 不读取 AgentCore 源码树，也不从环境变量寻找替代实现。

需要验证尚未 stage 的 candidate 时运行：

```bash
AGENTCORE_BUNDLE_ROOT=/absolute/path/to/bundle node scripts/run-agentcore-restore-probe.mjs
```

bundle 与 ABI 接受规则见 [AgentCore ABI v1 合同](docs/agentcore-abi-v1.md)，产品集成规则见 [AgentCore 集成契约](docs/agentcore-integration.md)。

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

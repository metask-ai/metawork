# Office Skill 跨平台适配最终方案

> 状态：方案定稿，实施中。2026-10-24。本文不是 decision record，也不替代领域真源；方案定稿不表示产品能力已经开放、实现已经验收或生效合同已经变更。

> 本轮范围调整（2026-10-24 用户后续指令）：停止分发验收，使用 `npm run dev` 开发版验证 Office 功能。下文正式包、签名、公证与最低系统分发矩阵保留为后续分发职责，不作为本轮开发版功能验收的前置条件；现有分发 Gate 不变。其他平台缺少原生机器或 CI 的功能验收缺口继续明确保留。

实施采用现有 AgentCore Skill、Shell/权限与成果交付链路，补齐 macOS 和 Windows arm64 的固定私有运行时，以及 macOS 资源发布。macOS Python 采用锁定的 standalone 发行包，Windows Python 沿用官方 NuGet 路线；Node 采用官方对应目标发行包。两平台共用身份构造与文档脚本。macOS 首次准备 Node 前先准备 Python，以完成排他原子发布；发布成功必须通过最终路径的新进程检查。

按 P0–P5 顺序交付：固定输入验证 → 目标锁与确定性资源 → 准备/执行入口 → 三格式与真实 Core → 桌面与分发 → macOS Intel、Windows arm64、Windows x64 回归及文档收口。先完成本机 macOS arm64；每目标分别报告功能验收和正式分发验收。

## 1. 目标、范围与完成口径

将现有 DOCX、XLSX、PPTX 内置 Skill 的私有环境准备扩展到 macOS 和 Windows arm64，保留普通 Task、AgentCore Skill、既有 Shell/权限和 `DeliverFile` 路径。应用主包继续只携带完整 Skill、必要脚本、OOXML schema 和锁定输入；私有解释器与文档库按需准备。

实现按 `windows-x86_64`、`windows-aarch64`、`macos-aarch64`、`macos-x86_64` 四个精确目标组织。各目标使用与当前应用目标兼容的系统基线；不能为 Office 适配静默提高整个应用的最低系统版本。先完成 macOS arm64 闭环，再分别完成 macOS Intel 和 Windows arm64 的原生验收。Windows x64 保持现有身份与行为并运行受影响回归；一个目标通过不代表其他目标通过，交叉编译不代表执行验收。

交付分为每目标的“功能验收”和“正式分发验收”：前者证明私有环境、文档处理、真实 Core 与桌面链路；后者追加对应系统基线、平台安装 artifact 和执行策略证据，分别遵守 macOS 与 Windows 分发合同。功能通过可以形成明确范围的阶段交付，不被缺少签名身份或其他目标机器改写成代码不可用；这些缺口仍阻止对应的正式分发结论。三个新增目标的两类验收及 Windows x64 受影响回归均完成前，不得报告本方案整体完成。

本轮包括：资源发布、固定运行时输入、准备与调用脚本、Skill 指引、真实 Core 与桌面链路、macOS 分发验证、Windows 回归和对应真源更新。

用户确认的范围是补齐 macOS arm64/x64 和 Windows arm64，并保留 Windows x64 现有行为。Windows x64 的固定发行版本、库锁、环境 ID/路径、既有 CLI、对话授权和 Python/Node 独立准备顺序均保持；不能给它增加 macOS 的 Python 前置条件、额外下载或自动迁移。共享代码只做新增目标所需的调整，并由原有行为回归证明兼容；独立的 Windows x64 问题另行报告，不借适配扩大整改范围。

能力继续限于现有读取、新建、针对性修改与交付检查。不新增公式重算、接受修订、渲染、缩略图、PDF 导出、文档预览、旧二进制格式、宏执行或加密文档能力。不增加 Host Tool、Bridge command、Snapshot 字段、安装卡片、Product 环境管理对象、环境选择器或后台更新/修复/回收状态机。不引入全局安装或系统解释器 fallback。

## 2. 真源与已确认事实

实施前重新核对工作树及相关章节；下表是本方案采用的职责路由。

| 合同                                              | 真源                                                                            |
| ------------------------------------------------- | ------------------------------------------------------------------------------- |
| Office 产品能力、支持范围与对话授权               | [产品需求 §5.3](../requirements.md#53-task)                                     |
| Skill 来源、环境身份、准备/执行/恢复生命周期      | [Product 架构：内置 Office Skill](../product-architecture.md#内置-office-skill) |
| Application 与 Native SDK、公开 OS API 的允许边界 | [高层架构 §3.5](../architecture.md#35-native-sdk)                               |
| macOS 外部发行来源、签名与分发接受规则            | [macOS 分发](../macos-distribution.md)                                          |
| Windows 发行来源与已有平台承诺                    | [Windows 分发：Office](../windows-distribution.md#office-skill-与私有依赖)      |
| 验证入口、平台证据与剩余缺口                      | [验证规范：Office](../validation.md#office-skill-与私有环境验证)                |

本机在 MetaWork `abafc54daf3a216bce4e1fb88cb10c5472301ee1`、macOS arm64、Zig 0.16.0 上确认：

- Application 仅在 Windows 发布内置 Office 来源，macOS 得到空来源。
- 准备/调用入口是 Windows batch，解释器输入为 Windows x64；不能直接执行 macOS 产品纵向。
- Windows arm64 已有应用产品目标、打包入口和 canonical AgentCore target lock；Office 资源按 Windows OS 发布，但其准备入口仅接受 AMD64，不能据 Skill 可发现推导出 ARM64 私有环境可用。
- 有界归档 helper 的 13 项行为测试通过。
- Office 资源发布单测失败于 `renamePreserve`；当前 Zig 的 Darwin 实现使用硬链接，目录发布返回 `EPERM`。
- 资源一致性 suite 为 2 通过、1 失败。包内 211 个文件内容与输入一致，本机对原 tar 重压缩仅 gzip OS 字节不同；现有字节级校验仍是失败结果。
- 隔离探针验证 `renameatx_np(RENAME_EXCL)` 的并发唯一成功，以及已有空目录、普通文件、符号链接保留。
- 名为 macOS 的桌面脚本仍将非 Windows 的 Office 名单设为空，Office 专用模式明确要求 Windows，且存在 Windows 路径假设。

本机线索见[测试报告](../../.zig-cache/office-macos-qualification/report.json)和[排他改名探针](../../.zig-cache/office-macos-qualification/exclusive-rename-probe.json)。这些是可删除缓存，不是持续回归输入或新的长期证据真源；实施中要把有效失败模式转入正式测试，并在验证真源记录实际平台结论。

## 3. 确定的技术方案

### 3.1 固定私有发行包

Windows x64 保留现有 CPython NuGet 和官方 Node ZIP；Windows arm64 使用官方 `pythonarm64` NuGet 与 Node Windows arm64 ZIP，独立锁定全部输入。macOS Python 采用 Astral `python-build-standalone` 的标准 GIL、`install_only` 类固定发行 artifact；Node 采用官方 Darwin 压缩包，分别锁定 arm64 与 x64。运行时不查询 latest、不使用可变下载入口，也不安装 uv 或另一个通用环境管理器。

P0 实测修正：现有 Node 24 的 Darwin 二进制最低系统为 macOS 13.5，高于应用的 13.0 基线，不接纳该候选。macOS 改用具备现有 `registerHooks` API、二进制最低系统为 11.0 的固定 Node 22 发行包；具体版本与摘要由机器输入拥有。Windows 两目标继续采用原定 Node 24 路线。此调整不提高应用基线，也不建立运行时版本 fallback。

Python 优先匹配当前 Windows 的版本与依赖版本集合；精确发行日期、文件名、摘要、大小、最低系统版本和 wheel 集合必须在 P0 实际取得并验证，才能写入 canonical 输入。若目标版本没有合适的 standalone artifact 或 wheel，P0 明确失败并提出具体版本调整；不得无声更换版本、源码编译或顺带升级 Windows。

选择依据：standalone 项目提供独立发行和两种 macOS 目标；Python.org 的标准 macOS installer 采用固定系统安装位置，不满足本方案的私有目录要求。Node 当前锁定版本有官方 Darwin 双架构发行。来源说明不构成 artifact 已验收证明。

### 3.2 macOS 的准备顺序

macOS 上 Python 环境可独立首次准备；Node 环境首次准备要求当前目标的固定私有 Python 已就绪。Python 通过标准库 `ctypes` 调用 Darwin 排他改名 API，作为 Node 发布的固定执行方法。Node 自身负责其锁定库的安装和验证。

`prepare.sh node` 不隐式下载 Python：若 Node 正式目录已经存在，先使用该 Node 自检并离线复用；若需要新建而 Python 未准备，则明确返回前置条件缺失，要求先准备 Python。Python 损坏时保留目录并报告不可用，不能改用其他 Python。

Agent 在首次准备前解释所需环境和缺失部分的预计下载量；需要两套时说明合计，并取得同意后依次调用。XLSX 仅需 Python 时不下载 Node。准备完成后 `run.sh node` 不依赖 Python 的存在，Node 环境身份也不绑定用于准备的 Python 身份；文档读取/校验需要 Python 时另按实际依赖反馈。

下载同意不替代既有 Shell/文件权限。共享依赖根通常在 Task Workspace 之外，默认权限下若需要既有审批则照常请求，拒绝时保留明确失败；不为 Office 自动加写权限、不换到工作区或系统包路径绕过拒绝。`full_access` 仍不增加额外产品安装 Gate。

这项顺序减少新原生 helper 的交付、签名及维护成本，但使 macOS Node 首次准备具有额外前置条件。它是显式的平台准备合同，Windows 继续保持两套环境独立准备。首版不并行交付“Python 协调”和“原生 helper”两条 active path。

### 3.3 目录与隔离

Office 依赖采用独立、固定的用户级 namespace，延续当前 Windows 的 `MetaWork/OfficeDependencies` 语义：

| 目标    | 依赖根目录                                                      |
| ------- | --------------------------------------------------------------- |
| Windows | `%LOCALAPPDATA%\MetaWork\OfficeDependencies`，保持现状          |
| macOS   | `$HOME/Library/Application Support/MetaWork/OfficeDependencies` |

这是 Office 的共享依赖目录，不从 Product 数据目录名称或 AgentCore 临时 Skill 路径推导。开发与其他应用构建有意复用同一用户下相同身份的依赖，以避免为相同内容重复准备；automation/qualification 必须通过独立 HOME 或 LOCALAPPDATA 隔离。这里的“不原地修改”是准备器和执行器的行为合同，不是文件系统只读或对同用户进程的安全隔离。该共享不包含 Account、credential、Task 原件或 Product metadata。

namespace 只由 Office 机器输入定义一次，构建器派生两平台脚本所需常量。HOME/LOCALAPPDATA 必须存在并为有效绝对目录；资源与依赖根 canonicalize 后使用。不读取工作区中的同名配置，不增加运行时根选择开关。正式环境的最终路径项若为符号链接、非目录或其他异常对象，必须拒绝，不沿链接验证或覆盖。

P0 同时核验真实 AgentCore Shell 的 HOME 与 Application canonical user home 一致，且不随 Task Workspace 或 Skill 临时物化目录变化；同一用户的两个 Task 必须解析出相同依赖根。若 Core 改写了这一环境事实，先明确报告该集成缺口，再调整经 owner 审查的有界执行输入；不得依靠开发 Shell 的 HOME 假设发布，也不修改 Task HOME 来拼出期望路径。

App 发布的 Skill 资源仍放在其现有 `data_root/builtin-office/<资源摘要>`；资源根和依赖根拥有不同生命周期。普通启动只做既有资源发布/核验，不准备或全量扫描解释器环境。

### 3.4 Windows arm64 的适配边界

Windows arm64 是独立 Office 执行目标，复用 Windows batch、NuGet/ZIP 解包、同卷排他发布和两种语言独立准备的流程，不引入 macOS 的 Python→Node 准备依赖。

P0 必须实际取得对应 CPython/Node 发行包，验证 pip、VC runtime 依赖、`lxml`/Pillow 等原生 wheel 与完整哈希集合；上游存在 ARM64 下载项不等于当前版本组合已经接受。不能沿用 x64 wheel 哈希、只删除 AMD64 guard、借 x64 仿真完成测试或静默回退 x64 解释器。

架构选择需要区分原生 ARM64 与 x64 仿真环境，并验证实际解释器的 PE 架构、版本与目标一致；增加目标输入与测试，不复制一套 ARM64 batch 实现。P3–P5 使用 `aarch64-windows-msvc` canonical Core 和真实 Windows ARM64 机器完成三格式、Shell、桌面、离线复用与安装 artifact 验收。缺少该机器时明确保留这一目标的未验收状态。

## 4. 唯一机器输入、锁与身份

将 [office-environment.json](../../build_support/office-environment.json) 一次性调整为明确 schema 的目标表；删除对旧顶层形状的读取，不保留两个 resolver。Office 目标键采用本文列出的四个名称；Core probe 使用对应 canonical target lock 的 `target.id`。按 OS/架构匹配二者，不能把 `windows-aarch64` 与 `aarch64-windows-msvc` 等不同 identifier 当作同一字符串，也不重定义 Core 的 target identity。

每个目标记录：固定 Python/Node 发行包、平台/架构、预期解包布局、解释器相对入口、Python requirements 输入、下载总量及其锁摘要。Node package-lock 保持单份；Python 按目标锁定完整直接/传递依赖的 wheel 哈希，拒绝 sdist。共用纯 Python wheel 时允许复用字节，但不让其他目标的原生 wheel 进入接受集合。

现有 Windows x64 requirements 的字节和发行字段保持不变；文件组织改变不改变其语义。新增目标的锁从同一版本选择流程生成，不手工维护多份需要同步的依赖版本说明。发行 URL、文件名、摘要、大小、wheel tag 等机器事实只存在于输入/锁，规范不镜像其当前值。

身份规则：

- 两平台共用现有 SHA-256 身份构造方法：选定语言的发行记录 JSON 字节 + 对应依赖锁字节 + 布局标记。目标表只负责选择输入，不新增第二套 macOS 身份算法、hash registry 或 resolver。
- Windows x64 继续逐字节使用现有发行记录、字段序列化顺序、requirements/package-lock 字节和 `layout-1`。P1 固定迁移前向量，变更后必须完全一致。目标表的外层 schema、其他目标、路径重命名不进入该材料。
- 新增目标的发行记录显式包含精确目标和必要的安装布局，使用同一构造方法；不同 OS/架构不能碰撞。布局变化推进其布局标记；下载说明、业务脚本、Skill 文案和用户目录不进入身份。
- 不给 Windows 建立“旧目录查找再 fallback 到新目录”的迁移路径；同一环境只有一个计算结果、一个正式目录。
- 每个目标/语言分别测量首次下载 payload，关联锁摘要；Node 在 macOS 的新建前置条件单独展示缺失 Python 的下载量，不把同一 payload 重复计数。
- Shell 根据固定平台/架构映射选择发行记录，再由实际私有解释器核对平台、架构和版本；三个 Skill 必须选择一致，不能分别从 PATH 猜测。未知目标、记录缺失或实际入口不匹配明确失败。不自动切换架构或触发 Rosetta 安装；Rosetta 不属于本轮支持承诺，也不额外引入一条未经需求要求的“检测到翻译即拒绝”产品政策。原生 arm64/x64 的证据不能证明翻译运行已验收。

生成的 `environment.cmd`、macOS `.sh` 常量及提供给 Python/Node 的 JSON 均从上述输入派生，无手写第二份 URL、ID、目录名或版本表。它们是构建输出，不是额外 authority。

## 5. macOS 引导、安装、发布与执行

### 5.1 固定 Shell 引导

新增 `environment/prepare.sh`、`environment/run.sh`。Skill 使用 `/bin/sh "${CLAUDE_SKILL_DIR}/environment/prepare.sh" python|node` 和对应 run 入口；不要求资源文件有可执行位。Shell 代码按 POSIX sh 编写，不依赖用户登录 shell、Homebrew 或 bash 新版本。

引导只使用最低支持系统上实测存在的 `/bin/sh`、`/usr/bin/curl`、`/usr/bin/shasum`、`/usr/bin/tar`、`/usr/bin/mktemp` 及必要基础工具，采用固定绝对入口。任何 required tool 缺失明确失败，不建立替代工具探测链。固定 JSON 在构建期派生为安全引用的常量，引导不依赖尚未下载的 Python/Node 解析配置，不 eval 下载内容。

`prepare.sh` 只接受一个固定语言目标；`run.sh` 接受语言、脚本路径及该脚本的参数。URL、包列表、版本、安装根和最终目录不成为 Agent 可选择的准备选项。路径、脚本名和每个参数分别引用，中文、空格、单引号等不得被二次解释为 Shell 代码。

### 5.2 暂存与安装

在依赖根内部以限制权限的新建随机目录暂存，保证与最终目录同卷。下载使用固定 HTTPS 来源、重定向协议约束、连接期限、低速检测和总期限；保留既有 30 秒连接、90 秒低速窗口、1,800 秒下载期限及 600 秒包安装期限的意图。具体参数需由真实 curl 和 subprocess 路径验证，不能只扩大测试进程 timeout 而生产命令仍提前退出。

准备调用的测试/工具外层等待预算须覆盖下载、安装和发布后检查的完整预算，并保留有界收尾时间。当前 qualification 中的 900 秒/360 秒外层 timeout 不能覆盖生产允许的完整准备过程，适配时必须按阶段预算收口；不直接复制到 macOS，也不无限延长文档执行命令。前台工具等待较短时沿既有后台/输出机制观察，不把工具等待结束误报为安装失败或完成。

发行包完整摘要通过后再解包和执行。P0 接受固定发行包时检查其成员布局、相对链接及外部依赖；运行时使用成熟系统 tar，保留解释器所需执行位和合法内部链接。不能把解释器发行包套入拒绝所有链接的用户 Office/ZIP 附件流程；用户文件仍走既有有界 helper，规则不变。

Python 不使用可搬移 venv：解释器和 `packages/` 同属一个完整环境，使用私有 Python `-I -B -m pip` 安装带哈希的固定 wheel，目标、安装行为与缓存位置明确固定。发行包必须已经提供运行准备器所需的 pip、ssl、ctypes 等能力；缺失时拒绝该 artifact，不临时下载 get-pip 或借用系统模块。Node 使用私有 `node` 直接运行其内附 npm CLI；Darwin 的 npm 相对布局从目标输入取得，不沿用 Windows 的 exe 布局。`npm ci` 继续禁用安装脚本、audit、fund 和全局目标，临时缓存留在本次 stage。

pip/npm 沿用用户网络、代理、镜像和证书机制，关键 CLI 参数固定私有安装目标；不写用户配置，不输出认证配置或凭据。清除既有 `NODE_OPTIONS`、`NODE_PATH` 注入；Python 的隔离参数继续隔离用户 Python 搜索路径。私有依赖不构成执行沙箱。

### 5.3 排他发布与故障

两处发布分别保持现有 owner：

| 发布对象               | 实现位置与边界                                                                           |
| ---------------------- | ---------------------------------------------------------------------------------------- |
| 主包 Office Skill 资源 | Application 调用一个已登记的 macOS 窄能力，仅处理本次自有资源 root 内的 stage 与内容目标 |
| Python/Node 私有环境   | Agent 经固定准备脚本执行，Python 标准库调用 Darwin 排他改名；不新增 Host 产品协议        |

macOS 采用 `renameatx_np(RENAME_EXCL)` 的同卷排他发布。Host 侧先审计 canonical Native SDK public API；若没有语义等价能力，按高层架构登记 Application-owned 的 `office_resource_publish.macos` seam，明确调用者、同步启动线程、目录所有权、errno、无悬挂资源及替换条件。不得修改 node_modules、升级成通用 OS facade 或弱化现有 allowlist。若 guard 不允许该 seam，在获得相应政策变化前该阶段明确阻塞。

环境侧只接受准备器计算出的当前根、随机 stage 和精确最终身份；不暴露通用任意路径改名命令。首次 Python 发布可由暂存 Python 执行；Node 发布由已经验证的正式 Python 执行。模块仅封装这一具体操作和错误映射，不建立通用 FFI/安装框架。

依赖环境按以下步骤发布；资源发布共用排他改名和真实赢家核验原则，按资源内容检查，不启动解释器：

1. 正式目录已存在时，先检查对象类型，再从该目录启动其自己的解释器验证当前目标及必要版本/import；成功复用，失败保留原状并打印精确人工恢复指引。不能用暂存 Node 的版本检查代替赢家 Node 的执行检查。
2. 不存在时只修改自己的 stage，安装并验证全部 required 输入。
3. 排他改名成功后，从最终路径启动一个新解释器进程检查可执行性、原生库和必要 import，再报告完成。stage 中已加载的模块、进程或 DLL 不能证明改名后的目录可用。新检查失败时保留已经发布的精确目录并报告不可用，不删除正式目录“回滚”。
4. `EEXIST` 表示竞争：重新验证确切赢家，成功才复用；损坏、空目录、符号链接或非目录不得被当作有效赢家。
5. 不支持排他语义、跨卷或永久错误明确失败，不回退到覆盖式 rename、copy、`mv -n` 或预创建最终目录再逐步填充。
6. 仅清理本次未发布 stage。取消/超时时先停止并确认本次子进程静止，再清理；无法确认或强杀残留时保留 stage，不能声称完成、复用或扫描删除其他暂存目录。
7. 共享冲突只允许有界重试；不自动隔离、重命名、修复、删除任何正式目录。人工恢复继续要求停止所有使用者、退出应用并确认无人使用，再由用户明确选择精确单目录清理。

这些步骤不引入持久化安装状态：最终目录不存在时只有本次 stage；最终目录存在时只有通过自身解释器检查才能复用。若进程恰好在改名后、成功返回前退出，下一次 prepare 验证该最终目录后复用，不重复发布或依赖上次的成功记录。

### 5.4 薄执行入口

`run.sh` 先精确选择目标、定位正式目录，进行与现有执行职责一致的有界检查，然后执行固定私有解释器；缺失或损坏只失败，不下载。Python 保留 `-I -B` 和本次调用路径设置；Node 保留固定入口包解析及本次进程的环境约束。参数和退出状态原样传递，不激活 venv、不改变 Task 长期 PATH、不创建健康数据库。

`finish.py`、`finish.cjs` 的平台无关安装/检查逻辑共用，解释器路径、npm 路径、发布方式按精确目标收窄。`run.py`、`run.cjs`、`read.py`、`document_text.py` 及 Office XML helpers 原位复用；仅在实际平台差异需要时修改。不复制成三套格式、两套平台各自演进的业务脚本。

## 6. 资源构建与 Skill 接入

保持单一确定性资源 archive，携带三种 Skill、共用 helper 和受支持目标所需的小型输入/脚本；不建立按平台可变下载的 Skill 来源或组件 catalog。现有 8 MiB 解压、成员数、单文件、路径等 guard 原样有效；超限必须减少输入或明确提出政策变更，不能调整限制掩盖超限。

构建器明确规范 USTAR 排序/元数据、`.cmd` 的 CRLF、`.sh` 的 LF、gzip mtime 和 OS 字段，并固定用于 canonical archive 的 Node/zlib 工具链。同一输入必须在 Windows/macOS 产出相同字节。仅把 gzip OS 字节规范化不足以证明所有压缩器版本兼容；受支持构建环境必须真实比较完整输出。这个约束只属于资源生成与一致性验证，不增加用户准备 Office 时的解释器依赖，也不建立自动下载构建工具链的机制。`--check` 继续逐字节比较 canonical 产物，工具链不匹配应有明确诊断，不能改为只看解压内容或忽略失败。

三种 Skill 共用一套平台准备说明，从唯一输入/生成过程取得差异，避免复制维护不同授权规则。指引明确：支持目标、对应绝对入口、macOS Python→Node 准备顺序、预计网络量、环境缺失/损坏处理，以及未执行的检查。保留 `checked_copy`、原件不覆盖、工作区输出和真实 `DeliverFile` 工具调用要求；收口描述中超出现有合同的“calculate/convert”等能力暗示。

P4 的 candidate 构建必须接通待验目标的真实 Application 来源，才能验证 catalog 和桌面链路；不要求先拿到尚无法产生的桌面证据再接线。接线只使用该目标完整的 canonical 输入，不增加运行时健康开关、测试专用来源或环境 fallback。目标验收通过后才能声明支持或进入相应发布；candidate 中存在接线不等于验收通过。

来源继续使用 `metawork.builtin`，由 Product Skill 提交现有 additional source，AgentCore 独占解析及冲突裁决。已有 Task 不因依赖准备而需要 catalog refresh；新 Task、普通 refresh 和冷启动沿既有机制验证。

## 7. 实施阶段与退出条件

| 阶段                  | 交付内容                                                                                          | 必须满足的退出条件                                                                                                                                 |
| --------------------- | ------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| P0 固定输入可行性     | 三个新增目标的候选 artifact、wheel 清单、实际大小/摘要、布局/链接/动态依赖检查；原生改名回归设计  | artifact 与 wheel 存在且兼容应用基线；macOS arm64 先实跑解释器/原生扩展及改名后执行；无隐式系统依赖。macOS Intel、Windows arm64 的执行证据分别补齐 |
| P1 输入与资源构建     | 唯一目标表、锁、身份生成、平台常量、确定性 archive；Windows x64 身份冻结向量                      | Windows x64 两种 ID 与路径不变；错目标/缺项/陈旧下载量失败；跨主机 archive 字节一致；原 guard 通过                                                 |
| P2 准备与调用         | macOS sh 入口、Windows batch ARM64 目标适配、共用 finish/run、排他发布；Host 窄 seam 的合同与实现 | 两套环境真实联网准备、并发/离线/失败隔离通过；没有全局副作用；Node 前置条件与授权量准确；资源发布单测通过                                          |
| P3 文档与 Core        | 三格式真实创建、工作副本修改、读取/校验；target-aware Core Shell probe                            | 经 canonical Core 临时物化入口，真实 Shell 完成三格式处理，结果/原件/环境摘要均符合断言；没有临时目录父路径推断                                    |
| P4 桌面与分发         | macOS candidate catalog 接线、专用桌面验收；另记录 Developer ID/DMG 分发验收                      | 功能：新 Task/refresh/冷启动、非致命来源失败、成果交付通过；分发：实际分发产物下解释器及扩展可执行。分别记录，未覆盖手势/模型质量不宣称通过        |
| P5 新增目标与回归收口 | macOS Intel、Windows arm64 原生执行证据，Windows x64 受影响回归，真源与 README 更新               | 每目标分别给出功能/分发结论；Windows x64 身份及既有行为保持；正式相关 roots/guard/typecheck 通过；剩余缺口如实记录                                 |

P0/P1 不提前接入 macOS Application 来源；P4 接入 candidate 后完成验收。arm64 功能通过后可以形成该目标的阶段交付并说明测试系统与分发状态，尚未验收的 x64 不得随同发布为已支持。精确 target 输入与产品接线必须一致，不建立运行时健康/版本开关来代替发布验收。

## 8. 代码与文档改动地图

| 位置                                                                                                             | 改动职责                                                                                            |
| ---------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| `build_support/office-environment.json`、Python requirements 与 Node lock                                        | 唯一目标输入、平台 wheel 身份、下载量；Windows x64 原身份保留                                       |
| `scripts/build-office-skills.mjs`、`scripts/office-resources.test.mjs`                                           | 目标校验、身份派生、脚本生成、确定性打包与拒绝用例                                                  |
| `src/product/skill/office_environment/`                                                                          | 新增薄 sh 入口和具体 Darwin 发布方法；现有 finish/run 平台布局适配                                  |
| `src/product/skill/assets/{docx,xlsx,pptx}/`                                                                     | 生成/共用平台说明，完整读取/修改/交付要求；无第二套业务执行实现                                     |
| `src/app/office_skills.zig`、`src/app.zig`                                                                       | 资源发布、竞争复用、受验收目标接线，失败继续非致命                                                  |
| `src/native_sdk_compat/`、正式 App build/test graph                                                              | 必要时登记并隔离 macOS 资源发布 seam；不修改外部 SDK artifact                                       |
| `scripts/check-office-{private-environment,preparation-failures,skill-shell}.py`、`tests/office_skill_shell.zig` | 扩展原入口的精确目标适配；保留一个权威场景 owner，去除 Windows exe/PowerShell/正则假设              |
| `scripts/test-agentcore-vertical-macos.mjs`、Windows wrapper                                                     | 原位修正目标名单、路径、专用模式与成果验证；保留 Windows 原生手势的独立分支，不顺带重构整套桌面脚本 |
| `docs/requirements.md`                                                                                           | 只声明已开放并验收的 macOS、Windows arm64 范围及相应准备顺序                                        |
| `docs/product-architecture.md`                                                                                   | 跨平台目录、身份与准备/执行/恢复合同；公共规则继续只在此定义                                        |
| `docs/macos-distribution.md`、`docs/windows-distribution.md`                                                     | macOS 来源/执行规则、Windows ARM64 NuGet/ZIP 接受及原生分发验收；不复制公共生命周期                 |
| `docs/architecture.md`                                                                                           | 仅在需要公开 OS API seam 时登记能力边界和替换条件                                                   |
| `docs/validation.md`、`README.md`                                                                                | 标准入口、独立平台证据和准确快速开始；删除旧组件流程说明                                            |

本轮不修改 AGENTS.md、产品 identity、renderer wire、持久化 schema 或 AgentCore ABI。只有实际引入稳定 owner/module root 变化时才修改 project-structure 真源，普通内部文件新增不要求更新目录清单。

## 9. 验证矩阵与判定

### 9.1 持续回归

| 失败模式                                                | 最小充分观察层                                                             |
| ------------------------------------------------------- | -------------------------------------------------------------------------- |
| 目标缺项、错误平台/ABI、锁或下载量过期、Windows ID 漂移 | Node 资源构建 suite；固定迁移前身份向量，不从被测新算法生成期望            |
| 资源可重复构建与源码一致                                | Windows/macOS 同输入产物字节比较、现有 archive `--check`、同步 helper 检查 |
| 首次/重复资源发布、改动来源拒绝、并发赢家、占位对象保留 | 正式 App Zig test root；macOS seam 定向错误/竞争测试                       |
| 解压越界、实际字节超限、坏 payload、原件保护            | 既有归档 helper 与 Office validator suite                                  |
| 执行入口错引入系统包、空格/Unicode/引用/退出状态损坏    | 固定入口行为测试与真实私有环境执行                                         |
| 运行环境内容被文档处理修改                              | 处理前后文件内容 inventory 比较；不以只检查文件数量代替                    |
| 未验收目标被启用、桌面名单为空导致空验证                | 目标输入/接线断言与实际 catalog 非空、精确三种 invocation 检查             |

资源、架构和共享 helper 变化运行其正式关联 root；App import graph/seam 改动运行正式 Native test graph。涉及 Renderer 的实际修改才追加 typecheck 与受影响 suite；最终 `npm run check` 仍按标准入口执行。缺少 canonical staged Core 必须失败，不能跳过 Core 用例后报告成功。

### 9.2 真实平台准备与负面用例

在隔离 profile 真实下载，Python/Node 分别记录 artifact 身份、操作系统、架构、入口、日志和结果。至少覆盖：

- 并发首次准备，只有一个正式目录，输家校验复用；既有正式目录字节不变。
- 无网络复用、安装目录改名后从最终路径启动新解释器并 import/执行、中文空格和带引号路径；覆盖改名后、成功返回前中断的再次复用。
- `run` 缺环境不联网、不创建环境；非法语言不触发副作用。
- macOS 新建 Node 缺固定 Python 时在下载 Node 前失败；Node 已就绪时可不借助 Python 复用/执行。
- 默认权限与 `full_access` 分别验证：下载同意不产生文件权限，既有 Shell 拒绝不触发替代路径；允许的准备可通过同一真实入口完成。
- 损坏、空目录、非目录、链接、错误架构/版本、缺原生库、进程异常终止均明确失败且不修改正式目录。
- 下载失败、摘要拒绝、包安装失败/超时、占用/权限、取消、子进程未静止时清理边界准确；不复用强杀残留。
- pip/npm 实际镜像请求、代理/证书路径和私有目标约束；异常网络配置不泄露认证信息、不触发其他源 fallback。
- 持续慢速下载可越过旧短期限；真正停滞按低速窗口终止。
- 人工恢复仅在确认没有消费者的隔离 fixture 中显式清理一个目录，重新准备成功，兄弟目录保持。

### 9.3 三格式、真实 Core、桌面与分发

三种格式均验证创建→结构化读取→工作副本定向修改→校验/重读→真实 `DeliverFile`。XLSX 验证公式字符串与缓存缺失能如实表达，不把设置打开时重算当成已计算；DOCX/PPTX 不宣称视觉检查或 PDF 输出。附件原件摘要始终不变，不交付临时 XML、脚本或未完成结果。

Core fixture 使用精确 target 的 canonical staged bundle、loopback Provider 和三个独立 Session；验证实际被展开的绝对资源入口来自 Core 临时物化目录，真实 Shell 调用成功。fixture 验证工具与资源链，不证明远端模型规划质量。另以合成文件做一次有界真实模型 smoke，观察平台选择、准备同意、失败反馈与成果交付，单列人工观察结论。外部服务不可用则保留该缺口，不用 fixture 冒充；它不否定已独立证明的运行时/产品链路，也不新增“所有模型必须通过”的发布 Gate。

桌面专用模式覆盖新 Task、手动选择/普通调用、显式刷新、冷启动、篡改发布副本后 Office 来源不可用而应用仍运行，以及成果检查/继续修改草稿/冷历史中的必要回归。断言必须消费真实三项 catalog，不能在 macOS 使用空集合让测试通过。Windows 原生保存/Explorer 等用例继续由其原 owner 验证，不改名后假充 macOS 手势验收。

正式分发验收从实际 Developer ID 应用/DMG 进入执行链，观察私有 Python、Node 和 wheel 扩展能否在真实执行策略下工作。保留上游 artifact 的接受身份；不删除 quarantine、关闭校验或临时重签来得到通过。若选定发行包无法满足既有分发承诺，该目标的分发验收明确失败，回到来源选择；若只是缺少签名身份则记录为未验收，不把它当作已观察到的运行时失败。不能宣称 shell 开发测试已经证明分发可用，已有应用签名、公证与 Gatekeeper Gate 保持有效。

Windows arm64 从对应 ARM64 installer 安装的应用完成相同 Office 链路，并沿用既有 Windows Authenticode、runtime stage 和安装包 Gate。记录真实 PE 架构及系统版本，不用 x64 installer 或仿真进程代替原生验收；原有 Windows x64 非 Office 分发缺口不因本方案自动关闭。

应用最低系统版本从既有 canonical target 派生，不为 Office 新建重复常量。至少在声明的最低系统版本和当前系统上覆盖原生扩展与执行入口；没有最低版本机器/环境证据时该项保持未验收。

### 9.4 标准入口调整

复用现有三条 Python qualification 入口，增加明确的 target 选择及平台参数适配；具体 CLI 在实现时一次性收口，Windows 已有 `--download` / `--profile` 调用继续可用。无 target 时只选择当前原生目标，显式请求其他平台只能做明确标识的静态输入检查，不能返回平台执行通过。

正式入口继续包含 `node --test scripts/office-resources.test.mjs`、`node scripts/build-office-skills.mjs --check`、归档/validator suite、`zig build build-office-skill-shell` 的目标构建及 `METAWORK_BUILTIN_OFFICE_ONLY=1` 桌面模式。构建与执行的 target 必须对齐，使用目标锁的部署约束。新增/调整后在验证真源给出实际可执行命令；本方案中尚未实现的参数不能被当作现有命令运行或报告通过。

## 10. 完成、失败与回退规则

每目标的功能完成条件是：精确输入已接受，在明确记录的原生系统上私有环境、三格式、真实 Core 和桌面链路通过，Windows 受影响共享逻辑回归通过，所有 required guard 未弱化，规范和快速开始准确描述该范围。正式分发完成另须对应系统基线及平台安装 artifact 执行证据；本方案整体完成要求三个新增目标的功能与分发矩阵、Windows x64 受影响回归均闭合。

本方案允许阶段性交付和明确失败，不允许用未执行/跳过代替通过。缺 macOS Intel/Windows ARM64 机器、最低系统版本、签名、公证、canonical bundle 或固定 wheel 时，记录精确缺口及其阻塞的目标/验收类别，不把全部工作合并成一个模糊的失败或通过。真实模型观察单列，不扩大结构性兼容结论。

回退只撤回本次产品接线、代码和资源构建输入，不修改用户已完成的依赖目录、附件或 Product 数据。资源包更新产生新的内容根，旧根继续按既有政策保留；不增加自动迁移、指针切换或回收协议。版本控制负责代码恢复，不建立 active archive。

## 11. 待实测项与阻塞范围

技术路线已经确定，下列事实由对应阶段取得实际证据，不以方案文字代替验证。

| 待确认项                                           | 关闭阶段与所需证据                                           | 未满足时的处理                                                                                  |
| -------------------------------------------------- | ------------------------------------------------------------ | ----------------------------------------------------------------------------------------------- |
| 精确 Python 发行包及三个新增目标的 wheel 可接受    | P0：固定来源、实际大小/摘要、布局、系统基线、原生扩展运行    | 停止相应目标的输入接纳；提出具体版本/来源调整，不借系统 Python、源码编译或自动升级 Windows 补齐 |
| Core Shell 的 HOME、跨 Task 共享根与权限符合预期   | P0 初验，P3/P4 在真实链路复验                                | 标明集成缺口并收口对应 owner 输入；不改 Task HOME、不自动扩大权限或换安装目录                   |
| 私有运行时在发布后可启动并加载依赖                 | P0 可搬移性验证，P2 最终路径新进程及中断恢复测试             | 保留精确正式目录并报告不可用；准备不成功，不自动删除、修复或回退                                |
| Windows x64 身份与跨主机资源字节一致               | P1：迁移前身份向量、完整 archive 比较和原 guard              | 不进入共享实现交付；修正输入/生成器，不接受目录兼容查找或放宽字节检查                           |
| Host 排他发布 API 符合架构允许边界                 | P2：canonical SDK 审计、必要的窄 seam 登记及正式测试         | 缺少允许能力时明确阻塞该接线；不 patch SDK、不绕过 guard                                        |
| macOS Intel、Windows arm64、系统基线和正式分发执行 | P4/P5：各自真实平台及 macOS DMG/Windows ARM64 installer 证据 | 只报告已完成的目标和验收类别；不以 arm64、开发启动或交叉构建替代                                |

P0 优先淘汰不满足现有合同的输入；后续缺少平台或签名条件时，其他不依赖该条件的工作可以继续。失败处理只沿本方案的明确边界推进，不为未知情况预建替代路径。

## 12. 外部依据

- [Python Standalone Builds：发行目标、archive 类型与运行](https://docs.astral.sh/python-build-standalone/running/)
- [Python Standalone Builds：已知行为差异](https://docs.astral.sh/python-build-standalone/quirks/)
- [Python 官方 macOS 安装与固定系统位置](https://docs.python.org/3/using/mac.html)
- [Node 当前锁定版本的官方发行目录](https://nodejs.org/download/release/v24.19.0/)
- [Python 官方 Windows NuGet 发行与 ARM64 package](https://docs.python.org/3.13/using/windows.html#the-nuget-org-packages)
- [当前版本的官方 pythonarm64 NuGet 页面](https://www.nuget.org/packages/pythonarm64/3.13.15)
- [Apple：Darwin 排他改名 API 声明](https://raw.githubusercontent.com/apple-oss-distributions/xnu/main/bsd/sys/stdio.h)
- [Apple：mv 实现](https://github.com/apple-oss-distributions/file_cmds/blob/main/mv/mv.c)
- [pip：固定哈希与仅接受二进制包](https://pip.pypa.io/en/stable/topics/secure-installs/)

这些链接解释所选机制，不是运行时可变输入。P0 必须产出固定来源、实际 artifact 摘要和接受证据；正文不手写未经实际下载核验的 hash。

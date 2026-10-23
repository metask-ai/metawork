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

编译安装器前，runtime stage 必须通过主包资源检查，不得混入完整 Office Skill 资源树、Python、Node 或 Office 引擎等独立组件资源。[产品需求](requirements.md#53-task)规定的基础 Skill 只有随程序编译的有界方法文本，不含脚本、校验 schema 或重依赖；Application 在本地数据目录按内容版本发布，不覆盖已有版本。最终安装器完成签名及身份检查后，还必须通过对应 target 的主包体积检查；超限或缺少有效基线均使 package 失败。基线安装器身份、摘要、实际字节和允许增量由 [`build_support/main-package-size.json`](../build_support/main-package-size.json) 唯一拥有，检查完整安装器，不以单个 executable 或源码目录大小代替。Office 组件与主包分别计量，不得通过把重依赖放进低压缩率或高压缩率资源来规避主包边界。

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

构建解释器只属于 producer，不成为交付物对系统 Python 的依赖。唯一供应商输入为 [`office-runtime.windows-x64.sources.json`](../build_support/office-runtime.windows-x64.sources.json)，固定引擎、所带 Python、Node、私有中文字体以及公开来源 bootstrap 所用临时便携 Python 的来源与摘要；Python wheel 身份由 [`office-python.windows-x64.lock.json`](../build_support/office-python.windows-x64.lock.json) 固定并绑定现有依赖输入，JavaScript 创作库从现有 `package-lock.json` 取得完整闭包和嵌套位置。producer 不复制整个开发依赖树，不安装全局 Office 或注册全局字体。临时便携 Python 不进入完整组件的常驻运行时，固定来源不等于客户端已支持该 bootstrap。

依赖布局由上述 canonical 输入生成；共享的离线组装器只消费固定摘要的 wheel ZIP 与 npm tar.gz，不调用 pip/npm 安装、不解析依赖或执行包安装脚本。Python 保留 wheel 原有代码、许可证、metadata、RECORD 和 `data/scripts` 资源，不生成带构建目录的启动包装器或安装记录；需要额外数据重定位的 wheel 须明确拒绝，不能假装安装成功。JavaScript 仅接受一个顶层目录，按 lock 固定的包位置写出并核验包名和版本，不生成 `.bin` 链接或消费包内嵌套依赖。源先复制到同一私有事务内并校验实际字节；压缩量、实际展开量、文件数、metadata 与路径有界，链接、reparse、碰撞和未知布局拒绝，失败不得启用半成品。producer 与后续客户端 bootstrap 使用同一组装实现；这不表示客户端多源安装已接通。最终启用仍须匹配主包固定的完整组件清单，不把客户端生成的 recipe 或清单当作新信任来源。

公开源的独立资格检查入口为 `node scripts/check-office-public-sources.mjs`。它与 producer 共用根 lock 的 JavaScript 闭包选择，只从固定 HTTPS 地址逐项 GET，以实际读取字节校验 SHA-256 或根 npm lock 的 SHA-512，不接受动态重定向、依赖解析或安装脚本，不保存和执行下载内容。LibreOffice 来源固定官方公开镜像的直取地址，不能把下载路由的临时跳转结果当作客户端信任输入。结果写入 `.zig-cache/office-public-source-verification.json`，包括实际下载量和每项通过情况；HEAD 可达或 Content-Length 不构成字节身份通过证据。

该检查只证明公开来源的下载字节，不表示客户端已支持从多个公开源本地组装，也不替代签名、安装、普通权限或干净机器验收。客户端下载 authority 仍以本节下文当前发布输入为准；公共来源安装改造尚未接入时，不能以供应商来源直接启用正式组件。

供应商输入必须通过摘要与适用的 Authenticode 校验；MSI 通过 Windows 只读数据库 API 和进程内 CAB API 提取到新的 staging 目录，不运行 MSI action、custom action、msiexec 或安装服务，保留许可证和运行所需的 app-local Microsoft 库。提取器在隔离子进程中运行，不能把其临时工作目录切换用于桌面主进程。MSI source 目录只映射到自有根内，不使用目标系统目录属性；CAB 成员须与有界 File 表逐项一致，实际大小、未知/重复成员、路径碰撞或额外介质均拒绝。输入锁拒绝写入与替换，并重新核验实际源字节。x64 输入仅按 sources 中的精确 File identity 排除重复目标的 ARM64 运行库；不以覆盖顺序选择架构，也不建立通用 MSI 条件求值器。组件入口拥有解释器和引擎进程树，组件内的私有字体由引擎加载。默认要求签署 MetaWork 自有入口并立即验证；显式 `--signing none` 仅产生开发组件，不能作为正式分发通过证据。签名身份与工具继续遵守上文的[签名边界](#签名边界)。

入口支持两种明确的生命周期 owner：模型经 Shell 调用时由入口保留整树 Job；Application 的安装自检和产品预览通过私有 Host Job 协议，在任何子进程启动前加入应用的随机 Job 并释放临时 Job handle。不得在 Host 退出后由组件长期保留该 handle。Native 能力边界见[高层架构](architecture.md#35-native-sdk)，Host 取消、超时、输出预算和物理静止的证据须独立于入口自有 Job 验收。

公开源安装的临时便携 Python 复用 Application Office 进程 owner。只执行已认证 stage 中的固定 bootstrap 脚本和固定相对输入/输出路径，显式传入主包固定的 seed 与最终清单摘要；不开放任意 executable、脚本、URL 或 shell 命令。安装调用必须绑定 pending operation Job，临时解释器加入前只加载已认证代码和解析参数，不创建安装输出或子进程；加入后立即关闭自己的 Job handle，拒绝缺失、未设 kill-on-close、允许 breakaway 或已封闭的 Job。安装 worker 才是长期 handle owner，取消、期限和输出超限沿既有根进程/整树静止语义执行，无法证实静止时保留事务资源。临时环境只继承固定 OS 变量，工作目录及临时目录均归本次事务；该进程路径不替代执行前的源、解释器、seed 身份与签名检查。

发布的组件目录是不可变资源；运行期的 profile、缓存和临时结果不得写回其中。引擎内嵌 Python 的字节码写入须被禁止，shared package cache 使用每次操作的临时目录，计算使用 CPU 路径，避免驱动自检和锁文件修改安装资源。不能只在打包前删除缓存来掩盖运行期修改。producer 在自检前后核对完整目录 inventory；引擎行为回归也必须验证操作没有增删或修改组件资源。归档校验仍独立执行，不因自检通过而省略。

组件归档为 `tar.gz`，tar 使用 USTAR；当前 Windows producer 不生成链接或特殊成员，不包含字节码缓存、PDB 或安装器副本。归档根的 `office-runtime.json` 使用 schema 1，固定 `target`，以 `files` 列出相对 `path`、实际 `bytes` 和 `sha256`；`payloadBytes` 是清单自身之外所列文件的总字节。归档旁的机器结果记录完整压缩摘要、压缩量和含清单的实际展开量。构建完成前必须重新流式读取完整归档，检查实际成员与清单一致及 gzip CRC，不能只核对构建目录。容量与成员预算由 producer 检查拥有；安装器的受限解包验收仍需独立完成。

这些 producer 来源不授予客户端任意下载 authority。正式客户端须由主包固定其接受的组件发布身份、来源和完整归档摘要；组件内引擎或解释器安全更新因此需要同步发布主包信任信息。主包升级不自动下载用户尚未启用的 Office 组件。完整 Skill 工作流、安装事务、签名后位置与干净机器验收通过前，不得将开发归档登记为可安装的正式组件。


自有安装输入使用 `node scripts/build-office-install-seed.mjs <prepared-component> <canonical-download-cache> <new-absolute-seed.tar.gz>` 构建。配套资源只允许当前仓库对应的完整 Skill、适配代码、自有入口及安装 metadata；不得混入供应商解释器、转换引擎、文档库或其安装器。输入与已验证 producer 资源和 canonical 锁必须一致，使用有独立清单的 USTAR `tar.gz`，并受单独的小资源预算及原有实际主安装包总预算约束。资源构建不登记正式 release，也不表示客户端已经安装或启用组件。小资源随主包、重依赖按需下载的边界不允许通过压缩来绕过内容检查。

构建期与离线 bootstrap 共用运行时布局和完整清单生成实现；bootstrap 在私有事务中重新核验全部固定源，组装期间不执行组件资源。完整清单可以由实际组装字节确定性重建，但其完整字节摘要必须与主包固定的 producer 清单摘要相同，失败不得写出可接受清单或启用组件；客户端生成的摘要不能成为新的信任来源。配套资源不必复制整份完整清单以扩大主包。该资格仍须与客户端 Zig 首阶段、下载、签名、最终位置自检及事务验收分别核对。

## 客户端 Office 安装事务

主包接受的 Windows x64 组件由 [`office-component-release.windows-x64.json`](../build_support/office-component-release.windows-x64.json) 唯一固定，并在构建时校验、编译到 Application。schema 1、protocolRevision 1 与 target `x86_64-windows-msvc` 固定；必填 `retained` 数组最多包含八个仍获主包信任的旧组件身份，每项精确为 `archiveSha256`、`manifestSha256`、`archiveBytes`、`unpackedBytes` 和 `files`，不含下载 URL。当前 release 与 retained 不允许重复或冲突身份。启动仅以 current 记录的精确归档摘要查找主包已固定身份，再验证所带清单和文件；retained 不用于目录发现、安装旧版本或下载 fallback。retained 是信任接受集合，不是磁盘引用；非当前旧目录仍按进程内引用静止规则清理，不能因该集合继续占用磁盘。它让升级失败后的仍可信旧组件继续工作；安全修复需要同时移除不再信任的旧身份，磁盘记录不能自行恢复该信任。`release: null` 表示尚未登记可供客户端安装的发布物，不得推测下载地址或转用开发归档。非空 release 必须同时提供 `url`、`archiveSha256`、`manifestSha256`、`archiveBytes`、`unpackedBytes` 和 `files`。URL 只接受固定 HTTPS 绝对地址，不含 credential、query 或 fragment；下载不接受重定向、远端 manifest、任意用户 URL 或恢复旧下载。组件安全修复需要重新发布包含新信任输入的主包。独立 producer 的供应商输入不能代替这个客户端发布输入。

Application 只有在持有本地数据目录 Primary authority 且该组件操作已串行准入时才能修改组件 store。下载限量写入本次阶段文件，校验同一实际字节的完整摘要及长度，再由主包 Zig 解包、校验完整清单与主包固定的清单摘要。先检查目标 PE machine，校验 MetaWork 入口及所带 Python、Node、引擎入口的 Authenticode，再将已认证字节移入独立最终候选目录。候选目录尚不可发布为 catalog 或当前可用版本，仅本次安装事务可启动受控自检。Windows 在执行资源后可能暂时无法移动其目录，因此完整运行自检只在最终候选位置执行，不在 staging 执行后再迁移。最终位置必须重新检查 PE 与签名，再通过 Application Office Job 完成自检，成功后才能原子替换当前记录。失败保留旧当前版本；不得把未签名开发模式接到正式客户端。自检只继承固定 OS 环境，使用事务所属 scratch 作为工作目录及临时目录，不继承任务或 Provider credential。

组件 store 的持久记录仅描述组件自身，不写入 Task 或 Session。`current.json` 与 `pending.json` 使用 schema 1、`installId`（32 位小写十六进制随机身份）及 `archiveSha256`（64 位小写十六进制）；固定 `.next` 文件是机械临时文件，不授予身份。阶段目录为 `staging/<installId>`，最终版本目录为 `versions/<installId>`，不得覆盖既有目录。新安装与修复都使用独立身份，不原地替换仍被引用的资源。归档摘要保留在记录中，不重复拼进长运行时路径，以避免供应商 Windows loader 的路径限制。

`host.scope` 只标识当前 Primary Host 的进程存活范围，不保存 Task/Session 或组件版本引用，不授予组件安装、下载或执行信任。它精确为 24 字节：ASCII `MWOFS001`、little-endian u32 PID、必须为零的 u32 保留位、little-endian u64 Windows 进程创建 FILETIME。Application worker 从当前进程取得身份，经 `host.scope.next` 写入、sync、原子替换；准备发布已安装 Skill 来源前必须成功完成。旧记录可留在磁盘，但不能被另一 Host、PID 复用或非祖先进程继续使用。正式 `versions/<installId>` 入口在开始子进程前必须验证该范围；Application 专用 `--host-job` 调用继续使用独占 Job 生命周期，不依赖模型 Shell 的身份记录。具体生命周期边界由[高层架构](architecture.md#35-native-sdk)定义。

替换或移除 current 前，必须先持久发布对应版本的删除意图 `retired-<installId>.json`，其内容采用同一 schema 1 记录。最多保留 128 个意图；同目录身份冲突、损坏记录或超出有界读取预算时拒绝继续，不猜测清理目标。固定 `retired.next`、`retired.json` 仅是意图发布的临时文件；恢复可清除它们，不能据此删除版本。意图描述组件自己的待清理资源，不保存或重建 Task/Session 引用，也不授予组件执行信任。它让重启后仍可定位旧版本，而无需扫描、收养或删除未登记目录。

Windows 资源 Job 名由已登记的随机安装或事务身份确定：版本为 `Local\MetaWork.Office.Version.<installId>`，pending 操作为 `Local\MetaWork.Office.Op.<installId>`。它们只属于本地组件生命周期，不进入 Task/Session、Bridge 或远程发布身份。registry 发布完整 Skill 来源前建立版本执行 Job；入口临时加入后立即关闭 handle，再建立其单次调用子树。封闭 reservation 设置 `JOB_OBJECT_LIMIT_ACTIVE_PROCESS` 且 limit 为零，不能作为执行 Job 使用。已有具名对象不得接管；冷清理最多有界等待其消失，失败保留目录与记录。版本 Job 由相应版本 bookkeeping 持有，pending Job 由单次 Application 进程调用持有；二者均禁止 breakaway 且 kill-on-last-close。新调用的 Job 准入与关闭、终止、active 数观测共同决定资源是否可删。

移除先提交 current 缺席，再由 owner 将新 catalog 来源切回基础 Skill；原有 catalog 继续持有旧资源。后台清理接收 owner 生成的进程内受保护身份快照，只有零引用的已认领条目或没有进程内引用的已登记意图才可删除；current 与 pending 的同目录保护仍必须独立检查。删除意图指向仍为 current 的版本时，只撤销意图，保留版本字节。物理删除成功后才能移除对应意图，失败与取消保留剩余工作；崩溃在两者之间时可幂等收口。启动清理仍以 Primary authority 和进程静止为前提，不能将内存引用丢失本身视为外层 Shell 进程已退出的证明。

pending 必须先于阶段写入；只有最终位置验证完成后才能提交 current。取消先等待进程与下载真正静止，再删除本次未提交资源；进程静止无法证实则保留事务并明确失败。current 提交后到达的取消不能撤销已提交事实；清理失败如实表示待清理。原子替换后的持久化结果不确定时保留 pending 与候选目录，禁止猜测回滚。恢复只在启动或 worker 已静止时读取 canonical current/pending：已提交候选予以保留，未提交候选只清理 pending 精确登记的目录，不扫描或收养未登记目录，不重放下载、自检或激活。旧版本最终清理由进程内 catalog lease、执行进程及预览 handle 的引用拥有者决定，安装事务不得自行删除旧版本。 Application 资源 owner 持有每个候选或当前版本的本地引用；退休时只消费自己的引用，catalog 回调和进程/预览 pin 只原子增减计数。零引用不可重新取得；registry owner 只选择零引用的清理候选，物理删除在独立有界 Application worker 内执行，join 后 owner 才消费结果并释放条目，避免在 Native loop 删除整套运行时。current 或 pending 指向同一安装目录时必须拒绝，即使记录摘要不一致。清理失败保留待清理条目，shutdown 在外部引用未静止时不得销毁 bookkeeping。这些引用不写入磁盘；本地记录冲突不能授予清理 authority。

机械事务测试与开发组件安装验证不表示正式签名发布、公开下载服务、干净机器或应用 UI 已通过验收。实际发布仍须通过完整的目标平台分发验证。

# MCP 通用配置接入与管理方案

日期：2026-11-06。状态：A、B、C、D 已实施，当前 Windows x86_64 正式验证已通过；其他平台与真实服务边界按第 8、9 节保留。本次整理合并复盘结论和最终设计，保留已通过的范围与验收要求，不新增产品选择。

## 1 复盘结论

此次问题首先是 MetaWork 的 MCP 成品能力缺口：用户取得常见 `mcpServers` 配置后，产品没有将其转入正式添加流程的入口；继续分析又复现了 Windows 路径分词、结构化 argv 编辑和启动诊断的真实缺陷。内部 registry 格式不同，不能成为不支持通用配置的理由，也不能据此认定安装说明本身错误。

Agent 的无效探索放大了问题，但本轮不扩展为 Agent 机制重构。自动审批判断单次授权，不负责判断整体进度；工具记录达到展示容量后继续运行属于既有设计，不作为 MCP 缺陷修复。修复应以“取得配置到新 Task 实际调用”的完整用户路径验收，而不是以解析成功、保存成功或测试连接成功代替完成。

凭据进入模型和历史的事实要求建立清晰的输入边界，但不能由此引入站点适配或把全部配置工作交回用户。受支持的配置由 MCP 模块消费，凭据走专用输入或 OAuth；无法识别的敏感 URL 需要如实列为剩余风险。

| 基线事实                                                                  | 本轮处理                               |
| ------------------------------------------------------------------------- | -------------------------------------- |
| 没有 `mcpServers` 到产品输入的转换                                        | 增加通用配置接入，复用现有 Add         |
| `C:\Tools\server.exe` 被分词为 `C:Toolsserver.exe`                        | 修复 Windows/POSIX 分词与格式化往返    |
| Edit 将 argv 拼成字符串，`--filter=$HOME` 等字面参数无法再次保存          | command、arguments、cwd 始终结构化保存 |
| spawn 原始错误被合并为 `child_exit`，启动后失败也缺乏诊断                 | 保留安全的 Host 启动与关闭事实         |
| Agent 没有正式 MCP 管理入口                                               | 模块能力就绪后增加 `ProposeMcpServer`  |
| 已有 STDIO、HTTP、static/OAuth、凭据存储、事务、apply、catalog 和工具选择 | 复用其 owner 与执行链，不另建实现      |

原有页面测试通过不代表上述路径已覆盖。当前工作树的候选实现须按本方案重新验证；文件存在、方案通过和代码通过是三个不同事实。

## 2 目标与范围

目标流程：

```text
粘贴通用配置或接收 Agent 提议
→ 查看并提交完整连接
→ 完成必要认证
→ 自动连接与发现工具
→ 用户选择开放的工具
→ 新 Task 实际调用
```

手动 Add、导入、Edit 和 Agent 提议共用 typed connection，最终进入现有 Product MCP mutation。连接授权仍来自用户提交 Add/Replace；提交前不得启动 child、读取已有凭据、连接网络或打开 OAuth browser。`full_access` 不替代产品提交或工具选择。

交付分为四个切片：A 输入正确性、B 通用配置接入、C 进程诊断、D Agent 入口。前三项不依赖新增 Host Tool。

本轮不增加站点安装器、任意网页安装协议、市场、publisher trust、CLI、URL scheme、第二实例管理通道、项目级配置覆盖、批量事务、legacy SSE、Resources、Prompts、MCP Apps、Core ABI 或 Native SDK 替代输入；不热附加既有 Task 工具，不调整 Run 上限、记录容量或审批机制。

本文是实施方案，不是 decision record，也不替代领域真源。规范更新范围见第 9 节。

## 3 配置输入与编辑

### 3.1 格式与预算

首版接受严格 JSON：根对象仅含非空 `mcpServers`，其值为服务名到配置对象的映射。服务名只作为初始 display name，Host 继续生成稳定 identity、namespace 和 generation。

不接受 JSONC、YAML、可执行配置、自然语言片段或格式猜测。重复 key、语法错误、错误字段类型及超限输入明确拒绝，不截断后继续执行；错误只含安全字段路径、类别或行列，不回显源片段。

Renderer 使用 `jsonc-parser` 稳定发布版的语法树与错误观测，作为直接依赖并由 lock 固定版本，禁止注释和尾逗号，检查全部解析错误及重复 key，不采用容错结果。输入限制为 256 KiB UTF-8、128 个服务和 32 层嵌套；大小和扫描深度先于递归树构造。新输入预算只在纯解析模块定义，连接字段沿用 Host Limits。参见该库的[官方 API](https://github.com/microsoft/node-jsonc-parser#readme)。

### 3.2 字段支持表

| 外部字段                     | 处理                                                                                             |
| ---------------------------- | ------------------------------------------------------------------------------------------------ |
| `command`                    | STDIO 可执行文件，不作为 shell 脚本                                                              |
| `args`                       | 字符串数组，保留顺序、空参数和实际字节                                                           |
| `cwd`                        | 可选工作目录，沿用 Host 接受规则                                                                 |
| `env`                        | 名称进入 typed connection，值进入专用凭据流程                                                    |
| `url`                        | 非敏感 Streamable HTTP endpoint，沿用 HTTPS/loopback 与 authority 规则                           |
| `headers`                    | 名称进入 typed connection，完整值进入专用凭据流程，不自动补 Bearer 前缀                          |
| `type`                       | STDIO 接受 `stdio`；HTTP 接受 `http`、`streamable-http`、`streamable_http`，归一为内部 transport |
| 缺省 `type`                  | command 或 url 恰好存在一个时推导，否则拒绝                                                      |
| `disabled`                   | 缺省或 boolean false 正常添加；true 明确不支持；其他类型拒绝                                     |
| `autoApprove`、`alwaysAllow` | 不产生授权，显示未采用提示，不生成 allowlist 或 Session grant                                    |

command 与 HTTP 字段互斥；消费的字段严格检查类型，不通过 `String()` 等强制转换接受错误值。协议策略和 timeout 使用现有 Add 默认值，提交前可编辑。

未知字段、`envFile`、其他客户端 OAuth 配置和 timeout 扩展使对应条目明确“不支持”，不得静默丢弃后按不同语义连接。含配置插值表达式，如 `${env:...}`、`${workspaceFolder}`、`${userHome}`、`${...}` 或命令替换的条目，提示提供具体值，不执行展开。没有插值语义的 secret 字符串及结构化 argv 中的 `$HOME`、反引号等按字面处理。

environment 名称、大小写、重复项及保留变量沿用 Host 当前平台规则；HTTP header 重名按 HTTP 大小写规则检查。不放宽 PATH/SystemRoot 基线、空凭据或其他现行限制。

`mcpServers` 的客户端扩展并不完全一致，本轮只承诺上表。[Cursor](https://cursor.com/docs/mcp)的变量展开、[VS Code](https://code.visualstudio.com/docs/agent-customization/mcp-servers)的 `servers` 格式等不自动成为本轮能力；不读取其他客户端目录、凭据或配置。

### 3.3 结构化参数与命令编辑器

单服务草稿保存分开的 command、arguments、cwd。导入和 Edit 默认使用可独立编辑的字段；无修改地打开再保存，不得改变 argv。

只有用户明确编辑或应用完整启动命令时才分词，不把显示文本作为结构化配置的真源。分词与格式化接受同一显式 platform 参数：

- Windows 保留普通反斜杠，正确处理双引号边界、盘符、UNC、空格和末尾反斜杠，保留已有单引号字面片段输入能力。
- POSIX 保留其引号和转义语义，包括 `/Applications/My\ App/x`。
- 可编辑命令的往返满足 `parse(format(argv)) == argv`；结构化参数不经过此路径。
- 不执行 shell、变量展开或命令替换；拒绝的管道、重定向等不改走 shell fallback。

命令编辑使用本机 Host 平台事实；若投影缺少可靠事实，仅增加窄非敏感平台信息，不推导远程执行协议或让模型指定平台。

## 4 添加与凭据提交

### 4.1 用户输入与多服务选择

MCP 页新增明确触发的“粘贴配置”入口，作为专用 password 表单。只在用户 paste 事件中接收原文，不自动读取剪贴板，不让原文进入 Task、模型、普通 textarea、公开预览、日志或浏览器持久存储。解析结束即清空接收控件并释放原文引用；语法错误要求重新粘贴，不恢复含凭据的源文本。

解析后按输入顺序列出服务名、transport 和可添加或不支持状态；用户每次选择一个进入现有 Add drawer。字段与凭据分别预填，完整公开配置可编辑。无效条目无 effect，不阻止其他合法项；不自动选择首项、不批量提交、不整批回滚、不按显示名替换服务，也不新增显示名唯一性要求。Edit 仍须由用户选定已有服务。

已有 Add/Edit 不被新导入或提议覆盖；用户先完成或明确放弃当前草稿。不自动从 Task 跳走，不增加重复确认 modal。

### 4.2 凭据分流与已知凭据检查

env/header 的 value 字段只进入临时 password 表单和有界 `captureSecret` 操作，不作为明文值进入普通配置命令、snapshot、卡片、模型、历史或日志。保密传输与存储不等于把所有 env 值认定为秘密：`PORT=3000` 与 `--port 3000` 可正常导入；字符串重合只作复核提示，不改写参数或扩大权限。

JSON 没有“说明已明确为 Key”的可信数据来源，不建立名称、熵值或站点识别器。现行 Gate 要求秘密不得进入公开 metadata，但现有 MCP create 只有 projection 防护，没有已知凭据写前拒绝。本轮必须在 Product Control 的所有创建 transport 与替换连接入口新增该检查：复用 Host 已登记凭据集合和现有敏感文本 predicate，不把全部 env 值登记为凭据；命中公开连接字段时，在持久化和 effect 前 rejected，create 的 serverId 为 null。错误不回显值，不以用户可见为由仅警告。

不另建匹配算法或导入白名单，不重写既有持久数据；现有 projection 防护继续有效。未知值不因重复出现自动成为秘密，剩余风险见第 9 节。

用户可选择现有 OAuth 流程。导入器不从名称、路径或 header 猜测 client、scope 或 issuer，Host 继续拥有 discovery、consent 与认证。

### 4.3 create 回执与串行捕获

Add 确认完整连接与本次明确输入的凭据。先 create；缺 static 凭据的服务保持需要认证，不先尝试无凭据连接。确认保存后，逐项调用现有 `captureSecret`，每个值提交后释放 Renderer 引用，Host 消费并清零 owned copy。

STDIO、static HTTP 和 OAuth HTTP 的 create 共用窄 `McpCreateResult`：outcome、desiredGeneration、nullable serverId。其他 mutation 不增加该字段。

| create 结果                                 | identity 与后续动作                                             |
| ------------------------------------------- | --------------------------------------------------------------- |
| `saved`                                     | 必须返回确认创建的稳定 serverId 与提交 generation，才能开始捕获 |
| `saved_recovery_required`                   | canonical target 已知时可带 id，但停止自动捕获                  |
| 失败、busy、stale、cancelled、indeterminate | serverId null；不能把仅生成的 id 当作创建成功                   |

Product 在 preparation 释放前复制或转移已确认 id 的有界 owned 回执，Control 与 Bridge 消费同一结果。严格更新 Zig/TypeScript 返回类型、decoder 和 fixture，不保留内部旧结果兼容分支。

Renderer 使用回执的 id 与 generation，不等待某一 snapshot、不比较新旧服务集合、不按显示名找接收方。每次 capture 由 Host 校验 generation、server、auth mode 和 slot；每次成功回执给出下一步唯一 generation 基线。外部 mutation、目标变化、管理冻结、结果未知或迟到响应都结束本次捕获、清除未发送值，保留实际保存结果并要求重新输入，不重放 create。

未提交表单仍遵循“generation 变化即清除”。已明确提交的有界操作仅允许自身已确认命令推进 generation，不能借最新 snapshot 自动重试秘密；实施时同步 Bridge 的这项生命周期合同。

取消、离页、断连或关闭后不再发送剩余 secret；已发命令按现有事务收口，迟到结果不重建输入或发送下一项。多服务输入不跨提交保留整批秘密：一次选择一个，提交、取消或 generation 变化后清除其他条目秘密，只保留公开信息与缺凭据状态，后续需重新粘贴或填写。JS 字符串只承诺及时释放引用，不宣称可保证原地清零。

### 4.4 连接与真正完成

保存后沿现有 `Connection → MCP handshake → Choose tools` 详情流程自动连接、发现工具，不要求先 Test 或重启。失败保留确认配置，按当前目标提供修正或重试。新服务 allowlist 仍为空，用户显式选择工具后，仅后续新 Task 获得能力。

保存成功、测试成功、已发现工具、已授权工具与新 Task 可用分别呈现。最终验收必须由新 Task 真实调用 MCP，不能以页面文案代替。

## 5 STDIO 进程诊断

Application 为每次尝试保留有界事实：server/source、attempt、spawn 是否成功、观察到的关闭阶段，以及实际取得的 exit code。

| 事实                          | 安全诊断与后续动作                             |
| ----------------------------- | ---------------------------------------------- |
| 程序不存在                    | 检查安装、command 和搜索路径                   |
| 启动权限拒绝                  | 检查可执行文件与访问权限                       |
| 无效可执行文件                | 检查 command 和目标平台                        |
| 其他 spawn 失败               | 给出安全类别，不回显原始系统文本               |
| spawn 成功、握手前 STDIO 关闭 | 程序已启动但未完成握手，检查依赖和参数         |
| 实际观察到退出                | 可附真实 exit code；EOF 不单独证明退出         |
| 成功握手后断开                | 沿现有断开与恢复语义，不冒充首次启动或认证失败 |

Core 继续接收既有 failure 枚举。Host 事实经 Application coordinator 交接，由 Product MCP 按 source/attempt 接纳；transport 线程不直接改 Product，也不增加 ABI 值。旧来源、候选测试、已取消或旧 completion 不覆盖正式连接。成功、目标变化或新尝试使旧诊断失效，诊断不写 registry/Task 历史。

复用 `safeDiagnostic` 展示受控文本，不发布 raw stderr。stderr 继续消费并清零以免 child 阻塞；不等待仍运行的进程只为取得诊断，不延长 timeout/cancellation，不新增轮询任务。Windows Job、句柄隔离和 POSIX 生命周期保持。

`npx --version` 仅证明 shim 可运行。通过正式 STDIO owner 验证 bare npx、npx.cmd、空格路径和已安装 Node 程序，继续观察真实握手。默认用本地临时包或固定离线 fixture；发布前在隔离 profile 对明确版本做一次实际下载与运行，记录环境条件。不使用 latest、shell fallback 或 SDK patch；不承诺仅凭退出阶段识别 npm 根因。

## 6 Agent 正式入口

### 6.1 工具与权限

固定 Host Tool 名为 `ProposeMcpServer`。输入为单服务 typed public connection：名称、transport、command/arguments/cwd 或 endpoint、明确 auth mode、environment/header 名称。禁止 secret value、credential locator、server id、allowlist、permission、站点安装 URL 或任意 Bridge 调用。

输入和 canonical 提议编码各不超过 32 KiB UTF-8，并满足 canonical SDK 预算；限额由工具合同唯一拥有，Host/Bridge 消费公开限额。Agent 严格解码、检查大小，最终业务校验仍由现有 Add/Host 执行，不复制 Product policy。

工具只返回一次 status、成功时的 proposal id 和固定短说明，不回传 draft。结果为 `proposal_submitted | busy | invalid_arguments | unavailable | cancelled`；submitted 仅表示 Host 信箱接管，不表示主线程已投影、已保存或已连接。后续状态归 MCP 页，不阻塞 Run、不轮询、不回推模型。

效果说明加入 `hostToolPermissionContext`：只提交非敏感建议，不连接、保存、读取凭据或扩权。这不授予免审批规则。人工模式可能先有 Core 工具审批再有产品 Add；自动审批和 full access 不跳过 Add/工具选择，不新增第三次产品确认，不缓存批准。

工具说明要求在获取 Key 前判断认证方式，不通过普通 WebFetch/Shell 获取安装凭据，不提交明知含 secret 的 URL、command 或 argv；需要凭据时使用专用输入或 OAuth。此为模型指令约束，不是机器全面识别能力。当前 Task 不热附加、不重建或自动续跑，完成时提示新 Task 可用。

### 6.2 单槽非阻塞交接

Product MCP 主线程拥有一个非持久待处理提议，绑定 id、来源 Task/Run 与有效来源证明。Run admission 冻结窄 Host capability；Agent 不 import Product/Bridge/Application，不持有 aggregate 指针。跨线程入口为容量一的小信箱：

1. callback 在锁外完成严格解码与有界 owned draft 构造，身份来自冻结 capability，不信任模型身份字段。
2. `tryPut` 使用 try-lock；竞争、消息未取走或已有待处理提议时立即 busy，调用方释放失败 candidate；关闭/来源失效返回 unavailable/cancelled。
3. 短锁内仅检查 token、生成非零进程内 id、转移 owner 并占名额，不分配、编码、调用其他 owner、唤醒、等待或 join。
4. 解锁后以非阻塞 RequiredWake 通知主线程并立即返回 submitted，不等待主线程响应，不重放提议。
5. 主线程 drain 重验来源并移动已构造数据，接管不再复制草稿；凭据复核只解析有界编码，资源不足时安全拒绝；take 不释放名额，create 消费、关闭或失效才释放。

queued、由主线程持有与 closed 属于同一名额生命周期，不是第二套配置状态。两个并发 callback 最多一个成功；释放核对 proposal id，不误释放新提议。

关闭顺序：主线程先停止 ingress，短锁内关闭信箱、使 token 失效并取出未处理消息，解锁后再取消和 join Executor/Run；Session callback/active_refs 静止后才释放 capability、信箱与 Product owner。锁不跨 join、Session.close 或 RequiredWake，callback 无 condition wait、同步主线程调用或重试循环。

完成 Run 可保留提议；取消来源 Run、删除来源 Task、关闭 owner 或用户关闭时清理，迟到 callback 不复活。提议不写 history、checkpoint 或 registry，重启不恢复；其交接不依赖 Tool 展示槽，超过既有记录容量仍可达。

### 6.3 投影与容量

公共 `context.mcpInstallation` 精确包含 `proposal` 和 `notice`。proposal 为 null 或仅含 id、taskId、runId 与公开 typed draft；notice 为 null 或固定 `proposal_rejected`，不回显输入。Task scope 不交付 MCP management，所以提议只在公共 context 发布一份 canonical 状态，不复制到管理块；无提议或已消费时 proposal 为 null。

主线程接管前及每次投影使用现有 Host 已知凭据 predicate 检查公开字段；命中则失效、释放名额并安全提示，不把脱敏失真的配置交给 Add。callback 不读取主线程可变凭据集合，submitted 不宣称后续检查已通过。

`worstCaseSnapshotBytes` 和实际分配独立计入最大提议、identity、结构及 JSON 转义开销，使用工具公开预算、现有转义上界与 checked add/mul。不能挤占 registry 上限、静默省略提议或忽略溢出。

### 6.4 用户查看与一次性消费

Task 卡片和 MCP 页仅从 canonical projection 提供“查看 MCP 配置”，不从 Markdown、任意工具结果或同名 MCP 工具构造控制入口。用户点击才进入 Add，不自动导航或覆盖表单。

用户关闭或取消时，调用 `metawork.mcp.dismissInstallProposal`，携带精确 id，仅允许 `zero://app`；旧 id 不影响新提议。

从提议创建时，现有 create 带可选 proposal id。Product 在同一主线程操作中检查其未消费，确认保存后原子移除提议、释放名额并返回 serverId，不需成功后的第二次清理。旧 id 在任何 create effect 前 rejected；手动 Add 不携带 id，仍允许同名服务。proposal id 不代替完整配置或授权。

| 结果或事件                                               | 提议与表单处理                                                                 |
| -------------------------------------------------------- | ------------------------------------------------------------------------------ |
| 明确拒绝、busy、stale                                    | 保留原提议供修正                                                               |
| saved 或已知 canonical target 的 saved_recovery_required | 消费提议，按实际结果继续                                                       |
| indeterminate                                            | 提议失效，沿既有管理冻结/恢复，不复活或重放                                    |
| 明确来源取消/删除，本表单从未发出 create                 | 清除凭据、保留公开字段并解除关联，提示转为普通 Add，由用户明确提交，不自动保存 |
| 仅 id 消失、create 在途/未知/成功，或原因不明            | 不自动转为普通 Add 重试，按创建结果或失效提示收口                              |
| Renderer reload                                          | 仅重新查看仍存在的公开提议，秘密输入丢弃                                       |

## 7 职责与实施顺序

| 切片         | Owner 与主要位置                                               | 完成标准                                                                                                |
| ------------ | -------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| A 输入正确性 | Renderer MCP 纯输入模块与 McpPage                              | 平台分词往返通过，手动/导入/Edit 保留原参数                                                             |
| B 通用接入   | Renderer 表单；Product MCP/Control；Bridge                     | 严格解析、逐项选择、已知凭据写前拒绝、create 回执和串行捕获；HTTP、header、env STDIO 到新 Task 调用通过 |
| C 进程诊断   | Application MCP platform/coordinator；Product MCP projection   | 安全区分未启动与启动后关闭，source/attempt 隔离，不改 ABI                                               |
| D Agent 入口 | Agent 固定工具；Product MCP 信箱；Bridge；Renderer composition | 提议可达、原子消费、并发关闭、snapshot 预算与旧 checkpoint 恢复通过                                     |

App 只做跨页 action wiring。公开草稿/提议类型放 shared projection 或 Bridge typed contract，Task feature 不 import MCP feature 内部文件。Agent 输入解码、Renderer 用户输入和 Product 最终校验各守边界，不建立通用 facade；仅有真实重复的纯语法才提取共享 leaf。

每片先保持产品可运行再进入下一层，A/B/C 不等 D。候选实现按最终工具名、结果、预算和交接方式核对，不把未发布旧内部路径当兼容合同。只对本轮涉及文件恢复既有 LF，核对忽略行尾差异的实质 diff 与普通 diff，保留其他任务改动，不批量格式化工作树。

## 8 验证与验收

### 8.1 必测场景

| 场景                                                            | 必须观察的结果                                                    |
| --------------------------------------------------------------- | ----------------------------------------------------------------- |
| Windows 盘符、UNC、空格、引号、末尾反斜杠；POSIX 引号与转义空格 | 正确分词和格式化往返，不破坏另一平台                              |
| 空参数、美元符号、反引号；无修改 Edit                           | argv 原样提交，无展开或重新分词                                   |
| JSON 错误、重复 key、超限、错误类型                             | effect 前拒绝，错误不含秘密/源片段                                |
| 混合多服务、同名服务                                            | 合法项逐个添加，无效项无 effect，不批量回滚或自动替换             |
| 未知字段、插值、SSE、disabled true/false/错误类型               | unsupported 明确；缺省/false 可添加；错误类型拒绝                 |
| autoApprove/alwaysAllow                                         | 提示未采用，工具权限不扩大                                        |
| Add 前查看、编辑、取消                                          | 无 child/network/credential read/browser effect                   |
| 无认证 HTTP、header HTTP、env STDIO、现有 OAuth                 | 正式 Runtime 完成认证、握手、工具发现与后续调用                   |
| 凭据分流、PORT 与参数重合                                       | 值只经专用路径；普通重合不误拒                                    |
| Host 已知凭据进入公开字段                                       | 所有创建/替换入口写前拒绝；已保存数据仅沿现有投影保护             |
| create 回执后外部 mutation；多 secret 捕获中取消/离页/变化      | id 来自回执，CAS 拒绝 stale，剩余值清除，无 create 或 secret 重放 |
| spawn 缺失/权限/无效；启动后 EOF/退出/npx 失败                  | 分类符合实际阶段，EOF 不伪造 exit code，不发布 stderr             |
| 旧来源、候选测试、晚到 completion                               | 不覆盖正式当前诊断                                                |
| 并发 tryPut、主线程 take 后再提议                               | 最多一个成功，待处理提议仍占名额                                  |
| 未 drain 即 shutdown，callback 与 close/join 并发               | 先关 ingress，callback 无需主线程响应退出，owner 静止后释放       |
| 来源取消/删除、用户关闭、late callback                          | 提议正确失效，不覆盖或复活；未提交公开表单按第 6 节保留           |
| create 成功后 reload 或旧 id 重交                               | 原子消费，旧 id 在 effect 前拒绝，不退回普通 Add 重复创建         |
| 提议接管前后新获知凭据                                          | 敏感提议不进 snapshot，失效释放名额，不用脱敏地址连接             |
| registry 与提议同时满额、最大转义、预算溢出                     | 分配覆盖真实上界，无静默丢提议，溢出明确失败                      |
| Run 超过 Tool 展示容量                                          | canonical 提议仍可查看，不改变记录政策                            |
| 旧工具集合 checkpoint 到新集合                                  | 官方 report 合法，Session/历史连续，无重放或扩权                  |
| 已发现未选择工具；选择后新建 Task                               | 前者仍待选择，后者实际收到一次目标 tools/call                     |
| 当前 Task 与冷重启                                              | 当前 Task 不热附加，持久配置/凭据正常恢复，提议与秘密输入不恢复   |

使用合成凭据扫描相关输出，不访问真实用户 Key。已知 Key 的 URL 样例须拒绝或停止提议；未知 URL 的风险不能被该负向测试掩盖。页面文案、fake Completion 或单个 fixture 不代替真实能力与平台证据。

### 8.2 执行入口

文档整理只检查链接、锚点、格式及 diff，不运行 runtime 测试。实施后按切片执行：

```text
npm --workspace @metawork/renderer run check
node --test scripts/mcp-page.test.mjs
node --test scripts/mcp-configuration-input.test.mjs

zig build test-mcp-configuration test-product-mcp-state test-product-mcp-policy test-product-mcp-view
zig build test-mcp-platform test-mcp-app
zig build test-product-mcp-runtime test-mcp-interop
zig build test-lifecycle
```

纯输入 suite 是实施时新增入口，不表示已存在或已通过。实际 Bridge/Task/workbench 变化追加对应 suite 和跨语言 fixture；Host Tool 验证严格 schema、容量、取消、shutdown 与正式 Native graph，扩展既有旧集合恢复 fixture，不能只测新集合自身恢复。

Windows x86_64 优先通过正式进程 owner、隔离 profile 和真实 MCP 调用验证；POSIX 纯解析可参数化测试，macOS 进程、OAuth、Keychain 仍须实际平台验收。其他已支持目标的编译、artifact 和发布责任不变。缺 canonical staged bundle 或 verifier 拒绝时明确失败，不跳过、改期望或弱化 guard 后报告通过。

## 9 合同更新与交付边界

实施按实际变更同步唯一真源，其他文档只链接，不复制规范：

| 真源                                                         | 更新范围                                                       |
| ------------------------------------------------------------ | -------------------------------------------------------------- |
| [产品需求](../requirements.md#510-mcp-服务)                  | 通用输入、认证与 URL 边界、Agent 提议和完成行为                |
| [UI 设计](../ui-design.md#54-mcp-服务)                       | 粘贴、结构化 argv、逐项选择、提议查看及安全诊断                |
| [Product 架构](../product-architecture.md#25-mcp-authority)  | 非阻塞信箱、关闭/取消、identity 回执和过程观察接纳             |
| [Renderer Bridge](../renderer-bridge-contract.md)            | create serverId、提议投影/关闭、凭据 generation 生命周期和预算 |
| [AgentCore 集成契约](../agentcore-integration.md#host-tools) | 固定工具、窄 capability、结果与恢复责任                        |
| [验证规范](../validation.md)                                 | 场景归属、完整调用、平台证据与剩余风险                         |

`app.zon` 只增加实际命令。无 AGENTS.md、Storage/registry schema、decision record、Core ABI 或 Native SDK 发布输入修改；仅真实改变稳定 module root 或依赖方向时更新工程结构/高层架构。

以下边界必须随交付明确：

- 只支持非敏感 endpoint。Host 保留 userinfo/query/fragment 等校验，并新增已知凭据写前拒绝；未知 path 凭据没有可靠通用识别，手动粘贴仍可能保存。这是剩余风险，不能声称机器全面拦截。
- MetaMind 仅作负向样例：当前说明要求普通工具先取 Key 再拼 URL，Agent 应明确停止；不做特例、不使用真实 Key、不未经验证断言服务端必须改造。通用 header/OAuth 配置若可用，按普通正向路径接入。
- 原始 stderr 及 npm 根因识别不在本轮交付；Windows 或合成 fixture 不关闭其他平台证据，也不关闭既有 MCP 来源隔离缺口。
- 方案批准不代表候选代码或外部服务验收通过；最终以每片测试、实际新 Task 调用及明确的平台限制为准。

完成条件是通用输入准确、参数保真、受支持凭据不经模型或公开配置路径、已知凭据拒绝有效、提交后才连接、失败可操作、Agent 入口可用、旧 Task 恢复无回退，且所有必须检查与剩余风险如实报告。

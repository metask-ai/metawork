# MCP 通用自动配置方案

日期：2026-11-06。状态：方向评审通过，已整理复盘与后续评审补充项；未实施。具体机制仍须由代码和验证兑现，最终真实服务与模型行为由用户验收。

## 1 目标与问题归属

用户在 Task 中提交 MCP 安装链接并表达安装意图后，MetaWork 自动理解说明、取得必要配置和凭据、保存连接、启动或连接服务，并使后续新 Task 获得工具。正常路径不要求用户搬运 Key、粘贴 JSON、点击 Add 或手动选择工具。确需登录、缺少必要信息或现有权限要求人工决定时，才进入对应交互。

```text
安装链接与安装意图
→ Agent 识别通用连接和认证要求
→ 正式安装工具及现有权限判断
→ Host 取得或接收凭据并保存配置
→ 正式 Runtime 连接、握手、发现工具
→ 保存本次发现工具的授权并发布新 Task authority
→ 报告安装结果；后续新 Task 可使用
```

当前 Task 保持创建时取得的工具集合，不热附加、不重建、不自动续跑；安装完成后新建 Task 使用新工具，这符合用户已确认的使用方式。

### 1.1 复盘结论

主要缺口属于 MCP 产品接入能力：现有入口只能提交非敏感建议，不支持含凭据的 endpoint，不能完成上述流程。即使 Agent 完全遵守现有限制，也只能更快说明无法安装，不能实现用户目标。没有调用 MCP 入口，不能证明问题不属于 MCP；缺少可用入口本身就是产品能力缺口。

Agent 已知限制仍承诺安装、取 Key 和查找其他客户端配置，是独立的执行错误，解释了为什么过程变得冗长。正式工具描述不能控制所有通用工具，增加禁止文字也不能代替可用的安装能力。本次修复直接相关的工具使用和结果表达，不将所有无效探索归因于 MCP 协议实现。

上一轮方案补齐了配置互通，却把触发本次讨论的安装方式排除为负向样例；其选定范围通过不等于用户安装需求解决。本轮此前草案还存在查询可能反复审批、Stop 仅停止等待、跨 Run 意图与 full_access 授权不明确、预算未贯通的问题。本版分别以单次有界工具调用、主动取消、目标绑定的历史用户证据、产品授权状态和完整阶段预算收口。

本方案新增一条可完成任务的正式能力，同时收口直接相关的 Agent 工具使用；不扩展通用 Agent 规划、审批机制或任意软件安装器。

## 2 范围与既有方案关系

支持现有 STDIO 和 Streamable HTTP：包括 npx、uvx 或已安装可执行文件的结构化启动配置，公开远程 endpoint，environment/header static credential、敏感 endpoint 和既有 OAuth。命令始终分为 executable、ordered argv、可选 cwd，不引入 shell string 或任意安装脚本执行器。原有协议版本、Tools 范围和外部依赖接受规则继续由真源约束。

Agent 理解不同网站的自然语言与配置说明；MCP 模块消费统一结构化请求。不按域名适配 MetaMind，不硬编码取 Key 接口，不假设任意网页都存在标准安装协议。无法表达或缺少证据时返回具体原因，不猜另一套 endpoint，也不转去改其他客户端配置。

[MCP 通用配置接入与管理方案](mcp-configuration-interoperability.md)记录上一轮输入互通、参数保真和诊断方案，本次保留那些已交付能力。其“仅提议、用户 Add、手动选工具、MetaMind 作为负向样例”的边界是本次需要改变的部分，不再作为本次完成条件；不改写旧方案以伪造其当时范围。

本文是实施方案，不是 decision record，不改变尚未更新的领域合同。当前请求只产出方案；代码、真源合同和依赖发布输入在实施时按第 11 节同步。

## 3 成功语义与用户流程

### 3.1 完成条件

`ready` 只能在同一安装目标上证明以下全部事实后发布：配置与所需凭据已确认持久保存，正式 Runtime 已接管正确版本，握手及工具发现成功，本次工具授权已确认持久保存，当前 Admission 已发布相应新 Task selection。

保存成功、隔离 Test 成功、`runtimeAlignment = current`、工具数量大于零，均不能单独代表安装完成。服务握手成功但没有工具时返回 `no_tools`，说明当前没有可供 Task 使用的工具，不报“已可使用”。真正的工具调用仍可能受其独立权限或远端业务条件限制。

首次自动安装以一次成功 discovery 得到的精确工具集合为授权集合，不保存 wildcard，不允许以后新发现工具自动扩权。后续刷新只能继续使用已保存集合中的合法工具。每次调用继续经过既有 AgentCore 权限语义，配置授权不等于免审批。

授权与首次发布串行化：先准备精确集合对应的 candidate selection，再持久保存授权，确认成功后安装 Admission。目录已变、TTL 不足、配置已被用户编辑或停止时重新观察或明确失败，不把旧目录工具套到新目标上。结果不确定时不发布 `ready`。

### 3.2 UI 与交互

来源 Task 的状态卡片和 MCP 页面消费同一 Host operation 投影，显示准备、等待必要输入、连接、发现、完成或具体失败。普通进度不要求点击，不依靠解析 Assistant 或工具文本生成产品动作。

缺少用户凭据时，卡片提供专用 password 表单，经现有领域凭据入口提交；OAuth 使用同一 server-bound Host 授权流，卡片只提供启动或继续入口。秘密不进入普通 Composer、卡片 metadata 或模型消息。卡片关闭只隐藏卡片，不取消安装。来源 Run 的主动 Stop 和卡片的显式“取消安装”都撤销未完成安装；Run 正常结束后仍可通过卡片取消，具体边界见第 7.3 节。

手动 MCP 页面继续可用，敏感 endpoint 使用显式 password 输入或敏感模式；不回填已存秘密，只允许保留或替换。普通公开地址仍可明确输入和编辑。Agent 路径按第 5 节采用更保守的地址处理。

## 4 Owner 与正式入口

| Owner                         | 本次职责                                                                                                                         |
| ----------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| Agent                         | 注册工具、严格解码、验证 RunContext、接收无秘密结果、维护可取消的 callback wait；不持有 Product 状态或执行系统 credential effect |
| Product MCP / Product Control | 安装 operation、授权和目标身份、事务与恢复、敏感字段语义、工具集合和新 Task authority                                            |
| Application                   | 有界凭据 HTTP 获取、系统 credential storage、进程与连接 effect、OAuth 和 coordinator；只执行 Product 已批准的目标                |
| Renderer / Bridge             | 状态投影、必要的安全输入与人工权限操作；不解释网页、不建立另一条安装协议                                                         |

### 4.1 工具与结果

以固定 Host tool `InstallMcpServer` 替换 Agent 的 `ProposeMcpServer`，不增加 `GetMcpInstallation` 或 Agent 进度轮询接口。fresh 与 restore 的集合、checkpoint 接受测试一起更新。不得为此绕过官方 SDK 或建立 Agent 调用 Bridge 的通道。

安装请求包含显示名、安装来源、完整 typed transport、认证计划和本次目标。认证计划仅包含公开的取值规则、模板或待填槽，不接收 secret value、credential locator、工具 allowlist 或模型声称的“用户已批准”。来源与 Task/Run 身份由 Host 验证，不信任模型提供身份。初始输入及 owned 编码沿用 32 KiB 工具预算，字段预算复用现有连接和 credential limits。

新建接纳后返回 Host 生成的稳定 `installationId`；修正或重试必须携带该 id 与 `expectedRevision`，更新已关联的 `serverId`，不重新创建。对既有独立服务的更新必须指定精确 `serverId`，证明用户意图并校验 generation，不按显示名或域名猜测替换对象。

结果是结构化、无秘密的 `installationId`、可选 `serverId`、revision、phase、稳定 reason、恢复动作及新 Task 可用事实。具体阶段为 `preparing | needs_input | needs_authorization | connecting | discovering | authorizing_tools | ready | no_tools | failed | interrupted | cancelled`。`needs_*` 是等待条件，不伪装成失败；`in_progress` 只作为工具等待到期的响应，不作为持久终态。

工具结果只返回当前 operation 的安全事实，不返回原始响应、秘密、完整敏感 URL 或内部 credential 引用。等待超时后普通进度由 Product 投影直接更新，不通过再次调用安装工具查询，也不新增 Product 对某个 Host tool 自动放行的机制。用户明确修正或重试时，原安装 id 只是精确目标引用，不构成新的执行 authority。

### 4.2 接纳与重复请求

沿用现有单槽交接及 MCP mutation/apply 串行 owner，不另建调度框架。callback 非阻塞提交 owned 请求；竞争或未接纳时返回 `busy`，不产生 effect。已接纳 operation 的内存和持久状态不由 callback 生命周期拥有；来源 Run 正常结束时可继续，主动 Stop 则按第 7.3 节取消。主线程只做状态与事务推进，网络和存储 effect 在既有 worker 边界执行。

同一 Run 中重入的相同初始请求复用 Host 保存的接纳记录和安装 id，不重复创建或再次取凭据；不同内容不能借此取得原批准。这个去重只限定同一可信 Task/Run 和完整请求，不把名称或地址相似视为同一个请求。跨 Run 修复使用精确安装 id；跨重启使用已持久记录，不声称 SDK 的 RunContext 提供了实际不存在的 tool-call id。

## 5 凭据与敏感 endpoint

### 5.1 Host 获取

凭据获取计划使用有限、声明式结构：`sourceUrl`、`method = GET`、`jsonPointer`、目标槽和由 literal/slot 片段组成的输出模板。JSON Pointer 只做 RFC 6901 字段定位，不支持脚本、任意 JSONPath 求值、shell、正则替换或执行响应内容。Header 模板负责明确的 Bearer 前缀，不自动猜测。

初版只自动执行 GET 获取；需要 POST 发放、guest claim、下载后运行或其他有副作用操作时不能伪装成 GET 重试。Agent 应说明缺少何种已支持能力，或沿现有权限和独立操作完成；本方案不增加通用 HTTP 编程语言。GET 方法本身不证明业务幂等，响应丢失或结果未知时不自动再次取 Key；必须有可靠的无副作用依据，或由显式重试动作重新接纳。

Application 仅为当前已批准安装执行 HTTPS 获取；不携带 Account/模型 provider 凭据、不继承浏览器 Cookie、进程环境或任意已有 secret。初始请求不自动跟随重定向；如服务必须跳转，作为新的实际目标重新校验并批准，不自动转送 header/credential。响应最多 64 KiB，单次 deadline 30 秒，目标字符串必须符合实际 credential storage 上限。非 JSON、重复字段、缺失或非字符串字段、超限均为 typed failure，不回显 body。原始 URL、response、解析值和派生完整 endpoint 只存在于对应 Host owner 的有界执行副本，使用后清零释放。

取得值后直接写入系统凭据库、组装运行时输入，结果只报告槽已满足或具体失败。Agent 不先用 Bash/WebFetch 取 Key，不要求用户贴 Token 到 Composer。把值先写普通临时文件、只传路径，不是本方案的凭据通道。

### 5.2 来源与目标授权

模型填写的 source/target 只是待执行请求，不能生成授权。Host 从同一 Task 的真实用户输入取得安装来源与意图证明，精确绑定本次获取地址、凭据接收目标、transport、STDIO 命令和持久 effect。证据可以跨 Run：例如 Run 1 提交链接、Run 3 说“开始吧”可以共同表达同一次安装；不要求后一轮重复链接。工具权限上下文必须展示这些 Host 校验后的事实及“后续启动会重连/运行”，而非只展示显示名。

现有 `currentReviewIntent` 提供当前 Run 意图，`appendReviewHistory` 已补充有界历史用户消息；本次补的是与安装目标绑定的证据选取，不重建一套全量历史审批。Host 记录相关用户消息/输入的稳定引用及目标版本，并在提交和 effect 前核对仍有效；模型引用消息只能作为候选，不能自证用户授权。优先选取相关用户指令及其后的修改、取消和拒绝，不能只取一条早期允许而遗漏后来的撤销。引用、网页、工具结果和 Assistant 的承诺不变成用户授权。

“当次安装意图”指当前仍有效的这次具体安装，不等于当前 Run 的最后一句话，也不等于整个 Task 的长期通行证。有多个候选目标、“开始吧”无法消歧、原始指令不可读或证据预算不足时，进入 `needs_authorization` 明确缺口；不臆测窗口之外的授权，不要求模型重新读私有历史文件。

相同 origin 的请求仍经正常权限判断；相同注册域或子域不自动成为可信依据，不为此增加 Public Suffix 信任规则。凭据源与使用目标跨 origin，且不存在用户对这组具体目标的有效人工授权时，安装进入 `needs_authorization`，明确展示“从 A 获取凭据并用于 B”，自动评审不能独自建立该授权。已有有效的精确人工授权不再重复询问。OAuth 的授权服务器与 resource 绑定沿标准 Host flow 验证，不套用模型 GET 模板。

`approval_required` 下优先复用能完整表达该 effect 的现有人工权限请求；该人工决定必须由可信的 request identity、实际选择及目标绑定证明，不能从模型返回“已批准”推断。`full_access` 可能不产生 Core 权限回调，不能据此视为跨站已批准：同样保留 `needs_authorization`，通过来源 Task/MCP 页的产品安全授权卡取得本次精确决定。两种模式消费同一个 Product 授权事实，任一模式都不得在授权前获取或转送这组凭据。授权卡不是重新引入普通 Add 确认，不授予整个 origin 或未来安装通行权限。

新工具 effect 说明要进入既有审批上下文。STDIO 安装授权涵盖完整 command、ordered argv、cwd、所需槽和自动启动事实，且必须有上述当前仍有效的用户安装意图；网页中的“立即安装”“自动批准”不提供 authority。继续区分 AgentCore tool permission 和 Product effect：用户取消、目标变化或旧审批失效后，Host 必须在 effect 前拒绝。现有 profile 的普通权限语义保持不变；本节跨站凭据授权是 Product 安装前置条件，不新增隐藏权限档位或把 full_access 静默降为另一 profile。

安全获取 URL 本身可能含访问材料，应同样在 Host 私有记录或 credential 槽中保存；公开记录只持 origin、用途和状态。用户原始提交的个人安装链接或自行输入到 Composer 的秘密已经进入对话，不能声称本功能会逆向消除；正常流程不再把取得的 Key 或拼接后的敏感 URL送回模型。

### 5.3 用户提供与安全引用

缺少自动获取方式时，先建立有身份且无运行资格的安装目标，再发布绑定 `installationId + serverId + revision + slot` 的安全输入请求。password 表单经专用 typed command 交给 Host，复用 credential journal；输入只在本地有界生命周期存在，不通过 tool result 或普通 Task 消息转发。

已有秘密只可沿 Host 验证过的同一目标和槽保留；不允许 Agent 任意枚举 credential store、传入系统 locator 或借另一服务的凭据。安全输入请求取消、目标变化、外部编辑、断连或结果未知时清空未提交内容，不从 snapshot 自动重放。

### 5.4 endpoint 表达与保存

持久 endpoint 区分公开 literal 和敏感 endpoint reference。Agent 路径提交的完整 HTTP endpoint 默认整体按敏感材料保存，至少 path/query 不进入公开 projection；UI 展示 scheme、host、port 和状态，不展示完整路径。手动输入可明确选择敏感模式。URL query 作为合法地址组成部分纳入能力；继续拒绝 userinfo、fragment、非法 authority、控制字符和不受支持 scheme，不靠 `api_key` 等名称猜敏感性。

明确的凭据模板保存无秘密 literal 和 slot reference，建立连接时由 Host 解析槽并拼接；完整敏感 URL 使用整体 credential 槽。二者是同一 endpoint 表达中的实际输入形式，不是两套安装流程。模板 literal、sourceUrl 及错误文本也须经过敏感输入处理，不能因字段名叫 template 就视为公开。

registry、Snapshot、卡片、日志、错误、permission preview 和工具历史均只能发布安全表达。Agent 对已知敏感字段的事件投影在进入 Product 记录之前清洗，不能等持久化后再处理。完整敏感地址的编辑不回显旧值，credential service 不可用时明确失败，不降级为明文 URL。

必须区分 Host 记录与 AgentCore 私有 Conversation：当前 canonical `HostToolV1` 没有敏感入参标记或回调后删除历史参数的 API。默认敏感存储能保护 Host 配置及公开投影，不能抹掉模型已生成的未知秘密。正常协议使用 Host 取得的槽与安全引用使秘密不经过模型；不能宣传“任意模型错误入参也绝不进入 Core checkpoint”。若实现或验收需要强制保证后一项，必须先按正式依赖流程取得上游能力并登记缺口，不能 patch bundle、解析私有 transcript 或用 Host 清洗测试冒充 Core 保证。

### 5.5 连接身份与 OAuth

Product connection approval、Runtime descriptor、Task restore 和 OAuth 必须消费同一 Host-owned endpoint identity。敏感 URL、secret-derived digest 不得进入 AgentCore `configuration_fingerprint`；canonical SDK 明确禁止这类输入。

公开目标或无秘密模板、Host 分配的非秘密 endpoint identity、接收目标和已验证的 principal epoch 构成连接来源事实。更新仅在能证明目标和 authenticated principal 不变时视为 credential rotation；无法证明时推进来源身份，重新批准/应用并按现有 Session 来源约束处理，不仅因为 origin 一致就保留旧授权。整体敏感 URL 替换默认属于目标变化。

OAuth 的 resource、issuer、discovery 与 refresh binding 继续遵守既有精确绑定语义。不能把敏感 endpoint 的公开展示 origin 当成 OAuth resource，也不能把带秘密的 URL 写入 consent metadata。需要保存的敏感 resource 使用 Host 私有安全引用，建立真实请求时解析；授权范围或 endpoint 变化按现有重新授权合同收口。

## 6 安装操作与可靠完成

### 6.1 状态和持久事实

Product MCP 持有有界安装记录，使用同一 registry 事务表达 server identity、安装 id/revision、来源 Task identity、目标配置版本、首次工具授权是否待完成、阶段和稳定失败原因。必要的安全获取计划或完整地址只保存 credential 引用；不新建独立安装数据库或另一份 desired 配置。

在任何外部 effect 前先确认最小安装 intent 和目标身份已持久保存。凭据 journal、Desired commit、正式 apply 和授权提交分别保留真实边界；不声称存在横跨网络与磁盘的原子事务。Operation 的 terminal summary 随对应服务保存；只保留当前活动/最近安装记录，容量按现有 server 容量约束，不建立无界任务账本。

重启时根据 registry、credential journal 与真实 Runtime 重新观察：已保存且安全就绪、未被停止的目标沿正常启动 apply 继续连接；纯等待用户输入不制造自动任务；需要重新获取的材料仅在既有批准和可验证的安全重试语义下继续，不能只因方法为 GET 就重发。主动取消标记先于继续安装规则判断，不因已有配置或凭据而续装。未确认的非幂等 effect、凭据提交或 outcome unknown 进入恢复状态，不自动重放。Runtime-only 连接阶段不作为重启后的成功证明。

### 6.2 首次工具授权跨退出恢复

自动安装意图持久包含一次性的 `initial_tools_pending`，绑定精确 server/endpoint identity 和已批准安装。首次 discovery 后把精确工具集合、状态变更和 pending 消费作为同一次 Desired 提交；确认后才发布 Admission 和 `ready`。

若退出发生在提交前，重启后可以对同一绑定重新 discovery 并完成这次初始授权；不是每次启动自动放行。提交已成功而 completion 未消费时，由 canonical registry 确认已完成，不再次取新集合。首次提交后后来出现的新工具保持排除。

用户 Edit、Disable、Delete、手动选择工具、主动 Stop、取消安装或改变授权目标时，事务性消费/撤销 pending。过期、来源不匹配、已经取消或不可确认的 intent 不能恢复为自动授权。这样正常退出不会丢首次授权，主动取消后不会续授，也不会撤销用户后续限制。

### 6.3 失败、修正和并发

安装失败保留同一 server 和具体原因，作为等待显式修正的状态，不让失败目标在每次无关 mutation 中重新连接。修正沿 `installationId + expectedRevision` 更新并重新批准实际改变的目标；结果未知先读取恢复，不重复 create，不按名称去重，不回滚覆盖用户后来的修改。

同目标的迟到凭据、apply、discovery 或授权 completion 必须核对目标 revision/source identity。外部编辑或 Delete 使旧 completion 失效；与其他成员的无关变更不应丢失已确认安装结果，也不借最新全局 generation 盲目重试。继续由现有 MCP owner 串行化 mutation/apply/OAuth，普通 Text Task 不因此被全局阻塞。

网络或握手失败不自动重放服务工具调用，也不反复执行未知安装脚本。用户显式修正后沿同目标重试。与失败目标关联的配置及凭据不静默删除；显式取消/删除沿现有资源与 journal 规则回收。

## 7 等待、停止与 shutdown

### 7.1 两种 deadline

一次 `InstallMcpServer` 调用默认最多等待 10 秒，绝对 deadline 不因进度或唤醒重置。若已达到终态或需要用户输入/授权，直接返回相应事实；否则超时返回 `in_progress` 和当前已接纳 id，不把正在进行的安装判为失败，也不重新提交安装。

返回 `in_progress` 后，Agent 如实报告正在配置并结束当前安装步骤，不调用查询工具或重复调用安装工具来等结果。Run 正常结束时 MCP owner 继续推进，Task 卡片与 MCP 页面自动呈现终态，不自动启动一个 Agent Run，也不为普通进度发起新的工具审批或审批模型请求。模型正文的旧“进行中”消息不自动改写，卡片显示最新真实状态。

安装自身使用独立的阶段预算：首次 STDIO 启动到首次握手允许最多 180 秒，以涵盖 npx/uvx 冷缓存；HTTP 和后续目录请求沿现有连接管理有效上限，所有执行阶段共享最多 300 秒总执行预算。等待用户输入/OAuth 不占用 callback 或执行 worker，也不消耗该执行预算；恢复时重验资格，以剩余额度建立阶段绝对 deadline，不把总额度重置为 300 秒。进入新阶段或重复唤醒都不能无限续期。工具等待 deadline 与安装执行 deadline 独立。

180 秒不能只写在外层 timer：当前 `max_management_timeout_ms` 为 120 秒，默认 descriptor/request timeout 为 30 秒。实施须贯通 Product 的安装阶段预算、AgentCore descriptor 和实际请求/取消 deadline、`mcp_catalog_budget.zig` 的 `open/request`、底层进程/transport 与 candidate 总预算，使首次启动不会先被内部 30/120 秒截断。正式 Runtime 一次新成员安装与隔离 Test 的预算不能混用；安装完成后解除首次启动预算。

现有普通管理上限和普通工具调用的 timeout 不整体放宽。以明确的安装阶段 scope 提供所需预算，`toolRequest` 继续原样使用该请求配置，不继承候选安装剩余时间。若 Core 自身先于 Host 到期，必须通过 canonical public 配置支持正确预算，不能仅延长 wrapper 等待冒充修复。预算由 Product MCP contract 唯一定义并投影，测试直接观察实际传入值和冷启动行为。

### 7.2 独立等待对象

callback 只持有引用计数的安全 operation observation 和本 Run 的 cancellation token，不持有主线程对象、Session mutex、管理锁、credential 副本或等待期间的 catalog lease。每个等待对象有自己的 mutex/condition，关闭标志与 revision 都在同一锁内检查，等待前后重验，避免丢唤醒。

Product MCP 保留来源 Task/Run 到未完成 operation 的取消关联和独立 token，寿命延续到安装结算，不随 10 秒 callback 返回而释放。Host 停止入口按可信来源身份直接设置该 token，Agent termination 路径也可通过冻结 capability 传递已验证的终止原因；两者作用于同一取消事实，不保留裸 Session 指针。这样 callback 已返回但来源 Run 仍在运行时，用户 Stop 仍能取消安装；Run 正常结束则仅释放其运行期引用，不取消 operation。

三个事件可直接结束等待：结果到达、本 Run termination、安装入口 shutdown。阶段变化可以更新 observation，但不延长等待。三个结束事件都必须能从当前执行线程设置 sticky flag 并 broadcast，不依赖主线程 drain 或 UI 回答。实现时在 Agent 的统一 Run termination 路径和 Host ingress close 中接入该唤醒；有限 deadline 是最后界限，不能替代主动唤醒。是否取消安装依据可信的 termination reason 判断，不能把所有 callback 释放或 Run 结束都当成用户 Stop。

锁序固定：不在 Session 锁内取得 operation wait 锁或调用 Product；取消先记录状态、释放 Session 锁，再通知 waiter。主线程写入安全 observation 后释放锁再唤醒。关闭入口先同步标记关闭并解除所有 waiter，再 join apply/executor，最后释放 operation owner。callback/result 由现有 paired release 恰好一次释放。

### 7.3 Stop 的含义

Run 正常完成与主动 Stop 明确区分：正常结束不撤销已经接纳的安装；用户主动 Stop 立即对该来源 Run 关联的未完成安装设置 cancellation fence，解除 callback 等待、阻止尚未开始的获取/启动/连接/工具授权，并请求取消在途工作。不能把“已接纳”当作忽略用户 Stop 的理由，也不要求用户再点一次取消卡片。

每个阶段在 effect 前与 cancellation fence 同步检查，并明确阶段接管的线性化点。Stop 先于接管时不得执行该阶段；接管先于 Stop 时取消在途工作并按真实结果结算，不声称远端请求、已完成的磁盘提交或已执行命令被回滚。取消信号应在 worker/transport 中直接生效，不等待主线程才阻断后续工作；持久状态由 Product 主线程按同一取消事实结算。

首次工具授权提交和 ready 发布也必须与取消 fence 对账。已开始的提交无法撤回时，按提交事实结算后执行停止事务，不能把取消后的迟到成功发布为 ready。新安装服务尚未 ready 时，停止决定与 `initial_tools_pending` 撤销、目标 disabled 状态一起提交，确保下次启动不因已保存配置而续装或运行。安装拥有的候选进程/连接按既有 owner 取消并关闭。修正既有服务时，只处理本次候选与待提交授权，不能误删旧配置、撤销其他用户已确认的工具或强制释放仍被合法 Task 持有的连接。已经发布 ready 的服务不因后来无关 Run 的 Stop 被卸载，用户通过正常 Disable/Delete 管理。

来源 Run 已正常结束后，状态卡仍提供精确安装 id 的“取消安装”，采用相同 cancellation fence 与持久语义。Task 删除、服务 Delete 同样阻止后续安装阶段；等待安全输入或授权的请求立即失效，迟到提交不得继续安装。停止结果只有在持久状态确认后才报告 `cancelled`；写失败或结果未知显示待恢复，不宣称取消已保存，也不重试已经停止的 effect。

Application shutdown 与用户主动取消不同：先关闭入口并唤醒 callback，再取消/join 当前进程工作，重启按第 6 节及持久停止事实恢复。测试须分别覆盖正常结束、主动 Stop、卡片取消、Task 删除和 shutdown，并证明主线程故意不 drain 时 callback 仍能退出、未接管的阶段不会启动，而不仅是测 10 秒后自然超时。

## 8 Agent 行为与通用安装范围

工具说明同步改成正式安装语义：先理解网页，形成结构化请求，把秘密获取交给 Host；根据 operation 的事实报告，不把“已接纳”说成“已安装”。10 秒后未完成时由卡片承接状态，不增加 Agent 查询循环。需要用户明确修复时携带原 id，不查找 Codex、Claude 或 MetaWork 私有文件，也不声称当前 Task 已取得新工具。外部安装页要求“先征求同意”只是参考说明，不能自行增加产品确认步骤或生成授权；实际意图依据同一 Task 的有效用户指令判断。

这是直接服务安装链路的工具合同和可信权限上下文，不另建意图识别模型或按域名拦 Bash 的规则。任意通用工具中未知秘密的检测和通用规划能力不因本次新增工具就被宣称解决。

MetaMind 使用通用 GET 提取、endpoint 槽注入和远程连接，是一个正向验收样例。除此之外必须覆盖公开 HTTP、Header credential、带 query 的 endpoint、environment credential STDIO、npx 冷缓存和 OAuth。支持同一条通用链路，不为样例保留专用 active path。

## 9 持久格式与旧链路收口

registry 在现有 schema 2 基础上增加 endpoint 安全表达与安装恢复事实，实施时提升 schema 并编写单向迁移。保留既有 server identity、namespace、凭据引用、批准与工具选择；旧配置不因迁移自动扩权。已存公开地址按原语义迁移；用户主动转为敏感模式时再安全替换，不猜测或静默改写历史含义。迁移失败保留原件并明确 recovery，不用空配置覆盖正常数据。

删除失去职责的 `ProposeMcpServer` 注册/执行、提议卡片、`context.mcpInstallation` 提议数据、`proposalId` create 关联、`metawork.mcp.dismissInstallProposal`、notice 和专属 fixture。Task 中的新 operation 状态卡取代旧建议卡，不保留两套活跃安装路径。手动 Add/Import/Edit 保留，复用相同 endpoint、凭据和正式连接能力，不自动继承 Agent 安装的工具授权政策。

旧 Host tool 集合进入已有 Conversation/checkpoint 的接受政策必须沿官方 SDK 验证；不能假设改 allowlist 就能无损接受旧记录。保留可读产品历史，不重放旧工具、不手改 checkpoint、不伪造旧工具成功。需要兼容的持久数据和旧会话消费按真源明确迁移或 degraded 行为，并以 canonical Core 回归确认。

## 10 实施顺序与验证

同一个 PR 以可运行切片推进，合入条件是通用路径闭环；中间切片不作为用户完成验收：

| 切片                     | 可验证交付                                                                                         |
| ------------------------ | -------------------------------------------------------------------------------------------------- |
| A endpoint 与凭据        | 安全表达、query、系统存储、迁移、指纹/OAuth 与真实 transport 接线；手动路径仍工作                  |
| B Product 安装 operation | 稳定身份、同目标修正、阶段预算、首次工具授权与跨退出恢复                                           |
| C Agent 工具与生命周期   | 单一 install 接口、跨 Run 意图证据、可信权限上下文、有界等待、主动取消与 shutdown 唤醒、旧链路收口 |
| D UI 与整体验证          | 状态卡、安全输入/OAuth、MCP 页、必要 Bridge 合同、完整安装到新 Task 工具调用                       |

自动化用合成秘密和本地受控 fixture，保护下列真实失败模式：

| 场景                                                                      | 必须观察的结果                                                                    |
| ------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| 公开 HTTP、静态 Header、GET JSON 字段、路径/query 注入、environment STDIO | 正式链路落地；新 Task 调用到对应真实 fixture server，而非只检查 parser 或页面文案 |
| 原始响应异常、超限、重定向、跨目标凭据传递、审批拒绝                      | effect 在正确边界停止，无秘密返回或盲目重试                                       |
| 初次工具集合、随后新增工具、用户手动撤销                                  | 仅初始精确集合可用；新增不扩权；用户撤销不被恢复覆盖                              |
| Stop、Task 删除、shutdown 与结果同时到达；主线程不 drain                  | callback 及时退出，paired release 恰好一次，owner 静止后才释放，无死锁            |
| 持久提交前后强制退出、授权 commit 成功而回执丢失                          | canonical 恢复不丢首次授权，不重放获取/创建，不二次放行新集合                     |
| 保存、credential journal、apply、discovery、授权提交分别失败或未知        | 结果准确，配置不重复，旧用户修改保留，不假报 ready                                |
| npx/uvx 冷缓存与正常握手失败                                              | 阶段预算有效，等待超时不误报安装失败，真实 spawn/握手原因可见                     |
| 来源/目标、endpoint/principal 变化、整体敏感地址更换                      | 重新校验批准、指纹、OAuth 与 restore，不把秘密 hash 送入 Core                     |
| 已有手动服务、schema 迁移、历史 Task、旧 checkpoint                       | 不丢数据、不隐式放行、不重放旧工具，fresh/restore 工具集合符合官方接受语义        |
| Renderer reload、断连、安全代次变化、窄窗和键盘操作                       | 输入及时清除，迟到响应隔离，状态与恢复动作来自 Host                               |

本次复盘追加的定向反例须纳入上述 owner 的最小充分 suite：

| 场景                                                                  | 必须观察的结果                                                                    |
| --------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| 安装超过 10 秒，分别使用人工和自动审批                                | 安装工具只调用一次；状态卡继续变化；没有进度查询审批或额外审批模型调用            |
| 链接在 Run 1、确认在 Run 3；旧允许后有取消；多个安装链接              | 正确关联同一次安装，后续取消生效，歧义不自动选目标；不把网页或 Assistant 当作授权 |
| full_access 下跨站且无精确人工授权；授权后目标变更                    | 进入 needs_authorization，授权前不取/传凭据，旧决定不能批准新目标                 |
| Stop 分别先于取凭据、spawn、apply、工具授权接管，及各自接管之后       | 前者没有 effect；后者取消并如实结算，不再启动下一阶段                             |
| 主动 Stop 持久成功后重启；正常结束后重启                              | 前者不续装、不自动运行/授权；后者在安全条件下继续，二者不混同                     |
| 180 秒冷启动经过 descriptor、Core 请求与 transport/candidate deadline | 没有内部 30/120 秒提前截断；普通管理和 toolRequest 仍保持原 timeout 语义          |

秘密检查分别覆盖 registry/journal、Product history、Bridge/Renderer projection、日志及本次正常 Host 获取路径的 Core checkpoint。对模型已经提交秘密的反例单独报告上游边界，不用“Host 输出没出现秘密”代替 Conversation 验证。

按 [验证规范](../validation.md)选择对应 Product MCP、Agent lifecycle/Host tool、Bridge/Renderer suite 和当前平台正式 Native graph；当前可用入口包括 `test-product-mcp-runtime`、`test-mcp-interop`、`test-lifecycle`，新增入口必须接入正式 test graph。共享 Session/工具集合变化运行正式 Native 测试。缺 canonical staged bundle 明确失败，不跳过 AgentCore 用例报成功。

最终真实验收由用户执行：在 `npm run dev` 重启后的新版本中，向普通 Task 发安装链接并表达安装意图；不搬 Key、不粘贴 JSON、不点击 Add/Choose tools，看到真实配置结果；随后新建 Task 调用对应 MCP 工具。MetaMind 是其中一个样例，不是唯一完成标准。需要真实登录或权限决定的场景只出现必要交互。执行方完成自动化、自查及可运行版本交付后标记“待用户验收”，不替用户作最终通过结论。

## 11 实施时同步的真源

| 真源                                                         | 本次需要改变的合同                                                                                           |
| ------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------ |
| [产品需求](../requirements.md#510-mcp-服务)                  | 自动安装代替仅建议、敏感/query endpoint、首次精确工具授权、必要交互、新 Task 可用                            |
| [Product 架构](../product-architecture.md#25-mcp-authority)  | operation owner、持久阶段、跨 Run 意图绑定、跨站授权、主动 Stop、阶段预算、恢复与 Admission 发布             |
| [AgentCore 集成契约](../agentcore-integration.md#host-tools) | 单一安装工具、Run capability、状态结果、可取消等待与终止原因、fresh/restore、实际请求预算和官方 API 边界     |
| [Renderer Bridge 合同](../renderer-bridge-contract.md)       | 安全 operation 投影、Task 安全输入、full_access 下产品授权、取消安装、OAuth 关联、旧 proposal 数据与命令移除 |
| [UI 设计规范](../ui-design.md)                               | 自动安装状态卡、必要认证和权限展示、敏感地址、安全输入生命周期、MCP 页结果                                   |
| [验证规范](../validation.md)                                 | 安装到新 Task 调用、取消/退出、恢复、秘密边界和用户最终验收责任                                              |
| [app.zon](../../app.zon)                                     | 仅实际增删的 Bridge command；保持 manifest、Zig、TypeScript 一致                                             |

不为本方案单独修改 AGENTS.md、Native SDK 或 AgentCore bundle。若实现发现 canonical public API 无法兑现必要合同，先登记具体缺口和所需发布输入，不用本地 patch、源码复制、静默 fallback 或削弱 verifier 解决。

## 12 评审收口条件

实施评审必须确认：新 Task 可用不是空允许列表；普通进度不触发 Agent 查询审批；等待不依赖主线程才能取消；主动 Stop 真正阻断后续阶段且不在重启后续装；跨 Run 用户证据准确且遵守后来的撤销；跨站授权不因 full_access 被跳过；path/query 不落公开字段；正常凭据路径不经过模型；安装与首次授权可跨正常退出恢复；180 秒预算贯通到真实请求而不改变普通 toolRequest；重试不创建重复服务；旧提议链路只有一处正式替代；用户最终验收仍是通用安装链接到实际使用。

方向评审通过不等于实现、外部服务或模型行为通过。本文所有新增状态、数字预算和工具名均为待实施设计，后续由唯一类型、机器输入或对应领域真源拥有，不在多个文档复制实现清单。

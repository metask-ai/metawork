# MetaWork 消费的 Metask Account API 合同状态

> 状态：**C1 OAuth 登录与无 Profile-ID 的 C2 API Key 通用路径已通过生产服务复核**
> 日期：2026-08-10
> 范围：MetaWork Account 的 OAuth/account lifecycle，以及后续 API Key/model/ExecutionTarget

## 1. 边界

登录与执行配置是两个独立门槛：

- **C1 登录**：OAuth、token rotation、严格 `/me` identity、token 恢复/刷新、退出和本地安全存储。当前信息已经足够实现，不依赖模型、API Key 或 AgentCore。
- **C2 执行配置**：Metask API Key catalog、model catalog 和 typed/fixed `ExecutionTarget { provider_kind, base_url, model }`。Account 只原子持久化无 secret 的默认选择；完整 ExecutionConfig 和 Metask Provider API Key 始终留在当前进程。Workbench 安装对应 generation 后才能创建 Agent Task。
- **Model Connection 扩展**：用户管理的 OpenAI Chat Completions 或 Gemini Native 连接使用独立的 typed connection registry 与 credential store；它不改变 C1/C2 的 Metask identity、catalog 或 fixed endpoint 合同。Anthropic Messages 保留为 AgentCore 能力候选，但在原生 API Key 鉴权合同通过前不进入产品 admission。

MetaWork 只作为 Metask Account API 和 AgentCore bundle 的消费方。本文档不要求、也不授权修改 Metask 内部实现仓库（精确路径标识为 `cc-t2z/metacodes`）。

## 2. C1 已锁定的生产合同

Metask 产品 owner 已确认 MetaWork 作为 Metask 第一方客户端复用当前 public-client identity：

| 项目                       | 锁定值                                                                                                                                                 |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Flow                       | OAuth 2.0 Authorization Code + PKCE S256                                                                                                               |
| Authority                  | `https://napi.metask-ai.com`                                                                                                                           |
| Authorize                  | `https://napi.metask-ai.com/oauth/authorize`                                                                                                           |
| Token                      | `https://napi.metask-ai.com/oauth/token`                                                                                                               |
| Revoke                     | `https://napi.metask-ai.com/oauth/revoke`；C1 本地退出不依赖 remote revoke 成功                                                                        |
| Client ID                  | `metawork-app`，无 `client_secret` 的 public client                                                                                                    |
| Scope                      | `metawork:use`，唯一可申请 scope                                                                                                                       |
| Redirect                   | `http://127.0.0.1:{dynamic_port}/auth/callback`                                                                                                        |
| Current user identity read | bearer `GET https://napi.metask-ai.com/api/v1/auth/me`；未进入 2026-08 发布文档，但当前 MetaWork 以 production 实测合同严格验证 authenticated identity |

固定行为：

- 只生成 CSPRNG `state` 与 PKCE verifier，只接受 `code_challenge_method=S256`；
- callback 只绑定 IPv4 loopback 动态端口，不依赖 `localhost` DNS，不绑定 wildcard；
- callback 只接受单次 `GET /auth/callback`，严格解析 query、拒绝重复/unknown 参数，并对 `state` 做 constant-time 比较；
- token response 有界解码并严格校验 MetaWork 实际消费的字段：`access_token`、每次必需的新 `refresh_token`、Bearer `token_type`、正整数 `expires_in`、精确 `metawork:use` scope 和非空 `account_id`；OAuth 服务允许增加未消费的 metadata，新增字段不得破坏客户端；
- refresh token 每次成功刷新都轮换；token response 成功即形成独立 rotation commit 边界。response 缺少新 refresh token 时进入 `signed_out`，不得继续使用已作废的旧 refresh token；后续 identity、catalog、execution nonce 或 preference 失败不得回滚已成功的轮换；
- 用户明确登录或冷启动恢复时，Account 使用同一 OAuth access token 单次读取 current user compatibility endpoint。只有响应 `code = 0`、数值 `data.id` 的十进制文本精确匹配 token `account_id`，且 `data.username` 为非空、有界 UTF-8 时才提交 authenticated identity；失败时不得发布持久化的旧 identity。refresh token 已轮换成功但随后 `/me` 失败时，仍必须先可靠保存新 refresh token，再发布可重试失败。该接口不进入普通后台定时 refresh 或 catalog refresh。2026-08-10 已用 production `metawork-app` / `metawork:use` refresh generation 验证：`/api/v1/auth/me` 返回 HTTP 200 与匹配用户；错误的 `/api/v1/auth/oauth/userinfo` 返回 HTTP 400 `invalid scope`，不得再作为客户端路径；
- token、verifier、authorization code、完整 authorize URL 和 Authorization header 不进入 Renderer、Bridge、日志、snapshot 或持久化产品视图。

## 3. C1 本地持久化合同

所有桌面平台使用同一个无版本 hard-cut 布局：

- secure credential service 为产品 Bundle ID 加 `.account`，只保存 `metask-refresh-token`；automation 构建在编译期改用 `.automation.account`，不得访问 production credential；
- Account 数据目录只保存原子 `preferences.json`，字段精确为 `selection_owner_account_id`、`api_key_id`、`model_id` 和 `execution_generation`；`execution_generation` 是 CSPRNG 生成的非零不透明 nonce，只用于相等性判别，没有顺序或计数语义。文件不保存 display name、access token、Provider API Key、base URL、provider 或完整 ExecutionConfig；
- production 与 automation 数据根在编译期固定隔离，automation Task、Schedule、Account preference 和 credential 不得进入 production 目录或 service；
- 冷启动只依赖 refresh token。不存在 token 时直接 `signed_out`；存在 token 时先 refresh，并用 `/me` 建立当前 identity，再决定 preference 能否复用；
- preference 缺失、损坏、owner 不同或 catalog membership 失效只清空默认选择，不影响登录，也不能制造 account mismatch；冷启动且当前进程尚未安装 execution 时，只有 owner、API Key 和 model 全部精确匹配才复用已保存 nonce；显式配置提交生成新 nonce；
- Model Connection metadata 不写入 `preferences.json`。它使用独立的原子 registry；registry 只保存 connection id、display name、provider、normalized endpoint、bounded model metadata、credential status、generation 和待完成的 credential 删除 tombstone。系统 credential account 由公开 connection id 确定，不另存一份 locator；API credential 只保存于系统安全存储，registry 不保存 secret 或 Authorization header；
- 冷启动恢复 durable default 时必须重新读取对应系统 credential。credential 已被系统或用户从安全存储移除时，Account 原子发布并持久化 `credential_status = missing`，撤销该默认并使 generation 回到不可执行的 `configuring`；不得继续显示 `ready`、安装空 credential 或回退到其他连接。安全存储读取本身失败时只 fail closed，不得把暂时不可读误写成已确认缺失；
- refresh response 成功后先替换 secure refresh token，随后 `/me`、catalog 或 preference 失败都不得恢复已作废的旧 token；
- refresh 或 `/me` 明确返回 `401/403` 时删除无效 refresh token 并进入 `signed_out`；网络、deadline、`429` 或 `5xx` 保留当前 refresh token 和明确重试入口，冷启动不得因此发布旧 identity；
- 默认选择在候选 execution preparation 期间生成新 nonce，并使用同目录临时文件、文件 sync、原子 rename 和提交确认；只有 catalog ownership 校验与 preference 持久化全部成功后才安装 execution；熵源失败或结果不确定时 fail closed，不发布未确认 execution；
- logout 先删除 refresh token，再删除无 secret preference。后续选择生成的新 nonce 不会复用旧 binding；durable Task、Run 和 Schedule 不参与 credential 删除 gate，旧 Schedule 仅因 nonce 不匹配进入 `needs_attention`；
- credential/open-browser effect 只在 Native SDK 主线程执行；网络与 loopback wait 在有界 Account worker 上执行；cancel、deadline、superseding attempt 和 shutdown 必须收口并 join；
- 不读取、迁移、清理或兼容旧 manifest、slot、`account.json` 或旧 credential family；旧开发数据由 hard-cut 开发流程在运行新构建前直接移除。

## 4. C2 现有兼容目录路径

本节是 MetaWork 用于向未修改的 AgentCore 提供普通 Provider API Key 的通用接口。2026-08-10 已用 production `metawork:use` OAuth generation 验证 API Key catalog 和 API Key bearer model catalog 均无需 Profile header。接口返回 `401`、`403`、遮蔽 secret 或 API Key 归属无法精确证明时，Account 保持已验证的 authenticated identity，但 catalog 进入失败状态；不得建立本地代理或绕过 AgentCore。

API Key catalog：

- 使用 OAuth access token 作为 Bearer，不携带 Profile header；
- 固定请求 `GET https://napi.metask-ai.com/api/v1/keys?page=1&page_size=100`；
- 成功响应严格为 `code = 0`、`message = "success"` 和 `data { items, total, page, page_size, pages }`；
- 当前只接受 `page = 1`、`page_size = 100`、`pages = 1` 且 `total == items.len`，不发布不完整分页；
- item 必须包含数值 `id`、`name`、完整 secret `key`、`status`、`group_id` 和完整 group；只发布 item 与 group 均为精确 `active` 的条目；
- decoder 严格校验上述消费字段、类型、语义和 byte/entry bound；服务端新增的未消费 metadata 不属于产品合同，不得破坏客户端；
- API Key secret 只由 Account catalog 与 execution staging/runtime ownership 链在当前进程持有。Renderer 只能看到十进制 id、name 和最后四位。

Model catalog：

- 选中 API Key 后，以该 Key 作为 Bearer，不携带 Profile header；
- 固定请求 `GET https://napi.metask-ai.com/v1/models`；
- 成功响应严格读取消费的 list 根字段和 `data[]`；拒绝缺失/非法消费字段、重复 model id、`has_more = true`、超限字段和超限集合，但允许服务端增加未消费 metadata；
- model 只向产品投影有界 `id` 与可选 `display_name`；投影同时发布已提交的 API/model identity、当前模型目录所属的脱敏 API Key selection identity，以及仅在重配置期间存在的 `candidateApiKeySelectionId` / `candidateModelSelectionId`。候选字段只表示 Host 已接收的进行中意图，不表示已通过目录校验或已经提交：`loading_keys` 时候选可能尚未属于刚刷新的目录，`loading_models` 后候选 API 才可作为模型目录 owner，`persisting` 时才形成完整且已验证的候选 execution target；成功后候选原子成为已提交默认值，取消或失败时候选必须清空。Renderer 不得把候选 API 的 model id 与已提交默认 API 混用，也不得以本地状态冒充提交结果；
- 已有 ready execution 上切换 API 或模型时，Account 先保留已提交 execution，并用当前 OAuth 重新加载完整 API catalog，再校验请求的 API、加载其模型并校验模型；secure-zero 后的旧 private catalog 不得被假定仍持有 credential。候选 private/public catalog 与 committed public catalog 分槽，只有 ownership 校验和 persistence 全部成功后才原子安装新的默认 generation 并提交候选目录。加载、选择或持久化确定失败必须完整丢弃候选，不得破坏旧默认配置，也不得把既有 Task 改绑；用户只可在进入 credential persistence 前取消，持久化 effect 开始后必须等待 completion 被 main thread 消费，不得用取消制造内存/磁盘 generation 分叉；
- 已有 ready execution 上执行普通 catalog refresh 时，Account 在完整 API catalog 中优先验证已提交 API，并在其仍有效时自动加载对应模型目录；已提交模型也仍属于该目录时，Host 直接提交新的脱敏目录而不递增 execution generation、不重写 credential persistence，也不要求用户重新确认同一选择。只有已提交 API 或模型确实离开最新目录时才进入对应的 `selecting_key` 或 `selecting_model`；
- 未消费的 capability 字段不进入客户端 typed contract。服务端增删这类 metadata，或以 `0` 表达 unknown/placeholder token capability，都不阻止模型进入目录，也不得被 MetaWork 推断为真实能力或 AgentCore 配置。

## 5. Provider 与 ExecutionTarget

对于 Metask managed execution，`provider_kind` 只来自选中 API Key 的精确 `group.platform`，绝不根据模型名推断：

| `group.platform` | Account provider | AgentCore `base_url`                             |
| ---------------- | ---------------- | ------------------------------------------------ |
| `anthropic`      | `anthropic`      | `https://napi.metask-ai.com/v1/messages`         |
| `openai`         | `openai`         | `https://napi.metask-ai.com/v1/chat/completions` |
| `gemini`         | `gemini`         | `https://generativelanguage.googleapis.com`      |

其他 platform 当前在 Metask managed catalog 中 fail closed；该 fixed catalog 不接受 Renderer、环境变量或任意 URL 覆盖。用户管理的 endpoint 只按 §5.1 的 Model Connection 合同校验。

Gemini 的 `base_url` 是 AgentCore Gemini Native client 使用的服务基址；AgentCore
负责按其 provider 合同拼接 model 与 `streamGenerateContent` 路径、认证 header
和请求/事件格式。MetaWork 不实现 Gemini transport，也不根据模型名推断 provider。

Account 必须在当前会话持有 token 的 `account_id`，并以 `account_id + API Key id` 证明 catalog 与 execution credential 归属。自动 refresh 与冷启动恢复必须精确核对 `account_id`，防止后台静默切换账号；用户显式完成 OAuth 时以本次 OAuth token 与 `/me` 共同验证的 identity 为准。identity replacement gate 覆盖异步登录或退出直至 identity terminal commit，但不覆盖后续 catalog/default generation：token 提交前失败保留旧默认配置，verified identity、token 已提交后的失败或成功退出清除旧默认配置并立即释放 identity gate，再以独立 default transaction 为新账号准备目录；旧 execution 不得与新账号混用。`profile_id`、`/v1/profiles` 与 Profile header 不属于 MetaWork runtime、persistence、Bridge 或 AgentCore 合同。

### 5.1 User-managed Model Connection

Model Connection 是 Account-owned 的本地连接对象，不是 Metask identity，也不从 `group.platform` 推导。创建时用户明确选择已登记协议：

| Protocol                | AgentCore provider | Normalized endpoint contract                                        |
| ----------------------- | ------------------ | ------------------------------------------------------------------- |
| OpenAI Chat Completions | `openai`           | 完整 `/v1/chat/completions` endpoint；不支持 `/v1/responses`        |
| Gemini Native           | `gemini`           | 服务 base URL；AgentCore 追加 model 与 `streamGenerateContent` 路径 |

Anthropic Messages 当前不在可创建协议表内：staged AgentCore 仍把 API Key 作为 Bearer 发送，尚未满足 Anthropic Native 所需的 `x-api-key` 合同。MetaWork 不复制 transport 进行补偿；AgentCore 修复并通过同一 provider contract 后再开放。

- Model Connection 不要求 Metask OAuth；但必须通过 Host 的 typed validation、credential persistence 和一次有界的 AgentCore streaming connection test 后，才能成为 default execution source；
- endpoint 只允许 HTTPS，或用户明确配置的 loopback HTTP；拒绝 control character、userinfo、query/fragment credential、过长 URL 和未登记 provider path。Host 将用户输入规范化为 AgentCore 所需的 endpoint，Renderer 不直接拼接或覆盖 `base_url`；
- API credential 只进入系统安全存储和当前 Session/Run 所需的 bounded owned copy。Renderer、Bridge、snapshot、Task/Run history、日志和 diagnostics 不得接收 credential 原文；
- 第一版不做 model discovery；用户明确提交 bounded model id，Host 保存其模型 metadata，并仍以 provider contract 校验连接；
- endpoint、provider 或 credential 变化生成新的 `connection_generation`；同一 ready connection 内切换已登记模型只生成新的 opaque execution generation。已有 live Session 不热替换，既有 Task 保留创建时的 execution binding；
- Test connection 只验证 provider request/streaming response，不创建产品 Task、Run history、checkpoint 或 durable Conversation。连接的 generation readiness 与最新 `untested | testing | connected | failed` 测试状态是两个事实：首次成功把当前 generation 标记为 ready；对已 ready generation 的失败重测只更新最新测试结果，不撤销既有 default execution 或跨重启 binding。AgentCore provider SSE/JSON parsing 仍归 AgentCore，MetaWork 不维护平行 transport。

## 6. 持久化崩溃一致性

- refresh rotation 与 preference 是两个独立 commit：refresh token 先提交，preference 后提交；
- refresh token 提交失败不得安装新内存 identity；提交成功后任何后续失败都不得回滚到旧 refresh token；
- preference 只描述默认选择及其不透明 nonce，丢失或损坏最多导致重新选择，不能影响 OAuth identity；
- preference 写入采用同目录临时文件、文件 sync、原子 rename 和提交确认；rename 后结果不确定时不得发布新 execution；
- Model Connection registry 使用独立的同目录临时文件、文件 sync、原子 rename 和提交确认；删除先持久化 credential cleanup tombstone，再删除系统 credential，最后原子清除 tombstone，启动和后续 mutation 会继续排空未完成清理。新增连接同样先持久化目标 connection id 的 cleanup tombstone，再写系统 credential，最后用一次原子 registry commit 将 tombstone 替换为完整连接；因此 credential write 前崩溃只留下无害 tombstone，write 后、连接 commit 前崩溃会在恢复时删除 credential，最终 commit 结果不确定时则由重启后的 registry 真相决定保留连接或排空 credential。创建或替换 credential 必须由 Account/Application-owned transaction 完成 secure capture、credential write、registry commit 与失败回滚；任何结果不确定都禁止安装新的 default execution；
- logout 删除顺序固定为 refresh token → preference；refresh token 已删除后，即使 preference 删除失败也不能继续使用旧 identity。

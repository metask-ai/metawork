# MetaWork 消费的 Metask Account API 合同状态

> 状态：**C1 OAuth 登录与 C2 执行目录合同均已确认**
> 日期：2026-07-22
> 范围：MetaWork Account 的 OAuth/account lifecycle，以及后续 API Key/model/ExecutionTarget

## 1. 边界

登录与执行配置是两个独立门槛：

- **C1 登录**：OAuth、profile identity、token 恢复/刷新、退出和本地安全存储。当前信息已经足够实现，不依赖模型、API Key 或 AgentCore。
- **C2 执行配置**：API Key catalog、model catalog 和 typed/fixed `ExecutionTarget { provider_kind, base_url, model }`。只有平台对应的持久化边界完成后，Account 才能发布 `execution_ready`；Workbench 安装同一 generation 后才能创建 Agent Task。macOS 的边界是 execution credential 与 `manifest.json` schema 1 原子提交；Windows 的边界只提交无 secret 的 API/model 选择，execution credential 保持进程内。

MetaWork 只作为 Metask Account API 和 AgentCore bundle 的消费方。本文档不要求、也不授权修改 Metask 内部实现仓库（精确路径标识为 `cc-t2z/metacodes`）。

## 2. C1 已锁定的生产合同

Metask 产品 owner 已确认 MetaWork 作为 Metask 第一方客户端复用当前 public-client identity：

| 项目 | 锁定值 |
| --- | --- |
| Flow | OAuth 2.0 Authorization Code + PKCE S256 |
| Authority | `https://napi.metask-ai.com` |
| Authorize | `https://napi.metask-ai.com/oauth/authorize` |
| Token | `https://napi.metask-ai.com/oauth/token` |
| Revoke | `https://napi.metask-ai.com/oauth/revoke`；C1 本地退出不依赖 remote revoke 成功 |
| Client ID | `metacode-cli`，Metask 第一方 public client identity |
| Scope | `metacode:use` |
| Redirect | `http://127.0.0.1:{dynamic_port}/auth/callback` |
| Profile | bearer `GET https://napi.metask-ai.com/v1/profiles` |

固定行为：

- 只生成 CSPRNG `state` 与 PKCE verifier，只接受 `code_challenge_method=S256`；
- callback 只绑定 IPv4 loopback 动态端口，不依赖 `localhost` DNS，不绑定 wildcard；
- callback 只接受单次 `GET /auth/callback`，严格解析 query、拒绝重复/unknown 参数，并对 `state` 做 constant-time 比较；
- token response 有界解码并严格校验 MetaWork 实际消费的字段：`access_token`、可选/轮换的 `refresh_token`、Bearer `token_type`、正整数 `expires_in`、可选 `scope` 和 `account_id`；OAuth 服务允许增加未消费的 metadata，新增字段不得破坏客户端；
- refresh response 未返回新 refresh token 时保留旧 token；如果服务端已轮换但新本地 generation 未提交，则进入 `reauth_required`，不声称 refresh 成功；
- profile response 有界解码并校验 MetaWork 消费的 `id/name/display_name/status/is_default`；`platform/group/group_name/expires_at` 等未消费 metadata 允许服务端演进。从 `status = active` 中选择唯一 `is_default = true` 的 profile，没有默认项时才回退第一个 active profile，多个 active default 则 fail closed；
- token、verifier、authorization code、完整 authorize URL 和 Authorization header 不进入 Renderer、Bridge、日志、snapshot 或持久化产品视图。

## 3. C1 本地持久化合同

两条平台路径独立拥有自己的存储语义。`manifest.json`、双 slot、marker 和 manifest schema 只属于 macOS；Windows 不读取、迁移、删除或解释这些数据。

### 3.1 macOS

macOS 使用 MetaWork 自己的命名空间，不读取或共享 `~/.metacode/auth.json`：

- development Bundle/runtime identity：`com.metask.metawork.dev`；
- 非秘密 Account 文件：`~/Library/Application Support/MetaWork Dev/account/manifest.json`；
- Keychain service：`com.metask.metawork.dev.account`；
- 真实 macOS Account development/package 使用 Apple-signed development identity，使 Keychain authorization 绑定稳定 Team 与 designated requirement；签名流程本身不改变本节的 service、slot 或 manifest 合同；
- 固定 OAuth slot：`oauth/A/*` 与 `oauth/B/*`；
- 每个 slot 分别保存 access、refresh 和最后写入的 generation marker；
- 非秘密 `manifest.json` schema 1 是 OAuth 与 execution 两个 credential family 的唯一 committed pointer，使用 `signed_out`、`account_only` 或 `execution_ready` 状态；
- 写新 inactive slot、读回校验、原子提交 manifest 后，才清理旧 slot；
- logout 先原子提交 `signed_out` tombstone，再清理 Keychain；清理失败不能复活旧账号；
- Keychain/open-browser 操作只能在 Native SDK 主线程执行；网络与 loopback wait 在有界 Account worker 上执行；
- cancel、deadline、superseding attempt 和 shutdown 必须关闭 listener、停止网络操作并 join worker。

#### macOS manifest schema 策略

Account manifest schema 与 Renderer Bridge revision、AgentCore ABI 和 bundle manifest schema 相互独立。当前固定文件名 `manifest.json` 与 body schema 1 是一次 pre-release hard cut；旧 `manifest.v2` 不构成兼容输入，也不能被解释为当前 committed state。

- `app.zon` 单一拥有 development 产品 Bundle ID；`src/product_identity.zig` 从该 manifest 派生 Bundle ID 及 macOS 数据目录与 Keychain service；`account/credential_store.zig` 独立拥有固定 manifest 文件名、body schema 与原子提交语义；
- schema 只在 manifest 布局、原子提交语义或安全解释发生不兼容变化时升级；增加内存字段、UI 字段或未持久化能力不升级；
- pre-1.0 不维护多版本 parser、静默迁移或 fallback。旧 `dev.metawork.desktop`、`dev.metawork.account.v2`、`MetaWork/account/manifest.v2` 均不作为输入；开发环境重新登录后可显式执行 Account-owned `npm run account:cleanup-legacy:macos`，幂等删除精确的旧 Keychain slot 与旧 manifest，不触碰当前 macOS namespace、Apple Development identity 或 Windows storage；
- macOS 代码只接受 schema 1。未来若没有真实不兼容的 macOS manifest 变化，不得因为产品版本、Bridge revision、Windows 存储布局或 AgentCore ABI 变化联动升级。

### 3.2 Windows

Windows 使用一条直接、无版本的恢复路径：

- Windows Credential Manager 的 service 为 `dev.metawork.account`，只保存一个 `metask-refresh-token`；
- `account.json` 只保存 account/profile/display name 与最近一次已提交的 API/model selection identifier，不含 schema/revision 字段；
- access token、Provider API Key、base URL、provider、execution generation 和完整 execution config 都不跨进程持久化；
- 冷启动只有同时取得 refresh token 与合法 `account.json` 才恢复 `account_only`，随后先刷新 OAuth 并重新读取 Metask profile identity；profile 必须与公共状态精确一致，refresh response 提供 `account_id` 时也必须精确一致。response 省略可选 `account_id` 时沿用已保存 account id 仅用于组成 identity，仍必须完成远端 profile 验证，不能直接信任磁盘。验证通过后再拉取 API/model catalog，并在历史选择仍属于当前 catalog 时于内存重建 execution；
- 历史选择失效时保持登录并请求用户重新选择，不从文件重建 Provider、base URL 或 credential；refresh 无效进入 `reauth_required`，网络失败保留可重试状态；
- 登录先原子替换 `account.json`，再写单个 refresh token；任一步失败都不提交内存登录事实。刷新只替换 refresh token，选择变更只替换 `account.json`；
- logout 先删除 refresh token，再删除 `account.json`，任一步失败都不声称退出成功；
- macOS 当前 `com.metask.metawork.dev.account`、`MetaWork Dev/account/manifest.json` 以及旧 `dev.metawork.account.v2`、`MetaWork/account/manifest.v2` 条目都由 Windows 完全忽略，不做兼容读取、迁移或静默清理。用户在 Windows hard cut 后只需重新登录一次；
- 快速开发阶段若 Windows 布局需要改变，直接原地 hard cut；不得自行增加版本号。任何合同类版本标识变更仍必须先得到用户显式同意。

## 4. C2 已锁定的目录合同

API Key catalog：

- 使用 OAuth access token 作为 Bearer，并携带当前 `profile.id` 的 `X-Metacode-Profile-ID`；
- 固定请求 `GET https://napi.metask-ai.com/api/v1/keys?page=1&page_size=100`；
- 成功响应严格为 `code = 0`、`message = "success"` 和 `data { items, total, page, page_size, pages }`；
- 当前只接受 `page = 1`、`page_size = 100`、`pages = 1` 且 `total == items.len`，不发布不完整分页；
- item 必须包含数值 `id`、`name`、完整 secret `key`、`status`、`group_id` 和完整 group；只发布 item 与 group 均为精确 `active` 的条目；
- decoder 严格校验上述消费字段、类型、语义和 byte/entry bound；服务端新增的未消费 metadata 不属于产品合同，不得破坏客户端；
- API Key secret 只由 Account catalog 与 execution staging/runtime ownership 链持有；macOS 可按本合同进入 Keychain execution family，Windows 始终只在当前进程持有。Renderer 只能看到十进制 id、name 和最后四位。

Model catalog：

- 选中 API Key 后，以该 Key 作为 Bearer，并携带同一 `X-Metacode-Profile-ID`；
- 固定请求 `GET https://napi.metask-ai.com/v1/models`；
- 成功响应严格读取消费的 list 根字段和 `data[]`；拒绝缺失/非法消费字段、重复 model id、`has_more = true`、超限字段和超限集合，但允许服务端增加未消费 metadata；
- model 只向产品投影有界 `id` 与可选 `display_name`；投影同时发布已提交的 API/model identity、当前模型目录所属的脱敏 API Key selection identity，以及仅在重配置期间存在的 `candidateApiKeySelectionId` / `candidateModelSelectionId`。候选字段只表示 Host 已接收的进行中意图，不表示已通过目录校验或已经提交：`loading_keys` 时候选可能尚未属于刚刷新的目录，`loading_models` 后候选 API 才可作为模型目录 owner，`persisting` 时才形成完整且已验证的候选 execution target；成功后候选原子成为已提交默认值，取消或失败时候选必须清空。Renderer 不得把候选 API 的 model id 与已提交默认 API 混用，也不得以本地状态冒充提交结果；
- 已有 ready execution 上切换 API 或模型时，Account 先保留已提交 execution，并用当前 OAuth/profile 重新加载完整 API catalog，再校验请求的 API、加载其模型并校验模型；secure-zero 后的旧 private catalog 不得被假定仍持有 credential。候选 private/public catalog 与 committed public catalog 分槽，只有 ownership 校验和 persistence 全部成功后才原子安装新的默认 generation 并提交候选目录。加载、选择或持久化确定失败必须完整丢弃候选，不得破坏旧默认配置，也不得把既有 Task 改绑；用户只可在进入 credential persistence 前取消，持久化 effect 开始后必须等待 completion 被 main thread 消费，不得用取消制造内存/磁盘 generation 分叉；
- 已有 ready execution 上执行普通 catalog refresh 时，Account 在完整 API catalog 中优先验证已提交 API，并在其仍有效时自动加载对应模型目录；已提交模型也仍属于该目录时，Host 直接提交新的脱敏目录而不递增 execution generation、不重写 credential persistence，也不要求用户重新确认同一选择。只有已提交 API 或模型确实离开最新目录时才进入对应的 `selecting_key` 或 `selecting_model`；
- 未消费的 capability 字段不进入客户端 typed contract。服务端增删这类 metadata，或以 `0` 表达 unknown/placeholder token capability，都不阻止模型进入目录，也不得被 MetaWork 推断为真实能力或 AgentCore 配置。

## 5. Provider 与 ExecutionTarget

`provider_kind` 只来自选中 API Key 的精确 `group.platform`，绝不根据模型名推断：

| `group.platform` | Account provider | AgentCore `base_url` |
| --- | --- | --- |
| `anthropic` | `anthropic` | `https://napi.metask-ai.com/v1/messages` |
| `openai` | `openai` | `https://napi.metask-ai.com/v1/chat/completions` |

其他 platform 当前 fail closed。production 不接受 Renderer、环境变量或任意 URL 覆盖。

Account 同时保存 token 的 `account_id` 与当前 `profile.id`。macOS 将其写入 committed manifest；Windows 只将无 secret identity 写入 `account.json`。后者用于请求 header、catalog ownership 和 execution credential 归属。自动 refresh 与冷启动恢复必须用已提交 identity 校验远端结果，防止后台静默切换账号；用户显式完成 OAuth 重认证时则以本次 OAuth 返回的 token 与 profile identity 为准，不得再用旧 identity 否决登录。显式重认证通过 identity replacement gate 后原子替换本机 identity 和 token，清除旧默认 execution、API/model selection 与 catalog，再按新 identity 重新准备目录；旧 execution 不得与新账号混用。

## 6. macOS 双 family 崩溃一致性

- OAuth family 使用 `oauth/{A,B}/{access,refresh,marker}`；
- execution family 使用 `execution/{A,B}/{api-key,marker}`；
- 每个 family 都先写 inactive slot、最后写 marker、读回校验，再通过一次 `manifest.json` 原子提交；
- `execution_ready` manifest 同时指向 OAuth slot 与 execution slot，并记录 account/profile、API Key id、typed provider、model、固定 base URL、execution generation 和 high watermark；
- OAuth refresh 只轮换 OAuth slot，必须保留已提交 execution family；
- execution 重配置只轮换 execution slot，必须保留已提交 OAuth family；
- rename 后目录 fsync 结果不确定时保留 staged slot，重启后以 manifest 为唯一 committed pointer；
- logout 先提交 `signed_out` tombstone，再清理两个 family；清理失败不能复活账号或 execution。

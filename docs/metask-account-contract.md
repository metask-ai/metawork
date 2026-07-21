# MetaWork 消费的 Metask Account API 合同状态

> 状态：**C1 OAuth 登录与 C2 执行目录合同均已确认**
> 日期：2026-07-20
> 范围：MetaWork Account 的 OAuth/account lifecycle，以及后续 API Key/model/ExecutionTarget

## 1. 边界

登录与执行配置是两个独立门槛：

- **C1 登录**：OAuth、profile identity、token 恢复/刷新、退出和本地安全存储。当前信息已经足够实现，不依赖模型、API Key 或 AgentCore。
- **C2 执行配置**：API Key catalog、model catalog 和 typed/fixed `ExecutionTarget { provider_kind, base_url, model }`。只有 execution credential 与原子 manifest 提交完成后，Account 才能发布 `execution_ready`；Workbench 安装同一 generation 后才能创建 Agent Task。

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

macOS 使用 MetaWork 自己的命名空间，不读取或共享 `~/.metacode/auth.json`：

- Keychain service：`dev.metawork.account.v2`；
- 固定 OAuth slot：`oauth/A/*` 与 `oauth/B/*`；
- 每个 slot 分别保存 access、refresh 和最后写入的 generation marker；
- 非秘密 `manifest.v2` 是 OAuth 与 execution 两个 credential family 的唯一 committed pointer，使用 `signed_out`、`account_only` 或 `execution_ready` 状态；
- 写新 inactive slot、读回校验、原子提交 manifest 后，才清理旧 slot；
- logout 先原子提交 `signed_out` tombstone，再清理 Keychain；清理失败不能复活旧账号；
- Keychain/open-browser 操作只能在 Native SDK 主线程执行；网络与 loopback wait 在有界 Account worker 上执行；
- cancel、deadline、superseding attempt 和 shutdown 必须关闭 listener、停止网络操作并 join worker。

### 3.1 持久化 revision 策略

Account persistence revision 与 Renderer Bridge revision、AgentCore ABI 和 bundle manifest schema 相互独立。当前 revision `2` 是一次真实的 hard cut：revision 1 只保存 OAuth family，revision 2 增加 execution credential family、统一 committed manifest 和 execution high watermark，因此不能把 revision 1 数据解释为当前状态。

- revision 只在持久化布局、原子提交语义或安全解释发生不兼容变化时升级；增加内存字段、UI 字段或未持久化能力不升级；
- Keychain service、manifest 文件名和 manifest body revision 分别隔离 secret namespace、非秘密元数据文件和内容校验，三者由 `account/credential_store.zig` 统一拥有，平台适配层不得另行定义版本；
- pre-1.0 不维护多版本 parser 或静默迁移。hard cut 必须显式决定旧 secret 与 manifest 的删除方式；不得读取旧数据后猜测补字段，也不得让不可达 credential 永久遗留；
- 当前代码只接受 revision 2。未来若没有真实不兼容的持久化变化，不得因为产品版本、Bridge revision 或 AgentCore ABI 变化联动升级。

## 4. C2 已锁定的目录合同

API Key catalog：

- 使用 OAuth access token 作为 Bearer，并携带当前 `profile.id` 的 `X-Metacode-Profile-ID`；
- 固定请求 `GET https://napi.metask-ai.com/api/v1/keys?page=1&page_size=100`；
- 成功响应严格为 `code = 0`、`message = "success"` 和 `data { items, total, page, page_size, pages }`；
- 当前只接受 `page = 1`、`page_size = 100`、`pages = 1` 且 `total == items.len`，不发布不完整分页；
- item 必须包含数值 `id`、`name`、完整 secret `key`、`status`、`group_id` 和完整 group；只发布 item 与 group 均为精确 `active` 的条目；
- decoder 严格校验上述消费字段、类型、语义和 byte/entry bound；服务端新增的未消费 metadata 不属于产品合同，不得破坏客户端；
- API Key secret 只由 Account catalog、execution staging 和 Keychain ownership 链持有；Renderer 只能看到十进制 id、name 和最后四位。

Model catalog：

- 选中 API Key 后，以该 Key 作为 Bearer，并携带同一 `X-Metacode-Profile-ID`；
- 固定请求 `GET https://napi.metask-ai.com/v1/models`；
- 成功响应严格读取消费的 list 根字段和 `data[]`；拒绝缺失/非法消费字段、重复 model id、`has_more = true`、超限字段和超限集合，但允许服务端增加未消费 metadata；
- model 只向产品投影有界 `id` 与可选 `display_name`；未消费的 capability 字段不进入客户端 typed contract。服务端增删这类 metadata，或以 `0` 表达 unknown/placeholder token capability，都不阻止模型进入目录，也不得被 MetaWork 推断为真实能力或 AgentCore 配置。

## 5. Provider 与 ExecutionTarget

`provider_kind` 只来自选中 API Key 的精确 `group.platform`，绝不根据模型名推断：

| `group.platform` | Account provider | AgentCore `base_url` |
| --- | --- | --- |
| `anthropic` | `anthropic` | `https://napi.metask-ai.com/v1/messages` |
| `openai` | `openai` | `https://napi.metask-ai.com/v1/chat/completions` |

其他 platform 当前 fail closed。production 不接受 Renderer、环境变量或任意 URL 覆盖。

Account 同时持久化 token 的 `account_id` 与当前 `profile.id`。后者用于请求 header、catalog ownership 和 execution credential 归属；重认证身份不一致时不得沿用旧 execution。

## 6. 双 family 崩溃一致性

- OAuth family 使用 `oauth/{A,B}/{access,refresh,marker}`；
- execution family 使用 `execution/{A,B}/{api-key,marker}`；
- 每个 family 都先写 inactive slot、最后写 marker、读回校验，再通过一次 `manifest.v2` 原子提交；
- `execution_ready` manifest 同时指向 OAuth slot 与 execution slot，并记录 account/profile、API Key id、typed provider、model、固定 base URL、execution generation 和 high watermark；
- OAuth refresh 只轮换 OAuth slot，必须保留已提交 execution family；
- execution 重配置只轮换 execution slot，必须保留已提交 OAuth family；
- rename 后目录 fsync 结果不确定时保留 staged slot，重启后以 manifest 为唯一 committed pointer；
- logout 先提交 `signed_out` tombstone，再清理两个 family；清理失败不能复活账号或 execution。

# MetaWork 消费的 Metask Account API 合同状态

> 状态：**C1 OAuth 登录合同已确认；C2 执行目录合同待完成**
> 日期：2026-07-20
> 范围：MetaWork Account 的 OAuth/account lifecycle，以及后续 API Key/model/ExecutionTarget

## 1. 边界

登录与执行配置是两个独立门槛：

- **C1 登录**：OAuth、profile identity、token 恢复/刷新、退出和本地安全存储。当前信息已经足够实现，不依赖模型、API Key 或 AgentCore。
- **C2 执行配置**：API Key catalog、model catalog 和 typed/fixed `ExecutionTarget { provider_kind, base_url, model }`。C2 未完成时可以登录，但不能创建 Agent Task。

MetaWork 只作为 Metask Account API 和 AgentCore bundle 的消费方。本文档不要求、也不授权修改 `cc-t2z/metacodes`。

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
- token response 只接受有界、严格 JSON：`access_token`、可选/轮换的 `refresh_token`、Bearer `token_type`、正整数 `expires_in`、可选 `scope` 和 `account_id`；
- refresh response 未返回新 refresh token 时保留旧 token；如果服务端已轮换但新本地 generation 未提交，则进入 `reauth_required`，不声称 refresh 成功；
- profile response 为严格 `{ "data": [{ "id", "name"?, "display_name"? }] }`；使用第一个非空 profile 作为当前 profile identity；
- token、verifier、authorization code、完整 authorize URL 和 Authorization header 不进入 Renderer、Bridge、日志、snapshot 或持久化产品视图。

## 3. C1 本地持久化合同

macOS 使用 MetaWork 自己的命名空间，不读取或共享 `~/.metacode/auth.json`：

- Keychain service：`dev.metawork.account.oauth.v1`；
- 固定 OAuth slot：`oauth/A/*` 与 `oauth/B/*`；
- 每个 slot 分别保存 access、refresh 和最后写入的 generation marker；
- 非秘密 `manifest.v1` 是唯一 committed pointer，使用 `account_only` 或 `signed_out` 状态；
- 写新 inactive slot、读回校验、原子提交 manifest 后，才清理旧 slot；
- logout 先原子提交 `signed_out` tombstone，再清理 Keychain；清理失败不能复活旧账号；
- Keychain/open-browser 操作只能在 Native SDK 主线程执行；网络与 loopback wait 在有界 Account worker 上执行；
- cancel、deadline、superseding attempt 和 shutdown 必须关闭 listener、停止网络操作并 join worker。

## 4. C2 尚未锁定的合同

C2 继续锁定：

- API Key catalog 的 endpoint、分页、strict response schema、状态和 revoke/disable 语义；
- model catalog 如何得到 typed `provider_kind + base_url + model`；
- 选定 API Key 与 profile/account 的稳定归属；
- credential probe 和确定性鉴权失败语义；
- production base URL/origin/path allowlist。

C2 不得根据模型名称猜 provider，不得从 Renderer 或环境变量接受生产 `base_url/provider/model/api_key`。C2 完成前 Account 状态可以是 `authenticated/account_only`，但 `ExecutionState` 保持 `none`，Workbench 必须拒绝 Task admission。

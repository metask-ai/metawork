# MetaWork 消费的 Metask Account API 合同状态

> 状态：**BLOCKED — 等待 Metask 服务端 owner 正式确认**
> 日期：2026-07-20
> 范围：MetaWork Account 的生产 OAuth、API Key catalog、模型 catalog 与 ExecutionTarget

## 1. 文档职责

本文档只记录 MetaWork 生产接入所需的外部合同及其确认状态。它不把其他客户端的当前实现、兼容解析器或测试 fixture 升格为 Metask 公共合同，也不要求修改 `cc-t2z/metacodes`。

在本合同解除 BLOCKED 前：

- 可以实现纯 Account 状态机、固定资源上限、secret ownership、fake client 和 test-only endpoint；
- 不得实现或发布生产 OAuth/API client；
- 不得把 `metacode-cli` client id、宽松 API Key JSON 解析或按模型名猜 Provider 的逻辑复制进 MetaWork；
- 生产 build 不得包含可由环境变量或 Renderer 覆盖的 endpoint、client id、scope、provider 或 base URL。

## 2. 已验证的一手实现证据

以下内容来自 Metask 自有仓库的当前代码，但仍只是候选证据：

| 项目 | 当前实现证据 | 合同状态 |
| --- | --- | --- |
| OAuth flow | mCode 使用 Authorization Code + PKCE S256、loopback callback | flow 可复用；MetaWork client registration 未确认 |
| OAuth authority | mCode 当前使用 `https://napi.metask-ai.com` | 未确认为 MetaWork 生产合同 |
| OAuth endpoints | `/oauth/authorize`、`/oauth/token`、`/oauth/revoke` | 未完成服务端 owner sign-off |
| mCode client | `client_id=metacode-cli`、`scope=metacode:use` | **禁止作为 MetaWork 默认值** |
| Profile catalog | bearer `GET /v1/profiles` | response/error/limit 合同未正式锁定 |
| Model catalog | bearer `GET /v1/models`，可带 `X-Metacode-Profile-ID` | 当前条目没有 typed `provider_kind + base_url` |
| API Key catalog | metacodes 当前访问 `/api/v1/keys?page=1&page_size=100` | 当前消费者使用宽松多形状解析，不能作为严格 schema |
| Metask gateway | mCode 当前默认 `https://napi.metask-ai.com/v1` | protocol、path 与模型适用范围未正式锁定 |

mCode 仓库内的 OAuth phase-0 文档自身标记为 draft/pending backend sign-off，因此不能据此宣称生产合同已经成立。

## 3. 必须由 Metask 锁定的生产合同

### 3.1 OAuth client

必须明确：

- MetaWork 独立 `client_id`；
- authorize、token、revoke endpoint；
- 精确 scope；
- 允许的 loopback host、动态端口策略和 callback path；
- access/refresh token required fields、expiry、refresh rotation 和 revoke 语义；
- HTTP status、OAuth error code、响应 body 上限与重试规则。

MetaWork 只接受 Authorization Code + PKCE S256。禁止 `plain` challenge、固定 callback 端口、`localhost` DNS 依赖或复用其他产品的 client id。

### 3.2 API Key catalog

必须明确：

- endpoint、method、pagination 和鉴权方式；
- key 的稳定 server id、显示名、secret、状态和可选 profile/account 归属；
- disabled/revoked 状态及其对既有 ExecutionConfig 的语义；
- unknown-field policy、最大页数、最大条目数、字段最大 bytes 和错误 schema；
- 是否提供显式 credential probe、disable/revoke 操作及其幂等语义。

MetaWork 生产 client 使用严格 decoder。现有消费者为兼容历史形状而接受多种 field alias，不构成可复制的合同。

### 3.3 Model catalog 与 ExecutionTarget

模型选择必须最终得到：

```text
ExecutionTarget {
  provider_kind,
  base_url,
  model
}
```

Metask 必须选择以下一种并正式锁定：

1. catalog 直接返回 typed `provider_kind`、`base_url` 和 `model`；或
2. 全部可选模型固定走一个 Metask gateway protocol/origin，由 MetaWork 编译期映射为单一 typed target。

不得根据模型名称、API Key group 名称或 Renderer 输入猜测 Provider。生产 base URL 必须通过编译期 origin allowlist，并拒绝非 HTTPS、userinfo、fragment、IP literal、跨 origin redirect 和非合同 path。

## 4. 解除 BLOCKED 的判据

Metask 服务端 owner 需提供一个可版本化、可测试的公开合同或机器可读 schema，并明确：

1. MetaWork OAuth registration；
2. OAuth 与 account/profile API 的稳定身份语义；
3. 严格 API Key catalog schema；
4. typed/fixed ExecutionTarget；
5. revoke/disable/refresh 与错误映射；
6. production 与 test endpoint 的隔离规则。

确认后应更新本文档的状态和精确版本，增加 contract fixture，并让 production client 的 decoder、endpoint allowlist 和回归测试都引用该版本。没有这些证据时，DAG C 保持 blocked；不得用消费方补丁伪造合同完成。

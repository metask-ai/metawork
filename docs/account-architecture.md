# MetaWork Account 架构

> 状态：Account Product owner、Metask identity/authorization 与 credential 生命周期的 source of truth。

## 1. 文档职责

本文定义 `src/product/account.zig` 与 `src/product/account/` 的职责、状态机、OAuth/identity 合同、credential 持久化、并发和生命周期。Account 授权如何使内置 Metask provider 可用，以及 Models 如何管理目录、选择和解析，由 [Product 架构](product-architecture.md)定义。

以下事实由其他规范独占：

- 产品可见行为与 Task/模型关系见[产品需求](requirements.md)；
- Models、Product Control 与跨 owner 事务见[Product 架构](product-architecture.md)；
- Renderer 交互见[UI 设计规范](ui-design.md)；
- wire command、Snapshot 与 transport 见[Renderer Bridge 合同](renderer-bridge-contract.md)；
- 测试入口和平台证据见[验证规范](validation.md)。

## 2. Owner 与模块边界

Account 是独立 Product owner，只拥有：

- OAuth Authorization Code + PKCE 登录、refresh token rotation 与退出；
- 当前 access token、通过 OAuth Userinfo 严格验证的 Metask identity，以及进程内无 secret 的 usage history summary；
- Account authorization generation，以及供 Application 单次转移的有界 authorization lease；
- Account command/completion 合法性、attempt identity、deadline/cancel、effect queue 与 mailbox；
- 唯一 canonical、无 secret 的 `AccountView` 与 `AccountFact`；
- Account refresh token 的安全存储、恢复与删除策略。

Account 不拥有：

- provider、model catalog、Custom Provider API Key、模型 metadata、Provider-local/global selection、source generation 或模型配置持久化；
- `Protocol`、`ModelRef`、source candidate、`ExecutionConfig`、默认来源、active binding、Task admission 或 consumer recovery；
- user-managed Custom Provider、credential vault、model probe、provider/source generation 或 readiness；
- Native SDK、HTTP client、窗口、WebView、socket、平台 timer 或 credential-store 具体实现；
- AgentCore、Bridge、Renderer 或任一消费方状态。

依赖方向固定为：

```text
contract.zig          Account identity/authorization 纯合同
oauth.zig             Metask OAuth policy 与 secret value
state.zig             Account identity 事务状态机
runtime.zig           aggregate、effect admission、completion 与 commit
ports.zig             Account 所需的窄平台 capability

Application adapter → Account ports
Application coordinator → Account Runtime + Account commit sink
Product Control / Bridge → Account contract

Account -X-> Models / Product Control / Task / Bridge / Agent / Application
Models  -X-> Account Runtime / Account contract
```

Application 可以同时持有 Account Runtime 与 Models 管理 capability，以 Account 的授权 lease 驱动 Metask provider；这属于组合，不形成 Account→Models 或 Models→Account 的模块依赖。

## 3. Canonical Account 合同

公开状态只有：

```text
checking | signed_out | authorizing | authenticated
```

`AccountView` 只包含 `state`、`can_cancel`、经过验证的 `account_id`、best-effort `display_name/email_hint/phone_hint/concurrency_limit`、Account-owned error，以及嵌套的 `summary`；四个资料字段都可以缺失，`concurrency_limit = null` 表示后端资料缺失或不可用，`concurrency_limit = 0` 精确表示 Metask 后端的不限并发语义。完整邮箱和手机号不得进入view、fact、Snapshot、日志或安全诊断；非authenticated状态必须隐藏全部identity字段。`summary` 保留全局 `operation = idle | refreshing`、`usage_eligibility = unknown | disabled | enabled` 与 `wallet/usage/history` 的稳定 wire shape；当前 OAuth 合同在 authenticated history 同步时将 eligibility 置为 enabled，wallet 与 usage 保持 unavailable且不携带数据或错误，history 发布后端返回的日历范围以及最多 371 个严格递增且日期唯一的每日 input/output/cache creation/cache read/total Token与 recorded cost。日期精确为 `YYYY-MM-DD`，金额和 Token 都以 canonical decimal string 越过 Bridge，Host 不发布浮点数。模型目录、默认模型、source、generation、Task admission、API Key和 connection 均不得进入 `AccountView` 或 `AccountFact`。

公开命令只有 `begin_login | cancel_operation | retry_refresh | refresh_summary | open_recharge | logout`。`retry_refresh` 只恢复已验证会话的 Account-owned token refresh 调度：token 已进入 refresh window 时立即启动 refresh，否则重新 arm Host timer；`refresh_summary` 只在 authenticated 时显式刷新 usage history，不刷新 token或 Models目录。`open_recharge` 只在authenticated时请求平台通过系统浏览器打开Account-owned固定充值页 `https://app.metask-ai.com/app/billing`，不接收URL、token、account id或query，也不改变Account状态或发布fact。Account error space只描述 OAuth、identity、refresh token、summary、平台 effect 和自身资源失败，不包含 catalog、model、source、execution、Task、Session 或 consumer 语义。

## 4. Authorization lease 与 Metask provider

产品语义上，Account 授权是 Models 内置 `metask` provider 的可用性前提。这个依赖通过单向 capability 表达：

1. Account 只在公开状态为 `authenticated`、identity 与 credential principal 精确匹配、authorization generation 非零且 access token 尚未到 hard expiry 时，向 Application 产生一份 owned authorization lease；进入 refresh skew window 本身不撤销仍未过期的 lease，正常 refresh commit 也不得误杀使用同一 generation 的在飞 Models operation；
2. lease 只包含 opaque principal、当前 access token 和 authorization generation，必须有界、单次持有并在结束时清零；
3. Application 将 lease 交给一次 Models Metask catalog operation；Models module 不导入 Account，也不持久化 OAuth token；
4. logout、credential 失效、identity replacement 或 authorization generation 变化后，旧 lease/completion 失效，Application 取消并 join 对应 catalog job，再通知 Models 将 Metask provider 置为 `needs_authentication`；
5. Models 清除 transient Metask credential 和可解析目录，但保留无 secret 的 Metask selection intent；custom source 不受影响；
6. 已经交给 Task/Run 的 owned binding 按自己的生命周期收口，Account 退出不构成对消费方的热撤权。

Account 不知道 provider 当前是否为默认值、是否存在 custom source、是否有 Task 正在运行，也不因这些事实拒绝 logout。Models 也不能调用 Account 登录、刷新或退出；它只能接受当次 lease 或观察授权不可用。

## 5. Metask OAuth 与 identity 合同

正式客户端只接受以下固定 public-client 合同：

| 项目          | 固定值                                                               |
| ------------- | -------------------------------------------------------------------- |
| Flow          | OAuth 2.0 Authorization Code + PKCE S256                             |
| Authority     | `https://app.metask-ai.com`                                          |
| Authorize     | `https://app.metask-ai.com/oauth/authorize`                          |
| Token         | `https://app.metask-ai.com/api/oauth/token`                          |
| Userinfo      | bearer `GET https://app.metask-ai.com/api/oauth/userinfo`            |
| Client ID     | `metawork`，无 `client_secret`                                       |
| Scope         | `openid profile email`                                               |
| Redirect      | `http://localhost:<dynamic-port>/auth/metask/callback`               |
| Usage history | bearer `GET https://app.metask-ai.com/v1/usage/stats`               |

Account 只生成 CSPRNG `state` 与 PKCE verifier，只接受 S256 challenge。每次登录由 Application callback listener 在 IPv4 loopback `127.0.0.1` 上绑定 OS 分配的动态端口；授权请求和 authorization-code exchange 必须使用同一个实际端口，并保持精确 `localhost` host 与 callback path。无法取得本地端口时登录明确失败，不改用非 loopback 地址或其他 URI。callback 只接受一次精确路径的 `GET`，严格解析 query、拒绝重复或 unknown 参数，并以 constant-time 比较 `state`。

authorization-code token response 必须有界解码，包含非空 `access_token`、每次必需的新 `refresh_token`、Bearer `token_type`、正整数 `expires_in` 与精确 scope；refresh request 必须携带固定 `client_id = metawork`，不使用 client secret；refresh response 具有相同 token 与过期字段，允许省略 scope。token response 不提供 principal；refresh token 成功轮换并 durable commit 后不得恢复旧 token。

只有 Userinfo 是有界、结构完整的 JSON，具有非空 UTF-8 `sub`、精确 `client_id = metawork` 与非空有界 `authorization_id`，Account 才能把 `sub` 绑定到已提交 token 并提交 authenticated identity。`name`、`email` 与 `phone_number` 都是非阻断、best-effort 资料字段：缺失、`null`、空值、类型错误、格式错误或超出字段边界都不得拒绝 identity。合法有界 UTF-8 `name` 发布为 `display_name`，否则发布空值；合法非空 `email` 必须无控制字符且恰含一个分隔本地部分与域名的 `@`，Account Host 只保留首个 Unicode 码点加 `***@` 与原域名组成的 `email_hint`，否则发布空值；合法 `phone_number` 只允许可选前导 `+` 和 7–20 位 ASCII 数字，Account Host 只保留可选 `+`、前三位数字、`****` 与末四位数字组成的 `phone_hint`，否则发布空值。新 Userinfo 不提供 concurrency，Account 发布 `null`。承载完整资料的 response buffer 在解析后清零。只有失败请求实际使用了当前 credential 时，明确 `401/403` 或 refresh exchange 的有界 OAuth JSON 错误 `400 + invalid_grant` 才能删除该 credential 并进入 `signed_out`：refresh exchange 使用旧 refresh token，Userinfo identity validation 使用刚提交的新 access token；refresh 的其他 `400` 请求、客户端或协议错误不得删除 retained credential，也不得仅凭 HTTP 状态将其归类为凭据失效；authorization-code exchange 不使用 retained credential，其 `400/401/403` 必须归类为 `oauth_exchange_failed`，不得删除已有会话的 credential。network、deadline、`429` 或 `5xx` 保留可恢复 credential 并发布 Account error，不得回退到旧 identity。

新的 OAuth gateway token 只发送给新 OAuth Userinfo 与 `app.metask-ai.com/v1/*`，不得发送给旧 `/api/v1/auth/me` 或 `/api/v1/usage/dashboard/*`，也不得以旧 `run_mode` 决定 history admission。authenticated identity 建立后，Account 直接把 `usage_eligibility` 置为 enabled并读取以周一为起点、截至上海当天的最近 53 个周列（365–371 个日历日）的 usage stats。history 请求固定使用 `scope=user&granularity=day`，Host拥有 `Asia/Shanghai` 日历范围并把本地日边界换算为 UTC `since`（包含）与 `before`（不包含）；Renderer不提交或推断这些参数。响应必须回显 `scope=user`、`granularity=day`、`timezone=Asia/Shanghai` 与精确查询边界；Host严格校验桶顺序、唯一性、`bucket_start`、Token恒等式与 `totals`。稀疏响应中缺失日期只在整段响应通过验证后由Renderer解释为零使用。`cost_mu` 是非负毫 U 整数并在Host中无损规范化为 U 十进制定点字符串；当前已发布响应允许省略 `unit` 与 `cost_complete`，若出现 `unit` 则必须为 `mU`，每日金额因此只具有 recorded cost语义，不承诺区间费用完整。服务端新增未知JSON字段可以忽略，但已消费字段类型必须严格；identity 的三个 best-effort资料字段是明确例外，字段自身不可用时只丢弃该投影。全部金额必须在Host中规范化为十进制定点字符串，不允许NaN、Infinity、指数形式或二进制浮点直接跨Bridge；Token计数必须规范化为十进制整数文本。history 的范围必须从周一开始并覆盖最近53个周列；范围、日期顺序、唯一性和上界必须整体通过验证后才可提交。失败或不完整响应不得清空旧值或伪造零使用。summary只描述整个Metask账户，不得暗示为MetaWork独占消耗。

`/v1/models` 与 `/v1/messages` 的 request、decode、metadata、固定 provider endpoint 和目录规则属于 Models 的 Metask provider，不在 Account 合同中定义。Account 只通过 generation-bound lease 交付当前 OAuth access token；Models 将其作为目录与模型调用的 transient bearer credential，不建立 Metask API Key 选择。OAuth token、PKCE verifier、authorization code、access/refresh token、Authorization header 和 authorization lease 不得进入 Renderer、Bridge、日志、Snapshot 或产品历史。

## 6. 事务、effect 与 commit

Account 只允许一个 identity transaction：

```text
none
| oauth_callback(attempt)
| token_exchange(attempt, login | refresh_token)
| loading_identity(attempt, login | refresh_token)
| logging_out(attempt)
```

每个非 `none` transaction 拥有非零 attempt identity、唯一合法阶段、至多一个 worker/effect，以及成功、明确失败、取消、deadline 和 shutdown 的 terminal 规则。command 和 completion 先产生 prepared transition；coordinator 必须按 committed current 与 prepared next 把它精确分类为 `starts | continues | finishes | no_attempt`。新 attempt 的 effect admission 失败不得提交；continuation admission 失败先提交已经观察到的外部阶段，再以 typed failure 关闭同一 attempt；terminal/no-attempt admission 失败不得误判为 continuation 或触发无 active attempt 的 panic，shutdown 必须在销毁未提交 effect 后完成收口。

登录路径为：OAuth callback → token exchange → refresh token durable commit → Userinfo identity validation 与 token principal binding → Account terminal commit。loopback worker 只等待 callback并交付包含 authorization code、PKCE verifier、callback port 与总 deadline 的 owned exchange input；主线程必须先提交 `token_exchange(login)`，再由独立 network attempt 发出一次 token request，不得在 callback worker 内跨过 commit boundary或自动重放 code exchange。登录总 deadline 为 5 分钟，exchange deadline 为 `min(总 deadline 剩余时间, 30 秒)`。token 已提交后，identity 请求失败不能回滚旧 token。每次显式 `begin_login` 都开始新的 OAuth，不得消费安全存储中保留的 refresh token；显式重新登录可以替换 identity，但旧 identity 在新 Userinfo 验证成功前不得被新值冒充。

Account coordinator 必须先提交 Account Runtime，再把 canonical Account fact提交给 Product Control，最后通知 Application 的 Models observer。Models 的 refresh/clear/install 结果不得回写、回滚或补充 Account transaction。

Account summary 使用独立于 identity transaction 的有界单飞 attempt。authenticated identity commit 或 authorization generation变化后，Application可启动一次自动同步；用户可用 `refresh_summary` 启动一次显式同步。两类触发都必须取得 generation-bound authorization lease，completion同时匹配 `account_id + authorization generation + summary attempt id` 才能提交。history 失败不能清除已有成功值，已有值在失败后转为 stale；初次无值则保持 unavailable。不得轮询、定时刷新或无界重试。logout、identity replacement、generation变化与 shutdown必须取消并 join旧 attempt，迟到 completion只能销毁owned token和数据。

refresh timer 的 wall-clock 读取、首次 arm 和失败后的 retry arm 都必须有 Account-owned 可观察结果。无法安排刷新时保持已验证 identity，但发布 `refresh_schedule_failed`；hard expiry 后停止签发或接受 authorization generation。用户通过显式 `retry_refresh` 重新 arm，或在 token 已进入 refresh window 时立即启动 refresh；不得依赖 Renderer timer、每次任意 commit 自动重试或继续发放过期 token。

logout 只要求删除 Account-owned refresh credential并提交 `signed_out`；它不读取 Models 或 consumer 状态。删除明确失败时保留原 committed identity并发布 Account error；成功后 Runtime 清除 access/refresh token和 authorization generation，随后由 Application 通知 Models 授权不可用。

把 credential mutation 错误解释为“未提交”的前提，是当前锁定 Native SDK 的 outcome-certainty Gate 持续通过：精确 package version 与 integrity、受支持平台实现、公开 wrapper 和系统安全存储同步返回合同必须同时匹配。依赖升级或实现漂移必须先重新审计并更新 Gate；若任一受支持平台不能证明错误即未提交，Account 不得把结果压成现有 definite failure，而必须先引入 `outcome_unknown`、readback 或 restart reconciliation，再允许后续状态迁移。当前 Gate 通过，因此不预防性增加未知状态。

## 7. Persistence 与恢复

Account durable authority 只有系统安全存储中的 Metask refresh token：

- credential service identity 为产品 Bundle ID 加 `.account`，automation 构建使用独立 `.automation.account`；
- 固定 account name 为 `metask-refresh-token`；
- Account 不读写 `preferences.json` 或 `models.json`；这些格式归 Models；
- Account summary 仅存在于当前进程内，不写入 credential storage、文件、Task历史或日志；
- production 与 automation 的 credential service 隔离，不得相互恢复。
- Account Runtime 和平台 binding 不拥有数据目录、路径创建或文件权限；Models 等其他 owner 的持久化路径不得作为 Account 初始化前置条件。

冷启动是唯一可以消费 retained refresh token 的入口：没有 refresh token 时直接进入 `signed_out`；存在时只尝试一次 restore，先 refresh并提交 rotation，再以 Userinfo 建立 identity。retryable restore failure 保留 credential 和错误事实，但后续显式登录必须开始新 OAuth，不能重新进入隐式 restore 或形成无出口循环。credential-store read failure 是 Account error，不得伪造成有效登录或 Models catalog failure。

## 8. 并发、取消、shutdown 与回归不变量

- 所有 Account state commit 与 projection 发生在主线程；worker 只通过有界 mailbox 交付 owned completion；
- 每个 attempt 最多一个 terminal completion，stale completion 必须销毁 owned secret且不能改变 state；
- 只有仍在等待 OAuth callback 的登录可以取消；callback 被主线程提交为 `token_exchange(login)` 后取消命令即失效，credential persistence 一旦可能提交即跨过取消边界；
- refresh timer、网络、loopback、deadline 与 cancellation 由 Account-owned policy和 Application byte/platform adapter协作收口；
- refresh timer 或 wall clock 失败不得静默；`refresh_schedule_failed` 必须保留 `authenticated` identity、提供显式 retry，并与 hard-expiry lease gate 共同 fail closed；
- shutdown 停止新 command，取消 timer，cancel/join worker，消费或销毁 mailbox，清零 access/refresh token，最后断开 ports；`deinit` 不执行平台 effect；
- 登录、refresh、restore、重新登录、取消、logout、明确 credential-store 失败、network/deadline failure、stale completion、mailbox collision 与 shutdown 都必须保持单一 terminal fact；
- Userinfo 未验证时绝不发布 authenticated identity；
- authorization generation 只随可用授权建立/替换，旧 generation 的 lease 和 completion不能再次生效；
- history summary 的 failure 和 stale 只改变 summary子投影，不回滚 identity、token rotation或 authorization generation；
- logout 后 Account 为 `signed_out`，Models 中 Metask provider 不可解析，custom source与已交付的 Task binding 不被改写；
- Account 模块和构建图不得导入 Models contract/root/runtime/ports/provider；模型类型和能力不得重新定义在 Account 中。

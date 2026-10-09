# MetaWork 登录刷新可靠性实施方案

状态：待实施的任务计划，不是已生效的架构合同或 decision record。日期：2026-10-09。基于 MetaWork `9a38b507` 与 metask-ai 已提交阶段 A `c0ecd25`；实施前核对实际部署的后端 revision。

目标是修复误清登录态、旧刷新令牌重放和正常退出丢失轮换结果。后端阶段 A 没有丢响应恢复协议；结果不确定或本地保存失败时，本期允许要求重新登录。

## 1 本期范围

已提交的刷新 `client_id=metawork` 和普通 400 不清凭据修复保留。本期只完成四项：

1. 按刷新接口的状态码与错误码分类，区分请求错误、凭据失效和结果不确定。
2. 请求前持久化阻断记录，防止本进程与重启后重放结果不确定的旧令牌。
3. 正常 Host 退出前保存已收到的合法刷新结果，修复完整响应被取消覆盖的竞态。
4. 补齐直接命中这些失败模式的测试与真实联调。

沿用现有 Account 单飞、公开四态、错误枚举、登录入口和 `retry_refresh` 职责。只增加一个 Account-owned“刷新被阻断”条件，与已有 attempt 和 credential binding 配合；不建立独立的登录恢复状态机。

本期不提供保存失败后的本地恢复按钮、长期保留新令牌的恢复流程、记录清理重试命令或服务端恢复扩展。保存失败只做一次写入尝试，失败后停止刷新并要求重新登录。无感恢复留给后端阶段 C 的双方协议。

## 2 刷新判定与运行中行为

| 结果                                                                          | 凭据与记录处理                        | 后续行为                                               |
| ----------------------------------------------------------------------------- | ------------------------------------- | ------------------------------------------------------ |
| 未调用 transport 的本地失败                                                   | 保留旧 token；若已写记录则尝试解除    | 解除成功后恢复刷新资格，不自动循环                     |
| 合法 `400 invalid_request`、`401 invalid_client`、`400 unauthorized_client`   | 保留旧 token，解除记录                | 显示请求或配置错误；解除成功后才允许安全调度恢复       |
| 合法 `400 invalid_grant`                                                      | 阻断刷新；先删 token，再删记录        | 重新登录                                               |
| 完整合法 200                                                                  | 先保存新 token，再清理旧记录          | 已验证会话沿用现有绑定；登录或 restore 才验证 Userinfo |
| transport 调用后的超时、取消、断网、5xx、无明确提交合同的 429、损坏或未知响应 | 保留记录与旧 token，阻断旧 token 刷新 | 重新登录，不重放                                       |

只有状态码与有界 OAuth 错误码精确匹配后端合同，才能判定明确未消费。描述文字、request ID、时间经过和通用错误名都不是回滚证据。当前 transport 不暴露可靠发送阶段，调用后失败统一按不确定处理，不增加底层网络探针。

移除大部分刷新失败后 30 秒重放旧 token 的路径。恢复刷新资格必须有明确未消费证据且记录解除成功，不能因 error 被清除、重新登录取消、timer 出错或 UI 状态变化而解除阻断。记录解除失败直接保持阻断并要求重新登录，不引入清理恢复流程。

`retry_refresh` 继续只恢复已验证会话的安全刷新调度；被阻断时拒绝。signed_out 不新增隐式 restore 或本地保存恢复入口。

已有 verified identity 和未过期 access token 可按现有规则继续使用。hard expiry 仍由现有 lease gate 拒绝新授权，不改变公开四态的过期转换行为。

凭据写入、删除及 generation 更新之前，先校验当前 attempt 与请求实际使用的 credential binding。迟到结果只能释放资源，不能删除或覆盖新会话。

Userinfo 同时收口与凭据失效有关的分类：明确的 `authorization_revoked` / `user_not_found` 才删除当前请求对应的 refresh credential；`invalid_token`、403 或损坏响应不能证明 refresh token 已失效，保留已保存的新 token，以现有 Account 错误和重新登录入口结束未验证身份。正常已验证刷新不增加 Userinfo。

## 3 最小持久化协议

### 3.1 存储与前提

保持现有 credential service、`metask-refresh-token` 名称和原始 token 值格式。新增同一系统安全存储中的 `metask-refresh-in-flight` 条目，格式为精确 ASCII `v1:<64 位小写 SHA-256 十六进制摘要>`，摘要输入为本次旧 refresh token 的完整字节。

该记录只表示旧 token 的刷新可能已发出，不保存身份、access token、请求或响应，不按 TTL 自动解除。摘要按凭据材料管理，临时缓冲区清零，不进入日志、Bridge、Snapshot 或普通文件。

沿用既有 canonical 单实例和 Account 单飞。两个条目由同一 Host 独占修改；合法摘要不匹配只证明本地 token 已被替换，不证明身份有效。确认当前支持入口的 credential service 与 writer authority 一致，不新增全局凭据协调器或 Native SDK 私有实现。

### 3.2 写入顺序

1. 主线程取得唯一 attempt，准备有界请求。
2. 成功写入绑定旧 token 的记录；失败时不发 HTTP。
3. 发出一次 refresh HTTP，禁止自动重放。
4. 合法响应通过有界 token 校验，新 refresh token 不得等于旧值；主线程尝试一次保存新 token。
5. 保存成功后安装新 credential，再清理旧记录；按现有流程结束刷新或进入 Userinfo。

第 4 步失败时保留旧记录，阻断刷新，释放未提交的新 token 并报告既有 credential-store 错误；不在之后的用户动作或退出中再次尝试保存同一结果。

第 4 步成功但记录清理失败时，新 token 摘要已与旧记录不同，允许正常使用及重启恢复；不能回滚 token 或把成功轮换当成失败。下一次刷新前须成功写入绑定当前 token 的新记录。

明确未消费时只尝试一次解除记录，失败保持阻断。`invalid_grant` 或 logout 先删除 token，再删除记录；token 删除失败时保留阻断记录，不能因删除错误而恢复刷新资格。退出失败保留身份的行为沿用现有合同。

显式新 OAuth 登录不消费旧 token，保存新 token 后可以清理旧记录。取消或失败不能解除原阻断。记录缺失时读取现有 token，不迁移其格式；未知版本或损坏记录不猜测、不自动刷新。

### 3.3 重启决策

| token  | 记录                           | 行为                                                  |
| ------ | ------------------------------ | ----------------------------------------------------- |
| 不存在 | 不存在                         | 正常 signed_out                                       |
| 存在   | 不存在                         | 尝试一次正常 restore，请求前先写记录                  |
| 存在   | 合法且匹配当前 token 摘要      | 不发 refresh，signed_out，要求重新登录                |
| 存在   | 合法但不匹配当前 token 摘要    | 恢复当前 token；新 HTTP 前先覆盖记录为当前 token 摘要 |
| 不存在 | 合法残留记录                   | signed_out，尝试清理，不发网络                        |
| 任意   | 读取失败、未知版本、损坏或超长 | 不发 refresh，报告既有存储错误                        |

记录写入后即使尚未发 HTTP，进程终止也会保守要求重新登录。新 token 已保存、旧记录未清理时，则能恢复新 token。这两个边界是该协议的明确取舍。

保证范围是正常系统存储返回与进程终止恢复；不把没有返回结果的写入当成已回滚，不承诺响应丢失、外部存储回滚或整机断电后一定无感恢复。更新前退出旧 Host；旧二进制不理解记录，不能承诺降级时仍遵守防重放约束。

## 4 正常退出收口

只在真正 Host stop 时执行；窗口隐藏、托盘后台和 Renderer reload 不执行 Account shutdown。

1. 在 stop 入口关闭 Account admission、timer 和会创建新工作的 follow-up；停止通知会重新启动 Models 的 observer。
2. 处理当前有效 attempt 已在 mailbox 中的刷新结果。
3. 在飞 refresh 使用已有网络 deadline 等待一次结果，不重新发请求、不延长 deadline，也不立即按普通取消丢弃。
4. join 后接收唯一结果；合法结果在主线程尝试一次保存。关闭期间不发 Userinfo、不安装新身份、不启动 summary 或 catalog。
5. 保存成功或失败收口后，提交唯一 shutdown terminal fact，再销毁 owned secret、mailbox 和平台 ports。

这里对一个结果只执行一次保存；运行中已经保存失败的结果不建立新的待恢复对象。关闭期间保存失败保留阻断记录，下次启动要求重新登录。

关闭不能直接调用普通 completion drain 的全部后续逻辑，否则可能重新安排 timer、summary 或通知已停止的 Models。保持正常 Account → Product commit 顺序，关闭路径仅收口凭据和 terminal fact。单实例 lease 持有到存储与 teardown 完成。

transport 已选中完整刷新响应时，后到的 cancellation 不能把它改报 Cancelled；若 deadline/cancellation 先胜出且没有完整可用响应，则按结果不确定处理。不改变无关 Models 请求的取消语义。

已有网络 deadline 不等于 worker join 或系统安全存储的墙钟上限。必须验证真实 adapter 的 deadline/cancellation 行为，不能超时后销毁 worker 仍在使用的内存或 ports。强制结束按重启协议处理。

## 5 呈现与合同

不增加公开状态、错误枚举、Bridge 字段或命令。复用既有 `token_refresh_failed` 与 credential-store 错误，调整受影响文案：普通请求或配置错误不再声称“凭据过期”“后端撤销”或“已从设备移除”；被阻断时提供既有重新登录动作。

Host 始终校验刷新资格；错误文案不是 admission authority。现有 `refresh_schedule_failed` 重试入口只用于未被阻断的安全调度恢复，阻断后不发布可重试调度错误来替代原失败。

实施时主要更新 [Account 架构](account-architecture.md) 的错误分类、记录格式、重启及退出顺序，以及 [UI 设计规范](ui-design.md) 的错误说明。其他真源只在其合同实际变化时更新，不机械同步。保留 [验证规范](validation.md) 的正式入口、现有 SDK public API 和机器 Gate，不修改 allowlist。

## 6 实施位置

- `metask_client.zig`：refresh/Userinfo 的凭据失效判断，保留有界解析。
- `credential_store.zig` 与 `account_platform_binding.zig`：新增记录的窄读写接口、绑定和存储顺序。
- `runtime.zig` 与必要的 `state.zig` 接线：一个刷新阻断条件、移除泛化重试、mutation 前的 attempt/binding 校验。
- `network_attempt.zig`：保留能区分调用 transport 前后失败的结果信息。
- `account_coordinator.zig`、`app.zig`、`metask_http_transport.zig`：关闭收口、ports 生命周期和响应/取消竞态。
- 受影响的 Renderer i18n 与现有账户测试：修正文案和重试呈现；不修改公开错误类型或新增恢复页面。

沿用现有 owned token 生命周期，不引入长期保存失败对象、额外协调层、通用存储 facade 或新依赖。

## 7 最小充分验证

| 测试层                   | 必须覆盖                                                                                                                                        |
| ------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| OAuth client             | 完整 client_id 表单；401 invalid_client 保留凭据；400 invalid_grant 失效；未知/损坏/5xx 响应不重放；Userinfo invalid_token 不删新 refresh token |
| Account 与存储           | 记录写入失败零 HTTP；所有重启组合；新 token 写成功而记录清理失败；保存失败阻断；删除顺序                                                        |
| Runtime                  | timer、retry、重新登录取消与 restart 不解除未知阻断；迟到 Unauthorized 不删除新会话；正常 hard-expiry gate 不回归                               |
| Application 与 transport | mailbox 成功遇到退出；在飞刷新遇到退出；完整响应与取消交错；退出不启动 Userinfo/summary/catalog，ports 与 lease 持有到收口                      |
| Renderer                 | 普通请求失败不显示过期/撤销；使用既有登录和安全调度动作；reload 不触发刷新                                                                      |

以新 Runtime 读取同一 backend 的实际值验证各持久化边界；不能用旧进程内标志代替 restart。测试实际收录到正式 graph，当前 `test-account` filter 不自动覆盖任意 transport test。

定向开发入口：

```powershell
zig build test-account -Dtarget=x86_64-windows-gnu --summary all
npm --workspace @metawork/renderer run check
node --test scripts/account-panel.test.mjs scripts/account-menu.test.mjs scripts/native-sdk-credential-contract.test.mjs
```

退出组合与共享 owner 改动按验证规范运行关联生命周期或正式 Native graph；提交前执行适用的 `npm run check`、`npm test`。缺 canonical staged bundle 时明确失败，不跳过 AgentCore 后报告完整通过。

真实验收只补本次独立失败模式：Windows Credential Manager 与 macOS Keychain 中两条目的进程终止/重启行为，以及当前后端的正常刷新、正常退出重启、提交后丢响应。分清真正 Host quit、托盘隐藏、开发命令退出和强制终止；`npm run dev` 停止是否走 stop 回调须实际观察。

丢响应必须在后端已经提交后注入，验证本进程及重启后都不再发送旧 token。证据绑定客户端/后端 revision、迁移、平台、artifact、入口和结果，不输出 token 或摘要。未执行的真实平台或整栈验收明确列为未闭合。

## 8 交付顺序与完成条件

1. 错误分类、阻断记录和 restart 决策一起跑通，同时移除泛化重试。
2. 收口正常退出及 transport 竞态，不增加保存失败恢复流程。
3. 同步实际变化的合同与文案，完成回归和真实验收后提交。

可分审阅提交，不能单独发布“停止定时重试、下次启动仍重放旧 token”的中间实现。

完成条件：配置错误不误删凭据；未知旧 token 在当前进程和重启后不重放；正常退出不丢弃尚未处理的合法刷新结果；保存失败安全收口并可重新登录；相关正式检查通过，真实验收结论与证据一致。

持久化记录保留，是因为内存阻断无法覆盖重启；attempt 校验保留，是因为迟到失败可误删新凭据；退出收口保留，是因为它保护正常路径的登录连续性。保存失败或丢响应后的无感恢复另行等待后端阶段 C，不提前实现。

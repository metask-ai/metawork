# MetaWork Application 内部架构

> 状态：Application 内部 owner、事务、并发与恢复的当前规范
> 日期：2026-08-04

顶层模块、进程方向和跨模块安全边界见 [MetaWork 高层架构](architecture.md)。本文件只定义 Application 内部的 `app`、`account`、`workbench` 与 `agent` owner；实际目录和依赖见 [工程结构与所有权](project-structure.md)，AgentCore 线程与 ABI 生命周期见 [AgentCore 集成契约](agentcore-integration.md)，Metask Account 外部合同见 [Metask Account API 合同](metask-account-contract.md)。

## 1. 模块与 owner

本节只在顶层模块边界确定后描述 Application 内部 owner。Application 内部由四个 named product modules 组成：`app` 负责 composition、主线程跨 owner 提交协调和平台 capability 注入，不持有领域运行状态；`account` 的 Runtime 负责 Metask 登录、catalog、credential、attempt/effect/mailbox、恢复与 ExecutionConfig generation；`workbench` 拥有产品状态、Task、队列、投影与持久化语义；`agent` 执行并收口一个真实 Agent Run。Bridge 位于 Application 之外，但与它们同属 Zig Desktop Host。`metawork_account_contract` 只承载 Account 发布给 App/Bridge/Workbench 的有界纯合同，不是第五个产品模块。

Application 内部负责：

- 由 Account 在 Renderer 之外完成 Metask OAuth、目录查询、凭据持久化与 ExecutionConfig 生成；
- 由 Account Runtime 在 committed transition 之后产生有界 continuation，由 App 将其重新送入同一提交链；登录后的确定性目录准备留在后台，并只把真实歧义投影成用户动作；
- 由 App 在同一主线程 turn 内协调 Account prepare、Workbench no-fail install 和 Account commit；
- 由 Workbench 管理持久 Scheduled Task、触发游标、有界 occurrence history、Task、Run/maintenance record、唯一 active operation 槽、队列、取消协调和产品历史；
- 由 App 在 `<MetaWork data dir>/workbench` 打开并持有 Task history 的进程级单写锁，把 bounded load/atomic replace capability 注入 Workbench；codec、恢复校验、candidate commit、持久化 health 和所有 Workspace/Task 产品事实仍归 Workbench；
- 由 App 通过 Native SDK `.data` 规则解析并打开 `<MetaWork data dir>/workspaces`，只把可用或不可用的 managed root capability 注入 Workbench；由 Workbench 独占目录分配、Workspace 注册、Task 创建事务与回滚；
- 由 App 向 Workbench 注入原子 schedule persistence、wall clock、单一 Native timer、系统通知与后台窗口生命周期 capability；timer callback 只唤醒 Workbench due reconciliation，不直接调用 AgentCore；
- 由 Agent 管理 AgentCore Session、active Run/manual compact、callback binding 和有界事件泵；
- 管理跨会话产品状态，并向 Bridge 提供 canonical 产品 projection。

## 2. 领域状态与业务事务

### 2.1 Account 与 ExecutionConfig

Account 和 Workbench 是同级 owner，彼此不导入 runtime。Account Runtime 独占 OAuth token、PKCE、完整 API Key、平台凭据 locator、catalog attempt、mailbox/effect queue、当前默认选择、恢复 continuation 和 credential generation；Workbench 独占已安装的默认 runtime ExecutionConfig、被 Task 引用的 generation owned copy、不含 secret 的 Task execution binding descriptor/epoch history、Task admission、Workspace/Task/Run history 与 execution replacement gate。Bridge 只提交无 secret 的 catalog selection identifier、严格解码后的 expected catalog/execution generation 或其他 `AccountCommand`；Renderer 不能提交 provider、base URL、完整 credential 或未被 Host catalog 验证的模型配置。Account Runtime 使用与 projection 相同的 committed/candidate catalog 装饰规则形成 canonical `AccountView`，校验 generation 与当前发布的 API/model membership；App 只协调 Workbench replacement gate 和两位 owner 的提交，不重复这些 Account policy。Bridge 不读取 `AccountView` 或决定 selection admission。

Account 使用 `AccountSessionState` 与 `ExecutionState` 两个正交状态。OAuth refresh 失败可以进入 `reauth_required` 并保留 ready ExecutionConfig；默认 API Key/模型/base URL 变化递增 `execution_generation`。Workbench 安装新 generation 后把它作为后续 New Task admission 的默认配置；创建 Task 时建立第一个 binding epoch，为 Agent Session 固化对应 owned config，并在 Task/Run 记录不含 secret 的 account/profile、generation、API/Provider identity 和 model。既有 Task 的后续 Run 校验当前 binding epoch，不要求等于 Account 当前默认 generation。后续默认值变化不修改或停止既有 Task 的当前 epoch；旧 generation 在最后一个 Task、Session、Run、executor job 与真实 worker reference 释放后 secure-zero。

`execution replacement gate` 区分两类操作：

- 默认 API/模型切换可以安装新 generation，既有 Task 继续引用旧 generation，且其 admission 不被无关的默认切换冻结；默认安装只在新配置无法安全安装、目标 catalog 已失效或同一 generation 提交仍未收口时拒绝；
- 账号 identity 切换、退出登录和设备 credential 清理必须等待所有引用该账号 credential 的 Task/Session/Run/job/worker reference 归零，不能借默认切换绕过 secret lifetime。

唯一 committed-state 写路径为：

```text
Account Runtime.prepare(command | completion)
→ Account effect admission
→ Workbench.commitAccountFactNoFail(...)
→ Workbench.installDefaultExecutionNoFail(...)  [可选]
→ Account Runtime.commit(prepared)
→ dispatch committed Account effect
```

前五步在 App 主线程同一 turn 内完成，effect 只有在 committed swap 后才能启动；worker completion 再经主循环进入同一条链。任何校验或内部不变量失败都保留旧 committed state，并清零 staged secret；Bridge 不参与 prepare/commit，也不接触 credential。C1 登录只依赖锁定的 OAuth client/scope/loopback/profile 合同，成功先提交 `account_only`，不等待 API Key 或模型目录。

Renderer catalog selection 的同步拒绝顺序固定为：Bridge authority/wire validation，Account Runtime generation 与 published membership validation，Account state-machine prepare，Workbench execution replacement gate，最后进入上述 commit 链。Account 独占 selection、session、operation 与 attempt 的状态合法性；Workbench 独占 replacement gate；App 只安排顺序。`prepare` 成功但 gate 拒绝时必须销毁 prepared transition，不能提交 Account fact 或启动 effect；gate 打开后的 effect admission 失败必须平衡关闭。

`account_only` 是安全与持久化提交边界，不是可进入 Workbench 的产品 readiness，也不是要求用户手动启动 C2 的边界。C1 commit 完成后，Account Runtime 产生新的 catalog command，App 将其重新送入相同 prepare/admit/commit 链；历史选择仍存在且匹配当前 catalog 时优先恢复，单一候选自动采用，只有无法由锁定合同确定的多候选才进入 waiting-for-user。Renderer 不观察状态后发送隐藏命令。

每个 Account attempt 都有 Host-owned deadline、attempt identity 和唯一 terminal completion。浏览器未回调、网络悬挂、effect 启动失败和取消都必须收口到可恢复 committed state。幂等 catalog read 可以有限重试；OAuth code exchange、凭据持久化和结果不确定 mutation 不得自动重放。进入 credential persistence 前允许取消；持久化 effect 开始后撤销 cancel admission，直到 main thread 原子消费 completion，避免磁盘已提交而内存被取消回滚。Renderer command timeout 只释放本地交互并触发 snapshot resync，不能代表 Host mutation 失败。

production 网络接入受 [Metask Account API 合同](metask-account-contract.md)约束。C1 OAuth/login 独立提交 `account_only`，不打开 Workbench 或 Task admission；C2 使用 profile-aware API Key/model catalog，从精确 `group.platform` 生成固定 Metask AgentCore target。macOS 通过 OAuth/execution 双 family A/B slot 与单一 `manifest.json` schema 1 提交 `execution_ready`；Windows 只在 Credential Manager 保存一个 refresh token，在无版本 `account.json` 保存无 secret identity/API/model 选择，access token 与 Provider API Key 不跨进程。Windows 冷启动恢复 `account_only` 后必须先刷新 OAuth、重新读取 profile 并精确核对 profile；refresh response 提供 `account_id` 时也必须精确核对，省略时只能沿用已保存 account id 组成 identity，不能跳过远端 profile 验证。identity 验证通过后才重新加载 catalog，并只在历史选择仍受当前 catalog ownership 证明时于内存重建 execution。只有 Workbench 安装同一默认 execution generation 后才进入 Workbench。macOS manifest 仍只持久化一个默认 execution family；Windows 不消费该 schema。被既有 Task 引用的旧 generation secret 仅在当前进程由 Workbench/Agent Session own。Task persistence 只能另存不含 secret 的 binding descriptor/epoch history，不能据此重建 credential。Metask 内部实现只作为外部合同确认的证据，MetaWork 不修改其代码。

进入 Workbench 后的 API/模型切换仍由 Account owner 执行，不是 Renderer preference。每次 steady selection 都用当前 OAuth/profile 重新加载 authenticated API catalog，不能复用已 secure-zero 的旧 private catalog。candidate private/public catalog 与 committed public catalog 分槽；Account projection 发布候选目录所属的脱敏 API selection identity，Renderer 只能从该 owned catalog 选择模型。加载、取消、选择或持久化期间继续保留已提交 execution，成功后才原子安装新的默认 generation 并提交候选目录；其他 terminal outcome 丢弃候选并回到旧默认配置。Workbench 只用新 generation 接纳之后创建的 Task，既有 Task 继续使用自身 binding epoch。

跨 Host 重启的 execution binding 恢复必须 fail closed：

1. Workbench 先把历史 Task、Run 与 binding descriptor 恢复成只读 projection；
2. Account 恢复可执行默认配置后，Host 才能比较 account/profile、API、model 和 generation。macOS 可从 committed execution family 恢复；Windows 必须刷新 OAuth、重新拉取 catalog 并在内存重建，不能从 `account.json` 恢复 credential。全部精确匹配也只证明 credential binding 可恢复，不证明 AgentCore Conversation 可恢复；
3. binding 或 Conversation 任一不可恢复时，Task admission 保持关闭。当前 Workbench 已恢复跨 Host 的只读产品历史，但只发布 typed `session_recovery_unsupported`，不注册伪 `resume`、`rebind` 或临时的“从历史新建”路径；
4. 未来 Conversation 恢复或重建通过独立能力验收后，无法精确恢复旧 binding 的 Task 发布 `rebind_required`。用户确认只提交 Task identity、expected binding epoch 和当前 catalog selection identifier；Host 重新校验 Workspace、account/profile、API→model 归属和无 non-terminal Run；
5. rebind commit 原子关闭旧 Session owner、创建新 binding epoch 与新 Agent Session，并追加不可改写的配置边界事件。它不修改旧 Run 记录，也绝不热替换 live Session。

因此“默认配置切换”和“历史 Task rebind”是两种不同 mutation：前者不触碰既有 Task，后者只由用户对单个只读 Task 明确发起，并受 optimistic epoch 与 admission 校验保护。

### 2.2 Workspace 与 Task admission

Workspace 是 Workbench-owned 产品对象，而不是 Renderer 从 Task 路径派生的 convenience view。Workspace record 具有 immutable `origin = user | managed`：User Workspace 由用户选择或重新授权，一个 record 可承载零到多个共享文件上下文的 Task；Managed Workspace 由 Workbench 分配，一个 record 精确归属一个 Task。两者共用同一个 registry、Task 引用和 AgentCore Session admission，不共享选择策略、容量池或 record 生命周期。Application 的 canonical projection 发布 stable identity、origin、optimistic epoch、canonical root、display label、authorization/removal outcome 与聚合 Task signals；每个 Task 引用的 Managed Workspace 必须在同一 projection 中存在。一次性用户目录能力由 Bridge/Native capability 生成并在同一 `workspaces.choose` Host 命令内消费，Renderer 只得到 Workspace identity；managed root/path/key 永不进入 Renderer 请求。Task 创建绑定 expected execution generation，后续 Run 绑定 expected binding epoch，Workspace mutation 绑定 expected Workspace epoch；Host 对 window、ownership、catalog membership 与 admission 重新校验。预期业务拒绝编码为 typed result，非法 payload 与 authority failure 仍由 Bridge fail closed；精确 wire 语义见 [Renderer Bridge 合同](renderer-bridge-contract.md)。

App 使用现有 `app_dirs.resolveOne(..., .data)` 结果派生 `workspaces` 保留根，并在启动时尝试创建、canonicalize 和打开该目录。失败只投影 `managedWorkspaces = false`，不得阻止 Account、User Workspace 或普通 Workbench 启动。成功后 Workbench-owned `ManagedWorkspaceStore` 只通过已打开的 root handle 相对创建随机 `u64` 的 16 位小写 hex 子目录，exclusive create 最多尝试 8 次，并验证结果严格位于 canonical managed root。managed root 及其子目录不得注册为 User Workspace；分配失败不得回退到 cwd、home 或共享目录。

Workbench 的 Task workspace request 是 `existing(workspace_id, expected_epoch) | managed`。Renderer/Bridge 对外使用 `manual | automatic` intent，并分别严格映射到这两个既有 admission variant；交互式 New task 与 Scheduled Task 不建立第二条 Task 创建路径。managed admission 先证明 execution、Task slot、managed Workspace slot、Session 与 shutdown capacity，再创建目录、注册 `origin=managed` temporary Workspace、创建 Session 并发布 Task；发布前任何失败用局部 rollback/`errdefer` 释放 Session/record 并删除本次创建且仍为空的目录，发布后的 Run 失败不回滚 Task 或目录。User Workspace record capacity 与 `max_tasks` 约束的 managed record capacity 分槽，后台创建不修改 Host selected Workspace、User recent order 或 Renderer draft scope。owning Task 物理删除且 Run event、worker、Session 与 catalog 全部 quiescent 后释放 managed record，但不删除真实目录；shutdown 与重启也只释放进程内 record，不扫描、接管或删除旧目录。目录持久存在不是 Task 恢复协议。

App 在 composition 时只解析一次 existing canonical user home，并以 immutable capability 注入 Workbench；Renderer、Bridge payload 和 Workspace selection 都不能覆盖。Workbench 把 AgentCore catalog discovery 作为现有 bounded Executor 的一种 job：worker 只产生 Agent-owned acquisition，主线程按 Workspace id、epoch 和 request generation 提交或丢弃。User Workspace current catalog 持有唯一 opaque lease 与有界产品 projection；Task 创建在 Agent Session 前完成容量证明并复制独立 pinned projection，同步借用 current lease 绑定 Session。首期 Managed Workspace 只接纳 Text Task，不启动 Workspace catalog job、不发布 refresh 动作，并以 null catalog lease 创建 Session；Skill managed admission fail closed，直到 root-specific acquisition、identity、容量和 shutdown 通过独立验收。Task refresh 只从已经提交的 User Workspace catalog 进行、只允许 idle Session，并在 Agent refresh 成功后替换 pinned projection。shutdown 先停止/join Executor、收口 catalog job 并释放全部 Workspace lease，再允许 Agent Runtime destroy；不建立第二 scheduler、隐式文件监听或 Renderer Skill loader。

### 2.3 Scheduled Task

Scheduled Task 是 Workbench 内新的可测试不变量，不是第六个 product module。`workbench/scheduled_tasks.zig` 拥有结构化 recurrence、bounded definition/occurrence storage、跨恢复稳定的 `(scheduledTaskId, plannedAt)` identity 与纯状态转换；独立的 `workbench/scheduled_task_persistence.zig` 拥有无 secret codec、原子 candidate commit、恢复校验和 schema revision。定义只保存名称、Text instruction、recurrence 与无 secret execution facts，不保存 Workspace target、Skill identity、catalog revision 或 Skill 参数；需要 Skill 的意图仍属于 instruction，occurrence 只生成普通 Text Run。`projection.zig` 在每个 occurrence 中固定请求新的 Managed Workspace，再进入真实 Task admission。当前仍处于 pre-release 开发期，Scheduled Task persistence schema 固定为 `1` 并对定义结构原地 hard cut：只接受当前 shape，不保留旧字段的解析、双写或迁移；旧开发数据按现有损坏恢复路径处理。

App 只注入平台 capability：产品数据目录中的原子读写、wall clock、单一 Native timer、notification，以及 tray/hidden-window 生命周期。主窗口 `close_policy = hide` 后 Host、Workbench、Executor 与 timer 都保持存活；tray 是重新打开窗口和显式退出的唯一入口。后台不是 Renderer timer，也不是 Agent Runtime capability。App 重启时必须先恢复并校验 canonical Schedule store，再 arm 最早 due time；若最近计划时间已经过去，只对每条定义协调一个最新 occurrence，不遍历补跑全部历史。store 损坏或提交结果不确定时 fail closed，保留可诊断 persistence health，不能假装成空列表。

到期回调在主线程要求 Workbench 最多提交一个 occurrence，再为下一次 due time 重新 arm。成功 occurrence 调用既有 Task 创建、命名与 `runTaskAtBinding`，因此复用同一 Session、Run record、Executor、event pump、permission 和 snapshot 路径；不能新增绕开 admission 的 schedule queue、schedule worker 或直接 AgentCore call。系统通知只消费已经提交的 Workbench occurrence/Task fact，通知失败不得伪造 Run cause或回滚 terminal fact。

### 2.4 Skill catalog 与本地资产管理

Workbench `TaskRunInput` 只有 Text/Skill 两个分支。Skill admission 在建立 Run record 前校验 Workspace/Task epoch、pinned revision、稳定 `skill_id`、参数数量、UTF-8 与产品容量；Run history 保存 admission 时的 invocation/display/arguments，不随后续 catalog 改写。AgentCore 仍负责最终参数、资源和 policy 校验；`stale_catalog`、`skill_not_found`、`invalid_skill_arguments`、`skill_policy_violation` 与 `skill_unavailable` 形成独立产品 cause，保持 Session 可复用且不自动刷新或重放。

Skill 中心在 revision 6 typed catalog 之外增加 Workbench-owned 本地资产管理层，但不形成新的产品 owner、AgentCore loader 或 Session execution binding。`workbench/skill_management.zig` 拥有 personal/project inventory、安装 provenance、独立 `install_id`、staged import/export、原子 publish/rollback、管理 health 和持久 store；App 只注入 canonical user home、产品数据目录原子文件能力与 Native file/folder picker，Bridge/Renderer 不持有物理路径。`agent/catalog.zig` 继续独占 AgentCore query/lease 与运行时 projection；runtime identity 始终是 `catalog_scope_id + skill_id`，不得被 `install_id`、目录名或 invocation 取代。管理 inventory 可以在已经授权的 canonical `<home>/.agents/skills` 和 `<workspace>/.agents/skills` 内枚举直接 Skill entry、读取受限 package 内容并建立 provenance，但不得自行决定 runtime winner、conflict、health 或 catalog revision；这些结果只来自 reconciliation 后的 AgentCore projection。

当前本地来源只有 `local_package`、`local_directory` 与 `external`。普通 Task 写出的 Skill 没有可靠发布事件，因此不得虚构 `created` 来源：写入项目 Skill root 后表现为 external project asset，打包后再导入则按真实本地来源记录。公司市场未来只能作为新的 package acquisition adapter 接入同一 staged transaction；服务上线前不注册 wire tag、UI 占位、搜索、排名、在线更新或 GitHub/skills.sh 依赖。MetaWork 不建立中央 Skill repository、symlink/copy fanout、Agent adapter、Preset 或第二份 catalog。

`.skill` 是 MetaWork 的可交换 ZIP envelope；规范导出在 archive root 直接包含精确大小写的 `SKILL.md` 和同一 Skill 的相对资源。导入普通 `.zip` 时只允许 archive root 本身或唯一 wrapper directory 成为候选 Skill root；多个 `SKILL.md`、多个候选根或 root 缺失均失败。归档和目录 import 都必须在目标 root 之外 materialize 为 staged tree，并拒绝 absolute、drive/UNC、空、`.`、`..`、NUL、非 UTF-8、重复归一化、Windows 保留名/尾随点空格路径，拒绝 symlink、hardlink、device、socket、FIFO 与其他特殊 entry；当前合同上限为 512 个 regular files、64 MiB 解压总量、16 MiB 单文件、512 UTF-8 bytes 相对路径和 128 UTF-8 bytes 单 path component。`.skill` 压缩输入上限为 32 MiB。Importer 只读取/复制 regular bytes，不执行脚本、解析远程链接或发起网络请求；export 服从同一边界并使用稳定相对路径排序，不包含绝对路径、provenance store、credential、`.git` 或平台 metadata。

Import preview 使用一次性、window/source-bound opaque staged capability，并在 preview identity 中绑定 content hash、候选名、source kind、容量结果和 expiry；Renderer 提交的 commit 只能包含该 preview identity、显式 target `personal | project(workspace_id, expected_epoch)` 与冲突确认 generation。目标 entry 由 Host 从受限候选名生成且必须保持在 canonical Skill root 直接子级；Renderer 不能提交目录名或路径。Publish 在同一 filesystem 上用 sibling candidate 与 backup 进行 rename transaction：先重新验证 capability/hash/target/generation 和相关 active-operation gate，再把既有 target 移到唯一 backup、candidate 移入 target、执行 AgentCore catalog reconciliation，最后删除 backup。明确映射到候选 invocation/scope 的 definition/resource/conflict failure 会恢复 backup；catalog transport/runtime 暂不可验证时保留 target 与 backup transaction record，发布 `pending_verification`，只允许 Retry 或 Uninstall，不能声称 ready。恢复时 fail closed 地完成或回滚唯一 transaction；不扫描、接管或删除 root 外目录。

Personal mutation 在任一可能消费 personal catalog 的 Task 存在 active operation 时拒绝；project mutation 在目标 Workspace 的 Task 存在 active operation时拒绝。已经发布的 mutation 不热更新 Session：Workspace current 与顶层管理 catalog 通过显式 transaction 重查；Task pinned catalog、draft identity 和参数保持原值并进入 stale 提示，只有用户在 idle Task 上显式 refresh 并重新选择后才能提交新的 Skill Run。Uninstall 与 replacement 使用同一 gate/backup/reconciliation；external asset 只有在 inventory 能证明它是 canonical Skill root 的直接子级、没有 link/reparse escape 且持有对应 personal/workspace authority 时才开放导出或删除，否则只以 `externally_managed` 展示。

Skill management persistence 是 Workbench-owned、无 secret、原子 candidate commit 的独立 schema 1 store。记录仅保存 `install_id`、source kind、目标 scope/workspace identity、Host-only target entry、content hash、安装/重新导入时间、management state 与未完成 transaction recovery facts；不保存 Skill body、raw path 到 Renderer、catalog handle、credential 或 Task binding。当前仍处于 pre-release，schema 原地 hard cut，不解析、双写或迁移被替代的开发 shape。对应 wire 与 transport 只由 [Renderer Bridge 合同](renderer-bridge-contract.md)定义。

### 2.5 Identity 与 credential redaction

Workbench 单独分配稳定的产品 Task identity，并在 Task owner 内保存 Agent Session route identity；AgentCore event 与 event-projection failure 都只按 route identity 回到 owner，Bridge snapshot 与 mutation 只使用产品 Task identity，二者不共享生成器也不依赖数值相等。Task binding descriptor 包含无 secret 的 account/profile、API、Provider、model、generation 与 binding epoch；内部执行使用的 raw model 与 Renderer projection 的 selection identity 分开持有。
credential redaction 是 owner 释放协议的一部分，而不是 snapshot 时的偶然过滤。安装新 credential 前先永久清洗所有既有产品投影；替换或清空默认 execution、释放 quiescent Task-owned execution 前再次使用即将释放的 credential 清洗 Workspace、Task、Run、tool 与 UI history，然后才 secure-zero。序列化仍扫描所有 live credential，并在前缀重叠时采用最长匹配，作为释放前的第二道防线。credential 是 opaque bytes；若匹配发生在 UTF-8 codepoint 内部，所有 ingestion、流式跨 chunk 清洗与序列化路径都必须扩大到完整 codepoint，禁止为了替换 secret 产生非法 UTF-8 产品事实或 JSON。

## 3. 并发与生命周期

```text
SessionRuntime
├── AgentCore Session handle
├── Conversation 所在 AgentCore Session 生命周期
├── task binding epoch 对应的 owned ExecutionConfig generation
├── current_operation: none | RunJob | CompactJob
├── bounded input/event state
├── synchronous UI wait state
└── callback lifetime guard

RunJob
├── run_id
├── pending external interruption（Workbench admission/handoff 窗口）
├── executor slot
└── run-scoped Host scratch

CompactJob
├── monotonic operation_id
├── executor slot
├── advisory handoff / pending interruption
├── preallocated bounded terminal diagnostic storage
└── allocation-free write-once compact terminal publication
```

- 每个 Session 至多一个 in-flight operation；Run、manual compact、Session mutation 与 destroy 互斥；
- 每个 Session 在创建时绑定一个 immutable ExecutionConfig generation；默认 Account 配置变化不热替换 live Session，显式 Task rebind 也必须创建新 Session；
- Host 使用有上限的 Workbench executor；
- 空闲 Session 不占 worker；同步 Run、同步 UI wait 和 manual compact 占用 execution slot；
- Workbench 创建、排队、停止并销毁 bounded Executor；Agent Runtime 不接收 Scheduler capability，worker 从 Workbench queue 主动进入 Agent Run；
- Scheduled Task 的 recurrence、持久触发游标、wall clock 和 timer admission 由 Workbench 拥有；App 只提供 store/timer/notification/tray capability。它只向同一 Task/Run Executor 提交真实产品工作，不把 scheduler capability 注入 Agent Runtime；
- Bridge/main thread 不执行长耗时 Run，也不等待 permission；
- 只有 `agent/` import `metask_agentcore`；App 让 Agent 内部完成 ABI discovery，Workbench 通过 Agent 公共 validated types 消费，Bridge DTO 不暴露 SDK enum/owner/handle；
- `account/contract.zig` 不导入 Native SDK、Agent、Workbench、Bridge 或 AgentCore；只有 `account/platform.zig` 适配 Native SDK，Account Runtime 消费该窄平台 seam；Workbench/Bridge 只导入纯 contract，不导入 Account runtime；
- Account Runtime 的 committed shutdown effect 必须在 Native SDK runner 返回前取消 Account timer、join attempt worker 并释放 platform seam；之后的普通 `deinit` 只释放不依赖平台存活的 Account 内存；
- Agent 只通过有界 notifier 报告事件就绪，App 负责把 wake 安全提交到平台主循环；精确状态、retry 与 deadline 见 [AgentCore 集成契约](agentcore-integration.md)；
- Renderer response、revision、snapshot 和 connection failure 作为 typed transport fact 进入 Workbench policy，默认只拒绝、重试或断开，不中止后台 Agent Run；

AgentCore Session、callback、UI request、event pump、close race、错误映射与 Runtime 销毁顺序只由 [AgentCore 集成契约](agentcore-integration.md)定义。

## 4. 产品状态、持久化与恢复

当前同步 baseline 应形成以下可靠 Host 状态：

- 用户提交的消息；
- 已完成的 assistant 消息；
- 工具调用和结果；
- 同步审批决策；
- Run 的 running/waiting/stopped/completed/cancelled/failed/interrupted 状态；
- manual compact 的 queued/compacting/stopping 与 append-only terminal history；
- WebView reload 所需的当前 Host view snapshot。

Workbench 在 admission 时为每个 Run 或 compact 建立稳定 record slot 和 bounded terminal diagnostic storage；Run 另有单调 generation。executor worker 入队前直接取得 Task-owned stable record reference，并在 queued cancellation、执行失败或 terminal publication 收口后精确释放；该真实引用非零时 Task record 不得物理释放，删除命令返回 `task_busy` 且不改变内存或持久化状态。引用归零后的删除先构造候选、提交 Task store，再物理释放 Task 与相应 managed Workspace；提交失败必须恢复候选，成功响应不能先于 durable commit。Agent 对已开始的 operation 返回自包含、不可变的 terminal result；Workbench 将其 allocation-free、no-fail、write-once 地提交进预留 payload，`published` release-store 是唯一 terminal linearization point，完成前不得 notify、释放引用或调用外部 owner。queued-before-execute 由 Workbench 直接生成 pre-execution 产品结果。Session snapshot 只描述 live lifecycle，不再承载历史 terminal facts。

Compact 的 executor handoff 与 pending interruption 是 advisory control fact，不能覆盖 terminal payload。Workbench main thread 按 `terminal publication > pending interruption > worker handoff` 派生 `terminal / stopping / queued|compacting` 产品 phase；独立 cancellation atomic 即使在 terminal race 后被设置也必须被忽略。Compact 没有 Run event stream，因此不复制 Run 的 final event-drain product gate；snapshot acquire 到 published payload 后即可消费全部 terminal fields 和 diagnostic bytes。

Workbench 将 `DurableTaskRecord` 与 `RuntimeAttachment` 分开：前者拥有 Task 产品历史和最小 `closed` 产品终态，后者独占 Task 级 Session、ExecutionConfig owned copy、catalog lease、thread/reference 以及 open/closing 的进程内协调。Run/Compact 内存 record 在 quiescent 前仍包含 terminal control 与临时 redaction secret；Task persistence codec 逐字段白名单编码无 secret 的 Workspace/Task/Run/tool/UI/compact 产品事实，pointer、atomic、control payload 和 credential 不进入 wire，Task execution 释放前同时清空 Run 与 Compact 的 secret 引用。App 在 restore 前取得 `workbench-state.json` 的 OS exclusive writer lock，读取上限为 16 MiB；commit 使用同目录随机临时文件、file sync、原子 rename 和最终文件/目录 sync。store 不存在表示首次启动；read failure、损坏、definite write failure 与 outcome unknown 分别进入 typed health，保留原文件并关闭新的 Task/Workspace mutation，不能静默降级为空状态。Host decoder 在安装候选前校验正数 recent order、Run phase/outcome、Tool state/error、Compact→Run、Compact phase/cause 和 activity order 等跨记录不变量，不能把 Renderer 必然拒绝的状态标为 ready。

Renderer reload 重建仍存活 Host 的视图；Host 重启从 Workbench store 重建只读产品历史。没有 live owner 的 non-terminal Run/compact 保守收口为 interrupted，不重放输入、工具或 permission；任何恢复 Run 中未完成的 running Tool 都不进入 projection，已完成 Tool result 保留。完成态 Tool result 是 Run terminal 前的持久边界，text chunk 与 progress 只保留在 live projection。canonical Metask AgentCore revision 6 已提供 checkpoint export/restore 与 Session description，但 MetaWork 尚未实现 checkpoint store、exclusive restore、execution binding 对账和 terminal reconciliation；因此恢复 Task 仍不创建 Session，`conversationRecovery` 保持 false，continuation 原因为 `session_recovery_unsupported`。恢复后的 open Task 仍能把 `closed` 产品终态原子提交后进入可删除状态；该动作不恢复或伪造 Session。Conversation/checkpoint 跨进程恢复必须通过独立能力验收后才能接通；MetaWork 不读取私有 transcript、不保存 opaque handle，也不建立 ABI 兼容实现。

Account attempt 与 Renderer 生命周期解耦：Renderer reload、短暂断连或视图同步失败不能遗失 Host 中的 deadline、取消能力或 terminal result。Workbench Account projection 必须发布产品 readiness 和 Host 允许的用户动作；Renderer 不从内部 operation、error code 或候选数量自行发明 continuation。

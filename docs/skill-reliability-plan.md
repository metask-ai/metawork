# Skill 可靠性修复方案

状态：本轮收尾，A/B 已交付，C 未实施。本文是实施计划与交付边界记录，不是规范性合同或 decision record；以下 C 的设计与验收要求不代表已经生效。

- A：`c9740f5f`，可信 enablement 的明确写失败恢复。
- B：`465fa975`，精确资产的当前进程文件事务恢复与 Retry。
- C：仅以 `b7687ffa` 固定历史恢复后 Workspace id 复用的安全反例；没有上线 id-only 归属、记录继承或退休逻辑。
- 本轮不扩大 Workspace admission、历史恢复或持久化格式，不为 Skill 修复冻结历史故障下仍可使用的主流程。C 保留为未完成项，不能将本轮收尾视为三批全部完成。

## 1. 目标、根因与取舍

本次处理三个已证实的问题：

| 问题 | 根因 | 修复 |
| --- | --- | --- |
| Enablement 一次明确写失败后，后续刷新与重试也被拒绝 | 用 persistence health 的 ready-only 判断代替 committed policy 的可信度 | 统一可信度判断，保留旧 committed 值并允许再次提交 |
| 文件事务失败后留下 recovery，但当前进程没有可执行入口 | durable phase 已存在，调用层却只处理成功后的 catalog verification | 复用现有 Transactions.recover，补齐失败入口、Retry 分派和变化发布 |
| 移除失败丢 override，旧 inventory 失配并占用容量 | 把操作 freshness 的 epoch 同时作为长期归属键；又用 visible 集合做持久数据清理 | 按 Workspace id 查归属，按当前 epoch 授权；只回收已退出 registry 的无 recovery 记录 |

明确采用以下产品语义：

- 同一个仍保留在 registry 中的 Manual Workspace，无论经历多少次移除失败，Skill override 和管理记录都保留。
- 移除成功只隐藏该 Workspace、撤销当前授权；不删除 Skill 文件，也不立即删除归属记录。
- 同一 registry record 重新授权后恢复记录，所有新操作取得当前 authority。旧 epoch 不回退，已有 freshness 校验不放宽。
- 隐藏 record 已被复用后，同一路径再次添加是新的 id，不自动继承旧记录。不承诺“路径相同就永久继承”；当前 allocator 可能在尚有空槽时优先复用可回收的隐藏 record，本批不顺便改这项策略。
- 文件操作明确失败时支持同进程恢复；management store 的 write_failed / outcome_unknown 仍冻结到重启后的严格加载与恢复。重启是重新尝试，不保证目录不可达、文件仍被占用或 canonical 损坏时一定恢复成功。

不做 ownership epoch、Workspace record 新字段、management schema 2、retired_scopes、detached recovery 列表、canonical reload、第二个 Retry command 或新的持久事务状态机。

来源配置首次缺失必须先 durable 提交默认值的合同不变。AgentCore discovery/winner、既有 Task pinned authority、Task epoch 变化后的 refresh/attachment 恢复、ZIP 导出优化不在本次范围。

## 2. 批次 A：可信 enablement 的明确写失败恢复

### 2.1 一条可信度规则

Skill policy owner 定义唯一的 enablementTrusted 判断：只有 ready、write_failed 为真。Runtime、View 和 Control 消费这条规则，不各自复制 health 枚举条件。

| Health | 使用最后 committed policy 编译新 catalog | Enablement mutation |
| --- | --- | --- |
| ready / write_failed | 允许 | 通过当前 authority、catalog revision、selection revision 等既有检查后允许 |
| outcome_unknown | 不允许新 authority/admission | 冻结 |
| unavailable / read_failed / corrupt | 不允许 | 冻结 |

具体修改：

- compileCatalogSnapshot、setEnabled、reconcileEnablementNoFail、View 的 effective policy/canSetEnabled、Control 的显式 Task catalog refresh 统一消费该判断。
- 明确写失败不安装 candidate，不推进 selection revision，不把旧 policy 改成默认全启用。
- 成功持久提交后安装 candidate、完成既有 no-fail authority 替换，并将 health 恢复 ready。
- 无实际写入的 no-op 不清除 write_failed；不能把没有验证过的持久化能力显示为恢复成功。
- 数组构造、clone 等尚未触及 store 的资源失败保留原 health；不冒充磁盘写失败。
- 删除 policy.matchManagedContribution 中已证明不可达的末尾分支。

批次 A 暂时保留现有 enablement reconcile 的调用与数据结构，只修其可信度和错误分类；批次 C 再删除基于 visible/epoch 的清理语义，避免在 A 中夹带身份改变。

### 2.2 验收

必须通过“写失败 → 后续 catalog refresh → 再次提交成功”的完整链路，观察 policy、selection revision、health 与 authority。补充 outcome_unknown 冻结、纯准备 OOM 不污染 health、no-op 不伪造恢复、Task 显式 refresh 继续使用 committed policy 的反例。

## 3. 批次 B：复用文件事务恢复，补齐当前进程入口

### 3.1 只复用 phase 决策，不照搬旧包装函数的错误分类

Transactions.recover 继续是唯一的物理恢复实现；不复制其 prepared / backup_renamed / candidate_published / reconciliation_pending / reconciled / rollback_pending 决策。

触发入口收口为：

1. install、allow_replace、reimport、uninstall 的文件事务返回 FileTransactionFailed，且 management health 仍为 ready、该 install_id 仍有 recovery 时，立即尝试一次恢复。
2. 用户对 recovery_required 资产点击现有 Retry 时，恢复该精确 install_id。
3. 启动或 Workspace 重新授权时，现有 scope 恢复循环调用相同的单资产恢复 helper。

同步失败的恢复放在仍持有 install_id 和本次已授权 root 的调用层，避免为了找出失败资产而扫描整个 scope、顺带推进其他事务。尚未建立 durable transaction 的失败不启动恢复。一次 Retry 本身失败后不再套一层自动 Retry。

原始操作仍返回原错误；恢复是否改变状态独立发布。若恢复进入 pending_verification，保留真实 pending，并在 admission 允许时登记新的精确 verification；不能把“恢复完成”直接翻译成“Skill 已验证可用”。

旧 recoverNoFail 包装需要一并修正：

- pending ID 数组分配失败、打开目标 root 失败、时间来源暂不可用，不应被错误标为 management canonical 的 write_failed/read_failed。
- 这类失败保留 transaction，给出实际恢复失败原因，允许条件恢复后显式 Retry。
- 真正 persist 的明确失败和结果不确定仍更新 management health 并冻结。不能把已改变内存 phase 后的提交失败误当成纯准备失败。
- 任何 recovery 都不得保留跨 inventory 删除/变更的 Asset 借用；操作后按 install_id 重新查找。

### 3.2 准入与投影

物理 recovery 要求：management ready、Transactions 存在、当前根授权有效、相关 Task quiescent、未 shutdown、没有 active management reconciliation，且目标 scope 没有冲突中的 job/reschedule。它不是绕过 authority 的后门。

来源配置只约束 catalog verification，不撤销已有事务的物理恢复职责。物理恢复成功但来源尚不可信时保留 pending，不排队假验证；后续显式 Retry 再尝试验证。其余 scope 的普通 catalog job 不因本次没有 reload 的恢复被一律禁止。

投影从实际事实派生：

| 资产事实 | managementState / 行为 |
| --- | --- |
| 无 recovery，且原 state 为 ready | 继续走普通管理能力 |
| recovery 存在，且 state/phase 不同时为 pending_verification/reconciliation_pending | recovery_required；包括 reconciled 后清理未完成，不能显示 ready 或开放普通替换 |
| 正处于 reconciliation_pending，state 为 pending_verification | pending_verification；Retry 登记新 verification |
| management store 不可信 | 保留可见诊断，canRetry=false，提示重启后重新加载与恢复 |

recovery_required 只扩展 Snapshot/Renderer 枚举，不写入现有 Asset.state 或 phase。canRetry 必须结合真实恢复/验证 admission；health ready 不是充分条件。Host 执行时再次检查，不能只信 Renderer 按钮。

health 错误必须在中心级可见：最终 persist 失败可能已经让资产从内存消失，因此不能只把“需要重启恢复”的说明放在资产行上。本批不为此增加 store recovery 命令。

### 3.3 变化发布与并发

- Skill 通过局部 changed 标记报告资产增加/删除、state、recovery phase 或可观察恢复状态的变化；success 和 error 路径均可取到，不能只把字段加到成功的 MutationResult。
- Control 合并 changed 与已有 previous_health 比较，一次用户操作最多发布一次必要 revision。拒绝前未改变事实不发布；无变化的重复恢复失败不形成 publication 循环。
- recovery helper 不自动递归调度；Runtime 在结果明确后决定是否 scheduleReconciliation。
- active verification 仍精确绑定 install_id、operation、当前 scope/epoch 和 request generation；普通刷新、取消后的 completion、过期 job 都不能结束事务。
- enqueue 失败按现有规则清掉对应 in-flight，保留 durable pending；不增加 timer 或无限 I/O 重试。

### 3.4 验收

覆盖 fresh install、allow_replace、reimport、uninstall 的 rename 边界，首次故障后当场恢复、二次故障后 recovery_required、解除故障后 Retry 收敛。分别验证回滚、转 pending、最终完成，不把所有 phase 都要求为回滚。

覆盖 root 暂不可达后恢复、准备 OOM、恢复过程中 persist 失败、资产已删除后的全局错误展示、错误返回仍发布变化、sources 不可信下的物理恢复，以及 stale verification/QueueFull 交错。持久化失败用真实重启和 strict decode 证明恢复，不能以同进程重读替代。

## 4. 批次 C：按 id 归属，按当前 authority 操作

### 4.1 不把所有相等判断改成 id-only

保留精确 scope 相等用于 authority 和异步验证，另设有明确用途的 sameOwner 判断用于持久归属查找。不增加持久 owner 类型，不把一个语义模糊的 eql 用于两类判断。

| 使用处 | 比较依据 |
| --- | --- |
| Workspace enablement policy、资产归属、归属冲突、退休候选 | Workspace id |
| 当前 catalog、canonical root capability、Bridge expected epoch、staged preview | 当前 Workspace id + epoch，及各自已有 token/revision |
| management verification/completion | 当前 id + epoch + request generation + install_id + operation |

存储里的 workspace_epoch 保留原字段、非零校验和数字，作为记录建立时的 epoch；不因为移除或重新授权而批量重写。新记录写入创建时的当前 epoch。它不再作为归属唯一键，也不能直接充当当前命令 authority。

调用链必须完整改通：

- assetScope 不再把存储里的建立 epoch 当作执行 scope。按 install_id 查归属 id 后，Control/Runtime 从当前 Workspace binding 取得实际 scope，并检查 manual、visible、authorization、Task quiescence。
- canonicalBase、openManagedRoot、read/export/reimport/uninstall/retry 使用已检查的当前 scope。根 capability 自己的 epoch 检查继续精确；Asset 与该根的归属关联才使用 sameOwner。
- 重试旧事务时重新创建当前 epoch 的 verification attempt；不修改或复活旧 job 的 token。
- View 关联当前 catalog、scope 标签和操作能力时解析当前 binding。可操作项目行的 workspaceEpoch 表示当前命令 epoch，不能沿用库存建立 epoch。
- Renderer 按 workspaceId 分组和找标签；开关请求从同一最新 snapshot 中取得当前 Workspace epoch、catalog revision 和 selection revision。不存在当前 binding 时不能从资产旧字段拼出请求。
- 现有只携带 installId 的命令按执行时的当前 authority 授权；它们没有请求起始 epoch，不能宣称具备一个 wire 中并不存在的 stale-page token。本批不扩展其 payload。已有 expected epoch 和 staged capability 的命令保持原校验。

移除同步失败、异步 close_failed、重启后重新授权走同一归属规则，不再分别实现跨 epoch 迁移。启动恢复不假设持久文件会还原 removing：当前格式恢复的是 visible/hidden record 与重新授权要求。

### 4.2 当前 schema 1 数据必须保全

不升级文件格式，不静默丢弃旧版合法记录，不按“同 id 取最大 epoch”整组覆盖。

- Management 保留每个 install_id 的完整 asset 与 recovery。相同 Workspace id 下不同 target_entry 是不同资产，全部保留。
- 相同 id + target_entry 对应多个旧资产时，保留记录并派生归属冲突；禁止对该冲突目标自动恢复、替换或卸载，不按 epoch 猜哪个 backup 可以删除。其他无冲突资产不受该目标冲突影响。
- Enablement 先按现有 schema 严格读取全部 policy。一个 id 只有一条旧 policy 时直接按 id 使用；多条且完整 override 映射一致时可形成一个有效视图，effective revision 取不小于各条的已提交 revision。
- 同 id 的多条 policy 映射不同，不能把缺项擅自解释成需要合并的 override，也不按 epoch 或单个 revision 猜用户意图。保留全部原记录，拒绝该 Workspace 的新 policy authority/mutation 并发布冲突诊断；User policy 和无冲突 Workspace 仍可用。
- 本批不增加自动冲突裁决或接管 UI。诊断必须说明保留了数据、没有自动选取；不能把旧版合法但现在归属有歧义的数据笼统当作可清空的损坏文件。
- decoder 仍拒绝非法字段、重复 install_id、损坏/未知 schema、无合法 recovery 的 pending_verification。不能为兼容歧义绕过结构和 phase 校验。
- 任何后续提交都保留未解决记录。等价 policy 的折叠若会写盘，必须先形成完整 candidate，成功提交后才安装，且不降低 selection revision。

### 4.3 隐藏记录保留与退休

删除现有“visible Manual id+epoch 集合 → Store.reconcile 删除其他 policy”的整条语义，包括启动、打开其他 Workspace、removing 中的调用。不能只删 removeWorkspace 中的一处调用。

隐藏 Workspace 只有在下列条件均成立时才允许 registry slot 复用：

- 既有规则要求的 Task、job 等引用已消失；
- 该 id 没有任何 recovery 资产，包括 pending_verification；
- management inventory 足够可信，可以证明上一条，而不是把不可读 store 当成空 inventory。

不能证明时保留隐藏 record 与 root。Workspace 仍可移除；如果没有可用槽位，新增不同 Workspace 使用现有容量拒绝并说明保留原因。重新授权原 record 后仍可显式恢复事务。不在移除阶段操作 target/candidate/backup，也不引入 detached scope。

正常 slot 复用后，只退休无 recovery 的 policy/inventory 记录，实际 Skill 文件不动。清理是 candidate-before-commit：明确写失败保留 committed 内存记录，outcome_unknown 按对应 store 冻结；不把 management 的 ready 重试规则偷偷改成 enablement 的规则。

退休不是一次性的 replaced 回调：

1. registry 改变先沿现有流程发布，Skill 清理失败不能回滚 Workspace 导航。
2. 只有实际确认提交且已完成本次内存发布的 registry，才能作为缺失 id 的清理依据。commitTaskStateBestEffort 返回成功不是 durable 证明。
3. 对已确认退出 registry 的无 recovery id，执行同一个幂等清理函数；enablement 与 management 可分别完成，失败保留未完成部分。
4. 后续实际成功的完整 history 提交、或完整可信的启动恢复，重新计算尚待清理的缺失 id；不依赖一个跨重启会丢失的事件列表。
5. 清理观察必须同时排除当前 registry 仍有的 id，避免用较旧的已提交视图删除本进程新建但尚未保存的记录。未知/不完整 history 不能用空集合替代。
6. 意外发现已经不在 registry 的 recovery 资产，只保留并诊断；既不能为 GC 删除它，也不能根据同路径新 Workspace 自动取得旧事务的 root authority。

Control 只向 Skill 传必要的、拥有明确提交来源的有界 registry id 集合及身份上界；不建持久 lifecycle journal、不让 Skill 读取 Task history 或反向 import Workspace。集合不是普通 visible projection，提交结果不能用当前 health 的偶然 ready 替代。

未清理记录继续计入各自既有容量。正常清理后释放容量；连续持久化失败时允许先达到 Skill store 的上限，不能声称容量只受 Workspace registry 限制，更不能为避免容量拒绝丢弃事务。

### 4.4 身份连续性：明确边界，不把 next_id 当成无条件证明

当前 next_id 的单调性依赖有效的持久历史。历史缺失/损坏后的空 Runtime，以及“新 Workspace history 保存失败但 Skill 文件提交成功”，都不能用“id 永不复用”一句话排除。

本批至少收口正常独立提交造成的碰撞：

- 在接纳任何新 Workspace id 前，Control 汇总已严格读取的 Skill 存量 Workspace id，上调 Workspace allocator 的保留上界：next_id 不得落入这些存量 id。只上调、不改已有 id，并沿已有 history metadata 持久化；不新增编号器或文件。
- 用“旧 canonical history + 更晚提交的 Skill 数据”重启反例，证明新目录不能拿到旧 id。上界溢出必须明确拒绝，不能回绕。
- 缺失 history 不是首次启动的充分证据：只要仍有 Skill 存量，就不能把它们绑定给从 1 开始新建的目录。已知存量使用上述上界保护；原记录不通过扫描路径接管。
- 对无法严格读取存量、history 被替换/重置等不能证明连续性的情况，不宣称可以自动恢复归属或安全 GC。必须保留原文件并报告身份连续性不可确认；不能仅靠本进程临时禁用按钮，就声称解决了下一次重启的误绑。
- 本批实现前须固定这组跨重启反例，并核对现有 load/restore 信息能否提供足够证明。如果解决它需要禁止正常 Workspace admission、增加持久身份字段或改变历史恢复合同，应暂停 C、单独报告具体缺失事实与最小合同选择；不得以“内部 id-only 重构”为名偷偷扩展。A、B 不因此阻塞。

这一边界不是新增通用恢复工程的任务单，也不是允许在证据不足时上线 id-only。C 的交付以防止误绑的反例闭合为准，不能用保留 old epoch 字段但不检查来假装已有保护。

### 4.5 继承不等于相信目录内容没有变化

重新授权恢复的是 provenance，不是“当前磁盘内容仍等于安装包”的证明。当前 reimport 检查的是新 candidate，不能引用它来声称检查过原 target。

- 对 ready 资产发起破坏性的 reimport/uninstall 前，在已授权根内重新 inspect 实际 target，检查类型、路径及与记录 content_hash 的一致性；复用 package.inspectDirectory，不以 Core revision 代替。
- 缺失、内容变化或无法验证时明确拒绝该破坏性操作并保留文件和记录，不悄悄接受新 hash。该保护不仅用于重开后的第一次操作。
- Recovery 使用对应 phase 的 target/candidate/backup 规则和已有 candidate_hash，不套用“ready 资产 hash 必须一致”来误拒绝合法中间态；物理歧义仍保留 artifact。
- read/export 读取当前实际内容，不能当作已验证原包的证明；不为只读操作增加无关的全局冻结。
- 本批不增加“强制接管修改后内容”能力。内容变化后的管理限制与诊断属于需随 C 明确的用户行为。

## 5. Owner、提交与验收顺序

| 批次 / 建议提交 | 主要改动范围 | 独立交付条件 |
| --- | --- | --- |
| A — fix(skill): keep trusted enablement policy after definite write failure | Skill policy/runtime/view；Control 消费入口 | 写失败后刷新与再次提交可用，unknown 仍冻结 |
| B — fix(skill): recover failed file transactions in process | Skill management_runtime/runtime/state/view；Control publication；Renderer/Bridge 类型与展示 | FileTransactionFailed 可恢复，错误变化可见，持久化失败仍正确冻结 |
| C — fix(skill): separate Workspace skill ownership from authority epochs | Skill ownership 查找与旧数据处理；Control/Workspace 的必要接线；View/Renderer | 身份连续性反例闭合，移除失败保留记录、旧验证失效、退休可重试且不丢数据 |

Skill 独占 phase、hash、安全文件操作、policy 和 inventory；Workspace 独占 registry 与 id 分配；Control 组合当前授权、Task quiescence、可靠提交结果及 revision。Application 只继续提供既有受限文件能力，不新增协议或 owner。

C 是完整交付单元，不能只提交 eql 改动、让授权、投影、冲突和退休在后续补齐。若 C 的身份连续性前提不能在既有合同内满足，先交付 A/B，明确报告 C 未闭合，不回退到旧的大方案。

## 6. 必须固定的跨层反例

除各批局部测试外，至少固定以下链路：

| 场景 | 必须观察到 |
| --- | --- |
| A removing → 打开 B → A 同步或异步 close_failed | A override/inventory 不丢；新操作用当前 epoch |
| 多次移除失败、其间修改 policy、重启后重新授权 | 同一 id 持续继承，无 re-key；旧 expected epoch 被拒绝 |
| pending verification → epoch 推进 → 旧 job 完成 → 当前 Retry | 旧 job 无 effect；只有新 attempt 能提交 |
| 成功移除 → 同 record 重开；以及 slot 复用后同路径重开 | 前者继承，后者新 id 不继承 |
| 根不可达且有 recovery → 移除 → 槽位压力 → 再授权 | 移除成功，恢复定位未丢；不能复用有义务的 record |
| registry 保存失败/unknown → Skill 清理；后续保存成功 | 未确证前不删，之后幂等推进 |
| 两个 Skill store 清理之间崩溃 / 清理写失败后重启 | 无 recovery 文件不动，剩余记录可再次清理 |
| 旧 history + 更新的 Skill 存量；缺失 history；连续两次重启 | 新根不误获旧 id/归属，不能靠一次性内存标记蒙混通过 |
| 无法读取身份上界 / history 隔离丢失 Workspace frame | 不把不完整集合当退休证据；明确暴露未闭合边界 |
| 同 id 不同 epoch 的不同资产 / 同 target 冲突 / policy 冲突 | 无损保留；只在无歧义处建立归属，不按最大 epoch 丢弃 |
| 重开前修改 target 或在 pending 中制造歧义 | 不误覆盖/删除，事务原副本与记录保留 |
| 错误返回但 asset/phase 改变、health-only 改变、无变化失败 | Snapshot revision 与实际变化一致，UI 能执行对应下一步 |

## 7. 验证与文档

计划文档自身的更新只执行链接、锚点、残留引用与 diff whitespace 检查；这不能代替各批实现验证，也不能证明未实施的 C 已通过。

实施验证遵循 [验证规范](validation.md)：

- 各批 Native 相关 root，交付前执行正式 Native graph；本机可使用 zig build test -j1，不能因内存问题跳过测试。
- Renderer 改动执行 npm --workspace @metawork/renderer run check，以及 node --test scripts/skills-center.test.mjs scripts/workbench-contract.test.mjs。
- B/C 追加对应 lifecycle 与真实 Windows 文件占用/rename 恢复用例；正式入口为 node scripts/run-lifecycle-tests.mjs。fixture 不替代物理文件和真实异步链路证据。
- 最终 npm test 按标准入口分别取得 Native 与 Node/Renderer 结果。canonical AgentCore bundle 缺失或 verifier 拒绝必须明确失败，不绕过 Gate。

仅在对应实现改变合同时同步唯一真源：

- [产品需求](requirements.md)：id 归属与条件继承、recovery_required 的用户下一步、修改后 target 的管理限制。
- [Product 架构](product-architecture.md)：health 与恢复准入、归属/authority 区分、退休的可靠提交前提及管理写失败的重启恢复边界；若 C 需要额外身份合同，先评审，不默写。
- [Renderer Bridge 合同](renderer-bridge-contract.md)：派生 managementState 和能力语义；不扩展 Retry 请求，不复制全部机器字段。
- [验证规范](validation.md)：错误路径中资产变化也必须发布 revision，以及新增长期回归责任；修正现有“只有 health 变化的失败路径推进 revision”的过窄约束。
- UI 真源仅在交互 gate 真正变化时更新相关小节，不引入新的恢复页面。

不修改 AGENTS、AgentCore ABI、sources 首次提交规则或无关架构。计划本身不批准破坏持久数据、弱化 verifier，也不把尚未验证的 C 身份前提写成已完成能力。

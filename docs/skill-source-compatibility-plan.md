# Skill 固定来源兼容实施方案

状态：Agent 消费层已提交为 `6684c28`，范围及上游依赖见第 8.7 节；Product Skill 已实施第 9 节允许的独立准备层，范围与未完成项见第 9.8 节，尚未接入生产 Runtime。产品默认值仍属于本方案建议，完整产品能力与 AgentCore 前置能力验收尚未完成。本文件不是产品真源或 decision record；正式实现时分别更新对应领域合同。

## 1. 产品边界与默认选择

用户通过勾选启用 MetaWork 预定义的 Skill 来源。Host 从 canonical user home 或已授权 Manual Workspace root 派生目录，Renderer 只提交固定 source ID 和开关，不传物理路径。

第一版建议如下；新增兼容来源默认关闭，保留现有用户行为。

| 来源 | 用户级位置 | 项目级位置 | 默认 |
| --- | --- | --- | --- |
| Agent Skills | `<home>/.agents/skills` | `<workspace>/.agents/skills` | 内置启用，首版不提供关闭开关 |
| Claude Skills | `<home>/.claude/skills` | `<workspace>/.claude/skills` | 关闭 |
| Codex 兼容目录 | `<home>/.codex/skills` | `<workspace>/.codex/skills` | 关闭 |

Claude 和 Codex 各提供“个人目录”“项目目录”两个独立 Checkbox。第一版将四个开关保存为本机用户级设置；项目目录开关适用于已授权 Manual Workspace，不增加逐项目继承/覆盖模型。界面明确标注这一范围。

为何采用四个全局开关：它们表达固定发现规则，不承担单 Skill 的可用策略；单 Skill 已有 Personal 默认与 Project override。代价是关闭某一兼容来源会影响所有项目的新 catalog，UI 必须写明“所有手动项目”。这是首版有意选择的范围；若产品需要只为某个项目关闭来源，应先调整配置模型，不能让项目筛选器偷偷改变全局 Checkbox 的含义。

AgentCore 自动加入 `.agents/skills`，现有 additional sources API 无法撤掉默认源，不能把它展示成可关闭的开关。若以后要求关闭默认源，需要先扩展 AgentCore 合同。

这里的兼容范围是约定目录中的 AgentCore 可识别 `SKILL.md` 及资源，不承诺与来源工具的完整执行语义等价。动态命令插值、subagent 设置、调用控制与工具限制按实际 AgentCore 能力逐项验证，不能仅因 parser 接受字段就宣称行为相同。commands 目录、插件配置不在本期范围。第一版只检查 home 和 Workspace root 下的固定位置，不向父目录搜索、不按访问文件发现嵌套目录、不读取其他工具配置来扩展搜索范围，也不继承 `CODEX_HOME` 等外部工具路径覆盖。

当前 Codex 官方文档以 `.agents/skills` 为本地发现约定；`.codex/skills` 在此是显式兼容入口，不标成当前官方标准。参考：[OpenAI Build skills](https://learn.chatgpt.com/docs/build-skills)、[Claude Code Skills](https://code.claude.com/docs/en/slash-commands)。

## 2. 发现、冲突与管理行为

Product Skill aggregate 拥有固定来源表、开关与 revision，使用受限文件能力派生和检查根目录。Agent adapter 将 typed source 列表编码为官方 `SkillSourceV1`。AgentCore 独占候选扫描、解析、优先级、冲突与 catalog 身份。

用户级来源使用 USER，项目级来源使用 WORKSPACE；不设置 Claude/Codex 品牌优先级。规则为：

“同名”精确指 AgentCore 的 `invocation_name`，当前由 Skill 子目录名形成，按字节区分大小写；不等同于 frontmatter 的 display name，不做 Unicode/case 折叠。

- 项目同名 Skill 覆盖用户 Skill。
- 最高优先级存在多个同名候选时，该 invocation 不可调用，并显示冲突；其他 Skill 继续可用。
- 高优先级候选损坏或不可用时，不静默回退到低优先级版本。
- 现有单 Skill enabled policy 在 winner resolution 后应用，不能通过关闭某个 Skill 让另一来源的同名候选胜出。解决冲突需要关闭相应来源，或由用户在外部修改定义后刷新。
- 第一版冲突提示使用 AgentCore 能证明的 invocation 和问题类型，不猜测完整冲突来源名单。提供进入“兼容来源”设置的动作，并明确来源开关的全局影响。关闭后仍有冲突时保留问题，不承诺关闭某一项一定能解决全部同名候选。

为什么不采用品牌优先级或自动内容去重：目录不代表可信等级，名字或内容相同也不能证明执行上下文相同。采用现有同级冲突规则，让用户决定关闭哪个来源；不复制文件、不重命名调用身份，也不合并不同物理目录的同内容 Skill。

冲突与损坏必须作为独立的问题列表投影，不能依赖 `assets[]` 中存在相应 Skill。两个纯外部来源同名时，AgentCore 只留下 issue，没有 winner，也没有 managed install；现有 SkillsPage 只按 asset 的 issueCodes 分组会漏掉它。页面直接消费当前管理范围对应的 catalog issues：顶层使用 personal catalog，项目使用所选 Workspace catalog；即使资产数为零也显示“需要处理”。同一 issue 同时关联资产时可以在详情复用，但问题区不重复计数。复用既有 catalog issues 的权威数据，不另造假 install 或第二份持久问题状态。

新增来源固定使用产品拥有的稳定 ID，例如 `compat.claude.user`、`compat.claude.workspace`、`compat.codex.user`、`compat.codex.workspace`。不得将列表序号、勾选顺序或内容 hash 当成 source ID。

兼容来源中的 Skill 按外部管理资产展示；MetaWork 的导入目标仍为 `.agents/skills`。外部来源不会因为勾选而取得导出、重导入、卸载的管理权限。现有单 Skill 启停规则继续适用。

必须修正管理资产关联：`src/product/skill/view.zig` 当前通过 invocation 关联 inventory 与 catalog。多来源下需要同时验证官方 provenance 与精确管理范围；无法证明来自对应 managed root 的 winner，不能与本地 install 合并。同步检查 reconciliation、import verification 和启停投影使用的关联逻辑，避免仅修正显示。

管理范围、catalog 查询范围和 Skill 原始来源是不同事实。项目页面可以展示继承的个人 Skill 并编辑项目启停策略，但来源标签仍是“个人”，不能因此取得项目文件管理权限。单 Skill policy 继续按现有 invocation 对应的稳定策略键继承：来源 winner 改变不会重置 disabled 策略；它不是针对某个目录内文件的独立开关。

资产关联至少要求已知默认 provider/source ID、原始 source scope、已授权 managed root 和该 root 内受管理 entry 一致；需要的 contribution 身份只能消费官方语义，不能复制 AgentCore hash 算法。管理资产与不同来源 winner 同名时保留两份事实，不能隐藏外部 winner，也不能把其描述和 enabled 控件附到 managed install 上。content revision 与本地 package hash 是不同协议，不直接比较。若公开 provenance 不能证明某项归属，则保持未关联并明确其运行时状态，而非按名称猜测。

文件事务按操作分别验证：

- install/reimport：用管理层的精确目标与 candidate hash 确认本地发布，用 AgentCore provenance 确认对应运行时结果。候选明确产生的 definition/resource/conflict failure 才按既有合同回滚；信息不足保持 pending_verification，不能把其他来源 winner 当成安装成功，也不能自动把不归属于本次候选的问题算给它。
- uninstall：成功条件是被管理目标确实移除，以及不再有该目标的运行时 contribution。同名个人 Skill 接替或其他来源出现冲突不构成卸载失败。当前 `reconcileNoFail` 的 `uninstall => !found` 只按 invocation 判断，必须替换，否则删掉项目 Skill 后个人版本显现会导致错误回滚。
- 受同级冲突影响的 managed install 仍可通过自身已证明的文件 authority 卸载；不要求它必须是 runtime winner 才能操作。外部 Skill 仍无卸载入口。

## 3. 配置提交与生效

来源配置由 Skill aggregate 持久化，使用独立 `skill-sources.json`，复用现有 FileStore 原子提交机制。建议 schema 1、最多 4 KiB，保存完整四项 source ID/boolean 与单调 revision；严格拒绝重复、未知 ID、缺项、非 boolean 与额外字段。首次启动文件不存在时初始化关闭兼容源的默认配置；运行中曾有配置却变为缺失则进入恢复状态，不能把文件消失当成用户停用。

独立文件的理由是发现配置先于 catalog，可在没有任何 Skill 时修改和恢复；现有 `skill-enablement.json` 管理单 Skill 策略，不能为了四个来源开关破坏其持久化格式。不建立两个 store 的联合写事务；每次新 catalog 提交时按当时最新且可信的 enablement policy 编译。

来源 revision 与单 Skill selection revision 分别表达来源选择和调用策略，避免复用同一个 revision 掩盖不同状态变化。

一次 Checkbox mutation 的建议流程：

1. Host 校验固定 ID、expected source revision、生命周期与 management transaction gate，构造完整配置 candidate。相同值是 no-op，不写盘、不推进 revision、不触发扫描；stale revision 返回明确拒绝。
2. 在写盘前完成内存预留、revision 溢出检查与受影响范围识别。原子保存成功后，在同一个 Product 串行提交边界安装配置、使受影响 current authority 失效并记录刷新意图；这一步不得再分配或产生可失败提交。明确写失败保留旧配置/authority；outcome unknown 冻结不确定的新 Skill authority。
3. 通过同一 bounded Executor 刷新。个人目录变化影响管理 catalog 和所有已授权 Manual Workspace；项目目录变化只影响 Manual Workspace。未授权项目不读盘，重新授权时按最新配置取得 catalog。保存后队列满属于“已保存、等待刷新”，不回滚配置。
4. 每个 job 拥有来源选择、路径和身份的有界副本。发布同时检查其实际相关来源选择、request generation、Workspace identity/epoch 与生命周期。个人查询只依赖两个个人开关；Workspace 查询依赖全部四个。全局 source revision 用于设置 CAS，不直接让无关 scope 的查询失效。受影响 scope 在设置提交时就推进请求代次，即使新 job 尚未入队，旧结果也不能发布；A→B→A 仍淘汰 A 的旧 job。
5. Personal 与 Workspace 都保留一个 latest reschedule intent；当前源码只有 Workspace 有该能力，Personal 需要补齐。旧 job 收口先释放结果，再调度最新请求。每个 scope 至多一个 job 与一个 pending intent；队列容量释放后公平续排，不能忙循环或为每次勾选分配一个等待 job。调用失败和无法继续调度时投影可重试状态。

设置保存与 catalog 就绪分别投影。刷新期间新的 Skill admission 不消费旧 current authority，普通 Text 路径保持现有行为。来源变化不递增 Workspace epoch，Workspace 授权身份没有改变。

来源选择的内部比较直接使用固定四项布尔值按 scope 投影，不引入第二套 hash/版本协议。catalog revision 仍由 AgentCore 拥有；配置变化但没有候选变化时，不能强行制造新 catalog revision。现有双 revision Skill admission 继续校验 current/pinned authority，额外的 source 配置一致性在 Host committed authority 上保证，不要求给每个 Run payload 增加来源字段。

已有 Task 继续使用 pinned catalog 与 policy，不热替换、不即时撤权；只有 idle Task 显式刷新才采用新设置。恢复 Conversation 仍不隐式绑定 Skill，Automatic Task 继续遵循当前 Text-only 合同。界面文案明确：“影响新任务；已有任务刷新技能后生效。”

来源设置可在已有 Task 执行期间提交，因为该动作只改变以后使用的 catalog；不等待全体 Task idle。Task refresh 则必须检查来源配置健康及 Workspace current authority 对齐，不能将配置失效前的 lease 重新绑定给 Task。旧 Task 的正常 Run 不受这项新 gate 追溯影响。

目录不存在时显示“未发现目录”，保留已勾选意图，后续显式刷新重新检查。权限失败、路径类型不支持、检查后目录消失与 catalog 错误分别报告，不能都归为“没有 Skill”。存在性预检查不能消除检查与查询之间的文件系统竞争；查询失败必须完整收口。

只把明确不存在的可选根从 additional sources 中省略。已启用根不可读或路径类型不支持时，该 scope 的本次查询失败，不静默跳过后绑定较低来源；候选级错误则保留 AgentCore 的局部 degraded 语义。每个来源的 `checked` 只表示根已检查并参与查询，不等于它贡献了 winner，更不能由 winner 数为零推断根不存在。

### 3.1 与文件事务的协调

来源切换不与进行中的 import/reimport/uninstall publish 或待判定的 catalog reconciliation 交错。复用 Skill aggregate 已有 transaction/reconciliation 状态：有相关活动事务时返回 busy，设置仍是旧值；UI 显示忙碌并允许收口后重试。不新增全局 Task 锁。

进入持久 `pending_verification` 且当前没有活动 reconciliation 时允许来源切换，避免用户无法通过关闭冲突来源修复问题。此后资产必须通过显式 retry 在最新来源选择下重新验证，不能让普通来源 refresh 顺便提交旧文件事务。活动验证结果只用于它绑定的目标、scope/epoch 和来源选择；过期结果不得触发 commit/rollback。

卸载释放出来的外部冲突不阻塞删除结果；source config outcome unknown 阻止开始新的管理 publish/verification，但已经进入文件事务的恢复仍按自身 durable record 收口。恢复文件事务不依赖来源设置恢复，避免两个恢复流程互相等待。

### 3.2 故障后的用户恢复

| 状态 | 保留什么 | 用户动作与结果 |
| --- | --- | --- |
| 明确保存失败 | 旧设置与旧 current authority | 显示保存失败，可重试同一修改 |
| 设置保存成功、catalog 查询失败 | 新设置；受影响 current authority 不可用于新绑定 | “刷新”按新设置重试，不回退旧目录集合 |
| source 配置读取失败 | 磁盘内容，不伪造开关状态 | “重新读取配置”；读取失败仍不写文件 |
| source 配置损坏或运行中缺失 | 不可信状态及旧 Task pinned authority | 明确的“重置兼容来源”动作，仅将四项兼容来源关闭，不修改安装文件或单 Skill policy |
| source 保存 outcome unknown | 无法确定的配置状态及旧 Task pinned authority | “重新读取配置”；合法内容必须经重新确认持久提交后恢复可用，不能只看内存判成功 |

配置恢复需由 Product Skill owner 实现 typed 命令，按当前 health/恢复代次校验。合法当前文件优先恢复其真实值，不清空；读取失败/资源不足不允许 reset 路径写盘；只有已确认缺失/损坏才接受显式 reset。reset 成功使用大于当前进程已观察 revision 的 revision，失效旧查询并按正常路径刷新；reset 再次写失败仍保持不可用。重置仅在该恢复面展示，按钮文案明确其效果，不追加与之重复的确认流程。

普通 Checkbox mutation、reload、页面打开及命令超时不会触发 reset。超时后 Renderer 先 resync，以 Host revision/health 确认提交结果，不自动重放。源配置恢复与完整 catalog 刷新分别返回真实状态。

## 4. 实施前需要验证的 AgentCore 边界

本方案依据 MetaWork 当前消费的 AgentCore commit `277ec01e78682141ef0240e637b533569539dccc`。不能把此前“现有机制足够”理解为所有兼容行为已经验证。

### 4.1 个人 catalog 的优先级一致性

现有顶层管理查询令 workspace root 等于 home。AgentCore `agentCoreSources` 在这个条件下只注册 WORKSPACE 默认 `.agents/skills`，优先级为 2；正常项目查询中的用户默认源优先级为 1。

如果直接追加 USER 的个人兼容来源，个人页中 `.agents` 会覆盖兼容源；进入普通项目后，两者却变成同级冲突。这是代码可推导的不一致，须用真实 bundle 最小用例确认。

期望合同：同一组个人来源在管理页及普通项目上下文中保留一致的相对优先级。方案选择明确的 personal catalog 查询语义：仅加载默认个人源与所选 USER 附加源，不加载 Workspace 默认源；该结果不得绑定 Session。Agent adapter 显式区分 personal-management 与 workspace 查询用途，正式编码通过上游 SDK，禁止靠 root 相等推断产品用途。上游具体通过新增选项还是独立 query 表面提供该能力，须结合 ABI 接受政策确定；这是实现依赖，不是可延期的 UI 优化。

不能在 MetaWork 通过虚构 workspace、伪造 USER 为 WORKSPACE、自行选 winner 或隐藏个人冲突规避。仅把 shared-root 默认源改为 USER 会影响真实“home 被授权为 Workspace”的调用，并不能完整表达两种用途，不作为默认修补方案。涉及上游公共语义的改动单独评审，本任务目前只读上游。

真实 Workspace root 等于 home 是另一个合法边界：同一生态的个人和项目规则会派生完全相同的目录。该查询只提交一份附加根，两个开关都启用时按现有 WORKSPACE 优先规则选项目来源身份；只启用个人开关时保留 USER 身份。由固定来源解析层处理这一个可证明的重复输入，不根据目录内容去重；不同生态因链接形成的别名按下一节处理。测试必须覆盖四种开关组合和 Workspace 重新授权。

### 4.2 路径身份与链接

上一轮源码审计发现 Windows `_fullpath` 与 POSIX `realpath` 的目录身份语义不一致。固定路径也可能通过 symlink/junction 指向同一目录，不能因为没有任意路径输入就忽略它。

首版选择真实目录与常规文件作为支持范围，链接根/链接 Skill/链接资源明确不支持。固定兼容根由 Host 在 canonical base 下通过受限文件能力检查 `.claude`/`.codex` 及 `skills` 两级，不能先 realpath 再假称输入没有链接；此检查只涉及固定根，不枚举 Skill 候选。候选及其资源由 AgentCore 负责检测。Windows reparse point/junction 与 POSIX symlink 分别验证，不能只检查一个目录最终字符串。

已读源码中的 `enumerateSource` 对不是 `.directory` 的 entry 直接 continue，因此 symlink Skill 目录可能静默消失。现有代码还不能兑现本方案“明确报告不支持的链接 Skill”的承诺；需要先在 AgentCore 补足候选级诊断，避免静默丢失或使低优先级同名候选接替。默认 `.agents/skills` 也经过相同发现链，必须纳入根链接用例。若上游选择支持链接而非拒绝，则需先统一真实目录身份、重复源和资源边界，再重新评审产品支持范围；MetaWork 不建立第二套扫描器。

### 4.3 文件格式兼容样本

直接源码证据：`snapshotCandidateTemporary` 将原始文件 bytes 交给 `validateSkillMetadata` 和 `parseSkillMdWithFallback`；两者都只认 `---\n`，没有在这段调用链规范化 CRLF。带 CRLF 的 frontmatter 可落入“无 frontmatter”分支，name 回退目录名，body 保留整份文件，控制字段没有被解析。逐行冒号拆分也不等价于一般 YAML parser。此问题与兼容外部 Skill 的格式要求直接相关，不能用功能提示代替修复。

第一步的 fixture 按以下期望验收，而不只检查 resolve 返回 OK：

| 类别 | 必须观察的结果 |
| --- | --- |
| 普通 UTF-8、LF/CRLF、末尾有无换行 | name/description/body 与控制字段语义一致，frontmatter 不混入正文 |
| 引号、冒号、常用 description 多行写法 | 正确解析支持的写法；不支持时明确 definition error，不能产生错误描述或静默丢字段 |
| 缺 name、目录名与 name 不同 | 以 AgentCore 的公开 fallback/调用身份合同为准，UI 分清显示名与 invocation |
| BOM、畸形 frontmatter、未知 metadata | 明确接受或拒绝；不可因格式退化静默放宽已识别的调用/工具限制 |
| disable-model-invocation、工具约束、context 等 | 分别验证显式/模型调用和执行层行为；parser 接受不等于约束被执行 |
| 资源相对引用、普通脚本文件 | 读取/执行沿已有 AgentCore 权限与资源机制，不获得其他工具的配置或隐含授权 |

常规 LF/CRLF 与已识别控制字段是首版必要门槛。对尚不支持的专有语义明确说明实际行为，不笼统声称 Claude/Codex 执行兼容。格式和执行差异应在 AgentCore 收口，MetaWork 不预处理或改写用户的 `SKILL.md` 来绕过验证。

## 5. 接口与代码落点

以下为建议形状，实施时与现有严格 wire 合同一次收口。

- `src/product/skill/`：固定来源定义、配置持久化、根目录解析、refresh generation 和 authority 提交。独立来源模块应聚合这些具体职责，不另建通用配置框架。
- `src/agent/catalog.zig`：为 `CatalogQuery` 增加有界 typed additional sources，按官方 SDK 编码，保留同步借用与 lease 生命周期。
- `src/app/stores.zig`：注入 source FileStore 和现有受限文件能力。
- Bridge：新增建议命令 `metawork.skills.setSourceEnabled`，payload 为 `{ sourceId, enabled, expectedRevision }`。返回保存结果与新 revision；catalog refresh 的结果由 snapshot 发布。另提供一个 `metawork.skills.recoverSourceSettings`，以 `action = reread | reset` 及 expected recovery token 区分第 3.2 节动作，不接受 paths 或任意配置 JSON。
- `skillManagement` snapshot：新增 `sourceSettings`，拥有全局配置 revision/health、固定条目 ID/可空 enabled/可切换性，以及 Host 决定的恢复能力和 opaque recovery token。配置未知时不能发布看似关闭的 Checkbox；正常状态无需 token。现有个人与 Workspace catalog 投影分别增加只读 source discovery 状态，不把多个项目目录压成一个全局 `found`。
- 每个 scope 的 source discovery 只发布固定 ID 与 `disabled | checking | missing | checked | error` 及 bounded typed reason；catalog 的 ready/degraded/unavailable 仍是其最终应用结果。没有 Workspace 选择时，项目开关只显示全局配置，不能显示某个项目的目录检测状态。原始物理路径和内部 source 列表不进入 wire。
- `frontend/src/features/skills/SkillsPage.tsx`：增加次级“兼容来源”入口和 Checkbox；来源配置位于独立区域，不能与单 Skill 开关混淆。显示来源标签、保存/刷新状态和冲突入口，沿用现有 drawer 与交互组件。
- 来源标签只能映射已知 source ID。未知 provenance 保留外部来源标识，不能通过名称推断生态。

两个新 command 必须同步收口 `app.zon` allowlist、Host registry/DTO、TypeScript 严格 decoder/client、snapshot fixture 和相关自动化。沿用 Renderer Bridge revision 1 的既定发布策略；配置数据 revision 不充当另一份 wire 版本。Task/Workspace 当前绑定、来源变更和恢复的跨 aggregate admission 由 Product Control 组合，Skill 文件/策略局部事务仍属于 Skill aggregate。

## 6. 分步交付与验收

第一步：完成真实 bundle 的最小反例验证。以个人 catalog 语义、CRLF/控制字段处理和链接诊断作为明确前置项；确认后的缺陷须由上游修复并按正式 bundle 流程接入，通过对应平台验收后，才能开放兼容勾选项。本地读取源码不能替代目标平台 bundle 证据。上游修复期间可独立实现纯设置与 DTO，但不对用户开放尚未闭合的能力。

第二步：实现 Claude 的个人/项目来源完整链路：持久化/恢复 → additional sources → catalog → 资产精确关联与文件事务 → 独立问题区 → Checkbox → 新 Task/显式刷新。必须同时包含冲突、关闭来源和失败恢复；这些不是可留到后续的正常链路依赖。这一条通过后加入 Codex 固定路径，复用同一实现。

第三步：完成四项开关的组合、并发、跨平台与恢复验收。最小充分用例：

- 默认开关全部关闭时，既有行为保持；勾选后能发现和执行受支持 Skill，重启保留选择。
- 同 scope 同名冲突、跨 scope 覆盖、损坏高优先级不回退；关闭来源后刷新可恢复，无注册顺序依赖。
- 个人管理页与项目上下文的个人来源优先级一致；不会将外部同名 winner 关联成 managed install。
- 两次快速切换、刷新中撤销 Workspace authority、写失败/outcome unknown、目录消失及 Executor 队列满均有明确结果；旧 job 不复活旧配置。
- 新 Task 使用 current authority，旧 Task 保留 pinned authority，idle refresh 后采用新配置；shutdown 不泄漏 catalog lease。
- Windows junction/路径别名与 POSIX symlink/不存在根分别覆盖，不用一个平台的普通目录用例代替另一平台证据。
- 两个纯外部来源冲突且无 managed asset 时，问题区仍可见；问题筛选与项目切换不会把上一范围问题带入下一范围。
- 卸载项目 managed Skill 后个人同名 winner 接替时，卸载正确提交；外部冲突不能导致错误回滚或删除外部目录。
- 项目开关变更不淘汰无关 personal job；personal job 执行期间个人开关 A→B→A，旧结果拒绝且最后一次请求最终完成。
- 来源切换与 install/reimport/uninstall/retry 的相邻时序不会提交旧验证结果；持久 pending_verification 不锁死来源修复入口。
- 目录 missing 后被创建、已启用根不可读、reset/re-read 再次失败及 UI command timeout 均有可执行恢复路径；零 winner 不伪装成零来源。

验证按 `docs/validation.md` 选择 Agent adapter、Product Skill、Bridge、Renderer 和 lifecycle/vertical 的相关入口。严格 DTO 变化运行跨语言 fixture/decoder；Renderer 运行 typecheck 与受影响 suite；AgentCore 调用使用 canonical staged bundle。最终检查 source count、snapshot bytes 与全部来源同时启用时的既有预算。

实施时更新产品范围、UI、Product Skill 来源事务、Bridge wire 和 AgentCore 消费合同的对应章节；若验收责任变化，再更新验证规范。不改 AGENTS.md，不在多份规范复制路径枚举。固定路径与 source ID 的机器事实由唯一来源表拥有。

第一步未通过时，结论只能是“方案可执行，兼容能力尚不可发布”。只有三个步骤均完成、失败恢复和真实执行用例通过，才称为完成多目录兼容。完整冲突 contenders 列表、品牌优先级、逐项目来源 override、自由目录、文件监听和完整第三方执行兼容均不作为首版隐含需求。

## 7. 初始方案的只读核查依据

以下是 Agent 层实施前的核查记录，不作为当前代码状态清单；Agent 已实施范围见第 8.7 节，Product 后续实施方案见第 9 节。

- `src/agent/catalog.zig`：Query 尚无 additional sources，已有 projection 保留来源 provenance。
- `src/product/skill/runtime.zig`：CatalogJob 当前只拥有 root/home/epoch 与 request generation。
- `src/product/skill/policy.zig`：启停策略应用在已 resolved catalog 上。
- `src/product/skill/view.zig`：管理资产关联仍按 invocation 匹配，需要多来源校验。
- `src/product/skill/management_runtime.zig` 的 `reconcileNoFail`：安装/卸载共用 invocation 判断；新增来源会扩大错误归属及卸载回滚场景。
- `frontend/src/features/skills/SkillsPage.tsx`：attention 从管理 assets 派生，纯外部冲突缺少独立呈现。
- `docs/agentcore-integration.md` 的 Skill catalog ownership、`docs/product-architecture.md` 的 Skill authority 与本地资产：现有 owner、current/pinned authority 和显式 refresh 边界。
- metacodes 上述 commit 的 `src/agentcore/skill_catalog_handles.zig` 与 `src/agentcore/abi_v1.zig`：默认源、shared-root 分支、scope priority 与额外根路径解析。
- 同 commit 的 `src/skills/runtime/catalog.zig` 和 `src/skills/runtime/definition.zig`：候选扫描跳过非 directory entry、原始文件字节解析、LF-only frontmatter 识别与控制字段处理。

复盘收敛记录：第一轮验证产品可见性与资产操作，补齐纯外部 issue 和卸载语义；第二轮验证配置提交时序，修正无关 scope 被全局 revision 淘汰以及 Personal 无 reschedule 的缺口，补齐持久化恢复；第三轮从修订后的交付顺序反查能力证据，明确 personal query、格式解析、链接诊断的上游前置责任，并将资产/恢复修复前移到第一条完整链路。

此次已完成源码与合同核对，未运行新兼容场景实验；第 4 节列明的最小用例属于下一步实施验证，不作为本次已通过证据。

## 8. `src/agent` 实施拆分

本节整理 Agent 消费层的目标改动；第 8.1—8.6 节保留完整能力的设计与验收要求，当前实施范围见第 8.7 节。沿用 `docs/agentcore-integration.md` 的 owner 边界，第一版不新增 Agent 子系统。必改实现集中在 `catalog.zig`、`session/runtime.zig`、`session.zig`，加上 public module `src/agent.zig` 的类型导出。

### 8.1 查询输入：明确用途，接收 typed 来源

`src/agent/catalog.zig` 的 `Query` 当前只有 root/home/epoch。建议收敛为以下 MetaWork-owned 类型形状；这是消费层提案，不是现有 SDK 的新 symbol：

```zig
pub const Source = struct {
    canonical_root: []const u8,
    scope: SourceScope, // 沿用已有 user | workspace
    source_instance_id: []const u8,
};

pub const QueryTarget = union(enum) {
    personal_management,
    workspace: struct {
        canonical_root: []const u8,
        epoch: []const u8,
    },
};

pub const Query = struct {
    canonical_user_home: []const u8,
    target: QueryTarget,
    additional_sources: []const Source = &.{},
};
```

target 必须显式填写，不能默认 personal 或用 root==home 猜测。Personal target 没有虚构 root/epoch，且只接受 USER 附加源；Workspace target 保持现有 root/epoch 绑定语义，不借本次改动额外改变 Agent 公共 epoch 合同。

Agent 不识别 `claude`/`codex` 枚举、勾选状态、产品 source revision 或路径模板。Product 传入已经完成授权、固定根检查和重复输入收敛的源；Agent 只接收通用 USER/WORKSPACE、绝对根与 opaque source ID。`SourceScope` 已存在，应直接复用。

`src/agent/session.zig`、`src/agent.zig` 沿现有导出链增加 `CatalogSource` 与 `CatalogQueryTarget`。变更后同步修改 Product CatalogJob 和测试构造处，不保留第二套旧 Query 路径；实施前确认这些调用者均在仓库内部，若有稳定外部消费者须按其公共合同迁移。

### 8.2 SDK 编码与输入边界

`catalog.query()` 使用官方 `wire.SkillSourceV1` 为每个 source 构造同步借用的 wire entry：

- 通过 `std.mem.zeroes` 初始化，设置正确 struct_size；scope 映射到 SDK 的 USER/WORKSPACE 常量。
- root/source_instance_id 使用 SDK BytesView；空列表为 null/count=0，非空为实际数组指针/count，保留顺序。
- 在分配或遍历前校验 count，不超过 SDK `MAX_SKILL_SOURCES_V1`；Agent 不把产品首版四项开关硬编码成自己的容量上限。
- 在调用前校验非空、UTF-8、NUL、绝对路径及长度加总溢出；总 metadata 遵守官方预算。source ID 的完整字符规则、真实目录别名和源冲突由官方 SDK/Core 验证，不再复制一份算法。
- 不把 `.agents/skills` 作为 additional source 追加，不对 SDK reserved 字段赋自定义含义，不拼装 raw catalog JSON。

wire 数组与输入 bytes 只需活到同步 resolve 返回。Product 的异步 job 拥有其输入副本；Agent 不保存这些 borrowed 指针，也不为来源配置另开线程、缓存或 watcher。

Workspace 模式的 additional sources 可用当前 SDK 实现。Personal 模式必须等待第 4.1 节的正式 SDK 支持，再按其真实字段/入口编码；不得用当前 `SkillCatalogQueryV1.reserved0` 私设 mode，也不得用现有 Workspace query 假装 Personal 成功。最终整包只消费一个通过 verifier 的确定版本，不增加运行时旧版 fallback。

### 8.3 Runtime 查询与 lease 生命周期

`src/agent/session/runtime.zig::querySkillCatalog()` 先运行有界的纯输入校验，在 source count/metadata 超限时于文件系统 I/O 前拒绝；然后按 target 校验 canonical home、需要时的 Workspace root，以及已传入的各 additional root。复用现有 canonical directory 边界检查，但不把该检查说成来源授权或 no-symlink 证明；固定根的原始路径检查属于 Product 文件能力，候选解析属于 AgentCore。

Product 可省略明确不存在的可选根；如果传入根在查询时已经消失、不可读或不符合 canonical 约束，Agent 返回失败，不能自行删掉该源继续查询。现有预校验会把部分文件系统错误归为 `InvalidCatalogQuery`，该结果不足以断言具体哪个根缺失；Product 的根检测状态与整个 query error 应分别呈现，不解析 diagnostic 文本来补身份。

继续保留 active_catalog_calls/active_catalog_leases 与 shutdown fence。wire 数组分配、SDK 解码、projection 复制、lease 分配中的任何失败都要释放自身临时存储；Core 已返回 handle 时仍恰好释放一次。查询期间开始 shutdown 时，结果按现有路径丢弃和释放。

`catalog.LeaseStorage` 保存拥有的 query target/用途与绑定所需 home/root/epoch。Personal lease 也计入 Runtime lease 数量并须释放，但不可用于 Session。无需在 lease 中再复制完整来源列表或 source 配置 revision：Core handle 已固定 catalog，Product 已拥有 current/pinned authority 与配置对齐事实；重复保存会引入第二份 freshness 判断。

### 8.4 所有 Session 绑定入口统一拒绝管理 lease

将 `catalog.matches()` 收敛为明确用于 Session 的匹配逻辑（例如改名 `matchesSession`）：先要求 workspace target，再匹配 root/home/epoch；owner 校验仍使用现有 belongsTo，或合并进一个窄绑定检查。用途校验不能仅依赖“Personal 的 epoch 通常为空”。

三个入口都使用同一判断，并在调用 Core 前返回 `CatalogBindingMismatch`：

| 入口 | 当前位置 | 必须保证 |
| --- | --- | --- |
| fresh create | `src/agent/session/runtime.zig::createSessionRoute` | 管理 lease 无法创建 Session；原有 catalog/policy 成对校验保留 |
| restore | `src/agent/session/runtime.zig::restoreSessionRoute` | 即使底层 Agent API 接收到非空 lease，也拒绝管理用途；Product 的正常 Conversation restore 仍传 null/null |
| idle refresh | `src/agent/session.zig::Session.refreshSkillCatalog` | 只接纳本 Runtime、同 Workspace/home/epoch 的可绑定 lease；保留 idle-only 和 policy 原子替换 |

对同一 Workspace，不同来源集合生成的合法 catalog 必须可以通过显式 idle refresh 替换。Agent 不能把创建时 source list 当成永不变化的 Session identity，也不能把来源开关变化解释成 Workspace epoch 变化。

### 8.5 Projection 和错误：已有能力优先复用

当前 `CatalogSkill` 已复制 provider_id、source_scope、source_instance_id、contribution_id、content_revision；`CatalogIssue` 已复制 kind/code/reason 与来源身份。`copyProjection()` 原则上不新增字段，只增加多来源、零 winner 多 issue 的复制与独立释放验证。

保留现有错误层次：输入拒绝为 InvalidCatalogQuery，Core catalog invalid/incomplete 与资源上限继续使用已有 typed error；`resolve OK + degraded` 是一次成功 acquisition，不能把 source_conflict 升级成整个 query 失败。Source labels、资产归属判断、独立问题区与 discovery 状态均由 Product/Renderer 消费这些事实，Agent 不新增品牌展示字段或虚构完整 contenders。

若上游为链接/格式问题复用 invalid_resource/unsupported_entry 或 invalid_definition，现有 enum/映射可直接消费；只有正式 SDK 引入新 tag 时才同步扩展 Agent mapping 与 Error surface。CRLF、YAML 和链接修复发生在 AgentCore，不能落到 `src/agent` 的预处理器。

本次不需要改 RunInput、Skill 参数编码、PermissionProfile、Completion 或 checkpoint 内容；restore 的变化仅限上述 lease 入口检查，不增补恢复时自动 discovery。

### 8.6 验证与实施顺序

当前 `tests/support/lifecycle_fixture.zig::runtimeQuerySkillCatalog` 只读取 root/home/epoch，不检查 additional sources。必须先补 fixture 的同步 wire 断言和有界 owned observation，否则测试可以在实际遗漏 source 编码时误报通过；fixture 不保存回调后的借用指针。

| 测试层 | 具体验收 |
| --- | --- |
| `catalog.zig` 局部输入/编码测试 | 0/1/4/SDK 上限与超限；个人 target 拒绝 WORKSPACE source；非法 UTF-8/NUL、空 root/ID、溢出；struct_size/reserved/ptr/count 正确 |
| `tests/agent/lifecycle_test.zig` + fixture | source scope/root/ID 精确传递；degraded 和零 winner issues 保留；管理 lease 对 create/restore/refresh 均拒绝；另一 Runtime/root/home/epoch 拒绝；同 Workspace 不同来源 lease 可显式刷新 |
| Agent lifecycle 失败路径 | 输入/wire/OOM/descriptor 错误清理；输入在同步调用结束后释放不影响 projection/lease；查询与 shutdown 竞争；释放 projection 不释放 lease，反之亦然；所有 lease 归还后 Runtime 可销毁 |
| canonical bundle 集成 | 真实附加根发现、同级冲突与跨级覆盖、明确 Personal query、格式与链接问题、真实 Session 绑定和执行；按实际平台差异验证 |

顺序为：确认上游 Personal query 合同与可接受 bundle → 修改 typed Query/导出和同步调用者 → 实现 wire/lease 三入口校验及 fixture 断言 → 跑相关 Agent lifecycle 和真实 bundle 用例。需要缩短反馈时可先验证现有 Workspace additional sources，但它不能作为完整 Personal 能力完成的证据。

验证入口使用 `docs/validation.md` 中的 `node scripts/run-lifecycle-tests.mjs` 及正式 Native test graph；bundle identity 先运行 `node scripts/verify-staged-agentcore-bundle.mjs`。

### 8.7 当前实施范围与未闭合项

当前 canonical SDK 尚无第 4.1 节要求的 personal-only query，因此此次仅实施可以通过现有正式 SDK 完成的 Agent 消费层，不制造 Personal 成功，也不停止既有管理能力：

- `QueryTarget` 当前为 `management | workspace`。`management` 明确表示既有默认源管理查询，按原有 root=home、epoch 为空编码，不表示完整 Personal 语义；携带任何附加源都以 `CatalogSourcesUnsupported` 拒绝。正式 Personal 模式必须在上游提供实际 SDK 后再实施。
- Workspace typed additional sources 编码、输入预算与 canonical 根检查、用途绑定的 lease、create/restore/idle refresh 三入口检查已落地。Product CatalogJob 仅迁移到显式 target，尚未传入兼容源或开放勾选设置。
- fixture 观察 struct size、reserved、ptr/count、scope/root/source ID；真实 canonical bundle 用例覆盖附加目录发现、零 winner 的同级冲突、顺序稳定、Workspace 覆盖及真实 Session 创建绑定与 idle refresh。该证据不等于真实 Skill Run、目录链接、CRLF 或个人查询验收。
- AgentCore 源码、ABI、bundle 与 lock 未修改。固定路径授权、Checkbox 设置与持久化、inventory 精确归属、刷新并发，以及上游 Personal/链接/格式问题仍按前文实施，不属于本次 Agent 层完成声明。

Agent 的长期消费边界只由 `docs/agentcore-integration.md` 定义；本节不替代合同。

## 9. Product Skill 最终修改方案

本节把第 1—6 节的产品目标收敛为 Product 的实施范围。复盘基于 `6684c28` 后的源码；结论是扩展现有 Skill aggregate，而不是重组它。本文中的“最终”表示本轮设计已收敛，不代表业务代码、上游依赖或产品验收已经完成，也不将本文件升级为 decision record。

### 9.1 三轮复盘与收敛结果

| 轮次 | WHY 与代码依据 | 最终取舍 |
| --- | --- | --- |
| 职责归属 | `state.zig` 已拥有 inventory、enablement、事务和 catalog slot；`runtime.zig` 已拥有 job、注册 Workspace 根、提交与 shutdown。为什么要另建来源 Runtime？ | 不另建。增加来源值与持久化输入，仍由现有 Runtime 驱动；Control 不遍历来源或读取 Skill State。 |
| 职责归属 | `CatalogSlot` 已独占 snapshot/lease，来源变化能通过失效 slot 和 request generation 表达。为什么再给 committed authority、Workspace、Task 各放一份 source revision？ | 不增加这些副本。全局 revision 只用于设置 CAS，job 保存相关开关值和已有请求代次；来源改变后旧 current 失效。 |
| 事务并发 | 当前 generation 在 enqueue 成功后才更新；Personal 无重排，Workspace 重排仅在已有 job 完成时处理。快速切换或 QueueFull 后如何避免旧结果发布、请求丢失？ | 设置提交时立即淘汰旧代次；Personal/Workspace 都保留有界 latest intent，`sync` 也处理无 job 的待入队 scope。 |
| 事务并发 | `finishJob` 对普通成功 catalog 也调用 reconciliation，活动 reconciliation 只按 scope 匹配。为什么普通刷新有权结束文件事务？ | 查询显式绑定普通刷新或本次 verification；只有精确匹配 install、操作、scope/epoch 和请求代次的结果才能结束该活动验证。 |
| 最小范围 | `view.zig` 按 invocation 合并/隐藏资产，`reconcileNoFail` 按同名 found 判定安装和卸载。能否只改 additional sources？ | 不能。只修正归属与事务判定的相关路径；不重做 inventory、归档格式或 enablement 策略。 |
| 最小范围 | 已有 Agent projection 保留 provenance/issues，已有 Task 显式刷新和 pinned snapshot。为什么新增问题库、Task watcher 或新 snapshot 协议？ | 不新增。复用 catalog 事实与 Task 路径；新增产品投影的 wire 接线留到 Bridge/Renderer 同步实施。 |

以上是方案收敛，不把原有单来源代码列为此次 Agent commit 引入的缺陷。

### 9.2 保持不变的 owner 与文件边界

Product Skill 继续是来源配置、catalog authority、单 Skill enablement、本地资产和局部文件事务的唯一 aggregate owner。文件职责如下，不按功能点机械创建一组新层：

| 文件/范围 | 必要改动 | 不承担的职责 |
| --- | --- | --- |
| 新增 `src/product/skill/sources.zig` | 固定来源表、四项选择值、严格配置 codec、专用 FileStore、固定根派生/检查的有界函数；类型名称在实现时确定 | 不持有 Runtime、job、current/pinned authority，不成为可插拔来源框架 |
| `src/product/skill/state.zig` | 接入来源配置与可信性、恢复事实；扩展现有 reconciliation 的查询绑定信息 | 不执行调度，不保存第二份 inventory 或来源 catalog |
| `src/product/skill/runtime.zig` | 来源 mutation/recovery、失效与调度、owned job、结果提交、事务协调与 shutdown | 不迁入 Core parser，不增加专用 Executor、timer 或文件 watcher |
| `src/product/skill/policy.zig` | 来源变更影响范围、健康到可用性的纯判断，以及被 view/reconciliation 共用的精确归属判断 | 不写文件、不分配全局 revision，不决定 runtime winner |
| `src/product/skill/management_runtime.zig` | 按具体目标与 provenance 验证 install/replace/uninstall，消费精确 verification 结果 | 不管理来源设置，不扩大可写目录 |
| `src/product/skill/view.zig` | 消费明确关联结果，保留外部同名 winner，准备来源/目录状态与独立 issues 的产品视图 | 不按名字推断来源，不在 serializer 中重新计算另一套归属或查询文件系统 |
| `src/product/skill/catalog.zig` | 原则上保留现有来源字段、snapshot/lease 与 revision 模型；仅因新增实际投影调整预算或相关测试 | 不增加 source revision、配置缓存或独立问题持久层 |
| `src/product/control/runtime.zig` | 窄 mutation/recovery 入口、配置注入、全局 publication 与既有 Workspace/Task admission 组合 | 不持有来源表副本，不拼路径，不直接读写 Skill 内部状态 |

只计划新增一个来源模块。它沿现有 `enablement.zig`/`management.zig` 的领域模块模式组织具体能力，不为限制文件数而把所有事务塞进去；若实现中出现有证据的独立生命周期或依赖隔离需求，再明确说明拆分理由。没有预先规划 `SourceManager`、resolver service、通用配置框架或新的 aggregate。

`src/product/skill.zig` 及 `build.zig` 只导出组装所需的配置、FileStore 和 mutation/view 类型，不向 Control 发布可变 State 或内部事务操作。`src/app/stores.zig` 与现有 Application 组装负责 store 的创建、恢复字节注入和释放；不能把读取结果简化成一个 bool 后丢掉 owner 恢复所需的区别。根检查复用现有文件能力，只有跨平台 no-follow 检查确有能力缺口时才补窄 port，不默认引入新的平台封装。

默认不修改 `src/product/workspace/`、`src/product/task/`、`src/product/skill/enablement.zig` 的业务模型，也不改 inventory 文件、`.skill` 交换格式、checkpoint、Run payload。已有 Workspace 注册/失效和 Task pinned/refresh 入口应足够；若测试证明有直接接线缺口，只在既有入口内修正，不把来源状态迁入这些 owner。

### 9.3 来源设置与唯一提交路径

产品默认值、固定路径和恢复动作沿用第 1、3 节。以下是实现约束：

1. 来源文件只持久化完整四项选择、schema 和配置 revision；目录检测、issues、job、pending intent 均为进程内派生状态。不修改现有 enablement 文件，不做两文件联合提交。
2. State 保留能证明当前配置是否可信的事实，明确保存失败不使旧可信配置失效。不能照抄 `health != ready` 就拒绝所有行为的判断，否则一次未提交的写失败也会错误冻结旧 authority。读失败、损坏、首次缺失、运行中缺失及 outcome unknown 的恢复规则按第 3.2 节实现；读取资源不足不是损坏，不得借 reset 写盘。
3. mutation 在现有主线程串行边界内检查生命周期、expected revision、能力与相关活动文件事务；相同值不写盘、不推进任何代次或刷新。写盘前完成编码、必要分配和所有受影响 request generation 的溢出检查。影响范围可遍历已有有界 Workspace registry，不另分配长期候选列表。
4. 原子保存成功后，安装新配置、推进受影响 scope 的 request generation、释放旧 current authority 并按既有 `ProjectionBudget` 扣账、登记 latest refresh intent。这些内存提交不得失败，不在保存后再构造会失败的权威 candidate。lease release 继续通过既有 Agent port，不重写释放协议。
5. enqueue、根检查、Core 查询和 snapshot 编译发生在上述配置提交之后。失败只改变刷新结果，不回滚已保存设置；受影响 scope 不恢复旧可调用 current。其他无关 scope 的 current 不失效，已有 Task pinned snapshot 不受影响。
6. outcome unknown 或重读得到不可信内容时，先淘汰相关旧查询并使不能证明有效的 current 失效，阻止新的相关 Skill 绑定和管理 publish/verification；不冻结 Text Run、旧 Task、其他 aggregate 或既有文件事务恢复。明确失败仍允许按旧可信设置刷新和重试保存。
7. Control 仅消费 mutation/recovery 的结果及“产品事实是否变化”。即使命令最终返回错误，若 health、恢复能力或 authority 已变化，也要推进全局产品 revision；真正 no-op 不推进。不能用外层 `try` 提前返回而漏掉失败状态发布。

不增加 committed authority 的来源 stamp。核心不变量是：slot 只有在当前 generation 与当前可信设置下完成查询和编译后才能成为 committed；所有影响查询的配置提交/恢复/授权变化必须同步失效相关 slot 与旧 generation。job 中相关选择值的比较作为提交校验，但不能替代 generation 对 A→B→A 的隔离。

### 9.4 CatalogJob、最新请求与生命周期

沿现有 CatalogJob 路径增加以下最小输入：相关来源选择、owned base root/home/epoch、请求目的，以及根检查所需的窄文件能力。worker 不持 Skill/Control/Workspace Runtime 指针，不读取主线程可变配置。

- 固定根派生与目录 I/O 在现有 catalog worker 内执行；worker 拥有解析出的附加根直到同步 Agent query 返回，再释放临时来源数组和路径。默认根也纳入既定链接检查，但不重复作为 additional source 提交；候选和资源仍由 Core 处理。
- 每个 scope 至多一个 job 与一个 latest intent。沿用 Workspace 的 reschedule 表达并补齐 Personal，不为每次点击分配 job 队列。latest intent 是已受理的新设置/刷新请求，不是失败旧 query 的自动重放。
- `sync` 先接收和销毁已完成结果，再对 pending scope 做有界续排；没有 job 的 pending scope 也参与。使用一个有界轮转游标避免总从 Personal 开始导致其他 scope 饥饿；不是另建 scheduler。
- QueueFull 保留 intent 并结束本轮；由现有 Product completion wake/lifecycle sync 再尝试，不忙循环、不依赖 Renderer 定时拉取。OOM、根错误或 Core 查询失败转为明确可重试状态，不无限自动查询。需要用“队列由非 Skill 工作占满”的 lifecycle 用例证明后续 wake 能继续推进。
- 发布检查 scope/Workspace epoch、request generation、相关来源选择、配置可信性及 shutdown；任何不匹配只销毁本次 acquisition，不能让过期的根检测结果覆盖当前 scope 状态。
- 配置影响范围按第 3 节：项目开关不淘汰 Personal；个人开关影响 Personal 和 Manual Workspace。来源变化不修改 Workspace epoch。失效/移除 Workspace 后不得续排；重新授权沿既有注册入口按最新选择查询。
- `beginShutdown` 清空所有 pending intent，取消 queued job；Executor join 后收口 running job，释放 temporary inputs、projection 和 lease，不新增另一条 shutdown 顺序。

`JobOutcome.failure` 需要能区分根检查与 catalog 失败，并保留有界 typed 原因；不暴露 raw diagnostic，也不把所有失败折叠成 missing。设置、scope 检查结果和最终 catalog 状态是不同事实：目录 missing 仍保留勾选值；checked 不代表存在 winner。配置代次变化时旧检查结果失效，不持久化检测结果。

普通手动刷新原有“保留 current 直到新结果成功”的语义不因本任务被整体改写；只有来源配置/恢复/授权变化导致 authority 无法证明有效时才先失效。`workspaceCatalogAuthority`、enablement mutation 和 view 必须共同遵守这一事实，不出现 UI 显示 unavailable 但仍可取得旧 lease 的双重状态。Task create/idle refresh 继续使用现有 authority getter，Control 不再手动比较来源数组。

### 9.5 精确资产关联与 reconciliation

这是多来源接入必需的局部修正，不重做管理系统。

1. 归属判断放在现有纯 policy 内，由 view 和 management reconciliation 共同消费。以 query 的管理上下文、官方 provider/source scope/source ID/contribution 语义及已授权 managed entry 为证据；同名仅用于寻找候选，不足以证明归属。root=home 的真实 Workspace 与管理用途按各自官方来源语义处理，不能写一条“Personal 永远是 USER”的猜测规则。
2. 关联判断应能区分已证明匹配、不属于此目标与证据不足。未知 provenance 不补推导、不复制 Core hash；本地 package hash 与 Core content revision 不直接比较。
3. view 不能只修改 `findCatalogSkill`：`inventoryHasInvocationInScope` 的外部 winner 隐藏逻辑和 `writeAssetTail` 的再次按名查找也须同步收口。asset tail 接收已核实的关联事实，不把另一个来源的 description、arguments、enabled 控件附到 managed install。文件管理按钮由资产自身 authority 决定，不要求资产一定是 winner。
4. 页面所在管理/策略 scope 与原始 source scope 分开。项目上下文可以展示继承的个人 Skill 并编辑项目 policy，但不得因此得到该个人目录的项目文件管理权。enablement 的稳定 policy key、User 默认和 Workspace override 不改变。
5. install/replace 先证明发布目标与预期内容一致，再验证属于该目标的 Core 结果；明确可归因于候选的失败按既有事务回滚，缺少归属证据保留 pending_verification。uninstall 以精确目标的物理删除和不再保留该目标的运行时结果为依据，同名低级 winner 接替或外部冲突本身不导致回滚。
6. Reconciliation 与 job 绑定具体 install ID、操作、scope/epoch 和已有 request generation；不新增一套持久验证版本。只有匹配 verification job 才能触发 commit/rollback，普通来源 refresh 只更新 catalog。
7. 取消、失效或查询失败时，仅结束与该 job 精确匹配的活动 reconciliation，保留 durable pending transaction；不得清除其他新验证的记录，也不能把活动标记永久留着导致来源设置一直 busy。显式 retry 在最新配置下建立新的验证绑定。
8. 来源 mutation/recovery 与受影响的活动 publish/verification 互斥；无活动 verification 的持久 pending 不阻止来源修复。沿用既有文件事务恢复，不因来源配置损坏或上游 query 暂不可用而停止恢复已登记的备份与目标。

### 9.6 对外接口、预算与不提前开放的能力

Skill Runtime 提供修改来源、重读/重置、读取设置和 scope 检查结果的窄 typed surface；具体命名及 wire 仍按第 5 节在 Bridge 接线时一次收口。外部只能提交固定 ID/boolean 与 CAS/恢复凭据，不能提交路径、Core source list 或任意 JSON。

Product 阶段可建立并测试 typed view，但不单独修改已发布 snapshot JSON shape 或 command allowlist。新增 wire 字段、source labels 和独立 issues 展示与 Bridge/Renderer 同步提交；已有 serializer 的精确资产关联修复可保持当前字段格式，不借此改变 scope 的外部含义。issues 继续来自已有 scope catalog，不另持久化或克隆成问题数据库。

外部 winner 不再被错误隐藏后，资产列表可能同时包含 managed install 和外部同名项；实现必须重新核对现有 catalog/global snapshot 最坏容量，失败时明确拒绝超预算 candidate，不能截断来源、隐藏问题或降低既有承诺来通过测试。新增来源/状态字符串也走现有脱敏与有界编码路径，不另建日志或 raw-path 投影。

上游 Personal query、目录链接诊断、CRLF/控制字段及真实执行验收仍按第 4 节推进。当前 Agent `.management` 拒绝附加来源，这不是 Product 可以绕过的限制。没有正式能力时只完成可独立验证的来源值/codec/目录检查和纯策略，不安装一个无法兑现的生产设置入口，不发布持久化的“已启用”兼容能力，也不创建虚构 Workspace 取得 Personal 结果。

### 9.7 实施顺序与验收闭环

按依赖推进，不按目录或文件数划分交付：

1. **准备层**：实现固定来源值、codec、FileStore/根检查的领域函数和纯归属判断，补独立测试；不接入生产入口，不借准备工作改变现有行为。确认正式上游查询合同后再接生产 Runtime。
2. **Product 闭环**：同一交付内完成 State/Runtime 配置提交、pending 调度、current authority 隔离、资产关联/verification 修正、Control 窄接口和 Application 注入。不能先启用额外目录，再把归属和事务修复留到后续。现有默认路径和未配置用户持续可用。
3. **展示与发布**：Bridge/Renderer 接入 typed 状态、勾选、来源标签和独立问题区；上游兼容与真实 Skill Run 验收通过后才开放。Product 阶段不以“没有 UI”替代内部调用的正确性验证。

以下用例是实现验收，不是本轮已执行证据：

| 观察层 | 最小必要反例 |
| --- | --- |
| sources/State | 四项默认与严格 codec；同值/stale CAS；根缺失、不可读、链接；root=home 四种选择；明确写失败保留旧 authority；outcome unknown、重读/reset 与 revision 溢出 |
| Skill Runtime | A→B→A 淘汰旧 job；项目开关不淘汰 Personal；Personal 与 Workspace 有/无 job 的 QueueFull 续排；候选 snapshot OOM 的释放和预算；配置提交后旧 current 不复活 |
| policy/view/management | 外部与 managed 同名同时保留；asset tail 不按名字二次误绑定；零 winner 仍有 issues；卸载后个人 winner 接替；无法归因保留 pending；普通刷新不能结束 verification |
| Product lifecycle | 非 Skill 工作占满队列后无需 UI 操作仍能推进；撤销/重新授权；stale/cancel 清理活动验证但不丢 durable recovery；旧 Task 可继续，新 Task/idle refresh 按新 authority；shutdown 无 job/lease 泄漏 |
| canonical bundle / 发布 | 管理与普通 Workspace 的个人来源语义一致；默认源及兼容源的冲突/覆盖；格式与链接诊断；来源变化前后的真实 Skill Run；平台差异与 Bridge/Renderer 端到端 |

模块测试按既有具名 root 接入；相关生命周期与共享 owner 变更使用 `docs/validation.md` 的 lifecycle 和正式 Native graph，架构检查证明没有反向 import 或新的顶层 owner。纯文档本轮只检查链接/引用及 diff 格式，不运行 runtime 测试。

实施时 Product 的事务/恢复不变量只更新 `docs/product-architecture.md` 对应 Skill 章节；产品开放范围、Bridge 与 UI 合同在各自接线阶段更新各自真源，不把本计划复制到多个规范。无需修改 AGENTS.md 或重命名现有 owner。

最终取舍：一个新增的具体来源领域模块，扩展现有 State/Runtime/policy/view/management 协作；不新建 owner，不迁移既有 enablement、inventory 或 Task authority，不用“以后会用”引入第二套状态和执行路径。接受此方案不等于提前批准上游 ABI 变更或宣称兼容功能已经可发布。

### 9.8 Product 准备层实施边界（2026-09-11）

本轮在 `6684c28` 基线上只完成第 9.7 节第 1 步。canonical staged bundle 验证通过，但现有 Personal/management query 仍不能接收附加来源，因此没有进入第 2 步，也未修改上游源码、ABI、lock 或 bundle。

- `sources.zig` 提供四个固定来源、默认关闭的选择值、严格 codec、CAS 候选值、专用 FileStore 和固定根检查。首次缺失不自动写入；读取失败、非法配置、未知 schema 与资源不足保留区别；写入明确失败与发布后持久性不确定分开报告。实际恢复与内存提交仍留给现有 Skill Runtime。
- 根发现只读取默认源及所选兼容源的固定根组件，不枚举 Skill、不解析 `SKILL.md`、不创建来源目录、不查询 Core。共享 home/Workspace 根按所选 scope 去重；遇到阻断根时不返回可用的部分列表。no-follow 检查只是时点观察，不宣称消除了检查到 Core 查询之间的目录替换风险。
- `policy.zig` 新增纯归属判断，区分 matched、different、unproven。调用方必须先提供已授权 managed entry 与确切 query source；不复制 Core hash，不把 package hash 当成 Core content revision。现有 view/reconciliation 尚未改用该函数，后续按第 9.5 节一起接线。
- `build.zig` 仅注册领域模块与正式测试 root。没有增加 Settings 生产入口、第二个 Runtime/State、公开 wire 字段、Application store 注入或 Renderer 控件；现有 Product Skill owner、文件管理和 authority 行为未改变。

准备层测试覆盖所有选择组合、严格解析、CAS/no-op/溢出、不同及共享基础根、missing/不可读/非目录、禁用来源不检查、写入结果分类与 OOM 清理。Windows 符号链接用例在缺少创建权限时明确跳过，不能作为链接验收通过的证据；junction 和其他平台真实行为仍需后续专项验证。

后续仍需正式 Personal query 能力，然后按第 9.7 节原定顺序完成 Product 配置事务、调度与 authority 隔离、精确资产关联/verification、Control/Application 注入，再进行 Bridge/Renderer 和真实执行验收。准备层通过不等于多目录功能已可用或可发布。

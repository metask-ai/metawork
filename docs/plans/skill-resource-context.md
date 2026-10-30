# #70 Skill 随包资源定位修复方案

本文是实施提案，不是已实施合同或 decision record。根据评审修订：交付限于 MetaWork 仓库，不修改 AgentCore 源码、不向上游提需求，也不等待新 bundle。用户已明确要求在新分支实施最终方案 B，授权受管导入的安装和导出内容变换。范围和未覆盖项仍按本文执行。

## 1. 诊断与范围

Issue：<https://github.com/shuzuan-org/metawork/issues/70>。

2026-10-30，MetaWork `42da311f`，当前 canonical bundle 通过 verifier。source-free、loopback Provider 探针观察到：

| Skill 正文 | typed `runSkill` | Text Run 调用 `Skill` |
| --- | --- | --- |
| issue 原样，仅包含相对文件名 | 未提供资源基目录 | 未提供资源基目录 |
| 增加 `ROOT=${CLAUDE_SKILL_DIR}` | 展开目录，真实 Read 成功 | 展开目录，真实 Read 成功 |

本地证据：`.zig-cache/issue70-current/`。该结果证明路径替换机制可用，不证明真实导入、真实模型或所有平台已通过。评审另提供锁定 Core 源码佐证：渲染只替换已有占位符，未自动附加目录说明。

catalog 不带物理路径、Renderer 不从 `file_refs` 推导模型上下文，这两个边界保持。ABI 已支持所需占位符行为，但没有已确认可由 MetaWork 覆盖所有 Skill 激活内容的公开 hook。因此，在不修改 Core 的约束下，不承诺任意来源、任意未改写 Skill 的统一修复。

## 2. 交付选择

| 选择 | 可交付行为 | 代价与边界 |
| --- | --- | --- |
| A：保留导入字节语义 | 继续在内置和自有 Skill 中显式使用占位符 | 对 issue 的普通第三方导入样本没有改善，#70 保持开放 |
| B：受管导入自动补充资源说明（建议） | 用户提供原样目录、`.zip`、`.skill`，正常导入确认后，已安装 Skill 自动获得定位说明 | 安装和导出内容成为经过明确规则变换的资产；仅覆盖受管导入，不处理外部管理来源 |

采用已获用户实施授权的 B，采用下述单一受管发布路径；不同时维护原件执行版与变换执行版。用户选入的源目录/归档不被修改。

不修改锁或 bundle，不建立外部来源镜像、第二套候选发现、安装路径 registry 或 event 文本改写。用户无需填写路径或手动编辑正文，也不为每次执行添加确认。

## 3. 受管资产变换规则

在隔离 staging 中，保留合法 Skill 的 front matter、名称、参数和作者正文，在正文开头补充固定说明，例如：

```text
Skill resource directory: ${CLAUDE_SKILL_DIR}
If this value is an expanded absolute path, resolve this Skill's relative
resource paths against it. If it is still a template token, do not use it as
a path or shell environment variable. Instead use the directory containing
this SKILL.md, as identified by the invoking tool's Skill-location context.
If neither location is available, report that resources cannot be located;
do not guess a filesystem root.
Use the existing tools and permission policy to access resources.
Use the invoking tool's activation or reload mechanism to obtain current
resource paths when continuing work.
```

说明使用占位符，不写入本机绝对路径。Core 继续拥有实际目录选择、激活和占位符替换。附带文件逐字节复制，不改写 Markdown 链接或脚本内字符串，不解析作者的业务指令。

受管安装目标 `.agents/skills` 是其他工具也可能读取的共享目录；项目 Skill 还可能随仓库分发给协作者。说明必须同时适用于展开占位符的 AgentCore 和不展开它的读取方。后者使用其已知的 `SKILL.md` 目录，不要求支持 AgentCore 的 `Skill` 工具，也不能把未展开 token 传入 shell，从而误读 `/qa-reference.txt`。这是模型指引，不假定任意第三方工具都执行其内容；至少应对目标共享读取方取得一次实际兼容性观测。

规范化必须确定、幂等：相同输入得到相同有效内容；再次导入本产品导出的资产不重复增加固定说明。只识别本变换放置位置上完全相同的固定说明，不删除任意作者文本或相似段落。已有其他占位符保留。固定文本在一个实现位置定义，测试引用真实行为，不复制第二套生成模板。

变换后的定义和总资源大小仍受现有上限约束；超限明确失败，不提升限制或截断正文。合法性继续由既有机械检查和 Core catalog reconciliation 判断，不在 MetaWork 复制完整 Skill parser。

## 4. 导入、摘要和导出事务

现有 preview grant 绑定源摘要，`management_runtime.installSource/reimportSource` 在 commit 时复核这个摘要。规范化是源字节的确定性纯函数，因此保留现有 grant 和 Bridge，不需要在 grant 中保存变换前后两份摘要。`package.stageDirectory` 和事务内 staged 比对仍须对应真实输入，不能在原 manifest 上追加字节后忽略不一致。

选择 B 后，按同一事务收口：

1. preview 沿用当前源检查、源 metadata 和源摘要；界面以固定说明告知安装时会补充资源定位信息，且安装和导出字节会被其他读取同一目录的工具看见。文件数量/大小仍按其实际源 metadata 呈现，不冒充变换后值，不新增 Bridge 字段或第二份摘要。
2. commit 沿既有 `installSource/reimportSource` 重读并核对源名称、摘要、目标 authority、相关 active operation 和确认时身份。源内容变化照常拒绝。
3. 源校验通过后，将原始资源复制到隔离候选，先验证复制后的原始 manifest 与已批准源摘要一致，再在该自有副本上规范化正文，重新检查容量和生成有效 manifest。这保证变换针对已验证的稳定副本，不能仅因之前检查过源就忽略复制期间的变化。目录和归档入口共用此变换。
4. `publish/reimport` 接收规范化候选及其有效 manifest，现有事务内 staged 比对、`candidate_hash`、reconcile 和 rollback 都使用对应有效摘要；失败仍保存原资产或按现有规则进入明确恢复状态。保留现有事务检查，不放宽校验以接受预期的不一致。
5. inventory 的 `content_hash` 对应实际发布的规范化字节，Core content revision 继续由 Core 计算；不自行合成 runtime identity。
6. reimport 使用同一候选变换与确认语义。export 导出实际安装内容，包括固定说明；再次导入保持幂等。不存在“导出时凭猜测删除说明并还原原包”的规则。

无需改变 `skill-management.json` 格式：既有 `content_hash` 仍描述安装字节，不新增原始包归档或平行 inventory。源摘要仅承担现有 preview/commit 的输入一致性职责，有效摘要承担安装字节和恢复事务职责；两者不用相等，也不在 grant 中建立双摘要状态。

### 既有安装

不在启动时自动扫描并改写所有 Skill。既有受管资产可通过现有 reimport 路径采用新规则；不重写飞行中的 active Run，也不重放历史工具。若用户要求升级后无须重新导入所有既有安装，需要另外明确批准受管内容迁移及其恢复方案，不能把它默认为本方案已具备的效果。

## 5. 来源与生命周期边界

| 来源 | 当前可执行处理 | 目录语义 |
| --- | --- | --- |
| 内置 Office、自有 Skill | 维护自身正文中的占位符说明；Office 现有固定入口继续使用 | 按 Core 实际激活行为处理 |
| 新导入或重新导入的受管 Skill | 选择 B 后自动采用规范化规则 | `.agents/skills` 激活使用 Core 物化目录 |
| 尚未重新导入的受管资产、手工创建的项目 Skill | 原样发现和执行；不能声称已自动修复 | 按其实际正文与 Core 行为处理 |
| 外部管理的 Claude/Codex 兼容来源 | 只读发现，不改写源文件，不建立镜像 | 评审确认使用 `live_dir`，是来源目录而非临时物化目录 |

统一说明只要求使用本次调用给出的目录，不宣称所有目录均为临时目录。临时物化来源的续轮需重新激活取得当前路径；compat 的 live directory 不因此获得永久有效承诺。资源移动、删除或权限变化仍返回真实错误。

该表描述 MetaWork 如何消费各来源，不限制其他工具读取受管 `.agents/skills`。共享读取方看到的是实际安装正文，其未展开占位符时的行为由第 3 节的兼容说明覆盖，不能据本表声称目录只供 MetaWork 使用。

这项改动不解决外部管理 Skill 缺少占位符时的自动定位，也不把它静默导入或变为受管资产。该剩余范围明确记录，不能通过全局提示词、搜索安装目录或放宽权限伪装成已闭合。

## 6. 实现 owner 与合同

| 范围 | 改动职责 |
| --- | --- |
| `src/product/skill/package.zig` | 单一、确定的候选内容规范化及变换后 manifest 检查；保留路径和容量限制 |
| `management_runtime.zig` 与受管 staging | 保留源摘要校验，在自有稳定副本上生成规范化候选，以有效 manifest 调用 install/reimport 事务 |
| `management.zig` | 复用已有发布、恢复、导出机制；只有真实事务需求才修改 |
| Skills Renderer/i18n | 若选择 B，沿用源 preview，补充安装内容变换和共享可见性的简短说明；不接收或推导资源绝对路径 |
| preview grant、Agent/Core、Bridge wire、store schema | 不改结构及其已有职责；继续官方 SDK、精确 catalog/grants 和既有协议 |

选择 B 会改变产品可观察的导入/导出行为，必须在实施时更新 `docs/requirements.md` 对应 Skill 合同，明确规范化安装字节位于共享标准目录、会对其他读取方及取得项目副本的协作者可见，并定义未展开占位符时的相对资源定位行为。内部事务不变量若确实改变，再更新 `docs/product-architecture.md` 的唯一对应章节。只改 preview 文案而不改交互合同，不机械扩写 UI 规范。

不把统一临时 lifetime 写入 `agentcore-integration.md`，不为此次纯 MetaWork 资产适配修改 AgentCore ABI 合同或 bundle locks。验证规范只登记实际新增入口、覆盖范围和未闭合项。

## 7. 最小充分验证

测试范围跟随最终选择：A 不触及导入，就不运行或增加导入/导出、同名竞争、冷恢复和 Snapshot 的新矩阵。B 确实改变候选字节及 preview/install/reimport/export，才增加以下针对性验证：

- 候选变换：作者定义和附带文件保留、幂等、变换后超限明确失败；未展开说明明确要求使用 `SKILL.md` 目录，禁止将模板 token 作为路径或 shell 变量。
- 事务：preview 源摘要与 commit 原始副本一致；确认后源变化或复制副本与源摘要不符时拒绝。变换后有效 manifest、事务 `candidate_hash`、inventory 与发布字节一致，失败保留原目标。沿用现有 grant，不新增双摘要 grant 测试。
- 导出再导入：固定说明不重复，摘要对应真实字节；原输入不被改写。
- 目录和归档入口只证明进入同一候选变换；`.zip`/`.skill` 共享实现时不重复完整矩阵。

核心资源验收只保留两条端到端用例：

1. issue 原样资产经真实受管导入，普通 Run 调用 `Skill`，根据实际 tool result 提供的目录使用真实 Read 得到标记。
2. 同一有效资产通过 typed `runSkill`，根据本次模型上下文使用真实 Read 得到标记。

受控 Provider 不从测试进程预知的安装根提供答案。另做一次桌面真实模型 smoke，用户输入不含绝对路径或占位符；不以 fixture 结果代替真实模型结果。

共享目录兼容性新增一个针对实际改动的用例：目标第三方读取方不展开该 token，并已通过自身 Skill 上下文获知定义位置时，仍从 `SKILL.md` 所在目录读取标记，不能把 token 交给 shell 或转而读取根目录文件。可在安全隔离项目中检查导出/安装正文，不安装新插件或修改其他工具的配置。单纯检查说明包含降级文案只能证明文本规则，不能替代这项实际读取观测；执行环境不可用时应明确记为未验收。

不因本任务新增同名来源竞争、冷恢复、Snapshot 字段、isolated Skill 或全 target 笛卡尔积验证。当前平台运行受影响 Skill/Product/Agent 测试及 verifier；Renderer 有变动才按仓库规则运行 typecheck 和受影响 suite。其他平台只针对本次引入的独立路径/编码失败模式追加验证，缺少 canonical dependency 时明确失败。

## 8. 实施顺序与完成标准

1. 按用户已授权的 B 实施安装/导出内容变换，沿用源摘要 grant；不扩展到未授权的既有资产迁移。
2. 若选择 B，先实现并验证候选规范化及摘要事务，再接入受管 preview/install/reimport；继续使用原 publish/reconcile，不保留两套执行路径。
3. 完成两条资源端到端用例、一次真实模型 smoke，以及实际受影响的验证入口。
4. 更新唯一对应合同和验证责任，报告新受管导入已修复、既有资产如何采用，以及外部来源剩余范围。

不等待新 Core artifact，也不创建上游 issue。A 只能算维持可用资产边界，不能关闭 #70。B 验收后可认定 issue 所述“正常导入后无法定位资源”的场景已修复；不能同时宣称所有既有安装、手工项目定义及外部管理来源均已修复。是否按该交付范围关闭 issue，由用户明确决定，不在实施中自动扩大结论或关闭。

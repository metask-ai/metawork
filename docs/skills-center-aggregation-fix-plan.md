# MetaWork 当前 Skill 列表聚合修复方案

> 状态：已实施
>
> 日期：2026-08-19
>
> 边界：只修复当前版本 Skill 中心的列表聚合与展示语义。本文不要求 AgentCore 提供新能力，不修改 AgentCore ABI、Renderer Bridge payload、Bridge revision、persistence schema 或任何版本标识。

## 1. 问题结论

当前页面显示的 8 行不是 8 份 Skill，而是两组不同 policy context 被错误地放进“全部”列表：

```text
4 个 personal row
    -> 控制用户默认 enabled/disabled

4 个 project row
    -> 控制 metacode-desktop 的 inherit/enabled/disabled

错误的“全部”聚合
    -> 显示为 8
```

`metacode-desktop` 的 `.agents/skills` 为空，因此后 4 行不能解释为 4 份项目 Skill。它们只是同一组逻辑 Skill 在该 Workspace 中的项目策略控制行。

根因位于现有 Renderer 展示机制：

- Host 在 `skillManagement.assets[]` 中同时发布 Personal policy row 和每个 Manual Workspace 的 Project policy row；
- `SkillsPage` 默认选择 `scopeFilter = "all"`；
- `all` 不区分 policy context，直接展示整个数组；
- 页面计数和“用户/项目”标签使用户误以为这些行表示物理资产来源。

本次修复不通过跨 scope 去重解决。相同 `skill_id` 在不同 Workspace 中可能具有不同 override 和 revision，合并成一行会丢失真实 policy context。

## 2. 修复目标

1. Skill 中心一次只展示一个明确的 policy context；
2. 用户默认和项目设置不再被相加成一个“全部”列表；
3. 项目设置一次只针对一个明确的 Manual Workspace；
4. 计数、搜索、空状态、Needs attention 和 mutation 都只作用于当前 context；
5. UI 不把 policy scope 表述成物理来源；
6. 保持现有 Host、Bridge、AgentCore、enablement store 和 revision CAS 行为不变。

## 3. UI 结构

### 3.1 Context selector

删除：

```text
全部 | 用户 | 项目
```

替换为：

```text
用户默认 | 项目设置
```

- 默认进入“用户默认”；
- “用户默认”只展示 `scope.kind === "personal"`；
- “项目设置”只展示一个已选择 Manual Workspace 的 Project row；
- 不再存在能够同时展示 Personal 与所有 Workspace row 的入口。

### 3.2 Workspace selector

选择“项目设置”后显示 Workspace selector：

- 候选只包含 `kind = manual`、`authorization = available` 的 Workspace；
- 默认选择 Host `workspaces[]` authoritative projection 顺序中的第一个有效候选；该顺序由 Workbench 的既有 recent-order 事实决定，Renderer 不再按字母或本地 locale 二次排序；
- 用户已经选择的 Workspace 仍存在时保持选择；
- Workspace 被移除或失去 authority 时，切换到第一个有效候选；
- 没有 Manual Workspace 时显示“暂无可配置项目”，不回退到所有 Project row。

Project row 的过滤条件必须同时匹配：

```text
asset.scope.kind === "project"
asset.scope.workspaceId === selectedWorkspace.id
asset.scope.workspaceEpoch === selectedWorkspace.epoch
```

epoch 也必须匹配，避免把旧 Workspace incarnation 的 row 显示为当前设置。

### 3.3 标签语义

Personal row 显示：

```text
用户默认
```

Project row 显示：

```text
项目设置 · <Workspace display name>
```

该标签表达 policy context，不表达 Skill 文件来源。

`sourceKind` 继续只用于现有管理 provenance 文案和管理动作，不得与 Project scope 组合成“Skill 来自该项目”的断言。无法证明物理来源时不新增来源说明。

## 4. 启停行为

现有 mutation 语义保持不变。

### 4.1 用户默认

```text
scope = personal
state = enabled | disabled
```

- switch 修改用户默认；
- 使用 Personal catalog revision 和 row selection revision；
- 不允许 `inherit`。

### 4.2 项目设置

```text
scope = project
workspace identity = selected workspace id + epoch
state = inherit | enabled | disabled
```

- `inherit` 显示“跟随用户设置”；
- 用户切换 switch 后写入目标 Workspace override；
- “恢复跟随用户”清除显式 override；
- 使用该 Workspace catalog revision 和 row selection revision；
- mutation busy identity 继续包含 scope、Workspace 和 `skill_id`。

本次修复不改变 policy persistence、全局 revision 分配、双 revision CAS、no-op 或 fail-closed 行为。

## 5. 列表派生规则

Renderer 先确定 context，再过滤，最后执行搜索：

```text
management.assets
    -> current context rows
    -> search filter
    -> attention / regular partition
    -> visible count
```

不得先把所有 context 搜索后再以底层数组长度计数。

所有页面状态都从 `visibleRows` 派生：

- 标题计数；
- 无 Skill 空状态；
- 无搜索结果状态；
- Needs attention；
- 普通卡片列表；
- 键盘导航和详情入口。

切换 context 或 Workspace 时关闭不再属于当前 `visibleRows` 的详情抽屉，避免在项目 A 的页面继续操作项目 B 的 row。

## 6. 修改范围

预计只涉及 Renderer：

- `frontend/src/features/skills/SkillsPage.tsx`
  - 移除 `all` filter；
  - 增加 `personal | project` context；
  - 增加 selected Workspace state 与严格 id/epoch 过滤；
  - 按当前 context 派生计数、列表和详情；
- `frontend/src/i18n/messages/en-US.ts`
  - 删除或停止使用“全部”；
  - 增加“用户默认”“项目设置”“暂无可配置项目”等文案；
- `frontend/src/i18n/messages/zh-CN.ts`
  - 同步中文文案；
- 受影响的 Renderer 测试或纯列表派生测试。

明确不修改：

- `src/agent/`；
- `src/workbench/`；
- `src/bridge/`；
- `.agentcore/bundles/<target-id>`；
- `docs/renderer-bridge-contract.md`；
- Skill management/enablement persistence；
- schema、Bridge revision、ABI revision 和产品版本。

## 7. 验收矩阵

| 场景                                     | 必须结果                                                      |
| ---------------------------------------- | ------------------------------------------------------------- |
| Personal 4 行、一个空项目的 Project 4 行 | 用户默认显示 4；项目设置显示 4；没有任何视图显示 8            |
| 默认打开 Skill 中心                      | 进入用户默认，不存在“全部”                                    |
| 两个 Manual Workspace 各有相同 4 行      | 选择项目 A 只显示 A 的 4 行；选择项目 B 只显示 B 的 4 行      |
| Workspace id 相同但 epoch 已变化         | 不显示旧 epoch row                                            |
| 没有 Manual Workspace                    | 项目设置显示明确空状态，不显示其他 scope row                  |
| Project row 为 inherit                   | 显示“跟随用户设置”，switch 显示 effective enabled 值          |
| Project row 有显式 override              | 显示 effective 值并提供“恢复跟随用户”                         |
| 搜索                                     | 只搜索当前 context，结果计数不包含其他 context                |
| Needs attention                          | 只统计和展示当前 context 的 issue                             |
| 切换 Workspace                           | 关闭不再可见 row 的详情抽屉                                   |
| Personal mutation                        | command payload 与 revision 语义保持现状                      |
| Project mutation                         | command 精确携带所选 Workspace id/epoch 与现有双 revision     |
| 合同与版本                               | Host、Bridge payload、AgentCore、persistence 和所有版本零变化 |

## 8. 验证

至少执行：

```text
npm --workspace @metawork/renderer run check
npm run format:check
```

并在真实应用中复现原场景：

1. 用户目录存在 4 个 Skill；
2. 注册一个 `.agents/skills` 为空的 Manual Workspace；
3. 用户默认显示 4；
4. 项目设置选择该 Workspace 后显示 4 个“跟随用户设置”row；
5. 页面任何状态都不再显示 8；
6. 分别切换一次用户默认和项目 override，确认 command、revision 与刷新结果正确。

# MCP 页面体验完善方案

> 状态：方案讨论稿，待批准
>
> 范围：MCP 页面的业务流程摩擦、交互引导、视觉一致性与 Foundation 组件收敛。
> 不改变 §5.10 的安全语义：Add/Replace 即授权、隔离测试、Runtime 不可变与
> restart_required、最小权限 allowlist、新发现工具不自动扩权全部保持。

## 1. 现状判断

已核实的事实：

- 14 个 `metawork.mcp.*` 命令全部接通 UI；业务功能相对成熟范围完整，唯一
  功能洞是 secret capture（Native SDK 无安全文本输入 capability，fail closed）。
- 用户旅程"配置 → 测试 → 重启生效 → 放行工具"四步散落在四个互不引导的
  位置：测试按钮在详情抽屉深处、测试结果是详情内瞬时文案、`restart_required`
  是行级状态词、allowlist 需逐工具勾选。
- 竞品共识（Cursor/VS Code/Cline）：连接状态以行级状态灯常驻；保存即重连
  （per-server 热重启）；错误可见（独立日志或行内错误）。我们因 Runtime
  不可变采用两段式，属架构决策不推翻，但状态呈现与错误可见性是真实短板。
- 视觉层：行 hover 直接消费 `--metask-primary-soft`（违反 token 分层且读作
  选中态）；两页间距节律抖动（header gap 32/24、toolbar 28/24、gap 14/12）；
  `--mcp-border`/`--skill-border` 是 `--ui-border` 的纯别名；搜索框在两页各有
  一份几乎相同的手工实现；`components/ui/alert.tsx` 零消费者而 MCP 自造
  `.mcp-state-banner`。

## 2. 业务流程调整（四项，均不破坏既有不变量）

### 2.1 已发现工具的批量授权

现状：新 server allowlist 默认全空，测试显示 connected + N tools 后，重启完
工具仍全部不可用，需逐个勾选。

调整：详情工具区与测试成功节点提供"允许全部 N 个已发现工具"动作，经确认
后以完整名单调用现有 `setAllowedTools`（全量重提交语义，无新命令）。

不变量保持：授权仍来自显式用户动作；动作只覆盖当前已发现清单；此后新
发现的工具仍默认不放行。`requirements.md` §5.10 补一句批量授权动作的存在。

### 2.2 保存并测试

现状：新建/编辑保存后，测试需要用户自己发现并触发。

调整：Add/Replace 提交成功后 Renderer 自动触发既有 `testConnection`，详情
视图直接进入流水线的测试节点。测试无副作用，失败只结束测试。无合同变更。

### 2.3 restart_required 的一键动作与精确文案

现状：`restart_required` 是状态词，用户需自行退出再打开应用。

调整：

- 文案精确化："重启应用后，新任务可使用该连接；现有任务不受影响"；
- 流水线/横幅提供"立即重启"动作。依赖项：Native SDK 是否提供 relaunch
  capability 需先核实；若无，降级为"退出应用"按钮 + 确认对话框（提示有
  运行中任务时会中断），或仅保留精确文案。此项的最终形态以核实结果为准，
  不自造平台重启路径。

### 2.4 static credential 的入口拦截

现状：secret capture 不可用期间，用户可完整配置 static 认证的 server，最后
停在 `needs_authentication` 且无路可走。

调整：认证方式选择步骤按 `capabilities.secretCapture` 分支——能力缺失时
static 选项禁用并标注"暂不可用（需要安全输入能力）"。fail closed 从终点
提前到入口；能力恢复后自动解禁。纯 Renderer 分支，无合同变更。

拦截只作用于"新建选择 static"与"从其他 auth mode 切换到 static"；编辑
既有 static server 时保留原 auth mode 原样可保存（display name、timeout 等
合法编辑不被堵死），secret 录入动作维持现有 capability 分支。

## 3. 交互设计

### 3.1 详情流水线

详情视图顶部以状态流水线呈现三步旅程：

```text
已保存 → 测试连接 [connected · N 个工具 / failed · N 个问题]
       → 允许工具 [N/M 已放行]
       → 重启后对新任务生效 / 新任务可用
```

- 每个节点显示当前状态与下一步动作；
- 测试结果驻留在流水线上，不再是瞬时文案。

### 3.2 行级状态常驻

列表行的 state 列升级为状态灯 + 文案：连接测试结果（connected/failed）、
`needs_authentication`、`restart_required`、disabled 等以统一的状态点呈现。
数据来自现有 projection（per-server connectionTest 与 newTaskAccess），实现
时核实列表行数据面已包含 connectionTest；若仅详情可得则补投影字段。

### 3.3 needs_authentication 行内行动点

从列表行进入详情时自动定位到凭证区（secret slots / OAuth 授权）。secret
capture 不可用时显示明确原因而非隐藏按钮。

### 3.4 issue 明细（独立切片，含合同变更）

现状：测试 projection 只含 `testing | connected | failed`、tool count 与
issue count（requirements §5.10 明文）。"3 个问题"无明细可看。

调整：安全 projection 扩展 bounded、脱敏后的 issue 条目文案（复用 Skill
catalog issue 的既有 bounded issue 模式），Renderer 在详情展示明细列表。
涉及 Host projection、Bridge snapshot 合同与跨语言 fixture，requirements
§5.10 同步改写。此项单独成片，不阻塞其余交互改动。

## 4. 视觉一致性

- 行 hover 改中性 formula（与 `.skill-card:hover` 同族：border + shadow），
  主色留给选中态；消除 `--metask-primary-soft` 的 primitive 直用违规；
- 两页间距对齐一套节律（header gap 24、toolbar margin-top 28、gap 12）；
- 删除 `--mcp-border`/`--skill-border` 别名，直用 `--ui-border`；
- 保留列表形态差异：Skills 卡片墙、MCP 表格行是数据形状差异，不强行统一。

## 5. Foundation 组件收敛

- `SearchField`：提炼两页几乎相同的搜索框实现（38px、radius 10、72% panel
  mix、同一 focus formula）为 foundation 组件，宽度差异由消费侧 utility 表达；
- Banner 迁移到 `components/ui/alert.tsx`（`data-tone` → variant），MCP 与
  后续页面共用，消除 foundation 组件零消费者的状态；
- 遵守既有定制契约：消费侧只经 className utility 定制，不新增产品 CSS 对
  foundation 几何的覆盖（`frontend-boundaries` 已锁）。

## 6. 明确不做

- 不改 Runtime 不可变与重启生效语义，不调用 live apply entry；
- 不改 Add/Replace 授权模型，不加二次确认弹窗；
- 不把 allowlist 改为默认放行；
- 不做 marketplace / 一键安装 / server 目录；
- 不从 Renderer 收取任何 secret；
- 不改列表的表格形态。

## 7. 实施切片

### Slice A：视觉小刀

hover 中性化、间距节律、别名删除。纯 CSS，约十行级。

### Slice B：流程与引导

2.1 批量授权、2.2 保存并测试、2.4 入口拦截、3.1 流水线、3.2 行级状态、
3.3 认证定位、restart 精确文案。McpPage + CSS + 双语 i18n + `mcp-page`
测试更新。2.3 的一键重启按 Native SDK capability 核实结果决定形态。

### Slice C：Foundation 收敛

SearchField 与 Alert 迁移，两页消费，删除对应手工 CSS。

### Slice D：issue 明细

Host projection 扩展 + Bridge 合同 + fixture + Renderer 明细展示 +
requirements 改写。独立评审后实施。

顺序 A → B → C → D；A/B/C 无合同变更，D 单独走合同评审。

## 8. 验收矩阵

| 场景 | 预期 |
| --- | --- |
| 新建 server 保存 | 自动进入测试，流水线显示测试节点 |
| 测试成功 | 行级状态灯 connected + 工具数常驻；流水线出现"允许全部 N 个工具" |
| 批量授权确认 | 一次 `setAllowedTools` 全量提交；新发现工具仍不放行 |
| secret capture 不可用时选 static | 入口即禁用并显示原因，无法进入死胡同 |
| needs_authentication 行点击 | 详情定位到凭证区 |
| restart_required | 文案含"新任务生效、现有任务不受影响"；动作形态按 capability 核实结果 |
| 行 hover | 中性反馈，无主色底 |
| 两页并排 | 间距节律一致，搜索框同一组件 |
| issue count > 0（Slice D 后） | 详情可见 bounded 脱敏明细 |

## 9. Source of truth 同步

- `docs/requirements.md` §5.10：批量授权动作；Slice D 的 projection 措辞；
- `docs/workbench-ui-design.md`：MCP 页流水线、行级状态、入口拦截；
- `docs/validation.md`：`mcp-page` 回归证据与 Slice D 合同证据；
- `components/ui/README.md`：SearchField、Alert 预设登记。

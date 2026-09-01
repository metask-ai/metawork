# File Changes 接入方案

> 状态：实施方案，不是规范真源。实际落地造成产品范围、持久化、Bridge、UI 或验证合同变化时，必须同步更新对应真源。

## 1. 目标

将现有 AgentCore `file_changes` 接入 MetaWork 产品链路，让用户在每个 Run 下查看已记录的文件修改及 unified diff。

```text
file_changes
→ Product Run 状态
→ Task history + diff artifact
→ Bridge
→ Review changes UI
```

## 2. 产品范围

展示：

- `created`
- `modified`
- `deleted`
- `moved`
- `applied`
- `partial`
- unified diff
- diff 是否完整
- observation 是否发生 overflow/lost

不展示：

- `failed`
- `rejected`
- `no_change`

不进行以下推断：

- 不解析 Tool 文本或 Bash 输出。
- 不扫描 Git 或 Workspace。
- 不从 File Preview 推断修改。
- 不合并为 Run 最终净 diff。
- 不累计多次修改的 `+/-` 作为最终变化量。

产品文案定义为：

> 显示 Agent 已记录的文件工具修改。

`agent_depth` 只表示记录来源于当前 Run 内哪一层 Agent。第一版接纳所有 depth，统一归属当前 Run；不按 depth 丢弃或合并记录，也不在产品中建立 subagent 层级。

## 3. Product 数据模型

文件修改属于 Run，不挂在 `ToolView` 下。

```ts
type RunFileChanges = {
  observation: "collecting" | "complete" | "incomplete";
  changes: FileChangeRecord[];
};

type FileChangeRecord = {
  id: string;
  order: string;
  kind: "created" | "modified" | "deleted" | "moved";
  status: "applied" | "partial";
  displayPath: string;
  fromDisplayPath: string | null;
  beforeBytes: string;
  afterBytes: string;
  diffAvailable: boolean;
  diffComplete: boolean;
  redacted: boolean;
};
```

内部另外保存：

- 原始 Tool ID 的单向关联摘要；
- 可选 diff artifact reference；
- artifact size/digest；
- Run 创建时即存在的单调 `known_loss` 状态，用于在任何后续分配失败时仍能无分配地记录观测丢失。

这些内部字段不进入 Renderer。

状态语义：

- `null`：旧历史，没有这项产品记录；
- `collecting`：Run 仍可能收到文件修改事件；
- `complete`：terminal event drain 已完成，未观察到已知丢失；
- `incomplete`：overflow、lost、容量不足、非法 locator、意外中断等；
- `complete + changes=[]`：确认没有结构化文件修改，UI 不显示空模块；
- `incomplete + changes=[]`：已知观测发生丢失，但没有可展示记录，UI 必须显示不完整提示，不能当作“没有修改”。

`complete` 只表示 typed `file_changes` 记录没有已知丢失，不表示 Workspace 所有修改都已覆盖。

恢复时，任何持久化为 `collecting`、但已不存在 live Session/event owner 的 Run，必须收口为 `incomplete`。已保存的记录和仍有效的 artifact reference 继续保留；不等待迟到事件，也不尝试重放 AgentCore 事件。

## 4. 事件接入与降级

File Changes 是补充审查能力，不是 Run 成功的前置条件。它可以不完整，但不能静默不完整，也不能因补充审查数据过大或本地容量不足而终止原本可完成的 Run。

### 4.1 Agent 事件边界

当前 Agent 事件单条编码上限为 `max_event_bytes`（现值 512 KiB），而 AgentCore 协议允许一个 `file_changes` 事件携带多条大 diff，不能假设合法协议事件一定低于该上限。

因此增加一条仅针对 `file_changes` 的可降级路径：

1. 正常尺寸事件继续走现有完整解析和 event pump。
2. 超过 `max_event_bytes` 时，使用无分配、有限深度的流式 JSON 扫描器校验完整 JSON 语法，同时只提取顶层 canonical event discriminator，不复制或完整物化事件。
3. 若确认是 `file_changes`，丢弃该事件正文，设置 Session 内预留的 `file_changes_lost` 单调标志，并返回 continue。
4. 若 event pump 因本地容量无法接纳已解析的 `file_changes`，释放该事件，设置同一标志，并返回 continue。
5. oversized 的非 `file_changes` 事件、无法确认类型的事件、非法 JSON 或扫描深度超限继续按现有 fatal 语义处理；不能把未知控制事件误降级为数据丢失。
6. Session terminal 结果携带 `file_changes_lost`，不依赖再投递一条可能同样失败的数据事件；Product 在 terminal drain 收口时据此将 observation 置为 `incomplete`。

不通过整体抬高事件和队列上限解决该问题，也不依赖 AgentCore 发射侧尚未形成合同的聚合尺寸保证。后续若 AgentCore 提供更细粒度事件或明确的聚合上限，可作为独立优化，不改变本方案的本地降级语义。

### 4.2 Product 投影

修改 `src/product/task/state.zig`，不再丢弃 `.file_changes`。

处理规则：

1. 只接纳 `applied` 和 `partial`。
2. 所有 `agent_depth` 都按当前 Run 收纳，保持 Product activity order。
3. 使用事件 ID 摘要和 change index 去重。
4. 生成 Product-owned ID 和稳定 order。
5. Workspace 相对路径规范化后保存。
6. Workspace 内绝对路径转换为相对路径。
7. URI、Workspace 外路径和非法路径不投影，并标记 incomplete。
8. SDK `overflow/lost`、Agent 本地 `file_changes_lost` 均标记 observation incomplete。
9. record/path/diff/artifact 任一容量不足时，保留已有记录、单调设置 `known_loss`，并丢弃无法容纳的部分；该分支不得转化为 generic consumer rejection 或让 Run 失败。
10. diff 在进入持久化和 Renderer 前执行 credential redaction。
11. `file_changes` 本身触发 durable boundary，不等待 `tool_result`。
12. terminal event drain 后，只有没有任何已知丢失才从 `collecting` 收口为 `complete`，否则收口为 `incomplete`。

同一文件修改多次时保留多条记录，Renderer 只进行视觉分组。

## 5. 持久化

### 5.1 Task history

保存文件修改元数据和 diff reference，不保存完整 diff。

旧历史格式通过可选字段恢复为：

```text
fileChanges = null
```

### 5.2 Diff artifact

增加专用 Product Task file-change store，保存脱敏后的 unified diff。

```text
<MetaWork data dir>/workbench/file-change-blobs/
```

采用现有 checkpoint store 已验证的模式：

- Application 持有 store 生命周期和 writer lock；
- Product 持有 artifact identity、引用和恢复策略；
- 原子写入；
- size/digest 校验；
- no-follow 和 resolve-beneath；
- history reference 后置安装；
- history 健康时才清理 orphan。

不复用 checkpoint 业务目录，不建立通用 Artifact Framework。

### 5.3 I/O

使用一个有界 file-change I/O lane 执行：

- diff artifact 写入；
- diff 按需读取；
- shutdown settle。

队列满或写入失败时：

- 文件修改元数据继续保留；
- diff 标记 unavailable；
- 通过预留状态无分配地将 observation 标记 incomplete；
- 不影响 Run 原有结果。

Task 删除或历史 Run 被清理后，再删除对应 artifact。

## 6. Bridge

### 6.1 Snapshot

在 `RunView` 增加：

```ts
fileChanges: RunFileChanges | null;
```

Snapshot 只运输元数据，不运输 unified diff。

### 6.2 Diff 命令

新增异步命令：

```text
metawork.files.diff
```

请求：

```json
{
  "taskId": "17",
  "runId": "23",
  "fileChangeId": "41"
}
```

响应：

```ts
type FileChangeDiffResult =
  | {
      status: "ready";
      content: string;
      complete: boolean;
      redacted: boolean;
    }
  | {
      status: "unavailable";
      reason: "not_recorded" | "capacity" | "missing" | "corrupt";
      content: "";
    };
```

Host 必须重新校验：

- Task、Run、fileChangeId 的归属；
- artifact size/digest；
- UTF-8 和响应容量；
- shutdown lifecycle。

历史 diff 不依赖当前 Workspace authorization。“打开当前文件”继续走 File Preview 权限链路。

同步更新：

- `app.zon` Bridge command allowlist；
- Native async dispatcher；
- TypeScript contracts；
- 严格 decoder；
- 跨语言 fixture；
- shutdown responder 收口。

## 7. UI

入口位于 Run 回复下方的 Work process 区域。

正常状态：

```text
文件更改   3 个文件 · 5 条修改   审查更改
```

不完整状态：

```text
文件更改   3 个文件 · 记录可能不完整   审查更改
```

`complete + changes=[]` 时不显示模块。`incomplete + changes=[]` 时显示“文件更改记录可能不完整”，但不提供空的 Review Drawer 入口。

点击后打开 Review changes Drawer：

- 左侧按目标路径分组；
- 显示 Added/Modified/Deleted/Moved；
- 同一文件多次修改显示数量；
- 右侧逐条显示真实 unified diff；
- moved 显示 `from → to`；
- deleted 不提供“打开当前文件”；
- diff 缺失、截断或脱敏时显示明确状态；
- 不显示 Run 级 `+/-` 汇总；
- 不提供 Accept/Reject。

视觉复用现有 MetaWork 组件和 token：

- 紫色用于选中和主要入口；
- 新增使用完成绿，删除使用异常红；
- 路径和 diff 使用等宽字体；
- 桌面使用宽 Drawer；
- 窄屏使用全屏审查布局；
- 支持键盘导航、焦点恢复、深浅主题和 reduced motion。

## 8. 实施顺序

### 8.1 第一阶段：事件边界和最小纵向链路

先完成 Agent 到 Product 的 loss handshake，再完成一个 `modified + applied`：

```text
真实事件
→ Product
→ history/artifact
→ Snapshot
→ diff command
→ Review Drawer
```

本阶段同时证明两条最小路径：正常事件可见；oversized 或 event-pump capacity 拒绝的 `file_changes` 不终止 Session，并在 Run 收口为 incomplete。此时 capability 保持关闭。

### 8.2 第二阶段：补齐协议类型

加入：

- created；
- deleted；
- moved；
- partial；
- 多文件；
- 同一文件多次修改；
- `agent_depth > 0`；
- diff incomplete；
- overflow/lost。

### 8.3 第三阶段：安全和恢复

加入：

- 路径边界；
- credential redaction；
- Product record/path/diff/artifact 容量降级；
- interrupted Run 与 `collecting → incomplete` 恢复；
- 旧历史恢复；
- missing/corrupt artifact；
- orphan cleanup；
- Task 删除；
- shutdown settle。

### 8.4 第四阶段：验收并开放

完成第 9 节全部 Gate、Native/Bridge/Renderer 自动化和真实 AgentCore vertical 后，将：

```text
typedFileChanges: false
```

改为：

```text
typedFileChanges: true
```

## 9. 验收 Gate 与用户结果

开放 capability 前必须证明：

- 正常尺寸的 `file_changes` 能完整进入 Product；
- 超过 `max_event_bytes` 的合法 `file_changes` 不终止 Session，Run 原结果不变且 observation 最终为 incomplete；
- event pump 容量拒绝 `file_changes` 时具有相同结果；
- oversized 非 `file_changes` 控制事件、非法 JSON 和无法确认类型的事件仍然 fatal；
- Product record/path/diff/artifact 容量不足不会产生 consumer rejection，不会改变 Run 原结果；
- SDK overflow/lost、本地丢失、diff 截断、存储失败都会在 UI 中形成明确的不完整状态；
- 恢复没有 live owner 的 collecting Run 时确定性收口为 incomplete，并保留已恢复记录；
- `agent_depth > 0` 的记录与 depth 0 一样归属当前 Run，顺序稳定且不被静默遗漏；
- 旧历史、artifact 缺失/损坏、Task 删除和 shutdown 均按定义收口；
- capability 关闭时不暴露半成品入口，开放后真实 AgentCore vertical 通过。

完成后用户能够：

- 在 Run 下看到文件修改摘要；
- 查看新增、修改、删除和移动记录；
- 查看同一文件的每次实际修改；
- 打开对应 unified diff；
- 看到丢失、截断、脱敏和存储失败状态；
- 重启 MetaWork 后继续审查历史 diff；
- 对仍存在的文件打开当前内容。

第一版不实现回滚、Accept/Reject、行级评论、最终净 diff、Git 扫描、Bash 修改推断和 Outputs 识别。

## 10. 落地时需要更新的真源

- `docs/requirements.md`：产品范围和用户可观察行为；
- `docs/ui-design.md`：Review changes 交互与呈现 Gate；
- `docs/product-architecture.md`：Run owner、artifact、恢复和清理；
- `docs/renderer-bridge-contract.md`：Snapshot 与异步命令；
- `docs/agentcore-integration.md`：`file_changes` 的 Product 消费、可降级事件边界和持久化语义；
- `docs/validation.md`：自动化和真实 vertical；
- `app.zon`：Bridge command allowlist。

## 11. 关键决策复盘

**为什么按 Run 归属，而不是挂在 ToolView？**

`file_changes` 是 AgentCore 对一次 Run 内文件副作用的结构化观测，一次事件可包含多条记录，也可能来自嵌套 Agent。Tool ID 只适合内部关联；把产品对象挂到 ToolView 会把审查入口和工具呈现生命周期错误耦合。

**为什么只消费 typed event，不补扫 Git、Workspace 或 Tool 文本？**

不同来源描述的是不同事实。typed event 表示 AgentCore 已记录的文件工具修改；Git/Workspace 表示当前状态；Tool 文本只是非结构化输出。混合它们会制造无法解释的遗漏、重复和归因错误。

**为什么 oversized `file_changes` 要降级，而不是整体提高 512 KiB 上限？**

提高单事件上限会同时放大事件 owner、解析对象、队列和并发 Session 的最坏内存占用，却仍无法证明覆盖协议理论上界。File Changes 不是 Run 正确执行所必需的数据，因此更可靠的合同是“保住 Run，诚实标记观测不完整”。

**为什么 loss 状态必须预留且单调？**

容量失败发生时不能再依赖一次可能失败的分配来记录失败。预留标志保证错误路径无分配；单调状态保证任何后续成功记录都不能把已经发生的丢失洗成 complete。

**为什么不通过 event pump 再发送一条 `file_changes_lost` 事件？**

原始失败可能正是 event pump 容量不足，再走同一通道无法形成保证。loss bit 随 Session terminal 结果进入 Product，利用已有 terminal drain 作为确定性收口点。

**为什么接纳所有 `agent_depth`，但第一版不展示 depth？**

depth 不改变记录属于当前 Run 的事实，丢弃 depth 大于零会静默漏掉 subagent 修改；而展示 Agent 层级不是文件审查所必需，会引入另一套产品对象和导航。先完整收纳，后续只有出现明确用户需求才增加呈现。

**为什么 diff 独立存储，不进入 Snapshot 或 Task history？**

diff 是大正文且按需读取。把它放进 Snapshot 会放大每次状态广播，把它放进 history 会放大恢复和重写成本；专用 blob store 让 history 只持有可校验引用，并保持 Bridge 响应有界。

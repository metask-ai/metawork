# Agent 结果文件预览 v1 方案

状态：方案讨论稿；Windows AgentCore canonical bundle 已升级到 `55f76601ee6f`，预览功能实现尚未开始

本文只定义 Agent 结果中的文件快速预览，不包含文件附件、上下文注入、Outputs、Files changed 或完整 diff 编辑器。

## 1. 目标

当 AgentCore `tool_result` 携带结构化 `file_refs` 后，MetaWork 能够：

1. 从 AgentCore 接收结构化文件引用；
2. 在工具结果中显示文件入口；
3. 用户点击后在 MetaWork 内预览文件；
4. 支持跳转到 AgentCore 提供的行范围；
5. 文件失效或无权限时给出明确状态。

## 2. 非目标

- Composer 中选择文件并作为 Agent 上下文发送；
- 从普通 Agent 文本、Bash 输出或 `file://` 文本猜测文件；
- 自动归类 Outputs 或 Files changed；
- 完整 diff 编辑器和文件版本历史；
- 文件实时同步；
- PDF、Notebook、远程 URI 的深度预览；
- 系统文件管理器打开动作。

## 3. 能力边界

```text
AgentCore Revision 8（`55f76601ee6f` exact bundle）
  tool_result.file_refs
          ↓
Agent Session
  解码、校验、深拷贝
          ↓
Workbench
  关联 Task / Run / ToolActivity
          ↓
Renderer Bridge
  发布非敏感文件引用
          ↓
Renderer
  文件 Chip / 预览入口
          ↓
Host Preview Service
  重新授权、读取、截断、返回预览
```

AgentCore 只提供文件引用事实，不负责读取文件、授权访问或决定 UI 行为。

## 4. AgentCore 接入

MetaWork 消费 Windows canonical AgentCore `55f76601ee6f`（ABI Revision 8）中的可选字段：

```text
tool_result.file_refs[]
```

当前 bundle 的每个引用包含：

- `locator`（`workspace_path`、`absolute_path` 或 `uri`）；
- `title`；
- `kind`；
- 可选 `range`。

当前 SDK binding 对该字段的硬边界为：单个 `tool_result` 最多 32 个引用；`workspace_path` / `absolute_path` 最多 4096 bytes；`uri` 最多 8192 bytes；`title` 最多 256 bytes；`kind` 最多 64 bytes。range 的行列从 1 开始，结束位置不得早于开始位置；超限、非法 range 或 malformed payload 由 typed decoder fail closed。

`kind` 和 locator 只作为 AgentCore 提供的事实保存；MetaWork 不从工具名称、普通文本或 Bash 输出推断文件引用。失败、拒绝、目标状态未知时，不生成写入类引用。未知 `kind` 保留并按普通文件引用处理。

Agent Session 必须：

1. 校验 UTF-8；
2. 校验引用数量和字节上限；
3. 校验 locator 和 range；
4. 对 callback 中的 borrowed 数据做深拷贝；
5. 将引用与 `Task / Run / ToolActivity` 绑定；
6. `file_refs` 为可选字段时按空引用处理；不建立旧 ABI revision 的兼容路径。

不新增 AgentCore `open_file` 命令。当前分支已将 Windows canonical bundle hard cut 到 `55f76601ee6f90f60c513dbef20a21c904dcbd78`；不保留旧 bundle、旧 revision parser 或静默 fallback。文件引用的可消费合同以锁定 manifest 与 canonical bundle 中的 `bindings/zig/src/protocol.zig` 为准。

## 5. Workbench 产品投影

不要把 AgentCore 原始协议直接暴露给 Renderer。Workbench 使用自己的非敏感产品投影：

```text
ToolFileReference {
    id
    title
    display_path
    kind
    range
    availability
}
```

- `id`：MetaWork 内部文件引用 ID；
- `title`：文件名；
- `display_path`：Workspace 相对路径；
- `kind`：`read`、`created`、`modified`、`notebook` 或未知值；
- `range`：可选的行列范围；
- `availability`：Host 当前判断的可用状态。

绝对路径只留在 Host 侧，不进入 Renderer。文件引用保存于：

```text
Task → Run → ToolActivity → file_refs
```

第一版只表示“工具访问或修改过的文件”，不自动等于最终交付文件。

## 6. Bridge 合同

增加产品级预览动作：

```text
preview_file
```

Renderer 只提交：

```text
file_reference_id
```

不得提交绝对路径、任意用户路径、shell 命令或 AgentCore handle。

Host 返回有界的预览结果：

```text
FilePreview {
    id
    title
    display_path
    language
    content
    truncated
    range
    file_state
}
```

继续使用 `metawork.renderer-bridge` revision 1，不建立局部 schema version。

## 7. Host Preview Service

预览服务由 Host / Workbench 持有，不放进 AgentCore，也不允许 Renderer 直接读取文件。

### 7.1 请求流程

```text
Renderer: preview_file(file_reference_id)
    ↓
Host 找到原始 FileReference
    ↓
重新验证路径和权限
    ↓
检查文件状态
    ↓
读取有界内容
    ↓
返回 FilePreview
```

### 7.2 重新验证

每次点击预览都重新检查：

- Task 和 Workspace 是否仍匹配；
- Workspace epoch 是否仍有效；
- `workspace_path` 是否含路径穿越；
- `absolute_path` 是否在允许范围；
- Windows reparse point / symlink 是否逃逸；
- 文件是否存在；
- 文件是否仍是允许的类型；
- 当前 Host 权限是否允许读取。

AgentCore 的 `absolute_path` 只代表定位信息，不代表访问授权。

### 7.3 Preview ticket

Workbench 应生成绑定以下事实的一次性 preview ticket：

```text
Task
Workspace
Workspace epoch
Run
ToolActivity
file_reference_id
expiry
```

Renderer 只持有 ticket 或内部 ID，不持有真实绝对路径。

## 8. 预览格式

### v1 支持

优先支持文本型文件：

- Markdown；
- TXT；
- JSON；
- Zig；
- TypeScript / JavaScript；
- Rust；
- Python；
- 其他可识别的 UTF-8 文本。

预览必须支持：

- 有界读取；
- 最大行数和最大单行长度；
- AgentCore range 定位；
- 内容截断标识；
- 基础语法高亮。

PDF、图片、Notebook、二进制和远程 URI 第一版显示受限状态，不实现深度内嵌渲染。

Markdown 预览禁止 raw HTML、script、远程 embed 和隐式网络加载。

## 9. Renderer 交互

工具结果中显示文件 Chip：

```text
Edit completed

📄 src/main.zig · modified · line 42
```

交互规则：

- 点击文件名打开预览；
- 点击行号打开并定位；
- 多个引用按列表显示；
- 不自动弹出预览；
- 不因为文件引用自动打开 Inspector；
- 预览关闭后返回原工具结果；
- 支持键盘 Enter / Space；
- 使用明确的无障碍名称，例如“预览 src/main.zig”。

预览界面优先使用中间区域的轻量 drawer / pane，不扩展为完整 Inspector 模块。

## 10. 预览状态

至少支持：

```text
loading
ready
truncated
missing
restricted
unsupported
error
```

文件删除或权限变化时，不返回过期内容并伪装成当前文件。v1 不采集文件指纹，因此不承诺识别“引用产生后文件被外部修改”；后续引入可靠 observation 或 content digest 后再增加 `changed` 状态。

预览内容不必持久化。持久化的是文件引用和元数据；历史 Task 重新打开时按需读取。

## 11. 实施阶段

### Phase 0：bundle 和合同验证

- Windows canonical bundle 使用 AgentCore `55f76601ee6f` Revision 8；macOS baseline 独立维护，不阻塞本分支；
- SDK 可以解码 `file_refs`；
- manifest 和 bundle hash 校验通过；
- 工具结果按 AgentCore typed `file_refs` 解码，不按工具名猜测引用。

### Phase 1：AgentCore → Workbench

- event 解码；
- 文件引用深拷贝；
- 工具活动关联；
- 有界 projection；
- 不兼容旧 ABI revision；缺少可选 `file_refs` 只表示该工具结果没有文件引用。

### Phase 2：Workbench → Bridge

- 文件引用产品 DTO；
- `preview_file` command；
- 预览状态和错误映射；
- 绝对路径隔离。

### Phase 3：Host 预览服务

- Workspace / path 校验；
- preview ticket；
- bounded read；
- 文本格式检测；
- missing / restricted / unsupported 状态；

### Phase 4：Renderer

- ToolActivity 文件 Chip；
- 预览 drawer / pane；
- range 定位；
- 截断和错误状态；
- 键盘与无障碍交互。

## 12. 验收标准

1. 携带 `workspace_path` 的成功 `tool_result` 能生成文件入口；
2. `kind` 原样保留，未知值不被静默丢弃，也不从工具名称或普通文本推断；
3. 合法 range 能定位预览位置，非法 range 在 Agent Session 解码阶段被拒绝；
4. `absolute_path`、`uri` 只保留在 Host 侧，Bridge payload 不包含真实定位值；
5. Workspace 路径、绝对路径和 URI 都经过 Host 重新授权，越界路径及 symlink / reparse 逃逸被拒绝；
6. 文件被删除后显示 `missing`，权限或类型不允许时显示 `restricted` 或 `unsupported`；v1 不声称检测外部修改；
7. 大文件显示有界截断；
8. Renderer reload 后历史引用仍可按需重新验证和浏览；
9. 没有 `file_refs` 时不会从文本猜出假链接；
10. 不兼容旧 ABI revision，不存在旧 bundle fallback。

## 13. 方案结论

```text
AgentCore：提供可信文件引用
Workbench：保存和投影引用
Host：执行安全预览读取
Renderer：呈现预览
```

Windows AgentCore `55f76601ee6f` 的 Revision 8 `tool_result.file_refs` 已经足够作为预览入口的数据基础；macOS 保持独立 baseline，不阻塞本分支方案。MetaWork 需要补齐的是 Host 预览服务、Workbench 投影、Bridge command 和 Renderer 展示，而不是另造一套 AgentCore 文件协议。

## Implementation status (2026-08-14)

The first end-to-end implementation slice is now in the working tree:

- Agent Session validates UTF-8 in typed `file_refs` and Workbench projects,
  bounds, persists, and snapshots opaque file-reference ids.
- `metawork.files.preview` accepts only `fileReferenceId`; Host-side Workbench
  re-authorizes workspace containment and opens files with no-follow,
  resolve-beneath semantics before bounded UTF-8 reads.
- Snapshot and preview responses use one wire representation for ranges:
  line/column values are canonical decimal strings. Reference ids are derived
  from durable Task and Run identities rather than Agent session route ids.
- Renderer tool cards expose file chips and a lightweight preview pane with
  ready/truncated/missing/restricted/unsupported/error states.
- v1 still does not collect fingerprints or claim external-change detection.

The preview plan remains intentionally uncommitted while implementation
changes are reviewed.

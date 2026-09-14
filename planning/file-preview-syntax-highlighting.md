# MetaWork 文件预览语法高亮实施方案

> 状态：最终实施方案，非规范性文档
> 日期：2026-09-14
> 目的：在不引入编辑器、Bridge 合同或 Host 读取路径变化的前提下，为文件预览中的常见代码文件增加有界、可降级的语法高亮。
> 说明：本文不是产品、架构或 wire contract 的真源。实施时，用户可观察行为必须同步收口到 `docs/ui-design.md`；其他稳定合同继续由仓库 `AGENTS.md` 指定的真源拥有。

## 1. 最终结论

MetaWork 应为文件预览中的已识别代码文件自动提供语法高亮。高亮只是一层 Renderer 展示增强，不改变文件身份、读取权限、安全分类或内容。

最终方案采用 `refractor/core` 和显式注册的 Prism grammar：

- 主要根据 `displayPath` 的特殊文件名和后缀选择语言；
- 无后缀脚本可以根据首行 shebang 选择语言；
- 不扫描全文自动猜测语言；
- 使用 Refractor AST 渲染 React 节点，不使用 `dangerouslySetInnerHTML`；
- 高亮模块仅在打开可识别且处于性能预算内的文件时按需加载；
- 未知格式、超出预算、加载失败或高亮失败时继续显示完整纯文本；
- 不增加设置、开关、语言选择器、状态提示或错误提示；
- 不引入 Monaco、Shiki、Web Worker、WASM 或 CSP 变化；
- 不修改 Bridge、Host、Product 或 Zig 文件读取实现。

本次只增强 File Preview。对话 Markdown、Tool 详情和共享 AI `CodeBlock` 不在本次范围内。

## 2. 当前实现与约束

### 2.1 当前数据链路

File Preview 现有链路保持不变：

1. Run 发布结构化文件引用；
2. 用户通过对话或 Tool 的文件入口选择精确引用；
3. Renderer 使用 `taskId + runId + fileReferenceId` 请求 Host；
4. Host 在独立 worker lane 中执行 no-follow、root-contained、regular-file-only 读取；
5. Host 只返回有界、已脱敏的 UTF-8 文本；
6. Renderer 在 Task Panel 中渲染当前内容。

现有 Host 上限为：

- 正文最多 256 KiB；
- 最多 5000 行；
- 单行最多 8192 bytes；
- 非 UTF-8、含不安全控制字符或非普通文件返回非 ready 状态。

这些属于现有读取与安全合同，本方案不修改。

### 2.2 当前 Renderer 行为

- `.md`、`.markdown` 默认以安全 Markdown 文档展示，并支持“预览 / 源码”切换；
- 其他 ready 文本统一使用等宽 `<pre>` 展示；
- HTML 只作为惰性源码显示，不执行脚本或加载资源；
- 打开、切换、刷新和关闭已经使用 request generation 防止迟到响应覆盖当前目标；
- 切换文件通过 component key 恢复默认模式，刷新保持当前 Markdown 模式。

语法高亮必须复用这些生命周期，不建立第二套文件预览状态。

### 2.3 规范变化

`docs/ui-design.md` 当前明确规定文件预览不做语法高亮。实现本方案时必须修改该段，稳定描述以下行为：

- 已识别且处于渲染预算内的代码文件自动高亮；
- 未知格式、大文件和高亮失败继续显示纯文本；
- HTML 仍只显示惰性源码；
- 不增加模式开关、语言选择、行号、diff、range 高亮、自动刷新或 watcher。

精确语言表、字符门槛、行数门槛和 token 节点门槛是机器可判定的实现事实，只保留在唯一代码常量及其测试中，不复制到规范文档。

## 3. 目标与非目标

### 3.1 本次目标

- 提升用户阅读 Agent 引用代码文件时的扫描效率；
- 保留原始文件的空白、缩进、换行和横向滚动；
- 高亮前后复制得到的文字与 Host 返回正文完全一致；
- 跟随 MetaWork 明暗主题，不呈现突兀的嵌入式编辑器外观；
- 在未知语言、异常 grammar 和大文件条件下可靠降级；
- 保持应用启动、普通文本预览和 Markdown 文档预览不加载高亮依赖；
- 保持文件正文不进入日志、缓存、Snapshot 或持久化数据。

### 3.2 明确不做

- 文件编辑、保存、格式化或代码补全；
- Monaco、CodeMirror 或其他完整编辑器；
- 行号、Minimap、折叠、搜索、复制按钮和语言选择器；
- 自动语言检测或内容统计；
- diff、诊断、语义分析、LSP、Tree-sitter 或 AST 代码理解；
- Markdown 渲染模式中 fenced code 的高亮；
- 对话消息、Tool 详情和审批参数中的代码高亮；
- Web Worker、WASM、CSP 放宽或新的运行时资源下载；
- Bridge response 增加 MIME、language 或 path 字段；
- 为未来编辑器能力预留抽象或兼容层。

## 4. 用户可观察行为

### 4.1 普通代码文件

用户打开受支持的代码文件时：

1. 正文读取成功后立即显示完整纯文本；
2. Renderer 在后台按需加载本地高亮 chunk；
3. 当前文件仍有效且高亮成功时，原位替换为带 token 颜色的同一份文字；
4. 加载或高亮失败时保持纯文本，不出现错误、闪烁或重试入口。

高亮不是独立状态。界面不得出现“正在高亮”“高亮失败”或“纯文本模式”等说明。

### 4.2 Markdown

- “预览”模式完全保持现状；
- “源码”模式按 Markdown grammar 高亮；
- 刷新继续保持当前模式；
- 切换到其他文件或关闭后重新打开继续恢复默认“预览”模式；
- Markdown 文档内的 fenced code 本次不改动。

### 4.3 HTML 与 XML

- HTML、HTM、SVG、XML 可以显示 markup 语法颜色；
- 文件内容仍只进入 `<pre><code>` 下的文本与受控 token `<span>`；
- 任何 `<script>`、`<img>`、`<iframe>`、事件属性或 URL 都不得形成真实可执行 DOM；
- 不新增本地或远程资源读取。

### 4.4 未知格式与超出预算

无法识别语言或超出高亮预算时，继续使用当前纯文本表现：

- 不显示警告或状态标签；
- 不影响刷新、滚动、选择和复制；
- 不尝试自动检测语言；
- 不加载高亮模块。

## 5. 语言识别

### 5.1 识别顺序

`resolvePreviewLanguage(displayPath, content)` 使用固定顺序：

1. 从 `displayPath` 中按 `/` 和 `\\` 取得 basename；
2. 匹配显式特殊文件名；
3. 匹配不区分大小写的最后一个文件后缀；
4. 仅当没有可识别后缀时检查首行 shebang；
5. 无法识别则返回 `null`。

`displayPath` 不是 URL：不得 percent-decode、解析 query/fragment、访问文件系统或规范化为真实路径。识别结果只控制颜色。

### 5.2 特殊文件名

首版支持：

| 文件名 | Grammar |
| --- | --- |
| `Dockerfile`、`Containerfile` | `docker` |
| `Makefile`、`GNUmakefile` | `makefile` |
| `CMakeLists.txt` | `cmake` |
| `Cargo.lock` | `toml` |
| `Gemfile` | `ruby` |

特殊文件名匹配使用 basename，不把目录名解释为文件类型。

### 5.3 后缀映射

| 文件后缀 | Grammar |
| --- | --- |
| `.js`、`.mjs`、`.cjs` | `javascript` |
| `.jsx` | `jsx` |
| `.ts`、`.mts`、`.cts` | `typescript` |
| `.tsx` | `tsx` |
| `.json`、`.jsonc` | `json` |
| `.zig`、`.zon` | `zig` |
| `.py` | `python` |
| `.rs` | `rust` |
| `.go` | `go` |
| `.c`、`.h` | `c` |
| `.cc`、`.cpp`、`.cxx`、`.hpp` | `cpp` |
| `.cs` | `csharp` |
| `.java` | `java` |
| `.html`、`.htm`、`.xml`、`.svg` | `markup` |
| `.css` | `css` |
| `.md`、`.markdown` | `markdown` |
| `.yaml`、`.yml` | `yaml` |
| `.toml` | `toml` |
| `.ini`、`.cfg`、`.conf` | `ini` |
| `.sh`、`.bash`、`.zsh` | `bash` |
| `.ps1`、`.psm1`、`.psd1` | `powershell` |
| `.sql` | `sql` |
| `.diff`、`.patch` | `diff` |
| `.rb` | `ruby` |

`.zon` 使用 Zig grammar 是展示层近似，不声明 ZON 与 Zig 源码具有相同语义。

### 5.4 Shebang

仅检查第一行，且只识别下列稳定形式：

- `node`、`deno`、`bun` → `javascript`；
- `python`、`python3` → `python`；
- `sh`、`bash`、`zsh` → `bash`；
- `pwsh`、`powershell` → `powershell`；
- `ruby` → `ruby`。

支持直接解释器路径和 `/usr/bin/env` 形式。不得根据正文中的关键字、标点或相似度猜测语言。

## 6. 高亮实现

### 6.1 依赖选择

使用：

- `refractor/core`；
- 仅显式导入第 5 节所需 grammar；
- Refractor 返回的 HAST 作为中间结果。

不使用默认 common bundle 或 all bundle，避免把未承诺语言加入产物。依赖及所有 transitive license 必须继续通过现有 package lock 和分发依赖流程。

### 6.2 懒加载边界

新增 `frontend/src/features/task-panel/syntax-highlight.ts`：

- 静态导入 `refractor/core` 和允许的 grammar；
- 完成一次模块级、幂等的 grammar 注册；
- 导出纯函数 `highlightSource(content, language)`；
- 不缓存输入正文或高亮结果；
- 不访问 Bridge、DOM、Task state 或浏览器全局对象。

`HighlightedSource.tsx` 使用动态 `import("./syntax-highlight.ts")`。因此高亮依赖形成独立 chunk，并且只在已识别、处于预算内的源码真正需要高亮时加载。

### 6.3 AST 白名单

Renderer 只接受：

- `root`；
- `text`；
- tagName 精确为 `span` 的 `element`；
- `className` 为字符串数组且每项满足受控 token class 格式。

不复制 Refractor 节点上的任意属性，不接受 style、id、URL、事件属性或其他 element。遇到未知节点、非法属性、超深嵌套或节点预算溢出时，放弃整棵高亮树并保留纯文本。

React key 使用遍历过程生成的稳定位置 key，不从代码正文构造 DOM id 或 selector。

### 6.4 内容完整性

高亮成功后必须满足：

```text
renderedTextContent === originalContent
```

如果 AST 文本拼接结果与输入不完全一致，则视为高亮失败并回退纯文本。不得修剪末尾换行、转换 CRLF、展开 tab 或替换控制字符。

### 6.5 错误处理

- 模块加载错误、未知 grammar、tokenize 异常和 AST 校验失败全部回退纯文本；
- 不将源文件正文、路径或异常对象写入日志；
- 不显示高亮专属错误状态；
- 不重试同一 mounted 内容；下一次刷新或打开可以重新尝试；
- 高亮失败不能影响现有 File Preview `ready` 状态。

## 7. Renderer 生命周期

`HighlightedSource` 始终先渲染可聚焦的纯文本 `<pre>`，随后使用 effect 启动渐进增强。

effect 必须：

1. 在语言识别和性能预算不通过时立即结束，不触发动态 import；
2. 新内容到达时先清除旧 token tree，使新纯文本立即可见；
3. 在 dynamic import 完成后先检查当前 effect 是否已取消；
4. 仅对仍然活动的内容执行高亮；
5. 高亮完成后再次检查取消状态和输入 identity；
6. 组件卸载、路径变化、正文变化或模式卸载后拒绝迟到结果。

不得把 token tree 提升到 `App.tsx`、Snapshot store 或其他长期 owner。组件卸载后不保留正文级 memoization 或 cache。

现有 File Preview request generation 继续负责 Host 响应的身份正确性；本地高亮 effect 只负责 Renderer 内的派生结果，二者不能合并。

## 8. 性能预算

### 8.1 输入预算

首版高亮条件固定为同时满足：

- `content.length <= 65_536` UTF-16 code units；
- 行数不超过 1500。

这里使用 code units 而不是 UTF-8 bytes，因为 Renderer tokenization 和 DOM 成本更接近 JavaScript 字符串长度。行数检查使用有界扫描，达到第 1501 行后立即停止，不通过 `split()` 构造完整行数组。

### 8.2 输出预算

AST 白名单转换最多接受 20,000 个节点，嵌套深度最多 8。任一预算超出即丢弃派生 AST，继续显示原始纯文本。

精确预算由代码常量唯一拥有，并由边界测试固定。未来调整预算只要求代码和测试同步；只有用户可观察策略变化时才修改 UI 规范。

### 8.3 首屏与主线程

- 纯文本必须在收到 Host ready 内容的同一次 React render 中出现；
- dynamic import 和 tokenization 在纯文本提交后的 effect 中发生；
- 首版不引入 Worker；
- 人工验收若发现预算内输入仍造成明显交互停顿，应先降低预算；只有降低预算无法满足产品需求时，才另立 Worker 方案。

Worker 不是本次的隐式 fallback，也不得为了高亮放宽 release CSP。

## 9. 视觉设计

### 9.1 布局

保持现有文件源码布局：

- 使用 `var(--font-mono)`；
- 13px 字号；
- 1.75 行高；
- 16px 内边距；
- `white-space: pre`；
- 独立横向和纵向滚动；
- 背景继续使用 `var(--ui-surface-canvas)`；
- `<pre>` 使用 `tabIndex={0}`，保留可见键盘焦点。

高亮不得改变行高、字重、字符间距或滚动容器结构，避免纯文本切换为 token 后发生布局跳动。

### 9.2 语义颜色

在 `frontend/src/styles/metask-tokens.css` 中增加六个语义 token，分别为 comment、keyword、string、constant、function 和 punctuation。

建议基线：

| 角色 | Light | Dark |
| --- | --- | --- |
| Comment | `#626775` | `#A7ABB7` |
| Keyword | `#6639BA` | `#C6A0F6` |
| String / inserted | `#26734D` | `#8BD5A5` |
| Number / constant / deleted | `#8A5515` | `#F5B97A` |
| Function / class / tag | `#2457A6` | `#8AADF4` |
| Punctuation / operator | `#4E5360` | `#CBD0DA` |

这些颜色在现有 light canvas `#F7F8FA` 和 dark canvas `#0F1115` 上均应保持至少 4.5:1 的文字对比度。实施时需要用实际 CSS 组合重新验证，不以表中静态计算替代浏览器验收。

### 9.3 Token class 映射

`frontend/src/index.css` 只负责把 Refractor/Prism token class 映射到上述语义变量。不得导入第三方完整主题，也不得让 grammar 提供的背景色、字体或装饰覆盖 MetaWork 基础排版。

注释可以使用 muted 颜色，但不使用低对比透明度；关键字和字符串不额外加粗或斜体。颜色是扫描辅助，不是理解代码的唯一信息来源。

## 10. 代码改动边界

### 10.1 新增

- `frontend/src/features/task-panel/HighlightedSource.tsx`
- `frontend/src/features/task-panel/syntax-highlight.ts`

### 10.2 修改

- `frontend/src/features/task-panel/FilePreviewView.tsx`
- `frontend/src/styles/metask-tokens.css`
- `frontend/src/index.css`
- `frontend/package.json`
- `package-lock.json`
- `scripts/task-panel.test.mjs`
- `docs/ui-design.md`

### 10.3 不修改

- `frontend/src/app/App.tsx`
- `frontend/src/components/ai/CodeBlock.tsx`
- `frontend/src/components/ai/Markdown.tsx`
- `frontend/src/bridge/`
- `src/bridge/`
- `src/product/`
- `docs/requirements.md`
- `docs/renderer-bridge-contract.md`
- `docs/project-structure.md`
- `docs/validation.md`
- `frontend/csp.mjs`
- `frontend/vite.config.ts`

若实现要求修改上述“不修改”范围，应先停止并重新审查方案，不能用顺手重构扩大本次任务。

## 11. 实施顺序

按一个最小端到端切片完成：

1. 在 `docs/ui-design.md` 收口新的用户可观察行为；
2. 添加并锁定 Refractor 依赖；
3. 实现语言识别、性能预算和 `HighlightedSource` 纯文本基线；
4. 实现懒加载、grammar 注册、AST 白名单和内容完整性校验；
5. 接入普通文件预览与 Markdown 源码模式；
6. 增加语义色变量和 token class 映射；
7. 补齐 Renderer 测试；
8. 运行 typecheck、受影响测试和格式检查；
9. 使用 `npm run dev` 完成真实明暗主题、窄窗、滚动和大文件验收。

不得先建立通用代码查看器、语言注册中心或未来编辑器 abstraction。

## 12. 测试矩阵

### 12.1 语言识别

- Unix 和 Windows 风格 `displayPath`；
- 后缀大小写；
- `.ts`、`.tsx`、`.zig`、`.json`、`.html`、`.md` 等代表性映射；
- `Dockerfile`、`Makefile`、`CMakeLists.txt`、`Cargo.lock`；
- 无后缀 Node、Python、Bash、PowerShell shebang；
- 未知后缀和普通无后缀文件返回 `null`；
- 目录名称或正文关键字不能影响后缀结果。

### 12.2 渐进增强

- ready 内容首次 render 立即包含完整纯文本；
- 已识别且预算内的文件最终生成 token span；
- 未知格式不触发高亮模块加载；
- 超出字符或行数预算不触发高亮模块加载；
- 模块加载和高亮异常保持纯文本；
- 同一 mounted 内容失败后不形成重试循环。

### 12.3 正确性与安全

- 高亮后 `textContent` 与输入逐字相同；
- CRLF、tab、末尾换行、中文注释和 emoji 保持不变；
- HTML/JS 测试输入不能产生真实 `script`、`img`、`iframe` 或事件属性；
- 非 `span` AST element、非法 class、过深嵌套和节点超限全部回退；
- 错误路径不记录正文和路径；
- 高亮模块不缓存源码或 AST。

### 12.4 生命周期

- 路径相同但正文刷新时旧 AST 不能保留；
- 快速切换文件时旧 dynamic import 或高亮结果不能覆盖新正文；
- 关闭 Task Panel 后迟到结果不能重新挂载内容；
- Markdown 切换到源码后高亮，切回预览后不保留隐藏源码 DOM；
- Markdown 刷新继续保持当前模式；
- 切换精确文件目标继续恢复默认 Markdown 模式。

### 12.5 视觉与可访问性

- `<pre>` 可获得键盘焦点并横向滚动；
- 纯文本与高亮状态布局尺寸不发生明显跳动；
- light/dark theme 都使用 MetaWork canvas，而不是第三方主题背景；
- 所有语义色达到至少 4.5:1 对比度；
- 颜色消失时源码仍完整可读和可复制；
- 320px 右栏宽度和窄窗全宽 Task Panel 均不溢出应用边界。

## 13. 验证命令

最小充分自动验证：

```bash
npm --workspace @metawork/renderer run check
node --test scripts/task-panel.test.mjs
npm run format:check
git diff --check
```

人工验证使用：

```bash
npm run dev
```

人工样本至少包括 Zig、TSX、JSON、Shell、Markdown、HTML、未知扩展名和超出高亮预算的文本文件。人工验收需要覆盖明暗主题、刷新、快速切换、横向滚动、窄窗和复制结果。

本次不要求 Native build、Zig test graph 或 AgentCore vertical，因为没有修改 Host、Bridge、Product、AgentCore 或跨语言合同。如果实现实际越过这些边界，必须按 `docs/validation.md` 重新选择验证层级。

## 14. 验收标准

以下条件全部满足才算完成：

- 受支持、预算内的代码文件自动出现语法颜色；
- 未知、大型或高亮失败的文件与当前纯文本体验等价；
- 用户无需理解或控制语言识别；
- HTML 和其他源码保持惰性、不可执行；
- 高亮不改变正文内容、空白、复制结果和现有文件预览状态；
- 没有新增 Host/Bridge contract、CSP 能力或运行时网络请求；
- 没有代码正文 cache、日志或持久化副本；
- 快速切换、刷新、关闭和 Markdown 模式生命周期通过测试；
- 明暗主题、键盘、横向滚动和窄窗通过真实 WebView 验收；
- 规范、实现、测试和依赖锁在同一个变更中收口。

## 15. 被否决的方案

### 15.1 Monaco 或 CodeMirror

拒绝。File Preview 是只读、单文件、按需查看能力，不需要 editor model、光标、编辑、诊断、补全、折叠或 worker lifecycle。

### 15.2 Shiki 默认引擎

拒绝。默认 Oniguruma engine 引入 WASM，并可能要求额外 CSP 和打包验证；为了展示增强扩大安全或平台边界不合理。

### 15.3 Shiki JavaScript engine

首版拒绝。MetaWork 以 Safari 16 为 build target，而该引擎在旧 RegExp runtime 上存在降级路径。当前没有证据证明所选全部 grammar 在支持矩阵内行为一致。

### 15.4 Highlight.js HTML 输出

拒绝。直接消费序列化 HTML 会引入不必要的 raw HTML trust surface；再自行解析和白名单化，其复杂度不低于直接使用 AST highlighter。

### 15.5 Web Worker

首版拒绝。Worker 会复制源码并增加 CSP、打包、销毁、错误与迟到结果生命周期。保守输入和输出预算足以先解决主线程与 DOM 风险。

### 15.6 自制正则高亮

拒绝。多语言 lexer、嵌套字符串、注释和模板语法的维护成本远高于功能价值，也容易产生错误或灾难性正则路径。

### 15.7 Host 返回 MIME 或 language

拒绝。语言仅是 Renderer 展示推断，不是 Host 文件事实。提升为 wire 字段会无收益地扩大 Zig DTO、Bridge decoder 和跨语言 fixture。

## 16. Commit 方案

本次应作为一个原子 commit：

```text
feat(file-preview): add bounded syntax highlighting
```

原因：规范调整、依赖、实现、样式和测试共同定义同一个用户可观察能力，拆开后任一中间 commit 都会形成规范、行为或验证不一致。

如果实施过程中发现必须修改 Bridge、Host、CSP、共享 Markdown 或编辑器能力，应停止当前 commit，而不是继续扩大它。

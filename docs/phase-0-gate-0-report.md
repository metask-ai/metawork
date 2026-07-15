# Phase 0 Gate 0：Native SDK macOS React 验证报告

> 日期：2026-07-15
> 结果：通过，Gate 1 可以开始
> 平台：macOS arm64

## 1. 锁定规格

| 项目 | 值 |
| --- | --- |
| Native SDK CLI | `@native-sdk/cli@0.5.1`，由根 `package.json` 与 `package-lock.json` 精确锁定 |
| Node.js | `v26.0.0`，项目最低要求 `>=22.15.0` |
| npm | `11.12.1` |
| Zig | `0.16.0` |
| WebView | macOS system WKWebView |
| Renderer | React `19.2.6` + Tailwind CSS `4.3.2` + Vite `8.1.4` |

MetaWork 不提交 Native SDK 生成的 `.native/` build graph，也不使用 npx cache 的绝对路径或全局 `native`。项目本地 CLI 每次从 `app.zon` 生成 build graph；这避免官方 `native init --full` 当前写入机器绝对路径的问题。

Vite 从官方 scaffold 的 `8.0.11` 升级为 `8.1.4`。`npm audit` 对最终 lock 报告 `0 vulnerabilities`。

## 2. 可复现命令

```bash
npm ci
npm run format:check
npm run check
npm test
npm run build:debug
npm run build:release
npm run package:macos
```

开发模式：

```bash
npm run dev
```

带 Native SDK automation 的 production-assets smoke：

```bash
npm run build:frontend
node_modules/.bin/native build . --yes -Doptimize=Debug -Dautomation=true
METAWORK_GATE0_AUTOMATION=1 ./zig-out/bin/metawork
node_modules/.bin/native automate wait
node_modules/.bin/native automate snapshot
node_modules/.bin/native automate reload
```

`METAWORK_GATE0_AUTOMATION=1` 只为 automation IPC 的 `zero://inline` source 开放 Gate 0 白名单。正常 release 仍只允许 `zero://app`；普通 release build 不包含 automation server。

## 3. 双向传输结论

JavaScript → Zig 使用 Native SDK `BridgeDispatcher`：

```text
window.zero.invoke("metawork.smoke.ping")
→ origin/policy/handler validation
→ Zig handler
→ typed JSON response
```

Zig → React 不需要自制 `events.drain`。当前 Native SDK 提供真实 `Runtime.emitWindowEvent`：

```text
Zig Runtime.emitWindowEvent("metawork:host-signal")
→ WKWebView window.zero._emit
→ React window.zero.on callback
→ metawork.smoke.eventAck
→ Zig acknowledgement log
```

`eventAck` 是 Gate 0 transport probe，不是 AgentCore 或 Workbench 协议。它严格解析收到的 sequence，避免只凭 Zig 发送日志误判 React 已消费 event。

production-assets 实测：

```text
source kind=assets url=zero://app
metawork.smoke.event_ack sequence=1 origin=zero://app main_thread=true
reload
metawork.smoke.event_ack sequence=2 origin=zero://app main_thread=true
```

development server 实测：

```text
source kind=url url=http://127.0.0.1:5173/
metawork.smoke.event_ack sequence=1 origin=http://127.0.0.1:5173 main_thread=true
reload
metawork.smoke.event_ack sequence=2 origin=http://127.0.0.1:5173 main_thread=true
```

React StrictMode 下每次 Renderer 装载仍只发起一次自动 ping，避免开发期 effect 重放造成并发探测和伪造双倍传输证据。

实测说明 Bridge handler 与 native event emission 当前都发生在 macOS platform/main thread。后续 AgentCore Run、等待、event copy 和 batch 不能放到该线程。

## 4. 大小与安全边界

当前 `0.5.1` 编译器代码的实际常量：

| 数据 | 当前边界 |
| --- | --- |
| Bridge request | `1 MiB` |
| Bridge handler result | `1 MiB` |
| Bridge response | `1 MiB` |
| request ID | `64 bytes` |
| command name | `128 bytes` |
| public window event detail constant | `8 KiB` |

Native SDK 随包 skill 文档仍写 Bridge request/response `16 KiB`、result `12 KiB`，与 `0.5.1` 编译器代码冲突；本报告和测试以锁定 package 的编译器常量为准，并记录该依赖文档缺陷。

macOS `emitWindowEvent` backend 当前没有像 Null backend 那样强制 `8 KiB`，因此不能把它描述为平台硬上限。MetaWork 把 `8 KiB` 作为当前 Host event budget，smoke 自身使用固定 `512-byte` buffer；Gate 5 再按真实 AgentCore trace 固定 batch 与 event pump 容量。

安全策略：

- release navigation 与 Bridge origin：仅 `zero://app`；
- development：`zero://app` 与精确的 `http://127.0.0.1:5173`；
- production CSP 不包含 localhost、WebSocket 或 `unsafe-inline`；
- development CSP 只增加 Vite 所需的 localhost、WebSocket 和 inline style；
- external links 默认拒绝；
- 只开放 smoke、window 和 open-file dialog 命令；
- 不开放 credentials builtin，Provider credential 不进入 Renderer 或 Bridge。

## 5. 窗口、对话框与生命周期

真实 automation 创建并关闭 secondary AppKit window：

```text
window-create → id=2 label=gate0-child open=true 480x320
window-close  → id=2 label=gate0-child open=false
```

`automate reload` 后 React 重新连接，而 Zig sequence 从 `1` 递增到 `2`，证明这是仍存活 Host 的 Renderer reload，不是进程恢复。

文件与目录控件都调用 default-deny 的 `native-sdk.dialog.openFile`，分别固定 `allowDirectories=false/true`。真实 macOS file command 已进入 AppKit modal panel；当前自动化进程没有 Accessibility 权限，无法注入 Escape 完成无人工取消，因此没有把“自动点击 Cancel”伪装为通过证据。Native SDK policy、真实 modal 入口、前端错误/取消分支和 production build 均已验证；交互式文件/目录选择保留为每次 release candidate 的人工 smoke 项。

main window close、secondary window close、reload 与 Ctrl-C shutdown 都返回正常 stop path；其中 automation 关闭 main window 返回 `open=false`，随后运行时记录 `runtime.event stop` 并退出。运行期 automation snapshot 为 `dispatch_errors=0`、`dropped_trace_records=0`。

## 6. 构建与产物

- `npm run check`：TypeScript 与 `native check --strict` 通过；
- `npm test`：3/3 Zig tests 通过；
- Debug macOS binary：通过；
- ReleaseFast macOS binary：通过；
- React production assets：通过；
- macOS package：`zig-out/package/metawork.app` 创建成功；打包命令先删除旧 `.app`，再校验产物中的 Renderer 文件集合及 SHA-256 与本次 `frontend/dist` 完全一致，避免旧哈希资源残留；
- responsive Renderer：1280px 与 390px 浏览器检查通过，无水平 overflow；
- `npm audit`：0 vulnerabilities。

## 7. Gate 0 结论

Gate 0 已确定可用的 Native SDK 规格和真实传输路径：

- 使用本地精确锁定的 Native SDK CLI 和零配置 build graph；
- React + Tailwind 是唯一 Renderer；
- JavaScript request/response 与 Zig native event 都使用 Native SDK 原生能力；
- Host 后续必须把长任务移出 main thread，并在回到 Native SDK 时遵守 main-thread dispatch；
- release/dev origin 与 CSP 分离；
- 不需要为 AgentCore 预先发明轮询协议或复制事件类型。

下一步进入 Gate 1 artifact-only raw contract probe；正式 Host 仍须等待 Gate 3 typed SDK。

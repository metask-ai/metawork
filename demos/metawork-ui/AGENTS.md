# MetaWork UI Demo

本文件仅适用于 `demos/metawork-ui/`。这里是用户明确要求保留的独立前端原型，未接入主程序；仓库根级规则仍适用，正式产品规范与依赖不得因 demo 的视觉实验而修改。

- 默认只改 demo 的 UI/UX，不改现有产品文案或合成业务协议；不连接真实模型、MCP、账号、系统凭据、计时器或已安装应用的存储。
- 沿用 MiSans、400/500/600 字重层级、灰紫选中 #F0EEF3 与悬停 #F4F3F6，以及少量品牌紫 #8A4ED1。代码保留等宽字体；保留 MiSans 许可、来源与 About 署名。
- 视觉覆盖优先位于 `src/demo/visual.css`。不要新增选中描边、紫色竖线、深色输入焦点框或整高调宽线；保留键盘焦点的底色反馈与透明调宽热区。
- 回复与交付成果优先，执行详情默认折叠；报错、待审批和操作始终可见。文件名打开右侧预览，继续修改为轻按钮。
- 首页不恢复顶部重复的新建任务或标题下的说明图标。侧栏入口、Ctrl/⌘N、搜索和响应式侧栏继续可用。
- `.app-columns` 保持 `overflow: clip`；仅会话、侧栏和预览的指定视口滚动。
- 运行 `npm run check`、`npm run test:uiux`、`npm run test:sites` 与 `npm run build`；在浏览器核对受影响流程，不能用纯源码检查代替交互验证。
- 保留 `.openai/hosting.json`、`worker/index.js`、`scripts/prepare-sites-build.mjs` 和 Sites 测试。禁止提交 `node_modules`、`dist`、本地凭据或私人测试截图。

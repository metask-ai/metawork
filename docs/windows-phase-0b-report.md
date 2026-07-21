# Windows Phase 0B 接入 baseline 验证报告

> 日期：2026-07-21
> 状态：接入 baseline 已通过；分发、签名、更新和完整安全矩阵未完成

## 1. 精确输入

AgentCore bundle identity：

- version：`0.1.0-dev+1ec7e4902727`
- source commit：`1ec7e4902727ff894c50452d6417fb6fc3d8bb2c`
- source dirty：`false`
- ABI：version 1 revision 3
- target：`x86_64-windows.win10...win11_dt-gnu`
- Rust target：`x86_64-pc-windows-gnu`
- Zig：`0.16.0`
- optimize：`ReleaseSafe`
- system libraries：`advapi32`、`crypt32`
- library：`lib/metask_agentcore.lib`

Repository lock 是 `spikes/agentcore-contract/bundle.windows.lock.json`，保存与 bundle `manifest.json` 完全相同的 bytes，并锁定全部 payload checksum。正式 Host 只消费 `.agentcore/bundle`，不读取或修改 metacodes source tree。

## 2. 验证命令

```powershell
npm run agentcore:stage -- C:\absolute\path\to\x86_64-windows.win10...win11_dt-gnu
npm run test:windows:bringup
```

`test:windows:bringup` 顺序执行：

```text
npm test
npm run test:agentcore-sdk
npm run test:lifecycle
npm run build:debug
npm run test:gate5:windows
npm run probe:agentcore:staged
npm run test:gate6:windows
npm run build:release
```

## 3. 通过证据

- repository test graph：42/42 build steps，105/105 Zig tests；
- Renderer runtime：60/60；architecture/automation isolation：23/23；
- bundle policy：22 passed，1 skipped；唯一 skip 是当前 Windows 未启用 Developer Mode/提权时无法创建测试 symlink，其他 symlink/path/checksum/identity fail-closed 覆盖均执行；
- source-free official Zig package discover/link/run 与 raw C probe 通过；
- Native Debug 与 Release 均生成 `zig-out/bin/metawork.exe`；
- `frontend/dist` 安装到 `zig-out/bin/frontend/dist`，应用从 executable-relative 路径解析生产资源；
- Gate 5 通过 worker wake、main-thread emit/fetch/ack、Renderer reload generation 和 clean stop；
- Gate 6 使用真实 revision 3 bundle 通过 Read/Bash/Edit、permission、AskUserQuestion、重复响应拒绝、reload-safe resume、Task metadata lifecycle 和 async close；
- Release artifact automation token isolation 扫描通过。

## 4. 边界

本报告证明 Windows 开发可执行 baseline 可构建、可启动并完成真实 AgentCore 垂直链路，不证明：

- MSI 或其他安装器；
- code signing、notarization 等发布签名；
- 自动更新与回滚；
- Native dev mode、完整 file dialog、timeout/process-tree termination 与 strict Workspace security 矩阵；
- stable AgentCore support policy；
- Linux 接入。

Linux 后续必须新增精确 target lock、系统链接 policy、source-free probe、Native 平台构建与 Gate 5/6 证据；当前 target-policy 结构只提供扩展点，不提供兼容声明。

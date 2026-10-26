# 历史与执行资源分离实施计划

日期：2026-10-26。分支：`feat/history-runtime-bounds`。TinyKG root：9975。

本计划记录用户已授权的本轮实施范围，不是 decision record。后续考虑 SQLite；本轮保留现有 framed store 的文件名、编码、保存与恢复路径，不实现自定义 V2、追加日志、根索引或 SQLite 接入。

## 1. 目标与边界

本轮实现能在未来存储切换后继续使用的领域改动：历史与执行资源分离、历史 Task 与 live Session 解耦、有界产品视图和 Host 搜索。

- 历史按实际内容分配，避免恢复时为每条 Run 分配完整执行结构和最大附属容量。执行资源只在活跃工作需要时拥有，引用全部静止后释放。
- Session 独立受执行资源约束；压力下只通过现有生命周期安全释放 idle attachment，保留历史和恢复能力。失败不伪装成历史槽位耗尽。
- 正文、导航、manifest、Compact、审批与搜索结果按条数和编码字节有界；剩余记录可续读，查询和缓存正确处理历史版本与安全失效。
- 保持产品 owner、已确认事务、credential 清洗、checkpoint 恢复资格及现有 worker/event 归还协议。公共视图合同变化随 Native、Bridge、Renderer 和 fixture 一起收口。
- 不借内部重构直接放开当前持久化数量和字节接受上限，不删除历史或新增运行时 reason 的持久化；不声称本轮完整修复 #12/#25。

资源、恢复与安全合同沿现有 [Product 架构](../product-architecture.md)；视图合同沿 [Renderer Bridge 合同](../renderer-bridge-contract.md)；验证按 [验证规范](../validation.md)。只有实际合同变化才修改对应真源。

## 2. DAG 与提交边界

| 子任务            | TinyKG id | 依赖   | 完成与提交条件                                                                                    |
| ----------------- | --------- | ------ | ------------------------------------------------------------------------------------------------- |
| T0 范围与任务控制 | 9976      | 无     | 新分支、goal、DAG 和本计划建立，文档检查通过；独立提交                                            |
| T1 历史与执行结构 | 9977      | T0     | 按需拥有执行 control/title/context；恢复集合按实际数量分配；OOM、格式往返与内存回归通过           |
| T2 静止回收       | 9978      | T1     | worker、事件、标题、checkpoint 和 artifact 引用静止后释放执行部分；取消、失败、删除与退出回归通过 |
| T3 Session 解耦   | 9979      | T2     | 小 Session 预算下多历史 Task 的安全压力回收与真实 Core 恢复；忙碌及关闭失败精确反馈               |
| T4 Host 有界视图  | 9980      | T1     | typed 请求、有界投影、有限 manifest、Host 分页搜索与 Bridge fixture 验证                          |
| T5 Renderer 接入  | 9981      | T4     | 分页、搜索 cursor、刷新与安全失效；typecheck 和受影响 suite 通过                                  |
| T6 联合验收       | 9982      | T3、T5 | 正式 Native graph、Bridge/Renderer、canonical Core lifecycle、相关桌面路径和合同/guard 收口       |

每个子任务完成后立即评估独立提交，记录 SHA 或暂缓理由。跨语言合同只有在生产链路和 fixture 一致时才提交，不能为了提交频率留下不可工作的中间状态。不自动 push 或 merge。

工作开始时已有 `build.zig` 测量入口、容量/写入测量脚本、探针和证据未提交；它们不属于产品实现提交，保留其原内容与职责，不用 `git add .` 混入。

## 3. 验收重点

1. 读取现有 framed 历史并重新编码保持完整事实；恢复终态不分配 worker 执行结构，内存随实际记录/附属内容增长。OOM 不泄漏或发布半个候选。
2. RunRecord 的 worker 指针与所有权保持稳定；终态不等于可回收，任何在途标题、checkpoint、事件与 artifact 都能阻止提前释放。
3. 历史 Task 保留，有限 Session 安全 detach/reattach；没有可回收对象时明确拒绝，不删除数据，不自动反复重试关闭失败。
4. 视图与搜索覆盖最后一页、无命中、超多命中、归档 Task、跨页更新/取消/安全失效；不把未返回解释为删除，不向 Renderer 下发全量搜索语料。
5. 当前数量/字节边界、旧数据恢复、完整保存失败与 unknown 行为保持，不能以取消 verifier 或扩大限制掩盖本轮不处理的存储问题。
6. 跑风险对应的最小充分测试，再执行共享 owner 与正式 Native graph；缺 canonical bundle 明确失败，不跳过真实 Core 后报告成功。性能沿现有主线程与展示 Gate 验证。

本轮结束时报告实际提交、完成项、验证结果及剩余存储约束。未来 SQLite 接入另行制定最小方案，不将前期自定义文件存储提案带入本轮代码。

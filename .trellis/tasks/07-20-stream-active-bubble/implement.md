# 执行计划：流式活跃气泡瞬态通道（v2，按 codex 审查修订）

> 顺序＝codex 审查 §七 的八步；每步独立 checkpoint。开关默认 false，全链路对照后单独翻 true。
> commit 授权：用户已于 2026-07-20 会话中明确「commit 不需要授权，本地 git 状态自行管理」，按组原子提交即可。

## 0. 规划修订 ✅

- [x] B1-B6 写回 design.md v2；测试矩阵吸收审查 §六。

## 1. Characterization 基线（旧路径） ✅ 部分 / 待补

- [x] 主干 A-E 七用例已落地全绿（grok 施工，主会话复跑验证）。
- [ ] 按审查 §六补：真实 interrupt（`interruptCurrentGeneration`，占位期/活跃期/揭示 backlog 期）、重试新建 delivery、failover reset、A→B→A 切会话、揭示等待期被 reset（segmentDelay>0）、揭示精确节奏（delay-ε 不揭示）。
- [ ] Timer seam：沿用现测试 harness，将宽区间断言中「结构转移」部分改为精确断言（保留量级断言作烟雾）。

## 2. 通道类型与生命周期（开关默认 false）

- [ ] `active_stream_projection.dart`：state ＋ 单 owner map notifier ＋ CAS publish/clear（B1/B3）＋ `streamProjectionPolicyProvider`（B5）。
- [ ] 单元测试：CAS 拒旧 token/旧 epoch、旧 token clear 不清新流、finalize 后条目移除、A/B 会话隔离、container dispose 回收。

## 3. `_applyState` 增量 diff（默认仍 off）

- [ ] diff 定义按 design §2.3；off 路径保留旧全量实现。
- [ ] on 路径测试：spy `replaceMessagesTransient` 载荷（removed/upsert 精确 id 集）；off 路径旧 characterization 全绿。

## 4. 气泡消费与视口窄信号

- [ ] `MessageBubble` 下传 `conversationId`＋通道 select 渲染（design §2.6）。
- [ ] `ChatMessageList` 挂 `ref.listen` 窄信号 → 只调度视口稳底，不重建（design §2.7）。
- [ ] 守卫：非分段 100 delta 窗口通知不增长；活跃气泡文本实时；历史气泡 build 计数不增长（MessageBubble 加 `@visibleForTesting` build 钩子，S4）；ChatPage/Composer 不重建；标签隐藏一致（B6）。

## 5. followLatest / detached 回归

- [ ] 通道驱动局部增高：贴底不脱离；detached 锚点不移位；键盘/bottomOverlayHeight 同帧不遮输入框（审查 §六.1）。

## 6. 全链路 on/off 对照

- [ ] 100 delta、分段揭示、TTS id 交接、reset/interrupt/retry/failover、A→B→A、finalize/DB 一致性——两个 container 对照跑（B5）。
- [ ] 通过后：单独小改动翻默认 true（独立可 revert）。

## 7. 全量回归与运行验收

- [ ] `flutter analyze` 无新增 error；全量 `flutter test` 全绿。
- [ ] `flutter run --no-resident` 编译；窄/宽屏 smoke（S5）。真机流式贴底若设备不可用，在任务记录 waiver 与残余风险，不默认转嫁 07-13。

## 8. 审查与收尾

- [ ] codex 代码审查，问题修完。
- [ ] spec 沉淀：流式双通道契约（结构转移表、CAS、交接顺序）入 `.trellis/spec/frontend/`。
- [ ] 分组提交：①补充 characterization ②通道+diff（机制，单一可 revert commit）③气泡+视口 ④翻默认+文档。

## 回滚点

- 机制回滚＝policy 默认值回 false（改码重建，非即时 flag，已如实声明）；整体回滚＝revert 机制 commit。characterization「旧路径行为」断言组保持对 off 路径成立。

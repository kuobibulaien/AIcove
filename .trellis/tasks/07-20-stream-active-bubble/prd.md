# PRD：流式旁路——chunk 更新只重建活跃气泡（路线图 G2.1）

## 背景

流式输出期间聊天页卡顿。已证实链路（`卡顿根源_grok_20260719.md` #1/#9 + 本任务预研）：

`onDelta` → ~180ms 节流 flush → 全文重新分段 + 全量重物化在飞时间线 → 视觉变化时 `replaceMessagesTransient(移除全部旧 id + 写入全部新消息)` → 时间线缓存通知 → 窗口 provider → **整页 + 整列表重建**。

预研修正的关键事实（必须以 characterization tests 锁定）：

1. **分段模式（enableChunking=true，默认）**：未完句尾巴不进 descriptors（不上屏），只有 seal/揭示/占位变化才通知——通知频率本就≈结构事件；但每次通知仍是全量替换＋整页重建，且每次 flush 都付全文重分段的 CPU。
2. **非分段模式（enableChunking=false）**：活跃尾文本每次 flush 都变 → 每 ~180ms 一次窗口通知＋整页重建——重建风暴主场。
3. 每次通知的 `replaceMessagesTransient` 都移除全部旧 id 再写入全部新消息（id 靠物化复用保持稳定）。

## 目标（MVP）

1. **活跃尾通道**：非分段模式的活跃尾文本与「生成中…」占位改走 generation-scoped 瞬态通道（Riverpod family provider），每个 delta/flush 只重建订阅该通道的单个气泡子树；窗口在流式期间只收结构事件（seal、pendingAudio、finalize、interrupt/remove）。
2. **结构事件最小写**：seal 时只向时间线增量写入新 seal 的消息（及必要的占位钉底更新），不再全量替换整段在飞时间线。
3. **不变式保持**：DB raw message 唯一真相源不变；瞬态通道不参与模型上下文；finalize 仍走既有 commit 路径写库；`_pendingRawSourceId` 共享 raw 槽位语义（05-05 任务）不回退。

## 非目标

- 不改分段揭示节奏（segment delay）、入场动画、followLatest 视口语义。
- 不做分段增量化（每 flush 全文重分段的 CPU 优化另立任务）。
- 不动 `_StreamPlaceholderDelivery` 的对外生命周期 API（start/onDelta/onStreamReset/finalize/commitToMessages/remove）——本任务只改其内部投影通道，整体迁 OutputPipeline 是 G3.1 第三步。

## 验收标准

- [ ] Characterization tests 先行落地并全绿：锁定 start/delta/seal/揭示/finalize/流内 reset（onStreamReset）/真实中断（interruptCurrentGeneration）/重试换 delivery/failover/占位钉底/pendingAudio/分段与非分段两模式下的「窗口通知次数」与消息序列现状。
- [ ] 非分段模式：100 个 delta（无边界）期间，窗口通知次数为 O(结构转移数)（完整转移表见 design.md §2.2），不随 delta 数增长；活跃尾文本仍逐 flush 上屏（经瞬态通道）。
- [ ] 分段模式：seal/揭示的通知行为与现状一致（characterization 基线不变）；每次通知不再移除+重写未变化的消息。
- [ ] interrupt/重试/切会话/重进页面：无幽灵尾气泡；generation epoch 防旧流覆盖新流。
- [ ] finalize 后 UI 与 DB 投影一致（既有 commit 测试全绿）。
- [ ] `flutter analyze` 无新增 error；全量测试全绿。

## 自主决策（供扫读否决）

- 瞬态通道用 `NotifierProvider.family<ActiveStreamNotifier, ActiveStreamState?, String>`（按 conversationId），state 含 generation epoch、活跃尾投影文本、占位阶段；不落任何持久层。
- 活跃尾在窗口中保留一个 id 稳定的壳消息（保证列表结构/分段/滚动语义不变），气泡渲染时发现自己是活跃壳则订阅通道取实时文本；通道为空时回退壳内容。
- 验收「通知次数」以测试内计数 `ConversationTimelineCache` 变更通知实现，不依赖真机。

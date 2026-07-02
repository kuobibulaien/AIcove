# fix: chat streaming placeholder short window

## Goal

修复 AI 流式回复期间聊天短窗把一轮回复临时拆成多个 raw 槽位的问题，避免老消息在生成中被挤出短窗，并减少流式 flush 对 projection mapping / DB 同步路径的无意义压力。

## Requirements

- 流式占位消息在同一轮回复内共享一个临时 `sourceMessageId`，让短窗 raw 槽位计数与最终提交后的真实 raw message 行为一致。
- 流式进行中的 placeholder flush 使用 transient timeline 写入路径，避免 pending raw id 被同步到持久 projection mappings。
- 最终提交仍使用真实 `rawMessage.id` 覆盖前端投影消息的 `sourceMessageId`，保持既有持久化语义。
- placeholder reset、remove、commit 路径保持可清理旧占位，不残留临时消息。

## Acceptance Criteria

- [ ] 一轮流式回复产生多个占位/分段时，短窗仍只按 1 个 raw 槽位计入该轮 assistant 回复。
- [ ] 流式过程中不会因为占位消息缺少 `sourceMessageId` 而挤掉额外历史消息。
- [ ] 流式 placeholder flush 不触发 projection mapping 同步；commit 后真实投影映射仍正常。
- [ ] 现有非流式、commit、remove placeholder、stream reset 路径不回退。
- [ ] 完成后运行 `flutter run --no-resident` 验证。

## Definition of Done

- 代码改动集中在聊天流式占位链路和必要测试。
- 增加或更新能复现短窗 raw 槽位行为的测试。
- Flutter 验证命令通过，若环境失败则记录失败原因与下一步。

## Technical Approach

1. 在 `_StreamPlaceholderDelivery` 生命周期内生成一个 `_pendingRawSourceId = genId('raw_msg')`。
2. `_createMessage` 和 `_rebuildMessage` 产出的占位 `Message` 均带上该 pending source id。
3. `_applyState` 的流式 flush 改用 `replaceMessagesTransient`，跳过 projection mapping 同步。
4. commit/remove/reset 仍保留现有 removeMessageIds 机制；commit 最终消息继续由 `buildFinalTimelineMessages(sourceMessageId: rawMessage.id)` 绑定真实 raw id。

## Decision (ADR-lite)

**Context**: 当前短窗按 `sourceMessageId` 去重计 raw 槽位；流式占位缺少 `sourceMessageId` 时，每条占位都会临时占一个槽位，并且 `replaceMessages` 会同步 projection mappings。

**Decision**: 将“占位统一 pending raw id”和“流式 flush transient 写入”绑定为同一个最小补丁。

**Consequences**: 可直接修复生成中老消息被挤出的问题，并降低流式写入压力；pending raw id 只停留在内存短窗，不进入持久映射。更大的 center/sliver 结构调整不在本次任务内。

## Out of Scope

- 不拆 `CustomScrollView` 的双 sliver + center 结构。
- 不做末条 active 占位增量 upsert。
- 不改 `MessageBubble` const 路径、delegate Map 缓存、cacheExtent 等性能二期优化。
- 不改聊天请求上下文组装或 raw DB 真相源。

## Technical Notes

- 相关代码：`apps/aicove_flutter/lib/src/features/chat/chat_actions_stream_placeholder.dart`
- 短窗 raw 槽位逻辑：`conversation_short_window_store.dart` 的 `_selectNewestProjectedMessagesByRawWindow` / `_messageRawSourceId`
- 聊天页当前 `transientMessages` 恒为空，流式消息通过 timeline cache 进入 stable messages。
- 前端规范要求 raw DB 是聊天上下文唯一真相源；本次只调整 UI projection / short-window read model，不改变模型上下文。

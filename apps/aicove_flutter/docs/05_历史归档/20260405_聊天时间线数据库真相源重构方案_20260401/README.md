# 聊天时间线数据库真相源重构方案

更新时间：2026-04-02

## 目标

- 数据库成为聊天时间线的唯一真相源。
- 前端投影消息只在前端生效，不再持久化为第二套真相源。
- 聊天页时间线回到“数据库分页 + 内存热缓存 + UI 窗口状态”模型。
- 已移除 `ConversationTimelineCache` 的 JSON 持久短列表机制，运行时只保留内存热缓存。

## 设计边界

### 数据层

- `messages`、`message_blocks` 继续作为 raw message 存储。
- `raw_payload` 仅保留重建 assistant 原始语义所需数据。
- `raw_payload.projectedMessages` 不再作为聊天页时间线真相源。

### 前端派生层

- `ChatFrontendMessageProjectionService` 负责将 raw message 投影为前端消息。
- 用户图文拆分、assistant 分段、多模态后补、展示态拼装，都只属于前端派生层。
- `Message.sourceMessageId` 保留，用于前端消息回溯 raw source。

### UI 时间线层

- 聊天页只展示最近 N 条前端投影消息。
- 历史消息只在用户上滑时按 raw message 分页加载。
- 进入页不再做 JSON 短列表恢复、补齐或 hydration。

## 当前问题

- 主时间线读取路径直接依赖 `ConversationTimelineCache.watchWindow(...)`。
- 旧文件路径 `conversation_short_window_store.dart` 仍保留，历史语义只剩文件名残留。
- `ChatFrontendMessageProjectionService` 仍保留对旧 `raw_payload.projectedMessages` 的兼容读取，用于老数据冷启动恢复。
- `message_projection_mappings` 仍承担历史投影 id 回溯，后续还需继续评估是否能进一步瘦身。

## 分阶段计划

### 阶段 0：调研和接口冻结

- 梳理当前聊天时间线读写链路。
- 明确 raw 层、前端投影层、UI 窗口层的职责边界。
- 冻结阶段 1 的改造范围：只切读路径，不动数据库 schema 和主写路径。

### 阶段 1：重建读路径

- 新建数据库时间线读取服务：
  - 从数据库读取最近 raw message；
  - 通过前端投影服务转换为前端消息列表；
  - 在内存中维护最近会话的热缓存。
- `conversationMessagesProvider / conversationHasMoreProvider` 切换到新读路径。
- 聊天页进入时固定显示最近 20 条前端投影消息。
- 上滑分页时直接按 raw message 继续向前加载，再投影追加。

#### 阶段 1 落地结果（2026-04-01 ~ 2026-04-02）

- `ConversationTimelineCache` 已从“JSON 持久短列表”收口为“数据库种子 + 内存热缓存”的前端时间线缓存：
  - 首次读取直接从数据库尾部窗口构建；
  - 上滑分页按 raw message cursor 扩展内存热缓存；
  - 不再把窗口快照持久化到 `conversation_short_windows/window.json`；
  - 不再维护媒体本地化目录、磁盘预算回收、后台 warmup。
- 聊天页已移除进入阶段的本地时间线 hydration，重进会话只显示尾部 20 条。
- 同一会话在单次 App 生命周期内仍可复用已展开的热缓存；冷启动后不再恢复上次扩展段总数。
- 运行时代码命名已切到明确分层语义：
  - 前端缓存：`ConversationTimelineCache / conversationTimelineCacheProvider`
  - raw 历史端口：`ChatHistoryPort.loadRawMessages(...)`
  - raw -> 投影读取：`ChatHistoryStore.loadProjectedMessagesFromRawStore(...)`
  - 前端缓存读取：`ChatHistoryStore.loadCachedTimelineMessages(...)`
- `App` 启动阶段已删除 `warmupConversations(...)`，消息分段策略更新也不再触发 `rebuildAllFromDb()`，因为分段策略属于纯前端投影配置。

### 阶段 2：重建页面状态与分页控制

- 移除进入页 hydration、短列表补齐、本地扩展段优先等逻辑。
- 保留纯 UI 层的窗口状态和滚动锚点恢复。

### 阶段 3：重建写路径

- `append/update/delete/edit/regenerate/deferred image/TTS pending` 改为：
  - 更新 raw 存储；
  - 更新内存前端态；
  - 不再写 JSON 短列表。
- 停止把 frontend projection 回写到 `raw_payload.projectedMessages`。

#### 阶段 3 首批落地（2026-04-02）

- `appendAssistantRawMessage / appendMessage / updateMessage / insertMessagesAroundAnchor / softDeleteMessages` 已切到“前端时间线补充语义回写”模式：
  - 图片后补改为回写 `raw_payload.pluginContents`；
  - TTS / 音频后补改为回写 `raw_payload.toolAudioResults`；
  - 流式/后补场景里，图片和语音的最终插入位点改为回写 `raw_payload.supplementInsertOps`，用于保留“插在第几个文本段后 / 是否强制追加到尾部”的语义；
  - 不再把完整 frontend projection 回写到 `raw_payload.projectedMessages`。
- `message_projection_mappings` 不再只当短窗当前窗口的镜像：
  - 历史 assistant 投影 id 会单独保留 raw -> projected 映射；
  - regenerate / edit / truncate 这类动作可以继续从分页外的旧投影气泡回溯到 raw source。
- `ChatFrontendMessageProjectionService` 仍保留对旧 `raw_payload.projectedMessages` 的兼容读取，用于老数据冷启动恢复。
- 当前数据库中的 assistant raw message 只保留“重建前端消息所需的语义材料”，前端气泡列表本身不再落为第二套持久真相源。
- 数据库重建时，若命中 `supplementInsertOps`，会先还原基础文本边界，再按持久化的插入位点补回图片/语音，避免慢图重新插回原 `<image>` 标签位置。

### 阶段 4：删除旧机制

- 删除 `warmupConversations / rebuildAllFromDb / window.json` 等 JSON 短列表机制。
- 继续评估并清理 `message_projection_mappings` 的主路径依赖。
- 继续评估何时移除对旧 `raw_payload.projectedMessages` 的兼容读取。

### 阶段 5：回归与验收

- 补齐时间线读取、分页、编辑、重生成、补图、TTS 的自动化测试。
- 真机验证进入会话、快速切联系人、上滑分页、多模态消息链路。

## 阶段 1 的施工范围

- 允许修改：
  - `features/chat/services/chat_history_store.dart`
  - `features/chat/conversation_timeline_providers.dart`
  - `ui/features/chat/pages/chat_page.dart`
  - `ui/features/chat/widgets/chat_message_list*.dart`
  - 新增数据库时间线读模型和内存热缓存服务
  - 配套测试和文档
- 明确不做：
  - 不改数据库 schema
  - 不删除旧表
  - 不删除 `ConversationTimelineCache`
  - 不修改导入导出
  - 不重做写路径

## 验收标准

- 进入会话时，聊天页不再依赖 JSON 短列表恢复。
- 首屏稳定显示最近 20 条前端投影消息。
- 上滑分页只触发数据库查询和前端投影，不再触发短列表 hydration。
- 编辑、删除、重生成、补图、TTS 后补等链路行为与现状保持一致。
- 相关 `flutter test` 通过，`flutter run --no-resident` 真机启动通过。

# 聊天稳定存储与导入导出重构方案

> 更新日期：2026-03-12
>
> 目标：把聊天记录改成单一真相源；把流式打字气泡彻底降级成前端挂件；让导入导出只处理真消息。

## 0. 当前进度补记

2026-03-12 已落地一小批：

- 聊天页真实消息已切到数据库 `watch()` + `StreamProvider.family`
- 上滑加载更多只增大 `visibleCount`，不再把分页结果回写会话对象
- 流式挂件已独立渲染到时间线底部，不再依赖伪消息占位

当前还没收口的点：

- `Conversation.messages` 仍保留兼容壳，后台分析、触发器、联系人预热等旧入口还在读它
- 导入导出还没切到稳定快照与完整去重

所以下一批应优先继续清理旧入口，再做导入导出收口。

2026-03-12 晚些时候又补了一批：

- 导入器已切到完整历史扫描；`merge` 改为按 `id + sourceMessageId` 去重
- `createNew` 导入会重写消息与 block 主键，并把旧主键写入 `sourceMessageId/sourceBlockId`
- 导出包已保留 `source_message_id/source_block_id`，供后续 merge 稳定去重
- 后台分析、提醒创建、联系人预热、启动预热、导出页预览都改读 `ChatHistoryStore`
- TTS 占位替换与删除已改成直接写消息仓库，不再回写 `Conversation.messages`

当前剩余的兼容位只在少数辅助函数里：

- `EnhancedDialogueService`
- `ChatSendService.prepareHistory`

这两处要么已经喂入数据库实历史，要么只被旧测试辅助调用，风险已明显下降，但还不算最终清零。

---

## 1. 这次到底要解决什么

现在的问题，不是某一段发送逻辑写得不够细，而是底层边界错了。

当前结构里，`Conversation.messages` 同时承担了三件事：

- 会话历史
- 页面展示
- 流式动画占位

这会直接带来三类问题：

- 流式占位有机会被写进数据库
- 分页和发送会互相覆盖
- 导入导出会拿到被 UI 污染过的消息集

这轮重构不再修补这个结构，而是直接拆掉它。

---

## 2. 新方案的核心原则

### 2.1 数据库是唯一真相源

聊天记录的唯一真相，只能是数据库里的 `messages` 和 `message_blocks`。

会话本身只保存元信息，不再保存 `messages` 列表。

### 2.2 流式气泡不是消息

生成中的 AI 气泡，不再伪装成 `Message`。

它只是聊天页底部的一个独立挂件，用来显示：

- 正在打字
- 当前已收到的 delta 文本
- 流式阶段状态

它不进数据库，也不进导出包，也不参与上下文。

### 2.3 列表更新依赖数据库响应式流

真实消息列表不再靠前端手工拼接后强推 UI。

数据库变了，列表自己刷新；数据库没变，列表就不动。

### 2.4 排序必须稳定

所有真实消息读取、分页、导出、上下文构建，都统一按：

```text
createdAt ASC, id ASC
```

这里的 `id` 只是并列时的稳定第二键，目的不是猜测顺序，而是避免同毫秒乱序。

---

## 3. 为什么这条路比旧方案更干净

旧方案的问题，不在于占位放内存还是放数据库，而在于它仍把占位当成一条消息。

一旦它还是消息，就还得面对这些脏问题：

- 怎么过滤它
- 怎么不让它导出
- 怎么不让它参与上下文
- 怎么不让它被分页写回库

这其实已经说明，这个实体本身就不该存在。

更简洁的做法是承认一件事：

流式占位不是消息，它只是一个前端动画部件。

---

## 4. 目标结构

### 4.1 会话模型只保留元信息

`Conversation` 或新的 `ChatSession` 只保留这些字段：

- `id`
- `title`
- `displayName`
- 头像、人设、背景、模型配置
- `lastMessage`
- `lastMessageTime`
- 未读数
- 其他会话级设置

它不再携带 `messages`。

### 4.2 真实消息只走消息仓库

所有消息相关操作，都直接走 `MessageRepository` 或新的 `ChatHistoryRepository`：

- 插入用户消息
- 插入助手消息
- 更新发送状态
- 读取最新 N 条消息
- 读取某会话全量稳定历史
- 导出快照
- 导入事务

以后不允许再从会话对象整包回写历史。

### 4.3 前端单独维护流式挂件状态

新增一个纯内存的流式状态仓库，比如：

- `streamingBubbleProvider(conversationId)`

它只保存：

- 是否显示挂件
- 当前流式文本
- 当前阶段，比如 `thinking / streaming / fallback / hidden`

它不是消息仓库，也不做持久化。

### 4.4 聊天页只做视图组合

聊天页最终展示的时间线，由两部分组成：

- 数据库返回的真实消息列表
- 底部一个可选的 `StreamingBubbleWidget`

这里的组合只是视图组合，不是把假消息拼进数据模型。

---

## 5. 读取方案

### 5.1 首屏和新消息刷新，直接用数据库 watch

这次建议正面拥抱 Drift 的响应式查询能力。

Drift 官方文档明确支持把查询转成自动更新的 `watch()` 流，数据库结果变化时，流会自动发新值。

所以聊天页的真实消息列表，应该改成：

- provider 持有当前会话 id
- provider 持有当前可见条数，比如默认 30
- repository 暴露 `watchRecentMessages(conversationId, limit)`
- UI 直接监听这个流

这样当用户消息落库、助手消息落库、消息状态更新时，列表会自动刷新，不再需要前端手工 append。

### 5.2 分页不再回写数据库

分页也不要再搞 拿到旧消息后回头改会话对象 这条路。

更简单的方案是：

- provider 只保存 `visibleCount`
- 初始值 30
- 上滑加载更多时，`visibleCount += 30`
- watch 查询自动返回更大的真实消息窗口

这条路的好处是：

- 没有反向写库
- 没有旧快照覆盖新消息
- 没有把分页结果和流式占位混在一起

这版优先的是正确和稳定，不先追求极限性能。

如果后面消息量特别大，再把 `visibleCount` 升级成游标分页，不影响总架构。

### 5.3 稳定排序和游标规则

所有消息仓库方法都统一成稳定版本：

- `watchRecentMessagesStable(conversationId, limit)`
- `getMessagesBeforeStable(conversationId, beforeCreatedAt, beforeId, limit)`
- `getAllByConversationStable(conversationId)`

排序统一：

- 查询结果最终对外永远是升序
- 分页条件永远同时比较 `createdAt` 和 `id`

这样导出、上下文、历史翻页会走同一套规则。

---

## 6. 发送链路要怎么改

### 6.1 用户发送

发送按钮按下后，流程改成：

- 真实用户消息直接写数据库
- 若需要发送中状态，就更新这条真实消息的 `status`
- 聊天列表通过数据库 watch 自动出现这条消息

### 6.2 助手流式返回

模型开始回流时：

- 打开 `StreamingBubbleWidget`
- delta 只更新流式挂件状态
- 不创建数据库占位消息
- 不创建占位 block

### 6.3 助手完成

流式完成后：

- 把完整助手消息一次性写数据库
- 清空流式挂件状态
- 列表通过数据库 watch 自动出现真实助手消息

### 6.4 流式失败或回退

失败时只做两件事：

- 关闭流式挂件
- 走失败文案或非流式补发

整个过程中，数据库里都不会留下半条占位垃圾。

---

## 7. 导入导出怎么跟着收口

### 7.1 导出只读取真实消息快照

导出器只能从稳定仓库拿数据：

- 会话元信息
- 全量真实消息
- 全量真实 blocks
- 附件文件

导出器不再依赖页面状态，也不再接触流式挂件状态。

### 7.2 createNew 不能再复用旧消息主键

当前导入器最大的问题，是新建副本时只换了 `conversationId`，没有重写消息和 block 的主键。

这条必须改掉。

`createNew` 模式导入时，必须同时重写：

- `conversation.id`
- `message.id`
- `message_block.id`

并建立整套旧新映射。

### 7.3 merge 不能只看前 50 条

当前合并去重只拿默认 50 条消息，这是不成立的。

`merge` 模式必须拿完整历史去重，至少要做到：

- 读取目标会话全部真实消息 id
- 再决定哪些消息跳过，哪些消息写入

### 7.4 为了长期稳定，建议给导入补一个来源标记

如果这次要一劳永逸，我建议顺手给消息和 block 增加一个可空来源字段，比如：

- `sourceMessageId`
- `sourceBlockId`

用途很简单：

- `createNew` 时生成新本地主键
- 同时把导出包里的原始 id 存进来源字段
- 后续再次导入或合并时，按 `本地 id + 来源 id` 双重判断

这样副本会话后续也能继续做稳定增量导入。

这不是增加新实体，只是给导入导出补一个长期身份锚点。

---

## 8. 需要替换的旧入口

这次重构建议直接替换这些职责，不再继续补丁：

- `lib/src/features/chat/domain/conversation.dart`
- `lib/src/features/chat/conversation_providers.dart`
- `lib/src/features/chat/chat_actions.dart`
- `lib/src/features/chat/services/chat_send_service.dart`
- `lib/src/ui/features/chat/pages/chat_page.dart`
- `lib/src/core/database/repositories/message_repository.dart`
- `lib/src/features/backup/data/conversation_exporter.dart`
- `lib/src/features/backup/data/conversation_importer.dart`

---

## 9. 建议的落地顺序

### 9.1 第一期，先拆掉假消息模型

先做最核心的骨架调整：

- `Conversation` 去掉 `messages`
- 会话不再整包回写历史
- 消息增删改都改成仓库直写
- 聊天页真实消息改成数据库 watch

### 9.2 第二期，把流式占位改成独立挂件

再把 UI 层彻底切干净：

- 删除 `_StreamPlaceholderDelivery` 这类伪消息交付逻辑
- 新增 `StreamingBubbleWidget`
- 新增流式状态 provider
- 发送完成后只写真实消息

### 9.3 第三期，重做导入导出

最后把稳定存储价值接上：

- 导出只走稳定快照
- `createNew` 全量重写 id
- `merge` 走完整去重
- 顺手补来源字段和事务导入

---

## 10. 验收标准

### 10.1 存储稳定

- App 崩溃或重启后，历史里绝不出现生成中气泡
- 连续发送和翻页时，真实消息不会丢
- 不再存在分页结果反向写回数据库

### 10.2 显示稳定

- 流式打字效果还在
- 流式失败时不会残留空消息
- 新真实消息落库后，列表会自动刷新

### 10.3 导入导出稳定

- 导出包里只包含真消息
- `createNew` 不会覆盖已有消息
- `merge` 在大历史下也不会漏判
- 导出再导入后，顺序稳定

---

## 11. 这版方案的取舍

这版不是最省改动的，但它最像正确的系统边界。

它放弃了 会话对象里顺手塞一切 的便利，换来三件真正值钱的东西：

- 数据库永远干净
- UI 动画不再污染存储
- 导入导出终于能只处理真数据

如果这轮目标是 一次性把病根挖掉，那就该按这条路线做。

---

## 12. 参考

- Drift 官方文档：`watch()` 查询会在结果变化时自动发新值，适合把数据库作为响应式数据源
- Riverpod 官方文档：`StreamProvider` 适合接流，`Notifier/AsyncNotifier` 适合持有可变页面状态，两者分层刚好适合这次拆分

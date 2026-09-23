# 记忆与上下文（现行说明）

> 决策出处：[ADR0038](../../../../../docs/项目记忆/决策记录/0038-记忆与上下文重构为短期长期两层.md)（2026-09-23）。本文说明现在是怎么做的，规则以 ADR 为准。
> 2026-09-23 以前的旧方案（四层向量库、角色 `MEMORY.md`、三种压缩与记忆待写队列）已归档到 [05_历史归档/20260923_旧记忆与压缩方案](../../05_历史归档/20260923_旧记忆与压缩方案/)。

## 一句话

原始聊天是唯一真相。**短期记忆**＝上下文管理器（手动压缩翻篇、自动压缩腾地方）；**长期记忆**＝每个角色一个 SQLite 记忆库（常驻＋档案）。压缩成功后，**记忆 Agent** 在后台把刚被压缩的对话整理进记忆库。聊天模型只管聊天，不带任何记忆工具。

## 发送一轮消息时

```text
① 读原文：当前话题（边界之后）的全部原文
② 找摘要：
   · 手动摘要：只在「当前边界正好是那次压缩」时带；边界有、摘要没有（别的设备同步来的、来源被改过）
     → 先把边界前最近约 24k tokens 的原文补整理一份，失败就不发送
   · 自动摘要：概括过的旧消息不再原样发送
③ 记忆插件（角色插件列表里启用「记忆库」才有）：
   常驻层全部 + 按「本轮输入＋最近两轮」关键词检索出的档案（≤6 条、约 1500 tokens）
④ 量长度：到 80% 触发线 → 先截短超长工具结果 → 还超：自动压缩后重来（最多两次）；只剩一轮就做运行时压缩
⑤ 工具循环每轮请求前再检查；服务端报超长只重试这一次模型调用
```

请求副本会把历史里 `memory_search`、`memory_read`、`context_read` 这些旧工具的调用和结果成对去掉。

## 三种压缩

| | 手动（翻篇） | 自动（腾地方） | 运行时（边干边收拾） |
|---|---|---|---|
| 触发 | 聊天页右上角，先预览可编辑 | 发送前到触发线 | 只剩一轮、工具循环中超线、服务端超长 |
| 摘要口径 | 只继承事实、经历、约定，不带旧格式 | 保留目标、进度、待办、工具结果 | 同自动 |
| 存储 | `context_summaries`（manual）＋移动话题边界 | `context_summaries`（auto），不动边界，每个话题只留最新一份 | 不落库 |
| 触发记忆整理 | 是 | 是 | 否 |
| 撤销 | 可以；已写入的记忆不回滚 | — | — |

压缩 Agent（`local.topic_content_handoff` / `local.automatic_context`）只写摘要，没有工具。

## 长期记忆

- **表**：`memory_items`（owner、layer=core/archive、标题、正文、来源消息、locked）、`memory_items_fts`（中文二元分词后由 Dart 写入）、`memory_progress`（书签、重建目标、重建代次、暂停、最近错误）。
- **常驻层**约 2000 tokens，超出的新常驻条目自动改存档案；用户手写的常驻超过上限会被拒绝保存。
- **用户编辑或新增的条目自动锁定**，记忆 Agent 只能读，不能改或删；可在页面上手动解锁。
- **检索**经 `MemoryRetriever` 接口，本期只有关键词实现（FTS5 BM25，同分时新近优先）。以后接向量检索只替换 `memoryRetrieverProvider`；`memory_items.embedding` 列已预留。

## 记忆 Agent

- 触发：手动或自动压缩成功后；每次启动后该角色第一次发送时续跑上次没完成的；角色记忆页的「继续」「从聊天记录重建」。
- 处理范围：从书签到「所有摘要覆盖到的最后一条」（由 `context_summaries` 推算，不另建任务表），重建时到最后一条原文。按记忆模型窗口分批，按时间顺序一批一批来。
- 每批输入：这批原文＋当前常驻层＋按这批原文检索到的档案；只有只读的 `memory_search` 工具。输出 `{"ops":[add/update/delete]}`，代码校验（来源必须在这批里、目标必须属于本角色且未锁定）后，**和书签推进在同一事务里写入**。
- 失败：记录错误，书签不动，不影响聊天，下次再试。重建会让代次加一，旧批次在写入时发现代次变了就整批放弃。
- 同一角色同一时间只有一个整理任务。

## 设置

- 设置 → 默认模型 →「上下文与记忆」，或插件列表的「记忆库」：上下文窗口（默认 272k）、压缩模型（空＝跟随默认聊天模型；旧「长期记忆」插件里配过的总结模型会被沿用）、记忆模型（空＝跟随压缩模型）。
- 角色是否使用长期记忆：角色插件列表里的「记忆」（ADR0035）。
- 角色记忆页（编辑角色 → 记忆 → 角色记忆文档）：常驻／档案两栏，编辑、锁定、删除、复制全部、从聊天记录重建（先显示条数、tokens 和批数估算）、暂停／继续。

## 旧数据退役

启动时 `LegacyMemoryRetirement` 检查旧表和 `contact_memories/`：先导出 JSON 并复制目录到 `ApplicationSupport/legacy_memory_backup/<时间>/`，把旧的手动摘要迁进 `context_summaries`，都成功后才删旧表和目录；失败下次启动重做。

## 同步与备份

- 旧记忆类型（`memories`、`summarization_records`、`memory_tombstones`、`diaries`、`topic_handoffs`、`contact_memory`）已退役：不上传，云端推下来的只消费不落地。
- 同步记录的 `client_schema` 用 `kCloudRowSchema`（同步表结构版本，当前 17），与整库版本解耦。
- 新表暂不同步（ADR0038 的 B5，需要改云端协议并部署）；导入导出也不含记忆，记忆页提供「复制全部记忆」。

## 代码地图（`lib/src/`）

| 模块 | 文件 |
|---|---|
| 上下文领域模型与端口 | `features/context/domain/context_summary.dart`、`context_window_policy.dart` |
| 上下文管理器（手动／自动／补整理） | `features/context/application/context_manager.dart` |
| 运行时压缩 | `features/context/application/runtime_context_service.dart` |
| 摘要存储 / 压缩 Agent | `features/context/data/sqlite_context_summary_store.dart`、`background_context_summarizer.dart` |
| 依赖装配与模型选择 | `features/context/providers/context_providers.dart`、`features/memory/providers/memory_providers.dart` |
| 记忆模型与端口 | `features/memory/domain/memory_item.dart`、`memory_ports.dart` |
| 记忆存储 / 检索注入 | `features/memory/data/sqlite_memory_store.dart`、`features/memory/application/memory_retrieval.dart` |
| 记忆 Agent / 维护服务 | `features/memory/data/background_memory_agent_adapter.dart`、`features/memory/application/memory_keeper_service.dart` |
| 旧数据退役 | `features/memory/data/legacy_memory_retirement.dart` |
| 记忆插件（只注入） | `features/plugins/memory/memory_plugin.dart` |
| 发送装配 / 工具循环 | `features/chat/services/chat_send_backend_service.dart`、`chat_send_api_runner.dart`、`chat_plugin_context_policy.dart` |
| 界面 | `ui/features/chat/widgets/topic_compaction_button.dart`、`ui/features/character/pages/contact_memory_page.dart`、`ui/features/settings/pages/context_memory_settings_page.dart` |
| 建表与迁移（v18） | `core/database/database.dart`（`_ensureContextMemoryTables`） |
| 测试 | `test/features/context/`、`test/features/memory/memory_keeper_test.dart`、`test/core/database/context_memory_migration_test.dart` |

## 不在本期范围

- 主动关怀的「后台即时生成」自己截取原文，拿不到新摘要和长期记忆（预生成走发送装配，不受影响）。
- 向量检索、记忆与摘要的云同步（B4、B5）。

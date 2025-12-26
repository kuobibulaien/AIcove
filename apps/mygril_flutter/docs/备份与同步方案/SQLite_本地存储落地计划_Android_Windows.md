# SQLite 本地存储落地计划（Android / Windows）

面向：MyGril Flutter 客户端  
目标：替换当前 SharedPreferences 的整包 JSON 存储，让聊天数据像通讯软件一样“分表存储、按需读取”，并且 **一套代码同时支持 Android + Windows**（未来可扩展 macOS / 鸿蒙）。  

## 0. 现状说明（为什么要做）

当前聊天数据主要由 `ConversationsNotifier` 负责本地持久化：  
- 文件：`apps/mygril_flutter/lib/src/features/chat/providers2.dart`  
- 存储：SharedPreferences  
- key：`mygril.conversations`  

这种方式像“把所有聊天记录写在一张很大的便签上”：  
- 数据越多越卡：每次写入都要把整坨 JSON 重新编码/存一遍  
- 容易脏数据：一旦 JSON 结构变化或解析失败，就需要兜底重建  
- 难扩展：多模态 block、附件、备份/合并、增量同步都不好做  

因此改为 SQLite（分表）是合理且必要的。

## 1. 技术选型结论（方案 B）

选型目标：**一次实现，多平台通用（Android + Windows）**。

结论：采用 **Drift（Dart 侧数据库层）+ SQLite（原生引擎）**  
- Drift 负责：建表、迁移、类型安全查询、事务、DAO（Repository）模式  
- SQLite 负责：最终数据存储（db 文件）  

说明：本方案比直接用 `sqflite` 更适合“多端统一”，减少 Android/Windows 分支逻辑。

> 依赖层面的改动属于“重大变更”，实际开始实现时会先再次确认并按项目现有依赖管理方式落地。

## 2. 数据表设计（与业务对象的对应关系）

你当前的草案总体可行，下面是“表 ↔ 功能”的对应关系（帮助下次排查问题知道去哪找）。

### 2.1 `conversations`（联系人/角色/会话概要）
负责：对话列表页所需的一切“摘要信息”（置顶/收藏/免打扰/最后一条预览/未读数等）  
核心点：`last_message` / `last_message_time` 是“缓存字段”，必须在写消息时同步更新，避免列表显示不一致。

建议补充（为后续同步/合并留口）：  
- `is_deleted` 或 `deleted_at`（软删除）  
- `sync_state`（本地新增/已同步/本地修改/待删除…）  

### 2.2 `messages`（消息主表）
负责：进入聊天页后分页读取消息（按会话 + 时间倒序）  
建议补充：  
- `updated_at`（因为消息 status/内容可能会被更新，不只是插入一次）  
- 未来同步可选：`server_id` / `client_local_id`（防重复/幂等）

### 2.3 `message_blocks`（多模态内容块）
负责：一条消息的分块内容（文本/图片/音频/表情/工具输出等）  
建议约束：  
- `UNIQUE(message_id, sort_order)` 防止导入/合并后顺序混乱  

“block 里的文本”解释：  
- `TextBlock.content` 是最常见的可见文本  
- `AudioBlock.text` 可能是语音字幕/原文  
- `Tool/Thinking` 默认不进入关键词搜索（避免搜索结果被内部信息污染），可后续做开关  

### 2.4 `memories`（记忆/向量，可选启用）
负责：长期记忆内容 + 可选向量检索  
约定：用户不导入 Embedding 模型时，可只存 `content`，向量相关字段允许为空。  

向量存储建议：  
- 二进制格式统一为 Float32（更紧凑、更快）  
- 写入时校验：`embedding_dim` 必须等于向量长度  
- 相似度计算要处理“向量全 0”避免 NaN  

### 2.5 `db_meta`（元信息）
建议策略：  
- SQLite `PRAGMA user_version` 用于“结构版本”（迁移用）  
- `db_meta` 用于“业务元信息”（最后备份时间、app 版本等）  

## 3. 目录结构规划（文件 ↔ 功能）

落地时建议建立以下目录（都在 Flutter 主工程内）：  

`apps/mygril_flutter/lib/src/core/database/`（数据库核心）
- `database_service.dart`：打开数据库、PRAGMA 初始化、事务封装、迁移入口  
- `database_schema.dart`：建表常量/公共 SQL（若采用 Drift 则这里会转为 table 定义）  
- `migrations/`：迁移脚本（v1/v2…）  

`apps/mygril_flutter/lib/src/core/database/repositories/`（数据访问）
- `conversation_repository.dart`：对话 CRUD、对话列表查询、更新会话摘要字段  
- `message_repository.dart`：消息增删改查、分页、写入消息时同步更新会话摘要  
- `memory_repository.dart`：记忆 CRUD、（可选）向量搜索/关键词检索入口  

`apps/mygril_flutter/lib/src/core/database/backup/`（备份）
- `backup_service.dart`：导出/导入/合并/覆盖策略、校验、临时目录管理  
- `backup_format.dart`：manifest / data json 的结构定义  

## 4. 关键工程约定（避免“写了却不生效”的坑）

### 4.1 SQLite 必须启用外键
否则 `ON DELETE CASCADE` 不会生效（删会话但消息残留）。  
落地时在打开数据库后执行：`PRAGMA foreign_keys = ON`。

### 4.2 建议使用 WAL
更适合聊天类“读多写多”的场景，减少卡顿：`PRAGMA journal_mode = WAL`。

### 4.3 批量导入/迁移必须用事务 + 批处理
否则迁移/导入会非常慢，并且中途失败容易出现半成品数据。

## 5. 备份导出/导入（私有存储 + 对外导出）

你的 zip 方案可行。这里明确“私有存储也能导出”的方式：
- 平时：附件（图片/音频等）存应用私有目录（安全、路径稳定）  
- 导出：生成 zip 到临时目录 → 让用户选择保存位置/系统分享  
- 单个附件“下载”：从私有目录复制到用户选的路径（或分享）  

导入建议补两点防翻车：
- DB 写入放在单个事务里；assets 拷贝失败要回滚或至少标记缺失  
- manifest 除总 checksum 外，可对每个 `data/*.json` 记录 checksum（更好排错）  

## 6. 迁移策略（SharedPreferences → SQLite）

迁移目标：把 `mygril.conversations` 的 JSON 结构，拆成：
- conversations（一行一个会话）
- messages（一行一条消息）
- message_blocks（一行一个 block）

迁移步骤建议：
1) 启动时检测旧 key 是否存在  
2) 事务内导入：先 conversation → messages → blocks  
3) 校验导入数量（至少会话数/消息数非 0 或符合预期）  
4) 成功后删除旧 key（避免重复导入）  

## 7. 搜索策略（先不做 FTS5）

第一阶段不启用 FTS5（减少复杂度），需要关键词搜索时再加：  
- 默认只索引“用户可见文本块”（TextBlock + Audio 字幕）  
- Tool/Thinking 默认不索引（避免污染），可加开关  

## 8. 实施优先级（按阶段交付）

Phase 1（1-2 天）
- DatabaseService + 表结构 + 迁移框架 + PRAGMA（外键/WAL）

Phase 2（1 天）
- Repository 层（Conversation/Message/Memory 基础 CRUD + 消息分页）

Phase 3（0.5 天）
- 改造 `ConversationsNotifier`：从“读写 SharedPreferences”切到“调用 Repository”

Phase 4（1 天）
- 备份导出/导入（覆盖/合并 + 附件打包）

Phase 5（0.5 天）
- 向量搜索接入（仅在用户启用 Embedding 时生效）

## 9. 待确认项（开始编码前必须最终敲定）

1) Drift 相关依赖与代码生成：项目是否允许引入 build_runner / generator（若已有同类流程则复用）  
2) 附件路径规范：DB 内保存“相对路径”，由统一的 FileStorageService 解析到真实目录（推荐）  
3) 云端同步：本项目最终采用“云端优先（Cloud wins）”，本地 SQLite 作为缓存/离线与导入导出的底座；后端 `cloud_backend` 将按本地结构对齐（字段/接口会调整）  

---

## 10. 施工入口（给“动工 AI”看的）

本文件是“本地库落地计划”。真正的施工手册（包含：最终表字段、同步接口、回收站、分支、重生成覆盖、备份格式、加密策略、施工顺序）在：
- `apps/mygril_flutter/docs/备份与同步方案/施工手册_备份与云同步.md`

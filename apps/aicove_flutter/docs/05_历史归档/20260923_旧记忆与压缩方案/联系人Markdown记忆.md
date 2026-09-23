# 联系人 Markdown 记忆

更新：2026-09-13。状态：独立文档、手动维护、按需读取与压缩时自动提出记忆增量已实现；执行边界见[压缩联动规范](上下文压缩与记忆联动方案.md)和ADR0027。

## 目标与入口

每个联系人有独立的常驻笔记与往事，取消新模式对 Embedding 和向量召回的依赖。记忆存储容量不等同于每轮模型上下文容量。

入口：编辑已有联系人 →「角色记忆文档」。开启「使用独立 MD 记忆」并保存，才切换该角色的模式；尚未创建文档时默认使用旧模式。角色卡模板、新建未保存联系人不提供此入口，避免把同一模板的多个联系人绑定到同一记忆。

聊天中仍受全局长期记忆开关和联系人插件许可控制。新模式可由用户维护，也可在聊天右上角“压缩并开启新话题”预览摘要后归档往事；自动压缩时也整理有来源的增量，不定时扫描历史。总结模型供旧记忆库和手动压缩使用，未配置时手动压缩使用默认聊天模型；MD 存储和读取不依赖 Embedding。

## 存储与隔离

```text
应用私有 ApplicationSupport 目录/
  contact_memories/
    <SHA256(稳定联系人 ID)>/
      MEMORY.md
      .write.lock
```

- MD 是新模式的唯一记忆真相源，不双写 SQLite 旧 Memories 表，不另存一套 JSON 正文。
- 文档内含格式版本、所属角色与模式标记，常驻正文和各事件正文均为可读文本。编辑器通过结构化页面维护 Markdown，直接编辑文件时必须保留结构标记。
- 联系人 ID 当前映射 Conversation.id；同名、相同人设、相同模板也不会共享。新话题只改变上下文边界，不改变记忆 owner。
- 应用层只依赖 `ContactMemoryPort`。文件路径由基础设施实现产生；工具既不接收 owner 参数，也不接收文件路径。
- 文档头 owner 不匹配、格式损坏或符号链接会拒绝读取；不得把损坏当空记忆覆盖，亦不得悄悄退回旧库召回。

写入先检查读取版本（内容哈希），使用进程内串行队列与文件锁，写临时文件、flush 后 rename 替换。并发或外部编辑导致版本变化时拒绝覆盖，UI 保留草稿。读取到旧完整文件或新完整文件均可，不接受半写文件。

## 两类内容

| 类型 | 内容 | 加载方式 |
| --- | --- | --- |
| 常驻笔记 | 明确偏好、相处约定、正在进行的事 | 每轮直接加载，保存时约 2000 tokens 上限；沿用项目 token 估算器，不把字符数当精确 token |
| 往事 | 标题、发生日期、事件正文 | 每轮只带最近 5 项目录；通过工具搜索及分页读取正文 |

事件标题最多 120 个 UTF-16 code units，正文最多 20000；单文档当前设 8 MiB 防异常读取上限。超限拒绝保存而非自动裁短或删除历史。这些是首批工程保护值，不是记忆效果已验证的最佳参数。

常驻内容不包含角色卡、人设的副本；模型不能把记忆当作覆盖系统权限的指令。手写事件可以表达共同经历，但 UI 提醒应区分角色剧情和用户现实事实。

## 真实工具链

```text
ChatSendBackendService.prepareApiConfig(明确联系人 ID)
  → ChatPluginContextBuilder.collectPluginToolsWithRetry(conversationId)
  → MemoryPlugin.getToolsForConversation(ownerId)
  → AITool handler 闭包绑定 owner
  → ApiConfig.boundTools 与 tools schema 同时保存
  → ChatSendApiRunner 读取绑定 handler
  → ContactMemoryReader → ContactMemoryPort
```

| 工具 | 参数 | 返回 |
| --- | --- | --- |
| `memory_search` | query（关键词/日期，可空）、offset | 该角色目录，每页最多 8 条、总数、nextOffset；不把所有事件正文塞给模型 |
| `memory_read` | id、offset | 该角色事件正文，最多 1200 Unicode code points、nextOffset |

关键词采用大小写无关子串匹配，空格分隔的词同时匹配；不是向量或语义搜索。模型可换词查找；查不到应承认不确定。第一批不新建检索 agent，也不宣称近义表达召回率与向量相同。

每次工具执行再次检查全局开关、该角色存在且未删除、该角色插件许可及文档模式。切页面、启动另一个角色的请求不会改变旧请求的 owner。缺少 owner 时无记忆提示、无全局记忆工具，禁止回退到 activeConversationProvider。

不支持工具调用的模型只获得常驻笔记及近期目录，提示明确说明不能读取完整旧事。读取失败由现有聊天装配边界降级为本轮无记忆，不阻塞聊天。提示和工具收集的文档读取超时为 500ms；工具正文读取沿用 runtime 的工具超时和回合数上限。

## 新旧模式互斥与回滚

1. MD 模式在常驻提示处提前返回，不进入旧 profile/search/daily 触发；pre-flush 与新话题入口也检查模式后跳过旧写入。切模式前已开始的旧后台请求不会被强制取消，但只能落旧库，不会写 MD。
2. 关闭该角色 MD 模式并保存，可恢复旧模式；新文档正文保留，旧数据库没有被迁移或删除。回滚不会自动把 MD 内容转换回旧库。
3. 用户移除往事并保存后，新请求及后续工具调用不再读取此项。不承诺撤回已发给模型的历史请求或清除原聊天中的相同内容。
4. 既有联系人软删除后工具拒绝读取，其文件保留便于恢复；本阶段未接物理删除清理或回收站同步。
5. 本阶段没有新 MD 的云同步、备份/导入导出和自动历史回填。不能用旧 memory 备份范围声称 MD 已被备份；卸载/清除应用数据会丢失仅本地保存的文档。

## 后续第二批

2026-09-05 新需求草案：[上下文压缩与记忆联动方案](上下文压缩与记忆联动方案.md)。用户已澄清手动需要“内容继承、格式重置”：新话题带纯内容摘要，但不带旧消息/旧格式指令；自动则保留工作摘要和最近轮次继续聊。手动部分已实现并接通归档，自动部分留第二批；详见该文档的实际限制。

从 DB raw messages 增量生成候选，补来源、敏感内容确认、人工锁定、失败重试与去重；不读 UI 投影，不因新模式去修改旧 summarized 标记。自动整理上线前需要继续验证旧方案中“没有 Embedding 时未写入却标记总结成功”的静态风险，不直接复用这一成功判定。

手写事件没有自动提取来源；压缩归档事件附带交接记录 ID，DB 保存其 raw 消息范围和版本。压缩增量带来源ID，可更正未被人工修改的自动记录；同一作业重试不重复写，完整忘记协议尚未实现。移除 MD 往事不同时移除会话内容摘要或原始聊天；撤销压缩也不自动删除已归档记忆。

## 验证与代码位置

- `features/memory/domain/contact_memory_port.dart`：存储契约与文档模型。
- `features/memory/data/markdown_contact_memory_store.dart`：单角色 MD、原子写、并发保护。
- `features/memory/application/contact_memory_reader.dart`、`contact_memory_tools.dart`：有界目录、关键词搜索、分页正文与绑定工具。
- `ui/features/character/pages/contact_memory_page.dart`：编辑/保存/移除入口，宽屏居中最大 760px，窄屏可滚动。
- `test/features/memory/contact_memory_*_test.dart`、`test/ui/features/character/pages/contact_memory_page_test.dart`：隔离、并发、损坏、工具参数注入、关闭/删除后旧工具拒读、真实工具循环、360/1000px 交互及页面复用。

工具循环测试只替换模型网络边界，不调用生产模型。文件隔离测试使用真实临时目录和两个 store 实例。页面复用测试先复现跨角色旧草稿残留，再以 owner 变更重置和异步 generation 校验修复。

## 压缩生成记录的元数据（2026-09-13）

version1新增可选appliedCompactions列表与事件generatedKey/generatedDigest/memoryKind；旧文档读取默认空。自动更新要求标题、正文及类型的摘要与生成版本一致，手写正文不参与改写。自动core事实计入每轮2000tokens常驻预算，剩余内容通过往事工具读取；策略和失败语义以[压缩联动规范](上下文压缩与记忆联动方案.md)为准。

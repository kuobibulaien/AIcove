# Provider 与会话状态收敛

## 本文目标

把聊天主流程相关 Provider 从“历史叠加”整理成“真相源明确、派生关系清晰、命令入口独立”的结构。

---

## 当前 Provider 盘点

当前主要 Provider 文件：

- `lib/src/features/chat/chat_providers.dart`
- `lib/src/features/chat/providers2.dart`
- `lib/src/features/chat/conversation_providers.dart`
- `lib/src/features/chat/chat_layer_providers.dart`
- `lib/src/features/chat/conversation_timeline_providers.dart`

审计中最明显的问题：

1. `providers2.dart` 是典型过渡命名，无法表达职责。
2. `chat_providers.dart` 里存在依赖 presentation 枚举的情况，说明分层反向耦合。
3. `activeConversationProvider` 既在兜 snapshot，又在兜数据库 watch，页面层还自己重复做了一次 fallback。
4. 时间线临时消息与流式状态仍有旧 Provider 残留。

---

## 目标组织方式

建议把 Provider 先按角色分 4 类，而不是先讨论应该有几个文件：

### 1. 真相源 Provider

特点：

- 直接来自数据库、仓储、控制器或稳定状态对象
- 是派生计算的输入
- 应该尽量少且名字稳定

典型例子：

- 当前会话
- 当前会话消息流
- 当前联系人配置
- 当前发送状态

### 2. 派生/选择器 Provider

特点：

- 只基于真相源做计算
- 不再兜底写逻辑
- 不应偷偷查询第二数据源

典型例子：

- 排序后的会话列表
- 当前页面可见时间线
- 当前会话的 UI 视图模型

### 3. 命令入口 Provider

特点：

- 只暴露动作对象、controller、service facade
- 不和纯派生数据混放

典型例子：

- `ChatActions`
- 会话编辑动作
- 时间线刷新动作

### 4. 兼容过渡 Provider

特点：

- 只在迁移期存在
- 要有明确删除计划
- 文件名/注释里要标明“过渡期”

---

## 文件级建议

### `providers2.dart`

建议目标：

- 第一阶段停止新增 import
- 第二阶段迁移完引用后删除

不要继续把它当“第二个总入口”。

### `chat_providers.dart`

建议只保留真正的 chat 域公共 Provider，不再依赖 presentation 层类型。像 `SortMode` 这类展示枚举应上移为 domain/application 可复用定义，或下沉为 UI 自己转换。

### `conversation_providers.dart`

适合承接：

- 当前会话真相源
- 会话列表真相源
- 会话基础派生选择器

但不要继续同时承担页面 fallback、临时消息兜底、数据库兼容分支。

### `conversation_timeline_providers.dart`

适合承接：

- 当前会话时间线真相源
- 仅与时间线展示相关的派生计算

不适合继续承接已经被 Actions/HistoryStore 吞掉的旧临时占位写逻辑。

### `chat_layer_providers.dart`

需要重新审视是否仍有存在必要。若只是旧中间层或历史导出层，应尽量收缩或并回明确职责文件。

---

## 推荐施工步骤

### Step 1：画出真相源清单

先列出“页面真正需要订阅的原始状态”有哪些，不要直接从现有 Provider 文件开始改。

建议至少包括：

- 当前会话实体
- 当前会话消息流
- 当前发送状态
- 当前流式占位状态
- 当前联系人/角色配置

### Step 2：把 snapshot/db fallback 收到 Provider 内部唯一出口

像当前会话这类状态，不应该由页面层再重复做一次 fallback。

目标是：

- 页面永远只读一个 Provider
- fallback 策略由 Provider 层自己维护

### Step 3：清理旧临时消息 Provider

先确认新的单一交付协调者已经就位，再逐步删除以下类型的旧出口：

- 不再有 writer 的临时时间线 Provider
- 只剩读取但无生产者的流式气泡 Provider

### Step 4：拆掉 `providers2.dart`

迁移策略建议：

1. 先冻结新增引用
2. 再逐个迁移 import 到明确文件
3. 最后删除 `providers2.dart`

这样最稳，不会在中途把全仓 import 一次性打散。

---

## 建议写文件范围

推荐由“Provider 窗口”负责：

- `apps/aicove_flutter/lib/src/features/chat/chat_providers.dart`
- `apps/aicove_flutter/lib/src/features/chat/providers2.dart`
- `apps/aicove_flutter/lib/src/features/chat/conversation_providers.dart`
- `apps/aicove_flutter/lib/src/features/chat/chat_layer_providers.dart`
- `apps/aicove_flutter/lib/src/features/chat/conversation_timeline_providers.dart`

必要时可少量联动提供者所依赖的 domain/application 定义，但不要主动接手页面层展示逻辑。

---

## 与其他窗口的接口约定

### 给 Actions 窗口

Provider 只消费“单一流式交付协调者”的公开状态，不和 `ChatActions` 共享隐式私有状态。

### 给 UI 窗口

UI 只订阅稳定 Provider，不自己做 snapshot/db fallback，也不自己拼临时消息来源。

### 给清理窗口

删除 dead code 前，先由 Provider 窗口明确哪些 Provider 已无读写双方。

---

## 验收标准

1. `providers2.dart` 不再作为新增引用入口。
2. 真相源 Provider、派生 Provider、命令 Provider 的边界清晰。
3. 页面层不再自己兜底 `activeConversation` 等状态来源。
4. 旧临时消息 Provider 在完成迁移后有明确下线计划。
5. Provider 文件命名能从名字看出职责，不再靠“历史记忆”理解。

---

## 高风险点

1. Provider 迁移时最容易出现“页面能编译，但监听不到更新”的隐性回归。
2. 如果多个窗口同时动同一 Provider 文件，冲突率会很高。
3. 删除旧 Provider 之前若没确认 writer/reader 全部迁走，UI 会直接丢状态。

建议：

- Provider 文件由单窗口独占
- 对外通过稳定接口对齐，减少多人同时改一个文件

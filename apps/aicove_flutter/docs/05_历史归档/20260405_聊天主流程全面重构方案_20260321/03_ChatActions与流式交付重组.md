# ChatActions 与流式交付重组

## 本文目标

解决两个紧耦合问题：

1. `ChatActions` 继续作为共享上帝类存在。
2. 流式占位消息的写路径和真相源不唯一。

---

## 当前症状

重点文件：

- `lib/src/features/chat/presentation/chat_actions.dart`
- `lib/src/features/chat/presentation/chat_actions_action_ops.dart`
- `lib/src/features/chat/presentation/chat_actions_stream_placeholder.dart`

当前问题集中在：

1. `ChatActions` 同时负责发送入口、本地消息操作、流式占位协调、会话编辑、副作用调度。
2. `part` 拆文件只解决了物理体积，没有解决共享状态耦合。
3. 占位消息逻辑已经部分迁到 HistoryStore 路径，但旧 Provider 思路仍残留，形成双通路。
4. 很多局部辅助方法只能依赖整类私有状态调用，难以单独测试。

---

## 目标口径

### `ChatActions` 要回到“页面动作门面”身份

它应该负责：

- 接 UI 命令
- 调应用层主入口
- 协调页面需要的少量即时副作用

它不应该负责：

- 自己实现一整套发送执行链
- 自己维护流式占位状态机
- 自己兼管会话编辑、消息删除、重试、重生成、引用协议、后台触发等所有事务

### 流式占位只能有一个交付协调者

无论最后协调者放在哪一层，都要满足：

- 占位创建、流式更新、最终落库、失败回滚都从同一入口走
- Provider/UI 只能消费统一结果，不能自己再拼临时气泡

---

## 建议拆分方式

### 1. `ChatActions` 保留为 facade

对 UI 暴露：

- `send`
- `retry`
- `regenerate`
- `deleteMessage`
- `editConversation`
- 其他页面动作

但内部不再堆大段业务实现，而是分发给明确的协作对象。

### 2. 把“发送类动作”与“本地编辑类动作”分开

建议至少在职责上切成两组：

- turn 类动作：发送、重试、重生成、主动触发
- 本地 mutation 类动作：删除、置顶、编辑会话、切换配置

文件名可以沿用现有 `part` 文件，也可以在后续改成更清晰命名；关键是不要继续共享过多内部状态。

### 3. 流式交付单独成为一套受控职责

建议把流式占位协调能力单独抽成稳定协作者，负责：

- 创建占位
- 接收流式增量
- 更新临时消息
- 交接到正式落库消息
- 失败时回滚占位

它不该顺手承担：

- 页面滚动控制
- Provider 派生计算
- 通用会话编辑

---

## 推荐施工步骤

### Step 1：梳理 `ChatActions` 对外 API，不急着改文件名

先列清楚 `ChatActions` 目前真正需要对 UI 暴露哪些方法，把内部方法和外部接口分清。

目标是先把“公开动作面”稳定下来，再做内部拆责。

### Step 2：发送类动作全部改为“构造命令 + 调用 use case”

`ChatActions` 中涉及发送的入口都不再保留自己的执行骨架，只负责：

- 整理页面输入
- 构造统一发送命令
- 调用 `ChatSendUseCase`
- 处理少量页面级回调

### Step 3：本地 mutation 类动作收成另一组职责

像这些本地动作应独立成清晰分组：

- 会话编辑
- 消息删除
- 置顶/取消置顶
- 草稿/引用清理

这些动作不应继续依赖发送链内部状态。

### Step 4：流式占位交付改成显式状态机

重点把以下阶段固定下来：

1. 初始化占位
2. 流式增量更新
3. 工具调用中间态
4. assistant 最终消息落库
5. 占位移除或转正
6. 失败回滚

一旦状态机稳定，`chat_message_list.dart` 和 Provider 只消费结果。

---

## 建议写文件范围

推荐由“Actions 窗口”负责：

- `apps/aicove_flutter/lib/src/features/chat/presentation/chat_actions.dart`
- `apps/aicove_flutter/lib/src/features/chat/presentation/chat_actions_action_ops.dart`
- `apps/aicove_flutter/lib/src/features/chat/presentation/chat_actions_stream_placeholder.dart`

必要时可联动少量接口定义文件，但不要主动改 Provider 大盘和 UI 页面。

---

## 不要在这个窗口做的事

1. 不直接改 5 个 Provider 文件的大结构。
2. 不直接改 `chat_page.dart` 和 `chat_message_list.dart` 的展示实现。
3. 不负责清理全量 dead code。
4. 不随手 rename 大量公开符号。

这个窗口的目标是先把 `ChatActions` 和流式交付职责收清。

---

## 与 Provider 窗口的边界

Actions 窗口需要向 Provider 窗口明确一件事：

- 最终由谁提供“当前会话的临时消息/流式占位视图模型”

但不要双方同时去改 `conversation_timeline_providers.dart`。建议让 Provider 窗口拥有该文件的最终写权限，Actions 窗口只提供交付协调接口。

---

## 验收标准

1. `ChatActions` 从共享上帝类明显收瘦，发送类动作不再自带执行骨架。
2. 本地 mutation 与 turn 类动作边界清晰。
3. 流式占位生命周期有明确单一协调者。
4. 失败回滚、正式落库、占位移除三条路径不再散落在多个入口里。
5. UI 不再需要自己判断该读哪个临时消息来源。

---

## 高风险点

1. 流式占位和正式落库交接很容易出现重复一条、闪空窗、顺序错位。
2. 如果在还没统一状态机前就强删旧 Provider 路径，容易把列表显示弄挂。
3. `ChatActions` 当前私有状态很多，拆解时最容易把取消/中断/回调时机改坏。

建议：

- 先以兼容方式引入单一协调者
- 确认 UI 完整切到新出口后，再删旧路径

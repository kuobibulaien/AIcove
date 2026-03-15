# 实施计划：记忆系统统一入库方法

## 任务类型
- [x] 后端 (Codex)

## 背景

当前 memory_service.dart 有两条入库路径，生命周期管理不统一：

| | 按天/轮次总结 (daily) | Pre-flush (上下文超限) |
|---|---|---|
| 入口 | checkAndTriggerDailySummarization | runPreFlush |
| 分轮 | _splitByOneHourGap | 跳过，取最后12条 |
| 总结+存储 | summarizeAndStore() | 同 |
| 写总结记录 | summarization_records | 不写 |
| 标记消息 | summarized=true | 不标记 |

核心问题：`summarizeAndStore()` 只管"总结+存储"，不管"标记"。标记逻辑散落在 daily 外层，pre-flush 完全没有。

## 技术方案

### 新增统一入库方法 `ingestMessages()`

触发器（daily / preFlush / manual）只负责"喊一声 + 传范围"，不写入库逻辑。

```
触发器 → ingestMessages(scope) → _buildIngestUnits() → _ingestUnit() → summarizeAndStore() + 标记
```

### 方法签名

```dart
enum MemoryIngestTrigger { daily, preFlush, manual }

Future<void> ingestMessages({
  required String conversationId,
  Iterable<String>? candidateMessageIds,    // preFlush/manual 传具体消息ID
  int? beforeTimestampExclusive,            // daily 传 startOfToday
  required MemoryIngestTrigger trigger,
});
```

- Public 方法不接收 raw messages，内部从 DB 读取（以 DB 中 summarized 状态为准）
- daily 传 `beforeTimestampExclusive = startOfTodayLocalMs`
- preFlush 传 `candidateMessageIds = droppedMessages.map(m => m.id)`
- manual 可传 candidateMessageIds 或不传（处理全部未入库）

## 实施步骤

### Step 1: message_repository.dart — 新增统一查询方法

在 MessageRepository 新增 `getIngestCandidates()`：
- 参数：conversationId, candidateMessageIds?, beforeTimestampExclusive?
- 固定过滤：summarized == false, deletedAt is null, replacedBy is null
- 排序：createdAt asc, id asc

### Step 2: memory_service.dart — 新增 MemoryIngestTrigger 枚举

```dart
enum MemoryIngestTrigger { daily, preFlush, manual }
```

### Step 3: memory_service.dart — 提取 _buildIngestUnits()

从 checkAndTriggerDailySummarization 中提取分轮逻辑：
- 统一走 _splitByOneHourGap()
- daily 触发时：消息少或单轮允许整天聚合（roundKey = 'day:$dateKey'），但如果该天有部分消息已被 preFlush 入库，则不做整天聚合
- preFlush 触发时：永远用严格 round key，不做整天聚合

### Step 4: memory_service.dart — 提取 _ingestUnit()

从 checkAndTriggerDailySummarization 中提取单轮入库逻辑：
1. 查 summarization_records 判断是否已处理
2. 修复历史脏数据（从 daily 移入，共享）
3. 调用 summarizeAndStore()
4. 成功后调用 markRoundSuccessAndMessages()
5. 失败后调用 markRoundFailure()

### Step 5: memory_service.dart — 新增公共入口 ingestMessages()

```dart
Future<void> ingestMessages({...}) {
  return _withConversationIngestLock(conversationId, () async {
    final rows = await _messageRepository.getIngestCandidates(...);
    if (rows.isEmpty) return;
    final units = _buildIngestUnits(rows, trigger: trigger);
    for (final unit in units) {
      await _ingestUnit(conversationId: conversationId, unit: unit);
    }
  });
}
```

含会话级串行锁，防止同一对话的 daily 和 preFlush 同时跑。

### Step 6: 重构 checkAndTriggerDailySummarization()

改成薄包装：
- 保留：计算 startOfToday、判断是否需要触发的前置检查
- 去掉：分轮逻辑、记账逻辑、标记逻辑（全部委托给 ingestMessages）
- 调用：`ingestMessages(trigger: daily, beforeTimestampExclusive: startOfToday)`

### Step 7: 重构 runPreFlush()

改成薄包装：
- 保留：确定哪些消息将被截断的逻辑
- 去掉：直接调用 summarizeAndStore 的代码
- 调用：`ingestMessages(trigger: preFlush, candidateMessageIds: focusIds)`

## 关键文件

| 文件 | 操作 | 说明 |
|------|------|------|
| memory_service.dart | 重构 | 核心改动：新增 ingestMessages + _buildIngestUnits + _ingestUnit，重构两个旧入口 |
| message_repository.dart | 新增 | 添加 getIngestCandidates() 查询方法 |
| memory_plugin.dart | 不改 | 触发器调用接口不变 |
| chat_send_service.dart | 不改 | triggerPreFlush 接口不变 |

## 风险与缓解

| 风险 | 缓解措施 |
|------|----------|
| 整天聚合与部分入库冲突 | _buildIngestUnits 检查是否有已总结消息，有则禁止整天聚合 |
| 并发触发 | 会话级串行锁，同一对话同时只跑一个 ingest |
| 重构后行为回归 | 现有测试 + 新增 ingestMessages 单元测试 |
| pre-flush 传入的消息不在 DB 中 | getIngestCandidates 从 DB 查，查不到就跳过 |

## 验收标准

1. daily 路径行为不变：按天/按轮次总结，记账，标记
2. preFlush 路径补全：同样记账、标记
3. ingestMessages() 幂等：重复调用不会重复总结
4. 新增测试覆盖 ingestMessages 主流程
5. flutter run 通过

## SESSION_ID
- CODEX_SESSION: 019ced26-9868-73f2-9d9b-a4b671ddc712

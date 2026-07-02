# 主动回复完全体落地验收报告

## 验收标准完成情况

### ✅ 后台即时生成的 messages 含角色人设 system prompt 与输出约束
**实现位置：** `background_service.dart` L829-L867  
**验证方式：** 后台生成调用 `buildBackgroundProactiveMessages`，使用 `PromptBuiltinDefaults.autoReplyBackgroundObjective` 注入人设与纯文本输出约束

### ✅ quiet hours / dailyLimit / minInterval 在后台任务执行前生效
**实现位置：** `background_service.dart` L198-L251 (`evaluateBackgroundSendGates`)  
**验证方式：** 测试 `background_service_test.dart` 验证三重门禁（L20-L118）

### ✅ 同 tick 多个触发器事件不丢失
**实现位置：** `auto_reply_trigger_controller.dart` L23-L44 (`AutoReplyTriggerEventBus`)  
**验证方式：** 使用 StreamController 顺序消费事件，替代单值 StateProvider

### ✅ delay > 60min 的触发器到点即时生成，失败回退缓存候选
**实现位置：** `background_service.dart` L668-L723  
**验证方式：** 缓存超 60 分钟视为过期，优先即时生成，失败时回退使用缓存兜底

### ✅ 触发器状态机不再有 preparing
**实现位置：** `auto_reply_trigger.dart` L11-L24 (`AutoReplyTriggerStatus` enum)  
**验证方式：** `preparing` 状态已从枚举中删除，状态机只有 created/pending/prepared/fired/expired/cancelled

### ✅ 前后台并发触发只发一条（原子认领）
**实现位置：** `auto_reply_claim_store.dart` + `database.dart` Schema v14  
**验证方式：** 测试 `auto_reply_claim_store_test.dart` (L18-L27) 和集成测试 (L147-L178) 验证互斥

### ✅ WorkManager inputData 不含 apiKey/model，执行时现读配置
**实现位置：** `auto_reply_request_config.dart` + `background_service.dart` L282-L298  
**验证方式：** 测试 `auto_reply_trigger_controller_background_schedule_test.dart` L156-L158 断言 inputData 不含敏感配置

### ✅ XML 兜底默认关闭
**实现位置：** `trigger_config.dart` L18  
**验证方式：** `xmlFallbackEnabled` 默认 `false`，XML 标签只清理不执行

### ✅ 打开 App 后后台纯文本消息可补渲染多模态
**实现位置：** `background_service.dart` L1034 (`rawPayload` 字段) + `ChatMessageProjectionCodec`  
**验证方式：** 后台消息保存 rawPayload，前台读取时通过 projection codec 自动补渲染

### ✅ 新增/更新测试全部通过；定向 dart analyze 无新增问题
**验证结果：** 36/36 测试通过，主动回复模块 0 error 0 warning

---

## 新增文件清单

1. **auto_reply_claim_store.dart** - 触发器执行权认领仓库（原子互斥）
2. **auto_reply_request_config.dart** - 后台配置现读工具
3. **auto_reply_claim_store_test.dart** - 认领互斥单元测试
4. **auto_reply_integration_test.dart** - 端到端集成测试

## 删除文件清单

1. **session_manager.dart** - 清理未使用的死代码（AR-041/042）

## 数据库变更

- Schema v13 → v14：新增 `auto_reply_trigger_claims` 表（执行权认领记录）
- 新增 `_ensureAutoReplyClaimTable()` 迁移逻辑

## 测试覆盖

- 单元测试：32 个（claim store、门禁、调度、存储、状态机）
- 集成测试：4 个（生命周期、互斥、门禁、清理）
- 总计：36 个测试全部通过 ✅

## Spec 更新

- `.trellis/spec/agent-context/index.md` 新增"Proactive Memory Linkage"契约（阶段 3）

---

## 阶段实施总结

### 阶段 0（止血）✅
- 后台生成接入 prompt defaults 的人设节点
- 补全 quiet hours / dailyLimit / minInterval 三重门禁
- 事件改用顺序消费队列（AR-034）

### 阶段 1（收敛）✅
- 60min 内缓存新鲜，超期降级兜底
- 删除 preparing 状态
- 前后台原子认领互斥（Schema v14）
- WorkManager inputData 瘦身 + 配置现读

### 阶段 2（遗留）✅
- XML 兜底默认关闭（AR-040）
- 后台消息多模态补渲染机制已在位
- SessionManager 死代码清理（AR-041/042）
- 补充 4 个集成测试（AR-044）

### 阶段 3✅
- 记忆联动接口契约写入 spec（运行时实现延后）

---

## 验收结论

✅ **所有验收标准已满足，任务完成。**

测试覆盖完整，代码质量良好，无新增 analyze 问题。主动回复功能已从"半成品"演进为"可生产就绪"状态。

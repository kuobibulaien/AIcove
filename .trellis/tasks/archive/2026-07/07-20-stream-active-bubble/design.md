# 技术设计：流式活跃气泡瞬态通道（v2，吸收 codex 方案审查 B1-B6）

> 审查记录：`scratch/diagnostics/方案审查_stream-active-bubble_20260720.md`。三条现状断言已全部核实属实；方案形态裁决＝壳消息＋气泡内订阅（否决列表尾独立 item / overlay）。

## 1. 现状边界（改造前）

```
_StreamPlaceholderDelivery（chat_actions_stream_placeholder.dart，part of ChatActions）
  onDelta → _scheduleFlush(180ms) → _applyState
    → _buildTimelineDescriptors(全文重分段；非分段模式产出 active descriptor)
    → _materializeTimeline(id 位置优先复用；占位条件式钉底)
    → 视觉不等 → replaceMessagesTransient(移除全部旧 id, 写入全部新消息) → 窗口通知 → 整页重建
```

Characterization 基线（test/features/chat/stream_placeholder_characterization_test.dart，7 用例已绿）：非分段 10 delta ≈13 次窗口变更；分段 ≈5 次（结构量级）；活跃尾 id 跨 flush 稳定；占位通知收敛；TTS 语序＝文本 seal→pendingAudio→文本 seal。

## 2. 目标架构

### 2.1 通道身份与所有权（B1/B3）

```
lib/src/features/chat/application/active_stream_projection.dart

ActiveStreamProjection {
  conversationId,
  generationToken(String),   // 由 ChatActions 分配（runId），跨 delivery 实例单调可辨
  writeEpoch(int),           // delivery 内次级版本（reset 递增）
  tailMessageId(String?),    // 窗口壳消息 id
  tailText(String),          // 仅来自 active descriptor（见 2.4）
  phase(thinking | streamingTail),
}

activeStreamProjectionsProvider =
  NotifierProvider<ActiveStreamProjectionsNotifier, Map<String, ActiveStreamProjection>>
```

- **单一 owner map**（codex B3 裁决二选一中取后者）：非 family；key=conversationId；只保留活跃会话条目。
- **CAS 语义**：`publish(projection)` 仅当 `(generationToken, writeEpoch)` ≥ 现值才写；`clear(conversationId, generationToken)` 仅当 token 匹配才清——旧 generation 的 clear 不得清掉新 generation（B1）。
- 生命周期：finalize/remove/interrupt/dispose → clear（带 token）；ProviderContainer dispose 自然回收；离页保活（map 常驻，条目只在流结束时移除）；A→B→A 重进恢复靠 map 条目仍在。

### 2.2 数据流分流

```
flush（_applyState）
  ├─ diff 为空（序列与视觉均不变，仅活跃尾文本增长/占位阶段变化）
  │    → 仅 publish 通道（不触碰时间线，无窗口通知）
  └─ diff 非空（结构转移）
       → 先增量写时间线（2.3），再 CAS publish 通道（2.5 顺序契约）
```

**结构转移完整表（S2）**：thinking 占位出现、占位→活跃壳换 id、首个活跃壳出现、chunk seal、揭示放行、pendingAudio 出现/回填、占位钉底 createdAt 重分配、finalize、reset/interrupt/remove。验收口径＝窗口通知数为 O(结构转移数)。

### 2.3 增量 diff 写（S1）

- removed = previous ids − next ids；
- upsert = next 中新 id ＋ 同 id 但 `_streamTimelineMessageVisuallyEqual`==false 者；
- removed 与 upsert 皆空 → 不调 cache；
- 顺序仍由 cache 侧现有 normalize（createdAt/id）决定，不依赖构造顺序。
- 测试须 spy `replaceMessagesTransient` 载荷，证明未变 id 不被重写。

### 2.4 通道文本真相源（B6）

`tailText` **只能取自 `_buildTimelineDescriptors` 产出的 active text descriptor**（已经过 `_sanitizeVisibleTextFragment`、TTS/image 标签拆分），禁止另建第二套 sanitize——未闭合 `<...`/`<image>`/trigger 标签的隐藏行为与旧投影一致。

### 2.5 交接顺序契约（B6）

| 场景 | 顺序 |
|---|---|
| 新壳出现 / 壳 id 变化 | 先写时间线（壳落位），再 publish 通道 |
| 纯文本增长 | 仅 publish 通道 |
| finalize | 先安装终态消息（时间线自洽），再 CAS clear 通道 |
| reset/interrupt/remove | 先使当前 generation 通道失效（clear），再撤壳 |

每个顺序配帧级测试：无标签泄露、无空壳闪烁、无旧壳文本回退。

### 2.6 气泡消费（B2 下半）

- `MessageBubble` 新增 `conversationId` 参数（调用点 `chat_message_list_presentation.dart` 下传；`ChatMessageList` 已持有）。
- 渲染文本块前：`ref.watch(activeStreamProjectionsProvider.select((m) { final p = m[conversationId]; return p != null && p.tailMessageId == message.id ? p : null; }))`；命中→用 `tailText`/thinking 渲染；否则壳内容。非活跃气泡因 select 结果恒 null 不重建。

### 2.7 followLatest 窄信号（B2）

纯 delta 不再改父列表入参 → 现有 `didUpdateWidget` 稳底入口失效；且「reverse 自然钉底」是未验证假设，不押注。方案：

- `ChatMessageList`（ConsumerState）`ref.listen` 通道中本会话条目的 `(tailMessageId, tailText.length, phase)` 变化，仅调度既有 `_scheduleFollowLatestViewportStabilization`——不 setState、不重建列表；
- detached/分页/程序滚动守卫沿用现有语义（`_autoScrollEnabled` 等判定不变）；
- 回归测试：通道驱动的局部增高贴底不脱离；detached 阅读锚点不移位；与键盘/bottomOverlayHeight 同帧不遮输入框。

### 2.8 开关（B5）

- `streamProjectionPolicyProvider = Provider<StreamProjectionPolicy>`（值对象含 `useActiveStreamChannel`），默认 **false 落地**；测试用两个 ProviderContainer 分别 override off/on 对照。
- 开关包住整组机制：off＝旧全量 `_applyState` ＋ 气泡不订阅通道（provider 返回空 map 即天然旁路）＋ 列表不挂窄信号监听；on＝新 diff＋通道＋气泡消费＋窄信号。旧实现代码保留至新路径全链路验收后另行清理。
- 全链路对照通过后，单独一个小改动翻默认 true（独立可 revert）。

## 3. 状态机事件口径（B4）

| 事件 | 真实入口 | 通道行为 |
|---|---|---|
| 流内 reset | `onStreamReset`（同 delivery，failover 前清屏） | writeEpoch+1；同 token CAS 覆盖 |
| 用户中断 | `ChatActions.interruptCurrentGeneration` | clear(token)；壳随恢复链路撤除 |
| 重试/重新生成 | 新 delivery（新 runId token） | 旧 token 的 update 与 clear 均不影响新流 |
| 多模型 failover | reset ＋ 可能替换 delivery | 同上两行组合 |

## 4. 兼容与风险

1. display cache / sending bypass：壳 status 仍 'sending'，行为不变；纯 delta 期间列表不重建。
2. TTS pendingAudio：结构事件；通道 delta 不得改写 AudioBlock；id 交接沿用 `chat_actions_test.dart:5306-5575` 基线。
3. 模型上下文安全：通道不进入 prepareHistory/上下文组装；commit 源仍为 raw 流文本。
4. 05-05 不变式：`_pendingRawSourceId` 共享 raw 槽位、transient 不同步 mapping——增量写路径同样遵守。

## 5. 发布与回滚

- 机制回滚＝policy override/默认值改回 false（运行时为 override、发版为改默认值＋重建——非即时 flag，如实声明）。
- 实现按「可原子 revert 的机制 commit」组织；characterization tests 分两组标注：「旧路径行为」（off 断言）与「新路径契约」（on 断言），回滚时不互相污染基线。
- 无持久化状态、无 schema 变更、无数据迁移。

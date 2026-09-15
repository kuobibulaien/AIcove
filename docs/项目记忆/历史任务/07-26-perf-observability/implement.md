# 执行计划：前端性能观测打点基建

> 依赖：`prd.md`（需求与验收）、`design.md`（技术设计）。
> 全程只装秤，不改被测对象行为——任何"顺手优化一下"的冲动都留给后续任务。

---

## 阶段 A：核心设施（无外部依赖，可独立验证）

- [ ] A1. 新建 `lib/src/features/observability/perf/perf_metrics.dart`
  - `kPerfMetricsEnabled = kDebugMode || kProfileMode` 编译期常量
  - `perfMetricsRuntimeEnabled` 运行时开关（`@visibleForTesting`）
  - 计数器字段（design §4.2 全表）
  - `DurationStats`（环形缓冲 256，记录 O(1)，分位按需算）
  - `FirstPaintRecord` + `firstPaints` 列表（上限 20）
  - `reset()` / `snapshot()`
  - **验证**：`flutter analyze` 该文件 0 问题

- [ ] A2. 新建 `lib/src/features/observability/perf/perf_frame_sampler.dart`
  - `start()`（幂等）/ `stop()` / `snapshot()`
  - warm-up 前 10 帧丢弃
  - 环形缓冲 600 帧
  - 帧预算由刷新率推导（60Hz 16.7ms / 120Hz 8.3ms）
  - 回调内只做数组写入
  - **验证**：`flutter analyze`

- [ ] A3. 新建单元测试 `test/features/observability/perf_metrics_test.dart`
  - `DurationStats` 分位数正确性（含样本数 < 缓冲上限 / 溢出环绕两种）
  - `reset()` 归零
  - `perfMetricsRuntimeEnabled = false` 时调用方短路（测调用方约定，非 PerfMetrics 内部）
  - `FirstPaintRecord` 上限 20 的丢最旧行为
  - **验证**：`flutter test test/features/observability/perf_metrics_test.dart --timeout 60s` 全绿

**阶段 A 检查点**：新增三文件，零处修改既有代码。此时 `flutter test --timeout 60s` 应仍是 623 全绿 + 新增用例。

---

## 阶段 B：重建域埋点（改动最小、守卫价值最高）

每处埋点形态统一为 design §4.1 的 if 短路，**不得**新增任何 provider watch / notifier 写入。

- [ ] B1. `chat_page.dart:966` build 计数
- [ ] B2. `chat_message_list.dart:563` build 计数（既有 `onDebugListItemCountChanged` 原样保留）
- [ ] B3. `chat_message_list_presentation.dart:277` 活跃尾 Consumer builder 计数
- [ ] B4. `chat_message_list_presentation.dart:37` `_updateListItems` 重算计数

- [ ] B5. 新建 `test/ui/features/chat/widgets/chat_message_list_perf_counters_test.dart`
  - 台架照抄 `chat_message_list_settings_select_test.dart`
  - `setUp` 调 `PerfMetrics.reset()`
  - P-01：纯 delta 期间 `activeTailConsumerBuilds` 增长、`messageListBuilds` 不增长
  - P-02：无关设置字段变化，三层均不增长
  - P-03：policy off 时通道 publish 不引起尾泡重建
  - P-04：`perfMetricsRuntimeEnabled = false` 时不累加
  - 真实 IO 包 `tester.runAsync`；显式钉 `streamProjectionPolicyProvider`
  - **验证**：新测试全绿

**阶段 B 检查点**：`flutter test --timeout 60s` 全绿。**若 P-01 或 P-02 失败，先停下报告**——那意味着 G2.1/G2.2 的既有结论与实测不符，是需要单独处理的发现，不得改断言迁就。

**回滚点**：阶段 B 结束后可独立 commit。后续阶段出问题不影响这层守卫价值。

---

## 阶段 C：首屏分段埋点

- [ ] C1. `chat_page.dart:202` initState 起计时（以 conversationId 为 key 存在途记录）
- [ ] C2. `conversation_short_window_store.dart:152` 订阅建立打点
- [ ] C3. `conversation_short_window_store.dart:158` 窗口首值产出打点
- [ ] C4. `conversation_short_window_store.dart:559` / `:567` 热/冷分叉标记
- [ ] C5. `chat_page.dart:273` 首次 `hasValue` build 打点
- [ ] C6. `chat_message_list_viewport.dart:222-223` 首次置底完成 → 首屏计时终点
- [ ] C7. `chat_page.dart:926` dispose / `:907` didUpdateWidget 丢弃在途记录

**注意**：C2/C3/C4 在 `conversation_short_window_store.dart` 内，该文件有严格的「读路径必须纯读」契约（规范 §首屏加载 第 3 条）。埋点只做计数器自增，**不得**触发任何调度、不得进入串行队列。

- [ ] C8. 首屏分段测试（在既有 widget 测试台架上加，或新建文件）
  - 热路径：内存命中时四个时间点均有值且单调不减
  - 冷路径：走 DB 时同样有值
  - 切会话：旧在途记录被丢弃，不产生半截数据
  - **验证**：全绿

**回滚点**：阶段 C 结束后可独立 commit。

---

## 阶段 D：流式埋点

- [ ] D1. `chat_actions_stream_placeholder.dart:401`/`:490` `_applyState` 双区间计时
  - 总区间
  - 排除 `_ensureTimelineBaseMs()` DB await 的纯投影区间（design §7 风险表）
- [ ] D2. `chat_actions_stream_placeholder.dart:465` 结构事件 vs 纯 delta 分流计数
- [ ] D3. `active_stream_projection.dart:105` publish 真实落地计数（注意：只在 CAS 通过并实际写 state 时计数，`:98-103` 的丢弃/去重路径不计）

- [ ] D4. 流式计数测试
  - 优先在既有 `test/features/chat/stream_placeholder_characterization_test.dart` 的 G2.1 组里加断言（该文件已有 `windowNotifyCount` / `transientReplaceCalls` 同类度量，是天然归属地）
  - 断言：100 delta 用例下 `streamPureDeltaTicks` 远大于 `streamStructuralEvents`（量化双通道契约「窗口通知数必须与结构转移数同阶」）
  - **验证**：全绿

**回滚点**：阶段 D 结束后可独立 commit。

---

## 阶段 E：调试页

- [ ] E1. 新建 `lib/src/ui/features/debug/pages/perf_monitor_debug_page.dart`
  - 结构对标 `stream_monitor_debug_page.dart`
  - `initState` 中 `PerfFrameSampler.start()`，`dispose` 中 `stop()`
  - 三组分区展示：首屏分段（warm/cold 分列）、流式、帧
  - 重置按钮 → `PerfMetrics.reset()` + 采样器重置
  - 刷新方式：1s 定时拉快照（页面自己驱动，不由埋点侧推送）
- [ ] E2. `debug_center_page.dart` 加一行 `MoeSettingsRow`（注意末项 `showDivider: false` 需要挪到新末项）
- [ ] E3. 页面 smoke 测试：能构建、能展示空态、重置按钮可点

---

## 阶段 F：收口

- [ ] F1. `flutter analyze` — 无新增 error/warning
- [ ] F2. `flutter test --timeout 60s` — 全绿（623 + 新增）
- [ ] F3. `flutter build apk --debug` — 通过（本机无 Xcode，APK 为编译门）
- [ ] F4. `/codex:review` 审代码，问题修完
- [ ] F5. spec 沉淀：`.trellis/spec/frontend/quality-guidelines.md` 新增「性能观测打点契约」一节
  - 埋点不得触发通知（一套计数器两个消费者的理由）
  - 编译期常量而非 assert（profile 模式必须保留采集）
  - `FrameTiming` 与被否决的 `currentSystemFrameTimeStamp` 的区别（design §2 的论证）
  - 首屏终点取"首次置底完成"而非"raster 完成"的口径偏差与理由
- [ ] F6. 提交前 `git diff --staged --stat` 逐一核对（交接文档教训 4：多会话并行期禁用 `git add -u` / `-A`）
- [ ] F7. 更新 journal

---

## 验证命令速查

```bash
cd /path/to/aicove/apps/aicove_flutter

flutter analyze
flutter test --timeout 60s
flutter test test/ui/features/chat/widgets/chat_message_list_perf_counters_test.dart --timeout 60s
flutter build apk --debug
```

## 停下报告的触发条件

按 AGENTS.md「遇到问题必须停」：

1. P-01/P-02 失败 —— 既有性能结论与实测不符，是需要单独定性的发现。
2. 既有 623 测试出现失败 —— 埋点意外改变了行为，必须定位而非绕过。
3. 任何埋点需要修改既有逻辑分支才能插入 —— 说明位置选错了，回来重新设计。

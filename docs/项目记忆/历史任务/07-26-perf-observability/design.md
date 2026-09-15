# 技术设计：前端性能观测打点基建

> 本文档只描述「装秤」的设计，不含任何被测对象的行为改动。
> 埋点位置全部来自本任务两路只读调研，行号截至 2026-07-26 `main` @ `a66eb5a`。

---

## 1. 核心结构

### 1.1 一套计数器、两个消费者

```
                    ┌──────────────────────────┐
   埋点调用          │   PerfMetrics（纯内存）    │
  ─────────────►    │  静态计数器 + 环形缓冲     │
                    │  零 IO、零 provider 通知   │
                    └────────┬─────────────────┘
                             │
              ┌──────────────┴──────────────┐
              ▼                             ▼
     ┌────────────────┐          ┌─────────────────────┐
     │ 测试直接读字段  │          │ 调试页 listen 快照   │
     │ expect(x, 0)   │          │ ValueNotifier 手动刷 │
     └────────────────┘          └─────────────────────┘
```

**关键约束：`PerfMetrics` 的写入路径绝不触发任何通知。** 计数器是裸字段自增，`ValueNotifier` 只在调试页**主动请求快照时**才被赋值（下拉刷新 / 定时 1s 轮询，由页面自己驱动）。这一条同时满足：

- 验收「采集写入不得触发热区 widget 的 build」；
- 规范 §首屏加载 第 2 条「通知必须以实际变化为条件」——我们干脆不发通知；
- 规范 §长列表滚动性能 第 1 条「帧阶段写 notifier 要推迟到 postFrame」——我们在帧阶段根本不写 notifier。

### 1.2 为什么不复用 `TraceStore`

| 项 | TraceStore 现状 | 对本任务的后果 |
|---|---|---|
| 落盘时机 | `record()` 每条 `_appendLine(flush: true)`（`trace_store.dart:431`） | 180ms 一次 flush + 每帧 build 计数 ⇒ IO 放大，观测自身成为卡顿源 |
| 内存上限 | 400 条环形（`:176`） | 高频前端事件会把后端 turn trace 挤出去，破坏既有排障能力 |
| 阶段模型 | `TraceStage` 闭合 enum，16 个全后端语义（`trace_models.dart:3-23`） | 扩展波及 `trace_query_service.dart:69/153-154`、trace UI stage 展示、约 15 处 `record()` 调用方 |
| 事件模型 | traceId/turnId/roundIndex/eventSeq 会话链路 | 帧指标无会话归属，塞进去语义污染 |

结论：**新起 `PerfMetrics`，与 `TraceStore` 平行共存，互不引用。**

首屏分段是唯一的低频事件，可以顺带用 `AppLogger.startTrace`（`app_logger.dart:402-414`）输出一条人类可读的层级耗时日志——但这只是**日志侧的便利**，聚合统计仍在 `PerfMetrics`，两者不互为依赖。

---

## 2. 时钟选型与对规范条款的正面回应

### 2.1 规范第 §纯渲染层长高 第 4 条否决了什么

> 动画期的结构性长高用生命周期事实静默，**禁止用帧时间戳猜时长**（codex 审查 R2：`currentSystemFrameTimeStamp` 是引擎裸时间戳——warm-up 帧跳变、不随 `timeDilation` 缩放、长帧穿透固定余量）。

该条款否决的具体做法是：**读 `SchedulerBinding.currentSystemFrameTimeStamp`，两次相减，用差值推断"动画应该已经播完了"**。否决理由是这个时间戳不可靠（预热帧跳变、不随调试时间缩放）且推断本身是猜测（长帧会穿透固定余量）。

### 2.2 本设计用什么，为什么不冲突

| 用途 | 选型 | 与该条款的关系 |
|---|---|---|
| 首屏分段耗时 | `Stopwatch`（Dart 单调时钟） | 不涉及帧时间戳。单调时钟不受墙钟跳变影响，是区间计时的标准手段。 |
| flush 投影耗时 | `Stopwatch` | 同上。 |
| 帧 build/raster 耗时 | `FrameTiming.buildDuration` / `.rasterDuration` | **不是时间戳相减**。这两个是 Flutter 引擎直接报告的实测区间（引擎在帧内自行计时后回传），语义上等价于引擎替我们跑了 Stopwatch。不做任何跨帧推断。 |

**关键区别**：被否决的是"用时间戳差值**推断另一件事的状态**"（动画是否播完）；本设计是"记录引擎报告的**该帧自身耗时**"，不推断任何状态、不驱动任何行为。

**额外防线**（对应「warm-up 帧跳变」的教训）：帧采集默认**丢弃开始采样后的前 N 帧**（N=10，可配），避开 shader warm-up 与页面切换的启动尖峰——这正是 codex §G1.1「排除 shader warm-up」的要求。

---

## 3. 模块划分与文件清单

### 3.1 新增文件

| 文件 | 职责 |
|---|---|
| `lib/src/features/observability/perf/perf_metrics.dart` | 纯内存计数器与快照模型。零依赖（只依赖 `foundation`），可被任何层导入而不产生循环。 |
| `lib/src/features/observability/perf/perf_frame_sampler.dart` | `FrameTiming` 采集器：注册/注销 `addTimingsCallback`、环形缓冲、分位数计算。 |
| `lib/src/ui/features/debug/pages/perf_monitor_debug_page.dart` | 「性能监控」调试页。对标 `stream_monitor_debug_page.dart` 结构。 |

放在 `observability/perf/` 子目录而非平铺，是为了和既有四个 trace 文件在物理上就分清界限。

### 3.2 修改文件（埋点接入，每处都是 1~3 行）

| 文件 | 埋点 |
|---|---|
| `lib/src/ui/features/chat/pages/chat_page.dart` | `:202` initState 起首屏计时；`:966` build 计数；`:273` 首次 hasValue 打点 |
| `lib/src/ui/features/chat/widgets/chat_message_list.dart` | `:563` build 计数（既有 `onDebugListItemCountChanged` 保留不动） |
| `lib/src/ui/features/chat/widgets/chat_message_list_presentation.dart` | `:277` 活跃尾 Consumer builder 计数；`:37` `_updateListItems` 重算计数 |
| `lib/src/ui/features/chat/widgets/chat_message_list_viewport.dart` | `:222-223` 首次置底 → 首屏计时终点 |
| `lib/src/features/chat/services/conversation_short_window_store.dart` | `:152` 订阅建立；`:158` 首值产出；`:559` 热命中 / `:567` 冷路径分叉 |
| `lib/src/features/chat/chat_actions_stream_placeholder.dart` | `:401`/`:490` `_applyState` 区间计时；`:465` 结构事件 vs 纯 delta 分流计数 |
| `lib/src/features/chat/application/active_stream_projection.dart` | `:105` publish 真实落地计数 |
| `lib/src/ui/features/debug/pages/debug_center_page.dart` | 加一个 `MoeSettingsRow`（注意末项 `showDivider: false` 要挪位） |

**不改** `TraceStore` / `TraceStage` / `AppLogger` / drift schema。

---

## 4. `PerfMetrics` 契约

### 4.1 开关：编译期 + 运行时双层

```dart
/// 编译期总闸：release 下整个采集被树摇掉。
const bool kPerfMetricsEnabled = kDebugMode || kProfileMode;

/// 运行时开关：debug 下做 on/off 对照实验用。默认 true。
@visibleForTesting
bool perfMetricsRuntimeEnabled = true;
```

所有埋点调用的形态统一为：

```dart
if (kPerfMetricsEnabled && perfMetricsRuntimeEnabled) {
  PerfMetrics.recordXxx(...);
}
```

`kPerfMetricsEnabled` 是编译期常量，release 下整个 if 块被 dart2native 消除，满足「release 完全关闭（编译期常量短路，不只是运行时 if）」。

> **不用 `assert(() {...; return true;}())`**：虽然项目里有此先例（`chat_message_list_viewport.dart:137-142`），但 assert 只在 debug 生效，**profile 模式下也会被剥离**——而性能基线必须在 profile 模式测（debug 模式的性能数据没有参考价值）。因此用 `kDebugMode || kProfileMode` 常量。

### 4.2 计数器分组

```dart
abstract final class PerfMetrics {
  // ── 重建域计数（测试守卫主用）─────────────────
  static int chatPageBuilds = 0;
  static int messageListBuilds = 0;
  static int listItemsRecomputes = 0;      // _updateListItems 全量重算
  static int activeTailConsumerBuilds = 0;  // 活跃尾气泡 Consumer 重建

  // ── 流式 ───────────────────────────────────
  static int streamFlushCount = 0;
  static int streamStructuralEvents = 0;    // :465 判定为真的次数
  static int streamPureDeltaTicks = 0;      // 判定为假（纯 delta）的次数
  static int activeStreamPublishLanded = 0; // CAS 真正写入 state 的次数
  static final DurationStats flushProjection = DurationStats(); // _applyState 区间

  // ── 首屏 ───────────────────────────────────
  static final List<FirstPaintRecord> firstPaints = <FirstPaintRecord>[]; // 上限 20

  static void reset() { ... }               // 调试页与测试 setUp 共用
  static PerfSnapshot snapshot() { ... }     // 拷贝出值对象，供 UI 展示
}
```

`DurationStats` 内部持环形缓冲（上限 256 个样本）+ 计数，提供 p50/p95/p99/max。分位数**按需计算**（快照时排序），不在每次记录时维护有序结构——记录路径必须是 O(1) 纯写。

### 4.3 首屏记录模型

```dart
class FirstPaintRecord {
  final String conversationId;
  final bool warm;                 // 内存快照命中（:559）= true
  final int? tSubscribeMs;         // initState → 订阅建立
  final int? tFirstValueMs;        // initState → 窗口首值 yield
  final int? tFirstDataBuildMs;    // initState → 首次 hasValue build
  final int? tBottomAnchoredMs;    // initState → 首次置底完成（终点）
}
```

四个点对齐 codex §G1.1「路由进入/订阅建立、热快照首值、首个消息 layout、首个 raster 完成」。

**关于第四点的口径修正**：codex 原文说「首个 raster 完成」。`_ensureInitialBottomPosition` 的 postFrame（`chat_message_list_viewport.dart:222-223`）发生在 layout 之后、raster 完成之前。取它而非真正的 raster 完成，理由：
1. 它是「消息可见且已定位到正确位置」的最准确业务信号——用户感知的"加载完了"就是这一刻；
2. 真正的 raster 完成时刻只能从 `FrameTiming` 拿，而 `FrameTiming` 不携带业务上下文（不知道这帧属于哪个会话的首屏），关联需要额外的帧序号对账机制，复杂度不成比例。

`FrameTiming` 的 raster 数据仍在帧采样器里独立采集，只是不与首屏分段强关联。此偏差在 spec 沉淀时记录。

### 4.4 跨会话与生命周期

- 首屏计时以 `conversationId` 为 key 存"在途"记录；`ChatPage.dispose`（`chat_page.dart:926`）时若仍在途则丢弃该条（不计入统计，避免半截数据污染分位）。
- 切会话（`didUpdateWidget` `:907-924`）视为新一轮首屏，旧在途记录丢弃。
- `firstPaints` 列表上限 20 条，超出丢最旧。

---

## 5. 帧采样器契约

```dart
class PerfFrameSampler {
  void start();   // 注册 addTimingsCallback；重置 warm-up 计数
  void stop();    // 注销
  FrameStats snapshot();
}
```

- **不常驻**：仅在性能调试页打开时 `start()`，页面 dispose 时 `stop()`。这是「观测自身开销有上限」的主要保障——不看的时候完全没有回调。
- **warm-up 丢弃**：`start()` 后前 10 帧不计入（对应 codex「排除 shader warm-up」）。
- **环形缓冲**上限 600 帧（60Hz 下约 10 秒窗口），内存有界。
- **帧预算按刷新率推导**：从 `View.of(context).display.refreshRate` 取，60Hz → 16.7ms，120Hz → 8.3ms。阈值不写死（codex §G1.1 明确要求区分刷新率）。
- `addTimingsCallback` 回调内**只做数组写入**，不做排序、不做通知、不碰 provider。

---

## 6. 测试策略

沿用「文件内自建台架」约定（项目 98 个测试文件无一共享 helper），不新建 helper 目录。

### 6.1 新增测试文件

`test/ui/features/chat/widgets/chat_message_list_perf_counters_test.dart`

台架照抄 `chat_message_list_settings_select_test.dart`（292 行，最短最易复用）：`_FakePathProviderPlatform` + `_FakeAppSettingsNotifier` + `ProviderScope overrides` 显式钉 `streamProjectionPolicyProvider`。

用例：

| 编号 | 断言 |
|---|---|
| P-01 | 流式纯 delta 期间：`activeTailConsumerBuilds` 增长，`messageListBuilds` **不增长**（双通道契约的直接量化守卫） |
| P-02 | 无关设置字段变化（如音量）：三层计数均不增长 |
| P-03 | `streamProjectionPolicyProvider` off 时：通道 publish 不产生 `activeTailConsumerBuilds` 增长（对应规范 §流式投影双通道契约 第 5 条的 off 严格回滚面） |
| P-04 | `PerfMetrics.reset()` 后所有计数归零，且 `perfMetricsRuntimeEnabled = false` 时埋点不再累加 |

`setUp` 里 `PerfMetrics.reset()`，避免用例间串扰。真实 IO 包 `tester.runAsync`（规范 §Testing Requirements）。

### 6.2 既有测试的兼容性

新增埋点**不改变任何既有行为**，623 个既有测试应全绿。若有测试因计数器全局状态串扰而失败，说明该测试隐式依赖了全局单例——需具体分析，不得靠改断言迁就（规范教训：修的应是真 bug）。

---

## 7. 风险与化解

| 风险 | 化解 |
|---|---|
| 埋点本身引入重建 | 计数器为裸字段自增，写入路径无 `ValueNotifier`/provider 触碰。P-01/P-02 测试直接守卫此点。 |
| 静态可变状态导致测试串扰 | 所有测试 `setUp` 调 `PerfMetrics.reset()`；`reset()` 与 `perfMetricsRuntimeEnabled` 均 `@visibleForTesting`。 |
| `_applyState` 区间计时把 await 时间算进去 | `_applyState` 内含 `_ensureTimelineBaseMs()` 的 DB await（`:1129-1139`）。**分两个计时区间**：总区间与「排除首次 DB base 加载」的纯投影区间分别记录，避免冷启动首次 flush 污染分位数。 |
| profile 模式下 `kProfileMode` 判断遗漏平台差异 | `kDebugMode`/`kProfileMode` 是 `foundation` 提供的跨平台常量，无平台分支需求。不涉及 `dart:io`/`dart:html`，无需条件导入。 |
| 帧采样器忘记 stop 导致常驻 | 页面 `dispose` 中 stop；另在 `start()` 中做幂等保护（重复 start 不重复注册）。 |
| 与并行会话的集成冲突 | 本任务改动集中在新文件 + 8 处 1~3 行插入，不改任何既有逻辑分支。提交前 `git diff --staged --stat` 逐一核对（交接文档教训 4）。 |

---

## 8. 兼容与回滚

- 对外 API 无变更；既有 `onDebugListItemCountChanged` / `onDebugAutoScrollRequested` 钩子保留原样不动。
- 无 DB schema 变更、无新增依赖、无 pubspec 改动。
- 回滚 = 反向应用本任务的原子 commit（不用 `git checkout --`，交接文档教训 4/5 与 07-19 §8 一致）。
- 运行时可用 `perfMetricsRuntimeEnabled = false` 即时关闭全部采集，无需重启。

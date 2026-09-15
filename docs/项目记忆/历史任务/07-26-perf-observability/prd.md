# 前端性能观测打点基建

## 背景

前端性能治理已推进到路线图阶段 1。此前 07-13（滑动优化）、07-19（首屏缓存）、07-20（流式双通道、入场锚定）四轮改动均已落地，但**收益无法量化**——所有结论建立在 widget 测试的行为断言与主观感受之上，没有任何耗时/帧率/重建次数的实测数据。

路线图 `scratch/diagnostics/架构迭代路线图_v2_20260719.md` 把「分段 trace 与重建域观测」定为阶段 1 的 P0 级基建；codex 对审意见（`架构迭代路线图_codex意见_20260719.md` §G1.1）进一步要求它先于后续性能改动，并给出了明确的事件边界定义与验收口径。

现状核实（本任务调研结论）：

- 项目已有 `lib/src/features/observability/`（`TraceStore`/`TraceEvent`），但 16 个 `TraceStage` **全是后端 turn/round/tool 语义**，不覆盖任何 UI 渲染。
- 全仓 **零** `FrameTiming` / `addTimingsCallback` / `dart:developer` 用法——前端渲染观测是绿地。
- 已有两处可复用的既有范式：
  - **测试计数器范式**：`ConversationTimelineCache` 的 `@visibleForTesting int debugXxxCount`（07-19 沉淀，`conversation_short_window_store.dart:83-95`）、`ChatMessageList.onDebugListItemCountChanged` build 计数钩子（`chat_message_list.dart:348-352`、`:624-629`；规范§全局设置订阅粒度 第 3 条钦定为守卫模式）。
  - **运行时采集范式**：`StreamMonitorService`（`stream_monitor_service.dart`，静态类 + `ValueNotifier<Snapshot>` + SharedPreferences 落盘 + 配套调试页挂在「调试中心」）。

## 本次目标

建立两层观测能力，**都复用上述既有范式，不另起门户**：

### 第一层：测试守卫计数器（防回潮）

在聊天页热区补齐 build 计数与通知计数的 `@visibleForTesting` 钩子，使「某操作不该引起某层重建」这类性能契约可被 `flutter test` 自动断言。

覆盖三个重建域：`ChatPage` 壳（`chat_page.dart:966`）、`ChatMessageList`（`chat_message_list.dart:563`）、活跃尾气泡（`chat_message_list_presentation.dart:277` 的 Consumer builder，比 `MessageBubble.build` 更精确——只有尾泡命中）。列表层已有 `onDebugListItemCountChanged`，本次补齐另两层并统一命名。

### 第二层：运行时性能采集（拿基线）

新增 `PerfMonitorService`（对标 `StreamMonitorService` 骨架）与「性能监控」调试页（挂入调试中心 `debug_center_page.dart`），采集三类场景：

1. **首屏分段**：进入会话到消息可见，分段计时。阶段边界对齐 codex §G1.1 的四点定义，落到本项目的具体位置：路由进入（`chat_page.dart:202` initState）、订阅建立（`conversation_short_window_store.dart:152`）、窗口首值产出（`:158` yield）、首次置底完成（`chat_message_list_viewport.dart:222-223` `_ensureInitialBottomPosition` 的 postFrame 内）。热路径（内存快照命中 `:559`）与冷路径（走 DB `_loadSnapshot`）分列统计。
2. **流式**：每次 flush 的投影耗时（`chat_actions_stream_placeholder.dart:401-490` `_applyState` 区间）、结构事件数与纯 delta 数分流计数（分流判定点 `:465`）、通道 publish 落地次数（`active_stream_projection.dart:105` 真实写入点）、三层 build 次数。
3. **滑动/帧**：基于 `FrameTiming` 的 build/raster 耗时分位数、超预算帧数、掉帧比例。


## 非目标（本次不做）

- **不做任何性能优化改动**。本任务只装秤，不动被测对象的行为——这是与后续 P1 任务的硬边界。
- 不引入任何第三方 APM / 崩溃采集依赖（sentry / firebase 等）。
- 不做内存与 ImageCache 峰值采集（`FrameTiming` 不提供，需另外的 API 面，独立评估后另立任务）。
- 不做自动化性能回归门（路线图阶段 4，需先有本任务产出的基线数据）。
- 不覆盖 Web 平台验收（2026-07-20 用户裁决：Web 当前不是目标；但代码不得因平台差异编译失败）。
- 不改 `TraceStore` / `TraceStage` 的既有 schema 与语义。

## 验收标准

### 功能

- [ ] `ChatPage`、`ChatMessageList`、活跃尾 `MessageBubble` 三层各有 `@visibleForTesting` build 计数钩子，命名遵循既有 `onDebugXxx` / `debugXxxCount` 约定。
- [ ] 新增守卫测试：至少覆盖「流式纯 delta 期间三层 build 计数的预期增长关系」与「无关设置字段变化时三层均不增长」两组断言。
- [ ] 「性能监控」调试页可从调试中心进入，展示首屏分段、流式、帧三组指标，支持重置。
- [ ] 首屏分段计时四个边界点均有数据，warm/cold 分列。
- [ ] 流式指标含：flush 次数、单次 flush 投影耗时分位、窗口通知次数、三层 build 次数。
- [ ] 帧指标含：采样帧数、build/raster 耗时 p50/p95/p99、超预算帧数与比例。

### 开销上限（路线图硬门：「观测自身开销有上限」）

- [ ] release 模式下采集**完全关闭**（编译期常量短路，不只是运行时 if）。
- [ ] 采集开启时不引入任何 UI 重建：采集写入不得触发热区 widget 的 build。
- [ ] 帧采样有固定上限的环形缓冲，内存占用有界。
- [ ] 落盘为节流写入，不在每帧/每 flush 触发 IO。

### 规范符合（`.trellis/spec/frontend/quality-guidelines.md` 硬约束）

- [ ] 打点的旁路副作用不使用 build 期 `ref.listen`，改用 `listenManual` 长驻订阅（§流式投影双通道契约 第 3 条）。
- [ ] 打点不在滚动通知中触发 `setState`；帧阶段写值推迟到 `addPostFrameCallback`（§长列表滚动性能 第 1 条）。
- [ ] 时长测量不使用引擎裸帧时间戳 `currentSystemFrameTimeStamp`（§纯渲染层长高 第 4 条的裁决理由）——见 design.md 对该条款的正面回应。
- [ ] 打点不寄生在 `peek`/`watch` 读路径上（§首屏加载 第 3 条「读路径必须纯读」）。
- [ ] 新测试沿用「文件内自建台架」约定，不新建共享 helper 目录。
- [ ] 新测试显式钉 `streamProjectionPolicyProvider`，不依赖全局默认（§流式投影双通道契约 第 5 条）。

### 工程

- [ ] `flutter analyze` 无新增 error/warning。
- [ ] `flutter test --timeout 60s` 全绿（当前基线 623 通过）。
- [ ] `flutter build apk --debug` 通过（本机无 Xcode，APK 构建为编译门）。
- [ ] 本任务产出的观测契约写入 `.trellis/spec/frontend/quality-guidelines.md`。

### 显式 waiver

- 真机基线数据采集（在一加 13T 上跑三套场景并记录数值）**不属于本任务验收范围**——本任务交付的是采集能力，数据采集本身依赖设备到位，与 `07-13-chat-scroll-perf` 的真机验收合并进行。

## 自主决策（AI 设计，供扫读否决）

- **一套计数器、两个消费者**（相对初稿的简化）：不做「测试计数器」与「运行时采集」两套独立设施，而是共用同一批纯内存计数器——测试直接读字段断言，调试页 listen 同一个 `ValueNotifier` 展示。理由：采集层本就设计为纯内存零 IO，测试再造一套只会产生两份需要同步维护的真相。
- **不复用 `TraceStore` 承载高频指标**。理由有二：(a) `TraceStore.record()` 每条同步刷盘（`trace_store.dart:431` `flush: true`），180ms 一次的 flush 打点或每帧 build 计数会造成 IO 放大；(b) 内存镜像仅 400 条上限（`:176`），高频事件会把后端 turn trace 挤出去。`TraceStage` 是闭合 enum，扩展它还会波及约 15 处既有调用方与 trace UI。
- **首屏分段例外**：首屏是低频事件（每次进入会话一条），可考虑复用既有 `AppLogger.startTrace` 的 `TraceLogger`（`app_logger.dart:436-584`，已有 note/startChild/end 的层级计时能力，`chat_actions.dart` 在用）——但仅作为可读日志输出，聚合统计仍走内存计数器。design.md 定最终形态。
- **时钟用 `Stopwatch`（单调时钟）而非 `DateTime.now()` 或帧时间戳**。这是对规范「禁止用帧时间戳猜时长」条款的正面回应：该条款否决的是用 `currentSystemFrameTimeStamp` 推断动画时长；`FrameTiming` 的 `buildDuration`/`rasterDuration` 是引擎直接报告的实测区间而非时间戳差值，属于不同性质，可用——design.md 展开论证。
- **开关用编译期常量 + 运行时开关双层**：`kDebugMode || kProfileMode` 编译期短路保证 release 零成本，其上再叠一个运行时开关供 debug 模式下手动关闭以做对照实验。
- **帧采集挂在 `SchedulerBinding.instance.addTimingsCallback`**，只在性能页打开或显式开启时注册，不常驻。

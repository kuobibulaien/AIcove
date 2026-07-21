# Quality Guidelines

> Code quality standards for frontend development.

---

## Overview

<!--
Document your project's quality standards here.

Questions to answer:
- What patterns are forbidden?
- What linting rules do you enforce?
- What are your testing requirements?
- What code review standards apply?
-->

(To be filled by the team)

---

## Forbidden Patterns

<!-- Patterns that should never be used and why -->

(To be filled by the team)

---

## Required Patterns

<!-- Patterns that must always be used -->

### 长列表滚动性能（聊天消息列表等）

以下为 2026-07-13 排查聊天列表滑动卡顿后沉淀的硬约束，违反会直接导致掉帧：

1. **滚动派生状态禁止进 `setState`。** 滚动通知（`ScrollUpdateNotification` 等）每个拖动帧触发一次；若在其中 `setState`，整个列表 widget 每帧全量 rebuild（重算分段、重建 sliver delegate、重绘所有可见气泡）。仅服务局部 UI（如「回到底部」按钮显隐）的派生状态，必须用 `ValueNotifier` + `ValueListenableBuilder` 局部消费，让滚动帧只重建那一个小部件。
   - 反例：`_manualDetachedDistanceToBottom` 曾是每帧 `setState` 的 double 字段（已废除）。
   - 正例：`_showJumpToBottom`（`ValueNotifier<bool>`），滚动回调只写布尔、不 `setState`。见 [chat_message_list_viewport.dart](../../../apps/aicove_flutter/lib/src/ui/features/chat/widgets/chat_message_list_viewport.dart) 的 `_syncJumpToBottomVisibility`。
   - 在 build/layout/animation 帧阶段（`persistentCallbacks`/`transientCallbacks`/`midFrameMicrotasks`）写 notifier 值，要推迟到 `addPostFrameCallback`，避免 markNeedsBuild during build；同一帧多个通知用一个 scheduled 标志合并，只注册一次回调。
   - 程序化滚动若用 `_isProgrammaticScroll` 守卫吞掉同步，结束时（清标志处）必须补一次同步，否则局部状态可能永久残留。

2. **列表内图片必须按显示尺寸降采样解码。** 原图直接解码会把数百万像素 bitmap 塞进 ImageCache，滚动进入新缓存区时产生解码/纹理上传尖峰。
   - 照片：`Image.file(cacheWidth:)` / `CachedNetworkImage(memCacheWidth:)` / `ResizeImage.resizeIfNeeded(width, null, provider)`，宽度 = 实际显示宽 × `MediaQuery.devicePixelRatioOf(context)`。
   - 头像：按固定显示尺寸（如 42px）× dpr 限制。
   - **全屏预览 / 画廊 / Hero 用的 `ImageProvider` 必须保持原图**，只对列表内显示的 `Image` widget 降采样，否则放大后模糊。

3. `CachedNetworkImage` 的 `memCacheWidth` 只控内存解码，不改磁盘缓存；不要顺手设 `maxWidthDiskCache`/`maxHeightDiskCache`。

4. **删 `setState` 前先确认没有隐式依赖它的"顺带稳定化"。** 长列表里一次 `setState` 除了刷新它名义上的状态，还会顺带触发整棵列表 rebuild——某些滚动/流式对齐逻辑（如 element 复用、`findChildIndexCallback` 对齐）可能**隐式依赖**这次 rebuild 才能正确收敛。把逐帧 `setState` 改成局部 `ValueNotifier` 时，必须区分：
   - **高频路径（拖动逐帧）**：这是卡顿主因，切断 setState 改走 notifier。
   - **低频路径（ScrollEnd、方向切换、流式内容稳定化）**：保留 setState，维持旧的稳定化 build 语义。
   本项目 `_updateManualDetachedDistanceToBottom({bool isDragFrame})` 就是这样分流的。
   - **务必跑 widget 测试验证**：这类隐式契约静态审查（自查 + 外部模型双审）都抓不到，只有真实 widget 测试能暴露。本次两个回归（`轻微手势脱离`、`流式气泡锚点 identical`）都是 `flutter test` 才发现的。

5. **滚动派生的显隐阈值用"手势时刻采样值"，不要用任意时刻的实时几何值。** `reverse:true` + `center` 双 sliver 列表的 `position.pixels - minScrollExtent` 在内容被动变化（如新消息撑高）时会算出很大的几何值，若据此实时判断按钮显隐会误触发。正确做法是保留一个仅由用户滚动事件更新、带去重的采样字段（本项目 `_manualDetachedDistanceToBottom`）作为显隐输入。

### 首屏加载与缓存后台维护（时间线缓存等）

以下为 2026-07-19 排查「进入聊天页记录要等一会儿才显示」后沉淀的硬约束（根因：时间线缓存的图片尺寸升级在主 isolate 整图解码、失败永不收敛且自激循环、慢任务与首屏读取共用串行队列）。完整契约与修复设计见 `.trellis/tasks/07-19-chat-first-paint-cache/design.md`（v4，经 codex 五轮审查定稿）。

1. **主 isolate 禁止整图解码。** 纯 Dart `image` 包的 `decodeImage` 对数百万像素图要几百毫秒到几秒，放在主 isolate 会直接卡首帧/掉帧。需要图片元数据（宽高等）时：原生平台用 `Isolate.run` 包裹的后台探测（头信息优先、整图回退、字节上限在**大块分配前**预检）；Web 无 isolate，用条件导入的桩静默降级，绝不能退回主线程解码。正例：[image_dimension_probe/](../../../apps/aicove_flutter/lib/src/features/chat/services/image_dimension_probe/)。

2. **后台维护任务必须收敛，通知必须以实际变化为条件。** 「缺元数据→补一次」类维护若失败后无终态标记，会每次读缓存都重跑；若完成后无条件广播变更，会触发「通知→重读→再调度」自激循环。硬规则：
   - 失败来源记终态（attempted，按**稳定来源身份**如 raw id＋内容指纹标识，不能用会漂移的投影 UUID）；
   - 无实际变化的维护轮**静默结束**：不替换缓存、不写库、不发通知；
   - 派生成功的结果写回持久层（本项目：宽高 CAS 写回 `message_blocks.data`），否则重启后重复付费；
   - 淘汰终态记录时不得逐出「当前数据中仍缺元数据的活跃来源」，否则逐出-重探测死循环。

3. **读路径必须纯读。** `peek`/`watch` 首值这类读接口不得顺带调度维护任务，也不得排入与写库/维护共用的串行队列——热缓存命中就直接返回。订阅型接口要**先建立（缓冲）订阅、再取首值**，否则「首值与监听建立之间」完成的变更会丢通知，UI 停在旧值。

4. **CAS 写回防并发污染。** 后台任务把探测结果写回 DB 时，探测期间行可能已被外部写路径替换。写回必须带乐观锁（where 含 data 原文全等）并校验受影响行数；全部 stale 时重读行按来源精确比较——来源未变（仅其他字段变了）就用新原文重试一次，来源已变才丢弃，否则同来源会被终态标记永久压死。

### 全局设置 Provider 的订阅粒度（2026-07-20 沉淀）

`appSettingsProvider` 是全应用共享的大对象；页面/大型列表整颗 `ref.watch(appSettingsProvider)` 会让任何一个设置字段变化（音量、TTS 开关…）重建整页/整列表。硬规则：

1. **热区 widget（聊天页、消息列表等）只允许字段级订阅**：`ref.watch(appSettingsProvider.select((s) => s.valueOrNull?.某字段))`；一个 widget 用几个字段就写几个 select。正例：[chat_message_list.dart](../../../apps/aicove_flutter/lib/src/ui/features/chat/widgets/chat_message_list.dart) 的 `uiScaleFactor` / `messageFormatConfig`，[chat_page.dart](../../../apps/aicove_flutter/lib/src/ui/features/chat/pages/chat_page.dart) 的 `chatBackgroundColor`。
2. **select 的字段类型必须有值相等性**。配置类（如 `MessageFormatConfig`）若不实现 `==`/`hashCode`，settings 每次重建新实例时 select 照样触发重建，粒度优化失效。新增配置类必须实现值相等（含 List 字段逐项比较）。
3. 守卫测试模式：用 `ChatMessageList.onDebugListItemCountChanged` 之类的 build 计数钩子断言「无关字段变化 build 计数不增长、相关字段变化必须增长」。正例：`test/ui/features/chat/widgets/chat_message_list_settings_select_test.dart`。

### 流式投影双通道契约（2026-07-21 沉淀，任务 07-20-stream-active-bubble）

流式期间 UI 投影分两条通道，禁止回退到「每 flush 全量替换时间线」的旧模式：

1. **结构转移走时间线**（增量 diff 写：removed=id 差集、upsert=新 id/视觉变化；空 diff 不触 cache）：占位出现/钉底、壳出现/换 id、chunk seal、揭示放行、pendingAudio、finalize、reset/interrupt。窗口通知数必须与结构转移数同阶（守卫：characterization 载荷 spy 与 100 delta 用例）。
2. **活跃尾文本增长走瞬态通道**（`activeStreamProjectionsProvider`，单 owner map）：`(generationSeq=runId, writeEpoch)` 字典序 CAS，旧流 publish/clear 均不得影响新流；`tailText` 只能取自物化管线的 active descriptor（已 sanitize），禁止另建第二套解析；顺序契约＝先写时间线后 publish、reset/remove 先 clear 再撤壳。
3. **消费端**：气泡在列表 presentation 层包 Consumer select 按 (conversationId, tailMessageId) 命中；列表用 `listenManual` 长驻窄信号（仅同尾同相位文本增长触发）只调度视口稳底——纯 delta 期间不 rebuild widget 的场景**禁止依赖 build 期 `ref.listen`** 做旁路副作用（首个变化后可能失联，实测踩坑）。
4. **首次出现 vs 增长的分工**：壳首次出现是结构事件，由 didUpdateWidget 稳底路径负责；窄信号只管增长步。窄信号稳底必须带多帧＋长尾（260ms）重试——布局下一帧生效且流末尾无后续信号，实测单次调度留 ~14px 残差。
5. **开关语义**：`streamProjectionPolicyProvider` off＝严格回滚面——机制分流、气泡 Consumer、列表订阅整组关闭，off 子树与旧实现一致（守卫：settings_select「off 下通道发布不重建/不上屏」）。基线测试必须显式钉 policy，不得依赖全局默认。

### 纯渲染层长高与入场收敛窗（2026-07-21 沉淀，任务 07-20-chat-entry-bottom-anchor）

进入会话后表情/图片异步解码长高、字体加载、视口尺寸变化等**纯渲染层 extent 变化不产生 didUpdateWidget**，follow-latest 的稳定化收不到信号，列表会停在「差一段」的位置。修复契约：

1. **唯一正统信号是 `ScrollMetricsNotification`**：它**不是** `ScrollNotification` 子类，必须独立挂 `NotificationListener`；框架在帧后 microtask 合并派发，此时挂普通 post-frame **不保证有下一帧**——处理器须当场 `jumpTo`（自会请求新帧），不做 debounce（latest state wins＋距离阈值幂等短路；jumpTo 只改 pixels 不改内容尺寸，不自激）。
2. **消息追加与纯渲染层长高在 metrics 层完全同构，不可无差别重锚。** 贴底时新 AI 消息不拉底是既有产品裁决（auto_scroll_guard 锁定；只有同尾可行动布局变化、输入区高度变化、pinLatestTail 才稳底）。重锚必须收窄到**入场收敛窗**：初始置底开窗；首次实质性结构变化/用户手势/历史分页锁一次性关窗；切会话复位重开。窗内位移定义上只能来自纯渲染层。
3. **关窗判据＝有序消息 ID 全序列逐位比较**（codex 审查 R1：只比 length/首尾 id 会漏判等长中间替换/重排）；**列表实例变化但 ID 结构等同的刷新不得关窗**——真机上入库回流常发同内容新实例列表，误关则修复失效。contextStart 类 nullable 锚点先 trim 规范化再比较。
4. **动画期的结构性长高用生命周期事实静默，禁止用帧时间戳猜时长**（codex 审查 R2：`currentSystemFrameTimeStamp` 是引擎裸时间戳——warm-up 帧跳变、不随 `timeDilation` 缩放、长帧穿透固定余量）。正例：`AnimatedMessageItem.onFinished`＋serial 对账；完成回调须经 post-frame＋`scheduleMicrotask` 延迟失效，才能存活过完成帧自身的 metrics 通知（通知的 microtask 在布局期入队，早于 post-frame 里再入队的 microtask）。
5. 实现与测试全貌见 [chat_message_list_viewport.dart](../../../apps/aicove_flutter/lib/src/ui/features/chat/widgets/chat_message_list_viewport.dart) 的 `_handleScrollMetricsNotification` 与 `test/ui/features/chat/widgets/chat_message_list_metrics_reanchor_test.dart`（10 用例：核心重锚/多次长高/脱离/分页/视口/负向锁裁决/R1 正反判据/空时间线动画/programmatic follow-up）。

---

## Testing Requirements

### widget 测试中的真实 IO 必须包 `tester.runAsync`（2026-07-20 沉淀）

`testWidgets` 运行在 FakeAsync zone：真实的文件/网络 IO Future **永远不会完成**，`await` 它会让单个用例挂满超时（本项目曾有测试因此每次挂约 10 分钟拖慢全套）。硬规则：

1. 测试体里凡是真实 IO（`Directory.createTemp`、读写文件、`clearPersistent` 之类的持久化清理），必须包在 `await tester.runAsync(() async { ... })` 里。
2. 被测 widget 内部 fire-and-forget 的 IO 不受影响（没人 await 它），无需处理。
3. 跑测试统一带 `--timeout 60s`（或按需更短），让挂起用例快速失败而不是拖满默认超时。
4. 无断言、纯 print 的调试测试不允许提交；调试完即删。

### finder 默认 skipOffstage 会漏掉「已构建未上台」的组件（2026-07-21 沉淀）

`find.byType`/`find.byWidgetPredicate` 默认 `skipOffstage: true`，沿 `debugVisitOnstageChildren` 遍历——**滚动列表 cacheExtent 区（已构建未绘制）的子项与高度为 0 的子项（如入场动画 `SizeTransition` 卡在第 0 帧）都会被判为 offstage 而「隐身」**，finder 返回 0 但组件和其中的图片解码链路其实全程健在。曾造成两个测试用例被误判为「组件消失」并长时间排障。硬规则：

1. 断言「组件是否存在/尺寸如何」而非「是否可见」时，finder 显式传 `skipOffstage: false`。
2. 诊断输出（dump 树内组件清单）同样要 `skipOffstage: false`，否则 dump 本身也会漏报。
3. `tester.drag` 松手带惯性速度（bouncing 物理会 fling 出 cacheExtent 使组件真被回收）；需要精确位移时用手工手势：分步 `moveBy`＋静置超过速度采样窗（>100ms）再 `up()`，抬手速度≈0。

(其余待补充)

---

## Code Review Checklist

<!-- What reviewers should check -->

(To be filled by the team)

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

---

## Testing Requirements

<!-- What level of testing is expected -->

(To be filled by the team)

---

## Code Review Checklist

<!-- What reviewers should check -->

(To be filled by the team)

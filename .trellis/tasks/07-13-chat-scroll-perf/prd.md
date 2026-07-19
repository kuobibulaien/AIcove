# 聊天消息列表滑动卡顿优化

## 背景

聊天页消息列表滑动容易卡顿。已由主会话（Claude）与 codex 两条独立只读诊断线交叉验证，结论一致：滑动卡顿由多因叠加，头号主因是「拖动时逐帧 setState 重建整个列表」。

诊断报告（含全部嫌疑项与行号证据）见对话记录，核心结论：

- **主因**：用户手指拖动期间（`ScrollUpdateNotification.dragDetails != null`），位移变化 > 0.5px 就更新 `_manualDetachedDistanceToBottom` 并 `setState`，导致整个 `ChatMessageList` 每帧重建。该状态实际只用于「回到底部」按钮的显隐阈值判断，却把每一帧的精确距离塞进了触发全列表重建的 State。
- 被主因放大的连带开销：每帧全量重算 `_splitListItems`/`_decorateSectionsWithTopicDivider`、每帧新建两个 `SliverChildBuilderDelegate`（`shouldRebuild` 恒 true）、气泡 `MoeG2Decoration` 每帧重算 squircle 路径。
- 独立开销：图片/头像按原图分辨率解码，无 `cacheWidth`/`ResizeImage`（42px 头像可能留几百万像素 bitmap）。

## 本次目标（MVP）

只修「性价比最高、可干净切断」的两刀，其余留给后续真机 profile 后决定：

1. **第一刀**：把「回到底部」按钮的显隐状态从整列表的逐帧 setState 中剥离，改用独立的 `ValueNotifier<bool>` + `ValueListenableBuilder`。拖动逐帧只更新按钮监听器，不再重建整个 `ChatMessageList`。此刀同时消除主因放大的分段重算、delegate 重建、气泡路径重算的每帧成本。
2. **第二刀**：给消息图片和头像的图片解码加目标尺寸降采样（`cacheWidth`/`ResizeImage`/`memCacheWidth`），按显示尺寸 × devicePixelRatio 计算。

## 非目标（本次不做）

- 不缓存 section 派生结果 / key→index 映射（留待 profile 确认 UI 线程是否仍是瓶颈）。
- 不改 squircle 裁剪实现、不动 `cacheExtent`、不收窄 `appSettingsProvider` 订阅粒度。
- 不改视口跟随 / detached / 历史分页等滚动定位语义。

## 验收标准

- [ ] 滑动聊天列表时，`ChatMessageList` 不再因「回到底部」按钮距离更新而每帧 `setState`（拖动帧不再触发全列表 rebuild）。
- [ ] 「回到底部」按钮的显隐行为与改动前一致：detached 且距底 ≥ 120px 时出现，回到底部/跟随最新时消失；点击行为不变。
- [ ] 图片与头像解码尺寸受目标显示尺寸约束，不再按原图全分辨率进 ImageCache。
- [ ] 图片显示效果（清晰度、占位、错误态、画廊预览、Hero 动画）无肉眼可见退化。
- [ ] `flutter analyze` 无新增错误/警告；窄屏、宽屏各验一次滑动与按钮显隐。

## 自主决策（AI 设计，供扫读否决）

- 按钮状态载体用 `ValueNotifier<bool>`（只存"是否应显示"布尔，不存精确距离），距离比较逻辑保留在滚动回调内，仅在布尔跨阈值时才 `notify`——避免把 double 精度变化传导成重建。
- `ValueListenableBuilder` 就地包住 `build()` 里现有的 `if (showJumpToBottomButton) Positioned(...)` 分支，最小化结构改动。
- 图片降采样在 `message_bubble.dart` 内计算目标像素：`(显示逻辑尺寸 * MediaQuery.devicePixelRatioOf(context)).round()`，`FileImage`/`MemoryImage` 用 `ResizeImage` 包裹，`CachedNetworkImage` 用 `memCacheWidth`。头像固定 42px 显示，按 42 × dpr 限制。
- 保守起见只对「照片」和「头像」限制；表情包（EmojiBlock，最大 140px）本身小，先不动，避免影响清晰度。

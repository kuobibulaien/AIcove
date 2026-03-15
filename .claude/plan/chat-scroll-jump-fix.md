# 重构计划：聊天消息列表 reverse:true 改造

## 目标
将 `ChatMessageList` 从 `reverse: false`（事后 jumpTo 跳底）改为 `reverse: true`（天然从底部渲染），彻底消除打开时的闪跳和卡顿。

## 核心原理

`reverse: true` 下的坐标系：
- `scrollOffset = 0` → 列表底部（最新消息）← 默认起始位置，无需 jumpTo
- `scrollOffset = maxScrollExtent` → 列表顶部（最旧消息）
- 用户上滑 → offset 增大 → 看到更旧的消息
- index 0 在屏幕底部显示，index N 在屏幕顶部显示

数据不动（上游仍然是升序 oldest→newest），只在 UI 层反转显示。

## 唯一需要修改的文件

`apps/aicove_flutter/lib/src/ui/features/chat/widgets/chat_message_list.dart`

## 逐步改动清单

### 1. ListView.builder 设置 reverse: true（约第 463 行）

```dart
// 改前：
reverse: false,
// 改后：
reverse: true,
```

### 2. itemBuilder 反转索引 + 调整 streaming/loading 位置（约第 479-490 行）

改前的顺序（reverse:false）：
```
[loading_indicator] [msg_oldest ... msg_newest] [streaming_bubble]
```

改后的顺序（reverse:true，index 0 在底部）：
```
index 0: streaming_bubble (底部，如果可见)
index 1..N: 消息（最新在前 = 底部在前）
index N+1: loading_indicator (顶部，如果在加载)
```

实现：
- 如果 hasStreamingBubble 且 index == 0 → 返回 streaming bubble
- 如果 isLoadingMore 且 index == itemCount - 1 → 返回 loading indicator
- 其他：计算 dataIndex 后反转取值 `listItems[listItems.length - 1 - dataIndex]`

### 3. _onScroll 加载方向反转（约第 150-172 行）

```dart
// 改前：距顶部 200px 时触发（offset ≤ threshold）
if (currentScroll <= threshold && ...)

// 改后：距 maxScrollExtent 200px 时触发（接近历史方向顶部）
final maxScroll = position.maxScrollExtent;
if (currentScroll >= maxScroll - threshold && maxScroll > 0 && ...)
```

### 4. _scheduleScrollToBottom 跳到 offset 0（约第 174-193 行）

```dart
// 改前：
_jumpToOffset(position.maxScrollExtent);
// 改后：
_jumpToOffset(position.minScrollExtent);
```

### 5. _ensureInitialBottomPosition 简化（约第 195-207 行）

reverse:true 天然从底部开始，此方法可以大幅简化：
- 仍然保留作为 fallback（确保首帧定位正确）
- 改 jumpTo 目标为 `position.minScrollExtent`（即 0）

### 6. _distanceToBottom 反转方向（约第 224-229 行）

```dart
// 改前：
return position.maxScrollExtent - position.pixels;
// 改后（reverse:true 下 offset=0 是底部）：
return position.pixels - position.minScrollExtent;
```

### 7. _shiftViewportByOverlayDelta 可能需要反转方向（约第 235-243 行）

reverse:true 下，overlay 增长（键盘弹出）时视口补偿方向需要测试：
- 尝试保持 `position.pixels + delta`，如果方向不对则改为 `position.pixels - delta`
- 关键测试：用户在历史中段时弹出键盘，当前阅读位置不应跳动

### 8. initState 中移除不必要的初始 scroll（约第 137-139 行）

reverse:true 默认从 0 开始即是底部，但保留 _scheduleScrollToBottom 调用以处理边界情况。

### 9. didUpdateWidget 中的滚动逻辑调整（约第 309-346 行）

会话切换时 `_scheduleScrollToBottom()` 现在跳到 0 而不是 maxScrollExtent，其余逻辑不变。

### 10. padding 保持不变

`reverse: true` 不影响 EdgeInsets 的视觉方向，padding 仍然是 top=10（视觉顶部），bottom=listBottomPadding（视觉底部 composer 区域）。

## 不需要改的东西

- `_handleScrollNotification`：不涉及方向
- `_updateListItems`：数据构建逻辑不变
- `_buildListItemsWithTimeDividers`：数据层面不变
- `MessageBubble` 等子组件：不受影响
- `chat_page.dart`：不需要改
- 上游 provider/store：数据顺序不变

## 验证清单（flutter run 后逐项检查）

1. 打开聊天 → 消息直接在底部，无闪跳
2. 切换会话 → 新会话消息直接在底部
3. 发消息 → 列表自动回到底部
4. 接收消息（streaming） → streaming bubble 在最底部
5. 上滑翻看历史 → 不被强制拉回底部
6. 翻到顶部附近 → 触发加载更多历史
7. 加载更多后 → 阅读位置不跳动
8. 弹出键盘 → 阅读位置不跳动
9. 长按消息 → 菜单正常弹出

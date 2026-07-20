# 聊天页进入时未锚定到底部（最后一条消息被输入框遮挡）

> 轻量任务：PRD-only。2026-07-20 真机冒烟发现（一加/小米 2211133C，debug 包）。
> v2：按 codex 方案审查（`scratch/diagnostics/方案审查_entry-anchor_20260720.md`）修订四项必须项
> （B1 帧调度陷阱→改直接跳转；B2 depth 过滤＋执行时守卫；B3 补 `_historyViewportRestorePending`；
> B4 测试具体化为同 state 受控异步长高）。

## 现象与复现

进入含表情包历史的会话后，列表停在「距真实底部差一段」的位置——最后一条消息被输入框遮挡或整段历史偏上；每次进入稳定复现，停住后不自动纠正。截图证据：`/tmp/aicove_enter_3.png`（差约一个输入框高度）、`/tmp/aicove_ctl_2.png`（偏差更大，停在数屏之前）。

## 根因（已验证）

1. **初始置底是一次性跳转**：`_scheduleScrollToBottom`（chat_message_list_viewport.dart）post-frame 跳到 `minScrollExtent`，最多重试 6 帧，只等 `hasClients/hasContentDimensions`，**不等图片解码**；`_ensureInitialBottomPosition` 同样一次性（`_didInitialBottomPosition` 置位后不再管）。
2. **表情包无预留尺寸**：`message_bubble.dart` 的 `_buildMediaImage` 对 EmojiBlock 只给 `maxW/maxH=140` 约束＋`BoxFit.contain`，解码前高度≈0、解码后长到 ~140px；照片路径有「持久化宽高/保守估算占位」保护，注释明确「仅照片路径，不动 EmojiBlock」。
3. **长高后无人再锚定**：表情异步解码使 active sliver（reverse+center 结构）`minScrollExtent` 阶跃、`pixels` 不变 → 内容相对视口位移；follow-latest 的稳定化 `_shouldStabilizeFollowLatestViewport` 只由 didUpdateWidget（消息数据/输入框高度变化）触发，纯渲染层长高不产生任何 didUpdateWidget → 无人补跳。detached 模式有像素补偿（`_scheduleDetachedActiveExtentRestore`），follow-latest 模式没有对应机制。
4. **为何以前没暴露（高可信推断，非已验证）**：修复前时间线缓存的图片尺寸升级自激循环持续广播变更 → 窗口反复重发 → didUpdateWidget 反复触发稳定化，把列表不停拉回底部，掩盖了本缺陷（07-19 任务治好循环后现形）。该推断有机制证据（旧循环无条件通知＋didUpdateWidget 可触发稳底均已实证）但无逐帧 trace，不影响根因 1-3 与修复选择。已排除 07-13 滑动优化改动的嫌疑（不含该改动的对照包同样复现）。

## 目标

进入会话且处于跟随最新（follow-latest）状态时，**任意 active sliver 的纯渲染层 extent 变化**（表情/图片解码长高、字体加载、键盘与视口尺寸变化等）之后，列表最终稳定停在真实底部：最后一条消息完整可见、紧贴输入框上方。

## 修复方案（v2）

在主 `CustomScrollView` 的**直接祖先**处新增独立的 `NotificationListener<ScrollMetricsNotification>`（注意它不是 `ScrollNotification` 子类，须与现有监听分层；handler 恒返回 false 不吞通知）。该通知由框架在 metrics 变化后的帧后 microtask 合并派发——此时挂普通 post-frame 回调**不保证有下一帧**（Flutter 不会为其请求新帧），因此 handler 采取**直接跳转**：

1. 守卫全部通过即在通知回调内当场读取**当前** `position` 并复用既有 `_jumpToOffset(position.minScrollExtent)`（自带 programmatic serial 管理；jumpTo 会自行请求新帧）。无延迟回调 ⇒ 无 stale callback，无需 pending/serial 失效机制（结构性满足审查 B2 的执行时重验要求）。
2. 守卫（调度即执行，一处齐全）：`notification.depth == 0`（只认主列表自己的 viewport，防未来嵌套滚动误触）＋ `mounted` ＋ `shouldFollowLatest` ＋ `_didInitialBottomPosition` ＋ `hasClients && hasContentDimensions` ＋ `!_historyPagingLockActive` ＋ **`!_historyViewportRestorePending`**（历史恢复优先契约，与 detached 补偿守卫对齐）＋ `!_isProgrammaticScroll` ＋ `!_isUserScrollActive` ＋ `(pixels - minScrollExtent).abs() > 0.5`。
3. 去重＝latest state wins：框架已按 microtask 合并同帧变化；业务层不做 debounce/延时窗口，多张表情跨帧陆续解码就多次收敛（每次都用执行时最新 min），距离阈值提供幂等短路；`jumpTo` 改 pixels 不改内容尺寸，不会自激再派发。
4. `programmatic` 期间跳过的通知由既有动画完成后的 distance follow-up 兜底收敛（有专项回归锁住）。

detached（用户上滑）路径不受影响：`shouldFollowLatest=false` 直接短路，沿用既有像素补偿机制。handler 不 `setState`、不改变 follow/detached 模式。

## 非目标

- 不给 EmojiBlock 加固定占位尺寸（会改变表情包视觉，方形预留产生空隙；且治标不治本——任何未来的渲染层长高仍会复发）。
- 不动照片的估算占位/降采样逻辑、不动 detached 补偿、不动历史分页与流式对齐语义。
- 不碰 message_formatter.dart 等用户正在并行编辑的文件。

## 验收标准（v2，按审查 B4 具体化）

- [ ] **复现测试先行**（同一 widget/state 的受控异步长高，不得靠 pumpWidget 换数据触发 didUpdateWidget 旧路径）：尾部放真实 EmojiBlock（asset 分支），用 `DefaultAssetBundle` 包可控 bundle——manifest 立即返回、目标 PNG 的 `loadBuffer` 由 Completer 延迟；首次布局后先断言初始置底完成且表情高度≈0，再 complete，同 state 后续帧长高；核心断言 `position.pixels` `closeTo(minScrollExtent, 0.5)`，按明确帧数 pump，不得用无条件 `pumpAndSettle()` 掩盖帧调度缺陷（修复前该测试必须红）。
- [ ] **连续长高收敛**：两到三次受控长高（多个延迟 Completer 分批 complete），用 `onDebugAutoScrollRequested`（reason=metricsReanchor）记录执行计数——跨帧 min 再变化允许再次执行、最终贴执行时最新 min（同时验证去重不吞最后一次、无通知风暴）。
- [ ] **守卫交叉回归**：用户 dragStart 后完成解码不拉底；`_historyViewportRestorePending`/paging lock 期间不拉底（覆盖「加载锁先释放、旧历史稍后 prepend」时序，扩展既有 auto_scroll_guard 基线用例）；programmatic 动画中尺寸变化最终仍收敛（由动画完成后 distance follow-up 兜底，锁时序）；视口尺寸变化（模拟键盘）follow-latest 时贴底、detached 时不贴底。
- [ ] 既有测试全绿：`chat_message_list_auto_scroll_guard_test.dart` 等 `test/ui/features/chat/` 相关套件。
- [ ] `flutter analyze` 本任务文件 0 新增告警。
- [ ] 真机验收：进入「测试」会话（尾部含表情包），最后一条消息完整可见紧贴输入框；退出重进 3 次一致；上滑后新消息到达不强拉（detached 语义不变）。

## 自主决策（AI 设计，供扫读否决）

- **选 ScrollMetricsNotification + 直接跳转**而非「表情包占位尺寸」「延迟初始跳转等解码」或「post-frame＋ensureVisualUpdate」：metrics 通知是框架处理「视口下内容尺寸变化」的正统入口，一次覆盖所有渲染层长高来源；直接跳转彻底消掉「帧后通知挂 post-frame 无人请求下一帧」的陷阱与 stale callback 机制成本（审查 B1/B2 的两个备选中更简的那个）。
- 重锚复用 `_jumpToOffset` 不用动画：与初始置底、稳定化行为一致，避免陆续解码时动画抖动；其 programmatic serial 语义顺带防重入。
- 守卫集合与 detached 补偿守卫对齐（含 history pending 优先），不新增语义分支。

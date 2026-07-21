# 聊天页进入时未锚定到底部（最后一条消息被输入框遮挡）

> 轻量任务：PRD-only。2026-07-20 真机冒烟发现（一加/小米 2211133C，debug 包）。
> v2：按 codex 方案审查（`scratch/diagnostics/方案审查_entry-anchor_20260720.md`）修订四项必须项
> （B1 帧调度陷阱→改直接跳转；B2 depth 过滤＋执行时守卫；B3 补 `_historyViewportRestorePending`；
> B4 测试具体化为同 state 受控异步长高）。
> v3（2026-07-21）：裁决与 4 个 auto_scroll_guard 守卫的语义冲突——重锚收窄到「入场收敛窗」，
> 详见「§冲突裁决（v3）」；同时修正两个测试用例的基建缺陷（惯性甩飞／结构性追加混入刺激）。

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

## 冲突裁决（v3）：重锚收窄到「入场收敛窗」

**冲突现场**：v2 的 handler 对「贴底＋位移>0.5」一律重锚，打挂 4 个 auto_scroll_guard 守卫
（「贴底状态下 AI 新消息/临时流式消息/空时间线临时消息不应自动请求回底」＋「流式更新气泡锚点 Key 稳定」）。
根因：**消息追加与纯渲染层长高在 ScrollMetrics 层完全同构**（都是 active sliver 向 min 侧扩展），
指标层不可区分；而产品既有裁决（`_shouldStabilizeFollowLatestViewport`）明确规定贴底时新 AI 消息
**不**拉底（读稳定哲学），只有同尾流式增长、输入区高度变化、pinLatestTail（用户刚发送）等才稳底。

**裁决**：本任务只治 PRD 目标句所写的「**进入会话**后的渲染层收敛」，不越权接管结构性变化后的锚定：

1. 新增布尔窗 `_entryRenderConvergenceActive`（入场收敛窗）：
   - **开窗**：`_didInitialBottomPosition` 置位（初始置底完成）时；
   - **关窗（一次性，切会话前不再开）**：① 首次**实质性**时间线结构变化——按**有序消息 ID
     全序列**逐位比较（审查 R1：只比 length/首尾 id 会漏判等长中间替换/重排），任一位置 ID
     不同、增删、历史 prepend、`contextStartMessageId`（trim 规范化，审查 S2）变化均关窗；
     **列表实例变化但 ID 结构等同的刷新不关窗**（防真机上「入库回流的同内容新实例列表」把
     窗口误关导致修复失效；同 ID 流式增长同理不关窗）；
     ② 用户手势接管（`_lockAutoScrollForUserInterruption`）；③ 历史分页锁（`_lockAutoScrollForHistoryPaging`）；
   - **复位**：conversationId 变化时随 `_didInitialBottomPosition` 一起复位（含入场动画静默
     serial，审查 S4），下次初始置底重新开窗。
2. handler 守卫链在 `_didInitialBottomPosition` 之后追加 `_entryRenderConvergenceActive`，
   再追加**入场动画静默**：空会话首条消息经 didUpdateWidget 到达时，窗口会开在其入场动画
   结束之前，动画期的 extent 增长是结构性来源——以 `AnimatedMessageItem.onFinished` 的
   **动画完成事实**静默（serial 对账；完成回调经 post-frame＋microtask 延迟失效，恰好排在
   完成帧自身的 metrics 通知之后）。不用帧时间戳猜时长（审查 R2：warm-up 帧跳变、
   timeDilation、长帧都会失真）。
   窗内的位移**定义上**只能来自纯渲染层（尚未发生过结构变化），可安全重锚；窗外的 extent 演变
   全部让位给既有稳定化路径（结构写稳底、G2.1 通道稳底、detached 补偿）。
3. 窗内与既有稳底重叠的场景（如入场后立刻输入区升高）：稳底 post-frame 先执行、
   metrics 通知 microtask 后到，届时距离≤0.5 幂等短路，无双跳、无日志污染（守卫已验证）。

**代价（如实声明）**：窗口关闭后发生的纯渲染层长高（如进入很久后收到的新表情消息在贴底时解码）
不再由本机制纠正——该场景归属既有语义：新消息本就不拉底（守卫锁定），pinLatestTail 发送链路有
post-frame＋260ms 长尾重试兜底。此为按产品裁决主动选择的边界，非遗漏。

**测试基建修正（v3，含审查 R3 整改）**：
- 「跨帧多次长高」用例改为**同一条尾消息的两个 EmojiBlock 分批放行**（原设计用追加新消息制造第二次长高，
  既与裁决冲突，又踩中 finder 默认 skipOffstage 的可见性坑）；
- 「用户拖动脱离」「历史分页」用例改用手工手势（分步 move＋静置>100ms 再抬手）压掉速度采样，杜绝
  `tester.drag` 惯性 fling 把列表甩出 cacheExtent 导致表情组件被虚拟化回收；分页用例改短历史（3 条），
  保证门控表情全程已构建、长高刺激真实发生并断言高度>100（审查 R3a：原版刺激为空是假覆盖）；
- finder 一律 `skipOffstage: false`：cacheExtent 区（已构建未绘制）与入场动画 0 高帧的组件会被默认
  finder 判为 offstage 而「隐身」，此前 finder=0 的疑案真凶即此，组件与解码链路全程健在；
- 新增负向用例锁裁决：窗口关闭（结构性追加）后，后续渲染层长高不得再触发 metricsReanchor；
- 新增 R1 正反判据用例：同 ID 新实例刷新不关窗（刷新后解码仍重锚）／等长中间换 ID 必须关窗；
- 新增 R2 专项：空时间线首条临时消息的入场动画全程（含单个 300ms 长帧跨越动画完成点）无重锚；
- 新增 R3b 专项：脱离后点回底、动画飞行中解码长高被 programmatic 守卫跳过，动画完成后的
  distance follow-up 兜底收敛到底（锁 PRD v2 验收第 3 条的时序契约）。

## 非目标

- 不给 EmojiBlock 加固定占位尺寸（会改变表情包视觉，方形预留产生空隙；且治标不治本——任何未来的渲染层长高仍会复发）。
- 不动照片的估算占位/降采样逻辑、不动 detached 补偿、不动历史分页与流式对齐语义。
- 不碰 message_formatter.dart 等用户正在并行编辑的文件。

## 验收标准（v2，按审查 B4 具体化）

- [x] **复现测试先行**（同一 widget/state 的受控异步长高，不得靠 pumpWidget 换数据触发 didUpdateWidget 旧路径）：尾部放真实 EmojiBlock（asset 分支），用 `DefaultAssetBundle` 包可控 bundle——manifest 立即返回、目标 PNG 的 `loadBuffer` 由 Completer 延迟；首次布局后先断言初始置底完成且表情高度≈0，再 complete，同 state 后续帧长高；核心断言 `position.pixels` `closeTo(minScrollExtent, 0.5)`，按明确帧数 pump，不得用无条件 `pumpAndSettle()` 掩盖帧调度缺陷（修复前该测试必须红）。
- [x] **连续长高收敛**：两到三次受控长高（多个延迟 Completer 分批 complete），用 `onDebugAutoScrollRequested`（reason=metricsReanchor）记录执行计数——跨帧 min 再变化允许再次执行、最终贴执行时最新 min（同时验证去重不吞最后一次、无通知风暴）。
- [x] **守卫交叉回归**：用户 dragStart 后完成解码不拉底；`_historyViewportRestorePending`/paging lock 期间不拉底（覆盖「加载锁先释放、旧历史稍后 prepend」时序，扩展既有 auto_scroll_guard 基线用例）；programmatic 动画中尺寸变化最终仍收敛（由动画完成后 distance follow-up 兜底，锁时序）；视口尺寸变化（模拟键盘）follow-latest 时贴底、detached 时不贴底。
- [x] 既有测试全绿：`chat_message_list_auto_scroll_guard_test.dart` 等 `test/ui/features/chat/` 相关套件。
- [x] `flutter analyze` 本任务文件 0 新增告警。
- [x] 真机验收：进入「测试」会话（尾部含表情包），最后一条消息完整可见紧贴输入框；退出重进 3 次一致；上滑后新消息到达不强拉（detached 语义不变）。

## 自主决策（AI 设计，供扫读否决）

- **选 ScrollMetricsNotification + 直接跳转**而非「表情包占位尺寸」「延迟初始跳转等解码」或「post-frame＋ensureVisualUpdate」：metrics 通知是框架处理「视口下内容尺寸变化」的正统入口，一次覆盖所有渲染层长高来源；直接跳转彻底消掉「帧后通知挂 post-frame 无人请求下一帧」的陷阱与 stale callback 机制成本（审查 B1/B2 的两个备选中更简的那个）。
- 重锚复用 `_jumpToOffset` 不用动画：与初始置底、稳定化行为一致，避免陆续解码时动画抖动；其 programmatic serial 语义顺带防重入。
- 守卫集合与 detached 补偿守卫对齐（含 history pending 优先），不新增语义分支。

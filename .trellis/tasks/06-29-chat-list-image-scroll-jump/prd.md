# fix: 对话列表图片收尾上滑时整列表大跳一下

## Goal

修复「最后一条消息是图片、且图片生成完成的那个时刻，用户正上滑屏幕，整个消息列表大跳一下（位移量与正常手指滑动不一致）」的体验问题。

## 症状

- 触发条件：尾消息为图片 + 图片生成完成那一刻 + 用户正在手指上滑。
- 表现：列表「多跳一下」，位移量与手指实际滑动量不连续。
- 对比：纯文本收尾不跳；贴底静止收尾时是另一个症状（整列表闪烁 / 消息短暂消失，已记于 spec）。

## 根因（2026-06-29 已做 4 视角 + 4 skeptic 对抗验证，confidence: high）

同一根因的两种表现——「贴底闪烁」与「上滑大跳」：

1. **图片高度阶跃**：图片生成完成时尾消息 `ImageBlock.width/height` 从 `null` → 真实值。`message_bubble._buildMediaImage` 的图片 `SizedBox` 从「无尺寸估算占位 `Size(maxW, min(maxW,maxH))`」切到「真实等比缩放尺寸」，高度发生阶跃。
   - 横图 1024×576：占位 ≈234×234 → 真实 ≈234×132，**高度差 ~102px**
   - 竖图 576×1024：占位 ≈234×234 → 真实 ≈169×300，高度差 ~+66px
   - 方图 1024×1024：高度差 ~0px（仅宽度变）
   - 证据：`message_bubble.dart:465-489`（`_resolveImageDisplaySize`）、`message_bubble.dart:526-529`（估算占位）、`message_bubble.dart:538-542`（`SizedBox` 承载尺寸）
2. **视口 extent 突变**：`CustomScrollView(reverse:true, center:_centerKey, cacheExtent:500)` 下，active sliver 尾项 extent 突变。**关键几何**（codex 审核修正）：active sliver 位于 `center` **之前**（`chat_message_list.dart:567-578`），属于 reverse growth，按 Flutter `RenderViewport`（`viewport.dart:1705-1710`）此类变化改的是 **`minScrollExtent`**（视觉底部侧，与 `_distanceToBottom = pixels - minScrollExtent`、贴底 `jumpTo(minScrollExtent)` 自洽），**不是** `maxScrollExtent`；而 history sliver 在 center 之后才改 `maxScrollExtent`。`position.pixels` 不变而 minScrollExtent 侧 extent 变化 → 可见内容相对视口跳移。证据：`chat_message_list.dart:560-586`。
3. **detached 模式无像素补偿**：用户上滑 → `onUserGesture()` 同步切 `mode=detached` → `_autoScrollEnabled=false` → `_shouldStabilizeFollowLatestViewport` 首守卫 `return false`，`_scheduleFollowLatestViewportStabilization` 入口同守卫 → **不补 `jumpTo`**。证据：`chat_viewport_controller.dart:36-41`、`chat_message_list_timeline.dart:568-571`、`chat_message_list_viewport.dart:418`
4. **两症状差异 = 有无补偿**：贴底（followLatest）有 `jumpTo` 补偿，但补偿发生在 layout 重组同帧的 postFrameCallback，中间态暴露 → 闪烁；上滑（detached）无补偿 → 大跳。

**触发分支**（取决于后端推送时序，均落同一根因）：
- 分支A defer 冻结→松手爆发：图片完成帧到达时 old timeline 仍 `status='sending'` → `_hasStreamingTimelineMessage(old)=true` → `_shouldDeferStreamingListUpdate` defer → 拖拽期间 `_flushDeferredStreamingListUpdate` 反复重排 220ms Timer 冻结 listItems → 松手 `ScrollEndNotification` → `_markUserScrollEnded` → flush 单帧爆发。证据：`chat_message_list_timeline.dart:704-725`、`:744-772`、`chat_message_list_viewport.dart:606-611`
- 分支B 双帧分裂/漏检 mid-drag 突变：图片尺寸注入帧 status 已 `sent` 且无 streaming text → `_hasStreamingTimelineMessage(old||new)=false`（漏检 ImageBlock 维度变更）→ defer 不触发 → `_updateListItems` 同步执行 → 拖拽中突变。证据：`chat_message_list_timeline.dart:727-742`、`:117-130`

**对旧结论的修正**：此前判断「`sameTail` 分支 `_tailHasActionableLayoutChange` 误触发 stabilize 是上滑主因」**错误**。4 verify 一致确认 detached 模式下 stabilize 路径在 `timeline.dart:568-571` 即短路，`_tailHasActionableLayoutChange`（`:661-701`）在上滑场景不可达。

## 候选方案

### 方案 A（推荐，codex 审核后修正）：detached 模式按 sliver 侧选择 min/max 的 extent 像素补偿

**核心思路**：复用 `_scheduleHistoryViewportRestore`（history sliver prepend 时的 `maxScrollExtent` 侧补偿），新增一个**针对 active sliver（尾项）变化的 `minScrollExtent` 侧补偿**。两者按 sliver 侧分别处理，不能共用同一公式或同一 serial。

**关键几何（codex 审核硬性修正）**：
- ❌ 原方案写 `delta = newMax - oldMax`、`jumpTo(pixels + delta)` 对尾图场景**不成立**——尾图在 active sliver（center 之前），其 extent 变化改的是 `minScrollExtent`，`newMax - oldMax` 通常为 0，修不到问题。
- ✅ 正确公式：`target = previousPixels + (newMin - oldMin)`。
  - 尾图变高（横图占位 234 → 真实 234，但若竖图 234→300 增高）：`newMin < oldMin` → pixels 应减小；
  - 尾图变矮（横图 234→132）：`newMin > oldMin` → pixels 应增大。
- history sliver 侧仍沿用现有 `pixels + (newMax - oldMax)`（见 `_scheduleHistoryViewportRestore`，`chat_message_list_viewport.dart:405-409`）。

**改动点**：
- `_ChatMessageListState`（`chat_message_list.dart:377-423`）新增状态字段：`_pendingDetachedExtentRestoreMin`（记录前 minScrollExtent）、`_pendingDetachedExtentRestorePixels`，以及独立 serial（**不得与 `_historyViewportRestoreSerial` 复用**，否则双重跳）。
- 新增 `_scheduleDetachedActiveExtentRestore(previousPixels, previousMin)`（`chat_message_list_viewport.dart`）：postFrame 捕获 newMin，`jumpTo(previousPixels + (newMin - previousMin))`。
- 调用点：`_flushDeferredStreamingListUpdate`（`chat_message_list_timeline.dart:761-791`）和同步 `_updateListItems` 路径（`:117-130`）执行 `_updateListItems` 前捕获 `previousMin` + `pixels`，**仅当 `_autoScrollEnabled==false` 且非 history prepend/restore 进行中**时挂补偿。
- **守卫**：`didPrependOlderHistory` / `_historyViewportRestorePending` 为真时不挂（避免与 history 补偿双重跳，见 `chat_message_list_timeline.dart:65-73,131-140`、`chat_message_list_viewport.dart:405-409`）。
- **与惯性冲突处理**：`jumpTo` 会 `goIdle()→forcePixels()→goBallistic(0.0)` 终止当前惯性（`scroll_position_with_single_context.dart:197-206`）。补偿须挂在「`_updateListItems` 触发的 rebuild 完成 layout 的 postFrame」；若 `_flushDeferredStreamingListUpdate` 本身已在 postFrame（`:776-785`），补偿需再挂一次 postFrame。松手惯性中是否补偿需明确取舍（终止惯性 or 等 idle）。
- **程序化滚动期间**：`_isProgrammaticScroll==true` 时跳过/重试补偿，不打断。

**实现前必须落实的 4 项细则（codex 第二轮终审，几何公式已放行，这 4 项不补不建议动手）**：
1. **触发条件守卫**：detached restore 只在「尾部 ImageBlock 宽高从缺失→有值、或数值变化」时挂（对比 oldWidget 与当前 tail 的 ImageBlock width/height，复用 `_tailHasActionableLayoutChange` 的判定逻辑 `chat_message_list_timeline.dart:661-701`）；其它 listItems 重建（纯文本追加、状态切换无几何变化）不挂。
2. **conversation 切换失效**：`didUpdateWidget` 中 `oldWidget.conversationId != widget.conversationId` 分支（`timeline.dart:17-41`）必须取消/递增 detached restore serial，回调执行时校验 `widget.conversationId == 捕获时 conversationId`，避免跨会话误补偿。
3. **serial 优先级 history > detached**：`didPrependOlderHistory` / `_historyViewportRestorePending` / `_historyPagingLockActive` 任一为真时，detached restore 不调度；已调度的在 postFrame 执行时二次校验、若 history 已介入则退出。detached serial 独立于 `_historyViewportRestoreSerial`、`_programmaticScrollSerial`。
4. **clamp 检测 + 惯性取舍**：
   - clamp：`_jumpToOffset` 会 clamp 到 `[min,max]`（`viewport.dart:226-235`）。`_scheduleDetachedActiveExtentRestore` 计算 `target = previousPixels + (newMin - previousMin)` 后，记录 `residual = target - clamped`（探针日志），便于定位补偿不足。
   - 惯性：**改为等真正 idle 后再 flush+补偿**——不在 `BallisticScrollActivity` 进行中 `jumpTo`（避免 `goIdle()` 截断松手惯性）。具体：`_markUserScrollEnded`（`viewport.dart:606-612`）收到 `ScrollEndNotification` 时，若仍有进行中 ballistics，把 flush+补偿推迟到下一帧 idle 校验通过后执行；代价是图片完成显示稍延后，收益是松手惯性不被截断。

### 方案 B（codex 审核推荐·源头）：Flutter 本地生图链路把请求宽高传到最终 ImageBlock

**核心思路**：codex 查明生图链路**完全在 Flutter 本地**（`agent_api.dart:153-185` → 本地 `agent_image_api_support.dart:70-88` → `image_plugin.dart:569-585`），**不触碰云端**（`cloud_backend` 搜 draw_image/generate-image/ImageBlock/生图 无命中，符合「云端只做备份」边界）。生图请求时**已知目标宽高**（`image_plugin.dart:394-395,457-464,569-575`），但中途 `PluginImageContent` 只带 localPath/caption（`plugin_content.dart:16-23`），最终 ImageBlock 没写宽高（`chat_deferred_image_delivery.dart:158-162`、`chat_message_processor.dart:633-637`、`image_plugin.dart:691-695`）——把宽高沿这条链路传到底，从源头消除 `null→真实值` 阶跃。

**优点**：治本；顺带改善冷加载布局稳定性；纯本地改动，不触碰云端边界。
**风险/成本**：要改生图链路 4+ 个点（image_plugin → PluginImageContent → delivery → processor），**会超过 3 文件**，按 AGENTS.md 应**拆成独立子任务**。前端估比例不可靠（方图占位正好不跳、横图才跳），不能只靠前端估算。

**codex 补充发现**：`conversation_short_window_store.dart:621-680` 已会在 upsert 前补图片宽高，`:496-513` 会异步升级旧快照——所以「null→真实值」不是所有新图路径都直接暴露给 UI，B 的收益对走 store 升级路径的图有限，对热路径（流式直接交付）最明显。

### 方案 C（并入 A）：把「图片未交付尺寸/尺寸变化」纳入流式语义，修 defer 漏检

**核心思路**：codex 确认 `_shouldDeferStreamingListUpdate` 的 `_hasStreamingTimelineMessage`（`chat_message_list_timeline.dart:711-724,727-741`）**只看 sending/streaming text/pending audio，漏了 ImageBlock 尺寸变化**——这是分支B（mid-drag 同步重建）的直接成因。把 `ImageBlock.width==null||height==null` 或尺寸变化纳入判定，让图片收尾也走 defer，避免拖拽中同步 `_updateListItems`（`timeline.dart:117-130`）。可选缩短 `_kStreamingScrollUpdateDeferDuration`（220ms→~80ms）。

**优点**：收窄分支B漏检，避免拖拽中 `jumpTo`（codex 明确「不建议拖拽中 jumpTo」）；改动小。
**风险**：单用只是把跳变从「mid-drag」挪到「松手」集中爆发，不消除；必须配合方案 A 才真治本。codex 还指出：现有 `_isUserScrollActive`（`chat_message_list.dart:422`）语义不够细，需区分「手指拖拽中」与「松手后惯性中」两种状态来决定补偿时机。

## codex 审核结论（2026-06-29）

### 第一轮（已吸收）
- **总体**：可行但需调整。
- **方案 A 硬伤（已修正）**：原 `newMax - oldMax` 对尾图通常为 0，已改为 `newMin - oldMin`（active sliver 在 center 前，属 reverse growth，改 minScrollExtent 侧）。
- **方案 B**：纯本地可行（生图链路在 Flutter：`agent_api.dart` → `agent_image_api_support.dart` → `image_plugin.dart`），不触碰云端边界。
- **文件数**：A 约 3 文件（state + viewport + timeline），不需拆；加 B 超 3 文件需拆独立子任务。
- **最终建议**：A（min 侧修正）+ B（本地尺寸传递），A 内先修 defer 漏检。

### 第二轮终审（几何放行，补 4 项细则）
- **几何精确性（放行）**：codex 查 Flutter 引擎 `RenderViewport.updateOutOfBandData`（GrowthDirection.reverse → `_minScrollExtent -= scrollExtent`）+ `RenderSliverPadding.performLayout`（`scrollExtent = mainAxisPadding + child.scrollExtent`）确认——只要本帧仅尾图高度变 Δh，`newMin - oldMin = -Δh`，公式精确。padding 同帧变化时会补偿整个 active 区变化（可接受）。
- **方案 B 与 display-cache（放行）**：`_buildWindowSignature` 已签 width/height（`presentation.dart:115-126`），B 只让 null→真实值首次 miss（预期）；但实现 B 时须同步更新 PluginContent 编解码，否则宽高在投影路径丢失。
- **还需调整 4 项（已补入方案 A 改动点）**：① 触发条件限定 tail ImageBlock 几何变化；② conversation 切换失效 serial；③ serial 优先级 history > detached；④ clamp 检测 + 改为 idle 后 flush+补偿（不截断松手惯性）。
- **终审结论**：核心几何公式已修正，方案 A+B 不否决；补完上述 4 项后可进入实现。

## 推荐组合（codex 审核后）

**A（按 min 侧修正 + 先修 defer 漏检）** 必做治本兜底；**+B（Flutter 本地宽高传递）** 从源头消除阶跃，作为独立子任务。C 已并入 A 的 defer 修正。

## 验收标准

- [ ] 尾消息为图片、生成完成时上滑，列表不再出现与手势位移不一致的额外大跳。
- [ ] 横图、竖图、方图三种比例均验证（方图理论上高度差 0，重点验横图）。
- [ ] 贴底跟随收尾不回归闪烁症状。
- [ ] 历史分页 prepend 的像素补偿不受影响。
- [ ] `flutter run --no-resident` 真机窄屏/宽屏各验证一次。

## Out of Scope

- 不重构 `reverse:true + center` 三 sliver 结构。
- 不更换生图供应商。
- 不新增全局依赖。
- 不动已确认在 detached 为死路径的 stabilize 代码（卫生项，留待后续清理）。

## 请 codex 重点审核

1. 根因因果链是否成立？file:line 证据是否属实？
2. 方案 A 的「extent 像素补偿」在 reverse:true + center 双 sliver 坐标系下方向是否正确？delta 应加还是减？
3. 方案 A 是否与松手后的惯性 `BallisticScrollActivity` 冲突？补偿时机的选择（postFrame vs 下帧）？
4. 是否有比 A 更简/更治本的方案被遗漏？
5. 方案 B 是否触碰「云端不参与开发」边界（生图链路在 Flutter 端还是 cloud_backend）？
6. 方案 A 改动是否超过 3 文件需进一步拆分？

## 技术备忘

- 已读：根 `README.md`、`AGENTS.md`、`.trellis/spec/README.md`。
- 待读（实现前）：`.trellis/spec/frontend/index.md`、`apps/aicove_flutter/docs/公共组件总览.md`。
- 诊断探针 `[ChatFlicker]` 仍在代码中，确认主因+修复后整体移除。

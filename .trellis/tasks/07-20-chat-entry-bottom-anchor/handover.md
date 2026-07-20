# 交接文档：07-20-chat-entry-bottom-anchor

> 写于 2026-07-20，主会话因用户新开窗口而交接。任务状态：in_progress（实现已完成且核心用例已绿，卡在两个测试用例的排障上）。
> 接手前请通读本文件＋`prd.md`（v2）＋`scratch/diagnostics/方案审查_entry-anchor_20260720.md`（codex 方案审查，PRD v2 已照单吸收其 4 项必须项）。

## 一、任务是什么

真机冒烟发现：进入聊天会话后列表未锚定到底部，最后一条消息被输入框遮挡，每次进入稳定复现。根因（已验证，详见 prd.md）：

1. 初始置底是一次性 post-frame 跳转，不等图片解码；
2. EmojiBlock 表情包无预留尺寸（`message_bubble.dart` `_buildMediaImage`，仅照片有估算占位），解码前高≈0、解码后长到 ~140px；
3. 纯渲染层长高不产生 didUpdateWidget，follow-latest 稳定化收不到信号，无人补跳；
4. 以前被 07-19 修掉的「图片尺寸升级自激循环」不停重新置底所掩盖（高可信推断）。

已排除：07-13 滑动优化改动（不含它的对照包同样复现）。

## 二、已完成的工作

### 修复实现（已落盘，两个文件）

1. [chat_message_list.dart](../../../apps/aicove_flutter/lib/src/ui/features/chat/widgets/chat_message_list.dart)：build 的 Stack 里，用 `NotificationListener<ScrollMetricsNotification>` 包住既有的 `NotificationListener<ScrollNotification>`（带注释；注意 ScrollMetricsNotification **不是** ScrollNotification 子类，必须独立监听）。
2. [chat_message_list_viewport.dart](../../../apps/aicove_flutter/lib/src/ui/features/chat/widgets/chat_message_list_viewport.dart)：`_handleScrollNotification`（约 :708）上方新增 `_handleScrollMetricsNotification`——守卫链：`depth==0` → `mounted` → `_autoScrollEnabled` → `_didInitialBottomPosition` → `!_historyPagingLockActive` → `!_historyViewportRestorePending` → `!_isProgrammaticScroll` → `!_isUserScrollActive` → `hasClients`/`hasContentDimensions` → 距离>0.5，全过则报 `metricsReanchor` 调试回调并**当场** `_jumpToOffset(position.minScrollExtent)`。
   - **为什么当场跳而不是 post-frame**：metrics 通知在帧后 microtask 派发，此时挂普通 post-frame **不保证有下一帧**（审查 B1，SDK 行号证据在审查报告里）；直接 jumpTo 自会请求新帧，且无 stale callback。
   - 去重＝latest state wins（读执行时最新 min＋距离阈值幂等短路），不做 debounce。

### 复现测试（新文件，5 个用例）

[chat_message_list_metrics_reanchor_test.dart](../../../apps/aicove_flutter/test/ui/features/chat/widgets/chat_message_list_metrics_reanchor_test.dart)

- 手法：`_GatedStickerBundle extends CachingAssetBundle`（manifest 即时返回、表情 PNG 字节由 Completer 门控）＋ `DefaultAssetBundle` 包裹（已验证 `createLocalImageConfiguration` 会带上它）→ 同一 widget/state 内制造「首帧高≈0 → 放行后长高」，绕开 didUpdateWidget 稳定化路径。PNG 用 `img.encodePng(img.Image(width:120,height:120))` 现做。
- **红已实证**：修复前核心用例位移 82px、重锚计数 0；修复后核心用例绿（metricsReanchor 触发、距离归 0）。

### 关键机理发现（写测试时挖出的，接手必读）

- 列表是 `CustomScrollView(reverse:true, center:_centerKey)` 双 sliver：**只有 active sliver（center 之前）的长高才改 `minScrollExtent` 产生位移需要重锚；历史 sliver 侧长高只扩 `maxScrollExtent`，天然不位移**（实测打点：尾部前一条表情长高时 pixels=-78/min=-78 不动、max +346）。所以「多次长高」用例设计成：尾部长高→重锚；`appendGatedSticker` 追加新门控表情成为新尾部→再长高→再重锚。
- 测试守则（审查 B4）：不许 `pumpAndSettle` 掩盖帧调度缺陷；门的 complete 必须放进 `tester.runAsync`（否则跨 fake/real zone 偶发问题）；解码等待用有界收敛循环（≤20 轮，每轮真实 20ms＋一帧）。

## 三、当前卡点（接手第一件事）

`flutter test test/.../chat_message_list_metrics_reanchor_test.dart` 稳定 **3 过 2 挂**：

- ✅ 核心用例（尾部表情长高重锚）、历史分页窗口、视口尺寸变化
- ❌ 「跨帧多次长高」：**phase B**（追加的第二张表情 `sticker_late`）放行后，20 轮内该 asset 的 Image 组件 finder 恒为 0（`末轮 finder=0`）
- ❌ 「用户拖动脱离」：drag 300px 后放行表情，同样 finder 恒 0

已排除/已知：

- `load()` **有被请求**、门 completed、输出里无任何解码报错（IMAGE RESOURCE/Unable to load 均无）；
- 每用例改用唯一 asset 名（`t{i}_` 前缀）**无效** → 不是按名字的全局污染；
- imageCache 跨用例累积（size 递增）但 key 含 bundle 实例应互不命中；
- 失败的共同点：放行发生在「同一用例内已有过滚动/跳转/追加」之后；首次直接放行的用例（t1/t5）都好。

**我刚加了最后一版诊断还没来得及跑**：失败 reason 里会 dump「树内全部 Image 的 provider 列表」＋末轮 finder/height。接手直接跑该文件看这个 dump：

- 若树里**有别的 Image 而无该 asset** → 大概率 bubble 的 `errorBuilder` 吞了流错误（errorBuilder 处理过的错不进控制台）。下一步：测试里手动 `AssetImage(key).resolve(ImageConfiguration(bundle: bundle))` 挂 error listener 把真实异常掏出来；
- 若连消息锚点 `find.byKey(ValueKey('message:sticker_late'))` 都不在 → 是虚拟化/detached split boundary 把尾部挪进了另一个 delegate 或没构建，去查 `_splitListItems`/`_captureDetachedSplitBoundary` 对追加消息与 detached 模式的处理；
- 也可对照：把 drag 300 改 150、或 phase B 改成不 drag 纯追加，二分出「哪个前置动作」导致组件消失。

注意：这两个失败是**测试基建问题的概率大于产品缺陷**（核心行为用例已绿），但在证明之前别下结论。

## 四、绿了之后的收尾清单（按序）

1. `flutter analyze`（本任务文件 0 新增）＋ 相关既有套件全绿：`test/ui/features/chat/widgets/chat_message_list_auto_scroll_guard_test.dart`、`test/ui/features/chat/pages/chat_page_lifecycle_test.dart`；已 `dart format` 过三个改动文件。
2. **codex 审代码**（项目规则「完工必审」）：`hands run codex --cwd /path/to/aicove --task <任务书.json>`；任务书必须是 JSON `{goal, scope{description, allowWrite}, acceptance{description}}`（markdown 会 exit 3）。审查重点让它对照方案审查 B1-B4 核代码闭合。
3. 真机验收：设备 `3a845d3f`（`adb` 在 `~/dev-sdks/android-sdk/platform-tools`；flutter 要 `export PATH="$HOME/dev-sdks/flutter/bin:$PATH"`）。`flutter run --no-resident -d 3a845d3f` → 进「测试」会话（列表页**第一次点击会被吞，点两次**，坐标约 540,500）→ `adb exec-out screencap -p > /tmp/x.png` 截图核验：最后一条消息完整贴输入框上方；退出重进 ×3；上滑后不被强拉。
4. 提交（**先问用户**）：⚠️ `chat_message_list.dart` 里同时有用户并行未提交的改动（见下节），整文件 add 会把人家的 WIP 一起提交——要么等用户先提交/确认，要么用 `git apply --cached` 只暂存本任务 hunk。`chat_message_list_viewport.dart` 与新测试文件干净可整体提交。附带 prd.md/handover.md 任务文档。
5. 若有值得沉淀的（候选：「渲染层长高须经 metrics 通知重锚，didUpdateWidget 稳定化覆盖不到」补进 `.trellis/spec/frontend/quality-guidelines.md` 滚动性能节），走 trellis-update-spec；然后 `/trellis:finish-work`（archive＋journal）。

## 五、并行工作警告（重要）

- **用户正在另一窗口改代码**（流式占位方向）：未提交改动含 `chat_actions*.dart`、`active_stream_projection.dart`、`chat_send_api_runner.dart`、`message_formatter.dart`、以及 **`chat_message_list.dart` / `chat_message_list_presentation.dart` / `chat_message_list_timeline.dart`**。绝对不要对这些文件 `git checkout`/`stash`；跑测试若出现莫名编译错误，先 `git status` 看是不是用户改到一半（发生过一次，`message_formatter.dart` 半成品挡了编译，稍后自愈）。
- 本任务改动边界：`chat_message_list.dart`（仅监听器包装 hunk）、`chat_message_list_viewport.dart`（handler）、新测试文件。别越界。

## 六、背景与相关工位

- 上一任务 07-19-chat-first-paint-cache（首屏加载慢）已完成、已提交（`a8d953c`）、已归档：真机验证首屏秒出、全程无崩溃。本 bug 正是它治好自激循环后现形的。
- 诊断/审查文档全在 `scratch/diagnostics/`：`聊天首屏加载慢_codex诊断_20260716.md`、`方案审查/复审/终审_chat-first-paint_20260719.md`、`代码审查/代码复审_chat-first-paint_20260719.md`、`方案审查_entry-anchor_20260720.md`。
- Web 端：用户已裁决**不需要兼容**（别设 Web 硬门，见 memory `web-not-a-target`）。
- 真机截图证据：`/tmp/aicove_enter_3.png`（bug 现场）、`/tmp/aicove_ctl_2.png`（对照包更严重的偏移）。

## 接手补记（2026-07-21，G2.1 会话代管）

- 你的实现曾被误扫进 HEAD，又与 4 个 auto_scroll_guard 守卫冲突（贴底状态下 AI 新消息/临时消息不应程序化回底、锚点 Key 稳定），已整体退出 HEAD 并从工作区清场，**一行不丢**地归档在本目录：
  - `wip_handler.patch`：viewport 的 `_handleScrollMetricsNotification`（`git apply` 即恢复）
  - `wip_hookup_removal.patch`：build 里的监听挂钩（`git apply -R` 即恢复）
- 接手第一件事仍是 handover 正文的两个测试卡点；**新增第零件事**：先裁决你的重锚与上述 4 个守卫的语义冲突（守卫是 07-13 沉淀的隐式契约；可能需要给 handler 增加「区分 didUpdateWidget 可见变化 vs 纯渲染层长高」的来源判别，或有意识地修订守卫并留档理由）。
- 另注意：G2.1（已完成）在同一批文件上新增了活跃流通道窄信号（listenManual）与稳底级联，先 rebase 再动工。

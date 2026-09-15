# 执行清单：聊天消息列表滑动卡顿优化

## 第一刀：回到底部按钮显隐隔离为 ValueNotifier ✅

目标文件：
- `lib/src/ui/features/chat/widgets/chat_message_list.dart`
- `lib/src/ui/features/chat/widgets/chat_message_list_viewport.dart`

实际改动（较原计划有升级，采纳 codex 审方案意见）：
1. [x] 新增 `ValueNotifier<bool> _showJumpToBottom`，`dispose()` 释放。
2. [x] **删除** `_manualDetachedDistanceToBottom` 字段与 `_updateManualDetachedDistanceToBottom()` 方法（codex 建议的更稳做法：不维护派生 double，`_shouldShowJumpToBottomButton()` 内直接 `_distanceToBottom()` 实时算，bool 自带去重）。
3. [x] 新增 `_syncJumpToBottomVisibility()`：只写 notifier 不 setState；在 persistentCallbacks/transientCallbacks/midFrameMicrotasks 阶段推迟 postFrame 写值（原 phase 守卫语义保留）；`_isProgrammaticScroll` 期间跳过。
4. [x] `_resetManualDetachedDistanceToBottom()` 退化为 `_syncJumpToBottomVisibility()` 转发（保留命名兼容调用点语义）。
5. [x] `build()`：按钮改为常挂 `Positioned` + `ValueListenableBuilder<bool>`，builder 内 show ? 按钮 : `SizedBox.shrink()`（codex 建议的更稳树形：Positioned 常挂）。
6. [x] 同步覆盖清单（codex 审方案要求明确化）：
   - 拖动/overscroll/方向变化/scrollEnd 各滚动通知分支 → sync
   - detached→followLatest（`_handleViewportControllerChanged`）→ reset→sync
   - followLatest→detached → capture 后 sync
   - 会话切换 / 时间线变空 / controller 实例替换 → `didUpdateWidget` 尾部统一 sync 兜底（`_handleDidUpdateWidget` 内部 return 不影响外层尾部执行）
   - initState 无需初始 sync：无 scroll client 时 distance=infinity→false，与初值一致
7. [x] grep 确认无悬空引用。

回滚点 A：git checkout 两个文件即可，改动自包含。

## 第二刀：图片/头像 cacheWidth 降采样 ✅

目标文件：`lib/src/features/chat/presentation/widgets/message_bubble.dart`

8. [x] 照片：`photoDecodeWidth = (photoDisplaySize?.width ?? maxW) × dpr`（codex 建议：优先实际显示宽，竖图更省）。FileImage→`Image.file(cacheWidth:)`；网络→`CachedNetworkImage(memCacheWidth:)`（不动磁盘缓存参数）；base64→`ResizeImage.resizeIfNeeded` 只包显示用 Image。
9. [x] **预览 provider 分离**（codex 阻塞点 2）：赋给 `imageProvider`（传 `_showImagePreview`/画廊/Hero）的保持原图 provider，三条路径均未污染。
10. [x] 头像：`avatarDecodeWidth = 42 × dpr`，file/asset 用 `cacheWidth`，base64 用 ResizeImage，网络用 `memCacheWidth`。
11. [x] EmojiBlock 表情包不动。

回滚点 B：单独回退 message_bubble.dart。

## 验证

12. [x] `flutter analyze`：全项目 error=0 / warning=0（最终在 Flutter 3.35.6 上验证）。
    - **SDK 版本纠正**：最初误装最新 3.44.6，`flutter analyze` 通过但真机构建失败——`lucide_icons 0.257.0`（停更包）`extends IconData` 被 3.44 的 final class 禁止。查 `.metadata` 确认项目原版为 **3.35.6**（revision 9f455d），降回后编译通过。教训：**搭环境先读 `.metadata`/lock 匹配项目版本；`flutter analyze` 通过 ≠ 能编译（analyze 不查第三方包源码，build 才会）**。3.44 期间顺手改的 `scrollCacheExtent` 已回退为 `cacheExtent`（3.35 正确 API），`pubspec.lock` 恢复基线版本。
    - 环境：Flutter 3.35.6 arm64（3.44.6 留档于 ~/dev-sdks/flutter-3.44.6）+ Android SDK(platform-36/build-tools 36) + JDK17（~/dev-sdks，PATH 已写入 .zshrc）。
    - 期间发现并修复独立既有问题：macOS 迁移基线丢失 25 个 data 层源文件（auto_reply/agent_context/backup/chat/settings/sync），已从 Windows 原始包（新打包/aicove_source_docs_complete_20260713-053422）对照补齐，迭代 4 轮 analyze 从 191 error 收敛到 0。
    - 行尾规整：编辑器把 3 个改动文件转成了 LF（仓库为 Windows 迁移的 CRLF 为主，无 .gitattributes），已按各文件 HEAD 原始行尾回转（两个列表文件 CRLF、message_bubble LF），最终真实 diff 82 增 24 删。
13. [~] 真机验证：3.35.6 debug APK 构建成功（产物 192MB 已确认存在，非退出码误报——后台脚本尾部 tail 会覆盖退出码，验证一律看产物文件）。一加13T(PKX110) 曾 adb 在线，装机时离线，等重连后安装实测：滑动流畅度、按钮显隐、图片清晰度、画廊预览、Hero 动画。
14. [x] codex review 复审实现完成：
    - 必修项（已修）：程序化滚动守卫吞掉同步 → `_endProgrammaticScroll`/`_cancelProgrammaticScrollTracking` 清标志后补 `_syncJumpToBottomVisibility()`，消除按钮永久残留竞态。
    - 建议1（已采纳）：`_jumpToBottomSyncScheduled` 标志合并同帧 postFrame 回调。
    - 建议2（已采纳）：initState 后注册一次 post-frame 初始同步，覆盖挂载前已 detached 的边界。
    - 建议3（记录待办）：补两个 widget 回归测试——预先 detached 的首次挂载、程序化滚动期间切回 followLatest。
    - 确认无碍：单图/画廊预览 provider 未被降采样污染（三条路径逐一核过）。
15. [x] 更新文档：`.trellis/spec/frontend/quality-guidelines.md` 新增「长列表滚动性能」硬约束；`apps/aicove_flutter/docs/公共组件总览.md` 更新记录加 2026-07-13 条目。

## 测试回归与最终方案修订（2026-07-13 深夜，重要）

初版实现跑真实 widget 测试后发现 2 个回归（50 个守卫测试中），根因与修订：

1. **「轻微手势脱离」测试失败**：初版把按钮显隐改为实时计算 `_distanceToBottom()`。但产品契约（测试断言）是：显隐由**用户手势时刻采样**的距离决定，新消息插入把底部撑远（被动变远）不得触发按钮。修订：恢复 `_manualDetachedDistanceToBottom` 采样字段及其 0.5px 去重/更新时机（语义与旧版 100% 一致），按钮判定读采样值。
2. **「流式气泡锚点 identical」测试失败**：实验证明该测试隐式依赖旧实现里"距离更新触发一次 setState 稳定化 build"来完成流式 element 对齐（补一个空 `_updateState((){})` 即恢复通过；与按钮 UI 结构无关——删掉按钮仍失败）。修订：`_updateManualDetachedDistanceToBottom({bool isDragFrame})` 分流——**拖动逐帧（卡顿主因）只写 notifier**，低频路径（ScrollEnd/方向切换）保留 setState 维持旧稳定化语义。
3. 初版加的 initState post-frame 初始同步 / programmatic 结束补同步在最终版中移除（最小化改动面；相关边界由采样字段初值 0 与 reset 时机天然覆盖，`_resetManualDetachedDistanceToBottom` 在 early-return 路径也强制同步一次 notifier 以覆盖 followLatest 切换）。

最终结果：50/50 守卫测试通过；全项目 analyze error=0。

**教训（已沉淀 spec）**：性能优化删除 setState 时，必须先确认没有其它行为隐式依赖"这次 rebuild 顺带完成的稳定化"；widget 测试是发现此类隐式契约的唯一可靠手段，静态审查（自查+codex 双审）都没抓到这两个回归。

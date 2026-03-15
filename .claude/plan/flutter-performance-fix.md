# 实施计划：Flutter 性能优化 — 内存泄漏修复 + 无效 rebuild 消除

## 任务类型
- [x] 前端 (Flutter/Dart)
- [ ] 后端
- [ ] 全栈

## 问题诊断总结

用户反馈：app 越用越卡，进出聊天/设置页面时突然卡顿。
根因：多处资源未随页面销毁而释放（内存泄漏）+ 多处 provider 监听粒度过粗（无效 rebuild）。

## 实施步骤

### Step 1: [Critical] 修复音频播放器内存泄漏
- **文件**: `apps/aicove_flutter/lib/src/features/chat/presentation/widgets/audio_player_widget.dart:306`
- **问题**: `audioPlayerControllerProvider` 用了 `StateNotifierProvider.family` 但没有 `autoDispose`。每播放一条语音消息就常驻一个 AudioPlayer 实例，流订阅也不会释放。
- **修复**: 改为 `StateNotifierProvider.autoDispose.family`，widget 卸载后自动释放 AudioPlayer 及其流订阅。
- **预期产物**: 语音消息的 AudioPlayer 实例随页面退出自动销毁。

### Step 2: [Critical] 修复聊天消息窗口 provider 内存泄漏
- **文件**: `apps/aicove_flutter/lib/src/features/chat/conversation_timeline_providers.dart:44`
- **问题**: `conversationMessageWindowProvider` 用了 `StreamProvider.family` 但没有 `autoDispose`。每切换一个会话就多一条数据库 watch 订阅永远不释放。
- **修复**: 改为 `StreamProvider.autoDispose.family`，离开聊天页后自动取消数据库监听。
- **预期产物**: 退出聊天页后数据库监听自动释放，不再累积。

### Step 3: [High] 优化聊天页面 provider 监听粒度
- **文件**: `apps/aicove_flutter/lib/src/features/chat/conversation_providers.dart:297`
- **问题**: `activeConversationProvider` watch 整个会话列表，任何会话变更都触发重建。
- **修复**: 改为只 watch 当前活跃的 conversationId 对应的单条会话，或使用 `.select()` 精确过滤。
- **预期产物**: 其他会话变更不再触发当前聊天页重建。

### Step 4: [High] 修复 ChatPage build 中的全量列表监听
- **文件**: `apps/aicove_flutter/lib/src/ui/features/chat/pages/chat_page.dart:566`
- **问题**: build() 里监听整个 conversationsProvider 再线性查找当前会话，任意会话更新触发整页 rebuild。
- **修复**: 使用 Step 3 修复后的精确 provider，直接获取当前会话数据。
- **预期产物**: ChatPage 只在自己的会话数据变更时才 rebuild。

### Step 5: [Medium] 优化设置页面无效 rebuild
- **文件**: `apps/aicove_flutter/lib/src/ui/features/settings/pages/settings_page.dart:52`
- **问题**: SettingsContent 订阅了整个 appSettingsProvider，但加载后值未参与渲染，设置修改会触发后台页面无效重建。
- **修复**: 使用 `.select()` 精确选择需要的字段，或拆分 provider。
- **预期产物**: 进入子设置页修改设置时，设置首页不再无效重建。

### Step 6: [Low] 修复 UI Gallery 页 dispose 缺失
- **文件**: `apps/aicove_flutter/lib/src/ui/features/debug/pages/ui_gallery_page.dart:18`
- **问题**: TextEditingController 未在 dispose() 中释放。
- **修复**: 添加 dispose() 方法并调用 controller.dispose()。
- **预期产物**: 开发调试页面资源正确释放。

## 关键文件

| 文件 | 操作 | 说明 |
|------|------|------|
| audio_player_widget.dart:306 | 修改 | 加 autoDispose，修复音频播放器泄漏 |
| conversation_timeline_providers.dart:44 | 修改 | 加 autoDispose，修复消息流泄漏 |
| conversation_providers.dart:297 | 修改 | 精确化 watch 范围，减少无效 rebuild |
| chat_page.dart:566 | 修改 | 使用精确 provider 替代全量列表查找 |
| settings_page.dart:52 | 修改 | 使用 select 精确订阅，消除无效重建 |
| ui_gallery_page.dart:18 | 修改 | 补 dispose() |

## 风险与缓解

| 风险 | 缓解措施 |
|------|----------|
| autoDispose 可能导致频繁重建 provider | 在需要跨页面保持状态的地方用 ref.keepAlive() 显式保活 |
| 精确化 watch 可能遗漏某些需要响应的变更 | 修改后逐项测试聊天功能，确认消息收发和显示正常 |
| 改动涉及聊天核心链路 | flutter run 全量验证，重点测试进出聊天和切换会话 |

## SESSION_ID（供 /ccg:execute 使用）
- CODEX_SESSION: 019cedb7-c09d-7a93-9ca2-46bccd028712
- CODEX_SESSION_2: 019cedb7-c09d-71b3-96db-ca08fcfc8123

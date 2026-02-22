/// 聊天相关的全局 Provider
/// 
/// 从 chat_actions.dart 提取的全局状态 Provider。
/// 
/// 更新记录：
/// - 2025-12-31: 从 chat_actions.dart 提取
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'presentation/widgets/momotalk_sort_dialog.dart' show SortMode;

// ===== 发送状态 =====

/// 是否正在发送消息
final sendingProvider = StateProvider<bool>((ref) => false);

/// 错误信息
final errorProvider = StateProvider<String?>((ref) => null);

// ===== 侧边栏状态 =====

/// 侧边栏可见性
final sidebarVisibleProvider = StateProvider<bool>((ref) => true);

// ===== 联系人列表排序状态 =====
// 遵循 DRY 原则：将排序状态提升到 Provider，供 ContactsPage 和 SplitChatPage 共享
// 更新记录：
// - 2025-12-06: 从 ContactsPage/SplitChatPage 提取，消除状态重复

/// 排序模式 Provider
final sortModeProvider = StateProvider<SortMode>((ref) => SortMode.latest);

/// 升序/降序 Provider
final sortAscendingProvider = StateProvider<bool>((ref) => false);

// ===== 模型轮询通知 =====

/// 模型切换通知（轮询时 UI 层监听此 Provider 弹 toast）
/// 值为正在尝试的模型名称，null 表示无通知
final modelFailoverInfoProvider = StateProvider<String?>((ref) => null);

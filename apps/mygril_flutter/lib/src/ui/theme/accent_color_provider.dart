/// 主题色状态管理
///
/// 管理全局主题强调色（AppBar、主按钮等共用）。
///
/// 更新记录：
/// - 2026-01-06: 创建主题色 Provider
/// - 2026-01-06: 重构为从 AppSettings 读取，保持数据流统一
/// - 2026-01-21: 改为支持任意颜色（十六进制存储）
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../features/settings/app_settings.dart';

/// 将十六进制字符串转换为 Color
Color _hexToColor(String hex) {
  final buffer = StringBuffer();
  if (hex.length == 6) buffer.write('FF');
  buffer.write(hex.toUpperCase());
  return Color(int.parse(buffer.toString(), radix: 16));
}

/// 当前主题色 Provider（返回 Color）
final accentColorProvider = Provider<Color>((ref) {
  final settingsAsync = ref.watch(appSettingsProvider);
  return settingsAsync.when(
    data: (s) => _hexToColor(s.accentColor),
    loading: () => const Color(0xFFFC96AA),
    error: (_, __) => const Color(0xFFFC96AA),
  );
});

/// 主题色设置操作扩展 (用于在 UI 中便捷修改)
extension AccentColorRefExtension on WidgetRef {
  void setAccentColor(Color color) {
    final hex = color.value.toRadixString(16).substring(2).toUpperCase();
    read(appSettingsProvider.notifier).setAccentColor(hex);
  }
}

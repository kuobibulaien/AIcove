/// 主题色状态管理
///
/// 管理全局主题强调色（AppBar、主按钮等共用），由当前界面皮肤决定。
///
/// 更新记录：
/// - 2026-01-06: 创建主题色 Provider
/// - 2026-01-06: 重构为从 AppSettings 读取，保持数据流统一
/// - 2026-01-21: 改为支持任意颜色（十六进制存储）
/// - 2026-09-23: 改为按界面皮肤解析，暗色默认金色
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../features/settings/app_settings.dart';

const _fallbackLightAccent = Color(0xFFFC96AA);

/// 浅色模式强调色
final accentColorProvider = Provider<Color>((ref) {
  return ref.watch(
        appSettingsProvider.select((s) => s.valueOrNull?.lightAccentColor),
      ) ??
      _fallbackLightAccent;
});

/// 暗色模式强调色
final darkAccentColorProvider = Provider<Color>((ref) {
  return ref.watch(
        appSettingsProvider.select((s) => s.valueOrNull?.darkAccentColor),
      ) ??
      kDefaultDarkAccentColor;
});

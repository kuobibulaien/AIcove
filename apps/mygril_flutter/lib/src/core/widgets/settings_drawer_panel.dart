/// 设置抽屉面板 - 公共组件
/// 
/// 遵循 DRY 原则：从 MainPage 和 SplitChatPage 中抽取的公共设置面板
/// 
/// 更新记录：
/// - 2025-12-06: 从 MainPage/SplitChatPage 抽取，消除代码重复
/// - 2025-12-06: 接入皮肤系统
/// - 2025-12-07: 使用 MoeAppBar 替换自定义头部，统一 AppBar 高度
import 'package:flutter/material.dart';
import '../theme/tokens.dart';
import 'moe_app_bar.dart';
import '../../features/chat/presentation/pages/settings_page.dart';

/// 设置抽屉面板内容组件
/// 
/// 用于 SettingsDrawerWrapper 的 settingsBuilder 参数
class SettingsDrawerPanel extends StatelessWidget {
  /// 关闭抽屉的回调
  final VoidCallback onClose;

  const SettingsDrawerPanel({
    super.key,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    
    return Scaffold(
      appBar: MoeAppBar(
        title: '设置',
        actions: [
          IconButton(
            icon: Icon(Icons.close, color: colors.headerContentColor),
            tooltip: '关闭',
            onPressed: onClose,
          ),
        ],
      ),
      backgroundColor: colors.surface,
      body: const SettingsContent(),
    );
  }
}

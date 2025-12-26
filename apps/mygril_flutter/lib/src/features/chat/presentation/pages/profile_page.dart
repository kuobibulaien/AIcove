import 'package:flutter/material.dart';
import '../../../../core/theme/tokens.dart';
import '../../../../core/widgets/moe_app_bar.dart';
import '../widgets/profile_content.dart';

/// 我的页面
/// 
/// 更新记录：
/// - 2025-12-06: 使用 MoeAppBar 替换原有 AppBar 样式
class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    return Scaffold(
      appBar: const MoeAppBar(title: '我的'),
      backgroundColor: colors.surface,
      body: const ProfileContent(),
    );
  }
}

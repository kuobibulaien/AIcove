import 'package:flutter/material.dart';
import '../../../../core/theme/tokens.dart';
import '../widgets/profile_content.dart';

/// 我的页面（占位）
class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: colors.headerColor,
        foregroundColor: colors.headerContentColor,
        elevation: 0,
        // 添加底部分割线
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(borderWidth),
          child: Container(
            color: colors.borderLight,
            height: borderWidth,
          ),
        ),
        title: Padding(
          padding: const EdgeInsets.only(left: 12),
          child: Text(
            '我的',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 24,
              color: colors.headerContentColor,
              letterSpacing: 0.8,
            ),
          ),
        ),
        centerTitle: false,
      ),
      backgroundColor: colors.surface,
      body: const ProfileContent(), // 复用内容组件
    );
  }
}

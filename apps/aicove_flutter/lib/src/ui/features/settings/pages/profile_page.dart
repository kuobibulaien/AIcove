import 'package:aicove_flutter/src/ui/shared/widgets/moe_page_scaffold.dart';
import 'package:flutter/material.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/widgets/moe_app_bar.dart';
import '../../../../features/chat/presentation/widgets/profile_content.dart';

/// 我的页面
///
/// 更新记录：
/// - 2025-12-06: 使用 MoeAppBar 替换原有 AppBar 样式
class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    return MoePageScaffold(
      appBar: const MoeAppBar(title: '个人资料', showBackButton: true),
      backgroundColor: colors.surface,
      body: const ProfileContent(),
    );
  }
}

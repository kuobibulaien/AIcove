/// EditSectionTitle - 编辑页通用区块标题
///
/// 从 ContactEditPage._buildSectionTitle 抽取，供各拆分子组件复用。
library;

import 'package:flutter/material.dart';

import '../../../../ui/theme/tokens.dart';

class EditSectionTitle extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const EditSectionTitle({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 18, color: colors.primary),
            const SizedBox(width: 8),
            Text(
              title,
              style: TextStyle(
                fontSize: 15,
                fontWeight: MoeFontWeights.emphasis,
                color: colors.text,
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(subtitle, style: TextStyle(fontSize: 12, color: colors.muted)),
      ],
    );
  }
}

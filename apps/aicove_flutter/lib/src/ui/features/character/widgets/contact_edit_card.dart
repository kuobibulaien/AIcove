/// ContactEditCard - 角色编辑页统一卡片容器
///
/// 与设置分组共享三态背景材质与主题底色。
library;

import 'package:flutter/material.dart';

import '../../../shared/widgets/moe_floating_surface.dart';
import '../../../theme/tokens.dart';

class ContactEditCard extends StatelessWidget {
  const ContactEditCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    return MoeFloatingSurface(
      baseline: MoeMaterialBaseline.text,
      radius: 16,
      padding: padding,
      solidColor: colors.componentBackground,
      shadows: const [],
      child: child,
    );
  }
}

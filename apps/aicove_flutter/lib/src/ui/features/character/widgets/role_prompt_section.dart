/// RolePromptSection - 角色编辑页：角色提示词
///
/// 单行入口，点击直接进入全屏编辑。角色专属的绘图要求在绘图预设的提示词里（ADR0092）。
library;

import 'package:flutter/material.dart';

import '../../../../ui/shared/widgets/index.dart';

class RolePromptSection extends StatelessWidget {
  final VoidCallback onEdit;

  const RolePromptSection({
    super.key,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    return MoeSettingsGroup(
      margin: EdgeInsets.zero,
      children: [
        MoeSettingsRow(label: '角色提示词', showDivider: false, onTap: onEdit),
      ],
    );
  }
}

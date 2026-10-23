/// CharacterAgentModeSection - 角色编辑页：角色模式（ADR0097）
///
/// 一行「角色模式」，行尾小号分段切换「聊天／工具」。
/// AIcove酱固定为工具模式，[locked] 时切换禁用。
library;

import 'package:flutter/material.dart';

import '../../../../features/chat/domain/role_agent_mode.dart';
import '../../../../ui/shared/widgets/index.dart';

class CharacterAgentModeSection extends StatelessWidget {
  final RoleAgentMode mode;
  final bool locked;
  final ValueChanged<RoleAgentMode> onChanged;

  const CharacterAgentModeSection({
    super.key,
    required this.mode,
    required this.locked,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return MoeSettingsGroup(
      margin: EdgeInsets.zero,
      children: [
        MoeSettingsRow(
          label: '角色模式',
          trailingType: MoeSettingsRowTrailing.custom,
          trailing: MoeSegmentedControl<RoleAgentMode>(
            value: mode,
            height: 28,
            expanded: false,
            segments: const [
              MoeSegment(value: RoleAgentMode.chat, label: '聊天'),
              MoeSegment(value: RoleAgentMode.tool, label: '工具'),
            ],
            onChanged: locked ? null : onChanged,
          ),
          showDivider: false,
        ),
      ],
    );
  }
}

/// CharacterAgentModeSection - 角色编辑页：角色模式（ADR0097）
///
/// 一行「角色模式」，行尾小号分段切换「纯聊天／工具／智能体」；放不下时
/// 行尾显示当前档位，点开底部菜单选择。
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

  static const _labels = {
    RoleAgentMode.chat: '纯聊天',
    RoleAgentMode.tool: '工具',
    RoleAgentMode.agent: '智能体',
  };

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 大字号或窄屏放不下三段时，改为显示当前档位，点开从底部菜单选。
        final inline = constraints.maxWidth >=
            MediaQuery.textScalerOf(context).scale(_inlineMinWidth);
        return MoeSettingsGroup(
          margin: EdgeInsets.zero,
          children: [
            if (inline)
              MoeSettingsRow(
                label: '角色模式',
                trailingType: MoeSettingsRowTrailing.custom,
                trailing: MoeSegmentedControl<RoleAgentMode>(
                  value: mode,
                  height: 28,
                  expanded: false,
                  segments: [
                    for (final entry in _labels.entries)
                      MoeSegment(value: entry.key, label: entry.value),
                  ],
                  onChanged: locked ? null : onChanged,
                ),
                showDivider: false,
              )
            else
              MoeSettingsRow(
                label: '角色模式',
                trailingType: MoeSettingsRowTrailing.text,
                detailText: _labels[mode],
                enabled: !locked,
                onTap: locked ? null : () => _pick(context),
                showDivider: false,
              ),
          ],
        );
      },
    );
  }

  void _pick(BuildContext context) {
    showMoeActionSheet(
      context: context,
      title: '角色模式',
      actions: [
        for (final entry in _labels.entries)
          MoeSheetAction(
            icon: entry.key == mode ? Icons.check_circle : Icons.circle_outlined,
            label: entry.value,
            onTap: () => onChanged(entry.key),
          ),
      ],
    );
  }

  /// 标题与三段切换同排所需的最小宽度（按 1 倍字号）。
  static const double _inlineMinWidth = 240;
}

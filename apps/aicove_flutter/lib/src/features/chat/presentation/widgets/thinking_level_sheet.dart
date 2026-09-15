/// 思考档位选择弹层。
///
/// 供聊天页（会话级覆盖）与设置页（模型默认）复用：调用方给出可选集合、
/// 当前生效值与来源，返回用户选中的档位；`null` 表示取消，
/// [ThinkingLevelSheetResult.cleared] 表示用户选择「清除本层设置」。
library;

import 'package:flutter/material.dart';

import '../../../../core/api/thinking/thinking_level.dart';
import '../../../../core/api/thinking/thinking_level_labels.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/theme/tokens.dart';

class ThinkingLevelSheetResult {
  final ThinkingLevel? level;
  final bool cleared;

  const ThinkingLevelSheetResult.selected(ThinkingLevel this.level)
      : cleared = false;
  const ThinkingLevelSheetResult.cleared()
      : level = null,
        cleared = true;
}

Future<ThinkingLevelSheetResult?> showThinkingLevelSheet(
  BuildContext context, {
  required String title,
  required ThinkingLevelOptions options,
  required ThinkingLevel current,
  required ThinkingLevelSource currentSource,

  /// 本层是否已有显式设置（决定是否显示「清除」项）。
  required bool hasOwnSetting,
  String? clearLabel,
}) {
  return showMoeBottomSheet<ThinkingLevelSheetResult>(
    context: context,
    title: title,
    useRootNavigator: true,
    builder: (_) => ThinkingLevelSheetBody(
      options: options,
      current: current,
      currentSource: currentSource,
      hasOwnSetting: hasOwnSetting,
      clearLabel: clearLabel ?? '清除本层设置',
    ),
  );
}

class ThinkingLevelSheetBody extends StatelessWidget {
  const ThinkingLevelSheetBody({
    super.key,
    required this.options,
    required this.current,
    required this.currentSource,
    required this.hasOwnSetting,
    required this.clearLabel,
  });

  final ThinkingLevelOptions options;
  final ThinkingLevel current;
  final ThinkingLevelSource currentSource;
  final bool hasOwnSetting;
  final String clearLabel;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final levels = options.levels;
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 16),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Text(
            options.isNative
                ? '此模型支持服务商原生档位。当前生效：'
                    '${thinkingLevelTitle(current, isNative: true)}'
                    '（${thinkingLevelSourceLabel(currentSource)}）'
                : '此模型使用通用四档，由应用翻译成服务商参数。当前生效：'
                    '${thinkingLevelTitle(current, isNative: false)}'
                    '（${thinkingLevelSourceLabel(currentSource)}）',
            style: TextStyle(fontSize: 12, color: colors.muted),
          ),
        ),
        MoeSettingsGroup(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          padding: EdgeInsets.zero,
          children: [
            for (var i = 0; i < levels.length; i++)
              DecoratedBox(
                key: ValueKey<String>('thinking_${levels[i].name}'),
                decoration: BoxDecoration(
                  border: i == levels.length - 1
                      ? null
                      : Border(
                          bottom: BorderSide(
                            color: colors.borderLight,
                            width: borderWidth,
                          ),
                        ),
                ),
                child: MoeListTile(
                  leading: Icon(
                    levels[i] == current
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    color:
                        levels[i] == current ? colors.primary : colors.muted,
                    size: 20,
                  ),
                  minLeadingWidth: 32,
                  title: Text(
                    thinkingLevelTitle(levels[i], isNative: options.isNative),
                  ),
                  subtitle: Text(thinkingLevelHint(levels[i])),
                  selected: levels[i] == current,
                  onTap: () => Navigator.of(context).pop(
                    ThinkingLevelSheetResult.selected(levels[i]),
                  ),
                ),
              ),
          ],
        ),
        if (hasOwnSetting) ...[
          const SizedBox(height: 12),
          MoeSettingsGroup(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            padding: EdgeInsets.zero,
            children: [
              MoeListTile(
                key: const ValueKey<String>('thinking_clear'),
                leading: Icon(Icons.restart_alt, color: colors.muted, size: 20),
                minLeadingWidth: 32,
                title: Text(clearLabel),
                onTap: () => Navigator.of(context).pop(
                  const ThinkingLevelSheetResult.cleared(),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

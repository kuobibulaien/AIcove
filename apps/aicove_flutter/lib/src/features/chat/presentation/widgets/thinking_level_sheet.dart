/// 思考档位选择弹层。
///
/// 供聊天页（会话级覆盖）与设置页（模型默认）复用：调用方给出可选集合、
/// 当前生效值与来源，返回用户选中的档位；`null` 表示取消，
/// [ThinkingLevelSheetResult.cleared] 表示用户选择「清除本层设置」，
/// [ThinkingLevelSheetResult.redetect] 表示清掉「最低」档的记忆重新试。
library;

import 'package:flutter/material.dart';

import '../../../../core/api/thinking/thinking_level.dart';
import '../../../../core/api/thinking/thinking_level_labels.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/theme/tokens.dart';

class ThinkingLevelSheetResult {
  final ThinkingLevel? level;
  final bool cleared;
  final bool redetect;

  const ThinkingLevelSheetResult.selected(ThinkingLevel this.level)
      : cleared = false,
        redetect = false;
  const ThinkingLevelSheetResult.cleared()
      : level = null,
        cleared = true,
        redetect = false;
  const ThinkingLevelSheetResult.redetect()
      : level = null,
        cleared = false,
        redetect = true;
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

  /// 「最低」档已试出并记住的上游档位；非空时显示「重新检测」。
  ThinkingLevel? lowestResolved,
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
      lowestResolved: lowestResolved,
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
    this.lowestResolved,
  });

  final ThinkingLevelOptions options;
  final ThinkingLevel current;
  final ThinkingLevelSource currentSource;
  final bool hasOwnSetting;
  final String clearLabel;
  final ThinkingLevel? lowestResolved;

  /// 副标题只有一行：「最低」已试出档位时直接显示结果，代替通用说明。
  String _subtitle(ThinkingLevel level) {
    final resolved = lowestResolved;
    if (!level.isLowest || resolved == null) return thinkingLevelHint(level);
    return '本渠道已试出：'
        '${thinkingLevelTitle(resolved, isNative: options.isNative)}';
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final levels = options.choices;
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 16),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Text(
            '当前：${thinkingLevelTitle(current, isNative: options.isNative)}'
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
                  subtitle: Text(_subtitle(levels[i])),
                  selected: levels[i] == current,
                  onTap: () => Navigator.of(context).pop(
                    ThinkingLevelSheetResult.selected(levels[i]),
                  ),
                ),
              ),
          ],
        ),
        if (hasOwnSetting || lowestResolved != null) ...[
          const SizedBox(height: 12),
          MoeSettingsGroup(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            padding: EdgeInsets.zero,
            children: [
              if (lowestResolved != null)
                MoeListTile(
                  key: const ValueKey<String>('thinking_redetect'),
                  leading: Icon(Icons.refresh, color: colors.muted, size: 20),
                  minLeadingWidth: 32,
                  title: const Text('重新检测最低档'),
                  subtitle: const Text('下次发送时从「关」重新试'),
                  onTap: () => Navigator.of(context).pop(
                    const ThinkingLevelSheetResult.redetect(),
                  ),
                ),
              if (hasOwnSetting)
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

/// SillyTavern 预设绑定共用小部件与导入摘要。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/agent_context/domain/silly_tavern_preset.dart';
import '../../../../features/agent_context/providers/preset_recipe_provider.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/theme/tokens.dart';

/// 角色已绑定预设的显示名。
String tavernPresetDisplayName(
  List<PresetRecipeSummary> presets,
  String? selectedRecipeId,
) {
  if (selectedRecipeId == null) return '跟随插件默认预设';
  final preset = presets.where((p) => p.id == selectedRecipeId).firstOrNull;
  return preset?.name ?? '绑定预设缺失，请重新选择';
}

/// 酒馆预设选择弹窗。[onChanged] 收到 null 表示改为跟随插件默认预设。
Future<void> showTavernPresetPicker({
  required BuildContext context,
  required String? selectedRecipeId,
  required ValueChanged<String?> onChanged,
}) async {
  await showMoeBottomSheet<void>(
    context: context,
    title: '选择酒馆预设',
    showCloseButton: true,
    builder: (context) {
      return Consumer(
        builder: (context, sheetRef, child) {
          final colors = context.moeColors;
          final livePresets = sheetRef
                  .watch(presetRecipeListProvider)
                  .valueOrNull ??
              const <PresetRecipeSummary>[];
          return SafeArea(
            minimum: const EdgeInsets.only(bottom: 24),
            child: Column(
              mainAxisSize: MainAxisSize.max,
              children: [
                ListTile(
                  leading: Icon(Icons.auto_mode, color: colors.primary),
                  title: const Text('跟随插件默认预设'),
                  subtitle: const Text('未设默认预设或插件关闭时，使用原有上下文'),
                  trailing: selectedRecipeId == null
                      ? Icon(Icons.check, color: colors.primary)
                      : null,
                  onTap: () {
                    onChanged(null);
                    Navigator.of(context).pop();
                  },
                ),
                if (livePresets.isNotEmpty) const Divider(height: 1),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: livePresets.length,
                    itemBuilder: (context, index) {
                      final preset = livePresets[index];
                      final isSelected = selectedRecipeId == preset.id;
                      return ListTile(
                        leading: Icon(
                          preset.warningCount > 0
                              ? Icons.warning_amber_outlined
                              : Icons.auto_awesome_outlined,
                        ),
                        title: Text(preset.name),
                        subtitle: Text(preset.description),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (isSelected)
                              Icon(Icons.check, color: colors.primary),
                          ],
                        ),
                        onTap: () {
                          onChanged(preset.id);
                          Navigator.of(context).pop();
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        },
      );
    },
  );
}

/// 导入前展示预设覆盖能力、兼容状态与 regex 授权范围。
class PresetImportSummary extends StatelessWidget {
  final SillyTavernPreset preset;
  final bool regexAuthorized;
  final ValueChanged<bool> onRegexAuthorizationChanged;

  const PresetImportSummary({
    super.key,
    required this.preset,
    required this.regexAuthorized,
    required this.onRegexAuthorizationChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 420),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              preset.name,
              style: TextStyle(
                color: colors.text,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '${preset.prompts.length} 个 prompt · '
              '${preset.enabledPromptCount} 个启用 · '
              '${preset.markerCount} 个 marker · '
              '${preset.absoluteInjectionCount} 个深度注入',
              style: TextStyle(color: colors.muted),
            ),
            const SizedBox(height: 4),
            Text(
              '${preset.promptOrderGroups.length} 组顺序 · '
              '${preset.regexScriptCount} 条 regex · '
              '采用第 ${preset.selectedOrder.sourceIndex + 1} 组',
              style: TextStyle(color: colors.muted),
            ),
            const SizedBox(height: 6),
            Text(
              '${preset.rawPreset.length} 个顶层字段：'
              '已应用 ${preset.parameterStatusCount(SillyTavernParameterStatus.applied, topLevelOnly: true)} · '
              '不适用 ${preset.parameterStatusCount(SillyTavernParameterStatus.notApplicable, topLevelOnly: true)} · '
              '明确不支持 ${preset.parameterStatusCount(SillyTavernParameterStatus.intentionallyUnsupported, topLevelOnly: true)}',
              style: TextStyle(color: colors.muted),
            ),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('查看参数生效明细'),
              children: [
                for (final entry in preset.parameterCompatibility)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        '${_statusLabel(entry.status)} ${entry.field}：${entry.reason}',
                        style: TextStyle(
                          color: entry.status ==
                                  SillyTavernParameterStatus
                                      .intentionallyUnsupported
                              ? colors.toastWarning
                              : colors.muted,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            if (preset.regexScriptCount > 0)
              SwitchListTile.adaptive(
                key: const ValueKey('authorize-preset-regex'),
                contentPadding: EdgeInsets.zero,
                title: Text('授权运行 ${preset.regexScriptCount} 条 regex'),
                subtitle: const Text('只改请求/显示副本，不改数据库原文'),
                value: regexAuthorized,
                onChanged: onRegexAuthorizationChanged,
              ),
            if (preset.temperature != null || preset.topP != null) ...[
              const SizedBox(height: 6),
              Text(
                '将覆盖采样参数：'
                '${preset.temperature == null ? '' : 'temperature=${preset.temperature} '}'
                '${preset.topP == null ? '' : 'top_p=${preset.topP}'}',
                style: TextStyle(color: colors.muted),
              ),
            ],
            if (preset.warnings.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                preset.warnings.map((warning) => '· $warning').join('\n'),
                style: TextStyle(color: colors.toastWarning, height: 1.45),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String _statusLabel(SillyTavernParameterStatus status) => switch (status) {
      SillyTavernParameterStatus.applied => '[已应用]',
      SillyTavernParameterStatus.notApplicable => '[不适用]',
      SillyTavernParameterStatus.intentionallyUnsupported => '[不支持]',
    };

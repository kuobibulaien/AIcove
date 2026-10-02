/// 酒馆兼容插件各页面共用的小部件与交互。
library;

import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../../features/agent_context/domain/silly_tavern_preset.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';

const int _maxImportBytes = 2 * 1024 * 1024;

/// 选择一个 JSON 文件；取消返回 null，超过 2 MB 直接拒绝。
Future<({String name, String source})?> pickTavernJson() async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['json'],
    withData: true,
  );
  if (result == null || result.files.isEmpty) return null;
  final file = result.files.single;
  if (file.size > _maxImportBytes) {
    throw const FormatException('文件超过 2 MB，已拒绝导入');
  }
  final bytes = file.bytes ?? await file.xFile.readAsBytes();
  if (bytes.length > _maxImportBytes) {
    throw const FormatException('文件超过 2 MB，已拒绝导入');
  }
  return (name: file.name, source: utf8.decode(bytes));
}

/// 执行一次用户操作，失败时用提示条说明原因。
Future<void> runTavernAction(
  BuildContext context,
  Future<void> Function() action, {
  String? success,
}) async {
  try {
    await action();
    if (success != null && context.mounted) MoeToast.success(context, success);
  } catch (error) {
    if (context.mounted) MoeToast.error(context, _describeError(error));
  }
}

String _describeError(Object error) => switch (error) {
  FormatException(:final message) => message,
  StateError(:final message) => message,
  _ => '$error',
};

/// 只读查看一段长文本（提示词正文、正则规则、世界书条目）。
Future<void> showTavernText(
  BuildContext context, {
  required String title,
  required String text,
}) => showMoeBottomSheet<void>(
  context: context,
  title: title,
  showCloseButton: true,
  maxHeight: MediaQuery.sizeOf(context).height * .75,
  builder: (context) => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
    child: SelectableText(
      text.trim().isEmpty ? '（空）' : text,
      style: TextStyle(
        fontSize: 14,
        height: 1.6,
        color: context.moeColors.text,
      ),
    ),
  ),
);

/// 行尾的小标记，例如「默认」。
class TavernBadge extends StatelessWidget {
  const TavernBadge(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: colors.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.bold,
          color: colors.primary,
        ),
      ),
    );
  }
}

/// 分组卡片里的一段说明文字。
class TavernNote extends StatelessWidget {
  const TavernNote(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => MoeSettingsGroup(
    padding: MoeSettingsLayout.contentPadding,
    children: [
      Text(
        text,
        style: TextStyle(
          fontSize: 13,
          height: 1.5,
          color: context.moeColors.muted,
        ),
      ),
    ],
  );
}

/// 普通副标题下追加一行警示文字。
Widget tavernSubtitle(
  BuildContext context,
  String text, {
  List<String> warnings = const [],
}) {
  final colors = context.moeColors;
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(text, style: TextStyle(fontSize: 13, color: colors.muted)),
      for (final warning in warnings)
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            warning,
            style: TextStyle(fontSize: 13, color: colors.toastWarning),
          ),
        ),
    ],
  );
}

/// 消息角色的中文名。
String tavernRoleLabel(String role) => switch (role) {
  'user' => '用户',
  'assistant' => 'AI',
  _ => '系统',
};

/// 导入来源、参数生效情况和导入提示。
class TavernPresetInfo extends StatelessWidget {
  const TavernPresetInfo({super.key, required this.preset});

  final SillyTavernPreset preset;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final muted = TextStyle(fontSize: 13, height: 1.5, color: colors.muted);
    int count(SillyTavernParameterStatus status) =>
        preset.parameterStatusCount(status, topLevelOnly: true);
    Widget heading(String text) => Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 6),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          fontWeight: MoeFontWeights.emphasis,
          color: colors.primary,
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '来自 ${preset.sourceFileName}',
          style: TextStyle(fontSize: 15, color: colors.text),
        ),
        const SizedBox(height: 4),
        Text(
          '${preset.prompts.length} 条提示词（启用 ${preset.enabledPromptCount}）'
          ' · ${preset.regexScriptCount} 条正则'
          ' · 使用第 ${preset.selectedOrder.sourceIndex + 1} 组顺序',
          style: muted,
        ),
        if (preset.temperature != null || preset.topP != null)
          Text(
            '会覆盖采样参数：${[if (preset.temperature != null) 'temperature ${preset.temperature}', if (preset.topP != null) 'top_p ${preset.topP}'].join('，')}',
            style: muted,
          ),
        heading('参数生效情况'),
        Text(
          '${preset.rawPreset.length} 个顶层字段：'
          '生效 ${count(SillyTavernParameterStatus.applied)} · '
          '不适用 ${count(SillyTavernParameterStatus.notApplicable)} · '
          '不支持 ${count(SillyTavernParameterStatus.intentionallyUnsupported)}',
          style: muted,
        ),
        const SizedBox(height: 6),
        for (final entry in preset.parameterCompatibility)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              '${_statusLabel(entry.status)}  ${entry.field}：${entry.reason}',
              style: TextStyle(
                fontSize: 12,
                height: 1.45,
                color:
                    entry.status ==
                        SillyTavernParameterStatus.intentionallyUnsupported
                    ? colors.toastWarning
                    : colors.muted,
              ),
            ),
          ),
        if (preset.warnings.isNotEmpty) ...[
          heading('导入提示'),
          for (final warning in preset.warnings)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '· $warning',
                style: TextStyle(
                  fontSize: 13,
                  height: 1.45,
                  color: colors.toastWarning,
                ),
              ),
            ),
        ],
      ],
    );
  }
}

String _statusLabel(SillyTavernParameterStatus status) => switch (status) {
  SillyTavernParameterStatus.applied => '生效',
  SillyTavernParameterStatus.notApplicable => '不适用',
  SillyTavernParameterStatus.intentionallyUnsupported => '不支持',
};

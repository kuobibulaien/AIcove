import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/app_logger.dart';
import '../../../../features/chat/chat_providers.dart';
import '../../../../features/chat/domain/model_request_error_report.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/moe_interaction_theme.dart';
import '../../../theme/tokens.dart';

/// 模型请求失败弹窗主体：突出主要原因，并提供本轮完整报错日志复制。
class ModelFailoverErrorContent extends StatelessWidget {
  const ModelFailoverErrorContent({super.key, required this.request});

  final ModelFailoverPromptRequest request;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final summary = ModelRequestErrorReport.summarize(request.errorMessage);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          key: const ValueKey('model_failover_error_summary'),
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(12),
          ),
          child: SelectableText(
            summary,
            style: TextStyle(
              fontSize: 15,
              height: 1.5,
              fontWeight: MoeFontWeights.emphasis,
              color: colors.text,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          '“${request.failedModelName}”请求失败，可重试，或切换到“${request.nextModelName}”。',
          style: TextStyle(fontSize: 13, color: colors.textSecondary),
        ),
        const SizedBox(height: 4),
        TextButton.icon(
          key: const ValueKey('model_failover_copy_log'),
          onPressed: () => _copyFullLog(context),
          style: withoutHoverFeedback(TextButton.styleFrom(
            foregroundColor: colors.accentColor,
            padding: const EdgeInsets.symmetric(vertical: 4),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          )),
          icon: const Icon(Icons.copy_rounded, size: 16),
          label: const Text(
            '复制完整报错日志（本轮）',
            style: TextStyle(fontSize: 14),
          ),
        ),
      ],
    );
  }

  Future<void> _copyFullLog(BuildContext context) async {
    final log = ModelRequestErrorReport.buildFullLog(
      failedModelName: request.failedModelName,
      nextModelName: request.nextModelName,
      errorMessage: request.errorMessage,
      errorDetail: request.errorDetail,
      roundStartedAt: request.roundStartedAt,
      failedAt: request.failedAt,
      logEntries: AppLogger.entries.value,
    );
    await Clipboard.setData(ClipboardData(text: log));
    if (context.mounted) {
      MoeToast.success(context, '已复制本轮报错日志');
    }
  }
}

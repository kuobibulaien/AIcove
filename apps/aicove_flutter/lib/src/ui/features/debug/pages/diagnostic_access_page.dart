import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../features/observability/frontend_diagnostics_provider.dart';
import '../../../theme/tokens.dart';
import '../../../shared/widgets/index.dart';

class DiagnosticAccessPage extends ConsumerStatefulWidget {
  const DiagnosticAccessPage({super.key});

  @override
  ConsumerState<DiagnosticAccessPage> createState() =>
      _DiagnosticAccessPageState();
}

class _DiagnosticAccessPageState extends ConsumerState<DiagnosticAccessPage> {
  bool _exporting = false;

  Future<void> _export() async {
    setState(() => _exporting = true);
    try {
      final bytes = await ref.read(diagnosticAccessProvider).exportBundle();
      if (!mounted) return;
      final mobile = Platform.isAndroid || Platform.isIOS;
      final path = await FilePicker.platform.saveFile(
        dialogTitle: '保存诊断包',
        fileName:
            'aicove_diagnostics_${DateTime.now().millisecondsSinceEpoch}.json',
        type: FileType.custom,
        allowedExtensions: ['json'],
        bytes: mobile ? bytes : null,
      );
      if (path == null) return;
      if (!mobile) await File(path).writeAsBytes(bytes, flush: true);
      if (mounted) MoeToast.success(context, '诊断包已保存，可直接交给电脑上的 Agent');
    } catch (_) {
      if (mounted) MoeToast.error(context, '诊断包保存失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final access = ref.watch(diagnosticAccessProvider);
    return MoePageScaffold(
      backgroundColor: colors.surface,
      appBar: const MoeAppBar(title: '诊断导出与电脑读取', showBackButton: true),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                'Release 正式版也能使用，无需换成 Debug。',
                style: TextStyle(color: colors.text),
              ),
              const SizedBox(height: 12),
              Text(
                '导出最近 7 天内可用的运行、错误与请求状态。'
                '不包含聊天正文、图片、密钥或数据库；记录缺失与截断会在包内说明。',
                style: TextStyle(color: colors.textSecondary),
              ),
              const SizedBox(height: 16),
              MoePrimaryButton(
                label: '保存诊断包',
                onPressed: _export,
                isLoading: _exporting,
                enabled: !_exporting,
              ),
              const SizedBox(height: 24),
              ValueListenableBuilder(
                valueListenable: access.session,
                builder: (context, session, _) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    MoeSettingsGroup(
                      margin: const EdgeInsets.symmetric(horizontal: 16),
                      children: [
                        MoeSettingsRow(
                          label: '允许电脑读取',
                          subtitle: session == null
                              ? '正在自动连接，暂不可用时会重试'
                              : '已自动开启，持续有效；应用重启后自动恢复',
                          trailingType: MoeSettingsRowTrailing.text,
                          detailText: session == null ? '连接中' : '已开启',
                          showDivider: false,
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Android：连接已授权的 USB 或无线 ADB，'
                      '将下方命令交给 Agent 在 Flutter 项目目录运行。'
                      '仅本机通道可访问，不开放局域网或公网。',
                      style: TextStyle(color: colors.textSecondary),
                    ),
                    if (session != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        '电脑命令持续有效，应用重启后无需重新复制。',
                        style: TextStyle(color: colors.textSecondary),
                      ),
                      const SizedBox(height: 8),
                      SelectableText(
                        session.command,
                        style: TextStyle(
                          color: colors.text,
                          fontFamily: 'monospace',
                        ),
                      ),
                      const SizedBox(height: 12),
                      MoePrimaryButton(
                        label: '复制电脑采集命令',
                        onPressed: () async {
                          await Clipboard.setData(
                            ClipboardData(text: session.command),
                          );
                          if (context.mounted) {
                            MoeToast.success(context, '已复制电脑采集命令');
                          }
                        },
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

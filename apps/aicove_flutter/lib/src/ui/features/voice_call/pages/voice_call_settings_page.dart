import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/voice_call/providers/voice_call_settings.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';

/// 语音插件下的「语音通话」子页面：通话是语音能力的一部分，不是独立插件。
class VoiceCallSettingsPage extends ConsumerWidget {
  const VoiceCallSettingsPage({super.key});

  Future<void> _select(
    BuildContext context,
    WidgetRef ref,
    CallRecognizerSource source,
  ) async {
    try {
      await ref.read(callRecognizerSourceProvider.notifier).set(source);
    } catch (e) {
      if (context.mounted) MoeToast.error(context, e.toString());
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.moeColors;
    final source = ref.watch(callRecognizerSourceProvider).valueOrNull;
    final readiness = ref.watch(callRecognizerReadinessProvider).valueOrNull;
    final localText = readiness == null
        ? null
        : readiness.localInstalled
        ? '本机已安装，识别不经过网络'
        : '本机还没有安装';
    final aliyunText = readiness == null
        ? null
        : readiness.aliyunConfigured
        ? '使用模型供应商里的阿里云密钥，录音会发送到阿里云'
        : '还没有配置阿里云百炼密钥';
    final autoText = readiness == null
        ? null
        : readiness.localInstalled
        ? '当前会用本地模型'
        : readiness.aliyunConfigured
        ? '本地模型未安装，当前会用阿里云百炼'
        : '本地模型和阿里云都还不可用';

    Widget option(
      CallRecognizerSource value,
      IconData icon,
      String label,
      String? subtitle, {
      bool showDivider = true,
    }) => MoeSettingsRow(
      icon: icon,
      label: label,
      subtitle: subtitle,
      showDivider: showDivider,
      trailingType: MoeSettingsRowTrailing.custom,
      trailing: source == value
          ? Icon(Icons.check, color: colors.primary, size: 18)
          : const SizedBox.shrink(),
      onTap: () => _select(context, ref, value),
    );

    return MoePageScaffold(
      backgroundColor: colors.surface,
      appBar: const MoeAppBar(title: '语音 · 语音通话', showBackButton: true),
      body: SafeArea(
        child: MoeSettingsContent(
          child: ListView(
            padding: MoeSettingsLayout.verticalListPadding,
            children: [
              MoeSettingsGroup(
                title: '语音识别',
                titleFirst: true,
                children: [
                  option(
                    CallRecognizerSource.auto,
                    Icons.auto_mode_outlined,
                    '自动',
                    autoText,
                  ),
                  option(
                    CallRecognizerSource.local,
                    Icons.phone_android_outlined,
                    '本地模型',
                    localText,
                  ),
                  option(
                    CallRecognizerSource.aliyun,
                    Icons.cloud_outlined,
                    '阿里云百炼',
                    aliyunText,
                    showDivider: false,
                  ),
                ],
              ),
              const SizedBox(height: MoeSettingsLayout.sectionGap),
              MoeSettingsGroup(
                padding: MoeSettingsLayout.contentPadding,
                children: [
                  Text(
                    '仅支持 Fish Audio 音色；挂断后会自动生成通话摘要。',
                    style: TextStyle(color: colors.textSecondary, height: 1.5),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

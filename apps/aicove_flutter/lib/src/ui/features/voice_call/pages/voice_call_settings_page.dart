import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/voice_call/data/local_asr_model_installer.dart';
import '../../../../features/voice_call/providers/voice_call_settings.dart';
import '../../settings/pages/add_provider_sheet.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';

final _modelSizeMb =
    (kLocalCallAsrModelFiles.fold(0, (sum, f) => sum + f.size) / 1024 / 1024)
        .round();

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
      return;
    }
    final missing = ref
        .read(callRecognizerReadinessProvider)
        .valueOrNull
        ?.cloud
        .where((o) => o.source == source && !o.ready)
        .firstOrNull
        ?.missing;
    if (missing != null && context.mounted) {
      MoeToast.warning(context, '这个渠道还缺 $missing，请到渠道商里填写后再通话');
    }
    // 选了本地却还没装：直接问要不要下载，别让用户自己找入口。
    final readiness = ref.read(callRecognizerReadinessProvider).valueOrNull;
    if (source == CallRecognizerSource.local &&
        readiness?.localInstalled == false &&
        !ref.read(localCallModelInstallProvider).downloading &&
        context.mounted) {
      await _confirmInstall(context, ref);
    }
  }

  Future<void> _confirmInstall(BuildContext context, WidgetRef ref) async {
    final ok = await showMeoTalkConfirm(
      context: context,
      title: '下载本地识别模型',
      message: '本地模型还没有安装。下载约 $_modelSizeMb MB，装好后识别在本机完成，录音不经过网络。',
      hint: '建议连接 Wi-Fi 下载；离开本页不会中断下载。',
      confirmText: '下载',
    );
    if (ok == true) {
      unawaited(ref.read(localCallModelInstallProvider.notifier).install());
    }
  }

  Future<void> _confirmUninstall(BuildContext context, WidgetRef ref) async {
    final ok = await showMeoTalkConfirm(
      context: context,
      title: '删除本地识别模型',
      message: '删除后本地识别不可用，需要时可以重新下载。',
      confirmText: '删除',
      isDanger: true,
    );
    if (ok != true) return;
    try {
      await ref.read(localCallModelInstallProvider.notifier).uninstall();
    } catch (e) {
      if (context.mounted) MoeToast.error(context, e.toString());
    }
  }

  Widget _modelRow(
    BuildContext context,
    WidgetRef ref,
    CallRecognizerReadiness? readiness,
  ) {
    final colors = context.moeColors;
    final install = ref.watch(localCallModelInstallProvider);
    if (install.downloading) {
      final mb = (install.received / 1024 / 1024).round();
      return MoeSettingsRow(
        icon: Icons.downloading_outlined,
        label: '正在下载 ${(install.progress * 100).floor()}%',
        subtitleWidget: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LinearProgressIndicator(
                value: install.progress,
                color: colors.primary,
                backgroundColor: colors.primary.withValues(alpha: 0.15),
              ),
              const SizedBox(height: 4),
              Text(
                '$mb / ${(install.total / 1024 / 1024).round()} MB',
                style: TextStyle(fontSize: 12, color: colors.textSecondary),
              ),
            ],
          ),
        ),
        showDivider: false,
        trailingType: MoeSettingsRowTrailing.custom,
        trailing: IntrinsicWidth(
          child: MoeSecondaryButton(
            label: '取消',
            size: MoeSecondaryButtonSize.sm,
            onPressed: ref.read(localCallModelInstallProvider.notifier).cancel,
          ),
        ),
      );
    }
    if (readiness?.localInstalled == true) {
      return MoeSettingsRow(
        icon: Icons.check_circle_outline,
        label: '已安装',
        subtitle: 'SenseVoice＋Silero VAD，约 $_modelSizeMb MB',
        showDivider: false,
        trailingType: MoeSettingsRowTrailing.custom,
        trailing: IntrinsicWidth(
          child: MoeSecondaryButton(
            label: '删除',
            size: MoeSecondaryButtonSize.sm,
            foregroundColor: colors.toastError,
            onPressed: () => _confirmUninstall(context, ref),
          ),
        ),
      );
    }
    return MoeSettingsRow(
      icon: Icons.download_outlined,
      label: install.error == null ? '下载本地识别模型' : '下载失败，点按重试',
      subtitle: install.error ?? '约 $_modelSizeMb MB，建议连接 Wi-Fi',
      showDivider: false,
      onTap: readiness == null ? null : () => _confirmInstall(context, ref),
    );
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
        : '本机还没有安装，点按下载';
    final cloud = readiness?.cloud ?? const <CloudRecognizerOption>[];
    final firstReady = readiness?.firstReadyCloud;
    final autoText = readiness == null
        ? null
        : readiness.localInstalled
        ? '当前会用本地模型'
        : firstReady != null
        ? '本地模型未安装，当前会用 ${firstReady.label}'
        : '本地模型和语音识别渠道都还不可用';

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
                  for (final item in cloud)
                    option(
                      item.source,
                      Icons.cloud_outlined,
                      item.label,
                      item.ready
                          ? '${item.format.label}，录音会发送到该厂商'
                          : '还缺 ${item.missing}，请在渠道商里填写',
                    ),
                  MoeSettingsRow(
                    icon: Icons.add,
                    label: '添加语音识别渠道',
                    subtitle: cloud.isEmpty
                        ? '支持阿里云、火山引擎、腾讯云、讯飞、OpenAI、Deepgram、ElevenLabs'
                        : null,
                    showDivider: false,
                    onTap: () => showAddProviderSheet(
                      context,
                      initialCategory: ProviderCategory.stt,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: MoeSettingsLayout.sectionGap),
              MoeSettingsGroup(
                title: '本地识别模型',
                titleFirst: true,
                children: [_modelRow(context, ref, readiness)],
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

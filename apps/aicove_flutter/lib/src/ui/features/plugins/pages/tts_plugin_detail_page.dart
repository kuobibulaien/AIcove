import 'package:flutter/material.dart';
import '../../../shared/animations/parallax_slide_page_route.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/plugins/plugin_providers.dart';
import '../../../../features/plugins/tts/tts_config.dart';
import '../../../../features/plugins/tts/voice_preset_application.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';
import '../widgets/voice_preset_list.dart';
import 'voice_preset_editor_page.dart';

/// The plugin manages the complete library, never an active vendor's subset.
class TtsPluginDetailPage extends ConsumerWidget {
  const TtsPluginDetailPage({super.key});

  Future<void> _openPreset(
    BuildContext context,
    WidgetRef ref,
    VoicePreset preset,
  ) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: Text(preset.name),
              subtitle: const Text('修改共享预设会影响绑定它的角色'),
            ),
            ListTile(
              title: const Text('编辑与试听'),
              onTap: () => Navigator.pop(context, 'edit'),
            ),
            ListTile(
              title: Text(
                ref.read(ttsPluginConfigProvider).defaultVoicePresetId ==
                        preset.id
                    ? '取消默认预设'
                    : '设为默认预设',
              ),
              subtitle: const Text('只用于没有单独绑定音色的角色'),
              onTap: () => Navigator.pop(context, 'default'),
            ),
            ListTile(
              title: const Text('移除预设'),
              subtitle: const Text('不删除云端音色和参考文件'),
              onTap: () => Navigator.pop(context, 'remove'),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted || action == null) return;
    if (action == 'edit') {
      await Navigator.of(context).push(
        ParallaxSlidePageRoute(page: VoicePresetEditorPage(preset: preset)),
      );
      return;
    }
    try {
      if (action == 'default') {
        await ref
            .read(ttsPluginConfigProvider.notifier)
            .setDefaultPreset(
              ref.read(ttsPluginConfigProvider).defaultVoicePresetId ==
                      preset.id
                  ? null
                  : preset.id,
            );
      } else {
        final port = ref.read(voicePresetApplicationProvider);
        final roles = await port.references(preset.id);
        if (!context.mounted) return;
        if (roles.isNotEmpty) {
          MoeToast.warning(context, '请先更换这些角色的音色：${roles.join('、')}');
          return;
        }
        final config = ref.read(ttsPluginConfigProvider);
        final confirmed = await showMeoTalkDialog(
          context: context,
          title: '移除音色预设',
          content: Text(
            '确定移除「${preset.name}」？${config.defaultVoicePresetId == preset.id ? '\n这会清除默认预设，未绑定角色将暂时无法发声。' : ''}',
          ),
          confirmText: '移除',
          isDanger: true,
        );
        if (confirmed != true || !context.mounted) return;
        await port.remove(preset.id);
      }
      if (context.mounted) MoeToast.success(context, '已保存');
    } catch (e) {
      if (context.mounted) MoeToast.error(context, e.toString());
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ready = ref.watch(voicePresetReadyProvider);
    final config = ref.watch(ttsPluginConfigProvider);
    final settings = ref.watch(appSettingsProvider).valueOrNull;
    final colors = context.moeColors;
    return MoePageScaffold(
      backgroundColor: colors.surface,
      appBar: const MoeAppBar(title: '语音 · 音色预设', showBackButton: true),
      body: SafeArea(
        child: MoeSettingsContent(
          child: ready.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('语音配置加载失败：$error'),
                  TextButton(
                    onPressed: () => ref.invalidate(voicePresetReadyProvider),
                    child: const Text('重试'),
                  ),
                ],
              ),
            ),
            data: (_) => VoicePresetList(
              presets: config.voicePresets,
              defaultId: config.defaultVoicePresetId,
              providerNames: {
                for (final p in settings?.providers ?? [])
                  p.id: p.displayName ?? p.id,
              },
              padding: MoeSettingsLayout.verticalListPadding,
              header: MoeSettingsGroup(
                padding: MoeSettingsLayout.contentPadding,
                children: [
                  const Text('每个角色绑定一套预设，渠道、模型和音色一起生效。'),
                  const SizedBox(height: 12),
                  MoePrimaryButton(
                    label: '新建预设',
                    onPressed: () => Navigator.of(context).push(
                      ParallaxSlidePageRoute(
                        page: const VoicePresetEditorPage(),
                      ),
                    ),
                  ),
                ],
              ),
              onSelect: (preset) {
                if (preset != null) _openPreset(context, ref, preset);
              },
            ),
          ),
        ),
      ),
    );
  }
}

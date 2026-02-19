/// TtsPluginDetailPage - TTS 插件详细设置页面
///
/// 显示和管理 TTS 语音合成插件的配置。
///
/// 重构记录：
/// - 2025-12-31: 拆分为多个组件文件，主页面精简至约120行
///   - 提取 TtsSettingsForm 设置表单组件
///   - 提取 TtsTestSection 测试功能组件
///   - 提取 TtsHelpSection 帮助说明组件
///   - 预设选择改用底部弹窗 (MoeActionSheet)
/// - 2026-01-25: 用公共组件重构界面（MoeSettingsGroup/Row）
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../features/plugins/plugin_providers.dart';
import '../widgets/tts_settings_form.dart';
import '../widgets/tts_test_section.dart';
import '../widgets/tts_help_section.dart';

/// TTS 插件详细设置页面
class TtsPluginDetailPage extends ConsumerWidget {
  const TtsPluginDetailPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(ttsPluginConfigProvider);
    final notifier = ref.read(ttsPluginConfigProvider.notifier);
    final colors = context.moeColors;

    return Scaffold(
      backgroundColor: colors.surface,
      appBar: AppBar(
        backgroundColor: colors.surface,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: colors.text),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          '语音合成 (TTS)',
          style: TextStyle(
            color: colors.text,
            fontSize: 18,
            fontWeight: MoeFontWeights.emphasis,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 启用开关
          MoeSettingsGroup(
            margin: EdgeInsets.zero,
            children: [
              MoeSettingsRow(
                icon: Icons.power_settings_new,
                label: '启用插件',
                subtitle: '开启后 AI 可以发送语音消息',
                trailingType: MoeSettingsRowTrailing.switchControl,
                switchValue: config.enabled,
                onSwitchChanged: (value) async {
                  await notifier.setEnabled(value);
                },
                showDivider: false,
              ),
            ],
          ),
          const SizedBox(height: 24),

          // 设置表单（仅在启用时显示）
          if (config.enabled) ...[
            Text(
              '详细设置',
              style: TextStyle(
                color: colors.text,
                fontSize: 16,
                fontWeight: MoeFontWeights.emphasis,
              ),
            ),
            const SizedBox(height: 16),
            const TtsSettingsForm(),
            const SizedBox(height: 24),

            // 测试功能
            const TtsTestSection(),
            const SizedBox(height: 24),
          ],

          // 使用说明
          const TtsHelpSection(),
        ],
      ),
    );
  }
}

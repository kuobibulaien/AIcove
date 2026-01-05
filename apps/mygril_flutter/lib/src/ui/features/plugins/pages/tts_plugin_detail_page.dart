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
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../ui/theme/tokens.dart';
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
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 启用开关
            _buildEnableSwitch(config, notifier, colors),
            const SizedBox(height: 24),

            // 设置表单（仅在启用时显示）
            if (config.enabled) ...[
              Text(
                '详细设置',
                style: TextStyle(
                  color: colors.text,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
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
      ),
    );
  }

  /// 构建启用开关
  Widget _buildEnableSwitch(
    dynamic config,
    dynamic notifier,
    MoeColors colors,
  ) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        children: [
          Text(
            '启用插件',
            style: TextStyle(
              color: colors.text,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          Switch(
            value: config.enabled,
            onChanged: (value) async {
              await notifier.setEnabled(value);
            },
            activeColor: colors.primary,
          ),
        ],
      ),
    );
  }
}

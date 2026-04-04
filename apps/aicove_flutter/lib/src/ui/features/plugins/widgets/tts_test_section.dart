/// TtsTestSection - TTS 测试功能组件
///
/// 从 tts_plugin_detail_page.dart 提取，处理 TTS 测试功能。
///
/// 更新记录：
/// - 2025-12-31: 从 tts_plugin_detail_page.dart 提取
/// - 2026-01-15: 适配新的 TtsService 构造函数（从统一模型管理获取 API 配置）
/// - 2026-01-27: 删除阿里云音色列表，音色管理统一到 tts_settings_form.dart
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/models/message_block.dart';
import '../../../../features/plugins/plugin_providers.dart';
import '../../../../features/plugins/tts/tts_service.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../../features/chat/presentation/widgets/audio_player_widget.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/index.dart';

/// 测试状态枚举
enum TtsTestStatus { idle, testing, success, error }

/// TTS 测试功能组件
class TtsTestSection extends ConsumerStatefulWidget {
  const TtsTestSection({super.key});

  @override
  ConsumerState<TtsTestSection> createState() => _TtsTestSectionState();
}

class _TtsTestSectionState extends ConsumerState<TtsTestSection> {
  final _testTextController = TextEditingController(text: '你好，这是一段测试文本。');
  TtsTestStatus _testStatus = TtsTestStatus.idle;
  String? _testError;
  String? _testAudioUrl;

  @override
  void dispose() {
    _testTextController.dispose();
    super.dispose();
  }

  /// 测试 TTS 转换功能
  Future<void> _testTtsConversion() async {
    final testText = _testTextController.text.trim();
    if (testText.isEmpty) {
      MoeToast.warning(context, '请输入测试文本');
      return;
    }

    // 获取 TTS 配置
    final config = ref.read(ttsPluginConfigProvider);
    if (config.selectedProviderId == null) {
      MoeToast.warning(context, '请先选择 TTS 渠道');
      return;
    }

    if (config.selectedModelId == null) {
      MoeToast.warning(context, '请先选择 TTS 模型');
      return;
    }

    if (config.selectedVoicePresetId == null) {
      MoeToast.warning(context, '请先选择音色');
      return;
    }

    // 从 appSettingsProvider 获取 API 配置
    final appSettings = ref.read(appSettingsProvider).valueOrNull;
    if (appSettings == null) {
      MoeToast.warning(context, '设置加载中，请稍后重试');
      return;
    }

    // 现在通过模型类型标签选择 TTS 模型，不再要求渠道具有 'tts' capability
    final provider = appSettings.providers
        .where((p) => p.id == config.selectedProviderId)
        .firstOrNull;
    if (provider == null) {
      MoeToast.warning(context, '未找到选中的渠道');
      return;
    }

    setState(() {
      _testStatus = TtsTestStatus.testing;
      _testError = null;
      _testAudioUrl = null;
    });

    try {
      // 使用当前配置创建 TTS 服务
      final apiKey =
          provider.apiKeys.isNotEmpty ? provider.apiKeys.first : null;
      final service = TtsService(
        config: config,
        apiKey: apiKey,
        requestUrl: provider.apiBaseUrl,
        requestFormat:
            provider.customConfig['requestFormat'] as String? ?? 'openai_tts',
        model: config.selectedModelId,
      );

      // 调用转换
      final result = await service.convert(testText);

      if (result.success && result.audioUrl.isNotEmpty) {
        setState(() {
          _testStatus = TtsTestStatus.success;
          _testAudioUrl = result.audioUrl;
        });
        if (!mounted) return;
        MoeToast.success(context, '测试成功！音频已生成');
      } else {
        setState(() {
          _testStatus = TtsTestStatus.error;
          _testError = result.error ?? '转换失败，未知错误';
        });
      }
    } on TtsException catch (e) {
      setState(() {
        _testStatus = TtsTestStatus.error;
        _testError = e.message;
      });
    } catch (e) {
      setState(() {
        _testStatus = TtsTestStatus.error;
        _testError = '测试失败: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: MoeG2Decoration(
        radius: 12,
        color: colors.panel,
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题
          Row(
            children: [
              Icon(Icons.play_circle_outline, color: colors.primary, size: 20),
              const SizedBox(width: 8),
              Text(
                '测试功能',
                style: TextStyle(
                  color: colors.text,
                  fontSize: 16,
                  fontWeight: MoeFontWeights.emphasis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // 测试文本输入
          Text(
            '测试文本',
            style: TextStyle(
              color: colors.text,
              fontSize: 14,
              fontWeight: MoeFontWeights.emphasis,
            ),
          ),
          const SizedBox(height: 8),
          MoeTextField(
            controller: _testTextController,
            maxLines: 3,
            hint: '输入要测试转换的文本...',
            fillColor: colors.surface,
            borderColor: colors.border,
            focusBorderColor: colors.primary,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
          const SizedBox(height: 16),

          // 测试按钮
          SizedBox(
            width: double.infinity,
            child: MoePrimaryButton(
              label: _testStatus == TtsTestStatus.testing ? '测试中...' : '开始测试',
              icon: Icons.play_arrow,
              enabled: _testStatus != TtsTestStatus.testing,
              onPressed: _testTtsConversion,
            ),
          ),

          // 测试结果显示
          _buildTestResult(colors),
        ],
      ),
    );
  }

  Widget _buildTestResult(MoeColors colors) {
    if (_testStatus == TtsTestStatus.success && _testAudioUrl != null) {
      return Column(
        children: [
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: MoeG2Decoration(
              radius: 8,
              color: colors.primary.withValues(alpha: 0.1),
              border: Border.all(color: colors.primary.withValues(alpha: 0.3)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.check_circle, color: colors.primary, size: 18),
                    const SizedBox(width: 8),
                    Text(
                      '测试成功',
                      style: TextStyle(
                        color: colors.primary,
                        fontSize: 14,
                        fontWeight: MoeFontWeights.emphasis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                AudioPlayerWidget(
                  block: AudioBlock(
                    messageId: 'tts-test',
                    url: _testAudioUrl!,
                    text: _testTextController.text,
                  ),
                  textColor: colors.text,
                ),
              ],
            ),
          ),
        ],
      );
    }

    if (_testStatus == TtsTestStatus.error && _testError != null) {
      return Column(
        children: [
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: MoeG2Decoration(
              radius: 8,
              color: colors.accent.withValues(alpha: 0.1),
              border: Border.all(color: colors.accent.withValues(alpha: 0.3)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.error_outline, color: colors.accent, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '测试失败',
                        style: TextStyle(
                          color: colors.accent,
                          fontSize: 14,
                          fontWeight: MoeFontWeights.emphasis,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _testError!,
                        style: TextStyle(
                          color: colors.textSecondary,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }

    return const SizedBox.shrink();
  }
}

/// TtsTestSection - TTS 测试功能组件
/// 
/// 从 tts_plugin_detail_page.dart 提取，处理 TTS 测试功能。
/// 
/// 更新记录：
/// - 2025-12-31: 从 tts_plugin_detail_page.dart 提取
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/models/message_block.dart';
import '../../../../features/plugins/plugin_providers.dart';
import '../../../../features/plugins/tts/tts_service.dart';
import '../../../../features/chat/presentation/widgets/audio_player_widget.dart';
import '../../../../ui/theme/tokens.dart';
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

    setState(() {
      _testStatus = TtsTestStatus.testing;
      _testError = null;
      _testAudioUrl = null;
    });

    try {
      // 使用当前配置创建 TTS 服务
      final config = ref.read(ttsPluginConfigProvider);
      final service = TtsService(config);

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
      decoration: BoxDecoration(
        color: colors.panel,
        borderRadius: BorderRadius.circular(12),
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
                  fontWeight: FontWeight.w600,
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
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _testTextController,
            maxLines: 3,
            style: TextStyle(
              color: colors.text,
              fontSize: 14,
            ),
            decoration: InputDecoration(
              hintText: '输入要测试转换的文本...',
              hintStyle: TextStyle(
                color: colors.muted,
                fontSize: 14,
              ),
              filled: true,
              fillColor: colors.surface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: colors.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: colors.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: colors.primary, width: 2),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
            ),
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
            decoration: BoxDecoration(
              color: colors.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
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
                        fontWeight: FontWeight.w600,
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
            decoration: BoxDecoration(
              color: colors.accent.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
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
                          fontWeight: FontWeight.w600,
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

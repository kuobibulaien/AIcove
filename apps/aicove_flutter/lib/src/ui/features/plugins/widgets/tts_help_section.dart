/// TtsHelpSection - TTS 帮助说明组件
/// 
/// 从 tts_plugin_detail_page.dart 提取，显示 TTS 使用说明。
/// 
/// 更新记录：
/// - 2025-12-31: 从 tts_plugin_detail_page.dart 提取
library;

import 'package:flutter/material.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';

/// TTS 帮助说明组件
class TtsHelpSection extends StatelessWidget {
  const TtsHelpSection({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: MoeG2Decoration(
        radius: 12,
        color: colors.panel.withValues(alpha: 0.5),
        border: Border.all(
          color: colors.border.withValues(alpha: 0.5),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '使用说明',
                style: TextStyle(
                  color: colors.text,
                  fontSize: 14,
                  fontWeight: MoeFontWeights.emphasis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '启用后，AI 可以调用「speak」工具将文字转为语音播放。\n\n'
            '工作模式：\n'
            '• 支持工具调用的模型：使用原生 Tool Calling（更可靠）\n'
            '• 不支持的模型：自动降级为 <tts> 标记方式\n\n'
            '使用提示：\n'
            '• 在添加模型渠道时勾选"工具调用"能力可启用原生模式\n'
            '• 语音会按顺序自动转换和播放',
            style: TextStyle(
              color: colors.textSecondary,
              fontSize: 13,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

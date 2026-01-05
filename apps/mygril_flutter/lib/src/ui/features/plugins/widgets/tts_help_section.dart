/// TtsHelpSection - TTS 帮助说明组件
/// 
/// 从 tts_plugin_detail_page.dart 提取，显示 TTS 使用说明。
/// 
/// 更新记录：
/// - 2025-12-31: 从 tts_plugin_detail_page.dart 提取
library;

import 'package:flutter/material.dart';
import '../../../../ui/theme/tokens.dart';

/// TTS 帮助说明组件
class TtsHelpSection extends StatelessWidget {
  const TtsHelpSection({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.panel.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
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
              Icon(Icons.help_outline, color: colors.primary, size: 20),
              const SizedBox(width: 8),
              Text(
                '使用说明',
                style: TextStyle(
                  color: colors.text,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '启用 TTS 插件后，AI 会自动使用 <tts>文本</tts> 标记需要转换为语音的内容。\n\n'
            '标记规则：\n'
            '• 每个 <tts></tts> 标记内的文本不超过设定的字数限制\n'
            '• 超过限制的文本会自动拆分成多段\n'
            '• 一轮对话可以使用多个 <tts></tts> 标记\n'
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

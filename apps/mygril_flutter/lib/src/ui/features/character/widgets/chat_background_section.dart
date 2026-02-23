/// ChatBackgroundSection - 角色编辑页：聊天背景区
///
/// 从 ContactEditPage 拆分，负责聊天背景预览 + 上传/清除操作。
library;

import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';

import '../../../../core/utils/data_image.dart';
import '../../../../ui/shared/effects/frosted_glass_card.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/theme/tokens.dart';
import 'edit_section_title.dart';

class ChatBackgroundSection extends StatelessWidget {
  final TextEditingController chatBackgroundCtrl;
  final Uint8List? chatBackgroundBytes;
  final VoidCallback onPick;
  final VoidCallback onClear;

  const ChatBackgroundSection({
    super.key,
    required this.chatBackgroundCtrl,
    required this.chatBackgroundBytes,
    required this.onPick,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final hasBackground = chatBackgroundCtrl.text.trim().isNotEmpty;

    return FrostedGlassContainer(
      borderRadius: 16,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          EditSectionTitle(
            icon: Icons.image_outlined,
            title: '聊天背景',
            subtitle: '为当前会话设置单独背景图',
          ),
          const SizedBox(height: 8),
          if (hasBackground) ...[
            MoeG2ClipRRect(
              radius: 12,
              child: Container(
                width: double.infinity,
                height: 120,
                decoration: MoeG2Decoration(
                  radius: 12,
                  color: colors.surfaceAlt.withValues(alpha: 0.25),
                  border: Border.all(color: colors.borderLight, width: 0.5),
                ),
                child: _buildPreview(colors),
              ),
            ),
            const SizedBox(height: 8),
          ],
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onPick,
                  icon: const Icon(Icons.photo_library_outlined),
                  label: Text(hasBackground ? '更换背景' : '选择背景'),
                ),
              ),
              if (hasBackground) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onClear,
                    icon: const Icon(Icons.close),
                    label: const Text('清除'),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPreview(MoeColors colors) {
    final raw = chatBackgroundCtrl.text.trim();

    if (chatBackgroundBytes != null) {
      return Image.memory(chatBackgroundBytes!, fit: BoxFit.cover);
    }

    final bytes = decodeDataImage(raw);
    if (bytes != null) {
      return Image.memory(bytes, fit: BoxFit.cover);
    }

    if (raw.startsWith('http://') || raw.startsWith('https://')) {
      return Image.network(
        raw,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _buildFallback(colors),
      );
    }

    if (raw.startsWith('assets/') || raw.startsWith('packages/')) {
      return Image.asset(
        raw,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _buildFallback(colors),
      );
    }

    final file = File(raw);
    return Image.file(
      file,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => _buildFallback(colors),
    );
  }

  Widget _buildFallback(MoeColors colors) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.image_not_supported_outlined,
              size: 24, color: colors.muted),
          const SizedBox(height: 4),
          Text(
            '背景预览不可用',
            style: TextStyle(fontSize: 12, color: colors.muted),
          ),
        ],
      ),
    );
  }
}

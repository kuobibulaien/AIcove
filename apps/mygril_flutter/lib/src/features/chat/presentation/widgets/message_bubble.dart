import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mygril_flutter/src/core/utils/data_image.dart';
import '../../../../core/theme/tokens.dart';
import '../../../../core/models/message_block.dart';
import '../../domain/message.dart';
import '../../../settings/app_settings.dart';
import 'audio_player_widget.dart';

/// 消息气泡组件（支持多模态）
/// 遵循单一职责原则(S)：只负责消息的UI渲染
class MessageBubble extends ConsumerWidget {
  final bool isMe;
  final Message message; // 使用完整的Message对象
  final String? avatarUrl; // 仅用于左侧（AI）
  final String? displayName; // 对方名字（仅用于左侧）
  final VoidCallback? onRetry; // 重新发送回调
  final double fontSize; // 字体大小

  const MessageBubble({
    super.key,
    required this.isMe,
    required this.message,
    this.avatarUrl,
    this.displayName,
    this.onRetry,
    this.fontSize = 13.0,
  });

  /// 向后兼容：纯文本构造函数
  MessageBubble.text({
    super.key,
    required this.isMe,
    required String text,
    this.avatarUrl,
    this.displayName,
    this.onRetry,
    this.fontSize = 13.0,
  }) : message = Message.text(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          role: isMe ? 'user' : 'assistant',
          content: text,
        );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final bubbleColor = isMe
        ? (isDark ? moeBubbleRightBgDark : moeBubbleRightBg)
        : (isDark ? moeBubbleLeftBgDark : moeBubbleLeftBg);

    final fg = isMe
        ? Colors.white
        : (isDark ? moeBubbleLeftFgDark : moeBubbleLeftFg);

    final align = isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    
    // Momotalk 风格圆角：
    // AI (左侧): 左上角直角，其他圆角
    // User (右侧): 右上角直角，其他圆角
    final radius = BorderRadius.only(
      topLeft: isMe ? const Radius.circular(12) : Radius.zero,
      topRight: isMe ? Radius.zero : const Radius.circular(12),
      bottomLeft: const Radius.circular(12),
      bottomRight: const Radius.circular(12),
    );

    // 获取要渲染的blocks
    final blocks = message.blocks ?? [];
    final hasBlocks = blocks.isNotEmpty;

    // 检测消息是否发送失败
    final isFailed = isMe && message.status == 'failed';

    // 获取用户头像
    final settingsAsync = ref.watch(appSettingsProvider);
    final userAvatar = isMe ? settingsAsync.valueOrNull?.userAvatar : null;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isMe) ...[
            _Avatar(avatarUrl: avatarUrl),
            const SizedBox(width: 8),
          ],
          // 用户消息发送失败时显示红色感叹号（可点击重发）
          if (isFailed) ...[
            GestureDetector(
              onTap: onRetry,
              child: Container(
                width: 20,
                height: 20,
                margin: const EdgeInsets.only(top: 9, right: 4),
                decoration: const BoxDecoration(
                  color: Colors.red,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.priority_high,
                  color: Colors.white,
                  size: 14,
                ),
              ),
            ),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment: align,
              children: [
                // AI 消息上方显示名字
                if (!isMe && displayName != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4, left: 0),
                    child: Text(
                      displayName!,
                      style: TextStyle(
                        color: isDark ? Colors.grey[400] : Colors.grey[800],
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                
                // Render image blocks separately without bubble
                ..._buildImageBlocksOnly(blocks),
                // Render non-image blocks in bubble (text, audio, etc.)
                if (_shouldShowBubble(blocks))
                  Container(
                    margin: const EdgeInsets.symmetric(vertical: 0),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: bubbleColor,
                      borderRadius: radius,
                    ),
                    // Non-image content (text, audio, etc.)
                    child: hasBlocks
                        ? _buildNonImageBlocksContent(blocks, fg)
                        : Builder(
                            builder: (context) {
                              final text = message.displayText;
                              if (text.trim().isEmpty) {
                                // 空消息占位符（用于调试，避免完全不显示）
                                return Text(
                                  '[空消息]',
                                  style: TextStyle(
                                    color: fg.withOpacity(0.5),
                                    height: 1.42,
                                    fontSize: fontSize - 1,
                                    fontStyle: FontStyle.italic,
                                  ),
                                );
                              }
                              return Text(
                                text,
                                style: TextStyle(color: fg, height: 1.42, fontSize: fontSize),
                              );
                            },
                          ),
                  ),
              ],
            ),
          ),
          if (isMe) ...[
            const SizedBox(width: 8),
            _Avatar(avatarUrl: userAvatar, isUser: true),
          ],
        ],
      ),
    );
  }

  /// Check if bubble should be shown (for text, audio, etc., but not for images only)
  bool _shouldShowBubble(List<MessageBlock> blocks) {
    // If no blocks, show bubble for displayText (even if empty, will show placeholder)
    if (blocks.isEmpty) {
      return true;
    }
    // If has non-image blocks, show bubble
    return blocks.any((block) => block is! ImageBlock);
  }

  /// Build only image blocks without bubble wrapper
  List<Widget> _buildImageBlocksOnly(List<MessageBlock> blocks) {
    return blocks
        .whereType<ImageBlock>()
        .map((block) => _buildImageBlock(block))
        .toList();
  }

  /// Build only non-image blocks content for bubble (text, audio, code, etc.)
  Widget _buildNonImageBlocksContent(List<MessageBlock> blocks, Color textColor) {
    // Filter to only non-image blocks
    final nonImageBlocks = blocks.where((block) => block is! ImageBlock).toList();
    
    // Filter out empty text blocks
    final filteredBlocks = nonImageBlocks.where((block) {
      if (block is TextBlock) {
        return block.content.trim().isNotEmpty;
      }
      return true;
    }).toList();
    
    if (filteredBlocks.isEmpty) {
      return const SizedBox.shrink();
    }
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: filteredBlocks.map((block) => _buildBlock(block, textColor)).toList(),
    );
  }

  /// 根据Block类型渲染不同的组件
  Widget _buildBlock(MessageBlock block, Color textColor) {
    if (block is TextBlock) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(
          block.content,
          style: TextStyle(color: textColor, height: 1.42, fontSize: fontSize),
        ),
      );
    } else if (block is ImageBlock) {
      return _buildImageBlock(block);
    } else if (block is AudioBlock) {
      return _buildAudioBlock(block, textColor);
    } else if (block is CodeBlock) {
      return _buildCodeBlock(block, textColor);
    } else if (block is ThinkingBlock) {
      return _buildThinkingBlock(block, textColor);
    } else if (block is ErrorBlock) {
      return _buildErrorBlock(block);
    }
    // 其他类型暂不渲染
    return const SizedBox.shrink();
  }

  /// 渲染图片块
  Widget _buildImageBlock(ImageBlock block) {
    Widget imageWidget;
    
    // 优先显示本地图片
    if (block.localPath != null && block.localPath!.isNotEmpty) {
      imageWidget = Image.file(
        File(block.localPath!),
        width: 200,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Container(
          width: 200,
          height: 150,
          color: Colors.grey.shade300,
          child: const Icon(Icons.broken_image, color: Colors.grey),
        ),
      );
    } else if (block.url != null && block.url!.isNotEmpty) {
      imageWidget = Image.network(
        block.url!,
        width: 200,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Container(
          width: 200,
          height: 150,
          color: Colors.grey.shade300,
          child: const Icon(Icons.broken_image, color: Colors.grey),
        ),
      );
    } else if (block.base64 != null && block.base64!.isNotEmpty) {
      // 支持base64编码的图片
      final dataBytes = decodeDataImage('data:image/jpeg;base64,${block.base64}');
      if (dataBytes != null) {
        imageWidget = Image.memory(
          dataBytes,
          width: 200,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Container(
            width: 200,
            height: 150,
            color: Colors.grey.shade300,
            child: const Icon(Icons.broken_image, color: Colors.grey),
          ),
        );
      } else {
        imageWidget = Container(
          width: 200,
          height: 150,
          color: Colors.grey.shade300,
          child: const Icon(Icons.image, color: Colors.grey),
        );
      }
    } else {
      imageWidget = Container(
        width: 200,
        height: 150,
        color: Colors.grey.shade300,
        child: const Icon(Icons.image, color: Colors.grey),
      );
    }
    
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: imageWidget,
      ),
    );
  }

  /// 渲染音频块
  Widget _buildAudioBlock(AudioBlock block, Color textColor) {
    return AudioPlayerWidget(
      block: block,
      textColor: textColor,
    );
  }

  /// 渲染代码块
  Widget _buildCodeBlock(CodeBlock block, Color textColor) {
    return Container(
      margin: const EdgeInsets.only(top: 8, bottom: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.8),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            block.language,
            style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
          ),
          const SizedBox(height: 8),
          SelectableText(
            block.content,
            style: const TextStyle(
              color: Colors.white,
              fontFamily: 'monospace',
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  /// 渲染思考过程块（可折叠）
  Widget _buildThinkingBlock(ThinkingBlock block, Color textColor) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: Text(
          '思考过程',
          style: TextStyle(color: textColor, fontSize: fontSize + 1),
        ),
        children: [
          Text(
            block.content,
            style: TextStyle(color: textColor.withOpacity(0.8), fontSize: fontSize),
          ),
        ],
      ),
    );
  }

  /// 渲染错误块
  Widget _buildErrorBlock(ErrorBlock block) {
    return Container(
      margin: const EdgeInsets.only(top: 8, bottom: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red.shade100,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.red.shade300),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: Colors.red.shade700, size: 20),
          // 附加内容区域的水平分隔适当减半，保持一致
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              block.message,
              style: TextStyle(color: Colors.red.shade900, fontSize: fontSize + 1),
            ),
          ),
        ],
      ),
    );
  }
}

// MoeTalk 左侧小三角（.左角::after）- 已废弃，保留类定义以防其他地方引用（虽然现在不应该引用了）
class _LeftTrianglePainter extends CustomPainter {
  final Color color;
  _LeftTrianglePainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final path = Path()
      ..moveTo(size.width, 0)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height / 2)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// MoeTalk 右侧小三角（.右角::after）- 已废弃
class _RightTrianglePainter extends CustomPainter {
  final Color color;
  _RightTrianglePainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(0, size.height)
      ..lineTo(size.width, size.height / 2)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _Avatar extends StatelessWidget {
  final String? avatarUrl;
  final bool isUser;
  const _Avatar({required this.avatarUrl, this.isUser = false});
  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    // 优化头像大小：38px（原来的三分之二）
    Widget buildFallback() =>
        Center(child: Icon(isUser ? Icons.person : Icons.face, color: colors.muted, size: 20));

    Widget buildImage(String url) {
      final trimmed = url.trim();

      // 优先检查是否为本地文件路径（用户头像）
      if (isUser && File(trimmed).existsSync()) {
        return Image.file(
          File(trimmed),
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => buildFallback(),
        );
      }

      final dataBytes = decodeDataImage(trimmed);
      if (dataBytes != null) {
        return Image.memory(
          dataBytes,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => buildFallback(),
        );
      }
      final isNetwork = trimmed.startsWith('http://') || trimmed.startsWith('https://');
      // 支持本地 assets 头像，避免再渲染时丢失角色图片（KISS/SOLID）。
      if (!isNetwork && (trimmed.startsWith('assets/') || !trimmed.contains('://'))) {
        return Image.asset(
          trimmed,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => buildFallback(),
        );
      }
      return Image.network(
        trimmed,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => buildFallback(),
      );
    }

    final trimmedUrl = avatarUrl?.trim();
    return Container(
      width: 38,
      height: 38,
      margin: const EdgeInsets.only(right: 0, top: 0),
      decoration:
          BoxDecoration(borderRadius: BorderRadius.all(radiusBubble), color: colors.surfaceAlt),
      clipBehavior: Clip.antiAlias,
      child: trimmedUrl != null && trimmedUrl.isNotEmpty ? buildImage(trimmedUrl) : buildFallback(),
    );
  }
}

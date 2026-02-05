/// 消息气泡组件（支持多模态）
/// 遵循单一职责原则(S)：只负责消息的UI渲染
///
/// 更新记录：
/// - 2025-12-06: 接入皮肤系统（背景色、描边）
/// - 2025-01-15: 图片预览改用公共组件 MoeImagePreview
/// - 2026-01-18: 网络图片改用 CachedNetworkImageProvider 磁盘缓存
library;

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:mygril_flutter/src/core/utils/data_image.dart';
import '../../../../ui/theme/skin_provider.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../core/models/message_block.dart';
import '../../../../ui/shared/widgets/media/moe_image_preview.dart';
import '../../domain/message.dart';
import '../../../settings/app_settings.dart';
import 'audio_player_widget.dart';

/// 消息气泡组件（支持多模态）
/// 遵循单一职责原则(S)：只负责消息的UI渲染
class MessageBubble extends ConsumerWidget {
  final bool isMe;
  final Message message; // 使用完整的Message对象
  final String? avatarUrl; // 仅用于左侧（AI）
  final String? displayName; // 对方名字（仅用于群聊模式）
  final VoidCallback? onRetry; // 重新发送回调
  final void Function(GlobalKey bubbleKey)? onLongPress; // 长按回调（传递气泡Key用于定位菜单）
  final double fontSize; // 字体大小

  /// 是否显示直角（连续消息组的第一条且后面还有同发送者消息时为 true）
  /// false = 全圆角（单条消息或组的后续消息）
  final bool showCorner;

  /// 是否显示名称（群聊模式为 true，一对一聊天为 false）
  final bool showName;

  const MessageBubble({
    super.key,
    required this.isMe,
    required this.message,
    this.avatarUrl,
    this.displayName,
    this.onRetry,
    this.onLongPress,
    this.fontSize = 13.0,
    this.showCorner = false,
    this.showName = false,
  });

  /// 向后兼容：纯文本构造函数
  MessageBubble.text({
    super.key,
    required this.isMe,
    required String text,
    this.avatarUrl,
    this.displayName,
    this.onRetry,
    this.onLongPress,
    this.fontSize = 13.0,
    this.showCorner = false,
    this.showName = false,
  }) : message = Message.text(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          role: isMe ? 'user' : 'assistant',
          content: text,
        );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final skin = context.skin;
    final colors = context.moeColors;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // 从 MoeColors 读取气泡颜色（已适配深浅模式）
    final bubbleColor = isMe ? colors.bubbleRightBg : colors.bubbleLeftBg;
    final fg = isMe ? Colors.white : colors.bubbleLeftFg;

    final align = isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start;

    // 圆角逻辑：统一使用大圆角（一对一聊天简洁风格）
    final bubbleRadius = skin.bubbleRadius;

    // 获取要渲染的blocks
    final blocks = message.blocks ?? [];
    final hasBlocks = blocks.isNotEmpty;

    // 检测消息是否发送失败
    final isFailed = isMe && message.status == 'failed';

    // 获取用户头像和隐藏设置
    final settingsAsync = ref.watch(appSettingsProvider);
    final settings = settingsAsync.valueOrNull;
    final userAvatar = isMe ? settings?.userAvatar : null;
    final hideUserAvatar = settings?.hideUserAvatar ?? false;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        mainAxisAlignment:
            isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
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
                // 群聊模式下，AI 消息上方显示名字
                if (showName && !isMe && displayName != null)
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

                // Render image/sticker blocks separately without bubble
                ..._buildMediaBlocksOnly(context, blocks),
                // Render non-image blocks in bubble (text, audio, etc.)
                if (_shouldShowBubble(blocks))
                  Builder(
                    builder: (context) {
                      final bubbleKey =
                          GlobalKey(debugLabel: 'bubble_${message.id}');
                      return GestureDetector(
                        key: bubbleKey,
                        onLongPress: onLongPress != null
                            ? () => onLongPress!(bubbleKey)
                            : null,
                         child: Container(
                           margin: const EdgeInsets.symmetric(vertical: 0),
                           padding: const EdgeInsets.symmetric(
                               horizontal: 10, vertical: 8),
                           decoration: MoeG2Decoration(
                             radius: bubbleRadius,
                             color: bubbleColor,
                           ),
                           // Non-image content (text, audio, etc.)
                           child: hasBlocks
                              ? _buildNonImageBlocksContent(context, blocks, fg)
                              : Builder(
                                  builder: (context) {
                                    final text = message.displayText;
                                    if (text.trim().isEmpty) {
                                      // 空消息占位符（用于调试，避免完全不显示）
                                      return Text(
                                        '[空消息]',
                                        style: TextStyle(
                                          color: fg.withValues(alpha: 0.5),
                                          height: 1.42,
                                          fontSize: fontSize - 1,
                                          fontStyle: FontStyle.italic,
                                        ),
                                      );
                                    }
                                    return Text(
                                      text,
                                      style: TextStyle(
                                          color: fg,
                                          height: 1.42,
                                          fontSize: fontSize),
                                    );
                                  },
                                ),
                        ),
                      );
                    },
                  ),
              ],
            ),
          ),
          if (isMe && !hideUserAvatar) ...[
            const SizedBox(width: 8),
            _Avatar(avatarUrl: userAvatar, isUser: true),
          ],
        ],
      ),
    );
  }

  /// Check if bubble should be shown (for text, audio, etc., but not for images/stickers only)
  bool _shouldShowBubble(List<MessageBlock> blocks) {
    // If no blocks, show bubble for displayText (even if empty, will show placeholder)
    if (blocks.isEmpty) {
      return true;
    }
    // If has non-image/non-emoji blocks, show bubble
    return blocks.any((block) => block is! ImageBlock && block is! EmojiBlock);
  }

  /// Build only image and sticker blocks without bubble wrapper
  List<Widget> _buildMediaBlocksOnly(
      BuildContext context, List<MessageBlock> blocks) {
    final widgets = <Widget>[];
    for (final block in blocks) {
      if (block is ImageBlock) {
        widgets.add(_buildImageBlock(context, block));
      } else if (block is EmojiBlock) {
        widgets.add(_buildStickerBlock(context, block));
      }
    }
    return widgets;
  }

  /// Build only non-image/non-sticker blocks content for bubble (text, audio, code, etc.)
  Widget _buildNonImageBlocksContent(
      BuildContext context, List<MessageBlock> blocks, Color textColor) {
    // Filter to only non-image and non-sticker blocks
    final nonMediaBlocks = blocks
        .where((block) => block is! ImageBlock && block is! EmojiBlock)
        .toList();

    // Filter out empty text blocks
    final filteredBlocks = nonMediaBlocks.where((block) {
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
      children: filteredBlocks
          .map((block) => _buildBlock(context, block, textColor))
          .toList(),
    );
  }

  /// 根据Block类型渲染不同的组件
  Widget _buildBlock(
      BuildContext context, MessageBlock block, Color textColor) {
    if (block is TextBlock) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(
          block.content,
          style: TextStyle(color: textColor, height: 1.42, fontSize: fontSize),
        ),
      );
    } else if (block is ImageBlock) {
      return _buildImageBlock(context, block);
    } else if (block is FileBlock) {
      return _buildFileBlock(context, block, textColor);
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

  Widget _buildFileBlock(
      BuildContext context, FileBlock block, Color textColor) {
    final colors = context.moeColors;
    final subtitleColor = textColor.withValues(alpha: 0.75);
    final sizeText = _formatBytes(block.fileSize);

    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 6),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: MoeG2Decoration(
          radius: 10,
          color: colors.surfaceAlt.withValues(alpha: 0.35),
          border: Border.all(
              color: colors.borderLight.withValues(alpha: 0.6), width: 0.5),
        ),
        child: Row(
          children: [
            Icon(Icons.insert_drive_file_outlined, color: textColor, size: 22),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    block.fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: textColor,
                      fontSize: fontSize + 0.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$sizeText · ${block.mimeType}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: subtitleColor, fontSize: fontSize - 0.5),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)}KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(1)}MB';
    final gb = mb / 1024;
    return '${gb.toStringAsFixed(1)}GB';
  }

  /// 渲染图片块
  Widget _buildImageBlock(BuildContext context, ImageBlock block) {
    Widget imageWidget;
    ImageProvider? imageProvider;

    // 优先显示本地图片
    if (block.localPath != null && block.localPath!.isNotEmpty) {
      imageProvider = FileImage(File(block.localPath!));
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
      // 使用 CachedNetworkImageProvider 磁盘缓存，避免重复下载
      imageProvider = CachedNetworkImageProvider(block.url!);
      imageWidget = CachedNetworkImage(
        imageUrl: block.url!,
        width: 200,
        fit: BoxFit.cover,
        fadeInDuration: Duration.zero,
        fadeOutDuration: Duration.zero,
        placeholder: (context, url) => Container(
          width: 200,
          height: 150,
          color: Colors.grey.shade200,
          child: const Center(
            child: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
        errorWidget: (context, url, error) => Container(
          width: 200,
          height: 150,
          color: Colors.grey.shade300,
          child: const Icon(Icons.broken_image, color: Colors.grey),
        ),
      );
    } else if (block.base64 != null && block.base64!.isNotEmpty) {
      // 支持base64编码的图片
      final dataBytes =
          decodeDataImage('data:image/jpeg;base64,${block.base64}');
      if (dataBytes != null) {
        imageProvider = MemoryImage(dataBytes);
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

    // 生成唯一的 Hero tag
    final heroTag = 'image_${block.id ?? block.hashCode}';

    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: GestureDetector(
        onTap: imageProvider != null
            ? () => _showImagePreview(context, imageProvider!, heroTag)
            : null,
        child: Hero(
          tag: heroTag,
          child: MoeG2ClipRRect(radius: 10, child: imageWidget),
        ),
      ),
    );
  }

  /// 显示图片全屏预览
  void _showImagePreview(
      BuildContext context, ImageProvider imageProvider, String heroTag) {
    MoeImagePreview.show(context, imageProvider, heroTag: heroTag);
  }

  /// 渲染表情包块（Sticker）- 也支持点击预览
  Widget _buildStickerBlock(BuildContext context, EmojiBlock block) {
    final skin = context.skin;
    final colors = context.moeColors;
    final heroTag = 'sticker_${block.id ?? block.hashCode}';
    const maxSize = 140.0;

    final path = block.path.trim().replaceAll('\\', '/');
    ImageProvider? imageProvider;
    if (path.isNotEmpty) {
      final isNetwork =
          path.startsWith('http://') || path.startsWith('https://');
      final isAsset =
          path.startsWith('assets/') || path.startsWith('packages/');
      if (isNetwork) {
        // 网络图片使用 CachedNetworkImageProvider 磁盘缓存
        imageProvider = CachedNetworkImageProvider(path);
      } else if (isAsset) {
        imageProvider = AssetImage(path);
      } else {
        final file = File(path);
        if (file.existsSync()) {
          imageProvider = FileImage(file);
        }
      }
    }

    final bubbleRadius = skin.bubbleRadius;

    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      child: GestureDetector(
        onTap: imageProvider != null
            ? () => _showImagePreview(context, imageProvider!, heroTag)
            : null,
        child: Hero(
          tag: heroTag,
          child: MoeG2ClipRRect(
            radius: bubbleRadius,
            child: DecoratedBox(
              decoration: MoeG2Decoration(
                radius: bubbleRadius,
                color: colors.surfaceAlt.withValues(alpha: 0.5),
                border: Border.all(
                    color: colors.borderLight.withValues(alpha: 0.95),
                    width: 0.5),
              ),
              child: ConstrainedBox(
                constraints:
                    const BoxConstraints(maxWidth: maxSize, maxHeight: maxSize),
                child: imageProvider != null
                    ? Image(
                        image: imageProvider!,
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => Padding(
                          padding: const EdgeInsets.all(18),
                          child: Icon(Icons.emoji_emotions,
                              color: colors.muted, size: 40),
                        ),
                      )
                    : Padding(
                        padding: const EdgeInsets.all(18),
                        child: Icon(Icons.emoji_emotions,
                            color: colors.muted, size: 40),
                      ),
              ),
            ),
          ),
        ),
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
      decoration: MoeG2Decoration(
        radius: 8,
        color: Colors.black.withValues(alpha: 0.8),
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
            style: TextStyle(
                color: textColor.withValues(alpha: 0.8), fontSize: fontSize),
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
      decoration: MoeG2Decoration(
        radius: 8,
        color: Colors.red.shade100,
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
              style:
                  TextStyle(color: Colors.red.shade900, fontSize: fontSize + 1),
            ),
          ),
        ],
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  final String? avatarUrl;
  final bool isUser;
  const _Avatar({required this.avatarUrl, this.isUser = false});
  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    // 优化头像大小：38px（原来的三分之二）
    Widget buildFallback() => Center(
        child: Icon(isUser ? Icons.person : Icons.face,
            color: colors.muted, size: 20));

    Widget buildImage(String url) {
      final trimmed = url.trim();
      // 解析对齐标记（如 #top），并获取清理后的路径和对齐方式
      final alignment = trimmed.contains('#top') ? Alignment.topCenter : Alignment.center;
      final cleanUrl = trimmed.split('#').first;

      // 优先检查是否为本地文件路径（用户头像）
      if (isUser && File(cleanUrl).existsSync()) {
        return Image.file(
          File(cleanUrl),
          fit: BoxFit.cover,
          alignment: alignment,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => buildFallback(),
        );
      }

      final dataBytes = decodeDataImage(cleanUrl);
      if (dataBytes != null) {
        return Image.memory(
          dataBytes,
          fit: BoxFit.cover,
          alignment: alignment,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => buildFallback(),
        );
      }
      final isNetwork =
          cleanUrl.startsWith('http://') || cleanUrl.startsWith('https://');
      // 支持本地 assets 头像，避免再渲染时丢失角色图片（KISS/SOLID）。
      if (!isNetwork &&
          (cleanUrl.startsWith('assets/') || !cleanUrl.contains('://'))) {
        return Image.asset(
          cleanUrl,
          fit: BoxFit.cover,
          alignment: alignment,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => buildFallback(),
        );
      }
      // 网络图片使用 CachedNetworkImage 磁盘缓存
      return CachedNetworkImage(
        imageUrl: cleanUrl,
        fit: BoxFit.cover,
        alignment: alignment,
        fadeInDuration: Duration.zero,
        fadeOutDuration: Duration.zero,
        placeholder: (context, url) => buildFallback(),
        errorWidget: (context, url, error) => buildFallback(),
      );
    }

    final trimmedUrl = avatarUrl?.trim();
    return Container(
      width: 38,
      height: 38,
      margin: const EdgeInsets.only(right: 0, top: 0),
      child: MoeG2ClipRRect(
        radius: radiusBubble.x,
        child: Container(
          color: colors.surfaceAlt,
          child: trimmedUrl != null && trimmedUrl.isNotEmpty
              ? buildImage(trimmedUrl)
              : buildFallback(),
        ),
      ),
    );
  }
}

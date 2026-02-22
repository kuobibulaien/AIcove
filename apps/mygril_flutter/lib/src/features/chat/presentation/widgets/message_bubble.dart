/// 消息气泡组件（支持多模态）
/// 遵循单一职责原则(S)：只负责消息的UI渲染
///
/// 更新记录：
/// - 2025-12-06: 接入皮肤系统（背景色、描边）
/// - 2025-01-15: 图片预览改用公共组件 MoeImagePreview
/// - 2026-01-18: 网络图片改用 CachedNetworkImageProvider 磁盘缓存
library;

import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:aicove_flutter/src/core/utils/data_image.dart';
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
  static const double _kDefaultFontSize = 15.0;
  static const double _kBubbleHorizontalPadding = 10.0;
  static const double _kBubbleVerticalPadding = 7.0;
  static const double _kMediaBlockVerticalPadding = 2.0;
  static const double _kRichBlockVerticalPadding = 4.0;

  final bool isMe;
  final Message message; // 使用完整的Message对象
  final String? avatarUrl; // 仅用于左侧（AI）
  final String? displayName; // 对方名字（仅用于群聊模式）
  final VoidCallback? onRetry; // 重新发送回调
  final void Function(GlobalKey bubbleKey)? onLongPress; // 长按回调（传递气泡Key用于定位菜单）
  final void Function(GlobalKey mediaKey, MessageBlock block)? onMediaLongPress; // 媒体长按/右键回调
  final double fontSize; // 字体大小

  /// 是否显示直角（连续消息组的第一条且后面还有同发送者消息时为 true）
  /// false = 全圆角（单条消息或组的后续消息）
  final bool showCorner;

  /// 是否显示名称（群聊模式为 true，一对一聊天为 false）
  final bool showName;

  /// 是否显示头像（连续消息组中只有第一条为 true）
  final bool showAvatar;

  const MessageBubble({
    super.key,
    required this.isMe,
    required this.message,
    this.avatarUrl,
    this.displayName,
    this.onRetry,
    this.onLongPress,
    this.onMediaLongPress,
    this.fontSize = _kDefaultFontSize,
    this.showCorner = false,
    this.showName = false,
    this.showAvatar = true,
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
    this.onMediaLongPress,
    this.fontSize = _kDefaultFontSize,
    this.showCorner = false,
    this.showName = false,
    this.showAvatar = true,
  }) : message = Message.text(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          role: isMe ? 'user' : 'assistant',
          content: text,
        );

  bool get _useDesktopContextMenu =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

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
    final hideUserAvatar = settings?.hideUserAvatar ?? true;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        mainAxisAlignment:
            isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isMe) ...[
            if (showAvatar)
              _Avatar(avatarUrl: avatarUrl)
            else
              const SizedBox(width: 42),
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
                        fontWeight: MoeFontWeights.emphasis,
                      ),
                    ),
                  ),

                // Render image/sticker blocks separately without bubble
                ..._buildMediaBlocksOnly(context, blocks,
                    imagePreviewScale: settings?.imagePreviewScale ?? 1.0),
                // Render non-image blocks in bubble (text, audio, etc.)
                if (_shouldShowBubble(blocks))
                  Builder(
                    builder: (context) {
                      final bubbleKey =
                          GlobalKey(debugLabel: 'bubble_${message.id}');
                      return Listener(
                        onPointerDown: (_useDesktopContextMenu &&
                                onLongPress != null)
                            ? (event) {
                                if ((event.buttons & kSecondaryMouseButton) !=
                                    0) {
                                  onLongPress!(bubbleKey);
                                }
                              }
                            : null,
                        child: GestureDetector(
                          key: bubbleKey,
                          onLongPress: (!_useDesktopContextMenu &&
                                  onLongPress != null)
                              ? () => onLongPress!(bubbleKey)
                              : null,
                          child: Container(
                            margin: const EdgeInsets.symmetric(vertical: 0),
                            padding: const EdgeInsets.symmetric(
                                horizontal: _kBubbleHorizontalPadding,
                                vertical: _kBubbleVerticalPadding),
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
                                      return _buildMessageText(
                                        text,
                                        TextStyle(
                                          color: fg,
                                          height: 1.42,
                                          fontSize: fontSize,
                                        ),
                                      );
                                    },
                                  ),
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
            if (showAvatar)
              _Avatar(avatarUrl: userAvatar, isUser: true)
            else
              const SizedBox(width: 42),
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
      BuildContext context, List<MessageBlock> blocks,
      {double imagePreviewScale = 1.0}) {
    final widgets = <Widget>[];
    for (final block in blocks) {
      if (block is ImageBlock || block is EmojiBlock) {
        widgets.add(_buildMediaImage(context, block,
            imagePreviewScale: imagePreviewScale));
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
      children: List<Widget>.generate(filteredBlocks.length, (index) {
        final block = filteredBlocks[index];
        final isLast = index == filteredBlocks.length - 1;
        return _buildBlock(context, block, textColor, isLast: isLast);
      }),
    );
  }

  /// 根据Block类型渲染不同的组件
  Widget _buildBlock(BuildContext context, MessageBlock block, Color textColor,
      {required bool isLast}) {
    if (block is TextBlock) {
      return Padding(
        padding: EdgeInsets.only(bottom: isLast ? 0 : 3),
        child: _buildMessageText(
          block.content,
          TextStyle(color: textColor, height: 1.42, fontSize: fontSize),
        ),
      );
    } else if (block is ImageBlock || block is EmojiBlock) {
      return _buildMediaImage(context, block);
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
      padding: const EdgeInsets.symmetric(vertical: _kRichBlockVerticalPadding),
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
                      fontWeight: MoeFontWeights.emphasis,
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

  /// 统一渲染图片/表情包块
  /// ImageBlock → 等比缩放，最长边贴合最大尺寸（仿微信策略）
  /// EmojiBlock → BoxFit.contain 完整显示（表情包，小尺寸，无裁剪）
  Widget _buildMediaImage(BuildContext context, MessageBlock block,
      {double imagePreviewScale = 1.0}) {
    final skin = context.skin;
    final radius = skin.bubbleRadius;
    final isSticker = block is EmojiBlock;

    // 尺寸策略：照片占屏幕65%，表情包固定小尺寸
    // imagePreviewScale 用于用户自定义缩放
    final double maxW;
    final double maxH;
    if (isSticker) {
      maxW = 140.0 * imagePreviewScale;
      maxH = 140.0 * imagePreviewScale;
    } else {
      final screenWidth = MediaQuery.of(context).size.width;
      maxW = (screenWidth * 0.65).clamp(180.0, 300.0) * imagePreviewScale;
      maxH = 300.0 * imagePreviewScale;
    }

    ImageProvider? imageProvider;
    Widget imageWidget;

    // 统一的占位/错误态
    Widget placeholder({bool isError = false}) => Container(
          width: isSticker ? null : maxW,
          height: isSticker ? null : maxH * 0.55,
          constraints: isSticker
              ? BoxConstraints(maxWidth: maxW * 0.7, maxHeight: maxH * 0.7)
              : null,
          color: Colors.grey.shade200,
          child: Center(
            child: isError
                ? Icon(
                    isSticker ? Icons.emoji_emotions : Icons.broken_image,
                    color: Colors.grey,
                  )
                : const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
          ),
        );

    // 根据 block 类型提取 ImageProvider 并构建 imageWidget
    if (isSticker) {
      final path = (block as EmojiBlock).path.trim().replaceAll('\\', '/');
      if (path.isNotEmpty) {
        final isNetwork =
            path.startsWith('http://') || path.startsWith('https://');
        final isAsset =
            path.startsWith('assets/') || path.startsWith('packages/');
        if (isNetwork) {
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
      imageWidget = imageProvider != null
          ? ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxW, maxHeight: maxH),
              child: Image(
                image: imageProvider,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => placeholder(isError: true),
              ),
            )
          : placeholder(isError: true);
    } else {
      // 照片：用 ConstrainedBox 限制最大尺寸，图片等比缩放（仿微信）
      final constraints = BoxConstraints(maxWidth: maxW, maxHeight: maxH);
      final imgBlock = block as ImageBlock;
      if (imgBlock.localPath != null && imgBlock.localPath!.isNotEmpty) {
        imageProvider = FileImage(File(imgBlock.localPath!));
        imageWidget = ConstrainedBox(
          constraints: constraints,
          child: Image.file(
            File(imgBlock.localPath!),
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => placeholder(isError: true),
          ),
        );
      } else if (imgBlock.url != null && imgBlock.url!.isNotEmpty) {
        imageProvider = CachedNetworkImageProvider(imgBlock.url!);
        imageWidget = ConstrainedBox(
          constraints: constraints,
          child: CachedNetworkImage(
            imageUrl: imgBlock.url!,
            fit: BoxFit.contain,
            fadeInDuration: Duration.zero,
            fadeOutDuration: Duration.zero,
            placeholder: (context, url) => placeholder(),
            errorWidget: (context, url, error) => placeholder(isError: true),
          ),
        );
      } else if (imgBlock.base64 != null && imgBlock.base64!.isNotEmpty) {
        final dataBytes =
            decodeDataImage('data:image/jpeg;base64,${imgBlock.base64}');
        if (dataBytes != null) {
          imageProvider = MemoryImage(dataBytes);
          imageWidget = ConstrainedBox(
            constraints: constraints,
            child: Image.memory(
              dataBytes,
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => placeholder(isError: true),
            ),
          );
        } else {
          imageWidget = placeholder(isError: true);
        }
      } else {
        imageWidget = placeholder(isError: true);
      }
    }

    final heroTag =
        isSticker ? 'sticker_${block.id}' : 'image_${block.id}';

    return Padding(
      padding:
          const EdgeInsets.symmetric(vertical: _kMediaBlockVerticalPadding),
      child: Builder(
        builder: (context) {
          final mediaKey = GlobalKey(debugLabel: 'media_${block.id}');
          return Listener(
            onPointerDown: (_useDesktopContextMenu &&
                    onMediaLongPress != null)
                ? (event) {
                    if ((event.buttons & kSecondaryMouseButton) != 0) {
                      onMediaLongPress!(mediaKey, block);
                    }
                  }
                : null,
            child: GestureDetector(
              key: mediaKey,
              onTap: imageProvider != null
                  ? () => _showImagePreview(context, imageProvider!, heroTag)
                  : null,
              onLongPress: (!_useDesktopContextMenu &&
                      onMediaLongPress != null)
                  ? () => onMediaLongPress!(mediaKey, block)
                  : null,
              child: Hero(
                tag: heroTag,
                child: MoeG2ClipRRect(radius: radius, child: imageWidget),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 显示图片全屏预览
  void _showImagePreview(
      BuildContext context, ImageProvider imageProvider, String heroTag) {
    MoeImagePreview.show(context, imageProvider, heroTag: heroTag);
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
      margin: const EdgeInsets.symmetric(vertical: _kRichBlockVerticalPadding),
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
          _buildMessageText(
            block.content,
            const TextStyle(
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
      padding: const EdgeInsets.symmetric(vertical: _kRichBlockVerticalPadding),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: Text(
          '思考过程',
          style: TextStyle(color: textColor, fontSize: fontSize + 1),
        ),
        children: [
          _buildMessageText(
            block.content,
            TextStyle(
              color: textColor.withValues(alpha: 0.8),
              fontSize: fontSize,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageText(String text, TextStyle style) {
    return Text(
      text,
      style: style,
    );
  }

  /// 渲染错误块
  Widget _buildErrorBlock(ErrorBlock block) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: _kRichBlockVerticalPadding),
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

    // 头像大小：42px
    Widget buildFallback() => Center(
        child: Icon(isUser ? Icons.person : Icons.face,
            color: colors.muted, size: 22));

    Widget buildImage(String url) {
      final trimmed = url.trim();
      // 解析对齐标记（如 #top），并获取清理后的路径和对齐方式
      final alignment =
          trimmed.contains('#top') ? Alignment.topCenter : Alignment.center;
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
      width: 42,
      height: 42,
      margin: const EdgeInsets.only(right: 0, top: 0),
      child: MoeG2ClipRRect(
        radius: context.skin.bubbleRadius,
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

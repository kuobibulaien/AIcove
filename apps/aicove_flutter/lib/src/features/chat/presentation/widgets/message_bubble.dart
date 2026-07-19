/// 消息气泡组件（支持多模态）
/// 遵循单一职责原则(S)：只负责消息的UI渲染
///
/// 更新记录：
/// - 2025-12-06: 接入皮肤系统（背景色、描边）
/// - 2025-01-15: 图片预览改用公共组件 MoeImagePreview
/// - 2026-01-18: 网络图片改用 CachedNetworkImageProvider 磁盘缓存
library;

import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
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
import '../../../../core/models/block_status.dart';
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
  final void Function(RenderBox box)? onLongPress; // 长按回调（传递气泡RenderBox用于定位菜单）
  final void Function(RenderBox box, MessageBlock block)?
      onMediaLongPress; // 媒体长按/右键回调
  final double fontSize; // 字体大小

  /// 聊天中所有图片列表（用于画廊模式左右滑动切换），由父组件传入
  final List<ImagePreviewItem>? chatImages;

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
    this.chatImages,
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
    this.chatImages,
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
    // 仅“当前正在发送”的消息显示 streaming 三点，历史消息一律按正文渲染。
    final allowStreamingPlaceholder = message.status == 'sending';

    // 检测消息是否发送失败
    final isFailed = isMe && message.status == 'failed';

    // 获取用户头像和隐藏设置（字段级订阅：无关设置变化不重建气泡）
    final userAvatar = isMe
        ? ref.watch(
            appSettingsProvider.select((s) => s.valueOrNull?.userAvatar))
        : null;
    final hideUserAvatar = ref.watch(appSettingsProvider
            .select((s) => s.valueOrNull?.hideUserAvatar)) ??
        true;
    final imagePreviewScale = ref.watch(appSettingsProvider
            .select((s) => s.valueOrNull?.imagePreviewScale)) ??
        1.0;

    final failedIndicator = isFailed
        ? GestureDetector(
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
          )
        : null;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: _AvatarAwareBubbleRow(
        debugId: message.id,
        isMe: isMe,
        hideUserAvatar: hideUserAvatar,
        showLeftSlot: !isMe,
        showRightSlot: isMe && !hideUserAvatar,
        hasFailedIndicator: isFailed,
        failedIndicator: failedIndicator,
        leftSlot: _AvatarSlot(
          showAvatar: showAvatar,
          isUser: false,
          avatar: _Avatar(avatarUrl: avatarUrl),
          gapOnLeft: false,
        ),
        rightSlot: _AvatarSlot(
          showAvatar: showAvatar,
          isUser: true,
          avatar: _Avatar(avatarUrl: userAvatar, isUser: true),
          gapOnLeft: true,
        ),
        bubbleChild: Column(
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
                imagePreviewScale: imagePreviewScale),
            // Render non-image blocks in bubble (text, audio, etc.)
            if (_shouldShowBubble(
              blocks,
              allowStreamingPlaceholder: allowStreamingPlaceholder,
            ))
              Builder(
                builder: (context) {
                  return Listener(
                    onPointerDown: (_useDesktopContextMenu &&
                            onLongPress != null)
                        ? (event) {
                            if ((event.buttons & kSecondaryMouseButton) != 0) {
                              final box =
                                  context.findRenderObject() as RenderBox?;
                              if (box != null) onLongPress!(box);
                            }
                          }
                        : null,
                    child: GestureDetector(
                      onLongPress:
                          (!_useDesktopContextMenu && onLongPress != null)
                              ? () {
                                  final box =
                                      context.findRenderObject() as RenderBox?;
                                  if (box != null) onLongPress!(box);
                                }
                              : null,
                      child: Container(
                        key: ValueKey<String>('message_bubble_${message.id}'),
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
                            ? _buildNonImageBlocksContent(
                                context,
                                blocks,
                                fg,
                                allowStreamingPlaceholder:
                                    allowStreamingPlaceholder,
                              )
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
    );
  }

  /// Check if bubble should be shown (for text, audio, etc., but not for images/stickers only)
  bool _shouldShowBubble(
    List<MessageBlock> blocks, {
    required bool allowStreamingPlaceholder,
  }) {
    // If no blocks, show bubble for displayText (even if empty, will show placeholder)
    if (blocks.isEmpty) {
      return true;
    }
    // 只要存在可视化内容块才显示气泡，避免 ToolBlock 等内部块形成空壳气泡。
    return blocks.any((block) => _isBubbleRenderableBlock(
          block,
          allowStreamingPlaceholder: allowStreamingPlaceholder,
        ));
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
    BuildContext context,
    List<MessageBlock> blocks,
    Color textColor, {
    required bool allowStreamingPlaceholder,
  }) {
    // Filter to only non-image and non-sticker blocks
    final nonMediaBlocks = blocks
        .where((block) => block is! ImageBlock && block is! EmojiBlock)
        .toList();
    final filteredBlocks = nonMediaBlocks
        .where((block) => _isBubbleRenderableBlock(
              block,
              allowStreamingPlaceholder: allowStreamingPlaceholder,
            ))
        .toList();

    if (filteredBlocks.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: List<Widget>.generate(filteredBlocks.length, (index) {
        final block = filteredBlocks[index];
        final isLast = index == filteredBlocks.length - 1;
        return _buildBlock(
          context,
          block,
          textColor,
          isLast: isLast,
          allowStreamingPlaceholder: allowStreamingPlaceholder,
        );
      }),
    );
  }

  bool _isBubbleRenderableBlock(
    MessageBlock block, {
    required bool allowStreamingPlaceholder,
  }) {
    if (block is TextBlock) {
      return block.content.trim().isNotEmpty ||
          (allowStreamingPlaceholder && block.status == BlockStatus.streaming);
    }
    return block is FileBlock ||
        block is AudioBlock ||
        block is CodeBlock ||
        block is ThinkingBlock ||
        block is ErrorBlock;
  }

  /// 根据Block类型渲染不同的组件
  Widget _buildBlock(
    BuildContext context,
    MessageBlock block,
    Color textColor, {
    required bool isLast,
    required bool allowStreamingPlaceholder,
  }) {
    if (block is TextBlock) {
      // streaming 状态统一显示三点闪动，避免模型首段返回过快时看不到“加载中”反馈。
      if (allowStreamingPlaceholder && block.status == BlockStatus.streaming) {
        return Padding(
          padding: EdgeInsets.only(bottom: isLast ? 0 : 3),
          child: TypingDotsIndicator(
            color: textColor,
            dotSize: fontSize * 0.4,
            height: fontSize * 1.42, // 与文字行高一致
          ),
        );
      }
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

  Size? _resolveImageDisplaySize(
    ImageBlock block, {
    required double maxWidth,
    required double maxHeight,
  }) {
    final rawWidth = block.width?.toDouble();
    final rawHeight = block.height?.toDouble();
    if (rawWidth == null ||
        rawHeight == null ||
        rawWidth <= 0 ||
        rawHeight <= 0) {
      return null;
    }
    final scale = math.min(
      1.0,
      math.min(maxWidth / rawWidth, maxHeight / rawHeight),
    );
    if (!scale.isFinite || scale <= 0) {
      return null;
    }
    return Size(
      rawWidth * scale,
      rawHeight * scale,
    );
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
    final photoConstraints = BoxConstraints(maxWidth: maxW, maxHeight: maxH);
    var photoDisplaySize = block is ImageBlock
        ? _resolveImageDisplaySize(
            block,
            maxWidth: maxW,
            maxHeight: maxH,
          )
        : null;
    // 照片无尺寸时（生成中/延迟交付）补一个保守的估算尺寸，让占位与成图同高，
    // 消除「无尺寸 ConstrainedBox(高 maxH*0.55) → 有尺寸 SizedBox」的高度跳变。
    // 仅照片路径，不动 EmojiBlock 表情包。
    if (!isSticker && photoDisplaySize == null) {
      final estimate = math.min(maxW, maxH);
      photoDisplaySize = Size(maxW, estimate);
    }

    // 列表内展示按目标显示宽降采样解码，避免原图分辨率 bitmap 进 ImageCache；
    // 传给 _showImagePreview 的 imageProvider（全屏预览/画廊/Hero）保持原图不受影响。
    // 有尺寸元数据时用实际显示宽（竖图更省），否则回退到 maxW；cacheWidth
    // 默认 allowUpscaling=false，小图不会被放大。
    final photoDecodeWidth =
        ((photoDisplaySize?.width ?? maxW) * MediaQuery.devicePixelRatioOf(context))
            .round();

    Widget wrapPhoto(Widget child) {
      if (photoDisplaySize == null) {
        return ConstrainedBox(
          constraints: photoConstraints,
          child: child,
        );
      }
      return SizedBox(
        width: photoDisplaySize.width,
        height: photoDisplaySize.height,
        child: child,
      );
    }

    // 统一的占位/错误态
    Widget placeholder({bool isError = false}) => Container(
          width: isSticker ? null : photoDisplaySize?.width ?? maxW,
          height: isSticker ? null : photoDisplaySize?.height ?? maxH * 0.55,
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
      final path = block.path.trim().replaceAll('\\', '/');
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
          imageProvider = FileImage(File(_normalizeLocalFilePath(path)));
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
      final imgBlock = block as ImageBlock;
      if (imgBlock.localPath != null && imgBlock.localPath!.isNotEmpty) {
        imageProvider = FileImage(File(imgBlock.localPath!));
        imageWidget = wrapPhoto(
          Image.file(
            File(imgBlock.localPath!),
            fit: BoxFit.contain,
            cacheWidth: photoDecodeWidth,
            errorBuilder: (_, __, ___) => placeholder(isError: true),
          ),
        );
      } else if (imgBlock.url != null && imgBlock.url!.isNotEmpty) {
        imageProvider = CachedNetworkImageProvider(imgBlock.url!);
        imageWidget = wrapPhoto(
          CachedNetworkImage(
            imageUrl: imgBlock.url!,
            fit: BoxFit.contain,
            memCacheWidth: photoDecodeWidth,
            fadeInDuration: Duration.zero,
            fadeOutDuration: Duration.zero,
            placeholder: (context, url) => placeholder(),
            errorWidget: (context, url, error) => placeholder(isError: true),
          ),
        );
      } else if (imgBlock.base64 != null && imgBlock.base64!.isNotEmpty) {
        final dataBytes = decodeInlineBase64Image(imgBlock.base64);
        if (dataBytes != null) {
          imageProvider = _MemoryImageProviderCache.fromBytes(dataBytes);
          imageWidget = wrapPhoto(
            Image(
              image: ResizeImage.resizeIfNeeded(
                photoDecodeWidth,
                null,
                imageProvider,
              ),
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

    final heroTag = isSticker ? 'sticker_${block.id}' : 'image_${block.id}';

    return Padding(
      padding:
          const EdgeInsets.symmetric(vertical: _kMediaBlockVerticalPadding),
      child: Builder(
        builder: (context) {
          return Listener(
            onPointerDown: (_useDesktopContextMenu && onMediaLongPress != null)
                ? (event) {
                    if ((event.buttons & kSecondaryMouseButton) != 0) {
                      final box = context.findRenderObject() as RenderBox?;
                      if (box != null) onMediaLongPress!(box, block);
                    }
                  }
                : null,
            child: GestureDetector(
              onTap: imageProvider != null
                  ? () => _showImagePreview(context, imageProvider!, heroTag)
                  : null,
              onLongPress: (!_useDesktopContextMenu && onMediaLongPress != null)
                  ? () {
                      final box = context.findRenderObject() as RenderBox?;
                      if (box != null) onMediaLongPress!(box, block);
                    }
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

  /// 显示图片全屏预览（支持画廊模式左右滑动切换）
  void _showImagePreview(
      BuildContext context, ImageProvider imageProvider, String heroTag) {
    final images = chatImages;
    if (images != null && images.length > 1) {
      // 画廊模式：在列表中找到当前图片的索引
      int index = images.indexWhere((item) => item.heroTag == heroTag);
      if (index < 0) index = 0;
      MoeImagePreview.showGallery(
        context,
        images: images,
        initialIndex: index,
      );
    } else {
      // 单张预览
      MoeImagePreview.show(context, imageProvider, heroTag: heroTag);
    }
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

/// 头像列（头像 + 与气泡的间隔）
///
/// showAvatar=false 时仍保留同宽占位，确保连续消息对齐不抖动。
class _AvatarSlot extends StatelessWidget {
  static const double _kAvatarGap = 8.0;
  static const double fallbackWidth = _Avatar.kSize + _kAvatarGap;

  final bool showAvatar;
  final bool isUser;
  final Widget avatar;
  final bool gapOnLeft;

  const _AvatarSlot({
    required this.showAvatar,
    required this.isUser,
    required this.avatar,
    required this.gapOnLeft,
  });

  @override
  Widget build(BuildContext context) {
    const placeholder = SizedBox(width: _Avatar.kSize);

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (gapOnLeft) const SizedBox(width: _kAvatarGap),
        showAvatar ? avatar : placeholder,
        if (!gapOnLeft) const SizedBox(width: _kAvatarGap),
      ],
    );
  }
}

/// 根据头像列实际渲染宽度，限制气泡最大宽度。
///
/// 规则：
/// - 默认双头像：左右都预留头像列宽度
/// - 隐藏用户头像：仅预留左侧头像列
class _AvatarAwareBubbleRow extends StatelessWidget {
  static const double _kMinBubbleMaxWidth = 120.0;
  static const double _kFailedIndicatorWidth = 24.0; // 20 + 右侧间距 4

  final String debugId;
  final bool isMe;
  final bool hideUserAvatar;
  final bool showLeftSlot;
  final bool showRightSlot;
  final bool hasFailedIndicator;
  final Widget? failedIndicator;
  final Widget leftSlot;
  final Widget rightSlot;
  final Widget bubbleChild;

  const _AvatarAwareBubbleRow({
    required this.debugId,
    required this.isMe,
    required this.hideUserAvatar,
    required this.showLeftSlot,
    required this.showRightSlot,
    required this.hasFailedIndicator,
    required this.failedIndicator,
    required this.leftSlot,
    required this.rightSlot,
    required this.bubbleChild,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const leftReserve = _AvatarSlot.fallbackWidth;
        final rightReserve = hideUserAvatar ? 0.0 : _AvatarSlot.fallbackWidth;
        final failedReserve = (isMe && hasFailedIndicator)
            ? _AvatarAwareBubbleRow._kFailedIndicatorWidth
            : 0.0;
        final bubbleWidthUpperBound =
            constraints.maxWidth > 0 ? constraints.maxWidth : 0.0;
        final bubbleWidthLowerBound = math.min(
          _AvatarAwareBubbleRow._kMinBubbleMaxWidth,
          bubbleWidthUpperBound,
        );
        final maxBubbleWidth =
            (constraints.maxWidth - leftReserve - rightReserve - failedReserve)
                .clamp(
                  bubbleWidthLowerBound,
                  bubbleWidthUpperBound,
                )
                .toDouble();

        Widget bubbleArea = ConstrainedBox(
          key: ValueKey<String>(
            'message_bubble_constraints_$debugId',
          ),
          constraints: BoxConstraints(maxWidth: maxBubbleWidth),
          child: bubbleChild,
        );

        if (isMe && hasFailedIndicator && failedIndicator != null) {
          bubbleArea = Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              failedIndicator!,
              bubbleArea,
            ],
          );
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showLeftSlot) leftSlot,
            Flexible(
              child: Align(
                alignment: isMe ? Alignment.topRight : Alignment.topLeft,
                child: bubbleArea,
              ),
            ),
            if (showRightSlot) rightSlot,
          ],
        );
      },
    );
  }
}

class _Avatar extends StatelessWidget {
  static const double kSize = 42.0;

  final String? avatarUrl;
  final bool isUser;
  const _Avatar({required this.avatarUrl, this.isUser = false});
  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    // 头像仅 42px 显示，按目标像素降采样解码，避免原图（可达数百万像素）
    // 进 ImageCache 拖慢滚动。
    final avatarDecodeWidth =
        (kSize * MediaQuery.devicePixelRatioOf(context)).round();

    // 头像大小
    Widget buildFallback() => Center(
        child: Icon(isUser ? Icons.person : Icons.face,
            color: colors.muted, size: 22));

    Widget buildImage(String url) {
      final trimmed = url.trim();
      // 解析对齐标记（如 #top），并获取清理后的路径和对齐方式
      final alignment =
          trimmed.contains('#top') ? Alignment.topCenter : Alignment.center;
      final cleanUrl = trimmed.split('#').first;
      final isNetwork =
          cleanUrl.startsWith('http://') || cleanUrl.startsWith('https://');
      final isAsset =
          cleanUrl.startsWith('assets/') || cleanUrl.startsWith('packages/');
      final isLocalFile = _looksLikeLocalFilePath(cleanUrl);

      if (isLocalFile) {
        return Image.file(
          File(_normalizeLocalFilePath(cleanUrl)),
          fit: BoxFit.cover,
          alignment: alignment,
          cacheWidth: avatarDecodeWidth,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => buildFallback(),
        );
      }

      final dataBytes = decodeInlineBase64Image(cleanUrl);
      if (dataBytes != null) {
        return Image(
          image: ResizeImage.resizeIfNeeded(
            avatarDecodeWidth,
            null,
            _MemoryImageProviderCache.fromBytes(dataBytes),
          ),
          fit: BoxFit.cover,
          alignment: alignment,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => buildFallback(),
        );
      }
      if (!isNetwork &&
          !isLocalFile &&
          (isAsset || !cleanUrl.contains('://'))) {
        return Image.asset(
          cleanUrl,
          fit: BoxFit.cover,
          alignment: alignment,
          cacheWidth: avatarDecodeWidth,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => buildFallback(),
        );
      }
      // 网络图片使用 CachedNetworkImage 磁盘缓存
      return CachedNetworkImage(
        imageUrl: cleanUrl,
        fit: BoxFit.cover,
        alignment: alignment,
        memCacheWidth: avatarDecodeWidth,
        fadeInDuration: Duration.zero,
        fadeOutDuration: Duration.zero,
        placeholder: (context, url) => buildFallback(),
        errorWidget: (context, url, error) => buildFallback(),
      );
    }

    final trimmedUrl = avatarUrl?.trim();
    return Container(
      width: kSize,
      height: kSize,
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

bool _looksLikeLocalFilePath(String path) {
  if (path.isEmpty) return false;
  if (path.startsWith('/')) return true;
  if (path.startsWith(r'\')) return true;
  if (path.startsWith('file://')) return true;
  if (RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path)) return true;
  return path.contains(r'\');
}

String _normalizeLocalFilePath(String path) {
  if (path.startsWith('file://')) {
    return Uri.parse(path).toFilePath();
  }
  return path;
}

class _MemoryImageProviderCache {
  _MemoryImageProviderCache._();

  static const int _maxEntries = 48;
  static final LinkedHashMap<Uint8List, MemoryImage> _entries =
      LinkedHashMap<Uint8List, MemoryImage>.identity();

  static MemoryImage fromBytes(Uint8List bytes) {
    final cached = _entries.remove(bytes);
    if (cached != null) {
      _entries[bytes] = cached;
      return cached;
    }

    final provider = MemoryImage(bytes);
    _entries[bytes] = provider;
    while (_entries.length > _maxEntries) {
      _entries.remove(_entries.keys.first);
    }
    return provider;
  }
}

/// Momotalk 风格三点闪动输入指示器
///
/// 三个圆点从左到右依次缩放+透明度变化，模拟"对方正在输入"效果。
/// 用于 AI 生成中的占位消息气泡内。
class TypingDotsIndicator extends StatefulWidget {
  /// 圆点颜色
  final Color color;

  /// 单个圆点直径
  final double dotSize;

  /// 圆点间距
  final double spacing;

  /// 组件高度（与文字行高一致，确保气泡大小正常）
  final double? height;

  const TypingDotsIndicator({
    super.key,
    required this.color,
    this.dotSize = 6.0,
    this.spacing = 4.0,
    this.height,
  });

  @override
  State<TypingDotsIndicator> createState() => _TypingDotsIndicatorState();
}

class _TypingDotsIndicatorState extends State<TypingDotsIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final effectiveHeight = widget.height ?? widget.dotSize * 1.6;
    return SizedBox(
      height: effectiveHeight,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: List.generate(3, (index) {
          return Padding(
            padding: EdgeInsets.only(
              right: index < 2 ? widget.spacing : 0,
            ),
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, child) {
                // 每个点在周期中有不同的相位偏移（0.0, 0.2, 0.4）
                final offset = index * 0.2;
                final t = (_controller.value - offset) % 1.0;
                // 活跃区间 [0, 0.4]，其余时间静止
                final active = t < 0.4;
                // 只使用透明度变化实现从左到右闪动，不缩放
                final opacity =
                    active ? 0.4 + 0.6 * math.sin(t / 0.4 * math.pi) : 0.4;
                return Opacity(
                  opacity: opacity,
                  child: child,
                );
              },
              child: Container(
                width: widget.dotSize,
                height: widget.dotSize,
                decoration: BoxDecoration(
                  color: widget.color,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}

/// 消息气泡组件（支持多模态）
/// 遵循单一职责原则(S)：只负责消息的UI渲染
///
/// 更新记录：
/// - 2025-12-06: 接入皮肤系统（背景色、描边）
/// - 2025-01-15: 图片预览改用公共组件 MoeImagePreview
/// - 2026-01-18: 网络图片改用 CachedNetworkImageProvider 磁盘缓存
library;

import '../../../../core/media/cloud_image.dart';
import '../../../../core/media/media_asset.dart';
import '../../../stickers/sticker_library.dart';

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SelectedContent;
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:aicove_flutter/src/core/utils/data_image.dart';
import 'package:aicove_flutter/src/core/utils/markdown_fence.dart';
import '../../../../ui/theme/skin_provider.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../core/models/message_block.dart';
import '../../../../core/models/block_status.dart';
import '../../application/chat_view_prefs.dart';
import '../../application/chat_media_regeneration.dart';
import '../../domain/message.dart';
import '../../domain/quoted_reply.dart';
import '../../../settings/app_settings.dart';
import 'audio_player_widget.dart';
import 'chat_record_bubble.dart';
import '../../../../ui/features/voice_call/widgets/call_record_bubble.dart';
import '../../../../ui/features/task_agent/task_receipt_bubble.dart';
import 'incremental_message_text.dart';
import 'message_text_viewer.dart';

part 'message_bubble_media_parts.dart';
part 'message_bubble_parts.dart';

/// 语音消息转文字单条展开状态覆盖（null 表示跟随全局设置）
final audioMessageTextExpandedProvider = StateProvider.family<bool?, String>(
  (ref, messageId) => null,
);

/// 消息气泡组件（支持多模态）
/// 遵循单一职责原则(S)：只负责消息的UI渲染
class MessageBubble extends ConsumerWidget {
  static const double _kMediaBlockVerticalPadding = 2.0;
  static const double _kRichBlockVerticalPadding = 4.0;

  static const double avatarBubbleGap = 8;

  /// Left edge of the contact's bubbles in bubble mode: row padding, avatar
  /// column and gap. Lines that sit under a bubble align to it.
  static const double contactContentInset = 8 + _Avatar.kSize + avatarBubbleGap;

  final Widget Function(Widget child)? selectionWrapper;
  final bool isMe;
  final Message message; // 使用完整的Message对象
  final String? avatarUrl; // 仅用于左侧（AI）
  final String? displayName; // 对方名字（仅用于群聊模式）
  final VoidCallback? onRetry; // 重新发送回调
  /// 长按／右键回调：气泡 RenderBox 用于定位菜单；selectedText 为用户在气泡里
  /// 选中的文字，没选时为 null。
  final void Function(
    RenderBox box,
    Offset globalPosition,
    String? selectedText,
  )?
  onLongPress;
  final void Function(RenderBox box, MessageBlock block, Offset globalPosition)?
  onMediaLongPress; // 媒体长按/右键回调

  /// 切换图片的历史版本（仅多版本图片显示切换条）。
  final void Function(ImageBlock block, int versionIndex)? onSelectImageVersion;
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
  final bool hideContactAvatar;

  /// 文档模式（ADR0047）：助手消息不画气泡、占满宽度、按 Markdown 渲染；
  /// 用户消息改为中性浅色块。
  final bool documentStyle;

  const MessageBubble({
    super.key,
    required this.isMe,
    required this.message,
    this.avatarUrl,
    this.displayName,
    this.onRetry,
    this.onLongPress,
    this.onMediaLongPress,
    this.onSelectImageVersion,
    this.fontSize = MoeBubbleStyle.defaultFontSize,
    this.chatImages,
    this.showCorner = false,
    this.showName = false,
    this.showAvatar = true,
    this.selectionWrapper,
    this.hideContactAvatar = false,
    this.documentStyle = false,
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
    this.onSelectImageVersion,
    this.fontSize = MoeBubbleStyle.defaultFontSize,
    this.chatImages,
    this.showCorner = false,
    this.showName = false,
    this.showAvatar = true,
    this.selectionWrapper,
    this.hideContactAvatar = false,
    this.documentStyle = false,
  }) : message = Message.text(
         id: DateTime.now().millisecondsSinceEpoch.toString(),
         role: isMe ? 'user' : 'assistant',
         content: text,
       );

  /// 交互场景的气泡正文可直接选字，长按（右键）菜单照旧；导出图、预览等
  /// 没有菜单的场景不包选择区。
  Widget _wrapSelectable(Widget bubble, {required Color textColor}) {
    final onLongPress = this.onLongPress;
    if (onLongPress == null) return bubble;
    return _SelectableBubble(
      onLongPress: onLongPress,
      // 气泡底色各异，选区高亮跟正文颜色走才看得清。
      selectionColor: textColor.withValues(alpha: 0.3),
      child: bubble,
    );
  }

  bool get _useDesktopContextMenu =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final skin = context.skin;
    final colors = context.moeColors;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // 从 MoeColors 读取气泡颜色（已适配深浅模式）
    final documentAssistant = documentStyle && !isMe;
    final bubbleColor = documentStyle
        ? (isMe ? colors.text.withValues(alpha: 0.07) : Colors.transparent)
        : (isMe ? colors.bubbleRightBg : colors.bubbleLeftBg);
    final fg = documentStyle
        ? colors.text
        : (isMe ? Colors.white : colors.bubbleLeftFg);

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
            appSettingsProvider.select((s) => s.valueOrNull?.userAvatar),
          )
        : null;
    // 头像、图片预览大小、语音展开按所在联系人生效（ChatViewScope）。
    final viewPrefs = ChatViewPrefs.watch(context, ref);
    final hideUserAvatar = viewPrefs.hideUserAvatar;
    final imagePreviewScale = viewPrefs.imagePreviewScale;
    final localExpandAudio = ref.watch(
      audioMessageTextExpandedProvider(message.id),
    );
    final isAudioTextExpanded = localExpandAudio ?? viewPrefs.expandAudioText;

    final failedIndicator = isFailed
        ? GestureDetector(
            onTap: onRetry,
            child: const MoeButtonSurface(
              width: 20,
              height: 20,
              margin: EdgeInsets.only(top: 9, right: 4),
              tintColor: Colors.red,
              radius: 999,
              child: Icon(Icons.priority_high, color: Colors.red, size: 14),
            ),
          )
        : null;

    final bubbleChild = Column(
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
        ..._buildMediaBlocksOnly(
          context,
          blocks,
          imagePreviewScale: imagePreviewScale,
        ),
        // 折叠块（思维链、状态栏等）自成一个折叠气泡，不再套普通气泡。
        for (final block in blocks.whereType<ThinkingBlock>())
          _buildFoldBubble(context, block),
        // Render non-image blocks in bubble (text, audio, etc.)
        if (_shouldShowBubble(
          blocks,
          allowStreamingPlaceholder: allowStreamingPlaceholder,
        ))
          _wrapSelectable(
            Container(
              key: ValueKey<String>('message_bubble_${message.id}'),
              width: documentAssistant ? double.infinity : null,
              margin: const EdgeInsets.symmetric(vertical: 0),
              padding: documentAssistant
                  ? const EdgeInsets.symmetric(vertical: 2)
                  : documentStyle
                  ? _DocumentMessageRow.userPadding
                  : MoeBubbleStyle.padding,
              decoration: documentAssistant
                  ? null
                  : MoeG2Decoration(radius: bubbleRadius, color: bubbleColor),
              // Non-image content (text, audio, etc.)
              child: hasBlocks
                  ? _buildNonImageBlocksContent(
                      context,
                      blocks,
                      fg,
                      allowStreamingPlaceholder: allowStreamingPlaceholder,
                      isAudioTextExpanded: isAudioTextExpanded,
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
                              height: MoeBubbleStyle.textHeight,
                              fontSize: fontSize - 1,
                              fontStyle: FontStyle.italic,
                            ),
                          );
                        }
                        return _buildBodyText(
                          text,
                          TextStyle(
                            color: fg,
                            height: MoeBubbleStyle.textHeight,
                            fontSize: fontSize,
                          ),
                        );
                      },
                    ),
            ),
            textColor: fg,
          ),
      ],
    );

    if (documentStyle) {
      return _DocumentMessageRow(
        isMe: isMe,
        startsTurn: showAvatar,
        reserveSelectionGutter: hideContactAvatar,
        selectionWrapper: hasVisibleContent(message) ? selectionWrapper : null,
        failedIndicator: failedIndicator,
        child: bubbleChild,
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: _AvatarAwareBubbleRow(
        debugId: message.id,
        selectionWrapper: hasVisibleContent(message) ? selectionWrapper : null,
        isMe: isMe,
        hideUserAvatar: hideUserAvatar,
        showLeftSlot: !isMe,
        showRightSlot: isMe && !hideUserAvatar,
        hasFailedIndicator: isFailed,
        failedIndicator: failedIndicator,
        leftSlot: _AvatarSlot(
          showAvatar: showAvatar,
          isUser: false,
          avatar: Visibility(
            visible: !hideContactAvatar,
            maintainSize: true,
            maintainAnimation: true,
            maintainState: true,
            child: _Avatar(avatarUrl: avatarUrl),
          ),
          gapOnLeft: false,
        ),
        rightSlot: _AvatarSlot(
          showAvatar: showAvatar,
          isUser: true,
          avatar: _Avatar(avatarUrl: userAvatar),
          gapOnLeft: true,
        ),
        bubbleChild: bubbleChild,
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
    return blocks.any(
      (block) =>
          block is! ThinkingBlock &&
          isRenderableBlock(
            block,
            allowStreamingPlaceholder: allowStreamingPlaceholder,
          ),
    );
  }

  Widget _buildFoldBubble(BuildContext context, ThinkingBlock block) {
    final title = block.title?.trim();
    final displayTitle = title == null || title.isEmpty ? '思考过程' : title;
    return Builder(
      builder: (context) => GestureDetector(
        onLongPressStart: onLongPress == null
            ? null
            : (details) {
                final box = context.findRenderObject() as RenderBox?;
                if (box != null) {
                  onLongPress!(box, details.globalPosition, null);
                }
              },
        // 文档模式的助手折叠内容用半隐藏折叠段，和正文区分开；其余仍是折叠气泡。
        child: documentStyle && !isMe
            ? Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: MoeFoldSection(
                  key: ValueKey<String>('fold_bubble_${block.id}'),
                  title: displayTitle,
                  content: block.content,
                  fontSize: fontSize,
                  child: MoeMarkdownView(
                    block.content,
                    fontSize: fontSize - 1,
                    color: MoeFoldSection.bodyColor(context),
                  ),
                ),
              )
            : MoeCollapsibleBubble(
                key: ValueKey<String>('fold_bubble_${block.id}'),
                isMe: isMe,
                title: displayTitle,
                content: block.content,
                fontSize: fontSize,
              ),
      ),
    );
  }

  /// Build only image and sticker blocks without bubble wrapper
  List<Widget> _buildMediaBlocksOnly(
    BuildContext context,
    List<MessageBlock> blocks, {
    double imagePreviewScale = 1.0,
  }) {
    final widgets = <Widget>[];
    for (final block in blocks) {
      if (block is ImageBlock || block is EmojiBlock) {
        widgets.add(
          _buildMediaImage(
            context,
            block,
            imagePreviewScale: imagePreviewScale,
          ),
        );
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
    required bool isAudioTextExpanded,
  }) {
    // Filter to only non-image and non-sticker blocks
    final nonMediaBlocks = blocks
        .where(
          (block) =>
              block is! ImageBlock &&
              block is! EmojiBlock &&
              block is! ThinkingBlock,
        )
        .toList();
    final filteredBlocks = nonMediaBlocks
        .where(
          (block) => isRenderableBlock(
            block,
            allowStreamingPlaceholder: allowStreamingPlaceholder,
          ),
        )
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
          isAudioTextExpanded: isAudioTextExpanded,
        );
      }),
    );
  }

  static bool hasVisibleContent(Message message) {
    final blocks = message.blocks ?? const <MessageBlock>[];
    return blocks.isEmpty ||
        blocks.any(
          (block) =>
              block is ImageBlock ||
              block is EmojiBlock ||
              isRenderableBlock(
                block,
                allowStreamingPlaceholder: message.status == 'sending',
              ),
        );
  }

  static bool isRenderableBlock(
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
    required bool isAudioTextExpanded,
  }) {
    if (block is CallRecordBlock) {
      return CallRecordBubble(record: block, textColor: textColor);
    }
    if (block is ChatRecordBlock) {
      return ChatRecordBubble(record: block, textColor: textColor);
    }
    if (block is TaskReceiptBlock) {
      return TaskReceiptBubble(receipt: block, textColor: textColor);
    }
    if (block is TaskControlBlock) return const SizedBox.shrink();
    if (block is TextBlock) {
      // streaming 状态统一显示三点闪动，避免模型首段返回过快时看不到“加载中”反馈。
      if (allowStreamingPlaceholder && block.status == BlockStatus.streaming) {
        return Padding(
          padding: EdgeInsets.only(bottom: isLast ? 0 : 3),
          child: TypingDotsIndicator(
            color: textColor,
            dotSize: fontSize * 0.4,
            height: fontSize * MoeBubbleStyle.textHeight, // 与文字行高一致
          ),
        );
      }
      return Padding(
        padding: EdgeInsets.only(bottom: isLast ? 0 : 3),
        child: _buildBodyText(
          block.content,
          TextStyle(
            color: textColor,
            height: MoeBubbleStyle.textHeight,
            fontSize: fontSize,
          ),
        ),
      );
    } else if (block is ImageBlock || block is EmojiBlock) {
      return _buildMediaImage(context, block);
    } else if (block is FileBlock) {
      return _buildFileBlock(context, block, textColor);
    } else if (block is AudioBlock) {
      return _buildAudioBlock(
        block,
        textColor,
        isExpanded: isAudioTextExpanded,
      );
    } else if (block is CodeBlock) {
      return _buildCodeBlock(block, textColor);
    } else if (block is ErrorBlock) {
      return _buildErrorBlock(block);
    }
    // 其他类型暂不渲染
    return const SizedBox.shrink();
  }

  /// 消息正文：文档模式的助手消息按 Markdown 渲染，其余走 [_buildMessageText]。
  /// 用户的引用回复把开头的引用摘要画成气泡内引用块。
  Widget _buildBodyText(String text, TextStyle style) {
    if (!isMe) {
      // Interactive blocks store what the user changed under the raw message.
      return MoeUiBlockMessage(
        messageId: message.sourceMessageIdOrSelf,
        child: documentStyle
            ? MoeMarkdownView(
                text,
                fontSize: style.fontSize ?? fontSize,
                color: style.color,
              )
            : _buildMessageText(text, style),
      );
    }
    final quoted = isMe ? QuotedReply.parse(text) : null;
    if (quoted == null) return _buildMessageText(text, style);
    final bodyFontSize = style.fontSize ?? fontSize;
    return Builder(
      builder: (context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1, bottom: 5),
            child: MoeQuoteBlock(
              text: quoted.quote,
              foregroundColor: style.color ?? context.moeColors.text,
              fontSize: bodyFontSize - 2,
              // 内嵌圆角 = 气泡圆角 − 气泡纵向内边距。
              radius: (context.skin.bubbleRadius - MoeBubbleStyle.padding.top)
                  .clamp(6.0, 14.0),
            ),
          ),
          _buildMessageText(quoted.body, style),
        ],
      ),
    );
  }

  /// 正文里的围栏代码块用 [MoeCodeBlock] 渲染，助手的 `aicove-ui` 块画成交互
  /// 组件（[MoeUiBlock]），其余保持纯文本（ADR0047）。
  Widget _buildMessageText(String text, TextStyle style) {
    final parts = text.contains('```') || text.contains('~~~')
        ? splitFencedText(text)
        : null;
    if (parts == null ||
        (parts.length == 1 && parts.single is FencedProsePart)) {
      return _buildPlainMessageText(text, style);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final part in parts)
          switch (part) {
            FencedProsePart(:final text) => _buildPlainMessageText(text, style),
            FencedCodePart(:final block)
                when !isMe && MoeUiBlock.handles(block.language) =>
              MoeUiBlock(
                code: block.code,
                closed: block.closed,
                foregroundColor: style.color,
                fontSize: style.fontSize ?? fontSize,
              ),
            FencedCodePart(:final block) => MoeCodeBlock(
              code: block.code,
              language: block.language,
              foregroundColor: style.color,
              fontSize: (style.fontSize ?? fontSize) - 2,
            ),
          },
      ],
    );
  }

  Widget _buildPlainMessageText(String text, TextStyle style) {
    if (text.length >= 512 && text.contains('\n')) {
      return IncrementalMessageText(text, style: style);
    }
    return Text(text, style: style);
  }
}

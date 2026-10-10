import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../../../features/chat/domain/message.dart';
import '../../../../features/chat/presentation/widgets/composer.dart';
import '../../../../features/chat/presentation/widgets/message_bubble.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';

/// One selected bubble with the grouping the timeline would give it.
typedef ChatExportBubble = ({
  Message message,
  bool showAvatar,
  bool showCorner,
});

/// Consecutive bubbles from the same side form one group: only the first
/// shows the avatar, and every bubble except the last keeps the tail corner.
List<ChatExportBubble> groupChatExportBubbles(List<Message> messages) => [
  for (var i = 0; i < messages.length; i++)
    (
      message: messages[i],
      showAvatar: i == 0 || messages[i - 1].role != messages[i].role,
      showCorner:
          i + 1 < messages.length && messages[i + 1].role == messages[i].role,
    ),
];

/// Static reproduction of the chat screen for long-image export: the chat
/// background repeated once per screen height (the last copy is cut off),
/// the floating header on top, the selected bubbles, and the composer below.
/// It lives in the real widget tree so images, wallpapers and glass surfaces
/// render through the same widgets as the chat page.
class ChatExportCanvas extends StatelessWidget {
  const ChatExportCanvas({
    super.key,
    required this.messages,
    required this.title,
    required this.background,
    required this.width,
    required this.screenHeight,
    this.avatarUrl,
    this.characterImage,
    this.showBackButton = false,
    this.documentStyle = false,
  });

  final List<Message> messages;
  final String title;
  final String? avatarUrl;
  final String? characterImage;

  /// Chat background exactly as it fills one screen.
  final Widget background;
  final double width;
  final double screenHeight;
  final bool showBackButton;
  final bool documentStyle;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final mediaQuery = MediaQuery.of(context);
    final toolbarHeight = MoeChatHeader.heightFor(mediaQuery.textScaler);
    final bubbleAvatar = avatarUrl ?? characterImage;
    return IgnorePointer(
      child: MediaQuery(
        data: mediaQuery.copyWith(
          size: Size(width, screenHeight),
          padding: EdgeInsets.zero,
          viewPadding: EdgeInsets.zero,
          viewInsets: EdgeInsets.zero,
        ),
        child: SizedBox(
          width: width,
          child: Stack(
            children: [
              Positioned.fill(
                child: _RepeatedBackground(
                  tileHeight: screenHeight,
                  child: background,
                ),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  MoeChatHeader(
                    showBackButton: showBackButton,
                    nativeInset: 0,
                    toolbarHeight: toolbarHeight,
                    title: Row(
                      children: [
                        MoeAvatar(
                          name: title,
                          avatarUrl: avatarUrl,
                          characterImage: characterImage,
                          size: telegramChatHeaderAvatarSize,
                        ),
                        const SizedBox(width: telegramChatHeaderGap),
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: colors.text,
                              fontSize: telegramChatHeaderTitleSize,
                              height: 1.2,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    actions: [
                      IconButton(
                        onPressed: () {},
                        icon: Icon(
                          Icons.more_horiz,
                          color: colors.headerContentColor,
                        ),
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      4,
                      telegramChatHeaderGap + 10,
                      4,
                      8,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final bubble in groupChatExportBubbles(messages))
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: MessageBubble(
                              message: bubble.message,
                              isMe: bubble.message.role == 'user',
                              avatarUrl: bubble.message.role == 'user'
                                  ? null
                                  : bubbleAvatar,
                              displayName: bubble.message.role == 'user'
                                  ? null
                                  : title,
                              showName: false,
                              showAvatar: bubble.showAvatar,
                              showCorner: bubble.showCorner,
                              documentStyle: documentStyle,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const ComposerIdlePreview(),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RepeatedBackground extends StatelessWidget {
  const _RepeatedBackground({required this.tileHeight, required this.child});

  final double tileHeight;
  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final count = math.max(1, (constraints.maxHeight / tileHeight).ceil());
      return ClipRect(
        child: OverflowBox(
          alignment: Alignment.topCenter,
          minHeight: 0,
          maxHeight: double.infinity,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < count; i++)
                SizedBox(
                  width: constraints.maxWidth,
                  height: tileHeight,
                  child: child,
                ),
            ],
          ),
        ),
      );
    },
  );
}

/// Waits until every image under [root] has decoded. Async widgets (cloud
/// media, static wallpaper blur) mount their images late, so passes repeat
/// until no new image appears. Failed images keep their error placeholder,
/// as they do in the chat.
Future<void> waitForChatExportImages(BuildContext root) async {
  final seen = <ImageProvider>{};
  var quietPasses = 0;
  for (var pass = 0; pass < 40 && quietPasses < 3; pass++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await WidgetsBinding.instance.endOfFrame;
    if (!root.mounted) throw StateError('已取消导出');
    final pending = <Future<void>>[];
    void visit(Element node) {
      final widget = node.widget;
      if (widget is Image && seen.add(widget.image)) {
        pending.add(precacheImage(widget.image, node, onError: (_, __) {}));
      }
      node.visitChildren(visit);
    }

    root.visitChildElements(visit);
    if (pending.isEmpty) {
      quietPasses++;
      continue;
    }
    quietPasses = 0;
    await Future.wait(pending).timeout(
      const Duration(seconds: 20),
      onTimeout: () => throw StateError('图片加载超时，请稍后重试'),
    );
  }
  await WidgetsBinding.instance.endOfFrame;
}

/// Rasterizes the canvas behind [boundary] at up to [pixelRatio], bounded by
/// texture size and memory; overly long selections ask for fewer messages
/// instead of silently cropping.
Future<Uint8List> captureChatExportImage(
  RenderRepaintBoundary boundary, {
  required double pixelRatio,
}) async {
  final size = boundary.size;
  final ratio = math.min(
    pixelRatio,
    math.min(
      16384 / math.max(size.width, size.height),
      math.sqrt(16000000 / (size.width * size.height)),
    ),
  );
  if (!ratio.isFinite || ratio < 1) throw StateError('所选消息过长，请分批导出');
  final image = await boundary.toImage(pixelRatio: ratio);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) throw StateError('图片生成失败，请重试');
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image.dispose();
  }
}

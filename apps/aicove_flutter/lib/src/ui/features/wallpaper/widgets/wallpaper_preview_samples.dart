import 'package:flutter/material.dart';

import '../../../../features/chat/domain/conversation.dart';
import '../../../../features/chat/domain/message.dart';
import '../../../../features/chat/presentation/widgets/character_list_item.dart';
import '../../../../features/chat/presentation/widgets/message_bubble.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';

/// 预览里壁纸上方的示例内容：全局壁纸看会话列表，角色壁纸看聊天气泡。
enum WallpaperPreviewKind { home, chat }

/// 预览画布的逻辑尺寸：按真实窗口布局后整体缩小显示。
const kNarrowPreviewSize = Size(390, 844);
const kWidePreviewSize = Size(1280, 800);

final _sampleTime = DateTime(2026, 1, 1, 21, 30);

/// 示例会话列表：标题＋几行真实列表项，第二行为当前会话高亮。
class WallpaperSampleList extends StatelessWidget {
  const WallpaperSampleList({super.key, this.conversation});

  /// 角色壁纸时放在列表里的那位角色。
  final Conversation? conversation;

  static final _names = ['小满', '纳西妲', '阿兰', '晚安电台'];
  static const _previews = ['今天也要好好吃饭哦', '那我们明天继续读那本书吧', '[图片]', '晚上好，想听点什么？'];

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 56,
          child: Center(
            child: Text(
              '聊天',
              style: TextStyle(
                fontSize: 17,
                fontWeight: MoeFontWeights.emphasis,
                color: colors.text,
              ),
            ),
          ),
        ),
        for (var i = 0; i < _names.length; i++)
          CharacterListItem(
            conversation: i == 1 && conversation != null
                ? conversation!
                : Conversation(
                    id: 'wallpaper_sample_$i',
                    title: _names[i],
                    displayName: _names[i],
                    lastMessage: _previews[i],
                    lastMessageTime: _sampleTime,
                    createdAt: _sampleTime,
                    updatedAt: _sampleTime,
                  ),
            isActive: i == 1,
            onTap: () {},
          ),
      ],
    );
  }
}

/// 示例对话：直接用聊天页的 [MessageBubble] 渲染。
class WallpaperSampleMessages extends StatelessWidget {
  const WallpaperSampleMessages({
    super.key,
    this.conversation,
    this.documentStyle = false,
  });

  final Conversation? conversation;
  final bool documentStyle;

  static final _samples = <Message>[
    Message(
      id: 'preview_user_1',
      role: 'user',
      content: '今天好累呀，想听你说说话',
      createdAt: _sampleTime,
    ),
    Message(
      id: 'preview_ai_1',
      role: 'assistant',
      content: '辛苦啦。先坐下来喝口水，我在这儿陪着你。',
      createdAt: _sampleTime,
    ),
    Message(
      id: 'preview_ai_2',
      role: 'assistant',
      content: '想从哪件事聊起都可以，慢慢说就好～',
      createdAt: _sampleTime,
    ),
    Message(
      id: 'preview_user_2',
      role: 'user',
      content: '嗯，那我先说说今天上班的事',
      createdAt: _sampleTime,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final avatar = conversation?.avatarUrl ?? conversation?.characterImage;
    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < _samples.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: MessageBubble(
              message: _samples[i],
              isMe: _samples[i].role == 'user',
              avatarUrl: _samples[i].role == 'user' ? null : avatar,
              displayName: conversation?.displayName ?? '',
              showName: false,
              // 同一发送方连续消息只在最后一条显示头像与尾角。
              showAvatar: _isLastOfRun(i),
              showCorner: _isLastOfRun(i),
              documentStyle: documentStyle,
            ),
          ),
      ],
    );
  }

  static bool _isLastOfRun(int index) =>
      index == _samples.length - 1 ||
      _samples[index + 1].role != _samples[index].role;
}

/// 一个预览画布里壁纸上方的界面：窄屏整屏内容，宽屏左侧悬浮列表＋右侧详情。
class WallpaperSampleScreen extends StatelessWidget {
  const WallpaperSampleScreen({
    super.key,
    required this.kind,
    required this.wide,
    this.conversation,
    this.documentStyle = false,
  });

  final WallpaperPreviewKind kind;
  final bool wide;
  final Conversation? conversation;
  final bool documentStyle;

  @override
  Widget build(BuildContext context) {
    final messages = Padding(
      padding: const EdgeInsets.fromLTRB(8, 72, 8, 96),
      child: WallpaperSampleMessages(
        conversation: conversation,
        documentStyle: documentStyle,
      ),
    );
    if (!wide) {
      return kind == WallpaperPreviewKind.home
          ? WallpaperSampleList(conversation: conversation)
          : messages;
    }
    return Stack(
      children: [
        Positioned(
          left: telegramWorkspaceInset,
          top: telegramWorkspaceInset,
          bottom: telegramWorkspaceInset,
          width: telegramPrimaryWidth,
          child: MoeFloatingSurface(
            baseline: MoeMaterialBaseline.background,
            useLiquid: false,
            radius: telegramPrimaryRadius,
            solidColor: context.moeColors.surface,
            border: BorderSide.none,
            shadows: const [],
            child: WallpaperSampleList(conversation: conversation),
          ),
        ),
        if (kind == WallpaperPreviewKind.chat)
          Positioned(
            left: telegramPrimaryWidth + telegramWorkspaceInset * 2,
            right: 0,
            top: 0,
            bottom: 0,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: messages,
              ),
            ),
          ),
      ],
    );
  }
}

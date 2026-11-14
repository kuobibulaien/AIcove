import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../settings/app_settings.dart';
import '../domain/conversation.dart';

/// 聊天界面里按联系人生效的显示偏好：图片预览大小、语音消息默认展开文字、
/// 隐藏用户头像。联系人没设过的项沿用旧版通用设置里存的全局值。
class ChatViewPrefs {
  const ChatViewPrefs({
    this.imagePreviewScale = 1.0,
    this.expandAudioText = true,
    this.hideUserAvatar = true,
    this.singleAvatarPerTurn = false,
  });

  /// 联系人自己的值优先，其次全局值，都没有用默认值。
  factory ChatViewPrefs.resolve(
    Conversation? conversation,
    AppSettings? settings,
  ) => ChatViewPrefs(
    imagePreviewScale:
        (conversation?.imagePreviewScale ?? settings?.imagePreviewScale ?? 1.0)
            .clamp(kMinImagePreviewScale, kMaxImagePreviewScale),
    expandAudioText:
        conversation?.expandAudioText ?? settings?.expandAudioText ?? true,
    hideUserAvatar:
        conversation?.hideUserAvatar ?? settings?.hideUserAvatar ?? true,
    singleAvatarPerTurn: settings?.singleAvatarPerTurn ?? false,
  );

  /// 所在聊天的偏好：有 [ChatViewScope] 用它，否则（导出图、备份预览等）
  /// 只用全局值。
  static ChatViewPrefs watch(BuildContext context, WidgetRef ref) =>
      ChatViewScope.maybeOf(context) ??
      ref.watch(
        appSettingsProvider.select(
          (s) => ChatViewPrefs.resolve(null, s.valueOrNull),
        ),
      );

  final double imagePreviewScale;
  final bool expandAudioText;
  final bool hideUserAvatar;
  final bool singleAvatarPerTurn;

  @override
  bool operator ==(Object other) =>
      other is ChatViewPrefs &&
      other.imagePreviewScale == imagePreviewScale &&
      other.expandAudioText == expandAudioText &&
      other.hideUserAvatar == hideUserAvatar &&
      other.singleAvatarPerTurn == singleAvatarPerTurn;

  @override
  int get hashCode => Object.hash(
    imagePreviewScale,
    expandAudioText,
    hideUserAvatar,
    singleAvatarPerTurn,
  );
}

/// 把一个联系人已经算好的 [ChatViewPrefs] 交给下面的消息气泡。由手里有会话的
/// 页面提供，气泡不必为读取显示偏好去监听整个会话列表。
class ChatViewScope extends InheritedWidget {
  const ChatViewScope({super.key, required this.prefs, required super.child});

  final ChatViewPrefs prefs;

  static ChatViewPrefs? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ChatViewScope>()?.prefs;

  @override
  bool updateShouldNotify(ChatViewScope oldWidget) => oldWidget.prefs != prefs;
}

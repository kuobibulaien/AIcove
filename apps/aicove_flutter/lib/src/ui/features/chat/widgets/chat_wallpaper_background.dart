import 'package:flutter/material.dart';

import '../../../../features/chat/domain/conversation.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';

/// 聊天区底色：深色固定；浅色未自定义（或白色）时用默认聊天底色。
Color resolveChatBackgroundColor(BuildContext context, Color? lightSetting) {
  if (Theme.of(context).brightness == Brightness.dark) {
    return telegramChatBackgroundDark;
  }
  return lightSetting == null || lightSetting == Colors.white
      ? telegramChatBackground
      : lightSetting;
}

/// 非 data URI 的壁纸／图片地址转图片源；data URI 由调用方先行解码。
ImageProvider? chatImageProviderFor(String url) {
  final trimmed = url.trim();
  if (trimmed.startsWith('data:image')) return null;
  return moeWallpaperImageProvider(trimmed);
}

/// 角色壁纸的调节：遮罩、模糊与宽窄屏截取，未设置的取聊天默认值。
WallpaperStyle chatWallpaperStyleOf(Conversation? conversation) =>
    WallpaperStyle(
      mask: conversation?.chatBackgroundMaskOpacity ?? kDefaultChatWallpaperMask,
      blur: conversation?.chatBackgroundBlurSigma ?? kDefaultChatWallpaperBlur,
    ).withEncodedFraming(conversation?.chatBackgroundFraming);

/// 角色自己存过的调节；一项都没存时为 null：有自己的图取聊天默认值，
/// 跟随全局壁纸时沿用全局壁纸的调节。
WallpaperStyle? chatWallpaperOwnStyleOf(Conversation? conversation) {
  if (conversation == null ||
      (conversation.chatBackgroundMaskOpacity == null &&
          conversation.chatBackgroundBlurSigma == null &&
          conversation.chatBackgroundFraming == null)) {
    return null;
  }
  return chatWallpaperStyleOf(conversation);
}

/// 聊天背景实际使用的调节，见 [ChatWallpaperLayer.style]。
WallpaperStyle resolveChatWallpaperStyle(
  BuildContext context,
  Conversation? conversation,
) {
  final own = chatWallpaperOwnStyleOf(conversation);
  if (own != null) return own;
  final hasImage = conversation?.chatBackgroundImage?.trim().isNotEmpty ?? false;
  return hasImage
      ? kDefaultChatWallpaperStyle
      : MoeWallpaperTheme.maybeOf(context)?.style ?? const WallpaperStyle();
}

/// 没有自己的图时聊天背景铺的全局壁纸来源；浅色自定义了聊天底色时不铺。
String? chatFallbackWallpaperSource(BuildContext context, Color fallbackColor) {
  if (fallbackColor != telegramChatBackground &&
      fallbackColor != telegramChatBackgroundDark) {
    return null;
  }
  return MoeWallpaperTheme.maybeOf(
    context,
  )?.sourceFor(GlobalWallpaperSlot.chat, Theme.of(context).brightness);
}

/// 角色壁纸默认遮罩：聊天文字多，比全局壁纸盖得重。
const double kDefaultChatWallpaperMask = 0.3;

/// 角色壁纸默认模糊：滑块范围 0～[kMaxWallpaperBlur]，默认取中等偏轻的 30。
const double kDefaultChatWallpaperBlur = 30;

/// 角色自己的图未调节过时的调节。
const WallpaperStyle kDefaultChatWallpaperStyle = WallpaperStyle(
  mask: kDefaultChatWallpaperMask,
  blur: kDefaultChatWallpaperBlur,
);

/// 会话壁纸层：与全局壁纸共用 [MoeWallpaperView]；无壁纸时回退底色或全局壁纸。
/// 聊天页与壁纸编辑页共用，保证编辑页背景就是实际聊天效果的预览。
class ChatWallpaperLayer extends StatelessWidget {
  const ChatWallpaperLayer({
    super.key,
    required this.image,
    required this.fallbackColor,
    this.style,
    this.layout,
  });

  ChatWallpaperLayer.forConversation({
    Key? key,
    required Conversation? conversation,
    required Color fallbackColor,
    WallpaperLayout? layout,
  }) : this(
         key: key,
         image: conversation?.chatBackgroundImage,
         fallbackColor: fallbackColor,
         style: chatWallpaperOwnStyleOf(conversation),
         layout: layout,
       );

  /// 壁纸地址：data URI、网络、资源或本地文件；空表示未设置。
  final String? image;
  final Color fallbackColor;

  /// 遮罩、模糊与截取；为 null 时有图取 [kDefaultChatWallpaperStyle]，
  /// 没图跟随全局壁纸时沿用全局壁纸的调节。
  final WallpaperStyle? style;

  /// 见 [MoeWallpaperView.layout]。
  final WallpaperLayout? layout;

  @override
  Widget build(BuildContext context) {
    final raw = image?.trim();
    if (raw == null || raw.isEmpty) {
      if (fallbackColor == telegramChatBackground ||
          fallbackColor == telegramChatBackgroundDark) {
        return MoeChatWallpaper(
          style: style,
          layout: layout,
          child: const SizedBox.expand(),
        );
      }
      return ColoredBox(color: fallbackColor);
    }
    return MoeWallpaperView(
      source: raw,
      style: style ?? kDefaultChatWallpaperStyle,
      color: fallbackColor,
      layout: layout,
    );
  }
}

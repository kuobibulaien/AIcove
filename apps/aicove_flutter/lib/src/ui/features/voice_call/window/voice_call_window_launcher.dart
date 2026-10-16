import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/app_logger.dart';
import '../../../../features/chat/conversation_providers.dart';
import '../../../../features/chat/domain/conversation.dart';
import '../../../../features/voice_call/application/active_voice_call.dart';
import '../../../../features/voice_call/providers/voice_call_providers.dart';
import '../../../theme/tokens.dart';
import '../../chat/widgets/chat_wallpaper_background.dart';
import 'voice_call_window_protocol.dart';

/// 桌面宽屏时通话放进独立的系统小窗（参照微信）。同一时间只有一通电话，
/// 也就只有一个小窗；再点拨号是把已有的小窗提到前面。
abstract final class VoiceCallWindows {
  static bool get supported => Platform.isMacOS || Platform.isWindows;

  static ActiveVoiceCall? _call;
  static WindowController? _window;
  static WindowMethodChannel? _channel;
  static VoiceCallWindowAppearance? _appearance;

  /// 这通电话已经在小窗里时提到前面；返回 false 表示小窗没打开，调用方
  /// 退回聊天页里的通话视图。
  static Future<bool> open(
    BuildContext context,
    ActiveVoiceCall call,
    Conversation conversation,
  ) async {
    if (identical(_call, call)) {
      await _window?.show();
      return _window != null;
    }
    if (_call != null || call.ending) return false;
    final appearance = voiceCallWindowAppearanceOf(context, conversation);
    final seed = VoiceCallWindowSeed(
      channel:
          'aicove/voice_call_window/${call.startedAt.microsecondsSinceEpoch}',
      appearance: appearance,
    );
    _call = call;
    _appearance = appearance;
    final channel = _channel = WindowMethodChannel(seed.channel);
    final link = VoiceCallWindowLink(
      call: call,
      send: (method, [arguments]) => channel.invokeMethod(method, arguments),
      onClosed: () {
        if (!identical(_call, call)) return;
        _call = null;
        _window = null;
        _channel = null;
        _appearance = null;
        channel.setMethodCallHandler(null);
      },
    );
    try {
      await channel.setMethodCallHandler((c) => link.handle(c.method));
      // 小窗自己设好尺寸再显示，避免先闪一个默认大小的窗口。
      _window = await WindowController.create(
        WindowConfiguration(
          arguments: jsonEncode(seed.toJson()),
          hiddenAtLaunch: true,
        ),
      );
    } catch (e) {
      AppLogger.error('VoiceCall', '通话小窗打开失败：$e');
      link.dispose();
      return false;
    }
    call.showInWindow();
    return true;
  }

  /// 主窗口的外观变了（壁纸、亮暗、主题色、材质参数）：推给开着的小窗。
  static void updateAppearance(VoiceCallWindowAppearance appearance) {
    final channel = _channel;
    if (channel == null || appearance == _appearance) return;
    _appearance = appearance;
    unawaited(
      channel
          .invokeMethod(VoiceCallWindowMethods.appearance, appearance.toJson())
          .catchError((Object _) {}),
    );
  }
}

/// 小窗该显示的样子，全部取自主窗口此刻的主题：聊天页那张壁纸、亮暗、
/// 主题色和根界面的材质。
VoiceCallWindowAppearance voiceCallWindowAppearanceOf(
  BuildContext context,
  Conversation conv,
) {
  final theme = Theme.of(context);
  final brightness = theme.brightness;
  final own = conv.chatBackgroundImage?.trim();
  final global = MoeWallpaperTheme.maybeOf(context);
  final glass = MoeGlassTheme.maybeOf(context);
  final useOwn = own != null && own.isNotEmpty;
  final source = useOwn
      ? own
      : global?.sourceFor(GlobalWallpaperSlot.chat, brightness);
  final style = useOwn ? chatWallpaperStyleOf(conv) : global?.style;
  final alignment = useOwn
      ? Alignment.center
      : global?.wallpaper.alignment ?? Alignment.center;
  return VoiceCallWindowAppearance(
    conversationId: conv.id,
    name: conv.displayName,
    avatarUrl: conv.avatarUrl,
    characterImage: conv.characterImage,
    wallpaper: source,
    wallpaperStyle: style?.toJson() ?? const {},
    wallpaperAlignment: [alignment.x, alignment.y],
    backgroundColor: theme.scaffoldBackgroundColor.toARGB32(),
    dark: brightness == Brightness.dark,
    accentColor: context.moeColors.accentColor.toARGB32(),
    glassEnabled: glass?.enabled ?? false,
    glassBlurSigma: glass?.blurSigma ?? 0,
    glassTintFill: glass?.tintFill ?? 0,
    glassLiquid: glass?.useLiquidGlass ?? false,
  );
}

/// 放在应用主题之下：通话在小窗里时，主窗口的壁纸、亮暗、主题色或材质
/// 参数一变就重推外观（聊天页关了也照常，小窗不跟着聊天页走）。
class VoiceCallWindowSync extends ConsumerWidget {
  const VoiceCallWindowSync({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final call = ref.watch(activeVoiceCallProvider);
    if (call == null) return child;
    return ListenableBuilder(
      listenable: call,
      builder: (context, child) {
        if (call.inWindow) _AppearanceProbe.push(context, ref, call);
        return child!;
      },
      child: child,
    );
  }
}

abstract final class _AppearanceProbe {
  static void push(BuildContext context, WidgetRef ref, ActiveVoiceCall call) {
    final conv = ref.watch(
      resolvedConversationByIdProvider(call.conversationId),
    );
    if (conv == null) return;
    final appearance = voiceCallWindowAppearanceOf(context, conv);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => VoiceCallWindows.updateAppearance(appearance),
    );
  }
}

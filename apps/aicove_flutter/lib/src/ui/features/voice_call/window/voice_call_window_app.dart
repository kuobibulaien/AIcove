import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../../../features/chat/domain/conversation.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/skin_provider.dart';
import '../../../theme/skins/moetalk_skin.dart';
import '../../../theme/tokens.dart';
import '../widgets/voice_call_view.dart';
import 'voice_call_window_protocol.dart';

/// 桌面端独立通话小窗的入口（由 `main` 按引擎参数分流）。这个引擎只注册了
/// 窗口插件，不碰数据库和设置：所见全部来自主窗口推来的状态和外观。
Future<void> runVoiceCallWindow(String argument) async {
  WidgetsFlutterBinding.ensureInitialized();
  final seed = VoiceCallWindowSeed.fromJson(jsonDecode(argument) as Map);
  final appearance = ValueNotifier(seed.appearance);
  final channel = WindowMethodChannel(seed.channel);
  final call = RemoteVoiceCall(
    (method, [arguments]) => channel.invokeMethod(method, arguments),
  );
  final window = _CallWindowCloser(call);
  await channel.setMethodCallHandler((c) async {
    switch (c.method) {
      case VoiceCallWindowMethods.state:
        call.apply(c.arguments as Map);
      case VoiceCallWindowMethods.elapsed:
        call.applyElapsed(c.arguments);
      case VoiceCallWindowMethods.appearance:
        appearance.value = VoiceCallWindowAppearance.fromJson(
          c.arguments as Map,
        );
        await windowManager.setTitle(_titleOf(appearance.value));
      case VoiceCallWindowMethods.close:
        await window.close(notify: false);
    }
    return null;
  });

  await windowManager.ensureInitialized();
  // 关窗即挂断：先拦下关闭，告诉主窗口再真正关掉。
  await windowManager.setPreventClose(true);
  windowManager.addListener(window);
  final options = WindowOptions(
    size: const Size(360, 640),
    minimumSize: const Size(320, 560),
    center: true,
    title: _titleOf(seed.appearance),
    // Windows 隐藏标题栏会连关闭按钮一起去掉，只在 Mac 上把内容铺到标题栏下。
    titleBarStyle: Platform.isMacOS
        ? TitleBarStyle.hidden
        : TitleBarStyle.normal,
    windowButtonVisibility: true,
  );
  // 设尺寸或居中出错也照样把窗口显示出来，不留一通看不见的电话。
  unawaited(
    windowManager
        .waitUntilReadyToShow(options, () async {
          await windowManager.show();
          await windowManager.focus();
        })
        .catchError((Object _) => windowManager.show()),
  );
  runApp(
    ValueListenableBuilder(
      valueListenable: appearance,
      builder: (context, value, _) =>
          VoiceCallWindowApp(appearance: value, call: call),
    ),
  );
  await channel
      .invokeMethod(VoiceCallWindowMethods.ready)
      .catchError((Object _) {});
}

String _titleOf(VoiceCallWindowAppearance a) => '${a.name} · 语音通话';

class _CallWindowCloser with WindowListener {
  _CallWindowCloser(this.call);

  final RemoteVoiceCall call;
  bool _closing = false;

  @override
  void onWindowClose() => unawaited(close(notify: true));

  /// [notify] 为 true 时是用户关的窗，要让主窗口挂断。不用
  /// `windowManager.destroy`：它在 Mac 上会退出整个应用。
  Future<void> close({required bool notify}) async {
    if (_closing) return;
    _closing = true;
    if (notify) {
      await call.hangUp();
      await call.notifyClosed();
    }
    await windowManager.setPreventClose(false);
    await windowManager.close();
  }
}

/// 小窗的界面：聊天页同一张壁纸，按根界面的材质做模糊，上面是通话视图。
class VoiceCallWindowApp extends StatelessWidget {
  const VoiceCallWindowApp({
    super.key,
    required this.appearance,
    required this.call,
  });

  final VoiceCallWindowAppearance appearance;
  final RemoteVoiceCall call;

  @override
  Widget build(BuildContext context) {
    final a = appearance;
    final now = DateTime.now();
    final conversation = Conversation(
      id: a.conversationId,
      title: a.name,
      displayName: a.name,
      avatarUrl: a.avatarUrl,
      characterImage: a.characterImage,
      createdAt: now,
      updatedAt: now,
    );
    final color = Color(a.backgroundColor);
    final accent = Color(a.accentColor);
    return SkinScope(
      skin: const MoeTalkSkin(),
      child: MoeGlassTheme(
        enabled: a.glassEnabled,
        blurSigma: a.glassBlurSigma,
        tintFill: a.glassTintFill,
        useLiquidGlass: a.glassLiquid,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            brightness: a.dark ? Brightness.dark : Brightness.light,
            scaffoldBackgroundColor: color,
            extensions: [
              a.dark
                  ? MoeColors.dark(accentColor: accent)
                  : MoeColors.light(accentColor: accent),
            ],
          ),
          home: Material(
            color: color,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (a.wallpaper != null)
                  MoeWallpaperView(
                    source: a.wallpaper!,
                    style: WallpaperStyle.fromJson(
                      a.wallpaperStyle,
                      custom: false,
                    ),
                    color: color,
                    layout: WallpaperLayout.narrow,
                    fallbackAlignment: Alignment(
                      a.wallpaperAlignment.first,
                      a.wallpaperAlignment.last,
                    ),
                  ),
                // 背景的模糊跟根界面走同一套材质；纯色档根界面不模糊、整块
                // 不透明，小窗就直接露出壁纸，不把它盖掉。
                if (a.glassEnabled)
                  const MoePageSurface(child: SizedBox.expand()),
                VoiceCallView(conversation: conversation, call: call),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

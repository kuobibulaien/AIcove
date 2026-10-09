import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/audio_player_widget.dart';
import 'package:aicove_flutter/src/ui/features/chat/pages/chat_page.dart';
import 'package:aicove_flutter/src/ui/features/home/pages/main_page.dart';
import 'package:aicove_flutter/src/ui/shared/animations/parallax_slide_page_route.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/desktop_window_frame.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:just_audio/just_audio.dart';

import '../../tool/chat_segmented_fixture.dart';
import '../helpers/release_source_preview.dart';

/// 官网截图：用真实首页、聊天页与设置页渲染演示数据，写入 website/assets/shots/。
/// 只在 --dart-define=WRITE_RELEASE_FIX_PREVIEW=true 时运行；角色为内置预设纳西妲，
/// 壁纸与配图取自 test/website/fixtures/，对话为演示文案，不读取用户数据。
/// 带壁纸的聊天图体积大，网页引用的是转码后的 JPEG：
///   for n in desktop-chat phone-chat; do
///     sips -s format jpeg -s formatOptions 82 $n.png --out $n.jpg && rm $n.png; done
const _accent = Color(0xFFFC96AA);

void main() {
  testWidgets('landing page screenshots', (tester) async {
    if (!captureReleaseSourcePreview) return;
    await loadReleasePreviewFonts(tester);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    DateTime at(int h, int m) => today.add(Duration(hours: h, minutes: m));

    Message text(String id, String role, String content, DateTime time) =>
        Message.text(id: id, role: role, content: content, createdAt: time);
    Message voice(String id, String line, double seconds, DateTime time) =>
        Message.fromBlocks(
          id: id,
          role: 'assistant',
          createdAt: time,
          blocks: [
            AudioBlock(
              messageId: id,
              url: '/nonexistent/$id.wav',
              text: line,
              durationSeconds: seconds,
            ),
          ],
        );

    Message picture(String id, String line, String file, DateTime time) =>
        Message.fromBlocks(
          id: id,
          role: 'assistant',
          createdAt: time,
          blocks: [
            TextBlock(messageId: id, content: line),
            ImageBlock(
              messageId: id,
              localPath: _fixture(file),
              width: 832,
              height: 1216,
            ),
          ],
        );

    // 一天里的问候与主动关心；文案为演示所写，不取自任何真实聊天。
    final history = <Message>[
      picture('d1', '早安呀～刚醒就想给你发消息', 'nahida_morning.jpg', at(7, 32)),
      voice('d2', '早饭要好好吃，不许只喝一杯咖啡哦。', 5, at(7, 33)),
      text('d3', 'user', '起啦起啦，今天要早点去公司', at(8, 10)),
      text('d4', 'assistant', '嗯！路上小心～中午我再来找你', at(8, 11)),
      picture('d5', '午饭吃了吗？我泡了一杯茶，分你一半', 'nahida_tea.jpg', at(12, 20)),
      text('d6', 'user', '吃了！这杯茶好可爱', at(12, 35)),
      voice('d7', '下午也要加油哦，累了就抬头看看窗外。', 4, at(12, 36)),
      picture('d8', '今天的星星好亮。早点休息，明天醒来，我还在这里', 'nahida_night.jpg',
          at(22, 48)),
    ];

    final fixture = (await tester.runAsync(
      () => SegmentedChatFixture.create(
        historyMessages: history,
        settings: segmentedProbeSettings.copyWith(hideUserAvatar: true),
        decorate: (c) => c.copyWith(
          title: '纳西妲',
          displayName: '纳西妲',
          avatarUrl: 'assets/characters/images/nahida.jpg#top',
          characterImage: 'assets/characters/images/nahida.jpg',
          chatBackgroundImage: _fixture('nahida_wallpaper.jpg'),
          chatBackgroundMaskOpacity: 0.25,
          chatBackgroundBlurSigma: 0.0,
        ),
        extraOverrides: [
          audioPlayerControllerProvider.overrideWith(
            (ref, url) => AudioPlayerController(url, backend: _SilentAudio()),
          ),
        ],
      ),
    ))!;

    final navigator = GlobalKey<NavigatorState>();
    final observer = MoeDetailStackObserver();
    final router = GoRouter(
      routes: [
        ShellRoute(
          navigatorKey: navigator,
          observers: [observer],
          builder: (_, __, child) => MoeAdaptiveShell(
            primary: const MainPage(),
            detail: child,
            navigatorKey: navigator,
            observer: observer,
          ),
          routes: [
            GoRoute(
              path: '/',
              builder: (_, __) => const MoeWorkspacePlaceholder(),
              routes: [
                GoRoute(
                  path: 'chat/:id',
                  pageBuilder: (_, state) => ParallaxSlidePage(
                    dimPreviousPage: false,
                    key: state.pageKey,
                    child: ChatPage(
                      conversationId: fixture.conversation.id,
                      initialConversation: fixture.conversation,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
    final shot = GlobalKey();

    // 壁纸与配图是本地文件，解码在真实异步区完成，多留一些时间。
    Future<void> settle() async {
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pumpAndSettle();
    }

    Future<void> render(Size size, String name) async {
      await tester.binding.setSurfaceSize(size);
      await settle();
      // 测试机是 macOS，窄屏会多出桌面标题行；手机图裁掉它。
      final cropTop = size.width < 900 && isDesktop
          ? telegramCompactTitleBarHeight
          : 0.0;
      await tester.runAsync(() => _save(shot, name, cropTop));
    }

    Future<void> mount(TargetPlatform platform) async {
      debugDefaultTargetPlatformOverride = platform;
      await tester.pumpWidget(
      RepaintBoundary(
        key: shot,
        child: UncontrolledProviderScope(
          container: fixture.container,
          // 与新安装默认一致：毛玻璃材质、推荐模糊度。
          child: MoeGlassTheme(
            enabled: true,
            blurSigma: kDefaultGlassBlurSigma,
            child: MaterialApp.router(
            debugShowCheckedModeBanner: false,
            routerConfig: router,
            theme: ThemeData(
              useMaterial3: true,
              fontFamily: 'ReleasePreview',
              scaffoldBackgroundColor: moeSurface,
              extensions: [MoeColors.light(accentColor: _accent)],
            ),
          ),
          ),
        ),
      ),
    );
    }

    const phone = Size(390, 844);
    const desktop = Size(1280, 800);
    const android = TargetPlatform.android;
    const mac = TargetPlatform.macOS;

    await mount(android);
    router.go('/chat/${fixture.conversation.id}');
    await render(phone, 'phone-chat');
    await mount(mac);
    await render(desktop, 'desktop-chat');
    router.go('/');
    await settle();
    await tester.tap(find.bySemanticsLabel('设置'));
    await settle();
    await tester.tap(find.text('插件'));
    await render(desktop, 'desktop-plugins');
    await mount(android);
    await render(phone, 'phone-plugins');

    await tester.pumpWidget(const SizedBox.shrink());
    debugDefaultTargetPlatformOverride = null;
    router.dispose();
    observer.dispose();
    await tester.binding.setSurfaceSize(null);
    var disposed = false;
    final cleanup = fixture.dispose().then((_) => disposed = true);
    for (var attempt = 0; attempt < 100 && !disposed; attempt++) {
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
    }
    await cleanup;
  });
}

Future<void> _save(GlobalKey key, String name, double cropTop) async {
  const ratio = 2.0;
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final full = await boundary.toImage(pixelRatio: ratio);
  final top = (cropTop * ratio).round();
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawImage(full, Offset(0, -top.toDouble()), Paint());
  final image =
      await recorder.endRecording().toImage(full.width, full.height - top);
  full.dispose();
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  final dir = Directory(const String.fromEnvironment(
    'RELEASE_PREVIEW_DIR',
    defaultValue: '../../website/assets/shots',
  ));
  await dir.create(recursive: true);
  await File('${dir.path}/$name.png')
      .writeAsBytes(bytes!.buffer.asUint8List());
}

class _SilentAudio implements AudioPlaybackBackend {
  @override
  Stream<PlayerState> get playerStateStream => const Stream.empty();
  @override
  Stream<Duration> get positionStream => const Stream.empty();
  @override
  Stream<Duration?> get durationStream => const Stream.empty();
  @override
  Stream<PlaybackEvent> get playbackEventStream => const Stream.empty();
  @override
  Duration get position => Duration.zero;
  @override
  Future<Duration?> setUrl(String url) async => const Duration(seconds: 4);
  @override
  Future<Duration?> setFilePath(String path) async =>
      const Duration(seconds: 4);
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> dispose() async {}
}

String _fixture(String name) =>
    File('test/website/fixtures/$name').absolute.path;

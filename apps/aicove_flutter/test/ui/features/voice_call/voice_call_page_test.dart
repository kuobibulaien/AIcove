import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/message_action_sheet.dart';
import 'package:aicove_flutter/src/features/voice_call/application/active_voice_call.dart';
import 'package:aicove_flutter/src/features/voice_call/application/voice_call_archiver.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/voice_call/application/voice_call_session.dart';
import 'package:aicove_flutter/src/features/voice_call/domain/speech_recognizer_port.dart';
import 'package:aicove_flutter/src/features/voice_call/providers/voice_call_providers.dart';
import 'package:aicove_flutter/src/ui/features/voice_call/pages/voice_call_page.dart';
import 'package:aicove_flutter/src/ui/features/voice_call/widgets/voice_call_floating_window.dart';
import 'package:aicove_flutter/src/ui/features/voice_call/widgets/voice_call_live_messages.dart';
import 'package:aicove_flutter/src/ui/theme/skin_provider.dart';
import 'package:aicove_flutter/src/ui/theme/skins/moetalk_skin.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../features/voice_call/voice_call_fakes.dart';

final _conv = Conversation(
  id: 'nahida',
  title: '纳西妲',
  displayName: '纳西妲',
  createdAt: DateTime(2026, 10, 12),
  updatedAt: DateTime(2026, 10, 12),
  chatBackgroundImage: 'assets/wallpapers/catnap_light.webp',
);

void main() {
  const capture = bool.fromEnvironment('WRITE_VOICE_CALL_PREVIEW');
  late FakeRecognizer recognizer;
  late FakeGenerator generator;
  late FakeOutput output;
  late VoiceCallSession session;
  late List<Message> bubbles;
  late ActiveVoiceCall call;

  setUp(() {
    bubbles = [];
    recognizer = FakeRecognizer();
    generator = FakeGenerator();
    output = FakeOutput();
    session = VoiceCallSession(
      recognizer: recognizer,
      tts: FakeTts(),
      input: FakeInput(),
      output: output,
      generator: generator,
      turnEndQuiet: const Duration(milliseconds: 40),
      userTurnGap: Duration.zero,
      pollInterval: const Duration(milliseconds: 10),
    );
  });

  final navigator = GlobalKey<NavigatorState>();

  /// 聊天页在下面，通话页压在上面（同真实入口），收起或挂断时弹回聊天页。
  Future<void> mount(
    WidgetTester tester,
    Future<VoiceCallSession> Function() build, {
    GlobalKey? boundary,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    call = ActiveVoiceCall(
      conversationId: _conv.id,
      createSession: build,
      archiver: VoiceCallArchiver(
        newId: (prefix) => prefix,
        appendBubble: (_, bubble) async => bubbles.add(bubble),
      ),
      describeError: (e) => e is VoiceCallUnavailable ? e.message : '通话接通失败：$e',
    );
    await tester.pumpWidget(
      ProviderScope(
        child: SkinScope(
          skin: const MoeTalkSkin(),
          child: MaterialApp(
            navigatorKey: navigator,
            theme: ThemeData(
              fontFamily: capture ? 'Preview' : null,
              extensions: [MoeColors.light()],
            ),
            home: const Scaffold(body: Text('聊天页')),
          ),
        ),
      ),
    );
    unawaited(call.connect());
    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => RepaintBoundary(
            key: boundary,
            child: VoiceCallPage(conversation: _conv, call: call),
          ),
        ),
      ),
    );
    // 计时器每秒刷新，不能 pumpAndSettle；推进到页面转场走完。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  /// 跑完一轮：用户说一句，角色回一句并播完。
  /// 会话在测试时钟里启动，事件回调要靠 pump 推进。
  Future<void> oneTurn(WidgetTester tester) async {
    recognizer.emit(const SpeechFinal('我今天下午去面试了，好紧张'));
    await tester.pump();
    generator.current!.add('诶？面试怎么样啊？没准备的问题确实挺慌的。');
    await tester.pump();
    await generator.current!.close();
    await tester.pump();
    output.playAll();
    // 轮次结束按真实时间判断静默，等一下再推进测试时钟里的检查定时器。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
  }

  testWidgets('connects, shows the conversation and hangs up on leave', (
    tester,
  ) async {
    await mount(tester, () async => session);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    expect(find.text('纳西妲'), findsOneWidget);
    expect(find.text('在听'), findsOneWidget);

    // 扬声器和话筒各自开关，按钮上方提示当前关掉了什么。
    await tester.tap(find.byKey(const ValueKey('voice-call-speaker')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(output.silenced, isTrue);
    expect(find.text('扬声器已关闭，可以看字幕'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('voice-call-mute')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(session.muted, isTrue);
    expect(find.text('话筒和扬声器已关闭'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('voice-call-speaker')));
    await tester.tap(find.byKey(const ValueKey('voice-call-mute')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(output.silenced, isFalse);
    expect(session.muted, isFalse);
    expect(find.byKey(const ValueKey('voice-call-notice')), findsNothing);

    await oneTurn(tester);
    expect(find.text('我今天下午去面试了，好紧张'), findsOneWidget);
    expect(find.text('诶？面试怎么样啊？没准备的问题确实挺慌的。'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    // 挂断里的取消订阅跨越测试时钟与真实事件循环，交替推进直到走完。
    for (var i = 0; i < 100 && session.phase != VoiceCallPhase.ended; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(session.phase, VoiceCallPhase.ended);
    for (var i = 0; i < 20 && bubbles.isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
    // 挂断即存档：聊天只多一条气泡，逐句记录在气泡里。
    expect((bubbles.single.blocks!.single as CallRecordBlock).turns, hasLength(2));
    expect(bubbles.single.content, startsWith('[语音通话 '));
    expect(tester.takeException(), isNull);
  });

  testWidgets('typing tucks the call into a floating window and back', (
    tester,
  ) async {
    await mount(tester, () async => session);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('voice-call-type')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    // 页面收起，通话照常进行，话筒暂停。
    expect(find.byType(VoiceCallPage), findsNothing);
    expect(call.minimized, isTrue);
    expect(session.typing, isTrue);
    expect(session.phase, VoiceCallPhase.listening);

    // 打的字进通话，回复照常念出来，同在一份逐句记录里。
    expect(call.sendText('我在地铁上'), isTrue);
    await tester.pump();
    generator.current!.add('那我小声点说。');
    await tester.pump();
    await generator.current!.close();
    await tester.pump();
    output.playAll();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    final live = voiceCallLiveMessages(call);
    expect(live.map((m) => (m.role, m.content)), [
      ('user', '我在地铁上'),
      ('assistant', '那我小声点说。'),
    ]);
    expect(live.first.id, startsWith(voiceCallLiveMessagePrefix));

    // 在聊天里删一句：只是不再显示，通话记录照常保留。
    call.hideTurn(voiceCallLiveTurnIndex(live.first.id)!);
    expect(voiceCallLiveMessages(call).map((m) => m.content), ['那我小声点说。']);
    expect(call.transcript, hasLength(2));

    // 悬浮窗：正中是禁用的话筒，点一下回到通话、话筒恢复。
    var reopened = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              Positioned.fill(
                child: VoiceCallFloatingWindow(
                  call: call,
                  onTap: () {
                    call.restore();
                    reopened = true;
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('voice-call-floating-mic')), findsOne);
    await tester.tap(find.byKey(const ValueKey('voice-call-floating-window')));
    expect(reopened, isTrue);
    expect(call.minimized, isFalse);
    expect(session.typing, isFalse);

    unawaited(call.hangUp());
    // 挂断跨越测试时钟与真实事件循环，交替推进直到存档完成。
    for (var i = 0; i < 100 && bubbles.isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }
    final block = bubbles.single.blocks!.single as CallRecordBlock;
    // 打的字和说的话在同一条通话气泡里。
    expect(block.turns.map((t) => t.text), ['我在地铁上', '那我小声点说。']);
  });

  testWidgets('a live call bubble menu has no edit or regenerate', (
    tester,
  ) async {
    for (final isUser in [true, false]) {
      final target = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          // 换一个 key，上一轮打开的菜单随旧 Navigator 一起丢掉。
          key: ValueKey(isUser),
          home: Scaffold(
            body: Center(
              child: Builder(
                builder: (context) => TextButton(
                  key: target,
                  onPressed: () => showMessageActionMenu(
                    context,
                    targetBox:
                        target.currentContext!.findRenderObject()! as RenderBox,
                    isUserMessage: isUser,
                    messageText: '我在地铁上',
                    editable: false,
                    onAction: (_) {},
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('复制'), findsOneWidget);
      expect(find.text('删除'), findsOneWidget);
      for (final hidden in ['编辑', '重新生成', '增强生成', '引用', '多选']) {
        expect(find.text(hidden), findsNothing);
      }
    }
  });

  testWidgets('shows why the call cannot connect', (tester) async {
    await mount(
      tester,
      () async => throw const VoiceCallUnavailable('此角色没有可用的音色'),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    expect(find.text('此角色没有可用的音色'), findsOneWidget);
  });

  testWidgets('voice call source rendered preview', (tester) async {
    if (!capture) return;
    await tester.runAsync(() async {
      final loader = FontLoader('Preview')
        ..addFont(
          File(
            '/System/Library/Fonts/STHeiti Medium.ttc',
          ).readAsBytes().then(ByteData.sublistView),
        );
      await loader.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(
          File(
            '${Platform.environment['HOME']}/dev-sdks/flutter-3.44.6/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ).readAsBytes().then(ByteData.sublistView),
        );
      await icons.load();
    });
    final key = GlobalKey();
    await mount(tester, () async => session, boundary: key);
    // 背景图解码要在真实事件循环里完成。
    await tester.runAsync(
      () => precacheImage(
        const AssetImage('assets/wallpapers/catnap_light.webp'),
        tester.element(find.byType(VoiceCallPage)),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    await oneTurn(tester);
    await tester.tap(find.byKey(const ValueKey('voice-call-speaker')));
    // 等背景、状态文字与提示胶囊的过渡动画走完再截。
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final dir = Directory('../../.codex-temp/voice-call/previews')
        ..createSync(recursive: true);
      await File(
        '${dir.path}/voice-call-390.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
    // 收起成悬浮窗后的样子：聊天背景上的小窗，正中是禁用的话筒。
    await tester.tap(find.byKey(const ValueKey('voice-call-type')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final floatKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(fontFamily: 'Preview'),
        home: RepaintBoundary(
          key: floatKey,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.asset(
                'assets/wallpapers/catnap_light.webp',
                fit: BoxFit.cover,
              ),
              Positioned.fill(
                child: VoiceCallFloatingWindow(
                  call: call,
                  topInset: 56,
                  onTap: () {},
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() async {
      final boundary =
          floatKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '../../.codex-temp/voice-call/previews/voice-call-floating-390.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
    // 通话临时气泡的长按菜单：只有复制和删除。
    final menuKey = GlobalKey();
    final menuTarget = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: menuKey,
        child: MaterialApp(
          key: const ValueKey('menu-preview'),
          theme: ThemeData(fontFamily: 'Preview'),
          home: Scaffold(
            body: Center(
              child: Builder(
                builder: (context) => TextButton(
                  key: menuTarget,
                  onPressed: () => showMessageActionMenu(
                    context,
                    targetBox:
                        menuTarget.currentContext!.findRenderObject()!
                            as RenderBox,
                    isUserMessage: true,
                    messageText: '我在地铁上',
                    editable: false,
                    onAction: (_) {},
                  ),
                  child: const Text('我在地铁上'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('我在地铁上'));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.runAsync(() async {
      final boundary =
          menuKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '../../.codex-temp/voice-call/previews/voice-call-live-menu-390.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
    unawaited(call.hangUp());
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 100 && session.phase != VoiceCallPhase.ended; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }
  });
}

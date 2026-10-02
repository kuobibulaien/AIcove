import 'package:aicove_flutter/src/features/chat/presentation/widgets/composer.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/composer_more_panel.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/message_bubble.dart';
import 'package:aicove_flutter/src/ui/features/chat/pages/chat_page.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_message_list.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_adaptive_shell.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_chat_header.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_floating_surface.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../../tool/chat_segmented_fixture.dart';

void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    for (final scale in [1.0, 1.8]) {
      testWidgets(
        '手机悬浮控件、菜单和键盘区域 $platform / $scale',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(360, 800);
          tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 24);
          tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
          addTearDown(() {
            tester.view.reset();
          });
          final fixture = (await tester.runAsync(
            () => SegmentedChatFixture.create(historyCount: 20),
          ))!;
          final navigator = GlobalKey<NavigatorState>();
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: fixture.container,
              child: MaterialApp(
                navigatorKey: navigator,
                theme: ThemeData(extensions: [MoeColors.light()]),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: const Scaffold(body: Text('联系人')),
              ),
            ),
          );
          navigator.currentState!.push(
            MaterialPageRoute<void>(
              builder: (_) => MoeWorkspace(
                navigatorKey: navigator,
                isWide: false,
                isDetail: true,
                child: ChatPage(
                  conversationId: fixture.conversation.id,
                  initialConversation: fixture.conversation,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final header = find.byType(MoeChatHeader);
          expect(
            tester.getRect(find.byType(ChatMessageList)).top,
            tester.getRect(find.byType(ChatPage)).top,
            reason: '消息视口延伸到导航背后，滚动不能在标题底部硬截断',
          );
          final back = find.descendant(
            of: header,
            matching: find.byType(BackButton),
          );
          expect(tester.getRect(back).left, 12);
          expect(tester.getRect(back).top, 30, reason: '仅避让手机状态栏，不插入Mac标题行');
          expect(
            find.descendant(
              of: header,
              matching: find.byType(MoeFloatingSurface),
            ),
            findsNWidgets(3),
          );
          expect(
            find.byKey(const ValueKey('workspace-compact-titlebar')),
            findsNothing,
          );

          await tester.drag(find.byType(ChatMessageList), const Offset(0, 300));
          await tester.pumpAndSettle();
          final scrollable = tester.state<ScrollableState>(
            find.descendant(
              of: find.byType(ChatMessageList),
              matching: find.byType(Scrollable),
            ),
          );
          scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
          await tester.pumpAndSettle();
          final oldest = find.byWidgetPredicate(
            (widget) =>
                widget is MessageBubble &&
                widget.message.displayText.contains('第 0 条历史消息'),
          );
          expect(
            tester.getRect(oldest).top,
            greaterThanOrEqualTo(tester.getRect(header).bottom),
            reason: '滚到最早一条时，正文必须完整露出导航下方',
          );

          await tester.tap(find.byTooltip('更多'));
          await tester.pumpAndSettle();
          expect(find.text('多选'), findsNothing);
          expect(find.text('详情'), findsOneWidget);
          expect(find.text('绘图风格'), findsOneWidget);
          expect(find.text('聊天设置'), findsNothing);
          expect(find.text('关闭聊天'), findsNothing);
          navigator.currentState!.pop();
          await tester.pumpAndSettle();

          final input = find.descendant(
            of: find.byType(Composer),
            matching: find.byType(TextField),
          );
          await tester.enterText(input, '保留手机草稿');
          tester.view.viewInsets = const FakeViewPadding(bottom: 280);
          tester.view.padding = const FakeViewPadding(top: 24);
          await tester.pumpAndSettle();
          final surface = find.byKey(
            const ValueKey('composer-floating-surface'),
          );
          final rect = tester.getRect(surface);
          expect(rect.bottom, lessThanOrEqualTo(520), reason: '输入浮层位于软键盘上方');
          expect(rect.height, lessThan(160), reason: '键盘占位不能拉长圆角输入浮层');
          expect(rect.left, 12);
          expect(rect.right, 348);

          tester.view.viewInsets = const FakeViewPadding(bottom: 1);
          await tester.pumpAndSettle();
          await tester.tap(find.byIcon(Icons.add_rounded));
          tester.view.viewInsets = const FakeViewPadding();
          tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
          await tester.pumpAndSettle();
          expect(find.byType(ComposerMorePanel), findsOneWidget);
          expect(
            tester.getSize(find.byType(ComposerMorePanel)).height,
            greaterThanOrEqualTo(200),
            reason: '浮动输入法的小高度不能压扁附件面板',
          );
          expect(tester.widget<TextField>(input).controller!.text, '保留手机草稿');
          expect(tester.takeException(), isNull);
          await tester.tap(back);
          await tester.pumpAndSettle();
          expect(find.byType(ChatPage), findsNothing);
          await tester.pumpWidget(const SizedBox.shrink());
          var disposed = false;
          final cleanup = fixture.dispose().then((_) => disposed = true);
          for (var attempt = 0; attempt < 100 && !disposed; attempt++) {
            await tester.pump(const Duration(milliseconds: 16));
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 5)),
            );
          }
          expect(disposed, isTrue);
          await cleanup;
        },
        variant: TargetPlatformVariant({platform}),
      );
    }
  }

  for (final width in [360.0, 420.0, 1000.0, 1280.0]) {
    for (final dark in [false, true]) {
      testWidgets('导航前景与安全区保持原尺寸 $width / dark=$dark', (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 400);
        tester.view.padding = const FakeViewPadding(top: 24);
        tester.view.viewPadding = const FakeViewPadding(top: 24);
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              brightness: dark ? Brightness.dark : Brightness.light,
              extensions: [dark ? MoeColors.dark() : MoeColors.light()],
            ),
            home: const Scaffold(
              extendBodyBehindAppBar: true,
              appBar: MoeChatHeader(
                title: Text('导航栏'),
                actions: [],
                showBackButton: true,
                nativeInset: 0,
                toolbarHeight: 90,
              ),
              body: SizedBox.expand(),
            ),
          ),
        );
        expect(
          tester.getRect(find.byType(BackButton)),
          const Rect.fromLTWH(12, 30, 90, 90),
        );
        expect(tester.getSize(find.byType(MoeChatHeader)).height, 126);
        expect(tester.takeException(), isNull);
      });
    }
  }
}

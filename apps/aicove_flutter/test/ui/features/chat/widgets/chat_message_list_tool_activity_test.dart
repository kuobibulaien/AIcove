import 'dart:io';

import 'package:aicove_flutter/src/features/chat/chat_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/chat_display_policy.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/message_bubble.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_message_list.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_viewport_controller.dart';
import 'package:aicove_flutter/src/ui/theme/skin_provider.dart';
import 'package:aicove_flutter/src/ui/theme/skins/moetalk_skin.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../../../../../tool/chat_segmented_fixture.dart';
import '../../../../helpers/release_source_preview.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final originalPaths = PathProviderPlatform.instance;
  late Directory directory;
  setUpAll(() {
    directory = Directory.systemTemp.createTempSync('tool_activity_list_');
    PathProviderPlatform.instance = _Paths(directory.path);
  });
  tearDownAll(() async {
    PathProviderPlatform.instance = originalPaths;
    await directory.delete(recursive: true);
  });

  for (final width in [390.0, 1000.0]) {
    for (final style in ChatDisplayStyle.values) {
      testWidgets('工具活动独立显示在最后消息后，不重建列表：$width / ${style.name}', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 640);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        await loadReleasePreviewFonts(tester);
        final fixture = (await tester.runAsync(
          () => SegmentedChatFixture.create(
            historyMessages: [
              Message.text(id: 'user', role: 'user', content: '帮我看一下配置文件。'),
              Message.text(
                id: 'assistant',
                role: 'assistant',
                content: '收到，我来检查一下。',
              ),
            ],
            decorate: (c) => c.copyWith(chatDisplayStyle: style),
          ),
        ))!;
        final viewport = ChatViewportController();
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(fixture.dispose);
          viewport.dispose();
        });
        final boundary = GlobalKey();
        var listBuilds = 0;
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: fixture.container,
            child: SkinScope(
              skin: const MoeTalkSkin(),
              child: MaterialApp(
                theme: ThemeData(
                  fontFamily: captureReleaseSourcePreview
                      ? 'ReleasePreview'
                      : null,
                ),
                home: RepaintBoundary(
                  key: boundary,
                  child: Scaffold(
                    body: ChatMessageList(
                      conversationId: fixture.conversation.id,
                      messages: fixture.timeline.value,
                      displayName: 'AIcove酱',
                      viewportController: viewport,
                      hasMoreMessages: false,
                      chatDisplayStyle: style,
                      onDebugListItemCountChanged: (_) => listBuilds++,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        final buildsBefore = listBuilds;
        expect(find.byType(TypingDotsIndicator), findsNothing);
        expect(find.byKey(const ValueKey('tool-activity')), findsNothing);

        // Another conversation's tool never shows in this list.
        fixture.container
            .read(conversationToolActivityProvider('other').notifier)
            .state = 'read · other.json';
        await tester.pump();
        expect(find.byKey(const ValueKey('tool-activity')), findsNothing);

        final activity = fixture.container.read(
          conversationToolActivityProvider(fixture.conversation.id).notifier,
        );
        activity.state = 'read · config.json';
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text('正在调用 read · config.json'), findsOneWidget);
        expect(
          tester.getRect(find.byKey(const ValueKey('tool-activity'))).top,
          greaterThanOrEqualTo(
            tester.getRect(find.byType(MessageBubble).last).bottom,
          ),
        );
        expect(listBuilds, buildsBefore);
        expect(tester.takeException(), isNull);
        await saveReleaseSourcePreview(
          tester,
          boundary,
          'tool-activity-${width.toInt()}-${style.name}',
        );
        // Image capture runs real async work, so flush unrelated hydration
        // before measuring the next provider-only update.
        await tester.pump();
        final buildsBeforeClear = listBuilds;

        activity.state = null;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byKey(const ValueKey('tool-activity')), findsNothing);
        expect(listBuilds, buildsBeforeClear);
        expect(tester.takeException(), isNull);
      });
    }
  }
}

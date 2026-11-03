import 'package:aicove_flutter/src/core/models/block_status.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/message_action_sheet.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/message_bubble.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/regenerate_guidance_dialog.dart';
import 'package:aicove_flutter/src/ui/theme/skin_provider.dart';
import 'package:aicove_flutter/src/ui/theme/skins/moetalk_skin.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'pages/chat_interface_test_support.dart';

void main() {
  group('改词重画菜单', () {
    for (final type in MediaType.values) {
      testWidgets('$type 菜单项', (tester) async {
        MessageAction? selected;
        await tester.pumpWidget(MaterialApp(
          theme: ThemeData(extensions: [MoeColors.light()]),
          home: Scaffold(
            body: Center(
              child: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showMediaActionMenu(
                    context,
                    targetBox: context.findRenderObject()! as RenderBox,
                    mediaType: type,
                    allowRegenerate: true,
                    onAction: (action) => selected = action,
                  ),
                  child: const Text('菜单'),
                ),
              ),
            ),
          ),
        ));
        await tester.tap(find.text('菜单'));
        await tester.pumpAndSettle();
        if (type == MediaType.audio) {
          expect(find.text('改词重画'), findsNothing);
          return;
        }
        expect(find.text('重新生成图片'), findsOneWidget);
        await tester.tap(find.text('改词重画'));
        await tester.pumpAndSettle();
        expect(selected, MessageAction.editAndRegenerateMedia);
      });
    }

    testWidgets('不允许重画时不显示改词重画', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(extensions: [MoeColors.light()]),
        home: Scaffold(
          body: Center(
            child: Builder(
              builder: (context) => TextButton(
                onPressed: () => showMediaActionMenu(
                  context,
                  targetBox: context.findRenderObject()! as RenderBox,
                  mediaType: MediaType.image,
                  onAction: (_) {},
                ),
                child: const Text('菜单'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('菜单'));
      await tester.pumpAndSettle();
      expect(find.text('改词重画'), findsNothing);
      await tester.tapAt(const Offset(1, 1));
      await tester.pumpAndSettle();
    });
  });

  group('改词重画弹窗', () {
    Future<List<String?>> pumpHost(WidgetTester tester) async {
      final results = <String?>[];
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(extensions: [MoeColors.light()]),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => results.add(
              await showEditImagePromptDialog(
                context,
                initialPrompt: '原画面描述',
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return results;
    }

    testWidgets('预填原提示词，重画返回去除首尾空白的文本', (tester) async {
      final results = await pumpHost(tester);
      expect(find.text('改词重画'), findsOneWidget);
      expect(find.text('原画面描述'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '  新的台词 ');
      await tester.tap(find.text('重画'));
      await tester.pumpAndSettle();
      expect(results, ['新的台词']);
    });

    testWidgets('清空后点重画不提交，取消返回 null', (tester) async {
      final results = await pumpHost(tester);
      await tester.enterText(find.byType(TextField), '   ');
      await tester.tap(find.text('重画'));
      await tester.pumpAndSettle();
      expect(results, isEmpty);
      expect(find.text('改词重画'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(results, [null]);
    });
  });

  group('图片版本切换与失败提示', () {
    ImageBlock image({
      int versions = 0,
      int active = 0,
      BlockStatus status = BlockStatus.success,
      String? prompt,
    }) =>
        ImageBlock(
          id: 'img',
          messageId: 'm',
          localPath: status == BlockStatus.error ? null : '/missing.png',
          status: status,
          prompt: prompt,
          versions: [
            for (var i = 0; i < versions; i++) ImageVersionEntry(prompt: 'p$i'),
          ],
          activeVersionIndex: active,
        );

    Future<List<int>> pumpBubble(WidgetTester tester, ImageBlock block) async {
      final selected = <int>[];
      await tester.pumpWidget(ProviderScope(
        overrides: [
          appSettingsProvider.overrideWith(
            () => FakeChatInterfaceSettingsNotifier(
              chatInterfaceTestSettings(),
            ),
          ),
        ],
        child: SkinScope(
          skin: const MoeTalkSkin(),
          child: MaterialApp(
            theme: ThemeData(extensions: [MoeColors.light()]),
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 390,
                  child: MessageBubble(
                    isMe: false,
                    message: Message.fromBlocks(
                      id: 'm',
                      role: 'assistant',
                      createdAt: DateTime(2026, 10, 28),
                      blocks: [block],
                    ),
                    onMediaLongPress: (_, __, ___) {},
                    onSelectImageVersion: (b, index) => selected.add(index),
                  ),
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      return selected;
    }

    testWidgets('单版本不显示切换条', (tester) async {
      await pumpBubble(tester, image(versions: 1));
      expect(find.byKey(const Key('image_version_prev_img')), findsNothing);
      expect(find.text('1/1'), findsNothing);
    });

    testWidgets('多版本中间页可前后切换', (tester) async {
      final selected = await pumpBubble(tester, image(versions: 3, active: 1));
      expect(find.text('2/3'), findsOneWidget);
      await tester.tap(find.byKey(const Key('image_version_prev_img')));
      await tester.tap(find.byKey(const Key('image_version_next_img')));
      expect(selected, [0, 2]);
    });

    testWidgets('首页和末页的边界箭头不触发', (tester) async {
      var selected = await pumpBubble(tester, image(versions: 2));
      await tester.tap(find.byKey(const Key('image_version_prev_img')));
      expect(selected, isEmpty);
      selected = await pumpBubble(tester, image(versions: 2, active: 1));
      await tester.tap(find.byKey(const Key('image_version_next_img')));
      expect(selected, isEmpty);
    });

    testWidgets('生成失败且可重画时显示重画提示', (tester) async {
      await pumpBubble(tester, image(status: BlockStatus.error, prompt: 'cat'));
      expect(find.text('生成失败，长按可重画'), findsOneWidget);
    });

    testWidgets('生成失败但没有提示词时不显示重画提示', (tester) async {
      await pumpBubble(tester, image(status: BlockStatus.error));
      expect(find.text('生成失败，长按可重画'), findsNothing);
    });

    testWidgets('越界的版本索引按末页显示且不传出越界值', (tester) async {
      final selected = await pumpBubble(tester, image(versions: 2, active: 5));
      expect(find.text('2/2'), findsOneWidget);
      await tester.tap(find.byKey(const Key('image_version_next_img')));
      await tester.tap(find.byKey(const Key('image_version_prev_img')));
      expect(selected, [0]);
    });

    testWidgets('成功态图片不显示重画提示', (tester) async {
      await pumpBubble(tester, image());
      expect(find.text('生成失败，长按可重画'), findsNothing);
    });
  });
}

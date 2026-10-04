import 'dart:io';

import 'package:aicove_flutter/src/features/agent_context/data/silly_tavern_preset_store.dart';
import 'package:aicove_flutter/src/features/agent_context/providers/preset_recipe_provider.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/ui/features/plugins/pages/tavern_plugin_detail_page.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../helpers/release_source_preview.dart';

class _NoRoles extends ConversationsNotifier {
  @override
  Future<List<Conversation>> build() async => const [];
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('预设详情页可删除预设并回到列表', (tester) async {
    await loadReleasePreviewFonts(tester);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('tavern_delete_ui_'),
    ))!;
    addTearDown(() => directory.delete(recursive: true));
    final store = SillyTavernPresetStore(
      documentsDirectoryResolver: () async => directory,
    );
    await tester.runAsync(
      () => store.importSource(
        '{"name":"待删预设","prompts":[{"identifier":"chatHistory","marker":true}],"prompt_order":[{"identifier":"chatHistory","enabled":true}]}',
        sourceFileName: 'a.json',
      ),
    );
    final boundary = GlobalKey();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sillyTavernPresetStoreProvider.overrideWithValue(store),
          conversationsProvider.overrideWith(_NoRoles.new),
        ],
        child: RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            theme: ThemeData(
              fontFamily: captureReleaseSourcePreview ? 'ReleasePreview' : null,
              extensions: [MoeColors.light()],
            ),
            home: const TavernPluginDetailPage(),
          ),
        ),
      ),
    );
    await _settle(tester);
    await tester.tap(find.text('待删预设'));
    await _settle(tester);

    final delete = find.text('删除预设');
    await tester.ensureVisible(delete);
    await _settle(tester);
    await saveReleaseSourcePreview(
      tester,
      boundary,
      'tavern-preset-delete-row',
    );
    await tester.tap(delete);
    await _settle(tester);
    await saveReleaseSourcePreview(
      tester,
      boundary,
      'tavern-preset-delete-confirm',
    );
    await tester.tap(find.text('删除').last);
    await _settle(tester);

    expect(find.text('酒馆相关'), findsOneWidget);
    expect(find.text('待删预设'), findsNothing);
    expect((await tester.runAsync(store.list))!, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 5));
  });
}

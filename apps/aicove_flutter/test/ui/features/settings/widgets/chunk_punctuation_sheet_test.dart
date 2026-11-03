import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/features/settings/widgets/chunk_punctuation_sheet.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<ProviderContainer> pumpEditor(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(appSettingsProvider.future);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: ChunkPunctuationEditor()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  MessageFormatConfig configOf(ProviderContainer c) =>
      c.read(appSettingsProvider).requireValue.messageFormatConfig;

  testWidgets('switching a plan and toggling a mark updates the active set', (
    tester,
  ) async {
    final c = await pumpEditor(tester);
    expect(configOf(c).activeChunkPunctuationSetId, 'standard');
    expect(find.text('回复会按下面这样拆成 3 条气泡'), findsOneWidget);

    await tester.tap(find.text('激进'));
    await tester.pumpAndSettle();
    expect(configOf(c).activeChunkPunctuationSetId, 'aggressive');
    expect(configOf(c).chunkPunctuations, contains('，'));

    await tester.tap(find.text('～'));
    await tester.pumpAndSettle();
    expect(configOf(c).activeChunkPunctuationSet!.punctuations, isNot(contains('～')));
    expect(configOf(c).chunkPunctuations, isNot(contains('～')));
    expect(find.textContaining('回复会按下面这样拆成'), findsOneWidget);

    await tester.tap(find.text('～'));
    await tester.pumpAndSettle();
    expect(configOf(c).chunkPunctuations.last, '～');
  });

  testWidgets('custom marks auto-save next to the toggled ones', (
    tester,
  ) async {
    final c = await pumpEditor(tester);
    await tester.enterText(find.byType(TextField), '♪  ★ 。');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(configOf(c).chunkPunctuations, ['♪', '★', '。']);

    // Switching away and back shows only the non-toggle marks in the field.
    await tester.tap(find.text('激进'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    await tester.tap(find.text('默认'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '♪ ★',
    );
  });

  testWidgets('line breaks and space runs are set per plan', (tester) async {
    final c = await pumpEditor(tester);
    expect(configOf(c).chunkSpaceRun, 3);
    await tester.ensureVisible(find.text('换行处分段').first);
    await tester.tap(find.byType(MoeSwitch));
    await tester.pumpAndSettle();
    expect(configOf(c).activeChunkPunctuationSet!.splitOnNewline, isFalse);
    expect(configOf(c).splitOnNewline, isFalse);

    await tester.tap(find.text('不分'));
    await tester.pumpAndSettle();
    expect(configOf(c).chunkSpaceRun, 0);
    expect(find.text('按现在的设置，这段回复不会拆开'), findsOneWidget);

    // Other plans keep their own rules.
    await tester.ensureVisible(find.text('激进'));
    await tester.tap(find.text('激进'));
    await tester.pumpAndSettle();
    expect(configOf(c).splitOnNewline, isTrue);
    expect(configOf(c).chunkSpaceRun, kDefaultChunkSpaceRun);
  });
}

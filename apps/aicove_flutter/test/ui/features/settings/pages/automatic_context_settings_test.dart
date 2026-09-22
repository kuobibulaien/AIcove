import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/plugins/plugin_providers.dart';
import 'package:aicove_flutter/src/features/plugins/memory/memory_config.dart';
import 'package:aicove_flutter/src/features/chat/providers/topic_compaction_provider.dart';
import 'package:aicove_flutter/src/features/chat/data/background_topic_summary_adapter.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/automatic_context_settings_page.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/default_model_settings_page.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';

class Settings extends AppSettingsNotifier {
  @override
  Future<AppSettings> build() async => mapUiModelsToAppSettings({}).copyWith(
    providers: [
      for (final id in ['a', 'b'])
        ProviderAuth(
          id: id,
          apiBaseUrl: 'https://example.invalid',
          displayName: '渠道 $id',
          apiKeys: const [],
          models: const ['same'],
          visibleModels: const ['same'],
        ),
    ],
    defaultChatModels: ['a:same'],
    modelConfigs: {
      'a:same': const ModelConfig(maxContextTokens: 32000),
      'b:same': const ModelConfig(maxContextTokens: 128000),
    },
  );
  @override
  Future<void> setContextWindowTokens(int limit) async {
    state = AsyncData(state.requireValue.copyWith(contextWindowTokens: limit));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('summary config null clears while omitted values survive', () {
    const original = MemoryConfig(
      summarizeProviderId: 'b',
      summarizeModelName: 'same',
    );
    expect(original.copyWith().summarizeProviderId, 'b');
    final cleared = MemoryConfig.fromJson(
      original
          .copyWith(summarizeProviderId: null, summarizeModelName: null)
          .toJson(),
    );
    expect(cleared.summarizeProviderId, isNull);
    expect(cleared.summarizeModelName, isNull);
  });
  test(
    'manual and automatic summary resolve the configured channel and budget',
    () async {
      final container = ProviderContainer(
        overrides: [appSettingsProvider.overrideWith(Settings.new)],
      );
      addTearDown(container.dispose);
      await container.read(appSettingsProvider.future);
      final notifier = container.read(memoryPluginConfigProvider.notifier);
      await Future<void>.delayed(Duration.zero);
      await notifier.setSummarizeModel('b', 'same');
      for (final provider in [
        topicSummaryPortProvider,
        automaticSummaryPortProvider,
      ]) {
        final summary =
            await container.read(provider.future)
                as BackgroundTopicSummaryAdapter;
        expect(summary.modelRef, 'b:same');
        expect(summary.contextTokens, 128000);
      }
      await notifier.setSummarizeModel(null, null);
      final saved = jsonDecode(
        (await SharedPreferences.getInstance()).getString(
          'aicove.plugins.memory.config',
        )!,
      );
      expect(saved['summarizeModelName'], isNull);
      expect(
        (await container.read(automaticSummaryPortProvider.future)
                as BackgroundTopicSummaryAdapter)
            .modelRef,
        'a:same',
      );
    },
  );
  for (final width in [320.0, 760.0]) {
    testWidgets('automatic settings navigation and persistence at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final key = GlobalKey();
      const capture = bool.fromEnvironment('WRITE_COMPACTION_PREVIEW');
      if (capture) {
        await tester.runAsync(() async {
          final loader = FontLoader('Preview');
          loader.addFont(
            File(
              '/System/Library/Fonts/STHeiti Medium.ttc',
            ).readAsBytes().then(ByteData.sublistView),
          );
          await loader.load();
        });
      }
      await tester.pumpWidget(
        ProviderScope(
          overrides: [appSettingsProvider.overrideWith(Settings.new)],
          child: MaterialApp(
            theme: ThemeData(
              fontFamily: capture ? 'Preview' : null,
              extensions: [MoeColors.light()],
            ),
            builder: (context, child) =>
                RepaintBoundary(key: key, child: child),
            home: const DefaultModelSettingsPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('自动压缩'));
      await tester.tap(find.text('自动压缩'));
      await tester.pumpAndSettle();
      expect(find.byType(AutomaticContextSettingsPage), findsOneWidget);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(AutomaticContextSettingsPage)),
      );
      await tester.tap(find.text('点击选择模型'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('渠道 b'));
      await tester.pumpAndSettle(const Duration(milliseconds: 500));
      expect(
        container.read(memoryPluginConfigProvider).summarizeProviderId,
        'b',
      );
      await tester.enterText(find.byType(TextField).last, '64.125');
      await tester.pumpAndSettle(const Duration(milliseconds: 500));
      expect(
        container.read(appSettingsProvider).requireValue.contextWindowTokens,
        64125,
      );
      expect(tester.takeException(), isNull);
      if (capture) {
        await tester.runAsync(() async {
          final image =
              await (key.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('build/compaction-preview-${width.toInt()}.png');
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.tap(find.text('点击选择模型'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('跟随默认聊天模型'));
      await tester.pumpAndSettle(const Duration(milliseconds: 500));
      expect(
        container.read(memoryPluginConfigProvider).summarizeModelName,
        isNull,
      );
      await tester.enterText(find.byType(TextField).last, '0');
      await tester.pumpAndSettle(const Duration(milliseconds: 500));
      expect(find.textContaining('请输入大于'), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, '96');
      await tester.pump();
      final scope = tester.widget<MoeAutoSaveScope>(
        find.descendant(
          of: find.byType(AutomaticContextSettingsPage),
          matching: find.byType(MoeAutoSaveScope),
        ),
      );
      await scope.controller.flush();
      expect(
        container.read(appSettingsProvider).requireValue.contextWindowTokens,
        96000,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}

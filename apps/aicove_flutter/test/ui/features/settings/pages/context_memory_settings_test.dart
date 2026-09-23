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
import 'package:aicove_flutter/src/features/context/data/background_context_summarizer.dart';
import 'package:aicove_flutter/src/features/context/providers/context_providers.dart';
import 'package:aicove_flutter/src/features/memory/data/background_memory_agent_adapter.dart';
import 'package:aicove_flutter/src/features/memory/providers/memory_providers.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/context_memory_settings_page.dart';
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

  @override
  Future<void> setCompactionModel(String modelRef) async {
    state = AsyncData(state.requireValue.copyWith(compactionModel: modelRef));
  }

  @override
  Future<void> setMemoryModel(String modelRef) async {
    state = AsyncData(state.requireValue.copyWith(memoryModel: modelRef));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('压缩模型与记忆模型按设置解析渠道和预算，清空后依次回退', () async {
    final container = ProviderContainer(
      overrides: [appSettingsProvider.overrideWith(Settings.new)],
    );
    addTearDown(container.dispose);
    await container.read(appSettingsProvider.future);
    final notifier = container.read(appSettingsProvider.notifier);
    Future<BackgroundContextSummarizer> summarizer() async =>
        await container.read(contextSummarizerProvider.future)
            as BackgroundContextSummarizer;
    Future<BackgroundMemoryAgentAdapter> agent() async =>
        await container.read(memoryAgentProvider.future)
            as BackgroundMemoryAgentAdapter;
    expect((await summarizer()).modelRef, 'a:same');
    expect((await agent()).modelRef, 'a:same');
    await notifier.setCompactionModel('b:same');
    expect((await summarizer()).modelRef, 'b:same');
    expect((await summarizer()).contextTokens, 128000);
    // 记忆模型未设置时跟随压缩模型。
    expect((await agent()).modelRef, 'b:same');
    await notifier.setMemoryModel('a:same');
    expect((await agent()).modelRef, 'a:same');
    await notifier.setCompactionModel('');
    expect((await summarizer()).modelRef, 'a:same');
  });
  test('旧长期记忆插件里的总结模型在新设置为空时沿用', () async {
    SharedPreferences.setMockInitialValues({
      'aicove.plugins.memory.config':
          jsonEncode({'summarizeProviderId': 'b', 'summarizeModelName': 'same'}),
    });
    final container = ProviderContainer(
      overrides: [appSettingsProvider.overrideWith(Settings.new)],
    );
    addTearDown(container.dispose);
    final settings = await container.read(appSettingsProvider.future);
    expect(await resolveCompactionModel(settings), 'b:same');
    expect(
      await resolveCompactionModel(settings.copyWith(compactionModel: 'a:same')),
      'a:same',
    );
  });
  for (final width in [320.0, 760.0]) {
    testWidgets('上下文与记忆设置的导航和保存 $width', (
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
      await tester.ensureVisible(find.text('上下文与记忆'));
      await tester.tap(find.text('上下文与记忆'));
      await tester.pumpAndSettle();
      expect(find.byType(ContextMemorySettingsPage), findsOneWidget);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ContextMemorySettingsPage)),
      );
      await tester.tap(find.text('压缩模型'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('渠道 b'));
      await tester.pumpAndSettle(const Duration(milliseconds: 500));
      expect(
        container.read(appSettingsProvider).requireValue.compactionModel,
        'b:same',
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
          final file = File('build/context-memory-preview-${width.toInt()}.png');
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.tap(find.text('压缩模型'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('跟随默认聊天模型').last);
      await tester.pumpAndSettle(const Duration(milliseconds: 500));
      expect(
        container.read(appSettingsProvider).requireValue.compactionModel,
        '',
      );
      await tester.enterText(find.byType(TextField).last, '0');
      await tester.pumpAndSettle(const Duration(milliseconds: 500));
      expect(find.textContaining('请输入大于'), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, '96');
      await tester.pump();
      final scope = tester.widget<MoeAutoSaveScope>(
        find.descendant(
          of: find.byType(ContextMemorySettingsPage),
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

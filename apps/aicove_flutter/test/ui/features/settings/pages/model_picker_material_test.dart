import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:aicove_flutter/src/ui/features/settings/widgets/model_picker_sheet.dart';

class _Settings extends AppSettingsNotifier {
  @override
  Future<AppSettings> build() async => _testSettings;
  @override
  Future<List<String>> previewProviderModels({
    required String providerId,
    required String apiKey,
    required String apiBaseUrl,
    Map<String, dynamic>? customConfig,
  }) async => ['deepseek-flash', 'deepseek-v4-pro'];
}

const _testSettings = AppSettings(
  ttsEnabled: true,
  defaultModelName: 'alpha-chat',
  defaultPersonaPrompt: '',
  modelList: <String>['provider_a:alpha-chat', 'provider_b:beta-chat'],
  allKnownModels: <String>[
    'provider_a:alpha-chat',
    'provider_a:alpha-vision',
    'provider_b:beta-chat',
  ],
  modelDisplayNames: <String, String>{
    'provider_a:alpha-chat': 'Alpha Chat',
    'provider_a:alpha-vision': 'Alpha Vision',
    'provider_b:beta-chat': 'Beta Chat',
  },
  modelTypes: <String, String>{
    'provider_a:alpha-chat': 'chat',
    'provider_a:alpha-vision': 'vision',
    'provider_b:beta-chat': 'chat',
  },
  modelConfigs: <String, ModelConfig>{},
  apiKey: '',
  apiBaseUrl: 'https://api.openai.com/v1',
  imageGenerationEnabled: false,
  maxFileUploadMB: 10,
  contextWindowTokens: 272000,
  customModels: <CustomModel>[],
  providers: <ProviderAuth>[
    ProviderAuth(
      id: 'provider_a',
      displayName: 'Provider A',
      apiKeys: <String>['key-a'],
      apiBaseUrl: 'https://provider-a.example.com/v1',
      visibleModels: <String>['alpha-chat', 'alpha-vision'],
      models: <String>['alpha-chat', 'alpha-vision'],
      capabilities: <String>['chat', 'vision'],
    ),
    ProviderAuth(
      id: 'provider_b',
      displayName: 'Provider B',
      apiKeys: <String>['key-b'],
      apiBaseUrl: 'https://provider-b.example.com/v1',
      visibleModels: <String>['beta-chat'],
      models: <String>['beta-chat'],
      capabilities: <String>['chat'],
    ),
  ],
  modelProviderMap: <String, String>{
    'provider_a:alpha-chat': 'provider_a',
    'provider_a:alpha-vision': 'provider_a',
    'provider_b:beta-chat': 'provider_b',
  },
  backendApiKey: '',
  messageChunkingEnabled: true,
  messageFormatConfig: MessageFormatConfig(
    enableChunking: true,
    chunkPunctuations: <String>['。'],
    minSegmentLength: 1,
  ),
  textScaleFactor: 1.0,
  uiScaleFactor: 1.0,
  imagePreviewScale: 1.0,
  autoReplySettings: AutoReplySettings(),
  globalBackgroundColor: GlobalBackgroundColor.white,
  chatBackgroundColor: ChatBackgroundColor.defaultColor,
  isDarkMode: false,
  useSystemTheme: true,
  accentColor: 'FC96AA',
  hideUserAvatar: false,
  defaultChatModels: <String>['provider_a:alpha-chat'],
);

void main() {
  setUpAll(() async {
    if (!const bool.fromEnvironment('WRITE_MATERIAL_QA')) return;
    for (final entry in {
      'MaterialCapture': '/System/Library/Fonts/STHeiti Medium.ttc',
      'packages/cupertino_icons/CupertinoIcons':
          'build/unit_test_assets/packages/cupertino_icons/assets/CupertinoIcons.ttf',
      'MaterialIcons':
          '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    }.entries) {
      final loader = FontLoader(entry.key);
      loader.addFont(
        File(entry.value).readAsBytes().then(ByteData.sublistView),
      );
      await loader.load();
    }
  });
  for (final dark in [false, true]) {
    for (final width in [390.0, 1000.0]) {
      testWidgets(
        'model picker keeps layered material and compact bounds at minimum thickness dark=$dark width=$width',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(width, 780);
          addTearDown(tester.view.reset);
          final container = ProviderContainer(
            overrides: [appSettingsProvider.overrideWith(_Settings.new)],
          );
          addTearDown(container.dispose);
          await container.read(appSettingsProvider.future);
          final capture = GlobalKey();
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: MaterialApp(
                theme: ThemeData(
                  brightness: dark ? Brightness.dark : Brightness.light,
                  fontFamily: const bool.fromEnvironment('WRITE_MATERIAL_QA')
                      ? 'MaterialCapture'
                      : null,
                  extensions: [dark ? MoeColors.dark() : MoeColors.light()],
                ),
                builder: (context, child) => RepaintBoundary(
                  key: capture,
                  child: MoeGlassTheme(
                    enabled: true,
                    blurSigma: 0,
                    child: child!,
                  ),
                ),
                home: Scaffold(
                  body: Consumer(
                    builder: (context, ref, _) => Stack(
                      children: [
                        Positioned.fill(
                          child: ColoredBox(
                            color: dark ? Colors.white : Colors.black,
                            child: const Center(
                              child: Text('背景内容 DeepSeek 渠道详情'),
                            ),
                          ),
                        ),
                        Center(
                          child: TextButton(
                            onPressed: () => showModelPickerSheet(
                              context,
                              ref,
                              providerId: 'provider_a',
                            ),
                            child: const Text('打开选择器'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('打开选择器'));
          await tester.pumpAndSettle();
          expect(find.text('deepseek-flash'), findsOneWidget);
          final sheetSurface = find.byWidgetPredicate(
            (widget) =>
                widget is MoeFloatingSurface &&
                widget.baseline == MoeMaterialBaseline.background,
          );
          expect(sheetSurface, findsOneWidget);
          expect(
            find.descendant(
              of: find.byType(MoePrimaryButton),
              matching: find.byType(MoeButtonSurface),
            ),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: find.byType(MoeSearchField),
              matching: find.byType(MoeFloatingSurface),
            ),
            findsOneWidget,
          );
          final material = tester.widget<Material>(
            find
                .descendant(of: sheetSurface, matching: find.byType(Material))
                .first,
          );
          // A draggable sheet stays opaque under the shared motion guard.
          expect(material.color!.a, closeTo(1, 0.0001));
          expect(find.descendant(of: sheetSurface,
              matching: find.byType(BackdropFilter)), findsNothing);
          final sheetRect = tester.getRect(sheetSurface);
          expect(
            sheetRect.height,
            lessThan(480),
            reason: 'Two rows must not force a nearly full-screen sheet',
          );
          expect(
            tester.getCenter(find.text('选择模型')).dx,
            closeTo(sheetRect.center.dx, 1),
          );
          final action = tester.getRect(find.byType(MoePrimaryButton));
          expect(action.left - sheetRect.left, closeTo(20, 1));
          expect(sheetRect.right - action.right, closeTo(20, 1));

          expect(tester.takeException(), isNull);
          if (const bool.fromEnvironment('WRITE_MATERIAL_QA')) {
            await tester.runAsync(() async {
              final boundary =
                  capture.currentContext!.findRenderObject()
                      as RenderRepaintBoundary;
              final surface = tester.getRect(sheetSurface);
              final origin = boundary.globalToLocal(surface.topLeft);
              final image = await (boundary.debugLayer! as OffsetLayer).toImage(
                origin & surface.size,
                pixelRatio: 1.5,
              );
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final file = File(
                '../../.codex-temp/material-baseline/model-picker-${width.toInt()}-${dark ? 'dark' : 'light'}.png',
              );
              await file.parent.create(recursive: true);
              await file.writeAsBytes(bytes!.buffer.asUint8List());
              image.dispose();
            });
          }
          await tester.enterText(find.byType(TextField), 'flash');
          await tester.pumpAndSettle();
          expect(find.text('deepseek-v4-pro'), findsNothing);
          await tester.tap(find.text('deepseek-flash'));
          await tester.pumpAndSettle();
          expect(find.text('已选择 1 个模型'), findsOneWidget);
          tester.platformDispatcher.textScaleFactorTestValue = 1.8;
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          tester.view.physicalSize = Size(width, 520);
          tester.view.viewInsets = const FakeViewPadding(bottom: 220);
          await tester.pumpAndSettle();
          expect(
            tester.getRect(find.byType(MoePrimaryButton)).bottom,
            lessThanOrEqualTo(300),
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}

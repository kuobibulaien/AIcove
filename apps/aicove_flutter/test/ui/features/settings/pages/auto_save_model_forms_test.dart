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
import 'package:aicove_flutter/src/ui/features/settings/pages/provider_detail_page.dart';
import 'package:aicove_flutter/src/ui/features/settings/widgets/model_row_tile.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';

const _writeTypePreview = bool.fromEnvironment('WRITE_MODEL_TYPE_PREVIEW');
const _writeAnyPreview =
    bool.fromEnvironment('WRITE_MODEL_REMARK_PREVIEW') || _writeTypePreview;

void main() {
  setUpAll(() async {
    if (!_writeAnyPreview) return;
    for (final entry in {
      'Preview': '/System/Library/Fonts/STHeiti Medium.ttc',
      'monospace': '/System/Library/Fonts/STHeiti Medium.ttc',
      'packages/cupertino_icons/CupertinoIcons':
          'build/unit_test_assets/packages/cupertino_icons/assets/CupertinoIcons.ttf',
      'MaterialIcons':
          '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    }.entries) {
      final file = File(entry.value);
      if (!file.existsSync()) continue;
      final loader = FontLoader(entry.key);
      loader.addFont(file.readAsBytes().then(ByteData.sublistView));
      await loader.load();
    }
  });

  for (final width in [360.0, 1000.0]) {
    testWidgets(
        'model form saves while open and closing flushes the latest alias $width',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        'aicove.ui_models.v1': jsonEncode({
          'providers': [
            {
              'id': 'openai',
              'displayName': 'Test',
              'enabled': true,
              'apiKeys': <String>[],
              'apiBaseUrl': 'https://example.invalid/v1',
              'models': ['test-model'],
              'visible_models': ['test-model'],
              'capabilities': ['chat']
            }
          ],
        })
      });
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const ProviderScope(
          child: MaterialApp(
              home: Scaffold(
                  body: ModelRowTile(
                      providerId: 'openai',
                      model: 'test-model',
                      displayName: null)))));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'first alias');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(find.text('编辑模型'), findsOneWidget);
      final first = ProviderContainer();
      addTearDown(first.dispose);
      expect(
          (await first.read(appSettingsProvider.future))
              .getModelDisplayName('openai:test-model'),
          'first alias');
      await tester.enterText(find.byType(TextField).first, 'final alias');
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      final fresh = ProviderContainer();
      addTearDown(fresh.dispose);
      expect(
          (await fresh.read(appSettingsProvider.future))
              .getModelDisplayName('openai:test-model'),
          'final alias');
      expect(find.text('编辑模型'), findsNothing);

      // Reopening the edit dialog must prefill the saved remark name.
      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();
      final remarkField = tester.widget<TextField>(find.byType(TextField).first);
      expect(remarkField.controller?.text, 'final alias');
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  for (final width in [390.0, 1000.0]) {
    testWidgets('添加自定义模型时直接选图像生成，同渠道保留原有对话模型 $width', (tester) async {
      debugClearProviderDetailWarmCache();
      _seedProvider(
        models: const ['gpt-4o'],
        visibleModels: const ['gpt-4o'],
        capabilities: const ['chat'],
      );
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final boundaryKey = GlobalKey();

      await tester.pumpWidget(
        _buildPreviewApp(
          boundaryKey: boundaryKey,
          home: const ProviderDetailPage(providerId: 'paint'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('模型'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('自定义模型'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'third-party-draw');
      await tester.pumpAndSettle();
      final imageChip = find.byWidgetPredicate(
        (widget) =>
            widget is MoeChoiceChip && widget.label == ModelType.image.label,
      );
      expect(imageChip, findsOneWidget);
      await tester.tap(imageChip);
      await tester.pumpAndSettle();
      expect(tester.widget<MoeChoiceChip>(imageChip).selected, isTrue);

      if (_writeTypePreview && width == 390.0) {
        await _savePreview(
          tester,
          boundaryKey,
          '../../scratch/model-type-preview/add_custom_model_dialog.png',
        );
      }

      await tester.tap(find.text('添加').last);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();

      expect(find.text('third-party-draw'), findsOneWidget);
      expect(find.text('gpt-4o'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(ModelRowTile),
          matching: find.text(ModelType.image.label),
        ),
        findsOneWidget,
      );

      final fresh = ProviderContainer();
      addTearDown(fresh.dispose);
      final saved = await fresh.read(appSettingsProvider.future);
      expect(saved.getModelType('paint:third-party-draw'), ModelType.image);
      expect(saved.getModelType('paint:gpt-4o'), ModelType.chat);
      expect(saved.getProvider('paint')!.capabilities, containsAll(['chat', 'image']));
      expect(saved.modelList, contains('paint:gpt-4o'));
      expect(saved.modelList, isNot(contains('paint:third-party-draw')));
      expect(tester.takeException(), isNull);
    });
  }

  for (final width in [360.0, 1000.0]) {
    for (final model in ['my-paint-v1', 'gemini:2.5-flash-image']) {
      testWidgets('普通渠道添加 $model 后手动选择图像并关闭持久化 $width', (tester) async {
        debugClearProviderDetailWarmCache();
        _seedProvider();
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          const ProviderScope(
            child: MaterialApp(home: ProviderDetailPage(providerId: 'paint')),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('模型'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('自定义模型'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).first, model);
        await tester.tap(find.text('添加').last);
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 3));
        await tester.pumpAndSettle();
        expect(find.text(model), findsOneWidget);
        await tester.tap(find.byIcon(Icons.edit_outlined));
        await tester.pumpAndSettle();
        final imageChip = find.byWidgetPredicate(
          (widget) =>
              widget is MoeChoiceChip && widget.label == ModelType.image.label,
        );
        expect(imageChip, findsOneWidget);
        if (model == 'my-paint-v1') {
          expect(tester.widget<MoeChoiceChip>(imageChip).selected, isFalse);
        } else {
          final chatChip = find.byWidgetPredicate(
            (widget) =>
                widget is MoeChoiceChip && widget.label == ModelType.chat.label,
          );
          await tester.tap(chatChip);
          await tester.pumpAndSettle();
          expect(tester.widget<MoeChoiceChip>(imageChip).selected, isFalse);
        }
        await tester.tap(imageChip);
        await tester.pumpAndSettle();
        expect(tester.widget<MoeChoiceChip>(imageChip).selected, isTrue);
        await tester.tap(find.byTooltip('关闭'));
        await tester.pumpAndSettle();
        expect(find.text('编辑模型'), findsNothing);
        expect(find.descendant(
          of: find.byType(ModelRowTile),
          matching: find.text(ModelType.image.label),
        ), findsOneWidget);
        final fresh = ProviderContainer();
        addTearDown(fresh.dispose);
        final saved = await fresh.read(appSettingsProvider.future);
        expect(saved.getModelType('paint:$model'), ModelType.image);
        expect(saved.getProvider('paint')!.capabilities, ['image']);
        expect(saved.modelList, isNot(contains('paint:$model')));
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final width in [390.0, 1000.0]) {
    testWidgets('获取模型确认导入后，在模型详情页切换用途并共存对话与图像模型 $width', (tester) async {
      debugClearProviderDetailWarmCache();
      final requests = <String>[];
      late HttpServer server;
      await tester.runAsync(() async {
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          requests.add('${request.method} ${request.uri.path}');
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'data': [
                {'id': 'gpt-4o'},
                {'id': 'my-custom-paint'},
                {'id': 'Kwai-Kolors/Kolors'},
              ],
            }),
          );
          await request.response.close();
        });
      });
      addTearDown(() => server.close(force: true));
      _seedProvider(baseUrl: 'http://127.0.0.1:${server.port}/v1');
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final boundaryKey = GlobalKey();
      await HttpOverrides.runWithHttpOverrides(() async {
        await tester.pumpWidget(
          _buildPreviewApp(
            boundaryKey: boundaryKey,
            home: const ProviderDetailPage(providerId: 'paint'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('模型'));
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await tester.tap(find.text('获取'));
          await tester.pump();
          for (var i = 0; i < 100 && requests.isEmpty; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await tester.pumpAndSettle();
        expect(requests, ['GET /v1/models']);
        expect(find.text('gpt-4o'), findsOneWidget);
        expect(find.text('my-custom-paint'), findsOneWidget);
        expect(find.text('Kwai-Kolors/Kolors'), findsOneWidget);
        expect(find.textContaining('切换用途'), findsNothing);

        // 在干净的选择列表里勾选两个模型，不展示列表内切换用途标签
        await tester.tap(find.text('gpt-4o'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('my-custom-paint'));
        await tester.pumpAndSettle();
        expect(find.textContaining('切换用途'), findsNothing);

        await tester.tap(find.text('确认导入'));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 3));
        await tester.pumpAndSettle();

        expect(find.text('选择模型'), findsNothing);
        expect(find.text('gpt-4o'), findsOneWidget);
        expect(find.text('my-custom-paint'), findsOneWidget);

        // 点进单个模型详情页（编辑模型）切换用途为图像生成
        await tester.tap(find.text('my-custom-paint'));
        await tester.pumpAndSettle();
        expect(find.text('编辑模型'), findsOneWidget);

        final imageChip = find.byWidgetPredicate(
          (widget) =>
              widget is MoeChoiceChip && widget.label == ModelType.image.label,
        );
        expect(imageChip, findsOneWidget);
        await tester.tap(imageChip);
        await tester.pumpAndSettle();
        expect(tester.widget<MoeChoiceChip>(imageChip).selected, isTrue);

        if (_writeTypePreview && width == 390.0) {
          await _savePreview(
            tester,
            boundaryKey,
            '../../scratch/model-type-preview/model_edit_sheet_type.png',
          );
        }

        await tester.tap(find.byTooltip('关闭'));
        await tester.pumpAndSettle();
        expect(find.text('编辑模型'), findsNothing);

        // 再次获取并确认导入，已设定的图像用途不会被覆盖回对话
        await tester.tap(find.text('模型'));
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await tester.tap(find.text('获取'));
          await tester.pump();
          for (var i = 0; i < 100 && requests.length < 2; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await tester.pumpAndSettle();
        expect(requests, ['GET /v1/models', 'GET /v1/models']);
        await tester.tap(find.text('确认导入'));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 3));
        await tester.pumpAndSettle();

        final fresh = ProviderContainer();
        addTearDown(fresh.dispose);
        final saved = await fresh.read(appSettingsProvider.future);
        final provider = saved.getProvider('paint')!;
        expect(
          provider.models,
          containsAll(['gpt-4o', 'Kwai-Kolors/Kolors', 'my-custom-paint']),
        );
        expect(
          provider.visibleModels,
          unorderedEquals(['gpt-4o', 'my-custom-paint']),
        );
        expect(provider.capabilities, unorderedEquals(['chat', 'image']));
        expect(saved.getModelType('paint:gpt-4o'), ModelType.chat);
        expect(saved.getModelType('paint:my-custom-paint'), ModelType.image);
        expect(
          saved.getProviderVisibleModelsByType('paint', type: ModelType.image),
          ['my-custom-paint'],
        );
        expect(saved.modelList, contains('paint:gpt-4o'));
        expect(saved.modelList, isNot(contains('paint:my-custom-paint')));
        expect(tester.takeException(), isNull);
      }, _LocalModelHttpOverrides());
    });
  }

  testWidgets(
      'ProviderDetailPage displays saved model remark name and prefills edit dialog',
      (tester) async {
    debugClearProviderDetailWarmCache();
    SharedPreferences.setMockInitialValues({
      'aicove.ui_models.v1': jsonEncode({
        'providers': [
          {
            'id': 'openai',
            'displayName': 'OpenAI',
            'enabled': true,
            'apiKeys': <String>['sk-test'],
            'apiBaseUrl': 'https://example.invalid/v1',
            'models': ['gpt-4o'],
            'visible_models': ['gpt-4o'],
            'capabilities': ['chat']
          }
        ],
        'model_display_names': {
          'openai:gpt-4o': '主力写作模型',
        },
      })
    });
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final boundaryKey = GlobalKey();
    final theme = ThemeData(
      brightness: Brightness.light,
      fontFamily: const bool.fromEnvironment('WRITE_MODEL_REMARK_PREVIEW')
          ? 'Preview'
          : null,
      extensions: [MoeColors.light()],
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          builder: (context, child) =>
              RepaintBoundary(key: boundaryKey, child: child!),
          home: const ProviderDetailPage(providerId: 'openai'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Switch to the models tab on ProviderDetailPage.
    await tester.tap(find.text('模型'));
    await tester.pumpAndSettle();

    expect(find.text('主力写作模型'), findsOneWidget);
    expect(find.text('gpt-4o'), findsNothing);

    if (const bool.fromEnvironment('WRITE_MODEL_REMARK_PREVIEW')) {
      await tester.runAsync(() async {
        final boundary = boundaryKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
        final outFile = File('../../scratch/model-remark-preview/model_list.png');
        await outFile.parent.create(recursive: true);
        await outFile.writeAsBytes(byteData!.buffer.asUint8List());
        image.dispose();
      });
    }

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();

    final remarkField = tester.widget<TextField>(find.byType(TextField).first);
    expect(remarkField.controller?.text, '主力写作模型');

    if (const bool.fromEnvironment('WRITE_MODEL_REMARK_PREVIEW')) {
      await tester.runAsync(() async {
        final boundary = boundaryKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
        final outFile = File('../../scratch/model-remark-preview/edit_sheet.png');
        await outFile.parent.create(recursive: true);
        await outFile.writeAsBytes(byteData!.buffer.asUint8List());
        image.dispose();
      });
    }
  });
}

Widget _buildPreviewApp({
  required GlobalKey boundaryKey,
  required Widget home,
}) {
  return ProviderScope(
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.light,
        fontFamily: _writeAnyPreview ? 'Preview' : null,
        extensions: [MoeColors.light()],
      ),
      builder: (context, child) =>
          RepaintBoundary(key: boundaryKey, child: child!),
      home: home,
    ),
  );
}

Future<void> _savePreview(
  WidgetTester tester,
  GlobalKey boundaryKey,
  String path,
) async {
  await tester.runAsync(() async {
    final boundary =
        boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    try {
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      final outFile = File(path);
      await outFile.parent.create(recursive: true);
      await outFile.writeAsBytes(byteData!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

void _seedProvider({
  String baseUrl = 'https://example.invalid/v1',
  List<String> models = const <String>[],
  List<String> visibleModels = const <String>[],
  List<String> capabilities = const <String>['chat'],
}) {
  SharedPreferences.setMockInitialValues({
    'aicove.ui_models.v1': jsonEncode({
      'providers': [
        {
          'id': 'paint',
          'displayName': '综合中转站',
          'enabled': true,
          'apiKeys': ['test-key'],
          'apiBaseUrl': baseUrl,
          'models': models,
          'visible_models': visibleModels,
          'capabilities': capabilities,
          'custom_config': {'requestFormat': 'openai'},
        },
      ],
    }),
  });
}

class _LocalModelHttpOverrides extends HttpOverrides {}

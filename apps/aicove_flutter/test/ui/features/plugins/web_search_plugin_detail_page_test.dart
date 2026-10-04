import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/features/plugins/plugin_providers.dart';
import 'package:aicove_flutter/src/features/plugins/web_search/web_search_config.dart';
import 'package:aicove_flutter/src/ui/features/plugins/pages/web_search_plugin_detail_page.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemoryConfigNotifier extends WebSearchPluginConfigNotifier {
  _MemoryConfigNotifier(WebSearchConfig config) {
    state = config;
  }

  @override
  Future<void> updateConfig(WebSearchConfig config) async => state = config;
}

const _configured = WebSearchConfig(
  replaceModelBuiltinSearch: true,
  providers: [
    WebSearchProviderEntry(
      id: 'a',
      type: WebSearchProviderType.tavily,
      apiKey: 'tvly-1234567890abcd',
    ),
    WebSearchProviderEntry(
      id: 'b',
      type: WebSearchProviderType.bocha,
      name: '博查（备用）',
      apiKey: 'sk-1234567890',
    ),
    WebSearchProviderEntry(id: 'c', type: WebSearchProviderType.exa),
    WebSearchProviderEntry(
      id: 'd',
      type: WebSearchProviderType.zhipu,
      apiKey: 'k',
      enabled: false,
    ),
  ],
);

void main() {
  const capture = bool.fromEnvironment('WRITE_WEB_SEARCH_PREVIEW');

  setUpAll(() async {
    if (!capture) return;
    final font = FontLoader('WebSearchPreview')
      ..addFont(
        File(
          '/System/Library/Fonts/STHeiti Medium.ttc',
        ).readAsBytes().then(ByteData.sublistView),
      );
    await font.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(
        File(
          '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        ).readAsBytes().then(ByteData.sublistView),
      );
    await icons.load();
  });

  Future<(ProviderContainer, GlobalKey)> pump(
    WidgetTester tester, {
    required double width,
    required WebSearchConfig config,
  }) async {
    SharedPreferences.setMockInitialValues({});
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 860);
    final boundaryKey = GlobalKey();
    final container = ProviderContainer(
      overrides: [
        webSearchPluginConfigProvider.overrideWith(
          (ref) => _MemoryConfigNotifier(config),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFFFC96AA),
              primary: const Color(0xFFFC96AA),
            ),
            scaffoldBackgroundColor: moeSurface,
            fontFamily: capture ? 'WebSearchPreview' : null,
            extensions: [MoeColors.light()],
          ),
          builder: (context, child) =>
              RepaintBoundary(key: boundaryKey, child: child!),
          home: const WebSearchPluginDetailPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (container, boundaryKey);
  }

  Future<void> shot(WidgetTester tester, GlobalKey key, String name) async {
    if (!capture) return;
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1.5);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('../../.codex-temp/web-search-preview/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  for (final width in [360.0, 1000.0]) {
    testWidgets('供应商列表状态与顶部开关 width=$width', (tester) async {
      final (container, key) = await pump(
        tester,
        width: width,
        config: _configured,
      );

      expect(tester.takeException(), isNull);
      expect(find.text('关闭模型内置搜索，改用此工具'), findsOneWidget);
      expect(find.text('优先使用'), findsOneWidget);
      expect(find.text('备用'), findsOneWidget);
      expect(find.text('未填写密钥'), findsOneWidget);
      expect(find.text('已停用'), findsOneWidget);
      await shot(tester, key, 'w${width.toInt()}-list');

      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('web-search-replace-builtin')),
          matching: find.byType(Switch),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        container.read(webSearchPluginConfigProvider).replaceModelBuiltinSearch,
        isFalse,
      );
    });
  }

  testWidgets('添加供应商后进入详情，可填写密钥与删除', (tester) async {
    final (container, key) = await pump(
      tester,
      width: 360,
      config: const WebSearchConfig(),
    );

    await tester.tap(find.byKey(const ValueKey('web-search-add-provider')));
    await tester.pumpAndSettle();
    await shot(tester, key, 'w360-add-sheet');
    await tester.tap(find.byKey(const ValueKey('web-search-type-serper')));
    await tester.pumpAndSettle();

    final added = container.read(webSearchPluginConfigProvider).providers;
    expect(added.single.type, WebSearchProviderType.serper);
    expect(find.text('Serper（Google）'), findsWidgets);
    expect(find.text('在 serper.dev 创建'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('web-search-provider-key')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).last, 'serper-key-0001');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(
      container.read(webSearchPluginConfigProvider).providers.single.apiKey,
      'serper-key-0001',
    );
    if (find.byType(BottomSheet).evaluate().isNotEmpty) {
      Navigator.of(tester.element(find.byType(BottomSheet))).pop();
      await tester.pumpAndSettle();
    }
    await shot(tester, key, 'w360-provider-detail');

    await tester.tap(find.byKey(const ValueKey('web-search-provider-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除').last);
    await tester.pumpAndSettle();
    expect(container.read(webSearchPluginConfigProvider).providers, isEmpty);
    expect(find.text('添加供应商'), findsOneWidget);
  });
}

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aicove_flutter/src/features/agent_context/domain/tavern_compatibility_port.dart';
import 'package:aicove_flutter/src/features/agent_context/providers/preset_recipe_provider.dart';
import 'package:aicove_flutter/src/features/plugins/mcp/mcp_connector.dart';
import 'package:aicove_flutter/src/features/plugins/mcp/mcp_connector_providers.dart';
import 'package:aicove_flutter/src/ui/features/character/widgets/character_plugins_section.dart';
import 'package:aicove_flutter/src/ui/features/plugins/pages/mcp_connector_detail_page.dart';
import 'package:aicove_flutter/src/ui/features/plugins/pages/mcp_connectors_page.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:aicove_flutter/src/ui/theme/skin_provider.dart';
import 'package:aicove_flutter/src/ui/theme/skins/moetalk_skin.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';

const _capture = bool.fromEnvironment('WRITE_MCP_PREVIEW');

final _weather = McpConnector(
  id: 'abc123',
  name: '天气',
  url: 'https://weather.example.com/mcp',
  bearerToken: 'sk-preview-token-123456',
  serverName: '天气服务',
  tools: const [
    McpToolInfo(name: 'get_weather', title: '查询天气', description: '按城市查询实时天气'),
    McpToolInfo(name: 'get_forecast', title: '天气预报', description: '未来三天预报'),
  ],
  disabledTools: const {'get_forecast'},
  toolsFetchedAt: DateTime(2026, 10, 10, 20, 15),
);

const _memory = McpConnector(
  id: 'def456',
  name: '外部记忆库',
  url: 'https://memory.example.com/mcp',
);

void _seed() {
  SharedPreferences.setMockInitialValues({
    McpConnectorsConfigNotifier.storageKey: jsonEncode(
      McpConnectorsConfig(connectors: [_weather, _memory]).toJson(),
    ),
  });
}

Future<void> _mount(
  WidgetTester tester,
  Widget home, {
  required double width,
  double height = 900,
  GlobalKey? boundary,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        presetRecipeListProvider.overrideWith((ref) async => const []),
        tavernPluginSettingsProvider.overrideWith(
          (ref) async => const TavernPluginSettings(enabled: true),
        ),
      ],
      child: SkinScope(
        skin: const MoeTalkSkin(),
        child: MaterialApp(
          theme: ThemeData(
            fontFamily: _capture ? 'Preview' : null,
            extensions: [MoeColors.light()],
          ),
          home: RepaintBoundary(key: boundary, child: home),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _SectionHost extends StatefulWidget {
  const _SectionHost();

  @override
  State<_SectionHost> createState() => _SectionHostState();
}

class _SectionHostState extends State<_SectionHost> {
  Set<String> ids = {'web_search', 'mcp:abc123'};

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: CharacterPluginsSection(
        selectedPluginIds: ids,
        boundVoiceId: null,
        voicePresets: const [],
        drawingPersonaPrompt: '',
        selectedRecipeId: null,
        memoryDocAvailable: false,
        onOpenMemoryDoc: null,
        onPluginIdsChanged: (next) => setState(() => ids = next),
        onVoiceChanged: (_) {},
        onDrawingPresetChanged: (_) {},
        onRecipeChanged: (_) {},
      ),
    ),
  );
}

void main() {
  setUp(_seed);

  for (final width in [360.0, 1040.0]) {
    testWidgets('连接器列表显示状态，无溢出（$width）', (tester) async {
      await _mount(tester, const McpConnectorsPage(), width: width);
      expect(find.text('天气'), findsOneWidget);
      expect(find.text('1 个工具'), findsOneWidget);
      expect(find.text('外部记忆库'), findsOneWidget);
      expect(find.text('尚未连接'), findsOneWidget);
      expect(find.text('添加连接器'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('详情页：令牌打码、工具开关写回配置', (tester) async {
    await _mount(
      tester,
      const McpConnectorDetailPage(connectorId: 'abc123'),
      width: 360,
      height: 1400,
    );
    expect(find.text('sk-p…3456'), findsOneWidget);
    expect(find.text('工具（1/2 已开启）'), findsOneWidget);
    expect(find.text('刷新工具列表'), findsOneWidget);

    final forecast = find.byKey(const ValueKey('mcp-tool-get_forecast'));
    await tester.ensureVisible(forecast);
    await tester.tap(forecast);
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(McpConnectorDetailPage)),
    );
    expect(
      container.read(mcpConnectorsConfigProvider).byId('abc123')!.disabledTools,
      isEmpty,
    );
    expect(find.text('工具（2/2 已开启）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('角色插件：每个连接器单独开关，开启后出现在已开启列表', (tester) async {
    await _mount(tester, const _SectionHost(), width: 360);
    expect(
      find.byKey(const ValueKey('enabled-plugin-mcp:abc123')),
      findsOneWidget,
    );
    expect(find.text('1 个工具'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('enabled-plugin-mcp:def456')),
      findsNothing,
    );

    await tester.ensureVisible(find.text('管理开启的插件'));
    await tester.tap(find.text('管理开启的插件'));
    await tester.pumpAndSettle();
    final memoryRow = find.byKey(const ValueKey('all-plugins-mcp:def456'));
    await tester.ensureVisible(memoryRow);
    await tester.tap(memoryRow);
    await tester.pumpAndSettle();

    final host = tester.state<_SectionHostState>(find.byType(_SectionHost));
    expect(host.ids, contains('mcp:def456'));
    expect(find.text('尚未连接'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('源码渲染预览', () {
    Future<void> loadFonts(WidgetTester tester) => tester.runAsync(() async {
      final text = FontLoader('Preview')
        ..addFont(
          File(
            '/System/Library/Fonts/STHeiti Medium.ttc',
          ).readAsBytes().then(ByteData.sublistView),
        );
      await text.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(
          File(
            '${Platform.environment['HOME']}/dev-sdks/flutter-3.44.6/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ).readAsBytes().then(ByteData.sublistView),
        );
      await icons.load();
    });

    Future<void> save(WidgetTester tester, GlobalKey key, String name) =>
        tester.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final dir = Directory('../../.codex-temp/mcp-connectors/previews')
            ..createSync(recursive: true);
          await File(
            '${dir.path}/$name.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });

    testWidgets('列表、详情与角色开关', (tester) async {
      if (!_capture) return;
      await loadFonts(tester);
      final key = GlobalKey();

      await _mount(
        tester,
        const McpConnectorsPage(),
        width: 360,
        boundary: key,
      );
      await save(tester, key, 'list-360');

      await _mount(
        tester,
        const McpConnectorDetailPage(connectorId: 'abc123'),
        width: 360,
        height: 1100,
        boundary: key,
      );
      await save(tester, key, 'detail-360');

      await _mount(tester, const _SectionHost(), width: 360, boundary: key);
      await tester.tap(find.text('管理开启的插件'));
      await tester.pumpAndSettle();
      await save(tester, key, 'character-360');
      expect(tester.takeException(), isNull);
    });
  });
}

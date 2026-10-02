import 'dart:io';

import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/persona_prompt_codec.dart';
import 'package:aicove_flutter/src/features/plugins/image/drawing_preset.dart';
import 'package:aicove_flutter/src/features/plugins/image/drawing_preset_provider.dart';
import 'package:aicove_flutter/src/features/plugins/image/image_config.dart';
import 'package:aicove_flutter/src/ui/features/chat/pages/chat_page.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_adaptive_shell.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../../../../../tool/chat_segmented_fixture.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.rootPath);

  final String rootPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => rootPath;
}

const _altPreset = DrawingPreset(
    id: 'alt',
    name: '备用绘图包',
    config: ImageConfig(selectedModelId: 'nai:nai-diffusion-5-full'));

Future<SegmentedChatFixture> _mount(WidgetTester tester,
    {List<String>? enabledPlugins}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.reset);
  final fixture = (await tester
      .runAsync(() => SegmentedChatFixture.create(
          historyCount: 4, enabledPlugins: enabledPlugins)))!;
  await tester.runAsync(() async {
    // ContactEditSnapshotStore 走 path_provider；写入测试临时目录。
    final dir = await Directory.systemTemp
        .createTemp('chat_drawing_preset_switch_test');
    final previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProviderPlatform(dir.path);
    addTearDown(() {
      PathProviderPlatform.instance = previous;
    });
    final notifier = fixture.container.read(drawingPresetCatalogProvider.notifier);
    await fixture.container.read(drawingPresetCatalogProvider.future);
    await notifier.savePreset(_altPreset);
  });
  await tester.pumpWidget(UncontrolledProviderScope(
    container: fixture.container,
    child: MaterialApp(
      theme: ThemeData(extensions: [MoeColors.light()]),
      home: MoeWorkspace(
        navigatorKey: GlobalKey<NavigatorState>(),
        isWide: false,
        isDetail: true,
        child: ChatPage(
          conversationId: fixture.conversation.id,
          initialConversation: fixture.conversation,
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return fixture;
}

/// 夹具释放含真实异步（关闭内存数据库），需要在假时钟里泵帧推进。
Future<void> _disposeFixture(
    WidgetTester tester, SegmentedChatFixture fixture) async {
  await tester.pumpWidget(const SizedBox.shrink());
  var disposed = false;
  final cleanup = fixture.dispose().then((_) => disposed = true);
  for (var attempt = 0; attempt < 100 && !disposed; attempt++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)));
  }
  expect(disposed, isTrue);
  await cleanup;
}

String _boundPresetId(SegmentedChatFixture fixture) {
  final conversation =
      fixture.container.read(conversationsProvider).requireValue.first;
  return PersonaPromptCodec.parse(conversation.personaPrompt)
          .drawingPresetId ??
      '';
}

Future<void> _openPresetPicker(WidgetTester tester) async {
  await tester.tap(find.byTooltip('更多'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('绘图风格'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('聊天菜单可快速切换绘图配置包并写回角色绑定', (tester) async {
    final fixture = await _mount(tester);

    await _openPresetPicker(tester);
    expect(find.text('选择绘图配置包'), findsOneWidget);
    expect(find.text('跟随默认绘图配置包'), findsOneWidget);

    await tester.tap(find.text('备用绘图包'));
    await tester.pumpAndSettle();
    expect(_boundPresetId(fixture), 'alt');

    await _openPresetPicker(tester);
    await tester.tap(find.text('跟随默认绘图配置包'));
    await tester.pumpAndSettle();
    expect(_boundPresetId(fixture), '');
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
    await _disposeFixture(tester, fixture);
  });

  testWidgets('聊天菜单「酒馆预设」打开本角色的预设页', (tester) async {
    final fixture = await _mount(tester);
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('酒馆预设'));
    await tester.pumpAndSettle();
    expect(find.text('当前预设'), findsOneWidget);
    expect(find.text('跟随默认酒馆预设'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _disposeFixture(tester, fixture);
  });

  testWidgets('角色禁用绘图插件时菜单不显示快捷入口', (tester) async {
    final fixture = await _mount(tester, enabledPlugins: const []);
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    expect(find.text('绘图风格'), findsNothing);
    expect(tester.takeException(), isNull);
    await _disposeFixture(tester, fixture);
  });
}

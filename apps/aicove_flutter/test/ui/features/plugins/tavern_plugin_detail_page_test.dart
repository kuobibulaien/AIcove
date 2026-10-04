import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/features/agent_context/data/silly_tavern_preset_store.dart';
import 'package:aicove_flutter/src/features/agent_context/providers/preset_recipe_provider.dart';
import 'package:aicove_flutter/src/ui/features/plugins/pages/tavern_plugin_detail_page.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/chat_plugin_settings_page.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';

class _Picker extends FilePicker {
  String source = '';
  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async => FilePickerResult([
    PlatformFile(
      name: 'test.json',
      size: utf8.encode(source).length,
      bytes: Uint8List.fromList(utf8.encode(source)),
    ),
  ]);
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 24; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pumpAndSettle();
}

Future<void> tapTab(WidgetTester tester, String label) async {
  final finder = find.descendant(
    of: find.byWidgetPredicate((w) => w is MoeToggleBar),
    matching: find.text(label),
  );
  await tester.ensureVisible(finder);
  await tester.tap(finder);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FilePicker.platform = _Picker();
  test('插件列表与绘图音色同级，不冒充角色工具权限', () {
    final tavern = chatPluginItems.singleWhere(
      (p) => p.id == 'tavern_compatibility',
    );
    expect(tavern.name, '酒馆相关');
    expect(chatPluginItems.last.id, tavern.id);
    expect(
      chatPluginItems.map((p) => p.id),
      containsAll(['image', 'tts', tavern.id]),
    );
    expect(tavern.conversationSelectable, isFalse);
  });

  testWidgets('损坏的总配置可以重置恢复，不删除已导入预设', (tester) async {
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('tavern_repair_'),
    ))!;
    addTearDown(() => directory.delete(recursive: true));
    final store = SillyTavernPresetStore(
      documentsDirectoryResolver: () async => directory,
    );
    await tester.runAsync(() async {
      final path = Directory('${directory.path}/aicove/sillytavern_presets');
      await path.create(recursive: true);
      await store.importSource(
        '{"prompts":[{"identifier":"chatHistory","marker":true}],"prompt_order":[{"identifier":"chatHistory","enabled":true}]}',
        sourceFileName: '保留.json',
      );
      await File('${path.path}/plugin_settings.json').writeAsString('{bad');
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sillyTavernPresetStoreProvider.overrideWithValue(store)],
        child: MaterialApp(
          theme: ThemeData(extensions: [MoeColors.light()]),
          home: const TavernPluginDetailPage(),
        ),
      ),
    );
    await settle(tester);
    await tester.ensureVisible(find.text('重置默认选择'));
    await tester.tap(find.text('重置默认选择'));
    await settle(tester);
    await tester.tap(find.text('确认重置'));
    await settle(tester);
    // 全局开关已移除：重置后读取恒为启用
    expect((await tester.runAsync(store.loadPluginSettings))!.enabled, isTrue);
    expect((await tester.runAsync(store.list))!.single.name, '保留');
    expect(tester.takeException(), isNull);
  });

  for (final (width, scale) in [(360.0, 1.0), (1000.0, 1.0), (320.0, 1.8)]) {
    testWidgets('真实入口导入三类资源、开关保存、重开恢复 $width/$scale', (tester) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final temp = await tester.runAsync(
        () => Directory.systemTemp.createTemp('tavern_ui_'),
      );
      final store = SillyTavernPresetStore(
        documentsDirectoryResolver: () async => temp!,
      );
      addTearDown(() => temp!.delete(recursive: true));
      final picker = _Picker();
      FilePicker.platform = picker;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [sillyTavernPresetStoreProvider.overrideWithValue(store)],
          child: MaterialApp(
            theme: ThemeData(extensions: [MoeColors.light()]),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: const TavernPluginDetailPage(),
          ),
        ),
      );
      await settle(tester);
      expect(find.text('酒馆相关'), findsOneWidget);
      picker.source = '''{"name":"界面测试预设","prompts":[
        {"identifier":"main","content":"规则","role":"system"},
        {"identifier":"chatHistory","marker":true}],"prompt_order":[
        {"identifier":"main","enabled":true},{"identifier":"chatHistory","enabled":true}]}''';
      await tester.tap(find.text('导入预设'));
      await settle(tester);
      await tester.tap(find.text('导入').last);
      await settle(tester);
      expect(
        find.text('界面测试预设'),
        findsWidgets,
        reason: tester
            .widgetList<Text>(find.byType(Text))
            .map((t) => t.data)
            .join('\n'),
      );
      expect(find.byKey(const ValueKey('prompt-main')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('prompt-main')));
      await settle(tester);
      var preset = (await tester.runAsync(store.list))!.single;
      expect(preset.enabledPrompts.any((p) => p.identifier == 'main'), isFalse);

      await tapTab(tester, '正则');
      await settle(tester);
      picker.source =
          '{"id":"r","scriptName":"用户替换","findRegex":"猫","replaceString":"狗","placement":[1],"promptOnly":true}';
      await tester.tap(find.text('导入正则'));
      await settle(tester);
      expect(find.text('用户替换'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('regex-authorization')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('regex-r')));
      await settle(tester);

      await tapTab(tester, '世界书');
      await settle(tester);
      picker.source =
          '{"name":"测试世界","entries":{"0":{"uid":0,"constant":true,"comment":"背景条目","content":"世界正文","position":4,"depth":0}}}';
      await tester.tap(find.text('导入世界书'));
      await settle(tester);
      preset = (await tester.runAsync(store.list))!.single;
      final book = preset.worldBooks.single;
      await tester.tap(find.text('测试世界'));
      await settle(tester);
      expect(find.text('背景条目'), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('world-${book.id}-0')));
      await settle(tester);
      final reopened = SillyTavernPresetStore(
        documentsDirectoryResolver: () async => temp!,
      );
      final saved = (await tester.runAsync(() => reopened.get(preset.id)))!;
      expect(saved.regexAuthorized, isTrue);
      expect(saved.regexScripts.single.disabled, isTrue);
      expect(saved.worldBooks.single.entries.single.enabled, isFalse);
      expect(saved.enabledPrompts.any((p) => p.identifier == 'main'), isFalse);
      expect(tester.takeException(), isNull);
      await tester.pageBack();
      await settle(tester);
      await tester.pageBack();
      await settle(tester);
      await tester.ensureVisible(find.byTooltip('更多操作'));
      await tester.tap(find.byTooltip('更多操作'));
      await settle(tester);
      await tester.tap(find.text('设为默认'));
      await settle(tester);
      expect(find.text('默认'), findsOneWidget);
      expect(
        (await tester.runAsync(reopened.loadPluginSettings))!.defaultPresetId,
        preset.id,
      );
      expect(tester.takeException(), isNull);
    });
  }
}

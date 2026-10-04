import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/features/agent_context/data/silly_tavern_preset_store.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/tavern_compatibility_port.dart';
import 'package:aicove_flutter/src/features/agent_context/providers/preset_recipe_provider.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/persona_prompt_codec.dart';
import 'package:aicove_flutter/src/features/plugins/image/drawing_preset.dart';
import 'package:aicove_flutter/src/features/plugins/image/image_config.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_config.dart';
import 'package:aicove_flutter/src/ui/features/character/pages/contact_edit_page.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const capture = bool.fromEnvironment('WRITE_EDIT_PREVIEW');
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');

  setUpAll(() async {
    final tempDir = await Directory.systemTemp.createTemp('edit_preview_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, (call) async {
          if (call.method == 'getApplicationDocumentsDirectory' ||
              call.method == 'getTemporaryDirectory') {
            return tempDir.path;
          }
          return null;
        });
  });

  setUpAll(() async {
    if (!capture) return;
    final font = FontLoader('EditPreview')
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

  testWidgets('contact edit page preview', (tester) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 900);

    final portrait = _pngDataUri(
      240,
      320,
      const (248, 176, 190),
      const (255, 226, 232),
    );
    final wallpaper = _pngDataUri(
      480,
      640,
      const (214, 196, 240),
      const (146, 180, 226),
    );

    final drawingCatalog = DrawingPresetCatalog(
      presets: const [
        DrawingPreset(
          id: 'drawing_default',
          name: '默认绘图',
          config: ImageConfig(),
        ),
        DrawingPreset(id: 'preset_anime', name: '二次元立绘', config: ImageConfig()),
      ],
      defaultPresetId: 'drawing_default',
      legacyConfig: const ImageConfig(),
    );
    final ttsConfig = TtsConfig(
      enabled: true,
      voicePresets: [
        VoicePreset.defaultPreset,
        VoicePreset(id: 'preset_yelu', name: '夜露·清亮'),
      ],
      defaultVoicePresetId: 'built_in_nahida',
    );

    SharedPreferences.setMockInitialValues({
      'aicove.ui_models.v1': jsonEncode({
        'auto_reply_settings': {'enabled': true},
      }),
      'aicove.plugins.image.drawing_presets.v1': jsonEncode(
        drawingCatalog.toJson(),
      ),
      'aicove.plugins.tts.config': jsonEncode(ttsConfig.toJson()),
    });

    final conversation = Conversation(
      id: 'preview_conv',
      title: '纳西妲',
      displayName: '纳西妲',
      avatarUrl: portrait,
      characterImage: portrait,
      chatBackgroundImage: wallpaper,
      voiceFile: 'built_in_nahida',
      description: '须弥的小吉祥草王',
      personaPrompt: PersonaPromptCodec.compose(
        userPrompt: '你是须弥的小吉祥草王纳西妲，温柔聪慧，喜欢用比喻解释事物。',
        customDrawingPrompt: 'nahida_(genshin_impact)，白色长发侧马尾，绿瞳',
        drawingPresetId: 'preset_anime',
      ),
      enabledPlugins: const ['tts', 'image', 'memory', 'sticker', 'trigger'],
      recipeId: 'recipe_story',
      createdAt: DateTime(2026, 9, 1),
      updatedAt: DateTime(2026, 9, 15),
    );

    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          presetRecipeListProvider.overrideWith(
            (ref) async => const [
              PresetRecipeSummary(
                id: 'recipe_story',
                name: '通用剧情 v2',
                description: '12 个启用节点 · 顺序组 1',
              ),
            ],
          ),
          tavernPluginSettingsProvider.overrideWith(
            (ref) async => const TavernPluginSettings(
              enabled: true,
              defaultPresetId: 'recipe_story',
            ),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFFFC96AA),
              primary: const Color(0xFFFC96AA),
            ),
            scaffoldBackgroundColor: moeSurface,
            fontFamily: capture ? 'EditPreview' : null,
            extensions: [MoeColors.light()],
          ),
          builder: (context, child) =>
              RepaintBoundary(key: boundaryKey, child: child!),
          home: ContactEditPage(
            conversation: conversation,
            editMode: EditMode.editConversation,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 越过延迟挂载窗口，呈现完整表单与壁纸背景。
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    // Image.memory/解码走真实异步，pumpAndSettle 不会等待——截图前留出真实时间。
    await tester.runAsync(
      () => Future.delayed(const Duration(milliseconds: 400)),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('已开启插件'), findsOneWidget);
    expect(find.text('壁纸'), findsNothing);
    expect(find.text('角色卡信息'), findsOneWidget);

    if (capture) {
      await _capture(tester, boundaryKey, 'contact-edit');
    }

    await tester.ensureVisible(find.text('角色卡信息'));
    await tester.pumpAndSettle();
    if (capture) {
      await _capture(tester, boundaryKey, 'contact-edit-scrolled');
    }

    await tester.tap(find.text('角色卡信息'));
    await tester.pumpAndSettle();
    expect(find.text('人设提示词'), findsOneWidget);
    expect(find.text('绘图提示'), findsOneWidget);
    if (capture) {
      await _capture(tester, boundaryKey, 'contact-edit-expanded');
    }

    await tester.ensureVisible(find.text('管理开启的插件'));
    await tester.tap(find.text('管理开启的插件'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('all-plugins-tts')), findsOneWidget);
    if (capture) {
      await _capture(tester, boundaryKey, 'contact-edit-all-plugins');
    }

    // 宽屏预览
    tester.view.physicalSize = const Size(1000, 900);
    await tester.pumpAndSettle();
    if (capture) {
      await _capture(tester, boundaryKey, 'contact-edit-wide');
    }

    // BlurredBackgroundService.ensureBlur 内部有 3s 超时定时器，结束前排空。
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });

  testWidgets('create page imports tavern card and binds new preset', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 900);
    SharedPreferences.setMockInitialValues({});
    final temp = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('create_preset_'),
    ))!;
    addTearDown(() => temp.delete(recursive: true));
    final store = SillyTavernPresetStore(
      documentsDirectoryResolver: () async => temp,
    );
    final picker = _JsonPicker(
      '{"name":"新角色专用预设","prompts":[{"identifier":"main","content":"规则","role":"system"},'
      '{"identifier":"chatHistory","marker":true}],"prompt_order":['
      '{"identifier":"main","enabled":true},{"identifier":"chatHistory","enabled":true}]}',
    );
    FilePicker.platform = picker;

    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sillyTavernPresetStoreProvider.overrideWithValue(store),
          tavernPluginSettingsProvider.overrideWith(
            (ref) async => const TavernPluginSettings(enabled: false),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFFFC96AA),
              primary: const Color(0xFFFC96AA),
            ),
            scaffoldBackgroundColor: moeSurface,
            fontFamily: capture ? 'EditPreview' : null,
            extensions: [MoeColors.light()],
          ),
          builder: (context, child) =>
              RepaintBoundary(key: boundaryKey, child: child!),
          home: ContactEditPage(
            conversation: Conversation(
              id: 'new_conv',
              title: '',
              displayName: '',
              personaPrompt: '',
              createdAt: DateTime(2026, 10, 3),
              updatedAt: DateTime(2026, 10, 3),
            ),
            editMode: EditMode.create,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final importButton = find.text('导入酒馆角色卡');
    expect(importButton, findsOneWidget);
    await tester.ensureVisible(importButton);
    await tester.pumpAndSettle();
    if (capture) {
      await _capture(tester, boundaryKey, 'contact-create-import');
    }

    await tester.tap(importButton);
    await tester.pumpAndSettle();
    expect(find.text('从图片导入'), findsOneWidget);
    expect(find.text('从链接导入'), findsOneWidget);
    if (capture) {
      await _capture(tester, boundaryKey, 'contact-create-import-sheet');
    }
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(find.text('新角色专用预设'), findsNothing);
    await tester.tap(find.text('导入绑定新预设'));
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('导入「新角色专用预设」'), findsOneWidget);
    await tester.tap(find.text('导入').last);
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(picker.lastExtensions, ['json']);
    expect(find.textContaining('跟随默认'), findsNothing);
    expect(
      find.text('新角色专用预设'),
      findsOneWidget,
      reason: tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .join(' | '),
    );
    await tester.ensureVisible(find.text('导入绑定新预设'));
    await tester.pumpAndSettle();
    if (capture) {
      await _capture(tester, boundaryKey, 'contact-create-preset-bound');
    }

    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });
}

Future<void> _capture(
  WidgetTester tester,
  GlobalKey boundaryKey,
  String name,
) async {
  await tester.runAsync(() async {
    final boundary =
        boundaryKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1.5);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('../../.codex-temp/contact-edit-preview/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

/// 生成线性渐变 PNG 的 data URI，避免在测试里依赖真实图片文件。
String _pngDataUri(
  int width,
  int height,
  (int, int, int) top,
  (int, int, int) bottom,
) {
  final image = img.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    final t = height <= 1 ? 0.0 : y / (height - 1);
    final r = (top.$1 + (bottom.$1 - top.$1) * t).round();
    final g = (top.$2 + (bottom.$2 - top.$2) * t).round();
    final b = (top.$3 + (bottom.$3 - top.$3) * t).round();
    img.fillRect(
      image,
      x1: 0,
      y1: y,
      x2: width,
      y2: y + 1,
      color: img.ColorRgb8(r, g, b),
    );
  }
  final png = img.encodePng(image);
  return 'data:image/png;base64,${base64Encode(png)}';
}

class _JsonPicker extends FilePicker {
  _JsonPicker(this.source);

  final String source;
  List<String>? lastExtensions;

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
  }) async {
    lastExtensions = allowedExtensions;
    final bytes = Uint8List.fromList(utf8.encode(source));
    return FilePickerResult([
      PlatformFile(name: 'preset.json', size: bytes.length, bytes: bytes),
    ]);
  }
}

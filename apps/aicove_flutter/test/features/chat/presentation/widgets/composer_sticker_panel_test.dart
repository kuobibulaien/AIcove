import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/chat/chat_actions.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/composer.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/composer_more_panel.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/composer_sticker_panel.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_request_message_builder.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/stickers/sticker_library.dart';
import 'package:aicove_flutter/src/features/stickers/sticker_library_provider.dart';
import 'package:aicove_flutter/src/features/stickers/sticker_registry.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const capture = bool.fromEnvironment('WRITE_COMPOSER_STICKER_PREVIEW');
  late Directory tempDir;
  late StickerLibrary lib;
  late Future<StickerLibrary> Function() originalOpen;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('composer_sticker_test_');
    originalOpen = StickerLibraryNotifier.open;
    lib = StickerLibrary(tempDir);
    await lib.load();
    Uint8List asset(String name) =>
        File('assets/stickers/builtin/$name.webp').readAsBytesSync();
    await lib.importFiles(
      [
        StickerImportFile(
          '贴贴.webp',
          asset('xiaokumao/459a6ca140046c4119aea0c038a3f742'),
          tags: const ['贴贴', '抱抱'],
          description: '小猫张开双手求抱抱',
        ),
        StickerImportFile('得意 叉腰.webp', asset('zhegou/f4703a3fe296d0c814eec32e4c97dbbc')),
        StickerImportFile('摸鱼-2.webp', asset('xiaokumao/b2cb23f85dc95dc1b610cc928da19243')),
        StickerImportFile(
          'IMG_0412.webp',
          asset('xiaokumao/dd3af701f8252f061f86bcb319aeeb1a'),
          tags: const [],
          description: '',
        ),
      ],
      packName: '我的表情',
    );
    await lib.importFiles(
      [
        StickerImportFile('晚安.webp', asset('xiaokumao/26569b02520a0464e87e5c01e5e1ff97')),
        StickerImportFile('早安.webp', asset('zhegou/dca01d6b71fac56fd87e7b2d07a03001')),
      ],
      packName: '日常收藏',
    );
    StickerLibraryNotifier.open = () async => lib;

    if (!capture) return;
    final font = FontLoader('StickerPreview')
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

  tearDownAll(() async {
    StickerLibraryNotifier.open = originalOpen;
    StickerRegistry.instance.replaceStickers(const []);
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<void> settleImages(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pumpAndSettle();
    }
    expect(tester.takeException(), isNull);
  }

  testWidgets('更多面板点击「表情」进入表情面板，点击表情立即触发发送回调', (tester) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 520);
    SharedPreferences.setMockInitialValues({});

    Sticker? sentSticker;
    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        child: MaterialApp(
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFFFC96AA),
              brightness: Brightness.light,
              surface: moeSurface,
              onSurface: moeText,
            ),
            scaffoldBackgroundColor: moeSurface,
            fontFamily: capture ? 'StickerPreview' : null,
            extensions: [MoeColors.light()],
          ),
          builder: (context, child) => MoeGlassTheme(
            enabled: true,
            useLiquidGlass: false,
            blurSigma: 16,
            child: RepaintBoundary(key: boundaryKey, child: child!),
          ),
          home: Scaffold(
            backgroundColor: const Color(0xFFFDF7F9),
            body: Column(
              children: [
                const Expanded(
                  child: Center(
                    child: Text(
                      '聊天消息区域',
                      style: TextStyle(color: Color(0xFF9E8E95), fontSize: 13),
                    ),
                  ),
                ),
                Composer(
                  onSend: (_) {},
                  onSubmitSticker: (sticker) {
                    sentSticker = sticker;
                    return true;
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 打开更多面板（六宫格）
    await tester.tap(find.byIcon(Icons.add_rounded));
    await tester.pumpAndSettle();
    expect(find.byType(ComposerMorePanel), findsOneWidget);
    expect(find.text('表情'), findsOneWidget);

    if (capture) {
      await settleImages(tester);
      await _capture(
        tester,
        boundaryKey,
        '../../scratch/composer-sticker-preview/more-panel-6grid-light.png',
      );
    }

    // 点击六宫格中的「表情」切换至表情面板
    await tester.tap(find.text('表情'));
    await tester.pumpAndSettle();
    await settleImages(tester);
    expect(find.byType(ComposerStickerPanel), findsOneWidget);
    expect(find.text('我的表情'), findsOneWidget);
    expect(find.text('日常收藏'), findsOneWidget);

    // 包括已标注和未标注的用户自导入表情都应展示（当前套组共 4 张）
    final firstPackStickers = lib.packs.first.stickers;
    expect(firstPackStickers.length, 4);
    for (final s in firstPackStickers) {
      expect(find.byKey(ValueKey('composer_sticker_${s.id}')), findsOneWidget);
    }

    if (capture) {
      await _capture(
        tester,
        boundaryKey,
        '../../scratch/composer-sticker-preview/sticker-panel-light.png',
      );
    }

    // 点击第一张表情触发发送
    await tester.tap(
      find.byKey(ValueKey('composer_sticker_${firstPackStickers.first.id}')),
    );
    await tester.pumpAndSettle();
    expect(sentSticker, isNotNull);
    expect(sentSticker!.id, firstPackStickers.first.id);
    expect(sentSticker!.tags, contains('贴贴'));
  });

  test('用户发送的表情块在构建模型请求时转为可读的表情文本', () async {
    final tagged = buildUserStickerMessage(
      const Sticker(
        id: 's_1',
        packId: 'p_1',
        path: '/tmp/goodnight.png',
        tags: ['晚安', '困了'],
        description: '小猫打哈欠',
      ),
    );
    final untagged = buildUserStickerMessage(
      const Sticker(
        id: 's_2',
        packId: 'p_1',
        path: '/tmp/custom.png',
        tags: [],
        description: '',
      ),
    );
    expect(tagged.displayText, '[表情]');
    expect(tagged.blocks!.single, isA<EmojiBlock>());

    final builder = ChatRequestMessageBuilder(
      readImageAsBase64: (_) async => null,
    );
    final req = await builder.buildRequestMessages(
      [tagged, untagged],
      settings: mapUiModelsToAppSettings(const {}),
    );
    expect(req, [
      {'role': 'user', 'content': '[表情：晚安、困了（小猫打哈欠）]'},
      {'role': 'user', 'content': '[表情]'},
    ]);
  });
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String path) async {
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2.0);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

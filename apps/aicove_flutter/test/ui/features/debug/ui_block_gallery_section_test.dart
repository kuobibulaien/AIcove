import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/features/debug/pages/ui_block_gallery_section.dart';
import 'package:aicove_flutter/src/ui/theme/skin_provider.dart';
import 'package:aicove_flutter/src/ui/theme/skins/moetalk_skin.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _writePreview = bool.fromEnvironment('WRITE_UI_BLOCK_PREVIEW');

class _FakeAppSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettings> build() async => AppSettings(
        ttsEnabled: false,
        defaultModelName: 'm',
        defaultPersonaPrompt: '',
        modelList: const ['m'],
        allKnownModels: const ['m'],
        modelDisplayNames: const {},
        modelTypes: const {},
        modelConfigs: const {},
        apiKey: '',
        apiBaseUrl: '',
        imageGenerationEnabled: false,
        maxFileUploadMB: 10,
        contextWindowTokens: 1000,
        customModels: const [],
        providers: const [],
        modelProviderMap: const {},
        backendApiKey: '',
        messageChunkingEnabled: false,
        messageFormatConfig: const MessageFormatConfig(),
        textScaleFactor: 1.0,
        uiScaleFactor: 1.0,
        imagePreviewScale: 1.0,
        autoReplySettings: const AutoReplySettings(),
        globalBackgroundColor: GlobalBackgroundColor.white,
        chatBackgroundColor: ChatBackgroundColor.defaultColor,
        isDarkMode: false,
        useSystemTheme: true,
        accentColor: 'FC96AA',
        hideUserAvatar: false,
      );
}

void main() {
  setUpAll(() async {
    if (!_writePreview) return;
    for (final entry in {
      'Preview': '/System/Library/Fonts/STHeiti Medium.ttc',
      'MaterialIcons':
          '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    }.entries) {
      final loader = FontLoader(entry.key);
      loader.addFont(File(entry.value).readAsBytes().then(ByteData.sublistView));
      await loader.load();
    }
  });

  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final dark in [false, true]) {
    final name = 'gallery-${dark ? 'dark' : 'light'}';
    // 源码渲染预览：--dart-define=WRITE_UI_BLOCK_PREVIEW=true 时写到 scratch/ui-blocks-20261018/。
    testWidgets('UI gallery samples render without errors ($name)', (tester) async {
      tester.view.physicalSize = const Size(420, 6000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final capture = GlobalKey();
      await tester.pumpWidget(ProviderScope(
        overrides: [appSettingsProvider.overrideWith(_FakeAppSettingsNotifier.new)],
        child: SkinScope(
          skin: const MoeTalkSkin(),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              brightness: dark ? Brightness.dark : Brightness.light,
              fontFamily: _writePreview ? 'Preview' : null,
              extensions: [dark ? MoeColors.dark() : MoeColors.light()],
            ),
            home: Builder(
              builder: (context) => Scaffold(
                backgroundColor: context.moeColors.bgMain,
                body: SingleChildScrollView(
                  child: RepaintBoundary(
                    key: capture,
                    child: ColoredBox(
                      color: context.moeColors.bgMain,
                      child: const UiBlockGallerySection(),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      expect(find.text('原语一览'), findsOneWidget);
      expect(find.text('正在生成交互组件…'), findsOneWidget);
      expect(find.textContaining('不认识的组件「rocket」'), findsOneWidget);
      expect(find.text('小雪 会用「温柔」的语气说话。'), findsOneWidget);
      await tester.tap(find.text('更多'));
      await tester.pump();
      await tester.tap(find.text('升一级'));
      await tester.pump();
      expect(find.text('等级 3'), findsOneWidget);
      if (_writePreview) {
        await tester.tap(find.text('人设'));
        await tester.pump();
        await tester.runAsync(() async {
          final boundary = capture.currentContext!.findRenderObject() as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('../../scratch/ui-blocks-20261018/$name.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
        });
      }
      await tester.pump(const Duration(seconds: 1));
    });
  }
}

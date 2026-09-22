import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/smart_reply/application/smart_reply_controller.dart';
import 'package:aicove_flutter/src/features/smart_reply/domain/smart_reply.dart';
import 'package:aicove_flutter/src/features/smart_reply/infrastructure/smart_reply_adapter.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/smart_reply_badge.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/ui_settings_page.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';

class PreviewSettings extends AppSettingsNotifier {
  @override
  Future<AppSettings> build() async => mapUiModelsToAppSettings({
    'smart_reply_enabled': true,
    'smart_reply_model': 'demo:fast',
    'use_liquid_glass': false,
    'providers': [
      {
        'id': 'demo',
        'displayName': '示例渠道',
        'models': ['fast'],
        'visible_models': ['fast'],
        'api_keys': [],
        'api_base_url': 'https://example.invalid',
      },
    ],
  });
}

class PreviewPort implements SmartReplyPort {
  int calls = 0;
  @override
  Future<SmartReplySnapshot> snapshot(String id) async =>
      SmartReplySnapshot(id, [
        Message(
          id: '1',
          role: 'assistant',
          content: '今天过得怎么样？想聊聊吗？',
          createdAt: DateTime(2026),
        ),
      ]);
  @override
  Future<List<String>> generate(
    SmartReplySnapshot snapshot,
    String modelRef,
  ) async {
    calls++;
    return ['今天有点累，想和你聊一会儿。', '你有什么让心情放松的小办法吗？', '想听你分享一件有趣的事。'];
  }
}

void main() {
  const write = bool.fromEnvironment('WRITE_SMART_REPLY_PREVIEW');
  setUpAll(() async {
    if (!write) return;
    final font = FontLoader('SmartReplyPreview')
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
  for (final width in [360.0, 1000.0]) {
    testWidgets('source preview and candidate selection at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final port = PreviewPort();
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWith(PreviewSettings.new),
          smartReplyPortProvider.overrideWithValue(port),
        ],
      );
      addTearDown(container.dispose);
      await container.read(appSettingsProvider.future);
      final boundaryKey = GlobalKey();
      Widget app(Widget child) => UncontrolledProviderScope(
        container: container,
        child: RepaintBoundary(
          key: boundaryKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              extensions: [MoeColors.light()],
              fontFamily: write ? 'SmartReplyPreview' : null,
            ),
            home: child,
          ),
        ),
      );
      Future<void> capture(String name) async {
        if (!write) return;
        await tester.runAsync(() async {
          final boundary =
              boundaryKey.currentContext!.findRenderObject()
                  as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1.5);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File(
            '../../.codex-temp/smart-reply/$name-${width.toInt()}.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }

      await tester.pumpWidget(app(const UiSettingsPage()));
      await tester.pumpAndSettle();
      expect(find.text('通用设置'), findsOneWidget);
      expect(find.text('辅助模型'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await capture('settings');
      final draft = container.listen(
        smartReplyDraftProvider('preview'),
        (_, _) {},
      );
      addTearDown(draft.close);
      await tester.pumpWidget(
        app(
          Scaffold(
            appBar: AppBar(title: const Text('辅助回答 · 源码渲染预览')),
            body: const Stack(
              children: [
                Positioned(left: 24, top: 36, child: Text('今天过得怎么样？想聊聊吗？')),
                Positioned(
                  right: 68,
                  bottom: 100,
                  child: SmartReplyBadge(conversationId: 'preview', size: 44),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byKey(const ValueKey('smart_reply_badge'))),
        const Size(44, 44),
      );
      await tester.tap(find.byKey(const ValueKey('smart_reply_badge')));
      await tester.pumpAndSettle();
      for (var index = 0; index < 3; index++) {
        expect(
          find.byKey(ValueKey('smart_reply_candidate_$index')),
          findsOneWidget,
        );
      }
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(OutlinedButton), findsNothing);
      expect(tester.takeException(), isNull);
      await capture('candidates');
      await tester.tap(find.text('今天有点累，想和你聊一会儿。'));
      await tester.pumpAndSettle();
      expect(draft.read(), '今天有点累，想和你聊一会儿。');
      await tester.tap(find.byKey(const ValueKey('smart_reply_badge')));
      await tester.pumpAndSettle();
      expect(port.calls, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

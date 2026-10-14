import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/features/plugins/tts/voice_preset_application.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/voice_call/providers/voice_call_settings.dart';
import 'package:aicove_flutter/src/ui/features/plugins/pages/tts_plugin_detail_page.dart';
import 'package:aicove_flutter/src/ui/features/voice_call/pages/voice_call_settings_page.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:aicove_flutter/src/ui/theme/skin_provider.dart';
import 'package:aicove_flutter/src/ui/theme/skins/moetalk_skin.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Settings extends AppSettingsNotifier {
  @override
  Future<AppSettings> build() async => mapUiModelsToAppSettings({});
}

void main() {
  const capture = bool.fromEnvironment('WRITE_VOICE_CALL_PREVIEW');

  Future<void> mount(
    WidgetTester tester,
    Widget page, {
    Size size = const Size(360, 720),
    GlobalKey? boundary,
  }) async {
    tester.view.physicalSize = size * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsProvider.overrideWith(_Settings.new),
          voicePresetReadyProvider.overrideWith((ref) async {}),
          callRecognizerReadinessProvider.overrideWith(
            (ref) async => const CallRecognizerReadiness(
              localInstalled: false,
              aliyunConfigured: true,
            ),
          ),
        ],
        child: SkinScope(
          skin: const MoeTalkSkin(),
          child: MaterialApp(
            theme: ThemeData(
              fontFamily: capture ? 'Preview' : null,
              extensions: [MoeColors.light()],
            ),
            home: RepaintBoundary(key: boundary, child: page),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the voice plugin page opens the call settings', (tester) async {
    await mount(tester, const TtsPluginDetailPage());
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('语音通话'));
    await tester.pumpAndSettle();
    expect(find.byType(VoiceCallSettingsPage), findsOneWidget);
  });

  testWidgets('recognizer source defaults to auto and is kept on this device', (
    tester,
  ) async {
    await mount(tester, const VoiceCallSettingsPage());
    expect(tester.takeException(), isNull);
    expect(find.text('本地模型未安装，当前会用阿里云百炼'), findsOneWidget);
    Finder checkIn(String label) => find.descendant(
      of: find.ancestor(
        of: find.text(label),
        matching: find.byType(MoeSettingsRow),
      ),
      matching: find.byIcon(Icons.check),
    );
    expect(checkIn('自动'), findsOneWidget);

    await tester.tap(find.text('阿里云百炼'));
    await tester.pumpAndSettle();
    expect(checkIn('阿里云百炼'), findsOneWidget);
    expect(checkIn('自动'), findsNothing);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('aicove.voice_call.recognizer_source.v1'), 'aliyun');
  });

  testWidgets('voice call settings source rendered preview', (tester) async {
    if (!capture) return;
    await tester.runAsync(() async {
      final loader = FontLoader('Preview')
        ..addFont(
          File(
            '/System/Library/Fonts/STHeiti Medium.ttc',
          ).readAsBytes().then(ByteData.sublistView),
        );
      await loader.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(
          File(
            '${Platform.environment['HOME']}/dev-sdks/flutter-3.44.6/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ).readAsBytes().then(ByteData.sublistView),
        );
      await icons.load();
    });
    for (final (name, page) in [
      ('voice-plugin', const TtsPluginDetailPage() as Widget),
      ('voice-call-settings', const VoiceCallSettingsPage()),
    ]) {
      final key = GlobalKey();
      await mount(tester, page, size: const Size(390, 760), boundary: key);
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final dir = Directory('../../.codex-temp/voice-call/previews')
          ..createSync(recursive: true);
        await File(
          '${dir.path}/$name-390.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
  });
}

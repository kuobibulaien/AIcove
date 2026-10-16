import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/ui/features/voice_call/window/voice_call_window_app.dart';
import 'package:aicove_flutter/src/ui/features/voice_call/window/voice_call_window_protocol.dart';
import 'package:aicove_flutter/src/ui/features/voice_call/widgets/voice_call_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _capture = bool.fromEnvironment('WRITE_VOICE_CALL_PREVIEW');

VoiceCallWindowAppearance _appearance({bool dark = false, bool glass = true}) =>
    VoiceCallWindowAppearance(
      conversationId: 'nahida',
      name: '纳西妲',
      backgroundColor: dark ? 0xFF101418 : 0xFFF6F2F4,
      dark: dark,
      accentColor: 0xFFE58FA8,
      glassEnabled: glass,
      glassBlurSigma: 20,
      glassTintFill: 0.5,
      wallpaper: 'assets/wallpapers/catnap_light.webp',
    );

void main() {
  testWidgets(
    'the call window follows appearance pushed from the main window',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final call = RemoteVoiceCall((_, [_]) async {});
      final appearance = ValueNotifier(_appearance());
      final key = GlobalKey();
      if (_capture) {
        await tester.runAsync(() async {
          final loader = FontLoader('Preview')
            ..addFont(
              File(
                '/System/Library/Fonts/STHeiti Medium.ttc',
              ).readAsBytes().then(ByteData.sublistView),
            );
          await loader.load();
        });
      }
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: ValueListenableBuilder(
            valueListenable: appearance,
            builder: (_, value, _) =>
                VoiceCallWindowApp(appearance: value, call: call),
          ),
        ),
      );
      call.apply({'phase': 'listening', 'elapsedMs': 12000, 'turns': []});
      await tester.pump();
      expect(find.text('纳西妲'), findsOneWidget);
      expect(find.byType(VoiceCallView), findsOneWidget);
      // 小窗没有收起按钮：关窗就是挂断。
      expect(find.byKey(const ValueKey('voice-call-collapse')), findsNothing);

      // 主窗口切到深色、关掉材质：小窗跟着换。
      appearance.value = _appearance(dark: true, glass: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final theme = Theme.of(tester.element(find.byType(VoiceCallView)));
      expect(theme.brightness, Brightness.dark);

      if (!_capture) return;
      for (final (name, value) in [
        ('voice-call-window-frosted-light', _appearance()),
        ('voice-call-window-solid-light', _appearance(glass: false)),
      ]) {
        appearance.value = value;
        await tester.runAsync(
          () => precacheImage(
            const AssetImage('assets/wallpapers/catnap_light.webp'),
            tester.element(find.byType(VoiceCallView)),
          ),
        );
        await tester.pump(const Duration(seconds: 1));
        await tester.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final dir = Directory('../../.codex-temp/voice-call/previews')
            ..createSync(recursive: true);
          await File(
            '${dir.path}/$name.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
    },
  );
}

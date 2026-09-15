import 'package:aicove_flutter/src/ui/features/plugins/pages/tts_plugin_detail_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Foundation phase only: existing page still renders with empty legacy
/// preferences. This is not acceptance of the planned replacement interface.
void main() {
  for (final size in [const Size(320, 568), const Size(1000, 768)]) {
    for (final scale in [1.2, 1.8]) {
      testWidgets('legacy TTS page $size text scale $scale', (tester) async {
        SharedPreferences.setMockInitialValues({});
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: const TtsPluginDetailPage(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        for (var step = 0; step < 6; step++) {
          await tester.drag(
            find.byType(Scrollable).first,
            const Offset(0, -400),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
      });
    }
  }
}

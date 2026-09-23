import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aicove_flutter/src/ui/features/plugins/pages/artist_preset_page.dart';
import 'package:aicove_flutter/src/ui/features/plugins/pages/draw_image_tool_description_page.dart';
import 'package:aicove_flutter/src/ui/features/plugins/pages/image_plugin_detail_page.dart';
import 'package:aicove_flutter/src/ui/features/plugins/pages/inline_image_prompt_page.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/context_memory_settings_page.dart';
import 'package:aicove_flutter/src/ui/features/plugins/pages/time_awareness_plugin_detail_page.dart';
import 'package:aicove_flutter/src/ui/features/plugins/pages/tts_plugin_detail_page.dart';
import 'package:aicove_flutter/src/ui/features/plugins/pages/sticker_settings_page.dart';

void main() {
  const pages = <String, Widget>{
    'artist': ArtistPresetPage(),
    'draw-description': DrawImageToolDescriptionPage(),
    'image': ImagePluginDetailPage(),
    'inline-prompt': InlineImagePromptPage(),
    'memory': ContextMemorySettingsPage(),
    'time': TimeAwarenessPluginDetailPage(),
    'tts': TtsPluginDetailPage(),
    'stickers': StickerSettingsPage(),
  };
  for (final page in pages.entries) {
    for (final size in [const Size(320, 568), const Size(1000, 768)]) {
      for (final scale in [1.2, 1.8]) {
        testWidgets('${page.key} size=$size scale=$scale', (tester) async {
          // Empty synthetic storage: no user preferences or service requests.
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
                home: page.value,
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          // Exercise lazily laid out content without invoking plugin actions.
          final scroll = find.byType(Scrollable).first;
          for (var step = 0; step < 6; step++) {
            await tester.drag(scroll, const Offset(0, -400));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          }
        });
      }
    }
  }
}

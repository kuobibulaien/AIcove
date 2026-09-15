import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/features/agent_context/providers/preset_recipe_provider.dart';
import 'package:aicove_flutter/src/ui/features/character/widgets/preset_recipe_section.dart';

void main() {
  for (final size in [const Size(320, 568), const Size(1000, 768)]) {
    for (final scale in [1.2, 1.8]) {
      testWidgets('preset picker 100 entries size=$size scale=$scale',
          (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        String? selected;
        await tester.pumpWidget(ProviderScope(
            overrides: [
              presetRecipeListProvider
                  .overrideWith((ref) async => List.generate(
                        100,
                        (i) => PresetRecipeSummary(
                            id: 'preset-$i',
                            name: 'Preset $i',
                            description: 'Synthetic preset'),
                      )),
            ],
            child: MaterialApp(
              builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!),
              home: Scaffold(
                  body: Builder(
                      builder: (context) => TextButton(
                            onPressed: () => showTavernPresetPicker(
                              context: context,
                              selectedRecipeId: null,
                              onChanged: (value) => selected = value,
                            ),
                            child: const Text('打开选择器'),
                          ))),
            )));
        await tester.pumpAndSettle();
        await tester.tap(find.text('打开选择器'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final list = find.descendant(
            of: find.byType(ListView), matching: find.byType(Scrollable));
        await tester.scrollUntilVisible(find.text('Preset 99'), 250,
            maxScrolls: 100, scrollable: list);
        // ensureVisible 最后一次跳转后等待布局，不能拿上一帧的命中区域断言。
        await tester.pumpAndSettle();
        expect(find.text('Preset 99').hitTestable(), findsOneWidget);
        await tester.tap(find.text('Preset 99'));
        await tester.pumpAndSettle();
        expect(selected, 'preset-99');
        expect(tester.takeException(), isNull);
      });
    }
  }
}

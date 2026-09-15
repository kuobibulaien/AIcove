import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/chat_plugin_selector.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';

void main() {
  for (final width in [320.0, 1000.0]) {
    testWidgets(
      'chat plugin switches save while open and flush on close $width',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          'aicove.ui_models.v1': '{"image_generation_enabled":true}',
        });
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final saved = <List<String>?>[];
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(1.8)),
                child: child!,
              ),
              home: Consumer(
                builder: (context, ref, _) => Scaffold(
                  body: TextButton(
                    child: const Text('插件设置'),
                    onPressed: () => showChatPluginSelector(
                      context: context,
                      ref: ref,
                      enabledPlugins: null,
                      onChanged: (value) async {
                        saved.add(value);
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('插件设置'));
        await tester.tap(find.text('插件设置'));
        await tester.pumpAndSettle();
        expect(find.byType(MoeBottomSheet), findsOneWidget);
        expect(find.byType(Checkbox), findsNothing);
        final image = find.text('绘图设置');
        await tester.ensureVisible(image);
        await tester.tap(image);
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pumpAndSettle();
        expect(saved, hasLength(1));
        expect(saved.single, isNot(contains('image')));
        expect(find.text('确定'), findsNothing);
        expect(
          tester
              .widget<MoeSettingsRow>(
                find.ancestor(of: image, matching: find.byType(MoeSettingsRow)),
              )
              .switchValue,
          isFalse,
        );
        expect(
          tester
              .widget<MoeSettingsRow>(
                find.ancestor(of: image, matching: find.byType(MoeSettingsRow)),
              )
              .enabled,
          isTrue,
        );
        await tester.tap(image);
        await tester.pump();
        expect(
          tester
              .widget<MoeAutoSaveScope>(find.byType(MoeAutoSaveScope))
              .controller
              .pending,
          isTrue,
        );
        await tester.tap(find.byIcon(CupertinoIcons.xmark));
        await tester.pumpAndSettle();
        expect(saved, hasLength(2));
        expect(saved.last, isNull);
        expect(find.byType(MoeBottomSheet), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

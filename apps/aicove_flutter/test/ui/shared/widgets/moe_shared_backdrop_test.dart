import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_chat_header.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Widget child) => MaterialApp(
  theme: ThemeData(extensions: [MoeColors.light()]),
  builder: (context, child) =>
      MoeGlassTheme(enabled: true, blurSigma: 16, child: child!),
  home: child,
);

List<BackdropKey?> _keys(WidgetTester tester) => tester
    .widgetList<BackdropFilter>(find.byType(BackdropFilter))
    .map((filter) => filter.backdropGroupKey)
    .toList();

void main() {
  testWidgets('header capsules share one backdrop read', (tester) async {
    await tester.pumpWidget(
      _app(
        Scaffold(
          appBar: MoeChatHeader(
            title: const Text('标题'),
            actions: [IconButton(onPressed: () {}, icon: const Icon(Icons.add))],
            showBackButton: true,
            nativeInset: 0,
            toolbarHeight: 44,
          ),
          body: const SizedBox.expand(),
        ),
      ),
    );

    final keys = _keys(tester);
    expect(keys, hasLength(3));
    expect(keys.toSet(), hasLength(1));
    expect(keys.first, isNotNull);
  });

  testWidgets('surfaces outside a shared backdrop keep their own read', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const Scaffold(
          body: Column(
            children: [
              MoeFloatingSurface(child: SizedBox(height: 40)),
              MoeFloatingSurface(child: SizedBox(height: 40)),
            ],
          ),
        ),
      ),
    );

    expect(_keys(tester), [null, null]);
  });
}

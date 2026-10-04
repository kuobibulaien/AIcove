import 'package:aicove_flutter/src/ui/features/character/widgets/tavern_greeting_picker_sheet.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('picker lists every greeting and returns the tapped index', (
    tester,
  ) async {
    int? picked;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: [MoeColors.light()]),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              picked = await showTavernGreetingPicker(
                context,
                greetings: const ['第一套', '第二套', '第三套'],
                selectedIndex: 0,
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('选择开场白'), findsOneWidget);
    expect(find.text('开场白 1（主开场白）'), findsOneWidget);
    expect(find.text('开场白 3'), findsOneWidget);

    await tester.tap(find.text('第二套'));
    await tester.pumpAndSettle();
    expect(picked, 1);
    expect(find.text('选择开场白'), findsNothing);
  });

  testWidgets('long greeting collapses to preview and expands to full text', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 568);
    addTearDown(tester.view.reset);
    final long = List.filled(80, '很长的开场白内容。').join('\n');
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: [MoeColors.light()]),
        home: Scaffold(
          body: TavernGreetingPickerList(
            greetings: ['短开场', long],
            onSelected: (_) {},
          ),
        ),
      ),
    );
    expect(find.text('展开全文'), findsOneWidget);
    Text body() => tester.widget<Text>(find.text(long));
    expect(body().maxLines, 6);

    await tester.tap(find.text('展开全文'));
    await tester.pump();
    expect(body().maxLines, isNull);
    expect(find.text('收起'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

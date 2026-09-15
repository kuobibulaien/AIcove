import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:aicove_flutter/src/ui/features/backup/pages/import_file_page.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';

void main() {
  testWidgets('分组最后一行保留自定义副标题和长按操作', (tester) async {
    var calls = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MoeSettingsGroup(children: [
          MoeSettingsRow(
            label: '预设',
            subtitleWidget: const Text('自定义说明'),
            onLongPress: () => calls++,
          ),
        ]),
      ),
    ));
    expect(find.text('自定义说明'), findsOneWidget);
    await tester.longPress(find.text('预设'));
    await tester.pumpAndSettle();
    expect(calls, 1);
  });

  for (final size in [
    const Size(320, 568),
    const Size(1000, 768),
    const Size(800, 360)
  ]) {
    for (final scale in [1.0, 1.2, 1.8, 2.0]) {
      testWidgets('backup import layout size=$size scale=$scale',
          (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(ProviderScope(
            child: MaterialApp(
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!),
          home: const ImportFilePage(),
        )));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('点击选择文件').hitTestable(), findsOneWidget);
      });
    }
  }

  for (final width in [320.0, 1000.0]) {
    testWidgets('action selector exposes long list at $width', (tester) async {
      await tester.binding.setSurfaceSize(Size(width, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var selected = -1;
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: Builder(
        builder: (context) => TextButton(
          onPressed: () => showMoeActionSheet(
            context: context,
            title: '选择 TTS 模型',
            enableHaptics: false,
            actions: List.generate(
                100,
                (i) => MoeSheetAction(
                      label: 'model-$i',
                      subtitle: 'Synthetic provider',
                      onTap: () => selected = i,
                    )),
          ),
          child: const Text('open'),
        ),
      ))));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('model-99'));
      await tester.tap(find.text('model-99'));
      await tester.pumpAndSettle();
      expect(selected, 99);
    });
  }

  testWidgets('disabled settings row rejects long press', (tester) async {
    var calls = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: MoeSettingsRow(
      label: 'disabled',
      enabled: false,
      onLongPress: () => calls++,
    ))));
    await tester.longPress(find.text('disabled'));
    await tester.pumpAndSettle();
    expect(calls, 0);
  });

  testWidgets('switch row default false can be toggled', (tester) async {
    bool? changed;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: MoeSettingsRow(
      label: 'switch',
      trailingType: MoeSettingsRowTrailing.switchControl,
      onSwitchChanged: (value) => changed = value,
    ))));
    await tester.tap(find.text('switch'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(changed, true);
  });
}

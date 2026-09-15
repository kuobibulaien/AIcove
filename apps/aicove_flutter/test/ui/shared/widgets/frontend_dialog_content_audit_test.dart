import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/meotalk_dialog.dart';

void main() {
  for (final size in [const Size(320, 568), const Size(1000, 768)]) {
    for (final scale in [1.2, 1.8]) {
      for (final long in [false, true]) {
        testWidgets('alert size=$size scale=$scale long=$long', (tester) async {
          await tester.binding.setSurfaceSize(size);
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final message = long
              ? List.filled(40, 'Synthetic diagnostic detail').join('\n')
              : 'Synthetic detail';
          await tester.pumpWidget(MaterialApp(
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!),
            home: Scaffold(
                body: Builder(
                    builder: (context) => TextButton(
                          onPressed: () => showMeoTalkAlert(
                              context: context, title: '提示', message: message),
                          child: const Text('open'),
                        ))),
          ));
          await tester.tap(find.text('open'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.ensureVisible(find.text('知道了'));
          await tester.tap(find.text('知道了'));
          await tester.pumpAndSettle();
          expect(find.text('知道了'), findsNothing);
        });
      }
    }
  }
}

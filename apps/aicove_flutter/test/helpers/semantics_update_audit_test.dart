import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'semantics_update_audit.dart';

void main() {
  SemanticsAuditBinding.ensureInitialized();
  final SemanticsUpdateAudit audit = SemanticsUpdateAudit.instance;
  setUp(audit.reset);

  testWidgets('flags the Slider-in-pushed-route orphan (flutter#190357)', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: ElevatedButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      Scaffold(body: Slider(value: .3, onChanged: (_) {})),
                ),
              ),
              child: const Text('push'),
            ),
          ),
        ),
      ),
    );
    expect(audit.violations, isEmpty);
    await tester.tap(find.text('push'));
    await tester.pumpAndSettle();
    expect(audit.violations, isNotEmpty);
  });

  testWidgets('a plain screen passes', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Column(children: <Widget>[Text('a'), TextField()])),
      ),
    );
    await tester.pumpAndSettle();
    expect(audit.violations, isEmpty);
  });
}

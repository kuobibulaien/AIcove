import 'package:aicove_flutter/src/ui/shared/widgets/form/moe_slider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../helpers/semantics_update_audit.dart';

/// A Material Slider sends semantics updates the desktop engine rejects: an
/// orphan value-indicator node while a route transition hides the slider, and
/// a moved indicator node that is not resent when enabled toggles. The macOS
/// accessibility bridge then keeps freed nodes and crashes on the next mouse
/// move (flutter#190357, flutter#193588).
void main() {
  SemanticsAuditBinding.ensureInitialized();
  final SemanticsUpdateAudit audit = SemanticsUpdateAudit.instance;
  setUp(audit.reset);

  testWidgets('pushing and popping a page with MoeSlider sends only '
      'semantics updates the desktop engine accepts', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Column(
              children: [
                const TextField(),
                ElevatedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => Scaffold(
                        body: Center(
                          child: MoeSlider(
                            value: .3,
                            label: '30%',
                            onChanged: (_) {},
                          ),
                        ),
                      ),
                    ),
                  ),
                  child: const Text('push'),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('push'));
    await tester.pumpAndSettle();
    expect(find.byType(MoeSlider), findsOneWidget);
    Navigator.of(tester.element(find.byType(MoeSlider))).pop();
    await tester.pumpAndSettle();

    expect(audit.violations, isEmpty, reason: audit.violations.join('\n'));
  });

  testWidgets('toggling MoeSlider enabled sends only semantics updates the '
      'desktop engine accepts', (tester) async {
    Widget host({required bool enabled}) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 300,
            child: MoeSlider(value: .3, onChanged: enabled ? (_) {} : null),
          ),
        ),
      ),
    );

    await tester.pumpWidget(host(enabled: true));
    await tester.pumpWidget(host(enabled: false));
    await tester.pumpWidget(host(enabled: true));
    await tester.pumpAndSettle();

    expect(audit.violations, isEmpty, reason: audit.violations.join('\n'));
  });
}

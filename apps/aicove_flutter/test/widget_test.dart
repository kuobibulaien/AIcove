import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/app.dart';

void main() {
  testWidgets('MyApp boots inside ProviderScope', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: MyApp()),
    );
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byType(MaterialApp), findsOneWidget);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/provider/provider_avatar.dart';

void main() {
  for (final name in ['audit-', '-audit', 'audit-provider', '']) {
    testWidgets('provider avatar accepts display name "$name"', (tester) async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: ProviderAvatar(providerName: name))));
      expect(tester.takeException(), isNull);
    });
  }
}

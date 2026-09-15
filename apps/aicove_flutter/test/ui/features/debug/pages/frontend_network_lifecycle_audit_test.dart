import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:aicove_flutter/src/ui/features/debug/pages/network_diagnostic_page.dart';

void main() {
  testWidgets('network diagnostic ignores response after page disposal',
      (tester) async {
    final response = Completer<http.Response>();
    var requests = 0;
    final client = MockClient((request) {
      requests++;
      expect(request.url.host, 'example.invalid');
      return response.future;
    });
    await tester.binding.setSurfaceSize(const Size(1000, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const MaterialApp(home: NetworkDiagnosticPage()));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byType(TextField).first, 'https://example.invalid/audit');
    await http.runWithClient(() async {
      await tester.tap(find.text('发送请求'));
      await tester.pump();
      expect(requests, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const MaterialApp(home: Scaffold()));
      response.complete(http.Response('synthetic', 200));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }, () => client);
  });
}

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import '../../../../helpers/release_source_preview.dart';
import 'package:aicove_flutter/src/ui/features/debug/pages/network_diagnostic_page.dart';

class _TrackedClient extends MockClient {
  _TrackedClient(super.fn);
  int closes = 0;
  @override
  void close() {
    closes++;
    super.close();
  }
}

void main() {
  for (final width in [360.0, 1000.0]) {
    testWidgets(
      'network diagnostic ignores response after page disposal width=$width',
      (tester) async {
        final response = Completer<http.Response>();
        var requests = 0;
        final client = _TrackedClient((request) {
          requests++;
          expect(request.url.host, 'example.invalid');
          return response.future;
        });
        await tester.binding.setSurfaceSize(Size(width, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await loadReleasePreviewFonts(tester);
        final key = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: ThemeData(
                fontFamily: captureReleaseSourcePreview
                    ? 'ReleasePreview'
                    : null,
              ),
              home: const NetworkDiagnosticPage(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await saveReleaseSourcePreview(tester, key, 'network-${width.toInt()}');
        await tester.enterText(
          find.byType(TextField).first,
          'https://example.invalid/audit',
        );
        await http.runWithClient(() async {
          await tester.tap(find.text('发送请求'));
          await tester.pump();
          expect(requests, 1);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const MaterialApp(home: Scaffold()));
          expect(
            client.closes,
            1,
            reason: 'leaving closes the active client immediately',
          );
          response.complete(http.Response('synthetic', 200));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(
            client.closes,
            1,
            reason: 'completion must not close a disposed client twice',
          );
        }, () => client);
      },
    );
  }
}

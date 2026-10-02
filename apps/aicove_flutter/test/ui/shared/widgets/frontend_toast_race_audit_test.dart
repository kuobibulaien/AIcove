import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_toast.dart';
import '../../../helpers/release_source_preview.dart';

void main() {
  for (final width in [360.0, 1000.0]) {
    testWidgets(
      'old dismissible toast completion preserves newer notification width=$width',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 560);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await loadReleasePreviewFonts(tester);
        final key = GlobalKey();
        final save = Completer<void>();
        late BuildContext host;
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
              home: Builder(
                builder: (context) {
                  host = context;
                  return const Scaffold();
                },
              ),
            ),
          ),
        );
        MoeToast.showDismissible(
          host,
          'Old notice',
          noticeKey: 'audit',
          onDismissForever: () => save.future,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('不再提醒'));
        await tester.pump();
        MoeToast.show(
          host,
          'New notice',
          duration: const Duration(seconds: 10),
        );
        await tester.pumpAndSettle();
        expect(find.text('New notice'), findsOneWidget);
        save.complete();
        await tester.pumpAndSettle();
        final newerNoticeRemains = find
            .text('New notice')
            .evaluate()
            .isNotEmpty;
        await tester.pump(const Duration(seconds: 11));
        expect(tester.takeException(), isNull);
        expect(
          newerNoticeRemains,
          isTrue,
          reason:
              'completion belongs to the old notification, not the current one',
        );
        expect(
          find.text('New notice'),
          findsNothing,
          reason: 'The newer notification must still expire on its own timer.',
        );

        MoeToast.show(host, '新通知仍然保留', duration: const Duration(seconds: 10));
        await tester.pumpAndSettle();
        await saveReleaseSourcePreview(tester, key, 'toast-${width.toInt()}');
        await tester.pump(const Duration(seconds: 11));
        expect(tester.takeException(), isNull);
      },
    );
  }
}

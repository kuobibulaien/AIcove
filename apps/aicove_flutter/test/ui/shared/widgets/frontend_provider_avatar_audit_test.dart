import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../../helpers/release_source_preview.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/provider/provider_avatar.dart';

void main() {
  for (final name in [
    'audit-',
    '-audit',
    'audit-provider',
    '',
    '--',
    '  ',
    '𠮷-先生',
    'e\u0301-lab',
  ]) {
    testWidgets('provider avatar accepts display name "$name"', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ProviderAvatar(providerName: name)),
        ),
      );
      expect(tester.takeException(), isNull);
      if (name == '𠮷-先生') expect(find.text('𠮷先'), findsOneWidget);
      if (name == 'e\u0301-lab') expect(find.text('E\u0301L'), findsOneWidget);
    });
  }
  for (final width in [360.0, 1000.0]) {
    testWidgets('provider avatars render safely at width=$width', (
      tester,
    ) async {
      await loadReleasePreviewFonts(tester);
      tester.view.physicalSize = Size(width, 580);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              fontFamily: captureReleaseSourcePreview ? 'ReleasePreview' : null,
            ),
            home: Scaffold(
              appBar: AppBar(title: const Text('渠道头像')),
              body: ListView(
                children: [
                  for (final name in [
                    'audit-',
                    '-audit',
                    'audit-provider',
                    '--',
                    '𠮷-先生',
                    'e\u0301-lab',
                  ])
                    ListTile(
                      leading: ProviderAvatar(providerName: name),
                      title: Text(name),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await saveReleaseSourcePreview(tester, key, 'avatar-${width.toInt()}');
    });
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';

void main() {
  test('Lucide preserves code points and packaged font on Flutter 3.44', () {
    final icons = <IconData, int>{
      LucideIcons.activity: 0xf101,
      LucideIcons.messageCircle: 0xf3cd,
      LucideIcons.settings: 0xf4b9,
      LucideIcons.user: 0xf564,
    };
    for (final entry in icons.entries) {
      expect(entry.key.codePoint, entry.value);
      expect(entry.key.fontFamily, 'Lucide');
      expect(entry.key.fontPackage, 'lucide_icons');
      expect(entry.key.matchTextDirection, isFalse);
    }
  });

  testWidgets('Lucide icons compile and lay out in light and dark themes',
      (tester) async {
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(brightness: brightness),
        home: const Scaffold(
          body: Row(children: [
            Icon(LucideIcons.messageCircle),
            Icon(LucideIcons.user),
            Icon(LucideIcons.settings),
          ]),
        ),
      ));
      expect(find.byType(Icon), findsNWidgets(3));
      expect(tester.takeException(), isNull);
    }
  });
}

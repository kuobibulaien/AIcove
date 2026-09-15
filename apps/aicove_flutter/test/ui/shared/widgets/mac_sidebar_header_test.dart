import 'dart:io';

import 'package:aicove_flutter/src/ui/shared/widgets/desktop_window_frame.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/mac_sidebar_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final width in [280.0, 480.0]) {
    for (final scale in [1.2, 1.8]) {
      testWidgets('integrated Mac header at $width, scale $scale', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(Size(width, 500));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        var composed = false;
        var query = '';
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: DesktopWindowFrame(
              child: Scaffold(
                body: Column(
                  children: [
                    MacSidebarHeader(
                      title: '聊天',
                      searchQuery: '原搜索',
                      onCompose: () => composed = true,
                      onSearchChanged: (value) => query = value,
                    ),
                    const Expanded(
                      child: SizedBox.expand(key: ValueKey('body')),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        expect(tester.getTopLeft(find.byType(MacSidebarHeader)).dy, 0);
        expect(find.byType(MacWindowButtons), findsNothing);
        final title = tester.getRect(find.text('聊天'));
        expect(title.center.dx, closeTo(width / 2, .1));
        expect(title.left, greaterThan(84));
        expect(
          title.right,
          lessThan(tester.getRect(find.byTooltip('添加角色')).left),
        );
        await tester.tap(find.byTooltip('添加角色'));
        expect(composed, isTrue);
        expect(find.text('原搜索'), findsOneWidget);
        await tester.enterText(
          find.byKey(const ValueKey('mac-contact-search')),
          '纳西妲',
        );
        expect(query, '纳西妲');
        expect(tester.takeException(), isNull);
      }, skip: !Platform.isMacOS);
    }
  }
}

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/model_list_page.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/provider_detail_page.dart';
import 'package:aicove_flutter/src/ui/shared/animations/parallax_slide_page_route.dart';

class _Routes extends NavigatorObserver {
  final pushed = <Route<dynamic>>[];
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route);
  }
}

void main() {
  for (final width in [360.0, 1000.0]) {
    for (final gap in [160, 520]) {
      testWidgets('supplier tap transition causality width=$width gap=$gap', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        SharedPreferences.setMockInitialValues({
          'aicove.ui_models.v1': jsonEncode({
            'providers': [
              {
                'id': 'diagnostic',
                'displayName': 'Diagnostic supplier',
                'apiKeys': <String>[],
                'apiBaseUrl': 'https://example.invalid/v1',
                'enabled': true,
                'models': <String>[],
                'visible_models': <String>[],
                'hidden_models': <String>[],
                'capabilities': ['chat'],
                'custom_config': <String, dynamic>{},
              },
            ],
            'visible_models': <String>[],
            'default_chat_models': <String>[],
            'model_display_names': <String, String>{},
          }),
        });
        final nav = GlobalKey<NavigatorState>();
        final observer = _Routes();
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              navigatorKey: nav,
              navigatorObservers: [observer],
              onGenerateRoute: (_) =>
                  ParallaxSlidePageRoute<void>(page: const ModelListPage()),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Diagnostic supplier'));
        await tester.pumpAndSettle();
        expect(find.byType(ProviderDetailPage), findsOneWidget);
        final old = observer.pushed.last as PageRoute<dynamic>;
        bool popped = false, completed = false;
        old.popped.then((_) {
          popped = true;
        });
        old.completed.then((_) {
          completed = true;
        });
        nav.currentState!.pop();
        await tester.pump();
        await tester.pump(Duration(milliseconds: gap));
        expect(popped, isTrue);
        expect(completed, gap >= 500);
        final before = observer.pushed.length;
        await tester.tap(find.text('Diagnostic supplier').first);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 16));
        expect(observer.pushed.length, before + 1);
        await tester.pumpAndSettle();
        expect(find.byType(ProviderDetailPage), findsOneWidget);
        nav.currentState!.pop();
        await tester.pumpAndSettle();
        expect(find.byType(ModelListPage), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}

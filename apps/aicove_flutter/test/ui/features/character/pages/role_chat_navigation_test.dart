import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/ui/features/character/pages/role_card_page.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _Roles extends ConversationsNotifier {
  int writes = 0;
  @override
  Future<List<Conversation>> build() async => [
    Conversation(
      id: 'local-role',
      title: '本地角色',
      displayName: '本地角色',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    ),
  ];
  @override
  Future<void> setAll(List<Conversation> roles, {bool persist = true}) async {
    if (persist) writes++;
    state = AsyncData(roles);
  }
}

void main() {
  for (final width in [360.0, 1000.0]) {
    for (final id in ['local-role', 'preset_nahida']) {
      testWidgets(
        'avatar directly opens one chat and materializes presets $width / $id',
        (tester) async {
          await tester.binding.setSurfaceSize(Size(width, 850));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final roles = _Roles();
          final container = ProviderContainer(
            overrides: [conversationsProvider.overrideWith(() => roles)],
          );
          addTearDown(container.dispose);
          final navigator = GlobalKey<NavigatorState>();
          final observer = MoeDetailStackObserver();
          final router = GoRouter(
            routes: [
              ShellRoute(
                navigatorKey: navigator,
                observers: [observer],
                builder: (_, __, child) => MoeAdaptiveShell(
                  primary: const RoleCardPage(),
                  detail: child,
                  navigatorKey: navigator,
                  observer: observer,
                ),
                routes: [
                  GoRoute(
                    path: '/',
                    builder: (_, __) => const MoeWorkspacePlaceholder(),
                    routes: [
                      GoRoute(
                        path: 'chat/:id',
                        builder: (_, state) {
                          final role = state.extra! as Conversation;
                          return Scaffold(
                            body: Text(
                              'chat:${state.pathParameters['id']}:${role.id}',
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ],
          );
          addTearDown(router.dispose);
          addTearDown(observer.dispose);
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: MaterialApp.router(routerConfig: router),
            ),
          );
          await tester.pumpAndSettle();
          final row = find.byKey(ValueKey('role-directory-$id'));
          expect(row, findsOneWidget);
          await tester.tap(
            find.descendant(of: row, matching: find.byType(MoeAvatar)),
          );
          await tester.pumpAndSettle();
          expect(find.text('chat:$id:$id'), findsOneWidget);
          expect(container.read(activeConversationIdProvider), id);
          expect(
            container
                .read(conversationsProvider)
                .requireValue
                .where((role) => role.id == id),
            hasLength(1),
          );
          expect(roles.writes, id == 'local-role' ? 0 : 1);
          expect(find.text('角色展示'), findsNothing);
          expect(find.text('开始聊天'), findsNothing);
          await navigator.currentState!.maybePop();
          await tester.pumpAndSettle();
          expect(find.text('chat:$id:$id'), findsNothing);
          expect(row, findsOneWidget);
          await tester.tap(row);
          await tester.pumpAndSettle();
          expect(find.text('chat:$id:$id'), findsOneWidget);
          expect(roles.writes, id == 'local-role' ? 0 : 1);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }
}

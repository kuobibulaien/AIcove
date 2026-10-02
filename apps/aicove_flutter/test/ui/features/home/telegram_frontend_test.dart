import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_message_list.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/composer.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/desktop_window_frame.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/character_list_item.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/custom_bottom_nav.dart';
import 'package:aicove_flutter/src/features/chat/providers2.dart';
import 'package:aicove_flutter/src/ui/features/character/pages/contact_edit_page.dart';
import 'package:aicove_flutter/src/ui/features/chat/pages/chat_page.dart';
import 'package:aicove_flutter/src/ui/features/home/pages/main_page.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/model_list_page.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/settings_page.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/ui_settings_page.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/profile_page.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/chat_plugin_settings_page.dart';
import 'package:aicove_flutter/src/ui/features/debug/pages/debug_center_page.dart';
import 'package:aicove_flutter/src/ui/features/debug/pages/prompt_node_management_page.dart';
import 'package:aicove_flutter/src/ui/shared/animations/parallax_slide_page_route.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import '../../../../tool/chat_segmented_fixture.dart';

void main() {
  for (final width in [360.0, 1000.0]) {
    for (final scale in [1.0, 1.8]) {
      testWidgets('真实首页搜索、聊天、设置与角色入口 $width / $scale', (tester) async {
        rootBundle.clear();
        await tester.binding.setSurfaceSize(Size(width, 850));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final fixture = (await tester.runAsync(
          () => SegmentedChatFixture.create(historyCount: 4),
        ))!;
        await tester.runAsync(
          () => fixture.database
              .into(fixture.database.messages)
              .insert(
                db.MessagesCompanion.insert(
                  id: 'search-hit',
                  conversationId: fixture.conversation.id,
                  role: 'user',
                  content: '昨天一起喝的橘子汽水很好喝',
                  createdAt: DateTime.now().millisecondsSinceEpoch,
                ),
              ),
        );
        final navigator = GlobalKey<NavigatorState>();
        final observer = MoeDetailStackObserver();
        final router = GoRouter(
          routes: [
            ShellRoute(
              navigatorKey: navigator,
              observers: [observer],
              builder: (_, __, child) => MoeAdaptiveShell(
                primary: const MainPage(),
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
                      pageBuilder: (_, state) => ParallaxSlidePage(
                        dimPreviousPage: false,
                        key: state.pageKey,
                        child: ChatPage(
                          conversationId: fixture.conversation.id,
                          initialConversation: fixture.conversation,
                        ),
                      ),
                    ),
                    GoRoute(
                      path: 'contact/new',
                      pageBuilder: (_, state) => ParallaxSlidePage(
                        key: state.pageKey,
                        child: ContactEditPage(
                          conversation: fixture.conversation,
                          editMode: EditMode.create,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        );
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: fixture.container,
            child: MaterialApp.router(
              routerConfig: router,
              theme: ThemeData(
                extensions: [MoeColors.light(accentColor: moePrimary)],
              ),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final bottomNav = find.byType(CustomBottomNav);
        Finder navigationItem(String label) => find.descendant(
          of: bottomNav,
          matching: find.byWidgetPredicate(
            (widget) => widget is Semantics && widget.properties.label == label,
          ),
        );
        void expectPrimaryPage(String title) {
          expect(
            find.descendant(of: bottomNav, matching: find.byType(Text)),
            findsNothing,
          );
          expect(
            find.descendant(of: bottomNav, matching: find.byType(Icon)),
            findsNWidgets(3),
          );
          expect(
            find.descendant(
              of: find.byType(MoeAppBar),
              matching: find.text(title),
            ),
            findsOneWidget,
          );
          for (final label in ['聊天', '角色', '设置']) {
            final item = tester.widget<Semantics>(navigationItem(label));
            expect(item.properties.button, isTrue);
            expect(item.properties.selected, label == title);
            expect(
              tester.getSize(navigationItem(label)).height,
              greaterThanOrEqualTo(kMinInteractiveDimension),
            );
          }
        }

        expectPrimaryPage('聊天');
        expect(find.byType(CharacterListItem), findsOneWidget);
        expect(find.byType(MoeSearchField), findsNothing, reason: '聊天页不放搜索框');
        expect(find.text('全部聊天'), findsNothing);
        expect(find.text('未读'), findsNothing);
        await tester.tap(find.byType(CharacterListItem));
        await tester.pumpAndSettle();
        expect(find.byType(ChatPage), findsOneWidget);
        if (width < 900 && isDesktop) {
          final bar = tester.getRect(
            find.byKey(const ValueKey('workspace-compact-titlebar')),
          );
          expect(bar.bottom, telegramCompactTitleBarHeight);
          final back = tester.getRect(
            find.descendant(
              of: find.byType(ChatPage),
              matching: find.byType(BackButton),
            ),
          );
          expect(back.left, 12, reason: '返回按钮应从内容左侧开始，不再被原生窗口按钮挤到右边');
          expect(back.top, greaterThanOrEqualTo(bar.bottom));
        }
        expect(
          tester.getRect(find.byType(ChatPage)).left,
          width >= 900 ? telegramPrimaryWidth + telegramWorkspaceInset * 2 : 0,
        );
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('更多'));
        await tester.pumpAndSettle();
        const menuLabels = ['详情', '壁纸', '绘图风格', '酒馆预设', '清空历史记录', '删除该角色'];
        for (final label in menuLabels) {
          expect(find.text(label), findsOneWidget);
        }
        expect(find.text('多选'), findsNothing);
        expect(find.text('聊天设置'), findsNothing);
        expect(find.text('查找聊天记录'), findsNothing);
        expect(
          tester.getRect(find.text('详情')).left,
          greaterThanOrEqualTo(
            width >= 900
                ? telegramPrimaryWidth + telegramWorkspaceInset * 2
                : 0,
          ),
        );
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('详情'));
        await tester.pumpAndSettle();
        expect(find.byType(ContactEditPage), findsOneWidget);
        await navigator.currentState!.maybePop();
        await tester.pumpAndSettle();
        expect(find.byType(ChatPage), findsOneWidget);
        await tester.longPress(
          find.byKey(
            ValueKey('message_bubble_${fixture.conversation.messages.last.id}'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('多选'));
        await tester.pumpAndSettle();
        expect(find.text('已选 1 条消息'), findsOneWidget);
        expect(find.byType(Composer), findsNothing);
        final selection = tester
            .widget<ChatMessageList>(find.byType(ChatMessageList))
            .selection!;
        selection.toggle(fixture.conversation.messages.first.id);
        await tester.pumpAndSettle();
        expect(find.text('已选 2 条消息'), findsOneWidget);
        await tester.tap(find.byTooltip('删除'));
        await tester.pumpAndSettle();
        expect(find.textContaining('不影响原始历史'), findsOneWidget);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(selection.count, 2);
        await navigator.currentState!.maybePop();
        await tester.pumpAndSettle();
        expect(find.byType(ChatPage), findsOneWidget);
        expect(selection.active, isFalse);
        expect(find.byType(Composer), findsOneWidget);
        await tester.tap(find.byTooltip('更多'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('详情'));
        await tester.pumpAndSettle();
        expect(find.byType(ContactEditPage), findsOneWidget);
        await navigator.currentState!.maybePop();
        await tester.pumpAndSettle();
        expect(find.byType(ChatPage), findsOneWidget);
        await navigator.currentState!.maybePop();
        await tester.pumpAndSettle();
        await tester.tap(navigationItem('设置'));
        await tester.pumpAndSettle();
        expectPrimaryPage('设置');
        final rootEntries = find.descendant(
          of: find.byType(SettingsContent),
          matching: find.byType(MoeSettingsRow),
        );
        final rows = tester.widgetList<MoeSettingsRow>(rootEntries).toList();
        expect(rows.map((row) => row.label), [
          '模型',
          '通用',
          '插件',
          '调试',
        ]);
        expect(rows.every((row) => row.subtitle == null), isTrue);
        final profileAvatar = tester.getRect(
          find.descendant(
            of: find.byType(SettingsContent),
            matching: find.byType(MoeAvatar),
          ),
        );
        final firstIcon = tester.getRect(find.byWidget(rows.first.iconWidget!));
        expect(firstIcon.left, profileAvatar.left, reason: '列表图标与个人头像使用同一左边距');
        final arrows = find.descendant(
          of: find.byType(SettingsContent),
          matching: find.byIcon(Icons.chevron_right),
        );
        final arrowRight = tester.getRect(arrows.first).right;
        for (final arrow in arrows.evaluate()) {
          expect(
            tester.getRect(find.byWidget(arrow.widget)).right,
            closeTo(arrowRight, 0.01),
            reason: '个人卡片与列表箭头使用同一右边距',
          );
        }

        expect(
          find.descendant(
            of: find.byType(SettingsPage),
            matching: find.byType(MoeSearchField),
          ),
          findsNothing,
          reason: '只有角色页保留搜索框',
        );
        await tester.tap(find.text('编辑头像和名字'));
        await tester.pumpAndSettle();
        expect(find.byType(ProfilePage), findsOneWidget);
        await navigator.currentState!.maybePop();
        await tester.pumpAndSettle();
        expect(find.text('提示词节点'), findsNothing);
        expect(find.text('编辑头像和名字'), findsOneWidget);
        await tester.tap(find.text('模型'));
        await tester.pumpAndSettle();
        expect(find.byType(ModelListPage), findsOneWidget);
        expect(
          tester.getRect(find.byType(ModelListPage)).left,
          width >= 900 ? telegramPrimaryWidth + telegramWorkspaceInset * 2 : 0,
        );
        expect(tester.takeException(), isNull);
        await navigator.currentState!.maybePop();
        await tester.pumpAndSettle();

        await tester.tap(find.text('通用'));
        await tester.pumpAndSettle();
        expect(find.byType(UiSettingsPage), findsOneWidget);
        await tester.tap(find.text('个人资料'));
        await tester.pumpAndSettle();
        expect(find.byType(ProfilePage), findsOneWidget);
        await navigator.currentState!.maybePop();
        await tester.pumpAndSettle();
        expect(find.byType(UiSettingsPage), findsOneWidget);
        await navigator.currentState!.maybePop();
        await tester.pumpAndSettle();

        await tester.tap(find.text('插件'));
        await tester.pumpAndSettle();
        expect(find.byType(ChatPluginSettingsPage), findsOneWidget);
        await navigator.currentState!.maybePop();
        await tester.pumpAndSettle();

        await tester.tap(find.text('调试'));
        await tester.pumpAndSettle();
        expect(find.byType(DebugCenterPage), findsOneWidget);
        await tester.ensureVisible(find.text('提示词节点'));
        await tester.tap(find.text('提示词节点'));
        await tester.pump();
        // 实际资产从宿主文件系统读取，给测试的真实异步区留出完成机会。
        for (var attempt = 0; attempt < 50; attempt++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 20));
          if (find.byType(MoeLoadingIndicator).evaluate().isEmpty) break;
        }
        expect(find.byType(MoeLoadingIndicator), findsNothing);
        await tester.pumpAndSettle();
        expect(find.byType(PromptNodeManagementPage), findsOneWidget);
        expect(
          tester.getRect(find.byType(PromptNodeManagementPage)).left,
          width >= 900 ? telegramPrimaryWidth + telegramWorkspaceInset * 2 : 0,
        );
        await navigator.currentState!.maybePop();
        await tester.pumpAndSettle();
        expect(find.byType(DebugCenterPage), findsOneWidget);
        await tester.ensureVisible(find.text('同步与备份'));
        await tester.pumpAndSettle();
        expect(find.text('同步与备份').hitTestable(), findsOneWidget);
        await navigator.currentState!.maybePop();
        await tester.pumpAndSettle();
        expectPrimaryPage('设置');
        expect(tester.takeException(), isNull);

        await tester.tap(navigationItem('角色'));
        await tester.pumpAndSettle();
        expectPrimaryPage('角色');
        for (final removed in [
          '收藏的角色',
          '创建新角色',
          '我的角色',
          '收藏',
          '推荐角色',
          '查看角色资料',
        ]) {
          expect(find.text(removed), findsNothing);
        }
        await tester.runAsync(
          () => fixture.container
              .read(conversationsProvider.notifier)
              .updateConversationSettings(
                fixture.conversation.id,
                isFavorite: true,
              ),
        );
        await tester.pumpAndSettle();
        final roleRow = find.byKey(
          ValueKey('role-directory-${fixture.conversation.id}'),
        );
        expect(roleRow, findsOneWidget, reason: '收藏的角色仍只显示一行');
        final roleSearch = find.descendant(
          of: find.byType(MoeSearchField),
          matching: find.byType(TextField),
        );
        await tester.enterText(roleSearch, '不存在的角色');
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
        expect(find.text('没有找到角色或聊天记录'), findsOneWidget);
        expect(roleRow, findsNothing);
        await tester.enterText(roleSearch, '橘子汽水');
        await tester.pump(const Duration(milliseconds: 300));
        for (var i = 0; i < 5 && find.text('聊天记录').evaluate().isEmpty; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(find.text('聊天记录'), findsOneWidget);
        expect(roleRow, findsNothing, reason: '名字不匹配时不显示角色行');
        expect(
          find.byKey(const ValueKey('message-hit-search-hit')),
          findsOneWidget,
        );
        await tester.tap(find.byTooltip('清除搜索'));
        await tester.pumpAndSettle();
        expect(find.text('聊天记录'), findsNothing);
        expect(roleRow, findsOneWidget);
        await tester.tap(
          find.descendant(of: roleRow, matching: find.byType(MoeAvatar)),
        );
        await tester.runAsync(() async {});
        await tester.pumpAndSettle();
        expect(find.byType(ChatPage), findsOneWidget);
        expect(
          tester.getRect(find.byType(ChatPage)).left,
          width >= 900 ? telegramPrimaryWidth + telegramWorkspaceInset * 2 : 0,
        );
        await navigator.currentState!.maybePop();
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('创建角色'));
        await tester.pumpAndSettle();
        expect(find.byType(ContactEditPage), findsOneWidget);
        expect(
          tester.getRect(find.byType(ContactEditPage)).left,
          width >= 900 ? telegramPrimaryWidth + telegramWorkspaceInset * 2 : 0,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        router.dispose();
        observer.dispose();
        var disposed = false;
        final cleanup = fixture.dispose().then((_) => disposed = true);
        for (var attempt = 0; attempt < 100 && !disposed; attempt++) {
          await tester.pump(const Duration(milliseconds: 16));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
        }
        expect(disposed, isTrue, reason: '离场后异步缓存与数据库必须完成释放');
        await cleanup;
      });
    }
  }
}

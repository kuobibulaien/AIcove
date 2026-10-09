import 'package:aicove_flutter/src/ui/shared/animations/parallax_slide_page_route.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_adaptive_shell.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_app_bar.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/desktop_window_frame.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_floating_surface.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _Editor extends StatefulWidget {
  const _Editor({this.protected = false});
  final bool protected;
  @override
  State<_Editor> createState() => _EditorState();
}

class _EditorState extends State<_Editor> {
  final controller = TextEditingController();
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !widget.protected,
    child: Scaffold(
      appBar: const MoeDetailAppBar(title: '编辑详情'),
      body: Column(
        children: [
          TextField(key: const ValueKey('draft'), controller: controller),
          TextButton(
            onPressed: () => MoeWorkspace.open(
              context,
              const Scaffold(
                appBar: MoeDetailAppBar(title: '第三级'),
                body: Text('详情的子页'),
              ),
            ),
            child: const Text('打开第三级'),
          ),
        ],
      ),
    ),
  );
}

void main() {
  for (final width in [360.0, 420.0, 899.0, 900.0, 901.0, 1000.0, 1280.0]) {
    testWidgets('一级入口、三级退栈与缩放保留草稿 $width', (tester) async {
      await tester.binding.setSurfaceSize(Size(width, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final key = GlobalKey<NavigatorState>();
      final observer = MoeDetailStackObserver();
      final router = GoRouter(
        routes: [
          ShellRoute(
            navigatorKey: key,
            observers: [observer],
            builder: (context, state, child) => MoeAdaptiveShell(
              primary: Builder(
                builder: (context) => Scaffold(
                  body: Column(
                    children: [
                      const Text('一级列表'),
                      TextButton(
                        onPressed: () =>
                            MoeWorkspace.open(context, const _Editor()),
                        child: const Text('打开详情'),
                      ),
                    ],
                  ),
                ),
              ),
              detail: child,
              navigatorKey: key,
              observer: observer,
            ),
            routes: [
              GoRoute(
                path: '/',
                builder: (_, __) => const MoeWorkspacePlaceholder(),
              ),
            ],
          ),
        ],
      );
      await tester.pumpWidget(
        MaterialApp.router(
          routerConfig: router,
          theme: ThemeData(extensions: [MoeColors.light()]),
        ),
      );
      await tester.pumpAndSettle();
      final primary = tester.getRect(
        find.byKey(const ValueKey('workspace-primary')),
      );
      final topBar = isDesktop && width < 900
          ? telegramCompactTitleBarHeight
          : 0.0;
      expect(
        primary,
        width >= 900
            ? const Rect.fromLTWH(12, 12, 360, 776)
            : Rect.fromLTWH(0, topBar, width, 800 - topBar),
        reason: '宽屏一级界面必须作为四周留白的完整手机面板悬浮',
      );
      if (topBar > 0) {
        expect(
          tester.getRect(
            find.byKey(const ValueKey('workspace-compact-titlebar')),
          ),
          Rect.fromLTWH(0, 0, width, topBar),
        );
        expect(
          MoeWorkspace.ownsWindowControls(tester.element(find.text('一级列表'))),
          isFalse,
        );
      } else {
        expect(
          find.byKey(const ValueKey('workspace-compact-titlebar')),
          findsNothing,
        );
      }
      if (width >= 900) {
        final placeholder = tester.renderObject<RenderParagraph>(
          find.text('选择一个聊天，开始对话'),
        );
        expect(
          placeholder.text.style?.decoration,
          isNot(TextDecoration.underline),
          reason: '空白详情应继承主题文字，不能出现缺少 Material 时的黄色下划线',
        );
      }
      await tester.tap(find.text('打开详情'));
      await tester.pump();
      expect(
        ModalRoute.of(tester.element(find.byType(_Editor, skipOffstage: false)))!.animation!.value,
        width >= 900 ? 1 : 0,
        reason: '宽屏二级页硬切，窄屏保留进入动画',
      );
      await tester.pumpAndSettle();
      expect(find.text('编辑详情'), findsOneWidget);
      if (width >= 900) {
        final titleSurface = find.ancestor(
          of: find.text('编辑详情'),
          matching: find.byType(MoeFloatingSurface),
        );
        expect(
          tester.getRect(titleSurface.first).top,
          primary.top,
          reason: '宽屏右侧悬浮标题与左侧手机面板顶部留白一致',
        );
      }
      expect(
        find.byType(BackButton),
        width >= 900 ? findsNothing : findsOneWidget,
      );
      expect(
        tester.getRect(find.byType(_Editor)).left,
        width >= 900 ? telegramPrimaryWidth + telegramWorkspaceInset * 2 : 0,
      );
      if (width >= 900) {
        final primaryContext = tester.element(find.text('打开详情'));
        for (var i = 0; i < 3; i++) {
          MoeWorkspace.open(primaryContext, const _Editor());
        }
        await tester.pumpAndSettle();
        expect(
          find.byType(_Editor, skipOffstage: false),
          findsOneWidget,
          reason: '左侧同级入口不能积累成详情历史',
        );
      }
      await tester.enterText(find.byKey(const ValueKey('draft')), '未提交的草稿');
      final editorState = tester.state(find.byType(_Editor));
      for (final size in [
        const Size(1280, 800),
        const Size(360, 800),
        const Size(1000, 800),
      ]) {
        await tester.binding.setSurfaceSize(size);
        await tester.pumpAndSettle();
        expect(
          find.byType(BackButton),
          size.width >= 900 ? findsNothing : findsOneWidget,
        );
        expect(tester.state(find.byType(_Editor)), same(editorState));
        expect(find.text('未提交的草稿'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      await tester.tap(find.text('打开第三级'));
      await tester.pump();
      expect(
        ModalRoute.of(tester.element(find.text('详情的子页', skipOffstage: false)))!.animation!.value,
        0,
        reason: '进入下一级仍然使用动画',
      );
      await tester.pumpAndSettle();
      expect(find.byType(BackButton), findsOneWidget);
      expect(
        tester.getRect(find.text('详情的子页')).left,
        greaterThanOrEqualTo(360),
      );
      await key.currentState!.maybePop();
      await tester.pumpAndSettle();
      expect(find.text('未提交的草稿'), findsOneWidget);
      await tester.binding.setSurfaceSize(const Size(360, 800));
      await tester.pumpAndSettle();
      await key.currentState!.maybePop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(observer.hasDetail.value, isTrue, reason: '退出动画完成前不能卸载详情');
      await tester.pumpAndSettle();
      expect(observer.hasDetail.value, isFalse);
      await tester.tap(find.text('打开详情'));
      await tester.pumpAndSettle();
      expect(find.text('编辑详情'), findsOneWidget);
      expect(find.text('未提交的草稿'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      router.dispose();
      observer.dispose();
    });
  }

  testWidgets('真实 go_router 声明式聊天跳转与系统返回', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final key = GlobalKey<NavigatorState>();
    final observer = MoeDetailStackObserver();
    final router = GoRouter(
      routes: [
        ShellRoute(
          navigatorKey: key,
          observers: [observer],
          builder: (context, state, child) => MoeAdaptiveShell(
            primary: Builder(
              builder: (context) => Column(
                children: [
                  TextButton(
                    onPressed: () =>
                        MoeWorkspace.openLocation(context, '/chat/a'),
                    child: const Text('聊天 A'),
                  ),
                  TextButton(
                    onPressed: () =>
                        MoeWorkspace.openLocation(context, '/chat/b'),
                    child: const Text('聊天 B'),
                  ),
                ],
              ),
            ),
            detail: child,
            navigatorKey: key,
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
                    key: state.pageKey,
                    child: Scaffold(
                      appBar: const MoeDetailAppBar(title: '聊天详情'),
                      body: Text(state.pathParameters['id']!),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    await tester.tap(find.text('聊天 A'));
    await tester.pumpAndSettle();
    expect(find.text('聊天详情'), findsOneWidget);
    await tester.binding.setSurfaceSize(const Size(360, 700));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('聊天详情'), findsNothing);
    expect(find.text('聊天 A').hitTestable(), findsOneWidget);
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    await tester.pumpAndSettle();
    final primaryContext = tester.element(find.text('聊天 A'));
    await tester.tap(find.text('聊天 A'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('聊天 B'));
    await tester.pump();
    final chatRoute = ModalRoute.of(tester.element(find.text('b')))!;
    expect(chatRoute.animation!.value, 1, reason: '同级聊天首帧即完成切换');
    await tester.pump();
    expect(find.text('a', skipOffstage: false), findsNothing);
    expect(find.byType(BackButton), findsNothing);
    // A page-based chat followed by an imperative settings page is still a sibling.
    MoeWorkspace.open(primaryContext, const _Editor());
    await tester.pump();
    expect(ModalRoute.of(tester.element(find.byType(_Editor, skipOffstage: false)))!.animation!.value, 1);
    await tester.pumpAndSettle();
    expect(find.text('b', skipOffstage: false), findsNothing);
    expect(find.byType(BackButton), findsNothing);
    final detailContext = tester.element(find.byType(_Editor));
    MoeWorkspace.openLocation(detailContext, '/chat/a');
    await tester.pumpAndSettle();
    expect(
      find.byType(BackButton),
      findsOneWidget,
      reason: '从详情进入聊天是递进，必须能回到详情',
    );
    await key.currentState!.maybePop();
    await tester.pumpAndSettle();
    expect(find.byType(_Editor), findsOneWidget);
    expect(find.byType(BackButton), findsNothing);
    await tester.tap(find.text('聊天 B'));
    await tester.pumpAndSettle();
    expect(find.byType(_Editor, skipOffstage: false), findsNothing);
    expect(find.byType(BackButton), findsNothing);
    MoeWorkspace.open(
      primaryContext,
      Scaffold(
        appBar: MoeAppBar(
          title: '自定义返回',
          showBackButton: true,
          leading: IconButton(
            key: const ValueKey('custom-back'),
            icon: const Icon(Icons.arrow_back),
            onPressed: () => key.currentState!.maybePop(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('custom-back')), findsNothing);
    await tester.binding.setSurfaceSize(const Size(420, 700));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('custom-back')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('custom-back')));
    await tester.pumpAndSettle();
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    await tester.pumpAndSettle();
    MoeWorkspace.open(primaryContext, const _Editor(protected: true));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('draft')), '切换联系人也保留');
    final editor = tester.state(find.byType(_Editor));
    await tester.tap(find.text('聊天 A'));
    await tester.pumpAndSettle();
    expect(find.text('聊天详情'), findsNothing);
    await tester.tap(find.text('聊天 B'));
    await tester.pumpAndSettle();
    expect(find.text('b'), findsNothing);
    MoeWorkspace.open(primaryContext, const Scaffold(body: Text('另一个二级页')));
    await tester.pumpAndSettle();
    expect(find.text('另一个二级页'), findsNothing);
    expect(tester.state(find.byType(_Editor)), same(editor));
    expect(find.text('切换联系人也保留'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    router.dispose();
    observer.dispose();
  });

  testWidgets('浮层拖动保留一级草稿，背景贯穿窗口并跟随详情退栈', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final navigator = GlobalKey<NavigatorState>();
    final observer = MoeDetailStackObserver();
    final draft = TextEditingController();
    final router = GoRouter(
      routes: [
        ShellRoute(
          navigatorKey: navigator,
          observers: [observer],
          builder: (_, __, child) => MoeAdaptiveShell(
            primary: Scaffold(
              body: TextField(
                controller: draft,
                key: const ValueKey('primary-draft'),
              ),
            ),
            detail: child,
            navigatorKey: navigator,
            observer: observer,
          ),
          routes: [
            GoRoute(
              path: '/',
              builder: (_, __) => const MoeWorkspaceBackground(
                background: ColoredBox(
                  key: ValueKey('root-background'),
                  color: Colors.teal,
                ),
                child: Scaffold(
                  backgroundColor: Colors.transparent,
                  body: Text('背景页面'),
                ),
              ),
            ),
          ],
        ),
      ],
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byKey(const ValueKey('root-background'))),
      const Rect.fromLTWH(0, 0, 1000, 700),
    );
    final surface = tester.widget<ClipRRect>(
      find.byKey(const ValueKey('workspace-primary-surface')),
    );
    expect(surface.borderRadius, BorderRadius.circular(telegramPrimaryRadius));
    final primaryContext = tester.element(
      find.byKey(const ValueKey('primary-draft')),
    );
    expect(MediaQuery.sizeOf(primaryContext), const Size(360, 676));
    await tester.enterText(find.byKey(const ValueKey('primary-draft')), '保留搜索');
    final state = tester.state(find.byKey(const ValueKey('primary-draft')));
    await tester.drag(
      find.byKey(const ValueKey('workspace-resize-handle')),
      const Offset(50, 0),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byKey(const ValueKey('workspace-primary'))).width,
      410,
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('workspace-detail'))).left,
      434,
    );
    MoeWorkspace.open(
      primaryContext,
      const MoeWorkspaceBackground(
        background: ColoredBox(
          key: ValueKey('detail-background'),
          color: Colors.purple,
        ),
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: Text('详情内容'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('detail-background')), findsOneWidget);
    expect(
      tester.getRect(find.byKey(const ValueKey('detail-background'))),
      const Rect.fromLTWH(0, 0, 1000, 700),
    );
    expect(find.byKey(const ValueKey('root-background')), findsNothing);
    final detailContext = tester.element(find.text('详情内容'));
    expect(
      ModalRoute.of(detailContext)!.barrierColor,
      isNull,
      reason: '共享背景不能被详情路由的全页暗色遮罩切成两块',
    );
    showDialog<void>(
      context: detailContext,
      builder: (_) => const AlertDialog(title: Text('菜单覆盖')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('detail-background')), findsOneWidget);
    Navigator.of(detailContext, rootNavigator: true).pop();
    await tester.pumpAndSettle();
    await navigator.currentState!.maybePop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(
      find.byKey(const ValueKey('detail-background')),
      findsOneWidget,
      reason: '退出未完成时保留退出页背景',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('root-background')), findsOneWidget);
    for (final size in [const Size(360, 700), const Size(1000, 700)]) {
      await tester.binding.setSurfaceSize(size);
      await tester.pumpAndSettle();
      expect(
        tester.state(find.byKey(const ValueKey('primary-draft'))),
        same(state),
      );
      expect(draft.text, '保留搜索');
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    router.dispose();
    observer.dispose();
    draft.dispose();
  });
}

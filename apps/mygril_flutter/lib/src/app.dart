import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'core/theme/tokens.dart';
import 'features/chat/presentation/pages/main_page.dart';
import 'features/chat/presentation/pages/chat_page.dart';
import 'features/chat/presentation/pages/split_chat_page.dart';
import 'features/chat/presentation/pages/contact_edit_page.dart';
import 'features/chat/domain/conversation.dart';
import 'features/chat/data/auto_reply_service.dart';
import 'features/chat/providers2.dart';
import 'features/settings/app_settings.dart';

class MyApp extends ConsumerStatefulWidget {
  const MyApp({super.key});

  @override
  ConsumerState<MyApp> createState() => _MyAppState();
}

class _MyAppState extends ConsumerState<MyApp> with WidgetsBindingObserver {
  // GoRouter 只创建一次，避免设置变更时路由重置
  late final GoRouter _router = _createRouter();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      ref.read(chatActionsProvider).onAppBackground();
    }
  }

  /// 创建路由配置（只调用一次）
  GoRouter _createRouter() {
    return GoRouter(
      routes: [
        GoRoute(
          path: '/',
          pageBuilder: (context, state) {
            // 自适应：小屏显示主页（带底部导航），大屏双栏
            final width = MediaQuery.of(context).size.width;
            final child = width < layoutBreakpoint
                ? const MainPage()
                : const SplitChatPage();
            
            return CustomTransitionPage(
              key: state.pageKey,
              child: child,
              // 主页面被覆盖时的视差动画（参考鸿蒙NEXT风格）
              // 优化：使用专用 Transition widget，减少每帧对象创建
              transitionsBuilder: (context, animation, secondaryAnimation, child) {
                const curve = Curves.fastOutSlowIn;
                final curvedSecondary = CurvedAnimation(
                  parent: secondaryAnimation,
                  curve: curve,
                );
                
                final slideTween = Tween(
                  begin: Offset.zero,
                  end: const Offset(-0.08, 0.0),
                );
                
                // 底层页面 - 仅微幅左移，无遮罩
                return SlideTransition(
                  position: curvedSecondary.drive(slideTween),
                  child: child,
                );
              },
            );
          },
          routes: [
            GoRoute(
              path: 'chat/:id',
              pageBuilder: (context, state) {
                final id = state.pathParameters['id'];
                return CustomTransitionPage(
                  key: state.pageKey,
                  child: ChatPage(conversationId: id),
                  transitionDuration: const Duration(milliseconds: 400),
                  reverseTransitionDuration: const Duration(milliseconds: 350),
                  // 视差滑动动画：新页面从右边滑入覆盖，左侧带阴影
                  transitionsBuilder: (context, animation, secondaryAnimation, child) {
                    const curve = Curves.fastOutSlowIn;
                    
                    final slideIn = Tween(
                      begin: const Offset(1.0, 0.0),
                      end: Offset.zero,
                    ).chain(CurveTween(curve: curve));

                    return SlideTransition(
                      position: animation.drive(slideIn),
                      // 左侧阴影 - 增强层次感
                      child: DecoratedBox(
                        decoration: const BoxDecoration(
                          boxShadow: [
                            BoxShadow(
                              color: Color(0x33000000), // 20% 黑色
                              blurRadius: 16,
                              offset: Offset(-4, 0), // 向左偏移
                            ),
                          ],
                        ),
                        child: child,
                      ),
                    );
                  },
                );
              },
            ),
            GoRoute(
              path: 'contact/new',
              pageBuilder: (context, state) {
                // 创建临时空白对话对象
                final now = DateTime.now();
                final tempConv = Conversation(
                  id: 'temp',
                  title: '新角色',
                  displayName: '',
                  createdAt: now,
                  updatedAt: now,
                );
                return CustomTransitionPage(
                  key: state.pageKey,
                  child: ContactEditPage(conversation: tempConv, isNew: true),
                  transitionsBuilder: (context, animation, secondaryAnimation, child) {
                    const begin = Offset(1.0, 0.0);
                    const end = Offset.zero;
                    const curve = Curves.easeInOut;

                    var tween = Tween(begin: begin, end: end).chain(
                      CurveTween(curve: curve),
                    );

                    return SlideTransition(
                      position: animation.drive(tween),
                      child: child,
                    );
                  },
                );
              },
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(appSettingsProvider);
    // Initialize AutoReplyService to listen for triggers
    ref.watch(autoReplyServiceProvider);

    // 创建浅色主题
    final lightTheme = _buildTheme(isDark: false);

    // 创建暗色主题
    final darkTheme = _buildTheme(isDark: true);

    return settingsAsync.when(
      loading: () => MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: moeSurface,
          body: const Center(child: CircularProgressIndicator()),
        ),
      ),
      error: (_, __) => MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: moeSurface,
          body: const Center(child: Text('加载设置失败')),
        ),
      ),
      data: (settings) {
        // 根据设置决定主题模式
        final themeMode = settings.useSystemTheme
            ? ThemeMode.system
            : (settings.isDarkMode ? ThemeMode.dark : ThemeMode.light);

        return MaterialApp.router(
          debugShowCheckedModeBanner: false,
          title: 'MyGril',
          theme: lightTheme,
          darkTheme: darkTheme,
          themeMode: themeMode,
          routerConfig: _router,
        );
      },
    );
  }

  /// 构建主题（浅色或暗色）
  ThemeData _buildTheme({required bool isDark}) {
    // 基础文本主题
    final baseText = isDark ? ThemeData.dark().textTheme : ThemeData.light().textTheme;
    final boldText = baseText.copyWith(
      // 标题/显示类：更粗一点
      displayLarge: baseText.displayLarge?.copyWith(fontWeight: FontWeight.w700),
      displayMedium: baseText.displayMedium?.copyWith(fontWeight: FontWeight.w700),
      displaySmall: baseText.displaySmall?.copyWith(fontWeight: FontWeight.w700),
      headlineLarge: baseText.headlineLarge?.copyWith(fontWeight: FontWeight.w700),
      headlineMedium: baseText.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
      headlineSmall: baseText.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
      titleLarge: baseText.titleLarge?.copyWith(fontWeight: FontWeight.w700),
      titleMedium: baseText.titleMedium?.copyWith(fontWeight: FontWeight.w700),
      titleSmall: baseText.titleSmall?.copyWith(fontWeight: FontWeight.w700),
      // 正文/标签：半粗，兼顾易读与"圆体"观感（不引入外部字体，KISS）
      bodyLarge: baseText.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
      bodyMedium: baseText.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
      bodySmall: baseText.bodySmall?.copyWith(fontWeight: FontWeight.w600),
      labelLarge: baseText.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      labelMedium: baseText.labelMedium?.copyWith(fontWeight: FontWeight.w600),
      labelSmall: baseText.labelSmall?.copyWith(fontWeight: FontWeight.w600),
    );

    return ThemeData(
      colorScheme: isDark ? moeTalkColorSchemeDark : moeTalkColorScheme,
      useMaterial3: true,
      scaffoldBackgroundColor: isDark ? moeSurfaceDark : moeSurface,
      // 跨平台字体回退栈（Web 优先使用 Noto Sans SC，已在 index.html 预加载）
      fontFamilyFallback: const [
        // 首选：Google Fonts 中文字体（Web 平台必需）
        'Noto Sans SC',
        // Apple 平台
        'SF Pro Rounded', 'SF Pro Text', 'SF Pro Display', 'PingFang SC', 'Hiragino Sans GB',
        // Windows
        'Segoe UI', 'Microsoft YaHei',
        // Android/Linux
        'Roboto',
      ],
      textTheme: boldText,
      // 全局分割线样式：1px 细线、无额外上下留白（颜色更柔和）
      dividerTheme: DividerThemeData(
        color: isDark ? moeDividerColorDark : moeDividerColor,
        thickness: borderWidth,
        space: 0,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: isDark ? moeSurfaceDark : moeHeaderPink,
        foregroundColor: isDark ? moeTextDark : moeHeaderContentLight,
        elevation: 0,
        titleTextStyle: boldText.titleLarge?.copyWith(
          color: isDark ? moeTextDark : moeHeaderContentLight,
        ),
      ),
      // 添加自定义主题扩展
      extensions: <ThemeExtension<dynamic>>[
        isDark ? MoeColors.dark : MoeColors.light,
      ],
    );
  }
}

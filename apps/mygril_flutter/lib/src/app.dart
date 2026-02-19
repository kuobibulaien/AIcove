import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'ui/theme/tokens.dart';
import 'ui/shared/widgets/desktop_window_frame.dart';
import 'ui/features/home/pages/main_page.dart';
import 'ui/features/chat/pages/chat_page.dart';
import 'ui/features/chat/pages/split_chat_page.dart';
import 'ui/features/character/pages/contact_edit_page.dart';
import 'core/models/message_block.dart';
import 'core/utils/image_preheat_queue.dart';
import 'core/utils/svg_preheat.dart';
import 'core/log_history_service.dart';
import 'core/app_logger.dart';
import 'core/api_logger.dart';
import 'features/chat/domain/conversation.dart';
import 'features/chat/data/auto_reply_service.dart';
import 'features/chat/providers2.dart';
import 'features/chat/services/tts_fallback_notification.dart';
import 'features/settings/app_settings.dart';
import 'ui/theme/accent_color_provider.dart';

class MyApp extends ConsumerStatefulWidget {
  const MyApp({super.key});

  @override
  ConsumerState<MyApp> createState() => _MyAppState();
}

class _MyAppState extends ConsumerState<MyApp> with WidgetsBindingObserver {
  // GoRouter 只创建一次，避免设置变更时路由重置
  late final GoRouter _router = _createRouter();

  // App 启动/恢复时的“预热重试”定时器（当会话列表还没加载出来时使用）
  Timer? _recentConversationsWarmupRetryTimer;
  bool _recentConversationsWarmupPending = false;
  bool _recentConversationsWarmupScheduled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // 初始化日志系统（从文件加载当天日志）
    _initializeLoggers();

    // App 启动后，尽早预热"最近会话"的图片（避免用户一打开就点进聊天导致闪烁）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _requestRecentConversationsWarmup();
      // 预热供应商 SVG 图标
      preheatProviderSvgIcons();
      // 清理过期日志（7天前的）
      _cleanExpiredLogs();
    });
  }

  /// 初始化日志系统
  Future<void> _initializeLoggers() async {
    try {
      await AppLogger.initialize();
      await ApiLogger.initialize();
      AppLogger.info('App', '日志系统初始化完成');
    } catch (e) {
      // 日志初始化失败不影响主流程
    }
  }

  @override
  void dispose() {
    _recentConversationsWarmupRetryTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      ref.read(chatActionsProvider).onAppBackground();
      // 日志已改为实时存储，无需在后台保存
    }
    if (state == AppLifecycleState.resumed) {
      // 从后台恢复时，内存 ImageCache 可能已被系统回收；提前把"最近会话"的图片重新解码进缓存，
      // 让用户点进聊天页时尽量不出现"占位→图片跳出来"的闪一下。
      _requestRecentConversationsWarmup();
    }
  }

  void _requestRecentConversationsWarmup() {
    _recentConversationsWarmupPending = true;
    _recentConversationsWarmupRetryTimer?.cancel();
    _scheduleRecentConversationsWarmup();
  }

  void _scheduleRecentConversationsWarmup() {
    if (_recentConversationsWarmupScheduled) return;
    _recentConversationsWarmupScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _recentConversationsWarmupScheduled = false;
      if (!mounted) return;
      _tryWarmupRecentConversations();
    });
  }

  void _tryWarmupRecentConversations() {
    if (!_recentConversationsWarmupPending) return;

    final listAsync = ref.read(conversationsProvider);
    final list = listAsync.valueOrNull;
    if (list == null) {
      // 会话列表还在加载（或出错），稍后重试；避免在这里 watch 导致整棵树频繁重建。
      if (listAsync.hasError) {
        _recentConversationsWarmupPending = false;
        return;
      }
      _recentConversationsWarmupRetryTimer?.cancel();
      _recentConversationsWarmupRetryTimer = Timer(
        const Duration(milliseconds: 220),
        () {
          if (!mounted) return;
          _scheduleRecentConversationsWarmup();
        },
      );
      return;
    }

    _recentConversationsWarmupPending = false;

    // 方案B：预热“最近 3 个会话”的最后 10 条消息相关图片（头像/图片/表情）。
    const recentConversationCount = 3;
    const maxMessagesToScan = 10;
    const maxImagesToCache = 24;

    final sorted = [...list]..sort(
        (a, b) => _conversationRecency(b).compareTo(_conversationRecency(a)));
    final targets = sorted.take(recentConversationCount).toList();
    if (targets.isEmpty) return;

    final queue = ref.read(imagePreheatQueueProvider);
    final configuration = createLocalImageConfiguration(context);

    for (final conv in targets) {
      final providers = _collectConversationPreviewProviders(
        conv,
        maxMessagesToScan: maxMessagesToScan,
        maxImagesToCache: maxImagesToCache,
      );
      queue.enqueueAll(
        providers,
        configuration,
        priority: ImagePreheatPriority.high,
      );
    }
  }

  DateTime _conversationRecency(Conversation c) {
    return c.lastMessageTime ?? c.updatedAt;
  }

  /// 清理过期日志（启动时调用）
  Future<void> _cleanExpiredLogs() async {
    try {
      final cleanedCount = await LogHistoryService.cleanExpiredLogs();
      if (cleanedCount > 0) {
        AppLogger.info('App', '已清理 $cleanedCount 个过期日志文件');
      }
    } catch (e) {
      AppLogger.warning('App', '日志清理失败', metadata: {'error': e.toString()});
    }
  }

  List<ImageProvider> _collectConversationPreviewProviders(
    Conversation conv, {
    required int maxMessagesToScan,
    required int maxImagesToCache,
  }) {
    final images = <ImageProvider>[];

    void addAvatar(String? raw) {
      final url = raw?.trim();
      if (url == null || url.isEmpty) return;

      final isNetwork = url.startsWith('http://') || url.startsWith('https://');
      final isAsset = url.startsWith('assets/') || url.startsWith('packages/');
      if (isNetwork) {
        images.add(CachedNetworkImageProvider(url));
      } else if (isAsset) {
        images.add(AssetImage(url));
      }
    }

    addAvatar(conv.avatarUrl);
    addAvatar(conv.characterImage);

    final messages = conv.messages;
    final start = messages.length > maxMessagesToScan
        ? messages.length - maxMessagesToScan
        : 0;

    for (var i = start;
        i < messages.length && images.length < maxImagesToCache;
        i++) {
      final blocks = messages[i].blocks;
      if (blocks == null) continue;

      for (final block in blocks) {
        if (images.length >= maxImagesToCache) break;

        if (block is ImageBlock) {
          final url = block.url?.trim();
          final localPath = block.localPath?.trim();

          if (url != null && url.isNotEmpty) {
            images.add(CachedNetworkImageProvider(url));
          } else if (localPath != null && localPath.isNotEmpty) {
            images.add(FileImage(File(localPath)));
          }
        } else if (block is EmojiBlock) {
          final path = block.path.trim();
          if (path.isEmpty) continue;

          final isNetwork =
              path.startsWith('http://') || path.startsWith('https://');
          final isAsset =
              path.startsWith('assets/') || path.startsWith('packages/');
          if (isNetwork) {
            images.add(CachedNetworkImageProvider(path));
          } else if (isAsset) {
            images.add(AssetImage(path));
          } else {
            images.add(FileImage(File(path)));
          }
        }
      }
    }

    return images;
  }

  /// 创建路由配置（只调用一次）
  GoRouter _createRouter() {
    return GoRouter(
      routes: [
        GoRoute(
          path: '/',
          pageBuilder: (context, state) {
            // 自适应：小屏显示主页（带底部导航），大屏双栏
            final width = MediaQuery.sizeOf(context).width;
            final child = width < layoutBreakpoint
                ? const MainPage()
                : const SplitChatPage();

            return CustomTransitionPage(
              key: state.pageKey,
              child: child,
              // 主页面被覆盖时的视差动画（参考鸿蒙NEXT风格）
              // 优化：使用专用 Transition widget，减少每帧对象创建
              transitionsBuilder:
                  (context, animation, secondaryAnimation, child) {
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
                final initialConversation = state.extra is Conversation
                    ? state.extra as Conversation
                    : null;
                return CustomTransitionPage(
                  key: state.pageKey,
                  child: ChatPage(
                      conversationId: id,
                      initialConversation: initialConversation),
                  transitionDuration: kAnimPage,
                  reverseTransitionDuration: kAnimPageReverse,
                  // 视差滑动动画：新页面从右边滑入覆盖，左侧带阴影
                  transitionsBuilder:
                      (context, animation, secondaryAnimation, child) {
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
                  child: ContactEditPage(
                      conversation: tempConv, editMode: EditMode.create),
                  transitionsBuilder:
                      (context, animation, secondaryAnimation, child) {
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
    final accentColor = ref.watch(accentColorProvider);
    // Initialize AutoReplyService to listen for triggers
    ref.watch(autoReplyServiceProvider);

    // 创建浅色主题
    final lightTheme = _buildTheme(isDark: false, accent: accentColor);

    // 创建暗色主题
    final darkTheme = _buildTheme(isDark: true, accent: accentColor);

    return settingsAsync.when(
      loading: () => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: lightTheme,
        darkTheme: darkTheme,
        themeMode: ThemeMode.system,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: const [
          Locale('zh', 'CN'),
          Locale('en', 'US'),
        ],
        locale: const Locale('zh', 'CN'),
        home: const Scaffold(
          body: Center(child: CircularProgressIndicator()),
        ),
      ),
      error: (_, __) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: lightTheme,
        darkTheme: darkTheme,
        themeMode: ThemeMode.system,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: const [
          Locale('zh', 'CN'),
          Locale('en', 'US'),
        ],
        locale: const Locale('zh', 'CN'),
        home: const Scaffold(
          body: Center(child: Text('加载设置失败')),
        ),
      ),
      data: (settings) {
        // 根据设置决定主题模式
        final themeMode = settings.useSystemTheme
            ? ThemeMode.system
            : (settings.isDarkMode ? ThemeMode.dark : ThemeMode.light);

        return TtsFallbackNotificationListener(
          child: MaterialApp.router(
            debugShowCheckedModeBanner: false,
            title: 'AIcove',
            theme: lightTheme,
            darkTheme: darkTheme,
            themeMode: themeMode,
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: const [
              Locale('zh', 'CN'),
              Locale('en', 'US'),
            ],
            locale: const Locale('zh', 'CN'),
            routerConfig: _router,
            // 桌面端包裹自定义标题栏
            builder: (context, child) {
              // 将设置页的 1.0 映射为历史默认观感（约 1.2x）
              const baselineScale = 1.2;
              final scale =
                  settings.textScaleFactor.clamp(0.8, 1.5) * baselineScale;
              return MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(scale),
                ),
                child:
                    DesktopWindowFrame(child: child ?? const SizedBox.shrink()),
              );
            },
          ),
        );
      },
    );
  }

  /// 构建主题（浅色或暗色）
  ThemeData _buildTheme({required bool isDark, required Color accent}) {
    // Material3 的默认组件（ElevatedButton、Switch、ProgressIndicator 等）主要跟随 colorScheme.primary。
    // 这里用用户选择的主题色作为 seed/primary，避免"主题粉色但按钮仍是蓝色"的割裂感。
    final seed = accent;
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: isDark ? Brightness.dark : Brightness.light,
      primary: seed,
      // MoeTalk 仍然用自定义 surface/onSurface 来保持整体灰阶风格一致
      surface: isDark ? moePanelDark : moePanel,
      onSurface: isDark ? moeTextDark : moeText,
    );

    // 基础文本主题
    final baseText =
        isDark ? ThemeData.dark().textTheme : ThemeData.light().textTheme;
    final boldText = baseText.copyWith(
      // 标题/显示类：统一使用 MoeFontWeights.emphasis
      displayLarge:
          baseText.displayLarge?.copyWith(fontWeight: MoeFontWeights.emphasis),
      displayMedium:
          baseText.displayMedium?.copyWith(fontWeight: MoeFontWeights.emphasis),
      displaySmall:
          baseText.displaySmall?.copyWith(fontWeight: MoeFontWeights.emphasis),
      headlineLarge:
          baseText.headlineLarge?.copyWith(fontWeight: MoeFontWeights.emphasis),
      headlineMedium: baseText.headlineMedium
          ?.copyWith(fontWeight: MoeFontWeights.emphasis),
      headlineSmall:
          baseText.headlineSmall?.copyWith(fontWeight: MoeFontWeights.emphasis),
      titleLarge:
          baseText.titleLarge?.copyWith(fontWeight: MoeFontWeights.emphasis),
      titleMedium:
          baseText.titleMedium?.copyWith(fontWeight: MoeFontWeights.emphasis),
      titleSmall:
          baseText.titleSmall?.copyWith(fontWeight: MoeFontWeights.emphasis),
      // 正文/标签：同样使用 emphasis，保持一致
      bodyLarge:
          baseText.bodyLarge?.copyWith(fontWeight: MoeFontWeights.emphasis),
      bodyMedium:
          baseText.bodyMedium?.copyWith(fontWeight: MoeFontWeights.emphasis),
      bodySmall:
          baseText.bodySmall?.copyWith(fontWeight: MoeFontWeights.emphasis),
      labelLarge:
          baseText.labelLarge?.copyWith(fontWeight: MoeFontWeights.emphasis),
      labelMedium:
          baseText.labelMedium?.copyWith(fontWeight: MoeFontWeights.emphasis),
      labelSmall:
          baseText.labelSmall?.copyWith(fontWeight: MoeFontWeights.emphasis),
    );

    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      scaffoldBackgroundColor: isDark ? moeSurfaceDark : moeSurface,
      // 跨平台字体回退栈（Web 优先使用 Noto Sans SC，已在 index.html 预加载）
      fontFamilyFallback: const [
        // 首选：Google Fonts 中文字体（Web 平台必需）
        'Noto Sans SC',
        // Apple 平台
        'SF Pro Rounded', 'SF Pro Text', 'SF Pro Display', 'PingFang SC',
        'Hiragino Sans GB',
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
        backgroundColor: accent,
        foregroundColor: isDark ? moeTextDark : moeHeaderContentLight,
        elevation: 0,
        // 统一去掉标题左侧的默认空白：避免返回按钮和标题之间出现“多出来的一段间距”。
        // 个别页面需要特殊间距时，可在该页面的 AppBar 里单独覆盖 titleSpacing。
        titleSpacing: 0,
        titleTextStyle: boldText.titleLarge?.copyWith(
          color: isDark ? moeTextDark : moeHeaderContentLight,
        ),
      ),
      // 全局底部弹窗主题：减少视觉复杂度
      bottomSheetTheme: const BottomSheetThemeData(
        elevation: 0,
        modalElevation: 0,
      ),
      // 添加自定义主题扩展（使用当前主题色）
      extensions: <ThemeExtension<dynamic>>[
        isDark
            ? MoeColors.dark(accentColor: accent)
            : MoeColors.light(accentColor: accent),
      ],
    );
  }
}

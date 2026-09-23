import 'dart:async';
import 'features/sync/providers/cloud_sync_provider.dart';

import 'package:aicove_flutter/src/ui/theme/moe_interaction_theme.dart';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'ui/theme/tokens.dart';
import 'ui/shared/animations/parallax_slide_page_route.dart';
import 'ui/shared/widgets/desktop_window_frame.dart';
import 'ui/features/home/pages/main_page.dart';
import 'ui/features/chat/pages/chat_page.dart';
import 'ui/shared/widgets/moe_adaptive_shell.dart';
import 'ui/features/character/pages/contact_edit_page.dart';
import 'core/utils/blurred_background_service.dart';
import 'core/utils/image_preheat_queue.dart';
import 'core/utils/svg_preheat.dart';
import 'core/log_history_service.dart';
import 'core/services/android_keep_alive_manager.dart';
import 'core/app_logger.dart';
import 'core/api_logger.dart';
import 'features/observability/trace_store.dart';
import 'features/chat/domain/conversation.dart';
import 'features/auto_reply/data/analyzer_scheduler.dart';
import 'features/auto_reply/data/auto_reply_service.dart';
import 'features/auto_reply/data/background_message_reprocessor.dart';
import 'features/chat/providers2.dart';
import 'features/chat/services/tts_fallback_notification.dart';
import 'features/settings/app_settings.dart';
import 'ui/theme/accent_color_provider.dart';
import 'features/memory/providers/memory_providers.dart';

class MyApp extends ConsumerStatefulWidget {
  const MyApp({super.key});

  @override
  ConsumerState<MyApp> createState() => _MyAppState();
}

class _MyAppState extends ConsumerState<MyApp> with WidgetsBindingObserver {
  // GoRouter 只创建一次，避免设置变更时路由重置
  final _detailNavigatorKey = GlobalKey<NavigatorState>();
  final _detailObserver = MoeDetailStackObserver();
  late final GoRouter _router = _createRouter();

  // App 启动/恢复时的“预热重试”定时器（当会话列表还没加载出来时使用）
  Timer? _recentConversationsWarmupRetryTimer;
  bool _recentConversationsWarmupPending = false;
  bool _recentConversationsWarmupScheduled = false;
  bool _blurMigrationRunning = false;
  bool _keepAliveSyncInFlight = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // 初始化日志系统（从文件加载当天日志）
    _initializeLoggers();
    unawaited(BlurredBackgroundService.init());

    // App 启动后，尽早预热"最近会话"的图片（避免用户一打开就点进聊天导致闪烁）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(cloudSyncProvider);
      unawaited(_retireLegacyMemory());
      _requestRecentConversationsWarmup();
      unawaited(_syncAndroidKeepAliveGuard());
      // 预热供应商 SVG 图标
      preheatProviderSvgIcons();
      // 清理过期日志（7天前的）
      _cleanExpiredLogs();
    });
  }

  /// 旧记忆数据先备份再退役（ADR0038）；失败只记日志，下次启动重试。
  Future<void> _retireLegacyMemory() async {
    try {
      await ref.read(legacyMemoryRetirementProvider).run();
    } catch (error) {
      AppLogger.warning(
        'LegacyMemoryRetirement',
        '旧记忆数据退役失败，下次启动重试',
        metadata: {'error': error.toString()},
      );
    }
  }

  /// 初始化日志系统
  Future<void> _initializeLoggers() async {
    try {
      await AppLogger.initialize();
      await ApiLogger.initialize();
      await TraceStore.instance.initialize();
      AppLogger.info('App', '日志系统初始化完成');
    } catch (e) {
      // 日志初始化失败不影响主流程
    }
  }

  @override
  void dispose() {
    _recentConversationsWarmupRetryTimer?.cancel();
    _router.dispose();
    _detailObserver.dispose();
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
      unawaited(ref.read(cloudSyncProvider.notifier).synchronize());
      // 从后台恢复时，内存 ImageCache 可能已被系统回收；提前把"最近会话"的图片重新解码进缓存，
      // 让用户点进聊天页时尽量不出现"占位→图片跳出来"的闪一下。
      _requestRecentConversationsWarmup();
      unawaited(_syncAndroidKeepAliveGuard());
      unawaited(ref.read(analyzerSchedulerProvider).onAppResumed());
      // 后台投递的多模态消息在回前台时补跑插件链
      unawaited(ref
          .read(backgroundMessageReprocessorProvider)
          .reprocessRecentBackgroundMessages());
    }
  }

  Future<void> _syncAndroidKeepAliveGuard() async {
    if (_keepAliveSyncInFlight || !AndroidKeepAliveManager.isSupported) {
      return;
    }

    _keepAliveSyncInFlight = true;
    try {
      final settings = await ref.read(appSettingsProvider.future);
      await AndroidKeepAliveManager.syncWithAutoReplySettings(
        settings.autoReplySettings,
      );
    } catch (_) {
      // 守护模式同步失败不影响主流程
    } finally {
      _keepAliveSyncInFlight = false;
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

    // 启动预热策略：
    // 1) 联系人列表：继续只预热头像，保证主列表滚动稳定。
    // 2) 聊天页：后台预热最近会话的内存热缓存，进入页只消费尾部窗口。
    const contactsAvatarWarmupCount = 12;

    final sorted = [...list]..sort(
        (a, b) => _conversationRecency(b).compareTo(_conversationRecency(a)));
    if (sorted.isEmpty) return;

    final queue = ref.read(imagePreheatQueueProvider);
    final configuration = createLocalImageConfiguration(context);

    // 预热联系人列表头像（主界面）
    for (final conv in sorted.take(contactsAvatarWarmupCount)) {
      final avatarProviders = _collectConversationAvatarProviders(conv);
      if (avatarProviders.isEmpty) continue;
      queue.enqueueAll(
        avatarProviders,
        configuration,
        priority: ImagePreheatPriority.normal,
      );
    }
    unawaited(_migrateConversationBlurBackgrounds(sorted));
  }

  Future<void> _migrateConversationBlurBackgrounds(
    List<Conversation> conversations,
  ) async {
    if (_blurMigrationRunning) return;
    _blurMigrationRunning = true;

    try {
      await BlurredBackgroundService.init();
      final pendingSources = <String>[];
      final seen = <String>{};

      for (final conv in conversations) {
        final source = BlurredBackgroundService.pickPreferredSource(
          characterImage: conv.characterImage,
          avatarUrl: conv.avatarUrl,
        );
        if (!BlurredBackgroundService.shouldPreGenerateEagerly(source)) {
          continue;
        }
        if (source == null || !seen.add(source)) continue;
        if (BlurredBackgroundService.hasBlur(source)) continue;
        pendingSources.add(source);
      }

      var nextIndex = 0;

      Future<void> worker() async {
        while (nextIndex < pendingSources.length) {
          final source = pendingSources[nextIndex++];
          await BlurredBackgroundService.ensureBlur(
            source,
            allowNetwork: false,
          );
          await Future<void>.delayed(Duration.zero);
        }
      }

      await Future.wait([
        worker(),
        worker(),
      ]);
    } finally {
      _blurMigrationRunning = false;
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

  String _stripPathFragment(String path) {
    final hashIndex = path.indexOf('#');
    if (hashIndex < 0) return path;
    return path.substring(0, hashIndex);
  }

  List<ImageProvider> _collectConversationAvatarProviders(Conversation conv) {
    final images = <ImageProvider>[];

    void addAvatar(String? raw) {
      final rawUrl = raw?.trim();
      if (rawUrl == null || rawUrl.isEmpty) return;

      final isNetwork =
          rawUrl.startsWith('http://') || rawUrl.startsWith('https://');
      if (isNetwork) {
        images.add(CachedNetworkImageProvider(rawUrl));
        return;
      }

      final url = _stripPathFragment(rawUrl);
      if (url.isEmpty) return;
      final isAsset = url.startsWith('assets/') || url.startsWith('packages/');
      if (isAsset) {
        images.add(AssetImage(url));
      }
    }

    addAvatar(conv.avatarUrl);
    addAvatar(conv.characterImage);
    return images;
  }

  /// 创建路由配置（只调用一次）
  GoRouter _createRouter() {
    return GoRouter(
      routes: [
        ShellRoute(
          navigatorKey: _detailNavigatorKey,
          observers: [_detailObserver],
          builder: (context, state, child) => MoeAdaptiveShell(
            navigatorKey: _detailNavigatorKey,
            observer: _detailObserver,
            primary: const MainPage(),
            detail: child,
          ),
          routes: [
            GoRoute(
              path: '/',
              pageBuilder: (context, state) => NoTransitionPage(
                key: state.pageKey,
                child: const MoeWorkspacePlaceholder(),
              ),
              routes: [
                GoRoute(
                  path: 'chat/:id',
                  pageBuilder: (context, state) {
                    final id = state.pathParameters['id'];
                    final initialConversation = state.extra is Conversation
                        ? state.extra as Conversation
                        : null;
                    return ParallaxSlidePage(
                      dimPreviousPage: false,
                      key: state.pageKey,
                      child: ChatPage(
                          conversationId: id,
                          initialConversation: initialConversation),
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
                    return ParallaxSlidePage(
                      key: state.pageKey,
                      child: ContactEditPage(
                          conversation: tempConv, editMode: EditMode.create),
                    );
                  },
                ),
              ],
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
    ref.watch(analyzerSchedulerProvider);
    // Initialize AutoReplyService to listen for triggers
    ref.watch(autoReplyServiceProvider);

    // 创建浅色主题
    final lightTheme = _buildTheme(isDark: false, accent: accentColor);

    // 暗色主题强调色由皮肤决定（默认金色）
    final darkAccent = ref.watch(darkAccentColorProvider);
    final darkTheme = _buildTheme(isDark: true, accent: darkAccent);

    return MoeLiquidGlassService.wrapApp(
      child: settingsAsync.when(
        loading: () => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: withMoeInteractionTheme(lightTheme),
        darkTheme: withMoeInteractionTheme(darkTheme),
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
        theme: withMoeInteractionTheme(lightTheme),
        darkTheme: withMoeInteractionTheme(darkTheme),
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
            theme: withMoeInteractionTheme(lightTheme),
            darkTheme: withMoeInteractionTheme(darkTheme),
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
            onNavigationNotification: moeNavigationNotification(_router),
            // 桌面端包裹自定义标题栏
            builder: (context, child) {
              // 用户字号缩放直接作用于统一的基础排版。
              const baselineScale = 1.0;
              final textScale = settings.textScaleFactor
                      .clamp(kMinTextScaleFactor, kMaxTextScaleFactor)
                      .toDouble() *
                  baselineScale;
              final uiScale = settings.uiScaleFactor
                  .clamp(kMinUiScaleFactor, kMaxUiScaleFactor)
                  .toDouble();
              return MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(textScale),
                ),
                child: MoeGlassTheme(
                  enabled: settings.glassEffectEnabled,
                  blurSigma: settings.glassBlurSigma
                      .clamp(kMinGlassBlurSigma, kMaxGlassBlurSigma)
                      .toDouble(),
                  useLiquidGlass: settings.useLiquidGlass,
                  child: DesktopWindowFrame(
                    windowControlsOnRight: settings.windowsWindowControlsSide ==
                        WindowControlButtonSide.right,
                    child: _GlobalUiScale(
                      scale: uiScale,
                      child: TooltipVisibility(
                        visible: false,
                        child: child ?? const SizedBox.shrink(),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
    ),
  );
  }

  /// 构建主题（浅色或暗色）
  ThemeData _buildTheme(
      {required bool isDark, required Color accent}) {
    // Material3 的默认组件（ElevatedButton、Switch、ProgressIndicator 等）主要跟随 colorScheme.primary。
    // 这里用用户选择的主题色作为 seed/primary，避免"主题粉色但按钮仍是蓝色"的割裂感。
    final seed = accent;
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: isDark ? Brightness.dark : Brightness.light,
      primary: seed,
      // MoeTalk 仍然用自定义 surface/onSurface 来保持整体灰阶风格一致
      surface: isDark ? moePanelDark : moePanel,
      surfaceDim: isDark ? moePanelDark : moePanel,
      surfaceBright: isDark ? moePanelDark : moePanel,
      surfaceContainerLowest: isDark ? moePanelDark : moePanel,
      surfaceContainerLow: isDark ? moePanelDark : moePanel,
      surfaceContainer: isDark ? moePanelDark : moePanel,
      surfaceContainerHigh: isDark ? moePanelDark : moePanel,
      surfaceContainerHighest: isDark ? moePanelDark : moePanel,
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
      scaffoldBackgroundColor:
          isDark ? moeSurfaceDark : moeSurface,
      // 跨平台字体回退栈（Web 优先使用 Noto Sans SC，已在 index.html 预加载）
      fontFamilyFallback: const [
        // 首选：Google Fonts 中文字体（Web 平台必需）
        'Noto Sans SC',
        // Apple 平台
        'SF Pro Text', 'SF Pro Display', 'PingFang SC',
        'Hiragino Sans GB',
        // Windows
        'Segoe UI', 'Microsoft YaHei',
        // Android/Linux
        'Roboto',
      ],
      textTheme: boldText.copyWith(
        bodyLarge: baseText.bodyLarge,
        bodyMedium: baseText.bodyMedium,
        bodySmall: baseText.bodySmall,
        labelMedium: baseText.labelMedium,
        labelSmall: baseText.labelSmall,
      ),
      listTileTheme: const ListTileThemeData(minVerticalPadding: 12),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? moeSurfaceAltDark : moeSurfaceAlt,
        visualDensity: VisualDensity.standard,
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none),
      ),
      // 全局分割线样式：1px 细线、无额外上下留白（颜色更柔和）
      dividerTheme: DividerThemeData(
        color: isDark ? moeDividerColorDark : moeDividerColor,
        thickness: borderWidth,
        space: 0,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: isDark ? moeSurfaceDark : moeSurface,
        foregroundColor: isDark ? moeTextDark : moeText,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        // 统一去掉标题左侧的默认空白：避免返回按钮和标题之间出现“多出来的一段间距”。
        // 个别页面需要特殊间距时，可在该页面的 AppBar 里单独覆盖 titleSpacing。
        titleSpacing: 0,
        titleTextStyle: boldText.titleLarge?.copyWith(
          color: isDark ? moeTextDark : moeText,
        ),
      ),
      // 全局底部弹窗主题：减少视觉复杂度
      bottomSheetTheme: BottomSheetThemeData(
        elevation: 0,
        modalElevation: 0,
        modalBarrierColor: isDark ? null : Colors.transparent,
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

/// 全局界面缩放容器
///
/// 通过反向 SizedBox + Transform.scale，让缩放后依然铺满视口，
/// 用于手动微调不同设备上的整体观感。
class _GlobalUiScale extends StatelessWidget {
  final double scale;
  final Widget child;

  const _GlobalUiScale({
    required this.scale,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveScale = scale.clamp(kMinUiScaleFactor, kMaxUiScaleFactor);
    if ((effectiveScale - 1.0).abs() < 0.001) {
      return child;
    }

    final viewport = MediaQuery.sizeOf(context);

    return ClipRect(
      child: OverflowBox(
        alignment: Alignment.topCenter,
        minWidth: 0,
        minHeight: 0,
        maxWidth: double.infinity,
        maxHeight: double.infinity,
        child: Transform.scale(
          scale: effectiveScale,
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: viewport.width / effectiveScale,
            height: viewport.height / effectiveScale,
            child: child,
          ),
        ),
      ),
    );
  }
}

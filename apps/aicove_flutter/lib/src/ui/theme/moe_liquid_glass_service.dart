import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../core/app_logger.dart';

/// 液态玻璃材质基础设施管理服务
///
/// 负责平台着色器安全预热、降级状态判定以及将项目的主题系统接入第三方玻璃基础设施。
class MoeLiquidGlassService {
  MoeLiquidGlassService._();

  static bool _initialized = false;
  static bool _isAvailable = true;
  static Object? _initError;

  /// 是否已尝试初始化
  static bool get isInitialized => _initialized;

  /// 着色器和引擎能力是否可用
  static bool get isAvailable => _isAvailable;

  /// 初始化异常（若有）
  static Object? get initError => _initError;

  /// 预热着色器与平台资源。
  ///
  /// 仅捕获着色器/渲染资源加载异常，记录原因并标记降级，
  /// 不会吞掉无关异常或阻断 App 启动。
  static Future<void> initialize() async {
    if (_initialized) return;
    try {
      await LiquidGlassWidgets.initialize(
        enablePerformanceMonitor: !kReleaseMode,
      );
      _initialized = true;
      _isAvailable = true;
      AppLogger.info('LiquidGlass', '液态玻璃着色器初始化成功');
    } catch (e, st) {
      _initialized = true;
      _isAvailable = false;
      _initError = e;
      AppLogger.warning(
        'LiquidGlass',
        '液态玻璃着色器初始化未就绪，将自动降级为原生材质: $e',
        metadata: {'error': e.toString(), 'stackTrace': st.toString()},
      );
    }
  }

  /// 在测试或特殊场景下手动重置或强制标记可用状态
  @visibleForTesting
  static void setMockState({bool initialized = true, bool available = true, Object? error}) {
    _initialized = initialized;
    _isAvailable = available;
    _initError = error;
  }

  /// 包装根组件，统一接入项目 MaterialApp 的亮暗色解析与全局无障碍设置
  static Widget wrapApp({
    required Widget child,
    GlassThemeData? theme,
    bool respectSystemAccessibility = true,
    bool adaptiveQuality = false,
    GlassAdaptiveScopeConfig? adaptiveConfig,
  }) {
    return LiquidGlassWidgets.wrap(
      theme: theme,
      brightnessResolver: Theme.maybeBrightnessOf,
      respectSystemAccessibility: respectSystemAccessibility,
      adaptiveQuality: adaptiveQuality,
      adaptiveConfig: adaptiveConfig,
      child: child,
    );
  }
}

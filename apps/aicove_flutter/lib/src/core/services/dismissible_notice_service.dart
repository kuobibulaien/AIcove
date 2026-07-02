/// 可静默通知服务
/// 
/// 管理用户"不再提醒"的偏好设置。
/// 提供统一的接口控制各种通知的显示与否。
/// 
/// 使用示例：
/// ```dart
/// final service = DismissibleNoticeService();
/// if (await service.shouldShowNotice('tts_fallback_notice')) {
///   // 显示通知
/// }
/// // 用户点击"不再提醒"
/// await service.dismissForever('tts_fallback_notice');
/// ```
library;

import 'package:shared_preferences/shared_preferences.dart';

/// 通知键名常量
class NoticeKeys {
  NoticeKeys._();
  
  /// TTS 生成失败回退通知
  static const String ttsFallback = 'notice_dismissed_tts_fallback';
  
  /// 添加更多通知键名...
}

/// 可静默通知服务
class DismissibleNoticeService {
  static const String _prefix = 'notice_dismissed_';
  
  /// 检查是否应该显示通知
  /// 
  /// 如果用户之前选择了"不再提醒"，返回 false
  Future<bool> shouldShowNotice(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return !(prefs.getBool('$_prefix$key') ?? false);
  }
  
  /// 永久关闭某个通知
  /// 
  /// 用户点击"不再提醒"后调用
  Future<void> dismissForever(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('$_prefix$key', true);
  }
  
  /// 重新启用某个通知（主要用于设置页面）
  Future<void> resetNotice(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_prefix$key');
  }
  
  /// 重置所有通知设置
  Future<void> resetAll() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where((k) => k.startsWith(_prefix)).toList();
    for (final key in keys) {
      await prefs.remove(key);
    }
  }
  
  /// 获取所有已关闭的通知键名（用于调试或设置页面）
  Future<List<String>> getDismissedNotices() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getKeys()
        .where((k) => k.startsWith(_prefix))
        .where((k) => prefs.getBool(k) == true)
        .map((k) => k.substring(_prefix.length))
        .toList();
  }
}

/// 全局单例
final dismissibleNoticeService = DismissibleNoticeService();

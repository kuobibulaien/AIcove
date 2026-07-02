/// TTS 失败回退通知服务
/// 
/// 管理 TTS 生成失败时的用户通知。
/// 使用 StreamController 实现 UI 层与业务层的解耦。
/// 
/// 更新记录：
/// - 2026-01-14: 创建
library;

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/dismissible_notice_service.dart';
import '../../../ui/shared/widgets/moe_toast.dart';

/// TTS 失败原因
enum TtsFallbackReason {
  timeout('语音生成超时'),
  emptyUrl('语音服务无响应'),
  error('语音生成失败');

  final String description;
  const TtsFallbackReason(this.description);

  static TtsFallbackReason fromString(String reason) {
    switch (reason) {
      case 'timeout':
        return TtsFallbackReason.timeout;
      case 'empty_url':
        return TtsFallbackReason.emptyUrl;
      default:
        return TtsFallbackReason.error;
    }
  }
}

/// TTS 失败事件
class TtsFallbackEvent {
  final TtsFallbackReason reason;
  final DateTime timestamp;

  TtsFallbackEvent(this.reason) : timestamp = DateTime.now();

  String get message => '${reason.description}，已显示文本';
}

/// TTS 失败通知服务
class TtsFallbackNotificationService {
  final _controller = StreamController<TtsFallbackEvent>.broadcast();

  /// 事件流
  Stream<TtsFallbackEvent> get stream => _controller.stream;

  /// 触发事件
  void notify(String reason) {
    final event =  TtsFallbackEvent(TtsFallbackReason.fromString(reason));
    _controller.add(event);
  }

  /// 销毁
  void dispose() {
    _controller.close();
  }
}

/// Provider
final ttsFallbackNotificationServiceProvider = Provider<TtsFallbackNotificationService>((ref) {
  final service = TtsFallbackNotificationService();
  ref.onDispose(() => service.dispose());
  return service;
});

/// TTS 失败通知 Widget
/// 
/// 放置在 App 根部，监听 TTS 失败事件并显示 Toast
class TtsFallbackNotificationListener extends ConsumerStatefulWidget {
  final Widget child;

  const TtsFallbackNotificationListener({
    super.key,
    required this.child,
  });

  @override
  ConsumerState<TtsFallbackNotificationListener> createState() =>
      _TtsFallbackNotificationListenerState();
}

class _TtsFallbackNotificationListenerState
    extends ConsumerState<TtsFallbackNotificationListener> {
  StreamSubscription<TtsFallbackEvent>? _subscription;

  @override
  void initState() {
    super.initState();
    _setupListener();
  }

  void _setupListener() {
    final service = ref.read(ttsFallbackNotificationServiceProvider);
    _subscription = service.stream.listen((event) async {
      if (!mounted) return;
      
      // 检查是否需要显示通知
      final shouldShow = await dismissibleNoticeService.shouldShowNotice('tts_fallback');
      if (!shouldShow) return;
      
      if (!mounted) return;
      
      // 显示可静默通知
      MoeToast.showDismissible(
        context,
        event.message,
        noticeKey: 'tts_fallback',
        onDismissForever: () => dismissibleNoticeService.dismissForever('tts_fallback'),
      );
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}

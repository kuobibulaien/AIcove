import 'dart:async';

import '../domain/plugin.dart';
import 'tts_service.dart';
import '../../../core/app_logger.dart';

/// TtsService 获取器类型定义
/// 用于延迟获取最新的 TtsService 实例，解决 Provider 异步加载顺序问题
typedef TtsServiceGetter = TtsService? Function();

/// TTS 播放队列管理器（简化版）
/// 职责：负责管理多个 TTS 事件的并发「生成」，并通过事件流把可用的音频 URL 通知给上层。
/// 注意：不再在这里直接播放音频，播放由前端语音条组件控制（KISS / YAGNI）。
///
/// 重要变更 2026-01-28：
/// - 不再在构造函数中接收 TtsService 实例
/// - 改为使用 TtsServiceGetter 延迟获取，确保每次调用时获取最新配置
class TtsPlayerManager {
  /// 获取最新 TtsService 的回调函数
  TtsServiceGetter _serviceGetter;

  /// 当前活跃的 TTS 任务
  final Map<String, TtsPlayItem> _activeItems = {};

  /// 已取消的任务 ID；底层请求可能仍会返回，但结果会被忽略
  final Set<String> _cancelledItemIds = <String>{};

  /// 当前正在处理的条目
  TtsPlayItem? _currentItem;

  /// 播放状态流（主要用于 UI 显示"转换中/空闲"等整体状态）
  final _playStateController = StreamController<TtsPlayState>.broadcast();
  Stream<TtsPlayState> get playStateStream => _playStateController.stream;

  /// TTS 项目完成流：每个成功/失败的 TTS 事件都会在这里通知上层
  final _processedItemController = StreamController<TtsPlayItem>.broadcast();
  Stream<TtsPlayItem> get processedStream => _processedItemController.stream;

  /// 当前播放状态
  TtsPlayState _currentState = TtsPlayState.idle;

  TtsPlayerManager(this._serviceGetter);

  /// 在配置变化时更新服务获取器
  void updateServiceGetter(TtsServiceGetter getter) {
    _serviceGetter = getter;
  }

  /// 兼容旧代码：直接传入 TtsService 实例
  @Deprecated('使用 updateServiceGetter 代替')
  void updateService(TtsService service) {
    _serviceGetter = () => service;
  }

  /// 添加 TTS 事件并立即并发处理
  Future<void> addEvents(List<PluginEvent> events) async {
    if (events.isEmpty) return;

    for (final event in events) {
      if (event.type != 'tts_convert') continue;

      final rawText = (event.data['text'] as String?)?.trim();
      final original = (event.data['originalText'] as String?)?.trim();
      final text = (rawText != null && rawText.isNotEmpty)
          ? rawText
          : (original != null && original.isNotEmpty ? original : null);

      if (text == null || text.isEmpty) {
        AppLogger.warning('TTS', '事件缺少可用文本，直接失败', metadata: {
          'eventId': event.id,
        });
        _emitProcessedItem(TtsPlayItem(
          id: event.id,
          text: '',
          event: event,
          status: TtsPlayItemStatus.failed,
          error: 'empty_text',
        ));
        continue;
      }

      if (_activeItems.containsKey(event.id)) {
        AppLogger.warning('TTS', '重复的 TTS 事件已忽略', metadata: {
          'eventId': event.id,
        });
        continue;
      }

      _cancelledItemIds.remove(event.id);
      final item = TtsPlayItem(
        id: event.id,
        text: text,
        event: event,
      );
      _activeItems[event.id] = item;
      _currentItem ??= item;

      AppLogger.info('TTS', '提交并发转换事件', metadata: {
        'eventId': event.id,
        'textLen': text.length,
        'inFlightCount': _activeItems.length,
      });
      _updateState(TtsPlayState.converting);
      unawaited(_processItem(item));
    }
  }

  /// 并发处理单个任务：只负责调用 TTS 接口并把结果抛给上层，不做播放控制
  Future<void> _processItem(TtsPlayItem item) async {
    try {
      item.status = TtsPlayItemStatus.converting;

      final ttsService = _serviceGetter();
      if (ttsService == null) {
        throw Exception('TTS 服务未初始化，请检查插件配置');
      }

      AppLogger.info('TTS', '开始转换，检查服务配置', metadata: {
        'eventId': item.id,
        'requestUrl': ttsService.requestUrl,
        'requestFormat': ttsService.requestFormat,
        'hasApiKey': ttsService.apiKey?.isNotEmpty == true,
        'model': ttsService.model,
        'textToConvert':
            item.text.length > 50 ? '${item.text.substring(0, 50)}...' : item.text,
      });

      final result = await ttsService.convert(item.text);
      if (_cancelledItemIds.contains(item.id)) return;

      if (result.success) {
        item.audioUrl = result.audioUrl;
        item.status = TtsPlayItemStatus.completed;
      } else {
        item.status = TtsPlayItemStatus.failed;
        item.error = result.error;
      }
      _emitProcessedItem(item);
    } catch (e) {
      if (_cancelledItemIds.contains(item.id)) return;
      item.status = TtsPlayItemStatus.failed;
      item.error = e.toString();
      AppLogger.error('TTS', '处理任务失败', metadata: {
        'eventId': item.id,
        'error': e.toString(),
      });
      _emitProcessedItem(item);
    } finally {
      _activeItems.remove(item.id);
      _cancelledItemIds.remove(item.id);
      _currentItem = _activeItems.isEmpty ? null : _activeItems.values.first;
      if (_currentState != TtsPlayState.paused) {
        _updateState(
          _activeItems.isEmpty ? TtsPlayState.idle : TtsPlayState.converting,
        );
      }
    }
  }

  void _emitProcessedItem(TtsPlayItem item) {
    if (_processedItemController.isClosed) return;
    _processedItemController.add(item);
  }

  /// 更新整体 TTS 状态并广播
  void _updateState(TtsPlayState state) {
    _currentState = state;
    if (!_playStateController.isClosed) {
      _playStateController.add(state);
    }
  }

  /// 停止当前处理：清空队列并回到 idle
  Future<void> stop() async {
    _cancelledItemIds.addAll(_activeItems.keys);
    _activeItems.clear();
    _currentItem = null;
    _updateState(TtsPlayState.idle);
  }

  /// 暂停：目前只更新状态，实际播放逻辑交给前端控件（YAGNI）
  Future<void> pause() async {
    _updateState(TtsPlayState.paused);
  }

  /// 恢复：如果还有待处理的队列，则继续处理
  Future<void> resume() async {
    if (_currentState != TtsPlayState.paused) return;
    _updateState(
      _activeItems.isEmpty ? TtsPlayState.idle : TtsPlayState.converting,
    );
  }

  /// 清空已登记的任务（不影响底层已经发出的网络请求）
  void clearQueue() {
    _cancelledItemIds.addAll(_activeItems.keys);
    _activeItems.clear();
    _currentItem = null;
    if (_currentState != TtsPlayState.paused) {
      _updateState(TtsPlayState.idle);
    }
  }

  /// 队列长度
  int get queueLength => _activeItems.length;

  /// 当前条目
  TtsPlayItem? get currentItem => _currentItem;

  /// 当前状态
  TtsPlayState get currentState => _currentState;

  /// 释放资源
  void dispose() {
    _playStateController.close();
    _processedItemController.close();
  }
}

/// TTS 播放条目（只描述一次 TTS 任务结果）
class TtsPlayItem {
  final String id;
  final String text;
  final PluginEvent event;

  String? audioUrl;
  TtsPlayItemStatus status;
  String? error;

  TtsPlayItem({
    required this.id,
    required this.text,
    required this.event,
    this.audioUrl,
    this.status = TtsPlayItemStatus.pending,
    this.error,
  });
}

/// TTS 播放条目状态
enum TtsPlayItemStatus {
  pending, // 等待处理
  converting, // 转换中
  playing, //（保留枚举值以兼容历史，当前未在此类中使用）
  completed, // 已完成
  failed, // 失败
}

/// TTS 播放整体状态
enum TtsPlayState {
  idle, // 空闲
  converting, // 转换中
  playing, //（保留枚举值以兼容历史，当前未在此类中使用）
  paused, // 暂停
}

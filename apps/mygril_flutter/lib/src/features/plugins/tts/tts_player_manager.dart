import 'dart:async';

import '../domain/plugin.dart';
import 'tts_service.dart';
import '../../../core/app_logger.dart';

/// TTS 播放队列管理器（简化版）
/// 职责：负责管理多个 TTS 事件的顺序「生成」，并通过事件流把可用的音频 URL 通知给上层。
/// 注意：不再在这里直接播放音频，播放由前端语音条组件控制（KISS / YAGNI）。
class TtsPlayerManager {
  TtsService _ttsService;

  /// 待处理的 TTS 队列
  final List<TtsPlayItem> _queue = [];

  /// 是否正在处理队列
  bool _isProcessing = false;

  /// 当前正在处理的条目
  TtsPlayItem? _currentItem;

  /// 播放状态流（主要用于 UI 显示“转换中/空闲”等整体状态）
  final _playStateController = StreamController<TtsPlayState>.broadcast();
  Stream<TtsPlayState> get playStateStream => _playStateController.stream;

  /// TTS 项目完成流：每个成功/失败的 TTS 事件都会在这里通知上层
  final _processedItemController = StreamController<TtsPlayItem>.broadcast();
  Stream<TtsPlayItem> get processedStream => _processedItemController.stream;

  /// 当前播放状态
  TtsPlayState _currentState = TtsPlayState.idle;

  TtsPlayerManager(this._ttsService);

  /// 在配置变化时更新服务实例（保持单一职责：管理队列，而不是关心配置来源）
  void updateService(TtsService service) {
    _ttsService = service;
  }

  /// 添加 TTS 事件到队列
  /// 如果队列为空，会自动开始处理（KISS：简单队列，而不是复杂调度器）
  Future<void> addEvents(List<PluginEvent> events) async {
    if (events.isEmpty) return;

    for (final event in events) {
      if (event.type == 'tts_convert') {
        final rawText = (event.data['text'] as String?)?.trim();
        final original = (event.data['originalText'] as String?)?.trim();
        final text = (rawText != null && rawText.isNotEmpty)
            ? rawText
            : (original != null && original.isNotEmpty ? original : null);

        if (text != null && text.isNotEmpty) {
          _queue.add(TtsPlayItem(
            id: event.id,
            text: text,
            event: event,
          ));
          AppLogger.info('TTS', '队列加入事件', metadata: {
            'eventId': event.id,
            'textLen': text.length,
            'queueLen': _queue.length,
          });
        } else {
          // 文本为空，直接标记失败并通知上层，方便移除占位条
          AppLogger.warning('TTS', '事件缺少可用文本，直接失败', metadata: {
            'eventId': event.id,
          });
          final item = TtsPlayItem(
            id: event.id,
            text: '',
            event: event,
            status: TtsPlayItemStatus.failed,
            error: 'empty_text',
          );
          _processedItemController.add(item);
        }
      }
    }

    if (!_isProcessing) {
      AppLogger.info('TTS', '开始处理队列', metadata: {
        'queueLen': _queue.length,
      });
      _processQueue();
    }
  }

  /// 顺序处理队列：只负责调用 TTS 接口并把结果抛给上层，不做播放控制
  Future<void> _processQueue() async {
    if (_isProcessing || _queue.isEmpty) return;

    _isProcessing = true;
    _updateState(TtsPlayState.converting);

    while (_queue.isNotEmpty) {
      final item = _queue.removeAt(0);
      _currentItem = item;

      try {
        item.status = TtsPlayItemStatus.converting;
        final result = await _ttsService.convert(item.text);

        if (result.success) {
          item.audioUrl = result.audioUrl;
          item.status = TtsPlayItemStatus.completed;

          // 通知上层：已有可用音频资源，用于更新语音条等 UI
          _processedItemController.add(item);
        } else {
          item.status = TtsPlayItemStatus.failed;
          item.error = result.error;
          _processedItemController.add(item);
        }
      } catch (e) {
        item.status = TtsPlayItemStatus.failed;
        item.error = e.toString();
        AppLogger.error('TTS', '处理队列项失败', metadata: {
          'eventId': item.id,
          'error': e.toString(),
        });
        _processedItemController.add(item);
      }
    }

    _isProcessing = false;
    _currentItem = null;
    _updateState(TtsPlayState.idle);
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
    _queue.clear();
    _isProcessing = false;
    _currentItem = null;
    _updateState(TtsPlayState.idle);
  }

  /// 暂停：目前只更新状态，实际播放逻辑交给前端控件（YAGNI）
  Future<void> pause() async {
    _updateState(TtsPlayState.paused);
  }

  /// 恢复：如果还有待处理的队列，则继续处理
  Future<void> resume() async {
    if (_queue.isNotEmpty && !_isProcessing) {
      _processQueue();
    } else if (_currentState == TtsPlayState.paused) {
      _updateState(TtsPlayState.idle);
    }
  }

  /// 清空队列（不影响已生成的结果）
  void clearQueue() {
    _queue.clear();
  }

  /// 队列长度
  int get queueLength => _queue.length;

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


import 'dart:async';
import 'dart:collection';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum ImagePreheatPriority { high, normal }

class ImagePreheatQueue {
  ImagePreheatQueue({
    this.maxPendingTasks = 200,
    this.taskTimeout = const Duration(seconds: 2),
  });

  final int maxPendingTasks;
  final Duration taskTimeout;

  final Queue<_PreheatTask> _high = Queue<_PreheatTask>();
  final Queue<_PreheatTask> _normal = Queue<_PreheatTask>();
  final Set<String> _enqueuedKeys = <String>{};

  bool _isProcessing = false;
  bool _scheduled = false;
  ImagePreheatPriority? _currentPriority;
  VoidCallback? _cancelCurrentTask;
  bool _interruptRequested = false;

  int get pendingCount => _high.length + _normal.length;

  Duration _timeoutFor(ImagePreheatPriority priority) {
    if (priority == ImagePreheatPriority.high) return taskTimeout;

    // 普通优先级只需要“尽快发起加载/解码”，不必在队列里长时间等待网络回包，
    // 否则会出现：队列被慢任务占住，用户点击后的高优先级预热迟迟排不上队。
    const normalCap = Duration(milliseconds: 150);
    return taskTimeout <= normalCap ? taskTimeout : normalCap;
  }

  void _interruptNormalIfNeeded() {
    if (!_isProcessing) return;
    if (_currentPriority != ImagePreheatPriority.normal) return;

    _interruptRequested = true;
    _cancelCurrentTask?.call();
  }

  void enqueueAllFromContext(
    BuildContext context,
    Iterable<ImageProvider> providers, {
    ImagePreheatPriority priority = ImagePreheatPriority.normal,
    Size? size,
  }) {
    if (providers.isEmpty) return;
    final configuration = createLocalImageConfiguration(context, size: size);
    enqueueAll(providers, configuration, priority: priority);
  }

  void enqueueAll(
    Iterable<ImageProvider> providers,
    ImageConfiguration configuration, {
    ImagePreheatPriority priority = ImagePreheatPriority.normal,
  }) {
    for (final provider in providers) {
      _enqueue(provider, configuration, priority: priority);
    }
    if (priority == ImagePreheatPriority.high) {
      _interruptNormalIfNeeded();
    }
    _schedule();
  }

  void enqueueFromContext(
    BuildContext context,
    ImageProvider provider, {
    ImagePreheatPriority priority = ImagePreheatPriority.normal,
    Size? size,
  }) {
    final configuration = createLocalImageConfiguration(context, size: size);
    enqueue(provider, configuration, priority: priority);
  }

  void enqueue(
    ImageProvider provider,
    ImageConfiguration configuration, {
    ImagePreheatPriority priority = ImagePreheatPriority.normal,
  }) {
    _enqueue(provider, configuration, priority: priority);
    if (priority == ImagePreheatPriority.high) {
      _interruptNormalIfNeeded();
    }
    _schedule();
  }

  void _enqueue(
    ImageProvider provider,
    ImageConfiguration configuration, {
    required ImagePreheatPriority priority,
  }) {
    final key = _buildKey(provider, configuration);
    if (_enqueuedKeys.contains(key)) return;

    if (pendingCount >= maxPendingTasks) {
      _dropOne();
    }

    _enqueuedKeys.add(key);
    final task = _PreheatTask(
      provider: provider,
      configuration: configuration,
      key: key,
    );

    if (priority == ImagePreheatPriority.high) {
      _high.addLast(task);
    } else {
      _normal.addLast(task);
    }
  }

  void _dropOne() {
    if (_normal.isNotEmpty) {
      final removed = _normal.removeFirst();
      _enqueuedKeys.remove(removed.key);
      return;
    }
    if (_high.isNotEmpty) {
      final removed = _high.removeFirst();
      _enqueuedKeys.remove(removed.key);
    }
  }

  void _schedule() {
    if (_scheduled || _isProcessing) return;
    if (pendingCount == 0) return;

    _scheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      _processNext();
    });
  }

  void _processNext() {
    if (_isProcessing) return;

    late final _PreheatTask task;
    late final ImagePreheatPriority priority;
    if (_high.isNotEmpty) {
      task = _high.removeFirst();
      priority = ImagePreheatPriority.high;
    } else if (_normal.isNotEmpty) {
      task = _normal.removeFirst();
      priority = ImagePreheatPriority.normal;
    } else {
      return;
    }

    _isProcessing = true;
    _currentPriority = priority;
    _interruptRequested = false;

    _precacheWithConfig(
      task.provider,
      task.configuration,
      timeout: _timeoutFor(priority),
    ).whenComplete(() {
      _enqueuedKeys.remove(task.key);
      _isProcessing = false;
      _currentPriority = null;
      _cancelCurrentTask = null;
      _interruptRequested = false;
      _schedule();
    });
  }

  Future<void> _precacheWithConfig(
    ImageProvider provider,
    ImageConfiguration configuration, {
    required Duration timeout,
  }) {
    final completer = Completer<void>();
    final stream = provider.resolve(configuration);

    late ImageStreamListener listener;
    Timer? timer;

    void finish() {
      if (completer.isCompleted) return;
      timer?.cancel();
      stream.removeListener(listener);
      if (identical(_cancelCurrentTask, finish)) {
        _cancelCurrentTask = null;
      }
      completer.complete();
    }

    _cancelCurrentTask = finish;

    listener = ImageStreamListener(
      (image, synchronousCall) => finish(),
      onError: (error, stackTrace) => finish(),
    );

    timer = Timer(timeout, finish);
    stream.addListener(listener);

    // 在 resolve() 之后立即被加急打断的情况：
    // 当用户 onTapDown 入队高优先级任务时，如果此时正在跑普通任务，
    // 我们会请求中断，确保高优先级任务尽快开始。
    if (_interruptRequested &&
        _currentPriority == ImagePreheatPriority.normal) {
      finish();
    }

    return completer.future;
  }

  String _buildKey(ImageProvider provider, ImageConfiguration configuration) {
    final dpr = configuration.devicePixelRatio?.toStringAsFixed(2) ?? 'null';
    return '${provider.runtimeType}|$dpr|${provider.toString()}';
  }
}

class _PreheatTask {
  const _PreheatTask({
    required this.provider,
    required this.configuration,
    required this.key,
  });

  final ImageProvider provider;
  final ImageConfiguration configuration;
  final String key;
}

final imagePreheatQueueProvider = Provider<ImagePreheatQueue>((ref) {
  return ImagePreheatQueue();
});

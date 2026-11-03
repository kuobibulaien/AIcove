import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../app_logger.dart';
import 'request_control.dart';

/// Isolate-local FIFO admission shared by image API client instances.
class ImageRequestGate {
  static final shared = ImageRequestGate();

  final Map<String, _Lane> _lanes = {};

  @visibleForTesting
  int get laneCount => _lanes.length;

  Future<T> run<T>(String key, int limit, Future<T> Function() body) async {
    assert(limit > 0);
    final cancellation = RequestControl.cancellation;
    cancellation?.throwIfCancelled();
    final lane = _lanes.putIfAbsent(key, () => _Lane(limit));
    assert(lane.limit == limit);
    final waiter = _Waiter();
    final watch = Stopwatch()..start();
    // Never put a request target or credential into queue logs.
    final keySummary = sha256
        .convert(utf8.encode(key))
        .toString()
        .substring(0, 12);
    try {
      if (lane.active < lane.limit) {
        lane.active++;
        waiter.granted = true;
        waiter.ready.complete();
      } else {
        lane.waiters.addLast(waiter);
        AppLogger.info(
          'ImageRequestGate',
          '图片请求排队',
          metadata: {
            'keySummary': keySummary,
            'queuePosition': lane.waiters.length,
          },
        );
      }

      await (cancellation == null
          ? waiter.ready.future
          : cancellation.bind(waiter.ready.future));
      cancellation?.throwIfCancelled();
      AppLogger.info(
        'ImageRequestGate',
        '图片请求取得名额',
        metadata: {
          'keySummary': keySummary,
          'queueWaitMs': watch.elapsedMilliseconds,
        },
      );
      // Do not race body against cancellation: its actual exit owns the slot.
      return await body();
    } finally {
      if (waiter.granted) {
        if (lane.waiters.isNotEmpty) {
          final next = lane.waiters.removeFirst();
          // Transfer synchronously before waking the next caller. A concurrent
          // cancellation can then only release this granted slot in its finally.
          next.granted = true;
          next.ready.complete();
        } else {
          lane.active--;
        }
      } else {
        lane.waiters.remove(waiter);
      }
      if (lane.active == 0 && lane.waiters.isEmpty) _lanes.remove(key);
    }
  }
}

class _Lane {
  _Lane(this.limit);
  final int limit;
  int active = 0;
  final Queue<_Waiter> waiters = Queue();
}

class _Waiter {
  final ready = Completer<void>();
  bool granted = false;
}

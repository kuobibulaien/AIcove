/// 「最低」思考档的换档重试与记忆。
///
/// 请求带 [ProviderChatRequestOptions.thinkingCandidates] 时，按候选顺序发送，
/// 上游以 400/422 拒绝就换下一档，最后再试一次不发思考参数。只有换档后
/// 成功才记住该档位，下次同一「渠道 + 模型」直接从记住的档位开始。
/// 记忆只存本机，不入库、不云同步；丢了最多再试一轮。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../providers/provider_adapter.dart';
import 'thinking_level.dart';

/// 按 `providerId:modelId`（即 modelFullId）记住「最低」档实际可用的档位。
class ThinkingFallbackMemory {
  ThinkingFallbackMemory._();

  static final ThinkingFallbackMemory instance = ThinkingFallbackMemory._();

  static const _prefsKey = 'thinking_lowest_memory_v1';

  Map<String, ThinkingLevel>? _cache;

  Future<Map<String, ThinkingLevel>> _load() async {
    final cached = _cache;
    if (cached != null) return cached;
    final loaded = <String, ThinkingLevel>{};
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            final level = ThinkingLevel.tryParse(entry.value);
            if (level != null) loaded[entry.key.toString()] = level;
          }
        }
      }
    } catch (_) {
      // 记忆损坏等同于没有记忆，重新试一轮即可。
    }
    return _cache = loaded;
  }

  Future<void> _save(Map<String, ThinkingLevel> map) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (map.isEmpty) {
        await prefs.remove(_prefsKey);
      } else {
        await prefs.setString(
          _prefsKey,
          jsonEncode({for (final e in map.entries) e.key: e.value.name}),
        );
      }
    } catch (_) {}
  }

  Future<ThinkingLevel?> recall(String modelFullId) async =>
      (await _load())[modelFullId];

  Future<void> remember(String modelFullId, ThinkingLevel level) async {
    final map = await _load();
    if (map[modelFullId] == level) return;
    map[modelFullId] = level;
    await _save(map);
  }

  Future<void> forget(String modelFullId) async {
    final map = await _load();
    if (map.remove(modelFullId) != null) await _save(map);
  }

  /// 渠道地址或自定义参数变了，上游可能换了，清掉该渠道下所有模型的记忆。
  Future<void> forgetProvider(String providerId) async {
    final map = await _load();
    final prefix = '$providerId:';
    final before = map.length;
    map.removeWhere((key, _) => key.startsWith(prefix));
    if (map.length != before) await _save(map);
  }

  @visibleForTesting
  void resetCache() => _cache = null;
}

final _rejectedStatus = RegExp(r'HTTP (400|422)\b');

/// 上游以参数错误拒绝了请求（400/422）。其他错误（鉴权、限流、网络）换档无用。
bool isThinkingParamRejection(Object error) =>
    _rejectedStatus.hasMatch(error.toString());

/// 按候选档位依次发送。没有候选链时原样发送一次。
///
/// 全部候选与「不发参数」都失败时，抛出最后一次的错误（此时与思考参数
/// 无关的概率最大）。
Future<T> runWithThinkingFallback<T>({
  required String modelFullId,
  required ProviderChatRequestOptions? options,
  required Future<T> Function(ProviderChatRequestOptions? options) send,
  ThinkingFallbackMemory? memory,
  void Function(ThinkingLevel rejected, ThinkingLevel next, Object error)?
  onFallback,
}) async {
  final candidates = options?.thinkingCandidates;
  if (options == null || candidates == null || candidates.isEmpty) {
    return send(options);
  }
  final store = memory ?? ThinkingFallbackMemory.instance;
  final chain = [...candidates, ThinkingLevel.auto];
  final remembered = await store.recall(modelFullId);
  final rememberedIndex = remembered == null ? -1 : chain.indexOf(remembered);
  final start = rememberedIndex < 0 ? 0 : rememberedIndex;
  for (var i = start; ; i++) {
    final attempt = options.copyWith(
      thinkingLevel: chain[i],
      clearThinkingCandidates: true,
    );
    try {
      final result = await send(attempt);
      if (i > start) await store.remember(modelFullId, chain[i]);
      return result;
    } catch (error) {
      if (i == chain.length - 1 || !isThinkingParamRejection(error)) rethrow;
      onFallback?.call(chain[i], chain[i + 1], error);
    }
  }
}

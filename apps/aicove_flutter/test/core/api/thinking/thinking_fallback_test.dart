import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aicove_flutter/src/core/api/providers/provider_adapter.dart';
import 'package:aicove_flutter/src/core/api/thinking/thinking_fallback.dart';

void main() {
  const model = 'relay:gemini-3.8-flash';
  final memory = ThinkingFallbackMemory.instance;
  const lowest = ProviderChatRequestOptions(
    thinkingLevel: ThinkingLevel.off,
    thinkingScheme: ThinkingScheme.generic,
    thinkingCandidates: [
      ThinkingLevel.off,
      ThinkingLevel.minimal,
      ThinkingLevel.low,
    ],
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    memory.resetCache();
  });

  /// 拒绝 [rejected] 里的档位，其余成功；记录每次实际发送的档位。
  Future<String> Function(ProviderChatRequestOptions?) upstream(
    Set<ThinkingLevel> rejected,
    List<ThinkingLevel?> sent, {
    String error = 'HTTP 400: unsupported value',
  }) => (options) async {
    final level = options?.thinkingLevel;
    sent.add(level);
    expect(options?.thinkingCandidates, isNull);
    if (rejected.contains(level)) throw Exception(error);
    return 'ok:${level?.name}';
  };

  test(
    'falls back through candidates and remembers the one that worked',
    () async {
      final sent = <ThinkingLevel?>[];
      final result = await runWithThinkingFallback(
        modelFullId: model,
        options: lowest,
        send: upstream({ThinkingLevel.off, ThinkingLevel.minimal}, sent),
      );
      expect(result, 'ok:low');
      expect(sent, [
        ThinkingLevel.off,
        ThinkingLevel.minimal,
        ThinkingLevel.low,
      ]);
      expect(await memory.recall(model), ThinkingLevel.low);

      // 下次直接从记住的档位开始，不再走失败的档位；记忆跨重启保留。
      memory.resetCache();
      sent.clear();
      await runWithThinkingFallback(
        modelFullId: model,
        options: lowest,
        send: upstream({ThinkingLevel.off, ThinkingLevel.minimal}, sent),
      );
      expect(sent, [ThinkingLevel.low]);
    },
  );

  test('first candidate succeeding writes no memory', () async {
    final sent = <ThinkingLevel?>[];
    await runWithThinkingFallback(
      modelFullId: model,
      options: lowest,
      send: upstream({}, sent),
    );
    expect(sent, [ThinkingLevel.off]);
    expect(await memory.recall(model), isNull);
  });

  test('ends with a request that omits thinking params', () async {
    final sent = <ThinkingLevel?>[];
    final result = await runWithThinkingFallback(
      modelFullId: model,
      options: lowest,
      send: upstream({
        ThinkingLevel.off,
        ThinkingLevel.minimal,
        ThinkingLevel.low,
      }, sent),
    );
    expect(result, 'ok:auto');
    expect(sent.last, ThinkingLevel.auto);
    expect(await memory.recall(model), ThinkingLevel.auto);
  });

  test('non-parameter errors are not retried or remembered', () async {
    for (final error in [
      'HTTP 401: bad key',
      'HTTP 429: slow down',
      'timeout',
    ]) {
      final sent = <ThinkingLevel?>[];
      await expectLater(
        runWithThinkingFallback(
          modelFullId: model,
          options: lowest,
          send: upstream({ThinkingLevel.off}, sent, error: error),
        ),
        throwsA(isA<Exception>()),
      );
      expect(sent, [ThinkingLevel.off], reason: error);
    }
    expect(await memory.recall(model), isNull);
  });

  test('every attempt rejected surfaces the last error', () async {
    final sent = <ThinkingLevel?>[];
    await expectLater(
      runWithThinkingFallback(
        modelFullId: model,
        options: lowest,
        send: upstream(
          ThinkingLevel.values.toSet(),
          sent,
          error: 'HTTP 400: context too long',
        ),
      ),
      throwsA(predicate((e) => e.toString().contains('context too long'))),
    );
    expect(sent.length, 4);
    expect(await memory.recall(model), isNull);
  });

  test('requests without candidates are sent once unchanged', () async {
    final sent = <ThinkingLevel?>[];
    const explicit = ProviderChatRequestOptions(
      thinkingLevel: ThinkingLevel.high,
    );
    await runWithThinkingFallback(
      modelFullId: model,
      options: explicit,
      send: upstream({}, sent),
    );
    expect(sent, [ThinkingLevel.high]);
  });

  test('forgetProvider clears only that channel', () async {
    await memory.remember('relay:a', ThinkingLevel.low);
    await memory.remember('relay:b', ThinkingLevel.minimal);
    await memory.remember('official:a', ThinkingLevel.off);
    await memory.forgetProvider('relay');
    expect(await memory.recall('relay:a'), isNull);
    expect(await memory.recall('relay:b'), isNull);
    expect(await memory.recall('official:a'), ThinkingLevel.off);
    await memory.forget('official:a');
    expect(await memory.recall('official:a'), isNull);
  });
}

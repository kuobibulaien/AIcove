import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/context/domain/context_summary.dart';
import 'package:aicove_flutter/src/features/voice_call/data/voice_call_context_brief.dart';
import 'package:flutter_test/flutter_test.dart';

class _Store implements ContextSummaryStorePort {
  ContextSummary? auto;
  @override
  Future<ContextSummary?> loadAuto(
    String ownerId,
    String? topicBoundary,
    List<Message> history,
  ) async => auto;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _Summarizer implements ContextSummarizerPort {
  final snapshots = <ContextSnapshot>[];
  @override
  Future<String> summarize(
    ContextSnapshot snapshot, {
    required ContextSummaryKind kind,
    required void Function(int completed, int total) onProgress,
    required bool Function() isCancelled,
  }) async {
    expect(kind, ContextSummaryKind.auto);
    snapshots.add(snapshot);
    return '摘要${snapshots.length}';
  }
}

void main() {
  final t = DateTime(2026, 10, 12);
  Message msg(int i) => Message(
    id: 'm$i',
    role: i.isEven ? 'user' : 'assistant',
    content: '第$i条',
    createdAt: t,
  );
  final conv = Conversation(
    id: 'nahida',
    title: '纳西妲',
    displayName: '纳西妲',
    createdAt: t,
    updatedAt: t,
  );

  test('keeps the latest messages and summarizes the rest once', () async {
    final window = [for (var i = 0; i < 12; i++) msg(i)];
    final split = splitVoiceCallWindow(window);
    expect(split.recent.map((m) => m.id), [for (var i = 4; i < 12; i++) 'm$i']);
    expect(split.earlier, hasLength(4));

    final summarizer = _Summarizer();
    final brief = VoiceCallContextBrief(
      store: _Store(),
      summarizer: () async => summarizer,
    );
    expect(await brief.build(conv, window, split.earlier), '摘要1');
    expect(summarizer.snapshots.single.messages.map((m) => m.id), [
      'm0',
      'm1',
      'm2',
      'm3',
    ]);
    // 同一段原文再打电话直接复用，不再调模型。
    expect(await brief.build(conv, window, split.earlier), '摘要1');
    expect(summarizer.snapshots, hasLength(1));
  });

  test('a short chat needs no brief', () async {
    final window = [for (var i = 0; i < 5; i++) msg(i)];
    final split = splitVoiceCallWindow(window);
    expect(split.earlier, isEmpty);
    final brief = VoiceCallContextBrief(
      store: _Store(),
      summarizer: () async => fail('should not summarize'),
    );
    expect(await brief.build(conv, window, split.earlier), isNull);
  });
}

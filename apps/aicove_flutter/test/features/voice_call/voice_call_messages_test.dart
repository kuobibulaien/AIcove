import 'package:aicove_flutter/src/features/voice_call/data/api_runner_call_reply_generator.dart';
import 'package:aicove_flutter/src/features/voice_call/domain/voice_call_ports.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const turns = [
    CallTurn(role: 'user', text: '我面完了'),
    CallTurn(role: 'assistant', text: '诶？怎么样', interrupted: true),
    CallTurn(role: 'user', text: '还行吧'),
  ];

  test(
    'call turns replace the anchor, ahead of post-history prompts and prefill',
    () {
      final messages = buildVoiceCallMessages([
        {'role': 'system', 'content': '你是纳西妲。'},
        {'role': 'user', 'content': '我明天面试'},
        {'role': 'assistant', 'content': '加油呀'},
        {'role': 'user', 'content': kVoiceCallTurnsAnchor},
        {'role': 'system', 'content': '后置指令'},
        {'role': 'assistant', 'content': '预填'},
      ], turns);

      // 提醒语义说明补在系统提示里，模型才知道提醒标签是什么。
      expect(messages.first['content'], startsWith('你是纳西妲。'));
      expect(messages.first['content'], contains('<system-reminder>'));
      expect(messages.skip(1).map((m) => m['content']), [
        '我明天面试',
        '加油呀',
        '我面完了',
        '诶？怎么样……（被用户打断）',
        contains(kVoiceCallInstruction),
        '还行吧',
        '后置指令',
        '预填',
      ]);
      expect(
        messages.any(
          (m) => m['content'].toString().contains(kVoiceCallTurnsAnchor),
        ),
        isFalse,
      );
    },
  );

  test(
    'the speech guide joins the call instruction; without it tags are banned',
    () {
      String reminder(List<Map<String, dynamic>> messages) => messages
          .map((m) => m['content'].toString())
          .firstWhere((c) => c.contains(kVoiceCallInstruction));
      const call = [CallTurn(role: 'user', text: '喂')];

      final guided = reminder(
        buildVoiceCallMessages(const [], call, speechGuide: '用 [笑着说] 控制语气'),
      );
      expect(guided, contains('用 [笑着说] 控制语气'));
      expect(guided, isNot(contains(kVoiceCallNoSpeechTags)));

      final plain = reminder(buildVoiceCallMessages(const [], call));
      expect(plain, contains(kVoiceCallNoSpeechTags));
    },
  );

  test('only an empty call asks the character to open the call', () {
    String reminder(List<CallTurn> turns) =>
        buildVoiceCallMessages(const [], turns)
            .map((m) => m['content'].toString())
            .firstWhere((c) => c.contains(kVoiceCallInstruction));
    expect(reminder(const []), contains(kVoiceCallOpening));
    expect(
      reminder(const [CallTurn(role: 'user', text: '喂')]),
      isNot(contains(kVoiceCallOpening)),
    );
  });

  test(
    'without the anchor the turns go to the end; the base is not modified',
    () {
      final base = [
        {'role': 'user', 'content': '在吗'},
      ];
      final messages = buildVoiceCallMessages(base, const [
        CallTurn(role: 'user', text: '喂'),
      ]);
      expect(messages.map((m) => m['content']).toList(), [
        contains('<system-reminder>'),
        '在吗',
        contains(kVoiceCallInstruction),
        '喂',
      ]);
      expect(base, [
        {'role': 'user', 'content': '在吗'},
      ]);
    },
  );

  test('calls keep only memory and time plugins the role has on', () {
    expect(voiceCallPluginIds(null), ['memory', 'time_awareness']);
    expect(voiceCallPluginIds(['tts', 'image', 'memory']), ['memory']);
    expect(voiceCallPluginIds(const []), isEmpty);
  });

  test(
    'the brief replaces its anchor; without a brief the anchor goes away',
    () {
      final base = [
        {'role': 'system', 'content': '你是纳西妲。'},
        {'role': 'user', 'content': kVoiceCallBriefAnchor},
        {'role': 'assistant', 'content': '加油呀'},
        {'role': 'user', 'content': kVoiceCallTurnsAnchor},
      ];
      const turn = [CallTurn(role: 'user', text: '喂')];
      final withBrief = buildVoiceCallMessages(base, turn, brief: '用户明天面试。');
      expect(withBrief[1]['content'], contains('用户明天面试。'));
      expect(withBrief[1]['content'], startsWith('<system-reminder>'));
      expect(withBrief[2]['content'], '加油呀');

      final pending = buildVoiceCallMessages(base, turn);
      expect(pending[1]['content'], '加油呀');
      expect(
        pending.any((m) => m['content'].toString().contains('⟦')),
        isFalse,
      );
    },
  );

  test('an anchor merged into another message only loses the anchor text', () {
    final messages = buildVoiceCallMessages(
      [
        {'role': 'user', 'content': '前缀 $kVoiceCallTurnsAnchor'},
      ],
      const [CallTurn(role: 'user', text: '喂')],
    );
    expect(messages.map((m) => m['content']), contains('前缀'));
    expect(messages.last['content'], '喂');
  });

  group('placeholder splicing (review fixes)', () {
    const turn = [CallTurn(role: 'user', text: '喂')];

    test(
      'a macro copy of the placeholder in a system prompt keeps the prompt',
      () {
        final messages = buildVoiceCallMessages([
          {'role': 'system', 'content': '上一句：$kVoiceCallTurnsAnchor。请接着说。'},
          {'role': 'user', 'content': '在吗'},
          {'role': 'assistant', 'content': kVoiceCallTurnsAnchor},
        ], turn);
        expect(messages.first['content'], startsWith('上一句：。请接着说。'));
        expect(messages.last['content'], '喂');
        expect(
          messages.map((m) => m['content'].toString()),
          isNot(contains(kVoiceCallTurnsAnchor)),
        );
      },
    );

    test(
      'a prefill merged into the placeholder stays after the call turns',
      () {
        final messages = buildVoiceCallMessages([
          {'role': 'user', 'content': '在吗'},
          {'role': 'assistant', 'content': '$kVoiceCallTurnsAnchor\n\n（预填）'},
        ], turn);
        final tail = messages.sublist(messages.length - 3);
        expect(tail.map((m) => m['role']), ['user', 'user', 'assistant']);
        expect(tail[0]['content'], contains(kVoiceCallInstruction));
        expect(tail[1]['content'], '喂');
        expect(tail[2]['content'], '（预填）');
      },
    );

    test('a reply merged with the placeholder stays before the call turns', () {
      final messages = buildVoiceCallMessages([
        {'role': 'assistant', 'content': '加油呀\n$kVoiceCallTurnsAnchor'},
      ], turn);
      expect(messages[1]['content'], '加油呀');
      expect(messages.last['content'], '喂');
    });
  });
}

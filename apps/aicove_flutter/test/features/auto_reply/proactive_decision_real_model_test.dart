// Real-model check for plan 12 (opt-in): the chat-model fallback prompt,
// sent to DeepSeek Flash, must come back as parseable answers. Skipped unless
// DEEPSEEK_API_KEY is set; the key is read from the environment only.
@Tags(['real_model'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:aicove_flutter/src/features/auto_reply/data/chat_model_decision_adapter.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/context_analyzer.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/conversation_proactive_state.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/proactive_planner.dart';
import 'package:aicove_flutter/src/features/auto_reply/domain/proactive_decision.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

final String? _deepseekKey = Platform.environment['DEEPSEEK_API_KEY'];

String _state({required List<(String, String)> lines, required DateTime now}) {
  var time = now.subtract(Duration(minutes: lines.length + 10));
  final recent = <Message>[
    for (final (i, (role, text)) in lines.indexed)
      Message.text(
        id: 'm$i',
        role: role,
        content: text,
        createdAt: time = time.add(const Duration(minutes: 1)),
      ),
  ];
  return ContextAnalyzer.buildDecisionState(
    assistantName: '理',
    proactiveState: ConversationProactiveState(
      conversationId: 'c',
      lastUserAt: recent.lastWhere((m) => m.role == 'user').createdAt,
    ),
    recent: recent,
    pendingTriggers: const [],
    now: now,
  );
}

Future<String> _deepseek(String prompt) async {
  final response = await http.post(
    Uri.parse('https://api.deepseek.com/chat/completions'),
    headers: {
      'Authorization': 'Bearer $_deepseekKey',
      'Content-Type': 'application/json',
    },
    body: jsonEncode({
      'model': 'deepseek-flash',
      'temperature': 0.2,
      'messages': [
        {'role': 'system', 'content': '你只做判断，只回一行 JSON。'},
        {'role': 'user', 'content': prompt},
      ],
    }),
  );
  expect(response.statusCode, 200, reason: response.body);
  final body = jsonDecode(utf8.decode(response.bodyBytes)) as Map;
  return (body['choices'] as List).first['message']['content'] as String;
}

void main() {
  final now = DateTime(2026, 10, 13, 20, 30);
  final shower = _state(
    now: now,
    lines: [
      ('user', '今天开会开到好累'),
      ('assistant', '辛苦啦，晚上好好放松一下吧'),
      ('user', '嗯，我先去洗个澡，等下再聊'),
      ('assistant', '好，去吧～'),
    ],
  );
  final goodnight = _state(
    now: now,
    lines: [('user', '今天就聊到这吧，我要睡了'), ('assistant', '晚安，做个好梦'), ('user', '晚安')],
  );
  final questions = ProactiveDecisionQuestions.reachOut(
    hasPendingTriggers: false,
  );

  test(
    'DeepSeek Flash answers the fallback prompt in a parseable shape',
    () async {
      final adapter = ChatModelDecisionAdapter(
        assistantName: '理',
        run: _deepseek,
      );
      final afterShower = await adapter.answer(
        state: shower,
        questions: questions,
      );
      final afterGoodnight = await adapter.answer(
        state: goodnight,
        questions: questions,
      );
      // ignore: avoid_print
      print('shower: ${_summary(afterShower)}');
      // ignore: avoid_print
      print('goodnight: ${_summary(afterGoodnight)}');
      expect(afterShower['kind']!.choice, isNot('stay_silent'));
      expect(ProactivePlanner.silenceReason(afterGoodnight), isNotNull);
    },
    skip: _deepseekKey == null ? 'DEEPSEEK_API_KEY not set' : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

String _summary(Map<String, ProactiveAnswer> answers) => answers.entries
    .map((e) => '${e.key}=${e.value.choice ?? e.value.yes}')
    .join(' ');

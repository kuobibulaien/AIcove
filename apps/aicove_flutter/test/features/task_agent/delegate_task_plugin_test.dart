import 'dart:convert';

import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:aicove_flutter/src/features/task_agent/application/delegate_task_plugin.dart';
import 'package:flutter_test/flutter_test.dart';

class _Port implements DelegateTaskPort {
  final List<String> calls = [];

  @override
  Future<Map<String, Object?>> start({
    required String conversationId,
    required String instruction,
    required String? callKey,
  }) async {
    calls.add('start $conversationId $instruction $callKey');
    return {'task_id': 't1', 'status': 'accepted'};
  }

  @override
  Future<Map<String, Object?>> reply({
    required String conversationId,
    required String taskId,
    required String answer,
    required String? callKey,
  }) async {
    calls.add('reply $taskId $answer');
    return {'task_id': taskId, 'status': 'resumed'};
  }

  @override
  Future<Map<String, Object?>> cancel({
    required String conversationId,
    required String taskId,
    required String? callKey,
  }) async {
    calls.add('cancel $taskId');
    return {'task_id': taskId, 'status': 'cancelled'};
  }
}

void main() {
  test('office plugins are web search and MCP connectors', () {
    expect(isOfficePluginId('web_search'), isTrue);
    expect(isOfficePluginId('mcp:notes'), isTrue);
    expect(isOfficePluginId('image'), isFalse);
    expect(isOfficePluginId('workspace:w1'), isFalse);
  });

  test('the call key carries conversation, run, round and call id', () async {
    final port = _Port();
    final tool = delegateTaskTool(port);
    const context = ToolCallContext(
      sessionId: 'c1',
      turnId: 'run9',
      round: 2,
      toolCallId: 'call_0',
    );
    final result = await context.run(
      () => tool.handler({'action': 'start', 'instruction': '查天气'}),
    );
    expect(jsonDecode(result!), {'task_id': 't1', 'status': 'accepted'});
    expect(port.calls.single, 'start c1 查天气 c1|run9|2|call_0');

    await context.run(
      () => tool.handler({'action': 'reply', 'task_id': 't1', 'answer': '杭州'}),
    );
    await context.run(
      () => tool.handler({'action': 'cancel', 'task_id': 't1'}),
    );
    expect(port.calls.skip(1), ['reply t1 杭州', 'cancel t1']);
  });

  test('missing arguments or context are reported, not executed', () async {
    final port = _Port();
    final tool = delegateTaskTool(port);
    expect(
      jsonDecode((await tool.handler({'action': 'start'}))!),
      contains('error'),
    );
    const context = ToolCallContext(
      sessionId: 'c1',
      turnId: 'r',
      round: 1,
      toolCallId: 'x',
    );
    final missing = await context.run(
      () => tool.handler({'action': 'reply', 'task_id': 't1'}),
    );
    expect(jsonDecode(missing!), contains('error'));
    expect(port.calls, isEmpty);
  });
}

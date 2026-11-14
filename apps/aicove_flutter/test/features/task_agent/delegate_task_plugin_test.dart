import 'dart:convert';

import 'package:aicove_flutter/src/features/plugins/data/tool_result_store.dart';
import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:aicove_flutter/src/features/task_agent/application/delegate_task_plugin.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/features/task_agent/domain/agent_task.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';

class _Port implements DelegateTaskPort {
  final List<String> calls = [];
  bool? lastReadOnly;

  @override
  Future<Map<String, Object?>> start({
    required String conversationId,
    required String instruction,
    required String? callKey,
    bool readOnly = false,
  }) async {
    lastReadOnly = readOnly;
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
  test('reply and legacy aliases forward additional requirements', () async {
    final port = _Port();
    final tools = DelegateTaskRequestScope(port, active: true).tools();
    expect(tools.map((t) => t.name), [delegateTaskToolName]);
    expect(DelegateTaskRequestScope(port, active: false).tools(), isEmpty);
    const context = ToolCallContext(
      sessionId: 'c',
      turnId: 'r',
      round: 1,
      toolCallId: 'reply',
    );
    for (final action in ['reply', 'steer', 'follow_up']) {
      await context.run(
        () => tools.single.handler({
          'action': action,
          'task_id': 't',
          'instruction': '只输出 CSV',
        }),
      );
    }
    expect(port.calls, List.filled(3, 'reply t 只输出 CSV'));
    await context.run(
      () => tools.single.handler({
        'action': 'reply',
        'task_id': 't',
        'instruction': '旧要求',
        'answer': '新回答',
      }),
    );
    expect(port.calls.last, 'reply t 新回答');
  });

  test('read_only is forwarded only for start', () async {
    final port = _Port();
    const context = ToolCallContext(
      sessionId: 'c',
      turnId: 'r',
      round: 1,
      toolCallId: 'start',
    );
    await context.run(
      () => delegateTaskTool(
        port,
      ).handler({'action': 'start', 'instruction': '查资料', 'read_only': true}),
    );
    expect(port.lastReadOnly, isTrue);
    await context.run(
      () => delegateTaskTool(
        port,
      ).handler({'action': 'start', 'instruction': '改配置'}),
    );
    expect(port.lastReadOnly, isFalse);
  });

  test('active task reminder is compact and suggests reuse', () {
    final now = DateTime(2026);
    final task = AgentTask(
      id: 't1',
      requestKey: null,
      conversationId: 'c',
      source: AgentTaskSource.chat,
      instruction: '第一行\n${List.filled(90, '字').join()}',
      status: AgentTaskStatus.needsInput,
      frozen: false,
      notify: TaskReceiptNotify.always,
      receiptSeq: 1,
      questionReceiptId: 'q',
      pendingReceipt: null,
      sideEffectUncertain: false,
      createdAt: now,
      updatedAt: now,
    );
    final scope = DelegateTaskRequestScope(
      _Port(),
      active: true,
      activeTasks: [task],
    );
    final reminder = scope.reminders(now).single;
    expect(reminder.content, contains('task_id=t1 status=needs_input'));
    expect(reminder.content, contains('正在等用户回答'));
    expect(reminder.content, contains('action=reply'));
    expect(
      reminder.content.split('instruction=').last.split('（').first.runes.length,
      80,
    );
    expect(
      DelegateTaskRequestScope(
        _Port(),
        active: false,
        activeTasks: [task],
      ).reminders(now),
      isEmpty,
    );
    expect(
      DelegateTaskRequestScope(_Port(), active: true).reminders(now),
      isEmpty,
    );
  });
  test('delegation tools alone do not pull in the result reader', () {
    expect(ToolResultStore.shortReplyTools, {delegateTaskToolName});
    expect(ToolResultStore.wantsReader([delegateTaskToolName]), isFalse);
    expect(
      ToolResultStore.wantsReader([delegateTaskToolName, 'web_search']),
      isTrue,
    );
  });

  test('delegation description excludes roleplay and prior context', () {
    final description = delegateTaskTool(_Port()).description;
    expect(description, contains('严禁为回忆人设或前文派活'));
    expect(description, contains('调外部服务'));
  });

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

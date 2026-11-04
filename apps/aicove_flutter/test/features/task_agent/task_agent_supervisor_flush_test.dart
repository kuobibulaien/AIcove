import 'dart:async';

import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/features/chat/chat_providers.dart';
import 'package:aicove_flutter/src/features/task_agent/application/task_agent_service.dart';
import 'package:aicove_flutter/src/features/task_agent/data/task_sync_scanner.dart';
import 'package:aicove_flutter/src/features/task_agent/application/task_agent_supervisor.dart';
import 'package:aicove_flutter/src/features/task_agent/task_agent_providers.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Service implements TaskAgentService {
  final calls = <String>[];
  final called = Completer<void>();
  bool fail = false;

  @override
  Future<void> flushConversation(String conversationId) async {
    calls.add(conversationId);
    if (!called.isCompleted) called.complete();
    if (fail) throw StateError('flush failed');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('idle event flushes the matching conversation while supervisor exists', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    final service = _Service();
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(database),
      taskAgentServiceProvider.overrideWith((ref) async => service),
    ]);
    final events = container.read(conversationIdleEventsProvider);
    container.read(taskAgentSupervisorProvider);
    events.add('conversation-1');
    await service.called.future.timeout(const Duration(seconds: 2));
    expect(service.calls, ['conversation-1']);
    container.invalidate(taskAgentSupervisorProvider);
    events.add('conversation-2');
    await Future<void>.delayed(Duration.zero);
    expect(service.calls, ['conversation-1']);
    container.dispose();
    await database.close();
  });

  test('flush errors do not escape the supervisor', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    final service = _Service()..fail = true;
    final supervisor = TaskAgentSupervisor(
      service: Future.value(service),
      scanner: TaskSyncScanner(database),
      loadBlocks: (_) async => [],
    );
    await supervisor.flushConversation('conversation-1');
    expect(service.calls, ['conversation-1']);
    await database.close();
  });
}

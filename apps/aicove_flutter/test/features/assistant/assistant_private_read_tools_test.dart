// ADR0073 full access, batch P5: the first read of a role's chat asks the
// user; after that the role is granted until revoked. Hidden roles never.
import 'dart:convert';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart'
    show GateOutcome, ToolCallScope;

import 'package:aicove_flutter/src/features/assistant/application/assistant_private_read_tools.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_review.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/memory/domain/memory_item.dart';
import 'package:aicove_flutter/src/features/context/domain/context_summary.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _now = DateTime(2026, 10, 19, 9);

Conversation _role(String id, {bool hidden = false}) => Conversation(
  id: id,
  title: id,
  displayName: id,
  isHidden: hidden,
  createdAt: _now,
  updatedAt: _now,
);

void main() {
  late AssistantPrivateReadTools tools;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    tools = AssistantPrivateReadTools(
      roles: () async => [_role('xue'), _role('secret', hidden: true)],
      rolesNow: () => [_role('xue')],
      grants: AssistantReadGrants(),
      messages: (roleId, {required limit, before, keyword}) async => [
        (role: 'user', content: 'x' * 3000, at: _now),
      ],
      memories: (roleId) async => [
        (title: '生日', content: '用户生日是 3 月 1 日', locked: true),
      ],
    );
  });

  /// Runs a call as the gate would: [approved] when the user said yes.
  Future<Map<String, dynamic>> run(
    String name,
    Map<String, dynamic> args, {
    bool approved = false,
  }) async {
    final scope = ToolCallScope()
      ..outcome = approved ? GateOutcome.approved : GateOutcome.allowed;
    final text = await scope.run(
      () => tools.tools().singleWhere((t) => t.name == name).handler(args),
    );
    return jsonDecode(text!) as Map<String, dynamic>;
  }

  test('chat and memory reads retain full content unless max_chars is provided', () async {
    final long = 'x' * 70000;
    var receivedLimit = 0;
    tools = AssistantPrivateReadTools(
      roles: () async => [_role('xue')], rolesNow: () => [_role('xue')],
      grants: AssistantReadGrants(),
      messages: (id, {required limit, before, keyword}) async {
        receivedLimit = limit;
        return [(role: 'user', content: long, at: _now)];
      },
      memories: (_) async => [for (var i = 0; i < 101; i++) (title: '$i', content: long, locked: false)],
    );
    Future<String> read(Map<String, dynamic> args) async =>
        ((await run(AssistantPrivateReadTools.readChat, {'role_id': 'xue', ...args}, approved: true))['messages'] as List).single['content'] as String;
    expect(await read({'limit': 150}), long);
    expect(receivedLimit, 150);
    expect(await read({'offset': 3}), long.substring(3));
    expect(await read({'max_chars': 3}), 'xxx…（截断）');
    expect(await read({'max_chars': 50000}), '${'x' * 50000}…（截断）');
    final result = await run(AssistantPrivateReadTools.readMemory, {'role_id': 'xue'}, approved: true);
    expect(result['memories'], hasLength(101));
    expect((result['memories'] as List).last['content'], long);
  });

  test(
    'aggregate context preserves grants, revocation and write approval',
    () async {
      const name = 'aicove_role_context';
      final args = <String, dynamic>{
        'target': 'chat',
        'action': 'read',
        'role_id': 'xue',
      };
      await tools.prepare();
      expect(tools.riskOf(name, args), AssistantRisk.major);
      expect(
        tools.describe(name, args).title,
        tools.describe(AssistantPrivateReadTools.readChat, args).title,
      );
      expect((await run(name, args))['error'], 'invalid');
      expect((await run(name, args, approved: true))['count'], 1);
      expect(tools.riskOf(name, args), AssistantRisk.readOnly);
      final write = {...args, 'action': 'append', 'content': 'test'};
      expect(tools.riskOf(name, write), AssistantRisk.review);
      expect(
        tools.describe(name, write).title,
        tools.describe(AssistantPrivateReadTools.appendChat, write).title,
      );
      expect((await run(name, write))['message'], contains('读取授权不能代替修改审批'));
      await run(AssistantPrivateReadTools.revoke, {'role_id': 'xue'});
      expect(tools.riskOf(name, args), AssistantRisk.major);
      expect((await run(name, args))['error'], 'invalid');
      expect(
        (await run(name, {
          ...args,
          'role_id': 'secret',
        }, approved: true))['error'],
        'invalid',
      );
      expect(
        (await run(name, {
          ...args,
          'target': 'summary',
          'action': 'append',
        }, approved: true))['error'],
        'invalid',
      );
    },
  );

  test(
    'context action matrix shares atomic risks, prompts and validation',
    () async {
      final cases = <(String, String, String)>[
        ('chat', 'read', AssistantPrivateReadTools.readChat),
        ('chat', 'append', AssistantPrivateReadTools.appendChat),
        ('chat', 'update', AssistantPrivateReadTools.updateChat),
        ('chat', 'write', AssistantPrivateReadTools.updateChat),
        ('chat', 'delete', AssistantPrivateReadTools.deleteChat),
        ('summary', 'read', AssistantPrivateReadTools.readSummary),
        ('summary', 'write', AssistantPrivateReadTools.editSummary),
        ('summary', 'update', AssistantPrivateReadTools.editSummary),
        ('summary', 'delete', AssistantPrivateReadTools.deleteSummary),
        ('memory', 'read', AssistantPrivateReadTools.readMemory),
        ('memory', 'write', AssistantPrivateReadTools.writeMemory),
        ('memory', 'update', AssistantPrivateReadTools.writeMemory),
        ('memory', 'delete', AssistantPrivateReadTools.deleteMemory),
      ];
      for (final (target, action, atomic) in cases) {
        final args = <String, dynamic>{
          'target': target,
          'action': action,
          'role_id': 'xue',
        };
        expect(AssistantPrivateReadTools.contextToolName(args), atomic);
        expect(
          tools.riskOf(AssistantPrivateReadTools.roleContext, args),
          tools.riskOf(atomic, {'role_id': 'xue'}),
        );
        final prompt = tools.describe(
          AssistantPrivateReadTools.roleContext,
          args,
        );
        final original = tools.describe(atomic, {'role_id': 'xue'});
        expect(prompt.title, original.title);
        expect(prompt.detail, original.detail);
        if (action != 'read') {
          final invalid = await run(
            AssistantPrivateReadTools.roleContext,
            args,
            approved: true,
          );
          expect(invalid['error'], 'invalid', reason: '$target/$action');
          expect(
            invalid['details'],
            isNotEmpty,
            reason: '$target/$action must retain required fields',
          );
        }
      }
    },
  );

  test('asks once per role, then reads directly until revoked', () async {
    await tools.prepare();
    final args = {'role_id': 'xue'};
    expect(
      tools.riskOf(AssistantPrivateReadTools.readChat, args),
      AssistantRisk.major,
    );

    expect(
      tools.describe(AssistantPrivateReadTools.readChat, args).title,
      contains('「xue」'),
    );
    final chat = await run(
      AssistantPrivateReadTools.readChat,
      args,
      approved: true,
    );
    expect((chat['messages'] as List).single['content'], 'x' * 3000);
    final clipped = await run(AssistantPrivateReadTools.readChat, {
      'role_id': 'xue',
      'max_chars': 100,
    });
    expect(
      (clipped['messages'] as List).single['content'],
      '${'x' * 100}…（截断）',
    );
    expect(
      tools.riskOf(AssistantPrivateReadTools.readMemory, args),
      AssistantRisk.readOnly,
    );
    expect(
      (await SharedPreferences.getInstance()).getStringList(
        AssistantReadGrants.prefsKey,
      ),
      ['xue'],
    );

    await run(AssistantPrivateReadTools.revoke, args);
    expect(
      tools.riskOf(AssistantPrivateReadTools.readChat, args),
      AssistantRisk.major,
    );
    // A read the gate let through before the revoke does not grant again.
    final late = await run(AssistantPrivateReadTools.readMemory, args);
    expect(late['error'], 'invalid');
    expect(
      (await SharedPreferences.getInstance()).getStringList(
        AssistantReadGrants.prefsKey,
      ),
      isEmpty,
    );
  });

  test('a role in the privacy space cannot be read', () async {
    final result = await run(AssistantPrivateReadTools.readChat, {
      'role_id': 'secret',
    }, approved: true);
    expect(result['error'], 'invalid');
    expect(
      (await SharedPreferences.getInstance()).getStringList(
        AssistantReadGrants.prefsKey,
      ),
      isNull,
    );
  });

  test(
    'raw chat supports exact messages, boundaries and stable id paging',
    () async {
      tools = AssistantPrivateReadTools(
        roles: () async => [_role('xue')],
        rolesNow: () => [_role('xue')],
        grants: AssistantReadGrants(),
        messages: (id, {required limit, before, keyword}) async => [],
        memories: (id) async => [],
        readBoundary: (_) async => 'm1',
        rawMessages: (_) async => [
          Message(id: 'm1', role: 'user', content: 'old', createdAt: _now),
          Message(
            id: 'm2',
            role: 'assistant',
            content: 'x' * 70000,
            createdAt: _now,
          ),
          Message(id: 'm3', role: 'user', content: 'new', createdAt: _now),
        ],
      );
      final topic = await run(AssistantPrivateReadTools.readChat, {
        'role_id': 'xue',
        'active_topic_only': true,
      }, approved: true);
      expect(topic['context_start_message_id'], 'm1');
      expect((topic['messages'] as List).map((m) => m['id']), ['m3', 'm2']);
      expect((topic['messages'] as List).last['content'], 'x' * 70000);
      final one = await run(AssistantPrivateReadTools.readChat, {
        'role_id': 'xue',
        'message_id': 'm2',
      });
      expect((one['messages'] as List).single['content'], 'x' * 70000);
      final tail = await run(AssistantPrivateReadTools.readChat, {'role_id': 'xue', 'message_id': 'm2', 'offset': 200});
      expect((tail['messages'] as List).single['content'], 'x' * 69800);
      final segment = await run(AssistantPrivateReadTools.readChat, {
        'role_id': 'xue',
        'message_id': 'm2',
        'offset': 200,
        'max_chars': 100,
      });
      expect((segment['messages'] as List).single['content'], 'x' * 100);
      final page = await run(AssistantPrivateReadTools.readChat, {
        'role_id': 'xue',
        'before_message_id': 'm3',
      });
      expect((page['messages'] as List).map((m) => m['id']), ['m2', 'm1']);
      final wrong = await run(AssistantPrivateReadTools.readChat, {
        'role_id': 'xue',
        'message_id': 'not-owned',
      });
      expect(wrong['error'], 'invalid');
    },
  );

  test(
    'memory read returns ids and supports layer and keyword filters',
    () async {
      tools = AssistantPrivateReadTools(
        roles: () async => [_role('xue')],
        rolesNow: () => [_role('xue')],
        grants: AssistantReadGrants(),
        messages: (id, {required limit, before, keyword}) async => [],
        memories: (id) async => [],
        memoryItems: (_) async => [
          MemoryItem(
            id: 'a',
            ownerId: 'xue',
            layer: MemoryLayer.core,
            title: '生日',
            content: '三月',
            sourceIds: const [],
            locked: true,
            createdAt: _now,
            updatedAt: _now,
          ),
          MemoryItem(
            id: 'b',
            ownerId: 'xue',
            layer: MemoryLayer.archive,
            title: '旅行',
            content: '三月',
            sourceIds: const [],
            locked: false,
            createdAt: _now,
            updatedAt: _now,
          ),
        ],
      );
      final result = await run(AssistantPrivateReadTools.readMemory, {
        'role_id': 'xue',
        'layer': 'archive',
        'keyword': '旅行',
      }, approved: true);
      final item = (result['memories'] as List).single;
      expect(item['id'], 'b');
      expect(item['layer'], 'archive');
      expect(item['locked'], false);
    },
  );

  test(
    'summary read excludes invalid current records and exposes history',
    () async {
      ContextSummary summary(String id, ContextSummaryKind kind) =>
          ContextSummary(
            id: id,
            ownerId: 'xue',
            kind: kind,
            boundaryId: 'm1',
            topicBoundary: null,
            summary: id,
            sourceIds: const ['m1'],
            sourceDigest: 'digest',
            createdAt: _now,
          );
      tools = AssistantPrivateReadTools(
        roles: () async => [_role('xue')],
        rolesNow: () => [_role('xue')],
        grants: AssistantReadGrants(),
        messages: (id, {required limit, before, keyword}) async => [],
        memories: (id) async => [],
        readBoundary: (_) async => 'm1',
        summaryHistory: (_) async => [
          ContextSummaryHistoryEntry(
            record: summary('manual', ContextSummaryKind.manual),
            isValid: true,
            isCurrent: true,
          ),
          ContextSummaryHistoryEntry(
            record: summary('auto', ContextSummaryKind.auto),
            isValid: false,
            isCurrent: true,
          ),
        ],
      );
      final result = await run(AssistantPrivateReadTools.readSummary, {
        'role_id': 'xue',
        'include_history': true,
      }, approved: true);
      expect((result['manual'] as Map)['summary'], 'manual');
      expect(result['auto'], isNull);
      expect(result['history'], hasLength(2));
    },
  );
}

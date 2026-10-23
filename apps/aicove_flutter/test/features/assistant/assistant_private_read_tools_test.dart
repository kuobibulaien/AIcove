// ADR0073 full access, batch P5: the first read of a role's chat asks the
// user; after that the role is granted until revoked. Hidden roles never.
import 'dart:convert';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart'
    show GateOutcome, ToolCallScope;

import 'package:aicove_flutter/src/features/assistant/application/assistant_private_read_tools.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_review.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
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
    expect((chat['messages'] as List).single['content'], endsWith('（截断）'));
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
}

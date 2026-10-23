import 'dart:async';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_review.dart';
import 'package:flutter_test/flutter_test.dart';

ApprovalRequest _request(String tool) => ApprovalRequest(
  toolName: tool,
  effect: ToolEffect.write,
  arguments: const {'role_id': 'role_li'},
  reason: '',
  withdrawn: Completer<void>().future,
);

AssistantRisk? _risk(String name, Map<String, dynamic> _) => switch (name) {
  'read' => AssistantRisk.readOnly,
  'toggle' => AssistantRisk.reversible,
  'edit' => AssistantRisk.review,
  'web' => AssistantRisk.major,
  _ => null,
};

void main() {
  test('default policy allows every risk tier without approval', () {
    const gate = AssistantToolGate(_risk);
    GateDecision decide(String name) => gate
        .check(
          KernelToolCall(id: 'c', name: name, arguments: const {}),
          ToolEffect.write,
        )
        .decision;

    expect(decide('read'), GateDecision.allow);
    expect(decide('toggle'), GateDecision.allow);
    expect(decide('draw_image'), GateDecision.allow);
    expect(decide('edit'), GateDecision.allow);
    expect(decide('web'), GateDecision.allow);
  });

  test('always-ask makes reversible calls ask; reads still run', () {
    final gate = AssistantToolGate(_risk, alwaysAsk: () => true);
    GateDecision decide(String name) => gate
        .check(
          KernelToolCall(id: 'c', name: name, arguments: const {}),
          ToolEffect.write,
        )
        .decision;
    expect(decide('read'), GateDecision.allow);
    // A write of another plugin (delegate_task) asks too.
    expect(decide('draw_image'), GateDecision.ask);
    expect(decide('toggle'), GateDecision.ask);
    expect(decide('edit'), GateDecision.ask);
    expect(decide('web'), GateDecision.ask);
  });

  group('approval port', () {
    late List<ReviewResult> verdicts;
    late List<String> reviewed;
    late List<String> asked;
    late bool userSays;

    AssistantApprovalPort port({
      bool reviewerThrows = false,
      bool alwaysAsk = false,
    }) => AssistantApprovalPort(
      alwaysAsk: () => alwaysAsk,
      riskOf: _risk,
      describe: (name, _) => ApprovalPrompt(title: name, detail: ''),
      toolDescription: (name) => name,
      userMessages: const ['帮我把小理改得活泼点'],
      review:
          ({
            required userMessages,
            required toolName,
            required toolDescription,
            required arguments,
          }) async {
            if (reviewerThrows) throw StateError('offline');
            reviewed.add(toolName);
            return verdicts.removeAt(0);
          },
      askUser: (prompt, _) async {
        asked.add(prompt.title);
        return userSays;
      },
    );

    setUp(() {
      verdicts = [];
      reviewed = [];
      asked = [];
      userSays = false;
    });

    test('a major call always goes to the user, never the reviewer', () async {
      userSays = true;
      final answer = await port().answer(_request('web'));
      expect(answer.approved, isTrue);
      expect(reviewed, isEmpty);
      expect(asked, ['web']);
    });

    test('the reviewer allows, denies with a reason, or hands over', () async {
      verdicts = [
        const ReviewResult(ReviewVerdict.allow, '用户要求的'),
        const ReviewResult(ReviewVerdict.deny, '用户没让改简介'),
        const ReviewResult(ReviewVerdict.askUser, '会覆盖大段人设'),
      ];
      final p = port();
      expect((await p.answer(_request('edit'))).approved, isTrue);
      final denied = await p.answer(_request('edit'));
      expect(denied.approved, isFalse);
      expect(denied.reason, contains('用户没让改简介'));
      final handed = await p.answer(_request('edit'));
      expect(handed.approved, isFalse);
      expect(asked, ['edit']);
    });

    test(
      'with always-ask the user decides and the reviewer is skipped',
      () async {
        userSays = true;
        final answer = await port(alwaysAsk: true).answer(_request('edit'));
        expect(answer.approved, isTrue);
        expect(reviewed, isEmpty);
        expect(asked, ['edit']);
      },
    );

    test('text too long to review goes to the user', () async {
      final answer = await port().answer(
        ApprovalRequest(
          toolName: 'edit',
          effect: ToolEffect.write,
          arguments: {'persona_prompt': 'x' * 9000},
          reason: '',
          withdrawn: Completer<void>().future,
        ),
      );
      expect(answer.approved, isFalse);
      expect(reviewed, isEmpty);
      expect(asked, ['edit']);
    });

    test('a reviewer that fails hands the call to the user', () async {
      userSays = true;
      final answer = await port(reviewerThrows: true).answer(_request('edit'));
      expect(answer.approved, isTrue);
      expect(asked, ['edit']);
    });

    test('three rejections in a row stop automatic review', () async {
      verdicts = [
        for (var i = 0; i < 3; i++)
          const ReviewResult(ReviewVerdict.deny, '不对'),
      ];
      final p = port();
      for (var i = 0; i < 3; i++) {
        await p.answer(_request('edit'));
      }
      final stopped = await p.answer(_request('edit'));
      expect(stopped.approved, isFalse);
      expect(stopped.reason, contains('告诉用户'));
      expect(reviewed, hasLength(3));
    });
  });

  test('only a well-formed verdict counts; anything else asks the user', () {
    expect(
      AssistantReviewer.parse(
        '好的\n{"verdict":"allow","reason":"用户明确要求"}',
      ).verdict,
      ReviewVerdict.allow,
    );
    expect(
      AssistantReviewer.parse('{"verdict":"deny","reason":"超范围"}').reason,
      '超范围',
    );
    expect(
      AssistantReviewer.parse('{"verdict":"yes"}').verdict,
      ReviewVerdict.askUser,
    );
    expect(AssistantReviewer.parse('允许').verdict, ReviewVerdict.askUser);
  });

  test('the reviewer sees user messages and the call, clipped', () async {
    List<Map<String, dynamic>>? sent;
    final reviewer = AssistantReviewer((messages) async {
      sent = messages;
      return '{"verdict":"allow","reason":"ok"}';
    });
    await reviewer.review(
      userMessages: const ['改一下小理'],
      toolName: 'aicove_update_role',
      toolDescription: '修改角色',
      arguments: {'persona_prompt': 'x' * 9000},
    );
    final request = sent!.last['content'] as String;
    expect(sent!.first['content'], AssistantReviewer.systemPrompt);
    expect(request, contains('改一下小理'));
    expect(request, contains('aicove_update_role'));
    expect(request, contains('共 9000 字'));
    expect(request.length, lessThan(9000));
  });
}

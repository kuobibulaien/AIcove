import 'dart:async';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart';
import 'package:test/test.dart';

const _prompts = KernelCapability('prompts');
const _promptKey = ContributionKey<String>('prompt', _prompts);

KernelTool _tool(
  String name, {
  ToolEffect effect = ToolEffect.external,
  Set<String>? agentIds,
}) =>
    KernelTool(
      name: name,
      schema: {'name': name},
      handler: (_) async => 'ran:$name',
      effect: effect,
      agentIds: agentIds,
    );

TurnContext _ctx({KernelCancellation? cancellation, List<KernelEvent>? log}) =>
    TurnContext(
      round: 1,
      maxRounds: 3,
      cancellation: cancellation ?? KernelCancellation(),
      emit: (event) async => log?.add(event),
    );

KernelToolCall _call(String name, [String id = 'c1']) =>
    KernelToolCall(id: id, name: name, arguments: const {'k': 'v'});

class _ThrowingApprovals implements ApprovalPort {
  ApprovalRequest? received;

  @override
  Future<bool> request(ApprovalRequest request) {
    received = request;
    throw StateError('no prompt surface');
  }
}

class _EffectGate implements ToolGate {
  _EffectGate(this.byEffect);
  final Map<ToolEffect, GateVerdict> byEffect;

  @override
  GateVerdict check(KernelToolCall call, ToolEffect effect) =>
      byEffect[effect] ?? const GateVerdict.allow();
}

class _Approvals implements ApprovalPort {
  _Approvals(this.answer);
  final Future<bool> Function(ApprovalRequest request) answer;
  final requests = <ApprovalRequest>[];

  @override
  Future<bool> request(ApprovalRequest request) {
    requests.add(request);
    return answer(request);
  }
}

void main() {
  group('host contributions', () {
    test('undeclared capabilities are rejected for services and contributions',
        () {
      final host = PluginHost(KernelScope());
      expect(
        () => host.install(KernelPlugin(
          id: 'p',
          capabilities: const {},
          setup: (r) => r.add(_promptKey, 'x'),
        )),
        throwsStateError,
      );
      expect(
        () => host.install(KernelPlugin(
          id: 'q',
          capabilities: const {},
          setup: (r) => r.service(const ServiceKey<int>('n'), 1),
        )),
        throwsStateError,
      );
      expect(host.isEnabled('p'), isFalse);
    });

    test('contributions keep order and owner, are fixed per snapshot, and are '
        'revoked with services on disable', () {
      const counter = ServiceKey<int>('counter');
      final scope = KernelScope();
      final host = PluginHost(scope)
        ..install(KernelPlugin(
          id: 'a',
          capabilities: const {_prompts, KernelCapability.services},
          setup: (r) {
            r.add(_promptKey, 'a1');
            r.service(counter, 7);
          },
        ))
        ..install(KernelPlugin(
          id: 'b',
          capabilities: const {_prompts},
          setup: (r) => r.add(_promptKey, 'b1'),
        ));

      final before = host.snapshot();
      host.disable('a');
      final after = host.snapshot();

      expect(
        before.contributionsOf(_promptKey).map((e) => '${e.owner}:${e.value}'),
        ['a:a1', 'b:b1'],
      );
      expect(after.contributionsOf(_promptKey).map((e) => e.value), ['b1']);
      expect(scope.lookup(counter), isNull);

      host.enable('a');
      expect(
        host.snapshot().contributionsOf(_promptKey).map((e) => e.value),
        ['b1', 'a1'],
      );
      expect(scope.lookup(counter), 7);
    });

    test('a registrar kept after setup cannot register anything', () {
      late PluginRegistrar kept;
      final scope = KernelScope();
      final host = PluginHost(scope)
        ..install(KernelPlugin(
          id: 'p',
          capabilities: const {_prompts, KernelCapability.services},
          setup: (r) => kept = r,
        ));
      host.disable('p');

      expect(() => kept.add(_promptKey, 'late'), throwsStateError);
      expect(() => kept.service(const ServiceKey<int>('n'), 1),
          throwsStateError);
      expect(host.snapshot().contributionsOf(_promptKey), isEmpty);
      expect(scope.lookup(const ServiceKey<int>('n')), isNull);
    });

    test('agent-only tools are visible only to their agents', () {
      final host = PluginHost(KernelScope())
        ..install(KernelPlugin(
          id: 'guide',
          capabilities: const {KernelCapability.tools},
          setup: (r) {
            r.tool(_tool('chat_tool'));
            r.tool(_tool('inspect', agentIds: {'guide'}));
          },
        ));
      expect(host.snapshot().tools.keys, ['chat_tool']);
      expect(host.snapshot(agentId: 'other').tools.keys, ['chat_tool']);
      expect(
        host.snapshot(agentId: 'guide').tools.keys,
        unorderedEquals(['chat_tool', 'inspect']),
      );
      expect(
        host.snapshot(requestTools: [_tool('inspect', agentIds: {'guide'})])
            .tools,
        isEmpty,
      );
      expect(host.snapshot(agentId: 'guide').tools['inspect']!.effect,
          ToolEffect.external);
    });
  });

  group('gated executor', () {
    RegistryToolExecutor registry(List<KernelTool> tools) {
      final host = PluginHost(KernelScope())
        ..install(KernelPlugin(
          id: 'p',
          capabilities: const {KernelCapability.tools},
          setup: (r) => tools.forEach(r.tool),
        ));
      return RegistryToolExecutor(
        host.snapshot(),
        timeout: const Duration(seconds: 1),
        modeFor: (_) => BatchMode.parallel,
      );
    }

    final tools = [
      _tool('diag', effect: ToolEffect.readDiagnostic),
      _tool('set', effect: ToolEffect.write),
      _tool('wipe', effect: ToolEffect.destructive),
    ];
    final effects = {for (final t in tools) t.name: t.effect};
    final manualGate = _EffectGate({
      ToolEffect.write: const GateVerdict.ask('修改设置'),
      ToolEffect.destructive: const GateVerdict.deny('手动模式禁止删除'),
    });

    GatedToolExecutor gated(ApprovalPort? approvals, {Duration? timeout}) =>
        GatedToolExecutor(
          registry(tools),
          gate: manualGate,
          effectOf: (call) => effects[call.name] ?? ToolEffect.external,
          approvals: approvals,
          approvalTimeout: timeout ?? const Duration(seconds: 1),
        );

    test('allowed calls run without asking; denied ones return a structured '
        'error and emit the outcome', () async {
      final approvals = _Approvals((_) async => true);
      final log = <KernelEvent>[];
      final executor = gated(approvals);

      final ok = await executor.executeOne(_call('diag'), _ctx(log: log));
      final no = await executor.executeOne(_call('wipe', 'c2'), _ctx(log: log));

      expect(ok.content, 'ran:diag');
      expect(no.isError, isTrue);
      expect(no.content, contains('手动模式禁止删除'));
      expect(approvals.requests, isEmpty);
      expect(
        log.whereType<ToolGated>().map((e) => '${e.toolName}:${e.outcome.name}'),
        ['diag:allowed', 'wipe:denied'],
      );
    });

    test('ask runs only after approval; rejection and timeout do not run',
        () async {
      final approved = await gated(_Approvals((_) async => true))
          .executeOne(_call('set'), _ctx());
      final rejected = await gated(_Approvals((_) async => false))
          .executeOne(_call('set'), _ctx());
      final never = Completer<bool>();
      final timedOut = await gated(
        _Approvals((_) => never.future),
        timeout: const Duration(milliseconds: 20),
      ).executeOne(_call('set'), _ctx());
      final noPort = await gated(null).executeOne(_call('set'), _ctx());

      expect(approved.content, 'ran:set');
      expect(rejected.isError, isTrue);
      expect(timedOut.content, contains('超时'));
      expect(noPort.isError, isTrue);
    });

    test('approval request carries tool, effect, arguments and reason',
        () async {
      final approvals = _Approvals((_) async => true);
      await gated(approvals).executeOne(_call('set'), _ctx());
      final request = approvals.requests.single;
      expect(request.toolName, 'set');
      expect(request.effect, ToolEffect.write);
      expect(request.arguments, {'k': 'v'});
      expect(request.reason, '修改设置');
    });

    test('cancelling while waiting for approval ends the ask as cancelled',
        () async {
      final cancellation = KernelCancellation();
      final log = <KernelEvent>[];
      final pending = gated(_Approvals((_) => Completer<bool>().future))
          .executeOne(_call('set'), _ctx(cancellation: cancellation, log: log));
      await Future<void>.delayed(Duration.zero);
      cancellation.cancel();
      final result = await pending;
      expect(result.isError, isTrue);
      expect(log.whereType<ToolGated>().single.outcome, GateOutcome.cancelled);
    });

    /// Gated executor over one counted `set` (write) tool.
    (GatedToolExecutor, List<int>) counted(
      ApprovalPort approvals, {
      Duration timeout = const Duration(seconds: 1),
    }) {
      final runs = [0];
      final host = PluginHost(KernelScope())
        ..install(KernelPlugin(
          id: 'p',
          capabilities: const {KernelCapability.tools},
          setup: (r) => r.tool(KernelTool(
            name: 'set',
            schema: const {},
            effect: ToolEffect.write,
            handler: (_) async {
              runs[0] += 1;
              return 'ran';
            },
          )),
        ));
      final executor = GatedToolExecutor(
        RegistryToolExecutor(host.snapshot(),
            timeout: const Duration(seconds: 1)),
        gate: manualGate,
        effectOf: (_) => ToolEffect.write,
        approvals: approvals,
        approvalTimeout: timeout,
      );
      return (executor, runs);
    }

    Future<bool> completesSoon(Future<void> future) => future
        .then((_) => true)
        .timeout(const Duration(milliseconds: 50), onTimeout: () => false);

    test('cancellation after approval but before execution does not run the '
        'tool; the last event for the call says cancelled', () async {
      final (executor, runs) = counted(_Approvals((_) async => true));
      final cancellation = KernelCancellation();
      final log = <ToolGated>[];
      final ctx = TurnContext(
        round: 1,
        maxRounds: 3,
        cancellation: cancellation,
        emit: (event) async {
          if (event is! ToolGated) return;
          log.add(event);
          cancellation.cancel();
        },
      );

      final result = await executor.executeOne(_call('set'), ctx);

      expect(runs.single, 0);
      expect(result.isError, isTrue);
      expect(result.content, contains('已取消'));
      expect(log.map((e) => '${e.callId}:${e.outcome.name}'),
          ['c1:approved', 'c1:cancelled']);
    });

    test('a port failing synchronously or asynchronously is a rejection and '
        'withdraws the request', () async {
      final sync = _ThrowingApprovals();
      final (syncExecutor, syncRuns) = counted(sync);
      final syncResult = await syncExecutor.executeOne(_call('set'), _ctx());

      final async = _Approvals((_) async => throw StateError('closed'));
      final (asyncExecutor, asyncRuns) = counted(async);
      final asyncResult =
          await asyncExecutor.executeOne(_call('set'), _ctx());

      for (final result in [syncResult, asyncResult]) {
        expect(result.isError, isTrue);
        expect(result.content, contains('用户未允许'));
      }
      expect(syncRuns.single + asyncRuns.single, 0);
      expect(await completesSoon(sync.received!.withdrawn), isTrue);
      expect(await completesSoon(async.requests.single.withdrawn), isTrue);
    });

    test('a late approval after timeout or cancel never runs the tool',
        () async {
      final afterTimeout = Completer<bool>();
      final timeoutPort = _Approvals((_) => afterTimeout.future);
      final (timeoutExecutor, timeoutRuns) = counted(timeoutPort,
          timeout: const Duration(milliseconds: 20));
      final timedOut = await timeoutExecutor.executeOne(_call('set'), _ctx());
      afterTimeout.complete(true);

      final afterCancel = Completer<bool>();
      final cancelPort = _Approvals((_) => afterCancel.future);
      final (cancelExecutor, cancelRuns) = counted(cancelPort);
      final cancellation = KernelCancellation();
      final pending = cancelExecutor.executeOne(
          _call('set'), _ctx(cancellation: cancellation));
      await Future<void>.delayed(Duration.zero);
      cancellation.cancel();
      afterCancel.complete(true);
      final cancelled = await pending;
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(timedOut.content, contains('超时'));
      expect(cancelled.content, contains('已取消'));
      expect(timeoutRuns.single + cancelRuns.single, 0);
      expect(await completesSoon(timeoutPort.requests.single.withdrawn),
          isTrue);
      expect(await completesSoon(cancelPort.requests.single.withdrawn),
          isTrue);
    });

    test('an answer, approval or rejection, never withdraws the request',
        () async {
      final approve = _Approvals((_) async => true);
      final reject = _Approvals((_) async => false);
      final (approveExecutor, approveRuns) = counted(approve);
      final (rejectExecutor, rejectRuns) = counted(reject);
      await approveExecutor.executeOne(_call('set'), _ctx());
      await rejectExecutor.executeOne(_call('set'), _ctx());

      expect(approveRuns.single, 1);
      expect(rejectRuns.single, 0);
      expect(await completesSoon(approve.requests.single.withdrawn), isFalse);
      expect(await completesSoon(reject.requests.single.withdrawn), isFalse);
    });

    test('batches needing approval run serially; others keep inner mode', () {
      final executor = gated(_Approvals((_) async => true));
      expect(executor.modeFor([_call('diag'), _call('wipe')], _ctx()),
          BatchMode.parallel);
      expect(executor.modeFor([_call('diag'), _call('set')], _ctx()),
          BatchMode.serial);
    });

    test('allow-all gate keeps ordinary chat behaviour', () async {
      final executor = GatedToolExecutor(
        registry(tools),
        gate: const AllowAllGate(),
        effectOf: (call) => effects[call.name]!,
      );
      final result = await executor.executeOne(_call('wipe'), _ctx());
      expect(result.content, 'ran:wipe');
    });
  });

  group('secret redactor', () {
    test('masks every registered secret, longest first, and ignores blanks',
        () {
      final redactor = SecretRedactor()
        ..register('sk-abcdef123456')
        ..register('sk-abcdef123456-extended')
        ..register('pin42')
        ..register('   ');
      expect(
        redactor.redact('k=sk-abcdef123456-extended, j=sk-abcdef123456, pin42'),
        'k=${SecretRedactor.mask}, j=${SecretRedactor.mask}, '
        '${SecretRedactor.mask}',
      );
      expect(redactor.redact('   '), '   ');
      redactor.unregister('sk-abcdef123456');
      expect(redactor.redact('sk-abcdef123456'), 'sk-abcdef123456');
    });

    test('redacting executor rewrites only results that contain secrets',
        () async {
      final host = PluginHost(KernelScope())
        ..install(KernelPlugin(
          id: 'p',
          capabilities: const {KernelCapability.tools},
          setup: (r) {
            r.tool(KernelTool(
              name: 'leak',
              schema: const {},
              handler: (_) async => 'key is sk-live-0123456789',
            ));
            r.tool(_tool('clean'));
          },
        ));
      final executor = RedactingToolExecutor(
        RegistryToolExecutor(host.snapshot(),
            timeout: const Duration(seconds: 1)),
        SecretRedactor()..register('sk-live-0123456789'),
      );
      final leak = await executor.executeOne(_call('leak'), _ctx());
      final clean = await executor.executeOne(_call('clean'), _ctx());
      expect(leak.content, 'key is ${SecretRedactor.mask}');
      expect(clean.content, 'ran:clean');
    });
  });
}

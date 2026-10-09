import 'dart:async';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart';
import 'package:test/test.dart';

KernelTool tool(String name, {Future<String> Function()? run}) => KernelTool(
      name: name,
      schema: {'name': name},
      handler: (_) => run?.call() ?? Future.value('ran:$name'),
    );

KernelPlugin plugin(
  String id,
  void Function(PluginRegistrar r) setup, {
  Set<KernelCapability> caps = const {
    KernelCapability.tools,
    KernelCapability.contribute,
  },
}) =>
    KernelPlugin(id: id, capabilities: caps, setup: setup);

TurnContext ctx() => TurnContext(
      round: 1,
      maxRounds: 1,
      cancellation: KernelCancellation(),
      emit: (_) async {},
    );

void main() {
  group('scope', () {
    test('dispose closes in reverse order exactly once, children first',
        () async {
      final log = <String>[];
      final root = KernelScope();
      final child = root.child();
      root.addCloser(() => log.add('root-1'));
      root.addCloser(() => log.add('root-2'));
      child.addCloser(() => log.add('child'));

      await root.dispose();
      await root.dispose();
      expect(log, ['child', 'root-2', 'root-1']);
      expect(child.isDisposed, isTrue);
    });

    test('a failing closer does not stop the others; first error rethrown',
        () async {
      final log = <String>[];
      final scope = KernelScope();
      scope.addCloser(() => log.add('a'));
      scope.addCloser(() => throw StateError('close failed'));
      scope.addCloser(() => log.add('c'));

      await expectLater(scope.dispose(), throwsStateError);
      expect(log, ['c', 'a']);
      expect(scope.isDisposed, isTrue);
    });

    test('child service overrides parent and parent value returns after dispose',
        () async {
      const key = ServiceKey<String>('model');
      final root = KernelScope()..provide(key, 'parent');
      final child = root.child()..provide(key, 'child');
      expect(child.lookup(key), 'child');
      await child.dispose();
      expect(root.lookup(key), 'parent');
      expect(() => child.provide(key, 'again'), throwsStateError);
    });

    test('scope is released when the run succeeds, fails or is cancelled',
        () async {
      Future<bool> released(Future<void> Function(KernelScope s) body) async {
        final scope = KernelScope();
        var closed = 0;
        scope.addCloser(() => closed++);
        try {
          await body(scope);
        } catch (_) {
        } finally {
          await scope.dispose();
        }
        return closed == 1;
      }

      expect(await released((_) async {}), isTrue);
      expect(await released((_) async => throw StateError('fail')), isTrue);
      expect(
        await released(
            (_) async => throw const KernelCancelledException()),
        isTrue,
      );
    });
  });

  group('plugin host', () {
    test('disable affects the next snapshot only; re-enable restores',
        () async {
      final host = PluginHost(KernelScope());
      host.install(plugin('memory', (r) => r.tool(tool('recall'))));

      final before = host.snapshot();
      host.disable('memory');
      final after = host.snapshot();
      host.enable('memory');
      final restored = host.snapshot();

      expect(before.tools.keys, ['recall']);
      expect(after.tools, isEmpty);
      expect(restored.tools.keys, ['recall']);
      final result = await RegistryToolExecutor(before,
              timeout: const Duration(seconds: 1))
          .executeOne(const KernelToolCall(id: '1', name: 'recall'), ctx());
      expect(result.content, 'ran:recall');
    });

    test('registration without the declared capability is rejected',
        () {
      final host = PluginHost(KernelScope());
      expect(
        () => host.install(plugin('x', (r) => r.tool(tool('t')),
            caps: const {KernelCapability.contribute})),
        throwsStateError,
      );
      expect(host.isEnabled('x'), isFalse);
      expect(host.snapshot().tools, isEmpty);
    });

    test('duplicate tool names are rejected', () {
      final host = PluginHost(KernelScope());
      host.install(plugin('a', (r) => r.tool(tool('t'))));
      expect(() => host.install(plugin('b', (r) => r.tool(tool('t')))),
          throwsStateError);
      expect(() => host.snapshot(requestTools: [tool('x'), tool('x')]),
          throwsStateError);
    });

    test('request tools are authoritative, even when empty', () {
      final host = PluginHost(KernelScope());
      host.install(plugin('a', (r) => r.tool(tool('plugin_tool'))));
      expect(host.snapshot(requestTools: const []).tools, isEmpty);
      expect(host.snapshot(requestTools: [tool('bound')]).tools.keys, ['bound']);
      expect(host.snapshot().tools.keys, ['plugin_tool']);
    });

    test('optional contributors are skipped on error; required ones fail',
        () async {
      final host = PluginHost(KernelScope());
      host.install(plugin('time', (r) => r.contributor((_) async => ['now'])));
      host.install(plugin('broken',
          (r) => r.contributor((_) async => throw StateError('bad'))));
      host.install(plugin('image', (r) => r.contributor((_) async => ['retry'])));

      final failures = <ContributionFailure>[];
      final out = await host.snapshot().collectContributions(
            const ContributionInput({}),
            onFailure: failures.add,
          );
      expect(out, ['now', 'retry']);
      expect(failures.single.owner, 'broken');

      host.install(plugin(
          'strict',
          (r) => r.contributor((_) async => throw StateError('must'),
              policy: ErrorPolicy.required)));
      await expectLater(
        host.snapshot().collectContributions(const ContributionInput({})),
        throwsStateError,
      );
    });
  });

  group('registry tool executor', () {
    test('timeout, handler error and unknown tool become error results',
        () async {
      final never = Completer<String>();
      final snapshot = PluginHost(KernelScope()).snapshot(requestTools: [
        tool('slow', run: () => never.future),
        tool('bad', run: () => throw StateError('x')),
      ]);
      final executor = RegistryToolExecutor(snapshot,
          timeout: const Duration(milliseconds: 10));

      final slow = await executor.executeOne(
          const KernelToolCall(id: '1', name: 'slow'), ctx());
      final bad = await executor.executeOne(
          const KernelToolCall(id: '2', name: 'bad'), ctx());
      final missing = await executor.executeOne(
          const KernelToolCall(id: '3', name: 'nope'), ctx());

      expect([slow.isError, bad.isError, missing.isError], [true, true, true]);
      expect(slow.content, contains('超时'));
      expect(missing.content, contains('未找到工具'));
    });
  });
}

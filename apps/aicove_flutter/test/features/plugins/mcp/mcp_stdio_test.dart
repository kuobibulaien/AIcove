import 'dart:async';
import 'dart:io';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart';
import 'package:aicove_flutter/src/core/api/request_control.dart';
import 'package:aicove_flutter/src/features/plugins/mcp/mcp_client_port.dart';
import 'package:aicove_flutter/src/features/plugins/mcp/mcp_http_client.dart'
    show McpClientPool;
import 'package:aicove_flutter/src/features/plugins/mcp/mcp_connector.dart';
import 'package:aicove_flutter/src/features/plugins/mcp/mcp_connector_providers.dart';
import 'package:aicove_flutter/src/features/plugins/mcp/mcp_stdio_client.dart';
import 'package:aicove_flutter/src/features/plugins/mcp/mcp_stdio_launch.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _fixture = 'test/features/plugins/mcp/fixtures/stdio_server.py';
McpConnector _connector() => McpConnector(
  id: 'local1',
  type: McpTransportType.stdio,
  command: '/usr/bin/python3',
  args: [File(_fixture).absolute.path],
  env: const {'SECRET_TOKEN': 'do-not-leak-this-secret'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'command tokenizer preserves empty args, Unicode, Windows paths and quotes',
    () {
      expect(
        parseMcpCommandLine("npx -y package '/path with spaces' '' \"你好\""),
        ['npx', '-y', 'package', '/path with spaces', '', '你好'],
      );
      expect(
        parseMcpCommandLine(
          r'"C:\Program Files\node\node.exe" C:\users\me\a.js "a\"b"',
        ),
        [r'C:\Program Files\node\node.exe', r'C:\users\me\a.js', 'a"b'],
      );
      for (final input in [
        'npx "oops',
        'a | b',
        'a > b',
        r'node $HOME/a',
        'a && b',
      ]) {
        expect(() => parseMcpCommandLine(input), throwsFormatException);
      }
      for (final args in [
        <String>['', r'C:\Program Files\node\', 'a"b', "a'b"],
        ['x', '你好'],
      ]) {
        expect(parseMcpCommandLine(formatMcpCommandLine('node', args)), [
          'node',
          ...args,
        ]);
      }
      expect(
        parseMcpCommandLine(formatMcpCommandLine('node', [r"a'b $HOME"])),
        ['node', r"a'b $HOME"],
      );
      expect(parseMcpCommandLine(r"node O\'Brien"), ['node', "O'Brien"]);
      expect(formatMcpCommandLine('', []), '');
      expect(parseMcpEnvironment('TOKEN=a=b\nPATH=/bin\n'), {
        'TOKEN': 'a=b',
        'PATH': '/bin',
      });
      expect(() => parseMcpEnvironment('bad line'), throwsFormatException);
    },
  );

  test(
    'GUI PATH merges user before parent and picks latest semantic nvm version',
    () async {
      final dir = await Directory(
        'test/features/plugins/mcp',
      ).createTemp('.launch-');
      addTearDown(() => dir.delete(recursive: true));
      for (final version in [
        'v9.20.0',
        'v22.3.0',
        'v22.10.0',
        'not-a-version',
      ]) {
        await Directory(
          '${dir.path}/.nvm/versions/node/$version/bin',
        ).create(recursive: true);
      }
      final env = mcpProcessEnvironment(
        parent: {'HOME': dir.absolute.path, 'PATH': '/parent'},
        overrides: {'PATH': '/custom', 'TOKEN': 'value'},
      );
      expect(env['PATH'], startsWith('/custom:/parent:'));
      expect(env['PATH'], contains('/opt/homebrew/bin'));
      expect(env['PATH'], contains('v22.10.0/bin'));
      expect(env['PATH'], isNot(contains('v9.20.0/bin')));
      expect(env['TOKEN'], 'value');
      expect(expandMcpHome('~/x', '/home/me'), '/home/me/x');
      final bin = Directory('${dir.path}/bin')..createSync();
      for (final name in ['npx', 'uvx', 'node', 'python3']) {
        final file = File('${bin.path}/$name')
          ..writeAsStringSync('#!/usr/bin/python3\nprint("resolved")\n');
        expect(
          (await Process.run('/bin/chmod', ['+x', file.path])).exitCode,
          0,
        );
        final merged = mcpProcessEnvironment(
          parent: {'PATH': '/nonexistent'},
          overrides: {'PATH': bin.absolute.path},
        );
        final executable = resolveMcpExecutable(name, merged);
        final result = await Process.run(
          executable,
          [],
          environment: merged,
          runInShell: false,
        );
        expect(result.exitCode, 0);
        expect(result.stdout, 'resolved\n');
      }
    },
    skip: Platform.isWindows,
  );

  test(
    'stdio startup fields and snapshot stay local; old HTTP remains usable',
    () async {
      SharedPreferences.setMockInitialValues({});
      final notifier = McpConnectorsConfigNotifier();
      addTearDown(notifier.dispose);
      await notifier.ready;
      final local = _connector().copyWith(
        tools: const [McpToolInfo(name: 'one')],
        serverName: 'private',
      );
      await notifier.saveConnector(local);
      final prefs = await SharedPreferences.getInstance();
      final shared = prefs.getString(McpConnectorsConfigNotifier.storageKey)!;
      for (final secret in [
        'python3',
        'SECRET_TOKEN',
        'private',
        'stdio_server',
        'tools',
      ]) {
        expect(shared, isNot(contains('"$secret"')));
      }
      expect(
        McpConnectorsConfigNotifier.localStorageKey,
        isNot(startsWith('aicove.plugins.')),
      );
      final reloaded = McpConnectorsConfigNotifier();
      addTearDown(reloaded.dispose);
      await reloaded.ready;
      expect(reloaded.state.byId('local1')!.command, local.command);
      expect(reloaded.state.byId('local1')!.tools.single.name, 'one');
      final old = McpConnector.fromJson({
        'id': 'http1',
        'url': 'https://example.test',
        'tools': [
          {'name': 'old'},
        ],
      });
      expect(old.type, McpTransportType.http);
      expect(old.isUsable, true);
      await notifier.saveConnector(local.copyWith(command: '/other/program'));
      expect(notifier.state.byId('local1')!.tools, isEmpty);
    },
  );

  test('stale refresh cannot overwrite edited configuration', () async {
    SharedPreferences.setMockInitialValues({});
    final fake = _DelayedClient();
    final notifier = McpConnectorsConfigNotifier(connect: (_) => fake);
    addTearDown(notifier.dispose);
    await notifier.ready;
    await notifier.saveConnector(_connector());
    final refresh = notifier.refreshTools('local1');
    await fake.started.future;
    await notifier.saveConnector(_connector().copyWith(command: '/changed'));
    fake.result.complete(
      const McpServerSnapshot(
        serverName: 'stale',
        tools: [McpToolInfo(name: 'stale')],
      ),
    );
    await expectLater(refresh, throwsA(isA<McpException>()));
    expect(notifier.state.byId('local1')!.tools, isEmpty);
  });

  group(
    'actual stdio process',
    () {
      late McpStdioClient client;
      setUp(() {
        client = McpStdioClient(
          connector: _connector(),
          requestTimeout: const Duration(seconds: 3),
        );
      });
      tearDown(() async {
        client.close();
        await client.stopped;
      });

      test(
        'initialize, pages, concurrent IDs, split Unicode and structured content',
        () async {
          final snapshot = await client.listTools();
          expect(snapshot.serverName, '本地测试');
          expect(snapshot.tools.map((t) => t.name), ['first', 'second']);
          final results = await Future.wait([
            client.callTool('slow', {}),
            client.callTool('fast', {}),
          ]);
          expect(results.map((r) => r.text), ['slow晴', 'fast晴']);
          expect(results.first.output?.structured, {'ok': true});
        },
      );

      test(
        'cancel notifies server without killing shared process or replaying',
        () async {
          await client.listTools();
          final signal = KernelCancellation();
          final call = RequestControl.run(
            signal,
            () => client.callTool('hang', {}),
          );
          await Future<void>.delayed(const Duration(milliseconds: 60));
          signal.cancel();
          await expectLater(call, throwsA(isA<KernelCancelledException>()));
          final status =
              (await client.callTool('status', {})).output!.structured as Map;
          expect(status['calls'], 2);
          expect(status['cancelled'], hasLength(1));
        },
      );

      test(
        'exit and malformed protocol produce clear errors with secrets redacted',
        () async {
          await client.listTools();
          await expectLater(
            client.callTool('exit', {}),
            throwsA(
              isA<McpException>()
                  .having((e) => e.message, 'unknown', contains('结果未知'))
                  .having(
                    (e) => e.message,
                    'secret',
                    isNot(contains('do-not-leak-this-secret')),
                  ),
            ),
          );
          final invalid = McpStdioClient(connector: _connector());
          addTearDown(() async {
            invalid.close();
            await invalid.stopped;
          });
          await expectLater(
            invalid.callTool('invalid', {}),
            throwsA(
              isA<McpException>().having(
                (e) => e.message,
                'protocol',
                contains('协议错误'),
              ),
            ),
          );
        },
      );

      test(
        'timeout reports unknown, no replay, and connection still works',
        () async {
          final short = McpStdioClient(
            connector: _connector(),
            requestTimeout: const Duration(milliseconds: 500),
          );
          addTearDown(() async {
            short.close();
            await short.stopped;
          });
          await expectLater(
            short.callTool('hang', {}),
            throwsA(
              isA<McpException>().having(
                (e) => e.message,
                'unknown',
                contains('结果未知'),
              ),
            ),
          );
          expect(
            ((await short.callTool('status', {})).output!.structured
                as Map)['calls'],
            2,
          );
        },
      );

      for (final replace in [false, true]) {
        test(
          'pool closeAll waits for retired process (${replace ? 'replace' : 'remove'})',
          () async {
            final pool = McpClientPool.instance;
            await pool.closeAll();
            addTearDown(pool.closeAll);
            final retired = pool.clientFor(_connector());
            final result =
                (await retired.callTool('spawn', {})).output!.structured as Map;
            final child = result['child'] as int;
            if (replace) {
              final replacement = pool.clientFor(
                _connector().copyWith(env: {'SECRET_TOKEN': 'new-generation'}),
              );
              expect(identical(replacement, retired), false);
            } else {
              pool.remove('local1');
            }
            var closed = false;
            final closing = pool.closeAll().then((_) => closed = true);
            await Future<void>.delayed(const Duration(milliseconds: 20));
            expect(closed, false);
            await closing;
            final alive = await Process.run('/bin/ps', [
              '-o',
              'stat=',
              '-p',
              '$child',
            ]);
            expect((alive.stdout as String).trim(), anyOf('', startsWith('Z')));
          },
        );
      }

      test(
        'shutdown cleans descendants without assuming a separate process group',
        () async {
          final result =
              (await client.callTool('spawn', {})).output!.structured as Map;
          final fixturePid = result['pid'] as int,
              child = result['child'] as int;
          final parentGroup = await Process.run('/bin/ps', [
            '-o',
            'pgid=',
            '-p',
            '$pid',
          ]);
          expect(
            int.parse((parentGroup.stdout as String).trim()),
            result['pgrp'],
          );
          expect(fixturePid, isNot(pid));
          client.close();
          await client.stopped;
          final alive = await Process.run('/bin/ps', [
            '-o',
            'stat=',
            '-p',
            '$child',
          ]);
          expect((alive.stdout as String).trim(), anyOf('', startsWith('Z')));
        },
      );
    },
    skip: Platform.isWindows || !File('/usr/bin/python3').existsSync(),
  );
}

class _DelayedClient implements McpClientPort {
  final started = Completer<void>();
  final result = Completer<McpServerSnapshot>();
  @override
  Future<McpServerSnapshot> listTools() {
    started.complete();
    return result.future;
  }

  @override
  Future<McpToolCallResult> callTool(
    String name,
    Map<String, dynamic> arguments,
  ) => throw UnimplementedError();
  @override
  void close() {}
}

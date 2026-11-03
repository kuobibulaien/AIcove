import 'dart:io';

import 'package:aicove_flutter/src/features/plugins/mcp/mcp_process_cleanup.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Windows process JSON accepts empty, single and array output', () {
    expect(parseMcpWindowsProcessParents(''), isEmpty);
    expect(
      parseMcpWindowsProcessParents('{"ProcessId":2,"ParentProcessId":1}'),
      {2: 1},
    );
    expect(
      parseMcpWindowsProcessParents(
        '[{"ProcessId":2,"ParentProcessId":1},'
        '{"ProcessId":3,"ParentProcessId":2},{"ProcessId":4,"ParentProcessId":99},'
        '{"ProcessId":"bad","ParentProcessId":1}]',
      ),
      {2: 1, 3: 2, 4: 99},
    );
  });

  test('descendant selection excludes unrelated IDs, root and cycles', () {
    expect(mcpDescendantPids(1, {1: 3, 2: 1, 3: 2, 4: 99, 5: 3}), [2, 3, 5]);
    expect(mcpDescendantPids(0, {1: 0}), isEmpty);
  });

  test(
    'Windows snapshot runs a constant no-profile command before cleanup',
    () async {
      final descendants = await captureMcpDescendants(
        10,
        windows: true,
        run: (executable, arguments) async {
          expect(
            executable,
            endsWith(r'WindowsPowerShell\v1.0\powershell.exe'),
          );
          expect(arguments.take(3), [
            '-NoProfile',
            '-NonInteractive',
            '-Command',
          ]);
          expect(arguments.last, startsWith('Get-CimInstance Win32_Process |'));
          return ProcessResult(
            1,
            0,
            '[{"ProcessId":11,"ParentProcessId":10},{"ProcessId":12,"ParentProcessId":11},'
                '{"ProcessId":20,"ParentProcessId":1}]',
            '',
          );
        },
      );
      expect(descendants, [11, 12]);
    },
  );

  test(
    'enumeration failure is distinct from an empty descendant snapshot',
    () async {
      expect(
        await captureMcpDescendants(
          10,
          windows: true,
          run: (_, _) async => null,
        ),
        null,
      );
      expect(
        await captureMcpDescendants(
          10,
          windows: true,
          run: (_, _) async => ProcessResult(1, 1, '', ''),
        ),
        null,
      );
      expect(
        await captureMcpDescendants(
          10,
          windows: true,
          run: (_, _) async => ProcessResult(1, 0, '[]', ''),
        ),
        isEmpty,
      );
    },
  );

  for (final code in [0, 1, -1]) {
    test(
      'Windows cleanup targets captured children after wrapper exit; status $code',
      () async {
        final fallback = <int>[];
        await stopMcpWindowsProcesses(
          [11, 12],
          // No parent PID: wrapper already exited and children are reparented.
          run: (executable, arguments) async {
            expect(executable, endsWith(r'System32\taskkill.exe'));
            expect(arguments, ['/T', '/F', '/PID', '12', '/PID', '11']);
            return code < 0 ? null : ProcessResult(1, code, '', '');
          },
          kill: (pid) {
            fallback.add(pid);
            return true;
          },
        );
        expect(fallback, code == 0 ? isEmpty : [12, 11]);
      },
    );
  }

  test('Windows cleanup includes a still-running wrapper once', () async {
    await stopMcpWindowsProcesses(
      [11, 12],
      parentPid: 10,
      run: (_, arguments) async {
        expect(arguments, [
          '/T',
          '/F',
          '/PID',
          '12',
          '/PID',
          '11',
          '/PID',
          '10',
        ]);
        return ProcessResult(1, 0, '', '');
      },
    );
  });

  test(
    'system helper timeout is bounded and terminates its helper',
    () async {
      final watch = Stopwatch()..start();
      final result = await runMcpProcessHelper('/usr/bin/python3', [
        '-c',
        'import time; time.sleep(30)',
      ], timeout: const Duration(milliseconds: 100));
      expect(result, null);
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    },
    skip: Platform.isWindows || !File('/usr/bin/python3').existsSync(),
  );
}

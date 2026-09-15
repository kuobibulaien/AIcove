import contextlib
import io
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

import mac_debug_session as debug


# A protocol-driven subprocess exercises the actual PID, cwd, FIFO and locking
# boundaries without launching Flutter or touching a desktop window.
FAKE_FLUTTER = '''import json, os, pathlib, signal, sys, time
root = pathlib.Path.cwd()
def config():
    return json.loads((root / 'behavior.json').read_text())
with (root / 'launches').open('a') as out:
    out.write(str(os.getpid()) + '\\n')
if config().get('startup') == 'exit':
    print('mock build failed', flush=True)
    sys.exit(7)
def emit(message):
    print(json.dumps([message]), flush=True)
def change(request):
    behavior = config()
    with (root / 'requests').open('a') as out:
        out.write(json.dumps(request) + '\\n')
    if behavior.get('reload') == 'silent':
        return
    time.sleep(behavior.get('delay', 0))
    # Flutter prints this even when a hot restart fails. It is not evidence.
    print('Restarted application in 5ms.', flush=True)
    emit({'id': 'unrelated-request', 'result': {'code': 0}})
    if behavior.get('reload') == 'fail':
        emit({'id': request['id'], 'result': {'code': 1, 'message': 'compile failed'}})
    elif behavior.get('reload') == 'rpc_error':
        emit({'id': request['id'], 'error': 'app not found'})
    else:
        emit({'id': request['id'], 'result': {'code': 0}})
signal.signal(signal.SIGTERM, lambda *args: sys.exit(0))
if config().get('startup') != 'hang':
    emit({'event': 'app.started', 'params': {'appId': 'test-app'}})
for line in sys.stdin:
    for request in json.loads(line):
        change(request)
'''


class MacDebugSessionTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='aicove fake debug ')
        self.addCleanup(self.temp.cleanup)
        self.project = Path(self.temp.name)
        self.tool = self.project / 'flutter_tools.snapshot'
        self.tool.write_text(FAKE_FLUTTER)
        self.flutter = self.project / 'flutter'
        self.flutter.write_text('#!/bin/sh\nexec ' + shlex.quote(sys.executable) +
                                ' ' + shlex.quote(str(self.tool)) + ' "$@"\n')
        self.flutter.chmod(0o700)
        self.session = debug.DebugSession(self.project)
        self.behavior()
        self.addCleanup(self.stop_fake_children)

    def behavior(self, **values):
        (self.project / 'behavior.json').write_text(json.dumps(values))

    def stop_fake_children(self):
        for child in self.session.children:
            if child.poll() is None:
                child.terminate()
            child.wait(timeout=3)
        launches = self.project / 'launches'
        if not launches.exists():
            return
        for pid in map(int, launches.read_text().splitlines()):
            info = debug.process_info(pid)
            if info and str(self.tool) in info['command']:
                os.kill(pid, signal.SIGTERM)
            with contextlib.suppress(ChildProcessError):
                os.waitpid(pid, 0)

    def start(self, timeout=3):
        with self.session.locked():
            return self.session.start(str(self.flutter), timeout)

    def request_count(self):
        path = self.project / 'requests'
        return len(path.read_text().splitlines()) if path.exists() else 0

    def test_live_session_is_reused_without_launch_or_log_truncation(self):
        outcome, state = self.start()
        log = Path(state['log'])
        with log.open('a') as out:
            out.write('preserved evidence\n')
        outcome, reused = self.start()
        self.assertEqual(outcome, 'reused')
        self.assertEqual(state['pid'], reused['pid'])
        self.assertEqual(len((self.project / 'launches').read_text().splitlines()), 1)
        self.assertIn('preserved evidence', log.read_text())

    def test_startup_exit_is_reported_without_waiting_for_timeout(self):
        self.behavior(startup='exit')
        began = time.monotonic()
        with self.assertRaisesRegex(debug.SessionError, '进程已退出'):
            self.start(timeout=3)
        self.assertLess(time.monotonic() - began, 2)
        self.assertTrue(list(self.session.directory.glob('*.log')))

    def test_macos_exec_transition_is_rechecked_before_identity_validation(self):
        prefix = 'Sat Sep 12 01:00:00 2026 R '
        transient = subprocess.CompletedProcess([], 0, prefix + '(dart)\n')
        ready = subprocess.CompletedProcess([], 0, prefix + '/sdk/flutter_tools.snapshot run\n')
        with patch.object(debug.subprocess, 'run', side_effect=[transient, ready]):
            self.assertEqual(debug.process_info(123)['command'], '/sdk/flutter_tools.snapshot run')

    def test_startup_timeout_is_bounded_and_retry_does_not_duplicate(self):
        self.behavior(startup='hang')
        began = time.monotonic()
        for _ in range(2):
            with self.assertRaisesRegex(debug.SessionError, '启动超时'):
                self.start(timeout=.15)
        self.assertLess(time.monotonic() - began, 3)
        self.assertEqual(len((self.project / 'launches').read_text().splitlines()), 1)

    def test_wrong_process_birth_is_never_signaled(self):
        _, state = self.start()
        state['started'] = 'a different process lifetime'
        self.session.save(state)
        with self.assertRaisesRegex(debug.SessionError, '不匹配'):
            self.session.change('reload', .2)
        with self.assertRaisesRegex(debug.SessionError, '不匹配'):
            self.session.stop(.2)
        self.assertEqual(self.request_count(), 0)

    def test_wrong_working_directory_is_never_signaled(self):
        self.start()
        with patch.object(debug, 'process_cwd', return_value=Path('/different-checkout')):
            with self.assertRaisesRegex(debug.SessionError, '不匹配'):
                self.session.change('reload', .2)
        self.assertEqual(self.request_count(), 0)

    def test_wrong_flutter_command_is_never_signaled(self):
        _, state = self.start()
        wrong = {'started': state['started'], 'command': '/bin/sleep 100'}
        with patch.object(debug, 'process_info', return_value=wrong):
            with self.assertRaisesRegex(debug.SessionError, '不匹配'):
                self.session.change('reload', .2)
        self.assertEqual(self.request_count(), 0)

    def test_old_success_cannot_confirm_a_new_silent_reload(self):
        self.behavior(reload='silent')
        _, state = self.start()
        with Path(state['log']).open('a') as out:
            out.write('[{"id":"old-request","result":{"code":0}}]\n')
        with self.assertRaisesRegex(debug.SessionError, '本次重载超时'):
            self.session.change('reload', .2)
        self.assertIsNotNone(self.session.load().get('pending'))

    def test_reload_and_restart_confirm_new_matching_completion(self):
        self.start()
        for action in ('reload', 'restart'):
            with self.session.locked():
                result, state = self.session.change(action, 3)
            self.assertEqual(result, action)
            self.assertNotIn('pending', state)
        self.assertEqual(self.request_count(), 2)
        requests = [json.loads(line) for line in (self.project / 'requests').read_text().splitlines()]
        self.assertEqual([r['params']['fullRestart'] for r in requests], [False, True])
        self.assertTrue(all(r['params']['appId'] == 'test-app' for r in requests))

    def test_rejected_reload_is_not_reported_as_success(self):
        self.behavior(reload='fail')
        self.start()
        for action in ('reload', 'restart'):
            with self.assertRaisesRegex(debug.SessionError, '出现错误'):
                self.session.change(action, 3)
            self.assertNotIn('pending', self.session.load())
        self.behavior()
        self.assertEqual(self.session.change('reload', 3)[0], 'reload')
        self.assertEqual(len((self.project / 'launches').read_text().splitlines()), 1)

    def test_protocol_error_does_not_report_success_or_block_retry(self):
        self.behavior(reload='rpc_error')
        self.start()
        with self.assertRaisesRegex(debug.SessionError, '出现错误'):
            self.session.change('reload', 3)
        self.assertNotIn('pending', self.session.load())

    def test_unsent_request_does_not_leave_a_pending_operation(self):
        self.start()
        with patch.object(debug.os, 'write', side_effect=BlockingIOError()):
            with self.assertRaises(BlockingIOError):
                self.session.change('reload', 3)
        self.assertNotIn('pending', self.session.load())
        self.assertEqual(self.request_count(), 0)
        self.assertEqual(self.session.change('reload', 3)[0], 'reload')

    def test_replaced_log_cannot_confirm_a_pending_request(self):
        self.behavior(reload='silent')
        _, state = self.start()
        with self.assertRaisesRegex(debug.SessionError, '本次重载超时'):
            self.session.change('reload', .1)
        replacement = self.project / 'replacement.log'
        replacement.write_text(json.dumps([{'id': self.session.load()['pending']['id'],
                                            'result': {'code': 0}}]) + '\n')
        replacement.replace(state['log'])
        with self.assertRaisesRegex(debug.SessionError, '替换或截断'):
            self.session.wait_change(.1)

    def test_timeout_blocks_new_request_until_prior_result_is_observed(self):
        self.behavior(delay=.7)
        self.start()
        with self.assertRaisesRegex(debug.SessionError, '本次重载超时'):
            self.session.change('reload', .1)
        with self.assertRaisesRegex(debug.SessionError, '上次重载结果'):
            self.session.change('restart', .1)
        self.assertEqual(self.request_count(), 1)
        action, state = self.session.wait_change(3)
        self.assertEqual(action, 'reload')
        self.assertNotIn('pending', state)

    def test_cli_process_can_exit_and_next_cli_reuses_fifo(self):
        command = [sys.executable, str(Path(debug.__file__).resolve()),
                   '--project', str(self.project), '--flutter', str(self.flutter), '--timeout', '3']
        results = []
        for action in ('start', 'start', 'reload', 'stop'):
            result = subprocess.run(command + [action], capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            results.append(json.loads(result.stdout))
        self.assertEqual([r['status'] for r in results], ['started', 'reused', 'reload', 'stopped'])
        self.assertEqual(len({r['pid'] for r in results}), 1)

    def test_stop_keeps_log_and_later_start_has_a_new_log(self):
        _, old = self.start()
        self.session.stop(3)
        self.assertTrue(Path(old['log']).exists())
        _, new = self.start()
        self.assertNotEqual(old['log'], new['log'])
        self.assertTrue(Path(old['log']).exists())

    def test_cli_lock_prevents_overlapping_commands(self):
        command = [sys.executable, str(Path(debug.__file__).resolve()), 'start',
                   '--project', str(self.project), '--flutter', str(self.flutter)]
        with self.session.locked():
            result = subprocess.run(command, capture_output=True, text=True, timeout=3)
        self.assertEqual(result.returncode, 2)
        self.assertIn('另一个任务', result.stderr)
        self.assertFalse((self.project / 'launches').exists())

    def test_status_does_not_launch_an_application(self):
        with patch.object(sys, 'argv', ['session', 'status', '--project', str(self.project)]):
            with contextlib.redirect_stdout(io.StringIO()) as output:
                self.assertEqual(debug.main(), 0)
        self.assertEqual(json.loads(output.getvalue())['status'], 'stopped')
        self.assertFalse((self.project / 'launches').exists())


if __name__ == '__main__':
    unittest.main()

#!/usr/bin/env python3
"""Manage one persistent macOS Flutter debug session per checkout."""

import argparse
from contextlib import contextmanager
import fcntl
import json
import math
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import subprocess
import sys
import time
import uuid


class SessionError(RuntimeError):
    pass


def process_info(pid):
    for attempt in range(3):
        result = subprocess.run(
            ['ps', '-ww', '-p', str(pid), '-o', 'lstart=', '-o', 'stat=', '-o', 'command='],
            capture_output=True, text=True, timeout=5,
            env={**os.environ, 'LC_ALL': 'C'})
        fields = result.stdout.strip().split(None, 6)
        if result.returncode or len(fields) != 7 or fields[5].startswith('Z'):
            return None
        # During exec, macOS can briefly expose only "(dart)" without argv.
        # Retry that incomplete observation; still require a full identity match.
        if fields[6].startswith('(') and attempt < 2:
            time.sleep(0.05)
            continue
        return {'started': ' '.join(fields[:5]), 'command': fields[6]}


def process_cwd(pid):
    result = subprocess.run(
        ['lsof', '-a', '-p', str(pid), '-d', 'cwd', '-Fn'],
        capture_output=True, text=True, timeout=5)
    paths = [line[1:] for line in result.stdout.splitlines() if line.startswith('n')]
    if result.returncode or len(paths) != 1:
        raise SessionError('无法核对会话进程的工作目录，拒绝发送信号。')
    return Path(paths[0]).resolve()


class DebugSession:
    def __init__(self, project):
        self.project = Path(project).resolve()
        self.directory = self.project / 'build' / 'mac-debug-session'
        self.state_file = self.directory / 'session.json'
        self.children = []  # Own Popen objects until this short-lived CLI exits.

    @contextmanager
    def locked(self):
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        with (self.directory / 'command.lock').open('a') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise SessionError('另一个任务正在操作此调试会话，请等它完成。')
            try:
                yield
            finally:
                fcntl.flock(lock, fcntl.LOCK_UN)

    def load(self):
        if not self.state_file.exists():
            return None
        try:
            state = json.loads(self.state_file.read_text())
            if (state['project'] != str(self.project)
                    or not isinstance(state['pid'], int) or state['pid'] <= 1
                    or not isinstance(state['started'], str)
                    or state['phase'] not in ('starting', 'ready', 'stopped')
                    or any(Path(state[key]).parent != self.directory
                           for key in ('input', 'log'))):
                raise ValueError('invalid session identity')
            return state
        except (KeyError, TypeError, ValueError) as error:
            raise SessionError('会话记录无效，拒绝接管进程。') from error

    def save(self, state):
        temporary = self.state_file.with_suffix('.tmp')
        with temporary.open('w') as target:
            os.chmod(temporary, 0o600)
            json.dump(state, target)
        temporary.replace(self.state_file)

    def checked(self, state):
        if state is None or state['phase'] == 'stopped':
            return False
        info = process_info(state['pid'])
        if info is None:
            return False
        suffix = 'run -d macos --debug --machine'
        if (info['started'] != state['started']
                or not info['command'].endswith(suffix)
                or not re.search(r'(?:/flutter|/flutter_tools\.(?:snapshot|dart)) ' +
                                 re.escape(suffix) + r'$', info['command'])):
            raise SessionError('PID 的启动时间、Flutter 命令或项目目录不匹配，拒绝接管或发送信号。')
        try:
            cwd = process_cwd(state['pid'])
        except SessionError:
            if process_info(state['pid']) is None:
                return False  # The process can exit between ps and lsof.
            raise
        if cwd != self.project:
            raise SessionError('PID 的项目目录不匹配，拒绝接管或发送信号。')
        return True

    def messages(self, state, offset, timeout, identity=None):
        deadline = time.monotonic() + timeout
        buffered = b''
        while True:
            with Path(state['log']).open('rb') as source:
                stamp = os.fstat(source.fileno())
                current = (stamp.st_dev, stamp.st_ino)
                identity = identity or current
                if current != identity or stamp.st_size < offset:
                    raise SessionError('等待期间日志被替换或截断，无法确认本次结果。')
                source.seek(offset)
                chunk = source.read(65536)
            offset += len(chunk)
            buffered += chunk
            lines = buffered.split(b'\n')
            buffered = lines.pop()
            if len(buffered) > 1024 * 1024:
                raise SessionError('日志单行超过 1 MiB，无法解析协议结果：' + state['log'])
            for raw in lines:
                try:
                    batch = json.loads(raw)
                except (ValueError, UnicodeError):
                    continue  # Build output can contain non-protocol lines.
                if isinstance(batch, list):
                    for message in batch:
                        if isinstance(message, dict):
                            yield message
            if not self.checked(state):
                raise SessionError('会话进程已退出；日志保留在 ' + state['log'])
            if time.monotonic() >= deadline:
                return
            if not chunk:
                time.sleep(0.1)

    def wait_ready(self, state, timeout):
        if state['phase'] == 'ready':
            return state
        for message in self.messages(state, 0, timeout):
            if message.get('event') == 'app.stop':
                raise SessionError('应用启动失败；日志保留在 ' + state['log'])
            if message.get('event') == 'app.started':
                app_id = message.get('params', {}).get('appId')
                if not isinstance(app_id, str) or not app_id:
                    continue
                state['app_id'] = app_id
                state['phase'] = 'ready'
                self.save(state)
                return state
        raise SessionError('启动超时；保留进程和日志，再次 start 会继续等待而不重复启动：' + state['log'])

    def start(self, flutter, timeout):
        state = self.load()
        if self.checked(state):
            return 'reused', self.wait_ready(state, timeout)
        executable = shutil.which(flutter)
        if not executable:
            raise SessionError('找不到 Flutter 命令：' + flutter)
        run_id = uuid.uuid4().hex
        log = self.directory / (run_id + '.log')
        input_file = self.directory / (run_id + '.fifo')
        os.mkfifo(input_file, mode=0o600)
        # RDWR keeps stdin open between CLI requests. Flutter owns this fd after
        # launch; no resident Python broker, terminal, or UI automation is needed.
        descriptor = os.open(input_file, os.O_RDWR)
        try:
            with log.open('xb') as output:
                os.chmod(log, 0o600)
                child = subprocess.Popen(
                    [executable, 'run', '-d', 'macos', '--debug', '--machine'],
                    cwd=self.project, stdin=descriptor,
                    stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
                self.children.append(child)
        finally:
            os.close(descriptor)
        info = process_info(child.pid)
        if info is None:
            child.poll()
            raise SessionError('启动进程已退出；日志保留在 ' + str(log))
        state = {'project': str(self.project), 'pid': child.pid,
                 'started': info['started'], 'phase': 'starting',
                 'input': str(input_file), 'log': str(log)}
        self.save(state)
        try:
            return 'started', self.wait_ready(state, timeout)
        finally:
            child.poll()

    def active(self):
        state = self.load()
        if not self.checked(state):
            raise SessionError('没有可复用的调试会话；先执行 start。')
        return state

    def change(self, action, timeout):
        state = self.active()
        if state['phase'] != 'ready':
            raise SessionError('调试会话尚未就绪；先执行 start 等待完成。')
        if state.get('pending'):
            raise SessionError('上次重载结果尚未确认；先执行 wait，不发送新请求。')
        stamp = Path(state['log']).stat()
        request_id = uuid.uuid4().hex
        state['pending'] = {'action': action, 'id': request_id, 'offset': stamp.st_size,
                            'inode': stamp.st_ino, 'device': stamp.st_dev}
        request = [{'id': request_id, 'method': 'app.restart',
                    'params': {'appId': state['app_id'], 'fullRestart': action == 'restart'}}]
        descriptor = os.open(state['input'], os.O_WRONLY | os.O_NONBLOCK)
        try:
            if not stat.S_ISFIFO(os.fstat(descriptor).st_mode):
                raise SessionError('会话输入不是 FIFO，拒绝写入。')
            payload = (json.dumps(request) + '\n').encode()
            if len(payload) > os.fpathconf(descriptor, 'PC_PIPE_BUF'):
                raise SessionError('请求超过 FIFO 原子写入上限，未发送。')
            # Recheck immediately before writing; never use only kill(pid, 0).
            if not self.checked(state):
                raise SessionError('调试进程已退出，未发送请求。')
            self.save(state)
            try:
                written = os.write(descriptor, payload)
            except OSError:
                # A nonblocking write <= PIPE_BUF either writes all or nothing.
                state.pop('pending')
                self.save(state)
                raise
            if written != len(payload):
                raise SessionError('请求写入不完整，保留待确认状态。')
        finally:
            os.close(descriptor)
        return self.wait_change(timeout)

    def wait_change(self, timeout):
        state = self.active()
        pending = state.get('pending')
        if not pending:
            raise SessionError('没有等待确认的重载操作。')
        identity = (pending['device'], pending['inode'])
        for message in self.messages(state, pending['offset'], timeout, identity):
            if message.get('event') == 'app.stop':
                raise SessionError('等待重载时应用退出；日志保留在 ' + state['log'])
            if message.get('id') != pending['id']:
                continue
            state.pop('pending')
            self.save(state)
            result = message.get('result')
            if ('error' in message or not isinstance(result, dict)
                    or type(result.get('code')) is not int or result['code'] != 0):
                raise SessionError('本次重载出现错误；修复后可重新请求，详细结果见 ' + state['log'])
            return pending['action'], state
        raise SessionError('本次重载超时，未确认成功；可执行 wait 继续确认：' + state['log'])

    def stop(self, timeout):
        state = self.active()
        os.kill(state['pid'], signal.SIGTERM)
        deadline = time.monotonic() + timeout
        while process_info(state['pid']) is not None:
            if time.monotonic() >= deadline:
                raise SessionError('停止超时；不强杀进程，请检查日志：' + state['log'])
            time.sleep(0.1)
        state['phase'] = 'stopped'
        state.pop('pending', None)
        self.save(state)
        return 'stopped', state


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['start', 'status', 'reload', 'restart', 'wait', 'stop'])
    parser.add_argument('--project', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--flutter', default=str(Path(__file__).with_name('flutterw')),
                        help='Flutter executable used by start (defaults to project SDK wrapper)')
    parser.add_argument('--timeout', type=float, help='Seconds; start defaults to 300, other actions to 60')
    args = parser.parse_args()
    timeout = args.timeout if args.timeout is not None else (300 if args.action == 'start' else 60)
    if not math.isfinite(timeout) or timeout <= 0:
        parser.error('--timeout must be finite and positive')
    session = DebugSession(args.project)
    try:
        with session.locked():
            if args.action == 'start':
                outcome, state = session.start(args.flutter, timeout)
            elif args.action in ('reload', 'restart'):
                outcome, state = session.change(args.action, timeout)
            elif args.action == 'wait':
                outcome, state = session.wait_change(timeout)
            elif args.action == 'stop':
                outcome, state = session.stop(timeout)
            else:
                state = session.load()
                outcome = state['phase'] if session.checked(state) else 'stopped'
            print(json.dumps({'status': outcome, 'pid': state['pid'] if state else None,
                              'log': state['log'] if state else None,
                              'pending': state.get('pending', {}).get('action') if state else None},
                             ensure_ascii=False))
    except (SessionError, OSError, subprocess.SubprocessError) as error:
        print('调试会话未完成：' + str(error), file=sys.stderr)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main())

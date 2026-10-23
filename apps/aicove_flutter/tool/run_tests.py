#!/usr/bin/env python3
"""Run the offline Flutter tests and record timing.

Usage (from apps/aicove_flutter):
  python3 tool/run_tests.py                 # full tier
  python3 tool/run_tests.py --fast          # skip slow / preview / real_model
  python3 tool/run_tests.py -- test/features/chat   # extra flutter test args

Wraps `tool/flutterw test --reporter=json`. Prints failures as they happen
and a summary with the slowest files. Any single test (or file compile)
running longer than --long-seconds (default 300) is announced while it is
still running and appended to scratch/test-reports/long_tests.jsonl at the
repository root. Each run writes scratch/test-reports/run-<time>.json.
DEEPSEEK_API_KEY is removed from the environment, so real_model tests skip.
"""
import argparse
import json
import os
import subprocess
import sys
import threading
import time
from datetime import datetime
from pathlib import Path

APP = Path(__file__).resolve().parent.parent
REPO = APP.parent.parent
REPORTS = REPO / 'scratch' / 'test-reports'
FAST_EXCLUDE = 'slow || preview || real_model'


def git_rev():
    try:
        return subprocess.run(['git', 'rev-parse', '--short', 'HEAD'], cwd=APP,
                              capture_output=True, text=True).stdout.strip()
    except OSError:
        return ''


def rel(path):
    return path.split('/aicove_flutter/', 1)[-1] if path else '?'


class Run:
    def __init__(self, long_seconds):
        self.long_seconds = long_seconds
        self.lock = threading.Lock()
        self.suites = {}      # suite id -> path
        self.tests = {}       # test id -> dict
        self.running = {}     # test id -> monotonic start
        self.files = {}       # path -> {load, run, tests, start, end}
        self.output = {}      # test id -> list of lines
        self.failures = []
        self.long = []
        self.flagged = set()
        self.counts = {'passed': 0, 'failed': 0, 'skipped': 0}
        self.started = time.monotonic()

    def file(self, test):
        path = self.suites.get(test['suiteID'], '?')
        return self.files.setdefault(path, {'load_s': 0.0, 'run_s': 0.0,
                                            'tests': 0, 'start': None, 'end': 0.0})

    def handle(self, event):
        kind = event.get('type')
        now = time.monotonic()
        with self.lock:
            if kind == 'suite':
                self.suites[event['suite']['id']] = rel(event['suite'].get('path'))
            elif kind == 'testStart':
                test = event['test']
                test['loading'] = test['name'].startswith('loading ')
                self.tests[test['id']] = test
                self.running[test['id']] = now
                info = self.file(test)
                if info['start'] is None:
                    info['start'] = now
            elif kind in ('print', 'error'):
                lines = self.output.setdefault(event['testID'], [])
                if kind == 'print':
                    lines.append(event['message'])
                else:
                    lines.append(event['error'])
                    lines.append(event.get('stackTrace', ''))
            elif kind == 'testDone':
                self.done(event, now)

    def done(self, event, now):
        test = self.tests[event['testID']]
        start = self.running.pop(test['id'], now)
        seconds = now - start
        info = self.file(test)
        info['end'] = max(info['end'], now)
        if test['loading']:
            info['load_s'] += seconds
        elif not event.get('hidden'):
            info['run_s'] += seconds
            info['tests'] += 1
            if event.get('skipped'):
                self.counts['skipped'] += 1
            elif event['result'] == 'success':
                self.counts['passed'] += 1
            else:
                self.counts['failed'] += 1
        if event['result'] != 'success':
            self.fail(test)
        if seconds >= self.long_seconds and test['id'] not in self.flagged:
            self.record_long(test, seconds, event['result'])
        elif test['id'] in self.flagged:
            for entry in self.long:
                if entry['id'] == test['id']:
                    entry.update(seconds=round(seconds, 1), result=event['result'])

    def fail(self, test):
        name = self.name(test)
        lines = '\n'.join(self.output.get(test['id'], [])).splitlines()
        self.failures.append({'test': name, 'output': lines[-60:]})
        print(f'\n失败 {name}', flush=True)
        for line in lines[-25:]:
            print(f'    {line}', flush=True)

    def name(self, test):
        path = self.suites.get(test['suiteID'], '?')
        if test['loading']:
            return f'{path} （编译加载）'
        return f'{path} :: {test["name"]}'

    def record_long(self, test, seconds, result):
        self.flagged.add(test['id'])
        entry = {'id': test['id'], 'test': self.name(test),
                 'seconds': round(seconds, 1), 'result': result}
        self.long.append(entry)
        print(f'\n超时警告 已运行 {seconds / 60:.1f} 分钟：{entry["test"]}', flush=True)

    def watch(self, stop):
        while not stop.wait(5):
            now = time.monotonic()
            with self.lock:
                for test_id, start in list(self.running.items()):
                    if (now - start >= self.long_seconds
                            and test_id not in self.flagged):
                        self.record_long(self.tests[test_id], now - start,
                                         'running')


def main():
    parser = argparse.ArgumentParser(
        description='Run offline Flutter tests with timing records.')
    parser.add_argument('--fast', action='store_true',
                        help=f"exclude tags: {FAST_EXCLUDE}")
    parser.add_argument('-j', '--jobs', type=int,
                        help='concurrent test processes (flutter default: half the cores)')
    parser.add_argument('--long-seconds', type=int, default=300,
                        help='record tests running at least this long (default 300)')
    parser.add_argument('test_args', nargs='*',
                        help='extra flutter test arguments, after --')
    args = parser.parse_args()

    cmd = [str(APP / 'tool' / 'flutterw'), 'test', '--reporter=json']
    if args.jobs:
        cmd.append(f'--concurrency={args.jobs}')
    if args.fast:
        cmd += ['--exclude-tags', FAST_EXCLUDE]
    cmd += args.test_args
    env = dict(os.environ)
    env.pop('DEEPSEEK_API_KEY', None)

    run = Run(args.long_seconds)
    stop = threading.Event()
    threading.Thread(target=run.watch, args=(stop,), daemon=True).start()
    proc = subprocess.Popen(cmd, cwd=APP, env=env, stdout=subprocess.PIPE,
                            text=True, encoding='utf-8', errors='replace')
    other = []
    for line in proc.stdout:
        line = line.rstrip('\n')
        if line.startswith('{'):
            try:
                run.handle(json.loads(line))
                continue
            except (json.JSONDecodeError, KeyError):
                pass
        other.append(line)
    code = proc.wait()
    stop.set()
    wall = time.monotonic() - run.started

    files = sorted(
        ({'path': p, 'span_s': round(i['end'] - i['start'], 1) if i['start'] else 0,
          'load_s': round(i['load_s'], 1), 'run_s': round(i['run_s'], 1),
          'tests': i['tests']} for p, i in run.files.items()),
        key=lambda f: -f['span_s'])
    c = run.counts
    print(f'\n共 {len(files)} 个文件，通过 {c["passed"]}，失败 {c["failed"]}，'
          f'跳过 {c["skipped"]}，耗时 {wall:.0f} 秒'
          f'{"（快速档）" if args.fast else ""}')
    print('最慢的 10 个文件（秒，含编译）：')
    for f in files[:10]:
        print(f'  {f["span_s"]:7.1f}  {f["path"]}')
    if run.long:
        print(f'超过 {args.long_seconds} 秒的测试 {len(run.long)} 个，已记入 '
              f'{REPORTS / "long_tests.jsonl"}')
    if not files:
        print('\n'.join(other[-40:]))

    REPORTS.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime('%Y%m%d-%H%M%S')
    meta = {'time': stamp, 'rev': git_rev(), 'fast': args.fast,
            'jobs': args.jobs, 'args': args.test_args}
    with open(REPORTS / 'long_tests.jsonl', 'a', encoding='utf-8') as out:
        for entry in run.long:
            out.write(json.dumps({**meta, **{k: v for k, v in entry.items()
                                             if k != 'id'}},
                                 ensure_ascii=False) + '\n')
    report = {**meta, 'exit_code': code, 'wall_s': round(wall, 1), **c,
              'long_tests': [{k: v for k, v in e.items() if k != 'id'}
                             for e in run.long],
              'failures': run.failures, 'files': files}
    path = REPORTS / f'run-{stamp}.json'
    path.write_text(json.dumps(report, ensure_ascii=False, indent=1),
                    encoding='utf-8')
    print(f'完整报告：{path}')
    return code


if __name__ == '__main__':
    sys.exit(main())

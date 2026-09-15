#!/usr/bin/env python3
"""只读 Android 诊断采集；原始旧日志仅经内存过滤，不保存正文/凭据/数据库。

python3 tool/collect_diagnostics.py --device auto --since 2h
python3 tool/collect_diagnostics.py --from-dir /path/to/logs --since 7d
"""
from __future__ import annotations

import argparse
from collections import defaultdict, deque
from datetime import datetime, timedelta, timezone
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import threading
import uuid
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
LOG_NAME = re.compile(r"(?:(?:app|api|trace)_|trace/index_)(\d{4}-\d{2}-\d{2})\.jsonl\Z")
ATOM = re.compile(r"[A-Za-z0-9_.:-]{1,160}\Z")
MAX_LINE = 512 * 1024
MAX_FILE = 16 * 1024 * 1024
MAX_INPUT = 64 * 1024 * 1024
MAX_OUTPUT = 16 * 1024 * 1024


def atom(value):
    return value if isinstance(value, str) and ATOM.fullmatch(value) else None


def timestamp(value, tz):
    try:
        # macOS 自带 Python 3.9 不接受 ISO 8601 的 Z 后缀，Dart 导出使用 Z。
        if isinstance(value, str) and value.endswith('Z'):
            value = value[:-1] + '+00:00'
        result = datetime.fromisoformat(value)
        return result.replace(tzinfo=tz) if result.tzinfo is None else result
    except (ValueError, TypeError):
        return None


def safe_map(value):
    if not isinstance(value, dict):
        return {}
    return {k: v for k, v in list(value.items())[:40]
            if atom(k) and (isinstance(v, bool) or isinstance(v, (int, float))
                            and abs(v) < 1e20)}


def normalize(entry, origin, tz):
    """显式允许列表；绝不透传未知 metadata、raw body 或自由文本 message。"""
    if not isinstance(entry, dict):
        return None
    time = timestamp(entry.get('time', entry.get('startedAt')), tz)
    if time is None:
        return None
    output = {'time': time.astimezone(timezone.utc).isoformat(), 'origin': origin}
    meta = entry.get('metadata')
    if isinstance(meta, dict) and meta.get('category') == 'frontend':
        for key in ('schemaVersion', 'sequence', 'monotonicUs', 'pid', 'isolateId',
                    'elapsedMs', 'itemCount', 'droppedCount', 'timeoutMs', 'rangeStart', 'rangeEnd'):
            value = meta.get(key)
            if isinstance(value, (int, float)) and not isinstance(value, bool) and abs(value) < 1e20:
                output[key] = value
        for key in ('appRunId', 'event', 'operationId', 'parentOperationId', 'conversationId',
                    'traceId', 'turnId', 'messageId', 'sourceMessageId', 'pageInstanceId',
                    'phase', 'reason', 'errorType'):
            value = atom(meta.get(key))
            if value is not None:
                output[key] = value
        for key in ('stackTruncated', 'stackNonCodeFramesOmitted', 'errorMessageOmitted'):
            if isinstance(meta.get(key), bool):
                output[key] = meta[key]
        # 上游仅输出受控错误说明；采集端也不相信任意写入者的自由文本。
        summary = meta.get('errorSummary')
        if summary in ('No element', 'Too many elements', 'Future already completed',
                       'Cannot add new events after calling close', 'timeout', 'range_error',
                       'free_form_message_omitted') or (isinstance(summary, str)
                       and re.fullmatch(r'platform:[A-Za-z_][A-Za-z0-9_]{0,47}', summary)):
            output['errorSummary'] = summary
        output['state'] = safe_map(meta.get('state'))
        output['writerHealth'] = safe_map(meta.get('writerHealth'))
        health = meta.get('writerHealth')
        if isinstance(health, dict) and atom(health.get('lastErrorType')):
            output['writerHealth']['lastErrorType'] = health['lastErrorType']
        locations = meta.get('codeLocations')
        if isinstance(locations, list):
            output['codeLocations'] = [s for s in locations[:64] if isinstance(s, str)
                and len(s) <= 512 and re.fullmatch(r'(?:package:|dart:)[A-Za-z0-9_./:-]+', s)]
        build = meta.get('build')
        if isinstance(build, dict):
            output['build'] = safe_map(build)
            for key in ('buildId', 'buildType', 'flutterMode', 'versionName',
                        'deviceModel', 'identityScope', 'identityErrorType'):
                if atom(build.get(key)):
                    output['build'][key] = build[key]
        output['kind'] = 'frontend'
    elif origin['file'].startswith(('trace_', 'trace/')):
        output['kind'] = 'trace'
        for key in ('traceId', 'sessionId', 'turnId', 'stage', 'status', 'source'):
            if atom(entry.get(key)):
                output[key] = entry[key]
        for key in ('roundIndex', 'eventSeq', 'durationMs'):
            if isinstance(entry.get(key), int):
                output[key] = entry[key]
    elif origin['file'].startswith('api_'):
        output['kind'] = 'network'
        for key in ('sessionId', 'turnId'):
            if atom(entry.get(key)):
                output[key] = entry[key]
        for key in ('ok', 'status', 'durationMs', 'roundIndex', 'eventSeq'):
            if isinstance(entry.get(key), (int, bool)):
                output[key] = entry[key]
    else:
        output['kind'] = 'legacyApp'
        for key in ('traceId', 'source'):
            if atom(entry.get(key)):
                output[key] = entry[key]
    if atom(entry.get('level')):
        output['level'] = entry['level']
    return output


def read_records(stream, name, tz, report, *, tail=False):
    line_number = 0
    while True:
        line = stream.readline(MAX_LINE + 1)
        if not line:
            break
        line_number += 1
        report['inputBytes'] += len(line)
        if report['inputBytes'] > MAX_INPUT:
            report['limits'].append('input_budget_reached')
            break
        if len(line) > MAX_LINE:
            report['limits'].append(f'{name}:oversize_line')
            while line and not line.endswith(b'\n'):
                line = stream.readline(MAX_LINE + 1)
                report['inputBytes'] += len(line)
                if report['inputBytes'] > MAX_INPUT:
                    return
            continue
        if not line.endswith(b'\n'):
            report['limits'].append(f'{name}:incomplete_tail')
            continue
        try:
            entry = json.loads(line)
        except (ValueError, UnicodeError):
            report['malformedLines'] += 1
            continue
        origin = {'file': name, 'lineInRead': line_number, 'tailRead': tail}
        item = normalize(entry, origin, tz)
        if item is not None:
            yield item


def make_summary(records, report):
    candidates = deque(maxlen=200)
    candidate_count = 0
    runs = defaultdict(list)
    missing_identity = 0
    for number, item in enumerate(records, 1):
        evidence = f'operations.jsonl:{number}'
        item['evidence'] = evidence
        if item.get('appRunId'):
            runs[(item['appRunId'], item.get('isolateId'))].append(item)
        if item['kind'] == 'frontend' and item.get('build', {}).get('buildId') in (None, 'unknown'):
            missing_identity += 1
        state = item.get('state', {})
        reason = None
        if item.get('event') == 'animationDecision' and state.get('animate') and state.get('previouslyBuilt'):
            reason = 'old_bubble_animation'
        elif item.get('event') == 'ttsApplyDecision' and item.get('reason') in ('ownerRejected', 'rawInactive', 'unknownMessage'):
            reason = 'tts_result_rejected_may_be_expected_cancellation'
        elif (item.get('phase') == 'error' or item.get('level') in ('error', 'fatal', 'ERROR')
              or item.get('stage') == 'TURN_FAILED' or item.get('status') in ('error', 'failed')
              or item.get('kind') == 'network' and item.get('ok') is False):
            reason = 'recorded_error'
        elif item.get('event') == 'diagnosticLoss' or item.get('writerHealth', {}).get('failedEntries', 0):
            reason = 'diagnostic_storage_or_queue_loss'
        if reason:
            candidate_count += 1
            candidates.append({'reason': reason, 'evidence': evidence,
                               'operationId': item.get('operationId'), 'traceId': item.get('traceId')})
    continuity = []
    for (run, isolate), events in runs.items():
        sequences = sorted({e['sequence'] for e in events if isinstance(e.get('sequence'), int)})
        gaps = [[a + 1, b - 1] for a, b in zip(sequences, sequences[1:]) if b > a + 1]
        continuity.append({'appRunId': run, 'isolateId': isolate, 'eventCount': len(events),
            'observedGaps': gaps[:100], 'gapMeaning': 'may_include_window_filter_or_truncation_not_proven_loss'})
    return {'recordCount': len(records), 'candidates': list(candidates), 'runs': continuity,
            'candidateCount': candidate_count, 'candidatesTruncated': candidate_count > 200,
            'frontendRecordsWithoutBuildIdentity': missing_identity,
            'interpretation': '候选不是根因；取消也可能是正常行为。请按关联编号和源码写复现测试验证。',
            'coverage': report}


class Adb:
    def __init__(self, serial, package):
        if not re.fullmatch(r'[A-Za-z0-9_.:-]+', serial):
            raise ValueError('invalid device serial')
        if not re.fullmatch(r'[A-Za-z]\w*(?:\.[A-Za-z]\w*)+', package):
            raise ValueError('invalid package')
        self.serial, self.package = serial, package

    def run(self, *args):
        result = subprocess.run(['adb', '-s', self.serial, *args], capture_output=True, timeout=15)
        if result.returncode:
            raise RuntimeError(f'ADB read failed ({result.returncode}); check authorized debug build')
        return result.stdout.decode('utf-8', errors='replace').strip()

    def names(self):
        # 某些 adb exec-out 不传播 run-as 的失败退出码，不能误报“0条日志”。
        try:
            identity = self.run('shell', 'run-as', self.package, 'id')
        except RuntimeError:
            raise RuntimeError('应用沙箱不可直接读取；Release 请使用自动诊断通道 --release') from None
        if not re.search(r'\buid=\d+', identity):
            raise RuntimeError('应用沙箱不可直接读取；Release 请使用自动诊断通道 --release')
        entries = self.run('exec-out', 'run-as', self.package, 'ls', '-1', 'app_flutter/logs').split()
        names = [s for s in entries if LOG_NAME.fullmatch(s)]
        if 'trace' in entries:
            names.extend('trace/' + s for s in self.run('exec-out', 'run-as', self.package,
                'ls', '-1', 'app_flutter/logs/trace').split() if LOG_NAME.fullmatch('trace/' + s))
        return names

    def records(self, name, tz, report):
        if not LOG_NAME.fullmatch(name):
            raise ValueError('invalid log filename')
        path = 'app_flutter/logs/' + name
        size = int(self.run('exec-out', 'run-as', self.package, 'stat', '-c', '%s', path))
        tail = size > MAX_FILE
        if tail:
            report['limits'].append(f'{name}:only_last_{MAX_FILE}_bytes')
        command = ['tail', '-c', str(MAX_FILE), path] if tail else ['cat', path]
        proc = subprocess.Popen(['adb', '-s', self.serial, 'exec-out', 'run-as', self.package, *command],
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        timer = threading.Timer(30, proc.kill)
        timer.start()
        try:
            yield from read_records(proc.stdout, name, tz, report, tail=tail)
        finally:
            timer.cancel()
            try:
                proc.wait(timeout=0.2)
            except subprocess.TimeoutExpired:
                proc.terminate()
                proc.wait(timeout=5)
            proc.stdout.close()
        if proc.returncode != 0:
            report['limits'].append(f'{name}:read_interrupted')


def choose_device(requested):
    result = subprocess.run(['adb', 'devices'], capture_output=True, text=True, timeout=15, check=True)
    authorized = [line.split()[0] for line in result.stdout.splitlines()[1:]
                  if len(line.split()) >= 2 and line.split()[1] == 'device']
    if requested != 'auto':
        if requested not in authorized:
            raise ValueError('指定手机不在线或未授权')
        return requested
    if len(authorized) != 1:
        raise ValueError('需要恰好一台已授权手机；多台时使用 --device 明确指定，不猜设备')
    return authorized[0]


def write_private(path, value, *, lines=False):
    with path.open('x', encoding='utf-8') as stream:
        path.chmod(0o600)
        if lines:
            for item in value:
                stream.write(json.dumps(item, ensure_ascii=False, allow_nan=False) + '\n')
        else:
            json.dump(value, stream, ensure_ascii=False, indent=2, allow_nan=False)


def validate_bundle(data):
    if len(data) > MAX_OUTPUT:
        raise ValueError('诊断包超过 16MiB 上限')
    bundle = json.loads(data)
    if (not isinstance(bundle, dict) or bundle.get('format') != 'aicove-diagnostic-export'
            or bundle.get('formatVersion') != 1):
        raise ValueError('不支持的诊断包格式')
    files = bundle.get('files')
    if (not isinstance(files, dict) or len(files) > 100
            or any(not LOG_NAME.fullmatch(k) or not isinstance(v, str) for k, v in files.items())):
        raise ValueError('诊断包文件列表无效')
    now = timestamp(bundle.get('collectedAt'), timezone.utc)
    if now is None:
        raise ValueError('诊断包缺少有效采集时间')
    if not isinstance(bundle.get('coverage'), dict):
        raise ValueError('诊断包缺少覆盖说明')
    coverage = bundle['coverage']
    if not isinstance(coverage.get('limits', []), list):
        raise ValueError('诊断包覆盖限制格式无效')
    bundle['coverage'] = {
        key: coverage[key] for key in ('inputBytes', 'malformedLines', 'recordCount',
                                      'snapshotAtomic', 'processMayStillBeWriting')
        if isinstance(coverage.get(key), (int, bool))
    }
    bundle['coverage']['limits'] = [value for value in coverage.get('limits', [])[:200]
        if isinstance(value, str) and re.fullmatch(r'[A-Za-z0-9_./:-]{1,200}', value)]
    bundle['coverage']['originPolicy'] = 'exported_lines_not_original_file_line_numbers'
    return bundle


def fetch_release_bundle(args):
    """仅转发到手机 loopback；无需 run-as，不更改 app 或系统权限。"""
    token = getattr(args, 'token', None) or os.environ.get('AICOVE_DIAGNOSTIC_TOKEN', '')
    if not re.fullmatch(r'[A-Za-z0-9_-]{43}', token):
        raise ValueError('请复制手机“诊断导出与电脑读取”中的电脑命令；也可用 AICOVE_DIAGNOSTIC_TOKEN')
    port = getattr(args, 'port', 48631)
    if not 1 <= port <= 65535:
        raise ValueError('端口必须在 1..65535 之间')
    device = Adb(choose_device(args.device), args.package)
    forwarded = device.run('forward', 'tcp:0', f'tcp:{port}')
    if not re.fullmatch(r'\d{1,5}', forwarded) or not 1 <= int(forwarded) <= 65535:
        raise RuntimeError('ADB 未返回有效的本地转发端口')
    try:
        request = urllib.request.Request(f'http://127.0.0.1:{forwarded}/v1/bundle',
                                         headers={'Authorization': f'Bearer {token}'})
        # 本机流量不经过系统 HTTP 代理，也不把读取凭证随重定向转交。
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *unused):
                return None
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        try:
            with opener.open(request, timeout=90) as response:
                data = response.read(MAX_OUTPUT + 1)
        except urllib.error.HTTPError as error:
            if error.code == 401:
                raise RuntimeError('读取凭证已失效或不匹配，请复制手机上的新命令') from None
            if error.code == 409:
                raise RuntimeError('手机正在生成另一个诊断包，请稍后重试') from None
            raise RuntimeError(f'诊断通道返回 HTTP {error.code}') from None
        except (urllib.error.URLError, TimeoutError, ConnectionError):
            raise RuntimeError('诊断通道不可达，请确认应用正在运行；启动后通道会自动恢复') from None
        return validate_bundle(data), device.serial
    finally:
        device.run('forward', '--remove', f'tcp:{forwarded}')


def print_records(output, *, event=None, trace=None, limit=200):
    """只投影受控字段，完整证据仍保留在 operations.jsonl。"""
    selected = deque(maxlen=limit)
    with (output / 'operations.jsonl').open() as stream:
        for line in stream:
            item = json.loads(line)
            if event and item.get('event', item.get('stage')) != event:
                continue
            if trace and item.get('traceId') != trace:
                continue
            selected.append(item)
    for item in selected:
        print('\t'.join(str(value) for value in (
            item['time'], item['kind'], item.get('event', item.get('stage', item.get('source', '-'))),
            item.get('phase', item.get('status', item.get('level', '-'))),
            item.get('reason', item.get('ok', '-')), item.get('elapsedMs', item.get('durationMs', '-')),
            item.get('traceId', '-'), item.get('evidence', '-'))))


def collect(args):
    duration = re.fullmatch(r'(\d+)([mhd])', args.since)
    if not duration:
        raise ValueError('--since 示例 30m / 2h / 7d')
    seconds = int(duration[1]) * {'m': 60, 'h': 3600, 'd': 86400}[duration[2]]
    if not 0 < seconds <= 7 * 86400:
        raise ValueError('时间窗口必须在 1 分钟到 7 天之间')
    report = {'inputBytes': 0, 'malformedLines': 0, 'limits': [],
              'snapshotAtomic': False, 'processMayStillBeWriting': True,
              'payloadPolicy': 'no_database_no_raw_payload_no_free_text',
              'nativeExitInfo': 'not_collected_phase_2',
              'timePolicy': 'device_current_offset_for_legacy_naive_time; clock/DST changes may affect lookup'}
    device = None
    bundle = None
    from_bundle = getattr(args, 'from_bundle', None)
    release = getattr(args, 'release', False)
    if sum(bool(v) for v in (args.from_dir, from_bundle, release)) > 1:
        raise ValueError('--from-dir / --from-bundle / --release 只能选择一个')
    if from_bundle or release:
        if release:
            bundle, serial = fetch_release_bundle(args)
            report['device'] = serial
            report['transport'] = 'adb_forward_loopback_authenticated'
        else:
            with Path(from_bundle).open('rb') as stream:
                bundle = validate_bundle(stream.read(MAX_OUTPUT + 1))
            report['transport'] = 'offline_app_export'
        tz = timezone.utc
        # 离线分析仍相对于手机导出时刻，避免隔天拿到包后错误地过滤为空。
        now = timestamp(bundle['collectedAt'], tz)
        names = list(bundle['files'])
        report['sourceCoverage'] = bundle['coverage']
        report['timePolicy'] = 'app_export_utc; window_relative_to_export_time'
        report['originPolicy'] = 'lineInRead_is_exported_line_not_original_disk_line'
    elif args.from_dir:
        tz = datetime.now().astimezone().tzinfo
        now = datetime.now(timezone.utc)
        folder = Path(args.from_dir)
        paths = list(folder.iterdir())
        trace_dir = folder / 'trace'
        if trace_dir.is_dir() and not trace_dir.is_symlink():
            paths.extend(trace_dir.iterdir())
        names = [p.relative_to(folder).as_posix() for p in paths if p.is_file() and not p.is_symlink()
                 and LOG_NAME.fullmatch(p.relative_to(folder).as_posix())]
    else:
        device = Adb(choose_device(args.device), args.package)
        epoch, offset = device.run('shell', 'date', '+%s,%z').split(',')
        tz = datetime.strptime(offset, '%z').tzinfo
        now = datetime.fromtimestamp(int(epoch), timezone.utc)
        names = device.names()
        report['device'] = device.serial
        report['package'] = device.package
        report['installedPackage'] = device.run('shell', 'dumpsys', 'package', device.package)
        # 不保存整个 dumpsys（可能有路径/其他状态），只留版本和安装时间。
        report['installedPackage'] = [line.strip() for line in report['installedPackage'].splitlines()
            if any(s in line for s in ('versionCode=', 'versionName=', 'lastUpdateTime='))][:4]
    cutoff = now - timedelta(seconds=seconds)
    # 额外读时间窗之前最多七天的可用记录，找回操作开始，最终只输出关联子图。
    earliest = (now.astimezone(tz) - timedelta(days=7)).date().isoformat()
    names = sorted([n for n in names if LOG_NAME.fullmatch(n)[1] >= earliest],
        key=lambda n: (LOG_NAME.fullmatch(n)[1], 2 if n.startswith('app_') else 1 if n.startswith('trace') else 0),
        reverse=True)
    records = []
    output_bytes = 0
    for name in names:
        if report['inputBytes'] >= MAX_INPUT or output_bytes >= MAX_OUTPUT:
            break
        def local_records():
            path = folder / name
            with path.open('rb') as stream:
                tail = path.stat().st_size > MAX_FILE
                if tail:
                    stream.seek(-MAX_FILE, 2)
                    report['limits'].append(f'{name}:only_last_{MAX_FILE}_bytes')
                yield from read_records(stream, name, tz, report, tail=tail)
        if bundle is not None:
            iterator = read_records(io.BytesIO(bundle['files'][name].encode('utf-8')), name, tz, report)
        else:
            iterator = device.records(name, tz, report) if device else local_records()
        try:
            for item in iterator:
                # 为排序后追加的 evidence 行号和换行预留空间，输出也不突破预算。
                size = len(json.dumps(item).encode()) + 64
                if output_bytes + size > MAX_OUTPUT or len(records) >= 20000:
                    report['limits'].append('normalized_record_budget_reached')
                    output_bytes = MAX_OUTPUT
                    break
                records.append(item)
                output_bytes += size
        finally:
            iterator.close()
    selected = {i for i, e in enumerate(records) if timestamp(e['time'], tz) >= cutoff}
    # traceId+父子操作双向闭包；操作编号按运行隔离，不按重试共用 turnId 盲绑网络请求。
    def links(entry):
        result = set()
        if entry.get('traceId'):
            result.add(('trace', entry['traceId']))
        for key in ('operationId', 'parentOperationId'):
            if entry.get(key):
                result.add(('operation', entry.get('appRunId'), entry[key]))
        return result
    by_link = defaultdict(list)
    for i, item in enumerate(records):
        for key in links(item):
            by_link[key].append(i)
    visited_links = set()
    pending = deque(selected)
    while pending:
        for key in links(records[pending.popleft()]):
            if key in visited_links:
                continue
            visited_links.add(key)
            for i in by_link[key]:
                if i not in selected:
                    selected.add(i)
                    pending.append(i)
    records = [records[i] for i in selected]
    records.sort(key=lambda e: (e['time'], e.get('appRunId', ''), e.get('sequence', 0)))
    report['limits'] = sorted(set(report['limits']))
    report['requestedSince'] = cutoff.isoformat()
    report['collectedAtDeviceTime'] = now.isoformat()
    report['candidateFiles'] = names
    report['legacyNetworkAssociation'] = 'time_candidates_only_without_explicit_traceId; no_turnId_guess'
    report['unknownFailureCoverage'] = 'no_freeze_or_frame_buffer_yet; absence_is_not_proof'
    report['hasMatchingRecords'] = bool(records)
    report['buildMapping'] = []
    for build_id in sorted({e.get('build', {}).get('buildId', 'unknown') for e in records} - {'unknown'}):
        if not re.fullmatch(r'[a-f0-9]{64}', build_id):
            continue
        path = ROOT / 'build' / 'diagnostics' / f'{build_id}.json'
        mapping = {'buildId': build_id, 'localManifestAvailable': path.exists(),
                   'hotReloadTracked': False}
        if path.exists():
            manifest = json.loads(path.read_text())
            mismatches = []
            for name, expected in manifest.get('files', {}).items():
                source = (ROOT / name).resolve()
                if not source.is_relative_to(ROOT) or not source.is_file() or hashlib.sha256(source.read_bytes()).hexdigest() != expected:
                    mismatches.append(name)
            mapping['sourceConsistency'] = manifest.get('sourceConsistency', 'not_checked')
            mapping['currentWorkspaceMismatchCount'] = len(mismatches)
            mapping['currentWorkspaceMismatchFiles'] = mismatches[:50]
        report['buildMapping'].append(mapping)
    output = Path(args.output) if args.output else ROOT / 'build' / 'diagnostic-bundles' / uuid.uuid4().hex
    output.mkdir(parents=True, exist_ok=False, mode=0o700)
    summary = make_summary(records, report)
    write_private(output / 'operations.jsonl', records, lines=True)
    write_private(output / 'summary.json', summary)
    write_private(output / 'manifest.json', {'formatVersion': 1, **report})
    return output, summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', default='auto')
    parser.add_argument('--package', default='com.example.aicove_flutter')
    parser.add_argument('--since', default='2h')
    parser.add_argument('--from-dir', help='离线测试/已有日志目录，不访问手机')
    parser.add_argument('--from-bundle', help='读取手机保存的诊断包 JSON，无需连接手机')
    parser.add_argument('--release', action='store_true', help='通过自动读取通道采集，Debug/Release 均可用')
    parser.add_argument('--port', type=int, default=48631, help='手机读取通道端口')
    parser.add_argument('--token', help='本机读取凭证；可改用 AICOVE_DIAGNOSTIC_TOKEN 环境变量')
    parser.add_argument('--print', action='store_true', dest='print_records', help='终端展示最近200条受控事件')
    parser.add_argument('--event', help='终端输出仅显示指定事件（诊断包仍保留完整关联证据）')
    parser.add_argument('--trace', help='终端输出仅显示指定 traceId')
    parser.add_argument('--output', help='必须为尚不存在的目录，绝不覆盖已有故障包')
    args = parser.parse_args()
    try:
        output, summary = collect(args)
    except (ValueError, OSError, RuntimeError, subprocess.SubprocessError) as error:
        parser.exit(2, f'采集未完成：{error}\n')
    print(f'{output}\n记录 {summary["recordCount"]} 条；候选 {len(summary["candidates"])} 个；先读 summary.json')
    if not summary['recordCount']:
        print('没有匹配证据；不能据此认定没有发生故障。请检查时间窗口、采集版本与设备。')
    if args.print_records:
        print_records(output, event=args.event, trace=args.trace)


if __name__ == '__main__':
    main()

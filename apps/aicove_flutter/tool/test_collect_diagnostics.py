import argparse
from datetime import datetime, timedelta, timezone
import io
import json
from pathlib import Path
import tempfile
import contextlib
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
import unittest
from unittest.mock import patch

import collect_diagnostics as collector


class CollectorTest(unittest.TestCase):
    def test_run_as_denied_is_not_reported_as_empty_logs(self):
        device = collector.Adb('device_1', 'com.example.aicove_flutter')
        with patch.object(device, 'run', return_value='run-as: package not debuggable'):
            with self.assertRaisesRegex(RuntimeError, 'Release'):
                device.names()

    def bundle(self):
        return {'format': 'aicove-diagnostic-export', 'formatVersion': 1,
                'collectedAt': '2026-09-10T12:00:00Z',
                'files': {'app_2026-09-10.jsonl': json.dumps({
                    **self.event(), 'time': '2026-09-10T11:00:00Z',
                    'message': 'PRIVATE_CHAT'}) + '\n'},
                'coverage': {'limits': ['bundle_budget_reached'], 'message': 'PRIVATE_CHAT'}}

    def test_offline_release_export_uses_capture_clock_and_keeps_source_gaps(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'export.json'
            path.write_text(json.dumps(self.bundle()))
            args = argparse.Namespace(since='2h', from_dir=None, from_bundle=str(path),
                                      output=str(Path(temp) / 'out'))
            out, summary = collector.collect(args)
            self.assertEqual(summary['recordCount'], 1)
            self.assertEqual(summary['coverage']['sourceCoverage']['limits'], ['bundle_budget_reached'])
            self.assertNotIn('PRIVATE', (out / 'operations.jsonl').read_text())
            self.assertNotIn('PRIVATE', (out / 'summary.json').read_text())
            with contextlib.redirect_stdout(io.StringIO()) as captured:
                collector.print_records(out, event='animationDecision')
            self.assertIn('operations.jsonl:1', captured.getvalue())

    def test_export_rejects_unknown_paths_version_and_size(self):
        value = self.bundle()
        value['files']['../chat.db'] = 'SECRET'
        with self.assertRaises(ValueError):
            collector.validate_bundle(json.dumps(value).encode())
        value = self.bundle()
        value['formatVersion'] = 999
        with self.assertRaises(ValueError):
            collector.validate_bundle(json.dumps(value).encode())
        with self.assertRaises(ValueError):
            collector.validate_bundle(b'x' * (collector.MAX_OUTPUT + 1))

    def test_release_http_auth_and_owned_forward_cleanup(self):
        payload = json.dumps(self.bundle()).encode()
        token = 'a' * 43
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                status = 200 if self.headers.get('Authorization') == 'Bearer ' + token else 401
                self.send_response(status)
                self.end_headers()
                self.wfile.write(payload if status == 200 else b'')
            def log_message(self, *unused):
                pass
        server = HTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        args = argparse.Namespace(token=token, port=48631, device='auto', package='com.example.aicove_flutter')
        with patch.object(collector, 'choose_device', return_value='device_1'), \
                patch.object(collector.Adb, 'run', return_value=str(server.server_port)) as run:
            bundle, serial = collector.fetch_release_bundle(args)
            self.assertEqual(serial, 'device_1')
            self.assertEqual(bundle['formatVersion'], 1)
            run.assert_called_with('forward', '--remove', f'tcp:{server.server_port}')
            args.token = 'b' * 43
            with self.assertRaisesRegex(RuntimeError, '凭证'):
                collector.fetch_release_bundle(args)
            run.assert_called_with('forward', '--remove', f'tcp:{server.server_port}')

    def event(self, sequence=1, **overrides):
        value = {'time': datetime.now(timezone.utc).isoformat(), 'level': 'info',
                 'metadata': {'category': 'frontend', 'schemaVersion': 2,
                     'appRunId': 'run_1', 'sequence': sequence, 'operationId': 'op_1',
                     'traceId': 'tr_1', 'event': 'animationDecision',
                     'build': {'buildId': 'unknown'}, **overrides}}
        return value

    def test_allowlist_drops_all_free_text_and_private_payloads(self):
        event = self.event(state={'pending': True, 'apiKey': 'SECRET', 'count': 3},
                           authorization='Bearer SECRET', codeLocations=['/path/to/home', 'package:app/main.dart:12:3'])
        event['message'] = '患者聊天正文 SECRET'
        normalized = collector.normalize(event, {'file': 'app_2026-09-05.jsonl'}, timezone.utc)
        serialized = json.dumps(normalized, ensure_ascii=False)
        self.assertNotIn('SECRET', serialized)
        self.assertNotIn('聊天', serialized)
        self.assertNotIn('/Users', serialized)
        self.assertEqual(normalized['state'], {'pending': True, 'count': 3})
        self.assertEqual(normalized['sequence'], 1)

    def test_evidence_and_candidates_not_declared_root_causes(self):
        records = [collector.normalize(self.event(1, state={'animate': True, 'previouslyBuilt': True}),
                                      {'file': 'app_2026-09-05.jsonl'}, timezone.utc),
                   collector.normalize(self.event(4, event='ttsApplyDecision', reason='ownerRejected'),
                                      {'file': 'app_2026-09-05.jsonl'}, timezone.utc)]
        summary = collector.make_summary(records, {})
        self.assertEqual(summary['candidates'][0]['reason'], 'old_bubble_animation')
        self.assertEqual(summary['candidates'][1]['evidence'], 'operations.jsonl:2')
        self.assertEqual(summary['runs'][0]['observedGaps'], [[2, 3]])
        self.assertEqual(summary['frontendRecordsWithoutBuildIdentity'], 2)

    def test_incomplete_tail_and_oversize_are_explicit(self):
        report = {'inputBytes': 0, 'limits': [], 'malformedLines': 0}
        stream = io.BytesIO(b'x' * (collector.MAX_LINE + 20) + b'\n' +
                            json.dumps(self.event()).encode() + b'\n' + b'{"time":')
        records = list(collector.read_records(stream, 'app_2026-09-05.jsonl', timezone.utc, report))
        self.assertEqual(len(records), 1)
        self.assertTrue(any('oversize' in s for s in report['limits']))
        self.assertTrue(any('incomplete_tail' in s for s in report['limits']))

    def test_old_parent_outside_window_is_restored_without_unrelated_plaintext(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp) / 'logs'
            folder.mkdir()
            older = self.event(1)
            older['time'] = (datetime.now(timezone.utc) - timedelta(hours=3)).isoformat()
            child = self.event(2, operationId='tts_2', parentOperationId='op_1', event='ttsRequested')
            path = folder / f'app_{datetime.now().date().isoformat()}.jsonl'
            path.write_text('\n'.join(json.dumps(e) for e in (older, child)) + '\n')
            (folder / 'chat.db').write_text('PRIVATE DATABASE')
            args = argparse.Namespace(since='2h', from_dir=str(folder), output=str(Path(temp) / 'out'))
            out, summary = collector.collect(args)
            self.assertEqual(summary['recordCount'], 2)
            self.assertEqual((out / 'operations.jsonl').stat().st_mode & 0o777, 0o600)
            self.assertFalse(summary['coverage']['snapshotAtomic'])
            self.assertNotIn('PRIVATE', (out / 'operations.jsonl').read_text())
            with self.assertRaises(FileExistsError):
                collector.collect(args)

    def test_real_nested_index_and_trace_less_parent_closure(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp) / 'logs'
            (folder / 'trace').mkdir(parents=True)
            old_time = (datetime.now(timezone.utc) - timedelta(hours=3)).isoformat()
            parent = self.event(1, operationId='parent', traceId=None)
            child = self.event(2, operationId='child', parentOperationId='parent', traceId=None)
            child['time'] = old_time
            unrelated = self.event(3, operationId='parent', appRunId='another_run', traceId=None)
            unrelated['time'] = old_time
            day = datetime.now().date().isoformat()
            (folder / f'app_{day}.jsonl').write_text('\n'.join(json.dumps(e) for e in [parent, child, unrelated]) + '\n')
            (folder / 'trace' / f'index_{day}.jsonl').write_text(json.dumps({
                'startedAt': datetime.now().isoformat(), 'traceId': 'real_trace', 'stage': 'TURN_FAILED', 'status': 'failed',
                'payloadRef': {'secret': 'DO_NOT_EXPORT'}}) + '\n')
            args = argparse.Namespace(since='2h', from_dir=str(folder), output=str(Path(temp) / 'out'))
            out, summary = collector.collect(args)
            self.assertEqual(summary['recordCount'], 3)
            self.assertEqual(summary['candidateCount'], 1)
            content = (out / 'operations.jsonl').read_text()
            self.assertNotIn('another_run', content)
            self.assertNotIn('DO_NOT_EXPORT', content)
            self.assertIn('child', content)

    def test_no_silent_device_choice_and_no_shell_injection(self):
        with patch('subprocess.run') as run:
            run.return_value.stdout = 'List of devices attached\na\tdevice\nb\tdevice\n'
            with self.assertRaises(ValueError):
                collector.choose_device('auto')
        with self.assertRaises(ValueError):
            collector.Adb('x;rm', 'com.example.app')
        with self.assertRaises(ValueError):
            collector.Adb('phone', 'com.example;bad')

    def test_token_read_from_adb_shell_when_not_given(self):
        device = collector.Adb('phone', 'com.example.app')
        token = 'c' * 43
        with patch.dict('os.environ', {}, clear=True), \
                patch.object(device, 'run', return_value=f'Row: 0 token={token}') as run:
            self.assertEqual(collector.resolve_token(device), token)
        run.assert_called_once_with('shell', 'content', 'query', '--uri',
                                    'content://com.example.app.diagnostics/token')
        with patch.dict('os.environ', {}, clear=True), \
                patch.object(device, 'run', return_value='No result found.'):
            with self.assertRaises(RuntimeError):
                collector.resolve_token(device)
        with patch.object(device, 'run') as run:
            self.assertEqual(collector.resolve_token(device, 'd' * 43), 'd' * 43)
        run.assert_not_called()

    def test_android_ls_columns_and_real_nested_trace_path(self):
        device = collector.Adb('phone', 'com.example.app')
        with patch.object(device, 'run', side_effect=[
            'uid=10123(u0_a123) gid=10123(u0_a123)',
            'app_2026-09-05.jsonl  api_2026-09-05.jsonl  trace',
            'index_2026-09-05.jsonl  payloads']):
            self.assertEqual(set(device.names()), {
                'app_2026-09-05.jsonl', 'api_2026-09-05.jsonl', 'trace/index_2026-09-05.jsonl'})

    def test_trace_and_api_never_export_body(self):
        event = {'time': datetime.now().isoformat(), 'traceId': 'tr_1', 'stage': 'MODEL_RESPONSE',
                 'rawResponseBody': 'SECRET', 'meta': {'content': 'SECRET'}, 'payloadRef': {'path': 'SECRET'}}
        output = collector.normalize(event, {'file': 'trace_2026-09-05.jsonl'}, timezone.utc)
        self.assertEqual(output['traceId'], 'tr_1')
        self.assertNotIn('SECRET', json.dumps(output))


if __name__ == '__main__':
    unittest.main()

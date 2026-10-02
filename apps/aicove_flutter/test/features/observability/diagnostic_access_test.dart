import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/features/observability/diagnostic_access_service.dart';
import 'package:aicove_flutter/src/features/observability/diagnostic_bundle.dart';

void main() {
  test('出口过滤正文、凭据与自由错误，只保留可关联状态', () {
    final item = sanitizeDiagnosticEntry({
      'time': '2026-09-10T12:00:00+08:00',
      'message': 'PRIVATE_CHAT',
      'authorization': 'SECRET_KEY',
      'metadata': {
        'category': 'frontend',
        'event': 'ttsFailed',
        'operationId': 'op_1',
        'phase': 'error',
        'errorSummary': 'PRIVATE_CHAT',
        'state': {'playing': false, 'count': 2, 'body': 'PRIVATE_CHAT'},
        'build': {
          'buildId': 'build_1',
          'flutterMode': 'release',
          'secret': 'SECRET_KEY'
        },
        'codeLocations': [
          'package:app/main.dart:1:2',
          '/home/kuobibulaien/file.dart:2'
        ],
      },
    }, 'app_2026-09-10.jsonl')!;
    final encoded = jsonEncode(item);
    expect(encoded, isNot(contains('PRIVATE')));
    expect(encoded, isNot(contains('SECRET')));
    expect(encoded, isNot(contains('/Users')));
    expect(item['time'], '2026-09-10T04:00:00.000Z');
    expect((item['metadata'] as Map)['operationId'], 'op_1');
    expect(encoded, contains('release'));
  });

  test('只导出允许文件，报告半行和坏行，不跟随符号链接', () async {
    final dir = await Directory.systemTemp.createTemp('diagnostic_export_test');
    addTearDown(() => dir.delete(recursive: true));
    final time = DateTime(2026, 9, 10, 12);
    await File('${dir.path}/app_2026-09-10.jsonl').writeAsString('${jsonEncode({
          'time': time.toIso8601String(),
          'message': 'PRIVATE'
        })}\nBAD\n{"time":');
    await File('${dir.path}/chat.db').writeAsString('PRIVATE_DB');
    await Link('${dir.path}/api_2026-09-10.jsonl')
        .create('${dir.path}/chat.db');
    await Directory('${dir.path}/trace/payloads').create(recursive: true);
    await File('${dir.path}/trace/payloads/data.json')
        .writeAsString('PRIVATE_BODY');
    final text = utf8.decode(await createDiagnosticBundle(dir.path, now: time));
    final bundle = jsonDecode(text) as Map;
    expect(text, isNot(contains('PRIVATE')));
    expect((bundle['files'] as Map).keys, ['app_2026-09-10.jsonl']);
    expect(bundle['coverage']['malformedLines'], 1);
    expect(bundle['coverage']['limits'],
        contains('app_2026-09-10.jsonl:incomplete_or_unread_tail'));
  });

  test('预算截断与日志目录缺失明确报告', () async {
    final dir = await Directory.systemTemp.createTemp('diagnostic_limits_test');
    addTearDown(() => dir.delete(recursive: true));
    final time = DateTime(2026, 9, 10);
    final line =
        '${jsonEncode({'time': time.toIso8601String(), 'level': 'error'})}\n';
    await File('${dir.path}/app_2026-09-10.jsonl').writeAsString(line * 10);
    final bundle = jsonDecode(utf8.decode(
        await createDiagnosticBundle(dir.path, now: time, maxRecords: 2)));
    expect(bundle['coverage']['recordCount'], 2);
    expect(bundle['coverage']['limits'], contains('bundle_budget_reached'));
    final missing = jsonDecode(
        utf8.decode(await createDiagnosticBundle('${dir.path}/missing')));
    expect(missing['coverage']['limits'], contains('log_directory_missing'));
  });

  test('本机服务验证凭证、路径、并发与资源释放', () async {
    final pending = Completer<Uint8List>();
    final entered = Completer<void>();
    final service = DiagnosticAccessService(
        port: 0,
        tokenLoader: () async => 'a' * 43,
        bundleBuilder: () {
          entered.complete();
          return pending.future;
        });
    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    addTearDown(() async {
      client.close(force: true);
      await service.stop();
    });
    await service.start();
    final session = service.session.value!;
    Future<HttpClientResponse> request(
        {String? token, String path = '/v1/bundle'}) async {
      final request = await client
          .getUrl(Uri.parse('http://127.0.0.1:${session.port}$path'));
      if (token != null) request.headers.set('Authorization', 'Bearer $token');
      return request.close();
    }

    var response = await request();
    expect(response.statusCode, 401);
    await response.drain<void>();
    response = await request(token: 'wrong');
    expect(response.statusCode, 401);
    await response.drain<void>();
    response = await request(token: session.token, path: '/logs/../chat.db');
    expect(response.statusCode, 404);
    await response.drain<void>();
    final first = request(token: session.token);
    // Wait until the injected snapshot has actually started, without a timing race.
    await entered.future;
    response = await request(token: session.token);
    expect(response.statusCode, 409);
    await response.drain<void>();
    pending.complete(Uint8List.fromList(utf8.encode('{"safe":true}')));
    response = await first;
    expect(response.statusCode, 200);
    expect(await utf8.decoder.bind(response).join(), '{"safe":true}');
    await service.stop();
    expect(service.session.value, isNull);
    await expectLater(Socket.connect('127.0.0.1', session.port),
        throwsA(isA<SocketException>()));
  });

  test('无需页面即可自动启动，重建服务保持原凭证', () async {
    String? saved;
    var writes = 0;
    Future<String> load() => loadDiagnosticAccessToken(
          read: () async => saved,
          write: (value) async {
            saved = value;
            writes++;
          },
        );
    Future<DiagnosticAccessService> boot() async {
      final service = DiagnosticAccessService(port: 0, tokenLoader: load);
      final ready = Completer<void>();
      service.session.addListener(() {
        if (service.session.value != null && !ready.isCompleted) {
          ready.complete();
        }
      });
      service.startAutomatically();
      await ready.future.timeout(const Duration(seconds: 3));
      return service;
    }

    final first = await boot();
    addTearDown(first.stop);
    final token = first.session.value!.token;
    expect(token.length, 43);
    await first.stop();
    final second = await boot();
    addTearDown(second.stop);
    expect(second.session.value!.token, token);
    expect(writes, 1);
  });

  test('安全存储失败时不开放临时通道，恢复后可再次启动', () async {
    var fails = true;
    final service = DiagnosticAccessService(
        port: 0,
        tokenLoader: () async {
          if (fails) throw StateError('storage unavailable');
          return 'a' * 43;
        });
    addTearDown(service.stop);
    await expectLater(service.start(), throwsStateError);
    expect(service.session.value, isNull);
    fails = false;
    await service.start();
    expect(service.session.value, isNotNull);
  });
}

import 'dart:io';

import 'package:aicove_flutter/src/features/voice_call/data/local_asr_model_installer.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late HttpServer server;
  late Directory dir;
  final requests = <String>[];
  final good = List<int>.generate(4096, (i) => i % 251);
  final bad = List<int>.filled(4096, 7);

  setUp(() async {
    requests.clear();
    dir = await Directory.systemTemp.createTemp('asr_install_');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      requests.add(request.uri.path);
      final res = request.response;
      switch (request.uri.path) {
        case '/good':
          res.add(good);
        case '/bad':
          res.add(bad);
        case '/slow':
          res
            ..bufferOutput = false
            ..contentLength = good.length * 100
            ..add(good);
          return; // 不结束，等客户端取消
        default:
          res.statusCode = 404;
      }
      res.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    await dir.delete(recursive: true);
  });

  String url(String path) => 'http://127.0.0.1:${server.port}$path';

  LocalAsrModelFile file(String name, List<String> paths) => LocalAsrModelFile(
    relativePath: 'sub/$name',
    size: good.length,
    sha256: sha256.convert(good).toString(),
    urls: paths.map(url).toList(),
  );

  test(
    'falls back to the next mirror when a download fails or mismatches',
    () async {
      final progress = <int>[];
      final installer = LocalAsrModelInstaller(
        dir: dir.path,
        files: [
          file('a.onnx', ['/missing', '/bad', '/good']),
        ],
      );
      await installer.install(
        onProgress: (received, _) => progress.add(received),
      );

      final target = File('${dir.path}/sub/a.onnx');
      expect(target.readAsBytesSync(), good);
      expect(File('${target.path}.part').existsSync(), isFalse);
      expect(requests, ['/missing', '/bad', '/good']);
      expect(progress.last, good.length);
    },
  );

  test(
    'skips files already installed and only fetches the missing ones',
    () async {
      File('${dir.path}/sub/a.onnx')
        ..createSync(recursive: true)
        ..writeAsBytesSync(good);
      final installer = LocalAsrModelInstaller(
        dir: dir.path,
        files: [
          file('a.onnx', ['/good']),
          file('b.onnx', ['/good']),
        ],
      );
      await installer.install();
      expect(requests, ['/good']);
      expect(File('${dir.path}/sub/b.onnx').existsSync(), isTrue);
    },
  );

  test(
    'fails without leaving a usable file when every mirror is wrong',
    () async {
      final installer = LocalAsrModelInstaller(
        dir: dir.path,
        files: [
          file('a.onnx', ['/bad']),
        ],
      );
      await expectLater(
        installer.install(),
        throwsA(isA<LocalAsrInstallException>()),
      );
      expect(File('${dir.path}/sub/a.onnx').existsSync(), isFalse);
      expect(File('${dir.path}/sub/a.onnx.part').existsSync(), isFalse);
    },
  );

  test('cancel stops the download and cleans up the partial file', () async {
    final cancel = CancelToken();
    final installer = LocalAsrModelInstaller(
      dir: dir.path,
      files: [
        file('a.onnx', ['/slow', '/good']),
      ],
    );
    final future = installer.install(
      cancelToken: cancel,
      onProgress: (received, _) {
        if (received > 0) cancel.cancel();
      },
    );
    await expectLater(
      future,
      throwsA(
        isA<DioException>().having(CancelToken.isCancel, 'cancel', isTrue),
      ),
    );
    expect(requests, ['/slow']);
    expect(Directory('${dir.path}/sub').listSync(), isEmpty);
  });

  test('uninstall removes the model directory', () async {
    File('${dir.path}/sub/a.onnx')
      ..createSync(recursive: true)
      ..writeAsBytesSync(good);
    await LocalAsrModelInstaller(dir: '${dir.path}/sub').uninstall();
    expect(Directory('${dir.path}/sub').existsSync(), isFalse);
  });

  test('the pinned model set matches the recognizer layout', () {
    expect(
      kLocalCallAsrModelFiles.map((f) => f.relativePath),
      containsAll([
        'silero_vad_v5.onnx',
        'sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09/model.int8.onnx',
        'sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09/tokens.txt',
      ]),
    );
  });
}

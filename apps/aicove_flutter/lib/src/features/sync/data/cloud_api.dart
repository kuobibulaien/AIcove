import 'dart:io';
import 'dart:convert';
import 'dart:isolate';
import 'package:archive/archive_io.dart';

import 'package:dio/dio.dart';

import '../../account/domain/account_port.dart';
import 'cloud_document.dart';

abstract interface class CloudRemote {
  Future<Map<String, dynamic>> get(String path, [Map<String, dynamic>? query]);
  Future<Map<String, dynamic>> post(String path, Map<String, dynamic> body);
  Future<void> upload(String digest, File file);
  Future<void> uploadBatch(Map<String, File> files);
  Future<void> download(String digest, File target);
  void close();
}

class CloudApi implements CloudRemote {
  CloudApi(AccountConnection connection)
    : _dio = Dio(
        BaseOptions(
          baseUrl: '${connection.server}/api/v1/sync/v3/',
          followRedirects: false,
          headers: {'Authorization': 'Bearer ${connection.token}'},
          connectTimeout: const Duration(seconds: 20),
          receiveTimeout: const Duration(minutes: 3),
          sendTimeout: const Duration(minutes: 3),
        ),
      );
  final Dio _dio;
  bool _gzip = false, _batch = false;

  Future<T> _call<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      if (status == 401) throw const CloudSyncFailure('登录已过期，请重新登录后继续同步');
      if (status == 413) throw const CloudSyncFailure('单条消息或附件过大，已保留本地数据');
      final data = error.response?.data;
      final detail = data is Map ? data['detail'] : null;
      if (detail is Map && detail['code'] == 'epoch_mismatch') {
        throw const CloudSyncFailure('云端数据已恢复到另一版本，已暂停同步并保留本地数据');
      }
      throw CloudSyncFailure(
        status == null ? '暂时无法连接服务器，稍后会继续同步' : '云同步请求未完成（$status），本地数据已保留',
      );
    }
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, [
    Map<String, dynamic>? query,
  ]) => _call(() async {
    final data = Map<String, dynamic>.from(
      (await _dio.get(path, queryParameters: query)).data as Map,
    );
    if (path == 'status') {
      _gzip = data['json_gzip'] == true;
      _batch = data['blob_batch_version'] == 1;
    }
    return data;
  });
  @override
  Future<Map<String, dynamic>> post(String path, Map<String, dynamic> body) =>
      _call(() async {
        final Object data = _gzip ? await _gzipJson(body) : body;
        return Map<String, dynamic>.from(
          (await _dio.post(
                path,
                data: data,
                options: _gzip
                    ? Options(
                        contentType: 'application/json',
                        headers: {'Content-Encoding': 'gzip'},
                      )
                    : null,
              )).data
              as Map,
        );
      });

  @override
  Future<void> uploadBatch(Map<String, File> files) async {
    if (files.isEmpty) return;
    if (!_batch) {
      for (final entry in files.entries) {
        await upload(entry.key, entry.value);
      }
      return;
    }
    // Bounded archives amortize network latency without duplicating the library.
    final groups = <Map<String, File>>[];
    var group = <String, File>{}, bytes = 0;
    for (final entry in files.entries) {
      final size = await entry.value.length();
      if (group.isNotEmpty &&
          (group.length == 64 || bytes + size > 12 * 1024 * 1024)) {
        groups.add(group);
        group = {};
        bytes = 0;
      }
      group[entry.key] = entry.value;
      bytes += size;
      if (bytes > 12 * 1024 * 1024) {
        groups.add(group);
        group = {};
        bytes = 0;
      }
    }
    if (group.isNotEmpty) groups.add(group);
    var next = 0;
    Future<void> worker() async {
      while (next < groups.length) {
        final items = groups[next++];
        if (items.length == 1) {
          await upload(items.keys.single, items.values.single);
          continue;
        }
        final temporary = await Directory.systemTemp.createTemp(
          'aicove-upload-',
        );
        try {
          final archive = File('${temporary.path}/files.zip');
          await _zipFiles(archive.path, {
            for (final e in items.entries) e.key: e.value.path,
          });
          await _call(() async {
            final response = await _dio.put(
              'blobs/batch',
              data: archive.openRead(),
              options: Options(
                contentType: 'application/zip',
                headers: {Headers.contentLengthHeader: await archive.length()},
              ),
            );
            final confirmed = {
              for (final item in response.data['blobs'] as List) item['digest'],
            };
            if (confirmed.length != items.length ||
                !confirmed.containsAll(items.keys)) {
              throw const CloudSyncFailure('服务器未确认完整附件批次，稍后安全重试');
            }
          });
        } finally {
          await temporary.delete(recursive: true);
        }
      }
    }

    await Future.wait(
      List.generate(groups.length.clamp(1, 3), (_) => worker()),
    );
  }

  @override
  Future<void> upload(String digest, File file) => _call(() async {
    await _dio.put(
      'blobs/$digest',
      data: file.openRead(),
      options: Options(
        contentType: 'application/octet-stream',
        headers: {Headers.contentLengthHeader: await file.length()},
      ),
    );
  });
  @override
  Future<void> download(String digest, File target) => _call(() async {
    await _dio.download('blobs/$digest', target.path);
  });
  @override
  void close() => _dio.close(force: true);
}

Future<List<int>> _gzipJson(Map<String, dynamic> body) => Isolate.run(
  () => GZipCodec(level: 3).encode(utf8.encode(jsonEncode(body))),
);
Future<void> _zipFiles(String output, Map<String, String> sources) =>
    Isolate.run(() async {
      final encoder = ZipFileEncoder();
      encoder.create(output, level: ZipFileEncoder.STORE);
      try {
        for (final entry in sources.entries) {
          await encoder.addFile(
            File(entry.value),
            entry.key,
            ZipFileEncoder.STORE,
          );
        }
      } finally {
        await encoder.close();
      }
    });

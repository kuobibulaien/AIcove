import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import 'sherpa_local_speech_recognizer.dart';

/// 本地识别模型里的一个文件：按固定版本下载，大小和 SHA-256 都校验。
class LocalAsrModelFile {
  const LocalAsrModelFile({
    required this.relativePath,
    required this.size,
    required this.sha256,
    required this.urls,
  });

  /// 相对模型目录的路径，与 [SherpaLocalModelFiles.inDirectory] 的布局一致。
  final String relativePath;
  final int size;
  final String sha256;

  /// 依次尝试的下载地址：国内镜像在前，官方源兜底。
  final List<String> urls;
}

const _senseVoiceRepo =
    'csukuangfj/${SherpaLocalModelFiles.senseVoiceDirName}/resolve/355f4d4884d8afd08aef04b9007a8556d7b463b2';
const _vadRepo =
    'csukuangfj/vad/resolve/fba88cd2e921609e7675c3aaf51e0b9b295da4bc';

List<String> _hfUrls(String repoPath, String file) => [
  'https://hf-mirror.com/$repoPath/$file',
  'https://huggingface.co/$repoPath/$file',
];

/// 本地通话识别（Silero VAD＋SenseVoice）需要的全部文件，版本与选型基准一致。
final kLocalCallAsrModelFiles = <LocalAsrModelFile>[
  LocalAsrModelFile(
    relativePath: 'silero_vad_v5.onnx',
    size: 2313101,
    sha256: '6b99cbfd39246b6706f98ec13c7c50c6b299181f2474fa05cbc8046acc274396',
    urls: [
      ..._hfUrls(_vadRepo, 'silero_vad_v5.onnx'),
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad_v5.onnx',
    ],
  ),
  LocalAsrModelFile(
    relativePath: '${SherpaLocalModelFiles.senseVoiceDirName}/tokens.txt',
    size: 315894,
    sha256: 'f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc',
    urls: _hfUrls(_senseVoiceRepo, 'tokens.txt'),
  ),
  LocalAsrModelFile(
    relativePath: '${SherpaLocalModelFiles.senseVoiceDirName}/model.int8.onnx',
    size: 237115547,
    sha256: '12ca1a2ae7ecf3e0019ef2822307ee0b5cadc9196569e379b4c4026f8205276d',
    urls: _hfUrls(_senseVoiceRepo, 'model.int8.onnx'),
  ),
];

class LocalAsrInstallException implements Exception {
  const LocalAsrInstallException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 把本地识别模型下载到 [dir]。
///
/// 每个文件先写 `.part`，大小和 SHA-256 都对上才改名为正式文件，所以正式文件存在即完整；
/// 已装好的文件会跳过，中途失败或取消后再次安装只补缺的文件。
class LocalAsrModelInstaller {
  LocalAsrModelInstaller({
    required this.dir,
    Dio? dio,
    List<LocalAsrModelFile>? files,
  }) : _dio = dio ?? Dio(),
       files = files ?? kLocalCallAsrModelFiles;

  final String dir;
  final List<LocalAsrModelFile> files;
  final Dio _dio;

  int get totalBytes => files.fold(0, (sum, f) => sum + f.size);

  /// [onProgress] 报告所有文件合计的已下载字节数；取消时抛出 [DioException]（类型 cancel）。
  Future<void> install({
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final total = totalBytes;
    var done = 0;
    for (final file in files) {
      final target = File('$dir/${file.relativePath}');
      if (!target.existsSync() || target.lengthSync() != file.size) {
        await target.parent.create(recursive: true);
        await _download(
          file,
          target,
          cancelToken: cancelToken,
          onReceived: (received) => onProgress?.call(done + received, total),
        );
      }
      done += file.size;
      onProgress?.call(done, total);
    }
  }

  Future<void> _download(
    LocalAsrModelFile file,
    File target, {
    required void Function(int received) onReceived,
    CancelToken? cancelToken,
  }) async {
    final part = File('${target.path}.part');
    Object? lastError;
    for (final url in file.urls) {
      try {
        await _dio.download(
          url,
          part.path,
          cancelToken: cancelToken,
          deleteOnError: true,
          onReceiveProgress: (received, _) => onReceived(received),
        );
        final length = part.lengthSync();
        if (length != file.size) {
          throw LocalAsrInstallException('文件大小不对（$length / ${file.size}）');
        }
        final digest = await sha256.bind(part.openRead()).first;
        if (digest.toString() != file.sha256) {
          throw const LocalAsrInstallException('文件校验失败');
        }
        await part.rename(target.path);
        return;
      } on DioException catch (e) {
        if (CancelToken.isCancel(e)) {
          if (part.existsSync()) await part.delete();
          rethrow;
        }
        lastError = e.message ?? e.type.name;
      } catch (e) {
        lastError = e;
      }
      if (part.existsSync()) await part.delete();
      onReceived(0);
    }
    throw LocalAsrInstallException('${file.relativePath} 下载失败：$lastError');
  }

  /// 删除整个模型目录。
  Future<void> uninstall() async {
    final directory = Directory(dir);
    if (directory.existsSync()) await directory.delete(recursive: true);
  }
}

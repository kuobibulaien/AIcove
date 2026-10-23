import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// 可选下载套组的一个下载源。
class StickerPackMirror {
  const StickerPackMirror(this.name, this.url, {this.domestic = false});

  final String name;
  final String url;

  /// 国内节点：在国内时优先使用。
  final bool domestic;
}

/// 动图表情包：Gitee 与 GitHub 各存一份，内容相同，互为兜底。
const List<StickerPackMirror> gifStickerPackMirrors = [
  StickerPackMirror(
    'Gitee',
    'https://gitee.com/koubibulaien/AIcove-stickers/releases/download/v1/AIcove-gif-stickers-v1.zip',
    domestic: true,
  ),
  StickerPackMirror(
    'GitHub',
    'https://github.com/kuobibulaien/AIcove-stickers/releases/download/v1/AIcove-gif-stickers-v1.zip',
  ),
];

/// 粗略判断是否在国内：用设备时区（东八区）。只决定先试哪个源，判断错了也有兜底。
bool deviceLikelyInChina() =>
    DateTime.now().timeZoneOffset == const Duration(hours: 8);

/// 下载前探测节点：并发请求各源，按「能连上 → 国内优先（在国内时）→ 延迟」排序。
/// 连不上的源排在最后，仍会作为兜底去试。
Future<List<StickerPackMirror>> rankStickerPackMirrors(
  http.Client client,
  List<StickerPackMirror> mirrors, {
  required bool inChina,
  Duration timeout = const Duration(seconds: 4),
}) async {
  Future<Duration?> probe(StickerPackMirror mirror) async {
    final watch = Stopwatch()..start();
    try {
      final response = await client
          .head(Uri.parse(mirror.url))
          .timeout(timeout);
      return response.statusCode < 400 ? watch.elapsed : null;
    } catch (_) {
      return null;
    }
  }

  final latencies = await Future.wait(mirrors.map(probe));
  final indexed = [for (var i = 0; i < mirrors.length; i++) i];
  int rank(int i) {
    if (latencies[i] == null) return 2;
    return inChina && mirrors[i].domestic ? 0 : 1;
  }

  indexed.sort((a, b) {
    final byRank = rank(a).compareTo(rank(b));
    if (byRank != 0) return byRank;
    final la = latencies[a], lb = latencies[b];
    if (la == null || lb == null) return a.compareTo(b);
    return la.compareTo(lb);
  });
  return [for (final i in indexed) mirrors[i]];
}

/// 按探测顺序逐个下载，失败（非 200、超时、拿到的不是 ZIP）就换下一个源。
Future<({Uint8List bytes, StickerPackMirror mirror})> downloadStickerPack(
  http.Client client,
  List<StickerPackMirror> mirrors, {
  bool? inChina,
  Duration timeout = const Duration(minutes: 5),
}) async {
  final ranked = await rankStickerPackMirrors(
    client,
    mirrors,
    inChina: inChina ?? deviceLikelyInChina(),
  );
  final errors = <String>[];
  for (final mirror in ranked) {
    try {
      final response = await client
          .get(Uri.parse(mirror.url))
          .timeout(timeout);
      final bytes = response.bodyBytes;
      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }
      // 被重定向到登录页或错误页时拿到的是 HTML，按 ZIP 文件头识别。
      if (bytes.length < 4 || bytes[0] != 0x50 || bytes[1] != 0x4B) {
        throw Exception('返回的不是 ZIP 文件');
      }
      return (bytes: bytes, mirror: mirror);
    } catch (error) {
      errors.add('${mirror.name}：$error');
    }
  }
  throw Exception(errors.join('；'));
}

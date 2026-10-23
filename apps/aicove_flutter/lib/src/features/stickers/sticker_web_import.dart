import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'sticker_library.dart';
import '../../core/network/public_network.dart';

/// 从一个网页里找表情图并下载（给 AIcove酱 的导入工具用）。
///
/// 图片地址只从两处取：微信图片消息脚本里的 `cdn_url`，以及普通 `<img>` 的
/// `data-src`／`src`。封面（og:image）不算表情。下载后按尺寸过滤头像之类的小图，
/// 入库去重交给 [StickerLibrary.importFiles]。
class StickerWebPage {
  const StickerWebPage({
    required this.title,
    required this.images,
    required this.foundCount,
    required this.smallCount,
    required this.failedCount,
  });

  /// 页面标题（og:title 优先）。
  final String title;

  /// 下载并通过尺寸检查的图片，文件名为 `image-01.jpg` 这类无意义名字，
  /// 所以入库后是「未标注」，要用户或 AIcove酱 之后再打标。
  final List<StickerImportFile> images;

  /// 页面里找到的图片地址数（去重后）。
  final int foundCount;

  /// 因为太小（头像、图标）被跳过的张数。
  final int smallCount;

  /// 下载或解码失败的张数。
  final int failedCount;
}

class StickerWebException implements Exception {
  const StickerWebException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 单张表情的最短边，小于它的图视为头像、图标。
const int stickerWebMinSide = 300;

/// 一个页面最多处理的图片数，防止恶意页面撑爆内存。
const int stickerWebMaxImages = 60;

const int _maxPageBytes = 8 * 1024 * 1024;
const Duration _timeout = Duration(seconds: 20);
const String _userAgent =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 '
    '(KHTML, like Gecko) Version/17.0 Safari/605.1.15';

final RegExp _imgTag = RegExp(r'<img\b[^>]*>', caseSensitive: false);
final RegExp _cdnUrl = RegExp(r"cdn_url:\s*'([^']+)'");
final RegExp _ogImage = RegExp(
  r'<meta[^>]+(?:property|name)="(?:og|twitter):image[^"]*"[^>]*content="([^"]+)"',
  caseSensitive: false,
);
final RegExp _title = RegExp(
  r'<meta[^>]+property="og:title"[^>]*content="([^"]*)"',
  caseSensitive: false,
);

/// 检查链接格式：只认 http(s)，支持本机、内网与代理 fake-IP。
String? checkFetchableUri(Uri uri, {bool allowPrivateHosts = false}) =>
    PublicNetwork.checkUri(uri, allowPrivateHosts: allowPrivateHosts);

/// 页面里的表情图地址，按出现顺序去重，排除封面。
///
/// 同一张图的身份看「域名＋路径」：微信的查询参数（wx_fmt、from）只是格式和来源，
/// 同一张图换个参数也算同一张。
List<Uri> stickerImageUrlsIn(String html, Uri page) {
  final excluded = {
    for (final match in _ogImage.allMatches(html))
      if (_resolve(match.group(1)!, page) case final cover?) _identity(cover),
  };
  final seen = <String>{};
  final result = <Uri>[];

  void add(String raw) {
    final uri = _resolve(raw, page);
    if (uri == null) return;
    final key = _identity(uri);
    if (excluded.contains(key) || !seen.add(key)) return;
    result.add(uri);
  }

  // 微信图片消息：图片列表写在脚本里，字符串里的 \x26 是 &
  for (final match in _cdnUrl.allMatches(html)) {
    add(match.group(1)!.replaceAll(r'\x26amp;', '&').replaceAll(r'\x26', '&'));
  }
  for (final match in _imgTag.allMatches(html)) {
    final tag = match.group(0)!;
    final raw = _attribute(tag, 'data-src') ?? _attribute(tag, 'src');
    if (raw != null) add(raw.replaceAll('&amp;', '&'));
  }
  return result;
}

String _identity(Uri uri) => '${uri.host}${uri.path}';

String? _attribute(String tag, String name) => RegExp(
  '(?<![\\w-])$name\\s*=\\s*["\']([^"\']+)["\']',
  caseSensitive: false,
).firstMatch(tag)?.group(1);

Uri? _resolve(String raw, Uri page) {
  final uri = page.resolve(raw.trim());
  return uri.scheme == 'http' || uri.scheme == 'https' ? uri : null;
}

/// 抓取页面并下载其中的表情图。
///
/// [allowPrivateHosts] 保留兼容旧调用；本机和内网地址始终可访问。
Future<StickerWebPage> fetchStickerPage(
  Uri page, {
  bool allowPrivateHosts = false,
}) async {
  final client = PublicNetwork(allowPrivateHosts: allowPrivateHosts);
  try {
    final html = utf8.decode(
      await _get(
        client,
        page,
        maxBytes: _maxPageBytes,
        allowPrivateHosts: allowPrivateHosts,
      ),
      allowMalformed: true,
    );
    final urls = stickerImageUrlsIn(html, page);
    final images = <StickerImportFile>[];
    var small = 0;
    var failed = 0;
    for (final url in urls.take(stickerWebMaxImages)) {
      final bytes = await _tryGetImage(
        client,
        url,
        referer: page,
        allowPrivateHosts: allowPrivateHosts,
      );
      if (bytes == null) {
        failed += 1;
        continue;
      }
      final decoded = img.decodeImage(bytes);
      final ext = _extensionOf(bytes);
      if (decoded == null || ext == null) {
        failed += 1;
      } else if (decoded.width < stickerWebMinSide ||
          decoded.height < stickerWebMinSide) {
        small += 1;
      } else {
        final index = (images.length + 1).toString().padLeft(2, '0');
        images.add(StickerImportFile('image-$index.$ext', bytes));
      }
    }
    return StickerWebPage(
      title: _titleOf(html),
      images: images,
      foundCount: urls.length,
      smallCount: small,
      failedCount: failed,
    );
  } finally {
    client.close();
  }
}

Future<Uint8List?> _tryGetImage(
  PublicNetwork client,
  Uri url, {
  required Uri referer,
  required bool allowPrivateHosts,
}) async {
  try {
    final bytes = await _get(
      client,
      url,
      referer: referer,
      maxBytes: StickerLibrary.maxFileBytes,
      allowPrivateHosts: allowPrivateHosts,
    );
    return Uint8List.fromList(bytes);
  } on Object {
    // 单张失败只计入失败数，不影响同页的其他图片
    return null;
  }
}

/// GET 一个地址，手动跟随重定向，每一跳都重新检查地址；超过大小上限即失败。
Future<List<int>> _get(
  PublicNetwork client,
  Uri uri, {
  Uri? referer,
  required int maxBytes,
  required bool allowPrivateHosts,
}) async {
  final problem = checkFetchableUri(uri, allowPrivateHosts: allowPrivateHosts);
  if (problem != null) throw StickerWebException(problem);
  final response = await client.fetch(uri, maxBytes: maxBytes, timeout: _timeout,
    headers: {HttpHeaders.userAgentHeader: _userAgent,
      if (referer != null) HttpHeaders.refererHeader: referer.toString()});
  if (response.status != HttpStatus.ok) throw StickerWebException('HTTP ${response.status}');
  return response.bytes;
}

String? _extensionOf(Uint8List bytes) {
  bool startsWith(List<int> magic, [int offset = 0]) {
    if (bytes.length < offset + magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (bytes[offset + i] != magic[i]) return false;
    }
    return true;
  }

  if (startsWith([0xff, 0xd8, 0xff])) return 'jpg';
  if (startsWith([0x89, 0x50, 0x4e, 0x47])) return 'png';
  if (startsWith([0x47, 0x49, 0x46, 0x38])) return 'gif';
  if (startsWith([0x52, 0x49, 0x46, 0x46]) &&
      startsWith([0x57, 0x45, 0x42, 0x50], 8)) {
    return 'webp';
  }
  return null;
}

String _titleOf(String html) {
  final og = _title.firstMatch(html)?.group(1);
  if (og != null && og.trim().isNotEmpty) return _unescape(og).trim();
  final tag = RegExp(r'<title[^>]*>([^<]*)</title>', caseSensitive: false)
      .firstMatch(html)
      ?.group(1);
  return tag == null ? '' : _unescape(tag).trim();
}

String _unescape(String text) => text
    .replaceAll('&amp;', '&')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>');

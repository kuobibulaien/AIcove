import 'dart:typed_data';

import 'package:aicove_flutter/src/features/stickers/sticker_pack_download.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _gitee = StickerPackMirror('Gitee', 'https://gitee.test/a.zip', domestic: true);
const _github = StickerPackMirror('GitHub', 'https://github.test/a.zip');
const _mirrors = [_gitee, _github];

final _zip = Uint8List.fromList([0x50, 0x4B, 0x03, 0x04, 1, 2, 3]);

/// [delays]：每个主机的响应延迟；[down]：连不上的主机；[html]：返回网页而不是 ZIP 的主机。
MockClient _client({
  Map<String, int> delays = const {},
  Set<String> down = const {},
  Set<String> html = const {},
  List<String>? gets,
}) => MockClient((request) async {
  final host = request.url.host;
  await Future<void>.delayed(Duration(milliseconds: delays[host] ?? 0));
  if (down.contains(host)) throw http.ClientException('unreachable');
  if (request.method == 'GET') gets?.add(host);
  if (html.contains(host)) return http.Response('<html>login</html>', 200);
  return http.Response.bytes(_zip, 200);
});

void main() {
  test('in China the domestic mirror goes first even when slower', () async {
    final ranked = await rankStickerPackMirrors(
      _client(delays: {'gitee.test': 30}),
      _mirrors,
      inChina: true,
    );
    expect(ranked.map((m) => m.name), ['Gitee', 'GitHub']);
  });

  test('outside China the faster mirror goes first', () async {
    final ranked = await rankStickerPackMirrors(
      _client(delays: {'gitee.test': 30}),
      _mirrors,
      inChina: false,
    );
    expect(ranked.map((m) => m.name), ['GitHub', 'Gitee']);
  });

  test('an unreachable mirror is ranked last', () async {
    final ranked = await rankStickerPackMirrors(
      _client(down: {'gitee.test'}),
      _mirrors,
      inChina: true,
    );
    expect(ranked.map((m) => m.name), ['GitHub', 'Gitee']);
  });

  test('falls back to the other mirror when the first returns a web page', () async {
    final gets = <String>[];
    final result = await downloadStickerPack(
      _client(html: {'gitee.test'}, gets: gets),
      _mirrors,
      inChina: true,
    );
    expect(gets, ['gitee.test', 'github.test']);
    expect(result.mirror.name, 'GitHub');
    expect(result.bytes, _zip);
  });

  test('reports every mirror when all fail', () async {
    expect(
      downloadStickerPack(
        _client(down: {'gitee.test', 'github.test'}),
        _mirrors,
        inChina: true,
      ),
      throwsA(
        isA<Exception>().having(
          (e) => e.toString(),
          'message',
          allOf(contains('Gitee'), contains('GitHub')),
        ),
      ),
    );
  });
}

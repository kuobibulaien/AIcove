import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart' show ToolEffect;
import 'package:aicove_flutter/src/features/agent_plugins/file_change_journal.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_review.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_sticker_tools.dart';
import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:aicove_flutter/src/features/stickers/sticker_library.dart';
import 'package:aicove_flutter/src/features/stickers/sticker_registry.dart';
import 'package:aicove_flutter/src/features/stickers/sticker_web_import.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// 本地假网站：一个文章页（微信图片消息写法 + 封面 + 头像），两张大图，一张小图。
Future<HttpServer> _startSite(Directory dir) async {
  final big = Uint8List.fromList(
    img.encodeJpg(img.Image(width: 400, height: 400), quality: 80),
  );
  final other = Uint8List.fromList(
    img.encodePng(img.Image(width: 320, height: 360)),
  );
  final tiny = Uint8List.fromList(
    img.encodePng(img.Image(width: 60, height: 60)),
  );
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final path = request.uri.path;
    final response = request.response;
    if (path == '/article') {
      response.headers.contentType = ContentType.html;
      response.write('''
<html><head>
<meta property="og:title" content="测试套图 &amp; 猫" />
<meta property="og:image" content="${_base(server)}/cover.jpg" />
</head><body>
<img data-src="${_base(server)}/avatar.png?wx_fmt=png" />
<script>
picture_page_info_list: [
  { cdn_url: '${_base(server)}/cover.jpg?wx_fmt=jpeg\\x26amp;from=appmsg', width: '1000' * 1 },
  { cdn_url: '${_base(server)}/a.jpg?wx_fmt=jpeg\\x26amp;from=appmsg', width: '1000' * 1 },
  { cdn_url: '${_base(server)}/a.jpg?wx_fmt=jpeg\\x26amp;from=appmsg', width: '1000' * 1 },
  { cdn_url: '${_base(server)}/b.png?wx_fmt=png', width: '1000' * 1 },
  { cdn_url: '${_base(server)}/tiny.png', width: '1000' * 1 },
]
</script>
</body></html>
''');
    } else if (path == '/avatar.png' || path == '/tiny.png') {
      response.headers.contentType = ContentType('image', 'png');
      response.add(tiny);
    } else if (path == '/cover.jpg' || path == '/a.jpg') {
      response.headers.contentType = ContentType('image', 'jpeg');
      response.add(big);
    } else if (path == '/b.png') {
      response.headers.contentType = ContentType('image', 'png');
      response.add(other);
    } else if (path == '/redirect') {
      await response.redirect(Uri.parse('${_base(server)}/article'));
      return;
    } else {
      response.statusCode = HttpStatus.notFound;
    }
    await response.close();
  });
  addTearDown(() => server.close(force: true));
  return server;
}

String _base(HttpServer server) =>
    'http://${server.address.address}:${server.port}';

void main() {
  group('fetchStickerPage', () {
    late Directory dir;
    late HttpServer server;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('sticker_web_test');
      server = await _startSite(dir);
    });

    tearDown(() async {
      await dir.delete(recursive: true);
    });

    test('抓到图片消息里的表情，去掉封面、重复和小图', () async {
      final page = await fetchStickerPage(
        Uri.parse('${_base(server)}/article'),
        allowPrivateHosts: true,
      );

      expect(page.title, '测试套图 & 猫');
      // 封面（og:image）不算；a.jpg 只算一次；tiny.png 太小被跳过
      expect(page.images.map((f) => f.name), [
        'image-01.jpg',
        'image-02.png',
      ]);
      expect(page.smallCount, 2); // avatar.png 与 tiny.png
      expect(page.failedCount, 0);
    });

    test('跟随重定向，并按每一跳检查地址', () async {
      final page = await fetchStickerPage(
        Uri.parse('${_base(server)}/redirect'),
        allowPrivateHosts: true,
      );
      expect(page.images, isNotEmpty);
    });

    test('默认允许本机和内网地址', () async {
      final page = await fetchStickerPage(Uri.parse('${_base(server)}/article'));
      expect(page.images, isNotEmpty);
    });

    test('只接受 http 和 https', () async {
      expect(
        checkFetchableUri(Uri.parse('file:///etc/hosts')),
        '只支持 http 和 https 链接',
      );
      expect(checkFetchableUri(Uri.parse('http://192.168.1.2/a')), isNull);
      expect(checkFetchableUri(Uri.parse('http://[fd00::1]/a')), isNull);
      expect(checkFetchableUri(Uri.parse('https://mp.weixin.qq.com/s/x')), isNull);
    });
  });

  group('AssistantStickerTools', () {
    late Directory dir;
    late StickerLibrary library;
    late FileChangeJournal journal;
    late HttpServer server;
    late AssistantStickerTools tools;

    AITool toolNamed(String name) =>
        tools.tools().firstWhere((tool) => tool.name == name);

    Future<Map<String, dynamic>> call(String name, Map<String, dynamic> args) async {
      final result = await toolNamed(name).handler(args);
      return jsonDecode(result!) as Map<String, dynamic>;
    }

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('sticker_tools_test');
      server = await _startSite(dir);
      library = StickerLibrary(Directory(p.join(dir.path, 'stickers')));
      await library.load();
      journal = FileChangeJournal(
        file: () async => File(p.join(dir.path, 'journal.json')),
        appliers: {
          assistantStickerImportKind: AssistantStickerImportApplier(
            () async => library,
          ),
          assistantStickerTagsKind: AssistantStickerTagsApplier(
            () async => library,
          ),
        },
      );
      tools = AssistantStickerTools(
        library: () async => library,
        journal: journal,
        fetch: (uri) => fetchStickerPage(uri, allowPrivateHosts: true),
      );
    });

    tearDown(() async {
      StickerRegistry.instance.replaceStickers(const []);
      await dir.delete(recursive: true);
    });

    test('导入保留高风险分级供手动模式使用；改标签可撤销', () {
      expect(
        tools.riskOf(AssistantStickerTools.importTool, const {}),
        AssistantRisk.major,
      );
      expect(
        tools.riskOf(AssistantStickerTools.tagsTool, const {}),
        AssistantRisk.reversible,
      );
      expect(toolNamed(AssistantStickerTools.importTool).effect, ToolEffect.write);
    });

    test('导入成新套组，图片都未标注；撤销删除套组', () async {
      final result = await call(AssistantStickerTools.importTool, {
        'url': '${_base(server)}/article',
      });

      expect(result['ok'], isTrue);
      expect(result['pack_name'], '测试套图 & 猫');
      expect(result['added'], 2);
      expect(result['untagged'], 2);
      final packId = result['pack_id'] as String;
      expect(library.packById(packId)!.stickers.length, 2);
      expect(library.packById(packId)!.stickers.every((s) => s.tags.isEmpty), isTrue);

      final entry = (await journal.recent()).single;
      expect(entry.change.kind, assistantStickerImportKind);
      await journal.undo(entry.id);
      expect(library.packById(packId), isNull);
    });

    test('给表情改标签，撤销后恢复原标签', () async {
      final imported = await call(AssistantStickerTools.importTool, {
        'url': '${_base(server)}/article',
        'pack_name': '猫猫',
      });
      final packId = imported['pack_id'] as String;
      final stickers = (imported['stickers'] as List).cast<Map<String, dynamic>>();

      final changed = await call(AssistantStickerTools.tagsTool, {
        'pack_id': packId,
        'stickers': [
          {'id': stickers[0]['id'], 'tags': ['开心', '<不要>']},
          {'id': stickers[1]['id'], 'tags': ['委屈']},
        ],
      });
      expect(changed['changed'], 2);
      final first = library.packById(packId)!.stickers[0];
      expect(first.tags, ['开心', '不要']); // 尖括号被清掉

      final entry = (await journal.recent()).first; // 最新的在前
      await journal.undo(entry.id);
      expect(library.packById(packId)!.stickers[0].tags, isEmpty);
      expect(library.packById(packId)!.stickers[1].tags, isEmpty);
    });

    test('内置套组和不存在的表情不能改', () async {
      final result = await call(AssistantStickerTools.tagsTool, {
        'pack_id': 'builtin_nahida',
        'stickers': [
          {'id': 'x', 'tags': ['开心']},
        ],
      });
      expect(result['error'], 'invalid');
    });

    test('链接不对或抓不到图时返回错误，不导入', () async {
      final bad = await call(AssistantStickerTools.importTool, {'url': 'not a url'});
      expect(bad['error'], 'invalid');

      final none = await call(AssistantStickerTools.importTool, {
        'url': '${_base(server)}/missing',
      });
      expect(none['error'], 'invalid');
      expect(library.packs, isEmpty);
    });
  });
}

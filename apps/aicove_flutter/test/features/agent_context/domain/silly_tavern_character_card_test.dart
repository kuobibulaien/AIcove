import 'dart:convert';
import 'dart:typed_data';

import 'package:aicove_flutter/src/features/agent_context/data/silly_tavern_character_card_loader.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/silly_tavern_character_card.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;

Uint8List _basePng() =>
    Uint8List.fromList(img.encodePng(img.Image(width: 4, height: 6)));

Uint8List _chunk(String type, List<int> data) {
  final typeBytes = latin1.encode(type);
  final header = ByteData(4)..setUint32(0, data.length);
  final crc = ByteData(4)..setUint32(0, getCrc32([...typeBytes, ...data]));
  return Uint8List.fromList([
    ...header.buffer.asUint8List(),
    ...typeBytes,
    ...data,
    ...crc.buffer.asUint8List(),
  ]);
}

/// 把文本块插在 IHDR 之后，模拟酒馆写卡的位置。
Uint8List _withChunks(Uint8List png, List<Uint8List> chunks) {
  const ihdrEnd = 8 + 25;
  return Uint8List.fromList([
    ...png.sublist(0, ihdrEnd),
    for (final c in chunks) ...c,
    ...png.sublist(ihdrEnd),
  ]);
}

Uint8List _tEXt(String keyword, Map<String, Object?> json) => _chunk('tEXt', [
  ...latin1.encode(keyword),
  0,
  ...latin1.encode(base64.encode(utf8.encode(jsonEncode(json)))),
]);

void main() {
  const v2 = {
    'spec': 'chara_card_v2',
    'spec_version': '2.0',
    'data': {
      'name': '纳西妲',
      'description': '{{char}}是须弥的草神。',
      'personality': '温柔、好奇',
      'scenario': '净善宫',
      'first_mes': '你好呀，{{user}}。',
      'alternate_greetings': ['  ', '{{Char}}抬起头：<USER>，早。', 42],
      'mes_example': '<START>\n{{char}}: 嗯？',
      'character_book': {
        'entries': [
          {
            'keys': ['须弥'],
            'content': '雨林之国',
          },
        ],
      },
      'extensions': {
        'regex_scripts': [
          {'id': 'hide', 'findRegex': '<x>', 'replaceString': ''},
          'not a script',
        ],
        'tavern_helper': {
          'scripts': [
            {'name': 'MVU'},
          ],
        },
      },
    },
  };

  test('reads chara chunk, strips card data and keeps image decodable', () {
    final card = SillyTavernCharacterCard.parseBytes(
      _withChunks(_basePng(), [_tEXt('chara', v2)]),
    );

    expect(card.name, '纳西妲');
    expect(card.hasCharacterBook, isTrue);
    expect(card.characterBook!['entries'], hasLength(1));
    expect(card.regexScripts.single['id'], 'hide');
    expect(card.hasHelperScripts, isTrue);
    expect(card.hasPresetResources, isTrue);
    expect(
      card.composePersonaPrompt(),
      '{{char}}是须弥的草神。\n\n【性格】\n温柔、好奇\n\n【场景】\n净善宫\n\n'
      '【对话示例】\n<START>\n{{char}}: 嗯？',
    );
    expect(card.greetings, ['你好呀，{{user}}。', '{{Char}}抬起头：<USER>，早。']);
    final image = card.imageBytes!;
    expect(latin1.decode(image).contains('tEXt'), isFalse);
    final decoded = img.decodePng(image)!;
    expect((decoded.width, decoded.height), (4, 6));
  });

  test('renders greeting name macros like SillyTavern', () {
    expect(
      SillyTavernCharacterCard.renderGreeting(
        '{{char}}抬起头：{{ USER }}，<BOT>在这里。{{random:a,b}}',
        charName: '纳西妲',
        userName: '旅行者',
      ),
      '纳西妲抬起头：旅行者，纳西妲在这里。{{random:a,b}}',
    );
  });

  test('prefers ccv3 over chara', () {
    final card = SillyTavernCharacterCard.parsePng(
      _withChunks(_basePng(), [
        _tEXt('chara', v2),
        _tEXt('ccv3', {
          'spec': 'chara_card_v3',
          'data': {'name': 'V3 角色'},
        }),
      ]),
    );
    expect(card.name, 'V3 角色');
  });

  test('reads uncompressed iTXt chunk', () {
    final payload = base64.encode(utf8.encode(jsonEncode({'name': 'iTXt'})));
    final chunk = _chunk('iTXt', [
      ...latin1.encode('chara'),
      0, 0, 0, // 关键字结束、未压缩、压缩方法
      0, 0, // 空语言标签、空译名
      ...utf8.encode(payload),
    ]);
    final card = SillyTavernCharacterCard.parsePng(
      _withChunks(_basePng(), [chunk]),
    );
    expect(card.name, 'iTXt');
  });

  test('parses V1 flat JSON without image', () {
    final card = SillyTavernCharacterCard.parseBytes(
      Uint8List.fromList(
        utf8.encode(jsonEncode({'name': 'V1', 'description': 'desc'})),
      ),
    );
    expect(card.name, 'V1');
    expect(card.composePersonaPrompt(), 'desc');
    expect(card.imageBytes, isNull);
    expect(card.hasCharacterBook, isFalse);
    expect(card.hasPresetResources, isFalse);
    expect(card.hasHelperScripts, isFalse);
  });

  test('rejects plain PNG without card data', () {
    expect(
      () => SillyTavernCharacterCard.parseBytes(_basePng()),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('没有找到'),
        ),
      ),
    );
  });

  group('loader', () {
    test('downloads direct PNG link', () async {
      final png = _withChunks(_basePng(), [_tEXt('chara', v2)]);
      final loader = SillyTavernCharacterCardLoader(
        client: MockClient((_) async => http.Response.bytes(png, 200)),
      );
      final card = await loader.load('https://example.com/card.png');
      expect(card.name, '纳西妲');
      expect(card.imageBytes, isNotNull);
    });

    test('maps chub.ai page to api and downloads avatar', () async {
      final requested = <String>[];
      final avatar = _basePng();
      final loader = SillyTavernCharacterCardLoader(
        client: MockClient((request) async {
          requested.add(request.url.toString());
          if (request.url.host == 'api.chub.ai') {
            return http.Response.bytes(
              utf8.encode(
                jsonEncode({
                  'node': {
                    'max_res_url': 'https://avatars.example/a.png',
                    'definition': {
                      'name': 'Chub 角色',
                      'personality': '描述',
                      'first_message': '开场',
                      'alternate_greetings': ['备选'],
                    },
                  },
                }),
              ),
              200,
            );
          }
          return http.Response.bytes(avatar, 200);
        }),
      );
      final card = await loader.load(
        'https://chub.ai/characters/someone/some-card-1234',
      );
      expect(
        requested.first,
        'https://api.chub.ai/api/characters/someone/some-card-1234?full=true',
      );
      expect(card.name, 'Chub 角色');
      expect(card.composePersonaPrompt(), '描述');
      expect(card.greetings, ['开场', '备选']);
      expect(card.imageBytes, avatar);
    });

    test('rejects non-http url and http errors', () async {
      final loader = SillyTavernCharacterCardLoader(
        client: MockClient((_) async => http.Response('nope', 404)),
      );
      await expectLater(loader.load('ftp://x'), throwsFormatException);
      await expectLater(
        loader.load('https://example.com/a.png'),
        throwsA(
          isA<FormatException>().having((e) => e.message, 'm', contains('404')),
        ),
      );
    });
  });
}

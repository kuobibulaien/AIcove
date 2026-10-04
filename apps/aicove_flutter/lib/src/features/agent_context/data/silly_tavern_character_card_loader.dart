import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../domain/silly_tavern_character_card.dart';

/// 从链接下载酒馆角色卡：直链 PNG / JSON，或 chub.ai 角色页面。
class SillyTavernCharacterCardLoader {
  // ignore: prefer_initializing_formals
  SillyTavernCharacterCardLoader({http.Client? client}) : _client = client;

  static const Duration _timeout = Duration(seconds: 30);
  static const int _maxBytes = 30 * 1024 * 1024;
  static const Set<String> _chubHosts = {
    'chub.ai',
    'www.chub.ai',
    'characterhub.org',
    'www.characterhub.org',
  };

  final http.Client? _client;

  Future<SillyTavernCharacterCard> load(String rawUrl) async {
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const FormatException('请输入以 http:// 或 https:// 开头的链接');
    }
    final client = _client ?? http.Client();
    try {
      final chubId = chubCharacterId(uri);
      if (chubId != null) return await _loadChub(client, chubId);
      return SillyTavernCharacterCard.parseBytes(await _get(client, uri));
    } finally {
      if (_client == null) client.close();
    }
  }

  /// chub.ai/characters/{作者}/{角色} → `作者/角色`；其他链接返回 null。
  static String? chubCharacterId(Uri uri) {
    if (!_chubHosts.contains(uri.host.toLowerCase())) return null;
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.length < 3 || segments.first.toLowerCase() != 'characters') {
      return null;
    }
    return '${segments[1]}/${segments[2]}';
  }

  /// 与 SillyTavern 内容管理器一致：读角色元数据，再下载最高清头像。
  Future<SillyTavernCharacterCard> _loadChub(
    http.Client client,
    String id,
  ) async {
    final meta = await _get(
      client,
      Uri.parse('https://api.chub.ai/api/characters/$id?full=true'),
      headers: const {'Accept': 'application/json'},
    );
    final node = (jsonDecode(utf8.decode(meta)) as Map)['node'];
    final definition = node is Map ? node['definition'] : null;
    if (definition is! Map) {
      throw const FormatException('chub.ai 没有返回角色定义');
    }
    final card = SillyTavernCharacterCard.parseJson(
      jsonEncode({
        'name': definition['name'],
        'description': definition['personality'],
        'personality': definition['tavern_personality'],
        'scenario': definition['scenario'],
        'first_mes': definition['first_message'],
        'alternate_greetings': definition['alternate_greetings'],
        'mes_example': definition['example_dialogs'],
        'creator_notes': definition['description'],
        'character_book': definition['embedded_lorebook'],
        'extensions': definition['extensions'],
      }),
    );
    final imageUrl = node['max_res_url'];
    if (imageUrl is! String || imageUrl.isEmpty) return card;
    try {
      final image = await _get(client, Uri.parse(imageUrl));
      return card.withImage(SillyTavernCharacterCard.stripCardData(image));
    } on Exception {
      return card;
    }
  }

  Future<Uint8List> _get(
    http.Client client,
    Uri uri, {
    Map<String, String>? headers,
  }) async {
    final response = await client.get(uri, headers: headers).timeout(_timeout);
    if (response.statusCode != 200) {
      throw FormatException('下载失败（HTTP ${response.statusCode}）');
    }
    if (response.bodyBytes.length > _maxBytes) {
      throw const FormatException('文件过大，超过 30MB');
    }
    return response.bodyBytes;
  }
}

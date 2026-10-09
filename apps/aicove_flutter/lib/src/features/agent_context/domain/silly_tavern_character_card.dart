import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// 酒馆（SillyTavern）角色卡，兼容 V1 平铺 JSON、V2 `chara` 与 V3 `ccv3`。
///
/// PNG 角色卡把 base64 编码的 JSON 存在文本块里；解析后 [imageBytes]
/// 是去掉角色数据块的原图，可直接用作头像与背景。
class SillyTavernCharacterCard {
  const SillyTavernCharacterCard({
    required this.name,
    this.description = '',
    this.personality = '',
    this.scenario = '',
    this.firstMessage = '',
    this.alternateGreetings = const [],
    this.messageExample = '',
    this.creatorNotes = '',
    this.characterBook,
    this.regexScripts = const [],
    this.hasHelperScripts = false,
    this.imageBytes,
  });

  final String name;
  final String description;
  final String personality;
  final String scenario;
  final String firstMessage;

  /// 卡内 `alternate_greetings`：主开场白之外的备选开场白。
  final List<String> alternateGreetings;
  final String messageExample;
  final String creatorNotes;

  /// 卡内 `character_book` 原文；没有条目时为 null。
  final Map<String, dynamic>? characterBook;

  /// 卡内 `extensions.regex_scripts` 原文，导入时并入角色专用组合预设。
  final List<Map<String, dynamic>> regexScripts;

  /// 卡内是否带酒馆助手脚本（`extensions.tavern_helper`），本项目不执行。
  final bool hasHelperScripts;

  bool get hasCharacterBook => characterBook != null;

  /// 卡片是否使用 MVU 变量：卡内世界书有 `[InitVar]` 条目，或开场白带初始化／更新块（ADR0071）。
  bool get usesMvu {
    final entries = characterBook?['entries'];
    final items = entries is Map ? entries.values : (entries is List ? entries : const []);
    for (final item in items) {
      if (item is! Map) continue;
      final name = (item['comment'] ?? item['name'] ?? '').toString();
      if (name.toLowerCase().contains('[initvar]')) return true;
    }
    final markup = RegExp(
      r'<\s*(?:initvar|updatevariable|json_?patch)\b',
      caseSensitive: false,
    );
    return greetings.any(markup.hasMatch);
  }

  /// 卡内是否带需要并入组合预设的资源。
  bool get hasPresetResources => hasCharacterBook || regexScripts.isNotEmpty;

  /// 去掉角色数据块后的 PNG 原图；JSON 卡为 null。
  final Uint8List? imageBytes;

  SillyTavernCharacterCard withImage(Uint8List? bytes) =>
      SillyTavernCharacterCard(
        name: name,
        description: description,
        personality: personality,
        scenario: scenario,
        firstMessage: firstMessage,
        alternateGreetings: alternateGreetings,
        messageExample: messageExample,
        creatorNotes: creatorNotes,
        characterBook: characterBook,
        regexScripts: regexScripts,
        hasHelperScripts: hasHelperScripts,
        imageBytes: bytes,
      );

  /// 全部非空开场白：主开场白在前，备选开场白按卡内顺序在后；换行统一为 `\n`。
  List<String> get greetings => [
    for (final text in [firstMessage, ...alternateGreetings])
      if (text.trim().isNotEmpty) text.replaceAll('\r\n', '\n').trim(),
  ];

  /// 组合为本应用的人设提示词；保留 `{{char}}`/`{{user}}` 宏交给装配器求值。
  ///
  /// 开场白不进人设，由导入流程写成会话里的第一条角色消息。
  String composePersonaPrompt() {
    final sections = <String>[
      if (description.trim().isNotEmpty) description.trim(),
      if (personality.trim().isNotEmpty) '【性格】\n${personality.trim()}',
      if (scenario.trim().isNotEmpty) '【场景】\n${scenario.trim()}',
      if (messageExample.trim().isNotEmpty) '【对话示例】\n${messageExample.trim()}',
    ];
    return sections.join('\n\n');
  }

  /// 与酒馆建聊时一致：把开场白里的角色名、用户名宏替换为实际名称。
  static String renderGreeting(
    String text, {
    required String charName,
    required String userName,
  }) {
    return text
        .replaceAll(RegExp(r'\{\{\s*char\s*\}\}|<BOT>', caseSensitive: false), charName)
        .replaceAll(RegExp(r'\{\{\s*user\s*\}\}|<USER>', caseSensitive: false), userName);
  }

  /// 按内容自动识别 PNG 或 JSON。
  static SillyTavernCharacterCard parseBytes(Uint8List bytes) {
    if (isPng(bytes)) return parsePng(bytes);
    final String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      throw const FormatException('不是酒馆角色卡：仅支持 PNG 角色卡或角色卡 JSON');
    }
    return parseJson(text);
  }

  static SillyTavernCharacterCard parsePng(Uint8List bytes) {
    final chunks = _readPngChunks(bytes);
    String? chara;
    String? ccv3;
    for (final chunk in chunks) {
      final text = _readTextChunk(bytes, chunk);
      if (text == null) continue;
      if (text.keyword == 'ccv3') ccv3 = text.value;
      if (text.keyword == 'chara') chara = text.value;
    }
    final payload = ccv3 ?? chara;
    if (payload == null) {
      throw const FormatException('图片里没有找到酒馆角色卡数据');
    }
    final String json;
    try {
      json = utf8.decode(base64.decode(base64.normalize(payload.trim())));
    } on FormatException {
      throw const FormatException('角色卡数据损坏，无法解码');
    }
    return parseJson(json).withImage(_writePng(bytes, chunks));
  }

  static SillyTavernCharacterCard parseJson(String source) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      throw const FormatException('角色卡 JSON 格式错误');
    }
    if (decoded is! Map) throw const FormatException('角色卡 JSON 不是对象');
    final nested = decoded['data'];
    final data = nested is Map && nested.containsKey('name') ? nested : decoded;
    String str(String key) {
      final value = data[key];
      return value is String ? value : '';
    }

    final name = str('name').trim();
    if (name.isEmpty) throw const FormatException('角色卡缺少角色名称');
    final book = data['character_book'];
    final alternates = data['alternate_greetings'];
    final extensions = data['extensions'];
    final scripts = extensions is Map ? extensions['regex_scripts'] : null;
    final helper = extensions is Map ? extensions['tavern_helper'] : null;
    return SillyTavernCharacterCard(
      name: name,
      description: str('description'),
      personality: str('personality'),
      scenario: str('scenario'),
      firstMessage: str('first_mes'),
      alternateGreetings: [
        if (alternates is List)
          for (final item in alternates)
            if (item is String && item.trim().isNotEmpty) item,
      ],
      messageExample: str('mes_example'),
      creatorNotes: str('creator_notes'),
      characterBook: book is Map && _hasEntries(book['entries'])
          ? Map<String, dynamic>.from(book)
          : null,
      regexScripts: [
        if (scripts is List)
          for (final script in scripts)
            if (script is Map) Map<String, dynamic>.from(script),
      ],
      hasHelperScripts:
          helper is Map &&
          helper['scripts'] is List &&
          (helper['scripts'] as List).isNotEmpty,
    );
  }

  static bool _hasEntries(Object? entries) =>
      (entries is List && entries.isNotEmpty) ||
      (entries is Map && entries.isNotEmpty);

  /// 去掉 PNG 内嵌的角色数据块；非 PNG 原样返回。
  static Uint8List stripCardData(Uint8List bytes) {
    if (!isPng(bytes)) return bytes;
    return _writePng(bytes, _readPngChunks(bytes));
  }

  static bool isPng(Uint8List bytes) {
    if (bytes.length < _pngSignature.length) return false;
    for (var i = 0; i < _pngSignature.length; i++) {
      if (bytes[i] != _pngSignature[i]) return false;
    }
    return true;
  }
}

const List<int> _pngSignature = [137, 80, 78, 71, 13, 10, 26, 10];
const Set<String> _cardKeywords = {'chara', 'ccv3'};

class _PngChunk {
  const _PngChunk(
    this.type,
    this.start,
    this.end,
    this.dataStart,
    this.dataEnd,
  );

  final String type;

  /// 整块（含长度、类型、CRC）在原文件中的范围。
  final int start;
  final int end;
  final int dataStart;
  final int dataEnd;
}

class _TextChunk {
  const _TextChunk(this.keyword, this.value);
  final String keyword;
  final String value;
}

List<_PngChunk> _readPngChunks(Uint8List bytes) {
  final view = ByteData.sublistView(bytes);
  final chunks = <_PngChunk>[];
  var offset = _pngSignature.length;
  while (offset + 12 <= bytes.length) {
    final length = view.getUint32(offset);
    final dataStart = offset + 8;
    final dataEnd = dataStart + length;
    if (dataEnd + 4 > bytes.length) {
      throw const FormatException('PNG 文件不完整');
    }
    final type = latin1.decode(bytes.sublist(offset + 4, dataStart));
    chunks.add(_PngChunk(type, offset, dataEnd + 4, dataStart, dataEnd));
    offset = dataEnd + 4;
    if (type == 'IEND') break;
  }
  return chunks;
}

_TextChunk? _readTextChunk(Uint8List bytes, _PngChunk chunk) {
  if (chunk.type != 'tEXt' && chunk.type != 'iTXt' && chunk.type != 'zTXt') {
    return null;
  }
  final data = bytes.sublist(chunk.dataStart, chunk.dataEnd);
  final nul = data.indexOf(0);
  if (nul <= 0) return null;
  final keyword = latin1.decode(data.sublist(0, nul));
  if (!_cardKeywords.contains(keyword)) return null;
  switch (chunk.type) {
    case 'tEXt':
      return _TextChunk(keyword, latin1.decode(data.sublist(nul + 1)));
    case 'zTXt':
      final inflated = const ZLibDecoder().decodeBytes(data.sublist(nul + 2));
      return _TextChunk(keyword, latin1.decode(inflated));
    default: // iTXt: 压缩标志、压缩方法、语言标签\0、译名\0、正文
      if (data.length < nul + 3) return null;
      final compressed = data[nul + 1] == 1;
      var cursor = nul + 3;
      for (var skip = 0; skip < 2; skip++) {
        final end = data.indexOf(0, cursor);
        if (end < 0) return null;
        cursor = end + 1;
      }
      final body = data.sublist(cursor);
      final raw = compressed ? const ZLibDecoder().decodeBytes(body) : body;
      return _TextChunk(keyword, utf8.decode(raw));
  }
}

/// 去掉角色数据文本块，避免头像与背景重复存一份完整角色卡 JSON。
Uint8List _writePng(Uint8List bytes, List<_PngChunk> chunks) {
  final out = BytesBuilder(copy: false)..add(_pngSignature);
  for (final chunk in chunks) {
    if (_readTextChunk(bytes, chunk) != null) continue;
    out.add(Uint8List.sublistView(bytes, chunk.start, chunk.end));
  }
  return out.toBytes();
}

import 'kaomoji_parser.dart';

const List<String> _kDefaultChunkPunctuations = [
  '\u3002',
  '\uff01',
  '\uff1f',
  '\uff0c',
  '\u3001',
  '\uff1b',
  '\u2026',
];

const List<String> _kSimpleChunkPunctuations = [
  '\u3002',
  '\uff01',
  '\uff1f',
];

const List<String> _kDetailedChunkPunctuations = [
  '\u3002',
  '\uff01',
  '\uff1f',
  '\uff0c',
  '\u3001',
  '\uff1b',
  '\uff1a',
  '\u2026',
];

const List<String> _kDefaultFilterPunctuations = [
  '\u3002',
  '\uff0c',
  '\u3001',
  '\uff1b',
  '\u2026',
  ',',
  ';',
];

class MessageChunkPunctuationSet {
  final String id;
  final String? name;
  final List<String> punctuations;

  const MessageChunkPunctuationSet({
    required this.id,
    this.name,
    required this.punctuations,
  });

  String get displayName {
    final value = name?.trim() ?? '';
    return value.isEmpty ? '未命名' : value;
  }

  MessageChunkPunctuationSet copyWith({
    String? id,
    String? name,
    List<String>? punctuations,
  }) {
    return MessageChunkPunctuationSet(
      id: id ?? this.id,
      name: name ?? this.name,
      punctuations: punctuations ?? this.punctuations,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'punctuations': punctuations,
    };
  }

  factory MessageChunkPunctuationSet.fromJson(Map<String, dynamic> json) {
    return MessageChunkPunctuationSet(
      id: (json['id'] as String? ?? '').trim(),
      name: (json['name'] as String?)?.trim(),
      punctuations:
          (json['punctuations'] as List<dynamic>?)?.cast<String>() ?? const [],
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is MessageChunkPunctuationSet &&
        other.id == id &&
        other.name == name &&
        _listContentEquals(other.punctuations, punctuations);
  }

  @override
  int get hashCode => Object.hash(id, name, Object.hashAll(punctuations));
}

const List<MessageChunkPunctuationSet> _kDefaultChunkPunctuationSets = [
  MessageChunkPunctuationSet(
    id: 'default',
    name: '默认',
    punctuations: _kDefaultChunkPunctuations,
  ),
  MessageChunkPunctuationSet(
    id: 'simple',
    name: '精简',
    punctuations: _kSimpleChunkPunctuations,
  ),
  MessageChunkPunctuationSet(
    id: 'conservative',
    name: '保守',
    punctuations: [],
  ),
  MessageChunkPunctuationSet(
    id: 'detailed',
    name: '详细',
    punctuations: _kDetailedChunkPunctuations,
  ),
];

/// UI-only message formatting config.
/// This does not change persisted raw message content.
class MessageFormatConfig {
  /// Whether chunked display is enabled.
  final bool enableChunking;

  /// Whether trailing punctuation should be filtered out.
  final bool filterPunctuation;

  /// Active punctuation list used by runtime chunking.
  final List<String> chunkPunctuations;

  /// Saved punctuation sets.
  final List<MessageChunkPunctuationSet> chunkPunctuationSets;

  /// Active punctuation set id.
  final String activeChunkPunctuationSetId;

  /// Punctuation list used by trailing punctuation filtering.
  final List<String> filterPunctuations;

  /// Sticker send probability (0.0 - 1.0).
  final double stickerProbability;

  /// Minimum chunk length. Short chunks may be merged.
  final int minSegmentLength;

  /// Whether quoted text is protected from splitting.
  final bool protectQuotes;

  const MessageFormatConfig({
    this.enableChunking = true,
    this.filterPunctuation = false,
    this.chunkPunctuations = _kDefaultChunkPunctuations,
    this.chunkPunctuationSets = _kDefaultChunkPunctuationSets,
    this.activeChunkPunctuationSetId = 'default',
    this.filterPunctuations = _kDefaultFilterPunctuations,
    this.stickerProbability = 0.3,
    this.minSegmentLength = 5,
    this.protectQuotes = true,
  });

  MessageChunkPunctuationSet? get activeChunkPunctuationSet =>
      _findSetById(chunkPunctuationSets, activeChunkPunctuationSetId);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is MessageFormatConfig &&
        other.enableChunking == enableChunking &&
        other.filterPunctuation == filterPunctuation &&
        _listContentEquals(other.chunkPunctuations, chunkPunctuations) &&
        _listContentEquals(other.chunkPunctuationSets, chunkPunctuationSets) &&
        other.activeChunkPunctuationSetId == activeChunkPunctuationSetId &&
        _listContentEquals(other.filterPunctuations, filterPunctuations) &&
        other.stickerProbability == stickerProbability &&
        other.minSegmentLength == minSegmentLength &&
        other.protectQuotes == protectQuotes;
  }

  @override
  int get hashCode => Object.hash(
        enableChunking,
        filterPunctuation,
        Object.hashAll(chunkPunctuations),
        Object.hashAll(chunkPunctuationSets),
        activeChunkPunctuationSetId,
        Object.hashAll(filterPunctuations),
        stickerProbability,
        minSegmentLength,
        protectQuotes,
      );

  List<String> get effectiveChunkPunctuations {
    final active = activeChunkPunctuationSet;
    if (active == null) return chunkPunctuations;
    if (_listEquals(chunkPunctuations, active.punctuations)) {
      return active.punctuations;
    }
    return chunkPunctuations;
  }

  MessageFormatConfig copyWith({
    bool? enableChunking,
    bool? filterPunctuation,
    List<String>? chunkPunctuations,
    List<MessageChunkPunctuationSet>? chunkPunctuationSets,
    String? activeChunkPunctuationSetId,
    List<String>? filterPunctuations,
    double? stickerProbability,
    int? minSegmentLength,
    bool? protectQuotes,
  }) {
    final sets =
        _sanitizeSets(chunkPunctuationSets ?? this.chunkPunctuationSets);
    final activeSetId = _resolveActiveSetId(
      activeChunkPunctuationSetId ?? this.activeChunkPunctuationSetId,
      sets,
    );
    // 不变量：copyWith 不隐式改写未涉及的字段——只有调用方显式切换了集合或
    // 激活 id 时，才用激活集合同步 chunkPunctuations；否则 copyWith() 必须
    // 与原实例值相等（select 粒度优化依赖该契约）。
    final setsTouched =
        chunkPunctuationSets != null || activeChunkPunctuationSetId != null;
    final activePunctuations = _findSetById(sets, activeSetId)?.punctuations;
    final resolvedChunkPunctuations = _sanitizePunctuations(
      chunkPunctuations ??
          (setsTouched
              ? (activePunctuations ?? this.chunkPunctuations)
              : this.chunkPunctuations),
    );

    return MessageFormatConfig(
      enableChunking: enableChunking ?? this.enableChunking,
      filterPunctuation: filterPunctuation ?? this.filterPunctuation,
      chunkPunctuations: resolvedChunkPunctuations,
      chunkPunctuationSets: sets,
      activeChunkPunctuationSetId: activeSetId,
      filterPunctuations:
          _sanitizePunctuations(filterPunctuations ?? this.filterPunctuations),
      stickerProbability: stickerProbability ?? this.stickerProbability,
      minSegmentLength: minSegmentLength ?? this.minSegmentLength,
      protectQuotes: protectQuotes ?? this.protectQuotes,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'enableChunking': enableChunking,
      'filterPunctuation': filterPunctuation,
      'chunkPunctuations': chunkPunctuations,
      'chunkPunctuationSets':
          chunkPunctuationSets.map((item) => item.toJson()).toList(),
      'activeChunkPunctuationSetId': activeChunkPunctuationSetId,
      'filterPunctuations': filterPunctuations,
      'stickerProbability': stickerProbability,
      'minSegmentLength': minSegmentLength,
      'protectQuotes': protectQuotes,
    };
  }

  factory MessageFormatConfig.fromJson(Map<String, dynamic> json) {
    final rawChunkPunctuations = _sanitizePunctuations(
      (json['chunkPunctuations'] as List<dynamic>?)?.cast<String>() ??
          _kDefaultChunkPunctuations,
    );

    final rawSets = (json['chunkPunctuationSets'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((item) =>
            MessageChunkPunctuationSet.fromJson(item.cast<String, dynamic>()))
        .toList();

    final hasStructuredSets = rawSets.isNotEmpty;
    final sets = hasStructuredSets
        ? _sanitizeSets(rawSets)
        : _buildSetsFromLegacy(rawChunkPunctuations);

    var activeSetId = (json['activeChunkPunctuationSetId'] as String?)?.trim();
    if ((activeSetId == null || activeSetId.isEmpty) && !hasStructuredSets) {
      activeSetId =
          _listEquals(rawChunkPunctuations, _kDefaultChunkPunctuations)
              ? 'default'
              : 'legacy';
    }
    final resolvedActiveSetId = _resolveActiveSetId(activeSetId, sets);
    final activePunctuations =
        _findSetById(sets, resolvedActiveSetId)?.punctuations ??
            rawChunkPunctuations;
    // 不变量：序列化里显式带了 chunkPunctuations 就原样恢复（保证
    // fromJson(toJson()) 值相等）；缺省时才落到激活集合。
    final hasExplicitChunkPunctuations = json['chunkPunctuations'] != null;

    return MessageFormatConfig(
      enableChunking: json['enableChunking'] as bool? ?? true,
      filterPunctuation: json['filterPunctuation'] as bool? ?? false,
      chunkPunctuations: hasExplicitChunkPunctuations
          ? rawChunkPunctuations
          : activePunctuations,
      chunkPunctuationSets: sets,
      activeChunkPunctuationSetId: resolvedActiveSetId,
      filterPunctuations: _sanitizePunctuations(
        (json['filterPunctuations'] as List<dynamic>?)?.cast<String>() ??
            _kDefaultFilterPunctuations,
      ),
      stickerProbability:
          (json['stickerProbability'] as num?)?.toDouble() ?? 0.3,
      minSegmentLength: json['minSegmentLength'] as int? ?? 5,
      protectQuotes: json['protectQuotes'] as bool? ?? true,
    );
  }

  static List<MessageChunkPunctuationSet> _buildSetsFromLegacy(
    List<String> legacyPunctuations,
  ) {
    if (_listEquals(legacyPunctuations, _kDefaultChunkPunctuations)) {
      return _kDefaultChunkPunctuationSets;
    }
    return <MessageChunkPunctuationSet>[
      MessageChunkPunctuationSet(
        id: 'legacy',
        name: '当前',
        punctuations: legacyPunctuations,
      ),
      ..._kDefaultChunkPunctuationSets,
    ];
  }

  static List<String> _sanitizePunctuations(List<String> source) {
    final result = <String>[];
    for (final token in source) {
      final value = token.trim();
      if (value.isNotEmpty && !result.contains(value)) {
        result.add(value);
      }
    }
    return result;
  }

  static List<MessageChunkPunctuationSet> _sanitizeSets(
    List<MessageChunkPunctuationSet> source,
  ) {
    if (source.isEmpty) {
      return _kDefaultChunkPunctuationSets;
    }

    final result = <MessageChunkPunctuationSet>[];
    final usedIds = <String>{};
    for (var i = 0; i < source.length; i++) {
      final item = source[i];
      var id = item.id.trim();
      if (id.isEmpty) {
        id = 'set_$i';
      }
      if (usedIds.contains(id)) {
        id = '${id}_$i';
      }
      usedIds.add(id);
      result.add(
        item.copyWith(
          id: id,
          punctuations: _sanitizePunctuations(item.punctuations),
        ),
      );
    }
    return result;
  }

  static String _resolveActiveSetId(
    String? activeSetId,
    List<MessageChunkPunctuationSet> sets,
  ) {
    final requested = activeSetId?.trim() ?? '';
    if (requested.isNotEmpty && _findSetById(sets, requested) != null) {
      return requested;
    }
    return sets.first.id;
  }

  static MessageChunkPunctuationSet? _findSetById(
    List<MessageChunkPunctuationSet> sets,
    String id,
  ) {
    for (final item in sets) {
      if (item.id == id) {
        return item;
      }
    }
    return null;
  }

  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Build a stable signature for frontend message projection settings.
///
/// This signature is used by frontend caches to detect message formatting
/// strategy changes (chunking, punctuation rules, etc.).
String buildMessageFormatProjectionSignature(MessageFormatConfig config) {
  final activePunctuations = config.effectiveChunkPunctuations.join(',');
  final filterPunctuations = config.filterPunctuations.join(',');
  return [
    config.enableChunking,
    config.filterPunctuation,
    activePunctuations,
    filterPunctuations,
    config.minSegmentLength,
    config.protectQuotes,
  ].join('|');
}

/// Message formatter for chunk display logic.
class MessageFormatter {
  // Matches paired quotes/brackets to protect quoted text from splitting.
  static final _quotePattern = RegExp(
    r'''(「.*?」|『.*?』|“.*?”|‘.*?’|".*?"|'.*?'|《.*?》|【.*?】)''',
  );

  // Clause-level punctuation usually merged forward for short chunks.
  static const _commaPuncts = {'\uff0c', ',', '\u3001', '\uff1b', ';'};

  // Sentence-level punctuation.
  static const _periodPuncts = {
    '\u3002',
    '\uff01',
    '\uff1f',
    '!',
    '?',
    '\u2026'
  };

  /// Format and chunk text.
  static List<String> formatAndChunkText(
    String text,
    MessageFormatConfig config,
  ) {
    // Chunking disabled: return raw text as one chunk.
    if (!config.enableChunking) {
      return [text];
    }

    // Normalize escaped newline.
    var processedText = text.replaceAll('\\n', '\n');
    // Treat 4+ consecutive spaces as paragraph breaks.
    processedText = processedText.replaceAll(RegExp(r'[^\S\r\n]{4,}'), '\n');
    final segments = processedText.split('\n');
    final rawChunks = <String>[];

    for (final segment in segments) {
      if (segment.trim().isEmpty) {
        rawChunks.add('');
        continue;
      }
      rawChunks.addAll(_splitSegment(segment, config));
    }

    // Merge short chunks in two passes.
    final merged = _mergeShortSentences(rawChunks, config.minSegmentLength);
    final finalChunks = _mergeShortSentences(merged, config.minSegmentLength);

    // Optional punctuation filtering.
    if (config.filterPunctuation) {
      return _filterTrailingPunctuation(finalChunks, config);
    }

    return finalChunks.where((chunk) => chunk.trim().isNotEmpty).toList();
  }

  /// Split one paragraph segment.
  static List<String> _splitSegment(
      String segment, MessageFormatConfig config) {
    // 1) Protect kaomojis using placeholders.
    final kaomojis = KaomojiParser.extractKaomojis(segment);
    const kaomojiPlaceholder = '\x00KMJ';
    var protected = segment;
    for (var i = 0; i < kaomojis.length; i++) {
      protected =
          protected.replaceFirst(kaomojis[i], '$kaomojiPlaceholder$i\x00');
    }

    // 2) Protect quoted content using placeholders.
    final quotedContents = <String>[];
    var quotePlaceholder = '\x00QTE';
    // Do not interpret literal placeholder-like input as a generated token.
    while (protected.contains(quotePlaceholder)) {
      quotePlaceholder += '_';
    }
    if (config.protectQuotes) {
      protected = protected.replaceAllMapped(_quotePattern, (match) {
        final index = quotedContents.length;
        quotedContents.add(match.group(0)!);
        return '$quotePlaceholder$index\x00';
      });
    }
    final quoteTokenPattern = RegExp(
      '${RegExp.escape(quotePlaceholder)}([0-9]+)\x00',
    );

    // 3) Split by configured punctuation with lookahead.
    final punctuationTokens = config.effectiveChunkPunctuations
        .where((p) => p.isNotEmpty)
        .toList()
      ..sort((a, b) => b.length.compareTo(a.length));

    late final List<String> sentences;
    if (punctuationTokens.isEmpty) {
      sentences = [protected];
    } else {
      final punctuationPattern =
          punctuationTokens.map((p) => RegExp.escape(p)).join('|');
      final splitPattern = RegExp(
        '((?:$punctuationPattern)+)(?:[^\\S\\r\\n]+)?(?=[\\u4e00-\\u9fffa-zA-Z])',
      );
      sentences = protected
          .replaceAllMapped(splitPattern, (m) => '${m.group(1)}\n')
          .split('\n');
    }

    // 4) Restore placeholders.
    final restored = <String>[];
    for (var sentence in sentences) {
      if (quotedContents.isNotEmpty) {
        sentence = sentence.replaceAllMapped(quoteTokenPattern, (match) {
          return quotedContents[int.parse(match.group(1)!)];
        });
      }
      for (var i = 0; i < kaomojis.length; i++) {
        sentence =
            sentence.replaceAll('$kaomojiPlaceholder$i\x00', kaomojis[i]);
      }
      if (sentence.trim().isNotEmpty) {
        restored.add(sentence.trim());
      }
    }

    return restored;
  }

  /// Merge short sentence chunks.
  static List<String> _mergeShortSentences(
    List<String> sentences,
    int minLength,
  ) {
    if (sentences.isEmpty) return [];

    final merged = <String>[];
    var pending = ''; // Short chunk waiting for forward merge.

    for (var sentence in sentences) {
      if (sentence.trim().isEmpty) continue;

      // Prepend pending short chunk if any.
      if (pending.isNotEmpty) {
        sentence = pending + sentence;
        pending = '';
      }

      if (sentence.length <= minLength) {
        if (_endsWithComma(sentence)) {
          // Comma-ending short chunk: merge forward.
          pending = sentence;
        } else if (_endsWithPeriod(sentence) &&
            merged.isNotEmpty &&
            _endsWithComma(merged.last)) {
          // Period-ending short chunk after comma-ending chunk: merge backward.
          merged.last = merged.last + sentence;
        } else {
          merged.add(sentence);
        }
      } else {
        merged.add(sentence);
      }
    }

    // Merge remaining pending chunk.
    if (pending.isNotEmpty) {
      if (merged.isNotEmpty) {
        merged.last = merged.last + pending;
      } else {
        merged.add(pending);
      }
    }

    return merged;
  }

  /// Remove one trailing punctuation mark from each chunk if configured.
  static List<String> _filterTrailingPunctuation(
    List<String> chunks,
    MessageFormatConfig config,
  ) {
    final result = <String>[];
    for (final chunk in chunks) {
      if (chunk.trim().isEmpty) continue;

      // Keep kaomoji chunks unchanged to avoid false positives.
      if (KaomojiParser.containsKaomoji(chunk)) {
        result.add(chunk);
        continue;
      }

      var filtered = chunk;
      for (final punct in config.filterPunctuations) {
        if (filtered.endsWith(punct)) {
          filtered = filtered.substring(0, filtered.length - punct.length);
          break;
        }
      }
      if (filtered.trim().isNotEmpty) {
        result.add(filtered);
      }
    }
    return result;
  }

  static bool _endsWithComma(String s) =>
      s.isNotEmpty && _commaPuncts.contains(s[s.length - 1]);

  static bool _endsWithPeriod(String s) =>
      s.isNotEmpty && _periodPuncts.contains(s[s.length - 1]);
}

bool _listContentEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

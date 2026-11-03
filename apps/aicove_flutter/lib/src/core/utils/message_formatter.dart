import 'kaomoji_parser.dart';
import 'markdown_fence.dart';

/// 「激进」方案在这些标点后分段。
const List<String> _kAggressiveChunkPunctuations = [
  '\u3002',
  '\uff01',
  '\uff1f',
  '\uff0c',
  '\u3001',
  '\uff1b',
  '\uff1a',
  '\u2026',
  '\uff5e',
  '!',
  '?',
  ',',
  ';',
  '~',
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

/// Consecutive spaces that start a new chunk unless a set says otherwise.
const int kDefaultChunkSpaceRun = 3;

class MessageChunkPunctuationSet {
  final String id;
  final String? name;
  final List<String> punctuations;

  /// Whether a line break starts a new chunk.
  final bool splitOnNewline;

  /// This many consecutive spaces start a new chunk; 0 turns it off.
  final int spaceRun;

  const MessageChunkPunctuationSet({
    required this.id,
    this.name,
    required this.punctuations,
    this.splitOnNewline = true,
    this.spaceRun = kDefaultChunkSpaceRun,
  });

  String get displayName {
    final value = name?.trim() ?? '';
    return value.isEmpty ? '未命名' : value;
  }

  MessageChunkPunctuationSet copyWith({
    String? id,
    String? name,
    List<String>? punctuations,
    bool? splitOnNewline,
    int? spaceRun,
  }) {
    return MessageChunkPunctuationSet(
      id: id ?? this.id,
      name: name ?? this.name,
      punctuations: punctuations ?? this.punctuations,
      splitOnNewline: splitOnNewline ?? this.splitOnNewline,
      spaceRun: spaceRun ?? this.spaceRun,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'punctuations': punctuations,
      'splitOnNewline': splitOnNewline,
      'spaceRun': spaceRun,
    };
  }

  factory MessageChunkPunctuationSet.fromJson(Map<String, dynamic> json) {
    return MessageChunkPunctuationSet(
      id: (json['id'] as String? ?? '').trim(),
      name: (json['name'] as String?)?.trim(),
      punctuations:
          (json['punctuations'] as List<dynamic>?)?.cast<String>() ?? const [],
      splitOnNewline: json['splitOnNewline'] as bool? ?? true,
      spaceRun: ((json['spaceRun'] as num?)?.toInt() ?? kDefaultChunkSpaceRun)
          .clamp(0, 99),
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is MessageChunkPunctuationSet &&
        other.id == id &&
        other.name == name &&
        _listContentEquals(other.punctuations, punctuations) &&
        other.splitOnNewline == splitOnNewline &&
        other.spaceRun == spaceRun;
  }

  @override
  int get hashCode => Object.hash(
    id,
    name,
    Object.hashAll(punctuations),
    splitOnNewline,
    spaceRun,
  );
}

const String _kDefaultChunkPunctuationSetId = 'standard';

/// Bumped when the built-in sets are rewritten; older configs are migrated
/// in [MessageFormatConfig.fromJson].
const int _kChunkPunctuationSetsVersion = 2;

/// 「默认」只在换行和连续空格处分段，「激进」再加上标点。
const List<MessageChunkPunctuationSet> _kDefaultChunkPunctuationSets = [
  MessageChunkPunctuationSet(
    id: _kDefaultChunkPunctuationSetId,
    name: '默认',
    punctuations: [],
  ),
  MessageChunkPunctuationSet(
    id: 'aggressive',
    name: '激进',
    punctuations: _kAggressiveChunkPunctuations,
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

  /// Minimum chunk length. Short chunks may be merged.
  final int minSegmentLength;

  /// Whether quoted text is protected from splitting.
  final bool protectQuotes;

  const MessageFormatConfig({
    this.enableChunking = true,
    this.filterPunctuation = false,
    this.chunkPunctuations = const [],
    this.chunkPunctuationSets = _kDefaultChunkPunctuationSets,
    this.activeChunkPunctuationSetId = _kDefaultChunkPunctuationSetId,
    this.filterPunctuations = _kDefaultFilterPunctuations,
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
        minSegmentLength,
        protectQuotes,
      );

  /// Whether a line break starts a new chunk under the active set.
  bool get splitOnNewline => activeChunkPunctuationSet?.splitOnNewline ?? true;

  /// Consecutive spaces that start a new chunk under the active set; 0 is off.
  int get chunkSpaceRun =>
      activeChunkPunctuationSet?.spaceRun ?? kDefaultChunkSpaceRun;

  List<String> get effectiveChunkPunctuations {
    final active = activeChunkPunctuationSet;
    if (active == null) return chunkPunctuations;
    if (_listEquals(chunkPunctuations, active.punctuations)) {
      return active.punctuations;
    }
    return chunkPunctuations;
  }

  /// Punctuation tokens from whitespace-separated [text], cleaned the way
  /// the config stores them.
  static List<String> parsePunctuations(String text) =>
      _sanitizePunctuations(text.split(RegExp(r'\s+')));

  /// The set [setId] with [punctuations]; the runtime list follows when it
  /// is the active set. Null when there is no such set.
  MessageFormatConfig? withSetPunctuations(
    String setId,
    List<String> punctuations,
  ) {
    final index = chunkPunctuationSets.indexWhere((s) => s.id == setId);
    if (index < 0) return null;
    final sets = [...chunkPunctuationSets];
    sets[index] = sets[index].copyWith(punctuations: punctuations);
    return copyWith(
      chunkPunctuationSets: sets,
      chunkPunctuations: setId == activeChunkPunctuationSetId
          ? punctuations
          : chunkPunctuations,
    );
  }

  /// Switches to the set [setId], with the runtime list set to
  /// [punctuations] (the set's own when null). Null when there is no such set.
  MessageFormatConfig? withActiveSet(String setId, [List<String>? punctuations]) {
    final set = _findSetById(chunkPunctuationSets, setId);
    if (set == null) return null;
    return copyWith(
      activeChunkPunctuationSetId: setId,
      chunkPunctuations: punctuations ?? set.punctuations,
    );
  }

  MessageFormatConfig copyWith({
    bool? enableChunking,
    bool? filterPunctuation,
    List<String>? chunkPunctuations,
    List<MessageChunkPunctuationSet>? chunkPunctuationSets,
    String? activeChunkPunctuationSetId,
    List<String>? filterPunctuations,
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
      'chunkPunctuationSetsVersion': _kChunkPunctuationSetsVersion,
      'minSegmentLength': minSegmentLength,
      'protectQuotes': protectQuotes,
    };
  }

  factory MessageFormatConfig.fromJson(Map<String, dynamic> json) {
    final rawChunkPunctuations = _sanitizePunctuations(
      (json['chunkPunctuations'] as List<dynamic>?)?.cast<String>() ??
          const <String>[],
    );

    final rawSets = (json['chunkPunctuationSets'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((item) =>
            MessageChunkPunctuationSet.fromJson(item.cast<String, dynamic>()))
        .toList();

    var activeSetId = (json['activeChunkPunctuationSetId'] as String?)?.trim();
    final current =
        json['chunkPunctuationSetsVersion'] == _kChunkPunctuationSetsVersion;
    final hasRuntime = json['chunkPunctuations'] != null;
    final List<MessageChunkPunctuationSet> sets;
    // 迁移后仍选着原来那套时，原样保留运行时标点（可能与方案本身不同）。
    var keepRuntime = current && hasRuntime;
    if (current) {
      sets = _sanitizeSets(rawSets);
    } else {
      // 旧的内置方案（保守、精简、详细、当前）换成「默认」「激进」两套，用户
      // 新建的方案保留；原来选的方案还在就沿用，否则按实际生效的标点有无
      // 归到两套之一。
      sets = _sanitizeSets([
        ..._kDefaultChunkPunctuationSets,
        ...rawSets.where((s) => s.id.trim().startsWith('set_')),
      ]);
      if (sets.any((s) => s.id == activeSetId)) {
        keepRuntime = hasRuntime;
      } else {
        final oldActive = rawSets.where((s) => s.id == activeSetId).firstOrNull;
        final inEffect = hasRuntime
            ? rawChunkPunctuations
            : _sanitizePunctuations(oldActive?.punctuations ?? const []);
        activeSetId = inEffect.isEmpty
            ? _kDefaultChunkPunctuationSetId
            : _kDefaultChunkPunctuationSets[1].id;
      }
    }
    final resolvedActiveSetId = _resolveActiveSetId(activeSetId, sets);
    final activePunctuations =
        _findSetById(sets, resolvedActiveSetId)?.punctuations ??
            rawChunkPunctuations;

    return MessageFormatConfig(
      enableChunking: json['enableChunking'] as bool? ?? true,
      filterPunctuation: json['filterPunctuation'] as bool? ?? false,
      chunkPunctuations:
          keepRuntime ? rawChunkPunctuations : activePunctuations,
      chunkPunctuationSets: sets,
      activeChunkPunctuationSetId: resolvedActiveSetId,
      filterPunctuations: _sanitizePunctuations(
        (json['filterPunctuations'] as List<dynamic>?)?.cast<String>() ??
            _kDefaultFilterPunctuations,
      ),
      minSegmentLength: json['minSegmentLength'] as int? ?? 5,
      protectQuotes: json['protectQuotes'] as bool? ?? true,
    );
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
    config.splitOnNewline,
    config.chunkSpaceRun,
    filterPunctuations,
    config.minSegmentLength,
    config.protectQuotes,
  ].join('|');
}

/// 分段保护区（ADR0047）：[start, end) 内的文本是一个组件，整块成为一个分段，
/// 内部不做换行切分、标点切分、短句合并与尾标点过滤。
/// [closed] 为 false 表示流式中尚未写完，区间延伸到当前文本末尾。
class ProtectedTextRange {
  const ProtectedTextRange(this.start, this.end, {this.closed = true});

  final int start;
  final int end;
  final bool closed;
}

/// 一个分段。[openEnded] 为 true 表示它是尚未闭合的组件，流式中还会继续增长。
class MessageChunk {
  const MessageChunk(this.text, {this.openEnded = false});

  final String text;
  final bool openEnded;
}

/// Message formatter for chunk display logic.
/// Stands in for a line break that stays inside its chunk.
const String _keptNewline = '\u0001';

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
    MessageFormatConfig config, {
    Iterable<ProtectedTextRange> protectedRanges = const [],
  }) {
    return [
      for (final chunk in formatAndChunk(
        text,
        config,
        protectedRanges: protectedRanges,
      ))
        chunk.text,
    ];
  }

  /// 只切正文句子（ADR0047）：围栏代码块总是受保护，调用方可再传入
  /// 标签等组件区间；代码块内部的区间视为代码文字而忽略。
  static List<MessageChunk> formatAndChunk(
    String text,
    MessageFormatConfig config, {
    Iterable<ProtectedTextRange> protectedRanges = const [],
  }) {
    // Chunking disabled: return raw text as one chunk.
    if (!config.enableChunking) {
      return [MessageChunk(text)];
    }
    final ranges = _resolveProtectedRanges(text, protectedRanges);
    if (ranges.isEmpty) {
      return [
        for (final chunk in _chunkPlainText(text, config)) MessageChunk(chunk),
      ];
    }
    final result = <MessageChunk>[];
    var cursor = 0;
    for (final range in ranges) {
      if (range.start > cursor) {
        for (final chunk
            in _chunkPlainText(text.substring(cursor, range.start), config)) {
          result.add(MessageChunk(chunk));
        }
      }
      final component = text.substring(range.start, range.end).trim();
      if (component.isNotEmpty) {
        result.add(MessageChunk(component, openEnded: !range.closed));
      }
      cursor = range.end;
    }
    if (cursor < text.length) {
      for (final chunk in _chunkPlainText(text.substring(cursor), config)) {
        result.add(MessageChunk(chunk));
      }
    }
    return result;
  }

  /// 合并围栏代码块与调用方区间：起点落在代码块内的区间丢弃，重叠区间合并。
  static List<ProtectedTextRange> _resolveProtectedRanges(
    String text,
    Iterable<ProtectedTextRange> extra,
  ) {
    final fences = [
      for (final block in scanFencedCodeBlocks(text))
        ProtectedTextRange(block.start, block.end, closed: block.closed),
    ];
    final candidates = <ProtectedTextRange>[
      ...fences,
      for (final range in extra)
        if (range.start >= 0 &&
            range.end <= text.length &&
            range.start < range.end &&
            !fences.any((f) => range.start >= f.start && range.start < f.end))
          range,
    ]..sort((a, b) => a.start.compareTo(b.start));
    final merged = <ProtectedTextRange>[];
    for (final range in candidates) {
      final last = merged.isEmpty ? null : merged.last;
      if (last != null && range.start < last.end) {
        if (range.end > last.end) {
          merged.last =
              ProtectedTextRange(last.start, range.end, closed: range.closed);
        }
        continue;
      }
      merged.add(range);
    }
    return merged;
  }

  static List<String> _chunkPlainText(
    String text,
    MessageFormatConfig config,
  ) {
    // Normalize escaped newline.
    var processedText = text.replaceAll('\\n', '\n');
    // Line breaks the set does not split on ride along inside a chunk.
    if (!config.splitOnNewline) {
      processedText = processedText.replaceAll('\n', _keptNewline);
    }
    final spaceRun = config.chunkSpaceRun;
    if (spaceRun > 0) {
      processedText = processedText.replaceAll(
        RegExp('[^\\S\\r\\n]{$spaceRun,}'),
        '\n',
      );
    }
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
        '((?:$punctuationPattern)+)(?:[^\\S\\r\\n]|$_keptNewline)*(?=[\\u4e00-\\u9fffa-zA-Z])',
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
      sentence = sentence.replaceAll(_keptNewline, '\n').trim();
      if (sentence.isNotEmpty) restored.add(sentence);
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

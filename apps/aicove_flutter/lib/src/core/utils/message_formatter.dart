import 'kaomoji_parser.dart';

/// 娑堟伅鏍煎紡鍖栭厤缃?
///
/// 娉ㄦ剰锛氬垎娈靛姛鑳芥槸绾墠绔睍绀洪€昏緫锛屼笉褰卞搷娑堟伅瀛樺偍銆?
/// 娑堟伅鍦ㄦ暟鎹簱涓繚鎸佸畬鏁达紝鍒嗘浠呭湪 UI 娓叉煋鏃跺鐞嗐€?
class MessageFormatConfig {
  /// 鏄惁鍚敤鍒嗘鏄剧ず
  final bool enableChunking;

  /// 鏄惁杩囨护鏍囩偣
  final bool filterPunctuation;

  /// 鍒嗘鏍囩偣鍒楄〃锛堢敤绌烘牸鍒嗛殧渚夸簬缂栬緫锛?
  final List<String> chunkPunctuations;

  /// 杩囨护鏍囩偣鍒楄〃
  final List<String> filterPunctuations;

  /// 琛ㄦ儏鍖呭彂閫佹鐜?(0.0 - 1.0锛?琛ㄧず鍏抽棴)
  final double stickerProbability;

  /// 鏈€灏忓垎娈甸暱搴︼紙鐭簬姝ら暱搴︾殑娈典細琚悎骞讹級
  final int minSegmentLength;

  /// 鏄惁淇濇姢寮曞彿鍐呭涓嶈鎷嗗垎
  final bool protectQuotes;

  const MessageFormatConfig({
    this.enableChunking = true, // 榛樿寮€鍚垎娈?
    this.filterPunctuation = false,
    this.chunkPunctuations = const [
      '\u3002',
      '\uff01',
      '\uff1f',
      '\uff0c',
      '\u3001',
      '\uff1b',
      '\u2026',
    ],
    this.filterPunctuations = const [
      '\u3002',
      '\uff0c',
      '\u3001',
      '\uff1b',
      '\u2026',
      ',',
      ';',
    ],
    this.stickerProbability = 0.3,
    this.minSegmentLength = 5,
    this.protectQuotes = true,
  });

  MessageFormatConfig copyWith({
    bool? enableChunking,
    bool? filterPunctuation,
    List<String>? chunkPunctuations,
    List<String>? filterPunctuations,
    double? stickerProbability,
    int? minSegmentLength,
    bool? protectQuotes,
  }) {
    return MessageFormatConfig(
      enableChunking: enableChunking ?? this.enableChunking,
      filterPunctuation: filterPunctuation ?? this.filterPunctuation,
      chunkPunctuations: chunkPunctuations ?? this.chunkPunctuations,
      filterPunctuations: filterPunctuations ?? this.filterPunctuations,
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
      'filterPunctuations': filterPunctuations,
      'stickerProbability': stickerProbability,
      'minSegmentLength': minSegmentLength,
      'protectQuotes': protectQuotes,
    };
  }

  factory MessageFormatConfig.fromJson(Map<String, dynamic> json) {
    return MessageFormatConfig(
      enableChunking: json['enableChunking'] as bool? ?? true, // 榛樿寮€鍚?
      filterPunctuation: json['filterPunctuation'] as bool? ?? false,
      chunkPunctuations:
          (json['chunkPunctuations'] as List<dynamic>?)?.cast<String>() ??
              const [
                '\u3002',
                '\uff01',
                '\uff1f',
                '\uff0c',
                '\u3001',
                '\uff1b',
                '\u2026',
              ],
      filterPunctuations:
          (json['filterPunctuations'] as List<dynamic>?)?.cast<String>() ??
              const [
                '\u3002',
                '\uff0c',
                '\u3001',
                '\uff1b',
                '\u2026',
                ',',
                ';',
              ],
      stickerProbability:
          (json['stickerProbability'] as num?)?.toDouble() ?? 0.3,
      minSegmentLength: json['minSegmentLength'] as int? ?? 5,
      protectQuotes: json['protectQuotes'] as bool? ?? true,
    );
  }
}

/// 娑堟伅鏍煎紡鍖栧櫒
///
/// 璐熻矗娑堟伅鐨勬牸寮忓寲澶勭悊,鍖呮嫭:
/// - 娑堟伅鍒嗘鍜屾櫤鑳藉垎鍓?
/// - 棰滄枃瀛椾繚鎶?
/// - 寮曞彿鍐呭淇濇姢
/// - 鐭彞鏅鸿兘鍚堝苟
/// - 鏍囩偣绗﹀彿杩囨护
class MessageFormatter {
  // 寮曞彿瀵瑰尮閰嶆鍒欙細鎴愬鐨勪腑鑻辨棩寮曞彿銆佷功鍚嶅彿銆佹柟鎷彿
  static final _quotePattern = RegExp(
    r'''(「.*?」|『.*?』|“.*?”|‘.*?’|".*?"|'.*?'|《.*?》|【.*?】)''',
  );

  // 閫楀彿绫绘爣鐐癸紙鍙ユ剰鏈畬鎴愶紝搴斿悜鍚庡悎骞讹級
  static const _commaPuncts = {'\uff0c', ',', '\u3001', '\uff1b', ';'};

  // 鍙ュ彿绫绘爣鐐癸紙鍙ユ剰瀹屾暣锛?
  static const _periodPuncts = {'\u3002', '\uff01', '\uff1f', '!', '?', '\u2026'};

  /// 鏍煎紡鍖栧苟鍒嗘鏂囨湰
  ///
  /// Args:
  ///   text: 鍘熷鏂囨湰
  ///   config: 鏍煎紡鍖栭厤缃?
  ///
  /// Returns:
  ///   鍒嗘鍚庣殑鏂囨湰鍒楄〃
  static List<String> formatAndChunkText(
    String text,
    MessageFormatConfig config,
  ) {
    // 濡傛灉鏈惎鐢ㄥ垎娈碉紝鐩存帴杩斿洖鍘熸枃鏈?
    if (!config.enableChunking) {
      return [text];
    }

    // 澶勭悊杞箟鐨勬崲琛岀
    var processedText = text.replaceAll('\\n', '\n');
    // 鎶婅繛缁?涓強浠ヤ笂鐨勭┖鏍间篃褰撲綔娈佃惤鍒嗛殧绗︼紙閮ㄥ垎AI鐢ㄧ┖鏍间唬鏇挎崲琛岋級
    processedText = processedText.replaceAll(RegExp(r'[^\S\r\n]{3,}'), '\n');
    final segments = processedText.split('\n');
    final rawChunks = <String>[];

    for (final segment in segments) {
      if (segment.trim().isEmpty) {
        rawChunks.add('');
        continue;
      }

      rawChunks.addAll(_splitSegment(segment, config));
    }

    // 鈹€鈹€ 鐭彞鍚堝苟 鈹€鈹€
    final merged = _mergeShortSentences(rawChunks, config.minSegmentLength);

    // 鈹€鈹€ 璺ㄦ钀戒簩娆″悎骞?鈹€鈹€
    final finalChunks = _mergeShortSentences(merged, config.minSegmentLength);

    // 鈹€鈹€ 鏍囩偣杩囨护 鈹€鈹€
    if (config.filterPunctuation) {
      return _filterTrailingPunctuation(finalChunks, config);
    }

    return finalChunks.where((chunk) => chunk.trim().isNotEmpty).toList();
  }

  /// 瀵瑰崟涓钀斤紙涓€琛屾枃鏈級鎵ц鍒嗘
  static List<String> _splitSegment(String segment, MessageFormatConfig config) {
    // 1) 棰滄枃瀛椾繚鎶わ細鎻愬彇骞舵浛鎹负鍗犱綅绗?
    final kaomojis = KaomojiParser.extractKaomojis(segment);
    const kaomojiPlaceholder = '\x00KMJ';
    var protected = segment;
    for (var i = 0; i < kaomojis.length; i++) {
      protected = protected.replaceFirst(kaomojis[i], '$kaomojiPlaceholder$i\x00');
    }

    // 2) 寮曞彿淇濇姢锛氭彁鍙栧苟鏇挎崲涓哄崰浣嶇
    final quotedContents = <String>[];
    const quotePlaceholder = '\x00QTE';
    if (config.protectQuotes) {
      for (final m in _quotePattern.allMatches(protected)) {
        quotedContents.add(m.group(0)!);
      }
      for (var i = 0; i < quotedContents.length; i++) {
        protected = protected.replaceFirst(
          quotedContents[i],
          '$quotePlaceholder$i\x00',
        );
      }
    }

    // 3) 鎸夋爣鐐瑰垎鍙ワ紙甯?lookahead锛氬彧鍦ㄦ爣鐐瑰悗闈㈢揣璺熶腑鑻辨枃瀛楃鏃舵墠鍒囷級
    final punctuationTokens = config.chunkPunctuations
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

    // 4) 鎭㈠寮曞彿 鈫?鎭㈠棰滄枃瀛?
    final restored = <String>[];
    for (var sentence in sentences) {
      for (var i = 0; i < quotedContents.length; i++) {
        sentence = sentence.replaceAll('$quotePlaceholder$i\x00', quotedContents[i]);
      }
      for (var i = 0; i < kaomojis.length; i++) {
        sentence = sentence.replaceAll('$kaomojiPlaceholder$i\x00', kaomojis[i]);
      }
      if (sentence.trim().isNotEmpty) {
        restored.add(sentence.trim());
      }
    }

    return restored;
  }

  /// 鍚堝苟杩囩煭鐨勫彞瀛?
  ///
  /// 瑙勫垯锛堝弬鑰?astrbot_plugin_smart_segment锛夛細
  /// - 閫楀彿绫荤粨灏剧殑鐭彞 鈫?鍚戝悗鍚堝苟锛堝彞鎰忔湭瀹屾垚锛?
  /// - 鍙ュ彿绫荤粨灏剧殑鐭彞锛屼笖鍓嶄竴鍙ユ槸閫楀彿缁撳熬 鈫?鍚戝墠鍚堝苟锛堣ˉ瀹屽墠鍙ワ級
  /// - 鍏朵粬 鈫?淇濇寔鐙珛
  static List<String> _mergeShortSentences(
    List<String> sentences,
    int minLength,
  ) {
    if (sentences.isEmpty) return [];

    final merged = <String>[];
    var pending = ''; // 寰呭悜鍚庡悎骞剁殑鐭彞

    for (var sentence in sentences) {
      if (sentence.trim().isEmpty) continue;

      // 鏈夊緟鍚堝苟鍐呭锛屾嫾鍒板綋鍓嶅彞鍓嶉潰
      if (pending.isNotEmpty) {
        sentence = pending + sentence;
        pending = '';
      }

      if (sentence.length <= minLength) {
        if (_endsWithComma(sentence)) {
          // 閫楀彿缁撳熬 鈫?鍚戝悗鍚堝苟
          pending = sentence;
        } else if (_endsWithPeriod(sentence) &&
            merged.isNotEmpty &&
            _endsWithComma(merged.last)) {
          // 鍙ュ彿缁撳熬锛屽墠涓€鍙ユ槸閫楀彿 鈫?鍚戝墠鍚堝苟
          merged.last = merged.last + sentence;
        } else {
          merged.add(sentence);
        }
      } else {
        merged.add(sentence);
      }
    }

    // 澶勭悊鏈熬娈嬬暀
    if (pending.isNotEmpty) {
      if (merged.isNotEmpty) {
        merged.last = merged.last + pending;
      } else {
        merged.add(pending);
      }
    }

    return merged;
  }

  /// 杩囨护娈垫湯鏍囩偣锛堜繚鎶ら鏂囧瓧锛?
  static List<String> _filterTrailingPunctuation(
    List<String> chunks,
    MessageFormatConfig config,
  ) {
    final result = <String>[];
    for (final chunk in chunks) {
      if (chunk.trim().isEmpty) continue;

      // 鍚鏂囧瓧鐨勬涓嶈繃婊ゆ爣鐐?
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


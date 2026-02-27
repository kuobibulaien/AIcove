/// 颜文字解析器
///
/// 使用保守启发式方法（低误报偏差）提取和检测颜文字。
/// 参考 astrbot_plugin_smart_segment 的三层检测策略。
class KaomojiParser {
  // ── 括号对 ──
  static const _bracketPairs = <(String, String)>[
    ('(', ')'),
    ('（', '）'),
    ('[', ']'),
    ('【', '】'),
    ('「', '」'),
    ('『', '』'),
    ('<', '>'),
    ('〈', '〉'),
  ];

  // 装饰性包裹字符，常见于 ╰( )╯ 等写法
  static const _wrapperChars = '↖↗↘↙╰╯╭╮┌┐└┘♪♫♬♩';

  // CJK 过滤：括号内含中文就不当颜文字
  static final _cjkRe = RegExp(r'[\u4e00-\u9fff]');

  // 颜文字中常见的符号提示（排除 ! ? 等常见句子标点以降低误报）
  static final _symbolHintRe = RegExp(
    r'[·・•｡。．.°ºˇˊˋˆ`~～＾^＿_￣¯—ー─━\-－≧≦＞＜><=＝;；]'
    r'|[♡♥❤💕💗💓💖💘💝💞💟❣❥☆★✦✧✩✪]'
    r'|[╰╯╭╮]',
  );

  // 颜文字中常用的"眼睛/嘴巴"字母（仅作辅助判断）
  static final _letterHintRe = RegExp(r'[oO0TQqpPwWvVωДд∀xX]');

  // 经典无括号颜文字模式
  static final _classicPatterns = <RegExp>[
    RegExp(r'[><＞＜]\s*[_\-\.]\s*[><＞＜]'), // >_<  >.<
    RegExp(r'[TQqpP]\s*[_\-\.]\s*[TQqpP]'), // T_T  Q_Q
    RegExp(r'\^\s*[_\-\.]\s*\^'), // ^_^
    RegExp(r'[;；]\s*[_\-\.]\s*[;；]'), // ;_;
    RegExp(r'[oO0]\s*[_\-\.]\s*[oO0]'), // o_o
    RegExp(r'=\s*[_\-\.]\s*='), // =_=
    RegExp(r'[xX]\s*[_\-\.]\s*[xX]'), // x_x
  ];

  // 连续特殊符号（保守的兜底策略）
  static final _specialRunRe = RegExp(r'[^\w\s\u4e00-\u9fff]{3,}');

  // "无聊"字符集——全是这些的话不算颜文字
  static const _boringChars = '!！?？.。…-—_=+=*/\\|`~^＾';

  /// 从 [text] 中提取所有颜文字（不重叠，左到右顺序）
  static List<String> extractKaomojis(String text) {
    final spans = <(int, int)>[];
    final results = <(int, int, String)>[];

    bool overlaps((int, int) span) {
      final (start, end) = span;
      for (final (s, e) in spans) {
        if (!(end <= s || start >= e)) return true;
      }
      return false;
    }

    void add((int, int) span, String value) {
      if (overlaps(span)) return;
      spans.add(span);
      results.add((span.$1, span.$2, value));
    }

    // ── 策略1：括号型颜文字 ──
    for (final (left, right) in _bracketPairs) {
      final leftEsc = RegExp.escape(left);
      final rightEsc = RegExp.escape(right);
      final innerExclude = RegExp.escape('$left$right');
      final pattern = RegExp('$leftEsc([^$innerExclude\\n]{1,64})$rightEsc');

      for (final m in pattern.allMatches(text)) {
        final inner = m.group(1)!;
        if (!_isProbableKaomojiInner(inner)) continue;

        var start = m.start;
        var end = m.end;

        // 包含前后各一个装饰字符（如 ╰( )╯）
        if (start > 0 && _wrapperChars.contains(text[start - 1])) {
          start -= 1;
        }
        if (end < text.length && _wrapperChars.contains(text[end])) {
          end += 1;
        }

        add((start, end), text.substring(start, end));
      }
    }

    // ── 策略2：经典无括号模式（>_<, T_T, ^_^）──
    for (final pat in _classicPatterns) {
      for (final m in pat.allMatches(text)) {
        add((m.start, m.end), m.group(0)!);
      }
    }

    // ── 策略3：连续特殊符号（非常保守，过滤掉纯"无聊"字符）──
    for (final m in _specialRunRe.allMatches(text)) {
      final s = m.group(0)!;
      if (s.runes.every((r) => _boringChars.contains(String.fromCharCode(r)))) {
        continue;
      }
      add((m.start, m.end), s);
    }

    results.sort((a, b) => a.$1.compareTo(b.$1));
    return results.map((r) => r.$3).toList();
  }

  /// 检查 [text] 是否包含颜文字
  static bool containsKaomoji(String text) {
    return extractKaomojis(text).isNotEmpty;
  }

  /// 判断括号内部文本是否像颜文字
  static bool _isProbableKaomojiInner(String inner) {
    inner = inner.trim();
    if (inner.length < 2) return false;
    // 包含中文 → 不是颜文字
    if (_cjkRe.hasMatch(inner)) return false;

    final symbolHints = _symbolHintRe.allMatches(inner).length;
    if (symbolHints <= 0) return false;

    // 两层判断：
    // - 符号特征 >= 2 → 直接认定
    // - 否则需要字母特征（眼睛/嘴巴）>= 2 辅助确认
    if (symbolHints >= 2) return true;

    final letterHints = _letterHintRe.allMatches(inner).length;
    return letterHints >= 2;
  }
}

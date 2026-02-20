class LexicalTokenizerZh {
  const LexicalTokenizerZh._();

  static bool _isHan(int codeUnit) {
    return (codeUnit >= 0x4E00 && codeUnit <= 0x9FFF) ||
        (codeUnit >= 0x3400 && codeUnit <= 0x4DBF);
  }

  static bool _isAsciiWord(int codeUnit) {
    return (codeUnit >= 0x30 && codeUnit <= 0x39) ||
        (codeUnit >= 0x41 && codeUnit <= 0x5A) ||
        (codeUnit >= 0x61 && codeUnit <= 0x7A) ||
        codeUnit == 0x5F;
  }

  /// 中文按 2-gram，ASCII 按整词
  static String tokenizeForFts(String text) {
    final input = text.trim();
    if (input.isEmpty) return '';

    final tokens = <String>[];
    var i = 0;
    while (i < input.length) {
      final cu = input.codeUnitAt(i);

      if (_isHan(cu)) {
        final start = i;
        i++;
        while (i < input.length && _isHan(input.codeUnitAt(i))) {
          i++;
        }
        final run = input.substring(start, i);
        if (run.length == 1) {
          tokens.add(run);
        } else {
          for (var j = 0; j < run.length - 1; j++) {
            tokens.add(run.substring(j, j + 2));
          }
        }
        continue;
      }

      if (_isAsciiWord(cu)) {
        final start = i;
        i++;
        while (i < input.length && _isAsciiWord(input.codeUnitAt(i))) {
          i++;
        }
        tokens.add(input.substring(start, i).toLowerCase());
        continue;
      }

      i++;
    }

    return tokens.join(' ');
  }

  static bool isSingleHanQuery(String text) {
    final t = text.trim();
    return t.length == 1 && _isHan(t.codeUnitAt(0));
  }

  static bool looksLikeFillerUtterance(String text) {
    final t = text.trim();
    if (t.isEmpty || t.length >= 5) return false;
    const fillers = {
      '嗯',
      '嗯嗯',
      '哦',
      '好的',
      '好',
      '哈哈',
      '哈',
      '行',
      'ok',
      'okay',
      '收到',
    };
    if (fillers.contains(t.toLowerCase())) return true;
    return RegExp(r'^[~!,.?，。！？；、\\s]+$').hasMatch(t);
  }
}

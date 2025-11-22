/// 颜文字解析器
///
/// 提供颜文字的提取和检测功能
class KaomojiParser {
  /// 智能提取颜文字
  ///
  /// 基于逻辑：如果标点符号周围都是标点而没有汉字，那它很可能是颜文字
  static List<String> extractKaomojis(String text) {
    final kaomojis = <String>[];

    // 1. 先匹配明显的括号类颜文字
    final bracketPattern = RegExp(r'[\(（][^\w\s\)）]*[\)）]');
    final bracketMatches = bracketPattern.allMatches(text);
    for (final match in bracketMatches) {
      kaomojis.add(match.group(0)!);
    }

    // 2. 智能检测连续的非汉字符号组合
    // 汉字范围：\u4e00-\u9fff
    // 英文字母数字：a-zA-Z0-9
    // 常见标点：，。！？、；：""''（）【】

    // 查找连续的特殊符号（不包括常见中文标点）
    final specialCharsPattern = RegExp(r'[^\u4e00-\u9fffa-zA-Z0-9\s，。！？、；：""''（）【】\[\]]{2,}');
    final specialMatches = specialCharsPattern.allMatches(text);

    for (final match in specialMatches) {
      final matchText = match.group(0)!;
      // 检查这个符号组合是否已经被括号匹配捕获
      if (!kaomojis.any((bracket) => bracket.contains(matchText))) {
        kaomojis.add(matchText);
      }
    }

    // 3. 检测混合型颜文字（包含一些汉字但明显是表情的）
    // 例如：>_<、T_T、-_-、^_^等
    final mixedPattern = RegExp(r'[><\-_\^TωΩ☆★♡♥]+[_\-><\^TωΩ☆★♡♥]*[><\-_\^TωΩ☆★♡♥]+');
    final mixedMatches = mixedPattern.allMatches(text);

    for (final match in mixedMatches) {
      final matchText = match.group(0)!;
      if (matchText.length >= 2 && !kaomojis.any((existing) => existing.contains(matchText))) {
        kaomojis.add(matchText);
      }
    }

    return kaomojis;
  }

  /// 检查文本是否包含颜文字
  static bool containsKaomoji(String text) {
    return extractKaomojis(text).isNotEmpty;
  }
}

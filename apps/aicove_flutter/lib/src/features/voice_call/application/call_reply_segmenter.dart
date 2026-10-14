/// 把流式回复切成可以立即送去合成的短段。
///
/// 句末标点立即切；逗号等句中标点要等攒够 [minChars] 个字再切，避免语调碎。
/// 方括号语气标签（如 `[笑着说，有点害羞]`）里的标点不切，标签要和后面的话
/// 一起送去合成。依据见 `docs/04_功能模块规范/语音通话/README.md`「流水线」。
class CallReplySegmenter {
  CallReplySegmenter({this.minChars = 6});

  final int minChars;
  final _buffer = StringBuffer();
  bool _inTag = false;

  static final _strong = RegExp(r'[。！？!?…~～\n]');
  static final _weak = RegExp(r'[，,、；;：:]');

  /// 送入一段增量文字，返回已经可以合成的段落。
  List<String> push(String delta) {
    final out = <String>[];
    for (final rune in delta.runes) {
      final ch = String.fromCharCode(rune);
      _buffer.write(ch);
      if (ch == '[') _inTag = true;
      if (ch == ']' || ch == '\n') _inTag = false;
      if (_inTag) continue;
      final current = _buffer.toString();
      final strong = _strong.hasMatch(ch) && current.trim().length > 1;
      final weak = _weak.hasMatch(ch) && current.length >= minChars;
      if (strong || weak) {
        if (current.trim().isNotEmpty) out.add(current);
        _buffer.clear();
      }
    }
    return out;
  }

  /// 取出剩余文字（回复结束时调用）。
  String drain() {
    final rest = _buffer.toString();
    _buffer.clear();
    _inTag = false;
    return rest.trim().isEmpty ? '' : rest;
  }
}

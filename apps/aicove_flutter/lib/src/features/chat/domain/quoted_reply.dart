/// 引用回复的文本格式：发送时拼装与显示时识别的唯一出处。
///
/// 引用随正文一起存为纯文本（Markdown 引用行），不加结构化字段：
/// `> Quote: 被引用内容摘要\n\n正文`。模型直接读得懂，旧消息也能被识别。
class QuotedReply {
  const QuotedReply({required this.quote, required this.body});

  /// 被引用内容的摘要（已去掉 `> Quote: ` 前缀）。
  final String quote;

  /// 用户真正写的正文。
  final String body;

  static const String prefix = '> Quote: ';
  static const String separator = '\n\n';
  static const int maxQuoteLength = 30;

  /// 拼装发送文本。被引用的内容本身若也是引用回复，只取它的正文，避免层层嵌套；
  /// 换行压成空格，保证引用只占一行。
  static String compose({required String quotedContent, required String text}) {
    final source = parse(quotedContent)?.body ?? quotedContent;
    final flat = source.replaceAll(RegExp(r'\s+'), ' ').trim();
    final quote = flat.length > maxQuoteLength
        ? '${flat.substring(0, maxQuoteLength)}...'
        : flat;
    return '$prefix$quote$separator$text';
  }

  /// 识别以引用开头的消息；不是引用回复时返回 null。
  /// 只认 [compose] 产出的严格前缀，普通的 `> ` Markdown 引用不受影响。
  static QuotedReply? parse(String text) {
    if (!text.startsWith(prefix)) return null;
    final end = text.indexOf(separator, prefix.length);
    if (end < 0) return null;
    final quote = text.substring(prefix.length, end).trim();
    final body = text.substring(end + separator.length).trimLeft();
    if (quote.isEmpty || body.isEmpty) return null;
    return QuotedReply(quote: quote, body: body);
  }
}

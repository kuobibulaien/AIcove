import '../content_tags/domain/content_tag_registry.dart';
import '../content_tags/domain/content_tag_scanner.dart';
import '../content_tags/domain/content_tag_spec.dart';

/// 表情包的语义标签：AI 在正文里写自闭合的 `<sticker tag="晚安"/>`（ADR0044 注册）。
///
/// 不用方括号：方括号会被语音当成普通文字念出来。识别、切段和语音清理都经
/// 唯一扫描器，这里只放三处共用的判断，不做正则。
class StickerTag {
  const StickerTag._();

  static const String name = 'sticker';

  static const StaticContentTagProvider contentTags = StaticContentTagProvider(
    providerId: name,
    tagSpecs: [
      ContentTagSpec(
        name: name,
        ownerId: name,
        display: ContentTagDisplay.hidden,
      ),
    ],
  );

  static bool isElement(ContentTagSegment segment) =>
      segment is ContentTagElement && segment.spec.name == name;

  /// tag 属性，去掉首尾空白；缺失时为空串。
  static String tagOf(ContentTagElement element) =>
      (element.attributes['tag'] ?? '').trim();

  /// 单个片段去掉表情标签后剩下的文字：自闭合的整个删掉，成对的只留正文。
  static String textOf(ContentTagSegment segment) {
    if (segment is ContentTagOrphanClose && segment.spec.name == name) {
      return '';
    }
    if (!isElement(segment)) return segment.raw;
    final element = segment as ContentTagElement;
    return element.selfClosing ? '' : element.inner;
  }

  /// 整段文本去掉表情标签，只留纯文字（语音正文等只需要文字的地方用）。
  static String removeFrom(ContentTagScanner scanner, String text) {
    return scanner.scan(text).map((segment) {
      if (segment is! ContentTagElement) return textOf(segment);
      final inner = removeFrom(scanner, segment.inner);
      if (isElement(segment)) return inner;
      return '${segment.openTag}$inner${segment.closeTag}';
    }).join();
  }
}

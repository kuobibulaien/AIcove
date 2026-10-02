import '../content_tags/domain/content_tag_registry.dart';
import '../content_tags/domain/content_tag_scanner.dart';
import '../content_tags/domain/content_tag_spec.dart';
import 'image/image_plugin.dart';
import 'tts/tts_plugin.dart';

/// 第一方插件声明的内容标签提供方（ADR0044）。
const List<ContentTagProvider> firstPartyContentTagProviders = [
  TtsPlugin.contentTags,
  ImagePlugin.contentTags,
];

/// 与开关无关的解析（落库拆分、流式显示）使用的扫描器：全部提供方视为生效。
final ContentTagScanner firstPartyContentTagScanner = ContentTagScanner(
  ContentTagRegistry(firstPartyContentTagProviders),
);

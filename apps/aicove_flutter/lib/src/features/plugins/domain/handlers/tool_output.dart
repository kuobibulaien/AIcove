import 'package:aicove_agent_kernel/aicove_agent_kernel.dart' show ToolImage;
export 'package:aicove_agent_kernel/aicove_agent_kernel.dart' show ToolImage;

const nonVisionToolImage = '当前模型不支持看图，看不到这张图片。回复用户时必须说明两点：你看不了这张图；请用户换一个支持图片的模型后再试。';
String omittedToolImage(String source) => '［图片已省略：$source］';

class ToolOutput {
  const ToolOutput({
    this.text = '',
    this.images = const [],
    this.isError = false,
    this.structured,
  });
  final String text;
  final List<ToolImage> images;
  final bool isError;
  final Object? structured;
  String get persistentText => [
    text,
    ...images.map((i) => omittedToolImage(i.source)),
  ].where((s) => s.isNotEmpty).join('\n');
}

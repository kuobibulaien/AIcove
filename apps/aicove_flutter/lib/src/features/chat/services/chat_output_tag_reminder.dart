library;

/// 本轮输出标签提醒：放进 system-reminder，只提示可用标签，不规定格式。
///
/// 格式与顺序以预设或插件规则为准；插件标签写用法（预设不知道它们），
/// 预设标签只点名，避免与预设自己的说明冲突。没有可提醒的标签时返回空串。
String buildOutputTagReminder({
  bool imageInline = false,
  bool imageTool = false,
  bool tts = false,
  Iterable<String> presetTags = const [],
}) {
  final lines = <String>[
    if (imageInline) '- 想给对方发图时，在合适的位置写 <image>英文提示词</image>',
    if (!imageInline && imageTool)
      '- 想给对方发图时，调用 draw_image 工具，并在正文合适的位置放 <image></image> 占位',
    if (tts) '- 想用语音说出来的话，放进 <tts></tts>',
  ];
  final names = {
    for (final name in presetTags)
      if (name.trim().isNotEmpty && !_pluginTags.contains(name.trim()))
        name.trim(),
  };
  if (names.isNotEmpty) {
    lines.add('- 预设里提到的：${names.map((name) => '<$name>').join('、')}');
  }
  if (lines.isEmpty) return '';
  return ['本轮回复可以用到的标签（只是提醒，格式和顺序以预设与插件的说明为准）：', ...lines]
      .join('\n');
}

const _pluginTags = {'image', 'tts'};

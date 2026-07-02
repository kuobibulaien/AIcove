import 'package:aicove_flutter/src/core/utils/message_formatter.dart';

void main() {
  const cfg = MessageFormatConfig(enableChunking: true);
  final cases = <String, String>{
    'ascii spaces after dots': '你好...    世界',
    'fullwidth spaces after dots': '你好...　　　世界',
    'nbsp after dots': '你好...\u00A0\u00A0\u00A0世界',
    'tab after dots': '你好...\t\t\t世界',
  };

  for (final entry in cases.entries) {
    final chunks = MessageFormatter.formatAndChunkText(entry.value, cfg);
    print('${entry.key} => ${chunks.length}: $chunks');
  }
}

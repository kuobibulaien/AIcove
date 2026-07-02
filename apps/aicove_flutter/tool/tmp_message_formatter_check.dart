import 'package:aicove_flutter/src/core/utils/message_formatter.dart';

void main() {
  const cfg = MessageFormatConfig(enableChunking: true);
  final cases = <String, String>{
    '3_ascii': 'A   B',
    '4_ascii': 'A    B',
    '4_tabmix': 'A\t\t\t\tB',
    '4_nbsp': 'A\u00A0\u00A0\u00A0\u00A0B',
    '4_fullwidth': 'A\u3000\u3000\u3000\u3000B',
  };

  for (final e in cases.entries) {
    final chunks = MessageFormatter.formatAndChunkText(e.value, cfg);
    print('${e.key}: ${chunks.length} => $chunks');
  }
}

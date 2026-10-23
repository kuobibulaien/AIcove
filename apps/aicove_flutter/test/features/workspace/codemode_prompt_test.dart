import 'package:aicove_flutter/src/features/assistant/application/assistant_plugin.dart';
import 'package:aicove_flutter/src/features/workspace/application/codemode_declarations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'assistant directs discovery to codemode instead of a parallel tool-name catalog',
    () {
      final prompt = AssistantRequestScope.promptText;
      expect(prompt, contains('codemode 的 aicove 分组'));
      expect(prompt, contains('searchTools'));
      expect(prompt, contains('不要只给链接'));
      expect(prompt, isNot(contains('工具按范围分')));
      expect(codemodeGuidance, contains('Promise.allSettled'));
    },
  );
}

import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_request_message_builder.dart';

void main() {
  test('removes draft tags, unclosed drafts and prefill closes', () {
    const strip = ChatRequestMessageBuilder.stripAssistantDraftTags;
    for (final tag in [
      'think',
      'thinking',
      'thought',
      'cot',
      'reasoning',
      '思考',
      '思维链',
      'comic_plan',
    ]) {
      expect(strip('前<$tag a="1">秘密</$tag>\n\n\n后'), '前\n\n后');
      expect(strip('<$tag>秘密'), '');
    }
    expect(strip('秘密</THINKING>正文'), '正文');
    expect(strip('<think>x</think>正文</think>继续'), '正文继续');
  });

  test('protects fenced and inline code', () {
    const strip = ChatRequestMessageBuilder.stripAssistantDraftTags;
    expect(
      strip(
        '`<think>示例</think>`\n```xml\n<comic_plan>示例</comic_plan>\n```\n<think>秘密</think>正文',
      ),
      '`<think>示例</think>`\n```xml\n<comic_plan>示例</comic_plan>\n```\n正文',
    );
  });
}

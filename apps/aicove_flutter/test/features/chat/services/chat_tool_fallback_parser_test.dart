import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/features/chat/services/chat_tool_fallback_parser.dart';

void main() {
  const parser = ChatToolFallbackParser();

  test('extracts fallback call from execute_tool payload', () {
    const text = '''
<execute_tool>
{"tool_name":"draw_image","tool_code":"draw_image(prompt='  cat  ', size='1024x768', steps=20)"}
</execute_tool>
''';

    final calls = parser.extractFallbackToolCalls(text);

    expect(calls, hasLength(1));
    expect(calls.first.name, 'draw_image');
    expect(calls.first.arguments['prompt'], 'cat');
    expect(calls.first.arguments['steps'], 20);
    expect(calls.first.arguments['width'], 1024);
    expect(calls.first.arguments['height'], 768);
  });

  test('keeps tool_name when tool_code function name differs', () {
    const text = '''
<execute_tool>
{"tool_name":"custom_draw","tool_code":"draw_image(prompt='demo')"}
</execute_tool>
''';

    final calls = parser.extractFallbackToolCalls(text);

    expect(calls, hasLength(1));
    expect(calls.first.name, 'custom_draw');
    expect(calls.first.arguments['prompt'], 'demo');
  });

  test('extracts fallback call from action payload', () {
    const text =
        '{"action":"draw_image","arguments":{"prompt":"sunset","size":"800x600"}}';

    final calls = parser.extractFallbackToolCalls(text);

    expect(calls, hasLength(1));
    expect(calls.first.name, 'draw_image');
    expect(calls.first.arguments['prompt'], 'sunset');
    expect(calls.first.arguments['width'], 800);
    expect(calls.first.arguments['height'], 600);
  });

  test('extracts fallback call from prompt block payload', () {
    const text = '''
[prompt]
city skyline
[negative_prompt]
low quality
[size]
640x360
''';

    final calls = parser.extractFallbackToolCalls(text);

    expect(calls, hasLength(1));
    expect(calls.first.name, 'draw_image');
    expect(calls.first.arguments['prompt'], 'city skyline');
    expect(calls.first.arguments['negative_prompt'], 'low quality');
    expect(calls.first.arguments['width'], 640);
    expect(calls.first.arguments['height'], 360);
  });

  test('parses fenced json map for shared callers', () {
    const raw = '''
```json
{"action":"draw_image","prompt":"test"}
```
''';

    final parsed = parser.tryParseJsonMap(raw);

    expect(parsed, isNotNull);
    expect(parsed!['action'], 'draw_image');
    expect(parsed['prompt'], 'test');
  });
}

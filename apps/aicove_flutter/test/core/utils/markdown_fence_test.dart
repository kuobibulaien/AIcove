import 'package:aicove_flutter/src/core/utils/markdown_fence.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('closed backtick fence with language', () {
    const text = '前文\n```dart\nprint(1);\n```\n后文';
    final blocks = scanFencedCodeBlocks(text);
    expect(blocks, hasLength(1));
    final block = blocks.single;
    expect(block.language, 'dart');
    expect(block.code, 'print(1);');
    expect(block.closed, isTrue);
    expect(text.substring(block.start, block.end), '```dart\nprint(1);\n```');
  });

  test('tilde fence needs same char and at least the opening length', () {
    const text = '~~~~\na\n~~~\n```\nb\n~~~~\nc';
    final block = scanFencedCodeBlocks(text).single;
    expect(block.code, 'a\n~~~\n```\nb');
    expect(text.substring(block.end), '\nc');
  });

  test('unclosed fence extends to end of text', () {
    const text = '说明\n```python\ndef f():\n    pass';
    final block = scanFencedCodeBlocks(text).single;
    expect(block.closed, isFalse);
    expect(block.end, text.length);
    expect(block.code, 'def f():\n    pass');
  });

  test('CRLF lines and indented fences up to three spaces', () {
    const text = '   ```js\r\nx\r\n   ```\r\ny';
    final block = scanFencedCodeBlocks(text).single;
    expect(block.closed, isTrue);
    expect(block.language, 'js');
    expect(block.code, 'x');
  });

  test('inline backticks and four-space indent are not fences', () {
    expect(scanFencedCodeBlocks('用 ```code``` 包起来'), isEmpty);
    expect(scanFencedCodeBlocks('    ```\n    x\n    ```'), isEmpty);
  });

  test('multiple blocks in order', () {
    final blocks = scanFencedCodeBlocks('```\na\n```\n中间\n```sh\nb\n```');
    expect(blocks.map((b) => b.code), ['a', 'b']);
    expect(blocks.map((b) => b.language), ['', 'sh']);
  });
}

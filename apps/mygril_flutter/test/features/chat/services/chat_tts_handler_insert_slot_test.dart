import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/features/chat/services/chat_tts_handler.dart';

void main() {
  group('resolveInsertSlotByChars', () {
    test('文本前插入命中 slot 0', () {
      final slot = resolveInsertSlotByChars(
        textChunkLengths: const [4, 3, 5],
        textCharsBefore: 0,
      );
      expect(slot, 0);
    });

    test('中间位置按累计字符命中正确槽位', () {
      expect(
        resolveInsertSlotByChars(
          textChunkLengths: const [4, 3, 5],
          textCharsBefore: 2,
        ),
        1,
      );
      expect(
        resolveInsertSlotByChars(
          textChunkLengths: const [4, 3, 5],
          textCharsBefore: 5,
        ),
        2,
      );
      expect(
        resolveInsertSlotByChars(
          textChunkLengths: const [4, 3, 5],
          textCharsBefore: 9,
        ),
        3,
      );
    });

    test('超出总长度时插入末尾槽位', () {
      final slot = resolveInsertSlotByChars(
        textChunkLengths: const [4, 3],
        textCharsBefore: 99,
      );
      expect(slot, 2);
    });
  });
}

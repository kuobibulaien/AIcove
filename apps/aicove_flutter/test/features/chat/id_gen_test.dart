import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/features/chat/id_gen.dart';

void main() {
  test('genId 在高频连续调用时不应重复', () {
    const total = 5000;
    final ids = <String>{};
    for (var i = 0; i < total; i++) {
      ids.add(genId('msg'));
    }
    expect(ids.length, total);
  });

  test('genId 结果应包含前缀与两段数字', () {
    final id = genId('img');
    expect(
      id,
      matches(RegExp(r'^img_\d+_\d+$')),
    );
  });
}

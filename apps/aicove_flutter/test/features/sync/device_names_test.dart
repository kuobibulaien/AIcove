import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/features/sync/data/device_names.dart';

void main() {
  test('system names keep the model and drop the owner', () {
    expect(stripOwnerName('kuobibulaien的MacBook Pro'), 'MacBook Pro');
    expect(stripOwnerName("Ann's MacBook Air"), 'MacBook Air');
    expect(stripOwnerName('一加 13T'), '一加 13T');
    expect(stripOwnerName('我的'), '我的');
  });

  test('labels prefer synced names and mark this device', () {
    final names = {'a': 'MacBook Pro', 'b': '一加 13T'};
    expect(deviceLabel('a', ownId: 'a', names: names), '本机 · MacBook Pro');
    expect(deviceLabel('b', ownId: 'a', names: names), '一加 13T');
    expect(
      deviceLabel('c', ownId: 'a', names: names, peerNames: {'c': '平板'}),
      '平板',
    );
    expect(deviceLabel('12345678abcd', ownId: 'a', names: {}), '设备 12345678');
  });
}

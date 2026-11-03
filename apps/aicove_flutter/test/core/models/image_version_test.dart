import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/core/models/block_status.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';

void main() {
  test('旧图片重画后可切换并序列化所有版本', () {
    final old = ImageBlock(
      id: 'image',
      messageId: 'message',
      base64: 'old-image',
      width: 100,
      height: 200,
      prompt: 'old',
    );
    expect(old.toJson().containsKey('versions'), isFalse);
    final next = old.withAddedVersion(
      ImageVersionEntry(
        localPath: '/new.png',
        width: 300,
        height: 400,
        prompt: 'new',
      ),
    );
    expect(next.versions.length, 2);
    expect(next.activeVersionIndex, 1);
    expect(next.localPath, '/new.png');
    final restored = ImageBlock.fromJson(next.toJson()).withActiveVersion(0);
    expect(restored.base64, 'old-image');
    expect(restored.localPath, isNull);
    expect(restored.prompt, 'old');
    expect(restored.width, 100);
    expect(restored.id, old.id);
    expect(() => restored.withActiveVersion(2), throwsRangeError);
  });

  test('失败占位块生成成功只保存成功版本', () {
    final failed = ImageBlock(
      messageId: 'm',
      status: BlockStatus.error,
      prompt: 'retry',
    );
    final next = failed.withAddedVersion(
      ImageVersionEntry(localPath: '/new.png'),
    );
    expect(next.versions.length, 1);
    expect(next.status, BlockStatus.success);
  });
}

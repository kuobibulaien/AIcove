import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/content_tags/domain/content_tag_registry.dart';
import 'package:aicove_flutter/src/features/plugins/plugin_content_tags.dart';
import 'package:aicove_flutter/src/features/task_agent/application/delegate_task_plugin.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final registry = ContentTagRegistry(firstPartyContentTagProviders);

  test('每种回执正文都由注册表里的杂活回执标签识别', () {
    for (final status in TaskReceiptStatus.values) {
      final label = taskReceiptLabel(
        status,
        taskId: 't1',
        summary: '摘要',
        question: '问题',
      );
      expect(registry.eventLabelOf(label), same(taskReceiptEventLabel));
      expect(label, startsWith(taskReceiptEventLabel.format(
        taskReceiptEventLabel.detailOf(label)!,
      )));
    }
  });

  test('未登记的方括号文字当普通文本', () {
    expect(registry.eventLabelOf('[备注：随便写的]'), isNull);
    expect(registry.eventLabelOf('正文里提到 [杂活回执：已完成]'), isNull);
  });
}

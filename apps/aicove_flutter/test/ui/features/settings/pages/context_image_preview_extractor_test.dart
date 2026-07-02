import 'dart:convert';

import 'package:aicove_flutter/src/ui/features/settings/pages/context_image_preview_extractor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('extractContextImagePreviewsFromRequestBody', () {
    test('提取 OpenAI 风格 image_url', () {
      final raw = jsonEncode({
        'messages': [
          {
            'role': 'user',
            'content': [
              {
                'type': 'image_url',
                'image_url': {'url': 'data:image/jpeg;base64,AAAA'}
              },
              {
                'type': 'image_url',
                'image_url': {'url': 'https://example.com/a.png'}
              },
            ],
          },
        ],
      });

      final batch = extractContextImagePreviewsFromRequestBody(raw, limit: 4);
      expect(batch.items.length, 2);
      expect(batch.hasMore, isFalse);
      expect(batch.items[0].kind, ContextImagePreviewKind.dataUri);
      expect(batch.items[1].kind, ContextImagePreviewKind.remoteUrl);
    });

    test('提取 Claude 风格 base64 source', () {
      final raw = jsonEncode({
        'messages': [
          {
            'role': 'user',
            'content': [
              {
                'type': 'image',
                'source': {
                  'type': 'base64',
                  'media_type': 'image/png',
                  'data': 'BBBB',
                },
              },
            ],
          },
        ],
      });

      final batch = extractContextImagePreviewsFromRequestBody(raw, limit: 4);
      expect(batch.items.length, 1);
      expect(batch.items.first.kind, ContextImagePreviewKind.dataUri);
      expect(batch.items.first.value, startsWith('data:image/png;base64,BBBB'));
    });

    test('超出上限时标记 hasMore', () {
      final parts = List.generate(
        6,
        (index) => {
          'type': 'image_url',
          'image_url': {'url': 'data:image/jpeg;base64,IMG_$index'}
        },
      );
      final raw = jsonEncode({
        'messages': [
          {'role': 'user', 'content': parts}
        ],
      });

      final batch = extractContextImagePreviewsFromRequestBody(raw, limit: 2);
      expect(batch.items.length, 2);
      expect(batch.hasMore, isTrue);
      expect(batch.totalCount, greaterThanOrEqualTo(3));
    });

    test('非法 JSON 返回空结果', () {
      final batch =
          extractContextImagePreviewsFromRequestBody('{bad json', limit: 4);
      expect(batch.items, isEmpty);
      expect(batch.totalCount, 0);
      expect(batch.hasMore, isFalse);
    });
  });
}

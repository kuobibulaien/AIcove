import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aicove_flutter/src/core/api/image_providers/comfyui_image_adapter.dart';
import 'package:aicove_flutter/src/core/api/image_providers/image_provider_adapter.dart';
import 'package:aicove_flutter/src/core/api/image_providers/openai_compatible_image_adapter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'media_retry_test_client.dart';

ImageProviderRequest request({bool comfy = false}) => ImageProviderRequest(
  provider: comfy ? 'comfyui' : 'openai',
  model: comfy ? 'template/basic' : 'image-model',
  prompt: 'cat',
  width: 512,
  height: 512,
  count: 1,
  baseUrl: 'https://image.example',
  apiKey: 'test-key',
);

http.Response json(Object body) => http.Response(jsonEncode(body), 200);

Map<String, dynamic> finished() => {
  'job': {
    'outputs': {
      '9': {
        'images': [
          {'filename': 'cat.png', 'type': 'output'},
        ],
      },
    },
  },
};

class _OnCancelTimer implements Timer {
  _OnCancelTimer(this.inner, this.onCancel);

  final Timer inner;
  final void Function() onCancel;
  bool _cancelled = false;

  @override
  bool get isActive => inner.isActive;

  @override
  int get tick => inner.tick;

  @override
  void cancel() {
    inner.cancel();
    if (_cancelled) return;
    _cancelled = true;
    onCancel();
  }
}

void main() {
  test(
    'OpenAI retries offline download without resubmitting generation',
    () async {
      var posts = 0;
      var downloads = 0;
      final client = NoRedirectMockClient((req) async {
        if (req.method == 'POST') {
          posts++;
          return json({
            'data': [
              {'url': 'https://image.example/cat.png'},
            ],
          });
        }
        if (++downloads == 1) throw const SocketException('offline');
        return http.Response.bytes([1, 2, 3], 200);
      });
      addTearDown(client.close);
      try {
        final result = await OpenAICompatibleImageAdapter().generate(
          client: client,
          timeout: const Duration(seconds: 3),
          request: request(),
        );
        expect(result.images.single, [1, 2, 3]);
      } finally {
        expect(posts, 1, reason: 'generation POST count');
        expect(downloads, 2, reason: 'image GET count');
      }
    },
  );

  test('OpenAI retries rejected 429 submission once before success', () async {
    var posts = 0;
    final client = NoRedirectMockClient((req) async {
      expect(req.method, 'POST');
      if (++posts == 1) {
        return http.Response('limited', 429, headers: {'retry-after': '0'});
      }
      return json({
        'data': [
          {
            'b64_json': base64Encode([1, 2, 3]),
          },
        ],
      });
    });
    addTearDown(client.close);
    try {
      final result = await OpenAICompatibleImageAdapter().generate(
        client: client,
        timeout: const Duration(seconds: 3),
        request: request(),
      );
      expect(result.images.single, [1, 2, 3]);
    } finally {
      expect(posts, 2, reason: 'generation POST count');
    }
  });

  test('ComfyUI retries history 502 without submitting another task', () async {
    var posts = 0;
    var histories = 0;
    var downloads = 0;
    final client = NoRedirectMockClient((req) async {
      if (req.method == 'POST') {
        posts++;
        return json({'prompt_id': 'job'});
      }
      if (req.url.path.contains('/history/')) {
        if (++histories == 1) return http.Response('bad gateway', 502);
        return json(finished());
      }
      downloads++;
      return http.Response.bytes([4, 5], 200);
    });
    addTearDown(client.close);
    try {
      final result = await const ComfyUIImageAdapter().generate(
        client: client,
        timeout: const Duration(seconds: 3),
        request: request(comfy: true),
      );
      expect(result.images.single, [4, 5]);
    } finally {
      expect(posts, 1, reason: 'task POST count');
      expect(histories, 2, reason: 'history GET count');
      expect(downloads, 1, reason: 'image GET count');
    }
  });

  test('ComfyUI submission timeout is not retried', () async {
    var posts = 0;
    final client = NoRedirectMockClient((req) async {
      expect(req.method, 'POST');
      posts++;
      throw TimeoutException('submission timed out');
    });
    addTearDown(client.close);
    await expectLater(
      const ComfyUIImageAdapter().generate(
        client: client,
        timeout: const Duration(seconds: 3),
        request: request(comfy: true),
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(posts, 1);
  });

  test(
    'ComfyUI exhausted polling budget preserves running-task timeout',
    () async {
      var posts = 0;
      var histories = 0;
      final client = NoRedirectMockClient((req) async {
        if (req.method == 'POST') {
          posts++;
          return json({'prompt_id': 'job'});
        }
        histories++;
        return json({});
      });
      addTearDown(client.close);
      const timeout = Duration(milliseconds: 80);
      await expectLater(
        const ComfyUIImageAdapter().generate(
          client: client,
          timeout: timeout,
          request: request(comfy: true),
        ),
        throwsA(
          isA<TimeoutException>()
              .having((e) => e.message, 'message', 'ComfyUI 等待超时，服务端任务可能仍在运行')
              .having((e) => e.duration, 'duration', timeout),
        ),
      );
      expect(posts, 1);
      expect(histories, 1);
    },
  );

  test('ComfyUI keeps complete 429 when submission exhausts budget', () async {
    var posts = 0;
    var wrappedTimer = false;
    var expiredAfterResponse = false;
    const budget = Duration(seconds: 1);
    final client = NoRedirectMockClient((req) async {
      posts++;
      return http.Response('limited', 429);
    });
    addTearDown(client.close);

    // Future.timeout cancels its timer after receiving the complete response.
    // Consume the remaining wall-clock budget at that exact boundary, without
    // racing the timeout against an intentionally slow network response.
    final result = runZoned(
      () => const ComfyUIImageAdapter().generate(
        client: client,
        timeout: budget,
        request: request(comfy: true),
      ),
      zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, duration, callback) {
          final timer = parent.createTimer(zone, duration, callback);
          if (wrappedTimer) return timer;
          wrappedTimer = true;
          return _OnCancelTimer(timer, () {
            sleep(budget);
            expiredAfterResponse = true;
          });
        },
      ),
    );
    await expectLater(
      result,
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'ComfyUI 提交任务 HTTP 429: limited',
        ),
      ),
    );
    expect(expiredAfterResponse, isTrue);
    expect(posts, 1);
  });

  test('OpenAI submission 503 preserves error without retrying', () async {
    var posts = 0;
    final client = NoRedirectMockClient((req) async {
      posts++;
      return http.Response('unavailable', 503);
    });
    addTearDown(client.close);
    await expectLater(
      OpenAICompatibleImageAdapter().generate(
        client: client,
        timeout: const Duration(seconds: 3),
        request: request(),
      ),
      throwsA(
        isA<Exception>().having(
          (error) => error.toString(),
          'message',
          'Exception: HTTP 503: unavailable',
        ),
      ),
    );
    expect(posts, 1);
  });

  test('ComfyUI retries submission 429 and view 502 independently', () async {
    var posts = 0;
    var histories = 0;
    var downloads = 0;
    final client = NoRedirectMockClient((req) async {
      if (req.method == 'POST') {
        if (++posts == 1) return http.Response('limited', 429);
        return json({'prompt_id': 'job'});
      }
      if (req.url.path.contains('/history/')) {
        histories++;
        return json(finished());
      }
      if (++downloads == 1) return http.Response('bad gateway', 502);
      return http.Response.bytes([4, 5], 200);
    });
    addTearDown(client.close);
    final result = await const ComfyUIImageAdapter().generate(
      client: client,
      timeout: const Duration(seconds: 3),
      request: request(comfy: true),
    );
    expect(result.images.single, [4, 5]);
    expect(posts, 2);
    expect(histories, 1);
    expect(downloads, 2);
  });

  test('ComfyUI catalog requests stay outside generation retries', () async {
    var gets = 0;
    final client = NoRedirectMockClient((req) async {
      gets++;
      return http.Response('unavailable', 503);
    });
    addTearDown(client.close);
    await expectLater(
      ComfyUIImageAdapter.fetchTemplates(
        baseUrl: 'https://image.example',
        client: client,
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'ComfyUI 拉取模板列表失败：HTTP 503（unavailable）',
        ),
      ),
    );
    expect(gets, 1);
  });
}

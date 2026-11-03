import 'dart:async';
import 'dart:convert';

import 'package:aicove_flutter/src/core/api/agent_api.dart';
import 'package:aicove_flutter/src/core/api/image_providers/comfyui_workflow.dart';
import 'package:aicove_flutter/src/core/app_logger.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'media_retry_test_client.dart';

Future<void> flush() => Future<void>.delayed(Duration.zero);

class HeldImages {
  final entered = <String>[];
  final releases = <String, Completer<void>>{};
  int active = 0;
  int peak = 0;

  late final client = NoRedirectMockClient((request) async {
    if (request.method == 'GET') {
      if (request.url.path.contains('/history/')) {
        final id = request.url.pathSegments.last;
        return http.Response(
          jsonEncode({
            id: {
              'status': {'completed': true},
              'outputs': {
                '9': {
                  'images': [
                    {'filename': 'image.png', 'type': 'output'},
                  ],
                },
              },
            },
          }),
          200,
        );
      }
      return http.Response.bytes([1], 200);
    }
    final body = jsonDecode(request.body) as Map;
    final isComfy = body['prompt'] is Map;
    final prompt = isComfy
        ? body['prompt']['6']['inputs']['text'] as String
        : (body['input'] ?? body['prompt']) as String;
    entered.add(prompt);
    active++;
    if (active > peak) peak = active;
    await releases.putIfAbsent(prompt, Completer<void>.new).future;
    active--;
    return http.Response(
      isComfy
          ? jsonEncode({'prompt_id': prompt})
          : body.containsKey('input')
          ? '{"image":"AQ=="}'
          : '{"data":[{"b64_json":"AQ=="}]}',
      200,
    );
  });

  void release(String prompt) =>
      releases.putIfAbsent(prompt, Completer<void>.new).complete();

  void releaseAll() {
    for (final release in releases.values) {
      if (!release.isCompleted) release.complete();
    }
  }
}

Future<ImageGenerationResult> generate(
  AgentApiClient api,
  String prompt, {
  String provider = 'openai',
  String? base = 'https://queue.test',
  String key = 'private-channel-key',
  Map<String, dynamic>? config,
}) => api.generateImage(
  provider: provider,
  model: provider == 'novelai' ? 'nai-diffusion-3' : 'image',
  prompt: prompt,
  providerApiBase: base,
  providerApiKey: key,
  customConfig: config,
  requestId: prompt,
);

void main() {
  setUp(AppLogger.clear);
  for (final (provider, limit) in [('openai', 2), ('novelai', 1)]) {
    test(
      '$provider shares limit $limit across two clients for six images',
      () async {
        final server = HeldImages();
        final apis = List.generate(
          2,
          (_) => AgentApiClient(client: server.client),
        );
        final tasks = [
          for (var i = 0; i < 6; i++)
            generate(apis[i % 2], '$i', provider: provider),
        ];
        // Always drain the bodies, even when a pre-fix admission assertion fails.
        try {
          await flush();
          expect(server.entered, List.generate(limit, (i) => '$i'));
          for (var i = 0; i < 6; i++) {
            server.release('$i');
            await flush();
            expect(server.active, lessThanOrEqualTo(limit));
          }
          await Future.wait(tasks);
          expect(server.peak, limit);
        } finally {
          for (var i = 0; i < 6; i++) {
            final release = server.releases.putIfAbsent(
              '$i',
              Completer<void>.new,
            );
            if (!release.isCompleted) release.complete();
          }
          await Future.wait(tasks);
        }
      },
    );

    test('$provider keeps different API keys independent', () async {
      final server = HeldImages();
      final api = AgentApiClient(client: server.client);
      final occupied = [
        for (var i = 0; i < limit; i++)
          generate(api, 'held$i', provider: provider, key: 'first-key'),
      ];
      await flush();
      final other = generate(
        AgentApiClient(client: server.client),
        'other',
        provider: provider,
        key: 'second-key',
      );
      try {
        await flush();
        expect(server.entered, contains('other'));
      } finally {
        server.releaseAll();
        await Future.wait([...occupied, other]);
      }
    });
  }

  for (final (label, provider, bases, configs)
      in <(String, String, List<String?>, List<Map<String, dynamic>?>)>[
        (
          'NovelAI empty default and legacy aliases',
          'novelai',
          [null, 'https://image.novelai.net', 'https://api.novelai.net'],
          [null, null, null],
        ),
        (
          'OpenAI root and v1 aliases',
          'openai',
          [
            'https://alias.test',
            'https://alias.test/v1',
            'https://alias.test/v1/',
          ],
          [null, null, null],
        ),
        (
          'absolute imageEndpoint overrides different bases',
          'openai',
          ['https://a.test', 'https://b.test/v1', 'https://c.test'],
          List.generate(
            3,
            (_) => {'imageEndpoint': 'https://actual.test/images'},
          ),
        ),
      ]) {
    test('$label share the actual target lane', () async {
      final server = HeldImages();
      final tasks = [
        for (var i = 0; i < 3; i++)
          generate(
            AgentApiClient(client: server.client),
            '$i',
            provider: provider,
            base: bases[i],
            config: configs[i],
          ),
      ];
      try {
        await flush();
        expect(server.entered.length, provider == 'novelai' ? 1 : 2);
      } finally {
        for (var i = 0; i < 3; i++) {
          server.release('$i');
        }
        await Future.wait(tasks);
      }
    });
  }

  for (final (provider, limit) in [
    ('openai', 2),
    ('novelai', 1),
    ('comfyui', 1),
  ]) {
    for (final (label, base, equivalent) in [
      (
        'host case',
        'https://canonical.test/proxy',
        'https://CANONICAL.test/proxy',
      ),
      (
        'scheme case',
        'https://canonical.test/proxy',
        'HTTPS://canonical.test/proxy',
      ),
      (
        'explicit HTTPS port',
        'https://canonical.test/proxy',
        'https://canonical.test:443/proxy',
      ),
      (
        'explicit HTTP port',
        'http://canonical.test/proxy',
        'http://canonical.test:80/proxy',
      ),
      (
        'trailing slash',
        'https://canonical.test/proxy',
        'https://canonical.test/proxy/',
      ),
    ]) {
      test('$provider $label shares channel limit $limit', () async {
        final server = HeldImages();
        final api = AgentApiClient(client: server.client);
        Map<String, dynamic>? configFor(String target) => switch (provider) {
          'openai' => {'imageEndpoint': target},
          'comfyui' => {
            'requestFormat': 'comfyui',
            'comfyWorkflow': ComfyUIWorkflow.buildStandardGraph(
              checkpoint: 'model',
              values: {},
            ),
            'comfyBindings': {'prompt': '6.text'},
          },
          _ => null,
        };
        final tasks = [
          for (var i = 0; i < limit; i++)
            generate(
              api,
              'held$i',
              provider: provider,
              base: base,
              config: configFor(base),
            ),
          generate(
            api,
            'equivalent',
            provider: provider,
            base: equivalent,
            config: configFor(equivalent),
          ),
        ];
        try {
          await flush();
          expect(server.entered, List.generate(limit, (i) => 'held$i'));
        } finally {
          for (final prompt in [
            for (var i = 0; i < limit; i++) 'held$i',
            'equivalent',
          ]) {
            server.release(prompt);
          }
          await Future.wait(tasks);
        }
        expect(server.peak, limit);
      });
    }
  }

  for (final provider in ['openai', 'novelai']) {
    for (final (label, target) in [
      ('path case', 'https://distinct.test/Proxy?route=one'),
      ('query', 'https://distinct.test/proxy?route=two'),
      ('non-default port', 'https://distinct.test:8443/proxy?route=one'),
    ]) {
      test(
        '$provider preserves meaningful $label in channel identity',
        () async {
          final server = HeldImages();
          final api = AgentApiClient(client: server.client);
          const base = 'https://distinct.test/proxy?route=one';
          final tasks = [
            for (var i = 0; i < (provider == 'novelai' ? 1 : 2); i++)
              generate(
                api,
                'held$i',
                provider: provider,
                base: base,
                config: provider == 'openai' ? {'imageEndpoint': base} : null,
              ),
            generate(
              api,
              'distinct',
              provider: provider,
              base: target,
              config: provider == 'openai' ? {'imageEndpoint': target} : null,
            ),
          ];
          try {
            await flush();
            expect(server.entered, contains('distinct'));
          } finally {
            server.releaseAll();
            await Future.wait(tasks);
          }
        },
      );
    }
  }

  test('distinct absolute imageEndpoints are independent channels', () async {
    final server = HeldImages();
    final api = AgentApiClient(client: server.client);
    final tasks = [
      for (var i = 0; i < 3; i++)
        generate(
          api,
          '$i',
          config: {
            'imageEndpoint': i == 2
                ? 'https://two.test/image'
                : 'https://one.test/image',
          },
        ),
    ];
    try {
      await flush();
      expect(server.entered.length, 3);
    } finally {
      server.releaseAll();
      await Future.wait(tasks);
    }
  });

  test('queue logs use a channel digest without plaintext API key', () async {
    final server = HeldImages();
    final api = AgentApiClient(client: server.client);
    final tasks = [for (var i = 0; i < 3; i++) generate(api, '$i')];
    try {
      await flush();
      final entries = AppLogger.entries.value
          .where((e) => e.source == 'ImageRequestGate')
          .toList();
      expect(entries, isNotEmpty);
      final digest = sha256
          .convert(utf8.encode('private-channel-key'))
          .toString()
          .substring(0, 12);
      final expectedSummary = sha256
          .convert(
            utf8.encode(
              'openai|https://queue.test/v1/images/generations|$digest',
            ),
          )
          .toString()
          .substring(0, 12);
      expect(
        entries.map((e) => e.metadata?['keySummary']),
        everyElement(expectedSummary),
      );
      expect(
        jsonEncode(entries.map((e) => e.metadata).toList()),
        isNot(contains('private-channel-key')),
      );
      expect(entries.any((e) => e.metadata?['queuePosition'] == 1), true);
    } finally {
      for (var i = 0; i < 3; i++) {
        server.release('$i');
      }
      await Future.wait(tasks);
    }
    expect(
      AppLogger.entries.value.where(
        (e) =>
            e.source == 'ImageRequestGate' &&
            e.metadata?.containsKey('queueWaitMs') == true,
      ),
      hasLength(3),
    );
  });

  test('adapter durationMs excludes queue wait', () async {
    final server = HeldImages();
    final api = AgentApiClient(client: server.client);
    final first = generate(api, 'first');
    final second = generate(api, 'second');
    final third = generate(api, 'third');
    await flush();
    // Only budget/timing tests use elapsed time rather than admission barriers.
    await Future<void>.delayed(const Duration(milliseconds: 160));
    server.release('first');
    await first;
    await flush();
    server.release('third');
    await third;
    server.release('second');
    await second;
    final done = AppLogger.entries.value.singleWhere(
      (e) => e.message == '图片请求完成' && e.metadata?['requestId'] == 'third',
    );
    final queue = AppLogger.entries.value.where(
      (e) =>
          e.source == 'ImageRequestGate' &&
          (e.metadata?['queueWaitMs'] as int? ?? 0) >= 140,
    );
    expect(queue, hasLength(1));
    expect(done.metadata!['durationMs'] as int, lessThan(100));
  });

  test('ComfyUI queued longer than timeout starts with a fresh budget', () async {
    final firstEntered = Completer<void>();
    final releaseFirst = Completer<void>();
    var posts = 0;
    final client = NoRedirectMockClient((request) async {
      if (request.method == 'POST') {
        final index = ++posts;
        if (index == 1) {
          firstEntered.complete();
          await releaseFirst.future;
        }
        return http.Response('{"prompt_id":"$index"}', 200);
      }
      if (request.url.path.contains('history')) {
        final id = request.url.pathSegments.last;
        return http.Response(
          jsonEncode({
            id: {
              'status': {'completed': true},
              'outputs': {
                '9': {
                  'images': [
                    {'filename': 'image.png', 'type': 'output'},
                  ],
                },
              },
            },
          }),
          200,
        );
      }
      return http.Response.bytes([1], 200);
    });
    final config = <String, dynamic>{
      'requestFormat': 'comfyui',
      'comfyWorkflow': ComfyUIWorkflow.buildStandardGraph(
        checkpoint: 'model',
        values: {},
      ),
      'comfyBindings': {'prompt': '6.text'},
    };
    final first = generate(
      AgentApiClient(client: client, timeout: const Duration(seconds: 3)),
      'first',
      provider: 'comfyui',
      base: 'http://LOCALHOST:8188/proxy/',
      config: config,
    );
    await firstEntered.future;
    final second = generate(
      AgentApiClient(
        client: client,
        timeout: const Duration(milliseconds: 100),
      ),
      'second',
      provider: 'comfyui',
      base: 'http://localhost:8188/proxy',
      config: config,
    );
    // Attach immediately to observe the old-code failure without unhandled errors.
    final success = expectLater(
      second,
      completion(isA<ImageGenerationResult>()),
    );
    await Future<void>.delayed(const Duration(milliseconds: 180));
    try {
      expect(posts, 1);
    } finally {
      releaseFirst.complete();
      await first;
      await success;
    }
    expect(posts, 2);
  });
}

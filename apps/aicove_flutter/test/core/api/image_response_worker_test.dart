import 'dart:convert';

import 'package:aicove_flutter/src/core/api/agent_api.dart';
import 'package:aicove_flutter/src/core/api/image_providers/image_provider_adapter.dart';
import 'package:aicove_flutter/src/core/api/image_providers/openai_compatible_image_adapter.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'OpenAI worker preserves mixed base64/url ordering and raw response',
    () async {
      final client = MockClient(
        (request) async => request.method == 'GET'
            ? http.Response.bytes([2], 200)
            : http.Response(
                jsonEncode({
                  'data': [
                    {'b64_json': 'AQ=='},
                    {'url': 'https://local.test/second'},
                    {'b64_json': 'Aw==', 'url': 'https://local.test/ignored'},
                  ],
                }),
                200,
              ),
      );
      addTearDown(client.close);
      final result = await OpenAICompatibleImageAdapter().generate(
        client: client,
        timeout: const Duration(seconds: 10),
        request: const ImageProviderRequest(
          provider: 'openai',
          model: 'test',
          prompt: 'test',
          width: 32,
          height: 32,
          count: 3,
          baseUrl: 'https://local.test/v1',
          apiKey: 'test',
        ),
      );
      expect(result.images.map((bytes) => bytes.single), [1, 2, 3]);
      expect(result.rawResponse!['data'], hasLength(3));
    },
  );

  test('OpenAI worker retains HTTP error wording', () async {
    final client = MockClient(
      (_) async => http.Response('invalid request', 400),
    );
    addTearDown(client.close);
    await expectLater(
      OpenAICompatibleImageAdapter().generate(
        client: client,
        timeout: const Duration(seconds: 10),
        request: const ImageProviderRequest(
          provider: 'openai',
          model: 'test',
          prompt: 'test',
          width: 32,
          height: 32,
          count: 1,
          baseUrl: 'https://local.test/v1',
          apiKey: 'test',
        ),
      ),
      throwsA(
        predicate(
          (Object error) =>
              error.toString().contains('HTTP 400: invalid request'),
        ),
      ),
    );
  });

  test('NovelAI worker extracts ZIP entries in order', () async {
    final zip = ZipEncoder().encode(
      Archive()
        ..addFile(ArchiveFile('first.png', 1, [4]))
        ..addFile(ArchiveFile('second.png', 1, [5])),
    )!;
    final client = MockClient(
      (_) async => http.Response.bytes(
        zip,
        200,
        headers: {'content-type': 'application/zip'},
      ),
    );
    addTearDown(client.close);
    final result = await AgentApiClient(client: client).generateImage(
      provider: 'novelai',
      model: 'nai-diffusion-3',
      prompt: 'test',
      providerApiBase: 'https://local.test',
      providerApiKey: 'test',
    );
    expect(result.images.map((bytes) => bytes.single), [4, 5]);
  });
}

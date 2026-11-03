import 'dart:convert';

import 'package:aicove_flutter/src/core/api/image_providers/comfyui_image_adapter.dart';
import 'package:aicove_flutter/src/core/api/image_providers/comfyui_workflow.dart';
import 'package:aicove_flutter/src/core/api/image_providers/image_provider_adapter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

String symbolicPrompt() => jsonEncode({
  'layout': 'balanced_2',
  'summary': {'caption': 'Travel manga'},
  'items': [
    {'panel': 1, 'slot': 'S', 'label': 'character', 'caption': 'Traveler'},
    {'panel': 2, 'slot': 'T', 'label': 'text', 'text': '到家了'},
  ],
});

ImageProviderRequest request(
  String prompt,
  String model,
  Map<String, dynamic> config,
) => ImageProviderRequest(
  provider: 'comfyui',
  model: model,
  prompt: prompt,
  negativePrompt: 'extra people',
  width: 1088,
  height: 1920,
  count: 1,
  baseUrl: 'http://localhost:8188/proxy',
  apiKey: 'test',
  seed: 42,
  customConfig: config,
);

void main() {
  for (final mode in ['gateway', 'custom', 'checkpoint']) {
    test('compiles symbolic prompt before submitting $mode request', () async {
      final config = <String, dynamic>{
        if (mode == 'custom') ...{
          ComfyUIWorkflow.modeKey: ComfyUIWorkflow.customMode,
          ComfyUIWorkflow.workflowKey: {
            '6': {
              'class_type': 'CLIPTextEncode',
              'inputs': {'text': 'old'},
            },
            '9': {
              'class_type': 'SaveImage',
              'inputs': {
                'images': ['6', 0],
              },
            },
          },
          ComfyUIWorkflow.bindingsKey: {'prompt': '6.text'},
        },
      };
      final calls = <String>[];
      final client = MockClient((req) async {
        calls.add('${req.method} ${req.url.path}');
        if (req.method == 'POST') {
          final body = jsonDecode(req.body) as Map;
          final String prompt;
          if (mode == 'gateway') {
            expect(req.url.path, '/proxy/api/generate');
            expect(body['template'], 'moss_image');
            expect(body['negative_prompt'], 'extra people');
            prompt = body['prompt'] as String;
          } else {
            expect(req.url.path, '/proxy/prompt');
            final graph = body['prompt'] as Map;
            final encoder = graph.values.firstWhere(
              (n) =>
                  n['class_type'] == 'CLIPTextEncode' &&
                  (n['inputs']['text'] as String).startsWith('{'),
            );
            prompt = encoder['inputs']['text'] as String;
          }
          final layout = jsonDecode(prompt) as Map;
          expect(layout['items'][0]['bbox'], [-725, -486, -30, 486]);
          expect(layout['items'][1]['text'], '到家了');
          expect(layout['summary']['caption'], startsWith('Page frame guide:'));
          expect(layout.containsKey('layout'), isFalse);
          return http.Response(jsonEncode({'prompt_id': 'job'}), 200);
        }
        if (req.url.path == '/proxy/history/job') {
          return http.Response(
            jsonEncode({
              'job': {
                'status': {'completed': true, 'status_str': 'success'},
                'outputs': {
                  '9': {
                    'images': [
                      {'filename': 'manga.png', 'type': 'output'},
                    ],
                  },
                },
              },
            }),
            200,
          );
        }
        expect(req.url.path, '/proxy/view');
        return http.Response.bytes([1, 2, 3], 200);
      });
      addTearDown(client.close);
      final original = symbolicPrompt();
      final req = request(
        original,
        mode == 'checkpoint' ? 'base.safetensors' : 'template/moss_image',
        config,
      );
      final response = await const ComfyUIImageAdapter().generate(
        client: client,
        timeout: const Duration(seconds: 5),
        request: req,
      );
      expect(response.images.single, [1, 2, 3]);
      expect(response.rawResponse, {'prompt_id': 'job'});
      expect(req.prompt, original);
      expect(calls, hasLength(3));
    });
  }

  test('invalid symbolic layout fails before any network submission', () async {
    var sent = false;
    final client = MockClient((req) async {
      sent = true;
      return http.Response('{}', 200);
    });
    addTearDown(client.close);
    await expectLater(
      const ComfyUIImageAdapter().generate(
        client: client,
        timeout: const Duration(seconds: 5),
        request: request(
          '{"layout":"unknown","items":[{"panel":1,"slot":"S"}]}',
          'template/moss_image',
          {},
        ),
      ),
      throwsFormatException,
    );
    expect(sent, isFalse);
  });
}

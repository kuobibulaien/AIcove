import 'dart:convert';

import 'package:aicove_flutter/src/core/api/agent_api.dart';
import 'package:aicove_flutter/src/core/api/manga_prompt_sanitizer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'media_retry_test_client.dart';

void main() {
  const comic = '@page\nmanga page\n@panel\nclose up\n@character\ngirl';
  for (final model in ['nai-diffusion-4-full', 'nai-diffusion-5-full']) {
    test(
      '$model manga defaults preserve comic styling and explicit overrides',
      () async {
        Future<Map> parameters(
          String prompt, [
          Map<String, dynamic>? extra,
        ]) async {
          Map? sent;
          final api = AgentApiClient(
            client: NoRedirectMockClient((request) async {
              sent = (jsonDecode(request.body) as Map)['parameters'] as Map;
              return http.Response('{"image":"AQ=="}', 200);
            }),
          );
          await api.generateImage(
            provider: 'novelai',
            model: model,
            prompt: prompt,
            providerApiBase: 'https://local.test',
            providerApiKey: 'test',
            customConfig: {'image_parameters': extra},
          );
          return sent!;
        }

        final defaults = await parameters(comic);
        expect(defaults['qualityToggle'], false);
        expect(defaults['ucPreset'], 3);
        expect(defaults['v4_negative_prompt']['legacy_uc'], false);
        final explicit = await parameters(comic, {
          'qualityToggle': true,
          'ucPreset': 1,
        });
        expect(explicit['qualityToggle'], true);
        expect(explicit['ucPreset'], 1);
        final plain = await parameters('girl | boy');
        expect(plain.containsKey('qualityToggle'), false);
        expect(plain.containsKey('ucPreset'), false);
      },
    );
  }
  test('manga dialogue and artist tags are compiled safely', () async {
    Map? sent;
    final api = AgentApiClient(client: NoRedirectMockClient((request) async {
      sent = (jsonDecode(request.body) as Map)['parameters'] as Map;
      return http.Response('{"image":"AQ=="}', 200);
    }));
    await api.generateImage(
      provider: 'novelai', model: 'nai-diffusion-5-full',
      providerApiBase: 'https://local.test', providerApiKey: 'test',
      negativePrompt: 'text, watermark, halftone, screentone, multiple views, lowres',
      prompt: '<artist>, solo, 0.7::close-up::,no text,\n'
          '@position manual\n@page\nmanga page, 3 panels\n@panel 1\n'
          'top wide panel, 1girl, 1boy\n@character C1\n'
          '1girl, silver long hair, speech bubble\n@center 0.35,0.18\n'
          'Text: "また、からかってる…？"\n@negative\nblonde hair\n'
          '@character C2\n1boy, black short hair\n@center 0.70,0.20\n'
          '@panel 2\nmiddle panel\n@character C1\n'
          '1girl, winking, speech bubble\n@center 0.50,0.52\nText: "冗談だよ"',
    );
    final caption = sent!['v4_prompt']['caption'] as Map;
    final base = caption['base_caption'] as String;
    expect(base, isNot(contains('@')));
    expect(base, isNot(contains('solo')));
    expect(base, isNot(contains('no text')));
    expect(base, endsWith('\nText: また、からかってる…？\n\n冗談だよ'));
    expect(base, contains('text'));
    final chars = caption['char_captions'] as List;
    expect(chars.length, 3);
    expect(chars.map((c) => c['centers'][0]).toList(), [
      {'x': 0.35, 'y': 0.18}, {'x': 0.7, 'y': 0.2}, {'x': 0.5, 'y': 0.52},
    ]);
    expect(chars.every((c) => !(c['char_caption'] as String).contains('Text:')), isTrue);
    expect(sent!['v4_negative_prompt']['caption']['base_caption'], 'watermark, lowres');
  });

  test('missing page and malformed markers never leak into NovelAI', () async {
    for (final prompt in ['@panel 1\nscene\n@character\ngirl\n@center 0.2,0.3\nText: “hello”', '@position manual\n@unknown stray\n@page\nText: "hello"']) {
      Map? sent;
      final api = AgentApiClient(client: NoRedirectMockClient((request) async {
        sent = jsonDecode(request.body) as Map;
        return http.Response('{"image":"AQ=="}', 200);
      }));
      await api.generateImage(provider: 'novelai', model: 'nai-diffusion-5-full', prompt: prompt,
          providerApiBase: 'https://local.test', providerApiKey: 'test');
      expect(sent!['input'], isNot(contains('@')));
      expect(sent!['input'], contains('Text: hello'));
    }
  });

  test('section directives keep positive and negative content separate', () async {
    Map? sent;
    final api = AgentApiClient(client: NoRedirectMockClient((request) async {
      sent = jsonDecode(request.body) as Map;
      return http.Response('{"image":"AQ=="}', 200);
    }));
    await api.generateImage(
      provider: 'novelai', model: 'nai-diffusion-5-full',
      providerApiBase: 'https://local.test', providerApiKey: 'test',
      negativePrompt: 'watermark, speech bubble',
      prompt: '@C1, @C1_outfit, leading scenery, sunlight\n'
          '@position manual\n@page\npage scene\n@negative\nblur\n'
          '@position manual\nfog\n@panel 1\npanel scene\n'
          '@negative\nnoise\n@center 0.2,0.3\ngrain\n'
          '@character C1\ngirl\n@negative\nblonde hair\n'
          '@center 0.4,0.5\nred hair\n@character C2\n'
          '@C1, @C1_outfit, standing by fence, gentle smile\n'
          '@unknown directive\n',
    );
    final params = sent!['parameters'] as Map;
    final positive = params['v4_prompt']['caption'] as Map;
    final negative = params['v4_negative_prompt']['caption'] as Map;
    expect(positive['base_caption'], contains('leading scenery, sunlight'));
    for (final tag in ['blur', 'fog', 'noise', 'grain']) {
      expect(positive['base_caption'], isNot(contains(tag)));
      expect(negative['base_caption'], contains(tag));
    }
    expect(negative['base_caption'], contains('watermark'));
    expect(negative['base_caption'], isNot(contains('speech bubble')));
    expect(negative['char_captions'][0]['char_caption'], contains('red hair'));
    expect(positive['char_captions'][0]['char_caption'], isNot(contains('red hair')));
    expect(positive['char_captions'][1]['char_caption'], 'standing by fence, gentle smile');
    expect(positive['char_captions'][1]['char_caption'], isNot(contains('@')));
  });

  test('sanitizer handles brackets, weights, and line separators', () {
    expect(MangaPromptSanitizer.positive(
      '{{no text}}，(solo)\n[no text], 1.2::[no text]::, scenery',
      '2girls',
    ), 'scenery');
    expect(MangaPromptSanitizer.negative(
      '[text]\n{{speech bubble}}, (comic), 0.7::{halftone}::, watermark',
    ), 'watermark');
  });

  test('V3 section prompts retain characters before dialogue', () async {
    Map? sent;
    final api = AgentApiClient(client: NoRedirectMockClient((request) async {
      sent = jsonDecode(request.body) as Map;
      return http.Response('{"image":"AQ=="}', 200);
    }));
    await api.generateImage(
      provider: 'novelai', model: 'nai-diffusion-3',
      providerApiBase: 'https://local.test', providerApiKey: 'test',
      prompt: '@page\nmanga page\n@panel\nscene\n@character C1\n'
          'silver hair\nText: "hello"\n@character C2\nblack hair',
    );
    final input = sent!['input'] as String;
    expect(input, contains('silver hair'));
    expect(input, contains('black hair'));
    expect(input, endsWith('\nText: hello'));
    expect(input.indexOf('silver hair'), lessThan(input.indexOf('\nText:')));
  });

  test('page negatives work without an external negative prompt', () async {
    Map? sent;
    final api = AgentApiClient(client: NoRedirectMockClient((request) async {
      sent = jsonDecode(request.body) as Map;
      return http.Response('{"image":"AQ=="}', 200);
    }));
    await api.generateImage(
      provider: 'novelai', model: 'nai-diffusion-5-full',
      providerApiBase: 'https://local.test', providerApiKey: 'test',
      prompt: '@page\nscene\n@negative\nblur\n@panel\n'
          'close up\n@position manual\ncity lights',
    );
    final params = sent!['parameters'] as Map;
    expect(params['v4_negative_prompt']['caption']['base_caption'], 'blur');
    expect(params['v4_prompt']['caption']['base_caption'], contains('city lights'));
  });

}

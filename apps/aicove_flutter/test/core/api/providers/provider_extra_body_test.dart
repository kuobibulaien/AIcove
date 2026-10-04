import 'package:aicove_flutter/src/core/api/providers/provider_adapter_factory.dart';
import 'package:aicove_flutter/src/core/api/providers/provider_extra_body.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('provider extra body', () {
    test('parses JSON object and rejects other input', () {
      expect(parseProviderExtraBody('  '), isEmpty);
      expect(
        parseProviderExtraBody('{"persona": "Emily Dickinson"}'),
        {'persona': 'Emily Dickinson'},
      );
      expect(() => parseProviderExtraBody('{persona}'), throwsFormatException);
      expect(() => parseProviderExtraBody('[1]'), throwsFormatException);
    });

    test('stays out of sanitized config and is merged into the body', () {
      final config = copyCustomConfigWithProviderExtraBody(
        {'apiPath': '/chat/completions', 'max_tokens': 100},
        {'persona': 'Joan Didion', 'max_tokens': 200},
      );
      final sanitized =
          ProviderAdapterFactory.sanitizeRequestCustomConfig(config)!;
      expect(sanitized.containsKey(kProviderExtraBodyField), isFalse);

      final body = ProviderAdapterFactory.getAdapter('openai').buildRequestBody(
        model: 'echo',
        messages: const [
          {'role': 'user', 'content': 'hi'},
        ],
        customConfig: sanitized,
      );
      applyProviderExtraBody(body, config);

      expect(body['persona'], 'Joan Didion');
      expect(body['max_tokens'], 200);
      expect(body['model'], 'echo');
    });

    test('empty extra body clears the stored field', () {
      final config = copyCustomConfigWithProviderExtraBody(
        {kProviderExtraBodyField: {'persona': 'x'}},
        const {},
      );
      expect(config.containsKey(kProviderExtraBodyField), isFalse);
      expect(formatProviderExtraBody(config), isEmpty);
    });
  });
}

import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/features/settings/settings_models.dart';

void main() {
  test('claude-fable-5 should infer as chat instead of TTS', () {
    expect(ModelType.inferFromModelId('claude-fable-5'), ModelType.chat);
  });

  test('OpenAI TTS voice ids still infer as TTS when exact', () {
    expect(ModelType.inferFromModelId('fable'), ModelType.tts);
    expect(ModelType.inferFromModelId('openai:fable'), ModelType.tts);
  });
}

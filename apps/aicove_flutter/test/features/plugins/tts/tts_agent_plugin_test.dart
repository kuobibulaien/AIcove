import 'package:aicove_flutter/src/features/agent_plugins/aicove_plugin.dart';
import 'package:aicove_flutter/src/features/agent_plugins/plugin_runtime.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_config.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_plugin.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('installs natively and declares request and responses only', () {
    final runtime =
        PluginRuntime.fromPlugins([TtsPlugin(TtsConfig(enabled: true))]);
    expect(runtime.plugin('tts')!.capabilities,
        {AppCapability.request, AppCapability.responses});
  });
}

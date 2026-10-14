import 'package:aicove_flutter/src/features/agent_plugins/aicove_plugin.dart';
import 'package:aicove_flutter/src/features/agent_plugins/plugin_runtime.dart';
import 'package:aicove_flutter/src/features/plugins/web_search/web_search_config.dart';
import 'package:aicove_flutter/src/features/plugins/web_search/web_search_plugin.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('installs natively and declares only the request capability', () {
    final runtime =
        PluginRuntime.fromPlugins([WebSearchPlugin(const WebSearchConfig())]);
    expect(runtime.plugin(WebSearchPlugin.pluginId)!.capabilities,
        {AppCapability.request});
  });
}

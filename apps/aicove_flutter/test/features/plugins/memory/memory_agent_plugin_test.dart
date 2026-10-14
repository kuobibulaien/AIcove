import 'package:aicove_flutter/src/features/agent_plugins/aicove_plugin.dart';
import 'package:aicove_flutter/src/features/agent_plugins/plugin_runtime.dart';
import 'package:aicove_flutter/src/features/plugins/memory/memory_plugin.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final _refProvider = Provider<Ref>((ref) => ref);

void main() {
  test('installs natively and declares only the request capability', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final runtime = PluginRuntime.fromPlugins(
      [MemoryPlugin(container.read(_refProvider))],
    );
    expect(runtime.plugin('memory')!.capabilities, {AppCapability.request});
  });
}

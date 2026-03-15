import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/features/chat/services/chat_plugin_context_builder.dart';
import 'package:aicove_flutter/src/features/plugins/domain/base_plugin.dart';
import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin_metadata.dart';
import 'package:aicove_flutter/src/features/plugins/memory/memory_config.dart';
import 'package:aicove_flutter/src/features/plugins/memory/memory_plugin.dart';

Future<String?> _noopToolHandler(Map<String, dynamic> _) async => 'ok';

AITool _buildTool(String name) => AITool(
      name: name,
      description: 'test tool',
      parameters: const {},
      handler: _noopToolHandler,
    );

class _StubPlugin extends BasePlugin {
  _StubPlugin({
    required String id,
    required this.onGetTools,
  }) : super(
          metadata: PluginMetadata(
            id: id,
            name: id,
            description: 'test plugin',
            version: '1.0.0',
            author: 'test',
            icon: Icons.extension,
          ),
        );

  final List<AITool> Function(int callCount) onGetTools;
  int getToolsCallCount = 0;

  @override
  bool get enabled => true;

  @override
  List<AITool> getTools() {
    getToolsCallCount += 1;
    return onGetTools(getToolsCallCount);
  }

  @override
  Future<String?> getSystemPrompt({
    String? userMessage,
    bool supportsToolCalling = false,
  }) async =>
      null;

  @override
  Future<PluginProcessResult> processResponse(String text) async =>
      PluginProcessResult(
        processedText: text,
        events: const [],
      );
}

class _SpyMemoryPlugin extends MemoryPlugin {
  _SpyMemoryPlugin(Ref ref) : super(const MemoryConfig(enabled: true), ref);

  String? lastConversationId;

  @override
  Future<String?> getSystemPrompt({
    String? userMessage,
    bool supportsToolCalling = false,
    String? conversationId,
  }) async {
    lastConversationId = conversationId;
    return 'memory_prompt';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('collectPluginToolsWithRetry 遇到依赖刷新窗口错误会重试一次', () async {
    const builder = ChatPluginContextBuilder();
    final plugin = _StubPlugin(
      id: 'image',
      onGetTools: (callCount) {
        if (callCount == 1) {
          throw StateError(
            "'package:riverpod/src/framework/element.dart': "
            "Failed assertion: line 675 pos 7: '!_didChangeDependency': "
            'Cannot use ref functions after the dependency of a provider '
            'changed but before the provider rebuilt',
          );
        }
        return [_buildTool('draw_image')];
      },
    );

    final tools = await builder.collectPluginToolsWithRetry(
      [plugin],
      retryDelay: Duration.zero,
      maxRetryAttempts: 1,
    );

    expect(tools.map((t) => t.name), contains('draw_image'));
    expect(plugin.getToolsCallCount, 2);
  });

  test('collectPluginToolsWithRetry 遇到普通错误不重试', () async {
    const builder = ChatPluginContextBuilder();
    final plugin = _StubPlugin(
      id: 'image',
      onGetTools: (_) => throw StateError('some other error'),
    );

    final tools = await builder.collectPluginToolsWithRetry(
      [plugin],
      retryDelay: Duration.zero,
      maxRetryAttempts: 1,
    );

    expect(tools, isEmpty);
    expect(plugin.getToolsCallCount, 1);
  });

  test('collectPluginToolsWithRetry 超过重试次数后停止', () async {
    const builder = ChatPluginContextBuilder();
    final plugin = _StubPlugin(
      id: 'image',
      onGetTools: (_) => throw StateError(
        "Failed assertion: '!_didChangeDependency': "
        'Cannot use ref functions after the dependency of a provider changed '
        'but before the provider rebuilt',
      ),
    );

    final tools = await builder.collectPluginToolsWithRetry(
      [plugin],
      retryDelay: Duration.zero,
      maxRetryAttempts: 1,
    );

    expect(tools, isEmpty);
    expect(plugin.getToolsCallCount, 2);
  });

  test('buildPluginPromptEntriesWithFilter 会向 MemoryPlugin 透传目标会话 ID',
      () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final builder = const ChatPluginContextBuilder();
    final pluginProvider = Provider<_SpyMemoryPlugin>((ref) {
      return _SpyMemoryPlugin(ref);
    });
    final plugin = container.read(pluginProvider);

    final result = await builder.buildPluginPromptEntriesWithFilter(
      [plugin],
      userMessage: '你好',
      supportsToolCalling: false,
      conversationId: 'conv_target',
    );

    expect(plugin.lastConversationId, 'conv_target');
    expect(result.entries.single.content, 'memory_prompt');
  });
}

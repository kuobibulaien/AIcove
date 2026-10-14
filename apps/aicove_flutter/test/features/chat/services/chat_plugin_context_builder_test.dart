import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_plugin_support.dart';

import 'package:aicove_flutter/src/features/chat/services/chat_plugin_context_builder.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart'
    show isProviderRefreshTimingError;
import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin_metadata.dart';

Future<String?> _noopToolHandler(Map<String, dynamic> _) async => 'ok';

AITool _buildTool(String name) => AITool(
      name: name,
      description: 'test tool',
      parameters: const {},
      handler: _noopToolHandler,
    );

StateError _buildProviderRefreshTimingError() => StateError(
      "'package:riverpod/src/framework/element.dart': "
      "Failed assertion: line 675 pos 7: '!_didChangeDependency': "
      'Cannot use ref functions after the dependency of a provider '
      'changed but before the provider rebuilt',
    );

class _StubPlugin extends TestPlugin {
  _StubPlugin({
    required String id,
    required this.onGetTools,
    this.onGetSystemPrompt,
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
  final Future<String?> Function(
    int callCount,
    String? userMessage,
    bool supportsToolCalling,
  )? onGetSystemPrompt;
  int getToolsCallCount = 0;
  int getSystemPromptCallCount = 0;

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
  }) async {
    getSystemPromptCallCount += 1;
    return onGetSystemPrompt?.call(
      getSystemPromptCallCount,
      userMessage,
      supportsToolCalling,
    );
  }

  @override
  Future<PluginProcessResult> processResponse(String text) async =>
      PluginProcessResult(
        processedText: text,
        events: const [],
      );
}

PluginPromptSource _promptSource(TestPlugin plugin) => PluginPromptSource(
      pluginId: plugin.id,
      pluginName: plugin.name,
      build: () => plugin.getSystemPrompt(userMessage: '你好'),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('isProviderRefreshTimingError 能识别标准 Riverpod 刷新窗口错误', () {
    expect(isProviderRefreshTimingError(_buildProviderRefreshTimingError()),
        isTrue);
  });

  test('isProviderRefreshTimingError 能识别仅含 !_didChangeDependency 的断言变体', () {
    final error = StateError(
        "Failed assertion: '!_didChangeDependency': some other context");

    expect(isProviderRefreshTimingError(error), isTrue);
  });

  test('isProviderRefreshTimingError 不会误判普通错误', () {
    expect(
        isProviderRefreshTimingError(StateError('some other error')), isFalse);
  });

  test('collectToolsWithRetry 遇到依赖刷新窗口错误会重试一次', () async {
    const builder = ChatPluginContextBuilder();
    final plugin = _StubPlugin(
      id: 'image',
      onGetTools: (callCount) {
        if (callCount == 1) {
          throw _buildProviderRefreshTimingError();
        }
        return [_buildTool('draw_image')];
      },
    );

    final tools = await builder.collectToolsWithRetry(
      [PluginToolSource(pluginId: plugin.id, tools: plugin.getTools)],
      retryDelay: Duration.zero,
      maxRetryAttempts: 1,
    );

    expect(tools.map((t) => t.name), contains('draw_image'));
    expect(plugin.getToolsCallCount, 2);
  });

  test('collectToolsWithRetry 遇到普通错误不重试', () async {
    const builder = ChatPluginContextBuilder();
    final plugin = _StubPlugin(
      id: 'image',
      onGetTools: (_) => throw StateError('some other error'),
    );

    final tools = await builder.collectToolsWithRetry(
      [PluginToolSource(pluginId: plugin.id, tools: plugin.getTools)],
      retryDelay: Duration.zero,
      maxRetryAttempts: 1,
    );

    expect(tools, isEmpty);
    expect(plugin.getToolsCallCount, 1);
  });

  test('collectToolsWithRetry 超过重试次数后停止', () async {
    const builder = ChatPluginContextBuilder();
    final plugin = _StubPlugin(
      id: 'image',
      onGetTools: (_) => throw StateError(
        "Failed assertion: '!_didChangeDependency': "
        'Cannot use ref functions after the dependency of a provider changed '
        'but before the provider rebuilt',
      ),
    );

    final tools = await builder.collectToolsWithRetry(
      [PluginToolSource(pluginId: plugin.id, tools: plugin.getTools)],
      retryDelay: Duration.zero,
      maxRetryAttempts: 1,
    );

    expect(tools, isEmpty);
    expect(plugin.getToolsCallCount, 2);
  });

  test('buildPromptEntries 遇到依赖刷新窗口错误会重试一次', () async {
    const builder = ChatPluginContextBuilder();
    final plugin = _StubPlugin(
      id: 'memory',
      onGetTools: (_) => const <AITool>[],
      onGetSystemPrompt: (callCount, userMessage, supportsToolCalling) async {
        if (callCount == 1) {
          throw _buildProviderRefreshTimingError();
        }
        return 'prompt_after_retry';
      },
    );

    final result = await builder.buildPromptEntries(
      [_promptSource(plugin)],
      retryDelay: Duration.zero,
      maxRetryAttempts: 1,
    );

    expect(result.entries.single.content, 'prompt_after_retry');
    expect(result.entries.single.injected, isTrue);
    expect(plugin.getSystemPromptCallCount, 2);
  });

  test('buildPromptEntries 遇到普通错误时不会重试且按原逻辑降级', () async {
    const builder = ChatPluginContextBuilder();
    final plugin = _StubPlugin(
      id: 'memory',
      onGetTools: (_) => const <AITool>[],
      onGetSystemPrompt: (_, __, ___) async =>
          throw StateError('some other error'),
    );

    final result = await builder.buildPromptEntries(
      [_promptSource(plugin)],
      retryDelay: Duration.zero,
      maxRetryAttempts: 1,
    );

    expect(plugin.getSystemPromptCallCount, 1);
    expect(result.entries.single.injected, isFalse);
    expect(result.entries.single.reason, 'build_failed');
    expect(result.entries.single.error, contains('some other error'));
  });
}

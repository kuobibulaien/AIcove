import 'dart:async';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart';
import 'package:aicove_flutter/src/core/api/agent_api.dart';
import 'package:aicove_flutter/src/core/api/providers/provider_adapter.dart'
    hide ApiCallResult;
import 'package:aicove_flutter/src/core/app_logger.dart';
import 'package:aicove_flutter/src/features/chat/domain/tool_call_label.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_api_runner.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';

class _Client extends AgentApiClient {
  int calls = 0;

  @override
  Future<SendMessageRichResult> sendMessageRich({
    required String agentId,
    required String sessionId,
    required String modelFullId,
    required List<Map<String, dynamic>> messages,
    required String userText,
    double? temperature,
    double? topP,
    String? token,
    String? providerApiBase,
    String? providerApiKey,
    Map<String, dynamic>? customConfig,
    ProviderChatRequestOptions? requestOptions,
    List<Map<String, dynamic>>? tools,
    TraceLogger? trace,
    String? turnId,
    int? roundIndex,
    String? traceId,
  }) async {
    calls++;
    return SendMessageRichResult(
      text: 'done',
      toolResults: const [],
      toolCalls: calls == 1
          ? const [
              ToolCall(
                id: 'r1',
                name: 'read',
                arguments: {'path': '/tmp/v1.3.1.json'},
              ),
            ]
          : const [],
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final fails in [false, true]) {
    test(
      'reports activity until a slow tool ${fails ? 'throws' : 'returns'}',
      () async {
        final events = <String>[];
        final entered = Completer<void>();
        final release = Completer<void>();
        final runner = KernelApiRunner.withAgentClientFactory(
          agentClientFactory: (_) => _Client(),
        );
        final run = runner.executeApiCall(
          config: ApiConfig(
            settings: mapUiModelsToAppSettings({
              'model_configs': {
                'openai:test': {
                  'chat_capabilities': ['tools'],
                },
              },
            }),
            modelFullId: 'openai:test',
            providerApiBase: 'https://invalid.test',
            providerApiKey: 'test',
            customConfig: const {},
            messages: const [
              {'role': 'user', 'content': 'look'},
            ],
            onToolActivity: (call) {
              events.add('${call.id}:start');
              return () => events.add('${call.id}:end');
            },
          ),
          sessionId: 'activity',
          userText: 'look',
          responseProcessors: const [],
          availableTools: [
            AITool(
              name: 'read',
              description: 'read',
              parameters: const {},
              handler: (_) async {
                events.add('handler');
                entered.complete();
                await release.future;
                if (fails) throw StateError('controlled tool failure');
                return 'content';
              },
              effect: ToolEffect.readDiagnostic,
            ),
          ],
        );

        await entered.future;
        expect(events, ['r1:start', 'handler']);
        release.complete();
        await run;
        expect(events, ['r1:start', 'handler', 'r1:end']);
      },
    );
  }

  test('labels a call by its tool and most telling argument', () {
    expect(
      toolCallLabel('read', {'path': '/tmp/v1.3.1.json'}),
      'read · /tmp/v1.3.1.json',
    );
    expect(
      toolCallLabel('read', {
        'path': '/path/to/home/projects/aicove/presets/酒馆兼容/v1.3.1.json',
      }),
      'read · …/酒馆兼容/v1.3.1.json',
    );
    expect(toolCallLabel('list_tools', const {}), 'list_tools');
    expect(toolCallLabel('codemode', {'code': 'x'}), '运行脚本');
  });

  test(
    'path hints trim trailing separators and retain the last two segments',
    () {
      expect(
        toolCallHint({'path': r'C:\Users\someone\projects\parent\file.json'}),
        '…/parent/file.json',
      );
      expect(
        toolCallHint({'path': '/path/to/home/projects/parent/folder/'}),
        '…/parent/folder',
      );
      expect(
        toolCallHint({'path': 'relative/long/project/parent/file.json'}),
        '…/parent/file.json',
      );
      expect(toolCallHint({'path': '/tmp/a.json'}), '/tmp/a.json');
      expect(toolCallHint({'path': 'a.json'}), 'a.json');
      expect(toolCallHint({'path': './a.json'}), './a.json');
      expect(toolCallHint({'path': 'parent/folder/'}), 'parent/folder');
      expect(toolCallHint({'path': 'C:\\tmp\\a.json\\'}), r'C:\tmp\a.json');
    },
  );

  test('long parents never consume the file name budget', () {
    final parent = List.filled(60, '目').join();
    final hint = toolCallHint({'path': '/root/$parent/important.json'})!;
    expect(hint, endsWith('/important.json'));
    expect(hint.length, lessThanOrEqualTo(40));
    expect(hint, startsWith('…/'));
    final longName = '${List.filled(60, 'a').join()}.json';
    final longHint = toolCallHint({'path': '/root/$parent/$longName'})!;
    expect(
      longHint,
      '${List.filled(25, 'a').join()}…${List.filled(9, 'a').join()}.json',
    );
    expect(longHint.length, 40);
    expect(
      toolCallHint({'path': '/root/${List.filled(39, 'x').join()}'}),
      List.filled(39, 'x').join(),
    );
  });
}

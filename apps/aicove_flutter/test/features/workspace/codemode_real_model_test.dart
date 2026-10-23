// Opt-in ADR0108 acceptance: every response is from the real DeepSeek endpoint.
import 'dart:convert';
import 'dart:io';
import 'package:aicove_flutter/src/core/api/agent_api.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/agent_runtime_contracts.dart';
import 'package:aicove_flutter/src/features/agent_plugins/tool_policy.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_plugin.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_api_runner.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/plugins/data/tool_result_store.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/workspace/application/codemode_declarations.dart';
import 'package:aicove_flutter/src/features/workspace/application/workspace_toolset.dart';
import 'package:aicove_flutter/src/features/workspace/data/workspace_store.dart';
import 'package:flutter_test/flutter_test.dart';
import '../task_agent/agent_execution_reliability_test.dart' show ScriptClient;

final _key = Platform.environment['DEEPSEEK_API_KEY'];
Future<Map<String, dynamic>> _run(String id, {bool chain = false}) async {
  final root = Directory(
    '../../scratch/codemode-backend/real/$id-${DateTime.now().millisecondsSinceEpoch}',
  ).absolute;
  await root.create(recursive: true);
  final store = await WorkspaceStore.open(root);
  try {
    final ws = (await store.create(name: 'AIcove', id: 'aicove')).id;
    if (chain) {
      for (var i = 1; i <= 12; i++) {
        final text = i == 12
            ? '链路结束，最终暗号：CHAIN_COMPLETE_TWELVE。'
            : '下一份文件：chain/${i + 1}.md。请逐个直接调用 read，不要用 codemode 或 bash。';
        await store.write(
          ws,
          'chain/$i.md',
          utf8.encode(text),
          runId: 'fixture',
        );
      }
    }
    final set = WorkspaceToolset(
      store: store,
      workspaceIds: {ws},
      runId: id,
      enableScripts: true,
      enableShell: true,
    );
    final tools = assembleCodemodeTools([
      ...set.tools(),
      ToolResultStore.shared.reader(id),
    ]);
    final actual = AgentApiClient();
    // ScriptClient records requests, but delegates every request to AgentApiClient.
    final counter = ScriptClient(
      (n, messages) => actual.sendMessageRich(
        agentId: 'default',
        sessionId: id,
        modelFullId: 'openai:deepseek-flash',
        messages: messages,
        userText: '',
        providerApiBase: 'https://api.deepseek.com',
        providerApiKey: _key,
        temperature: 0.2,
        tools: directToolSchemas(tools),
      ),
    );
    final watch = Stopwatch()..start();
    final result =
        await KernelApiRunner.withAgentClientFactory(
          agentClientFactory: (_) => counter,
        ).executeApiCall(
          config: ApiConfig(
            settings: mapUiModelsToAppSettings({}),
            modelFullId: 'openai:deepseek-flash',
            providerApiBase: 'https://api.deepseek.com',
            providerApiKey: _key,
            customConfig: const {},
            modelTemperature: 0.2,
            toolResultStore: ToolResultStore(
              () async => Directory('${root.path}/tool-results'),
            ),
            toolResultOwner: id,
            currentWorkspaceId: () => set.currentWorkspaceId,
            toolPolicy: const AgentToolPolicy(
              authorization: AgentToolAuthorization.allowAll,
            ),
            tools: directToolSchemas(tools),
            boundTools: tools,
            messages: [
              {
                'role': 'system',
                'content':
                    '${AssistantRequestScope.promptText}\n${await set.prompt()}\n当前空间网页运行尚未实现；请保存完整产物，告知路径及如何用外部浏览器玩。禁止编造下载成功。所有文件操作限当前工作区，不安装依赖、启动服务、终止进程或打开浏览器；优先下载 Release 成品，不要从源码构建。',
              },
              {
                'role': 'user',
                'content': chain
                    ? '从 chain/1.md 开始，按文件指向依次读取十二份文件，最后告诉我暗号。验收要求：每次只直接调用一个 read，不能用 codemode、bash 或并行调用跳步。'
                    : 'https://github.com/0xSynt4x/MyRaidRealmWEB/ 我想玩这个',
              },
            ],
          ),
          sessionId: id,
          userText: null,
          responseProcessors: const [],
          availableTools: tools,
        );
    final nested = <Map<String, dynamic>>[
      for (final output in result.rawToolResults)
        for (final call
            in (output.structured as Map?)?['codemodeCalls'] as List? ?? [])
          Map<String, dynamic>.from(call as Map),
    ];
    final files = [
      for (final file in await store.files(ws))
        {'path': file.path, 'bytes': file.size},
    ];
    final metrics = <String, dynamic>{
      'id': id,
      'rounds': counter.requests.length,
      'directCalls': result.toolCalls.length,
      'nestedCalls': nested.length,
      'directFailures': result.rawToolResults.where((r) => r.isError).length,
      'nestedFailures': nested.where((c) => c['status'] == 'error').length,
      'rawResults': [
        for (final output in result.rawToolResults)
          {
            'name': output.name,
            'isError': output.isError,
            'text': output.result,
          },
      ],
      'status': result.status.name,
      'seconds': watch.elapsedMilliseconds / 1000,
      'workspace': store.directoryOf(ws).path,
      'reply': result.processedText,
      'files': files,
      'nested': nested,
      'direct': [
        for (final call in result.toolCalls)
          {'name': call.name, 'arguments': call.arguments},
      ],
      if (!chain)
        'baseline': {
          'trace': 'tr_1792670560031032',
          'source': 'code-mode照抄Pi实施方案 §1',
          'rounds': 5,
          'toolFailures': 2,
        },
    };
    await File(
      '${root.path}/metrics.json',
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(metrics));
    print('REAL_CODEMODE_METRICS ${jsonEncode(metrics)}');
    expect(result.status, ApiRunStatus.completed);
    expect(RegExp(r'[\u4e00-\u9fff]').hasMatch(result.processedText), true);
    if (chain) {
      expect(result.processedText, contains('CHAIN_COMPLETE_TWELVE'));
      expect(counter.requests.length, greaterThan(10));
      expect(result.toolCalls.where((c) => c.name == 'read').length, 12);
    } else {
      expect(
        files.any(
          (f) =>
              '${f['path']}'.toLowerCase().endsWith('.html') &&
              (f['bytes'] as int) > 0,
        ),
        true,
        reason: 'Must download a playable HTML artifact',
      );
      expect(
        result.rawToolResults.any(
          (r) => r.result.contains('invalid_tool_arguments'),
        ),
        false,
      );
    }
    return metrics;
  } finally {
    await store.close();
  }
}

void main() {
  test(
    'original game download scenario',
    () async {
      await _run('game');
    },
    skip: _key == null,
    timeout: Timeout.none,
  );
  test(
    'twelve dependent reads finish in one uncapped run',
    () async {
      await _run('chain', chain: true);
    },
    skip: _key == null,
    timeout: Timeout.none,
  );
  test(
    'same game scenario failures versus recorded pre-change trace',
    () async {
      final metrics = await _run('comparison');
      expect(
        (metrics['directFailures'] as int) + (metrics['nestedFailures'] as int),
        lessThan(2),
      );
    },
    skip: _key == null,
    timeout: Timeout.none,
  );
}

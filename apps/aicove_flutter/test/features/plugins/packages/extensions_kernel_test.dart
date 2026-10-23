import 'dart:convert';
import 'dart:io';
import 'package:aicove_agent_kernel/aicove_agent_kernel.dart';
import 'package:aicove_flutter/src/core/api/agent_api.dart';
import 'package:aicove_flutter/src/core/api/providers/provider_adapter.dart'
    hide ApiCallResult;
import 'package:aicove_flutter/src/core/app_logger.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/agent_runtime_contracts.dart';
import 'package:aicove_flutter/src/features/agent_plugins/tool_policy.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_package_tools.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_review.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_api_runner.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/plugins/data/tool_result_store.dart';
import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:aicove_flutter/src/features/plugins/packages/aicove_package.dart';
import 'package:aicove_flutter/src/features/plugins/packages/package_plugin.dart';
import 'package:aicove_flutter/src/features/plugins/packages/package_providers.dart';
import 'package:aicove_flutter/src/features/plugins/packages/package_store.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/task_agent/application/task_agent_runner.dart';
import 'package:aicove_flutter/src/features/task_agent/task_agent_providers.dart';
import 'package:aicove_flutter/src/features/workspace/application/workspace_shell.dart';
import 'package:aicove_flutter/src/features/workspace/data/workspace_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'extension_test_support.dart';
import 'package:aicove_flutter/src/features/background_agent/background_agent_service.dart';

class _Client extends AgentApiClient {
  final List<List<Map<String, dynamic>>> sent = [];
  _Client(this.call, {this.extra = const []});
  final List<ToolCall> extra;
  final ToolCall call;
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
    sent.add(jsonDecode(jsonEncode(messages)).cast<Map<String, dynamic>>());
    return SendMessageRichResult(
      text: 'done',
      toolResults: const [],
      toolCalls: sent.length == 1 ? [call, ...extra] : const [],
    );
  }
}

class _InstallGate implements ToolGate {
  @override
  GateVerdict check(KernelToolCall call, ToolEffect effect) =>
      call.name == AssistantPackageTools.installTool
      ? const GateVerdict.ask('安装扩展包')
      : const GateVerdict.allow();
}

class _Human implements ApprovalPort {
  _Human(this.allow, {this.human = true});
  final bool allow, human;
  int calls = 0;
  @override
  Future<bool> request(ApprovalRequest request) async {
    calls++;
    ToolCallScope.current!.humanApproved = human && allow;
    return allow;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late WorkspaceStore workspaces;
  late AicovePackagesNotifier notifier;
  late PackageStore packages;
  late ToolResultStore results;
  late String workspace;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('extension_kernel_');
    workspaces = await WorkspaceStore.open(Directory('${root.path}/spaces'));
    workspace = (await workspaces.create(name: 'authorized')).id;
    packages = PackageStore(Directory('${root.path}/packages'));
    notifier = AicovePackagesNotifier(Future.value(packages));
    await notifier.ready;
    results = ToolResultStore(() async => Directory('${root.path}/results'));
  });
  tearDown(() async {
    notifier.dispose();
    await workspaces.close();
    await root.delete(recursive: true);
  });

  Future<ApiCallResult> execute(
    _Client client,
    List<AITool> tools, {
    ApprovalPort? approvals,
  }) =>
      KernelApiRunner.withAgentClientFactory(
        agentClientFactory: (_) => client,
      ).executeApiCall(
        config: ApiConfig(
          settings: mapUiModelsToAppSettings({}),
          modelFullId: 'openai:test',
          providerApiBase: 'https://invalid.test',
          providerApiKey: 'test',
          customConfig: const {},
          messages: const [
            {'role': 'user', 'content': 'run'},
          ],
          toolResultStore: results,
          toolResultOwner: 'owner',
          toolPolicy: AgentToolPolicy(
            authorization: AgentToolAuthorization.allowAll,
            approvals: approvals,
            customGate: approvals == null ? null : _InstallGate(),
          ),
        ),
        sessionId: 'owner',
        userText: 'run',
        responseProcessors: const [],
        availableTools: tools,
      );

  Future<PackagePlugin> plugin(String source, {String id = 'demo'}) async {
    final plugin = PackagePlugin(
      AicovePackage.parse(scriptFiles(source, id: id)),
    );
    await plugin.prepare();
    return plugin;
  }

  test(
    'script tools reach kernel validation and handler output, with failed call not breaking loop',
    () async {
      final script = await plugin(scriptSource);
      final tool = script.getTools().single;
      final client = _Client(
        ToolCall(id: 'valid', name: tool.name, arguments: {'value': 11}),
        extra: [
          ToolCall(
            id: 'invalid',
            name: tool.name,
            arguments: {'value': 'wrong'},
          ),
          ToolCall(
            id: 'throw',
            name: tool.name,
            arguments: {'value': 1, 'fail': true},
          ),
        ],
      );
      final result = await execute(client, [tool]);
      expect(result.replyText, 'done');
      expect(result.rawToolResults, hasLength(3));
      expect(result.rawToolResults.first.result, 'count:1\n33');
      expect(result.rawToolResults[1].isError, true);
      expect(
        result.rawToolResults[1].result,
        contains('invalid_tool_arguments'),
      );
      expect(result.rawToolResults[2].result, contains('intentional-failure'));
      expect(client.sent, hasLength(2));
    },
  );

  test(
    'plugin handler calls other run tools through the same guarded host',
    () async {
      final script = await plugin(
        '''aicove.registerTool({name:'combine', description:'Combine',
      inputSchema:{type:'object',properties:{}},handler:async () => {
        const result = await tools.helper({value:13}); text(result.text); return 39;
      }});''',
      );
      final helper = AITool(
        name: 'helper',
        description: 'Helper',
        parameters: const {},
        effect: ToolEffect.readDiagnostic,
        handler: (_) async => 'helper:13',
      );
      final tool = script.getTools().single;
      final result = await execute(
        _Client(ToolCall(id: 'c', name: tool.name, arguments: {})),
        [tool, helper],
      );
      expect(result.rawToolResults.single.result, 'helper:13\n39');
    },
  );

  test(
    'large skill pages and large JS output use ADR0101 references, never early 50 KiB truncation',
    () async {
      final long = '${'x' * 60000}TAIL-SECRET';
      final skill = PackagePlugin(
        AicovePackage.parse({
          ...skillFiles(),
          'references/long.txt': utf8.encode(long),
          'scripts/long.js': utf8.encode(
            'text(await skill.readText("references/long.txt"));',
          ),
        }),
      );
      for (final name in [
        'read_skill_sample-skill',
        'run_skill_js_sample-skill',
      ]) {
        final args = {
          'name': 'sample-skill',
          'path': name.startsWith('read')
              ? 'references/long.txt'
              : 'scripts/long.js',
        };
        final tool = skill.getTools().firstWhere((t) => t.name == name);
        final result = await execute(
          _Client(ToolCall(id: 'c', name: name, arguments: args)),
          [tool],
        );
        expect(result.rawToolResults.single.result, contains('reference='));
        expect(result.rawToolResults.single.result, contains('TAIL-SECRET'));
        final reference = RegExp(
          r'reference=([a-f0-9]+)',
        ).firstMatch(result.rawToolResults.single.result)![1]!;
        final page = await results.reader('owner').invoke({
          'reference': reference,
          'offset': 60000,
          'limit': 100,
        });
        expect(page.text, contains('TAIL-SECRET'));
      }
    },
  );

  test(
    'task runner inherits package prompts/tools and preset narrows both',
    () async {
      final script = await plugin(scriptSource);
      final skill = PackagePlugin(AicovePackage.parse(skillFiles()));
      final capabilities = await resolveTaskPluginCapabilities(
        [script, skill],
        {'pkg:demo', 'pkg:sample-skill'},
      );
      for (final allowed in [
        null,
        <String>{'pkg:sample-skill'},
        <String>{},
      ]) {
        final runner = TaskAgentRunner(
          loadSettings: () async => mapUiModelsToAppSettings({}),
          requestConfig: ({required settings, required modelRef}) async =>
              const BackgroundAgentRequestConfig(
                modelFullId: 'openai:test',
                providerApiBase: 'https://invalid.test',
                providerApiKey: 'test',
                customConfig: {},
                modelTemperature: 0,
                modelTopP: null,
                modelContextMessageLimit: null,
              ),
          executor:
              ({
                required config,
                required tools,
                required sessionId,
                required cancellation,
              }) async {
                final text = jsonEncode(config.messages);
                expect(text.contains('script-prompt'), allowed == null);
                expect(
                  tools.any((t) => t.name == 'pkg_4_demo_answer'),
                  allowed == null,
                );
                expect(
                  tools.any((t) => t.name == 'read_skill_sample-skill'),
                  allowed == null || allowed.contains('pkg:sample-skill'),
                );
                return const ApiCallResult(
                  replyText: 'done',
                  rawReplyText: 'done',
                  processedText: 'done',
                  pluginEvents: [],
                  toolResults: [],
                );
              },
        );
        await runner.run(
          taskId: 'owner',
          runId: 'run',
          transcript: 'task',
          capabilities: capabilities,
          preset: TaskAgentPreset(allowedPluginIds: allowed),
          cancellation: KernelCancellation(),
        );
      }
    },
  );

  AssistantPackageTools installer({Set<String>? grants}) =>
      AssistantPackageTools(
        store: () async => workspaces,
        packages: () => notifier,
        workspaceIds: () async => grants ?? {workspace},
      );

  Future<void> writeSource() async {
    for (final e in skillFiles().entries) {
      final file = File(
        '${workspaces.directoryOf(workspace).path}/extension/${e.key}',
      );
      await file.parent.create(recursive: true);
      await file.writeAsBytes(e.value);
    }
  }

  test('default install policy needs no approval channel', () async {
    await writeSource();
    final tool = groupTool(installer());
    final result = await execute(
      _Client(
        ToolCall(
          id: 'default-install',
          name: tool.name,
          arguments: {'workspaceId': workspace, 'path': 'extension'},
        ),
      ),
      [tool],
    );
    expect(result.rawToolResults.single.isError, false);
    expect(notifier.state.single.id, 'sample-skill');
  });

  test('manual install policy requires real per-call human consent', () async {
    await writeSource();
    final group = installer(), tool = groupTool(installer());
    expect(group.riskOf(tool.name, {}), AssistantRisk.major);
    expect(tool.requiresHumanApproval, false);
    final args = {'workspaceId': workspace, 'path': 'extension'};
    // Direct invocation cannot fake authorization; an automatic approval cannot either.
    expect((await tool.invoke(args)).isError, true);
    final denied = _Human(false);
    expect(
      (await execute(
        _Client(ToolCall(id: 'c', name: tool.name, arguments: args)),
        [tool],
        approvals: denied,
      )).rawToolResults.single.isError,
      true,
    );
    final automatic = _Human(true, human: false);
    expect(
      (await execute(
        _Client(ToolCall(id: 'c', name: tool.name, arguments: args)),
        [tool],
        approvals: automatic,
      )).rawToolResults.single.isError,
      true,
    );
    expect(await packages.list(), isEmpty);
    final human = _Human(true);
    final accepted = await execute(
      _Client(ToolCall(id: 'c', name: tool.name, arguments: args)),
      [tool],
      approvals: human,
    );
    expect(human.calls, 1);
    expect(accepted.rawToolResults.single.isError, false);
    expect(notifier.state.single.id, 'sample-skill');
  });

  test(
    'install rejects unauthorized sources, traversal and symlinks, accepts zip; nested scripts use the same human approval gate',
    () async {
      await writeSource();
      final zipFile = File(
        '${workspaces.directoryOf(workspace).path}/skill.zip',
      );
      await zipFile.writeAsBytes(zip(skillFiles()));
      for (final args in [
        {'workspaceId': 'missing', 'path': 'extension'},
        {'workspaceId': workspace, 'path': '../extension'},
        {'workspaceId': workspace, 'path': '/tmp/extension'},
      ]) {
        final tool = groupTool(installer());
        final result = await execute(
          _Client(ToolCall(id: 'c', name: tool.name, arguments: args)),
          [tool],
          approvals: _Human(true),
        );
        expect(result.rawToolResults.single.isError, true);
      }
      Link(
        '${workspaces.directoryOf(workspace).path}/linked',
      ).createSync('${workspaces.directoryOf(workspace).path}/extension');
      final tool = groupTool(installer());
      final linked = await execute(
        _Client(
          ToolCall(
            id: 'c',
            name: tool.name,
            arguments: {'workspaceId': workspace, 'path': 'linked'},
          ),
        ),
        [tool],
        approvals: _Human(true),
      );
      expect(linked.rawToolResults.single.isError, true);
      final script = await plugin(
        '''aicove.registerTool({name:'install',description:'install',inputSchema:{type:'object'},
      handler:async()=>await tools.aicove_package_install({workspaceId:${jsonEncode(workspace)},path:'extension'})});''',
      );
      final scriptTool = script.getTools().single, human = _Human(true);
      final blocked = await execute(
        _Client(ToolCall(id: 'c', name: scriptTool.name, arguments: {})),
        [scriptTool, tool],
        approvals: human,
      );
      expect(blocked.rawToolResults.single.isError, false);
      expect(human.calls, 1);
      expect((await packages.list()).single.id, 'sample-skill');
      final accepted = await execute(
        _Client(
          ToolCall(
            id: 'c',
            name: tool.name,
            arguments: {'workspaceId': workspace, 'path': 'skill.zip'},
          ),
        ),
        [tool],
        approvals: _Human(true),
      );
      expect(accepted.rawToolResults.single.isError, false);
      expect(notifier.state.single.id, 'sample-skill');
    },
  );

  test(
    'direct non-JS skill invocation still needs a tool policy scope',
    () async {
      final output = await WorkspaceShell(
        store: workspaces,
        workspace: workspace,
        runId: 'shell',
      ).run('echo must-not-run');
      expect(output.isError, true);
      expect(output.text, contains('authorization'));
    },
  );
}

AITool groupTool(AssistantPackageTools group) => group.tools().single;

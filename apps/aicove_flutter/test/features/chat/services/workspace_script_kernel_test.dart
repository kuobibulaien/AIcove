import 'dart:convert';
import 'dart:io';
import 'package:aicove_agent_kernel/aicove_agent_kernel.dart';
import 'package:aicove_flutter/src/core/api/agent_api.dart';
import 'package:aicove_flutter/src/core/api/providers/provider_adapter.dart'
    hide ApiCallResult;
import 'package:aicove_flutter/src/core/app_logger.dart';
import 'package:aicove_flutter/src/features/agent_context/data/silly_tavern_preset_store.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/agent_runtime_contracts.dart';
import 'package:aicove_flutter/src/features/agent_plugins/file_change_journal.dart';
import 'package:aicove_flutter/src/features/agent_plugins/tool_policy.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_plugin.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_review.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_toolset.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_write_tools.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_api_runner.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/workspace/application/workspace_toolset.dart';
import 'package:aicove_flutter/src/features/workspace/data/workspace_store.dart';
import 'package:flutter_test/flutter_test.dart';

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

class _Roles implements AssistantRoleStore {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unused role store');
}

class _Presets implements SillyTavernPresetStore {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unused preset store');
}

class _Journal implements FileChangeJournal {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unused journal');
}

class _Approval implements ApprovalPort {
  final calls = <String>[];
  bool allowed = true;
  final deniedTools = <String>{};
  @override
  Future<bool> request(ApprovalRequest r) async {
    calls.add(r.toolName);
    return allowed && !deniedTools.contains(r.toolName);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late WorkspaceStore store;
  late String workspace;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('script_kernel_');
    store = await WorkspaceStore.open(root);
    workspace = (await store.create(name: '笔记')).id;
  });
  tearDown(() async {
    await store.close();
    await root.delete(recursive: true);
  });
  AITool runTool() => WorkspaceToolset(
    store: store,
    workspaceIds: {workspace},
    runId: 'script',
    enableScripts: true,
  ).tools().firstWhere((t) => t.name == 'codemode');
  final actualRisk = AssistantRequestScope.riskOf(
    AssistantToolset(
      roles: () async => [],
      presets: () async => [],
      previewContext: (_) async => throw StateError('Unused'),
      readDoc: (_) async => null,
    ),
    AssistantWriteTools(
      roles: _Roles(),
      presets: _Presets(),
      journal: _Journal(),
    ),
  );
  Future<ApiCallResult> execute(
    _Client client,
    List<AITool> tools,
    AgentToolPolicy policy,
  ) => KernelApiRunner.withAgentClientFactory(agentClientFactory: (_) => client)
      .executeApiCall(
        config: ApiConfig(
          settings:
              mapUiModelsToAppSettings({
                'model_configs': {
                  'openai:test': {
                    'chat_capabilities': ['tools'],
                  },
                },
              }).copyWith(
                callFlowSettings: const CallFlowSettings(toolTimeoutSeconds: 1),
              ),
          modelFullId: 'openai:test',
          providerApiBase: 'https://invalid.test',
          providerApiKey: 'test',
          customConfig: const {},
          messages: const [
            {'role': 'user', 'content': 'run'},
          ],
          toolPolicy: policy,
        ),
        sessionId: 'script',
        userText: 'run',
        responseProcessors: const [],
        availableTools: tools,
      );

  test(
    'default assistant script policy runs directly and retains manual approval copy',
    () {
      expect(actualRisk('codemode', {}), AssistantRisk.review);
      final gate = AssistantToolGate(actualRisk);
      expect(
        gate
            .check(
              const KernelToolCall(id: 'r', name: 'codemode'),
              ToolEffect.external,
            )
            .decision,
        GateDecision.allow,
      );
      final prompt = ApprovalPrompt.workspaceScript('笔记');
      expect(prompt.title, '运行脚本');
      expect(prompt.detail, '在空间「笔记」里运行脚本，可能访问网络；空间内的改动可以撤销');
      expect(runTool().effect, ToolEffect.external);
    },
  );
  test('rejected script does not execute even a byte write', () async {
    final approval = _Approval()..allowed = false;
    final client = _Client(
      ToolCall(
        id: 'r',
        name: 'codemode',
        arguments: {
          'code': "await ws.writeBytes('denied',new Uint8Array([1]));",
        },
      ),
    );
    final result = await execute(
      client,
      [runTool()],
      AgentToolPolicy(
        authorization: AgentToolAuthorization.manual,
        customGate: AssistantToolGate(actualRisk, alwaysAsk: () => true),
        approvals: approval,
      ),
    );
    expect(approval.calls, ['codemode']);
    expect(result.rawToolResults.single.isError, isTrue);
    expect(await store.stat(workspace, 'denied'), isNull);
  });
  test(
    'approved script still requires child approval and respects rejection',
    () async {
      var writes = 0;
      final dangerous = AITool(
        name: 'dangerous',
        description: 'dangerous',
        parameters: const {},
        effect: ToolEffect.write,
        handler: (_) async {
          writes++;
          return 'done';
        },
      );
      final approval = _Approval()..deniedTools.add('dangerous');
      final policy = AgentToolPolicy(
        authorization: AgentToolAuthorization.manual,
        approvals: approval,
        customGate: AssistantToolGate(
          (name, args) => name == 'codemode'
              ? actualRisk(name, args)
              : AssistantRisk.review,
          alwaysAsk: () => true,
        ),
      );
      final script = _Client(
        ToolCall(
          id: 'r',
          name: 'codemode',
          arguments: {'code': 'await tools.dangerous();'},
        ),
      );
      final out = await execute(script, [runTool(), dangerous], policy);
      expect(writes, 0);
      expect(approval.calls, ['codemode', 'dangerous']);
      expect(out.rawToolResults.single.isError, isTrue);
      expect(out.rawToolResults.single.result, contains('dangerous'));
      approval.deniedTools.clear();
      final direct = _Client(
        const ToolCall(id: 'd', name: 'dangerous', arguments: {}),
      );
      await execute(direct, [dangerous], policy);
      expect(writes, 1);
      expect(approval.calls, ['codemode', 'dangerous', 'dangerous']);
    },
  );
  test(
    'nested calls retain scope, cancellation and redaction before JS sees results',
    () async {
      final secret = AITool(
        name: 'private',
        description: 'private',
        parameters: const {},
        effect: ToolEffect.readPrivate,
        handler: (_) async {
          expect(ToolCallScope.current?.outcome, GateOutcome.allowed);
          expect(ToolCallContext.current?.toolCallId, 'r/1');
          expect(ToolCallContext.current?.isCancelled?.call(), isFalse);
          return 'secret';
        },
      );
      final redactor = SecretRedactor()..register('secret');
      final client = _Client(
        ToolCall(
          id: 'r',
          name: 'codemode',
          arguments: {'code': 'text(await tools.private());'},
        ),
      );
      final out = await execute(
        client,
        [runTool(), secret],
        AgentToolPolicy(
          authorization: AgentToolAuthorization.allowAll,
          redactor: redactor,
        ),
      );
      expect(out.rawToolResults.single.result, contains(SecretRedactor.mask));
      expect(
        (out.rawToolResults.single.structured as Map)['codemodeCalls'],
        isNotEmpty,
      );
      expect(jsonEncode(client.sent), isNot(contains('secret')));
    },
  );
  test(
    'codemode self-managed deadline is not truncated by global one-second timeout',
    () async {
      final client = _Client(
        ToolCall(
          id: 'r',
          name: 'codemode',
          arguments: {
            'code':
                '// @options: {"timeout_ms":2000}\n'
                'const end=Date.now()+1100; while(Date.now()<end){} text("done");',
          },
        ),
      );
      final out = await execute(
        client,
        [runTool()],
        const AgentToolPolicy(authorization: AgentToolAuthorization.allowAll),
      );
      expect(out.rawToolResults.single.isError, isFalse);
      expect(out.rawToolResults.single.result, contains('Script completed'));
      expect(out.rawToolResults.single.result, contains('done'));
    },
  );
  test(
    'nested I/O remains owned by the script deadline rather than a detached global timeout',
    () async {
      final slow = AITool(
        name: 'slow',
        description: 'slow',
        parameters: const {},
        effect: ToolEffect.readDiagnostic,
        handler: (_) async {
          await Future<void>.delayed(const Duration(milliseconds: 1100));
          return 'settled';
        },
      );
      final client = _Client(
        ToolCall(
          id: 'r',
          name: 'codemode',
          arguments: {
            'code':
                '// @options: {"timeout_ms":2000}\ntext(await tools.slow());',
          },
        ),
      );
      final out = await execute(
        client,
        [runTool(), slow],
        const AgentToolPolicy(authorization: AgentToolAuthorization.allowAll),
      );
      expect(out.rawToolResults.single.isError, isFalse);
      expect(out.rawToolResults.single.result, contains('Script completed'));
      expect(out.rawToolResults.single.result, contains('settled'));
    },
  );
  AITool shellTool() => WorkspaceToolset(
    store: store,
    workspaceIds: {workspace},
    runId: 'shell',
    enableShell: true,
  ).tools().firstWhere((t) => t.name == 'bash');

  test(
    'default assistant policy executes shell without an approval channel',
    () async {
      final client = _Client(
        ToolCall(
          id: 'default',
          name: 'bash',
          arguments: {'command': 'printf ok > default_shell'},
        ),
      );
      final result = await execute(
        client,
        [shellTool()],
        AgentToolPolicy(
          authorization: AgentToolAuthorization.allowAll,
          customGate: AssistantToolGate(actualRisk),
        ),
      );
      expect(result.rawToolResults.single.isError, isFalse);
      expect(
        await File(
          '${store.directoryOf(workspace).path}/default_shell',
        ).readAsString(),
        'ok',
      );
    },
  );

  test(
    'manual shell policy asks for every command and skips the reviewer',
    () async {
      expect(actualRisk('bash', {}), AssistantRisk.major);
      var asked = 0, reviewed = 0;
      final port = AssistantApprovalPort(
        alwaysAsk: () => true,
        riskOf: (_, __) => AssistantRisk.review, // Deliberately wrong default.
        describe: (_, a) =>
            ApprovalPrompt.workspaceShell('笔记', a['command'] as String),
        toolDescription: (_) => 'shell',
        userMessages: const ['run'],
        review:
            ({
              required userMessages,
              required toolName,
              required toolDescription,
              required arguments,
            }) async {
              reviewed++;
              return const ReviewResult(ReviewVerdict.allow, 'allow');
            },
        askUser: (prompt, withdrawn) async {
          asked++;
          expect(prompt.title, '运行命令');
          return true;
        },
      );
      for (var i = 0; i < 2; i++) {
        final client = _Client(
          ToolCall(
            id: 'same',
            name: 'bash',
            arguments: {'command': 'printf ok > approved$i'},
          ),
        );
        await execute(
          client,
          [shellTool()],
          AgentToolPolicy(
            authorization: AgentToolAuthorization.manual,
            customGate: AssistantToolGate(actualRisk, alwaysAsk: () => true),
            approvals: port,
          ),
        );
        expect(
          await File(
            '${store.directoryOf(workspace).path}/approved$i',
          ).readAsString(),
          'ok',
        );
      }
      expect(asked, 2);
      expect(reviewed, 0);
    },
  );

  test(
    'shell rejected by human never launches, even when reviewer would allow',
    () async {
      var reviewed = 0;
      final port = AssistantApprovalPort(
        alwaysAsk: () => true,
        riskOf: (_, __) => AssistantRisk.review,
        describe: (_, a) =>
            ApprovalPrompt.workspaceShell('笔记', a['command'] as String),
        toolDescription: (_) => 'shell',
        userMessages: const [],
        review:
            ({
              required userMessages,
              required toolName,
              required toolDescription,
              required arguments,
            }) async {
              reviewed++;
              return const ReviewResult(ReviewVerdict.allow, 'allow');
            },
        askUser: (_, __) async => false,
      );
      final client = _Client(
        ToolCall(
          id: 'no',
          name: 'bash',
          arguments: {'command': 'touch denied'},
        ),
      );
      await execute(
        client,
        [shellTool()],
        AgentToolPolicy(
          authorization: AgentToolAuthorization.manual,
          customGate: AssistantToolGate(actualRisk, alwaysAsk: () => true),
          approvals: port,
        ),
      );
      expect(reviewed, 0);
      expect(
        await File('${store.directoryOf(workspace).path}/denied').exists(),
        isFalse,
      );
      expect(await store.index.fetch('SELECT * FROM shell_intents'), isEmpty);
    },
  );

  test('allow-all policy never consults the approval port for shell', () async {
    final automatic = _Approval();
    final client = _Client(
      ToolCall(
        id: 'auto',
        name: 'bash',
        arguments: {'command': 'touch automatic'},
      ),
    );
    await execute(
      client,
      [shellTool()],
      AgentToolPolicy(
        authorization: AgentToolAuthorization.allowAll,
        approvals: automatic,
      ),
    );
    expect(automatic.calls, isEmpty);
    expect(
      await File('${store.directoryOf(workspace).path}/automatic').exists(),
      isTrue,
    );
  });

  test('manual shell cannot use automatic approval as human consent', () async {
    final automatic = _Approval();
    final result = await execute(
      _Client(
        ToolCall(
          id: 'auto-manual',
          name: 'bash',
          arguments: {'command': 'touch automatic_manual'},
        ),
      ),
      [shellTool()],
      AgentToolPolicy(
        authorization: AgentToolAuthorization.manual,
        customGate: AssistantToolGate(actualRisk, alwaysAsk: () => true),
        approvals: automatic,
      ),
    );
    expect(automatic.calls, ['bash']);
    expect(result.rawToolResults.single.isError, isTrue);
    expect(await store.stat(workspace, 'automatic_manual'), isNull);
  });

  test(
    'default codemode calls bash through the same unrestricted gate',
    () async {
      final automatic = _Approval();
      final result = await execute(
        _Client(
          ToolCall(
            id: 'nested-shell',
            name: 'codemode',
            arguments: {
              'code':
                  'text(await tools.bash({command:"printf nested > nested_shell"}));',
            },
          ),
        ),
        [runTool(), shellTool()],
        AgentToolPolicy(
          authorization: AgentToolAuthorization.allowAll,
          customGate: AssistantToolGate(actualRisk),
          approvals: automatic,
        ),
      );
      expect(result.rawToolResults.single.isError, isFalse);
      expect(automatic.calls, isEmpty);
      expect(
        await File(
          '${store.directoryOf(workspace).path}/nested_shell',
        ).readAsString(),
        'nested',
      );
    },
  );

  test('allow-all shell needs no approval channel', () async {
    final client = _Client(
      ToolCall(
        id: 'none',
        name: 'bash',
        arguments: {'command': 'touch no_channel'},
      ),
    );
    await execute(
      client,
      [shellTool()],
      const AgentToolPolicy(authorization: AgentToolAuthorization.allowAll),
    );
    expect(
      await File('${store.directoryOf(workspace).path}/no_channel').exists(),
      isTrue,
    );
  });
  test('manual mode without an approval channel cannot launch shell', () async {
    final result = await execute(
      _Client(
        ToolCall(
          id: 'manual',
          name: 'bash',
          arguments: {'command': 'touch manual_denied'},
        ),
      ),
      [shellTool()],
      AgentToolPolicy(
        authorization: AgentToolAuthorization.manual,
        customGate: AssistantToolGate(actualRisk, alwaysAsk: () => true),
      ),
    );
    expect(result.rawToolResults.single.isError, isTrue);
    expect(await store.stat(workspace, 'manual_denied'), isNull);
  });
  test(
    'manual mode asks separately for each shell in a provider batch',
    () async {
      var asked = 0;
      final port = AssistantApprovalPort(
        alwaysAsk: () => true,
        riskOf: (_, __) => AssistantRisk.review,
        describe: (_, a) =>
            ApprovalPrompt.workspaceShell('笔记', a['command'] as String),
        toolDescription: (_) => 'shell',
        userMessages: const [],
        review:
            ({
              required userMessages,
              required toolName,
              required toolDescription,
              required arguments,
            }) async => const ReviewResult(ReviewVerdict.allow, 'automatic'),
        askUser: (_, __) async => ++asked == 1,
      );
      final client = _Client(
        ToolCall(
          id: 'one',
          name: 'bash',
          arguments: {'command': 'touch batch_one'},
        ),
        extra: [
          ToolCall(
            id: 'two',
            name: 'bash',
            arguments: {'command': 'touch batch_two'},
          ),
        ],
      );
      await execute(
        client,
        [shellTool()],
        AgentToolPolicy(
          authorization: AgentToolAuthorization.manual,
          customGate: AssistantToolGate(actualRisk, alwaysAsk: () => true),
          approvals: port,
        ),
      );
      expect(asked, 2);
      expect(
        await File('${store.directoryOf(workspace).path}/batch_one').exists(),
        isTrue,
      );
      expect(
        await File('${store.directoryOf(workspace).path}/batch_two').exists(),
        isFalse,
      );
    },
  );
}

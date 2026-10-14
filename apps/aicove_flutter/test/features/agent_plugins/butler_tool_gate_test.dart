// Batch 2d, group D: tool authorization and undo through the kernel runner
// with a fake "butler" plugin whose tools are visible to one agent only.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart';
import 'package:aicove_flutter/src/core/api/agent_api.dart';
import 'package:aicove_flutter/src/core/api/providers/provider_adapter.dart'
    show ProviderChatRequestOptions, ToolCall;
import 'package:aicove_flutter/src/core/app_logger.dart' show TraceLogger;
import 'package:aicove_flutter/src/features/agent_context/domain/agent_runtime_contracts.dart';
import 'package:aicove_flutter/src/features/agent_plugins/aicove_plugin.dart';
import 'package:aicove_flutter/src/features/agent_plugins/file_change_journal.dart';
import 'package:aicove_flutter/src/features/agent_plugins/plugin_runtime.dart';
import 'package:aicove_flutter/src/features/agent_plugins/preference_change_applier.dart';
import 'package:aicove_flutter/src/features/agent_plugins/tool_policy.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_api_runner.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _agent = 'butler';
const _flagKey = 'aicove.test.flag';
const _secret = 'sk-live-butler-123';

class _ScriptedClient extends AgentApiClient {
  _ScriptedClient(this.steps) : super();

  final List<SendMessageRichResult> steps;
  final List<List<Map<String, dynamic>>> requests = [];

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
    requests.add([
      for (final m in messages)
        Map<String, dynamic>.from(jsonDecode(jsonEncode(m)) as Map),
    ]);
    if (steps.isEmpty) throw StateError('no scripted step');
    return steps.removeAt(0);
  }
}

SendMessageRichResult _calls(List<ToolCall> calls) => SendMessageRichResult(
      text: '',
      toolResults: const [],
      toolCalls: calls,
    );

SendMessageRichResult _text(String text) =>
    SendMessageRichResult(text: text, toolResults: const []);

class _Approvals implements ApprovalPort {
  _Approvals(this.answer);

  /// null never answers.
  final bool? answer;
  final List<String> asked = [];
  final List<ApprovalRequest> requests = [];

  @override
  Future<bool> request(ApprovalRequest request) {
    asked.add(request.toolName);
    requests.add(request);
    final answer = this.answer;
    return answer == null ? Completer<bool>().future : Future.value(answer);
  }
}

/// The fake butler: one tool per effect, visible to [_agent] only.
class _Butler {
  _Butler(this.journal, this.prefs);

  final FileChangeJournal journal;
  final SharedPreferences prefs;
  final List<String> ran = [];

  PreferenceChangeApplier get _applier => PreferenceChangeApplier(prefs);

  KernelTool _tool(
    String name,
    ToolEffect effect,
    Future<String> Function(Map<String, dynamic> args) run,
  ) =>
      KernelTool(
        name: name,
        effect: effect,
        agentIds: const {_agent},
        schema: {
          'name': name,
          'description': name,
          'parameters': {'type': 'object', 'properties': <String, dynamic>{}},
        },
        handler: (args) {
          ran.add(name);
          return run(args);
        },
      );

  AicovePlugin get plugin => AicovePlugin(
        id: 'butler',
        name: '管家',
        exposure: const AgentOnlyExposure({_agent}),
        capabilities: const {KernelCapability.tools},
        setup: (r) {
          r.tool(_tool('diag_status', ToolEffect.readDiagnostic,
              (_) async => 'rounds=3'));
          r.tool(_tool('read_chat', ToolEffect.readPrivate,
              (_) async => '最近一条：你好'));
          r.tool(_tool('set_flag', ToolEffect.write, (args) async {
            final entry = await journal.commit(
              'set_flag',
              _applier.changeOf(_flagKey, args['value'],
                  description: '把测试开关改为 ${args['value']}'),
            );
            return '已修改，记录 ${entry.id}';
          }));
          r.tool(_tool('delete_flag', ToolEffect.destructive, (_) async {
            final entry = await journal.commit(
              'delete_flag',
              _applier.changeOf(_flagKey, null, description: '删除测试开关'),
            );
            return '已删除，记录 ${entry.id}';
          }));
          r.tool(_tool('leak_key', ToolEffect.readDiagnostic,
              (_) async => '渠道密钥是 $_secret'));
        },
      );
}

void main() {
  late Directory dir;
  late SharedPreferences prefs;
  late FileChangeJournal journal;
  late _Butler butler;
  late PluginRuntime runtime;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('butler_gate_');
    SharedPreferences.setMockInitialValues({_flagKey: 'off'});
    prefs = await SharedPreferences.getInstance();
    journal = FileChangeJournal(
      file: () async => File('${dir.path}/journal.json'),
      appliers: {PreferenceChangeApplier.kind: PreferenceChangeApplier(prefs)},
    );
    butler = _Butler(journal, prefs);
    runtime = PluginRuntime()..install(butler.plugin);
  });
  tearDown(() => dir.delete(recursive: true));

  Future<(ApiCallResult, _ScriptedClient)> run(
    List<ToolCall> calls, {
    required AgentToolPolicy? policy,
  }) async {
    final client = _ScriptedClient([_calls(calls), _text('好了')]);
    final runner = KernelApiRunner.withAgentClientFactory(
      agentClientFactory: (_) => client,
    );
    final result = await runner.executeApiCall(
      config: ApiConfig(
        settings: mapUiModelsToAppSettings({}),
        modelFullId: 'openai:gpt-test',
        providerApiBase: 'https://invalid.test',
        customConfig: const {},
        messages: const [
          {'role': 'user', 'content': '帮我看看'},
        ],
        toolPolicy: policy,
      ),
      sessionId: 'butler_session',
      userText: '帮我看看',
      responseProcessors: const [],
      availableTools: runtime.agentTools(runtime.snapshot(agentId: _agent)),
    );
    return (result, client);
  }

  /// Tool result texts the model receives in the second request.
  List<String> toolResultsSent(_ScriptedClient client) => [
        for (final message in client.requests[1])
          if (message['role'] == 'tool') message['content'].toString(),
      ];

  ToolCall call(String name, [Map<String, dynamic> args = const {}]) =>
      ToolCall(id: 'c_$name', name: name, arguments: args);

  test('agent-only tools are invisible to other agents and to role runs', () {
    expect(runtime.agentTools(runtime.snapshot(agentId: 'other')), isEmpty);
    expect(runtime.agentTools(runtime.snapshot()), isEmpty);
    expect(runtime.selectForRole(null), isEmpty);
    expect(
      runtime.agentTools(runtime.snapshot(agentId: _agent)).map((t) => t.effect),
      [
        ToolEffect.readDiagnostic,
        ToolEffect.readPrivate,
        ToolEffect.write,
        ToolEffect.destructive,
        ToolEffect.readDiagnostic,
      ],
    );
  });

  group('manual mode (D1)', () {
    test('diagnostics run without asking; private reads and writes ask, and '
        'run once approved', () async {
      final approvals = _Approvals(true);
      final (_, client) = await run(
        [call('diag_status'), call('read_chat'), call('set_flag', {'value': 'on'})],
        policy: AgentToolPolicy(
          authorization: AgentToolAuthorization.manual,
          approvals: approvals,
        ),
      );
      expect(approvals.asked, ['read_chat', 'set_flag']);
      expect(butler.ran, ['diag_status', 'read_chat', 'set_flag']);
      expect(prefs.getString(_flagKey), 'on');
      expect(toolResultsSent(client)[0], 'rounds=3');
    });

    test('a rejected call does not run; the model gets a structured refusal '
        'and the loop goes on', () async {
      final (result, client) = await run(
        [call('set_flag', {'value': 'on'})],
        policy: AgentToolPolicy(
          authorization: AgentToolAuthorization.manual,
          approvals: _Approvals(false),
        ),
      );
      expect(butler.ran, isEmpty);
      expect(prefs.getString(_flagKey), 'off');
      expect(await journal.recent(), isEmpty);
      expect(toolResultsSent(client), ['用户未允许：set_flag']);
      expect(result.processedText, '好了');
    });

    test('an unanswered request times out as a refusal and is withdrawn',
        () async {
      final approvals = _Approvals(null);
      final (_, client) = await run(
        [call('delete_flag')],
        policy: AgentToolPolicy(
          authorization: AgentToolAuthorization.manual,
          approvals: approvals,
          approvalTimeout: const Duration(milliseconds: 20),
        ),
      );
      expect(butler.ran, isEmpty);
      expect(prefs.getString(_flagKey), 'off');
      expect(toolResultsSent(client), ['用户未允许：等待确认超时']);
      await approvals.requests.single.withdrawn
          .timeout(const Duration(seconds: 1));
    });

    test('without an approval channel every ask is a refusal', () async {
      final (_, client) = await run(
        [call('read_chat')],
        policy: const AgentToolPolicy(
          authorization: AgentToolAuthorization.manual,
        ),
      );
      expect(butler.ran, isEmpty);
      expect(toolResultsSent(client), ['用户未允许：read_chat']);
    });
  });

  test('unrestricted mode asks nothing but journals writes and backs up '
      'deletions (D2)', () async {
    final approvals = _Approvals(false);
    await run(
      [call('set_flag', {'value': 'on'}), call('delete_flag')],
      policy: AgentToolPolicy(
        authorization: AgentToolAuthorization.unrestricted,
        approvals: approvals,
      ),
    );
    expect(approvals.asked, isEmpty);
    expect(butler.ran, ['set_flag', 'delete_flag']);
    expect(prefs.containsKey(_flagKey), isFalse);
    final entries = await journal.recent();
    expect([for (final e in entries) e.toolName], ['delete_flag', 'set_flag']);
    // The deletion's backup is the value it removed.
    expect(entries.first.change.before, {'key': _flagKey, 'value': 'on'});
  });

  test('undo restores in reverse order and logs the reverse changes (D3)',
      () async {
    await run(
      [call('set_flag', {'value': 'on'}), call('set_flag', {'value': 'max'})],
      policy: const AgentToolPolicy(
        authorization: AgentToolAuthorization.unrestricted,
      ),
    );
    expect(prefs.getString(_flagKey), 'max');
    final [second, first] = await journal.recent();

    await journal.undo(second.id);
    expect(prefs.getString(_flagKey), 'on');
    await journal.undo(first.id);
    expect(prefs.getString(_flagKey), 'off');

    final entries = await journal.recent();
    expect([for (final e in entries.take(2)) e.toolName], ['undo', 'undo']);
    expect(entries.first.change.after, {'key': _flagKey, 'value': 'off'});
    expect(() => journal.undo(first.id), throwsStateError);
  });

  test('a registered secret never reaches the model (D5)', () async {
    final redactor = SecretRedactor()..register(_secret);
    final (result, client) = await run(
      [call('leak_key')],
      policy: AgentToolPolicy(
        authorization: AgentToolAuthorization.manual,
        redactor: redactor,
      ),
    );
    expect(butler.ran, ['leak_key']);
    expect(toolResultsSent(client), ['渠道密钥是 ${SecretRedactor.mask}']);
    expect(jsonEncode(client.requests), isNot(contains(_secret)));
    expect(jsonEncode(result.toolResults), isNot(contains(_secret)));
  });

  test('credentials the app holds are registered for redaction', () {
    final settings = mapUiModelsToAppSettings({
      'providers': [
        {
          'id': 'p',
          'apiBaseUrl': 'https://x.test',
          'apiKeys': ['sk-channel'],
        },
      ],
    });
    final redactor = redactorForCredentials(settings: settings);
    expect(redactor.redact('key sk-channel'), 'key ${SecretRedactor.mask}');
  });

  test('without a policy tools run exactly as before (D6)', () async {
    final (_, client) = await run(
      [call('read_chat'), call('leak_key')],
      policy: null,
    );
    expect(butler.ran, ['read_chat', 'leak_key']);
    expect(toolResultsSent(client), ['最近一条：你好', '渠道密钥是 $_secret']);
  });
}

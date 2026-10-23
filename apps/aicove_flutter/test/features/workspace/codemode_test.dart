import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:aicove_agent_kernel/aicove_agent_kernel.dart';
import 'package:aicove_flutter/src/core/api/agent_api.dart';
import 'package:aicove_flutter/src/core/api/providers/provider_adapter.dart'
    show ToolCall;
import 'package:aicove_flutter/src/features/chat/services/chat_send_api_runner.dart';
import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:aicove_flutter/src/features/agent_plugins/tool_policy.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/agent_runtime_contracts.dart';
import 'package:aicove_flutter/src/features/workspace/application/codemode_script.dart';
import 'package:aicove_flutter/src/features/workspace/application/codemode_source.dart';
import 'package:aicove_flutter/src/features/workspace/application/workspace_toolset.dart';
import 'package:aicove_flutter/src/features/workspace/data/workspace_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import '../task_agent/agent_execution_reliability_test.dart' as app;
import '../task_agent/agent_reliability_regression_test.dart' as base;

void main() {
  late Directory root;
  late WorkspaceStore store;
  late String ws;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('codemode-test-');
    store = await WorkspaceStore.open(root);
    ws = (await store.create(name: 'code')).id;
  });
  tearDown(() async {
    await store.close();
    await root.delete(recursive: true);
  });
  CodemodeScript script({ScriptToolAccess? tools}) => CodemodeScript(
    store: store,
    workspace: () => ws,
    runId: 'r',
    owner: 'conversation',
    tools: tools,
  );
  test('source options are first-line only, strict and keep line numbers', () {
    final parsed = parseCodemodeSource(
      '// @options: {"max_output_tokens":2,"timeout_ms":1000}\ntext(1)',
    );
    expect(parsed.code, '\ntext(1)');
    expect(parsed.timeout, const Duration(seconds: 1));
    expect(parsed.maxOutputTokens, 2);
    expect(parseCodemodeSource('text(1)').timeout, isNull);
    for (final source in [
      '',
      '// @options: {}',
      '\n// @options: {}\ntext(1)',
      '// @options: {"other":1}\ntext(1)',
      '// @options: {"timeout_ms":0}\ntext(1)',
    ]) {
      expect(() => parseCodemodeSource(source), throwsFormatException);
    }
  });
  test(
    'text, return, console, exit and failed partial output match Pi format',
    () async {
      final result = await script().run(
        'text("one"); console.log("log", 2); text("two"); return "three";',
      );
      expect(result.text, startsWith('Script completed'));
      expect(result.text, contains('==> text 1/3 <=='));
      expect(
        result.text,
        contains('<console_output>\nlog 2\n</console_output>'),
      );
      final failed = await script().run(
        'text("kept"); throw new Error("oops")',
      );
      expect(failed.text, startsWith('Script failed'));
      expect(failed.text, contains('kept'));
      expect(failed.text, contains('Script error:'));
      expect(
        (await script().run('text("before"); exit(); text("after");')).text,
        isNot(contains('after')),
      );
    },
  );
  test(
    'successful store persists across calls; failed stores are discarded',
    () async {
      await script().run('store("key",{n:42});');
      expect(
        (await script().run('text(load("key"));')).text,
        contains('"n":42'),
      );
      await script().run('store("key",{n:99}); throw Error("fail");');
      expect(
        (await script().run('text(load("key"));')).text,
        contains('"n":42'),
      );
      expect(
        (await script().run('store("large", "x".repeat(262145));')).isError,
        true,
      );
    },
  );
  test(
    'default waits for a five-second nested call; explicit timeout preserves output',
    () async {
      final access = ScriptToolAccess(
        [
          AITool(
            name: 'slow',
            description: 'slow',
            parameters: const {},
            handler: (_) async => 'ok',
          ),
        ],
        (_, _, active) async {
          for (var i = 0; i < 100; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
            if (!active())
              return const ToolOutput(text: 'cancelled', isError: true);
          }
          return const ToolOutput(text: 'five-second-result');
        },
      );
      final result = await script(
        tools: access,
      ).run('text(await tools.slow({}));');
      expect(result.isError, false);
      expect(result.text, contains('five-second-result'));
      final timed = await script(tools: access).run(
        '// @options: {"timeout_ms":1000}\ntext("partial"); await tools.slow({});',
      );
      expect(timed.isError, true);
      expect(timed.text, contains('Script timed out'));
      expect(timed.text, contains('partial'));
      expect(
        (timed.structured as Map)['codemodeCalls'].single['status'],
        'cancelled',
      );
    },
  );
  test(
    'nested display metadata is bounded without truncating the model error',
    () async {
      final access = ScriptToolAccess(
        [
          AITool(
            name: 'fail',
            description: 'failure',
            parameters: const {},
            handler: (_) async => '',
          ),
        ],
        (_, _, _) async =>
            ToolOutput(text: 'failure:' + ('x' * 600), isError: true),
      );
      final out = await script(tools: access).run(
        'try { await tools.fail({value:"x".repeat(400)}); } catch(e) { text(e.message); }',
      );
      final call =
          ((out.structured as Map)['codemodeCalls'] as List).single as Map;
      expect((call['args'] as String).length, 200);
      expect((call['error'] as String).length, 300);
      expect(call['status'], 'error');
      expect(call['durationMs'], isA<int>());
      expect(out.text, contains('x' * 600));
    },
  );
  test('large output keeps head and tail and saves full output', () async {
    final out = await script().run(
      '// @options: {"max_output_tokens":20}\ntext("HEAD"+"x".repeat(500)+"TAIL");',
    );
    expect(out.text, contains('HEAD'));
    expect(out.text, contains('TAIL'));
    final path = (out.structured as Map)['fullOutputPath'] as String;
    expect(utf8.decode((await store.read(ws, path)).$1), contains('x' * 500));
  });
  test(
    'deferred tools are searchable, describable and callable; unawaited calls are cancelled',
    () async {
      final access = ScriptToolAccess(
        [
          AITool(
            name: 'mcp__s__special',
            description: 'unique catalog needle',
            parameters: const {},
            exposure: ToolExposure.deferred,
            handler: (_) async => 'found',
          ),
        ],
        (_, _, active) async {
          await Future<void>.delayed(const Duration(milliseconds: 40));
          return const ToolOutput(text: 'found');
        },
      );
      final found = await script(tools: access).run(
        'const t=await searchTools("needle"); text(t[0].name); text(await describeTool(t[0].name)); text(await tools.mcp__s__special({}));',
      );
      expect(found.isError, false);
      expect(found.text, contains('found'));
      expect(found.text, contains('codemode tool declaration'));
      final discarded = await script(tools: access).run(
        'for(let i=0;i<7;i++) tools.mcp__s__special({}); text("finished");',
      );
      final calls = (discarded.structured as Map)['codemodeCalls'] as List;
      expect(calls, hasLength(7));
      expect(calls.every((c) => c['status'] == 'cancelled'), true);
    },
  );
  test(
    'manual nested gate waits for rejection and rejects Error without executing side effect',
    () async {
      final approvals = _NestedRejectApproval();
      final set = WorkspaceToolset(
        store: store,
        workspaceIds: {ws},
        runId: 'r',
        enableScripts: true,
        enableShell: true,
      );
      final client = app.ScriptClient(
        (n, _) async => n == 1
            ? const SendMessageRichResult(
                text: '',
                toolResults: [],
                toolCalls: [
                  ToolCall(
                    id: 'gate-code',
                    name: 'codemode',
                    arguments: {
                      'code':
                          'try { await tools.bash({command:"touch denied"}); } catch(e) { text(e.message); }',
                    },
                  ),
                ],
              )
            : app.done,
      );
      final cfg = base.config().copyWith(
        toolPolicy: AgentToolPolicy(
          authorization: AgentToolAuthorization.manual,
          approvals: approvals,
        ),
      );
      final result =
          await KernelApiRunner.withAgentClientFactory(
            agentClientFactory: (_) => client,
          ).executeApiCall(
            config: cfg,
            sessionId: 'c',
            userText: null,
            responseProcessors: const [],
            availableTools: set.tools(),
          );
      expect(approvals.calls, 2);
      expect(result.rawToolResults.single.result, contains('用户未允许'));
      expect(await store.stat(ws, 'denied'), isNull);
    },
  );
  test(
    'fetch, byte helpers and saved images use the current workspace',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.headers.set('x-code-test', 'yes');
        request.response.write('local-network');
        await request.response.close();
      });
      final png = base64Encode(img.encodePng(img.Image(width: 2, height: 3)));
      final result = await script().run(
        'const r=await fetch("http://127.0.0.1:${server.port}/"); text(r.headers.get("x-code-test")); text(await r.text()); await ws.writeBytes("bytes.bin",new Uint8Array([1,2,3])); text(await ws.readBytes("bytes.bin")); await image("data:image/png;base64,$png");',
      );
      expect(result.isError, false, reason: result.text);
      expect(result.text, contains('local-network'));
      expect(result.text, contains('AQID'));
      expect(result.images, hasLength(1));
      expect(result.text, contains('Image saved: .aicove/outputs/'));
      expect(
        (await store.files(
          ws,
        )).any((f) => f.path.startsWith('.aicove/outputs/') && f.size > 0),
        true,
      );
    },
  );
  test(
    'manual gate covers built-in byte writes and denied codemode keeps contract B',
    () async {
      final approvals = _RejectApproval();
      final set = WorkspaceToolset(
        store: store,
        workspaceIds: {ws},
        runId: 'r',
        enableScripts: true,
      );
      final client = app.ScriptClient(
        (n, _) async => n == 1
            ? const SendMessageRichResult(
                text: '',
                toolResults: [],
                toolCalls: [
                  ToolCall(
                    id: 'blocked-code',
                    name: 'codemode',
                    arguments: {
                      'code':
                          'await ws.writeBytes("denied.bin",new Uint8Array([1]));',
                    },
                  ),
                ],
              )
            : app.done,
      );
      final cfg = base.config().copyWith(
        toolPolicy: AgentToolPolicy(
          authorization: AgentToolAuthorization.manual,
          approvals: approvals,
        ),
      );
      final result =
          await KernelApiRunner.withAgentClientFactory(
            agentClientFactory: (_) => client,
          ).executeApiCall(
            config: cfg,
            sessionId: 'c',
            userText: null,
            responseProcessors: const [],
            availableTools: set.tools(),
          );
      expect(approvals.calls, 1);
      expect(await store.stat(ws, 'denied.bin'), isNull);
      expect(result.rawToolResults.single.result, startsWith('Script failed'));
      expect(
        (result.rawToolResults.single.structured as Map)['codemodeCalls'],
        isEmpty,
      );
    },
  );
  test(
    'nested calls share schema validation and gate, allSettled and structured bash work',
    () async {
      final set = WorkspaceToolset(
        store: store,
        workspaceIds: {ws},
        runId: 'r',
        enableScripts: true,
        enableShell: true,
      );
      final tools = [
        ...set.tools(),
        AITool(
          name: 'typed',
          description: 'requires field',
          parameters: const {},
          inputSchema: const {
            'type': 'object',
            'properties': {
              'field': {'type': 'string'},
            },
            'required': ['field'],
          },
          handler: (_) async => 'valid',
        ),
      ];
      final client = app.ScriptClient(
        (n, _) async => n == 1
            ? const SendMessageRichResult(
                text: '',
                toolResults: [],
                toolCalls: [
                  ToolCall(
                    id: 'code-id',
                    name: 'codemode',
                    arguments: {
                      'code':
                          'const r = await Promise.allSettled([tools.typed({}), tools.typed({field:"ok"})]); text(r.map(x=>x.status === "rejected" ? x.reason.message : x.value)); const b = await tools.bash({command:"printf shell; exit 7"}); text(b);',
                    },
                  ),
                ],
              )
            : app.done,
      );
      final result =
          await KernelApiRunner.withAgentClientFactory(
            agentClientFactory: (_) => client,
          ).executeApiCall(
            config: base.config().copyWith(
              toolPolicy: AgentToolPolicy(
                authorization: AgentToolAuthorization.allowAll,
                approvals: _HumanApproval(),
              ),
            ),
            sessionId: 'c',
            userText: null,
            responseProcessors: const [],
            availableTools: tools,
          );
      final text = result.rawToolResults.single.result;
      expect(text, contains('field'));
      expect(text, contains('valid'));
      expect(text, contains('"exit_code":7'));
      final calls =
          (result.rawToolResults.single.structured as Map)['codemodeCalls']
              as List;
      expect(calls.map((c) => c['id']), [
        'code-id/1',
        'code-id/2',
        'code-id/3',
      ]);
      expect(calls.map((c) => c['status']), ['error', 'ok', 'ok']);
    },
  );
}

class _RejectApproval implements ApprovalPort {
  int calls = 0;
  @override
  Future<bool> request(ApprovalRequest request) async {
    calls++;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return false;
  }
}

class _NestedRejectApproval implements ApprovalPort {
  int calls = 0;
  @override
  Future<bool> request(ApprovalRequest request) async {
    calls++;
    return request.toolName == 'codemode';
  }
}

// Simulates an explicit user answer, not an automatic reviewer approval.
class _HumanApproval implements ApprovalPort {
  @override
  Future<bool> request(ApprovalRequest request) async {
    ToolCallScope.current!.humanApproved = true;
    return true;
  }
}

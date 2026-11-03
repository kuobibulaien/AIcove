import 'dart:io';

import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:aicove_flutter/src/features/workspace/application/codemode_declarations.dart';
import 'package:aicove_flutter/src/features/workspace/application/codemode_script.dart';
import 'package:aicove_flutter/src/features/workspace/application/workspace_toolset.dart';
import 'package:aicove_flutter/src/features/workspace/data/workspace_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late WorkspaceStore store;
  late String workspace;
  late WorkspaceToolset set;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('codemode-structured-');
    store = await WorkspaceStore.open(root);
    workspace = (await store.create(name: 'test')).id;
    set = WorkspaceToolset(
      store: store,
      workspaceIds: {workspace},
      runId: 'r',
      runWebApp: (_, _) async => Uri.parse('http://localhost/'),
    );
  });
  tearDown(() async {
    await store.close();
    await root.delete(recursive: true);
  });

  test('workspace result declarations expose required and optional fields', () {
    final tools = {for (final tool in set.tools()) tool.name: tool};
    for (final entry in <String, List<String>>{
      'workspace_open': ['entries', 'webapp_guide'],
      'workspace_run': ['url', 'ai_base_url', 'note'],
      'workspace_create': ['workspace', 'name'],
      'write': ['path', 'revision'],
      'workspace_list': ['items'],
      'workspace_glob': ['items'],
      'workspace_grep': ['matches'],
      'workspace_move': ['path'],
      'workspace_delete': ['deleted'],
    }.entries) {
      final schema = tools[entry.key]!.outputSchema!;
      expect(schema['type'], 'object');
      expect(schema['required'], entry.value);
      expect(schema.containsKey('additionalProperties'), false);
      expect(renderToolSignature(tools[entry.key]!), contains('Promise<{'));
    }
    expect(tools['read']!.outputSchema, isNull);
    expect(tools['edit']!.outputSchema, isNull);
    final openProperties =
        tools['workspace_open']!.outputSchema!['properties'] as Map;
    expect(openProperties['agents_md']['type'], ['string', 'null']);
    expect(
      openProperties.keys,
      containsAll(['instructions', 'available_skills', 'notice']),
    );
  });

  test('nested write rejects a lost local directory', () async {
    final local = await Directory('${root.path}/local').create();
    final localSet = WorkspaceToolset(
      store: store,
      workspaceIds: {workspace},
      runId: 'r',
      enableLocalFiles: true,
      enableScripts: true,
      currentLocalDirectory: local.path,
    );
    final tools = localSet.tools();
    final byName = {for (final tool in tools) tool.name: tool};
    final context = ToolCallContext(
      sessionId: 's',
      turnId: 't',
      round: 1,
      toolCallId: 'c',
      scriptTools: ScriptToolAccess(
        tools,
        (name, args, _) => byName[name]!.invoke(args),
      ),
    );
    await local.delete();
    final result = await context.run(
      () => byName['codemode']!.invoke({
        'code':
            'try { await tools.write({path:"nested.txt",content:"bad"}); } catch(e) { text(e.message); }',
      }),
    );
    expect(result.text, contains('directory_unavailable'));
    expect(
      await File('${store.directoryOf('aicove').path}/nested.txt').exists(),
      false,
    );
  });

  test('ws.writeBytes rejects a lost local directory', () async {
    final local = await Directory('${root.path}/local-bytes').create();
    final localSet = WorkspaceToolset(
      store: store,
      workspaceIds: {workspace},
      runId: 'r',
      enableLocalFiles: true,
      enableScripts: true,
      currentLocalDirectory: local.path,
    );
    final tools = localSet.tools();
    final byName = {for (final tool in tools) tool.name: tool};
    await local.delete();
    final result = await byName['codemode']!.invoke({
      'code':
          'try { await ws.writeBytes("bytes.bin", "YQ=="); } catch(e) { text(e.message); }',
    });
    expect(result.text, contains('directory_unavailable'));
    expect(
      await File('${store.directoryOf('aicove').path}/bytes.bin').exists(),
      false,
    );
  });

  test('codemode receives workspace list and grep as objects', () async {
    final tools = set.tools();
    final byName = {for (final tool in tools) tool.name: tool};
    final write = await byName['write']!.invoke({
      'path': 'hello.txt',
      'content': 'needle here\n',
    });
    expect(write.isError, false, reason: write.text);
    final script = CodemodeScript(
      store: store,
      workspace: () => workspace,
      runId: 'r',
      owner: 'test',
      tools: ScriptToolAccess(
        tools,
        (name, args, _) => byName[name]!.invoke(args),
      ),
    );
    final result = await script.run('''
const list = await tools.workspace_list({});
const grep = await tools.workspace_grep({pattern: "needle"});
text(JSON.stringify({listObject: typeof list === "object", listed: list.items.includes("hello.txt"), grepObject: typeof grep === "object", match: grep.matches[0]}));
''');
    expect(result.isError, false, reason: result.text);
    expect(result.text, contains('"listObject":true'));
    expect(result.text, contains('"listed":true'));
    expect(result.text, contains('"grepObject":true'));
    expect(result.text, contains('needle here'));
  });
}

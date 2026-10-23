import 'dart:io';
import 'package:aicove_flutter/src/features/workspace/application/workspace_toolset.dart';
import 'package:aicove_flutter/src/features/workspace/application/codemode_declarations.dart';
import 'package:aicove_flutter/src/features/workspace/data/workspace_store.dart';
import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'cwd tools have Pi names and no workspace argument; open and create switch cwd',
    () async {
      final root = await Directory.systemTemp.createTemp('codemode-cwd-');
      final store = await WorkspaceStore.open(root);
      addTearDown(() async {
        await store.close();
        await root.delete(recursive: true);
      });
      final a = (await store.create(name: 'a')).id;
      final b = (await store.create(name: 'b')).id;
      final set = WorkspaceToolset(
        store: store,
        workspaceIds: {a, b},
        runId: 'cwd',
        enableShell: true,
        enableScripts: true,
      );
      final tools = assembleCodemodeTools(set.tools());
      final mobile = assembleCodemodeTools(
        WorkspaceToolset(
          store: store,
          workspaceIds: {a},
          runId: 'mobile',
          enableShell: true,
          enableScripts: true,
          platform: 'android',
        ).tools(),
      );
      expect(
        mobile
            .where((t) => t.exposure == ToolExposure.direct)
            .map((t) => t.name),
        ['codemode', 'read', 'write', 'edit'],
      );
      expect(
        tools
            .where((t) => t.exposure == ToolExposure.direct)
            .map((t) => t.name),
        ['bash', 'codemode', 'read', 'write', 'edit'],
      );
      for (final tool in tools)
        expect(
          (tool.parameterSchema['properties'] as Map).containsKey('workspace'),
          false,
          reason: tool.name,
        );
      for (final tool in tools)
        expect(
          tool.parameterSchema['required'] as List? ?? [],
          isNot(contains('workspace')),
          reason: tool.name,
        );
      Future<ToolOutput> call(String name, Map<String, dynamic> args) =>
          tools.firstWhere((t) => t.name == name).invoke(args);
      expect(
        (await call('write', {'path': 'a.txt', 'content': 'first'})).isError,
        false,
      );
      expect(await store.stat(a, 'a.txt'), isNotNull);
      await call('workspace_open', {'id': b});
      await call('write', {'path': 'b.txt', 'content': 'second'});
      expect(await store.stat(b, 'b.txt'), isNotNull);
      expect(await store.stat(a, 'b.txt'), isNull);
      final created = await call('workspace_create', {'name': 'new'});
      final id = (created.structured as Map)['workspace'] as String;
      await call('write', {'path': 'new.txt', 'content': 'third'});
      expect(await store.stat(id, 'new.txt'), isNotNull);
      expect(await set.prompt(), contains('路径都相对当前工作区'));
    },
  );
}

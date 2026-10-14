import 'dart:io';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart';
import 'package:aicove_flutter/src/features/agent_plugins/file_change_journal.dart';
import 'package:flutter_test/flutter_test.dart';

class _Noop implements ChangeApplier {
  @override
  Future<void> apply(Map<String, Object?> state) async {}
}

ReversibleChange _change(String name) => ReversibleChange(
      kind: 'noop',
      description: name,
      before: const {},
      after: {'name': name},
    );

void main() {
  late Directory dir;

  setUp(() async => dir = await Directory.systemTemp.createTemp('journal_'));
  tearDown(() => dir.delete(recursive: true));

  FileChangeJournal journal() => FileChangeJournal(
        file: () async => File('${dir.path}/journal.json'),
        appliers: {'noop': _Noop()},
      );

  test('concurrent appends from separate instances keep every record',
      () async {
    await Future.wait([
      for (var i = 0; i < 8; i++) journal().append('write$i', _change('w$i')),
    ]);

    final names = [
      for (final entry in await journal().recent())
        entry.change.description,
    ];
    expect(names.toSet(), {for (var i = 0; i < 8; i++) 'w$i'});
    expect(
      dir.listSync().where((e) => e.path.endsWith('.tmp')),
      isEmpty,
    );
  });

  test('an undo racing an append keeps both', () async {
    final first = await journal().append('write', _change('a'));
    await Future.wait([
      journal().undo(first.id),
      journal().append('write', _change('b')),
    ]);

    final entries = await journal().recent();
    expect(entries, hasLength(3));
    expect(entries.where((e) => e.undoneAt != null), hasLength(1));
  });
}

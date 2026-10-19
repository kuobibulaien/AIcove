import 'dart:async';
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

  test('an undo cannot pick up a guarded change before its write decides',
      () async {
    final writing = Completer<bool>();
    final commit = journal().commitIf('write', _change('a'), () => writing.future);
    await pumpEventQueue();
    // The undo list may already show the record; undoing it has to wait.
    final pending = (await journal().recent()).single;
    final undo = journal().undo(pending.id);
    writing.complete(false);
    expect(await commit, isNull);
    await expectLater(undo, throwsStateError);
    expect(await journal().recent(), isEmpty);
  });

  test('a guarded change that lands keeps its record', () async {
    final entry = await journal().commitIf('write', _change('a'), () async => true);
    expect(entry, isNotNull);
    expect((await journal().recent()).single.id, entry!.id);
  });
}

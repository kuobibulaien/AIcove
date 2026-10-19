import 'package:aicove_flutter/src/features/workspace/domain/workspace_errors.dart';
import 'package:aicove_flutter/src/features/workspace/domain/workspace_path_rules.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  void rejects(String path, [String? reason]) => expect(
    () => WorkspacePathRules.normalize(path),
    throwsA(isA<WorkspaceException>()),
    reason: reason ?? path,
  );

  test('accepts ordinary relative paths', () {
    expect(WorkspacePathRules.normalize('notes/今天.md'), 'notes/今天.md');
    expect(WorkspacePathRules.normalize('a b/c-d_e.f.txt'), 'a b/c-d_e.f.txt');
  });

  test('normalizes NFD names to NFC', () {
    const nfd = 'cafe\u0301.txt';
    expect(WorkspacePathRules.normalize(nfd), 'caf\u00e9.txt');
    expect(
      WorkspacePathRules.fold(WorkspacePathRules.normalize(nfd)),
      WorkspacePathRules.fold(WorkspacePathRules.normalize('CAF\u00c9.txt')),
    );
  });

  test('rejects paths leaving the workspace', () {
    for (final path in ['', '/etc/passwd', '../x', 'a/../b', 'a/./b', 'a//b']) {
      rejects(path);
    }
  });

  test('rejects Windows reserved names and characters', () {
    for (final path in [
      'CON', 'con.txt', 'a/Nul', 'LPT9.log', 'COM1', //
      'a<b', 'a>b', 'a:b', 'a"b', 'a|b', 'a?b', 'a*b', r'a\b', 'a\u0001b',
      'trailing.', 'trailing ', 'dir./x',
    ]) {
      rejects(path);
    }
    expect(WorkspacePathRules.normalize('CONSOLE.txt'), 'CONSOLE.txt');
    expect(WorkspacePathRules.normalize('.hidden'), '.hidden');
  });

  test('segment length in UTF-16 units: below, at and over', () {
    WorkspacePathRules.normalize('a' * 99);
    WorkspacePathRules.normalize('a' * 100);
    rejects('a' * 101);
  });

  test('segment length in UTF-8 bytes: below, at and over', () {
    // Each CJK character is 3 bytes: 66 → 198, 67 → 201.
    WorkspacePathRules.normalize('${'字' * 66}ab');
    expect(
      () => WorkspacePathRules.normalize('${'字' * 66}abc'),
      throwsA(anything),
    );
    WorkspacePathRules.normalize('${'字' * 66}a');
    rejects('字' * 67);
  });

  test('whole path length: below, at and over', () {
    String path(int length) => '${'a' * 90}/${'b' * (length - 91)}';
    WorkspacePathRules.normalize(path(149));
    WorkspacePathRules.normalize(path(150));
    rejects(path(151));
  });

  test('host directory detection', () {
    expect(WorkspacePathRules.isHostPath('.aicove/workspace.json'), isTrue);
    expect(WorkspacePathRules.isHostPath('.aicove'), isTrue);
    expect(WorkspacePathRules.isHostPath('.aicove2/x'), isFalse);
  });

  test('root budget on Windows and elsewhere', () {
    final windowsRoot = 'C:\\${'r' * 105}';
    expect(WorkspacePathRules.rootFits(windowsRoot, windows: true), isTrue);
    expect(
      WorkspacePathRules.rootFits('${windowsRoot}x', windows: true),
      isFalse,
    );
    expect(
      WorkspacePathRules.rootFits('/var/mobile/${'r' * 150}', windows: false),
      isTrue,
    );
  });
}

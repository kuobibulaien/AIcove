import 'dart:async';
import 'dart:io';

import 'package:aicove_flutter/src/core/storage/app_data_directory.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/semantics_update_audit.dart';

/// Tests fake only the documents directory; keep app data there no matter
/// which host runs them (an unsandboxed Mac or Windows/Linux would otherwise
/// ask for the application support directory, ADR0106).
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  AppDataMigration.debugUsesSupportDirectory = false;
  final String? auditOut = Platform.environment['AICOVE_SEMANTICS_AUDIT'];
  if (auditOut != null) {
    SemanticsAuditBinding.ensureInitialized();
    final SemanticsUpdateAudit audit = SemanticsUpdateAudit.instance;
    setUp(audit.reset);
    tearDown(() {
      if (audit.violations.isEmpty) return;
      File(auditOut).writeAsStringSync(
        '${audit.violations.join('\n---\n')}\n=====\n',
        mode: FileMode.append,
      );
    });
  }
  await testMain();
}

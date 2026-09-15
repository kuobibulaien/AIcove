// Temporary, same-package diagnostic entry point. Does not open the business
// database through the app, run migrations, clean logs, or initialize network/sync providers.
// Restore the original APK after collecting the inventory.
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:aicove_flutter/src/features/observability/diagnostic_access_service.dart';
import 'package:aicove_flutter/src/features/observability/storage_inventory.dart';
import 'package:aicove_flutter/src/features/observability/diagnostic_runtime_identity.dart';
import 'storage_probe_details.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  DiagnosticAccessService(
    storageBuilder: () async {
      final root = (await getApplicationSupportDirectory()).parent.path;
      final build = await readDiagnosticRuntimeIdentity();
      return Isolate.run(() async {
        final report = await createStorageInventory(root);
        report['build'] = build;
        report['details'] = await storageProbeDetails(root);
        return Uint8List.fromList(utf8.encode(jsonEncode(report)));
      });
    },
  ).startAutomatically();
  runApp(
    const Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: Color(0xFFF6F6F6),
        child: Center(
          child: Text('正在进行只读存储盘点', style: TextStyle(color: Color(0xFF222222))),
        ),
      ),
    ),
  );
}

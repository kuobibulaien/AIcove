import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Device-only credentials. macOS deliberately avoids Keychain access so
/// locally signed updates can restore their session without an OS prompt.
/// This directory is outside the cloud sync and conversation export roots.
class DeviceCredentialStorage {
  const DeviceCredentialStorage();

  static const _secure = FlutterSecureStorage();

  Future<File> _file(String key) async {
    if (!RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(key)) {
      throw ArgumentError.value(key, 'key', 'Invalid credential key');
    }
    final support = await getApplicationSupportDirectory();
    return File(p.join(support.path, 'local_credentials', '$key.json'));
  }

  Future<String?> read({required String key}) async {
    if (!Platform.isMacOS) return _secure.read(key: key);
    final file = await _file(key);
    try {
      return await file.readAsString();
    } on FileSystemException catch (error) {
      if (error.osError?.errorCode == 2) return null;
      rethrow;
    }
  }

  Future<void> write({required String key, required String value}) async {
    if (!Platform.isMacOS) return _secure.write(key: key, value: value);
    final target = await _file(key);
    await target.parent.create(recursive: true);
    await _chmod(target.parent.path, '700');
    final staging = await target.parent.createTemp('.write-');
    try {
      final temporary = File(p.join(staging.path, 'value'));
      await temporary.writeAsString(value, flush: true);
      await _chmod(temporary.path, '600');
      await temporary.rename(target.path);
    } finally {
      await staging.delete(recursive: true);
    }
  }

  Future<void> _chmod(String path, String mode) async {
    final result = await Process.run('/bin/chmod', [mode, path]);
    if (result.exitCode != 0) {
      throw const FileSystemException('Unable to set credential permissions');
    }
  }
}

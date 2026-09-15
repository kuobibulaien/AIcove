import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/features/account/data/account_repository.dart';
import 'package:aicove_flutter/src/core/storage/device_credential_storage.dart';
// Override the path_provider adapter to keep credentials inside the test sandbox.
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

void main() {
  test(
    'Mac credentials persist across instances without any Keychain call',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      const channel = MethodChannel(
        'plugins.it_nomads.com/flutter_secure_storage',
      );
      final root = await Directory.systemTemp.createTemp('account-storage-');
      final originalPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths(root.path);
      addTearDown(() async {
        PathProviderPlatform.instance = originalPaths;
        await root.delete(recursive: true);
      });
      var keychainCalls = 0;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        keychainCalls++;
        throw PlatformException(code: 'keychain-must-not-be-accessed');
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      const storage = DeviceAccountStorage();
      expect(await storage.read(), isNull);
      await storage.write('fixture-account');
      expect(await const DeviceAccountStorage().read(), 'fixture-account');
      await storage.write('fixture-logged-out-owner');
      expect(await storage.read(), 'fixture-logged-out-owner');
      const credentials = DeviceCredentialStorage();
      await credentials.write(
        key: 'diagnostic_access_token_v1',
        value: 'probe',
      );
      expect(
        await credentials.read(key: 'diagnostic_access_token_v1'),
        'probe',
      );
      expect(await storage.read(), 'fixture-logged-out-owner');
      final files = await Directory(
        '${root.path}/local_credentials',
      ).list().toList();
      expect(
        files,
        hasLength(2),
        reason: 'Atomic staging leaves no stale tokens',
      );
      for (final file in files) {
        expect((await file.stat()).mode & 0x1ff, 0x180);
      }
      expect(keychainCalls, 0);
    },
    skip: !Platform.isMacOS,
  );
}

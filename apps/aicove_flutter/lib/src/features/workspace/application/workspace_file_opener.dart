import 'dart:io';

import 'package:flutter/services.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/workspace_store.dart';
import '../domain/workspace_path_rules.dart';

/// Hands a workspace file to the app the device uses for its type. Desktop
/// opens the file in place; Android views a cached copy through a content
/// URI; iOS has no default apps, so it offers the share sheet.
class WorkspaceFileOpener {
  WorkspaceFileOpener(this.store);

  final WorkspaceStore store;

  static const _android = MethodChannel('aicove/open_file');

  /// False when no app on this device accepts the file.
  Future<bool> open(String workspaceId, String path, {Rect? origin}) async {
    final normalized = WorkspacePathRules.normalize(path);
    final local = await store.diskFile(workspaceId, normalized);
    final file = Platform.isAndroid || local == null
        ? await _copy(workspaceId, normalized, local)
        : local;
    if (Platform.isAndroid) {
      return await _android.invokeMethod<bool>('open', {
            'path': file.path,
            'mime': lookupMimeType(file.path) ?? '*/*',
          }) ??
          false;
    }
    if (Platform.isIOS) {
      await Share.shareXFiles([XFile(file.path)], sharePositionOrigin: origin);
      return true;
    }
    return launchUrl(Uri.file(file.path));
  }

  /// Keeps the original name, and with it the type, under the cache folder
  /// that Android's FileProvider exposes.
  Future<File> _copy(String workspaceId, String path, File? local) async {
    final target = File(
      p.joinAll([
        (await getTemporaryDirectory()).path,
        'workspace_open',
        workspaceId,
        ...path.split('/'),
      ]),
    );
    await target.parent.create(recursive: true);
    if (local != null) return local.copy(target.path);
    final (bytes, _) = await store.read(workspaceId, path);
    return target.writeAsBytes(bytes, flush: true);
  }
}

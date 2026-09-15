// Temporary same-package maintenance entry. Restore the original APK afterwards.
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:aicove_flutter/src/features/observability/storage_inventory.dart';
import 'storage_cache_cleanup.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const token = String.fromEnvironment('STORAGE_MAINTENANCE_TOKEN');
  if (token.length < 43) throw StateError('Missing maintenance credential');
  final root = (await getApplicationSupportDirectory()).parent
      .resolveSymbolicLinksSync();
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 48632);
  var busy = false;
  server.listen((request) async {
    final response = request.response;
    response.headers.set('Cache-Control', 'no-store');
    if (request.headers.value('Authorization') != 'Bearer $token') {
      response.statusCode = 401;
      await response.close();
      return;
    }
    if (busy) {
      response.statusCode = 409;
      await response.close();
      return;
    }
    busy = true;
    try {
      Object? result;
      if (request.uri.hasQuery) {
        response.statusCode = 404;
      } else if (request.method == 'GET' && request.uri.path == '/plan') {
        result = publicCleanupPlan(
          await Isolate.run(() => planCacheCleanup(root)),
        );
      } else if (request.method == 'GET' && request.uri.path == '/inventory') {
        result = await Isolate.run(() => createStorageInventory(root));
      } else if (request.method == 'POST' &&
          request.uri.path == '/clean' &&
          request.contentLength > 0 &&
          request.contentLength < 256) {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        final planId = body['planId'] as String;
        result = await Isolate.run(() => executeCacheCleanup(root, planId));
      } else {
        response.statusCode = 404;
      }
      if (result != null) {
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode(result));
      }
    } catch (e) {
      response.statusCode = 500;
      response.write(jsonEncode({'errorType': e.runtimeType.toString()}));
    } finally {
      busy = false;
      await response.close();
    }
  });
  runApp(
    const Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: Color(0xfff6f6f6),
        child: Center(
          child: Text(
            '正在检查和清理可重建缓存',
            style: TextStyle(color: Color(0xff222222)),
          ),
        ),
      ),
    ),
  );
}

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'cancellable_tls_socket.dart';

/// Shared HTTP transport for scripts and sticker import. Production uses the
/// application HttpOverrides (including system proxies), without DNS filtering.
/// Resolver/connector injection is retained for deterministic transport tests.
class PublicNetwork {
  PublicNetwork({
    Future<List<InternetAddress>> Function(String)? resolve,
    Future<ConnectionTask<Socket>> Function(InternetAddress, int)? connect,
    this.securityContext,
    this.allowPrivateHosts = false,
  }) : _resolve = resolve,
       _connect = connect ?? Socket.startConnect;

  static const maxResponseBytes = 8 * 1024 * 1024;
  static const maxRedirects = 5;
  
  final Future<List<InternetAddress>> Function(String)? _resolve;
  final Future<ConnectionTask<Socket>> Function(InternetAddress, int) _connect;
  final SecurityContext? securityContext;

  /// Retained for source compatibility; local hosts are always allowed.
  final bool allowPrivateHosts;
  final _clients = <HttpClient>{};
  final _connections = <ConnectionTask<Socket>>{};
  bool _closed = false;

  void close() {
    _closed = true;
    for (final connection in _connections.toList()) {
      connection.cancel();
    }
    for (final client in _clients.toList()) {
      client.close(force: true);
    }
  }

  static String? checkUri(Uri uri, {bool allowPrivateHosts = false}) {
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      return '只支持 http 和 https 链接';
    }
    if (uri.host.isEmpty) return '链接缺少域名';
    if (uri.userInfo.isNotEmpty) return 'URL credentials are not supported';
    return null;
  }

  static bool isPublicAddress(InternetAddress address) {
    final b = address.rawAddress;
    if (address.type == InternetAddressType.IPv6) {
      // Normalize IPv4-mapped IPv6 before applying the IPv4 rules.
      if (b.take(10).every((v) => v == 0) && b[10] == 255 && b[11] == 255) {
        return isPublicAddress(
          InternetAddress.fromRawAddress(Uint8List.fromList(b.sublist(12))),
        );
      }
      // Global unicast only; exclude documentation and special-purpose space.
      return (b[0] & 0xe0) == 0x20 &&
          !(b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0d && b[3] == 0xb8) &&
          !(b[0] == 0x20 && b[1] == 0x01 && b[2] < 2) &&
          !(b[0] == 0x20 && b[1] == 0x02) &&
          !(b[0] == 0x3f && b[1] == 0xff && (b[2] & 0xf0) == 0);
    }
    final a = b[0], c = b[1];
    return a != 0 &&
        a != 10 &&
        a != 127 &&
        a < 224 &&
        !(a == 100 && c >= 64 && c <= 127) &&
        !(a == 169 && c == 254) &&
        !(a == 172 && c >= 16 && c <= 31) &&
        !(a == 192 && (c == 168 || (c == 0 && (b[2] == 0 || b[2] == 2)))) &&
        !(a == 198 && (c == 18 || c == 19 || (c == 51 && b[2] == 100))) &&
        !(a == 203 && c == 0 && b[2] == 113);
  }

  Future<PublicResponse> fetch(
    Uri uri, {
    String method = 'GET',
    Map<String, String> headers = const {},
    List<int>? body,
    int maxBytes = maxResponseBytes,
    Duration? timeout,
    bool Function()? isActive,
  }) async {
    if (maxBytes < 0) throw ArgumentError('Invalid response limit');
    if (timeout != null && timeout <= Duration.zero) throw ArgumentError('Invalid fetch timeout');
    var callOpen = true;
    void check() {
      if (!callOpen || _closed || (isActive != null && !isActive())) {
        throw StateError('Network invocation closed');
      }
    }

    check();
    final clients = <HttpClient>{};
    final connections = <ConnectionTask<Socket>>{};
    Future<PublicResponse> operation() async {
      var current = uri;
      var currentMethod = method.toUpperCase();
      var currentBody = body;
      var currentHeaders = Map<String, String>.of(headers);
      for (var hop = 0; ; hop++) {
        check();
        final problem = checkUri(current, allowPrivateHosts: allowPrivateHosts);
        if (problem != null) throw StateError(problem);
        final host = current.host.replaceAll(RegExp(r'^\[|\]$'), '');
        final client = HttpClient(context: securityContext);
        clients.add(client);
        _clients.add(client);
        // Only tests override DNS. Real requests keep HttpClient's proxy/TLS path.
        if (_resolve != null) {
        client.findProxy = (_) => 'DIRECT';
        final addresses = await _resolve(host);
        check();
        if (addresses.isEmpty) throw const SocketException('DNS returned no addresses');
        client.connectionFactory = (url, proxyHost, proxyPort) async {
          check();
          if (url.host != current.host ||
              url.port != current.port ||
              proxyHost != null) {
            throw StateError('Unexpected connection target');
          }
          // InternetAddress.lookup retains the requested hostname in .host.
          // SecureSocket uses it for SNI/certificate verification while TCP
          // uses rawAddress, with no second DNS lookup. The factory itself
          // must supply TLS: HttpClient will not add it here.
          var cancelled = false;
          ConnectionTask<Socket>? attempt;
          Socket? connected;
          Future<Socket> connectPinned() async {
            Object? lastError;
            for (final address in addresses) {
              check();
              if (cancelled) throw StateError('Connection cancelled');
              if (current.scheme == 'https' &&
                  address.host.toLowerCase() != host.toLowerCase()) {
                throw StateError('TLS DNS address lost its original hostname');
              }
              try {
                attempt = current.scheme == 'https'
                    ? await connectCancellableTls(
                        address,
                        current.port,
                        context: securityContext,
                      )
                    : await _connect(address, current.port);
                if (cancelled || !callOpen || _closed) {
                  attempt!.cancel();
                  check();
                  throw StateError('Connection cancelled');
                }
                connected = await attempt!.socket;
                try {
                  check();
                  if (cancelled) throw StateError('Connection cancelled');
                } catch (_) {
                  connected!.destroy();
                  rethrow;
                }
                return connected!;
              } on SocketException catch (error) {
                lastError = error;
                attempt?.cancel();
                // Only try another address from this same validated DNS set.
              }
            }
            throw lastError ??
                const SocketException('No usable public address');
          }

          final task = ConnectionTask.fromSocket(connectPinned(), () {
            cancelled = true;
            attempt?.cancel();
            connected?.destroy();
          });
          connections.add(task);
          _connections.add(task);
          try {
            check();
          } catch (_) {
            task.cancel();
            connections.remove(task);
            _connections.remove(task);
            rethrow;
          }
          return task;
        };
        }
        final request = await client.openUrl(currentMethod, current);
        check();
        request.followRedirects = false;
        currentHeaders.forEach(request.headers.set);
        if (currentBody != null) request.add(currentBody);
        final response = await request.close();
        check();
        final location = response.headers.value(HttpHeaders.locationHeader);
        if ([301, 302, 303, 307, 308].contains(response.statusCode) &&
            location != null) {
          // Do not drain an untrusted redirect body (it may never finish).
          client.close(force: true);
          if (hop >= maxRedirects) throw StateError('重定向次数过多');
          final next = current.resolve(location);
          if (next.origin != current.origin) {
            currentHeaders.removeWhere(
              (name, _) => [
                'authorization',
                'cookie',
                'proxy-authorization',
              ].contains(name.toLowerCase()),
            );
          }
          if (response.statusCode == 303 ||
              ([301, 302].contains(response.statusCode) &&
                  currentMethod == 'POST')) {
            currentMethod = 'GET';
            currentBody = null;
            currentHeaders.removeWhere(
              (name, _) => [
                'content-type',
                'content-length',
              ].contains(name.toLowerCase()),
            );
          }
          current = next;
          continue;
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response) {
          check();
          if (bytes.length + chunk.length > maxBytes) {
            throw StateError('文件超过大小上限');
          }
          bytes.add(chunk);
        }
        check();
        final responseHeaders = <String, String>{};
        response.headers.forEach(
          (name, values) => responseHeaders[name] = values.join(', '),
        );
        return PublicResponse(
          current,
          response.statusCode,
          responseHeaders,
          bytes.takeBytes(),
        );
      }
    }

    try {
      return await (timeout == null ? operation() : operation().timeout(timeout));
    } finally {
      callOpen = false;
      // Also closes sockets/streams on timeout, rather than merely ignoring
      // a Future that can continue consuming data in the background.
      for (final client in clients) {
        client.close(force: true);
        _clients.remove(client);
      }
      for (final task in connections) {
        task.cancel();
        _connections.remove(task);
      }
    }
  }
}

class PublicResponse {
  const PublicResponse(this.url, this.status, this.headers, this.bytes);
  final Uri url;
  final int status;
  final Map<String, String> headers;
  final Uint8List bytes;
}

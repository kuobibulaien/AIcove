import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Mock transport with explicit final-URL metadata and no redirect handling.
/// MockClient itself discards this metadata, unlike the production IOClient.
class NoRedirectMockClient extends MockClient {
  NoRedirectMockClient(super.handler);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await super.send(request);
    return _ResponseWithUrl(response, request);
  }
}

class _ResponseWithUrl extends http.StreamedResponse
    implements http.BaseResponseWithUrl {
  _ResponseWithUrl(http.StreamedResponse response, http.BaseRequest request)
    : url = request.url,
      super(
        response.stream,
        response.statusCode,
        request: request,
        contentLength: response.contentLength,
        headers: response.headers,
        isRedirect: response.isRedirect,
        persistentConnection: response.persistentConnection,
        reasonPhrase: response.reasonPhrase,
      );

  @override
  final Uri url;
}

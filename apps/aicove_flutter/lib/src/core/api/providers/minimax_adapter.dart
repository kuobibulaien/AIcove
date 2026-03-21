library;

import 'openai_adapter.dart';
import 'minimax_compat.dart';

class MiniMaxAdapter extends OpenAIAdapter {
  @override
  String get name => 'minimax';

  @override
  String buildEndpoint(String baseUrl, {required String modelType}) {
    switch (modelType) {
      case 'chat':
      default:
        return normalizeMiniMaxNativeChatEndpoint(baseUrl);
    }
  }
}

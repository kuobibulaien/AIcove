library;

const kMiniMaxDefaultChatModels = <String>[
  'MiniMax-M2.7',
  'MiniMax-M2.7-highspeed',
  'MiniMax-M2.5',
  'MiniMax-M2.5-highspeed',
  'MiniMax-M2.1',
  'MiniMax-M2.1-highspeed',
  'MiniMax-M2',
];

const _miniMaxHosts = <String>{
  'api.minimax.io',
  'api.minimaxi.com',
};

bool isMiniMaxApiUrl(String? value) {
  final uri = Uri.tryParse(value?.trim() ?? '');
  if (uri == null) return false;
  return _miniMaxHosts.contains(uri.host.toLowerCase());
}

bool isMiniMaxNativeChatEndpoint(String? value) {
  final uri = Uri.tryParse(value?.trim() ?? '');
  if (uri == null || !_miniMaxHosts.contains(uri.host.toLowerCase())) {
    return false;
  }
  final path = uri.path.toLowerCase().replaceAll(RegExp(r'/+$'), '');
  return path.endsWith('/v1/text/chatcompletion_v2');
}

String normalizeMiniMaxNativeChatEndpoint(String value) {
  final trimmed = value.trim().replaceAll(RegExp(r'/+$'), '');
  final uri = Uri.tryParse(trimmed);
  if (uri == null) return trimmed;

  final path = uri.path.replaceAll(RegExp(r'/+$'), '');
  if (path.toLowerCase().endsWith('/v1/text/chatcompletion_v2')) {
    return uri.replace(path: path).toString();
  }
  if (path.toLowerCase().endsWith('/v1')) {
    return uri.replace(path: '$path/text/chatcompletion_v2').toString();
  }
  if (path.isEmpty || path == '/') {
    return uri.replace(path: '/v1/text/chatcompletion_v2').toString();
  }
  return uri.replace(path: '$path/v1/text/chatcompletion_v2').toString();
}

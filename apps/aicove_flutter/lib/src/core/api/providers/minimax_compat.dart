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

const kMiniMaxDefaultTtsModels = <String>[
  'speech-2.8-hd',
  'speech-2.8-turbo',
  'speech-2.6-hd',
  'speech-2.6-turbo',
  'speech-02-hd',
  'speech-02-turbo',
];

const kMiniMaxDefaultPreviewModels = <String>[
  ...kMiniMaxDefaultChatModels,
  ...kMiniMaxDefaultTtsModels,
];

const _miniMaxHosts = <String>{
  'api.minimax.io',
  'api.minimaxi.com',
  'api-bj.minimaxi.com',
};

bool isMiniMaxApiUrl(String? value) {
  final uri = Uri.tryParse(value?.trim() ?? '');
  if (uri == null) return false;
  return _miniMaxHosts.contains(uri.host.toLowerCase());
}

List<String> mergeMiniMaxPreviewModels(
  Iterable<String> models, {
  bool includeDefaultChatModels = false,
  bool includeDefaultTtsModels = true,
}) {
  final merged = <String>[];

  void addAll(Iterable<String> values) {
    for (final value in values) {
      final trimmed = value.trim();
      if (trimmed.isEmpty || merged.contains(trimmed)) {
        continue;
      }
      merged.add(trimmed);
    }
  }

  addAll(models);
  if (includeDefaultChatModels) {
    addAll(kMiniMaxDefaultChatModels);
  }
  if (includeDefaultTtsModels) {
    addAll(kMiniMaxDefaultTtsModels);
  }

  return merged;
}

bool isMiniMaxNativeChatEndpoint(String? value) {
  final uri = Uri.tryParse(value?.trim() ?? '');
  if (uri == null || !_miniMaxHosts.contains(uri.host.toLowerCase())) {
    return false;
  }
  final path = uri.path.toLowerCase().replaceAll(RegExp(r'/+$'), '');
  return path.endsWith('/v1/text/chatcompletion_v2');
}

String? buildMiniMaxModelsEndpoint(String value) {
  final trimmed = value.trim().replaceAll(RegExp(r'/+$'), '');
  final uri = Uri.tryParse(trimmed);
  if (uri == null || !_miniMaxHosts.contains(uri.host.toLowerCase())) {
    return null;
  }

  final path = uri.path.replaceAll(RegExp(r'/+$'), '');
  final lowerPath = path.toLowerCase();
  if (lowerPath.endsWith('/v1/text/chatcompletion_v2')) {
    return null;
  }

  String modelsPath;
  if (path.isEmpty || path == '/') {
    modelsPath = '/v1/models';
  } else if (lowerPath.endsWith('/anthropic/v1')) {
    final prefix = path.substring(0, path.length - '/anthropic/v1'.length);
    modelsPath = prefix.isEmpty ? '/v1/models' : '$prefix/v1/models';
  } else if (lowerPath.endsWith('/anthropic')) {
    final prefix = path.substring(0, path.length - '/anthropic'.length);
    modelsPath = prefix.isEmpty ? '/v1/models' : '$prefix/v1/models';
  } else if (lowerPath.endsWith('/v1')) {
    modelsPath = '$path/models';
  } else {
    modelsPath = '$path/models';
  }

  if (!modelsPath.startsWith('/')) {
    modelsPath = '/$modelsPath';
  }
  return Uri(
    scheme: uri.scheme,
    userInfo: uri.userInfo,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: modelsPath,
  ).toString();
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

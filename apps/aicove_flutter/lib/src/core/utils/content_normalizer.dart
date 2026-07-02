class ContentNormalizer {
  const ContentNormalizer._();

  static String coerceToText(dynamic content) {
    if (content == null) return '';
    if (content is String) return content;
    if (content is List) {
      final buf = StringBuffer();
      for (final part in content) {
        if (part is Map<String, dynamic>) {
          final text = part['text'] ?? part['input_text'];
          if (text != null) buf.write(text.toString());
        } else if (part is Map) {
          final text = part['text'] ?? part['input_text'];
          if (text != null) buf.write(text.toString());
        } else if (part is String) {
          buf.write(part);
        }
      }
      return buf.toString();
    }
    if (content is Map<String, dynamic>) {
      final parts = content['parts'];
      if (parts is List) return coerceToText(parts);
      final text = content['text'] ?? content['input_text'];
      if (text != null) return text.toString();
      return content.toString();
    }
    if (content is Map) {
      final parts = content['parts'];
      if (parts is List) return coerceToText(parts);
      final text = content['text'] ?? content['input_text'];
      if (text != null) return text.toString();
      return content.toString();
    }
    return content.toString();
  }

  static bool isEmpty(dynamic content) {
    if (content == null) return true;
    if (content is String) return content.trim().isEmpty;
    if (content is List) return content.isEmpty;
    if (content is Map<String, dynamic>) {
      final parts = content['parts'];
      if (parts is List) return parts.isEmpty;
      return coerceToText(content).trim().isEmpty;
    }
    if (content is Map) {
      final parts = content['parts'];
      if (parts is List) return parts.isEmpty;
      return coerceToText(content).trim().isEmpty;
    }
    return false;
  }
}

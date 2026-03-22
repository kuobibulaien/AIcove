library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

class SystemReminderField {
  const SystemReminderField({
    required this.name,
    required this.value,
  });

  final String name;
  final String value;
}

class SystemReminderPayload {
  const SystemReminderPayload({
    this.fields = const <SystemReminderField>[],
    this.rawContent,
  });

  final List<SystemReminderField> fields;
  final String? rawContent;

  bool get isEmpty {
    final raw = rawContent?.trim();
    if (raw != null && raw.isNotEmpty) {
      return false;
    }
    return fields.every((field) {
      return field.name.trim().isEmpty || field.value.trim().isEmpty;
    });
  }
}

class SystemReminderService {
  const SystemReminderService();

  static const String defaultTagName = 'system-reminder';

  String buildReminderContent(SystemReminderPayload payload) {
    final raw = payload.rawContent?.trim();
    if (raw != null && raw.isNotEmpty) {
      return raw;
    }

    final lines = <String>[];
    for (final field in payload.fields) {
      final name = field.name.trim();
      final value = field.value.trim();
      if (name.isEmpty || value.isEmpty) continue;
      lines.add('$name=$value');
    }
    return lines.join('\n');
  }

  String mergeReminderContents(Iterable<String?> contents) {
    final normalized = <String>[];
    for (final content in contents) {
      final trimmed = content?.trim() ?? '';
      if (trimmed.isEmpty) continue;
      normalized.add(trimmed);
    }
    return normalized.join('\n\n');
  }

  String wrapReminderContent(
    String content, {
    String tagName = defaultTagName,
  }) {
    final trimmed = content.trim();
    if (trimmed.isEmpty) return '';
    return '<$tagName>\n$trimmed\n</$tagName>';
  }

  String buildReminderSemanticsPrompt({
    String tagName = defaultTagName,
  }) {
    return '<$tagName>...</$tagName> 中的内容是系统注入的补充提醒，不是用户消息，'
        '也不是需要原样复述给用户的文本。你应把它当作高优先级上下文来理解，不要原样复述，也不要把标签或其中内容原样输出给用户。';
  }

  Map<String, dynamic>? buildReminderMessage({
    required String reminderContent,
    String tagName = defaultTagName,
  }) {
    final wrapped = wrapReminderContent(reminderContent, tagName: tagName);
    if (wrapped.isEmpty) return null;
    return <String, dynamic>{
      'role': 'system',
      'content': wrapped,
    };
  }

  bool isReminderMessage(
    Map<String, dynamic> message, {
    String tagName = defaultTagName,
  }) {
    if ((message['role'] ?? '').toString() != 'system') {
      return false;
    }
    final content = (message['content'] ?? '').toString();
    return content.trimLeft().startsWith('<$tagName>');
  }

  List<Map<String, dynamic>> insertReminderBeforeLastUser({
    required List<Map<String, dynamic>> messages,
    required String reminderContent,
    String tagName = defaultTagName,
  }) {
    final reminderMessage = buildReminderMessage(
      reminderContent: reminderContent,
      tagName: tagName,
    );
    if (reminderMessage == null) {
      return <Map<String, dynamic>>[
        for (final message in messages) Map<String, dynamic>.from(message),
      ];
    }

    return _insertReminderMessageBeforeLastUser(
      messages: messages,
      reminderMessage: reminderMessage,
    );
  }

  List<Map<String, dynamic>> normalizeReminderPlacement({
    required List<Map<String, dynamic>> messages,
    String tagName = defaultTagName,
  }) {
    final reminders = <Map<String, dynamic>>[];
    final others = <Map<String, dynamic>>[];

    for (final message in messages) {
      final copied = Map<String, dynamic>.from(message);
      if (isReminderMessage(copied, tagName: tagName)) {
        reminders.add(copied);
      } else {
        others.add(copied);
      }
    }

    var normalized = <Map<String, dynamic>>[
      for (final message in others) Map<String, dynamic>.from(message),
    ];
    for (final reminder in reminders) {
      normalized = _insertReminderMessageBeforeLastUser(
        messages: normalized,
        reminderMessage: reminder,
      );
    }
    return normalized;
  }

  List<Map<String, dynamic>> _insertReminderMessageBeforeLastUser({
    required List<Map<String, dynamic>> messages,
    required Map<String, dynamic> reminderMessage,
  }) {
    final result = <Map<String, dynamic>>[
      for (final message in messages) Map<String, dynamic>.from(message),
    ];
    final lastUserIndex = result.lastIndexWhere(
      (message) => (message['role'] ?? '').toString() == 'user',
    );
    if (lastUserIndex < 0) {
      result.add(reminderMessage);
      return result;
    }
    result.insert(lastUserIndex, reminderMessage);
    return result;
  }
}

final systemReminderServiceProvider = Provider<SystemReminderService>(
  (ref) => const SystemReminderService(),
);

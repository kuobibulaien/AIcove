library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../prompts/prompt_builtin_defaults.g.dart';
import '../prompts/prompt_template_renderer.dart';

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
    return PromptTemplateRenderer.renderTrimmed(
      PromptBuiltinDefaults.requireTemplate(
        'system_reminder.semantics',
      ),
      <String, Object?>{
        'tag_name': tagName,
      },
    );
  }

  Map<String, dynamic>? buildReminderMessage({
    required String reminderContent,
    String tagName = defaultTagName,
  }) {
    final wrapped = wrapReminderContent(reminderContent, tagName: tagName);
    if (wrapped.isEmpty) return null;
    return <String, dynamic>{
      'role': 'user',
      'content': wrapped,
    };
  }

  bool isReminderMessage(
    Map<String, dynamic> message, {
    String tagName = defaultTagName,
  }) {
    if ((message['role'] ?? '').toString() != 'user') {
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

  List<Map<String, dynamic>> appendReminderAsLastUser({
    required List<Map<String, dynamic>> messages,
    required String reminderContent,
    String tagName = defaultTagName,
  }) {
    final reminderMessage = buildReminderMessage(
      reminderContent: reminderContent,
      tagName: tagName,
    );
    final result = <Map<String, dynamic>>[
      for (final message in messages) Map<String, dynamic>.from(message),
    ];
    if (reminderMessage != null) {
      result.add(reminderMessage);
    }
    return result;
  }

  List<Map<String, dynamic>> ensureReminderSemanticsPrompt({
    required List<Map<String, dynamic>> messages,
    String tagName = defaultTagName,
  }) {
    final normalized = <Map<String, dynamic>>[
      for (final message in messages) Map<String, dynamic>.from(message),
    ];
    final semanticsPrompt = buildReminderSemanticsPrompt(tagName: tagName);
    final hasSystemReminderSemantics = normalized.any((message) {
      if ((message['role'] ?? '').toString() != 'system') {
        return false;
      }
      final content = (message['content'] ?? '').toString();
      return content.contains('<$tagName>');
    });
    if (hasSystemReminderSemantics) {
      return normalized;
    }

    final firstSystemIndex = normalized.indexWhere(
      (message) => (message['role'] ?? '').toString() == 'system',
    );
    if (firstSystemIndex >= 0) {
      final content =
          (normalized[firstSystemIndex]['content'] ?? '').toString().trim();
      normalized[firstSystemIndex]['content'] =
          content.isEmpty ? semanticsPrompt : '$content\n\n$semanticsPrompt';
      return normalized;
    }

    normalized.insert(0, <String, dynamic>{
      'role': 'system',
      'content': semanticsPrompt,
    });
    return normalized;
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

library;

import '../../../core/api/providers/provider_adapter.dart'
    show ToolCall, ToolResult;
import '../../../core/models/message_block.dart';
import '../../plugins/domain/plugin.dart';
import '../../plugins/domain/plugin_content.dart';
import '../domain/message.dart';
import 'chat_types.dart';

class ChatMessageProjectionCodec {
  static const int rawPayloadVersion = 1;
  static const String _versionKey = 'version';
  static const String _rawReplyTextKey = 'rawReplyText';
  static const String _processedTextKey = 'processedText';
  static const String _pluginEventsKey = 'pluginEvents';
  static const String _pluginContentsKey = 'pluginContents';
  static const String _toolAudioResultsKey = 'toolAudioResults';
  static const String _toolCallsKey = 'toolCalls';
  static const String _rawToolResultsKey = 'rawToolResults';
  static const String _projectedMessagesKey = 'projectedMessages';

  static Map<String, dynamic> buildRawAssistantPayload({
    required ApiCallResult apiResult,
    required List<Message> projectedMessages,
  }) {
    return <String, dynamic>{
      _versionKey: rawPayloadVersion,
      _rawReplyTextKey: apiResult.rawReplyText,
      _processedTextKey: apiResult.processedText,
      _pluginEventsKey: <Map<String, dynamic>>[
        for (final event in apiResult.pluginEvents) event.toJson(),
      ],
      _pluginContentsKey: <Map<String, dynamic>>[
        for (final content in apiResult.pluginContents)
          if (_encodePluginContent(content) case final encoded?) encoded,
      ],
      _toolAudioResultsKey: <Map<String, dynamic>>[
        for (final item in apiResult.toolAudioResults)
          <String, dynamic>{
            'audioUrl': item.audioUrl,
            'text': item.text,
          },
      ],
      _toolCallsKey: <Map<String, dynamic>>[
        for (final call in apiResult.toolCalls)
          <String, dynamic>{
            'id': call.id,
            'name': call.name,
            'arguments': call.arguments,
            'thoughtSignature': call.thoughtSignature,
          },
      ],
      _rawToolResultsKey: <Map<String, dynamic>>[
        for (final result in apiResult.rawToolResults)
          <String, dynamic>{
            'toolCallId': result.toolCallId,
            'name': result.name,
            'result': result.result,
          },
      ],
      _projectedMessagesKey: serializeMessages(projectedMessages),
    };
  }

  static Map<String, dynamic> copyWithProjectedMessages(
    Map<String, dynamic>? rawPayload,
    List<Message> projectedMessages,
  ) {
    final next = <String, dynamic>{
      _versionKey: rawPayloadVersion,
      ...?rawPayload,
    };
    next[_projectedMessagesKey] = serializeMessages(projectedMessages);
    return next;
  }

  static String? rawReplyText(Map<String, dynamic>? rawPayload) {
    final value = rawPayload?[_rawReplyTextKey];
    return value is String ? value : null;
  }

  static String? processedText(Map<String, dynamic>? rawPayload) {
    final value = rawPayload?[_processedTextKey];
    return value is String ? value : null;
  }

  static List<PluginEvent> pluginEvents(Map<String, dynamic>? rawPayload) {
    final rawList = rawPayload?[_pluginEventsKey];
    if (rawList is! List) return const <PluginEvent>[];
    final events = <PluginEvent>[];
    for (final item in rawList) {
      if (item is! Map) continue;
      try {
        events.add(PluginEvent.fromJson(Map<String, dynamic>.from(item)));
      } catch (_) {}
    }
    return events;
  }

  static List<PluginContent> pluginContents(Map<String, dynamic>? rawPayload) {
    final rawList = rawPayload?[_pluginContentsKey];
    if (rawList is! List) return const <PluginContent>[];
    final contents = <PluginContent>[];
    for (final item in rawList) {
      if (item is! Map) continue;
      final decoded = _decodePluginContent(Map<String, dynamic>.from(item));
      if (decoded != null) {
        contents.add(decoded);
      }
    }
    return contents;
  }

  static List<ToolAudioResult> toolAudioResults(
    Map<String, dynamic>? rawPayload,
  ) {
    final rawList = rawPayload?[_toolAudioResultsKey];
    if (rawList is! List) return const <ToolAudioResult>[];
    final results = <ToolAudioResult>[];
    for (final item in rawList) {
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item);
      final audioUrl = map['audioUrl'] as String?;
      final text = map['text'] as String?;
      if (audioUrl == null || text == null) continue;
      results.add(ToolAudioResult(audioUrl: audioUrl, text: text));
    }
    return results;
  }

  static List<ToolCall> toolCalls(Map<String, dynamic>? rawPayload) {
    final rawList = rawPayload?[_toolCallsKey];
    if (rawList is! List) return const <ToolCall>[];
    final calls = <ToolCall>[];
    for (final item in rawList) {
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item);
      final id = map['id'] as String?;
      final name = map['name'] as String?;
      final arguments = map['arguments'];
      if (id == null || name == null || arguments is! Map) continue;
      calls.add(
        ToolCall(
          id: id,
          name: name,
          arguments: Map<String, dynamic>.from(arguments),
          thoughtSignature: map['thoughtSignature'] as String?,
        ),
      );
    }
    return calls;
  }

  static List<ToolResult> rawToolResults(Map<String, dynamic>? rawPayload) {
    final rawList = rawPayload?[_rawToolResultsKey];
    if (rawList is! List) return const <ToolResult>[];
    final results = <ToolResult>[];
    for (final item in rawList) {
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item);
      final toolCallId = map['toolCallId'] as String?;
      final name = map['name'] as String?;
      final result = map['result'] as String?;
      if (toolCallId == null || name == null || result == null) continue;
      results.add(
        ToolResult(
          toolCallId: toolCallId,
          name: name,
          result: result,
        ),
      );
    }
    return results;
  }

  static List<Message> projectedMessages(Map<String, dynamic>? rawPayload) {
    final rawList = rawPayload?[_projectedMessagesKey];
    if (rawList is! List) return const <Message>[];
    return deserializeMessages(rawList);
  }

  static List<Map<String, dynamic>> serializeMessages(
      Iterable<Message> messages) {
    return <Map<String, dynamic>>[
      for (final message in messages) serializeMessage(message),
    ];
  }

  static List<Message> deserializeMessages(List<dynamic> rawMessages) {
    final messages = <Message>[];
    for (final item in rawMessages) {
      if (item is! Map) continue;
      final message = deserializeMessage(Map<String, dynamic>.from(item));
      if (message != null) {
        messages.add(message);
      }
    }
    return messages;
  }

  static Map<String, dynamic> serializeMessage(Message message) {
    return <String, dynamic>{
      'id': message.id,
      'role': message.role,
      'sourceMessageId': message.sourceMessageId,
      'content': message.content,
      'createdAt': message.createdAt.millisecondsSinceEpoch,
      'status': message.status,
      'blocks': <Map<String, dynamic>>[
        for (final block in message.blocks ?? const <MessageBlock>[])
          block.toJson(),
      ],
    };
  }

  static Message? deserializeMessage(Map<String, dynamic> raw) {
    final id = raw['id'] as String?;
    final role = raw['role'] as String?;
    final content = raw['content'] as String?;
    final createdAt = _readInt(raw['createdAt']);
    if (id == null || role == null || content == null || createdAt == null) {
      return null;
    }

    final blocks = <MessageBlock>[];
    final rawBlocks = raw['blocks'];
    if (rawBlocks is List) {
      for (final rawBlock in rawBlocks) {
        if (rawBlock is! Map) {
          return null;
        }
        try {
          blocks.add(
            MessageBlock.fromJson(Map<String, dynamic>.from(rawBlock)),
          );
        } catch (_) {
          return null;
        }
      }
    }

    return Message(
      id: id,
      role: role,
      sourceMessageId: raw['sourceMessageId'] as String?,
      content: content,
      blocks: blocks.isEmpty ? null : blocks,
      createdAt: DateTime.fromMillisecondsSinceEpoch(createdAt),
      status: raw['status'] as String?,
    );
  }

  static Map<String, dynamic>? _encodePluginContent(PluginContent content) {
    if (content is PluginTextContent) {
      return <String, dynamic>{
        'type': 'text',
        'text': content.text,
      };
    }
    if (content is PluginImageContent) {
      return <String, dynamic>{
        'type': 'image',
        'localPath': content.localPath,
        'caption': content.caption,
      };
    }
    if (content is PluginAudioContent) {
      return <String, dynamic>{
        'type': 'audio',
        'localPath': content.localPath,
        'durationMs': content.duration?.inMilliseconds,
      };
    }
    return null;
  }

  static PluginContent? _decodePluginContent(Map<String, dynamic> raw) {
    final type = raw['type'] as String?;
    switch (type) {
      case 'text':
        final text = raw['text'] as String?;
        return text == null ? null : PluginTextContent(text);
      case 'image':
        final localPath = raw['localPath'] as String?;
        if (localPath == null) return null;
        return PluginImageContent(
          localPath,
          caption: raw['caption'] as String?,
        );
      case 'audio':
        final localPath = raw['localPath'] as String?;
        if (localPath == null) return null;
        final durationMs = _readInt(raw['durationMs']);
        return PluginAudioContent(
          localPath,
          duration:
              durationMs == null ? null : Duration(milliseconds: durationMs),
        );
    }
    return null;
  }

  static int? _readInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return null;
  }
}

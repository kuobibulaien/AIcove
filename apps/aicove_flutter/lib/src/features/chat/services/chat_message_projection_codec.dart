library;

import '../../../core/api/providers/provider_adapter.dart'
    show ToolCall, ToolResult;
import '../../../core/models/message_block.dart';
import '../../../core/models/block_status.dart';
import '../../plugins/domain/plugin.dart';
import '../../plugins/domain/plugin_content.dart';
import '../domain/message.dart';
import 'chat_types.dart';

class StoredSupplementInsertOp {
  const StoredSupplementInsertOp({
    required this.kind,
    this.status = BlockStatus.success,
    required this.textCharsBefore,
    required this.forceAppendToTail,
    this.localPath,
    this.width,
    this.height,
    this.prompt,
    this.generationSnapshot,
    this.versions = const [],
    this.activeVersionIndex = 0,
    this.audioUrl,
    this.text,
    this.unread = false,
    this.legacyMessageId,
    this.legacyBlockId,
  });

  final String kind;
  final BlockStatus status;
  final int textCharsBefore;
  final bool forceAppendToTail;
  final String? localPath;
  final int? width, height;
  final String? prompt;
  final ImageGenerationSnapshot? generationSnapshot;
  final List<ImageVersionEntry> versions;
  final int activeVersionIndex;
  final String? audioUrl;
  final String? text;
  final bool unread;
  final String? legacyMessageId;
  final String? legacyBlockId;
}

class ChatMessageProjectionCodec {
  /// Repairs legacy display copies without changing raw text or stored aliases.
  /// This is pure: availability on a particular device never selects the source.
  static Map<String, dynamic>? normalizeLegacyMediaPayload({
    required String rawMessageId,
    required String role,
    required Map<String, dynamic>? payload,
    Iterable<Map<String, dynamic>> blocks = const [],
  }) {
    if (payload == null || payload['projectedMessages'] is! List)
      return payload;
    final sources = blocks.toList();
    final images = sources.where((b) => b['type'] == 'image').toList();
    var changed = false;
    final snapshots = <dynamic>[];
    for (final item in payload['projectedMessages'] as List) {
      if (item is! Map || item['blocks'] is! List) {
        snapshots.add(item);
        continue;
      }
      final aligned = <dynamic>[];
      for (final block in item['blocks'] as List) {
        if (block is! Map ||
            !const {'image', 'audio'}.contains(block['type'])) {
          aligned.add(block);
          continue;
        }
        final matches = sources
            .where((b) => b['id'] == block['id'] && b['type'] == block['type'])
            .toList();
        final source = matches.length == 1
            ? matches.single
            : role == 'user' &&
                  block['type'] == 'image' &&
                  item['id'] == '${rawMessageId}__proj_01_image' &&
                  images.length == 1
            ? images.single
            : null;
        if (source == null) {
          aligned.add(block);
          continue;
        }
        final next = Map<String, dynamic>.from(block);
        for (final key in [
          'url', 'localPath', 'width', 'height',
          if (block['type'] == 'image') ...[
            'base64', 'prompt', 'generationSnapshot', 'versions', 'activeVersionIndex',
          ],
        ]) {
          if (source.containsKey(key) || next.containsKey(key)) {
            if (next[key] != source[key]) changed = true;
            next[key] = source[key];
          }
        }
        aligned.add(next);
      }
      snapshots.add({...item, 'blocks': aligned});
    }
    var next = changed
        ? <String, dynamic>{...payload, 'projectedMessages': snapshots}
        : payload;
    final hasMedia =
        sources.any((b) => const {'image', 'audio'}.contains(b['type'])) ||
        pluginContents(
          next,
        ).any((c) => c is PluginImageContent || c is PluginAudioContent) ||
        toolAudioResults(next).isNotEmpty ||
        supplementInsertOps(next).isNotEmpty ||
        replyRounds(next).any(
          (r) => r.pluginContents.any(
            (c) => c is PluginImageContent || c is PluginAudioContent,
          ),
        );
    if (role != 'assistant' || displayReplyText(next) == null || hasMedia)
      return next;
    final messages = <Message>[];
    for (final item in next['projectedMessages'] as List) {
      if (item is! Map) continue;
      try {
        final message = deserializeMessage(Map<String, dynamic>.from(item));
        if (message != null) messages.add(message);
      } on Object {
        // A corrupt legacy copy must not block valid semantic text.
      }
    }
    var offset = 0;
    final ops = <StoredSupplementInsertOp>[];
    for (var i = 0; i < messages.length; i++) {
      final message = messages[i];
      final messageBlocks = message.blocks ?? const <MessageBlock>[];
      final hasTextBlocks = messageBlocks.whereType<TextBlock>().any(
        (b) => b.content.trim().isNotEmpty,
      );
      for (final (blockIndex, block) in messageBlocks.indexed) {
        if (block is TextBlock) {
          offset += block.content.replaceAll(RegExp(r'\s+'), '').length;
          continue;
        }
        if (block.status != BlockStatus.success) continue;
        final tail =
            !messageBlocks
                .skip(blockIndex + 1)
                .whereType<TextBlock>()
                .any((b) => b.content.trim().isNotEmpty) &&
            !messages.skip(i + 1).any((m) => _legacyText(m).trim().isNotEmpty);
        final legacyId = ops.any((op) => op.legacyMessageId == message.id)
            ? null
            : message.id;
        if (block is ImageBlock &&
            (block.localPath ?? block.url ?? '').trim().isNotEmpty) {
          ops.add(
            StoredSupplementInsertOp(
              kind: 'image',
              textCharsBefore: offset,
              forceAppendToTail: tail,
              localPath: block.localPath ?? block.url,
              prompt: block.prompt,
              width: block.width, height: block.height,
              generationSnapshot: block.generationSnapshot,
              versions: block.versions,
              activeVersionIndex: block.activeVersionIndex,
              legacyMessageId: legacyId,
              legacyBlockId: block.id,
            ),
          );
        } else if (block is AudioBlock && block.url.trim().isNotEmpty) {
          ops.add(
            StoredSupplementInsertOp(
              kind: 'audio',
              textCharsBefore: offset,
              forceAppendToTail: tail,
              audioUrl: block.url,
              text: block.text,
              unread: block.unread,
              legacyMessageId: legacyId,
              legacyBlockId: block.id,
            ),
          );
        }
      }
      if (!hasTextBlocks)
        offset += message.content.replaceAll(RegExp(r'\s+'), '').length;
    }
    if (ops.isNotEmpty) next = copyWithSupplementInsertOps(next, ops);
    return next;
  }

  static String _legacyText(Message message) {
    final text = (message.blocks ?? const <MessageBlock>[])
        .whereType<TextBlock>()
        .map((b) => b.content)
        .join();
    return text.trim().isNotEmpty ? text : message.content;
  }

  static const int rawPayloadVersion = 1;
  static const String _versionKey = 'version';
  static const String _rawReplyTextKey = 'rawReplyText';
  static const String _displayReplyTextKey = 'displayReplyText';
  static const String _processedTextKey = 'processedText';
  static const String _hiddenThoughtPartsKey = 'hiddenThoughtParts';
  static const String _pluginEventsKey = 'pluginEvents';
  static const String _pluginContentsKey = 'pluginContents';
  static const String _toolAudioResultsKey = 'toolAudioResults';
  static const String _toolCallsKey = 'toolCalls';
  static const String _rawToolResultsKey = 'rawToolResults';
  static const String _projectedMessagesKey = 'projectedMessages';
  static const String _supplementInsertOpsKey = 'supplementInsertOps';
  static const String _reasoningKey = 'reasoning';
  static const String _replyRoundsKey = 'replyRounds';

  static Map<String, dynamic> buildRawAssistantPayload({
    required ApiCallResult apiResult,
  }) {
    return <String, dynamic>{
      _versionKey: rawPayloadVersion,
      if (apiResult.status != ApiRunStatus.completed) 'runStatus': apiResult.status.name,
      if (apiResult.stopReason != null) 'stopReason': apiResult.stopReason,
      _rawReplyTextKey: apiResult.rawReplyText,
      _processedTextKey: apiResult.processedText,
      _displayReplyTextKey: apiResult.replyText,
      _hiddenThoughtPartsKey: <Map<String, dynamic>>[
        for (final part in apiResult.hiddenThoughtParts)
          Map<String, dynamic>.from(part),
      ],
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
            'result': result.persistentText,
            'isError':result.isError, 'structured':result.structured,
          },
      ],
      if (apiResult.reasoning.trim().isNotEmpty)
        _reasoningKey: apiResult.reasoning,
      if (apiResult.replyRounds.isNotEmpty)
        _replyRoundsKey: <Map<String, dynamic>>[
          for (final round in apiResult.replyRounds)
            <String, dynamic>{
              'replyText': round.replyText,
              if (round.rawText != null) 'rawText': round.rawText,
              'processedText': round.processedText,
              'pluginEvents': <Map<String, dynamic>>[
                for (final event in round.pluginEvents) event.toJson(),
              ],
              'pluginContents': <Map<String, dynamic>>[
                for (final content in round.pluginContents)
                  if (_encodePluginContent(content) case final encoded?)
                    encoded,
              ],
              if (round.reasoning.isNotEmpty) 'reasoning': round.reasoning,
              'toolCallIds': round.toolCallIds,
            },
        ],
    };
  }

  /// Status is display metadata on the final bubble, never model input.
  static List<Message> applyRunStatus(List<Message> messages, Map<String, dynamic>? payload) {
    final index = messages.lastIndexWhere((m) => m.role == 'assistant');
    if (index < 0 || (payload?['runStatus'] == null && payload?['stopReason'] == null)) return messages;
    return [for (var i = 0; i < messages.length; i++)
      if (i == index) messages[i].copyWith(rawPayload: {
        ...?messages[i].rawPayload,
        if (payload?['runStatus'] != null) 'runStatus': payload!['runStatus'],
        if (payload?['stopReason'] != null) 'stopReason': payload!['stopReason'],
      }) else messages[i]];
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

  static Map<String, dynamic> copyWithPluginContents(
    Map<String, dynamic>? rawPayload,
    List<PluginContent> pluginContents,
  ) {
    final next = <String, dynamic>{
      _versionKey: rawPayloadVersion,
      ...?rawPayload,
    };
    next[_pluginContentsKey] = <Map<String, dynamic>>[
      for (final content in pluginContents)
        if (_encodePluginContent(content) case final encoded?) encoded,
    ];
    return next;
  }

  static Map<String, dynamic> copyWithToolAudioResults(
    Map<String, dynamic>? rawPayload,
    List<ToolAudioResult> toolAudioResults,
  ) {
    final next = <String, dynamic>{
      _versionKey: rawPayloadVersion,
      ...?rawPayload,
    };
    next[_toolAudioResultsKey] = <Map<String, dynamic>>[
      for (final item in toolAudioResults)
        <String, dynamic>{
          'audioUrl': item.audioUrl,
          'text': item.text,
        },
    ];
    return next;
  }

  static Map<String, dynamic> removeProjectedMessages(
    Map<String, dynamic>? rawPayload,
  ) {
    final next = <String, dynamic>{
      _versionKey: rawPayloadVersion,
      ...?rawPayload,
    };
    next.remove(_projectedMessagesKey);
    return next;
  }

  static Map<String, dynamic> copyWithSupplementInsertOps(
    Map<String, dynamic>? rawPayload,
    List<StoredSupplementInsertOp> insertOps,
  ) {
    final next = <String, dynamic>{
      _versionKey: rawPayloadVersion,
      ...?rawPayload,
    };
    next[_supplementInsertOpsKey] = <Map<String, dynamic>>[
      for (final op in insertOps)
        <String, dynamic>{
          'kind': op.kind,
          if (op.status != BlockStatus.success) 'status': op.status.name,
          'textCharsBefore': op.textCharsBefore,
          'forceAppendToTail': op.forceAppendToTail,
          if (op.localPath != null) 'localPath': op.localPath,
          if (op.width != null) 'width': op.width,
          if (op.height != null) 'height': op.height,
          if (op.prompt != null) 'prompt': op.prompt,
          if (op.generationSnapshot != null) 'generationSnapshot': op.generationSnapshot!.toJson(),
          if (op.versions.isNotEmpty) ...{
            'versions': [for (final version in op.versions) version.toJson()],
            'activeVersionIndex': op.activeVersionIndex,
          },
          if (op.audioUrl != null) 'audioUrl': op.audioUrl,
          if (op.text != null) 'text': op.text,
          if (op.unread) 'unread': true,
          if (op.legacyMessageId != null) 'legacyMessageId': op.legacyMessageId,
          if (op.legacyBlockId != null) 'legacyBlockId': op.legacyBlockId,
        },
    ];
    return next;
  }

  /// Legacy cache/mixed-image IDs still need aliases; new semantic projection
  /// IDs identify their raw row without a stored projection mapping.
  static bool isCanonicalProjectionId(String rawMessageId, String projectedId) =>
      projectedId.startsWith('${rawMessageId}__proj_r') ||
      projectedId.startsWith('${rawMessageId}__proj_supplement_');

  /// Existing semantic fields are authoritative; snapshots are legacy fallback only.
  static bool hasProjectionSemantics(Map<String, dynamic>? payload) =>
      displayReplyText(payload) != null ||
      processedText(payload) != null ||
      replyRounds(payload).isNotEmpty ||
      pluginContents(payload).isNotEmpty ||
      toolAudioResults(payload).isNotEmpty ||
      supplementInsertOps(payload).isNotEmpty;

  static String? rawReplyText(Map<String, dynamic>? rawPayload) {
    final value = rawPayload?[_rawReplyTextKey];
    return value is String ? value : null;
  }

  /// Display-regex output before multimedia tags are consumed by plugins.
  static String? displayReplyText(Map<String, dynamic>? rawPayload) {
    final value = rawPayload?[_displayReplyTextKey];
    return value is String ? value : processedText(rawPayload);
  }

  static String? processedText(Map<String, dynamic>? rawPayload) {
    final value = rawPayload?[_processedTextKey];
    return value is String ? value : null;
  }

  /// 模型原生思考；旧数据没有这一项时为空串。
  static String reasoning(Map<String, dynamic>? rawPayload) {
    final value = rawPayload?[_reasoningKey];
    return value is String ? value : '';
  }

  static List<Map<String, dynamic>> hiddenThoughtParts(
    Map<String, dynamic>? rawPayload,
  ) {
    final rawList = rawPayload?[_hiddenThoughtPartsKey];
    if (rawList is! List) return const <Map<String, dynamic>>[];
    final parts = <Map<String, dynamic>>[];
    for (final item in rawList) {
      if (item is! Map) continue;
      parts.add(Map<String, dynamic>.from(item));
    }
    return parts;
  }

  static List<ReplyRound> replyRounds(Map<String, dynamic>? rawPayload) {
    final rawList = rawPayload?[_replyRoundsKey];
    if (rawList is! List) return const <ReplyRound>[];
    return <ReplyRound>[
      for (final item in rawList)
        if (item is Map)
          ReplyRound(
            replyText: item['replyText'] as String? ?? '',
            rawText: item['rawText'] as String?,
            processedText: item['processedText'] as String? ?? '',
            pluginEvents: pluginEvents({_pluginEventsKey: item['pluginEvents']}),
            pluginContents:
                pluginContents({_pluginContentsKey: item['pluginContents']}),
            reasoning: item['reasoning'] as String? ?? '',
            toolCallIds: <String>[
              for (final id in item['toolCallIds'] as List? ?? const [])
                if (id is String) id,
            ],
          ),
    ];
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

  static List<StoredSupplementInsertOp> supplementInsertOps(
    Map<String, dynamic>? rawPayload,
  ) {
    final rawList = rawPayload?[_supplementInsertOpsKey];
    if (rawList is! List) return const <StoredSupplementInsertOp>[];
    final ops = <StoredSupplementInsertOp>[];
    for (final item in rawList) {
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item);
      final kind = map['kind'] as String?;
      final textCharsBefore = map['textCharsBefore'];
      final forceAppendToTail = map['forceAppendToTail'];
      if (kind == null ||
          textCharsBefore is! int ||
          forceAppendToTail is! bool) {
        continue;
      }
      ops.add(
        StoredSupplementInsertOp(
          kind: kind,
          status: map['status'] == 'error' ? BlockStatus.error : BlockStatus.success,
          textCharsBefore: textCharsBefore,
          forceAppendToTail: forceAppendToTail,
          localPath: map['localPath'] as String?,
          width: _readInt(map['width']), height: _readInt(map['height']),
          prompt: map['prompt'] as String?,
          generationSnapshot: ImageGenerationSnapshot.tryRead(map['generationSnapshot']),
          versions: _readImageVersions(map['versions']),
          activeVersionIndex: _readInt(map['activeVersionIndex']) ?? 0,
          audioUrl: map['audioUrl'] as String?,
          text: map['text'] as String?,
          unread: map['unread'] == true,
          legacyMessageId: map['legacyMessageId'] as String?,
          legacyBlockId: map['legacyBlockId'] as String?,
        ),
      );
    }
    return ops;
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
          isError:map['isError']==true, structured:map['structured'],
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
      if (message.rawPayload?['runStatus'] != null)
        'runStatus': message.rawPayload!['runStatus'],
      if (message.rawPayload?['stopReason'] != null)
        'stopReason': message.rawPayload!['stopReason'],
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
    var fallbackContent = content;
    var downgradedAudio = false;
    final rawBlocks = raw['blocks'];
    if (rawBlocks is List) {
      for (final rawBlock in rawBlocks) {
        if (rawBlock is! Map) {
          return null;
        }
        try {
          final block = MessageBlock.fromJson(
            Map<String, dynamic>.from(rawBlock),
          );
          // Legacy unfinished audio is a display-only text fallback. Never
          // rewrite the source payload while decoding history.
          if (block is AudioBlock &&
              block.url.trim().isEmpty &&
              (block.text?.trim().isNotEmpty ?? false)) {
            downgradedAudio = true;
            blocks.add(TextBlock(
              id: block.id,
              messageId: id,
              content: block.text!.trim(),
              status: BlockStatus.success,
              createdAt: block.createdAt,
            ));
          } else {
            blocks.add(block);
          }
        } catch (_) {
          return null;
        }
      }
    }

    if (content.trim().isEmpty && downgradedAudio && blocks.length == 1) {
      fallbackContent = (blocks.single as TextBlock).content;
    }
    return Message(
      id: id,
      role: role,
      sourceMessageId: raw['sourceMessageId'] as String?,
      content: fallbackContent,
      blocks: blocks.isEmpty ? null : blocks,
      createdAt: DateTime.fromMillisecondsSinceEpoch(createdAt),
      status: raw['status'] as String?,
      rawPayload: raw['runStatus'] == null && raw['stopReason'] == null
          ? null
          : {
              if (raw['runStatus'] != null) 'runStatus': raw['runStatus'],
              if (raw['stopReason'] != null) 'stopReason': raw['stopReason'],
            },
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
        'width': content.width, 'height': content.height,
        'caption': content.caption,
        if (content.versions.isNotEmpty) ...{
          'versions': [for (final version in content.versions) version.toJson()],
          'activeVersionIndex': content.activeVersionIndex,
        },
        if (content.generationSnapshot != null) 'generationSnapshot': content.generationSnapshot!.toJson(),
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
          versions: _readImageVersions(raw['versions']),
          activeVersionIndex: _readInt(raw['activeVersionIndex']) ?? 0,
          width: _readInt(raw['width']), height: _readInt(raw['height']),
          generationSnapshot: ImageGenerationSnapshot.tryRead(raw['generationSnapshot']),
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

  static List<ImageVersionEntry> _readImageVersions(Object? value) => [
    if (value is List)
      for (final entry in value)
        if (entry is Map)
          ImageVersionEntry.fromJson(Map<String, dynamic>.from(entry)),
  ];

  static int? _readInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return null;
  }
}

library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/api/providers/provider_adapter.dart' show ToolCall;
import '../../settings/app_settings.dart';
import '../domain/message.dart';
import '../../../core/models/message_block.dart';
import '../../../core/utils/mime_utils.dart';
import '../../content_tags/domain/content_tag_registry.dart';
import '../../content_tags/domain/content_tag_scanner.dart';
import '../../content_tags/domain/content_tag_spec.dart';
import 'chat_plugin_context_policy.dart';
import 'chat_message_projection_codec.dart';

/// 负责将会话消息转换为模型请求消息。
///
/// 聚合图片、媒体附件与文本文件的请求转换。
class ChatRequestMessageBuilder {
  ChatRequestMessageBuilder({required this.readImageAsBase64});

  final Future<String?> Function(String imagePath) readImageAsBase64;

  static final _draftScanner = ContentTagScanner(
    ContentTagRegistry([
      StaticContentTagProvider(
        providerId: 'assistant-drafts',
        tagSpecs: [
          for (final name in const [
            'think',
            'thinking',
            'thought',
            'cot',
            'reasoning',
            '思考',
            '思维链',
            'comic_plan',
          ])
            ContentTagSpec(name: name, ownerId: ContentTagSpec.builtinOwnerId),
        ],
      ),
    ]),
  );

  static String stripAssistantDraftTags(String text) {
    final output = StringBuffer();
    var seenElement = false;
    var seenOrphan = false;
    for (final segment in _draftScanner.scan(maskCode(text))) {
      if (segment is ContentTagText) {
        output.write(text.substring(segment.start, segment.end));
      } else if (segment is ContentTagElement) {
        seenElement = true;
      } else if (segment is ContentTagOrphanClose) {
        if (!seenElement && !seenOrphan) output.clear();
        seenOrphan = true;
      }
    }
    return output.toString().replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }

  static const String internalImageContextToolName = 'image_context';
  static const String nonVisionImageContextSource = 'history';
  static final RegExp nonVisionImageContextRegex = RegExp(
    r'<image\s+[^>]*source="history"[^>]*>[\s\S]*?</image>',
    caseSensitive: false,
  );

  Future<List<Map<String, dynamic>>> buildRequestMessages(
    List<Message> history, {
    required AppSettings settings,
    bool supportsVision = true,
    ChatPluginContextPolicy? pluginPolicy,
    bool inlineImagePrompts = true,
  }) async {
    final reqMessages = <Map<String, dynamic>>[];
    final lastCompletedAssistantIndex = history.lastIndexWhere(
      (m) =>
          m.role == 'assistant' &&
          m.status != 'sending' &&
          (m.rawPayload?['runStatus'] == null ||
              m.rawPayload?['runStatus'] == 'completed') &&
          m.rawPayload?['stopReason'] != 'inProgress',
    );
    for (final (i, message) in history.indexed) {
      final convertedMessages = await _toRequestMessages(
        message,
        expandTaskMaterial: i > lastCompletedAssistantIndex,
        settings: settings,
        supportsVision: supportsVision,
        pluginPolicy: pluginPolicy,
        inlineImagePrompts: inlineImagePrompts,
      );
      if (pluginPolicy != null &&
          identical(message, history.last) &&
          message.role == 'user' &&
          convertedMessages.isEmpty &&
          message.content.trim().isNotEmpty) {
        throw StateError('当前消息过滤已关闭插件的标签后为空，请输入正文或添加附件。');
      }
      reqMessages.addAll(convertedMessages);
      final payload = message.rawPayload;
      if (message.role == 'assistant' &&
          (payload?['runStatus'] == 'cancelled' ||
              payload?['runStatus'] == 'failed' ||
              payload?['stopReason'] == 'inProgress')) {
        reqMessages.add({
          'role': 'assistant',
          'content': '[本次请求已中断。以上工具可能已产生副作用；未拿到结果的调用需先核实状态，再继续任务。]',
        });
      }
    }
    return _mergeAdjacentAssistantTextMessages(reqMessages);
  }

  List<Map<String, dynamic>> _mergeAdjacentAssistantTextMessages(
    List<Map<String, dynamic>> messages,
  ) {
    if (messages.isEmpty) return const <Map<String, dynamic>>[];

    final merged = <Map<String, dynamic>>[];
    for (final raw in messages) {
      final current = Map<String, dynamic>.from(raw);
      if (merged.isNotEmpty &&
          _isMergeableAssistantText(merged.last) &&
          _isMergeableAssistantText(current)) {
        final previousText = (merged.last['content'] as String?)?.trim() ?? '';
        final currentText = (current['content'] as String?)?.trim() ?? '';
        if (currentText.isEmpty) continue;
        merged.last['content'] = previousText.isEmpty
            ? currentText
            : '$previousText\n$currentText';
        continue;
      }
      merged.add(current);
    }
    return merged;
  }

  bool _isMergeableAssistantText(Map<String, dynamic> message) {
    final role = (message['role'] ?? '').toString();
    if (role != 'assistant') return false;
    if (message.containsKey('tool_calls') ||
        message.containsKey('function_call')) {
      return false;
    }
    final content = message['content'];
    if (content is! String) return false;
    return content.trim().isNotEmpty;
  }

  Future<List<Map<String, dynamic>>> _toRequestMessages(
    Message message, {
    required AppSettings settings,
    bool supportsVision = true,
    ChatPluginContextPolicy? pluginPolicy,
    bool inlineImagePrompts = true,
    bool expandTaskMaterial = false,
  }) async {
    final rounds = ChatMessageProjectionCodec.replyRounds(message.rawPayload);
    if (message.role == 'assistant' && rounds.isNotEmpty) {
      final remainingCalls = ChatMessageProjectionCodec.toolCalls(
        message.rawPayload,
      );
      final remainingResults = ChatMessageProjectionCodec.rawToolResults(
        message.rawPayload,
      );
      final messages = <Map<String, dynamic>>[];
      void appendRound(
        List<Map<String, dynamic>> converted,
        List<ToolCall> roundCalls,
      ) {
        final calls = <Map<String, dynamic>>[];
        final results = <Map<String, dynamic>>[];
        for (final call in roundCalls) {
          final resultIndex = remainingResults.indexWhere(
            (r) => r.toolCallId == call.id,
          );
          final result = resultIndex < 0
              ? null
              : remainingResults.removeAt(resultIndex);
          if (pluginPolicy != null && !pluginPolicy.allowsTool(call.name)) {
            continue;
          }
          calls.add(call.toOpenAIFormat());
          results.add({
            'role': 'tool',
            'tool_call_id': call.id,
            'name': call.name,
            'content': !expandTaskMaterial
                ? _stripHistoricalTaskDetail(
                    call.name,
                    result?.persistentText ?? '已中断，未拿到结果',
                  )
                : result?.persistentText ?? '已中断，未拿到结果',
          });
        }
        if (calls.isNotEmpty) {
          if (converted.isEmpty) {
            converted.add({'role': 'assistant', 'content': ''});
          }
          converted.first['tool_calls'] = calls;
        }
        messages.addAll([...converted, ...results]);
      }

      for (final (index, round) in rounds.indexed) {
        // Convert each round through the same text/media policy as legacy raw.
        final roundContent = round.rawText ?? round.replyText;
        final converted = await _toRequestMessages(
          message.copyWith(
            content: roundContent,
            rawPayload: null,
            blocks: [
              TextBlock(messageId: message.id, content: roundContent),
              if (index == rounds.length - 1)
                for (final block in message.blocks ?? const <MessageBlock>[])
                  if (block is! TextBlock &&
                      block is! ToolBlock &&
                      block is! ThinkingBlock)
                    block,
            ],
          ),
          expandTaskMaterial: expandTaskMaterial,
          settings: settings,
          supportsVision: supportsVision,
          pluginPolicy: pluginPolicy,
          inlineImagePrompts: inlineImagePrompts,
        );
        final roundCalls = <ToolCall>[];
        for (final id in round.toolCallIds) {
          final callIndex = remainingCalls.indexWhere((c) => c.id == id);
          if (callIndex >= 0) {
            roundCalls.add(remainingCalls.removeAt(callIndex));
          }
        }
        appendRound(converted, roundCalls);
      }
      // Older/mixed progress records can contain settled calls outside the
      // product-stage drafts. Keep their original order, without reusing calls
      // that were already claimed by a round.
      appendRound([], remainingCalls);
      return messages;
    }
    // Native and inline reasoning are never replayed as assistant dialogue.
    String requestText(String text) {
      final clean = message.role == 'assistant'
          ? stripAssistantDraftTags(text)
          : text;
      return pluginPolicy?.filterText(clean) ?? clean;
    }

    final blocks = message.blocks;
    if (blocks == null || blocks.isEmpty) {
      final content = requestText(message.content);
      if (content.trim().isEmpty) return [];
      return [
        {'role': message.role, 'content': content},
      ];
    }

    final parts = <Map<String, dynamic>>[];
    final toolCalls = <Map<String, dynamic>>[];
    final toolResultMessages = <Map<String, dynamic>>[];

    for (final block in blocks) {
      if (block is TextBlock) {
        final text = requestText(
          block is TaskReceiptBlock && expandTaskMaterial
              ? block.expandedContent
              : block.content,
        );
        if (text.trim().isEmpty) continue;
        parts.add({'type': 'text', 'text': text});
        continue;
      }

      if (block is EmojiBlock) {
        final text = formatEmojiBlockContextText(block);
        if (text.isNotEmpty) {
          parts.add({'type': 'text', 'text': text});
        }
        continue;
      }

      if (block is ImageBlock) {
        if (message.role == 'assistant') {
          if (pluginPolicy?.includesGeneratedImages == false) continue;
          // 模型自己生成的图只以它写过的标签回放，不论是否支持看图，
          // 让历史保持「回复里带 <image>」的样子，避免模型逐渐漏写标签。
          final tag = buildGeneratedImageTag(
            block.generationSnapshot?.basePrompt ?? block.prompt,
            inlinePrompt: inlineImagePrompts,
          );
          if (tag != null) parts.add({'type': 'text', 'text': tag});
          continue;
        }
        if (!supportsVision) {
          final description = block.prompt;
          final fallbackText = buildNonVisionImageMessageText(
            role: message.role,
            description: description,
          );
          if (fallbackText != null && fallbackText.isNotEmpty) {
            parts.add({'type': 'text', 'text': fallbackText});
          }
          continue;
        }

        if (block.mediaId != null) {
          parts.add({
            'type': 'image_url',
            'image_url': {'url': 'aicove-media://${block.mediaId}'},
          });
          continue;
        }

        final url = block.url?.trim();
        if (url != null && url.isNotEmpty) {
          parts.add({
            'type': 'image_url',
            'image_url': {'url': url},
          });
          continue;
        }

        final base64 = block.base64?.trim();
        if (base64 != null && base64.isNotEmpty) {
          parts.add({
            'type': 'image_url',
            'image_url': {'url': 'data:image/jpeg;base64,$base64'},
          });
          continue;
        }

        final localPath = block.localPath?.trim();
        if (localPath != null && localPath.isNotEmpty) {
          final encoded = await readImageAsBase64(localPath);
          if (encoded != null && encoded.isNotEmpty) {
            final mime = MimeUtils.guessImageMimeType(localPath);
            parts.add({
              'type': 'image_url',
              'image_url': {'url': 'data:$mime;base64,$encoded'},
            });
          } else {
            parts.add({'type': 'text', 'text': '[图片读取失败]'});
          }
        }
        continue;
      }

      if (block is FileBlock) {
        final mimeType =
            MimeUtils.normalizeContentType(block.mimeType) ??
            MimeUtils.guessAttachmentMimeType(block.filePath);
        if (MimeUtils.isAudioMimeType(mimeType) ||
            MimeUtils.isVideoMimeType(mimeType)) {
          final file = File(block.filePath);
          final maxBytes = settings.maxFileUploadMB * 1024 * 1024;
          final size = await file.length();
          if (maxBytes > 0 && size > maxBytes) {
            throw StateError('附件 ${block.fileName} 超过上传大小限制');
          }
          final data = base64Encode(await file.readAsBytes());
          parts.add({
            'type': 'file',
            'file': {
              'filename': block.fileName,
              'file_data': 'data:$mimeType;base64,$data',
            },
          });
          continue;
        }
        final fileText = await _readTextFileForAi(block, settings: settings);
        if (fileText.trim().isEmpty) continue;
        parts.add({'type': 'text', 'text': fileText});
        continue;
      }

      if (block is ToolBlock) {
        if (pluginPolicy != null && !pluginPolicy.allowsTool(block.toolName)) {
          continue;
        }
        if (extractInternalImageContextPayloadFromToolBlock(block) != null) {
          continue;
        }
        if (block.toolCallId != null && block.toolCallId!.isNotEmpty) {
          toolCalls.add({
            'id': block.toolCallId,
            'type': 'function',
            'function': {
              'name': block.toolName,
              'arguments': block.arguments != null
                  ? jsonEncode(block.arguments)
                  : '{}',
            },
          });
          toolResultMessages.add({
            'role': 'tool',
            'tool_call_id': block.toolCallId,
            'name': block.toolName,
            'content': !expandTaskMaterial && message.role == 'assistant'
                ? _stripHistoricalTaskDetail(
                    block.toolName,
                    block.result != null
                        ? jsonEncode(block.result)
                        : '{"success": true}',
                  )
                : block.result != null
                ? jsonEncode(block.result)
                : '{"success": true}',
          });
        }
      }
    }

    final assistantMessage = <String, dynamic>{'role': message.role};

    if (parts.isNotEmpty) {
      if (parts.length == 1 && parts.first['type'] == 'text') {
        assistantMessage['content'] = parts.first['text'];
      } else {
        assistantMessage['content'] = parts;
      }
    } else {
      assistantMessage['content'] = '';
    }

    if (toolCalls.isNotEmpty) {
      assistantMessage['tool_calls'] = toolCalls;
    }

    return [
      if (parts.isNotEmpty || toolCalls.isNotEmpty) assistantMessage,
      ...toolResultMessages,
    ];
  }

  /// 快速模式回放 `<image>提示词</image>`；稳定模式提示词在 draw_image
  /// 调用里，正文只回放发送占位 `<image></image>`。
  static String? buildGeneratedImageTag(
    String? prompt, {
    required bool inlinePrompt,
  }) {
    if (!inlinePrompt) return '<image></image>';
    final normalized = prompt?.trim();
    if (normalized == null || normalized.isEmpty) return null;
    return '<image>$normalized</image>';
  }

  static String? buildNonVisionImageMessageText({
    required String role,
    required String? description,
  }) {
    final normalized = description?.trim();
    if (normalized == null || normalized.isEmpty) {
      return null;
    }
    if (role == 'assistant') {
      return null;
    }
    return normalized;
  }

  static Map<String, dynamic> buildImageContextPayload({
    required String role,
    required String status,
    String? description,
    String? prompt,
    String? rawPrompt,
    String? reason,
    bool imagePresent = true,
  }) {
    final payload = <String, dynamic>{
      'type': 'image_context',
      'role': role,
      'status': status,
      'image_present': imagePresent,
    };

    final normalizedDescription = description?.trim();
    final normalizedPrompt = prompt?.trim();
    final normalizedRawPrompt = rawPrompt?.trim();
    final normalizedReason = reason?.trim();

    if (role == 'assistant') {
      if (status == 'failed') {
        payload['generation_failed'] = true;
      } else {
        payload['delivered_to_chat'] = true;
      }
      if (normalizedRawPrompt != null && normalizedRawPrompt.isNotEmpty) {
        payload['raw_prompt'] = normalizedRawPrompt;
      }
      if (normalizedPrompt != null && normalizedPrompt.isNotEmpty) {
        payload['prompt'] = normalizedPrompt;
      }
    } else {
      payload['uploaded_to_chat'] = true;
      if (normalizedDescription != null && normalizedDescription.isNotEmpty) {
        payload['description'] = normalizedDescription;
      }
    }

    if (normalizedReason != null && normalizedReason.isNotEmpty) {
      payload['reason'] = normalizedReason;
    }

    return payload;
  }

  static String buildInternalImageContextText(Map<String, dynamic> payload) {
    final role = payload['role']?.toString().trim();
    final status = payload['status']?.toString().trim();
    final attrs = <String>[
      'source="$nonVisionImageContextSource"',
      if (role != null && role.isNotEmpty) 'role="$role"',
      if (status != null && status.isNotEmpty) 'status="$status"',
    ];
    return '<image ${attrs.join(' ')}>${jsonEncode(payload)}</image>';
  }

  static bool containsInternalImageContextText(String text) {
    return nonVisionImageContextRegex.hasMatch(text);
  }

  static Map<String, dynamic>? extractInternalImageContextPayloadFromToolBlock(
    ToolBlock block,
  ) {
    if (block.toolCallId != null && block.toolCallId!.trim().isNotEmpty) {
      return null;
    }
    if (block.toolName != internalImageContextToolName) {
      return null;
    }
    final payload = block.result ?? block.arguments;
    if (payload == null || payload.isEmpty) {
      return null;
    }
    return Map<String, dynamic>.from(payload);
  }

  static String? buildInternalImageContextTextFromToolBlock(ToolBlock block) {
    final payload = extractInternalImageContextPayloadFromToolBlock(block);
    if (payload == null || payload.isEmpty) {
      return null;
    }
    return buildInternalImageContextText(payload);
  }

  static const _supportedTextFileExts = <String>{
    'txt',
    'md',
    'markdown',
    'json',
    'yaml',
    'yml',
    'csv',
    'log',
    'xml',
    'ini',
    'conf',
    'toml',
    'dart',
    'py',
    'js',
    'ts',
    'java',
    'kt',
    'swift',
    'go',
    'rs',
    'c',
    'cpp',
    'h',
    'hpp',
    'html',
    'css',
    'sh',
  };

  Future<String> _readTextFileForAi(
    FileBlock block, {
    required AppSettings settings,
  }) async {
    final path = block.filePath.trim();
    if (path.isEmpty) return '';

    final maxBytes = settings.maxFileUploadMB * 1024 * 1024;
    if (maxBytes > 0 && block.fileSize > maxBytes) {
      return 'User uploaded file ${block.fileName} (${block.fileSize}B), but it exceeds size limit.';
    }

    final ext = p.extension(path).replaceFirst('.', '').toLowerCase();
    if (ext.isNotEmpty && !_supportedTextFileExts.contains(ext)) {
      return 'User uploaded file ${block.fileName} (${block.mimeType}), but this format is not supported for reading.';
    }

    try {
      final bytes = await File(path).readAsBytes();
      final content = utf8.decode(bytes, allowMalformed: false);
      final safeContent = _truncateForPrompt(content);
      final lang = ext.isEmpty ? 'text' : ext;
      return '用户上传了文件：${block.fileName}（${block.fileSize}B）。\n\n```$lang\n$safeContent\n```';
    } catch (_) {
      try {
        final bytes = await File(path).readAsBytes();
        final content = utf8.decode(bytes, allowMalformed: true);
        if (content.contains('\u0000')) {
          return 'User uploaded file ${block.fileName} (${block.mimeType}), but it appears to be binary and cannot be read as text.';
        }
        final safeContent = _truncateForPrompt(content);
        final lang = ext.isEmpty ? 'text' : ext;
        return '用户上传了文件：${block.fileName}（${block.fileSize}B）。\n\n```$lang\n$safeContent\n```';
      } catch (e) {
        return 'User uploaded file ${block.fileName}, but reading failed: $e';
      }
    }
  }

  String _truncateForPrompt(String content) {
    const maxChars = 40000;
    if (content.length <= maxChars) return content;
    return '${content.substring(0, maxChars)}\n...(内容过长，已截断，仅发送前 $maxChars 字符)';
  }
}

String _stripHistoricalTaskDetail(String toolName, String content) {
  if (toolName != 'delegate_task') return content;
  try {
    final value = jsonDecode(content);
    if (value is Map && value.containsKey('detail')) {
      value.remove('detail');
      return jsonEncode(value);
    }
  } on FormatException {
    return content;
  }
  return content;
}

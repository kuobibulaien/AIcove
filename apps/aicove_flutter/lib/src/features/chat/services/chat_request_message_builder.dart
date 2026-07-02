library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/services/multimodal_assistant_service.dart';
import '../../settings/app_settings.dart';
import '../domain/message.dart';
import '../../../core/models/message_block.dart';
import '../../../core/utils/mime_utils.dart';

/// 负责将会话消息转换为模型请求消息。
///
/// 聚合了图片/文件消息转换、非视觉模型回退描述、视觉辅助模型翻译等逻辑。
class ChatRequestMessageBuilder {
  ChatRequestMessageBuilder({
    required this.readImageAsBase64,
    MultimodalAssistantService? multimodalAssistantService,
  }) : _multimodalAssistantService = multimodalAssistantService ??
            MultimodalAssistantService(
              readImageAsBase64: readImageAsBase64,
            );

  final Future<String?> Function(String imagePath) readImageAsBase64;
  final MultimodalAssistantService _multimodalAssistantService;

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
  }) async {
    final reqMessages = <Map<String, dynamic>>[];
    for (final message in history) {
      final convertedMessages = await _toRequestMessages(
        message,
        settings: settings,
        supportsVision: supportsVision,
      );
      reqMessages.addAll(convertedMessages);
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
        merged.last['content'] =
            previousText.isEmpty ? currentText : '$previousText\n$currentText';
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
  }) async {
    final blocks = message.blocks;
    if (blocks == null || blocks.isEmpty) {
      final content = message.content;
      if (content.trim().isEmpty) return [];
      return [
        {'role': message.role, 'content': content}
      ];
    }

    final parts = <Map<String, dynamic>>[];
    final toolCalls = <Map<String, dynamic>>[];
    final toolResultMessages = <Map<String, dynamic>>[];

    for (final block in blocks) {
      if (block is TextBlock) {
        if (block.content.trim().isEmpty) continue;
        parts.add({'type': 'text', 'text': block.content});
        continue;
      }

      if (block is ImageBlock) {
        if (!supportsVision) {
          final description =
              await _multimodalAssistantService.describeImageBlock(
            imageBlock: block,
            settings: settings,
          );
          final fallbackText = buildNonVisionImageMessageText(
            role: message.role,
            description: description,
          );
          if (fallbackText != null && fallbackText.isNotEmpty) {
            parts.add({'type': 'text', 'text': fallbackText});
          }
          continue;
        }

        final url = block.url?.trim();
        if (url != null && url.isNotEmpty) {
          parts.add({
            'type': 'image_url',
            'image_url': {'url': url}
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
        final fileText = await _resolveFileBlockText(block, settings: settings);
        if (fileText.trim().isEmpty) continue;
        parts.add({'type': 'text', 'text': fileText});
        continue;
      }

      if (block is ToolBlock) {
        if (extractInternalImageContextPayloadFromToolBlock(block) != null) {
          continue;
        }
        if (block.toolCallId != null && block.toolCallId!.isNotEmpty) {
          toolCalls.add({
            'id': block.toolCallId,
            'type': 'function',
            'function': {
              'name': block.toolName,
              'arguments':
                  block.arguments != null ? jsonEncode(block.arguments) : '{}',
            }
          });
          toolResultMessages.add({
            'role': 'tool',
            'tool_call_id': block.toolCallId,
            'name': block.toolName,
            'content': block.result != null
                ? jsonEncode(block.result)
                : '{"success": true}',
          });
        }
      }
    }

    final assistantMessage = <String, dynamic>{
      'role': message.role,
    };

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
      ...toolResultMessages
    ];
  }

  static Future<String?> resolveImageDescriptionForNonVision({
    required ImageBlock imageBlock,
    required Future<String?> Function() translateWithVision,
    String? cachedDescription,
    void Function(String description)? onDescriptionResolved,
  }) async {
    final existingPrompt = imageBlock.prompt?.trim();
    if (existingPrompt != null && existingPrompt.isNotEmpty) {
      return existingPrompt;
    }

    final cached = cachedDescription?.trim();
    if (cached != null && cached.isNotEmpty) {
      return cached;
    }

    final translated = (await translateWithVision())?.trim();
    if (translated == null || translated.isEmpty) return null;
    onDescriptionResolved?.call(translated);
    return translated;
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

  Future<String> _resolveFileBlockText(
    FileBlock block, {
    required AppSettings settings,
  }) async {
    final mimeType = MimeUtils.normalizeContentType(block.mimeType) ??
        MimeUtils.guessAttachmentMimeType(block.filePath);
    if (MimeUtils.isAudioMimeType(mimeType)) {
      final audioContext =
          await _multimodalAssistantService.transcribeAudioFile(
        fileBlock: block,
        settings: settings,
      );
      return _buildAudioContextText(block, audioContext);
    }
    if (MimeUtils.isVideoMimeType(mimeType)) {
      final videoContext = await _multimodalAssistantService.summarizeVideoFile(
        fileBlock: block,
        settings: settings,
      );
      return _buildVideoContextText(block, videoContext);
    }
    return _readTextFileForAi(block, settings: settings);
  }

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

  String _buildAudioContextText(FileBlock block, String? analysis) {
    final normalized = analysis?.trim();
    if (normalized != null && normalized.isNotEmpty) {
      return '<audio_context source="history" file="${block.fileName}">$normalized</audio_context>';
    }
    return '用户上传了音频文件：${block.fileName}（${block.fileSize}B，${block.mimeType}），但当前无法解析音频内容。';
  }

  String _buildVideoContextText(FileBlock block, String? analysis) {
    final normalized = analysis?.trim();
    if (normalized != null && normalized.isNotEmpty) {
      return '<video_context source="history" file="${block.fileName}">$normalized</video_context>';
    }
    return '用户上传了视频文件：${block.fileName}（${block.fileSize}B，${block.mimeType}），但当前无法解析视频内容。';
  }

  String _truncateForPrompt(String content) {
    const maxChars = 40000;
    if (content.length <= maxChars) return content;
    return '${content.substring(0, maxChars)}\n...(内容过长，已截断，仅发送前 $maxChars 字符)';
  }
}

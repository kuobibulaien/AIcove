library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../settings/app_settings.dart';
import '../domain/message.dart';
import '../../../core/api/agent_api.dart';
import '../../../core/models/message_block.dart';
import '../../../core/app_logger.dart';
import '../../../core/utils/mime_utils.dart';

/// 负责将会话消息转换为模型请求消息。
///
/// 聚合了图片/文件消息转换、非视觉模型回退描述、视觉辅助模型翻译等逻辑。
class ChatRequestMessageBuilder {
  ChatRequestMessageBuilder({
    required this.readImageAsBase64,
  });

  final Future<String?> Function(String imagePath) readImageAsBase64;
  final Map<String, String> _imageDescriptionCache = <String, String>{};

  static const int _maxImageDescriptionCacheSize = 128;
  static const String visionDescriptionSystemPrompt = '你是图片解释助手。只输出客观、简洁的图片描述。';
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
          final cacheKey = _buildImageDescriptionCacheKey(block);
          final cachedDescription =
              cacheKey == null ? null : _imageDescriptionCache[cacheKey];
          final description = await resolveImageDescriptionForNonVision(
            imageBlock: block,
            cachedDescription: cachedDescription,
            onDescriptionResolved: (resolved) {
              if (cacheKey != null) {
                _cacheImageDescription(cacheKey, resolved);
              }
            },
            translateWithVision: () =>
                _translateImageWithVisionModel(block, settings),
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
        final fileText = await _readTextFileForAi(block, settings: settings);
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

  static List<Map<String, dynamic>> buildVisionTranslationMessages({
    required Map<String, dynamic> imagePart,
  }) {
    return <Map<String, dynamic>>[
      {
        'role': 'system',
        'content': visionDescriptionSystemPrompt,
      },
      {
        'role': 'user',
        'content': [imagePart],
      }
    ];
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

  String? _buildImageDescriptionCacheKey(ImageBlock block) {
    final url = block.url?.trim();
    if (url != null && url.isNotEmpty) return 'url:$url';

    final localPath = block.localPath?.trim();
    if (localPath != null && localPath.isNotEmpty) return 'local:$localPath';

    final base64 = block.base64?.trim();
    if (base64 != null && base64.isNotEmpty) {
      if (base64.length <= 160) return 'b64:$base64';
      final head = base64.substring(0, 80);
      final tail = base64.substring(base64.length - 80);
      return 'b64:${base64.length}:$head:$tail';
    }
    return null;
  }

  void _cacheImageDescription(String cacheKey, String description) {
    final trimmed = description.trim();
    if (trimmed.isEmpty) return;

    if (_imageDescriptionCache.containsKey(cacheKey)) {
      _imageDescriptionCache.remove(cacheKey);
    }
    _imageDescriptionCache[cacheKey] = trimmed;
    while (_imageDescriptionCache.length > _maxImageDescriptionCacheSize) {
      _imageDescriptionCache.remove(_imageDescriptionCache.keys.first);
    }
  }

  Future<String?> _translateImageWithVisionModel(
    ImageBlock block,
    AppSettings settings,
  ) async {
    final visionModelRef = settings.defaultVisionModel;
    if (visionModelRef == null || visionModelRef.trim().isEmpty) return null;

    final providerId = settings.getModelProviderId(visionModelRef);
    final rawModelId = settings.getRawModelId(visionModelRef);
    if (providerId == null || rawModelId.isEmpty) return null;

    final provider = settings.providers.firstWhere(
      (p) => p.id == providerId,
      orElse: () =>
          const ProviderAuth(id: '', apiKeys: <String>[], apiBaseUrl: ''),
    );
    if (provider.id.isEmpty || provider.apiKeys.isEmpty) return null;

    final apiKey = provider.apiKeys.first.trim();
    if (apiKey.isEmpty) return null;

    final apiBaseUrl = provider.apiBaseUrl.trim();

    Map<String, dynamic>? imagePart;

    final url = block.url?.trim();
    if (url != null && url.isNotEmpty) {
      imagePart = {
        'type': 'image_url',
        'image_url': {'url': url}
      };
    } else {
      final base64 = block.base64?.trim();
      if (base64 != null && base64.isNotEmpty) {
        imagePart = {
          'type': 'image_url',
          'image_url': {'url': 'data:image/jpeg;base64,$base64'},
        };
      } else {
        final localPath = block.localPath?.trim();
        if (localPath != null && localPath.isNotEmpty) {
          final encoded = await readImageAsBase64(localPath);
          if (encoded != null && encoded.isNotEmpty) {
            final mime = MimeUtils.guessImageMimeType(localPath);
            imagePart = {
              'type': 'image_url',
              'image_url': {'url': 'data:$mime;base64,$encoded'},
            };
          }
        }
      }
    }

    if (imagePart == null) return null;

    final messages = buildVisionTranslationMessages(imagePart: imagePart);

    try {
      final agent = AgentApiClient(timeout: const Duration(seconds: 30));
      final result = await agent.sendMessageRich(
        agentId: 'system_vision',
        sessionId: 'vision_translate_${DateTime.now().millisecondsSinceEpoch}',
        modelFullId: visionModelRef,
        messages: messages,
        userText: '',
        providerApiBase: apiBaseUrl,
        providerApiKey: apiKey,
        customConfig: provider.customConfig,
      );
      final text = result.text.trim();
      if (text.isEmpty) return null;
      return text;
    } catch (e) {
      AppLogger.warning(
        'ChatSendService',
        'Vision translation failed',
        metadata: {'error': e.toString()},
      );
      return null;
    }
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

import 'dart:convert';
import '../../../core/models/message_block.dart';

/// Message模型（支持多模态Blocks）
/// 遵循开闭原则(O)：通过blocks扩展多模态能力，无需修改核心逻辑
class Message {
  static const Object _unset = Object();

  final String id;
  final String role; // 'user' | 'assistant'

  /// 当前消息投影自哪条原始消息
  final String? sourceMessageId;

  /// 文本内容（向后兼容旧版本）
  /// 当blocks为空时使用，或作为blocks的fallback
  final String content;

  /// 多模态内容块（新增）
  /// 可包含文本、图片、音频、代码等多种类型
  final List<MessageBlock>? blocks;

  final DateTime createdAt;

  /// 消息状态：'sending' | 'sent' | 'failed'
  /// null 或 'sent' 表示已成功发送（向后兼容）
  final String? status;

  /// 原始后端消息载荷（仅数据库正式消息使用）
  final Map<String, dynamic>? rawPayload;

  const Message({
    required this.id,
    required this.role,
    this.sourceMessageId,
    required this.content,
    this.blocks,
    required this.createdAt,
    this.status,
    this.rawPayload,
  });

  /// 返回可用于定位原始持久化消息的稳定 ID。
  ///
  /// 前端时间线中的投影消息会把真实 raw message id 放在 [sourceMessageId]，
  /// 新话题这类需要写“上下文边界”的场景必须优先使用它。
  String get sourceMessageIdOrSelf {
    final normalizedSourceMessageId = sourceMessageId?.trim();
    if (normalizedSourceMessageId != null &&
        normalizedSourceMessageId.isNotEmpty) {
      return normalizedSourceMessageId;
    }
    return id;
  }

  /// 获取显示文本（智能fallback）
  /// 优先从blocks中提取，否则使用content字段
  /// 对于多模态内容返回占位符文本
  String get displayText {
    if (blocks != null && blocks!.isNotEmpty) {
      final textBlocks = blocks!.whereType<TextBlock>();
      if (textBlocks.isNotEmpty) {
        return textBlocks.map((b) => b.content).join('\n\n');
      }
      // 多模态内容的占位符
      final firstBlock = blocks!.first;
      if (firstBlock is ImageBlock) return '[图片]';
      if (firstBlock is FileBlock) return '[文件]';
      if (firstBlock is AudioBlock) return '[语音]';
      if (firstBlock is EmojiBlock) return '[表情]';
      if (firstBlock is ToolBlock) return '[工具调用]';
      if (firstBlock is ThinkingBlock) return '[思考中...]';
    }
    return content;
  }

  /// 是否包含多模态内容
  bool get hasMultiModal {
    return blocks != null && blocks!.any((b) => b is! TextBlock);
  }

  /// 获取所有图片块
  List<ImageBlock> get images {
    return blocks?.whereType<ImageBlock>().toList() ?? [];
  }

  /// 获取所有音频块
  List<AudioBlock> get audios {
    return blocks?.whereType<AudioBlock>().toList() ?? [];
  }

  /// 转换为API历史格式（向后兼容）
  ///
  /// [includeTimestamp] 为 true 时，在消息内容前添加时间戳前缀 [YYYY-MM-DD HH:mm]
  /// 用于让 AI 感知消息的时间顺序
  /// 转换为API历史格式（向后兼容）
  ///
  /// [includeTimestamp] 为 true 时，在消息内容前添加时间戳前缀 [YYYY-MM-DD HH:mm]
  /// 用于让 AI 感知消息的时间顺序
  List<Map<String, dynamic>> toHistoryJsonList(
      {bool includeTimestamp = false}) {
    // 格式化时间戳前缀
    String addTimestampPrefix(String text) {
      if (!includeTimestamp) return text;
      final y = createdAt.year.toString();
      final m = createdAt.month.toString().padLeft(2, '0');
      final d = createdAt.day.toString().padLeft(2, '0');
      final h = createdAt.hour.toString().padLeft(2, '0');
      final min = createdAt.minute.toString().padLeft(2, '0');
      return '[$y-$m-$d $h:$min]: $text';
    }

    // 如果没有blocks，使用简单格式（向后兼容）
    if (blocks == null || blocks!.isEmpty) {
      return [
        {
          'role': role,
          'content': addTimestampPrefix(content),
        }
      ];
    }

    // 有blocks时，转换为多模态格式
    final contentParts = <Map<String, dynamic>>[];
    final toolCalls = <Map<String, dynamic>>[];
    final toolResultMessages = <Map<String, dynamic>>[];

    for (final block in blocks!) {
      if (block is TextBlock) {
        contentParts.add({
          'type': 'text',
          'text': addTimestampPrefix(block.content),
        });
      } else if (block is ImageBlock) {
        if (block.url != null) {
          contentParts.add({
            'type': 'image_url',
            'image_url': {'url': block.url},
          });
        } else if (block.base64 != null) {
          contentParts.add({
            'type': 'image_url',
            'image_url': {'url': 'data:image/jpeg;base64,${block.base64}'},
          });
        }
      } else if (block is ToolBlock) {
        if (block.toolCallId != null && block.toolCallId!.isNotEmpty) {
          toolCalls.add({
            'id': block.toolCallId,
            'type': 'function',
            'function': {
              'name': block.toolName,
              'arguments': block.arguments ?? {},
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
      // 其他类型的block可以根据需要添加
    }

    final assistantMessage = <String, dynamic>{
      'role': role,
    };

    if (contentParts.isNotEmpty) {
      if (contentParts.length == 1 && contentParts[0]['type'] == 'text') {
        assistantMessage['content'] = contentParts[0]['text'];
      } else {
        assistantMessage['content'] = contentParts;
      }
    } else {
      assistantMessage['content'] = '';
    }

    if (toolCalls.isNotEmpty) {
      assistantMessage['tool_calls'] = toolCalls;
    }

    return [assistantMessage, ...toolResultMessages];
  }

  /// 从文本创建消息（便捷构造函数）
  factory Message.text({
    required String id,
    required String role,
    required String content,
    String? sourceMessageId,
    DateTime? createdAt,
    String? status,
    Map<String, dynamic>? rawPayload,
  }) {
    return Message(
      id: id,
      role: role,
      sourceMessageId: sourceMessageId,
      content: content,
      blocks: [
        TextBlock(
          messageId: id,
          content: content,
        ),
      ],
      createdAt: createdAt ?? DateTime.now(),
      status: status,
      rawPayload: rawPayload,
    );
  }

  /// 从Blocks创建消息（新的推荐方式）
  factory Message.fromBlocks({
    required String id,
    required String role,
    required List<MessageBlock> blocks,
    String? sourceMessageId,
    DateTime? createdAt,
    String? status,
    Map<String, dynamic>? rawPayload,
  }) {
    // 提取文本内容作为fallback
    final textContent =
        blocks.whereType<TextBlock>().map((b) => b.content).join('\n\n');

    return Message(
      id: id,
      role: role,
      sourceMessageId: sourceMessageId,
      content: textContent,
      blocks: blocks,
      createdAt: createdAt ?? DateTime.now(),
      status: status,
      rawPayload: rawPayload,
    );
  }

  /// 复制消息并更新指定字段
  Message copyWith({
    String? id,
    String? role,
    Object? sourceMessageId = _unset,
    String? content,
    Object? blocks = _unset,
    DateTime? createdAt,
    String? status,
    Object? rawPayload = _unset,
  }) {
    return Message(
      id: id ?? this.id,
      role: role ?? this.role,
      sourceMessageId: identical(sourceMessageId, _unset)
          ? this.sourceMessageId
          : sourceMessageId as String?,
      content: content ?? this.content,
      blocks: identical(blocks, _unset)
          ? this.blocks
          : blocks as List<MessageBlock>?,
      createdAt: createdAt ?? this.createdAt,
      status: status ?? this.status,
      rawPayload: identical(rawPayload, _unset)
          ? this.rawPayload
          : rawPayload as Map<String, dynamic>?,
    );
  }
}

import '../../../core/models/message_block.dart';

/// Message模型（支持多模态Blocks）
/// 遵循开闭原则(O)：通过blocks扩展多模态能力，无需修改核心逻辑
class Message {
  final String id;
  final String role; // 'user' | 'assistant'

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

  const Message({
    required this.id,
    required this.role,
    required this.content,
    this.blocks,
    required this.createdAt,
    this.status,
  });

  /// 获取显示文本（智能fallback）
  /// 优先从blocks中提取，否则使用content字段
  String get displayText {
    if (blocks != null && blocks!.isNotEmpty) {
      final textBlocks = blocks!.whereType<TextBlock>();
      if (textBlocks.isNotEmpty) {
        return textBlocks.map((b) => b.content).join('\n\n');
      }
    }
    return content;
  }

  /// 是否包含多模态内容
  bool get hasMultiModal {
    return blocks != null &&
           blocks!.any((b) => b is! TextBlock);
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
  Map<String, dynamic> toHistoryJson() {
    // 如果没有blocks，使用简单格式（向后兼容）
    if (blocks == null || blocks!.isEmpty) {
      return {
        'role': role,
        'content': content,
      };
    }

    // 有blocks时，转换为多模态格式
    final contentParts = <Map<String, dynamic>>[];
    for (final block in blocks!) {
      if (block is TextBlock) {
        contentParts.add({
          'type': 'text',
          'text': block.content,
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
      }
      // 其他类型的block可以根据需要添加
    }

    // 如果只有一个文本part，使用简单格式
    if (contentParts.length == 1 && contentParts[0]['type'] == 'text') {
      return {
        'role': role,
        'content': contentParts[0]['text'],
      };
    }

    // 多模态格式
    return {
      'role': role,
      'content': contentParts,
    };
  }

  /// 从文本创建消息（便捷构造函数）
  factory Message.text({
    required String id,
    required String role,
    required String content,
    DateTime? createdAt,
    String? status,
  }) {
    return Message(
      id: id,
      role: role,
      content: content,
      blocks: [
        TextBlock(
          messageId: id,
          content: content,
        ),
      ],
      createdAt: createdAt ?? DateTime.now(),
      status: status,
    );
  }

  /// 从Blocks创建消息（新的推荐方式）
  factory Message.fromBlocks({
    required String id,
    required String role,
    required List<MessageBlock> blocks,
    DateTime? createdAt,
    String? status,
  }) {
    // 提取文本内容作为fallback
    final textContent = blocks
        .whereType<TextBlock>()
        .map((b) => b.content)
        .join('\n\n');

    return Message(
      id: id,
      role: role,
      content: textContent,
      blocks: blocks,
      createdAt: createdAt ?? DateTime.now(),
      status: status,
    );
  }

  /// 复制消息并更新指定字段
  Message copyWith({
    String? id,
    String? role,
    String? content,
    List<MessageBlock>? blocks,
    DateTime? createdAt,
    String? status,
  }) {
    return Message(
      id: id ?? this.id,
      role: role ?? this.role,
      content: content ?? this.content,
      blocks: blocks ?? this.blocks,
      createdAt: createdAt ?? this.createdAt,
      status: status ?? this.status,
    );
  }
}


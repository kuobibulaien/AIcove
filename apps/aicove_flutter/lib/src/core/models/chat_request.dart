import 'message_block.dart';

/// 聊天请求模型
/// 统一的请求格式，遵循单一职责原则(S)
class ChatRequest {
  /// 用户ID
  final String userId;

  /// 会话ID
  final String sessionId;

  /// 当前消息内容
  final String message;

  /// 消息历史（包含Blocks的完整消息）
  final List<ChatMessage> history;

  /// 是否启用流式响应
  final bool stream;

  /// 温度参数（0-2）
  final double? temperature;

  /// 最大token数
  final int? maxTokens;

  /// Top P参数
  final double? topP;

  /// 工具偏好设置
  final Map<String, dynamic>? toolPreferences;

  const ChatRequest({
    required this.userId,
    required this.sessionId,
    required this.message,
    required this.history,
    this.stream = true,
    this.temperature,
    this.maxTokens,
    this.topP,
    this.toolPreferences,
  });

  Map<String, dynamic> toJson() => {
        'user_id': userId,
        'session_id': sessionId,
        'message': message,
        'history': history.map((m) => m.toJson()).toList(),
        'stream': stream,
        if (temperature != null) 'temperature': temperature,
        if (maxTokens != null) 'max_tokens': maxTokens,
        if (topP != null) 'top_p': topP,
        if (toolPreferences != null) 'tool_preferences': toolPreferences,
      };
}

/// 聊天消息（用于请求历史）
/// 简化版Message，只包含API需要的字段
class ChatMessage {
  final String role; // 'user' | 'assistant' | 'system'
  final List<MessageBlock> blocks;

  const ChatMessage({
    required this.role,
    required this.blocks,
  });

  /// 转换为API格式的JSON
  /// 将blocks转换为OpenAI兼容的content数组
  Map<String, dynamic> toJson() {
    // 如果只有一个文本block，使用简单格式
    if (blocks.length == 1 && blocks.first is TextBlock) {
      return {
        'role': role,
        'content': (blocks.first as TextBlock).content,
      };
    }

    // 多模态格式：content为数组
    final contentParts = <Map<String, dynamic>>[];
    for (final block in blocks) {
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
      // 其他类型的block暂时忽略（可根据需要扩展）
    }

    return {
      'role': role,
      'content': contentParts,
    };
  }

  /// 从旧的Message格式转换（向后兼容）
  factory ChatMessage.fromLegacy(String role, String content) {
    return ChatMessage(
      role: role,
      blocks: [
        TextBlock(
          messageId: 'temp',
          content: content,
        ),
      ],
    );
  }
}

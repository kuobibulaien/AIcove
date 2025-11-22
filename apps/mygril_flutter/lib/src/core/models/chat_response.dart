import 'message_block.dart';

/// 聊天响应模型
/// 统一的响应格式，遵循单一职责原则(S)
class ChatResponse {
  /// 响应的内容块列表
  final List<MessageBlock> blocks;

  /// 使用的Provider ID
  final String providerId;

  /// 使用的模型ID
  final String? modelId;

  /// Token使用情况
  final TokenUsage? usage;

  /// 响应元数据
  final Map<String, dynamic>? metadata;

  const ChatResponse({
    required this.blocks,
    required this.providerId,
    this.modelId,
    this.usage,
    this.metadata,
  });

  /// 获取主要文本内容（向后兼容）
  String get text {
    final textBlocks = blocks.whereType<TextBlock>();
    if (textBlocks.isEmpty) return '';
    return textBlocks.map((b) => b.content).join('\n\n');
  }

  /// 获取思考内容
  String? get thinking {
    final thinkingBlocks = blocks.whereType<ThinkingBlock>();
    if (thinkingBlocks.isEmpty) return null;
    return thinkingBlocks.map((b) => b.content).join('\n\n');
  }

  /// 获取所有图片
  List<ImageBlock> get images {
    return blocks.whereType<ImageBlock>().toList();
  }

  /// 获取所有音频
  List<AudioBlock> get audios {
    return blocks.whereType<AudioBlock>().toList();
  }

  /// 获取TTS音频URL（向后兼容）
  String? get ttsAudioUrl {
    final audioBlocks = audios;
    return audioBlocks.isNotEmpty ? audioBlocks.first.url : null;
  }

  /// 是否有错误
  bool get hasError {
    return blocks.any((block) => block is ErrorBlock);
  }

  /// 获取错误消息
  String? get errorMessage {
    final errorBlocks = blocks.whereType<ErrorBlock>();
    if (errorBlocks.isEmpty) return null;
    return errorBlocks.map((b) => b.message).join('; ');
  }

  factory ChatResponse.fromJson(Map<String, dynamic> json) {
    final blocksJson = json['blocks'] as List<dynamic>?;
    final blocks = blocksJson?.map((b) => MessageBlock.fromJson(b as Map<String, dynamic>)).toList() ?? [];

    return ChatResponse(
      blocks: blocks,
      providerId: json['provider_id'] as String? ?? json['provider'] as String? ?? 'unknown',
      modelId: json['model_id'] as String?,
      usage: json['usage'] != null ? TokenUsage.fromJson(json['usage'] as Map<String, dynamic>) : null,
      metadata: json['metadata'] as Map<String, dynamic>?,
    );
  }

  Map<String, dynamic> toJson() => {
        'blocks': blocks.map((b) => b.toJson()).toList(),
        'provider_id': providerId,
        'model_id': modelId,
        'usage': usage?.toJson(),
        'metadata': metadata,
      };
}

/// Token使用情况
class TokenUsage {
  /// 提示词token数
  final int promptTokens;

  /// 完成token数
  final int completionTokens;

  /// 总token数
  final int totalTokens;

  const TokenUsage({
    required this.promptTokens,
    required this.completionTokens,
    required this.totalTokens,
  });

  factory TokenUsage.fromJson(Map<String, dynamic> json) {
    return TokenUsage(
      promptTokens: json['prompt_tokens'] as int? ?? 0,
      completionTokens: json['completion_tokens'] as int? ?? 0,
      totalTokens: json['total_tokens'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'prompt_tokens': promptTokens,
        'completion_tokens': completionTokens,
        'total_tokens': totalTokens,
      };
}

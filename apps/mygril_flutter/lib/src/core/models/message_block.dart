import 'package:uuid/uuid.dart';
import 'block_type.dart';
import 'block_status.dart';

const _uuid = Uuid();

/// MessageBlock基类
/// 遵循单一职责原则(S)：只负责数据表示，不含业务逻辑
/// 遵循开闭原则(O)：通过继承扩展，无需修改基类
abstract class MessageBlock {
  /// 块的唯一ID
  final String id;

  /// 所属消息的ID
  final String messageId;

  /// 块类型
  final BlockType type;

  /// 块状态
  final BlockStatus status;

  /// 创建时间
  final DateTime createdAt;

  /// 更新时间
  final DateTime? updatedAt;

  /// 使用的模型（可选）
  final String? modelId;

  /// 错误信息（当status为error时）
  final String? errorMessage;

  MessageBlock({
    String? id,
    required this.messageId,
    required this.type,
    this.status = BlockStatus.success,
    DateTime? createdAt,
    this.updatedAt,
    this.modelId,
    this.errorMessage,
  })  : id = id ?? _uuid.v4(),
        createdAt = createdAt ?? DateTime.now();

  /// 转换为JSON（用于序列化）
  Map<String, dynamic> toJson();

  /// 从JSON创建Block（工厂方法）
  static MessageBlock fromJson(Map<String, dynamic> json) {
    final typeStr = json['type'] as String;
    final type = BlockType.values.firstWhere(
      (e) => e.name == typeStr,
      orElse: () => BlockType.unknown,
    );

    switch (type) {
      case BlockType.mainText:
        return TextBlock.fromJson(json);
      case BlockType.thinking:
        return ThinkingBlock.fromJson(json);
      case BlockType.image:
        return ImageBlock.fromJson(json);
      case BlockType.audio:
        return AudioBlock.fromJson(json);
      case BlockType.emoji:
        return EmojiBlock.fromJson(json);
      case BlockType.tool:
        return ToolBlock.fromJson(json);
      case BlockType.code:
        return CodeBlock.fromJson(json);
      case BlockType.file:
        return FileBlock.fromJson(json);
      case BlockType.error:
        return ErrorBlock.fromJson(json);
      default:
        return PlaceholderBlock.fromJson(json);
    }
  }
}

/// 占位Block（未知类型）
class PlaceholderBlock extends MessageBlock {
  PlaceholderBlock({
    String? id,
    required String messageId,
    BlockStatus status = BlockStatus.pending,
  }) : super(
          id: id,
          messageId: messageId,
          type: BlockType.unknown,
          status: status,
        );

  factory PlaceholderBlock.fromJson(Map<String, dynamic> json) {
    return PlaceholderBlock(
      id: json['id'] as String,
      messageId: json['messageId'] as String,
      status: BlockStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => BlockStatus.pending,
      ),
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'messageId': messageId,
        'type': type.name,
        'status': status.name,
        'createdAt': createdAt.toIso8601String(),
      };
}

/// 文本Block
class TextBlock extends MessageBlock {
  /// 文本内容
  final String content;

  TextBlock({
    String? id,
    required String messageId,
    required this.content,
    BlockStatus status = BlockStatus.success,
  }) : super(
          id: id,
          messageId: messageId,
          type: BlockType.mainText,
          status: status,
        );

  factory TextBlock.fromJson(Map<String, dynamic> json) {
    return TextBlock(
      id: json['id'] as String,
      messageId: json['messageId'] as String,
      content: json['content'] as String,
      status: BlockStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => BlockStatus.success,
      ),
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'messageId': messageId,
        'type': type.name,
        'status': status.name,
        'content': content,
        'createdAt': createdAt.toIso8601String(),
      };

  TextBlock copyWith({String? content, BlockStatus? status}) {
    return TextBlock(
      id: id,
      messageId: messageId,
      content: content ?? this.content,
      status: status ?? this.status,
    );
  }
}

/// 思考过程Block（用于Claude/o1等模型）
class ThinkingBlock extends MessageBlock {
  /// 思考内容
  final String content;

  /// 思考耗时（毫秒）
  final int? durationMs;

  ThinkingBlock({
    String? id,
    required String messageId,
    required this.content,
    this.durationMs,
    BlockStatus status = BlockStatus.success,
  }) : super(
          id: id,
          messageId: messageId,
          type: BlockType.thinking,
          status: status,
        );

  factory ThinkingBlock.fromJson(Map<String, dynamic> json) {
    return ThinkingBlock(
      id: json['id'] as String,
      messageId: json['messageId'] as String,
      content: json['content'] as String,
      durationMs: json['durationMs'] as int?,
      status: BlockStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => BlockStatus.success,
      ),
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'messageId': messageId,
        'type': type.name,
        'status': status.name,
        'content': content,
        'durationMs': durationMs,
        'createdAt': createdAt.toIso8601String(),
      };
}

/// 图片Block
class ImageBlock extends MessageBlock {
  /// 图片URL（网络图片或生成的图片）
  final String? url;

  /// 本地文件路径
  final String? localPath;

  /// Base64编码的图片
  final String? base64;

  /// 图片宽度
  final int? width;

  /// 图片高度
  final int? height;

  /// 生成图片的提示词（如果是AI生成）
  final String? prompt;

  ImageBlock({
    String? id,
    required String messageId,
    this.url,
    this.localPath,
    this.base64,
    this.width,
    this.height,
    this.prompt,
    BlockStatus status = BlockStatus.success,
  })  : assert(url != null || localPath != null || base64 != null,
            'At least one of url, localPath, or base64 must be provided'),
        super(
          id: id,
          messageId: messageId,
          type: BlockType.image,
          status: status,
        );

  factory ImageBlock.fromJson(Map<String, dynamic> json) {
    return ImageBlock(
      id: json['id'] as String,
      messageId: json['messageId'] as String,
      url: json['url'] as String?,
      localPath: json['localPath'] as String?,
      base64: json['base64'] as String?,
      width: json['width'] as int?,
      height: json['height'] as int?,
      prompt: json['prompt'] as String?,
      status: BlockStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => BlockStatus.success,
      ),
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'messageId': messageId,
        'type': type.name,
        'status': status.name,
        'url': url,
        'localPath': localPath,
        'base64': base64,
        'width': width,
        'height': height,
        'prompt': prompt,
        'createdAt': createdAt.toIso8601String(),
      };
}

/// 音频Block（TTS生成的语音）
class AudioBlock extends MessageBlock {
  /// 音频URL
  final String url;

  /// 对应的文本内容
  final String? text;

  /// 音频时长（秒）
  final double? durationSeconds;

  AudioBlock({
    String? id,
    required String messageId,
    required this.url,
    this.text,
    this.durationSeconds,
    BlockStatus status = BlockStatus.success,
  }) : super(
          id: id,
          messageId: messageId,
          type: BlockType.audio,
          status: status,
        );

  factory AudioBlock.fromJson(Map<String, dynamic> json) {
    return AudioBlock(
      id: json['id'] as String,
      messageId: json['messageId'] as String,
      url: json['url'] as String,
      text: json['text'] as String?,
      durationSeconds: json['durationSeconds'] as double?,
      status: BlockStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => BlockStatus.success,
      ),
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'messageId': messageId,
        'type': type.name,
        'status': status.name,
        'url': url,
        'text': text,
        'durationSeconds': durationSeconds,
        'createdAt': createdAt.toIso8601String(),
      };
}

/// 工具调用Block
class ToolBlock extends MessageBlock {
  /// 工具名称（如"tts", "web_search"）
  final String toolName;

  /// 工具调用参数
  final Map<String, dynamic>? arguments;

  /// 工具调用结果
  final Map<String, dynamic>? result;

  ToolBlock({
    String? id,
    required String messageId,
    required this.toolName,
    this.arguments,
    this.result,
    BlockStatus status = BlockStatus.success,
  }) : super(
          id: id,
          messageId: messageId,
          type: BlockType.tool,
          status: status,
        );

  factory ToolBlock.fromJson(Map<String, dynamic> json) {
    return ToolBlock(
      id: json['id'] as String,
      messageId: json['messageId'] as String,
      toolName: json['toolName'] as String,
      arguments: json['arguments'] as Map<String, dynamic>?,
      result: json['result'] as Map<String, dynamic>?,
      status: BlockStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => BlockStatus.success,
      ),
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'messageId': messageId,
        'type': type.name,
        'status': status.name,
        'toolName': toolName,
        'arguments': arguments,
        'result': result,
        'createdAt': createdAt.toIso8601String(),
      };
}

/// 代码Block
class CodeBlock extends MessageBlock {
  /// 代码内容
  final String content;

  /// 编程语言
  final String language;

  CodeBlock({
    String? id,
    required String messageId,
    required this.content,
    required this.language,
    BlockStatus status = BlockStatus.success,
  }) : super(
          id: id,
          messageId: messageId,
          type: BlockType.code,
          status: status,
        );

  factory CodeBlock.fromJson(Map<String, dynamic> json) {
    return CodeBlock(
      id: json['id'] as String,
      messageId: json['messageId'] as String,
      content: json['content'] as String,
      language: json['language'] as String,
      status: BlockStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => BlockStatus.success,
      ),
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'messageId': messageId,
        'type': type.name,
        'status': status.name,
        'content': content,
        'language': language,
        'createdAt': createdAt.toIso8601String(),
      };
}

/// 文件Block（用户上传的文档）
class FileBlock extends MessageBlock {
  /// 文件名
  final String fileName;

  /// 文件大小（字节）
  final int fileSize;

  /// 文件类型（MIME类型）
  final String mimeType;

  /// 文件URL或路径
  final String filePath;

  FileBlock({
    String? id,
    required String messageId,
    required this.fileName,
    required this.fileSize,
    required this.mimeType,
    required this.filePath,
    BlockStatus status = BlockStatus.success,
  }) : super(
          id: id,
          messageId: messageId,
          type: BlockType.file,
          status: status,
        );

  factory FileBlock.fromJson(Map<String, dynamic> json) {
    return FileBlock(
      id: json['id'] as String,
      messageId: json['messageId'] as String,
      fileName: json['fileName'] as String,
      fileSize: json['fileSize'] as int,
      mimeType: json['mimeType'] as String,
      filePath: json['filePath'] as String,
      status: BlockStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => BlockStatus.success,
      ),
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'messageId': messageId,
        'type': type.name,
        'status': status.name,
        'fileName': fileName,
        'fileSize': fileSize,
        'mimeType': mimeType,
        'filePath': filePath,
        'createdAt': createdAt.toIso8601String(),
      };
}

/// 表情包Block
class EmojiBlock extends MessageBlock {
  /// 表情包ID
  final String emojiId;

  /// 表情包文件路径（本地路径或URL）
  final String path;

  /// 匹配的标签（用于显示）
  final String? matchedTag;

  /// 原始文本（AI生成的文本）
  final String? originalText;

  EmojiBlock({
    String? id,
    required String messageId,
    required this.emojiId,
    required this.path,
    this.matchedTag,
    this.originalText,
    BlockStatus status = BlockStatus.success,
  }) : super(
          id: id,
          messageId: messageId,
          type: BlockType.emoji,
          status: status,
        );

  factory EmojiBlock.fromJson(Map<String, dynamic> json) {
    return EmojiBlock(
      id: json['id'] as String,
      messageId: json['messageId'] as String,
      emojiId: json['emojiId'] as String,
      path: json['path'] as String,
      matchedTag: json['matchedTag'] as String?,
      originalText: json['originalText'] as String?,
      status: BlockStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => BlockStatus.success,
      ),
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'messageId': messageId,
        'type': type.name,
        'status': status.name,
        'emojiId': emojiId,
        'path': path,
        'matchedTag': matchedTag,
        'originalText': originalText,
        'createdAt': createdAt.toIso8601String(),
      };
}

/// 错误Block
class ErrorBlock extends MessageBlock {
  /// 错误消息
  final String message;

  /// 错误代码
  final String? errorCode;

  ErrorBlock({
    String? id,
    required String messageId,
    required this.message,
    this.errorCode,
  }) : super(
          id: id,
          messageId: messageId,
          type: BlockType.error,
          status: BlockStatus.error,
          errorMessage: message,
        );

  factory ErrorBlock.fromJson(Map<String, dynamic> json) {
    return ErrorBlock(
      id: json['id'] as String,
      messageId: json['messageId'] as String,
      message: json['message'] as String,
      errorCode: json['errorCode'] as String?,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'messageId': messageId,
        'type': type.name,
        'status': status.name,
        'message': message,
        'errorCode': errorCode,
        'createdAt': createdAt.toIso8601String(),
      };
}

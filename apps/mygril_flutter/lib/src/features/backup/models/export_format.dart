/// 导出文件格式定义
/// 基于 docs/备份与同步方案/离线导入导出功能设计.md

/// 当前导出格式版本
const int kExportFormatVersion = 1;

/// 导出文件扩展名
const String kExportFileExtension = '.mygril';

/// 同步范围（Scope）定义
/// 基于 docs/备份与同步方案/同步范围清单.md
class SyncScope {
  static const String chatHistory = 'chat.history';
  static const String characterCards = 'characters.cards';
  static const String characterSettings = 'characters.per_settings';
  static const String providersConfig = 'providers.config';
  static const String providersKeys = 'providers.keys';
  static const String memory = 'memory';
  static const String memoryTrash = 'memory.trash';

  /// 所有可选范围
  static const List<String> allScopes = [
    chatHistory,
    characterCards,
    characterSettings,
    providersConfig,
    providersKeys,
    memory,
  ];

  /// 默认导出范围
  static const List<String> defaultExportScopes = [
    chatHistory,
    characterCards,
  ];

  /// Scope 的中文名称
  static String getDisplayName(String scope) {
    switch (scope) {
      case chatHistory:
        return '聊天记录';
      case characterCards:
        return '角色卡';
      case characterSettings:
        return '角色设置';
      case providersConfig:
        return '模型配置';
      case providersKeys:
        return '模型密钥';
      case memory:
        return '角色记忆';
      default:
        return scope;
    }
  }

  /// Scope 的描述
  static String getDescription(String scope) {
    switch (scope) {
      case chatHistory:
        return '所有聊天消息（含图片、语音等）';
      case characterCards:
        return '头像、人设、称呼、立绘等';
      case characterSettings:
        return '置顶、收藏、免打扰等设置';
      case providersConfig:
        return 'API 地址、模型列表等';
      case providersKeys:
        return 'API Key（敏感数据）';
      case memory:
        return 'AI 记住的内容';
      default:
        return '';
    }
  }
}

/// 导出选项
class ExportOptions {
  /// 要导出的范围
  final List<String> scopes;

  /// 是否包含图片
  final bool includeImages;

  /// 是否包含语音
  final bool includeAudio;

  /// 是否包含视频
  final bool includeVideo;

  const ExportOptions({
    this.scopes = const [SyncScope.chatHistory, SyncScope.characterCards],
    this.includeImages = true,
    this.includeAudio = true,
    this.includeVideo = true,
  });

  ExportOptions copyWith({
    List<String>? scopes,
    bool? includeImages,
    bool? includeAudio,
    bool? includeVideo,
  }) {
    return ExportOptions(
      scopes: scopes ?? this.scopes,
      includeImages: includeImages ?? this.includeImages,
      includeAudio: includeAudio ?? this.includeAudio,
      includeVideo: includeVideo ?? this.includeVideo,
    );
  }
}

/// 导出进度
class ExportProgress {
  final ExportPhase phase;
  final double progress; // 0.0 - 1.0
  final String? currentFile;
  final String? message;

  const ExportProgress(
    this.phase,
    this.progress, {
    this.currentFile,
    this.message,
  });
}

/// 导出阶段
enum ExportPhase {
  preparing, // 准备中
  queryingData, // 查询数据
  copyingFiles, // 复制文件
  packaging, // 打包
  done, // 完成
  error, // 出错
}

/// 导出结果
class ExportResult {
  final String filePath;
  final String fileName;
  final int conversationCount;
  final int messageCount;
  final int fileCount;
  final int sizeBytes;

  const ExportResult({
    required this.filePath,
    required this.fileName,
    required this.conversationCount,
    required this.messageCount,
    required this.fileCount,
    required this.sizeBytes,
  });
}

/// 导入模式
enum ImportMode {
  create, // 新建角色
  merge, // 合并到已有
  replace, // 覆盖已有（危险）
}

/// 导入预览
class ImportPreview {
  final int formatVersion;
  final String appVersion;
  final DateTime exportTime;
  final String? exportDevice;
  final List<ConversationPreview> conversations;
  final List<String> includedScopes;
  final bool isCompatible;
  final String? incompatibleReason;

  const ImportPreview({
    required this.formatVersion,
    required this.appVersion,
    required this.exportTime,
    this.exportDevice,
    required this.conversations,
    required this.includedScopes,
    this.isCompatible = true,
    this.incompatibleReason,
  });

  int get totalMessageCount =>
      conversations.fold(0, (sum, c) => sum + c.messageCount);

  int get totalImageCount =>
      conversations.fold(0, (sum, c) => sum + c.imageCount);

  int get totalAudioCount =>
      conversations.fold(0, (sum, c) => sum + c.audioCount);
}

/// 单个会话的预览信息
class ConversationPreview {
  final String id;
  final String displayName;
  final String? avatarPath;
  final int messageCount;
  final int imageCount;
  final int audioCount;
  final DateTime? lastMessageTime;

  const ConversationPreview({
    required this.id,
    required this.displayName,
    this.avatarPath,
    required this.messageCount,
    this.imageCount = 0,
    this.audioCount = 0,
    this.lastMessageTime,
  });
}

/// 导入进度
class ImportProgress {
  final ImportPhase phase;
  final double progress;
  final String? currentItem;
  final String? message;

  const ImportProgress(
    this.phase,
    this.progress, {
    this.currentItem,
    this.message,
  });
}

/// 导入阶段
enum ImportPhase {
  extracting, // 解压中
  validating, // 验证格式
  importing, // 导入数据
  copyingFiles, // 复制文件
  done, // 完成
  error, // 出错
}

/// 导入结果
class ImportResult {
  final List<String> conversationIds;
  final int messagesImported;
  final int filesImported;
  final int skipped;
  final List<ImportConflict> conflicts;

  const ImportResult({
    required this.conversationIds,
    required this.messagesImported,
    required this.filesImported,
    this.skipped = 0,
    this.conflicts = const [],
  });
}

/// 导入冲突
class ImportConflict {
  final String type; // 'conversation', 'message', etc.
  final String id;
  final String name;
  final ImportConflictResolution? resolution;

  const ImportConflict({
    required this.type,
    required this.id,
    required this.name,
    this.resolution,
  });

  ImportConflict copyWith({ImportConflictResolution? resolution}) {
    return ImportConflict(
      type: type,
      id: id,
      name: name,
      resolution: resolution ?? this.resolution,
    );
  }
}

/// 冲突解决方式
enum ImportConflictResolution {
  skip, // 跳过
  merge, // 合并
  createNew, // 新建副本
  replace, // 覆盖（危险）
}

/// Manifest 文件结构
class ExportManifest {
  final int formatVersion;
  final String appVersion;
  final String appName;
  final DateTime exportTime;
  final String? exportDevice;
  final List<String> includedScopes;
  final int conversationCount;
  final int messageCount;
  final int fileCount;
  final int? totalSizeBytes;
  final String? checksum;

  const ExportManifest({
    required this.formatVersion,
    required this.appVersion,
    this.appName = 'MyGril',
    required this.exportTime,
    this.exportDevice,
    required this.includedScopes,
    required this.conversationCount,
    required this.messageCount,
    required this.fileCount,
    this.totalSizeBytes,
    this.checksum,
  });

  Map<String, dynamic> toJson() => {
        'format_version': formatVersion,
        'app_version': appVersion,
        'app_name': appName,
        'export_time': exportTime.toIso8601String(),
        'export_device': exportDevice,
        'included_scopes': includedScopes,
        'conversation_count': conversationCount,
        'message_count': messageCount,
        'file_count': fileCount,
        'total_size_bytes': totalSizeBytes,
        'checksum': checksum,
      };

  factory ExportManifest.fromJson(Map<String, dynamic> json) {
    return ExportManifest(
      formatVersion: json['format_version'] as int,
      appVersion: json['app_version'] as String,
      appName: json['app_name'] as String? ?? 'MyGril',
      exportTime: DateTime.parse(json['export_time'] as String),
      exportDevice: json['export_device'] as String?,
      includedScopes: (json['included_scopes'] as List<dynamic>?)
              ?.cast<String>() ??
          [],
      conversationCount: json['conversation_count'] as int? ?? 0,
      messageCount: json['message_count'] as int? ?? 0,
      fileCount: json['file_count'] as int? ?? 0,
      totalSizeBytes: json['total_size_bytes'] as int?,
      checksum: json['checksum'] as String?,
    );
  }
}

import '../../../../core/api_logger.dart' show ApiLogEntry;
import '../../../../core/app_logger.dart' show LogLevel;

/// 统一的日志条目（合并 API 日志和系统日志）
class UnifiedLogEntry {
  final DateTime time;
  final String title; // 简短标题（一行显示）
  final String? extraContent; // 额外内容（metadata 等，不重复标题）
  final String fullContent; // 完整内容（用于复制）
  final LogLevel? level;
  final bool isApiLog;
  final bool isConversation; // 是否为 AI 对话日志

  /// AI 原始回复（完整）
  final String? rawAiResponse;

  /// AI 收到的原始上下文（完整）
  final String? rawContext;

  UnifiedLogEntry({
    required this.time,
    required this.title,
    this.extraContent,
    required this.fullContent,
    this.level,
    this.isApiLog = false,
    this.isConversation = false,
    this.rawAiResponse,
    this.rawContext,
  });

  /// 是否需要折叠（有额外内容才需要）
  bool get needsFold => extraContent != null && extraContent!.isNotEmpty;
}

/// 对话中的单轮请求/工具记录
class ConversationRoundLog {
  final int roundIndex;
  final ApiLogEntry? requestLog;
  final ApiLogEntry? toolLog;

  const ConversationRoundLog({
    required this.roundIndex,
    this.requestLog,
    this.toolLog,
  });
}

/// 一次完整的对话 Turn（可含多轮）
class ConversationTurnLog {
  final String turnKey;
  final String? sessionId;
  final String? turnId;
  final DateTime startedAt;
  final List<ConversationRoundLog> rounds;
  final ApiLogEntry? finalLog;

  const ConversationTurnLog({
    required this.turnKey,
    required this.sessionId,
    required this.turnId,
    required this.startedAt,
    required this.rounds,
    this.finalLog,
  });
}

/// 日志类型筛选选项
enum LogTypeFilter {
  all('全部'),
  conversation('对话'),
  api('API'),
  system('系统');

  const LogTypeFilter(this.label);
  final String label;
}

/// 日志级别筛选选项
enum LogLevelFilter {
  all('全部', null),
  info('INFO+', LogLevel.info),
  warning('WARNING+', LogLevel.warning),
  error('ERROR+', LogLevel.error);

  const LogLevelFilter(this.label, this.minLevel);
  final String label;
  final LogLevel? minLevel;
}

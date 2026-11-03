import '../../../core/utils/message_formatter.dart';

/// 聊天样式（ADR0047）：气泡为聊天软件式分段气泡，文档为不分段的全宽富文本。
enum ChatDisplayStyle {
  bubble,
  document;

  static ChatDisplayStyle? fromValue(String? value) =>
      ChatDisplayStyle.values.where((style) => style.name == value).firstOrNull;
}

/// 一个联系人是否分段；null 跟随全局默认。分段标点与句末标点全局共用。
class ChatChunkOverride {
  const ChatChunkOverride({this.enableChunking});

  static const none = ChatChunkOverride();

  final bool? enableChunking;

  /// [config] 叠加这里的设置。
  MessageFormatConfig applyTo(MessageFormatConfig config) =>
      enableChunking == null
      ? config
      : config.copyWith(enableChunking: enableChunking);

  @override
  bool operator ==(Object other) =>
      other is ChatChunkOverride && other.enableChunking == enableChunking;

  @override
  int get hashCode => enableChunking.hashCode;
}

/// 一个会话实际生效的显示策略：全局默认样式与分段叠加会话覆盖。
///
/// 流式交付与聊天列表只读这里的 [effectiveFormatConfig]，不各自判断样式；
/// 文档模式强制不分段，用户的分段偏好保留在配置里，切回气泡即恢复。
class ChatDisplayPolicy {
  const ChatDisplayPolicy._(this.style, this.effectiveFormatConfig);

  factory ChatDisplayPolicy.resolve({
    required MessageFormatConfig formatConfig,
    required ChatDisplayStyle globalStyle,
    ChatDisplayStyle? conversationStyle,
    ChatChunkOverride chunkOverride = ChatChunkOverride.none,
  }) {
    final style = conversationStyle ?? globalStyle;
    final config = chunkOverride.applyTo(formatConfig);
    return ChatDisplayPolicy._(
      style,
      style == ChatDisplayStyle.document && config.enableChunking
          ? config.copyWith(enableChunking: false)
          : config,
    );
  }

  final ChatDisplayStyle style;
  final MessageFormatConfig effectiveFormatConfig;

  @override
  bool operator ==(Object other) =>
      other is ChatDisplayPolicy &&
      other.style == style &&
      other.effectiveFormatConfig == effectiveFormatConfig;

  @override
  int get hashCode => Object.hash(style, effectiveFormatConfig);
}

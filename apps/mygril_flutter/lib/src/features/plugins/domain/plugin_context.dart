/// 插件上下文
/// 提供给插件 Handler 使用，包含当前环境信息和操作能力
class PluginContext {
  // ========== 环境信息 ==========
  
  /// 当前对话 ID
  final String conversationId;
  
  /// 发送者信息 (可选，若无法获取则为空)
  final String? userId; 
  final String? userName;

  // ========== 主动能力 (Actions) ==========
  
  /// 发送文本消息
  final Future<void> Function(String text) sendText;
  
  /// 发送图片消息
  final Future<void> Function(String imagePath) sendImage;
  
  /// 发送错误提示 (Toast)
  final Future<void> Function(String message) showToast;

  PluginContext({
    required this.conversationId,
    this.userId,
    this.userName,
    required this.sendText,
    required this.sendImage,
    required this.showToast,
  });
}

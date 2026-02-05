import '../plugin_context.dart';

/// 命令处理器
/// 用于处理用户输入的命令（如 /tts 你好）
class CommandHandler {
  /// 命令名称（如 "/tts"）
  final String command;

  /// 命令别名（如 {"/语音", "/speak"}）
  final Set<String> alias;

  /// 命令描述
  final String description;

  /// 命令处理函数
  /// 参数：
  /// - context: 插件上下文，包含环境信息和操作能力
  /// - args: 命令后面的参数列表（如 /tts 你好 → ['你好']）
  /// 返回：命令执行结果（会展示给用户）
  final Future<String> Function(PluginContext context, List<String> args) handler;

  const CommandHandler({
    required this.command,
    this.alias = const {},
    required this.description,
    required this.handler,
  });

  /// 检查给定的输入是否匹配此命令
  bool matches(String input) {
    final normalizedInput = input.trim().toLowerCase();
    final normalizedCommand = command.toLowerCase();
    
    // 检查主命令
    if (normalizedInput.startsWith(normalizedCommand)) {
      return true;
    }
    
    // 检查别名
    for (final a in alias) {
      if (normalizedInput.startsWith(a.toLowerCase())) {
        return true;
      }
    }
    
    return false;
  }

  /// 解析命令参数
  List<String> parseArgs(String input) {
    final trimmed = input.trim();
    
    // 找到命令结束位置
    int commandEnd = command.length;
    for (final a in alias) {
      if (trimmed.toLowerCase().startsWith(a.toLowerCase())) {
        commandEnd = a.length;
        break;
      }
    }
    
    // 提取参数部分
    final argsStr = trimmed.substring(commandEnd).trim();
    if (argsStr.isEmpty) return [];
    
    // 简单按空格分割（后续可以支持引号等复杂解析）
    return argsStr.split(RegExp(r'\s+'));
  }
}

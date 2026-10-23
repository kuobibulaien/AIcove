/// 角色的工作模式（ADR0097）。
///
/// - [chat]：聊天模式。聊天模型只拿到派活工具 `delegate_task`，上网搜索、
///   MCP、读写工作区交给后台杂活助手去办。
/// - [tool]：工具模式。角色本身就是完整 Agent，直接使用全部已开启的插件工具，
///   不派活。
enum RoleAgentMode {
  chat,
  tool;

  static RoleAgentMode? fromValue(String? value) =>
      RoleAgentMode.values.where((mode) => mode.name == value).firstOrNull;
}

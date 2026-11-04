/// 角色工作模式：纯聊天、直接使用工具、或派活给后台子 Agent。
enum RoleAgentMode {
  chat,
  tool,
  agent;

  static RoleAgentMode? fromValue(String? value) =>
      RoleAgentMode.values.where((mode) => mode.name == value).firstOrNull;
}

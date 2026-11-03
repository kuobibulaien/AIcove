import '../domain/handlers/tool_output.dart';
import 'mcp_connector.dart';

/// MCP 调用失败（网络、HTTP 状态、JSON-RPC 错误或响应格式不对）。
class McpException implements Exception {
  const McpException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// initialize＋tools/list 的结果。
class McpServerSnapshot {
  const McpServerSnapshot({required this.serverName, required this.tools});

  final String serverName;
  final List<McpToolInfo> tools;
}

/// tools/call 的结果，已压平成可回给模型的文本。
class McpToolCallResult {
  const McpToolCallResult({
    required this.text,
    required this.isError,
    this.output,
  });

  final String text;
  final bool isError;
  final ToolOutput? output;
}

/// MCP 工具能力；传输实现自行管理会话和资源。
abstract interface class McpClientPort {
  Future<McpServerSnapshot> listTools();
  Future<McpToolCallResult> callTool(
    String name,
    Map<String, dynamic> arguments,
  );
  void close();
}

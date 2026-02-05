/// Function Calling 集成示例
/// 
/// 展示如何在发送 AI 请求时集成插件提供的工具
/// 
/// 使用场景：
/// 1. 在 ChatActions.send() 中集成
/// 2. 收集所有插件的 AITool
/// 3. 转换为 LLM 格式并添加到请求
/// 4. 处理 AI 的工具调用响应
/// 
/// ```dart
/// // 在 chat_actions.dart 中使用：
/// 
/// import '../ai_tools/ai_tool_collector.dart';
/// import '../ai_tools/llm_hook_manager.dart';
/// 
/// // 1. 初始化工具收集器和钩子管理器
/// final toolCollector = AIToolCollector(pluginManager);
/// final hookManager = LLMHookManager(pluginManager);
/// 
/// // 2. 构建请求上下文
/// final requestContext = LLMRequestContext(
///   systemPrompt: await pluginManager.getSystemPrompts(userMessage: message),
///   messages: conversationHistory,
/// );
/// 
/// // 3. 收集工具（如果 LLM 支持）
/// if (supportsTools) {
///   final tools = toolCollector.toFormat(AIProvider.openai); // 或 anthropic
///   requestContext.setTools(tools);
/// }
/// 
/// // 4. 触发请求前钩子
/// await hookManager.triggerBeforeRequest(requestContext);
/// 
/// // 5. 发送请求
/// final response = await llmClient.sendMessage(
///   systemPrompt: requestContext.systemPrompt,
///   messages: requestContext.messages,
///   tools: requestContext.tools,
/// );
/// 
/// // 6. 处理工具调用
/// if (response.toolCalls != null && response.toolCalls!.isNotEmpty) {
///   final requests = response.toolCalls!.map((call) {
///     return ToolCallRequest.fromOpenAI(call); // 或 fromAnthropic
///   }).toList();
///   
///   final results = await toolCollector.executeTools(requests);
///   
///   // 7. 将工具结果添加到对话历史
///   for (final result in results) {
///     requestContext.addMessage(result.toOpenAIMessage()); // 或 toAnthropicResult
///   }
///   
///   // 8. 重新发送请求（让 AI 根据工具结果继续生成）
///   final finalResponse = await llmClient.sendMessage(
///     systemPrompt: requestContext.systemPrompt,
///     messages: requestContext.messages,
///   );
///   
///   response = finalResponse;
/// }
/// 
/// // 9. 触发响应后钩子
/// final responseContext = LLMResponseContext(
///   text: response.text,
///   toolCalls: response.toolCalls,
/// );
/// await hookManager.triggerAfterResponse(responseContext);
/// 
/// // 10. 处理响应（现有逻辑）
/// final processResult = await pluginManager.processResponse(response.text);
/// ```
/// 
/// ## 关键点说明
/// 
/// ### 1. 工具格式转换
/// - OpenAI 使用 `tools` 参数，格式见 `AITool.toOpenAISchema()`
/// - Anthropic 使用 `tools` 参数，格式见 `AITool.toAnthropicSchema()`
/// - 根据实际使用的 LLM 提供商选择对应格式
/// 
/// ### 2. 工具调用流程
/// ```
/// 用户消息 → 收集工具 → 发送请求 
///   ↓
/// AI 决定调用工具 → 返回 tool_calls
///   ↓
/// 执行工具 → 获取结果 → 添加到对话
///   ↓
/// 再次发送请求 → AI 根据工具结果生成最终回复
/// ```
/// 
/// ### 3. 错误处理
/// - 单个工具执行失败不影响其他工具
/// - 工具调用失败会返回错误信息给 AI
/// - AI 可以根据错误信息调整策略
/// 
/// ### 4. 钩子触发时机
/// - `beforeRequest`: 在发送 LLM 请求前
/// - `afterResponse`: 在收到 LLM 响应后
/// - 钩子可以修改请求内容（如注入时间、天气等上下文）
/// 
/// ## 插件示例
/// 
/// ### 定义一个搜索工具
/// ```dart
/// class SearchPlugin extends BasePlugin {
///   @override
///   List<AITool> getTools() => [
///     AITool(
///       name: 'search_web',
///       description: '搜索互联网获取实时信息',
///       parameters: {
///         'query': ToolParameter(
///           type: 'string',
///           description: '搜索关键词',
///           required: true,
///         ),
///       },
///       handler: (args) async {
///         final query = args['query'] as String;
///         final results = await _searchService.search(query);
///         return results.join('\n');
///       },
///     ),
///   ];
/// }
/// ```
/// 
/// ### 定义一个时间注入钩子
/// ```dart
/// class TimePlugin extends BasePlugin {
///   @override
///   List<LLMHook> getHooks() => [
///     LLMHook(
///       type: LLMHookType.beforeRequest,
///       handler: (context) async {
///         if (context is LLMRequestContext) {
///           final now = DateTime.now();
///           final timeInfo = '当前时间: ${now.year}-${now.month}-${now.day} ${now.hour}:${now.minute}';
///           context.appendSystemPrompt(timeInfo);
///         }
///       },
///     ),
///   ];
/// }
/// ```

void main() {
  // 此文件仅作为文档示例，不需要执行
}

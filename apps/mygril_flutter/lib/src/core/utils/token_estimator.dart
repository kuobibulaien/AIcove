/// Token 估算与上下文截断工具
///
/// 参考 ChatGPT-Next-Web 的字符估算算法 + LibreChat 的滑动窗口截断策略。
///
/// 核心思路：
/// - 不引入外部 tokenizer 库，用字符比例估算 token 数（KISS 原则）
/// - 从最新消息逆向收集，超出限制就停止（保留最近的对话上下文）
/// - 始终保留 system 提示词
///
/// 参考来源：
/// - ChatGPT-Next-Web: app/utils/token.ts (estimateTokenLength)
/// - LibreChat: api/app/clients/BaseClient.js (getMessagesWithinTokenLimit)
library;

import '../app_logger.dart';

/// 估算文本的 token 数量
///
/// 算法来自 ChatGPT-Next-Web，基于字符类型的加权估算：
/// - ASCII 字母: ~0.25 token（约 4 字符 = 1 token）
/// - 其他 ASCII（数字、标点等）: ~0.5 token
/// - Unicode 字符（中文、日文等）: ~1.5 token
int estimateTokenCount(String text) {
  double tokens = 0;
  for (int i = 0; i < text.length; i++) {
    final code = text.codeUnitAt(i);
    if (code < 128) {
      // ASCII
      if ((code >= 65 && code <= 90) || (code >= 97 && code <= 122)) {
        tokens += 0.25; // 字母
      } else {
        tokens += 0.5; // 数字、标点、空格等
      }
    } else {
      // 中文、日文、emoji 等
      tokens += 1.5;
    }
  }
  return tokens.ceil();
}

/// 估算单条消息的 token 数
///
/// 每条消息额外计算 4 token 的消息格式开销（role 标签等）
/// 参考 OpenAI 的 token 计算规则
int estimateMessageTokens(Map<String, dynamic> message) {
  const messageOverhead = 4; // 每条消息的格式开销
  final content = message['content'];
  if (content is String) {
    return estimateTokenCount(content) + messageOverhead;
  }
  if (content is List) {
    // 多模态消息：累加每个 part 的 token
    int total = messageOverhead;
    for (final part in content) {
      if (part is Map<String, dynamic>) {
        final text = (part['text'] ?? '') as String;
        if (text.isNotEmpty) {
          total += estimateTokenCount(text);
        }
        // 图片按固定 token 估算（OpenAI 标准: 低分辨率 85 token）
        if (part['type'] == 'image_url') {
          total += 85;
        }
      }
    }
    return total;
  }
  return messageOverhead;
}

/// 对已构建好的请求消息列表做 token 截断
///
/// 策略（参考 LibreChat）：
/// 1. 始终保留第一条 system 消息
/// 2. 从最新消息逆向收集，直到 token 累计达到上限
/// 3. 为模型回复预留 reserveTokens 的空间
///
/// [messages] 已组装好的请求消息列表（第一条可能是 system）
/// [maxContextTokens] 模型的最大上下文长度（token）
/// [reserveTokens] 为回复预留的 token 数
///
/// 返回截断后的消息列表
List<Map<String, dynamic>> truncateMessagesToFit({
  required List<Map<String, dynamic>> messages,
  required int maxContextTokens,
  int reserveTokens = 1024,
}) {
  if (messages.isEmpty) return messages;

  final availableTokens = maxContextTokens - reserveTokens;
  if (availableTokens <= 0) return messages; // 配置异常，不截断

  // 分离 system 消息和聊天消息
  final systemMessages = <Map<String, dynamic>>[];
  final chatMessages = <Map<String, dynamic>>[];

  for (final msg in messages) {
    if (msg['role'] == 'system') {
      systemMessages.add(msg);
    } else {
      chatMessages.add(msg);
    }
  }

  // 计算 system 提示词占用的 token
  int systemTokens = 0;
  for (final sysMsg in systemMessages) {
    systemTokens += estimateMessageTokens(sysMsg);
  }

  // 剩余可用于聊天消息的 token
  final chatBudget = availableTokens - systemTokens;
  if (chatBudget <= 0) {
    // system 提示词本身就超限了，只保留 system（极端情况）
    AppLogger.warning('TokenEstimator', '系统提示词已超出上下文限制', metadata: {
      'systemTokens': systemTokens,
      'availableTokens': availableTokens,
    });
    return systemMessages;
  }

  // 从最新消息逆向收集（LibreChat 策略）
  final kept = <Map<String, dynamic>>[];
  int usedTokens = 0;

  for (int i = chatMessages.length - 1; i >= 0; i--) {
    final msgTokens = estimateMessageTokens(chatMessages[i]);
    if (usedTokens + msgTokens > chatBudget) {
      break; // 超限，停止收集
    }
    kept.insert(0, chatMessages[i]); // 插入到头部，保持原始顺序
    usedTokens += msgTokens;
  }

  final truncatedCount = chatMessages.length - kept.length;
  if (truncatedCount > 0) {
    AppLogger.info('TokenEstimator', '上下文截断', metadata: {
      'original': chatMessages.length,
      'kept': kept.length,
      'truncated': truncatedCount,
      'systemTokens': systemTokens,
      'chatTokens': usedTokens,
      'totalTokens': systemTokens + usedTokens,
      'maxContext': maxContextTokens,
    });
  }

  // 重新组装：system 消息 + 保留的聊天消息
  return [...systemMessages, ...kept];
}

/// 常见模型的上下文长度映射（token）
///
/// 参考 SillyTavern 的预定义常量
const Map<String, int> knownModelContextLimits = {
  // OpenAI
  'gpt-3.5-turbo': 4096,
  'gpt-3.5-turbo-16k': 16384,
  'gpt-4': 8192,
  'gpt-4-32k': 32768,
  'gpt-4-turbo': 128000,
  'gpt-4o': 128000,
  'gpt-4o-mini': 128000,
  'o1': 200000,
  'o1-mini': 128000,
  'o1-pro': 200000,
  'o3-mini': 200000,

  // Claude
  'claude-3-opus': 200000,
  'claude-3-sonnet': 200000,
  'claude-3-haiku': 200000,
  'claude-3.5-sonnet': 200000,
  'claude-3.5-haiku': 200000,
  'claude-4-sonnet': 200000,

  // DeepSeek
  'deepseek-chat': 65536,
  'deepseek-coder': 65536,
  'deepseek-reasoner': 65536,

  // Google Gemini
  'gemini-pro': 32768,
  'gemini-1.5-pro': 1048576,
  'gemini-1.5-flash': 1048576,
  'gemini-2.0-flash': 1048576,

  // Qwen
  'qwen-turbo': 131072,
  'qwen-plus': 131072,
  'qwen-max': 32768,

  // Llama
  'llama-3.1-8b': 131072,
  'llama-3.1-70b': 131072,
  'llama-3.1-405b': 131072,
};

/// 根据模型名称获取上下文长度限制
///
/// 支持模糊匹配（如 "gpt-4o-2024-05-13" 会匹配到 "gpt-4o"）
/// 找不到时返回默认值 32768（保守估计）
int getModelContextLimit(String modelName) {
  const defaultLimit = 32768; // 保守默认值

  // 精确匹配
  if (knownModelContextLimits.containsKey(modelName)) {
    return knownModelContextLimits[modelName]!;
  }

  // 模糊匹配：按从长到短的 key 排序，找到第一个前缀匹配
  final lower = modelName.toLowerCase();
  for (final entry in knownModelContextLimits.entries) {
    if (lower.contains(entry.key.toLowerCase())) {
      return entry.value;
    }
  }

  return defaultLimit;
}

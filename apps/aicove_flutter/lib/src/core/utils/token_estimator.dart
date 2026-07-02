library;

import '../app_logger.dart';

/// Estimate token count by character classes.
int estimateTokenCount(String text) {
  double tokens = 0;
  for (int i = 0; i < text.length; i++) {
    final code = text.codeUnitAt(i);
    if (code < 128) {
      if ((code >= 65 && code <= 90) || (code >= 97 && code <= 122)) {
        tokens += 0.25; // ASCII letters
      } else {
        tokens += 0.5; // numbers, punctuation, spaces
      }
    } else {
      tokens += 1.5; // CJK / emoji / other unicode
    }
  }
  return tokens.ceil();
}

/// Estimate token count of one chat message.
int estimateMessageTokens(Map<String, dynamic> message) {
  const messageOverhead = 4;
  final content = message['content'];

  if (content is String) {
    return estimateTokenCount(content) + messageOverhead;
  }

  if (content is List) {
    int total = messageOverhead;
    for (final part in content) {
      if (part is Map<String, dynamic>) {
        final text = (part['text'] ?? '') as String;
        if (text.isNotEmpty) {
          total += estimateTokenCount(text);
        }
        if (part['type'] == 'image_url') {
          total += 85;
        }
      }
    }
    return total;
  }

  return messageOverhead;
}

/// Truncate request messages to fit context window.
List<Map<String, dynamic>> truncateMessagesToFit({
  required List<Map<String, dynamic>> messages,
  required int maxContextTokens,
  int reserveTokens = 1024,
}) {
  if (messages.isEmpty) return messages;

  final availableTokens = maxContextTokens - reserveTokens;
  if (availableTokens <= 0) return messages;

  final systemMessages = <Map<String, dynamic>>[];
  final chatMessages = <Map<String, dynamic>>[];

  for (final msg in messages) {
    if (msg['role'] == 'system') {
      systemMessages.add(msg);
    } else {
      chatMessages.add(msg);
    }
  }

  int systemTokens = 0;
  for (final sysMsg in systemMessages) {
    systemTokens += estimateMessageTokens(sysMsg);
  }

  final chatBudget = availableTokens - systemTokens;
  if (chatBudget <= 0) {
    AppLogger.warning('TokenEstimator', 'System prompt exceeds context budget',
        metadata: {
          'systemTokens': systemTokens,
          'availableTokens': availableTokens,
        });
    return systemMessages;
  }

  final kept = <Map<String, dynamic>>[];
  int usedTokens = 0;

  for (int i = chatMessages.length - 1; i >= 0; i--) {
    final msgTokens = estimateMessageTokens(chatMessages[i]);
    if (usedTokens + msgTokens > chatBudget) {
      break;
    }
    kept.insert(0, chatMessages[i]);
    usedTokens += msgTokens;
  }

  final truncatedCount = chatMessages.length - kept.length;
  if (truncatedCount > 0) {
    AppLogger.info('TokenEstimator', 'Context truncated', metadata: {
      'original': chatMessages.length,
      'kept': kept.length,
      'truncated': truncatedCount,
      'systemTokens': systemTokens,
      'chatTokens': usedTokens,
      'totalTokens': systemTokens + usedTokens,
      'maxContext': maxContextTokens,
    });
  }

  final keptWithoutOrphanTools = _dropOrphanToolMessages(kept);
  final orphanToolCount = kept.length - keptWithoutOrphanTools.length;
  if (orphanToolCount > 0) {
    AppLogger.warning('TokenEstimator', 'Removed orphan tool messages',
        metadata: {
          'orphanToolCount': orphanToolCount,
          'keptBefore': kept.length,
          'keptAfter': keptWithoutOrphanTools.length,
        });
  }

  return [...systemMessages, ...keptWithoutOrphanTools];
}

List<Map<String, dynamic>> _dropOrphanToolMessages(
  List<Map<String, dynamic>> messages,
) {
  if (messages.isEmpty) return messages;

  final kept = <Map<String, dynamic>>[];
  for (final message in messages) {
    final role = (message['role'] ?? '').toString();
    if (role != 'tool' && role != 'function') {
      kept.add(message);
      continue;
    }

    if (_hasMatchingAssistantToolCall(
      previousMessages: kept,
      toolMessage: message,
    )) {
      kept.add(message);
    }
  }
  return kept;
}

bool _hasMatchingAssistantToolCall({
  required List<Map<String, dynamic>> previousMessages,
  required Map<String, dynamic> toolMessage,
}) {
  final toolCallId = (toolMessage['tool_call_id'] ?? '').toString().trim();
  final toolName = (toolMessage['name'] ?? '').toString().trim();

  for (var i = previousMessages.length - 1; i >= 0; i--) {
    final candidate = previousMessages[i];
    if ((candidate['role'] ?? '').toString() != 'assistant') {
      continue;
    }

    final toolCalls = candidate['tool_calls'];
    if (toolCalls is List && toolCalls.isNotEmpty) {
      if (toolCallId.isEmpty) {
        return true;
      }

      for (final call in toolCalls) {
        if (call is! Map) continue;
        final id = (call['id'] ?? '').toString().trim();
        if (id.isNotEmpty && id == toolCallId) {
          return true;
        }
      }
    }

    final functionCall = candidate['function_call'];
    if (functionCall is Map) {
      if (toolName.isEmpty) {
        return true;
      }
      final name = (functionCall['name'] ?? '').toString().trim();
      if (name.isNotEmpty && name == toolName) {
        return true;
      }
    }
  }

  return false;
}

const Map<String, int> knownModelContextLimits = {
  // OpenAI — legacy
  'gpt-3.5-turbo': 16384,
  'gpt-3.5-turbo-16k': 16384,
  'gpt-4': 8192,
  'gpt-4-32k': 32768,
  'gpt-4-turbo': 128000,
  'gpt-4o': 128000,
  'gpt-4o-mini': 128000,
  // OpenAI — current gen
  'gpt-4.1': 1000000,
  'gpt-4.1-mini': 1000000,
  'gpt-4.1-nano': 1000000,
  'gpt-5': 400000,
  'gpt-5.2': 400000,
  'gpt-5.4': 1000000,
  'gpt-5-nano': 400000,
  'o1': 200000,
  'o1-mini': 128000,
  'o1-pro': 200000,
  'o3': 200000,
  'o3-mini': 200000,
  'o4-mini': 200000,

  // Claude
  'claude-3-opus': 200000,
  'claude-3-sonnet': 200000,
  'claude-3-haiku': 200000,
  'claude-3.5-sonnet': 200000,
  'claude-3.5-haiku': 200000,
  'claude-4-sonnet': 200000,
  'claude-4-opus': 200000,
  'claude-sonnet-4': 200000,
  'claude-opus-4': 200000,
  'claude-haiku-4.5': 200000,
  'claude-sonnet-4.5': 200000,
  'claude-sonnet-4.6': 200000,
  'claude-opus-4.6': 200000,

  // DeepSeek
  'deepseek-chat': 128000,
  'deepseek-coder': 128000,
  'deepseek-reasoner': 128000,
  'deepseek-r1': 128000,
  'deepseek-v3': 128000,

  // Z.AI GLM
  'glm-5': 200000,
  'glm-5-turbo': 200000,
  'glm-4.7': 200000,
  'glm-4.7-flash': 200000,
  'glm-4.7-flashx': 200000,
  'glm-4.6': 200000,
  'glm-4.5': 128000,
  'glm-4.5-air': 128000,
  'glm-4.5-x': 128000,
  'glm-4.5-airx': 128000,
  'glm-4.5-flash': 128000,

  // Google Gemini
  'gemini-pro': 32768,
  'gemini-1.5-pro': 1048576,
  'gemini-1.5-flash': 1048576,
  'gemini-2.0-flash': 1048576,
  'gemini-2.5-pro': 1048576,
  'gemini-2.5-flash': 1048576,

  // Qwen
  'qwen-turbo': 131072,
  'qwen-plus': 131072,
  'qwen-max': 131072,
  'qwen3-235b': 128000,

  // Llama
  'llama-3.1-8b': 131072,
  'llama-3.1-70b': 131072,
  'llama-3.1-405b': 131072,
  'llama-4-scout': 10000000,
  'llama-4-maverick': 1000000,

  // Mistral
  'mistral-large': 128000,

  // Grok
  'grok-4': 2000000,
};

/// Resolve context limit by model name.
int getModelContextLimit(String modelName) {
  const defaultLimit = 128000;

  if (knownModelContextLimits.containsKey(modelName)) {
    return knownModelContextLimits[modelName]!;
  }

  final lower = modelName.toLowerCase();
  for (final entry in knownModelContextLimits.entries) {
    if (lower.contains(entry.key.toLowerCase())) {
      return entry.value;
    }
  }

  return defaultLimit;
}

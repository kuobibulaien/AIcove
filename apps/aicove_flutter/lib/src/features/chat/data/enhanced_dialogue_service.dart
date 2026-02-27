library;

import '../domain/conversation.dart';
import '../domain/message.dart';
import '../id_gen.dart';

/// 增强对话拼接结果
class EnhancedDialogueContext {
  final Conversation conversation;
  final List<Message> history;
  final String sessionId;

  const EnhancedDialogueContext({
    required this.conversation,
    required this.history,
    required this.sessionId,
  });
}

/// 增强对话服务
///
/// 负责：
/// 1. 按“最近 N 轮”拼接上下文
/// 2. 注入第一条任务消息
/// 3. 组合增强系统提示词 + 原始人设
/// 4. 从模型输出中提取 <enhance> 标签文本
class EnhancedDialogueService {
  const EnhancedDialogueService();

  static final RegExp _enhanceTagPattern =
      RegExp(r'<enhance>([\s\S]*?)</enhance>', caseSensitive: false);
  static final RegExp _enhanceCnTagPattern =
      RegExp(r'<增强>([\s\S]*?)</增强>', caseSensitive: false);

  EnhancedDialogueContext buildContext({
    required Conversation conversation,
    required Message targetUserMessage,
    required String enhancerSystemPrompt,
    required String bootstrapUserMessage,
    required int recentRounds,
  }) {
    final rounds = normalizeRounds(recentRounds);
    final contextWindow = _sliceByContextStartMarker(
      messages: conversation.messages,
      contextStartMessageId: conversation.contextStartMessageId,
    );
    final selected = _selectRecentRounds(contextWindow, rounds: rounds);

    final selectedWithTarget = List<Message>.from(selected);
    final hasTarget =
        selectedWithTarget.any((message) => message.id == targetUserMessage.id);
    if (!hasTarget) {
      selectedWithTarget.add(targetUserMessage);
    }

    final history = <Message>[];
    final bootstrap = bootstrapUserMessage.trim();
    if (bootstrap.isNotEmpty) {
      history.add(Message(
        id: genId('enhance_bootstrap'),
        role: 'user',
        content: bootstrap,
        createdAt: DateTime.now(),
        status: 'sent',
      ));
    }
    history.addAll(selectedWithTarget);

    final mergedPersonaPrompt = _mergePersonaPrompt(
      originalPersonaPrompt: conversation.personaPrompt,
      enhancerSystemPrompt: enhancerSystemPrompt,
    );

    return EnhancedDialogueContext(
      conversation: conversation.copyWith(personaPrompt: mergedPersonaPrompt),
      history: history,
      sessionId:
          'enhance_${conversation.id}_${DateTime.now().millisecondsSinceEpoch}',
    );
  }

  String extractEnhancedText({
    required String processedText,
    required String rawReplyText,
  }) {
    final fromProcessed = _extractTagged(processedText);
    if (fromProcessed != null && fromProcessed.isNotEmpty) {
      return fromProcessed;
    }

    final fromRaw = _extractTagged(rawReplyText);
    if (fromRaw != null && fromRaw.isNotEmpty) {
      return fromRaw;
    }

    final processed = processedText.trim();
    if (processed.isNotEmpty) return processed;
    return rawReplyText.trim();
  }

  int normalizeRounds(int rounds) {
    if (rounds < 1) return 1;
    if (rounds > 20) return 20;
    return rounds;
  }

  String _mergePersonaPrompt({
    required String originalPersonaPrompt,
    required String enhancerSystemPrompt,
  }) {
    final enhancer = enhancerSystemPrompt.trim();
    final original = originalPersonaPrompt.trim();
    if (enhancer.isEmpty) return originalPersonaPrompt;
    if (original.isEmpty) return enhancer;
    return '$enhancer\n\n以下是当前会话原始人设，请严格遵守：\n$original';
  }

  String? _extractTagged(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;

    final match = _enhanceTagPattern.firstMatch(trimmed) ??
        _enhanceCnTagPattern.firstMatch(trimmed);
    if (match == null) return null;
    return match.group(1)?.trim();
  }

  List<Message> _sliceByContextStartMarker({
    required List<Message> messages,
    required String? contextStartMessageId,
  }) {
    if (contextStartMessageId == null || contextStartMessageId.isEmpty) {
      return messages;
    }
    final markerIndex =
        messages.lastIndexWhere((m) => m.id == contextStartMessageId);
    if (markerIndex >= 0 && markerIndex + 1 < messages.length) {
      return messages.sublist(markerIndex + 1);
    }
    return messages;
  }

  List<Message> _selectRecentRounds(List<Message> messages,
      {required int rounds}) {
    if (messages.isEmpty) return const <Message>[];

    final userIndexes = <int>[];
    for (var i = 0; i < messages.length; i++) {
      if (messages[i].role == 'user') {
        userIndexes.add(i);
      }
    }

    if (userIndexes.isEmpty) {
      final tailCount = (rounds * 2).clamp(1, messages.length).toInt();
      return messages.sublist(messages.length - tailCount);
    }

    final clampedRounds = rounds.clamp(1, userIndexes.length).toInt();
    final startIndex = userIndexes[userIndexes.length - clampedRounds];
    return messages.sublist(startIndex);
  }
}

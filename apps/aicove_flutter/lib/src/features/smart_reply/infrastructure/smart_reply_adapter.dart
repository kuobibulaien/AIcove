import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../background_agent/background_agent_service.dart';
import '../../background_agent/domain/background_agent_definition.dart';
import '../../background_agent/domain/background_context_spec.dart';
import '../../chat/services/chat_history_store.dart';
import '../../settings/app_settings.dart';
import '../domain/smart_reply.dart';

final smartReplyPortProvider = Provider<SmartReplyPort>(
  (ref) => SmartReplyAdapter(ref),
);

class SmartReplyAdapter implements SmartReplyPort {
  SmartReplyAdapter(this.ref);
  final Ref ref;

  @override
  Future<SmartReplySnapshot> snapshot(String conversationId) async {
    final raw = await ref
        .read(chatHistoryStoreProvider)
        .loadCanonicalContextMessages(conversationId, limit: 10);
    return SmartReplySnapshot(conversationId, buildSmartReplyContext(raw));
  }

  @override
  Future<List<String>> generate(
    SmartReplySnapshot snapshot,
    String modelRef,
  ) async {
    final settings = await ref.read(appSettingsProvider.future);
    final available = settings.providers.any(
      (p) =>
          p.enabled &&
          {...p.models, ...p.visibleModels}.any(
            (m) =>
                settings.buildModelRef(p.id, m) == modelRef &&
                settings.getModelType(modelRef) == ModelType.chat,
          ),
    );
    if (!settings.smartReplyEnabled ||
        settings.smartReplyModel != modelRef ||
        !available) {
      throw const FormatException('请在通用设置中启用辅助回答，并选择可用模型');
    }
    if (snapshot.messages.isEmpty ||
        snapshot.messages.last.role != 'assistant') {
      throw const FormatException('等待对方回复后，再生成辅助回答');
    }
    const definition = smartReplyDefinition;
    final result = await ref
        .read(backgroundAgentServiceProvider)
        .run(
          definition: BackgroundAgentDefinition(
            id: definition.id,
            name: definition.name,
            objectivePrompt: definition.objective,
            contextSpec: const BackgroundContextSpec(lastMessages: 1),
            modelRef: modelRef,
            allowedToolNames: definition.allowedToolNames,
            maxRounds: definition.maxRounds,
          ),
          conversationId: snapshot.conversationId,
          contextMessages: [buildSmartReplyRequest(snapshot.messages)],
          maxOutputTokens: 512,
        );
    return parseSmartReplies(result.text);
  }
}

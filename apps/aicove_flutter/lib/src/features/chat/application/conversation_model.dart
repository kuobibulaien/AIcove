import '../../settings/app_settings.dart';
import '../domain/conversation.dart';

/// 本会话选过、且仍在可见模型里的模型；没选过或已删除时为 null。
String? conversationModelOverride(
  AppSettings settings,
  Conversation? conversation,
) =>
    usableSessionModel(settings, conversation?.sessionProvider);

/// [sessionModel] 是会话存的 `session_provider` 原值；不可用时为 null。
String? usableSessionModel(AppSettings settings, String? sessionModel) {
  final ref = sessionModel?.trim() ?? '';
  if (ref.isEmpty || !settings.modelList.contains(ref)) return null;
  return ref;
}

/// 本会话实际使用的主模型：会话选过的模型 > 全局默认模型。
String conversationPrimaryModel(
  AppSettings settings,
  Conversation? conversation,
) =>
    sessionPrimaryModel(settings, conversation?.sessionProvider);

/// 只拿得到 `session_provider` 原值时（如后台任务）用的 [conversationPrimaryModel]。
String sessionPrimaryModel(AppSettings settings, String? sessionModel) {
  return usableSessionModel(settings, sessionModel) ??
      conversationChatModels(settings, null).first;
}

/// 本会话的聊天模型链：会话选过的模型排在最前，其余按默认队列兜底。
/// [base] 为空时用默认聊天模型队列。
List<String> conversationChatModels(
  AppSettings settings,
  Conversation? conversation, {
  List<String>? base,
}) {
  final chain = <String>[];
  void add(String? value) {
    final ref = value?.trim() ?? '';
    if (ref.isEmpty || chain.contains(ref)) return;
    chain.add(ref);
  }

  add(conversationModelOverride(settings, conversation));
  final fallback = base ??
      (settings.defaultChatModels.isNotEmpty
          ? settings.defaultChatModels
          : <String>[settings.defaultModelName]);
  fallback.forEach(add);
  if (chain.isEmpty) chain.add(settings.defaultModelName);
  return chain;
}

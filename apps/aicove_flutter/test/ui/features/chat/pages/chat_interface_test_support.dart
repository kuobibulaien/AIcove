import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class FakeChatInterfaceSettingsNotifier extends AppSettingsNotifier {
  FakeChatInterfaceSettingsNotifier(this.settings);

  AppSettings settings;

  @override
  Future<AppSettings> build() async => settings;

  @override
  Future<void> setAutoScrollOnSend(bool enabled) async {
    settings = settings.copyWith(autoScrollOnSend: enabled);
    state = AsyncData(settings);
  }
}

AppSettings chatInterfaceTestSettings() => const AppSettings(
  ttsEnabled: false,
  defaultModelName: '',
  defaultPersonaPrompt: '',
  modelList: <String>[],
  allKnownModels: <String>[],
  modelDisplayNames: <String, String>{},
  modelTypes: <String, String>{},
  modelConfigs: <String, ModelConfig>{},
  apiKey: '',
  apiBaseUrl: '',
  imageGenerationEnabled: false,
  maxFileUploadMB: 10,
  contextWindowTokens: 272000,
  customModels: <CustomModel>[],
  providers: <ProviderAuth>[],
  modelProviderMap: <String, String>{},
  backendApiKey: '',
  messageChunkingEnabled: false,
  messageFormatConfig: MessageFormatConfig(),
  textScaleFactor: 1.0,
  uiScaleFactor: 1.0,
  autoReplySettings: AutoReplySettings(),
  globalBackgroundColor: GlobalBackgroundColor.white,
  chatBackgroundColor: ChatBackgroundColor.defaultColor,
  isDarkMode: false,
  useSystemTheme: true,
  accentColor: 'FC96AA',
);

/// 聊天界面页测试宿主：设置与会话均为内存假数据，不读数据库或本机存储。
Widget chatInterfaceTestScope({
  required Conversation conversation,
  required Widget child,
  FakeChatInterfaceSettingsNotifier? settings,
}) {
  final notifier =
      settings ??
      FakeChatInterfaceSettingsNotifier(chatInterfaceTestSettings());
  return ProviderScope(
    overrides: [
      appSettingsProvider.overrideWith(() => notifier),
      resolvedConversationByIdProvider(
        conversation.id,
      ).overrideWith((ref) => conversation),
    ],
    child: child,
  );
}

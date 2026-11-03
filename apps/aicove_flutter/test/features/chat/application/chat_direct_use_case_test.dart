import 'dart:io';

import 'package:aicove_flutter/src/features/chat/application/chat_ports.dart';
import 'package:aicove_flutter/src/features/chat/application/chat_send_use_case.dart';
import 'package:aicove_flutter/src/features/chat/application/chat_turn_command.dart';
import 'package:aicove_flutter/src/features/chat/chat_actions.dart';
import 'package:aicove_flutter/src/features/chat/chat_layer_providers.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../../../../tool/chat_segmented_fixture.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

class _UnusedPort implements ChatSendPort {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('The injected use case must not call a model');
}

class _UseCase extends ChatSendUseCase {
  _UseCase() : super(_UnusedPort());
  final commands = <ChatTurnCommand>[];
  @override
  Future<ChatSendTurnResult?> executeTurn({
    required ChatTurnCommand command,
    required ChatTurnExecutionOptions options,
  }) async {
    commands.add(command);
    expect(options.isCurrent(), isTrue);
    return null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'ChatActions reads the injected ChatSendUseCase and settles a skipped turn',
    () async {
      final oldPaths = PathProviderPlatform.instance;
      final root = await Directory.systemTemp.createTemp(
        'chat_direct_use_case_',
      );
      PathProviderPlatform.instance = _Paths(root.path);
      addTearDown(() async {
        PathProviderPlatform.instance = oldPaths;
        await root.delete(recursive: true);
      });
      final useCase = _UseCase();
      final fixture = await SegmentedChatFixture.create(
        historyCount: 0,
        extraOverrides: [chatSendUseCaseProvider.overrideWithValue(useCase)],
      );
      addTearDown(fixture.dispose);
      await fixture.container.read(chatActionsProvider).send('direct turn');
      expect(useCase.commands, hasLength(1));
      final command = useCase.commands.single;
      expect(command.isStreaming, isTrue);
      expect(command.conversation.id, fixture.conversation.id);
      expect(command.apiText, 'direct turn');
      expect(
        fixture.container.read(
          conversationSendingProvider(fixture.conversation.id),
        ),
        isFalse,
      );
      final stored = await fixture.database
          .select(fixture.database.messages)
          .get();
      expect(stored, hasLength(1));
      expect(stored.single.role, 'user');
      expect(stored.single.content, 'direct turn');
    },
  );
}

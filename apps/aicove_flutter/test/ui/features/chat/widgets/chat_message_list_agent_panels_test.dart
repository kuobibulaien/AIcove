import 'dart:io';

import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/domain/role_agent_mode.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_message_list.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_viewport_controller.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/ui_blocks/moe_ui_block_scope.dart';
import 'package:aicove_flutter/src/ui/theme/skin_provider.dart';
import 'package:aicove_flutter/src/ui/theme/skins/moetalk_skin.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../../../../../tool/chat_segmented_fixture.dart';
import '../../../../helpers/release_source_preview.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

/// ADR0111: the chat page turns quick panels on for tool-mode chats.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final originalPaths = PathProviderPlatform.instance;
  late Directory directory;
  setUpAll(() {
    directory = Directory.systemTemp.createTempSync('agent_panels_list_');
    PathProviderPlatform.instance = _Paths(directory.path);
  });
  tearDownAll(() async {
    PathProviderPlatform.instance = originalPaths;
    await directory.delete(recursive: true);
  });

  for (final mode in [RoleAgentMode.tool, RoleAgentMode.chat]) {
    testWidgets('quick panels in ${mode.name} mode', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 560);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await loadReleasePreviewFonts(tester);
      final fixture = (await tester.runAsync(
        () => SegmentedChatFixture.create(
          historyMessages: [
            Message.text(id: 'user', role: 'user', content: '看看角色库'),
            Message.text(
              id: 'reply',
              role: 'assistant',
              content:
                  '你的角色都在这里，点一个就能改：\n\n'
                  '```aicove-ui\n'
                  '{"component": "roles", "id": "pick-role", "purpose": "edit"}\n'
                  '```',
            ),
          ],
          decorate: (c) => c.copyWith(agentMode: mode),
        ),
      ))!;
      final viewport = ChatViewportController();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(fixture.dispose);
        viewport.dispose();
      });
      final boundary = GlobalKey();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: fixture.container,
          child: SkinScope(
            skin: const MoeTalkSkin(),
            child: MaterialApp(
              theme: ThemeData(
                fontFamily: captureReleaseSourcePreview
                    ? 'ReleasePreview'
                    : null,
              ),
              home: RepaintBoundary(
                key: boundary,
                child: Scaffold(
                  body: ChatMessageList(
                    conversationId: fixture.conversation.id,
                    messages: fixture.timeline.value,
                    displayName: '小帮手',
                    viewportController: viewport,
                    hasMoreMessages: false,
                    quickPanels: mode == RoleAgentMode.tool,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      final scope = tester.widget<MoeUiBlockScope>(
        find.byType(MoeUiBlockScope),
      );
      expect(scope.actions, mode == RoleAgentMode.tool ? isNotNull : isNull);
      expect(
        find.textContaining('只在 Agent 模式的聊天里能用'),
        mode == RoleAgentMode.tool ? findsNothing : findsOneWidget,
      );
      await saveReleaseSourcePreview(
        tester,
        boundary,
        'agent-panels-${mode.name}',
      );
    });
  }
}

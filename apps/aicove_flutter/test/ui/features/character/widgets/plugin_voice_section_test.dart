import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aicove_flutter/src/ui/features/character/widgets/plugin_voice_section.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/chat_plugin_settings_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('插件弹窗内切换开关后立即刷新状态', (tester) async {
    final totalPlugins = conversationScopedChatPluginItems.length;

    await tester.pumpWidget(const _TestApp());
    await tester.pumpAndSettle();

    expect(find.text('已启用全部 $totalPlugins 个插件'), findsOneWidget);

    await tester.tap(find.text('已启用全部 $totalPlugins 个插件'));
    await tester.pumpAndSettle();

    expect(find.text('选择插件'), findsOneWidget);
    expect(find.text('主动关怀'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch).first).value, isTrue);

    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();

    expect(find.text('已启用 ${totalPlugins - 1} / $totalPlugins 个插件'),
        findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch).first).value, isFalse);
  });
}

class _TestApp extends StatelessWidget {
  const _TestApp();

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: _PluginVoiceSectionHost(
              initialSelectedPluginIds: {
                for (final item in conversationScopedChatPluginItems) item.id,
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _PluginVoiceSectionHost extends StatefulWidget {
  const _PluginVoiceSectionHost({
    required this.initialSelectedPluginIds,
  });

  final Set<String> initialSelectedPluginIds;

  @override
  State<_PluginVoiceSectionHost> createState() =>
      _PluginVoiceSectionHostState();
}

class _PluginVoiceSectionHostState extends State<_PluginVoiceSectionHost> {
  late Set<String> _selectedPluginIds;

  @override
  void initState() {
    super.initState();
    _selectedPluginIds = {...widget.initialSelectedPluginIds};
  }

  @override
  Widget build(BuildContext context) {
    return PluginVoiceSection(
      selectedPluginIds: _selectedPluginIds,
      boundVoiceId: null,
      voicePresets: const [],
      onPluginIdsChanged: (newIds) {
        setState(() {
          _selectedPluginIds = newIds;
        });
      },
      onVoiceChanged: (_) {},
    );
  }
}

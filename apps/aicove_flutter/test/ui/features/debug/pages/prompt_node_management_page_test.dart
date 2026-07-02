import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aicove_flutter/src/core/prompts/prompt_custom_nodes.dart';
import 'package:aicove_flutter/src/ui/features/debug/pages/prompt_node_management_page.dart';

void main() {
  final bundle = _StringAssetBundle(<String, String>{
    'assets/prompt_defaults.json': jsonEncode(<String, Object?>{
      'prompts': <Object?>[
        <String, Object?>{
          'id': 'auto_reply.analyzer.default',
          'title': '主动回复分析',
          'category': 'auto_reply',
          'description': '测试提示词',
          'dartName': 'autoReplyAnalyzerDefault',
          'variables': <Object?>['state_json'],
          'template': '分析 {state_json}',
        },
        <String, Object?>{
          'id': 'tts.system.default',
          'title': '语音标签',
          'category': 'tts',
          'description': '测试提示词',
          'dartName': 'ttsSystemDefault',
          'variables': <Object?>[],
          'template': '使用语音标签',
        },
      ],
    }),
    'assets/agent_context_defaults.json': jsonEncode(<String, Object?>{
      'version': 1,
      'source': 'test',
      'syncedAt': '2026-05-26T00:00:00Z',
      'agents': <Object?>[
        <String, Object?>{
          'id': 'proactive_agent:default',
          'name': '主动回复 Agent',
          'agentKind': 'proactive',
          'contactId': null,
          'modelRef': null,
          'contextRecipeId': 'standard_proactive_recipe:default',
          'contextProfile': <String, Object?>{},
          'toolPolicyId': null,
          'outputContractId': null,
          'triggerPolicy': <String, Object?>{},
          'assemblyFlow': <String, Object?>{},
          'agentGraph': <String, Object?>{
            'nodes': <Object?>[
              <String, Object?>{
                'id': 'graph:auto_reply.analyzer.default',
                'nodeId': 'auto_reply.analyzer.default',
                'assetId': 'auto_reply.analyzer.default',
                'nodeType': 'prompt',
                'label': '主动回复分析',
                'enabled': true,
                'position': <String, Object?>{'x': 0, 'y': 0},
                'slot': 'analyzer_prompt',
                'config': <String, Object?>{
                  'stageLabel': 'Analyzer',
                },
              },
            ],
            'edges': <Object?>[],
            'entryNodeIds': <Object?>['graph:auto_reply.analyzer.default'],
            'outputNodeIds': <Object?>['graph:auto_reply.analyzer.default'],
            'viewport': <String, Object?>{},
          },
          'deliveryChannel': 'background_proactive',
          'enabled': true,
        },
      ],
      'bindings': <Object?>[],
      'nodeLibrary': <Object?>[],
    }),
  });

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Future<void> pumpPage(WidgetTester tester, Size size) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: PromptNodeManagementPage(
          key: ValueKey<String>('prompt-node-${size.width}x${size.height}'),
          assetBundle: bundle,
        ),
      ),
    );
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('shows prompt node summary on narrow screen', (tester) async {
    await pumpPage(tester, const Size(390, 844));

    expect(find.text('提示词节点'), findsOneWidget);
    expect(find.text('内置提示词'), findsOneWidget);
    expect(find.text('Agent Build'), findsWidgets);
    expect(find.text('图外运行'), findsOneWidget);
  });

  testWidgets('shows prompt node summary on wide screen', (tester) async {
    await pumpPage(tester, const Size(1024, 768));

    expect(find.text('提示词节点'), findsOneWidget);
    expect(find.text('内置提示词'), findsOneWidget);
    expect(find.text('Agent Build'), findsWidgets);
    expect(find.text('图外运行'), findsOneWidget);
  });

  testWidgets('default prompt nodes are read only', (tester) async {
    await pumpPage(tester, const Size(390, 844));

    await tester.tap(find.text('主动回复分析'));
    await tester.pumpAndSettle();

    expect(find.text('默认只读'), findsOneWidget);
    expect(find.text('编辑'), findsNothing);
    expect(find.text('恢复默认'), findsNothing);
  });

  testWidgets('creates and persists a custom prompt node', (tester) async {
    await pumpPage(tester, const Size(390, 844));

    await tester.tap(find.text('新增自定义节点'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'custom.test.node');
    await tester.enterText(fields.at(1), '测试自定义节点');
    await tester.enterText(fields.at(3), '测试说明');
    await tester.enterText(fields.at(4), 'name, context');
    await tester.enterText(fields.at(5), '你好 {name}');
    await tester.drag(find.byType(ListView).last, const Offset(0, -500));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存').last);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3));

    final nodes = await PromptCustomNodeStore.instance.load();
    expect(nodes, hasLength(1));
    expect(nodes.first.id, 'custom.test.node');
    expect(nodes.first.variables, <String>['name', 'context']);
    expect(find.text('自定义节点'), findsWidgets);
    expect(find.text('测试自定义节点'), findsOneWidget);
  });

  testWidgets('rejects custom node id that matches a default prompt', (
    tester,
  ) async {
    await pumpPage(tester, const Size(390, 844));

    await tester.tap(find.text('新增自定义节点'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'auto_reply.analyzer.default');
    await tester.enterText(fields.at(1), '冲突节点');
    await tester.enterText(fields.at(5), '不会保存');
    await tester.drag(find.byType(ListView).last, const Offset(0, -500));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存').last);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3));

    final nodes = await PromptCustomNodeStore.instance.load();
    expect(nodes, isEmpty);
    expect(find.text('新增自定义节点'), findsWidgets);
  });
}

class _StringAssetBundle extends AssetBundle {
  _StringAssetBundle(this.assets);

  final Map<String, String> assets;

  @override
  Future<ByteData> load(String key) async {
    final value = assets[key];
    if (value == null) {
      throw FlutterError('Missing test asset: $key');
    }
    final bytes = Uint8List.fromList(utf8.encode(value));
    return ByteData.sublistView(bytes);
  }

  @override
  Future<String> loadString(String key, {bool cache = true}) async {
    final value = assets[key];
    if (value == null) {
      throw FlutterError('Missing test asset: $key');
    }
    return value;
  }
}

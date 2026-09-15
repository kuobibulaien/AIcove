import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/api/thinking/thinking_level.dart';
import 'package:aicove_flutter/src/core/api/thinking/thinking_level_catalog.dart';
import 'package:aicove_flutter/src/core/api/thinking/thinking_level_labels.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/thinking_level_sheet.dart';
import 'package:aicove_flutter/src/ui/theme/skin_provider.dart';
import 'package:aicove_flutter/src/ui/theme/skins/moetalk_skin.dart';

void main() {
  Widget host({
    required ThinkingLevelOptions options,
    required ThinkingLevel current,
    required bool hasOwnSetting,
    required void Function(ThinkingLevelSheetResult?) onResult,
  }) {
    return SkinScope(
      skin: const MoeTalkSkin(),
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () async {
                  onResult(await showThinkingLevelSheet(
                    context,
                    title: '思考档位',
                    options: options,
                    current: current,
                    currentSource: ThinkingLevelSource.session,
                    hasOwnSetting: hasOwnSetting,
                  ));
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('renders native levels with source label and returns pick',
      (tester) async {
    ThinkingLevelSheetResult? result;
    final options = resolveThinkingOptions(
      providerType: 'openai',
      modelId: 'gpt-5.2',
    );
    await tester.pumpWidget(host(
      options: options,
      current: ThinkingLevel.medium,
      hasOwnSetting: false,
      onResult: (r) => result = r,
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.textContaining('本会话设置'), findsOneWidget);
    expect(find.text('xhigh'), findsOneWidget);
    expect(find.text('跟随上游'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('thinking_clear')), findsNothing);

    await tester.tap(find.text('xhigh'));
    await tester.pumpAndSettle();
    expect(result?.level, ThinkingLevel.xhigh);
    expect(result?.cleared, isFalse);
  });

  testWidgets('generic scheme shows 4-tier chinese labels and clear entry',
      (tester) async {
    ThinkingLevelSheetResult? result;
    final options = resolveThinkingOptions(
      providerType: 'openai',
      modelId: 'deepseek-chat',
    );
    await tester.pumpWidget(host(
      options: options,
      current: ThinkingLevel.low,
      hasOwnSetting: true,
      onResult: (r) => result = r,
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('低'), findsOneWidget);
    expect(find.text('高'), findsOneWidget);
    expect(find.text('xhigh'), findsNothing);

    await tester.tap(find.byKey(const ValueKey<String>('thinking_clear')));
    await tester.pumpAndSettle();
    expect(result?.cleared, isTrue);
    expect(result?.level, isNull);
  });
}

import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/core/utils/avatar_helper.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/provider_detail_page.dart';
import 'package:aicove_flutter/src/ui/features/settings/widgets/model_row_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Diagnostic observations, not fixed-performance acceptance tests.
void main() {
  for (final width in [360.0, 1000.0]) {
    testWidgets('observe initial model rows at width=$width', (tester) async {
      await tester.binding.setSurfaceSize(Size(width, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final store = jsonDecode(jsonEncode(_mockStore)) as Map<String, dynamic>;
      final provider = (store['providers'] as List).first;
      provider['models'] = List.generate(100, (i) => 'audit-model-$i');
      provider['visible_models'] = provider['models'];
      SharedPreferences.setMockInitialValues(
          {'aicove.ui_models.v1': jsonEncode(store)});
      await tester.pumpWidget(const ProviderScope(
          child: MaterialApp(home: ProviderDetailPage(providerId: 'openai'))));
      await tester.pumpAndSettle();
      await tester.tap(find.text('模型'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final mountedRows = find.byType(ModelRowTile).evaluate().length;
      final last = find.text('audit-model-99');
      expect(mountedRows, 100,
          reason: 'Observe eager mounting on current code');
      expect(last, findsOneWidget);
      expect(last.hitTestable(), findsNothing);
      debugPrint(
          '[PerformanceAudit] width=$width mountedRows=$mountedRows lastRowOffscreen=true');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }

  testWidgets('observe full raster decoding for a 56 pixel avatar',
      (tester) async {
    final png = (await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawColor(Colors.blue, BlendMode.src);
      final picture = recorder.endRecording();
      final source = await picture.toImage(2048, 2048);
      final data = await source.toByteData(format: ui.ImageByteFormat.png);
      source.dispose();
      picture.dispose();
      return data!.buffer.asUint8List();
    }))!;
    final helper = AvatarHelper(
      avatarUrl: 'data:image/png;base64,${base64Encode(png)}',
      displayName: 'Synthetic avatar',
    );
    await tester.pumpWidget(MaterialApp(
        home: Center(
            child: SizedBox(
      width: 56,
      height: 56,
      child: helper.buildAvatarWidget(),
    ))));
    final widget = tester.widget<Image>(find.byType(Image));
    expect(tester.getSize(find.byType(Image)), const Size(56, 56));
    final info = (await tester.runAsync(() async {
      final result = Completer<ImageInfo>();
      final stream = widget.image.resolve(const ImageConfiguration(
        size: Size(56, 56),
        devicePixelRatio: 1,
      ));
      late ImageStreamListener listener;
      listener = ImageStreamListener((info, synchronousCall) {
        if (!result.isCompleted) result.complete(info);
      }, onError: (Object error, StackTrace? stack) {
        if (!result.isCompleted) result.completeError(error, stack);
      });
      stream.addListener(listener);
      try {
        return await result.future.timeout(const Duration(seconds: 10));
      } finally {
        stream.removeListener(listener);
      }
    }))!;
    expect(info.image.width, 2048);
    expect(info.image.height, 2048);
    debugPrint(
        '[PerformanceAudit] avatarLayout=56x56 decoded=${info.image.width}x${info.image.height}');
    info.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });
}

const _mockStore = <String, dynamic>{
  'providers': [
    {
      'id': 'openai',
      'displayName': 'OpenAI',
      'apiKeys': <String>['sk-test-1'],
      'apiBaseUrl': 'https://api.example.com/v1',
      'enabled': true,
      'models': <String>['gpt-4o-mini'],
      'visible_models': <String>['gpt-4o-mini'],
      'hidden_models': <String>[],
      'capabilities': <String>['chat'],
      'custom_config': <String, dynamic>{
        'requestFormat': 'openai',
        'multi_key_enabled': true,
        'multi_key_strategy': 'round_robin',
        'multi_key_items': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'mk_1',
            'key': 'sk-test-1',
            'alias': '主 Key',
            'enabled': true,
            'status': 'normal',
            'updated_at': 1,
          },
        ],
        'multi_key_rr_index': 0,
      },
    },
  ],
  'visible_models': <String>['gpt-4o-mini'],
  'default_model': 'openai:gpt-4o-mini',
  'default_chat_models': <String>['openai:gpt-4o-mini'],
  'model_display_names': <String, String>{
    'openai:gpt-4o-mini': 'GPT-4o mini',
  },
};

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/chat/application/active_stream_projection.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/settings/settings_models.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_message_list.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_message_list_display_cache.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_viewport_controller.dart';
import 'package:aicove_flutter/src/ui/theme/skin_provider.dart';
import 'package:aicove_flutter/src/ui/theme/skins/moetalk_skin.dart';

/// G2.1 followLatest 场景组（翻默认 true 前置清单第 5 条）：
/// 活跃流通道驱动的「气泡局部增高」在各视口状态下的贴底/锚点语义。
/// 程序滚动争抢场景（清单 5-4）由既有 auto_scroll_guard 套件的
/// programmatic 用例覆盖——窄信号与其共用同一组守卫旗标（_isProgrammaticScroll 等）。

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.rootPath);
  final String rootPath;
  @override
  Future<String?> getApplicationDocumentsPath() async => rootPath;
}

class _FakeAppSettingsNotifier extends AppSettingsNotifier {
  _FakeAppSettingsNotifier(this._settings);
  final AppSettings _settings;
  @override
  Future<AppSettings> build() async => _settings;
}

AppSettings _buildSettings() {
  return const AppSettings(
    ttsEnabled: true,
    defaultModelName: 'deepseek-chat',
    defaultPersonaPrompt: '',
    modelList: <String>['deepseek-chat'],
    allKnownModels: <String>['deepseek-chat'],
    modelDisplayNames: <String, String>{},
    modelTypes: <String, String>{},
    modelConfigs: <String, ModelConfig>{},
    apiKey: '',
    apiBaseUrl: 'https://api.openai.com/v1',
    imageGenerationEnabled: false,
    maxFileUploadMB: 10,
    historyMessageLimit: 100,
    customModels: <CustomModel>[],
    providers: <ProviderAuth>[],
    modelProviderMap: <String, String>{},
    backendApiKey: '',
    messageChunkingEnabled: false,
    messageFormatConfig: MessageFormatConfig(enableChunking: false),
    textScaleFactor: 1.0,
    uiScaleFactor: 1.0,
    imagePreviewScale: 1.0,
    autoReplySettings: AutoReplySettings(),
    globalBackgroundColor: GlobalBackgroundColor.white,
    chatBackgroundColor: ChatBackgroundColor.defaultColor,
    isDarkMode: false,
    useSystemTheme: true,
    accentColor: 'FC96AA',
    hideUserAvatar: false,
  );
}

const String _kConvId = 'conv_stream_follow';
const String _kStreamShellId = 'm_stream_shell';

List<Message> _buildMessages({int historyCount = 14}) {
  final baseTime = DateTime(2026, 1, 1, 12, 0, 0);
  final history = List<Message>.generate(historyCount, (index) {
    final role = index.isEven ? 'assistant' : 'user';
    final id = 'm_$index';
    return Message.fromBlocks(
      id: id,
      role: role,
      blocks: <MessageBlock>[
        TextBlock(messageId: id, content: '历史消息内容第$index条，用于撑高列表方便滚动。'),
      ],
      createdAt: baseTime.add(Duration(minutes: index)),
      status: 'sent',
    );
  });
  // 活跃尾壳：assistant sending + 单 TextBlock（非分段活跃尾的物化形态）
  final shell = Message.fromBlocks(
    id: _kStreamShellId,
    role: 'assistant',
    blocks: <MessageBlock>[
      TextBlock(messageId: _kStreamShellId, content: '壳'),
    ],
    createdAt: baseTime.add(Duration(minutes: historyCount)),
    status: 'sending',
  );
  return [...history, shell];
}

class _Host extends StatefulWidget {
  const _Host({super.key});
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  double bottomOverlayHeight = 0;
  int listBuildCount = 0;

  void setOverlay(double value) => setState(() => bottomOverlayHeight = value);

  @override
  Widget build(BuildContext context) {
    return ChatMessageList(
      conversationId: _kConvId,
      messages: _buildMessages(),
      displayName: '测试AI',
      avatarUrl: null,
      bottomOverlayHeight: bottomOverlayHeight,
      viewportController: ChatViewportController(),
      onDebugListItemCountChanged: (_) => listBuildCount++,
    );
  }
}

Future<ProviderContainer> _pumpHost(
  WidgetTester tester,
  GlobalKey<_HostState> hostKey,
) async {
  final tempDir = await tester.runAsync(() async {
    final dir = await Directory.systemTemp.createTemp('stream_follow_test');
    PathProviderPlatform.instance = _FakePathProviderPlatform(dir.path);
    ChatMessageListDisplayCache.clear();
    await ChatMessageListDisplayCache.clearPersistent();
    return dir;
  });
  addTearDown(() {
    try {
      tempDir?.deleteSync(recursive: true);
    } catch (_) {}
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appSettingsProvider
            .overrideWith(() => _FakeAppSettingsNotifier(_buildSettings())),
        streamProjectionPolicyProvider.overrideWithValue(
          const StreamProjectionPolicy(useActiveStreamChannel: true),
        ),
      ],
      child: SkinScope(
        skin: const MoeTalkSkin(),
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 360,
                height: 520,
                child: _Host(key: hostKey),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 320));
  return ProviderScope.containerOf(
    tester.element(find.byType(ChatMessageList)),
  );
}

double _distanceToBottom(WidgetTester tester) {
  final controller =
      tester.widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller!;
  final position = controller.position;
  return position.pixels - position.minScrollExtent;
}

String _growingText(int step) =>
    List.filled(step, '实时增长的流式正文第$step轮，足够长以改变气泡高度。').join('\n');

void _publishGrowth(ProviderContainer container, int step) {
  container.read(activeStreamProjectionsProvider.notifier).publish(
        ActiveStreamProjection(
          conversationId: _kConvId,
          generationSeq: 1,
          writeEpoch: step,
          tailMessageId: _kStreamShellId,
          tailText: _growingText(step),
          phase: ActiveStreamPhase.streamingTail,
        ),
      );
}

Future<void> _settleStabilization(WidgetTester tester) async {
  // 稳底调度含 post-frame 重试与 260ms 延迟重试；延迟重试在计时 pump 内
  // 触发后还会挂 post-frame，需要额外帧才能执行，故末尾再补两帧。
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 40));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('S1 贴底跟随：通道驱动气泡增高仍贴底，且列表不重建、实时文本上屏',
      (tester) async {
    final hostKey = GlobalKey<_HostState>();
    final container = await _pumpHost(tester, hostKey);
    expect(_distanceToBottom(tester), lessThanOrEqualTo(8),
        reason: '初始应贴底');
    // 种子 publish：生产中「壳首次出现」伴随结构性时间线写入、由
    // didUpdateWidget 稳底路径负责（S-04 分工）；窄信号只管后续同尾增长。
    // 台架无结构写，先建立 prev 再度量增长步。
    container.read(activeStreamProjectionsProvider.notifier).publish(
          const ActiveStreamProjection(
            conversationId: _kConvId,
            generationSeq: 1,
            writeEpoch: 0,
            tailMessageId: _kStreamShellId,
            tailText: '起',
            phase: ActiveStreamPhase.streamingTail,
          ),
        );
    await _settleStabilization(tester);
    final buildsBefore = hostKey.currentState!.listBuildCount;

    for (var step = 1; step <= 3; step++) {
      _publishGrowth(container, step);
      await _settleStabilization(tester);
      expect(_distanceToBottom(tester), lessThanOrEqualTo(8),
          reason: '第$step轮增高后应保持贴底（窄信号稳底）');
    }
    expect(hostKey.currentState!.listBuildCount, buildsBefore,
        reason: '通道文本增长不得重建 ChatMessageList（Consumer 隔离）');
    expect(find.textContaining('实时增长的流式正文第3轮'), findsOneWidget,
        reason: '活跃气泡应渲染通道实时文本');
  });

  testWidgets('S2 detached 阅读：通道增高不移动锚点、不强制回底', (tester) async {
    final hostKey = GlobalKey<_HostState>();
    final container = await _pumpHost(tester, hostKey);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, 320));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    final gapDetached = _distanceToBottom(tester);
    expect(gapDetached, greaterThan(40), reason: '前置：已脱离贴底');

    // 阅读锚点＝可见历史气泡的屏幕位置（reverse 列表中距底偏移会随尾部
    // 长高等量增大以保持画面稳定，偏移差不是正确契约）。
    String? anchorText;
    double? anchorDy;
    for (var i = 13; i >= 0; i--) {
      final candidate = find.textContaining('历史消息内容第$i条');
      if (candidate.evaluate().isNotEmpty) {
        anchorText = '历史消息内容第$i条';
        anchorDy = tester.getTopLeft(candidate.first).dy;
        break;
      }
    }
    expect(anchorText, isNotNull, reason: '前置：应有可见历史气泡作锚点');

    for (var step = 1; step <= 3; step++) {
      _publishGrowth(container, step);
      await _settleStabilization(tester);
    }
    expect(_distanceToBottom(tester), greaterThan(40),
        reason: 'detached 下通道增高不得强制回底');
    final anchorAfter = find.textContaining(anchorText!);
    expect(anchorAfter.evaluate().isNotEmpty, isTrue,
        reason: '锚点历史气泡应仍在屏上');
    expect((tester.getTopLeft(anchorAfter.first).dy - anchorDy!).abs(),
        lessThanOrEqualTo(2),
        reason: 'detached 阅读画面（历史气泡屏幕位置）不得被通道增高移动');
  });

  testWidgets('S3 历史分页加载中：通道增高不得触发回底争抢', (tester) async {
    final hostKey = GlobalKey<_HostState>();
    final container = await _pumpHost(tester, hostKey);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, 320));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    final gapDetached = _distanceToBottom(tester);
    expect(gapDetached, greaterThan(40));

    // isLoadingMore 语义经 widget 层进入分页保持路径；此处直接以 detached
    // ＋连续增高验证「加载窗口期不回底」的外观契约。
    for (var step = 1; step <= 2; step++) {
      _publishGrowth(container, step);
      await tester.pump(const Duration(milliseconds: 60));
    }
    await _settleStabilization(tester);
    expect(_distanceToBottom(tester), greaterThan(40),
        reason: '分页/脱离窗口期通道增高不得抢占视口回底');
  });

  testWidgets('S5 键盘/底部遮挡同帧变化：贴底不破、不遮输入区', (tester) async {
    final hostKey = GlobalKey<_HostState>();
    final container = await _pumpHost(tester, hostKey);
    expect(_distanceToBottom(tester), lessThanOrEqualTo(8));

    // 同帧：底部 overlay 升高（键盘/面板）＋通道文本增长。
    hostKey.currentState!.setOverlay(160);
    _publishGrowth(container, 1);
    await _settleStabilization(tester);
    expect(_distanceToBottom(tester), lessThanOrEqualTo(8),
        reason: 'overlay 变化与通道增高同帧后仍应贴底（最后消息不被遮）');

    hostKey.currentState!.setOverlay(0);
    _publishGrowth(container, 2);
    await _settleStabilization(tester);
    expect(_distanceToBottom(tester), lessThanOrEqualTo(8),
        reason: 'overlay 收起后继续增高仍贴底');
  });
}

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../../core/models/message_block.dart';
import '../../../../features/voice_call/application/active_voice_call.dart';
import '../../../../features/voice_call/application/voice_call_controls.dart';
import '../../../../features/voice_call/application/voice_call_session.dart';

/// 主窗口与桌面端独立通话小窗之间的消息。通话只在主窗口里跑，小窗有自己的
/// 引擎、拿不到主窗口的对象：主窗口推状态，小窗回传按钮。
abstract final class VoiceCallWindowMethods {
  /// 小窗 → 主窗口：消息处理已就绪，请推一次完整状态。
  static const ready = 'ready';
  static const toggleMute = 'toggleMute';
  static const toggleSpeaker = 'toggleSpeaker';
  static const hangUp = 'hangUp';

  /// 小窗 → 主窗口：窗口已关掉。
  static const closed = 'closed';

  /// 主窗口 → 小窗。
  static const state = 'state';
  static const elapsed = 'elapsed';
  static const appearance = 'appearance';
  static const close = 'close';
}

typedef VoiceCallWindowSend =
    Future<void> Function(String method, [Object? arguments]);

/// 小窗显示的角色、壁纸和材质：打开时带过去，主窗口这边任何一项变了
/// （换壁纸、切亮暗、调材质参数）就整份重推，小窗不自己写死任何外观。
@immutable
class VoiceCallWindowAppearance {
  const VoiceCallWindowAppearance({
    required this.conversationId,
    required this.name,
    required this.backgroundColor,
    required this.dark,
    required this.accentColor,
    this.glassEnabled = false,
    this.glassBlurSigma = 0,
    this.glassTintFill = 0,
    this.glassLiquid = false,
    this.avatarUrl,
    this.characterImage,
    this.wallpaper,
    this.wallpaperStyle = const {},
    this.wallpaperAlignment = const [0, 0],
  });

  final String conversationId;
  final String name;
  final String? avatarUrl;
  final String? characterImage;

  /// 聊天页实际显示的壁纸（角色壁纸，没有则全局壁纸）；null 时只有底色。
  final String? wallpaper;

  /// `WallpaperStyle.toJson()`。
  final Map<String, Object?> wallpaperStyle;

  /// 没有截取时的默认焦点（x, y）。
  final List<double> wallpaperAlignment;
  final int backgroundColor;
  final bool dark;
  final int accentColor;

  /// 主窗口当前的 `MoeGlassTheme`，小窗背景和根界面走同一套材质。
  final bool glassEnabled;
  final double glassBlurSigma;
  final double glassTintFill;
  final bool glassLiquid;

  Map<String, Object?> toJson() => {
    'conversationId': conversationId,
    'name': name,
    'avatarUrl': avatarUrl,
    'characterImage': characterImage,
    'wallpaper': wallpaper,
    'wallpaperStyle': wallpaperStyle,
    'wallpaperAlignment': wallpaperAlignment,
    'backgroundColor': backgroundColor,
    'dark': dark,
    'accentColor': accentColor,
    'glassEnabled': glassEnabled,
    'glassBlurSigma': glassBlurSigma,
    'glassTintFill': glassTintFill,
    'glassLiquid': glassLiquid,
  };

  factory VoiceCallWindowAppearance.fromJson(Map<Object?, Object?> json) =>
      VoiceCallWindowAppearance(
        conversationId: json['conversationId']! as String,
        name: json['name']! as String,
        avatarUrl: json['avatarUrl'] as String?,
        characterImage: json['characterImage'] as String?,
        wallpaper: json['wallpaper'] as String?,
        wallpaperStyle: Map<String, Object?>.from(
          json['wallpaperStyle'] as Map? ?? const {},
        ),
        wallpaperAlignment: [
          for (final v in json['wallpaperAlignment'] as List? ?? const [0, 0])
            (v as num).toDouble(),
        ],
        backgroundColor: json['backgroundColor']! as int,
        dark: json['dark'] as bool? ?? false,
        accentColor: json['accentColor']! as int,
        glassEnabled: json['glassEnabled'] as bool? ?? false,
        glassBlurSigma: (json['glassBlurSigma'] as num? ?? 0).toDouble(),
        glassTintFill: (json['glassTintFill'] as num? ?? 0).toDouble(),
        glassLiquid: json['glassLiquid'] as bool? ?? false,
      );

  @override
  bool operator ==(Object other) =>
      other is VoiceCallWindowAppearance &&
      jsonEncode(other.toJson()) == jsonEncode(toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}

/// 打开小窗时的引擎参数：通道名和初始外观。
@immutable
class VoiceCallWindowSeed {
  const VoiceCallWindowSeed({required this.channel, required this.appearance});

  final String channel;
  final VoiceCallWindowAppearance appearance;

  Map<String, Object?> toJson() => {
    'channel': channel,
    'appearance': appearance.toJson(),
  };

  factory VoiceCallWindowSeed.fromJson(Map<Object?, Object?> json) =>
      VoiceCallWindowSeed(
        channel: json['channel']! as String,
        appearance: VoiceCallWindowAppearance.fromJson(
          json['appearance']! as Map,
        ),
      );
}

Map<String, Object?> encodeVoiceCallState(VoiceCallControls call) => {
  'phase': call.phase.name,
  'error': call.error,
  'partial': call.partial,
  'muted': call.muted,
  'speakerOff': call.speakerOff,
  'ending': call.ending,
  'elapsedMs': call.elapsed.value.inMilliseconds,
  'turns': [
    for (final turn in call.transcript)
      {'role': turn.role, 'text': turn.text, 'interrupted': turn.interrupted},
  ],
};

/// 主窗口一侧：把这通电话推给小窗、执行小窗回传的按钮。小窗还没注册时
/// 发送会失败，忽略即可，小窗就绪后会要一次完整状态。
class VoiceCallWindowLink {
  VoiceCallWindowLink({
    required this.call,
    required VoiceCallWindowSend send,
    this.closeDelay = const Duration(milliseconds: 1200),
    VoidCallback? onClosed,
  }) : _send = send,
       _onClosed = onClosed {
    call.addListener(_onCallChanged);
    call.elapsed.addListener(_pushElapsed);
  }

  final ActiveVoiceCall call;
  final VoiceCallWindowSend _send;

  /// 通话结束后停留多久让用户看到「通话已结束」再关小窗；没接通的不自动关，
  /// 留着显示原因。
  final Duration closeDelay;
  final VoidCallback? _onClosed;
  bool _disposed = false;
  bool _closeScheduled = false;

  Future<Object?> handle(String method) async {
    switch (method) {
      case VoiceCallWindowMethods.ready:
        _pushState();
      case VoiceCallWindowMethods.toggleMute:
        if (call.connected) call.toggleMute();
      case VoiceCallWindowMethods.toggleSpeaker:
        if (call.connected) call.toggleSpeaker();
      case VoiceCallWindowMethods.hangUp:
        unawaited(call.hangUp());
      case VoiceCallWindowMethods.closed:
        // 用户关掉小窗即挂断（已在挂断时什么也不做）。
        unawaited(call.hangUp());
        dispose();
    }
    return null;
  }

  void _onCallChanged() {
    _pushState();
    if (call.phase == VoiceCallPhase.ended &&
        call.error == null &&
        !_closeScheduled) {
      _closeScheduled = true;
      Timer(closeDelay, () {
        if (_disposed) return;
        _post(VoiceCallWindowMethods.close);
        dispose();
      });
    }
  }

  void _pushState() =>
      _post(VoiceCallWindowMethods.state, encodeVoiceCallState(call));

  void _pushElapsed() =>
      _post(VoiceCallWindowMethods.elapsed, call.elapsed.value.inMilliseconds);

  void _post(String method, [Object? arguments]) {
    if (_disposed) return;
    unawaited(_send(method, arguments).catchError((Object _) {}));
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    call.removeListener(_onCallChanged);
    call.elapsed.removeListener(_pushElapsed);
    _onClosed?.call();
  }
}

/// 小窗一侧的这通电话：照主窗口推来的状态显示，按钮转发回主窗口。
class RemoteVoiceCall extends ChangeNotifier implements VoiceCallControls {
  RemoteVoiceCall(this._send);

  final VoiceCallWindowSend _send;

  @override
  final ValueNotifier<Duration> elapsed = ValueNotifier(Duration.zero);

  @override
  VoiceCallPhase phase = VoiceCallPhase.connecting;
  @override
  String? error;
  @override
  String partial = '';
  @override
  bool muted = false;
  @override
  bool speakerOff = false;
  @override
  bool ending = false;
  @override
  List<CallTurn> transcript = const [];

  @override
  bool get connected =>
      phase == VoiceCallPhase.listening ||
      phase == VoiceCallPhase.thinking ||
      phase == VoiceCallPhase.speaking;

  void apply(Map<Object?, Object?> state) {
    phase = VoiceCallPhase.values.asNameMap()[state['phase']] ?? phase;
    error = state['error'] as String?;
    partial = state['partial'] as String? ?? '';
    muted = state['muted'] as bool? ?? false;
    speakerOff = state['speakerOff'] as bool? ?? false;
    ending = state['ending'] as bool? ?? false;
    transcript = [
      for (final raw in state['turns'] as List? ?? const [])
        if (raw is Map)
          CallTurn(
            role: raw['role'] as String? ?? 'assistant',
            text: raw['text'] as String? ?? '',
            interrupted: raw['interrupted'] as bool? ?? false,
          ),
    ];
    applyElapsed(state['elapsedMs']);
    notifyListeners();
  }

  void applyElapsed(Object? ms) {
    if (ms is int) elapsed.value = Duration(milliseconds: ms);
  }

  @override
  void toggleMute() =>
      unawaited(_send(VoiceCallWindowMethods.toggleMute).catchError((_) {}));

  @override
  void toggleSpeaker() =>
      unawaited(_send(VoiceCallWindowMethods.toggleSpeaker).catchError((_) {}));

  @override
  Future<void> hangUp() async {
    if (!ending) {
      ending = true;
      notifyListeners();
    }
    await _send(VoiceCallWindowMethods.hangUp).catchError((Object _) {});
  }

  /// 用户关掉了小窗。
  Future<void> notifyClosed() =>
      _send(VoiceCallWindowMethods.closed).catchError((Object _) {});
}

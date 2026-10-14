import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/models/message_block.dart';
import '../../../../features/chat/domain/conversation.dart';
import '../../../../features/voice_call/application/active_voice_call.dart';
import '../../../../features/voice_call/application/voice_call_session.dart';
import '../../../../features/voice_call/domain/voice_call_ports.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../shared/widgets/index.dart';
import '../../chat/widgets/chat_wallpaper_background.dart';

/// 背景用这个角色的聊天背景（没有就用全局壁纸），上面压一层深色遮罩，
/// 文字和按钮固定白色（参照 Telegram 通话界面），不随应用主题变化。
const voiceCallHangUpRed = Color(0xFFE5484D);

/// 与角色的语音通话（ADR0074）。页面只是 [ActiveVoiceCall] 的视图：
/// 点「打字」收成聊天页里的悬浮窗，通话继续；直接离开页面即挂断并存档。
class VoiceCallPage extends ConsumerStatefulWidget {
  const VoiceCallPage({
    super.key,
    required this.conversation,
    required this.call,
  });

  final Conversation conversation;
  final ActiveVoiceCall call;

  @override
  ConsumerState<VoiceCallPage> createState() => _VoiceCallPageState();
}

class _VoiceCallPageState extends ConsumerState<VoiceCallPage>
    with TickerProviderStateMixin {
  bool _captions = true;
  bool _leaving = false;

  ActiveVoiceCall get _call => widget.call;

  /// 角色说话时头像外圈的波纹。
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  @override
  void initState() {
    super.initState();
    _call.addListener(_onCallChanged);
    _syncWithCall();
  }

  void _onCallChanged() {
    if (!mounted) return;
    setState(() {});
    _syncWithCall();
  }

  void _syncWithCall() {
    if (_call.phase == VoiceCallPhase.speaking) {
      if (!_pulse.isAnimating) _pulse.repeat();
    } else if (_pulse.isAnimating || _pulse.value != 0) {
      _pulse
        ..stop()
        ..value = 0;
    }
    // 识别出错等原因由会话自己挂断时，停留片刻让用户看到“通话已结束”再离开；
    // 没接通的留在页面上显示原因。
    if (_call.phase == VoiceCallPhase.ended &&
        _call.error == null &&
        !_leaving) {
      _leaving = true;
      Future<void>.delayed(const Duration(milliseconds: 1200), () {
        if (mounted) Navigator.of(context).maybePop();
      });
    }
  }

  void _hangUpPressed() {
    _leaving = true;
    Navigator.of(context).maybePop();
  }

  /// 收成悬浮窗，回到聊天页打字。
  void _typePressed() {
    _leaving = true;
    _call.minimize();
    Navigator.of(context).maybePop();
  }

  /// 按钮上方的状态提示（同 Telegram 的“麦克风已关闭”胶囊）。
  String? get _notice => !_call.connected
      ? null
      : _call.muted && _call.speakerOff
      ? '话筒和扬声器已关闭'
      : _call.muted
      ? '话筒已关闭，角色听不到你'
      : _call.speakerOff
      ? '扬声器已关闭，可以看字幕'
      : null;

  @override
  void dispose() {
    _call.removeListener(_onCallChanged);
    // 不是收成悬浮窗的离开（返回手势、挂断）都挂断并存档。
    if (!_call.minimized) unawaited(_call.hangUp());
    _pulse.dispose();
    super.dispose();
  }

  String get _statusText {
    if (_call.error != null) return _call.error!;
    return switch (_call.phase) {
      VoiceCallPhase.connecting => '正在接通…',
      VoiceCallPhase.ended => '通话已结束',
      _ => formatCallDuration(_call.elapsed.value),
    };
  }

  String get _activityText => switch (_call.phase) {
    VoiceCallPhase.listening when _call.muted => '',
    VoiceCallPhase.listening =>
      _call.partial.isNotEmpty ? _call.partial : '在听',
    VoiceCallPhase.thinking => '正在想…',
    VoiceCallPhase.speaking => '正在说',
    _ => '',
  };

  @override
  Widget build(BuildContext context) {
    final conv = widget.conversation;
    final turns = _call.transcript;
    final phase = _call.phase;
    final fallback = resolveChatBackgroundColor(
      context,
      ref.watch(appSettingsProvider).valueOrNull?.lightChatBackground,
    );
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 聊天背景自带的浅色遮罩不用，改由下面的深色遮罩压暗。
          ChatWallpaperLayer(
            image: conv.chatBackgroundImage,
            fallbackColor: fallback,
            style: chatWallpaperStyleOf(conv).copyWith(mask: 0),
          ),
          // 深色遮罩保证白字可读；通话结束时再压暗一些。
          AnimatedContainer(
            duration: const Duration(milliseconds: 600),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  for (final alpha
                      in phase == VoiceCallPhase.ended
                          ? const [0.62, 0.55, 0.72]
                          : const [0.42, 0.30, 0.58])
                    Colors.black.withValues(alpha: alpha),
                ],
              ),
            ),
          ),
          SafeArea(
            child: LayoutBuilder(
              builder: (context, box) {
                final avatar = math.min(140.0, box.maxHeight * 0.2);
                return Column(
                  children: [
                    SizedBox(height: box.maxHeight * 0.1),
                    VoiceCallPulsingAvatar(
                      animation: _pulse,
                      size: avatar,
                      child: MoeAvatar(
                        name: conv.displayName,
                        avatarUrl: conv.avatarUrl,
                        characterImage: conv.characterImage,
                        size: avatar,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Text(
                        conv.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: ValueListenableBuilder<Duration>(
                        valueListenable: _call.elapsed,
                        builder: (context, _, _) => Text(
                          _statusText,
                          key: const ValueKey('voice-call-status'),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 16,
                            color: Colors.white.withValues(alpha: 0.85),
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    AnimatedOpacity(
                      opacity: _activityText.isEmpty ? 0 : 1,
                      duration: const Duration(milliseconds: 200),
                      child: Text(
                        _activityText,
                        key: const ValueKey('voice-call-activity'),
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.white.withValues(alpha: 0.7),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _PillButton(
                          key: const ValueKey('voice-call-captions'),
                          icon: _captions
                              ? Icons.closed_caption_rounded
                              : Icons.closed_caption_off_outlined,
                          label: _captions ? '字幕' : '字幕已关',
                          on: _captions,
                          onTap: () => setState(() => _captions = !_captions),
                        ),
                        const SizedBox(width: 8),
                        _PillButton(
                          key: const ValueKey('voice-call-type'),
                          icon: Icons.keyboard_alt_outlined,
                          label: '打字',
                          on: false,
                          onTap: _call.connected ? _typePressed : null,
                        ),
                      ],
                    ),
                    Expanded(
                      child: _captions
                          ? _Captions(turns: turns)
                          : const SizedBox.shrink(),
                    ),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      child: _notice == null
                          ? const SizedBox(height: 32)
                          : _NoticePill(key: ValueKey(_notice), text: _notice!),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 36),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          VoiceCallRoundButton(
                            key: const ValueKey('voice-call-speaker'),
                            icon: _call.speakerOff
                                ? Icons.volume_off_rounded
                                : Icons.volume_up_rounded,
                            label: _call.speakerOff ? '扬声器已关' : '扬声器',
                            active: _call.speakerOff,
                            onTap: _call.connected
                                ? _call.toggleSpeaker
                                : null,
                          ),
                          VoiceCallRoundButton(
                            key: const ValueKey('voice-call-hang-up'),
                            icon: Icons.call_end_rounded,
                            label: '挂断',
                            color: voiceCallHangUpRed,
                            onTap: _hangUpPressed,
                          ),
                          VoiceCallRoundButton(
                            key: const ValueKey('voice-call-mute'),
                            icon: _call.muted
                                ? Icons.mic_off_rounded
                                : Icons.mic_rounded,
                            label: _call.muted ? '话筒已关' : '话筒',
                            active: _call.muted,
                            onTap: _call.connected ? _call.toggleMute : null,
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 头像外圈一圈圈扩散的波纹（角色说话、来电响铃时）。
class VoiceCallPulsingAvatar extends StatelessWidget {
  const VoiceCallPulsingAvatar({
    required this.animation,
    required this.size,
    required this.child,
  });

  final Animation<double> animation;
  final double size;
  final Widget child;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size * 1.45,
    height: size * 1.45,
    child: AnimatedBuilder(
      animation: animation,
      builder: (context, child) => Stack(
        alignment: Alignment.center,
        children: [
          for (final offset in const [0.0, 0.5])
            if (animation.value > 0) _ring((animation.value + offset) % 1),
          child!,
        ],
      ),
      child: child,
    ),
  );

  Widget _ring(double v) => Container(
    width: size * (1 + 0.45 * v),
    height: size * (1 + 0.45 * v),
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: Colors.white.withValues(alpha: 0.22 * (1 - v)),
    ),
  );
}

/// 最近几句通话字幕，新的在下面。
class _Captions extends StatelessWidget {
  const _Captions({required this.turns});

  final List<CallTurn> turns;

  @override
  Widget build(BuildContext context) {
    final recent = turns.length > 4 ? turns.sublist(turns.length - 4) : turns;
    return Align(
      alignment: Alignment.bottomCenter,
      child: SingleChildScrollView(
        reverse: true,
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final turn in recent)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Text(
                  turn.interrupted ? '${turn.spokenText}……' : turn.spokenText,
                  textAlign: turn.isUser ? TextAlign.right : TextAlign.left,
                  style: TextStyle(
                    fontSize: 15,
                    height: 1.4,
                    color: Colors.white.withValues(
                      alpha: turn.isUser ? 0.72 : 0.95,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _NoticePill extends StatelessWidget {
  const _NoticePill({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 32,
    child: Center(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            color: Colors.black.withValues(alpha: 0.18),
            child: Text(
              text,
              key: const ValueKey('voice-call-notice'),
              style: const TextStyle(fontSize: 13, color: Colors.white),
            ),
          ),
        ),
      ),
    ),
  );
}

/// 状态文字下面的小胶囊（字幕开关、打字），不占底部按钮位。
class _PillButton extends StatelessWidget {
  const _PillButton({
    super.key,
    required this.icon,
    required this.label,
    required this.on,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool on;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final fg = Colors.white.withValues(alpha: on ? 0.95 : 0.8);
    return Semantics(
      button: true,
      label: label,
      child: Opacity(
        opacity: onTap == null ? 0.5 : 1,
        child: Material(
          color: Colors.white.withValues(alpha: on ? 0.24 : 0.12),
          shape: const StadiumBorder(),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 16, color: fg),
                  const SizedBox(width: 4),
                  Text(label, style: TextStyle(fontSize: 12, color: fg)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 通话页底部的毛玻璃圆钮，下方带文字。
class VoiceCallRoundButton extends StatelessWidget {
  const VoiceCallRoundButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
    this.color,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  /// 开关类按钮打开时用白底深色图标（同 Telegram）。
  final bool active;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final fill =
        color ?? (active ? Colors.white : Colors.white.withValues(alpha: 0.18));
    final iconColor = color == null && active
        ? const Color(0xFF2C3440)
        : Colors.white;
    return Semantics(
      button: true,
      label: label,
      child: Opacity(
        opacity: onTap == null ? 0.5 : 1,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 毛玻璃圆钮（同 Telegram），背景渐变透过来。
            ClipOval(
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                child: Material(
                  color: fill,
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: onTap,
                    child: SizedBox(
                      width: 60,
                      height: 60,
                      child: Icon(icon, color: iconColor, size: 28),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: Colors.white.withValues(alpha: 0.9),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

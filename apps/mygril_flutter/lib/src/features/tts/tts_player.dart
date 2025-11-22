import 'package:audio_session/audio_session.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

final ttsPlayerProvider = Provider<TtsPlayer>((ref) => TtsPlayer());

class TtsPlayer {
  final AudioPlayer _player = AudioPlayer();
  bool _initialized = false;

  Future<void> _ensureSession() async {
    if (_initialized) return;
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.speech());
    _initialized = true;
  }

  Future<void> playUrl(String url) async {
    await _ensureSession();
    await _player.setUrl(url);
    await _player.play();
  }

  Future<void> dispose() async {
    await _player.dispose();
  }
}


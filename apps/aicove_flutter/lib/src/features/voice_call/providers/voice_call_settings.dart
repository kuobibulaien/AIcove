import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../settings/app_settings.dart';
import '../data/sherpa_local_speech_recognizer.dart';

/// 通话的语音识别来源。本地模型装在哪台设备上不一定，所以这个选择只存本机、不同步。
enum CallRecognizerSource {
  /// 装了本地模型就用本地，否则用阿里云。
  auto,
  local,
  aliyun,
}

const _sourceKey = 'aicove.voice_call.recognizer_source.v1';

final callRecognizerSourceProvider =
    AsyncNotifierProvider<CallRecognizerSourceNotifier, CallRecognizerSource>(
      CallRecognizerSourceNotifier.new,
    );

class CallRecognizerSourceNotifier extends AsyncNotifier<CallRecognizerSource> {
  @override
  Future<CallRecognizerSource> build() async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString(_sourceKey);
    return CallRecognizerSource.values.firstWhere(
      (value) => value.name == name,
      orElse: () => CallRecognizerSource.auto,
    );
  }

  Future<void> set(CallRecognizerSource source) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(_sourceKey, source.name)) {
      throw StateError('识别来源保存失败');
    }
    state = AsyncData(source);
  }
}

/// 本地识别模型的存放目录（应用支持目录下，模型下载功能写入同一位置）。
Future<String> voiceCallLocalModelDir() async {
  final support = await getApplicationSupportDirectory();
  return '${support.path}/voice_call/asr-models';
}

/// 本机已装好的本地识别模型；没装齐时为空。
Future<SherpaLocalModelFiles?> installedLocalCallModel() async {
  final local = SherpaLocalModelFiles.inDirectory(
    await voiceCallLocalModelDir(),
  );
  return File(local.senseVoiceModel).existsSync() &&
          File(local.vadModel).existsSync()
      ? local
      : null;
}

/// 阿里云百炼的密钥（复用模型供应商里配置的阿里云）。
String? aliyunCallRecognizerKey(AppSettings settings) {
  final key = settings.providers
      .where((p) => p.id == 'aliyun')
      .firstOrNull
      ?.apiKeys
      .firstOrNull
      ?.trim();
  return key == null || key.isEmpty ? null : key;
}

/// 设置页展示用：每个识别来源当前能不能用。
class CallRecognizerReadiness {
  const CallRecognizerReadiness({
    required this.localInstalled,
    required this.aliyunConfigured,
  });

  final bool localInstalled;
  final bool aliyunConfigured;
}

final callRecognizerReadinessProvider =
    FutureProvider.autoDispose<CallRecognizerReadiness>((ref) async {
      final settings = await ref.watch(appSettingsProvider.future);
      return CallRecognizerReadiness(
        localInstalled: await installedLocalCallModel() != null,
        aliyunConfigured: aliyunCallRecognizerKey(settings) != null,
      );
    });

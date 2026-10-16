import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../settings/app_settings.dart';
import '../domain/asr_request_format.dart';
import '../../../core/app_logger.dart';
import '../data/local_asr_model_installer.dart';
import '../data/sherpa_local_speech_recognizer.dart';

/// 通话的语音识别来源。本地模型装在哪台设备上不一定，所以这个选择只存本机、不同步。
///
/// 云端来源是渠道商里某个语音识别模型（渠道 id + 模型名），协议由渠道的识别格式决定。
class CallRecognizerSource {
  const CallRecognizerSource._(this.kind) : providerId = null, model = null;

  /// 装了本地模型就用本地，否则用渠道商里第一个能用的识别模型。
  static const auto = CallRecognizerSource._(CallRecognizerKind.auto);
  static const local = CallRecognizerSource._(CallRecognizerKind.local);

  const CallRecognizerSource.cloud(String this.providerId, String this.model)
    : kind = CallRecognizerKind.cloud;

  final CallRecognizerKind kind;
  final String? providerId;
  final String? model;

  String encode() => switch (kind) {
    CallRecognizerKind.cloud => jsonEncode({
      'provider': providerId,
      'model': model,
    }),
    _ => kind.name,
  };

  static CallRecognizerSource? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    if (raw == CallRecognizerKind.auto.name) return auto;
    if (raw == CallRecognizerKind.local.name) return local;
    try {
      final json = jsonDecode(raw);
      if (json is Map &&
          json['provider'] is String &&
          json['model'] is String) {
        return CallRecognizerSource.cloud(
          json['provider'] as String,
          json['model'] as String,
        );
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is CallRecognizerSource &&
      other.kind == kind &&
      other.providerId == providerId &&
      other.model == model;

  @override
  int get hashCode => Object.hash(kind, providerId, model);
}

enum CallRecognizerKind { auto, local, cloud }

const _sourceKey = 'aicove.voice_call.recognizer_source.v2';

/// v1 只有 auto／local／aliyun 三个枚举值。
const _legacySourceKey = 'aicove.voice_call.recognizer_source.v1';

final callRecognizerSourceProvider =
    AsyncNotifierProvider<CallRecognizerSourceNotifier, CallRecognizerSource>(
      CallRecognizerSourceNotifier.new,
    );

class CallRecognizerSourceNotifier extends AsyncNotifier<CallRecognizerSource> {
  @override
  Future<CallRecognizerSource> build() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = CallRecognizerSource.decode(prefs.getString(_sourceKey));
    if (stored != null) return stored;
    final legacy = prefs.getString(_legacySourceKey);
    if (legacy == 'local') return CallRecognizerSource.local;
    if (legacy == 'aliyun') {
      // 旧「阿里云百炼」迁到阿里云渠道里第一个识别模型。
      final settings = await ref.read(appSettingsProvider.future);
      final option = cloudRecognizerOptions(
        settings,
      ).where((o) => o.provider.id == 'aliyun').firstOrNull;
      if (option != null) return option.source;
    }
    return CallRecognizerSource.auto;
  }

  Future<void> set(CallRecognizerSource source) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(_sourceKey, source.encode())) {
      throw StateError('识别来源保存失败');
    }
    state = AsyncData(source);
  }
}

/// 渠道商里的一个语音识别模型。
class CloudRecognizerOption {
  const CloudRecognizerOption({
    required this.provider,
    required this.model,
    required this.format,
    this.missing,
  });

  final ProviderAuth provider;
  final String model;
  final AsrRequestFormat format;

  /// 缺的凭证（如「API Key」「AppID」）；齐了为 null。
  final String? missing;

  bool get ready => missing == null;

  CallRecognizerSource get source =>
      CallRecognizerSource.cloud(provider.id, model);

  String get label => '${provider.displayName ?? provider.id} · $model';
}

/// 所有启用的、设了识别格式的渠道里的识别模型，按渠道顺序。
List<CloudRecognizerOption> cloudRecognizerOptions(AppSettings settings) {
  final options = <CloudRecognizerOption>[];
  for (final provider in settings.providers) {
    final format = AsrRequestFormat.ofConfig(provider.customConfig);
    if (format == null || !provider.enabled) continue;
    final hasKey = provider.apiKeys.any((key) => key.trim().isNotEmpty);
    final missingField = format.credentialFields
        .where(
          (field) =>
              !field.optional &&
              (provider.customConfig[field.key]?.toString().trim() ?? '')
                  .isEmpty,
        )
        .firstOrNull;
    final missing = !hasKey ? format.apiKeyLabel : missingField?.label;
    for (final model in settings.getProviderVisibleModelsByType(
      provider.id,
      type: ModelType.stt,
    )) {
      options.add(
        CloudRecognizerOption(
          provider: provider,
          model: model,
          format: format,
          missing: missing,
        ),
      );
    }
  }
  return options;
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

/// 设置页展示用：每个识别来源当前能不能用。
class CallRecognizerReadiness {
  const CallRecognizerReadiness({
    required this.localInstalled,
    this.cloud = const <CloudRecognizerOption>[],
  });

  final bool localInstalled;
  final List<CloudRecognizerOption> cloud;

  CloudRecognizerOption? get firstReadyCloud =>
      cloud.where((o) => o.ready).firstOrNull;
}

final callRecognizerReadinessProvider =
    FutureProvider.autoDispose<CallRecognizerReadiness>((ref) async {
      final settings = await ref.watch(appSettingsProvider.future);
      return CallRecognizerReadiness(
        localInstalled: await installedLocalCallModel() != null,
        cloud: cloudRecognizerOptions(settings),
      );
    });

/// 本地识别模型的下载进度。全局保留，离开设置页下载也不中断。
class LocalCallModelInstallState {
  const LocalCallModelInstallState({
    this.downloading = false,
    this.received = 0,
    this.total = 0,
    this.error,
  });

  final bool downloading;
  final int received;
  final int total;

  /// 上次下载失败的原因；用户取消不算失败。
  final String? error;

  double get progress => total == 0 ? 0 : received / total;
}

final localCallModelInstallProvider =
    NotifierProvider<LocalCallModelInstallNotifier, LocalCallModelInstallState>(
      LocalCallModelInstallNotifier.new,
    );

class LocalCallModelInstallNotifier
    extends Notifier<LocalCallModelInstallState> {
  CancelToken? _cancel;

  /// 测试可替换：按模型目录造安装器。
  static LocalAsrModelInstaller Function(String dir) createInstaller = (dir) =>
      LocalAsrModelInstaller(dir: dir);

  @override
  LocalCallModelInstallState build() => const LocalCallModelInstallState();

  Future<void> install() async {
    if (state.downloading) return;
    final installer = createInstaller(await voiceCallLocalModelDir());
    final cancel = _cancel = CancelToken();
    state = LocalCallModelInstallState(
      downloading: true,
      total: installer.totalBytes,
    );
    try {
      await installer.install(
        cancelToken: cancel,
        onProgress: (received, total) {
          state = LocalCallModelInstallState(
            downloading: true,
            received: received,
            total: total,
          );
        },
      );
      AppLogger.info('VoiceCall', '本地识别模型安装完成');
      state = const LocalCallModelInstallState();
    } on DioException catch (e) {
      state = CancelToken.isCancel(e)
          ? const LocalCallModelInstallState()
          : LocalCallModelInstallState(error: e.message ?? e.type.name);
    } catch (e) {
      AppLogger.warning('VoiceCall', '本地识别模型安装失败：$e');
      state = LocalCallModelInstallState(error: e.toString());
    } finally {
      if (identical(_cancel, cancel)) _cancel = null;
      ref.invalidate(callRecognizerReadinessProvider);
    }
  }

  void cancel() => _cancel?.cancel();

  Future<void> uninstall() async {
    cancel();
    await createInstaller(await voiceCallLocalModelDir()).uninstall();
    state = const LocalCallModelInstallState();
    ref.invalidate(callRecognizerReadinessProvider);
  }
}

import 'dart:io';
import 'dart:typed_data';

import '../../../core/storage/app_data_directory.dart';
import 'providers/tts_voice_provider.dart';
import 'tts_available_models.dart';
import 'tts_config.dart';
import 'tts_provider_context.dart';

/// Copies a picked reference audio file into `appDataDirectory()/voices` and
/// returns the stored path.
Future<String> storeVoiceFile({
  required String sourcePath,
  required String name,
}) async {
  final bytes = await File(sourcePath).readAsBytes();
  final appDir = await appDataDirectory();
  final voicesDir = Directory('${appDir.path}/voices');
  if (!await voicesDir.exists()) {
    await voicesDir.create(recursive: true);
  }

  final fileName = '${DateTime.now().millisecondsSinceEpoch}_$name';
  final savedFile = File('${voicesDir.path}/$fileName');
  await savedFile.writeAsBytes(bytes);
  return savedFile.path;
}

Future<Uint8List> readVoiceFileBytes(String path) => File(path).readAsBytes();

/// Deletes a local reference audio file the editor copied but no preset keeps:
/// [savedPath] is the one the preset stores, [keepPath] another to spare.
void deleteVoiceFileIfNeeded(
  String? path, {
  required String? savedPath,
  String? keepPath,
}) {
  if (path == null || path.isEmpty || path == savedPath) return;
  if (path == keepPath) return;
  try {
    File(path).deleteSync();
  } catch (_) {}
}

String? extractVoiceFileName(String? path) {
  if (path == null || path.isEmpty) return null;
  return path.split('/').last.split('\\').last;
}

/// Replaces the binding for the same channel and model, else appends it.
List<VoiceChannelBinding> upsertVoiceBinding(
  List<VoiceChannelBinding> bindings,
  VoiceChannelBinding binding,
) {
  final next = [...bindings];
  final index = next.indexWhere((item) {
    final sameAdapter =
        item.normalizedAdapterId != null &&
        binding.normalizedAdapterId != null &&
        item.normalizedAdapterId == binding.normalizedAdapterId;
    final sameProvider =
        item.normalizedProviderId == binding.normalizedProviderId;
    return (sameAdapter || sameProvider) &&
        (item.modelId ?? '') == (binding.modelId ?? '');
  });
  if (index >= 0) {
    next[index] = binding;
  } else {
    next.add(binding);
  }
  return next;
}

List<VoiceChannelBinding> removeVoiceBinding(
  List<VoiceChannelBinding> bindings,
  VoiceChannelBinding binding,
) {
  return bindings.where((item) {
    return !(item.providerId == binding.providerId &&
        item.adapterId == binding.adapterId &&
        (item.modelId ?? '') == (binding.modelId ?? '') &&
        item.remoteVoiceId == binding.remoteVoiceId);
  }).toList();
}

/// The binding for [entry] in a voice a channel just created.
VoiceChannelBinding bindingFromRemoteVoice({
  required VoicePreset remoteVoice,
  required TtsAvailableModelEntry entry,
  required TtsProviderContext bindingContext,
}) {
  final matchedBinding = remoteVoice.resolveBinding(
    providerId: entry.providerId,
    adapterId: bindingContext.voiceProviderId,
    modelId: entry.modelId,
  );
  if (matchedBinding != null) {
    return matchedBinding;
  }

  String? remoteVoiceId;
  for (final binding in remoteVoice.effectiveBindings) {
    final candidate = binding.remoteVoiceId.trim();
    if (candidate.isNotEmpty) {
      remoteVoiceId = candidate;
      break;
    }
  }
  remoteVoiceId ??= remoteVoice.aliyunVoiceId?.trim();
  remoteVoiceId ??= remoteVoice.siliconFlowVoiceUri?.trim();

  if (remoteVoiceId == null || remoteVoiceId.isEmpty) {
    throw TtsProviderException('渠道返回成功，但未解析到音色 ID');
  }

  return VoiceChannelBinding(
    providerId: entry.providerId,
    providerName: entry.providerName,
    adapterId:
        bindingContext.voiceProviderId ??
        entry.voiceProviderId ??
        entry.providerId,
    modelId: entry.modelId,
    remoteVoiceId: remoteVoiceId,
    status: remoteVoice.aliyunVoiceStatus,
    sourceKind: VoiceBindingSourceKind.remoteCreated,
  );
}

String describeBindingCapability({
  required TtsAvailableModelEntry entry,
  required TtsCapabilities? capabilities,
  required TtsProviderContext? bindingContext,
}) {
  final parts = <String>['${entry.providerName} / ${entry.displayName}'];

  if (bindingContext == null || !bindingContext.hasVoiceProvider) {
    parts.add('当前渠道暂不支持在线创建，只能手填音色 ID');
    return parts.join(' · ');
  }

  if (capabilities != null) {
    final uploadModes = <String>[];
    if (capabilities.canUploadUrl) uploadModes.add('公网直链');
    if (capabilities.canUploadFile) uploadModes.add('本地文件');
    if (uploadModes.isNotEmpty) {
      parts.add('支持 ${uploadModes.join(' / ')}');
    }
    if (capabilities.needsPromptText) {
      parts.add('生成时需要参考文本');
    }
    if (capabilities.needsApproval) {
      parts.add('创建后需审核');
    }
  }

  parts.add(bindingContext.hasApiKey ? '可在线创建' : '缺少 API Key');
  return parts.join(' · ');
}

String describeVoiceBindingSource(VoiceBindingSourceKind sourceKind) {
  switch (sourceKind) {
    case VoiceBindingSourceKind.remoteCreated:
      return '在线创建';
    case VoiceBindingSourceKind.manual:
      return '手动填写';
    case VoiceBindingSourceKind.imported:
      return '远端导入';
    case VoiceBindingSourceKind.legacy:
      return '旧字段迁移';
  }
}

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_logger.dart';
import '../plugins/domain/plugin.dart';
import '../plugins/domain/plugin_content.dart';
import '../plugins/image/image_config.dart';
import '../plugins/tts/voice_request.dart';
import '../settings/app_settings.dart';

/// Inputs for processing one assistant reply. A request reply carries the
/// drawing and voice snapshots fixed when the request was prepared; a cached
/// reply has no drawing snapshot and processes with live configuration.
class PluginResponseInputs {
  const PluginResponseInputs({
    required this.ref,
    required this.voiceRequest,
    this.drawingConfig,
    this.settings,
    this.rolePluginIds,
  });

  final Ref ref;
  final VoiceRequest? voiceRequest;

  /// The reply owner's raw plugin list (null = all plugins), for plugins
  /// that read per-role grants from it.
  final Set<String>? rolePluginIds;

  /// Image configuration fixed at prepare; null for cached replies.
  final ImageConfig? drawingConfig;

  /// Settings fixed at prepare, used with [drawingConfig].
  final AppSettings? settings;
}

/// Order values for [PluginResponseProcessor.order].
abstract final class ResponseOrder {
  static const normal = 0;

  /// Runs after every [normal] processor, on text whose plugin tags are
  /// already removed (speech must not read out other plugins' markup).
  static const afterTagRemoval = 100;
}

/// Post-processes one assistant reply for one plugin (replaced
/// `Plugin.processResponse`, removed in batch 2c).
abstract class PluginResponseProcessor {
  String get pluginId;

  /// Lower runs first; ties keep plugin order.
  int get order => ResponseOrder.normal;

  Future<PluginProcessResult> process(String text);
}

/// A processor backed by a function.
class ResponseFunction extends PluginResponseProcessor {
  ResponseFunction(
    this.pluginId,
    this._process, {
    this.order = ResponseOrder.normal,
  });

  @override
  final String pluginId;

  @override
  final int order;

  final Future<PluginProcessResult> Function(String text) _process;

  @override
  Future<PluginProcessResult> process(String text) => _process(text);
}

typedef PluginResponseProcessorFactory = PluginResponseProcessor Function(
  PluginResponseInputs inputs,
);

/// The single traversal both reply paths use: processors run in [order]
/// (ties in plugin order), each on the previous one's text. A processor that
/// throws is skipped and logged; the others still run.
Future<PluginProcessResult> runResponseProcessors(
  List<PluginResponseProcessor> processors,
  String text, {
  required String logTag,
  String failureMessage = '插件响应处理失败',
}) async {
  if (processors.isEmpty) {
    return PluginProcessResult(processedText: text, events: const []);
  }
  final ordered = [
    for (final (index, processor) in processors.indexed) (index, processor),
  ]..sort((a, b) {
      final byOrder = a.$2.order.compareTo(b.$2.order);
      return byOrder != 0 ? byOrder : a.$1.compareTo(b.$1);
    });

  var currentText = text;
  final events = <PluginEvent>[];
  final contents = <PluginContent>[];
  for (final (_, processor) in ordered) {
    try {
      final result = await processor.process(currentText);
      currentText = result.processedText;
      events.addAll(result.events);
      contents.addAll(result.contents);
    } catch (e) {
      AppLogger.warning(
        logTag,
        failureMessage,
        metadata: {'pluginId': processor.pluginId, 'error': e.toString()},
      );
    }
  }
  return PluginProcessResult(
    processedText: currentText,
    events: events,
    contents: contents,
  );
}

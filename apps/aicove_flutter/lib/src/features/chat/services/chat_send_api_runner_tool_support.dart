part of 'chat_send_api_runner.dart';

Future<_ToolExecutionOutcome> _executeToolCall({
  required ToolCall toolCall,
  required List<Plugin> effectivePlugins,
  List<AITool>? availableTools,
  required Duration toolTimeout,
  required CallFlowSettings flowSettings,
  required void Function(String toolName)? onToolExecuting,
  required bool drawImageStableReviewEnabled,
  required String sessionId,
  required String turnId,
  required String? boundImageToolPresetName,
  required String? boundImageArtistPresetName,
  required TraceContext? traceContext,
  required int round,
  required bool useFastToolRoute,
}) async {
  final startedAt = DateTime.now();
  if (traceContext != null) {
    await TraceStore.instance.record(
      traceId: traceContext.traceId,
      sessionId: traceContext.sessionId,
      turnId: traceContext.turnId,
      roundIndex: round,
      stage: TraceStage.toolExecStarted,
      status: TraceEventStatus.running,
      source: 'ChatSendApiRunner',
      startedAt: startedAt,
      endedAt: startedAt,
      durationMs: 0,
      meta: {
        'toolName': toolCall.name,
        'toolCallId': toolCall.id,
      },
    );
  }

  var finishedStatus = TraceEventStatus.success;
  var finishMeta = <String, dynamic>{
    'toolName': toolCall.name,
    'toolCallId': toolCall.id,
  };
  try {
    final tool = _findToolByName(
      effectivePlugins,
      toolCall.name,
      availableTools: availableTools,
    );
    if (tool == null) {
      AppLogger.warning(
        ChatSendApiRunner._logTag,
        'Tool not found',
        metadata: {'name': toolCall.name},
      );
      finishedStatus = TraceEventStatus.failed;
      finishMeta['error'] = 'tool_not_found';
      return _ToolExecutionOutcome(
        toolResult: ToolResult(
          toolCallId: toolCall.id,
          name: toolCall.name,
          result: jsonEncode({'error': 'Tool not found: ${toolCall.name}'}),
        ),
      );
    }

    onToolExecuting?.call(toolCall.name);
    final actualFlowMode = useFastToolRoute
        ? EffectiveImageGenerationRoute.fast.value
        : EffectiveImageGenerationRoute.stable.value;
    final executionArgs = _buildToolArgumentsForExecution(
      toolName: toolCall.name,
      originalArguments: toolCall.arguments,
      useFastToolRoute: useFastToolRoute,
      flowMode: actualFlowMode,
      sessionId: sessionId,
      turnId: turnId,
      roleToolPresetName: boundImageToolPresetName,
      roleArtistPresetName: boundImageArtistPresetName,
    );
    AppLogger.info(ChatSendApiRunner._logTag, '执行工具调用', metadata: {
      'round': round,
      'name': toolCall.name,
      'args': executionArgs,
    });

    final result = await tool.handler(executionArgs).timeout(toolTimeout);
    final resultStr = result ?? '';
    finishMeta['rawResultLength'] = resultStr.length;
    AppLogger.info(ChatSendApiRunner._logTag, '工具调用完成', metadata: {
      'name': toolCall.name,
      'result': resultStr,
    });

    if (toolCall.name == 'speak') {
      ToolAudioResult? audioResult;
      try {
        final parsed = jsonDecode(resultStr) as Map<String, dynamic>;
        final success = parsed['success'] == true;
        final audioUrl = parsed['audioUrl'] as String?;
        final text = parsed['text'] as String? ?? '';
        if (success && audioUrl != null && audioUrl.isNotEmpty) {
          audioResult = ToolAudioResult(audioUrl: audioUrl, text: text);
          finishMeta['audioProduced'] = true;
          AppLogger.info(ChatSendApiRunner._logTag, '收集到 speak 工具音频',
              metadata: {
                'audioUrlLength': audioUrl.length,
                'text': text,
              });
        }
      } catch (e) {
        AppLogger.warning(ChatSendApiRunner._logTag, '解析 speak 结果失败',
            metadata: {'error': e.toString()});
      }

      return _ToolExecutionOutcome(
        toolResult: ToolResult(
          toolCallId: toolCall.id,
          name: toolCall.name,
          result: '{"success": true, "message": "语音已播放给用户"}',
        ),
        audioResult: audioResult,
      );
    }

    if (toolCall.name == 'draw_image') {
      final asyncAccepted = _isAsyncDrawImageAccepted(resultStr);
      final imageContents = _extractToolImageContents(resultStr);
      final requiresStableVisionReview = drawImageStableReviewEnabled &&
          !useFastToolRoute &&
          imageContents.isNotEmpty;
      finishMeta['imageCount'] = imageContents.length;
      finishMeta['asyncAccepted'] = asyncAccepted;
      finishMeta['stableVisionReview'] = requiresStableVisionReview;
      finishMeta['actualFlowMode'] = actualFlowMode;
      if (imageContents.isNotEmpty) {
        AppLogger.info(
          ChatSendApiRunner._logTag,
          'Collected draw_image tool images',
          metadata: {'count': imageContents.length},
        );
      }
      return _ToolExecutionOutcome(
        toolResult: ToolResult(
          toolCallId: toolCall.id,
          name: toolCall.name,
          result: _buildToolResultForModel(
            toolName: toolCall.name,
            rawResult: resultStr,
            drawImageDeliveredToChat: !requiresStableVisionReview,
            drawImageRequiresReview: requiresStableVisionReview,
          ),
        ),
        imageContents: imageContents,
        isAsyncAcceptedDrawImage: asyncAccepted,
      );
    }

    return _ToolExecutionOutcome(
      toolResult: ToolResult(
        toolCallId: toolCall.id,
        name: toolCall.name,
        result: _buildToolResultForModel(
          toolName: toolCall.name,
          rawResult: resultStr,
        ),
      ),
    );
  } on TimeoutException {
    finishedStatus = TraceEventStatus.failed;
    finishMeta['error'] = 'timeout';
    AppLogger.warning(ChatSendApiRunner._logTag, '工具调用超时', metadata: {
      'name': toolCall.name,
      'timeoutSec': flowSettings.toolTimeoutSeconds,
    });
    return _ToolExecutionOutcome(
      toolResult: ToolResult(
        toolCallId: toolCall.id,
        name: toolCall.name,
        result: jsonEncode(
          {'error': 'Tool timeout after ${flowSettings.toolTimeoutSeconds}s'},
        ),
      ),
    );
  } catch (e) {
    finishedStatus = TraceEventStatus.failed;
    finishMeta['error'] = e.toString();
    AppLogger.error(ChatSendApiRunner._logTag, '工具调用失败', metadata: {
      'name': toolCall.name,
      'error': e.toString(),
    });
    return _ToolExecutionOutcome(
      toolResult: ToolResult(
        toolCallId: toolCall.id,
        name: toolCall.name,
        result: jsonEncode({'error': e.toString()}),
      ),
    );
  } finally {
    if (traceContext != null) {
      final endedAt = DateTime.now();
      await TraceStore.instance.record(
        traceId: traceContext.traceId,
        sessionId: traceContext.sessionId,
        turnId: traceContext.turnId,
        roundIndex: round,
        stage: TraceStage.toolExecFinished,
        status: finishedStatus,
        source: 'ChatSendApiRunner',
        startedAt: startedAt,
        endedAt: endedAt,
        durationMs: endedAt.difference(startedAt).inMilliseconds,
        meta: finishMeta,
      );
    }
  }
}

AITool? _findToolByName(
  List<Plugin> plugins,
  String name, {
  List<AITool>? availableTools,
}) {
  if (availableTools != null) {
    for (final tool in availableTools) {
      if (tool.name == name) return tool;
    }
    return null;
  }

  for (final plugin in plugins) {
    try {
      final tools = plugin.getTools();
      for (final tool in tools) {
        if (tool.name == name) return tool;
      }
    } catch (e) {
      AppLogger.warning(ChatSendApiRunner._logTag, '插件工具查找失败', metadata: {
        'pluginId': plugin.id,
        'toolName': name,
        'error': e.toString(),
      });
    }
  }
  return null;
}

String? _encodeToolCallsForLog(List<ToolCall> calls) {
  if (calls.isEmpty) return null;
  return jsonEncode([
    for (final call in calls)
      {
        'id': call.id,
        'name': call.name,
        'arguments': call.arguments,
      },
  ]);
}

String? _encodeToolResultsForLog(List<ToolResult> results) {
  if (results.isEmpty) return null;
  return jsonEncode([
    for (final result in results)
      {
        'toolCallId': result.toolCallId,
        'name': result.name,
        'result': result.result,
      },
  ]);
}

List<PluginImageContent> _extractToolImageContents(String result) {
  final trimmed = result.trim();
  if (trimmed.isEmpty) return const <PluginImageContent>[];

  final payload = _tryParseJsonMap(trimmed);
  if (payload == null) return const <PluginImageContent>[];

  final contents = <PluginImageContent>[];
  final seenPaths = <String>{};

  void collect(dynamic value, {String? fallbackCaption}) {
    String localPath = '';
    String? caption;

    if (value is Map) {
      final map = _toStringDynamicMap(value);
      localPath = (map['localPath'] ??
                  map['image_path'] ??
                  map['imagePath'] ??
                  map['path'])
              ?.toString()
              .trim() ??
          '';
      caption = map['caption']?.toString().trim();
      caption ??= map['prompt']?.toString().trim();
    } else if (value is String) {
      localPath = value.trim();
    }

    if (localPath.isEmpty || !seenPaths.add(localPath)) {
      return;
    }

    final effectiveCaption = (caption == null || caption.isEmpty)
        ? (fallbackCaption == null || fallbackCaption.isEmpty
            ? null
            : fallbackCaption)
        : caption;
    contents.add(PluginImageContent(localPath, caption: effectiveCaption));
  }

  final promptCaption = payload['prompt']?.toString().trim();
  final images = payload['images'];
  if (images is List) {
    for (final image in images) {
      collect(image, fallbackCaption: promptCaption);
    }
  }

  collect(payload['image'], fallbackCaption: promptCaption);
  collect(payload['image_path'], fallbackCaption: promptCaption);
  collect(payload['imagePath'], fallbackCaption: promptCaption);
  collect(payload['localPath'], fallbackCaption: promptCaption);
  collect(payload['path'], fallbackCaption: promptCaption);

  final data = payload['data'];
  if (data is Map) {
    final dataMap = _toStringDynamicMap(data);
    collect(dataMap['image'], fallbackCaption: promptCaption);
    collect(dataMap['image_path'], fallbackCaption: promptCaption);
    collect(dataMap['imagePath'], fallbackCaption: promptCaption);
    collect(dataMap['localPath'], fallbackCaption: promptCaption);
    collect(dataMap['path'], fallbackCaption: promptCaption);
    final dataImages = dataMap['images'];
    if (dataImages is List) {
      for (final image in dataImages) {
        collect(image, fallbackCaption: promptCaption);
      }
    }
  }

  return contents;
}

List<PluginImageContent> _selectStableReviewImages(
  List<PluginImageContent> images,
) {
  if (images.isEmpty) return const <PluginImageContent>[];
  return <PluginImageContent>[images.first];
}

Future<List<Map<String, dynamic>>> _buildStableDrawImageReviewMessages(
  List<PluginImageContent> images,
) async {
  if (images.isEmpty) return const <Map<String, dynamic>>[];

  final content = <Map<String, dynamic>>[
    <String, dynamic>{
      'type': 'text',
      'text': ChatSendApiRunner._stableDrawImageReviewInstruction,
    },
  ];

  for (final image in images) {
    final imagePart = await _buildLocalImageInputPart(image.localPath);
    if (imagePart != null) {
      content.add(imagePart);
    }
  }

  if (content.length <= 1) {
    AppLogger.warning(
      ChatSendApiRunner._logTag,
      'Stable draw_image review image load failed',
    );
    return const <Map<String, dynamic>>[];
  }

  return <Map<String, dynamic>>[
    <String, dynamic>{
      'role': 'user',
      'content': content,
    },
  ];
}

Future<Map<String, dynamic>?> _buildLocalImageInputPart(
    String localPath) async {
  final trimmed = localPath.trim();
  if (trimmed.isEmpty) return null;

  try {
    final file = File(trimmed);
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) return null;
    final mime = MimeUtils.guessImageMimeType(trimmed);
    final base64 = base64Encode(bytes);
    return <String, dynamic>{
      'type': 'image_url',
      'image_url': <String, dynamic>{
        'url': 'data:$mime;base64,$base64',
      },
    };
  } catch (e) {
    AppLogger.warning(
      ChatSendApiRunner._logTag,
      'Stable draw_image review image read failed',
      metadata: {
        'path': trimmed,
        'error': e.toString(),
      },
    );
    return null;
  }
}

bool _containsImagePlaceholder(String text) =>
    ChatSendApiRunner._imagePlaceholderRegex.hasMatch(text);

List<ToolCall> _extractFallbackToolCalls(String text) =>
    ChatSendApiRunner._fallbackParser.extractFallbackToolCalls(text);

Map<String, dynamic>? _tryParseJsonMap(String raw) =>
    ChatSendApiRunner._fallbackParser.tryParseJsonMap(raw);

Map<String, dynamic> _toStringDynamicMap(Map raw) =>
    ChatSendApiRunner._fallbackParser.toStringDynamicMap(raw);

String _buildToolCallSignature(ToolCall call) {
  final keys = call.arguments.keys.toList()..sort();
  final normalizedArgs = <String, dynamic>{};
  for (final key in keys) {
    normalizedArgs[key] = call.arguments[key];
  }
  return '${call.name}:${jsonEncode(normalizedArgs)}';
}

Map<String, dynamic> _buildToolArgumentsForExecution({
  required String toolName,
  required Map<String, dynamic> originalArguments,
  required bool useFastToolRoute,
  required String flowMode,
  required String sessionId,
  required String turnId,
  required String? roleToolPresetName,
  required String? roleArtistPresetName,
}) {
  if (toolName != 'draw_image') {
    return originalArguments;
  }
  final args = Map<String, dynamic>.from(originalArguments);
  args['_aicove_flow_mode'] = flowMode;
  args['_aicove_session_id'] = sessionId;
  args['_aicove_turn_id'] = turnId;
  if (useFastToolRoute) {
    args['_aicove_async'] = true;
  }
  if (roleToolPresetName != null && roleToolPresetName.trim().isNotEmpty) {
    args['_aicove_role_tool_preset_name'] = roleToolPresetName.trim();
  }
  if (roleArtistPresetName != null && roleArtistPresetName.trim().isNotEmpty) {
    args['_aicove_role_artist_preset_name'] = roleArtistPresetName.trim();
  }
  return args;
}

bool _shouldUseFastToolRoute({
  required bool fastModeEnabled,
  required List<ToolCall> toolCalls,
}) {
  if (!fastModeEnabled || toolCalls.isEmpty) {
    return false;
  }
  return toolCalls.every((call) => call.name == 'draw_image');
}

bool _isAsyncDrawImageAccepted(String rawResult) {
  final payload = _tryParseJsonMap(rawResult.trim());
  if (payload == null) return false;
  final success = payload['success'];
  final successOk = success is bool ? success : true;
  if (!successOk) return false;

  final accepted = payload['accepted'] == true;
  final status = payload['status']?.toString().trim().toLowerCase() ?? '';
  final hasJobId = [payload['job_id'], payload['jobId'], payload['id']]
      .any((value) => value != null && value.toString().trim().isNotEmpty);
  final isPendingStatus =
      status == 'pending' || status == 'accepted' || status == 'queued';

  return accepted || (hasJobId && isPendingStatus);
}

String _buildToolResultForModel({
  required String toolName,
  required String rawResult,
  bool drawImageDeliveredToChat = true,
  bool drawImageRequiresReview = false,
}) {
  if (toolName != 'draw_image') {
    return rawResult;
  }

  final payload = _tryParseJsonMap(rawResult.trim());
  if (payload == null) {
    return rawResult;
  }

  final summary = <String, dynamic>{};

  void copyTrimmedString(String key, {String? toKey}) {
    final value = payload[key]?.toString().trim();
    if (value == null || value.isEmpty) return;
    summary[toKey ?? key] = value;
  }

  final success = payload['success'];
  if (success is bool) {
    summary['success'] = success;
  }

  final provider = payload['provider']?.toString().trim();
  if (provider != null && provider.isNotEmpty) {
    summary['provider'] = provider;
  }

  final model = payload['model']?.toString().trim();
  if (model != null && model.isNotEmpty) {
    summary['model'] = model;
  }

  final accepted = payload['accepted'];
  if (accepted is bool) {
    summary['accepted'] = accepted;
  }
  final status = payload['status']?.toString().trim();
  if (status != null && status.isNotEmpty) {
    summary['status'] = status;
  }
  final jobId = (payload['job_id'] ?? payload['jobId'] ?? payload['id'])
      ?.toString()
      .trim();
  if (jobId != null && jobId.isNotEmpty) {
    summary['job_id'] = jobId;
  }

  var imageCount = 0;
  final images = payload['images'];
  if (images is List) {
    imageCount = images.length;
  } else {
    final hasSingleImage = [
      payload['image'],
      payload['image_path'],
      payload['imagePath'],
      payload['localPath'],
      payload['path'],
    ].any((value) => value != null && value.toString().trim().isNotEmpty);
    if (hasSingleImage) {
      imageCount = 1;
    }
  }
  summary['image_count'] = imageCount;

  final prompt = payload['prompt']?.toString().trim();
  if (prompt != null && prompt.isNotEmpty) {
    summary['prompt'] = prompt;
  }
  copyTrimmedString('raw_prompt');
  copyTrimmedString('negative_prompt');
  copyTrimmedString('artist_preset_name');
  copyTrimmedString('artist_preset_source');
  copyTrimmedString('artist_prompt_prefix');
  copyTrimmedString('artist_negative_prompt');

  if (imageCount > 0) {
    summary['image_present'] = true;
    if (drawImageDeliveredToChat) {
      summary['delivered_to_chat'] = true;
    } else {
      summary['image_delivery_pending'] = true;
    }
    if (drawImageRequiresReview) {
      summary['image_review_pending'] = true;
    }
  } else if (accepted == true) {
    summary['image_delivery_pending'] = true;
  }

  final message = payload['message']?.toString().trim();
  if (message != null && message.isNotEmpty) {
    summary['message'] = message;
  }

  final error = payload['error']?.toString().trim();
  if (error != null && error.isNotEmpty) {
    summary['error'] = error;
  }

  return jsonEncode(summary);
}

Map<String, dynamic> _buildFallbackAssistantMessageForToolCalls(
  List<ToolCall> toolCalls,
  String adapterName,
) {
  if (adapterName != 'openai' && adapterName != 'minimax') {
    return <String, dynamic>{'content': ''};
  }
  return <String, dynamic>{
    'content': null,
    'tool_calls': [
      for (var i = 0; i < toolCalls.length; i++)
        {
          'id': toolCalls[i].id.trim().isNotEmpty
              ? toolCalls[i].id
              : 'fallback_tool_call_${i + 1}',
          'type': 'function',
          'function': {
            'name': toolCalls[i].name,
            'arguments': jsonEncode(toolCalls[i].arguments),
          },
        },
    ],
  };
}

Map<String, dynamic> _buildAssistantMessageFromRich(
  SendMessageRichResult rich,
  String adapterName,
) {
  switch (adapterName) {
    case 'claude':
    case 'anthropic':
      return rich.rawResponse ?? {'content': []};
    case 'gemini':
    case 'google':
      final candidates = (rich.rawResponse?['candidates'] as List?) ?? [];
      if (candidates.isNotEmpty) {
        final first = candidates.first as Map<String, dynamic>;
        return {'content': first['content']};
      }
      return {
        'content': {'parts': []},
      };
    default:
      final choices = (rich.rawResponse?['choices'] as List?) ?? [];
      if (choices.isNotEmpty) {
        final first = choices.first as Map<String, dynamic>;
        return first['message'] as Map<String, dynamic>? ?? {};
      }
      return {};
  }
}

class _ToolExecutionOutcome {
  const _ToolExecutionOutcome({
    required this.toolResult,
    this.audioResult,
    this.imageContents = const <PluginImageContent>[],
    this.isAsyncAcceptedDrawImage = false,
  });

  final ToolResult toolResult;
  final ToolAudioResult? audioResult;
  final List<PluginImageContent> imageContents;
  final bool isAsyncAcceptedDrawImage;
}

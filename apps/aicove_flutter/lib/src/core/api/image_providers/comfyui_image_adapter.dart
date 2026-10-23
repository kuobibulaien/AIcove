import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'comfyui_workflow.dart';
import 'image_provider_adapter.dart';

class ComfyUIImageAdapter implements ImageProviderAdapter {
  const ComfyUIImageAdapter({this.pollInterval = const Duration(seconds: 1)});

  final Duration pollInterval;

  @override
  String get name => 'comfyui';

  static Uri endpoint(
    String baseUrl,
    String path, [
    Map<String, String>? query,
  ]) {
    final base = Uri.tryParse(baseUrl.trim());
    if (base == null ||
        !const ['http', 'https'].contains(base.scheme) ||
        base.host.isEmpty ||
        base.userInfo.isNotEmpty ||
        base.hasQuery ||
        base.hasFragment) {
      throw const FormatException('请输入 ComfyUI 的 HTTP(S) 服务地址，不含查询参数或账号密码');
    }
    return base.replace(
      path: '${base.path.replaceFirst(RegExp(r'/+$'), '')}/$path',
      queryParameters: query,
    );
  }

  /// Prefers the readable reason from ComfyUI (`error.message`) or the
  /// modal-comfy gateway (`detail`, e.g. the monthly budget refusal).
  static String errorMessage(http.Response response) {
    final text = utf8.decode(response.bodyBytes, allowMalformed: true);
    try {
      final data = jsonDecode(text);
      final error = data is Map ? data['error'] : null;
      final message = data is Map && data['detail'] is String
          ? data['detail'] as String
          : error is Map && error['message'] is String
          ? error['message'] as String
          : null;
      if (message != null && message.trim().isNotEmpty) return message.trim();
    } on FormatException {
      // Fall through to the raw body.
    }
    return text;
  }

  /// Template names from a modal-comfy gateway, as image model IDs.
  static Future<List<String>> fetchTemplates({
    required String baseUrl,
    String apiKey = '',
    http.Client? client,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final data = await _getJson(
      baseUrl: baseUrl,
      apiKey: apiKey,
      client: client,
      timeout: timeout,
      path: 'api/templates',
      label: '模板',
    );
    final items = data is Map ? data['templates'] : null;
    if (items is! List) throw const FormatException('网关模板列表格式无效');
    return [
      for (final item in items)
        if (item is Map && (item['name']?.toString().trim() ?? '').isNotEmpty)
          '${ComfyUIWorkflow.templatePrefix}${item['name'].toString().trim()}',
    ];
  }

  static Future<Object?> _getJson({
    required String baseUrl,
    required String apiKey,
    required http.Client? client,
    required Duration timeout,
    required String path,
    required String label,
  }) async {
    final httpClient = client ?? http.Client();
    try {
      final response = await httpClient
          .get(endpoint(baseUrl, path), headers: headers(apiKey))
          .timeout(timeout);
      if (response.statusCode != 200) {
        throw StateError(
          'ComfyUI 拉取$label列表失败：HTTP ${response.statusCode}（${errorMessage(response)}）',
        );
      }
      try {
        return jsonDecode(utf8.decode(response.bodyBytes));
      } on FormatException {
        throw FormatException('ComfyUI $label列表返回了无效 JSON');
      }
    } finally {
      if (client == null) httpClient.close();
    }
  }

  static Map<String, String> headers(String key) => {
    'Content-Type': 'application/json',
    if (key.trim().isNotEmpty) 'Authorization': 'Bearer ${key.trim()}',
  };

  /// Uses the supplied client without closing it, or owns a short-lived client.
  /// An empty result means a successful response with no installed LoRAs.
  static Future<List<String>> fetchLoras({
    required String baseUrl,
    String apiKey = '',
    http.Client? client,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    try {
      return await _fetchOptions(
        baseUrl: baseUrl,
        apiKey: apiKey,
        client: client,
        timeout: timeout,
        nodeClass: 'LoraLoader',
        inputField: 'lora_name',
        label: 'LoRA',
      );
    } on StateError catch (error) {
      // A modal-comfy gateway has no /object_info; list its loras/ folder.
      if (!error.message.contains('HTTP 404')) rethrow;
      final data = await _getJson(
        baseUrl: baseUrl,
        apiKey: apiKey,
        client: client,
        timeout: timeout,
        path: 'api/models',
        label: ' LoRA ',
      );
      final models = data is Map ? data['models'] : null;
      if (models is! List) throw const FormatException('网关模型列表格式无效');
      return [
        for (final item in models)
          if (item is Map &&
              (item['path']?.toString() ?? '').startsWith('loras/'))
            item['path'].toString().substring('loras/'.length),
      ];
    }
  }

  static Future<List<String>> fetchCheckpoints({
    required String baseUrl,
    String apiKey = '',
    http.Client? client,
    Duration timeout = const Duration(seconds: 10),
  }) => _fetchOptions(
    baseUrl: baseUrl,
    apiKey: apiKey,
    client: client,
    timeout: timeout,
    nodeClass: 'CheckpointLoaderSimple',
    inputField: 'ckpt_name',
    label: 'Checkpoint',
  );

  static Future<List<String>> fetchSamplers({
    required String baseUrl,
    String apiKey = '',
    http.Client? client,
    Duration timeout = const Duration(seconds: 10),
  }) => _fetchOptions(
    baseUrl: baseUrl,
    apiKey: apiKey,
    client: client,
    timeout: timeout,
    nodeClass: 'KSampler',
    inputField: 'sampler_name',
    label: '采样器',
  );

  static Future<List<String>> fetchSchedulers({
    required String baseUrl,
    String apiKey = '',
    http.Client? client,
    Duration timeout = const Duration(seconds: 10),
  }) => _fetchOptions(
    baseUrl: baseUrl,
    apiKey: apiKey,
    client: client,
    timeout: timeout,
    nodeClass: 'KSampler',
    inputField: 'scheduler',
    label: '调度器',
  );

  static Future<List<String>> _fetchOptions({
    required String baseUrl,
    required String apiKey,
    required http.Client? client,
    required Duration timeout,
    required String nodeClass,
    required String inputField,
    required String label,
  }) async {
    final httpClient = client ?? http.Client();
    try {
      final response = await httpClient
          .get(
            endpoint(baseUrl, 'object_info/$nodeClass'),
            headers: headers(apiKey),
          )
          .timeout(timeout);
      if (response.statusCode != 200) {
        final reason = switch (response.statusCode) {
          401 || 403 => '鉴权失败，请检查 API Key 和访问权限',
          >= 500 => '服务异常，请检查 ComfyUI 服务',
          _ => '请求失败',
        };
        throw StateError(
          'ComfyUI 拉取 $label 列表失败：HTTP ${response.statusCode}（$reason）',
        );
      }
      final Object? decoded;
      try {
        decoded = jsonDecode(utf8.decode(response.bodyBytes));
      } on FormatException {
        throw FormatException('ComfyUI $label 列表返回了无效 JSON');
      }
      // Distinguish malformed object_info from a valid empty option list.
      final node = decoded is Map ? decoded[nodeClass] : null;
      final input = node is Map ? node['input'] : null;
      final requiredInputs = input is Map ? input['required'] : null;
      final spec = requiredInputs is Map ? requiredInputs[inputField] : null;
      if (spec is! List ||
          spec.isEmpty ||
          !(spec.first is List ||
              (spec.first == 'COMBO' &&
                  spec.length > 1 &&
                  spec[1] is Map &&
                  (spec[1] as Map)['options'] is List))) {
        throw FormatException('ComfyUI $label 列表缺少 $nodeClass.$inputField 选项');
      }
      return ComfyUIWorkflow.extractObjectInfoOptions(
        decoded,
        nodeClass: nodeClass,
        inputField: inputField,
      );
    } finally {
      if (client == null) httpClient.close();
    }
  }

  static Map<String, dynamic> _graph(
    Map<String, dynamic> config,
    ImageProviderRequest request,
    String model,
    int seed,
    String? Function(String key) option,
  ) => ComfyUIWorkflow.build(config, {
    // Placeholder and gateway template models keep the Checkpoint in the JSON.
    'model':
        model.isEmpty ||
            model == ComfyUIWorkflow.modelId ||
            ComfyUIWorkflow.isTemplateModel(model)
        ? null
        : model,
    'prompt': request.prompt,
    'negative_prompt': request.negativePrompt ?? '',
    'width': request.width,
    'height': request.height,
    'batch_size': request.count,
    'steps': request.steps,
    'cfg_scale': request.guidanceScale,
    'seed': seed,
    'sampler_name': request.sampler ?? option(ComfyUIWorkflow.samplerKey),
    'scheduler': option(ComfyUIWorkflow.schedulerKey),
  }, checkpointModel: request.model);

  @override
  Future<ImageProviderResponse> generate({
    required http.Client client,
    required Duration timeout,
    required ImageProviderRequest request,
  }) async {
    final config = request.customConfig ?? const <String, dynamic>{};
    String? option(String key) {
      final value = config[key]?.toString().trim() ?? '';
      return value.isEmpty ? null : value;
    }

    final model = request.model.trim();
    final seed = request.seed ?? Random.secure().nextInt(0x7fffffff);
    // A gateway template is used as-is unless the preset imported its own JSON.
    final template =
        ComfyUIWorkflow.isTemplateModel(model) &&
            config[ComfyUIWorkflow.modeKey] != ComfyUIWorkflow.customMode
        ? ComfyUIWorkflow.templateName(model)
        : null;
    final Object body;
    final String submitPath;
    if (template != null) {
      ComfyUIWorkflow.validateForModel(config, model);
      final lora = option(ComfyUIWorkflow.loraNameKey);
      // Steps, CFG and sampler stay with the template's tuned values.
      body = {
        'template': template,
        'prompt': request.prompt,
        'negative_prompt': request.negativePrompt ?? '',
        'width': request.width,
        'height': request.height,
        'batch_size': request.count,
        'seed': seed,
        if (lora != null)
          'loras': [
            {
              'name': lora,
              'strength':
                  double.tryParse(
                    config[ComfyUIWorkflow.loraStrengthKey]?.toString() ?? '',
                  ) ??
                  1.0,
            },
          ],
      };
      submitPath = 'api/generate';
    } else {
      body = {'prompt': _graph(config, request, model, seed, option)};
      submitPath = 'prompt';
    }
    final watch = Stopwatch()..start();
    Duration remaining() {
      final left = timeout - watch.elapsed;
      if (left <= Duration.zero) {
        throw TimeoutException('ComfyUI 等待超时，服务端任务可能仍在运行', timeout);
      }
      return left;
    }

    Map<String, dynamic> decode(http.Response response, String phase) {
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError(
          'ComfyUI $phase HTTP ${response.statusCode}: ${errorMessage(response)}',
        );
      }
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      if (data is! Map) throw FormatException('ComfyUI $phase 返回了无效 JSON');
      return Map<String, dynamic>.from(data);
    }

    final auth = headers(request.apiKey);
    final submitted = decode(
      await client
          .post(
            endpoint(request.baseUrl, submitPath),
            headers: auth,
            body: jsonEncode(body),
          )
          .timeout(remaining()),
      '提交任务',
    );
    final id = submitted['prompt_id']?.toString() ?? '';
    if (id.isEmpty || submitted['error'] != null) {
      throw StateError('ComfyUI 拒绝工作流：${jsonEncode(submitted)}');
    }
    while (true) {
      final history = decode(
        await client
            .get(
              endpoint(request.baseUrl, 'history/${Uri.encodeComponent(id)}'),
              headers: auth,
            )
            .timeout(remaining()),
        '读取任务',
      );
      final task = history[id];
      if (task is Map) {
        final status = task['status'] as Map?;
        final messages = status?['messages'] as List? ?? const [];
        if (status?['status_str'] == 'error' ||
            messages.any(
              (message) =>
                  message is List &&
                  message.isNotEmpty &&
                  const [
                    'execution_error',
                    'execution_interrupted',
                  ].contains(message.first),
            )) {
          throw StateError('ComfyUI 任务失败：${jsonEncode(status)}');
        }
        final outputs = task['outputs'] as Map? ?? const {};
        final outputId =
            config[ComfyUIWorkflow.outputKey]?.toString().trim() ?? '';
        final nodes = outputId.isEmpty ? outputs.values : [outputs[outputId]];
        final images = <Uint8List>[];
        for (final node in nodes) {
          if (node is! Map) continue;
          for (final file in node['images'] as List? ?? const []) {
            if (file is! Map || file['type'] != 'output') continue;
            final filename = file['filename']?.toString() ?? '';
            if (filename.isEmpty) continue;
            final response = await client
                .get(
                  endpoint(request.baseUrl, 'view', {
                    'filename': filename,
                    'subfolder': file['subfolder']?.toString() ?? '',
                    'type': 'output',
                  }),
                  headers: auth,
                )
                .timeout(remaining());
            if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
              throw StateError('ComfyUI 下载图片失败：HTTP ${response.statusCode}');
            }
            images.add(response.bodyBytes);
            if (images.length >= request.count) break;
          }
          if (images.length >= request.count) break;
        }
        if (images.isEmpty) {
          throw StateError('ComfyUI 任务已结束但没有输出图片，请检查 SaveImage 和输出节点');
        }
        return ImageProviderResponse(
          images: images,
          rawResponse: {'prompt_id': id},
        );
      }
      final left = remaining();
      await Future<void>.delayed(left < pollInterval ? left : pollInterval);
    }
  }
}

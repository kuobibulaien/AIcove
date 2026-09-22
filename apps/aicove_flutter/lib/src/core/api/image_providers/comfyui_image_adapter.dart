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

  static Map<String, String> headers(String key) => {
    'Content-Type': 'application/json',
    if (key.trim().isNotEmpty) 'Authorization': 'Bearer ${key.trim()}',
  };

  @override
  Future<ImageProviderResponse> generate({
    required http.Client client,
    required Duration timeout,
    required ImageProviderRequest request,
  }) async {
    final graph = ComfyUIWorkflow.build(request.customConfig ?? {}, {
      'prompt': request.prompt,
      'negative_prompt': request.negativePrompt ?? '',
      'width': request.width,
      'height': request.height,
      'batch_size': request.count,
      'steps': request.steps,
      'cfg_scale': request.guidanceScale,
      'seed': request.seed ?? Random.secure().nextInt(0x7fffffff),
      'sampler_name': request.sampler,
    });
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
          'ComfyUI $phase HTTP ${response.statusCode}: ${utf8.decode(response.bodyBytes)}',
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
            endpoint(request.baseUrl, 'prompt'),
            headers: auth,
            body: jsonEncode({'prompt': graph}),
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
            request.customConfig?[ComfyUIWorkflow.outputKey]
                ?.toString()
                .trim() ??
            '';
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

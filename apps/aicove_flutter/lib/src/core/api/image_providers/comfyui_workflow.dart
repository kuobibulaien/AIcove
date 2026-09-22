import 'dart:convert';

/// A saved API workflow, with explicit input bindings independent of node types.
class ComfyUIWorkflow {
  static const modelId = 'comfyui-workflow';
  static const workflowKey = 'comfyWorkflow';
  static const bindingsKey = 'comfyBindings';
  static const outputKey = 'comfyOutputNode';
  static const fieldLabels = <String, String>{
    'prompt': '正向提示词',
    'negative_prompt': '负向提示词',
    'width': '宽度',
    'height': '高度',
    'seed': '随机种子',
    'steps': '采样步数',
    'cfg_scale': '提示词引导强度',
    'batch_size': '图片数量',
    'sampler_name': '采样器',
  };

  static bool isProvider(String provider, Map<String, dynamic>? config) {
    final format = config?['requestFormat']?.toString().trim().toLowerCase();
    return (format == null || format.isEmpty
            ? provider.trim().toLowerCase()
            : format) ==
        'comfyui';
  }

  static Map<String, dynamic> parse(Object? raw) {
    final decoded = raw is String ? jsonDecode(raw) : raw;
    if (decoded is! Map || decoded.isEmpty || decoded['nodes'] is List) {
      throw const FormatException('请导入 ComfyUI 的 API 格式工作流 JSON，不是画布格式');
    }
    final graph = Map<String, dynamic>.from(decoded);
    for (final entry in graph.entries) {
      final node = entry.value;
      if (node is! Map ||
          node['class_type'] is! String ||
          node['inputs'] is! Map) {
        throw FormatException('节点 ${entry.key} 缺少 class_type 或 inputs');
      }
    }
    return graph;
  }

  static Map<String, String> inputChoices(Map<String, dynamic> graph) {
    final result = <String, String>{};
    for (final entry in graph.entries) {
      final node = entry.value as Map;
      final title = (node['_meta'] as Map?)?['title'] ?? node['class_type'];
      for (final input in (node['inputs'] as Map).entries) {
        if (input.value is List || input.value is Map) continue;
        result['${entry.key}.${input.key}'] =
            '${entry.key} · $title · ${input.key}';
      }
    }
    return result;
  }

  static void validate(Map<String, dynamic> config) {
    final graph = parse(config[workflowKey]);
    final bindings = config[bindingsKey] as Map? ?? const {};
    final choices = inputChoices(graph);
    final used = <String>{};
    for (final entry in bindings.entries) {
      if (!fieldLabels.containsKey(entry.key) ||
          !choices.containsKey(entry.value)) {
        throw FormatException('无效的工作流输入绑定：${entry.key} → ${entry.value}');
      }
      if (!used.add(entry.value.toString())) {
        throw const FormatException('不同参数不能绑定到同一个节点输入');
      }
    }
    if (!bindings.containsKey('prompt') &&
        !graph.values.any((node) => _containsPrompt((node as Map)['inputs']))) {
      throw const FormatException('请选择正向提示词输入，或在工作流中使用 %prompt%');
    }
    final output = config[outputKey]?.toString().trim() ?? '';
    if (output.isNotEmpty && !graph.containsKey(output)) {
      throw const FormatException('输出节点不存在于工作流中');
    }
  }

  static bool _containsPrompt(Object? value) {
    if (value is String) return value.contains('%prompt%');
    if (value is Map) return value.values.any(_containsPrompt);
    if (value is List) return value.any(_containsPrompt);
    return false;
  }

  static Map<String, dynamic> build(
    Map<String, dynamic> config,
    Map<String, Object?> values,
  ) {
    validate(config);
    Object? replace(Object? value) {
      if (value is Map) {
        return value.map(
          (key, item) => MapEntry(key.toString(), replace(item)),
        );
      }
      if (value is List) return value.map(replace).toList();
      if (value is! String) return value;
      var text = value;
      for (final entry in values.entries) {
        final token = '%${entry.key}%';
        if (!text.contains(token)) continue;
        if (entry.value == null) {
          throw FormatException('工作流需要 ${entry.key}，请在工作流中设置固定值');
        }
        if (text == token) return entry.value;
        text = text.replaceAll(token, entry.value.toString());
      }
      return text;
    }

    final graph = Map<String, dynamic>.from(
      replace(parse(config[workflowKey])) as Map,
    );
    final bindings = config[bindingsKey] as Map? ?? const {};
    for (final entry in bindings.entries) {
      final value = values[entry.key];
      // Optional parameters keep the workflow's own value when not supplied.
      if (value == null) continue;
      final path = entry.value.toString();
      final dot = path.indexOf('.');
      final node = graph[path.substring(0, dot)] as Map;
      (node['inputs'] as Map)[path.substring(dot + 1)] = value;
    }
    return graph;
  }
}

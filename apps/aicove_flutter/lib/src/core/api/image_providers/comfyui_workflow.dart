import 'dart:convert';

/// A saved API workflow, with explicit input bindings independent of node types,
/// or a built-in standard Checkpoint (+ optional LoRA) workflow.
class ComfyUIWorkflow {
  static const modelId = 'comfyui-workflow';
  static const workflowKey = 'comfyWorkflow';
  static const bindingsKey = 'comfyBindings';
  static const outputKey = 'comfyOutputNode';
  static const modeKey = 'comfyWorkflowMode';
  static const inheritMode = 'inherit';
  static const standardMode = 'standard';
  static const customMode = 'custom';
  static const loraNameKey = 'comfyLoraName';
  static const loraStrengthKey = 'comfyLoraStrength';
  static const samplerKey = 'comfySampler';
  static const schedulerKey = 'comfyScheduler';
  static const defaultSampler = 'euler';
  static const defaultScheduler = 'normal';
  /// Models listed from a modal-comfy gateway's `/api/templates`; the gateway
  /// owns the graph, bindings and tuned defaults of each template.
  static const templatePrefix = 'template/';

  static bool isTemplateModel(String model) =>
      model.trim().startsWith(templatePrefix) &&
      model.trim().length > templatePrefix.length;

  static String templateName(String model) =>
      model.trim().substring(templatePrefix.length);

  static const fieldLabels = <String, String>{
    'model': '基础模型',
    'prompt': '正向提示词',
    'negative_prompt': '负向提示词',
    'width': '宽度',
    'height': '高度',
    'seed': '随机种子',
    'steps': '采样步数',
    'cfg_scale': '提示词引导强度',
    'batch_size': '图片数量',
    'sampler_name': '采样器',
    'scheduler': '调度器',
  };

  static bool isProvider(String provider, Map<String, dynamic>? config) {
    final format = config?['requestFormat']?.toString().trim().toLowerCase();
    return (format == null || format.isEmpty
            ? provider.trim().toLowerCase()
            : format) ==
        'comfyui';
  }

  static bool hasCustomWorkflow(Map<String, dynamic>? config) {
    final raw = config?[workflowKey];
    if (raw is Map) return raw.isNotEmpty;
    if (raw is String) return raw.trim().isNotEmpty;
    return false;
  }

  /// Legacy presets inherit a channel workflow only for the workflow model.
  /// A preset's own JSON remains custom even when it names a Checkpoint model.
  static String resolveMode({
    String mode = inheritMode,
    required String model,
    Map<String, dynamic>? presetConfig,
    Map<String, dynamic>? providerConfig,
  }) {
    if (mode == standardMode || mode == customMode) return mode;
    if (mode != inheritMode) {
      throw FormatException('未知的 ComfyUI 工作流模式：$mode');
    }
    if (hasCustomWorkflow(presetConfig)) return customMode;
    if (model.trim() == modelId && hasCustomWorkflow(providerConfig)) {
      return customMode;
    }
    return standardMode;
  }

  /// Validates the effective request config, not inactive editor drafts.
  static void validateForModel(Map<String, dynamic> config, String model) {
    if (config[modeKey] != standardMode && hasCustomWorkflow(config)) {
      validate(config);
      return;
    }
    if (config[modeKey] == customMode) {
      throw const FormatException('请导入 ComfyUI 自定义工作流 JSON');
    }
    if (model.trim().isEmpty || model.trim() == modelId) {
      throw const FormatException('请选择具体的 ComfyUI 基础模型，或导入自定义工作流 JSON');
    }
    if ((config[loraNameKey]?.toString().trim() ?? '').isNotEmpty) {
      final strength = double.tryParse(
        config[loraStrengthKey]?.toString() ?? '1',
      );
      if (strength == null ||
          !strength.isFinite ||
          strength < -2 ||
          strength > 2) {
        throw const FormatException('LoRA 强度请填写 -2.0 到 2.0 之间的数值');
      }
    }
  }

  /// Extracts options from ComfyUI `/object_info/{NodeClass}` response for
  /// `input.required.{inputField}`.
  static List<String> extractObjectInfoOptions(
    Object? decoded, {
    required String nodeClass,
    required String inputField,
  }) {
    if (decoded is! Map) return const [];
    final node = decoded[nodeClass];
    if (node is! Map) return const [];
    final input = node['input'];
    if (input is! Map) return const [];
    final requiredInputs = input['required'];
    if (requiredInputs is! Map) return const [];
    final fieldSpec = requiredInputs[inputField];
    if (fieldSpec is! List || fieldSpec.isEmpty) return const [];
    final first = fieldSpec.first;
    final Iterable<Object?> rawItems;
    if (first is List) {
      rawItems = first;
    } else if (first == 'COMBO' &&
        fieldSpec.length > 1 &&
        fieldSpec[1] is Map &&
        (fieldSpec[1] as Map)['options'] is List) {
      rawItems = (fieldSpec[1] as Map)['options'] as List;
    } else {
      return const [];
    }
    final result = <String>[];
    for (final item in rawItems) {
      final text = item?.toString().trim() ?? '';
      if (text.isNotEmpty && !result.contains(text)) {
        result.add(text);
      }
    }
    return result;
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

  /// Automatically infers common input bindings and output node from an API
  /// workflow graph so users do not have to manually locate every node input.
  static ({Map<String, String> bindings, String outputNode}) inferBindings(
    Map<String, dynamic> graph,
  ) {
    final choices = inputChoices(graph);
    final bindings = <String, String>{};
    final used = <String>{};

    void tryBind(String field, String? target) {
      if (target == null ||
          !choices.containsKey(target) ||
          used.contains(target)) {
        return;
      }
      final dot = target.indexOf('.');
      final inputs = (graph[target.substring(0, dot)] as Map)['inputs'] as Map;
      final value = inputs[target.substring(dot + 1)];
      // Keep template prefixes/suffixes (and typed placeholders) intact.
      if (value is String &&
          fieldLabels.keys.any((key) => value.contains('%$key%'))) {
        return;
      }
      bindings[field] = target;
      used.add(target);
    }

    String? linkedNode(Object? value) {
      if (value is! List || value.length != 2 || value[1] is! int) return null;
      final id = value.first.toString();
      return graph.containsKey(id) ? id : null;
    }

    // Preorder upstream traversal, protected against cycles and shared nodes.
    List<String> upstream(Object? link) {
      final result = <String>[];
      final seen = <String>{};
      void visit(Object? value) {
        final id = linkedNode(value);
        if (id == null || !seen.add(id)) return;
        result.add(id);
        final inputs = (graph[id] as Map)['inputs'] as Map;
        for (final input in inputs.values) {
          visit(input);
        }
      }

      visit(link);
      return result;
    }

    bool isSampler(String id) {
      final type = (graph[id] as Map)['class_type'].toString();
      return type.contains('KSampler') || type == 'SamplerCustom';
    }

    bool isLatent(String id) {
      final type = (graph[id] as Map)['class_type'].toString();
      return type == 'EmptyLatentImage' || type == 'EmptySD3LatentImage';
    }

    String? textInput(Iterable<String> ids) {
      for (final id in ids) {
        final inputs = (graph[id] as Map)['inputs'] as Map;
        // A single binding cannot update both SDXL encoders. Require explicit
        // placeholders in both inputs instead of silently changing just one.
        if (inputs.containsKey('text_g') && inputs.containsKey('text_l')) {
          return null;
        }
        for (final key in const ['text', 'prompt', 'string', 'text_g']) {
          if (choices.containsKey('$id.$key')) return '$id.$key';
        }
      }
      return null;
    }

    final outputNode =
        graph.keys
            .where((id) => (graph[id] as Map)['class_type'] == 'SaveImage')
            .firstOrNull ??
        '';
    final outputInputs = outputNode.isEmpty
        ? const <String, dynamic>{}
        : (graph[outputNode] as Map)['inputs'] as Map;
    final branch = upstream(outputInputs['images']);
    final candidates = branch.isEmpty ? graph.keys.toList() : branch;
    final sampler = candidates.where(isSampler).firstOrNull;
    if (sampler != null) {
      final inputs = (graph[sampler] as Map)['inputs'] as Map;
      tryBind('seed', '$sampler.seed');
      if (!bindings.containsKey('seed')) tryBind('seed', '$sampler.noise_seed');
      tryBind('steps', '$sampler.steps');
      tryBind('cfg_scale', '$sampler.cfg');
      tryBind('sampler_name', '$sampler.sampler_name');
      tryBind('scheduler', '$sampler.scheduler');
      final loader = upstream(
        inputs['model'],
      ).where((id) => choices.containsKey('$id.ckpt_name')).firstOrNull;
      if (loader != null) tryBind('model', '$loader.ckpt_name');
      tryBind('prompt', textInput(upstream(inputs['positive'])));
      tryBind('negative_prompt', textInput(upstream(inputs['negative'])));
    } else if (branch.isEmpty) {
      // Only disconnected graphs use a graph-order fallback. Never jump from
      // an unresolved prompt on the saved branch to another branch's text.
      final encoders = graph.keys
          .where(
            (id) => (graph[id] as Map)['class_type'].toString().contains(
              'CLIPTextEncode',
            ),
          )
          .toList();
      tryBind('prompt', textInput(encoders.take(1)));
      tryBind('negative_prompt', textInput(encoders.skip(1).take(1)));
    }

    final samplerInputs = sampler == null
        ? const <String, dynamic>{}
        : (graph[sampler] as Map)['inputs'] as Map;
    final latentBranch = upstream(samplerInputs['latent_image']);
    final latent = (latentBranch.isNotEmpty ? latentBranch : candidates)
        .where(isLatent)
        .firstOrNull;
    if (latent != null) {
      tryBind('width', '$latent.width');
      tryBind('height', '$latent.height');
      tryBind('batch_size', '$latent.batch_size');
    }
    return (bindings: bindings, outputNode: outputNode);
  }

  /// Builds a standard txt2img ComfyUI API graph from a Checkpoint name and an
  /// optional LoRA.
  static Map<String, dynamic> buildStandardGraph({
    required String checkpoint,
    String? loraName,
    double loraStrength = 1.0,
    required Map<String, Object?> values,
  }) {
    final ckpt = checkpoint.trim();
    if (ckpt.isEmpty || ckpt == modelId) {
      throw const FormatException('请选择具体的 ComfyUI 基础模型，或在绘图预设中导入自定义工作流 JSON');
    }
    final lora = loraName?.trim() ?? '';
    final hasLora = lora.isNotEmpty;
    final modelOut = hasLora ? ['10', 0] : ['4', 0];
    final clipOut = hasLora ? ['10', 1] : ['4', 1];
    final strength = loraStrength.isFinite ? loraStrength : 1.0;

    return <String, dynamic>{
      '4': {
        'class_type': 'CheckpointLoaderSimple',
        'inputs': {'ckpt_name': ckpt},
      },
      if (hasLora)
        '10': {
          'class_type': 'LoraLoader',
          'inputs': {
            'lora_name': lora,
            'strength_model': strength,
            'strength_clip': strength,
            'model': ['4', 0],
            'clip': ['4', 1],
          },
        },
      '5': {
        'class_type': 'EmptyLatentImage',
        'inputs': {
          'width': values['width'] ?? 832,
          'height': values['height'] ?? 1216,
          'batch_size': values['batch_size'] ?? 1,
        },
      },
      '6': {
        'class_type': 'CLIPTextEncode',
        'inputs': {'text': values['prompt']?.toString() ?? '', 'clip': clipOut},
      },
      '7': {
        'class_type': 'CLIPTextEncode',
        'inputs': {
          'text': values['negative_prompt']?.toString() ?? '',
          'clip': clipOut,
        },
      },
      '3': {
        'class_type': 'KSampler',
        'inputs': {
          'seed': values['seed'] ?? 1,
          'steps': values['steps'] ?? 28,
          'cfg': values['cfg_scale'] ?? 5.0,
          'sampler_name': values['sampler_name'] ?? defaultSampler,
          'scheduler': values['scheduler'] ?? defaultScheduler,
          'denoise': 1,
          'model': modelOut,
          'positive': ['6', 0],
          'negative': ['7', 0],
          'latent_image': ['5', 0],
        },
      },
      '8': {
        'class_type': 'VAEDecode',
        'inputs': {
          'samples': ['3', 0],
          'vae': ['4', 2],
        },
      },
      '9': {
        'class_type': 'SaveImage',
        'inputs': {
          'filename_prefix': 'AIcove',
          'images': ['8', 0],
        },
      },
    };
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
    Map<String, Object?> values, {
    String? checkpointModel,
  }) {
    validateForModel(config, checkpointModel ?? '');
    if (config[modeKey] == standardMode || !hasCustomWorkflow(config)) {
      final rawStrength = config[loraStrengthKey];
      final strength = rawStrength is num
          ? rawStrength.toDouble()
          : double.tryParse(rawStrength?.toString() ?? '') ?? 1.0;
      return buildStandardGraph(
        checkpoint: checkpointModel ?? '',
        loraName: config[loraNameKey]?.toString(),
        loraStrength: strength,
        values: values,
      );
    }
    // Workflows shared for st-chatu8 use %MODEL_NAME% for the Checkpoint.
    values = {...values, 'MODEL_NAME': values['model']};
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

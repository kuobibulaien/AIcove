import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../../core/api/image_providers/comfyui_workflow.dart';
import '../../../shared/widgets/index.dart';

Future<Map<String, dynamic>?> showComfyUIWorkflowEditor(
  BuildContext context,
  Map<String, dynamic> config,
) => showDialog<Map<String, dynamic>>(
  context: context,
  useRootNavigator: false,
  barrierColor: Colors.transparent,
  builder: (context) => ComfyUIWorkflowEditor(config: config),
);

class ComfyUIWorkflowEditor extends StatefulWidget {
  const ComfyUIWorkflowEditor({super.key, required this.config});
  final Map<String, dynamic> config;

  @override
  State<ComfyUIWorkflowEditor> createState() => _ComfyUIWorkflowEditorState();
}

class _ComfyUIWorkflowEditorState extends State<ComfyUIWorkflowEditor> {
  late final TextEditingController _json;
  late Map<String, String> _bindings;
  Map<String, dynamic>? _graph;
  String _output = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    final raw = widget.config[ComfyUIWorkflow.workflowKey];
    _json = TextEditingController(
      text: raw == null
          ? ''
          : raw is String
          ? raw
          : const JsonEncoder.withIndent('  ').convert(raw),
    );
    _bindings = Map<String, String>.from(
      widget.config[ComfyUIWorkflow.bindingsKey] as Map? ?? {},
    );
    _output = widget.config[ComfyUIWorkflow.outputKey]?.toString() ?? '';
    if (_json.text.isNotEmpty) _parse();
  }

  @override
  void dispose() {
    _json.dispose();
    super.dispose();
  }

  void _parse({bool reInfer = false}) {
    try {
      final graph = ComfyUIWorkflow.parse(_json.text);
      final choices = ComfyUIWorkflow.inputChoices(graph);
      setState(() {
        _graph = graph;
        if (reInfer) {
          final inferred = ComfyUIWorkflow.inferBindings(graph);
          _bindings = Map<String, String>.from(inferred.bindings);
          _output = inferred.outputNode;
        } else {
          _bindings.removeWhere((key, value) => !choices.containsKey(value));
          if (!graph.containsKey(_output)) _output = '';
        }
        _error = null;
      });
    } catch (error) {
      setState(() {
        _graph = null;
        _error = error.toString();
      });
    }
  }

  Future<void> _import() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        withData: true,
      );
      if (result == null || !mounted) return;
      final file = result.files.single;
      final bytes = file.bytes ?? await File(file.path!).readAsBytes();
      if (!mounted) return;
      _json.text = utf8.decode(bytes);
      _parse(reInfer: true);
    } catch (error) {
      if (mounted) setState(() => _error = '导入失败：$error');
    }
  }

  void _save() {
    if (_graph == null) {
      _parse(reInfer: _bindings.isEmpty);
    } else {
      _parse();
    }
    if (_graph == null) return;
    final config = <String, dynamic>{
      ComfyUIWorkflow.workflowKey: _graph,
      ComfyUIWorkflow.bindingsKey: _bindings,
      ComfyUIWorkflow.outputKey: _output,
    };
    try {
      ComfyUIWorkflow.validate(config);
      Navigator.of(context).pop(config);
    } catch (error) {
      setState(() => _error = error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final choices = _graph == null
        ? <String, String>{}
        : ComfyUIWorkflow.inputChoices(_graph!);
    return MeoTalkDialog(
      title: 'ComfyUI 工作流',
      confirmText: '保存工作流',
      onCancel: () => Navigator.of(context).pop(),
      onConfirm: _save,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '从 ComfyUI 导出 API 格式 JSON，导入后会自动识别各参数对应的节点。基础模型、采样器等绑定后跟随预设设置；未绑定的参数沿用工作流原值。',
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              IntrinsicWidth(
                child: MoeSecondaryButton(
                  label: '导入 JSON 文件',
                  icon: Icons.file_open_outlined,
                  size: MoeSecondaryButtonSize.sm,
                  onPressed: _import,
                ),
              ),
              IntrinsicWidth(
                child: MoeSecondaryButton(
                  label: '解析粘贴内容',
                  size: MoeSecondaryButtonSize.sm,
                  onPressed: () => _parse(reInfer: true),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('comfy-workflow-json'),
            controller: _json,
            minLines: 4,
            maxLines: 7,
            decoration: const MoeInputDecoration(
              hintText: '在此粘贴 API 工作流 JSON',
            ),
            onChanged: (_) {
              if (_graph != null) setState(() => _graph = null);
            },
          ),
          if (_graph != null) ...[
            const SizedBox(height: 16),
            Text(
              '参数绑定 · ${_graph!.length} 个节点',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            for (final field in ComfyUIWorkflow.fieldLabels.entries)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: _dropdown(
                  label: field.value,
                  value: _bindings[field.key] ?? '',
                  choices: choices,
                  emptyLabel: field.key == 'prompt'
                      ? '请选择（已使用 %prompt% 可留空）'
                      : '沿用工作流',
                  onChanged: (value) => setState(() {
                    if (value.isEmpty) {
                      _bindings.remove(field.key);
                    } else {
                      _bindings[field.key] = value;
                    }
                  }),
                ),
              ),
            const SizedBox(height: 12),
            _dropdown(
              label: '图片输出节点',
              value: _output,
              choices: {
                for (final entry in _graph!.entries)
                  entry.key:
                      '${entry.key} · ${(entry.value as Map)['class_type']}',
              },
              emptyLabel: '自动读取保存的图片',
              onChanged: (value) => setState(() => _output = value),
            ),
            const SizedBox(height: 12),
            const Text(
              '也支持 %prompt%、%negative_prompt%、%seed%、%width%、%height%、%scheduler%、%model%（兼容 %MODEL_NAME%）等占位符（如 CLIPTextEncodeSDXL 双输入节点可在 text_g 与 text_l 中同时填写 %prompt%）。工作流需包含保存图片的输出节点。',
            ),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _error!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _dropdown({
    required String label,
    required String value,
    required Map<String, String> choices,
    required String emptyLabel,
    required ValueChanged<String> onChanged,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label),
      DropdownButtonFormField<String>(
        initialValue: value,
        key: ValueKey('$label:$value:${choices.keys.join(',')}'),
        isExpanded: true,
        decoration: const MoeInputDecoration(isDense: true),
        items: [
          DropdownMenuItem(
            value: '',
            child: Text(emptyLabel, overflow: TextOverflow.ellipsis),
          ),
          for (final entry in choices.entries)
            DropdownMenuItem(
              value: entry.key,
              child: Text(entry.value, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (value) => onChanged(value ?? ''),
      ),
    ],
  );
}

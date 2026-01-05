/// ImportModelFormFields - 导入模型表单字段组件
/// 
/// 从 import_model_dialog.dart 提取，处理表单输入字段。
/// 
/// 更新记录：
/// - 2025-12-31: 从 import_model_dialog.dart 提取
library;

import 'dart:convert';
import 'package:flutter/material.dart';

import '../../../../ui/theme/tokens.dart';

/// 渠道预设配置
class ChannelPreset {
  final String key;
  final String label;
  final String url;

  const ChannelPreset({
    required this.key,
    required this.label,
    required this.url,
  });

  static const Map<String, ChannelPreset> presets = {
    'openai': ChannelPreset(key: 'openai', label: 'OpenAI (默认)', url: 'https://api.openai.com/v1'),
    'newapi': ChannelPreset(key: 'newapi', label: 'NewAPI / OneAPI', url: 'https://api.openai.com/v1'),
    'siliconflow': ChannelPreset(key: 'siliconflow', label: '硅基流动 (SiliconFlow)', url: 'https://api.siliconflow.cn/v1'),
    'deepseek': ChannelPreset(key: 'deepseek', label: 'DeepSeek', url: 'https://api.deepseek.com'),
    'custom': ChannelPreset(key: 'custom', label: '自定义渠道', url: ''),
  };
}

/// 模型类型选择器
class ModelTypeSelector extends StatelessWidget {
  final String selectedType;
  final ValueChanged<String> onChanged;

  const ModelTypeSelector({
    super.key,
    required this.selectedType,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '模型类型',
          style: TextStyle(fontSize: 12, color: colors.textSecondary),
        ),
        const SizedBox(height: 4),
        DropdownButtonFormField<String>(
          value: selectedType,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          ),
          items: const [
            DropdownMenuItem(
              value: 'chat',
              child: Row(
                children: [
                  Icon(Icons.chat_bubble_outline, size: 18),
                  SizedBox(width: 8),
                  Text('基础对话'),
                ],
              ),
            ),
            DropdownMenuItem(
              value: 'embedding',
              child: Row(
                children: [
                  Icon(Icons.code_outlined, size: 18),
                  SizedBox(width: 8),
                  Text('嵌入(Embedding)'),
                ],
              ),
            ),
            DropdownMenuItem(
              value: 'tts',
              child: Row(
                children: [
                  Icon(Icons.volume_up_outlined, size: 18),
                  SizedBox(width: 8),
                  Text('文字转语音'),
                ],
              ),
            ),
            DropdownMenuItem(
              value: 'stt',
              child: Row(
                children: [
                  Icon(Icons.mic_outlined, size: 18),
                  SizedBox(width: 8),
                  Text('语音转文字'),
                ],
              ),
            ),
            DropdownMenuItem(
              value: 'image',
              child: Row(
                children: [
                  Icon(Icons.image_outlined, size: 18),
                  SizedBox(width: 8),
                  Text('图像生成'),
                ],
              ),
            ),
          ],
          onChanged: (value) {
            if (value != null) onChanged(value);
          },
        ),
      ],
    );
  }
}

/// 渠道类型选择器
class ChannelTypeSelector extends StatelessWidget {
  final String selectedPreset;
  final ValueChanged<String> onChanged;

  const ChannelTypeSelector({
    super.key,
    required this.selectedPreset,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '渠道类型',
          style: TextStyle(fontSize: 12, color: colors.textSecondary),
        ),
        const SizedBox(height: 4),
        DropdownButtonFormField<String>(
          value: selectedPreset,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          ),
          items: ChannelPreset.presets.entries.map((e) {
            return DropdownMenuItem(
              value: e.key,
              child: Text(e.value.label),
            );
          }).toList(),
          onChanged: (value) {
            if (value != null) onChanged(value);
          },
        ),
      ],
    );
  }
}

/// 高级设置：自定义请求体
class CustomBodyExpansion extends StatelessWidget {
  final TextEditingController controller;

  const CustomBodyExpansion({
    super.key,
    required this.controller,
  });

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      title: const Text('高级设置：自定义请求体', style: TextStyle(fontSize: 14)),
      tilePadding: EdgeInsets.zero,
      children: [
        TextFormField(
          controller: controller,
          maxLines: 3,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          decoration: const InputDecoration(
            hintText: '{"model": "gpt-4", "temperature": 0.7}',
            helperText: 'JSON 格式，将合并到请求体中',
            border: OutlineInputBorder(),
          ),
          validator: (value) {
            if (value != null && value.trim().isNotEmpty) {
              try {
                jsonDecode(value);
              } catch (e) {
                return 'JSON 格式错误';
              }
            }
            return null;
          },
        ),
      ],
    );
  }
}

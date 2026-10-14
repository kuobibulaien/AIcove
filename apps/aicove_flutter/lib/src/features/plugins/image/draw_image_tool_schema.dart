import 'image_config.dart';

/// Rewrites the `draw_image` tool schema with the role's tool preset and
/// custom drawing prompt (stable image route). Other schemas pass through.
List<Map<String, dynamic>> applyRoleDrawImageToolPreset({
  required List<Map<String, dynamic>> tools,
  required ImageConfig imageConfig,
  required String? toolPresetName,
  required String customDrawingPrompt,
}) {
  final normalizedDrawingPrompt = customDrawingPrompt.trim();
  final hasToolPreset = toolPresetName != null && toolPresetName.isNotEmpty;
  if (!hasToolPreset && normalizedDrawingPrompt.isEmpty) {
    return tools;
  }

  var blocks = imageConfig.effectiveToolDescriptionBlocks;
  if (hasToolPreset) {
    final preset = imageConfig.systemPromptPresets
        .where((item) => item.name == toolPresetName)
        .firstOrNull;
    if (preset != null) {
      blocks =
          ImageConfig.decodeToolDescriptionBlocks(preset.content) ??
          ImageConfig.defaultToolDescriptionBlocks;
    }
  }
  if (normalizedDrawingPrompt.isNotEmpty) {
    final promptDescription = blocks.promptDescription.trim();
    blocks = blocks.copyWith(
      promptDescription:
          '$promptDescription\n\n【角色专属生图要求】\n$normalizedDrawingPrompt',
    );
  }

  return [
    for (final rawSchema in tools)
      () {
        final schema = Map<String, dynamic>.from(rawSchema);
        final rawFunction = schema['function'];
        if (rawFunction is! Map) return schema;

        final function = Map<String, dynamic>.from(rawFunction);
        final functionName = function['name']?.toString().trim();
        if (functionName != 'draw_image') return schema;

        function['description'] = blocks.toolDescription;

        final rawParameters = function['parameters'];
        if (rawParameters is Map) {
          final parameters = Map<String, dynamic>.from(rawParameters);
          final rawProperties = parameters['properties'];
          if (rawProperties is Map) {
            final properties = Map<String, dynamic>.from(rawProperties);

            void overrideDescription(String key, String description) {
              final rawProperty = properties[key];
              if (rawProperty is! Map) return;
              final property = Map<String, dynamic>.from(rawProperty);
              property['description'] = description;
              properties[key] = property;
            }

            overrideDescription('prompt', blocks.promptDescription);
            overrideDescription(
              'negative_prompt',
              blocks.negativePromptDescription,
            );
            // 尺寸描述由请求插件生成，保留其中的预设参考值。

            parameters['properties'] = properties;
          }
          function['parameters'] = parameters;
        }

        schema['function'] = function;
        return schema;
      }(),
  ];
}

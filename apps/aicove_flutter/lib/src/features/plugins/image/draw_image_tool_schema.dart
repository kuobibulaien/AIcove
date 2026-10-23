import '../domain/handlers/ai_tool.dart';

/// Rewrites the collected `draw_image` schema with this request's tool text
/// (stable image route), so a schema built elsewhere still carries the
/// preset's prompt pack (ADR0092). Other schemas pass through.
List<Map<String, dynamic>> applyDrawImageToolText({
  required List<Map<String, dynamic>> tools,
  required AITool drawImage,
}) => [
  for (final rawSchema in tools)
    () {
      final schema = Map<String, dynamic>.from(rawSchema);
      final rawFunction = schema['function'];
      if (rawFunction is! Map) return schema;
      final function = Map<String, dynamic>.from(rawFunction);
      if (function['name']?.toString().trim() != drawImage.name) return schema;
      function['description'] = drawImage.description;
      final rawParameters = function['parameters'];
      if (rawParameters is Map) {
        final parameters = Map<String, dynamic>.from(rawParameters);
        final rawProperties = parameters['properties'];
        if (rawProperties is Map) {
          final properties = Map<String, dynamic>.from(rawProperties);
          for (final entry in drawImage.parameters.entries) {
            final rawProperty = properties[entry.key];
            if (rawProperty is! Map) continue;
            properties[entry.key] = {
              ...Map<String, dynamic>.from(rawProperty),
              'description': entry.value.description,
            };
          }
          parameters['properties'] = properties;
        }
        function['parameters'] = parameters;
      }
      schema['function'] = function;
      return schema;
    }(),
];

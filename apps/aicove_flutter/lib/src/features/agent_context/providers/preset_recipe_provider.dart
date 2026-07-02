/// 预设 Recipe 提供者
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/agent_runtime_contracts.dart';

/// 预设摘要
class PresetRecipeSummary {
  final String id;
  final String name;
  final String description;

  const PresetRecipeSummary({
    required this.id,
    required this.name,
    required this.description,
  });
}

/// 预设列表提供者（第一阶段返回示例数据）
final presetRecipeListProvider = Provider<List<PresetRecipeSummary>>((ref) {
  return const [
    PresetRecipeSummary(
      id: 'default_chat_recipe',
      name: '标准对话预设',
      description: '适用于日常聊天的默认预设',
    ),
    PresetRecipeSummary(
      id: 'creative_writing_recipe',
      name: '创意写作预设',
      description: '适合角色扮演和创意对话',
    ),
    // 后续从 assets/agent_context_defaults.json 加载
  ];
});

/// 单个预设提供者
final presetRecipeProvider =
    FutureProvider.family<AgentContextRecipe?, String>(
  (ref, recipeId) async {
    // 第一阶段返回 null，等待预设文件准备
    // 第二阶段从 assets 或数据库加载
    return null;
  },
);

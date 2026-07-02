# 提示词节点管理面板（增强版）

## 概述

增强版提示词节点管理面板在原有功能基础上，新增了联系人筛选和上下文预览功能，帮助开发者更直观地了解每个联系人实际使用的提示词节点及其渲染效果。

## 新增功能

### 1. 联系人筛选

**位置**：页面顶部，节点概览下方

**功能**：
- 显示所有活跃联系人（未删除的会话）
- 点击联系人可筛选出该联系人实际使用的提示词节点
- 支持"全部联系人"选项，恢复显示所有节点

**实现原理**：
- 从 `agent_context_defaults.json` 读取 Agent 定义
- 通过 `contactId` 字段关联 Agent 与联系人
- 遍历 Agent Graph 中的 prompt 节点，建立联系人到提示词的映射关系

### 2. 上下文预览

**位置**：每个提示词节点卡片的操作按钮区

**功能**：
- 显示提示词 ID
- 展示变量替换示例（使用模拟数据）
- 渲染后的完整上下文预览
- 联系人专属标识（当选中联系人时）

**变量替换示例**：
```dart
final exampleVars = <String, String>{
  'userName': '用户',
  'characterName': contactName ?? '角色',
  'currentTime': '2026年5月26日 14:30',
  'userAddress': '你',
  'characterAddress': contactName ?? '角色',
};
```

### 3. 联系人专属节点标识

**功能**：
- 当选中联系人筛选时，节点卡片会显示"联系人专用"标签
- Agent Build 详情区域标题变更为"该联系人使用的 Agent Build 节点"
- 更清晰地展示该联系人实际涉及的节点路径

## 数据流

```
1. 加载 prompt_defaults.json
   ↓
2. 加载 agent_context_defaults.json
   ↓
3. 从数据库读取联系人列表（Conversations 表）
   ↓
4. 建立映射关系：
   - agentsByContactId: 联系人 → Agent 列表
   - graphLinksByPromptId: 提示词 → Agent Graph 节点列表
   ↓
5. 用户选择联系人
   ↓
6. 筛选出该联系人使用的提示词节点
   ↓
7. 点击"上下文预览"查看渲染效果
```

## 核心数据结构

### _PromptNodeSnapshot

```dart
class _PromptNodeSnapshot {
  final List<_PromptDefaultNode> prompts;
  final Map<String, List<_PromptGraphLink>> graphLinksByPromptId;
  final Map<String, String> overridesByPromptId;
  final List<_ContactInfo> contacts;  // 新增
  final Map<String, List<SyncedAgentContextDefinition>> agentsByContactId;  // 新增
}
```

### _PromptGraphLink

```dart
class _PromptGraphLink {
  final String agentId;
  final String agentName;
  final String stageLabel;
  final String slot;
  final String? contactId;  // 新增：关联到具体联系人
}
```

### _ContactInfo

```dart
class _ContactInfo {
  final String id;
  final String name;
  final String? avatarUrl;
}
```

## 筛选模式

增强版新增了 `contactSpecific` 筛选模式：

```dart
enum _PromptNodeFilter {
  all,              // 全部节点
  graph,            // Agent Build 图内节点
  graphMissing,     // 图外运行节点
  attention,        // 需要关注的节点
  contactSpecific,  // 联系人专属节点（新增）
}
```

## 使用场景

### 场景 1：调试特定联系人的提示词

1. 打开"调试中心"
2. 点击"提示词节点管理（增强版）"
3. 在联系人筛选区选择目标联系人
4. 查看该联系人实际使用的所有提示词节点
5. 点击"上下文预览"查看渲染后的效果

### 场景 2：验证提示词变量替换

1. 选择一个提示词节点
2. 点击"上下文预览"
3. 查看"变量替换示例"区域
4. 查看"渲染后的上下文"区域
5. 验证变量是否正确替换

### 场景 3：对比不同联系人的提示词配置

1. 选择联系人 A，记录使用的节点
2. 切换到联系人 B，对比节点差异
3. 分析不同联系人的 Agent 配置差异

## 技术细节

### 数据库查询

```dart
final contactRows = await _database.select(_database.conversations).get();
final contacts = contactRows
    .where((row) => row.deletedAt == null)
    .map((row) => _ContactInfo(
          id: row.id,
          name: row.displayName,
          avatarUrl: row.avatarUrl,
        ))
    .toList(growable: false);
```

### Agent 与联系人关联

```dart
final agentsByContactId = <String, List<SyncedAgentContextDefinition>>{};
for (final agent in defaults.agents) {
  if (agent.contactId != null) {
    agentsByContactId
        .putIfAbsent(agent.contactId!, () => [])
        .add(agent);
  }
}
```

### 提示词节点与联系人关联

```dart
for (final agent in defaults.agents) {
  for (final node in agent.agentGraph.nodes) {
    if (node.nodeType != 'prompt') continue;
    final links = graphLinks.putIfAbsent(node.nodeId, () => []);
    links.add(_PromptGraphLink(
      agentId: agent.id,
      agentName: agent.name,
      stageLabel: _readString(node.config['stageLabel']),
      slot: node.slot ?? '',
      contactId: agent.contactId,  // 关键：记录联系人 ID
    ));
  }
}
```

### 联系人专属节点筛选

```dart
List<_PromptGraphLink> linksForContact(String promptId, String? contactId) {
  if (contactId == null) {
    return graphLinksByPromptId[promptId] ?? const <_PromptGraphLink>[];
  }
  return (graphLinksByPromptId[promptId] ?? const <_PromptGraphLink>[])
      .where((link) => link.contactId == contactId)
      .toList(growable: false);
}
```

## UI 组件

### _ContactSelector

联系人选择器，显示所有联系人的芯片列表。

**特点**：
- 支持"全部联系人"选项
- 选中状态高亮显示
- 点击切换选中状态

### _ContextPreviewSheet

上下文预览底部弹窗。

**内容**：
- 联系人信息（如果选中）
- 提示词 ID
- 变量替换示例
- 渲染后的上下文
- 提示信息

### _ContactChip

联系人芯片组件。

**状态**：
- 未选中：灰色边框，白色背景
- 选中：主题色边框，主题色半透明背景

## 注意事项

1. **模拟数据**：上下文预览使用的是模拟变量值，实际运行时会根据真实上下文动态替换
2. **性能考虑**：联系人列表较多时，建议添加搜索功能
3. **数据一致性**：确保 `agent_context_defaults.json` 中的 `contactId` 与数据库中的联系人 ID 一致
4. **删除联系人**：已删除的联系人（`deletedAt != null`）不会显示在筛选列表中

## 未来改进方向

1. **搜索功能**：支持按联系人名称搜索
2. **批量操作**：支持批量修改多个联系人的提示词
3. **差异对比**：可视化对比不同联系人的提示词配置差异
4. **实时预览**：编辑提示词时实时显示渲染效果
5. **变量管理**：提供变量定义和使用情况的统计
6. **导出功能**：导出联系人的完整提示词配置

## 文件位置

- 增强版页面：`lib/src/ui/features/debug/pages/prompt_node_management_page_enhanced.dart`
- 调试中心入口：`lib/src/ui/features/debug/pages/debug_center_page.dart`
- 原版页面：`lib/src/ui/features/debug/pages/prompt_node_management_page.dart`（保留）

## 相关文档

- [提示词默认值系统](./提示词默认值系统.md)
- [Agent Context 架构](../.trellis/spec/agent-context/index.md)

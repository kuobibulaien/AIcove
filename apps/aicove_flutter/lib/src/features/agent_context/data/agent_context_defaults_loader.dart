import 'dart:convert';

import 'package:flutter/services.dart';

class AgentContextDefaultsLoader {
  static const defaultAssetPath = 'assets/agent_context_defaults.json';

  final AssetBundle? _bundle;

  const AgentContextDefaultsLoader({AssetBundle? bundle}) : _bundle = bundle;

  Future<SyncedAgentContextDefaults> load({
    String assetPath = defaultAssetPath,
  }) async {
    final raw = await (_bundle ?? rootBundle).loadString(assetPath);
    return parse(raw);
  }

  SyncedAgentContextDefaults parse(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map) {
      throw const FormatException('Agent Context defaults must be a JSON object');
    }
    return SyncedAgentContextDefaults.fromJson(_objectMap(decoded));
  }
}

class SyncedAgentContextDefaults {
  final int version;
  final String? source;
  final String? syncedAt;
  final List<SyncedAgentContextDefinition> agents;
  final List<SyncedAgentContextBinding> bindings;
  final List<SyncedAgentContextNodeSummary> nodeLibrary;

  const SyncedAgentContextDefaults({
    required this.version,
    required this.source,
    required this.syncedAt,
    required this.agents,
    required this.bindings,
    required this.nodeLibrary,
  });

  factory SyncedAgentContextDefaults.fromJson(Map<String, Object?> json) {
    return SyncedAgentContextDefaults(
      version: _int(json['version'], fallback: 1),
      source: _nullableString(json['source']),
      syncedAt: _nullableString(json['syncedAt']),
      agents: _objectList(json['agents'])
          .map(SyncedAgentContextDefinition.fromJson)
          .toList(growable: false),
      bindings: _objectList(json['bindings'])
          .map(SyncedAgentContextBinding.fromJson)
          .toList(growable: false),
      nodeLibrary: _objectList(json['nodeLibrary'])
          .map(SyncedAgentContextNodeSummary.fromJson)
          .toList(growable: false),
    );
  }

  Map<String, SyncedAgentContextDefinition> get agentsById {
    return <String, SyncedAgentContextDefinition>{
      for (final agent in agents) agent.id: agent,
    };
  }

  Map<String, SyncedAgentContextNodeSummary> get nodesById {
    return <String, SyncedAgentContextNodeSummary>{
      for (final node in nodeLibrary) node.id: node,
    };
  }

  List<SyncedAgentContextBinding> bindingsForAgent(String agentId) {
    return bindings.where((binding) => binding.agentId == agentId).toList();
  }
}

class SyncedAgentContextDefinition {
  final String id;
  final String name;
  final String agentKind;
  final String? contactId;
  final Object? modelRef;
  final String? contextRecipeId;
  final Map<String, Object?> contextProfile;
  final String? toolPolicyId;
  final String? outputContractId;
  final Map<String, Object?> triggerPolicy;
  final Map<String, Object?> assemblyFlow;
  final SyncedAgentGraph agentGraph;
  final String deliveryChannel;
  final bool enabled;

  const SyncedAgentContextDefinition({
    required this.id,
    required this.name,
    required this.agentKind,
    required this.contactId,
    required this.modelRef,
    required this.contextRecipeId,
    required this.contextProfile,
    required this.toolPolicyId,
    required this.outputContractId,
    required this.triggerPolicy,
    required this.assemblyFlow,
    required this.agentGraph,
    required this.deliveryChannel,
    required this.enabled,
  });

  factory SyncedAgentContextDefinition.fromJson(Map<String, Object?> json) {
    return SyncedAgentContextDefinition(
      id: _string(json['id']),
      name: _string(json['name']),
      agentKind: _string(json['agentKind']),
      contactId: _nullableString(json['contactId']),
      modelRef: json['modelRef'],
      contextRecipeId: _nullableString(json['contextRecipeId']),
      contextProfile: _objectMap(json['contextProfile']),
      toolPolicyId: _nullableString(json['toolPolicyId']),
      outputContractId: _nullableString(json['outputContractId']),
      triggerPolicy: _objectMap(json['triggerPolicy']),
      assemblyFlow: _objectMap(json['assemblyFlow']),
      agentGraph: SyncedAgentGraph.fromJson(_objectMap(json['agentGraph'])),
      deliveryChannel: _string(json['deliveryChannel']),
      enabled: _bool(json['enabled']),
    );
  }
}

class SyncedAgentGraph {
  final List<SyncedAgentGraphNode> nodes;
  final List<SyncedAgentGraphEdge> edges;
  final List<String> entryNodeIds;
  final List<String> outputNodeIds;
  final Map<String, Object?> viewport;

  const SyncedAgentGraph({
    required this.nodes,
    required this.edges,
    required this.entryNodeIds,
    required this.outputNodeIds,
    required this.viewport,
  });

  factory SyncedAgentGraph.fromJson(Map<String, Object?> json) {
    return SyncedAgentGraph(
      nodes: _objectList(json['nodes'])
          .map(SyncedAgentGraphNode.fromJson)
          .toList(growable: false),
      edges: _objectList(json['edges'])
          .map(SyncedAgentGraphEdge.fromJson)
          .toList(growable: false),
      entryNodeIds: _stringList(json['entryNodeIds']),
      outputNodeIds: _stringList(json['outputNodeIds']),
      viewport: _objectMap(json['viewport']),
    );
  }
}

class SyncedAgentGraphNode {
  final String id;
  final String nodeId;
  final String assetId;
  final String nodeType;
  final String label;
  final bool enabled;
  final double x;
  final double y;
  final String? slot;
  final Map<String, Object?> config;

  const SyncedAgentGraphNode({
    required this.id,
    required this.nodeId,
    required this.assetId,
    required this.nodeType,
    required this.label,
    required this.enabled,
    required this.x,
    required this.y,
    required this.slot,
    required this.config,
  });

  factory SyncedAgentGraphNode.fromJson(Map<String, Object?> json) {
    final position = _objectMap(json['position']);
    return SyncedAgentGraphNode(
      id: _string(json['id']),
      nodeId: _string(json['nodeId']),
      assetId: _string(json['assetId']),
      nodeType: _string(json['nodeType']),
      label: _string(json['label']),
      enabled: _bool(json['enabled']),
      x: _double(position['x']),
      y: _double(position['y']),
      slot: _nullableString(json['slot']),
      config: _objectMap(json['config']),
    );
  }
}

class SyncedAgentGraphEdge {
  final String id;
  final String source;
  final String target;
  final String sourcePort;
  final String targetPort;
  final bool enabled;
  final Object? condition;

  const SyncedAgentGraphEdge({
    required this.id,
    required this.source,
    required this.target,
    required this.sourcePort,
    required this.targetPort,
    required this.enabled,
    required this.condition,
  });

  factory SyncedAgentGraphEdge.fromJson(Map<String, Object?> json) {
    return SyncedAgentGraphEdge(
      id: _string(json['id']),
      source: _string(json['source']),
      target: _string(json['target']),
      sourcePort: _string(json['sourcePort']),
      targetPort: _string(json['targetPort']),
      enabled: _bool(json['enabled']),
      condition: json['condition'],
    );
  }
}

class SyncedAgentContextBinding {
  final String id;
  final String agentId;
  final String assetType;
  final String assetId;
  final String nodeType;
  final String nodeId;
  final String? graphNodeId;
  final bool enabled;
  final int? priority;
  final String? slot;
  final String? source;

  const SyncedAgentContextBinding({
    required this.id,
    required this.agentId,
    required this.assetType,
    required this.assetId,
    required this.nodeType,
    required this.nodeId,
    required this.graphNodeId,
    required this.enabled,
    required this.priority,
    required this.slot,
    required this.source,
  });

  factory SyncedAgentContextBinding.fromJson(Map<String, Object?> json) {
    return SyncedAgentContextBinding(
      id: _string(json['id']),
      agentId: _string(json['agentId']),
      assetType: _string(json['assetType']),
      assetId: _string(json['assetId']),
      nodeType: _string(json['nodeType']),
      nodeId: _string(json['nodeId']),
      graphNodeId: _nullableString(json['graphNodeId']),
      enabled: _bool(json['enabled']),
      priority: _nullableInt(json['priority']),
      slot: _nullableString(json['slot']),
      source: _nullableString(json['source']),
    );
  }
}

class SyncedAgentContextNodeSummary {
  final String id;
  final String name;
  final String assetType;
  final String nodeType;
  final String nodeId;
  final bool enabled;
  final Map<String, Object?> safeSummary;

  const SyncedAgentContextNodeSummary({
    required this.id,
    required this.name,
    required this.assetType,
    required this.nodeType,
    required this.nodeId,
    required this.enabled,
    required this.safeSummary,
  });

  factory SyncedAgentContextNodeSummary.fromJson(Map<String, Object?> json) {
    return SyncedAgentContextNodeSummary(
      id: _string(json['id']),
      name: _string(json['name']),
      assetType: _string(json['assetType']),
      nodeType: _string(json['nodeType']),
      nodeId: _string(json['nodeId']),
      enabled: _bool(json['enabled']),
      safeSummary: _objectMap(json['safeSummary']),
    );
  }
}

Map<String, Object?> _objectMap(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) {
    return value.map<String, Object?>(
      (key, value) => MapEntry(key.toString(), value),
    );
  }
  return const <String, Object?>{};
}

List<Map<String, Object?>> _objectList(Object? value) {
  if (value is! List) return const <Map<String, Object?>>[];
  return value
      .whereType<Map>()
      .map(_objectMap)
      .toList(growable: false);
}

List<String> _stringList(Object? value) {
  if (value is! List) return const <String>[];
  return value.map(_string).where((value) => value.isNotEmpty).toList();
}

String _string(Object? value) => value?.toString() ?? '';

String? _nullableString(Object? value) {
  final text = _string(value).trim();
  return text.isEmpty ? null : text;
}

bool _bool(Object? value, {bool fallback = true}) {
  return value is bool ? value : fallback;
}

int _int(Object? value, {required int fallback}) {
  return value is num ? value.toInt() : fallback;
}

int? _nullableInt(Object? value) {
  return value is num ? value.toInt() : null;
}

double _double(Object? value) {
  return value is num ? value.toDouble() : 0;
}

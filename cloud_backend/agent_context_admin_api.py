"""Agent Context Studio 管理端 API（Phase 1）

本模块按 `Agent上下文系统Web管理端实施说明_20260430.md` 实现：
- 数据落 `data/agent_context_admin.json`，与 prompt_defaults 数据隔离
- 不做数据库迁移
- 默认仅返回 safeSummary，不渲染原文
- 路由前缀由 main.py 挂载到 `/api/v1/agent-context-admin`
"""
from __future__ import annotations

import copy
import json
import re
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable, Optional

from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import RedirectResponse

from database import get_db
from prompt_defaults_codegen import (
    PromptCodegenError,
    generate_from_document as generate_prompt_defaults_from_document,
    load_document as load_prompt_defaults_document,
)

router = APIRouter()

# ── 路径与常量 ──────────────────────────────────────────────────────────
_BASE_DIR = Path(__file__).resolve().parent
DATA_PATH = _BASE_DIR / 'data' / 'agent_context_admin.json'
FLUTTER_AGENT_CONTEXT_DEFAULTS_PATH = (
    _BASE_DIR.parent / 'apps' / 'aicove_flutter' / 'assets' / 'agent_context_defaults.json'
)

DOCUMENT_VERSION = 1
PROMPT_PLACEHOLDER_RE = re.compile(
    r'\{\{\{([A-Za-z_][A-Za-z0-9_]*)\}\}\}|(?<!\{)\{([A-Za-z_][A-Za-z0-9_]*)\}(?!\})',
)

# 与 Flutter `AgentContextAssemblyPermission.id` 对齐
FULL_CHAT_PERMISSIONS: list[str] = [
    'role_card',
    'silly_tavern_preset',
    'prompt_order',
    'lorebook',
    'memory',
    'conversation_window',
    'runtime_facts',
    'regex_transform',
    'extension_prompt',
    'tool_policy',
    'output_contract',
    'provider_renderer',
]

PROACTIVE_PERMISSIONS: list[str] = [
    'role_card',
    'memory',
    'conversation_window',
    'runtime_facts',
    'tool_policy',
    'output_contract',
]

ANALYZER_PERMISSIONS: list[str] = [
    'memory',
    'conversation_window',
    'runtime_facts',
    'output_contract',
]

MEMORY_PERMISSIONS: list[str] = [
    'memory',
    'conversation_window',
    'output_contract',
]

RENDERER_PERMISSIONS: list[str] = [
    'tool_policy',
    'output_contract',
    'provider_renderer',
]

AGENT_KINDS: list[str] = ['chat', 'proactive', 'analyzer', 'memory', 'renderer']

NODE_TYPES: list[str] = [
    'role_card',
    'silly_tavern_preset',
    'prompt',
    'prompt_order',
    'lorebook',
    'memory',
    'conversation_window',
    'runtime_facts',
    'regex_set',
    'regex_transform',
    'extension_prompt',
    'tool',
    'tool_policy',
    'output_contract',
    'provider_renderer',
    'post_processor',
]

ASSET_TYPES: list[str] = NODE_TYPES

NODE_TYPE_GROUPS: dict[str, list[str]] = {
    'identity': ['role_card'],
    'preset_prompt': ['silly_tavern_preset', 'prompt', 'prompt_order', 'extension_prompt'],
    'knowledge': ['lorebook', 'memory', 'conversation_window', 'runtime_facts'],
    'transform': ['regex_set', 'regex_transform'],
    'capability': ['tool', 'tool_policy', 'provider_renderer'],
    'output': ['output_contract', 'post_processor'],
}

ASSEMBLY_SCOPES: list[str] = [
    'full_chat',
    'proactive_specialized',
    'analyzer_specialized',
    'memory_specialized',
    'renderer_specialized',
]

DELIVERY_CHANNELS: list[str] = [
    'foreground_conversation',
    'background_proactive',
    'analyzer_decision',
    'memory_writer',
    'renderer_output',
]

TRIGGER_KINDS: list[str] = [
    'user_message',
    'schedule',
    'event',
    'silence_window',
    'output_event',
    'manual',
]

DEFAULT_TRIGGER_BY_KIND: dict[str, dict[str, Any]] = {
    'chat': {
        'triggerKind': 'user_message',
        'source': 'foreground_conversation',
        'enabled': True,
    },
    'proactive': {
        'triggerKind': 'silence_window',
        'source': 'local_or_cloud_scheduler',
        'enabled': True,
    },
    'analyzer': {
        'triggerKind': 'event',
        'source': 'context_state_change',
        'enabled': True,
    },
    'memory': {
        'triggerKind': 'event',
        'source': 'conversation_changed',
        'enabled': True,
    },
    'renderer': {
        'triggerKind': 'output_event',
        'source': 'output_pipeline',
        'enabled': True,
    },
}

DEFAULT_PERMISSIONS_BY_KIND: dict[str, list[str]] = {
    'chat': FULL_CHAT_PERMISSIONS,
    'proactive': PROACTIVE_PERMISSIONS,
    'analyzer': ANALYZER_PERMISSIONS,
    'memory': MEMORY_PERMISSIONS,
    'renderer': RENDERER_PERMISSIONS,
}

DEFAULT_SCOPE_BY_KIND: dict[str, str] = {
    'chat': 'full_chat',
    'proactive': 'proactive_specialized',
    'analyzer': 'analyzer_specialized',
    'memory': 'memory_specialized',
    'renderer': 'renderer_specialized',
}

DEFAULT_DELIVERY_BY_KIND: dict[str, str] = {
    'chat': 'foreground_conversation',
    'proactive': 'background_proactive',
    'analyzer': 'analyzer_decision',
    'memory': 'memory_writer',
    'renderer': 'renderer_output',
}

BUILTIN_AGENT_GRAPH_PROMPT_IDS: dict[str, list[str]] = {
    'proactive_agent:default': [
        'auto_reply.analyzer.default',
        'auto_reply.agent.objective',
    ],
    'memory_agent:default': [
        'memory.summary.default',
        'memory.summary.extra_instruction',
        'memory.summary.role_persona.generic_instruction',
        'memory.summary.role_persona.context_instruction',
        'memory.role_scoped.root',
        'memory.profile_prompt.root',
        'memory.merge.prompt',
        'memory.reenrich.default',
    ],
}

BUILTIN_AGENT_GRAPH_STAGES: dict[str, list[dict[str, Any]]] = {
    'proactive_agent:default': [
        {
            'id': 'analyzer',
            'label': 'Analyzer / trigger decision',
            'name': '后台分析 / 触发决策',
            'order': 10,
            'description': '用于判断是否触发主动关怀的后台分析请求。',
        },
        {
            'id': 'reply_generation',
            'label': 'Proactive reply generation',
            'name': '主动回复生成',
            'order': 20,
            'description': '用于生成最终主动回复文本的聊天模型请求。',
        },
    ],
}

PROACTIVE_AGENT_GRAPH_PROMPT_STAGE: dict[str, dict[str, Any]] = {
    'auto_reply.analyzer.default': {
        'stage': 'analyzer',
        'stageLabel': 'Analyzer / trigger decision',
        'stageOrder': 10,
        'slot': 'analyzer_prompt',
        'position': {'x': 120, 'y': 120},
    },
    'auto_reply.agent.objective': {
        'stage': 'reply_generation',
        'stageLabel': 'Proactive reply generation',
        'stageOrder': 20,
        'slot': 'reply_generation_prompt',
        'position': {'x': 120, 'y': 320},
    },
}


# ── 工具函数 ────────────────────────────────────────────────────────────
def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def _new_id(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4().hex[:12]}"


def _is_object(v: Any) -> bool:
    return isinstance(v, dict)


def _str(v: Any) -> str:
    return str(v).strip() if v is not None else ''


def _ensure_list(v: Any) -> list[Any]:
    return list(v) if isinstance(v, list) else []


def _ensure_object(v: Any) -> dict[str, Any]:
    return dict(v) if isinstance(v, dict) else {}


def _float_or_default(v: Any, fallback: float) -> float:
    if v is None or v == '':
        return fallback
    try:
        return float(v)
    except (TypeError, ValueError):
        return fallback


def _normalize_graph_stages(stages: Any) -> list[dict[str, Any]]:
    normalized: list[dict[str, Any]] = []
    for index, item in enumerate(_ensure_list(stages)):
        if not isinstance(item, dict):
            continue
        stage_id = _str(item.get('id') or item.get('stage'))
        if not stage_id:
            continue
        label = _str(item.get('label') or item.get('name')) or stage_id
        order = _float_or_default(item.get('order'), index + 1)
        normalized.append({
            'id': stage_id,
            'label': label,
            'name': _str(item.get('name')) or label,
            'order': int(order) if float(order).is_integer() else order,
            'description': _str(item.get('description')) or None,
        })
    return normalized


def _normalize_trigger_policy(policy: Any, *, agent_kind: str) -> dict[str, Any]:
    default = copy.deepcopy(DEFAULT_TRIGGER_BY_KIND.get(agent_kind, DEFAULT_TRIGGER_BY_KIND['chat']))
    incoming = _ensure_object(policy)
    out = {**default, **incoming}
    trigger_kind = _str(out.get('triggerKind') or default.get('triggerKind'))
    if trigger_kind not in TRIGGER_KINDS:
        trigger_kind = _str(default.get('triggerKind') or 'manual')
    out['triggerKind'] = trigger_kind
    out['source'] = _str(out.get('source') or default.get('source') or 'manual')
    out['enabled'] = bool(out.get('enabled', True))
    # 这些字段不强校验结构，留给前端/后续 runtime 使用。
    if 'eventNames' in out and not isinstance(out.get('eventNames'), list):
        out['eventNames'] = []
    if 'conditions' in out and not isinstance(out.get('conditions'), dict):
        out['conditions'] = {}
    if 'schedule' in out and not isinstance(out.get('schedule'), dict):
        out['schedule'] = {}
    return out


def _normalize_assembly_flow(flow: Any) -> dict[str, Any]:
    incoming = _ensure_object(flow)
    stages = incoming.get('stages')
    if not isinstance(stages, list) or not stages:
        stages = [
            {'id': 'collect_nodes', 'name': '收集节点', 'enabled': True},
            {'id': 'transform', 'name': '上下文变换', 'enabled': True},
            {'id': 'budget', 'name': 'Token 预算', 'enabled': True},
            {'id': 'render', 'name': 'Provider 渲染', 'enabled': True},
            {'id': 'output', 'name': '输出归一化', 'enabled': True},
        ]
    return {
        'stages': [s for s in stages if isinstance(s, dict)],
        'notes': incoming.get('notes') or None,
    }


def _normalize_agent_graph(graph: Any) -> dict[str, Any]:
    incoming = _ensure_object(graph)
    nodes_in = incoming.get('nodes')
    edges_in = incoming.get('edges')
    nodes: list[dict[str, Any]] = []
    if isinstance(nodes_in, list):
        for index, item in enumerate(nodes_in):
            if not isinstance(item, dict):
                continue
            node_id = _str(item.get('id')) or _new_id('graph_node')
            library_node_id = _str(item.get('nodeId') or item.get('assetId'))
            position = _ensure_object(item.get('position'))
            raw_x = position.get('x') if 'x' in position else item.get('x')
            raw_y = position.get('y') if 'y' in position else item.get('y')
            nodes.append({
                'id': node_id,
                'nodeId': library_node_id,
                'assetId': library_node_id,
                'nodeType': _str(item.get('nodeType') or item.get('assetType')),
                'label': _str(item.get('label') or item.get('name')) or f'节点 {index + 1}',
                'enabled': bool(item.get('enabled', True)),
                'position': {
                    'x': _float_or_default(raw_x, 120 + index * 220),
                    'y': _float_or_default(raw_y, 160),
                },
                'slot': item.get('slot') or item.get('contextSlot') or None,
                'config': _ensure_object(item.get('config')),
            })
    edges: list[dict[str, Any]] = []
    if isinstance(edges_in, list):
        for item in edges_in:
            if not isinstance(item, dict):
                continue
            source = _str(item.get('source'))
            target = _str(item.get('target'))
            if not source or not target:
                continue
            edges.append({
                'id': _str(item.get('id')) or f'edge:{source}:{target}',
                'source': source,
                'target': target,
                'sourcePort': _str(item.get('sourcePort') or 'out'),
                'targetPort': _str(item.get('targetPort') or 'in'),
                'enabled': bool(item.get('enabled', True)),
                'condition': item.get('condition') or None,
            })
    viewport = _ensure_object(incoming.get('viewport'))
    return {
        'nodes': nodes,
        'edges': edges,
        'stages': _normalize_graph_stages(incoming.get('stages')),
        'entryNodeIds': [str(v) for v in _ensure_list(incoming.get('entryNodeIds')) if _str(v)],
        'outputNodeIds': [str(v) for v in _ensure_list(incoming.get('outputNodeIds')) if _str(v)],
        'viewport': {
            'x': _float_or_default(viewport.get('x'), 0),
            'y': _float_or_default(viewport.get('y'), 0),
            'zoom': _float_or_default(viewport.get('zoom'), 1),
        },
    }


# ── 默认文档 ────────────────────────────────────────────────────────────
def _default_document() -> dict[str, Any]:
    return {
        'version': DOCUMENT_VERSION,
        'updatedAt': _now_iso(),
        'agents': [],
        'assets': {asset_type: [] for asset_type in ASSET_TYPES},
        'bindings': [],
        'previewDefaults': {
            'provider': 'openai',
            'tokenBudget': 8000,
            'safePreview': True,
        },
        'metadata': {
            'createdAt': _now_iso(),
            'note': 'Agent Context Studio Phase 1 文档；schema 仍在收敛期。',
        },
    }


def _normalize_document(document: Any) -> dict[str, Any]:
    """补齐缺失字段，避免老文档读出来缺字段时报错。"""
    base = _default_document()
    if not isinstance(document, dict):
        return base
    out = copy.deepcopy(document)
    out.setdefault('version', DOCUMENT_VERSION)
    out.setdefault('updatedAt', _now_iso())
    if not isinstance(out.get('agents'), list):
        out['agents'] = []
    assets = out.get('assets')
    if not isinstance(assets, dict):
        assets = {}
    for asset_type in ASSET_TYPES:
        if not isinstance(assets.get(asset_type), list):
            assets[asset_type] = []
    out['assets'] = assets
    if not isinstance(out.get('bindings'), list):
        out['bindings'] = []
    if not isinstance(out.get('previewDefaults'), dict):
        out['previewDefaults'] = base['previewDefaults']
    if not isinstance(out.get('metadata'), dict):
        out['metadata'] = {}
    return out


# ── 文档读写 ────────────────────────────────────────────────────────────
def _load_document() -> dict[str, Any]:
    if not DATA_PATH.exists():
        document = _default_document()
        _ensure_builtin_agents_in_document(document)
        _save_document(document)
        return document
    try:
        raw = DATA_PATH.read_text(encoding='utf-8')
        data = json.loads(raw) if raw.strip() else _default_document()
    except Exception as e:
        raise HTTPException(status_code=500, detail=f'读取上下文文档失败：{e}')
    document = _normalize_document(data)
    if _ensure_builtin_agents_in_document(document):
        _save_document(document)
    return document


def _save_document(document: dict[str, Any]) -> None:
    document = _normalize_document(document)
    document['updatedAt'] = _now_iso()
    DATA_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = DATA_PATH.with_suffix(DATA_PATH.suffix + '.tmp')
    payload = json.dumps(document, ensure_ascii=False, indent=2)
    tmp_path.write_text(payload, encoding='utf-8')
    tmp_path.replace(DATA_PATH)
    try:
        _write_flutter_agent_context_artifact(document)
    except OSError:
        raise HTTPException(status_code=500, detail='同步 Flutter Agent Context artifact 失败')


# ── 校验 ────────────────────────────────────────────────────────────────
_AGENT_ID_PATTERN = re.compile(r'^[a-zA-Z0-9_:.\-]+$')


def _validate_agent(agent: dict[str, Any], *, allow_blank_id: bool = False) -> list[str]:
    issues: list[str] = []
    agent_id = _str(agent.get('id'))
    if not agent_id and not allow_blank_id:
        issues.append('agent.id 不能为空')
    elif agent_id and not _AGENT_ID_PATTERN.match(agent_id):
        issues.append(f'agent.id 含非法字符：{agent_id}')
    name = _str(agent.get('name'))
    if not name:
        issues.append('agent.name 不能为空')
    kind = _str(agent.get('agentKind') or 'chat')
    if kind not in AGENT_KINDS:
        issues.append(f'agent.agentKind 不合法：{kind}')
    profile = agent.get('contextProfile')
    if not _is_object(profile):
        issues.append('agent.contextProfile 必须是对象')
        profile = {}
    scope = _str(profile.get('scope'))
    if scope and scope not in ASSEMBLY_SCOPES:
        issues.append(f'contextProfile.scope 不合法：{scope}')
    permissions = profile.get('assemblyPermissions') or []
    if not isinstance(permissions, list):
        issues.append('contextProfile.assemblyPermissions 必须是字符串数组')
    else:
        for p in permissions:
            if not isinstance(p, str) or not p.strip():
                issues.append('contextProfile.assemblyPermissions 含非法元素')
                break
    delivery = _str(agent.get('deliveryChannel'))
    if delivery and delivery not in DELIVERY_CHANNELS:
        issues.append(f'deliveryChannel 不合法：{delivery}')
    trigger_policy = agent.get('triggerPolicy')
    if trigger_policy is not None:
        if not _is_object(trigger_policy):
            issues.append('triggerPolicy 必须是对象')
        else:
            trigger_kind = _str(trigger_policy.get('triggerKind'))
            if trigger_kind and trigger_kind not in TRIGGER_KINDS:
                issues.append(f'triggerPolicy.triggerKind 不合法：{trigger_kind}')
    assembly_flow = agent.get('assemblyFlow')
    if assembly_flow is not None and not _is_object(assembly_flow):
        issues.append('assemblyFlow 必须是对象')
    agent_graph = agent.get('agentGraph')
    if agent_graph is not None and not _is_object(agent_graph):
        issues.append('agentGraph 必须是对象')
    return issues


def _validate_asset(asset: dict[str, Any]) -> list[str]:
    issues: list[str] = []
    if not _str(asset.get('id')):
        issues.append('asset.id 不能为空')
    if not _str(asset.get('name')):
        issues.append('asset.name 不能为空')
    asset_type = _str(asset.get('assetType'))
    if asset_type not in ASSET_TYPES:
        issues.append(f'asset.assetType 不合法：{asset_type}')
    return issues


def _validate_binding(binding: dict[str, Any], *, agent_ids: set[str], asset_ids: set[str]) -> list[str]:
    issues: list[str] = []
    if not _str(binding.get('id')):
        issues.append('binding.id 不能为空')
    agent_id = _str(binding.get('agentId'))
    if agent_id and agent_id not in agent_ids:
        issues.append(f'binding.agentId 不存在：{agent_id}')
    asset_id = _str(binding.get('assetId') or binding.get('nodeId'))
    if asset_id and asset_id not in asset_ids:
        issues.append(f'binding.assetId/nodeId 不存在：{asset_id}')
    asset_type = _str(binding.get('assetType') or binding.get('nodeType'))
    if asset_type and asset_type not in ASSET_TYPES:
        issues.append(f'binding.assetType 不合法：{asset_type}')
    return issues


def _validate_document(document: dict[str, Any]) -> list[str]:
    issues: list[str] = []
    agents = _ensure_list(document.get('agents'))
    seen_agent_ids: set[str] = set()
    for index, agent in enumerate(agents):
        if not _is_object(agent):
            issues.append(f'agents[{index}] 必须是对象')
            continue
        for issue in _validate_agent(agent):
            issues.append(f'agents[{index}]：{issue}')
        agent_id = _str(agent.get('id'))
        if agent_id:
            if agent_id in seen_agent_ids:
                issues.append(f'agents[{index}] id 重复：{agent_id}')
            seen_agent_ids.add(agent_id)

    assets_obj = document.get('assets') or {}
    seen_asset_ids: set[str] = set()
    for asset_type, items in assets_obj.items():
        if asset_type not in ASSET_TYPES:
            issues.append(f'assets 含未知类型：{asset_type}')
            continue
        for index, asset in enumerate(_ensure_list(items)):
            if not _is_object(asset):
                issues.append(f'assets.{asset_type}[{index}] 必须是对象')
                continue
            for issue in _validate_asset(asset):
                issues.append(f'assets.{asset_type}[{index}]：{issue}')
            aid = _str(asset.get('id'))
            if aid:
                if aid in seen_asset_ids:
                    issues.append(f'assets 出现重复 id：{aid}')
                seen_asset_ids.add(aid)
    for prompt_asset in _prompt_defaults_virtual_assets():
        prompt_id = _str(prompt_asset.get('id'))
        if prompt_id:
            if prompt_id in seen_asset_ids:
                issues.append(f'assets 与 prompt_defaults 虚拟节点 id 冲突：{prompt_id}')
            else:
                seen_asset_ids.add(prompt_id)

    bindings = _ensure_list(document.get('bindings'))
    for index, binding in enumerate(bindings):
        if not _is_object(binding):
            issues.append(f'bindings[{index}] 必须是对象')
            continue
        for issue in _validate_binding(binding, agent_ids=seen_agent_ids, asset_ids=seen_asset_ids):
            issues.append(f'bindings[{index}]：{issue}')
    return issues


def _prompt_placeholders(template: str) -> set[str]:
    return {
        match.group(1) or match.group(2)
        for match in PROMPT_PLACEHOLDER_RE.finditer(template or '')
        if match.group(1) or match.group(2)
    }


def _prompt_variable_index(prompt_document: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {
        _str(variable.get('name')): variable
        for variable in _ensure_list(prompt_document.get('variables'))
        if _is_object(variable) and _str(variable.get('name'))
    }


def _prompt_variable_contract_summary(variable: dict[str, Any]) -> dict[str, Any]:
    out: dict[str, Any] = {}
    for key in (
        'label',
        'description',
        'usage',
        'valueSource',
        'runtimeShape',
        'sampleValue',
        'runtimeSampleValue',
    ):
        if key in variable and variable.get(key) not in (None, ''):
            out[key] = variable.get(key)
    return out


def _prompt_variable_contracts_for_prompt(
    prompt_document: dict[str, Any],
    variable_names: Iterable[str],
) -> dict[str, dict[str, Any]]:
    variable_index = _prompt_variable_index(prompt_document)
    out: dict[str, dict[str, Any]] = {}
    for name in variable_names:
        variable = variable_index.get(_str(name))
        if not variable:
            continue
        summary = _prompt_variable_contract_summary(variable)
        if summary:
            out[_str(name)] = summary
    return out


def _prompt_preview_variable_values(
    prompt_document: dict[str, Any],
    payload: dict[str, Any],
) -> dict[str, Any]:
    variable_index = _prompt_variable_index(prompt_document)
    payload_sample_values: dict[str, Any] = {}
    payload_runtime_values: dict[str, Any] = {}
    if isinstance(payload, dict):
        sample_values = payload.get('sampleValues')
        if _is_object(sample_values):
            payload_sample_values.update(sample_values)
        legacy_values = payload.get('variables')
        if _is_object(legacy_values):
            payload_runtime_values.update(legacy_values)
        runtime_values = payload.get('runtimeValues')
        if _is_object(runtime_values):
            payload_runtime_values.update(runtime_values)
    values: dict[str, Any] = {}
    for name, variable in variable_index.items():
        if variable.get('sampleValue') not in (None, ''):
            values[name] = variable.get('sampleValue')
        if variable.get('runtimeSampleValue') not in (None, ''):
            values[name] = variable.get('runtimeSampleValue')
    values.update(payload_sample_values)
    values.update(payload_runtime_values)
    return values


def _prompt_preview_value_to_text(value: Any) -> str:
    if value is None:
        return ''
    if isinstance(value, str):
        return value
    if isinstance(value, (dict, list)):
        return json.dumps(value, ensure_ascii=False, indent=2)
    return str(value)


def _render_prompt_template_for_preview(template: str, values: dict[str, Any]) -> tuple[str, set[str]]:
    unresolved: set[str] = set()

    def replace(match: re.Match[str]) -> str:
        name = match.group(1) or match.group(2)
        if name not in values:
            unresolved.add(name)
            return match.group(0)
        return _prompt_preview_value_to_text(values[name])

    return PROMPT_PLACEHOLDER_RE.sub(replace, template or ''), unresolved


def _prompt_default_variable_warnings(
    prompt_document: dict[str, Any],
    *,
    prompt_ids: Optional[set[str]] = None,
    include_orphans: bool = False,
) -> list[str]:
    variable_names = set(_prompt_variable_index(prompt_document))
    warnings: list[str] = []
    used_placeholders: set[str] = set()
    declared_variables: set[str] = set()
    for prompt in _ensure_list(prompt_document.get('prompts')):
        if not _is_object(prompt):
            continue
        prompt_id = _str(prompt.get('id')) or '(unknown)'
        placeholders = _prompt_placeholders(_str(prompt.get('template')))
        declared = {
            _str(item)
            for item in _ensure_list(prompt.get('variables'))
            if _str(item)
        }
        used_placeholders.update(placeholders)
        declared_variables.update(declared)
        if prompt_ids is not None and prompt_id not in prompt_ids:
            continue
        for name in sorted(placeholders - variable_names):
            warnings.append(f'{prompt_id} 引用未定义变量：{{{name}}}')
        for name in sorted(placeholders - declared):
            warnings.append(f'{prompt_id} 模板占位符未登记到 variables：{{{name}}}')
        for name in sorted(declared - placeholders):
            warnings.append(f'{prompt_id} 声明变量当前模板未直接使用：{name}')
    if include_orphans:
        for name in sorted(variable_names - used_placeholders - declared_variables):
            warnings.append(f'变量库存在孤立变量：{name}')
    return warnings


# ── 装配/摘要 ───────────────────────────────────────────────────────────
def _safe_asset_summary(asset: dict[str, Any]) -> dict[str, Any]:
    asset_type = _str(asset.get('assetType'))
    summary = _ensure_object(asset.get('safeSummary'))
    out = {
        'id': _str(asset.get('id')),
        'name': _str(asset.get('name')),
        'assetType': asset_type,
        'nodeType': asset_type,
        'nodeId': _str(asset.get('id')),
        'enabled': asset.get('enabled', True),
        'updatedAt': asset.get('updatedAt'),
    }
    if summary:
        out['safeSummary'] = summary
    if asset.get('source'):
        out['source'] = _str(asset.get('source'))
    if 'readOnly' in asset:
        out['readOnly'] = bool(asset.get('readOnly'))
    return out


def _prompt_defaults_virtual_assets() -> list[dict[str, Any]]:
    """Expose prompt_defaults prompts as read-only Agent Build library assets."""
    try:
        prompt_document = load_prompt_defaults_document()
    except Exception:
        return []

    assets: list[dict[str, Any]] = []
    for prompt in _ensure_list(prompt_document.get('prompts')):
        if not _is_object(prompt):
            continue
        prompt_id = _str(prompt.get('id'))
        if not prompt_id:
            continue
        summary = {
            'category': _str(prompt.get('category')) or None,
            'dartName': _str(prompt.get('dartName')) or None,
            'description': _str(prompt.get('description')) or None,
            'variables': [
                str(item)
                for item in _ensure_list(prompt.get('variables'))
                if _str(item)
            ],
        }
        variable_names = summary['variables'] or []
        contracts = _prompt_variable_contracts_for_prompt(prompt_document, variable_names)
        if contracts:
            summary['variableContracts'] = contracts
        validation_warnings = _prompt_default_variable_warnings(
            prompt_document,
            prompt_ids={prompt_id},
        )
        if validation_warnings:
            summary['validationWarnings'] = validation_warnings
        assets.append({
            'id': prompt_id,
            'name': _str(prompt.get('title')) or prompt_id,
            'assetType': 'prompt',
            'nodeType': 'prompt',
            'enabled': True,
            'source': 'prompt_defaults',
            'readOnly': True,
            'safeSummary': {k: v for k, v in summary.items() if v},
        })
    return assets


def _prompt_defaults_index() -> dict[str, dict[str, Any]]:
    try:
        prompt_document = load_prompt_defaults_document()
    except Exception:
        return {}
    return _prompt_defaults_index_from_document(prompt_document)


def _prompt_defaults_index_from_document(prompt_document: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {
        _str(prompt.get('id')): prompt
        for prompt in _ensure_list(prompt_document.get('prompts'))
        if _is_object(prompt) and _str(prompt.get('id'))
    }


def _prompt_default_public_detail(
    prompt: dict[str, Any],
    *,
    prompt_document: Optional[dict[str, Any]] = None,
) -> dict[str, Any]:
    if prompt_document is None:
        try:
            prompt_document = load_prompt_defaults_document()
        except Exception:
            prompt_document = {'variables': [], 'prompts': []}
    variables = [
        str(item)
        for item in _ensure_list(prompt.get('variables'))
        if _str(item)
    ]
    return {
        'id': _str(prompt.get('id')),
        'dartName': _str(prompt.get('dartName')),
        'title': _str(prompt.get('title')),
        'category': _str(prompt.get('category')),
        'description': _str(prompt.get('description')),
        'variables': variables,
        'variableContracts': _prompt_variable_contracts_for_prompt(
            prompt_document,
            variables,
        ),
        'validationWarnings': _prompt_default_variable_warnings(
            prompt_document,
            prompt_ids={_str(prompt.get('id'))},
        ),
        'template': _str(prompt.get('template')),
        'source': 'prompt_defaults',
        'nodeType': 'prompt',
    }


def _assets_for_type(document: dict[str, Any], asset_type: str) -> list[dict[str, Any]]:
    assets_obj = document.get('assets') or {}
    items = [
        asset for asset in _ensure_list(assets_obj.get(asset_type))
        if _is_object(asset)
    ]
    if asset_type == 'prompt':
        seen_ids = {_str(asset.get('id')) for asset in items if _str(asset.get('id'))}
        for asset in _prompt_defaults_virtual_assets():
            asset_id = _str(asset.get('id'))
            if asset_id and asset_id not in seen_ids:
                items.append(asset)
    return items


def _find_stored_asset(document: dict[str, Any], asset_id: str) -> tuple[str, int, dict[str, Any]]:
    assets_obj = document.get('assets') or {}
    for asset_type in ASSET_TYPES:
        items = _ensure_list(assets_obj.get(asset_type))
        for index, asset in enumerate(items):
            if _is_object(asset) and _str(asset.get('id')) == asset_id:
                return asset_type, index, asset
    if any(_str(asset.get('id')) == asset_id for asset in _prompt_defaults_virtual_assets()):
        raise HTTPException(
            status_code=400,
            detail='prompt defaults 虚拟节点为只读资产，不能通过 Agent Context API 修改或删除',
        )
    raise HTTPException(status_code=404, detail=f'Asset 不存在：{asset_id}')


def _graph_has_nodes(graph: Any) -> bool:
    return bool(_ensure_list(_normalize_agent_graph(graph).get('nodes')))


def _builtin_prompt_seed_specs(agent_id: str) -> list[dict[str, Any]]:
    specs: list[dict[str, Any]] = []
    for index, prompt_id in enumerate(BUILTIN_AGENT_GRAPH_PROMPT_IDS.get(agent_id, [])):
        stage_meta = (
            PROACTIVE_AGENT_GRAPH_PROMPT_STAGE.get(prompt_id, {})
            if agent_id == 'proactive_agent:default'
            else {}
        )
        specs.append({
            'promptId': prompt_id,
            'slot': stage_meta.get('slot') or 'prompt_defaults',
            'position': stage_meta.get('position') or {
                'x': 120 + (index % 3) * 260,
                'y': 140 + (index // 3) * 160,
            },
            'stage': stage_meta.get('stage'),
            'stageLabel': stage_meta.get('stageLabel'),
            'stageOrder': stage_meta.get('stageOrder'),
        })
    return specs


def _stage_legacy_proactive_builtin_graph(agent: dict[str, Any]) -> dict[str, Any]:
    graph = _normalize_agent_graph(agent.get('agentGraph') or agent.get('assemblyGraph'))
    existing_by_prompt = {
        _str(node.get('nodeId') or node.get('assetId')): node
        for node in _ensure_list(graph.get('nodes'))
        if _is_object(node)
    }
    nodes: list[dict[str, Any]] = []
    for index, spec in enumerate(_builtin_prompt_seed_specs('proactive_agent:default')):
        prompt_id = _str(spec.get('promptId'))
        existing = existing_by_prompt.get(prompt_id)
        if not existing:
            continue
        spec_position = _ensure_object(spec.get('position'))
        existing_position = _ensure_object(existing.get('position'))
        stage = _str(spec.get('stage'))
        config = {
            **_ensure_object(existing.get('config')),
            'source': _str(_ensure_object(existing.get('config')).get('source')) or 'builtin_seed',
            'promptDefaultId': prompt_id,
            'stage': stage,
            'stageLabel': _str(spec.get('stageLabel')) or stage,
            'stageOrder': spec.get('stageOrder'),
        }
        nodes.append({
            'id': _str(existing.get('id')) or f'graph:proactive_agent:default:{prompt_id}',
            'nodeId': prompt_id,
            'assetId': prompt_id,
            'nodeType': 'prompt',
            'label': _str(existing.get('label') or existing.get('name')) or prompt_id,
            'enabled': existing.get('enabled', True) is not False,
            'position': {
                'x': _float_or_default(
                    existing_position.get('x'),
                    _float_or_default(spec_position.get('x'), 120 + index * 260),
                ),
                'y': _float_or_default(
                    existing_position.get('y'),
                    _float_or_default(spec_position.get('y'), 140),
                ),
            },
            'slot': _str(spec.get('slot')) or existing.get('slot') or 'prompt_defaults',
            'config': config,
        })
    node_by_prompt = {_str(node.get('nodeId')): node for node in nodes}
    entries = [
        node_by_prompt[prompt_id]['id']
        for prompt_id in ('auto_reply.analyzer.default', 'auto_reply.agent.objective')
        if prompt_id in node_by_prompt
    ]
    outputs = [
        node_by_prompt[prompt_id]['id']
        for prompt_id in ('auto_reply.analyzer.default', 'auto_reply.agent.objective')
        if prompt_id in node_by_prompt
    ]
    return {
        'nodes': nodes,
        'edges': [],
        'stages': copy.deepcopy(BUILTIN_AGENT_GRAPH_STAGES['proactive_agent:default']),
        'entryNodeIds': entries,
        'outputNodeIds': outputs,
        'viewport': graph.get('viewport') or {'x': 0, 'y': 0, 'zoom': 1},
    }


def _default_builtin_agent_graph(agent_id: str) -> dict[str, Any]:
    prompt_assets = {
        _str(asset.get('id')): asset
        for asset in _prompt_defaults_virtual_assets()
        if _str(asset.get('id'))
    }
    nodes: list[dict[str, Any]] = []
    stage_node_groups: dict[str, list[dict[str, Any]]] = {}
    stage_order: list[str] = []
    for index, spec in enumerate(_builtin_prompt_seed_specs(agent_id)):
        prompt_id = _str(spec.get('promptId'))
        asset = prompt_assets.get(prompt_id)
        if not asset:
            continue
        graph_node_id = f'graph:{agent_id}:{prompt_id}'
        position = _ensure_object(spec.get('position'))
        stage = _str(spec.get('stage'))
        config = {
            'source': 'builtin_seed',
            'promptDefaultId': prompt_id,
        }
        if stage:
            config.update({
                'stage': stage,
                'stageLabel': _str(spec.get('stageLabel')) or stage,
                'stageOrder': spec.get('stageOrder'),
            })
        nodes.append({
            'id': graph_node_id,
            'nodeId': prompt_id,
            'assetId': prompt_id,
            'nodeType': 'prompt',
            'label': _str(asset.get('name')) or prompt_id,
            'enabled': True,
            'position': {
                'x': _float_or_default(position.get('x'), 120 + (index % 3) * 260),
                'y': _float_or_default(position.get('y'), 140 + (index // 3) * 160),
            },
            'slot': _str(spec.get('slot')) or 'prompt_defaults',
            'config': config,
        })
        group_key = stage or '__default__'
        if group_key not in stage_node_groups:
            stage_node_groups[group_key] = []
            stage_order.append(group_key)
        stage_node_groups[group_key].append(nodes[-1])
    edges: list[dict[str, Any]] = []
    for group_key in stage_order:
        group_nodes = stage_node_groups[group_key]
        for index in range(1, len(group_nodes)):
            source = group_nodes[index - 1]['id']
            target = group_nodes[index]['id']
            edges.append({
                'id': f'edge:{source}:{target}',
                'source': source,
                'target': target,
                'sourcePort': 'out',
                'targetPort': 'in',
                'enabled': True,
                'condition': None,
            })
    entry_node_ids = [stage_node_groups[key][0]['id'] for key in stage_order if stage_node_groups[key]]
    output_node_ids = [stage_node_groups[key][-1]['id'] for key in stage_order if stage_node_groups[key]]
    return {
        'nodes': nodes,
        'edges': edges,
        'stages': copy.deepcopy(BUILTIN_AGENT_GRAPH_STAGES.get(agent_id, [])),
        'entryNodeIds': entry_node_ids,
        'outputNodeIds': output_node_ids,
        'viewport': {'x': 0, 'y': 0, 'zoom': 1},
    }


def _agent_full_chat_template(*, agent_id: str, contact_id: str, name: str) -> dict[str, Any]:
    return {
        'id': agent_id,
        'name': name,
        'agentKind': 'chat',
        'contactId': contact_id,
        'modelRef': None,
        'contextRecipeId': f'standard_chat_recipe:{contact_id}',
        'contextProfile': {
            'scope': 'full_chat',
            'assemblyPermissions': list(FULL_CHAT_PERMISSIONS),
            'tokenBudget': None,
            'traceAssembly': True,
        },
        'toolPolicyId': None,
        'outputContractId': 'standard_chat',
        'triggerPolicy': copy.deepcopy(DEFAULT_TRIGGER_BY_KIND['chat']),
        'assemblyFlow': _normalize_assembly_flow(None),
        'agentGraph': _normalize_agent_graph(None),
        'deliveryChannel': 'foreground_conversation',
        'enabled': True,
        'metadata': {
            'source': 'web_admin',
            'createdAt': _now_iso(),
        },
    }


def _system_agent_template(*, agent_id: str, name: str, agent_kind: str) -> dict[str, Any]:
    return {
        'id': agent_id,
        'name': name,
        'agentKind': agent_kind,
        'contactId': None,
        'modelRef': None,
        'contextRecipeId': f'standard_{agent_kind}_recipe:default',
        'contextProfile': {
            'scope': DEFAULT_SCOPE_BY_KIND.get(agent_kind, 'full_chat'),
            'assemblyPermissions': list(DEFAULT_PERMISSIONS_BY_KIND.get(agent_kind, FULL_CHAT_PERMISSIONS)),
            'tokenBudget': None,
            'traceAssembly': True,
        },
        'toolPolicyId': None,
        'outputContractId': 'memory_writer' if agent_kind == 'memory' else None,
        'triggerPolicy': copy.deepcopy(DEFAULT_TRIGGER_BY_KIND.get(agent_kind, DEFAULT_TRIGGER_BY_KIND['chat'])),
        'assemblyFlow': _normalize_assembly_flow(None),
        'agentGraph': _normalize_agent_graph(None),
        'deliveryChannel': DEFAULT_DELIVERY_BY_KIND.get(agent_kind, 'foreground_conversation'),
        'enabled': True,
        'metadata': {
            'source': 'system_bootstrap',
            'createdAt': _now_iso(),
            'description': 'Agent Context Studio 默认内置 Agent。',
        },
    }


BUILTIN_AGENT_TEMPLATES: tuple[dict[str, str], ...] = (
    {
        'id': 'proactive_agent:default',
        'name': '主动回复 Agent',
        'agentKind': 'proactive',
    },
    {
        'id': 'memory_agent:default',
        'name': '记忆 Agent',
        'agentKind': 'memory',
    },
)


def _is_legacy_proactive_builtin_graph(agent: dict[str, Any]) -> bool:
    if _str(agent.get('id')) != 'proactive_agent:default':
        return False
    graph = _normalize_agent_graph(agent.get('agentGraph') or agent.get('assemblyGraph'))
    nodes = _ensure_list(graph.get('nodes'))
    if not nodes:
        return False
    prompt_ids = {_str(node.get('nodeId') or node.get('assetId')) for node in nodes}
    current_prompt_ids = set(BUILTIN_AGENT_GRAPH_PROMPT_IDS['proactive_agent:default'])
    if not current_prompt_ids.issubset(prompt_ids):
        return False
    if any(_str(_ensure_object(node.get('config')).get('stage')) for node in nodes):
        return False
    extra_prompt_ids = prompt_ids - current_prompt_ids
    if len(extra_prompt_ids) == 1 and all(
        _looks_like_legacy_proactive_seed_node(node)
        for node in nodes
        if _is_object(node)
    ):
        return True
    if prompt_ids != current_prompt_ids:
        return False
    graph_node_to_prompt = {
        _str(node.get('id')): _str(node.get('nodeId') or node.get('assetId'))
        for node in nodes
    }
    edge_pairs = {
        (
            graph_node_to_prompt.get(_str(edge.get('source')), ''),
            graph_node_to_prompt.get(_str(edge.get('target')), ''),
        )
        for edge in _ensure_list(graph.get('edges'))
        if _is_object(edge) and edge.get('enabled', True) is not False
    }
    analyzer_prompt_ids = {
        prompt_id
        for prompt_id, stage_meta in PROACTIVE_AGENT_GRAPH_PROMPT_STAGE.items()
        if stage_meta.get('stage') == 'analyzer'
    }
    reply_prompt_ids = {
        prompt_id
        for prompt_id, stage_meta in PROACTIVE_AGENT_GRAPH_PROMPT_STAGE.items()
        if stage_meta.get('stage') == 'reply_generation'
    }
    return any(
        (
            source in analyzer_prompt_ids and target in reply_prompt_ids
        ) or (
            source in reply_prompt_ids and target in analyzer_prompt_ids
        )
        for source, target in edge_pairs
    )


def _looks_like_legacy_proactive_seed_node(node: dict[str, Any]) -> bool:
    node_type = _str(node.get('nodeType') or node.get('assetType'))
    if node_type and node_type != 'prompt':
        return False
    slot = _str(node.get('slot') or node.get('contextSlot'))
    if slot and slot != 'prompt_defaults':
        return False
    source = _str(_ensure_object(node.get('config')).get('source'))
    return source in {'', 'builtin_seed'}


def _ensure_builtin_graph_stage_definitions(agent: dict[str, Any]) -> bool:
    agent_id = _str(agent.get('id'))
    default_stages = BUILTIN_AGENT_GRAPH_STAGES.get(agent_id)
    if not default_stages:
        return False
    graph = _normalize_agent_graph(agent.get('agentGraph') or agent.get('assemblyGraph'))
    nodes = _ensure_list(graph.get('nodes'))
    if not nodes:
        return False
    default_stage_ids = {_str(stage.get('id')) for stage in default_stages if _str(stage.get('id'))}
    node_stage_ids = {
        _str(_ensure_object(node.get('config')).get('stage') or node.get('stage'))
        for node in nodes
        if _str(_ensure_object(node.get('config')).get('stage') or node.get('stage'))
    }
    if not node_stage_ids.intersection(default_stage_ids):
        return False
    existing_stages = _normalize_graph_stages(graph.get('stages'))
    existing_stage_ids = {_str(stage.get('id')) for stage in existing_stages if _str(stage.get('id'))}
    missing_stages = [
        copy.deepcopy(stage)
        for stage in default_stages
        if _str(stage.get('id')) and _str(stage.get('id')) not in existing_stage_ids
    ]
    if not missing_stages:
        return False
    graph['stages'] = existing_stages + _normalize_graph_stages(missing_stages)
    agent['agentGraph'] = graph
    return True


def _ensure_builtin_agent_graph(document: dict[str, Any], agent: dict[str, Any]) -> bool:
    agent_id = _str(agent.get('id'))
    if agent_id not in BUILTIN_AGENT_GRAPH_PROMPT_IDS:
        return False
    if _is_legacy_proactive_builtin_graph(agent):
        seeded_graph = _stage_legacy_proactive_builtin_graph(agent)
        if not _ensure_list(seeded_graph.get('nodes')):
            return False
        agent['agentGraph'] = seeded_graph
        metadata = _ensure_object(agent.get('metadata'))
        metadata['graphSeedSource'] = 'prompt_defaults_virtual_nodes'
        metadata['graphSeedMigratedAt'] = _now_iso()
        metadata['graphSeedMigration'] = 'proactive_stage_split'
        agent['metadata'] = metadata
        _replace_agent_bindings_from_graph(document, agent_id, agent['agentGraph'])
        return True
    if _graph_has_nodes(agent.get('agentGraph') or agent.get('assemblyGraph')):
        return _ensure_builtin_graph_stage_definitions(agent)

    existing_graph = _graph_from_bindings(document, agent_id)
    if _ensure_list(existing_graph.get('nodes')):
        if _is_legacy_proactive_builtin_graph({'id': agent_id, 'agentGraph': existing_graph}):
            agent['agentGraph'] = _stage_legacy_proactive_builtin_graph({
                **agent,
                'agentGraph': existing_graph,
            })
            metadata = _ensure_object(agent.get('metadata'))
            metadata['graphSeedSource'] = 'prompt_defaults_virtual_nodes'
            metadata['graphSeedMigratedAt'] = _now_iso()
            metadata['graphSeedMigration'] = 'proactive_stage_split'
            agent['metadata'] = metadata
            _replace_agent_bindings_from_graph(document, agent_id, agent['agentGraph'])
        else:
            agent['agentGraph'] = existing_graph
        return True
    else:
        seeded_graph = _default_builtin_agent_graph(agent_id)
        if not _ensure_list(seeded_graph.get('nodes')):
            return False
        agent['agentGraph'] = seeded_graph
        metadata = _ensure_object(agent.get('metadata'))
        metadata.setdefault('graphSeededAt', _now_iso())
        metadata['graphSeedSource'] = 'prompt_defaults_virtual_nodes'
        agent['metadata'] = metadata

    _replace_agent_bindings_from_graph(document, agent_id, agent['agentGraph'])
    return True


def _ensure_builtin_agents_in_document(document: dict[str, Any]) -> bool:
    agents = _ensure_list(document.get('agents'))
    changed = False
    by_id = {
        _str(agent.get('id')): index
        for index, agent in enumerate(agents)
        if _is_object(agent) and _str(agent.get('id'))
    }
    for item in BUILTIN_AGENT_TEMPLATES:
        agent_id = item['id']
        if agent_id in by_id:
            index = by_id[agent_id]
            normalized = _normalize_agent(agents[index])
            if _ensure_builtin_agent_graph(document, normalized):
                changed = True
            if normalized != agents[index]:
                agents[index] = normalized
                changed = True
            continue
        agent = _system_agent_template(
            agent_id=agent_id,
            name=item['name'],
            agent_kind=item['agentKind'],
        )
        _ensure_builtin_agent_graph(document, agent)
        agents.append(agent)
        changed = True
    if changed:
        document['agents'] = agents
    return changed


def _ensure_chat_agent_in_document(
    document: dict[str, Any],
    *,
    contact_id: str,
    display_name: Optional[str] = None,
) -> tuple[dict[str, Any], bool]:
    contact_id = _str(contact_id)
    if not contact_id:
        raise HTTPException(status_code=400, detail='contact_id 不能为空')
    agents = _ensure_list(document.get('agents'))
    target_id = f'chat_agent:{contact_id}'
    for index, agent in enumerate(agents):
        if _is_object(agent) and _str(agent.get('id')) == target_id:
            normalized = _normalize_agent(agent)
            agents[index] = normalized
            document['agents'] = agents
            return normalized, False
    name = _str(display_name) or f'ChatAgent:{contact_id}'
    agent = _agent_full_chat_template(agent_id=target_id, contact_id=contact_id, name=name)
    agents.append(agent)
    document['agents'] = agents
    return agent, True


def _normalize_agent(agent: dict[str, Any]) -> dict[str, Any]:
    """补齐字段，方便前端直接使用。"""
    if not _is_object(agent):
        raise HTTPException(status_code=400, detail='agent 必须是对象')
    kind = _str(agent.get('agentKind') or 'chat')
    if kind not in AGENT_KINDS:
        kind = 'chat'
    profile = _ensure_object(agent.get('contextProfile'))
    profile_scope = _str(profile.get('scope') or DEFAULT_SCOPE_BY_KIND.get(kind, 'full_chat'))
    if profile_scope not in ASSEMBLY_SCOPES:
        profile_scope = DEFAULT_SCOPE_BY_KIND.get(kind, 'full_chat')
    permissions = profile.get('assemblyPermissions')
    if not isinstance(permissions, list) or not permissions:
        permissions = list(DEFAULT_PERMISSIONS_BY_KIND.get(kind, FULL_CHAT_PERMISSIONS))
    profile_out = {
        'scope': profile_scope,
        'assemblyPermissions': [p for p in permissions if isinstance(p, str)],
        'tokenBudget': profile.get('tokenBudget'),
        'traceAssembly': bool(profile.get('traceAssembly', True)),
    }
    delivery = _str(agent.get('deliveryChannel') or DEFAULT_DELIVERY_BY_KIND.get(kind, 'foreground_conversation'))
    if delivery not in DELIVERY_CHANNELS:
        delivery = DEFAULT_DELIVERY_BY_KIND.get(kind, 'foreground_conversation')
    out = {
        'id': _str(agent.get('id')),
        'name': _str(agent.get('name')),
        'agentKind': kind,
        'contactId': agent.get('contactId') or None,
        'modelRef': agent.get('modelRef') or None,
        'contextRecipeId': _str(agent.get('contextRecipeId')) or None,
        'contextProfile': profile_out,
        'toolPolicyId': agent.get('toolPolicyId') or None,
        'outputContractId': agent.get('outputContractId') or ('standard_chat' if kind == 'chat' else None),
        'triggerPolicy': _normalize_trigger_policy(agent.get('triggerPolicy'), agent_kind=kind),
        'assemblyFlow': _normalize_assembly_flow(agent.get('assemblyFlow')),
        'agentGraph': _normalize_agent_graph(agent.get('agentGraph') or agent.get('assemblyGraph')),
        'deliveryChannel': delivery,
        'enabled': bool(agent.get('enabled', True)),
        'metadata': _ensure_object(agent.get('metadata')),
    }
    return out


def _bindings_for_agent(document: dict[str, Any], agent_id: str) -> list[dict[str, Any]]:
    return [b for b in _ensure_list(document.get('bindings')) if _str(b.get('agentId')) == agent_id]


def _binding_summary(document: dict[str, Any], agent_id: str) -> dict[str, Any]:
    counts = {asset_type: 0 for asset_type in ASSET_TYPES}
    enabled_counts = {asset_type: 0 for asset_type in ASSET_TYPES}
    for binding in _bindings_for_agent(document, agent_id):
        asset_type = _str(binding.get('assetType') or binding.get('nodeType'))
        if asset_type in counts:
            counts[asset_type] += 1
            if binding.get('enabled', True):
                enabled_counts[asset_type] += 1
    return {
        'totals': counts,
        'enabled': enabled_counts,
        'totalBindings': sum(counts.values()),
    }


def _graph_from_bindings(document: dict[str, Any], agent_id: str) -> dict[str, Any]:
    asset_index = _build_asset_index(document)
    nodes: list[dict[str, Any]] = []
    edges: list[dict[str, Any]] = []
    bindings = sorted(
        _bindings_for_agent(document, agent_id),
        key=lambda b: (int(b.get('priority') or 100), _str(b.get('id'))),
    )
    previous_graph_node_id = ''
    for index, binding in enumerate(bindings):
        library_node_id = _str(binding.get('assetId') or binding.get('nodeId'))
        asset = asset_index.get(library_node_id)
        graph_node_id = _str(binding.get('graphNodeId')) or f'graph_node:{agent_id}:{index + 1}'
        node_type = _str(binding.get('assetType') or binding.get('nodeType') or (asset or {}).get('assetType'))
        nodes.append({
            'id': graph_node_id,
            'nodeId': library_node_id,
            'assetId': library_node_id,
            'nodeType': node_type,
            'label': _str((asset or {}).get('name')) or library_node_id,
            'enabled': bool(binding.get('enabled', True)),
            'position': {'x': 120 + index * 240, 'y': 180},
            'slot': binding.get('slot') or None,
            'config': {
                'bindingId': _str(binding.get('id')),
                'stage': _str(binding.get('stage')) or None,
                'stageLabel': _str(binding.get('stageLabel')) or None,
                'stageOrder': binding.get('stageOrder') if binding.get('stageOrder') is not None else None,
            },
        })
        if previous_graph_node_id:
            edges.append({
                'id': f'edge:{previous_graph_node_id}:{graph_node_id}',
                'source': previous_graph_node_id,
                'target': graph_node_id,
                'sourcePort': 'out',
                'targetPort': 'in',
                'enabled': True,
                'condition': None,
            })
        previous_graph_node_id = graph_node_id
    return {
        'nodes': nodes,
        'edges': edges,
        'stages': [],
        'entryNodeIds': [nodes[0]['id']] if nodes else [],
        'outputNodeIds': [nodes[-1]['id']] if nodes else [],
        'viewport': {'x': 0, 'y': 0, 'zoom': 1},
    }


def _validate_agent_graph(document: dict[str, Any], graph: dict[str, Any]) -> list[str]:
    issues: list[str] = []
    asset_index = _build_asset_index(document)
    graph_node_ids: set[str] = set()
    for index, node in enumerate(_ensure_list(graph.get('nodes'))):
        if not _is_object(node):
            issues.append(f'graph.nodes[{index}] 必须是对象')
            continue
        graph_node_id = _str(node.get('id'))
        if not graph_node_id:
            issues.append(f'graph.nodes[{index}].id 不能为空')
        elif graph_node_id in graph_node_ids:
            issues.append(f'graph.nodes[{index}].id 重复：{graph_node_id}')
        graph_node_ids.add(graph_node_id)
        library_node_id = _str(node.get('nodeId') or node.get('assetId'))
        if not library_node_id:
            issues.append(f'graph.nodes[{index}].nodeId 必填，Agent Build 只能拼节点库子节点')
        elif library_node_id not in asset_index:
            issues.append(f'graph.nodes[{index}].nodeId 不存在：{library_node_id}')
    for index, edge in enumerate(_ensure_list(graph.get('edges'))):
        if not _is_object(edge):
            issues.append(f'graph.edges[{index}] 必须是对象')
            continue
        source = _str(edge.get('source'))
        target = _str(edge.get('target'))
        if source not in graph_node_ids:
            issues.append(f'graph.edges[{index}].source 不存在：{source}')
        if target not in graph_node_ids:
            issues.append(f'graph.edges[{index}].target 不存在：{target}')
    return issues


def _bindings_from_graph(document: dict[str, Any], agent_id: str, graph: dict[str, Any]) -> list[dict[str, Any]]:
    next_bindings: list[dict[str, Any]] = []
    for index, graph_node in enumerate(_ensure_list(graph.get('nodes'))):
        library_node_id = _str(graph_node.get('nodeId') or graph_node.get('assetId'))
        node_type, _, _ = _find_asset(document, library_node_id)
        config = _ensure_object(graph_node.get('config'))
        binding = {
            'id': _str(config.get('bindingId')) or f'binding:{agent_id}:{library_node_id}:{index + 1}',
            'agentId': agent_id,
            'assetType': node_type,
            'assetId': library_node_id,
            'nodeType': node_type,
            'nodeId': library_node_id,
            'graphNodeId': _str(graph_node.get('id')),
            'enabled': bool(graph_node.get('enabled', True)),
            'priority': (index + 1) * 100,
            'slot': graph_node.get('slot') or None,
            'source': 'agent_build_graph',
            'createdAt': _now_iso(),
            'updatedAt': _now_iso(),
        }
        stage = _str(config.get('stage'))
        if stage:
            binding['stage'] = stage
            binding['stageLabel'] = _str(config.get('stageLabel')) or None
            binding['stageOrder'] = config.get('stageOrder') if config.get('stageOrder') is not None else None
        next_bindings.append(binding)
    return next_bindings


def _replace_agent_bindings_from_graph(document: dict[str, Any], agent_id: str, graph: dict[str, Any]) -> None:
    kept = [
        b for b in _ensure_list(document.get('bindings'))
        if _str(b.get('agentId')) != agent_id
    ]
    document['bindings'] = kept + _bindings_from_graph(document, agent_id, graph)


def _ordered_graph_nodes(graph: dict[str, Any]) -> list[dict[str, Any]]:
    nodes = [
        node for node in _ensure_list(graph.get('nodes'))
        if _is_object(node) and _str(node.get('id'))
    ]
    if not nodes:
        return []
    node_by_id = {_str(node.get('id')): node for node in nodes}
    outgoing: dict[str, list[str]] = {}
    incoming: set[str] = set()
    for edge in _ensure_list(graph.get('edges')):
        if not _is_object(edge) or edge.get('enabled') is False:
            continue
        source = _str(edge.get('source'))
        target = _str(edge.get('target'))
        if source in node_by_id and target in node_by_id:
            outgoing.setdefault(source, []).append(target)
            incoming.add(target)

    entries = [
        _str(node_id) for node_id in _ensure_list(graph.get('entryNodeIds'))
        if _str(node_id) in node_by_id
    ]
    if not entries:
        entries = [_str(node.get('id')) for node in nodes if _str(node.get('id')) not in incoming]
    if not entries:
        entries = [_str(nodes[0].get('id'))]

    ordered: list[dict[str, Any]] = []
    visited: set[str] = set()

    def visit(node_id: str) -> None:
        if node_id in visited or node_id not in node_by_id:
            return
        visited.add(node_id)
        ordered.append(node_by_id[node_id])
        for next_id in outgoing.get(node_id, []):
            visit(next_id)

    for entry in entries:
        visit(entry)
    for node in nodes:
        visit(_str(node.get('id')))
    return ordered


def _graph_stage_definitions(graph: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {
        _str(stage.get('id')): stage
        for stage in _normalize_graph_stages(graph.get('stages'))
        if _str(stage.get('id'))
    }


def _node_stage_metadata(
    node: dict[str, Any],
    stage_definitions: dict[str, dict[str, Any]],
    *,
    fallback_order: int,
) -> dict[str, Any]:
    config = _ensure_object(node.get('config'))
    stage_id = _str(config.get('stage') or node.get('stage'))
    if not stage_id:
        return {
            'stage': 'default',
            'stageLabel': '默认请求',
            'stageOrder': fallback_order,
            'stageDescription': None,
        }
    stage_definition = stage_definitions.get(stage_id, {})
    order_source = config.get('stageOrder')
    if order_source is None:
        order_source = stage_definition.get('order')
    return {
        'stage': stage_id,
        'stageLabel': (
            _str(config.get('stageLabel'))
            or _str(stage_definition.get('label'))
            or _str(stage_definition.get('name'))
            or stage_id
        ),
        'stageOrder': _float_or_default(order_source, fallback_order),
        'stageDescription': (
            _str(config.get('stageDescription'))
            or _str(stage_definition.get('description'))
            or None
        ),
    }


def _agent_prompt_preview(document: dict[str, Any], agent: dict[str, Any], payload: dict[str, Any]) -> dict[str, Any]:
    """Resolve enabled prompt nodes into the prompt text the Agent graph contributes."""
    agent_id = _str(agent.get('id'))
    normalized = _normalize_agent(agent)
    graph_payload = payload.get('graph') if isinstance(payload, dict) else None
    graph = _normalize_agent_graph(graph_payload or normalized.get('agentGraph'))
    if not _ensure_list(graph.get('nodes')):
        graph = _graph_from_bindings(document, agent_id)

    try:
        prompt_document = load_prompt_defaults_document()
    except Exception:
        prompt_document = {'variables': [], 'prompts': []}
    prompt_index = _prompt_defaults_index_from_document(prompt_document)
    preview_values = _prompt_preview_variable_values(prompt_document, payload if isinstance(payload, dict) else {})
    rendered: list[dict[str, Any]] = []
    node_previews: list[dict[str, Any]] = []
    stage_groups_by_id: dict[str, dict[str, Any]] = {}
    warnings: list[str] = []
    preview_prompt_ids: set[str] = set()
    stage_definitions = _graph_stage_definitions(graph)
    for graph_order, node in enumerate(_ordered_graph_nodes(graph)):
        node_id = _str(node.get('nodeId') or node.get('assetId'))
        node_type = _str(node.get('nodeType'))
        enabled = node.get('enabled', True) is not False
        if node_type != 'prompt' and node_id not in prompt_index:
            continue
        prompt = prompt_index.get(node_id)
        if not prompt:
            warnings.append(f'提示词节点不存在：{node_id}')
            continue
        detail = _prompt_default_public_detail(prompt, prompt_document=prompt_document)
        preview_prompt_ids.add(node_id)
        template_text = detail['template']
        rendered_text, unresolved_variables = _render_prompt_template_for_preview(
            template_text,
            preview_values,
        )
        for name in sorted(unresolved_variables):
            warnings.append(f'{node_id} 预览缺少变量值：{{{name}}}')
        placeholders = _prompt_placeholders(template_text)
        stage_meta = _node_stage_metadata(node, stage_definitions, fallback_order=1000 + graph_order)
        item = {
            'graphNodeId': _str(node.get('id')),
            'nodeId': node_id,
            'enabled': enabled,
            'label': _str(node.get('label')) or detail['title'] or node_id,
            'title': detail['title'] or node_id,
            'role': _str(_ensure_object(node.get('config')).get('role')) or 'system',
            **stage_meta,
            'source': 'prompt_defaults',
            'variables': detail['variables'],
            'variableContracts': detail.get('variableContracts') or {},
            'template': template_text,
            'content': rendered_text,
            'preview': rendered_text,
            'renderedContent': rendered_text,
            'usedPreviewValues': {
                name: preview_values[name]
                for name in sorted(placeholders)
                if name in preview_values
            },
            'unresolvedVariables': sorted(unresolved_variables),
            'charCount': len(rendered_text),
            'templateCharCount': len(template_text),
        }
        node_previews.append(item)
        if enabled:
            rendered.append(item)
            stage_id = item['stage']
            if stage_id not in stage_groups_by_id:
                stage_groups_by_id[stage_id] = {
                    'stage': stage_id,
                    'label': item['stageLabel'],
                    'order': item['stageOrder'],
                    'description': item['stageDescription'],
                    'firstGraphOrder': graph_order,
                    'renderedMessages': [],
                }
            stage_groups_by_id[stage_id]['renderedMessages'].append(item)

    stage_groups = sorted(
        stage_groups_by_id.values(),
        key=lambda group: (group['order'], group['firstGraphOrder']),
    )
    for group in stage_groups:
        messages = group['renderedMessages']
        group['messageCount'] = len(messages)
        group['combinedText'] = '\n\n'.join(
            f"[{index + 1}] {item['title']} ({item['nodeId']})\n{item['content']}"
            for index, item in enumerate(messages)
        )
        group['combinedTemplateText'] = '\n\n'.join(
            f"[{index + 1}] {item['title']} ({item['nodeId']})\n{item['template']}"
            for index, item in enumerate(messages)
        )
        group.pop('firstGraphOrder', None)
    combined_text = '\n\n---\n\n'.join(
        f"## {group['label']} ({group['stage']})\n\n{group['combinedText']}"
        for group in stage_groups
    )
    combined_template_text = '\n\n---\n\n'.join(
        f"## {group['label']} ({group['stage']})\n\n{group.get('combinedTemplateText', '')}"
        for group in stage_groups
    )
    if not rendered:
        warnings.append('当前图没有启用的 prompt 节点。')
    warnings.extend(
        _prompt_default_variable_warnings(
            prompt_document,
            prompt_ids=preview_prompt_ids,
            include_orphans=True,
        )
    )

    profile = _ensure_object(normalized.get('contextProfile'))
    provider = _str(payload.get('provider') if isinstance(payload, dict) else None) or 'openai'
    token_budget = (
        payload.get('tokenBudget') if isinstance(payload, dict) else None
    ) or profile.get('tokenBudget') or _ensure_object(document.get('previewDefaults')).get('tokenBudget') or 8000
    return {
        'ok': True,
        'agentId': agent_id,
        'contextRecipeId': normalized.get('contextRecipeId'),
        'assemblyPermissions': profile.get('assemblyPermissions') or [],
        'renderedMessages': rendered,
        'safeRenderedMessages': rendered,
        'nodePromptPreviews': node_previews,
        'stageGroups': stage_groups,
        'actualPromptPreview': {
            'combinedText': combined_text,
            'combinedTemplateText': combined_template_text,
            'mode': 'sample_rendered',
            'messageCount': len(rendered),
            'nodeCount': len(node_previews),
            'stageCount': len(stage_groups),
            'stageGroups': stage_groups,
        },
        'budgetTrace': {
            'tokenBudget': token_budget,
            'used': None,
            'remaining': None,
            'note': '预览展示当前 Agent Build 图中的 prompt defaults 文本；token 统计仍待运行时 assembler 接入。',
        },
        'providerMessagesSummary': {
            'provider': provider,
            'messageCount': len(rendered),
            'stageCount': len(stage_groups),
        },
        'warnings': warnings,
    }


PROMPT_DEFAULT_NODE_EDIT_FIELDS = {'title', 'category', 'description', 'variables', 'template'}


def _update_prompt_default_node(prompt_id: str, incoming: dict[str, Any]) -> tuple[dict[str, Any], dict[str, Any]]:
    if not isinstance(incoming, dict):
        raise HTTPException(status_code=400, detail='请求体必须包含对象 prompt')
    try:
        prompt_document = load_prompt_defaults_document()
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f'读取提示词文档失败：{exc}') from exc

    prompts = _ensure_list(prompt_document.get('prompts'))
    target_index = -1
    for index, prompt in enumerate(prompts):
        if _is_object(prompt) and _str(prompt.get('id')) == prompt_id:
            target_index = index
            break
    if target_index < 0:
        raise HTTPException(status_code=404, detail=f'提示词节点不存在：{prompt_id}')

    if incoming.get('id') not in (None, '', prompt_id):
        raise HTTPException(status_code=400, detail='Agent 图内编辑不支持修改提示词 ID')
    next_prompt = copy.deepcopy(prompts[target_index])
    for field in PROMPT_DEFAULT_NODE_EDIT_FIELDS:
        if field not in incoming:
            continue
        value = incoming[field]
        if field == 'variables':
            if isinstance(value, str):
                next_prompt[field] = [part.strip() for part in re.split(r'[,，]', value) if part.strip()]
            elif isinstance(value, list):
                next_prompt[field] = [str(part).strip() for part in value if _str(part)]
            else:
                raise HTTPException(status_code=400, detail='variables 必须是字符串数组')
        elif value is None:
            next_prompt[field] = ''
        else:
            next_prompt[field] = str(value)
    prompts[target_index] = next_prompt
    prompt_document['prompts'] = prompts

    try:
        generate_prompt_defaults_from_document(prompt_document)
    except PromptCodegenError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f'保存提示词文档失败：{exc}') from exc

    try:
        _write_flutter_agent_context_artifact(_load_document())
    except OSError as exc:
        raise HTTPException(status_code=500, detail='同步 Flutter Agent Context artifact 失败') from exc

    return prompt_document, _prompt_default_public_detail(next_prompt)


def _mock_assemble_preview(document: dict[str, Any], agent: dict[str, Any], payload: dict[str, Any]) -> dict[str, Any]:
    """Phase 1：返回结构 mock，不接入真实 assembler。"""
    agent_id = _str(agent.get('id'))
    profile = _ensure_object(agent.get('contextProfile'))
    bindings = _bindings_for_agent(document, agent_id)
    asset_index = _build_asset_index(document)
    asset_summary = []
    for binding in bindings:
        asset = asset_index.get(_str(binding.get('assetId') or binding.get('nodeId')))
        if asset:
            asset_summary.append({
                'bindingId': _str(binding.get('id')),
                'assetType': _str(binding.get('assetType') or binding.get('nodeType')),
                'nodeType': _str(binding.get('assetType') or binding.get('nodeType')),
                'enabled': bool(binding.get('enabled', True)),
                'priority': binding.get('priority'),
                'asset': _safe_asset_summary(asset),
                'node': _safe_asset_summary(asset),
            })

    sample_message = _str(payload.get('sampleUserMessage') or '示例消息')
    provider = _str(payload.get('provider') or 'openai')
    token_budget = payload.get('tokenBudget') or profile.get('tokenBudget') or 8000

    rendered = [
        {'role': 'system', 'source': 'role_card', 'preview': '[role card 安全摘要]'},
        {'role': 'system', 'source': 'silly_tavern_preset', 'preview': '[silly_tavern preset 安全摘要]'},
        {'role': 'system', 'source': 'lorebook', 'preview': '[lorebook 命中摘要]'},
        {'role': 'user', 'source': 'sample', 'preview': sample_message},
    ]
    return {
        'ok': True,
        'agentId': agent_id,
        'contextRecipeId': agent.get('contextRecipeId'),
        'assemblyPermissions': profile.get('assemblyPermissions') or [],
        'assetSummary': asset_summary,
        'nodeSummary': asset_summary,
        'renderedMessages': rendered,
        'safeRenderedMessages': rendered,
        'transformTrace': [
            {'stage': 'role_card', 'note': 'Phase 1 mock'},
            {'stage': 'silly_tavern_preset', 'note': 'Phase 1 mock'},
            {'stage': 'lorebook', 'note': 'Phase 1 mock'},
            {'stage': 'regex_transform', 'note': 'Phase 1 mock'},
        ],
        'budgetTrace': {
            'tokenBudget': token_budget,
            'used': 0,
            'remaining': token_budget,
            'note': 'Phase 1 mock：未接入真实 token 计算',
        },
        'providerMessagesSummary': {
            'provider': provider,
            'messageCount': len(rendered),
        },
        'warnings': [
            'Phase 1：组装预览仍为结构 mock；待 assembler 接入后替换。',
        ],
    }


def _build_asset_index(document: dict[str, Any]) -> dict[str, dict[str, Any]]:
    index: dict[str, dict[str, Any]] = {}
    assets_obj = document.get('assets') or {}
    for asset_type in ASSET_TYPES:
        for asset in _ensure_list(assets_obj.get(asset_type)):
            if _is_object(asset) and _str(asset.get('id')):
                index[_str(asset.get('id'))] = asset
    for asset in _prompt_defaults_virtual_assets():
        index.setdefault(_str(asset.get('id')), asset)
    return index


def _find_agent(document: dict[str, Any], agent_id: str) -> tuple[int, dict[str, Any]]:
    agents = _ensure_list(document.get('agents'))
    for index, agent in enumerate(agents):
        if _is_object(agent) and _str(agent.get('id')) == agent_id:
            return index, agent
    raise HTTPException(status_code=404, detail=f'Agent 不存在：{agent_id}')


def _find_asset(document: dict[str, Any], asset_id: str) -> tuple[str, int, dict[str, Any]]:
    assets_obj = document.get('assets') or {}
    for asset_type in ASSET_TYPES:
        items = _ensure_list(assets_obj.get(asset_type))
        for index, asset in enumerate(items):
            if _is_object(asset) and _str(asset.get('id')) == asset_id:
                return asset_type, index, asset
    for index, asset in enumerate(_prompt_defaults_virtual_assets()):
        if _str(asset.get('id')) == asset_id:
            return 'prompt', index, asset
    raise HTTPException(status_code=404, detail=f'Asset 不存在：{asset_id}')


def _artifact_agent(agent: dict[str, Any]) -> dict[str, Any]:
    normalized = _normalize_agent(agent)
    return {
        'id': normalized['id'],
        'name': normalized['name'],
        'agentKind': normalized['agentKind'],
        'contactId': normalized['contactId'],
        'modelRef': normalized['modelRef'],
        'contextRecipeId': normalized['contextRecipeId'],
        'contextProfile': normalized['contextProfile'],
        'toolPolicyId': normalized['toolPolicyId'],
        'outputContractId': normalized['outputContractId'],
        'triggerPolicy': normalized['triggerPolicy'],
        'assemblyFlow': normalized['assemblyFlow'],
        'agentGraph': normalized['agentGraph'],
        'deliveryChannel': normalized['deliveryChannel'],
        'enabled': normalized['enabled'],
    }


def _artifact_binding(binding: dict[str, Any]) -> dict[str, Any]:
    out = {
        'id': _str(binding.get('id')),
        'agentId': _str(binding.get('agentId')),
        'assetType': _str(binding.get('assetType') or binding.get('nodeType')),
        'assetId': _str(binding.get('assetId') or binding.get('nodeId')),
        'nodeType': _str(binding.get('nodeType') or binding.get('assetType')),
        'nodeId': _str(binding.get('nodeId') or binding.get('assetId')),
        'graphNodeId': _str(binding.get('graphNodeId')) or None,
        'enabled': bool(binding.get('enabled', True)),
        'priority': binding.get('priority'),
        'slot': binding.get('slot') or None,
        'source': binding.get('source') or None,
    }
    stage = _str(binding.get('stage'))
    if stage:
        out['stage'] = stage
        out['stageLabel'] = _str(binding.get('stageLabel')) or None
        out['stageOrder'] = binding.get('stageOrder') if binding.get('stageOrder') is not None else None
    return out


def _flutter_agent_context_artifact(document: dict[str, Any]) -> dict[str, Any]:
    document = _normalize_document(copy.deepcopy(document))
    _ensure_builtin_agents_in_document(document)
    agents = [_artifact_agent(agent) for agent in _ensure_list(document.get('agents')) if _is_object(agent)]
    bindings = [
        _artifact_binding(binding)
        for binding in _ensure_list(document.get('bindings'))
        if _is_object(binding)
    ]
    referenced_node_ids = {
        _str(binding.get('nodeId') or binding.get('assetId'))
        for binding in bindings
        if _str(binding.get('nodeId') or binding.get('assetId'))
    }
    asset_index = _build_asset_index(document)
    node_library = [
        _safe_asset_summary(asset_index[node_id])
        for node_id in sorted(referenced_node_ids)
        if node_id in asset_index
    ]
    return {
        'version': DOCUMENT_VERSION,
        'source': 'cloud_backend/data/agent_context_admin.json',
        'syncedAt': _now_iso(),
        'agents': agents,
        'bindings': bindings,
        'nodeLibrary': node_library,
    }


def _write_flutter_agent_context_artifact(document: dict[str, Any]) -> dict[str, Any]:
    artifact = _flutter_agent_context_artifact(document)
    FLUTTER_AGENT_CONTEXT_DEFAULTS_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = FLUTTER_AGENT_CONTEXT_DEFAULTS_PATH.with_suffix(
        FLUTTER_AGENT_CONTEXT_DEFAULTS_PATH.suffix + '.tmp',
    )
    tmp_path.write_text(json.dumps(artifact, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    tmp_path.replace(FLUTTER_AGENT_CONTEXT_DEFAULTS_PATH)
    return artifact


# ── 路由：面板 ──────────────────────────────────────────────────────────
@router.get('/panel', include_in_schema=False)
async def get_panel():
    """兼容旧入口；真实主面板统一由 prompt-defaults-admin 返回。"""
    return RedirectResponse(url='/api/v1/prompt-defaults-admin/panel')


# ── 路由：schema ────────────────────────────────────────────────────────
@router.get('/schema')
async def get_schema():
    """供前端渲染表单的轻量 schema。"""
    return {
        'version': DOCUMENT_VERSION,
        'agentKinds': AGENT_KINDS,
        'assetTypes': ASSET_TYPES,
        'nodeTypes': NODE_TYPES,
        'nodeTypeGroups': NODE_TYPE_GROUPS,
        'assemblyScopes': ASSEMBLY_SCOPES,
        'deliveryChannels': DELIVERY_CHANNELS,
        'triggerKinds': TRIGGER_KINDS,
        'agentBuildGraph': {
            'nodeIdRequired': True,
            'edgePorts': ['in', 'out', 'success', 'failure', 'tool', 'fallback'],
            'defaultViewport': {'x': 0, 'y': 0, 'zoom': 1},
        },
        'fullChatPermissions': FULL_CHAT_PERMISSIONS,
        'permissionsByKind': DEFAULT_PERMISSIONS_BY_KIND,
        'scopeByKind': DEFAULT_SCOPE_BY_KIND,
        'deliveryByKind': DEFAULT_DELIVERY_BY_KIND,
        'triggerByKind': DEFAULT_TRIGGER_BY_KIND,
    }


# ── 路由：文档 ──────────────────────────────────────────────────────────
@router.get('/document')
async def get_document():
    document = _load_document()
    try:
        prompt_warnings = _prompt_default_variable_warnings(
            load_prompt_defaults_document(),
            include_orphans=True,
        )
    except Exception:
        prompt_warnings = []
    return {
        'document': document,
        'path': str(DATA_PATH),
        'issues': _validate_document(document),
        'promptDefaultWarnings': prompt_warnings,
    }


@router.put('/document')
async def put_document(payload: dict[str, Any]):
    document_payload = payload.get('document') if isinstance(payload, dict) else None
    if not isinstance(document_payload, dict):
        raise HTTPException(status_code=400, detail='请求体必须包含对象 document')
    document = _normalize_document(document_payload)
    _ensure_builtin_agents_in_document(document)
    issues = _validate_document(document)
    if issues:
        raise HTTPException(status_code=400, detail={'message': '文档校验失败', 'issues': issues})
    _save_document(document)
    return {'ok': True, 'document': document, 'message': 'Agent Context 文档已保存'}


@router.post('/document/validate')
async def validate_document(payload: Optional[dict[str, Any]] = None):
    document = (payload or {}).get('document') if isinstance(payload, dict) else None
    document = _normalize_document(document) if document is not None else _load_document()
    issues = _validate_document(document)
    try:
        prompt_warnings = _prompt_default_variable_warnings(
            load_prompt_defaults_document(),
            include_orphans=True,
        )
    except Exception:
        prompt_warnings = []
    return {'ok': not issues, 'issues': issues, 'promptDefaultWarnings': prompt_warnings}


@router.post('/document/export')
async def export_document(payload: Optional[dict[str, Any]] = None):
    document = _load_document()
    issues = _validate_document(document)
    return {
        'ok': not issues,
        'issues': issues,
        'exportedAt': _now_iso(),
        'version': DOCUMENT_VERSION,
        'document': document,
    }


@router.post('/document/sync-project')
async def sync_project_document():
    document = _load_document()
    artifact = _write_flutter_agent_context_artifact(document)
    return {
        'ok': True,
        'path': str(FLUTTER_AGENT_CONTEXT_DEFAULTS_PATH),
        'agentCount': len(_ensure_list(artifact.get('agents'))),
        'bindingCount': len(_ensure_list(artifact.get('bindings'))),
        'nodeCount': len(_ensure_list(artifact.get('nodeLibrary'))),
        'message': 'Agent Context artifact 已同步到 Flutter assets',
    }


# ── 路由：Agents ────────────────────────────────────────────────────────
@router.get('/agents')
async def list_agents():
    document = _load_document()
    agents = _ensure_list(document.get('agents'))
    enriched = []
    for agent in agents:
        if not _is_object(agent):
            continue
        normalized = _normalize_agent(agent)
        normalized['bindingSummary'] = _binding_summary(document, normalized['id'])
        enriched.append(normalized)
    return {
        'agents': enriched,
        'agentCount': len(enriched),
        'permissionDefaults': DEFAULT_PERMISSIONS_BY_KIND,
    }


@router.post('/agents')
async def create_agent(payload: dict[str, Any]):
    document = _load_document()
    agent_payload = payload.get('agent') if isinstance(payload, dict) else None
    if not isinstance(agent_payload, dict):
        raise HTTPException(status_code=400, detail='请求体必须包含对象 agent')
    agent = _normalize_agent(agent_payload)
    if not agent.get('id'):
        agent['id'] = _new_id('agent')
    issues = _validate_agent(agent)
    if issues:
        raise HTTPException(status_code=400, detail={'message': 'Agent 校验失败', 'issues': issues})
    agents = _ensure_list(document.get('agents'))
    if any(_is_object(a) and _str(a.get('id')) == agent['id'] for a in agents):
        raise HTTPException(status_code=400, detail=f'Agent id 已存在：{agent["id"]}')
    agents.append(agent)
    document['agents'] = agents
    _save_document(document)
    return {'ok': True, 'agent': agent, 'message': f'Agent 已创建：{agent["id"]}'}


@router.get('/agents/{agent_id}')
async def get_agent(agent_id: str):
    document = _load_document()
    _, agent = _find_agent(document, agent_id)
    normalized = _normalize_agent(agent)
    normalized['bindingSummary'] = _binding_summary(document, agent_id)
    bindings = _bindings_for_agent(document, agent_id)
    asset_index = _build_asset_index(document)
    bindings_view = []
    for binding in bindings:
        asset = asset_index.get(_str(binding.get('assetId') or binding.get('nodeId')))
        bindings_view.append({
            **binding,
            'assetSafeSummary': _safe_asset_summary(asset) if asset else None,
            'nodeSafeSummary': _safe_asset_summary(asset) if asset else None,
            'nodeId': _str(binding.get('assetId') or binding.get('nodeId')),
            'nodeType': _str(binding.get('assetType') or binding.get('nodeType')),
        })
    return {'agent': normalized, 'bindings': bindings_view, 'agentGraph': normalized.get('agentGraph')}


@router.put('/agents/{agent_id}')
async def update_agent(agent_id: str, payload: dict[str, Any]):
    document = _load_document()
    index, _ = _find_agent(document, agent_id)
    agent_payload = payload.get('agent') if isinstance(payload, dict) else None
    if not isinstance(agent_payload, dict):
        raise HTTPException(status_code=400, detail='请求体必须包含对象 agent')
    agent = _normalize_agent(agent_payload)
    if not agent.get('id'):
        agent['id'] = agent_id
    issues = _validate_agent(agent)
    if issues:
        raise HTTPException(status_code=400, detail={'message': 'Agent 校验失败', 'issues': issues})
    agents = _ensure_list(document.get('agents'))
    next_id = agent['id']
    if next_id != agent_id and any(
        _is_object(a) and _str(a.get('id')) == next_id and i != index
        for i, a in enumerate(agents)
    ):
        raise HTTPException(status_code=400, detail=f'Agent id 已存在：{next_id}')
    agents[index] = agent
    document['agents'] = agents
    if next_id != agent_id:
        for binding in _ensure_list(document.get('bindings')):
            if _str(binding.get('agentId')) == agent_id:
                binding['agentId'] = next_id
                binding['updatedAt'] = _now_iso()
    _save_document(document)
    return {'ok': True, 'agent': agent, 'message': f'Agent 已保存：{next_id}'}


@router.delete('/agents/{agent_id}')
async def delete_agent(agent_id: str):
    document = _load_document()
    index, _ = _find_agent(document, agent_id)
    agents = _ensure_list(document.get('agents'))
    del agents[index]
    document['agents'] = agents
    document['bindings'] = [
        b for b in _ensure_list(document.get('bindings'))
        if _str(b.get('agentId')) != agent_id
    ]
    _save_document(document)
    return {'ok': True, 'message': f'Agent 已删除：{agent_id}'}


@router.post('/agents/{agent_id}/duplicate')
async def duplicate_agent(agent_id: str):
    document = _load_document()
    _, agent = _find_agent(document, agent_id)
    new_agent = copy.deepcopy(agent)
    new_id = _new_id('agent')
    new_agent['id'] = new_id
    new_agent['name'] = f"{_str(agent.get('name'))} (副本)"
    new_agent.setdefault('metadata', {})['duplicatedFrom'] = agent_id
    new_agent['metadata']['createdAt'] = _now_iso()
    document.setdefault('agents', []).append(_normalize_agent(new_agent))
    _save_document(document)
    return {'ok': True, 'agent': new_agent, 'message': f'已复制为：{new_id}'}


@router.post('/agents/{agent_id}/preview')
async def preview_agent(agent_id: str, payload: Optional[dict[str, Any]] = None):
    document = _load_document()
    _, agent = _find_agent(document, agent_id)
    return _mock_assemble_preview(document, _normalize_agent(agent), payload or {})


@router.post('/agents/{agent_id}/prompt-preview')
async def preview_agent_prompt(agent_id: str, payload: Optional[dict[str, Any]] = None):
    document = _load_document()
    _, agent = _find_agent(document, agent_id)
    return _agent_prompt_preview(document, _normalize_agent(agent), payload or {})


@router.get('/agents/{agent_id}/flow')
async def get_agent_flow(agent_id: str):
    document = _load_document()
    _, agent = _find_agent(document, agent_id)
    normalized = _normalize_agent(agent)
    graph = normalized.get('agentGraph') or {}
    if not _ensure_list(graph.get('nodes')):
        graph = _graph_from_bindings(document, agent_id)
    return {
        'agentId': agent_id,
        'triggerPolicy': normalized['triggerPolicy'],
        'assemblyFlow': normalized['assemblyFlow'],
        'agentGraph': graph,
        'nodeBindingSummary': _binding_summary(document, agent_id),
    }


@router.put('/agents/{agent_id}/flow')
async def update_agent_flow(agent_id: str, payload: dict[str, Any]):
    document = _load_document()
    index, agent = _find_agent(document, agent_id)
    normalized = _normalize_agent(agent)
    if 'triggerPolicy' in payload:
        normalized['triggerPolicy'] = _normalize_trigger_policy(
            payload.get('triggerPolicy'),
            agent_kind=normalized['agentKind'],
        )
    if 'assemblyFlow' in payload:
        normalized['assemblyFlow'] = _normalize_assembly_flow(payload.get('assemblyFlow'))
    if 'agentGraph' in payload or 'graph' in payload:
        graph = _normalize_agent_graph(payload.get('agentGraph') or payload.get('graph'))
        graph_issues = _validate_agent_graph(document, graph)
        if graph_issues:
            raise HTTPException(status_code=400, detail={'message': 'Agent graph 校验失败', 'issues': graph_issues})
        normalized['agentGraph'] = graph
        _replace_agent_bindings_from_graph(document, agent_id, graph)
    issues = _validate_agent(normalized)
    if issues:
        raise HTTPException(status_code=400, detail={'message': 'Agent flow 校验失败', 'issues': issues})
    document['agents'][index] = normalized
    _save_document(document)
    return {
        'ok': True,
        'agentId': agent_id,
        'triggerPolicy': normalized['triggerPolicy'],
        'assemblyFlow': normalized['assemblyFlow'],
        'agentGraph': normalized.get('agentGraph'),
    }


@router.get('/agents/{agent_id}/graph')
async def get_agent_graph(agent_id: str):
    document = _load_document()
    _, agent = _find_agent(document, agent_id)
    normalized = _normalize_agent(agent)
    graph = normalized.get('agentGraph') or {}
    if not _ensure_list(graph.get('nodes')):
        graph = _graph_from_bindings(document, agent_id)
    return {
        'agentId': agent_id,
        'graph': graph,
        'nodeBindingSummary': _binding_summary(document, agent_id),
    }


@router.put('/agents/{agent_id}/graph')
async def update_agent_graph(agent_id: str, payload: dict[str, Any]):
    """保存 Agent Build 流程图。

    Agent Build 的主体是流程图画布；每个 graph node 必须引用节点库的 nodeId。
    保存图时会同步生成兼容旧预览/绑定统计的 bindings。
    """
    document = _load_document()
    index, agent = _find_agent(document, agent_id)
    graph_payload = payload.get('graph') if isinstance(payload, dict) else None
    if graph_payload is None:
        graph_payload = payload.get('agentGraph') if isinstance(payload, dict) else None
    graph = _normalize_agent_graph(graph_payload)
    graph_issues = _validate_agent_graph(document, graph)
    if graph_issues:
        raise HTTPException(status_code=400, detail={'message': 'Agent graph 校验失败', 'issues': graph_issues})
    normalized = _normalize_agent(agent)
    normalized['agentGraph'] = graph
    document['agents'][index] = normalized
    _replace_agent_bindings_from_graph(document, agent_id, graph)
    _save_document(document)
    return {
        'ok': True,
        'agentId': agent_id,
        'graph': graph,
        'nodeBindingSummary': _binding_summary(document, agent_id),
    }


@router.get('/agents/{agent_id}/nodes')
async def list_agent_nodes(agent_id: str):
    document = _load_document()
    agent_index, agent = _find_agent(document, agent_id)
    asset_index = _build_asset_index(document)
    nodes = []
    for binding in sorted(
        _bindings_for_agent(document, agent_id),
        key=lambda b: (int(b.get('priority') or 100), _str(b.get('id'))),
    ):
        node = asset_index.get(_str(binding.get('assetId') or binding.get('nodeId')))
        nodes.append({
            **binding,
            'nodeId': _str(binding.get('assetId') or binding.get('nodeId')),
            'nodeType': _str(binding.get('assetType') or binding.get('nodeType')),
            'nodeSafeSummary': _safe_asset_summary(node) if node else None,
        })
    return {'agentId': agent_id, 'nodes': nodes, 'count': len(nodes)}


@router.put('/agents/{agent_id}/nodes')
async def replace_agent_nodes(agent_id: str, payload: dict[str, Any]):
    """替换某个 Agent 的节点编排绑定。

    前端传 `nodes` 数组，元素至少包含 `nodeId` 或 `assetId`；后端仍复用 bindings 存储，
    因而旧 assets/bindings API 与新 nodes API 可以并存。
    """
    document = _load_document()
    agent_index, agent = _find_agent(document, agent_id)
    incoming = payload.get('nodes') if isinstance(payload, dict) else None
    if not isinstance(incoming, list):
        raise HTTPException(status_code=400, detail='请求体必须包含数组 nodes')
    kept = [
        b for b in _ensure_list(document.get('bindings'))
        if _str(b.get('agentId')) != agent_id
    ]
    next_bindings: list[dict[str, Any]] = []
    for index, item in enumerate(incoming):
        if not isinstance(item, dict):
            raise HTTPException(status_code=400, detail=f'nodes[{index}] 必须是对象')
        node_id = _str(item.get('nodeId') or item.get('assetId'))
        if not node_id:
            raise HTTPException(status_code=400, detail=f'nodes[{index}].nodeId 必填')
        node_type, _, _ = _find_asset(document, node_id)
        binding = {
            'id': _str(item.get('id')) or f'binding:{agent_id}:{node_id}',
            'agentId': agent_id,
            'assetType': node_type,
            'assetId': node_id,
            'nodeType': node_type,
            'nodeId': node_id,
            'enabled': bool(item.get('enabled', True)),
            'priority': item.get('priority', (index + 1) * 100),
            'slot': item.get('slot') or item.get('contextSlot') or None,
            'source': item.get('source') or 'node_editor',
            'createdAt': item.get('createdAt') or _now_iso(),
            'updatedAt': _now_iso(),
        }
        next_bindings.append(binding)
    document['bindings'] = kept + next_bindings
    normalized = _normalize_agent(agent)
    normalized['agentGraph'] = _graph_from_bindings({**document, 'bindings': next_bindings}, agent_id)
    document['agents'][agent_index] = normalized
    issues = _validate_document(document)
    if issues:
        raise HTTPException(status_code=400, detail={'message': '节点绑定校验失败', 'issues': issues})
    _save_document(document)
    return {'ok': True, 'agentId': agent_id, 'nodes': next_bindings, 'count': len(next_bindings)}


# ── 路由：Contacts ──────────────────────────────────────────────────────
@router.get('/contacts')
async def list_contacts(
    user_id: Optional[int] = Query(default=None, description='按用户过滤；不传则只返回 Web 草稿（不读 DB）'),
    limit: int = Query(default=50, ge=1, le=500),
    db: Any = Depends(get_db),
):
    """联系人列表：

    - 默认仅基于 web 草稿（不读真实 DB），第一阶段避免泄露 PII。
    - 显式传 `user_id` 时读取该用户的 Conversation 摘要（最多 limit 条）。
    """
    document = _load_document()
    drafts = _ensure_list(document.get('metadata', {}).get('contactDrafts'))
    db_contacts: list[dict[str, Any]] = []
    if user_id is not None:
        from models import Conversation

        rows: Iterable[Any] = (
            db.query(Conversation)
            .filter(Conversation.user_id == user_id, Conversation.deleted_at.is_(None))
            .order_by(Conversation.updated_at.desc())
            .limit(limit)
            .all()
        )
        for row in rows:
            db_contacts.append({
                'id': row.id,
                'displayName': row.display_name,
                'updatedAt': row.updated_at,
                'userId': row.user_id,
                'isPinned': bool(row.is_pinned),
            })
    agent_index = {
        _str(a.get('contactId')): _str(a.get('id'))
        for a in _ensure_list(document.get('agents'))
        if _is_object(a) and _str(a.get('contactId'))
    }
    contacts = []
    for c in drafts:
        if not _is_object(c):
            continue
        cid = _str(c.get('id'))
        contacts.append({
            'id': cid,
            'displayName': _str(c.get('displayName') or c.get('name') or cid),
            'source': 'draft',
            'agentId': agent_index.get(cid),
        })
    for c in db_contacts:
        contacts.append({
            **c,
            'source': 'db',
            'agentId': agent_index.get(c['id']),
        })
    return {
        'contacts': contacts,
        'draftCount': len(drafts),
        'dbCount': len(db_contacts),
        'note': '默认不读 DB，加 ?user_id=<id> 拉取该用户已同步的联系人。',
    }


@router.post('/contacts/drafts')
async def create_contact_draft(payload: dict[str, Any]):
    """创建一个本地草稿 Contact，便于在 Web 端独立测试。"""
    document = _load_document()
    contact_id = _str(payload.get('id')) or _new_id('contact')
    display_name = _str(payload.get('displayName')) or contact_id
    metadata = _ensure_object(document.get('metadata'))
    drafts = _ensure_list(metadata.get('contactDrafts'))
    if any(_is_object(c) and _str(c.get('id')) == contact_id for c in drafts):
        raise HTTPException(status_code=400, detail=f'草稿 Contact 已存在：{contact_id}')
    draft = {
        'id': contact_id,
        'displayName': display_name,
        'createdAt': _now_iso(),
        'source': 'draft',
    }
    drafts.append(draft)
    metadata['contactDrafts'] = drafts
    document['metadata'] = metadata
    _save_document(document)
    return {'ok': True, 'contact': draft}


@router.post('/contacts/{contact_id}/chat-agent/ensure')
async def ensure_chat_agent(contact_id: str, payload: Optional[dict[str, Any]] = None):
    document = _load_document()
    name = _str((payload or {}).get('displayName')) or f'ChatAgent:{contact_id}'
    agent, created = _ensure_chat_agent_in_document(document, contact_id=contact_id, display_name=name)
    _save_document(document)
    return {
        'ok': True,
        'agent': agent,
        'message': '已生成 chat_agent' if created else '已存在',
        'created': created,
    }


@router.post('/contacts/chat-agents/ensure-all')
async def ensure_all_chat_agents(
    payload: Optional[dict[str, Any]] = None,
    db: Any = Depends(get_db),
):
    """为联系人批量补齐独立 ChatAgent。

    - 传 `userId` 时从同步库 Conversation 读取该用户联系人。
    - 不传 `userId` 时默认只处理 Web 草稿联系人，避免裸跑读取真实 DB。
    """
    payload = payload or {}
    user_id = payload.get('userId')
    include_drafts = bool(payload.get('includeDrafts', True))
    try:
        limit = int(payload.get('limit') or 500)
    except (TypeError, ValueError):
        raise HTTPException(status_code=400, detail='limit 必须是整数')
    limit = max(1, min(limit, 1000))
    user_id_int: Optional[int] = None
    if user_id is not None:
        try:
            user_id_int = int(user_id)
        except (TypeError, ValueError):
            raise HTTPException(status_code=400, detail='userId 必须是整数')
        if user_id_int <= 0:
            raise HTTPException(status_code=400, detail='userId 必须是正整数')
    document = _load_document()
    candidates: list[dict[str, Any]] = []
    if include_drafts:
        for c in _ensure_list(document.get('metadata', {}).get('contactDrafts')):
            if _is_object(c) and _str(c.get('id')):
                candidates.append({
                    'id': _str(c.get('id')),
                    'displayName': _str(c.get('displayName') or c.get('name') or c.get('id')),
                    'source': 'draft',
                })
    if user_id_int is not None:
        from models import Conversation

        rows: Iterable[Any] = (
            db.query(Conversation)
            .filter(Conversation.user_id == user_id_int, Conversation.deleted_at.is_(None))
            .order_by(Conversation.updated_at.desc())
            .limit(limit)
            .all()
        )
        for row in rows:
            candidates.append({
                'id': row.id,
                'displayName': row.display_name,
                'source': 'db',
            })
    seen: set[str] = set()
    results: list[dict[str, Any]] = []
    for c in candidates:
        cid = _str(c.get('id'))
        if not cid or cid in seen:
            continue
        seen.add(cid)
        agent, created = _ensure_chat_agent_in_document(
            document,
            contact_id=cid,
            display_name=_str(c.get('displayName')) or cid,
        )
        results.append({
            'contactId': cid,
            'source': c.get('source'),
            'agentId': agent.get('id'),
            'created': created,
        })
    _save_document(document)
    return {
        'ok': True,
        'results': results,
        'createdCount': sum(1 for r in results if r.get('created')),
        'total': len(results),
        'note': '每个 contactId 对应 chat_agent:<contactId>；不传 userId 时只处理 Web 草稿联系人。',
    }


@router.get('/contacts/{contact_id}/chat-agent')
async def get_chat_agent(contact_id: str):
    document = _load_document()
    target_id = f'chat_agent:{contact_id}'
    try:
        _, agent = _find_agent(document, target_id)
    except HTTPException:
        return {'ok': False, 'agent': None, 'message': f'未找到 {target_id}'}
    normalized = _normalize_agent(agent)
    normalized['bindingSummary'] = _binding_summary(document, target_id)
    return {'ok': True, 'agent': normalized}


# ── 路由：Assets ────────────────────────────────────────────────────────
@router.get('/nodes')
async def list_nodes(type: Optional[str] = Query(default=None, description='按 nodeType 过滤')):
    document = _load_document()
    if type:
        if type not in NODE_TYPES:
            raise HTTPException(status_code=400, detail=f'未知 nodeType：{type}')
        items = _assets_for_type(document, type)
        return {'nodes': [_safe_asset_summary(a) for a in items], 'nodeType': type}
    out = {}
    for node_type in NODE_TYPES:
        items = _assets_for_type(document, node_type)
        out[node_type] = [_safe_asset_summary(a) for a in items]
    return {'nodesByType': out, 'nodeTypeGroups': NODE_TYPE_GROUPS}


@router.post('/nodes')
async def create_node(payload: dict[str, Any]):
    node = payload.get('node') if isinstance(payload, dict) else None
    if node is None:
        node = payload.get('asset') if isinstance(payload, dict) else None
    if not isinstance(node, dict):
        raise HTTPException(status_code=400, detail='请求体必须包含对象 node')
    asset = dict(node)
    asset['assetType'] = _str(asset.get('nodeType') or asset.get('assetType'))
    response = await create_asset({'asset': asset})
    return {
        'ok': True,
        'node': response['asset'],
        'asset': response['asset'],
    }


@router.get('/prompt-default-nodes/{prompt_id}')
async def get_prompt_default_node(prompt_id: str):
    prompt = _prompt_defaults_index().get(prompt_id)
    if not prompt:
        raise HTTPException(status_code=404, detail=f'提示词节点不存在：{prompt_id}')
    return {
        'ok': True,
        'node': _prompt_default_public_detail(prompt),
        'prompt': _prompt_default_public_detail(prompt),
    }


@router.put('/prompt-default-nodes/{prompt_id}')
async def update_prompt_default_node(prompt_id: str, payload: dict[str, Any]):
    prompt_payload = payload.get('prompt') if isinstance(payload, dict) else None
    if prompt_payload is None:
        prompt_payload = payload.get('node') if isinstance(payload, dict) else None
    prompt_document, prompt = _update_prompt_default_node(prompt_id, prompt_payload)
    return {
        'ok': True,
        'node': prompt,
        'prompt': prompt,
        'document': prompt_document,
        'message': '提示词节点已保存，并已同步更新 Dart 默认值。',
    }


@router.get('/nodes/{node_id}')
async def get_node(node_id: str, includeRaw: bool = Query(default=False, description='是否返回 raw 原文')):
    response = await get_asset(node_id, includeRaw=includeRaw)
    return {
        'node': response['asset'],
        'asset': response['asset'],
        'nodeType': response['assetType'],
        'assetType': response['assetType'],
        **({'raw': response['raw']} if includeRaw and 'raw' in response else {}),
    }


@router.put('/nodes/{node_id}')
async def update_node(node_id: str, payload: dict[str, Any]):
    node = payload.get('node') if isinstance(payload, dict) else None
    if node is None:
        node = payload.get('asset') if isinstance(payload, dict) else None
    if not isinstance(node, dict):
        raise HTTPException(status_code=400, detail='请求体必须包含对象 node')
    asset = dict(node)
    if asset.get('nodeType') and not asset.get('assetType'):
        asset['assetType'] = asset.get('nodeType')
    response = await update_asset(node_id, {'asset': asset})
    return {'ok': True, 'node': response['asset'], 'asset': response['asset']}


@router.delete('/nodes/{node_id}')
async def delete_node(node_id: str):
    return await delete_asset(node_id)


@router.get('/assets')
async def list_assets(type: Optional[str] = Query(default=None, description='按 assetType 过滤')):
    document = _load_document()
    if type:
        if type not in ASSET_TYPES:
            raise HTTPException(status_code=400, detail=f'未知 assetType：{type}')
        items = _assets_for_type(document, type)
        return {'assets': [_safe_asset_summary(a) for a in items], 'assetType': type}
    out = {}
    for asset_type in ASSET_TYPES:
        items = _assets_for_type(document, asset_type)
        out[asset_type] = [_safe_asset_summary(a) for a in items]
    return {'assetsByType': out}


@router.post('/assets')
async def create_asset(payload: dict[str, Any]):
    asset = payload.get('asset') if isinstance(payload, dict) else None
    if not isinstance(asset, dict):
        raise HTTPException(status_code=400, detail='请求体必须包含对象 asset')
    asset = dict(asset)
    asset_type = _str(asset.get('assetType'))
    if asset_type not in ASSET_TYPES:
        raise HTTPException(status_code=400, detail=f'未知 assetType：{asset_type}')
    if not _str(asset.get('id')):
        asset['id'] = _new_id(asset_type)
    asset.setdefault('enabled', True)
    asset.setdefault('createdAt', _now_iso())
    asset['updatedAt'] = _now_iso()
    issues = _validate_asset(asset)
    if issues:
        raise HTTPException(status_code=400, detail={'message': 'Asset 校验失败', 'issues': issues})
    document = _load_document()
    assets_obj = document.get('assets') or {}
    items = _ensure_list(assets_obj.get(asset_type))
    if _str(asset.get('id')) in _build_asset_index(document):
        raise HTTPException(status_code=400, detail=f'Asset id 已存在：{asset["id"]}')
    items.append(asset)
    assets_obj[asset_type] = items
    document['assets'] = assets_obj
    _save_document(document)
    return {'ok': True, 'asset': _safe_asset_summary(asset)}


@router.get('/assets/{asset_id}')
async def get_asset(asset_id: str, includeRaw: bool = Query(default=False, description='是否返回 raw 原文')):
    document = _load_document()
    asset_type, _, asset = _find_asset(document, asset_id)
    response = {
        'asset': _safe_asset_summary(asset),
        'assetType': asset_type,
    }
    if includeRaw:
        response['raw'] = asset
    return response


@router.put('/assets/{asset_id}')
async def update_asset(asset_id: str, payload: dict[str, Any]):
    document = _load_document()
    asset_type, index, existing = _find_stored_asset(document, asset_id)
    payload_asset = payload.get('asset') if isinstance(payload, dict) else None
    if not isinstance(payload_asset, dict):
        raise HTTPException(status_code=400, detail='请求体必须包含对象 asset')
    new_asset = {**existing, **payload_asset}
    new_asset['id'] = asset_id
    new_asset['assetType'] = asset_type
    new_asset['updatedAt'] = _now_iso()
    issues = _validate_asset(new_asset)
    if issues:
        raise HTTPException(status_code=400, detail={'message': 'Asset 校验失败', 'issues': issues})
    document['assets'][asset_type][index] = new_asset
    _save_document(document)
    return {'ok': True, 'asset': _safe_asset_summary(new_asset)}


@router.delete('/assets/{asset_id}')
async def delete_asset(asset_id: str):
    document = _load_document()
    asset_type, index, _ = _find_stored_asset(document, asset_id)
    del document['assets'][asset_type][index]
    document['bindings'] = [
        b for b in _ensure_list(document.get('bindings'))
        if _str(b.get('assetId')) != asset_id
    ]
    _save_document(document)
    return {'ok': True, 'message': f'Asset 已删除：{asset_id}'}


# ── 路由：Bindings ──────────────────────────────────────────────────────
@router.get('/bindings')
async def list_bindings(agent_id: Optional[str] = Query(default=None, alias='agentId')):
    document = _load_document()
    bindings = _ensure_list(document.get('bindings'))
    if agent_id:
        bindings = [b for b in bindings if _str(b.get('agentId')) == agent_id]
    enriched = []
    asset_index = _build_asset_index(document)
    for binding in bindings:
        if not _is_object(binding):
            continue
        asset_id = _str(binding.get('assetId') or binding.get('nodeId'))
        node = asset_index.get(asset_id)
        enriched.append({
            **binding,
            'nodeId': asset_id,
            'nodeType': _str(binding.get('assetType') or binding.get('nodeType')),
            'nodeSafeSummary': _safe_asset_summary(node) if node else None,
        })
    return {'bindings': enriched, 'count': len(enriched)}


@router.post('/bindings')
async def create_binding(payload: dict[str, Any]):
    document = _load_document()
    binding = payload.get('binding') if isinstance(payload, dict) else None
    if not isinstance(binding, dict):
        raise HTTPException(status_code=400, detail='请求体必须包含对象 binding')
    binding = dict(binding)
    agent_id = _str(binding.get('agentId'))
    asset_id = _str(binding.get('assetId') or binding.get('nodeId'))
    if not agent_id or not asset_id:
        raise HTTPException(status_code=400, detail='binding 必须包含 agentId 和 assetId/nodeId')
    asset_type, _, asset = _find_asset(document, asset_id)
    binding.setdefault('id', f'binding:{agent_id}:{asset_id}')
    binding['assetType'] = asset_type
    binding.setdefault('enabled', True)
    binding.setdefault('priority', 100)
    binding.setdefault('source', 'web_admin')
    binding.setdefault('createdAt', _now_iso())
    binding['updatedAt'] = _now_iso()
    bindings = _ensure_list(document.get('bindings'))
    if any(_is_object(b) and _str(b.get('id')) == binding['id'] for b in bindings):
        raise HTTPException(status_code=400, detail=f'Binding id 已存在：{binding["id"]}')
    binding['assetId'] = asset_id
    binding['nodeId'] = asset_id
    binding['nodeType'] = asset_type
    bindings.append(binding)
    document['bindings'] = bindings
    _save_document(document)
    return {'ok': True, 'binding': binding, 'node': _safe_asset_summary(asset)}


@router.delete('/bindings/{binding_id}')
async def delete_binding(binding_id: str):
    document = _load_document()
    bindings = _ensure_list(document.get('bindings'))
    new_list = [b for b in bindings if _str(b.get('id')) != binding_id]
    if len(new_list) == len(bindings):
        raise HTTPException(status_code=404, detail=f'Binding 不存在：{binding_id}')
    document['bindings'] = new_list
    _save_document(document)
    return {'ok': True, 'message': f'Binding 已删除：{binding_id}'}


# ── 路由：SillyTavern Import (Phase 1 安全摘要占位) ────────────────────
def _summarize_silly_tavern(content: dict[str, Any]) -> dict[str, Any]:
    prompts = content.get('prompts') if isinstance(content, dict) else None
    prompt_count = len(prompts) if isinstance(prompts, list) else 0
    prompt_order = content.get('prompt_order') if isinstance(content, dict) else None
    groups: list[dict[str, Any]] = []
    if isinstance(prompt_order, list):
        for group in prompt_order:
            if not isinstance(group, dict):
                continue
            entries = group.get('order') or group.get('prompts') or []
            entries_list = entries if isinstance(entries, list) else []
            groups.append({
                'id': str(group.get('character_id') or group.get('id') or ''),
                'nodeCount': len(entries_list),
            })
    selected_id = max(groups, key=lambda g: g['nodeCount'], default={}).get('id') if groups else None
    selected_count = next((g['nodeCount'] for g in groups if g['id'] == selected_id), 0) if selected_id else 0
    regex_rules = content.get('regex') or content.get('regex_scripts') if isinstance(content, dict) else None
    regex_count = len(regex_rules) if isinstance(regex_rules, list) else 0
    enabled_regex = 0
    if isinstance(regex_rules, list):
        for rule in regex_rules:
            if isinstance(rule, dict) and rule.get('disabled') in (False, None):
                enabled_regex += 1
    extensions = content.get('extensions') if isinstance(content, dict) else None
    return {
        'promptCount': prompt_count,
        'promptOrderGroupCount': len(groups),
        'selectedPromptOrderId': selected_id,
        'selectedPromptOrderNodeCount': selected_count,
        'markerCount': sum(1 for p in (prompts or []) if isinstance(p, dict) and p.get('marker')),
        'regexRuleCount': regex_count,
        'enabledRegexRuleCount': enabled_regex,
        'disabledRegexRuleCount': max(0, regex_count - enabled_regex),
        'hasWorldInfoBefore': bool(prompt_count and any(
            isinstance(p, dict) and p.get('identifier') == 'worldInfoBefore' for p in (prompts or [])
        )),
        'hasWorldInfoAfter': bool(prompt_count and any(
            isinstance(p, dict) and p.get('identifier') == 'worldInfoAfter' for p in (prompts or [])
        )),
        'hasExtensions': bool(extensions),
        'promptOrderGroups': groups,
    }


@router.post('/silly-tavern/import/preview')
async def silly_tavern_preview(payload: dict[str, Any]):
    if not isinstance(payload, dict):
        raise HTTPException(status_code=400, detail='请求体必须是对象')
    content = payload.get('content')
    if not isinstance(content, dict):
        raise HTTPException(status_code=400, detail='content 必须是对象')
    summary = _summarize_silly_tavern(content)
    warnings: list[str] = []
    if summary['promptCount'] == 0:
        warnings.append('未识别到 prompts 数组，可能不是 SillyTavern 预设。')
    if summary['promptOrderGroupCount'] == 0:
        warnings.append('未识别到 prompt_order 分组。')
    return {
        'ok': True,
        'summary': summary,
        'promptOrderGroups': summary['promptOrderGroups'],
        'warnings': warnings,
    }


@router.post('/silly-tavern/import/commit')
async def silly_tavern_commit(payload: dict[str, Any]):
    if not isinstance(payload, dict):
        raise HTTPException(status_code=400, detail='请求体必须是对象')
    content = payload.get('content')
    if not isinstance(content, dict):
        raise HTTPException(status_code=400, detail='content 必须是对象')
    name = _str(payload.get('name')) or _str(payload.get('fileName')) or 'SillyTavern Preset'
    selected_prompt_order = payload.get('selectedPromptOrderId')
    summary = _summarize_silly_tavern(content)
    document = _load_document()
    asset_id = _new_id('st_preset')
    asset = {
        'id': asset_id,
        'name': name,
        'assetType': 'silly_tavern_preset',
        'source': 'silly_tavern_json',
        'safeSummary': summary,
        'selectedPromptOrderId': str(selected_prompt_order) if selected_prompt_order is not None else summary.get('selectedPromptOrderId'),
        'raw': content,
        'createdAt': _now_iso(),
        'updatedAt': _now_iso(),
        'enabled': True,
    }
    document['assets']['silly_tavern_preset'].append(asset)
    _save_document(document)
    return {'ok': True, 'asset': _safe_asset_summary(asset), 'message': f'预设已导入：{asset_id}'}


# ── 路由：Preview Assemble ──────────────────────────────────────────────
@router.post('/preview/assemble')
async def preview_assemble(payload: dict[str, Any]):
    if not isinstance(payload, dict):
        raise HTTPException(status_code=400, detail='请求体必须是对象')
    agent_id = _str(payload.get('agentId'))
    if not agent_id:
        raise HTTPException(status_code=400, detail='agentId 必填')
    document = _load_document()
    _, agent = _find_agent(document, agent_id)
    return _mock_assemble_preview(document, _normalize_agent(agent), payload)

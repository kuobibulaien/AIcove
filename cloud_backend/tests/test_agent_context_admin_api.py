import asyncio
import json
import tempfile
import unittest
from pathlib import Path

import agent_context_admin_api as api


class AgentContextAdminApiTest(unittest.TestCase):
    def setUp(self):
        self._original_prompt_defaults_loader = api.load_prompt_defaults_document
        api.load_prompt_defaults_document = self._fake_prompt_defaults_document

    def tearDown(self):
        api.load_prompt_defaults_document = self._original_prompt_defaults_loader

    def _fake_prompt_defaults_document(self):
        prompt_ids = (
            api.BUILTIN_AGENT_GRAPH_PROMPT_IDS['proactive_agent:default']
            + api.BUILTIN_AGENT_GRAPH_PROMPT_IDS['memory_agent:default']
        )
        prompts = []
        for prompt_id in prompt_ids:
            dart_name = ''.join(part.capitalize() for part in prompt_id.replace(':', '.').split('.'))
            prompts.append({
                'id': prompt_id,
                'dartName': dart_name[:1].lower() + dart_name[1:],
                'title': prompt_id,
                'category': 'test',
                'description': '',
                'variables': (
                    ['state_json', 'current_role_persona', 'trigger_list']
                    if prompt_id == 'auto_reply.analyzer.default'
                    else []
                ),
                'template': f'{prompt_id} body',
            })
        return {
            'version': 1,
            'variables': [
                {
                    'name': 'state_json',
                    'label': 'State JSON',
                    'sampleValue': '{"mode":"active"}',
                    'runtimeSampleValue': '{"mode":"active","conversation_id":"conv_test"}',
                    'valueSource': 'ContextAnalyzer._buildRuntimeStateJson',
                    'runtimeShape': {'type': 'json_string'},
                },
                {
                    'name': 'current_role_persona',
                    'label': 'Persona',
                    'sampleValue': 'Test persona',
                    'valueSource': 'PersonaPromptCodec.userPrompt',
                    'runtimeShape': {'type': 'string'},
                },
                {
                    'name': 'trigger_list',
                    'label': 'Triggers',
                    'sampleValue': '当前会话暂无待处理触发器。',
                    'valueSource': 'ContextAnalyzer._formatTriggerListForPrompt',
                    'runtimeShape': {'type': 'string'},
                },
            ],
            'prompts': prompts,
        }

    def _use_temp_paths(self, temp_dir: str) -> tuple[Path, Path, Path, Path]:
        original_data_path = api.DATA_PATH
        original_artifact_path = api.FLUTTER_AGENT_CONTEXT_DEFAULTS_PATH
        api.DATA_PATH = Path(temp_dir) / 'agent_context_admin.json'
        api.FLUTTER_AGENT_CONTEXT_DEFAULTS_PATH = Path(temp_dir) / 'agent_context_defaults.json'
        return original_data_path, original_artifact_path, api.DATA_PATH, api.FLUTTER_AGENT_CONTEXT_DEFAULTS_PATH

    def test_load_document_bootstraps_builtin_agents(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            original_data_path, original_artifact_path, _, artifact_path = self._use_temp_paths(temp_dir)
            try:
                document = api._load_document()
                self.assertTrue(artifact_path.exists())
            finally:
                api.DATA_PATH = original_data_path
                api.FLUTTER_AGENT_CONTEXT_DEFAULTS_PATH = original_artifact_path

        agents = {agent['id']: agent for agent in document['agents']}
        agent_ids = set(agents)
        self.assertIn('proactive_agent:default', agent_ids)
        self.assertIn('memory_agent:default', agent_ids)
        self.assertGreater(len(agents['proactive_agent:default']['agentGraph']['nodes']), 0)
        self.assertGreater(len(agents['memory_agent:default']['agentGraph']['nodes']), 0)

    def test_builtin_bootstrap_preserves_existing_agents(self):
        document = {
            'version': api.DOCUMENT_VERSION,
            'agents': [
                {
                    'id': 'proactive_agent:default',
                    'name': '自定义主动回复',
                    'agentKind': 'proactive',
                    'contextProfile': {
                        'scope': 'proactive_specialized',
                        'assemblyPermissions': ['memory'],
                    },
                    'triggerPolicy': {
                        'triggerKind': 'manual',
                        'source': 'custom',
                        'enabled': False,
                    },
                    'deliveryChannel': 'background_proactive',
                },
                {
                    'id': 'agent_custom',
                    'name': 'Custom',
                    'agentKind': 'chat',
                    'contextProfile': {},
                },
            ],
            'assets': {},
            'bindings': [],
        }

        changed = api._ensure_builtin_agents_in_document(document)

        self.assertTrue(changed)
        agents = {agent['id']: agent for agent in document['agents']}
        self.assertEqual(agents['proactive_agent:default']['name'], '自定义主动回复')
        self.assertEqual(
            agents['proactive_agent:default']['triggerPolicy']['source'],
            'custom',
        )
        self.assertIn('agent_custom', agents)
        self.assertIn('memory_agent:default', agents)
        self.assertGreater(len(agents['proactive_agent:default']['agentGraph']['nodes']), 0)
        self.assertGreater(len(agents['memory_agent:default']['agentGraph']['nodes']), 0)

    def test_builtin_seed_uses_prompt_default_virtual_nodes_and_bindings(self):
        document = api._default_document()

        changed = api._ensure_builtin_agents_in_document(document)

        self.assertTrue(changed)
        agents = {agent['id']: agent for agent in document['agents']}
        proactive_node_ids = {
            node['nodeId']
            for node in agents['proactive_agent:default']['agentGraph']['nodes']
        }
        memory_node_ids = {
            node['nodeId']
            for node in agents['memory_agent:default']['agentGraph']['nodes']
        }
        self.assertEqual(
            set(api.BUILTIN_AGENT_GRAPH_PROMPT_IDS['proactive_agent:default']),
            proactive_node_ids,
        )
        self.assertEqual(
            set(api.BUILTIN_AGENT_GRAPH_PROMPT_IDS['memory_agent:default']),
            memory_node_ids,
        )
        proactive_graph = agents['proactive_agent:default']['agentGraph']
        proactive_stage_ids = {stage['id'] for stage in proactive_graph['stages']}
        self.assertEqual({'analyzer', 'reply_generation'}, proactive_stage_ids)
        proactive_stage_by_prompt = {
            node['nodeId']: node['config'].get('stage')
            for node in proactive_graph['nodes']
        }
        self.assertEqual('analyzer', proactive_stage_by_prompt['auto_reply.analyzer.default'])
        self.assertEqual('reply_generation', proactive_stage_by_prompt['auto_reply.agent.objective'])
        proactive_node_by_graph_id = {
            node['id']: node['nodeId']
            for node in proactive_graph['nodes']
        }
        proactive_edge_pairs = {
            (
                proactive_node_by_graph_id[edge['source']],
                proactive_node_by_graph_id[edge['target']],
            )
            for edge in proactive_graph['edges']
        }
        self.assertEqual(set(), proactive_edge_pairs)
        self.assertNotIn(
            ('auto_reply.analyzer.default', 'auto_reply.agent.objective'),
            proactive_edge_pairs,
        )
        binding_agent_ids = {binding['agentId'] for binding in document['bindings']}
        self.assertIn('proactive_agent:default', binding_agent_ids)
        self.assertIn('memory_agent:default', binding_agent_ids)

    def test_builtin_proactive_graph_restores_missing_stage_definitions(self):
        document = api._default_document()
        agent = api._system_agent_template(
            agent_id='proactive_agent:default',
            name='主动回复 Agent',
            agent_kind='proactive',
        )
        graph = api._default_builtin_agent_graph('proactive_agent:default')
        graph['stages'] = []
        agent['agentGraph'] = graph
        document['agents'].append(agent)

        changed = api._ensure_builtin_agents_in_document(document)

        self.assertTrue(changed)
        graph = document['agents'][0]['agentGraph']
        stage_ids = {stage['id'] for stage in graph['stages']}
        self.assertEqual({'analyzer', 'reply_generation'}, stage_ids)

        artifact = api._flutter_agent_context_artifact(document)
        proactive = next(
            agent
            for agent in artifact['agents']
            if agent['id'] == 'proactive_agent:default'
        )
        artifact_stage_ids = {
            stage['id']
            for stage in proactive['agentGraph']['stages']
        }
        self.assertEqual({'analyzer', 'reply_generation'}, artifact_stage_ids)

    def test_builtin_bootstrap_migrates_legacy_proactive_linear_seed(self):
        document = api._default_document()
        agent = api._system_agent_template(
            agent_id='proactive_agent:default',
            name='主动回复 Agent',
            agent_kind='proactive',
        )
        agent.pop('metadata', None)
        old_nodes = []
        legacy_extra_prompt_id = 'legacy.proactive.extra_context'
        for index, prompt_id in enumerate([
            'auto_reply.analyzer.default',
            'auto_reply.agent.objective',
            legacy_extra_prompt_id,
        ]):
            old_nodes.append({
                'id': f'g{index + 1}',
                'nodeId': prompt_id,
                'assetId': prompt_id,
                'nodeType': 'prompt',
                'label': prompt_id,
                'enabled': True,
                'position': {'x': 120 + index * 240, 'y': 140},
                'slot': 'prompt_defaults',
                'config': {'source': 'builtin_seed', 'promptDefaultId': prompt_id},
            })
        agent['agentGraph'] = api._normalize_agent_graph({
            'nodes': old_nodes,
            'edges': [
                {'id': 'e1', 'source': 'g1', 'target': 'g2'},
                {'id': 'e2', 'source': 'g2', 'target': 'g3'},
            ],
            'entryNodeIds': ['g1'],
            'outputNodeIds': ['g3'],
        })
        document['agents'].append(agent)

        changed = api._ensure_builtin_agents_in_document(document)

        self.assertTrue(changed)
        graph = document['agents'][0]['agentGraph']
        graph_prompt_ids = {node['nodeId'] for node in graph['nodes']}
        self.assertEqual(
            {'auto_reply.analyzer.default', 'auto_reply.agent.objective'},
            graph_prompt_ids,
        )
        node_by_graph_id = {node['id']: node['nodeId'] for node in graph['nodes']}
        edge_pairs = {
            (node_by_graph_id[edge['source']], node_by_graph_id[edge['target']])
            for edge in graph['edges']
        }
        self.assertEqual(set(), edge_pairs)
        stages = {node['nodeId']: node['config'].get('stage') for node in graph['nodes']}
        self.assertEqual('reply_generation', stages['auto_reply.agent.objective'])
        self.assertEqual(
            'proactive_stage_split',
            document['agents'][0]['metadata']['graphSeedMigration'],
        )

    def test_builtin_bootstrap_migrates_binding_only_legacy_proactive_linear_seed(self):
        document = api._default_document()
        agent = api._system_agent_template(
            agent_id='proactive_agent:default',
            name='主动回复 Agent',
            agent_kind='proactive',
        )
        agent['agentGraph'] = api._normalize_agent_graph(None)
        document['agents'].append(agent)
        legacy_extra_prompt_id = 'legacy.proactive.extra_context'
        for index, prompt_id in enumerate([
            'auto_reply.analyzer.default',
            'auto_reply.agent.objective',
            legacy_extra_prompt_id,
        ]):
            document['bindings'].append({
                'id': f'legacy_binding_{index + 1}',
                'agentId': 'proactive_agent:default',
                'assetType': 'prompt',
                'assetId': prompt_id,
                'nodeType': 'prompt',
                'nodeId': prompt_id,
                'graphNodeId': f'g{index + 1}',
                'enabled': True,
                'priority': (index + 1) * 100,
                'slot': 'prompt_defaults',
            })

        changed = api._ensure_builtin_agents_in_document(document)

        self.assertTrue(changed)
        graph = document['agents'][0]['agentGraph']
        graph_prompt_ids = {node['nodeId'] for node in graph['nodes']}
        self.assertEqual(
            {'auto_reply.analyzer.default', 'auto_reply.agent.objective'},
            graph_prompt_ids,
        )
        node_by_graph_id = {node['id']: node['nodeId'] for node in graph['nodes']}
        edge_pairs = {
            (node_by_graph_id[edge['source']], node_by_graph_id[edge['target']])
            for edge in graph['edges']
        }
        self.assertEqual(set(), edge_pairs)
        binding_stages = {
            binding['nodeId']: binding.get('stage')
            for binding in document['bindings']
            if binding.get('agentId') == 'proactive_agent:default'
        }
        self.assertEqual('analyzer', binding_stages['auto_reply.analyzer.default'])
        self.assertEqual('reply_generation', binding_stages['auto_reply.agent.objective'])
        self.assertNotIn(legacy_extra_prompt_id, binding_stages)
        self.assertEqual(
            'proactive_stage_split',
            document['agents'][0]['metadata']['graphSeedMigration'],
        )

    def test_prompt_defaults_prompt_nodes_are_valid_graph_assets(self):
        prompt_document = api.load_prompt_defaults_document()
        prompt_id = prompt_document['prompts'][0]['id']
        document = api._default_document()
        graph = api._normalize_agent_graph({
            'nodes': [
                {
                    'id': 'graph_prompt_1',
                    'nodeId': prompt_id,
                    'nodeType': 'prompt',
                    'label': 'Prompt node',
                    'position': {'x': 120, 'y': 160},
                },
            ],
            'edges': [],
        })

        self.assertEqual([], api._validate_agent_graph(document, graph))
        node_type, _, asset = api._find_asset(document, prompt_id)
        self.assertEqual('prompt', node_type)
        self.assertEqual(prompt_id, asset['id'])

    def test_prompt_default_virtual_nodes_are_listed_readonly(self):
        prompt_id = api.load_prompt_defaults_document()['prompts'][0]['id']
        with tempfile.TemporaryDirectory() as temp_dir:
            original_data_path, original_artifact_path, _, _ = self._use_temp_paths(temp_dir)
            try:
                response = asyncio.run(api.list_nodes(type='prompt'))
            finally:
                api.DATA_PATH = original_data_path
                api.FLUTTER_AGENT_CONTEXT_DEFAULTS_PATH = original_artifact_path

        nodes = {node['id']: node for node in response['nodes']}
        self.assertIn(prompt_id, nodes)
        self.assertTrue(nodes[prompt_id]['readOnly'])
        self.assertEqual('prompt_defaults', nodes[prompt_id]['source'])

    def test_prompt_default_virtual_node_summary_includes_variables(self):
        assets = {
            asset['id']: asset
            for asset in api._prompt_defaults_virtual_assets()
        }
        analyzer = assets['auto_reply.analyzer.default']

        self.assertIn(
            'current_role_persona',
            analyzer['safeSummary']['variables'],
        )
        self.assertIn(
            'trigger_list',
            analyzer['safeSummary']['variables'],
        )

    def test_prompt_default_virtual_node_summary_includes_variable_contracts(self):
        assets = {
            asset['id']: asset
            for asset in api._prompt_defaults_virtual_assets()
        }
        analyzer = assets['auto_reply.analyzer.default']
        contracts = analyzer['safeSummary']['variableContracts']

        self.assertEqual(
            'ContextAnalyzer._buildRuntimeStateJson',
            contracts['state_json']['valueSource'],
        )
        self.assertEqual(
            {'type': 'json_string'},
            contracts['state_json']['runtimeShape'],
        )

    def test_flutter_artifact_node_library_includes_prompt_variables(self):
        artifact = api._flutter_agent_context_artifact(api._default_document())
        nodes = {
            node['id']: node
            for node in artifact['nodeLibrary']
        }
        analyzer = nodes['auto_reply.analyzer.default']

        self.assertIn(
            'current_role_persona',
            analyzer['safeSummary']['variables'],
        )
        self.assertIn(
            'trigger_list',
            analyzer['safeSummary']['variables'],
        )
        self.assertIn('variableContracts', analyzer['safeSummary'])
        self.assertIn('state_json', analyzer['safeSummary']['variableContracts'])

    def test_prompt_default_virtual_nodes_cannot_be_mutated_as_assets(self):
        prompt_id = api.load_prompt_defaults_document()['prompts'][0]['id']
        with tempfile.TemporaryDirectory() as temp_dir:
            original_data_path, original_artifact_path, _, _ = self._use_temp_paths(temp_dir)
            try:
                with self.assertRaises(Exception) as update_error:
                    asyncio.run(api.update_asset(prompt_id, {'asset': {'name': 'Changed'}}))
                with self.assertRaises(Exception) as delete_error:
                    asyncio.run(api.delete_asset(prompt_id))
                with self.assertRaises(Exception) as create_error:
                    asyncio.run(api.create_asset({
                        'asset': {
                            'id': prompt_id,
                            'name': 'Collision',
                            'assetType': 'role_card',
                        },
                    }))
            finally:
                api.DATA_PATH = original_data_path
                api.FLUTTER_AGENT_CONTEXT_DEFAULTS_PATH = original_artifact_path

        self.assertEqual(400, update_error.exception.status_code)
        self.assertEqual(400, delete_error.exception.status_code)
        self.assertEqual(400, create_error.exception.status_code)

    def test_save_graph_replaces_derived_bindings(self):
        document = api._default_document()
        agent = api._agent_full_chat_template(
            agent_id='chat_agent:contact_1',
            contact_id='contact_1',
            name='ChatAgent:contact_1',
        )
        document['agents'].append(agent)
        prompt_id = api.load_prompt_defaults_document()['prompts'][0]['id']
        graph = api._normalize_agent_graph({
            'nodes': [
                {
                    'id': 'graph_prompt_1',
                    'nodeId': prompt_id,
                    'nodeType': 'prompt',
                    'label': 'Prompt node',
                },
            ],
        })

        api._replace_agent_bindings_from_graph(document, 'chat_agent:contact_1', graph)

        bindings = api._bindings_for_agent(document, 'chat_agent:contact_1')
        self.assertEqual(1, len(bindings))
        self.assertEqual(prompt_id, bindings[0]['nodeId'])
        self.assertEqual('graph_prompt_1', bindings[0]['graphNodeId'])

    def test_flutter_artifact_is_compact_and_consumable(self):
        document = api._default_document()
        api._ensure_builtin_agents_in_document(document)
        with tempfile.TemporaryDirectory() as temp_dir:
            original_artifact_path = api.FLUTTER_AGENT_CONTEXT_DEFAULTS_PATH
            api.FLUTTER_AGENT_CONTEXT_DEFAULTS_PATH = Path(temp_dir) / 'agent_context_defaults.json'
            try:
                artifact = api._write_flutter_agent_context_artifact(document)
                decoded = json.loads(api.FLUTTER_AGENT_CONTEXT_DEFAULTS_PATH.read_text(encoding='utf-8'))
            finally:
                api.FLUTTER_AGENT_CONTEXT_DEFAULTS_PATH = original_artifact_path

        self.assertEqual(artifact['version'], decoded['version'])
        self.assertIn('agents', decoded)
        self.assertIn('bindings', decoded)
        self.assertIn('nodeLibrary', decoded)
        self.assertNotIn('assets', decoded)
        self.assertNotIn('raw', json.dumps(decoded, ensure_ascii=False))

    def test_agent_prompt_preview_uses_actual_prompt_defaults_text(self):
        original_loader = api.load_prompt_defaults_document
        api.load_prompt_defaults_document = lambda: {
            'version': 1,
            'variables': [],
            'prompts': [
                {
                    'id': 'prompt.one',
                    'dartName': 'promptOne',
                    'title': 'Prompt One',
                    'variables': [],
                    'template': 'First prompt body',
                },
                {
                    'id': 'prompt.two',
                    'dartName': 'promptTwo',
                    'title': 'Prompt Two',
                    'variables': [],
                    'template': 'Second prompt body',
                },
            ],
        }
        try:
            document = api._default_document()
            agent = api._agent_full_chat_template(
                agent_id='chat_agent:preview',
                contact_id='preview',
                name='Preview Agent',
            )
            graph = api._normalize_agent_graph({
                'nodes': [
                    {'id': 'g1', 'nodeId': 'prompt.one', 'nodeType': 'prompt'},
                    {'id': 'g2', 'nodeId': 'prompt.two', 'nodeType': 'prompt'},
                ],
                'edges': [{'id': 'e1', 'source': 'g1', 'target': 'g2'}],
                'entryNodeIds': ['g1'],
            })
            agent['agentGraph'] = graph
            document['agents'].append(agent)

            preview = api._agent_prompt_preview(document, agent, {'graph': graph})
        finally:
            api.load_prompt_defaults_document = original_loader

        self.assertEqual(2, preview['actualPromptPreview']['messageCount'])
        self.assertIn('First prompt body', preview['actualPromptPreview']['combinedText'])
        self.assertIn('Second prompt body', preview['actualPromptPreview']['combinedText'])
        self.assertEqual('prompt.one', preview['renderedMessages'][0]['nodeId'])

    def test_agent_prompt_preview_renders_sample_values_and_warns_about_variables(self):
        original_loader = api.load_prompt_defaults_document
        api.load_prompt_defaults_document = lambda: {
            'version': 1,
            'variables': [
                {
                    'name': 'name',
                    'sampleValue': '小柚',
                    'valueSource': 'test',
                    'runtimeShape': {'type': 'string'},
                },
                {
                    'name': 'state_json',
                    'runtimeSampleValue': '{"mode":"active","conversation_id":"conv_test"}',
                    'valueSource': 'runtime',
                    'runtimeShape': {'type': 'json_string'},
                },
            ],
            'prompts': [
                {
                    'id': 'prompt.render',
                    'dartName': 'promptRender',
                    'title': 'Prompt Render',
                    'variables': ['name', 'state_json', 'unused_declared'],
                    'template': 'name={name}\nstate={state_json}\nmissing={missing_value}',
                },
            ],
        }
        try:
            document = api._default_document()
            agent = api._agent_full_chat_template(
                agent_id='chat_agent:render',
                contact_id='render',
                name='Render Agent',
            )
            graph = api._normalize_agent_graph({
                'nodes': [
                    {'id': 'g1', 'nodeId': 'prompt.render', 'nodeType': 'prompt'},
                ],
            })
            agent['agentGraph'] = graph
            document['agents'].append(agent)

            preview = api._agent_prompt_preview(document, agent, {'graph': graph})
        finally:
            api.load_prompt_defaults_document = original_loader

        combined = preview['actualPromptPreview']['combinedText']
        self.assertIn('name=小柚', combined)
        self.assertIn('conversation_id', combined)
        self.assertIn('missing={missing_value}', combined)
        self.assertIn('Prompt Render', combined)
        joined_warnings = '\n'.join(preview['warnings'])
        self.assertIn('prompt.render 引用未定义变量：{missing_value}', joined_warnings)
        self.assertIn(
            'prompt.render 声明变量当前模板未直接使用：unused_declared',
            joined_warnings,
        )
        self.assertIn('missing_value', preview['renderedMessages'][0]['unresolvedVariables'])

    def test_agent_prompt_preview_prefers_supplied_runtime_values(self):
        original_loader = api.load_prompt_defaults_document
        api.load_prompt_defaults_document = lambda: {
            'version': 1,
            'variables': [
                {
                    'name': 'name',
                    'sampleValue': '样例名',
                    'runtimeSampleValue': '运行态样例名',
                    'valueSource': 'test',
                    'runtimeShape': {'type': 'string'},
                },
            ],
            'prompts': [
                {
                    'id': 'prompt.render',
                    'dartName': 'promptRender',
                    'title': 'Prompt Render',
                    'variables': ['name'],
                    'template': 'name={name}\nextra={extra_value}',
                },
            ],
        }
        try:
            document = api._default_document()
            agent = api._agent_full_chat_template(
                agent_id='chat_agent:render',
                contact_id='render',
                name='Render Agent',
            )
            graph = api._normalize_agent_graph({
                'nodes': [
                    {'id': 'g1', 'nodeId': 'prompt.render', 'nodeType': 'prompt'},
                ],
            })
            agent['agentGraph'] = graph
            document['agents'].append(agent)

            preview = api._agent_prompt_preview(document, agent, {
                'graph': graph,
                'sampleValues': {'name': '样例覆盖名'},
                'variables': {'name': '兼容变量名'},
                'runtimeValues': {
                    'name': '运行态实值名',
                    'extra_value': '运行态额外值',
                },
            })
        finally:
            api.load_prompt_defaults_document = original_loader

        combined = preview['actualPromptPreview']['combinedText']
        self.assertIn('name=运行态实值名', combined)
        self.assertIn('extra=运行态额外值', combined)
        self.assertNotIn('extra_value', preview['renderedMessages'][0]['unresolvedVariables'])

    def test_agent_prompt_preview_groups_stage_separated_graph_nodes(self):
        original_loader = api.load_prompt_defaults_document
        api.load_prompt_defaults_document = lambda: {
            'version': 1,
            'variables': [],
            'prompts': [
                {
                    'id': 'analyzer.default',
                    'dartName': 'analyzerDefault',
                    'title': 'Analyzer',
                    'variables': [],
                    'template': 'Analyzer body',
                },
                {
                    'id': 'runtime.instruction',
                    'dartName': 'runtimeInstruction',
                    'title': 'Runtime',
                    'variables': [],
                    'template': 'Runtime body',
                },
                {
                    'id': 'reply.objective',
                    'dartName': 'replyObjective',
                    'title': 'Reply',
                    'variables': [],
                    'template': 'Reply body',
                },
            ],
        }
        try:
            document = api._default_document()
            agent = api._agent_full_chat_template(
                agent_id='chat_agent:staged_preview',
                contact_id='staged_preview',
                name='Staged Preview Agent',
            )
            graph = api._normalize_agent_graph({
                'stages': [
                    {'id': 'analyzer', 'label': 'Analyzer stage', 'order': 10},
                    {'id': 'reply_generation', 'label': 'Reply stage', 'order': 20},
                ],
                'nodes': [
                    {
                        'id': 'g1',
                        'nodeId': 'analyzer.default',
                        'nodeType': 'prompt',
                        'config': {'stage': 'analyzer', 'stageLabel': 'Analyzer stage', 'stageOrder': 10},
                    },
                    {
                        'id': 'g2',
                        'nodeId': 'runtime.instruction',
                        'nodeType': 'prompt',
                        'config': {'stage': 'analyzer', 'stageLabel': 'Analyzer stage', 'stageOrder': 10},
                    },
                    {
                        'id': 'g3',
                        'nodeId': 'reply.objective',
                        'nodeType': 'prompt',
                        'config': {'stage': 'reply_generation', 'stageLabel': 'Reply stage', 'stageOrder': 20},
                    },
                ],
                'edges': [{'id': 'e1', 'source': 'g1', 'target': 'g2'}],
                'entryNodeIds': ['g1', 'g3'],
                'outputNodeIds': ['g2', 'g3'],
            })
            agent['agentGraph'] = graph
            document['agents'].append(agent)

            preview = api._agent_prompt_preview(document, agent, {'graph': graph})
        finally:
            api.load_prompt_defaults_document = original_loader

        groups = preview['actualPromptPreview']['stageGroups']
        self.assertEqual(['analyzer', 'reply_generation'], [group['stage'] for group in groups])
        self.assertEqual(
            ['analyzer.default', 'runtime.instruction'],
            [item['nodeId'] for item in groups[0]['renderedMessages']],
        )
        self.assertEqual(['reply.objective'], [item['nodeId'] for item in groups[1]['renderedMessages']])
        self.assertIn('## Analyzer stage (analyzer)', preview['actualPromptPreview']['combinedText'])
        self.assertIn('## Reply stage (reply_generation)', preview['actualPromptPreview']['combinedText'])

    def test_prompt_default_node_update_uses_prompt_codegen_path(self):
        prompt_document = {
            'version': 1,
            'variables': [],
            'prompts': [
                {
                    'id': 'prompt.one',
                    'dartName': 'promptOne',
                    'title': 'Old',
                    'variables': [],
                    'template': 'Old body',
                },
            ],
        }
        captured: dict[str, object] = {}
        original_loader = api.load_prompt_defaults_document
        original_generate = api.generate_prompt_defaults_from_document

        def fake_loader():
            return json.loads(json.dumps(prompt_document, ensure_ascii=False))

        def fake_generate(document):
            captured['document'] = json.loads(json.dumps(document, ensure_ascii=False))
            return Path('generated.dart')

        with tempfile.TemporaryDirectory() as temp_dir:
            original_data_path, original_artifact_path, _, artifact_path = self._use_temp_paths(temp_dir)
            api.load_prompt_defaults_document = fake_loader
            api.generate_prompt_defaults_from_document = fake_generate
            try:
                _, prompt = api._update_prompt_default_node(
                    'prompt.one',
                    {
                        'title': 'New',
                        'description': 'Edited from graph',
                        'variables': 'foo, bar',
                        'template': 'New body',
                    },
                )
                artifact_written = artifact_path.exists()
            finally:
                api.load_prompt_defaults_document = original_loader
                api.generate_prompt_defaults_from_document = original_generate
                api.DATA_PATH = original_data_path
                api.FLUTTER_AGENT_CONTEXT_DEFAULTS_PATH = original_artifact_path

        saved_prompt = captured['document']['prompts'][0]  # type: ignore[index]
        self.assertEqual('New', prompt['title'])
        self.assertEqual('New body', saved_prompt['template'])
        self.assertEqual(['foo', 'bar'], saved_prompt['variables'])
        self.assertTrue(artifact_written)


if __name__ == '__main__':
    unittest.main()
